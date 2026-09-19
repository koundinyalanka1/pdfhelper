import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/home_tabs.dart';
import '../models/library_query.dart';
import '../providers/theme_provider.dart';
import '../services/pdf_library_service.dart';
import '../services/pdf_raster.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../utils/format_utils.dart';
import 'ai_screen.dart';
import 'extract_text_screen.dart';
import 'metadata_screen.dart';
import 'organize_pages_screen.dart';
import 'pdf_viewer_screen.dart';
import 'protect_screen.dart';

/// Every PDF on the device, on one screen.
///
/// This is the app's landing tab and its answer to "where are my documents" —
/// a reader shows you what you already have rather than making you find it
/// through a file picker every time. The sweep itself lives in
/// [PdfLibraryService]; this screen owns presentation, selection state and
/// the per-file actions.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.onSendTo,
    this.onOpenInTools,
    this.refreshToken = 0,
  });

  /// Open merge or split on a document. Null when this screen is pushed as a
  /// standalone route, in which case those actions are not offered.
  final void Function(DocHandoff action, String path)? onSendTo;

  /// Make a document the one the Tools tab is working on, and go there.
  final void Function(String path)? onOpenInTools;

  /// Bumped by [HomeScreen] whenever the user returns to this tab.
  ///
  /// An `IndexedStack` gives its children no "you are visible again" callback,
  /// so without this a PDF just produced in Merge or Scan would not appear
  /// here until the user thought to pull to refresh.
  final int refreshToken;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  static const Color _accent = Color(0xFFE94560);
  static const String _viewModeKey = 'library.grid';
  static const String _sortKey = 'library.sort';

  List<PdfFileEntry> _entries = const [];
  List<String> _recentOrder = const [];
  Set<String> _starred = {};

  LibraryFilter _filter = LibraryFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  bool _isGrid = true;
  bool _isSearching = false;
  String _query = '';

  StorageAccess _access = StorageAccess.appOnly;
  bool _isScanning = false;
  bool _refreshPending = false;
  bool _isRequestingAccess = false;
  bool _hasScanned = false;

  final TextEditingController _searchController = TextEditingController();

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshToken != oldWidget.refreshToken) {
      unawaited(_refresh(prune: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A file or a storage grant can change even during a brief visit to
    // Settings/another app. Never suppress that refresh with a time throttle.
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refresh(prune: true));
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> _bootstrap() async {
    await _restorePreferences();
    // Warm start: show last session's list immediately, then refresh behind
    // it. A full sweep takes seconds; an empty screen for that long reads as
    // "this app has nothing in it".
    final cached = await PdfLibraryService.cached();
    if (mounted && cached.isNotEmpty) {
      setState(() => _entries = cached);
    }
    await _loadUserLists();
    await _refresh(prune: cached.isNotEmpty);
  }

  Future<void> _restorePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final grid = prefs.getBool(_viewModeKey);
      final sortIndex = prefs.getInt(_sortKey);
      if (!mounted) return;
      setState(() {
        if (grid != null) _isGrid = grid;
        if (sortIndex != null &&
            sortIndex >= 0 &&
            sortIndex < LibrarySort.values.length) {
          _sort = LibrarySort.values[sortIndex];
        }
      });
    } catch (_) {
      // Preferences are a convenience; defaults are fine.
    }
  }

  Future<void> _loadUserLists() async {
    final recents = await RecentFilesService.recents();
    final starred = await RecentFilesService.starred();
    if (!mounted) return;
    setState(() {
      _recentOrder = recents;
      _starred = starred;
    });
  }

  Future<void> _refresh({bool prune = false}) async {
    if (!mounted) return;
    if (_isScanning) {
      // A grant or a newly mounted volume may arrive during an older sweep.
      // Queue a fresh sweep instead of dropping the request.
      _refreshPending = true;
      return;
    }
    setState(() => _isScanning = true);
    try {
      final access = await PdfLibraryService.access();
      if (!mounted) return;
      setState(() => _access = access);
      if (prune) {
        final alive = await PdfLibraryService.prune(_entries);
        if (mounted && alive.length != _entries.length) {
          setState(() => _entries = alive);
        }
      }
      final found = await PdfLibraryService.scan();
      // Recents can point at files outside every scanned root — a document
      // opened straight from another app, for instance. Describe those so the
      // Recent filter never has holes in it.
      final known = found.map((e) => e.path).toSet();
      final extras = <PdfFileEntry>[];
      for (final path in _recentOrder) {
        if (known.contains(path)) continue;
        final entry = await PdfLibraryService.describe(path);
        if (entry != null) extras.add(entry);
      }
      if (!mounted) return;
      setState(() {
        _entries = [...found, ...extras];
        _access = access;
      });
    } catch (e) {
      // A failed sweep leaves whatever was already listed on screen. The one
      // outcome that must not happen is a spinner that never stops.
      logError('LibraryScreen._refresh', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not finish looking for PDFs. Pull down to try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _hasScanned = true;
        });
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_refresh(prune: true));
        }
      }
    }
  }

  // ------------------------------------------------------------- filtering

  List<PdfFileEntry> get _visible => LibraryQuery(
    filter: _filter,
    sort: _sort,
    search: _query,
    recents: _recentOrder,
    starred: _starred,
  ).apply(_entries);

  // --------------------------------------------------------------- actions

  Future<void> _open(PdfFileEntry entry) async {
    await RecentFilesService.markOpened(entry.path);
    await _loadUserLists();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PdfViewerScreen(pdfPath: entry.path, title: entry.name),
      ),
    );
  }

  Future<void> _requestAccess() async {
    if (_isRequestingAccess) return;
    setState(() => _isRequestingAccess = true);
    final granted = await PdfLibraryService.requestAccess();
    if (!mounted) return;
    setState(() {
      _access = granted;
      _isRequestingAccess = false;
    });
    if (granted == StorageAccess.full) {
      await _refresh();
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'PDF Helper still cannot read shared storage. Turn on '
          'storage access in Settings to find PDFs outside this app.',
        ),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: PdfLibraryService.openSettings,
        ),
      ),
    );
  }

  /// Bring a PDF in from the system file picker.
  ///
  /// On iOS this is the only way a document reaches the app at all, so the
  /// file is copied into app storage; on Android the picked path is already
  /// readable and is left where it is.
  Future<void> _import() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      final picked = result.map((f) => f.path).whereType<String>().toList();
      if (picked.isEmpty) return;

      final imported = <String>[];
      for (final path in picked) {
        imported.add(await _shouldCopy(path) ? await _copyIntoLibrary(path) : path);
      }
      for (final path in imported) {
        await RecentFilesService.markOpened(path);
      }
      await _loadUserLists();
      await _refresh();
      if (!mounted) return;
      _snack(
        imported.length == 1
            ? 'Added ${imported.first.split('/').last}'
            : 'Added ${imported.length} PDFs',
      );
    } catch (e) {
      if (mounted) _snack('Could not import that file: $e');
    }
  }

  /// Whether an imported file has to be copied to survive.
  ///
  /// iOS hands out a sandboxed temporary copy, and Android's picker copies
  /// `content://` selections into the app cache — a directory the sweep skips
  /// and the OS is free to empty. A file picked from a real, durable location
  /// on Android is referenced where it already lives instead of duplicated.
  Future<bool> _shouldCopy(String path) async {
    if (Platform.isIOS) return true;
    try {
      final temp = await getTemporaryDirectory();
      if (path.startsWith(temp.path)) return true;
    } catch (_) {
      // Fall through to the path check.
    }
    return path.contains('/cache/');
  }

  Future<String> _copyIntoLibrary(String path) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = path.split('/').last;
    var target = File('${dir.path}/$name');
    var counter = 1;
    while (await target.exists()) {
      final base = name.toLowerCase().endsWith('.pdf')
          ? name.substring(0, name.length - 4)
          : name;
      target = File('${dir.path}/$base ($counter).pdf');
      counter++;
    }
    await File(path).copy(target.path);
    return target.path;
  }

  Future<void> _toggleStar(PdfFileEntry entry) async {
    final starred = await RecentFilesService.toggleStar(entry.path);
    if (!mounted) return;
    setState(() {
      if (starred) {
        _starred.add(entry.path);
      } else {
        _starred.remove(entry.path);
      }
    });
  }

  Future<void> _rename(PdfFileEntry entry) async {
    final controller = TextEditingController(text: entry.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text('Rename', style: TextStyle(color: _colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: _colors.textPrimary),
          decoration: const InputDecoration(
            labelText: 'File name',
            suffixText: '.pdf',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: _colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    final trimmed = newName?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == entry.title) return;
    // Path separators in a file name would silently move the file somewhere
    // else, so they are stripped rather than rejected.
    final safe = trimmed.replaceAll(RegExp(r'[/\\]'), '_');
    final directory = entry.path.substring(0, entry.path.lastIndexOf('/'));
    final target = '$directory/$safe.pdf';
    if (target == entry.path) return;

    try {
      if (await File(target).exists()) {
        if (mounted) _snack('A file with that name already exists');
        return;
      }
      await File(entry.path).rename(target);
      PdfRaster.invalidate(entry.path);
      PdfLibraryService.forget(entry.path);
      await RecentFilesService.rename(entry.path, target);
      await _loadUserLists();
      await _refresh();
      if (mounted) _snack('Renamed to $safe.pdf');
    } catch (e) {
      if (mounted) _snack('Could not rename: $e');
    }
  }

  Future<void> _delete(PdfFileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text(
          'Delete file?',
          style: TextStyle(color: _colors.textPrimary),
        ),
        content: Text(
          '${entry.name} will be permanently deleted from this device.',
          style: TextStyle(color: _colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: _colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await File(entry.path).delete();
      PdfRaster.invalidate(entry.path);
      PdfLibraryService.forget(entry.path);
      await RecentFilesService.forget(entry.path);
      if (!mounted) return;
      setState(() {
        _entries = _entries.where((e) => e.path != entry.path).toList();
        _starred.remove(entry.path);
        _recentOrder = _recentOrder.where((p) => p != entry.path).toList();
      });
      _snack('${entry.name} deleted');
    } catch (e) {
      if (mounted) _snack('Could not delete: $e');
    }
  }

  Future<void> _showDetails(PdfFileEntry entry) async {
    // A details sheet has no way to ask for a password, so an encrypted
    // file simply reports an unknown page count here.
    final pageCount = await PdfRaster.pageCountOrZero(entry.path);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text(
          entry.title,
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('Pages', pageCount > 0 ? '$pageCount' : 'Unreadable'),
            _detailRow('Size', formatFileSize(entry.sizeBytes)),
            _detailRow('Modified', formatLibraryDate(entry.modified, long: true)),
            _detailRow('Location', entry.path),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: _colors.textTertiary,
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(color: _colors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showActions(PdfFileEntry entry) async {
    final isStarred = _starred.contains(entry.path);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _colors.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.picture_as_pdf_rounded,
                      color: _accent,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${entry.folder} · ${formatFileSize(entry.sizeBytes)}',
                            style: TextStyle(
                              color: _colors.textTertiary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: _colors.divider, height: 20),
              _action(ctx, Icons.visibility_rounded, 'Open', () {
                _open(entry);
              }),
              _action(
                ctx,
                isStarred ? Icons.star_rounded : Icons.star_border_rounded,
                isStarred ? 'Remove star' : 'Star',
                () => _toggleStar(entry),
              ),
              _action(ctx, Icons.share_rounded, 'Share', () {
                SharePlus.instance.share(ShareParams(files: [XFile(entry.path)]));
              }),
              Divider(color: _colors.divider, height: 20),
              _action(ctx, Icons.auto_awesome_rounded, 'Ask AI', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AiScreen(pdfPath: entry.path),
                  ),
                );
              }),
              _action(ctx, Icons.dashboard_customize_rounded, 'Organize pages', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OrganizePagesScreen(pdfPath: entry.path),
                  ),
                );
              }),
              _action(ctx, Icons.text_snippet_rounded, 'Extract text', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExtractTextScreen(pdfPath: entry.path),
                  ),
                );
              }),
              _action(ctx, Icons.lock_rounded, 'Protect', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProtectScreen(pdfPath: entry.path),
                  ),
                );
              }),
              _action(ctx, Icons.info_outline_rounded, 'Document details', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MetadataScreen(pdfPath: entry.path),
                  ),
                );
              }),
              if (widget.onSendTo != null) ...[
                Divider(color: _colors.divider, height: 20),
                _action(ctx, Icons.merge_rounded, 'Merge with…', () {
                  widget.onSendTo!(DocHandoff.merge, entry.path);
                }),
                _action(ctx, Icons.content_cut_rounded, 'Split', () {
                  widget.onSendTo!(DocHandoff.split, entry.path);
                }),
              ],
              if (widget.onOpenInTools != null)
                _action(ctx, Icons.handyman_rounded, 'Open in Tools', () {
                  widget.onOpenInTools!(entry.path);
                }),
              Divider(color: _colors.divider, height: 20),
              _action(ctx, Icons.drive_file_rename_outline_rounded, 'Rename', () {
                _rename(entry);
              }),
              _action(ctx, Icons.article_outlined, 'File info', () {
                _showDetails(entry);
              }),
              _action(
                ctx,
                Icons.delete_outline_rounded,
                'Delete',
                () => _delete(entry),
                danger: true,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext sheetContext,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final color = danger ? Colors.red.shade400 : _colors.textPrimary;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: danger ? Colors.red.shade400 : _accent, size: 21),
      title: Text(label, style: TextStyle(color: color, fontSize: 14.5)),
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _colors = AppColors.of(context);
    final visible = _visible;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFilterBar(),
          if (_isScanning) _buildScanIndicator(),
          if (_access == StorageAccess.appOnly && !_isScanning)
            _buildAccessBanner(),
          Expanded(
            child: RefreshIndicator(
              color: _accent,
              onRefresh: () => _refresh(prune: true),
              child: visible.isEmpty
                  ? _buildEmptyState()
                  : (_isGrid ? _buildGrid(visible) : _buildList(visible)),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _import,
        backgroundColor: _accent,
        tooltip: 'Import a PDF',
        child: const Icon(Icons.note_add_rounded, color: Colors.white),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _colors.cardBackground,
      elevation: 0,
      titleSpacing: _isSearching ? 8 : null,
      title: _isSearching
          ? TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: _colors.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Search PDFs',
                hintStyle: TextStyle(color: _colors.textTertiary),
                border: InputBorder.none,
              ),
              onChanged: (value) => setState(() => _query = value),
            )
          : Text(
              'Files',
              style: TextStyle(
                color: _colors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
      actions: [
        IconButton(
          tooltip: _isSearching ? 'Close search' : 'Search',
          icon: Icon(
            _isSearching ? Icons.close_rounded : Icons.search_rounded,
            color: _colors.textPrimary,
          ),
          onPressed: () => setState(() {
            _isSearching = !_isSearching;
            if (!_isSearching) {
              _query = '';
              _searchController.clear();
            }
          }),
        ),
        IconButton(
          tooltip: _isGrid ? 'List view' : 'Grid view',
          icon: Icon(
            _isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
            color: _colors.textPrimary,
          ),
          onPressed: () async {
            setState(() => _isGrid = !_isGrid);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(_viewModeKey, _isGrid);
          },
        ),
        PopupMenuButton<LibrarySort>(
          tooltip: 'Sort',
          icon: Icon(Icons.sort_rounded, color: _colors.textPrimary),
          color: _colors.cardBackground,
          initialValue: _sort,
          onSelected: (value) async {
            setState(() => _sort = value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(_sortKey, value.index);
          },
          itemBuilder: (_) => [
            for (final option in LibrarySort.values)
              PopupMenuItem(
                value: option,
                child: Text(
                  option.label,
                  style: TextStyle(color: _colors.textPrimary),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterBar() {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final option in LibraryFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(option.label),
                selected: _filter == option,
                onSelected: (_) => setState(() => _filter = option),
                showCheckmark: false,
                backgroundColor: _colors.cardBackground,
                selectedColor: _accent.withValues(alpha: 0.16),
                labelStyle: TextStyle(
                  color: _filter == option ? _accent : _colors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: _filter == option
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
                side: BorderSide(
                  color: _filter == option ? _accent : _colors.divider,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScanIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
          ),
          const SizedBox(width: 10),
          Text(
            'Looking for PDFs on this device…',
            style: TextStyle(color: _colors.textTertiary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildAccessBanner() {
    final isAndroid = Platform.isAndroid;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.folder_open_rounded, color: _accent, size: 19),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAndroid
                      ? 'Showing only PDF Helper\'s own files'
                      : 'Showing documents inside PDF Helper',
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isAndroid
                      ? 'Allow all files access to find PDFs in internal '
                            'storage and SD/USB drives. Android keeps other '
                            'apps\' private folders restricted.'
                      : 'iOS keeps each app to its own documents. Import a '
                            'PDF to add it to your library.',
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: FilledButton(
                    onPressed: _isRequestingAccess
                        ? null
                        : isAndroid
                        ? _requestAccess
                        : _import,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(isAndroid ? 'Allow access' : 'Import a PDF'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final String message;
    if (_query.trim().isNotEmpty) {
      message = 'No PDFs match "${_query.trim()}".';
    } else {
      message = switch (_filter) {
        LibraryFilter.recent => 'Documents you open show up here.',
        LibraryFilter.starred => 'Star a document to keep it close at hand.',
        LibraryFilter.created =>
          'PDFs you make with PDF Helper are collected here.',
        LibraryFilter.all => _hasScanned
            ? 'No PDFs found on this device yet.'
            : 'Looking for PDFs…',
      };
    }
    // Explicitly always-scrollable: this content is shorter than the viewport,
    // and a ListView that cannot scroll gives RefreshIndicator no drag to
    // respond to — pull-to-refresh would be dead exactly when it is most
    // useful, on an empty library.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 90),
      children: [
        Icon(
          Icons.folder_open_rounded,
          size: 54,
          color: _colors.textTertiary,
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _colors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: OutlinedButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.note_add_rounded, size: 18),
            label: const Text('Import a PDF'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              side: const BorderSide(color: _accent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGrid(List<PdfFileEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Target ~160dp tiles, so a phone gets 2-3 columns and a tablet more.
        final columns = (constraints.maxWidth / 170).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.62,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) => _GridTile(
            entry: entries[index],
            colors: _colors,
            accent: _accent,
            isStarred: _starred.contains(entries[index].path),
            onTap: () => _open(entries[index]),
            onMore: () => _showActions(entries[index]),
          ),
        );
      },
    );
  }

  Widget _buildList(List<PdfFileEntry> entries) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _ListRow(
          entry: entry,
          colors: _colors,
          accent: _accent,
          isStarred: _starred.contains(entry.path),
          subtitle:
              '${entry.folder} · ${formatFileSize(entry.sizeBytes)} · '
              '${formatLibraryDate(entry.modified)}',
          onTap: () => _open(entry),
          onMore: () => _showActions(entry),
        );
      },
    );
  }
}

/// Tab indices for [HomeScreen], so the library can hand a file to another
/// tab without hard-coding a number that shifts every time the nav changes.
// ---------------------------------------------------------------------------
// Tiles
// ---------------------------------------------------------------------------

/// First-page cover, rendered on demand.
///
/// Kept as its own widget so each tile owns exactly one render request and a
/// scroll past a tile that never finished does not leave a dangling setState.
class _Cover extends StatefulWidget {
  const _Cover({required this.entry, required this.colors});

  final PdfFileEntry entry;
  final AppColors colors;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  Uint8List? _bytes;
  bool _done = false;

  /// Largest size asked for so far, in device pixels.
  int _requested = 0;

  @override
  void didUpdateWidget(_Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.entry.modifiedMs != widget.entry.modifiedMs) {
      _done = false;
      _bytes = null;
      _requested = 0;
    }
  }

  /// Ask for a cover at least [longEdge] device pixels on its long side.
  void _want(int longEdge) {
    if (longEdge <= _requested) return;
    _requested = longEdge;

    final path = widget.entry.path;
    final modified = widget.entry.modifiedMs;

    // An already-rendered cover is taken synchronously, so scrolling back over
    // a tile paints it in the same frame instead of flashing a placeholder.
    if (PdfRaster.isCoverCached(
      path,
      modifiedMs: modified,
      longEdge: longEdge,
    )) {
      _bytes = PdfRaster.cachedCover(
        path,
        modifiedMs: modified,
        longEdge: longEdge,
      );
      _done = true;
      return;
    }
    unawaited(_render(path, modified, longEdge));
  }

  Future<void> _render(String path, int modified, int longEdge) async {
    // Let a fling settle first. Without this, dragging through a long library
    // queues one render per tile the list passes over, and the renderer spends
    // the next several seconds drawing covers for rows nobody is looking at.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted || widget.entry.path != path) return;

    final bytes = await PdfRaster.libraryCover(
      path,
      modifiedMs: modified,
      longEdge: longEdge,
    );
    if (!mounted || widget.entry.path != path) return;
    setState(() {
      _bytes = bytes;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Covers used to render at a fixed 240px and were then stretched to fill
    // the tile, which on a 3x phone meant a 480px box showing a 240px image —
    // visibly soft. Measure the tile and ask for its real device pixels.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final longest = constraints.biggest.longestSide;
        if (longest.isFinite && longest > 0) {
          _want((longest * dpr).round());
        }
        final bytes = _bytes;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => _placeholder(failed: true),
          );
        }
        return _placeholder(failed: _done);
      },
    );
  }

  Widget _placeholder({required bool failed}) {
    return ColoredBox(
      color: widget.colors.isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
      child: Center(
        child: Icon(
          failed
              ? Icons.picture_as_pdf_rounded
              : Icons.hourglass_empty_rounded,
          color: widget.colors.textTertiary,
          size: 22,
        ),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.entry,
    required this.colors,
    required this.accent,
    required this.isStarred,
    required this.onTap,
    required this.onMore,
  });

  final PdfFileEntry entry;
  final AppColors colors;
  final Color accent;
  final bool isStarred;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${entry.title}, ${formatFileSize(entry.sizeBytes)}',
      button: true,
      child: Material(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onMore,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Cover(entry: entry, colors: colors),
                    if (isStarred)
                      const Positioned(
                        top: 6,
                        left: 6,
                        child: Icon(
                          Icons.star_rounded,
                          size: 16,
                          color: Color(0xFFFFC107),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 2, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            formatFileSize(entry.sizeBytes),
                            style: TextStyle(
                              color: colors.textTertiary,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 17,
                        tooltip: 'More',
                        onPressed: onMore,
                        icon: Icon(
                          Icons.more_vert_rounded,
                          color: colors.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.entry,
    required this.colors,
    required this.accent,
    required this.isStarred,
    required this.subtitle,
    required this.onTap,
    required this.onMore,
  });

  final PdfFileEntry entry;
  final AppColors colors;
  final Color accent;
  final bool isStarred;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.cardBackground,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMore,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 42,
                  height: 54,
                  child: _Cover(entry: entry, colors: colors),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (isStarred) ...[
                          const Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Color(0xFFFFC107),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textTertiary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'More',
                iconSize: 19,
                onPressed: onMore,
                icon: Icon(Icons.more_vert_rounded, color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
