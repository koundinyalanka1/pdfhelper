import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/features.dart';
import '../models/doc_kind.dart';
import '../models/home_tabs.dart';
import '../models/library_query.dart';
import '../providers/theme_provider.dart';
import '../services/document_router.dart';
import '../services/library_service.dart';
import '../services/pdf_raster.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../utils/format_utils.dart';
import '../utils/file_naming.dart';
import '../widgets/library_scan_dialog.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/storage_access_dialog.dart';
import 'ai_screen.dart';
import 'document_editor_screen.dart';
import 'extract_text_screen.dart';
import 'metadata_screen.dart';
import 'organize_pages_screen.dart';
import 'protect_screen.dart';
import 'sheet_editor_screen.dart';
import 'slide_editor_screen.dart';

/// Every document on the device, on one screen: PDFs, Word, Excel,
/// PowerPoint and text files.
///
/// This is the app's landing tab and its answer to "where are my documents" —
/// a reader shows you what you already have rather than making you find it
/// through a file picker every time. The sweep itself lives in
/// [LibraryService]; this screen owns presentation, selection state and
/// the per-file actions.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.onSendTo,
    this.onOpenInTools,
    this.refreshToken = 0,
    this.isActive = true,
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

  /// A kept-alive tab must not ask for storage access over another tab.
  final bool isActive;

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

  /// Set once the access explanation has been offered on its own, so the
  /// library asks at the moment it is first obviously empty and never nags
  /// again. The banner stays as the always-available way back to it.
  static const String _accessPromptKey = 'library.accessPromptShown';

  List<LibraryEntry> _entries = const [];
  List<LibraryEntry> _referenceEntries = const [];
  List<String> _recentOrder = const [];
  Set<String> _starred = {};

  LibraryFilter _filter = LibraryFilter.all;
  LibrarySort _sort = LibrarySort.newest;

  /// Only documents of this kind; null shows every kind.
  DocKind? _kind;

  /// List is the default: a filename, folder, size and date say more about a
  /// document than a thumbnail of its first page, and most first pages of
  /// text documents look alike. A saved preference still wins — see
  /// [_restorePreferences].
  bool _isGrid = false;
  bool _isSearching = false;
  String _query = '';

  StorageAccess _access = StorageAccess.appOnly;
  bool _isScanning = false;
  bool _refreshPending = false;
  bool _isRequestingAccess = false;
  bool _hasScanned = false;
  bool _accessPromptShown = false;

  /// [_access] holds a real reading rather than its initial default, so a
  /// change to full access means a new grant, not a cold start that had it.
  bool _accessChecked = false;
  bool _searchDialogOpen = false;

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
    final cached = await LibraryService.cached();
    if (mounted && cached.isNotEmpty) {
      setState(() => _entries = cached);
    }
    await _loadUserLists();
    await _refresh(prune: cached.isNotEmpty);
    await _offerAccessOnce();
  }

  /// Ask for storage access once, the first time the library is opened
  /// without it.
  ///
  /// This is the moment the request makes sense: the user is looking at a
  /// library that is empty or nearly so, and the explanation answers the
  /// question they already have. Asking from a small banner button meant most
  /// people met Android's warning-toned settings screen with no context, or
  /// never found the button at all.
  Future<void> _offerAccessOnce() async {
    if (!mounted || !widget.isActive || !Platform.isAndroid) return;
    if (_accessPromptShown || _access == StorageAccess.full) return;
    // Do not talk over a sweep that might still turn the banner off.
    if (_isScanning) return;
    // A PDF opened from another app pushes the viewer over this tab while it
    // still bootstraps underneath. Say nothing then — the prompt is not spent,
    // so the next launch that actually lands here will offer it.
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    setState(() => _accessPromptShown = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_accessPromptKey, true);
    } catch (_) {
      // A preference that will not save is not worth blocking the prompt.
    }
    if (!mounted) return;
    await _requestAccess();
  }

  Future<void> _restorePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final grid = prefs.getBool(_viewModeKey);
      final sortIndex = prefs.getInt(_sortKey);
      final prompted = prefs.getBool(_accessPromptKey) ?? false;
      if (!mounted) return;
      setState(() {
        _accessPromptShown = prompted;
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

  /// Look through the device again. True when this sweep finished; false
  /// when it failed (and said so) or was queued behind one already running.
  Future<bool> _refresh({bool prune = false}) async {
    if (!mounted) return false;
    if (_isScanning) {
      // A grant or a newly mounted volume may arrive during an older sweep.
      // Queue a fresh sweep instead of dropping the request.
      _refreshPending = true;
      return false;
    }
    setState(() => _isScanning = true);
    // Set when this sweep is the first to see a new storage grant, so it is
    // shown in a dialog. Resolves to the number found, or null on failure.
    Completer<int?>? shown;
    var finished = false;
    try {
      await _loadUserLists();
      final access = await LibraryService.access();
      if (!mounted) return false;
      final justGranted =
          _accessChecked &&
          _access == StorageAccess.appOnly &&
          access == StorageAccess.full;
      _accessChecked = true;
      setState(() => _access = access);
      if (justGranted) {
        shown = Completer<int?>();
        unawaited(_showSearchProgress(shown.future));
      }
      if (prune) {
        final alive = await LibraryService.prune(_entries);
        if (mounted && alive.length != _entries.length) {
          setState(() => _entries = alive);
        }
      }
      final found = await LibraryService.scan();
      await _loadUserLists();
      // Intent/picker copies belong to Recent or Starred, not the device
      // library. Keep them separate so viewing a file never imports its
      // temporary copy into All PDFs or Created.
      final known = found.map((e) => e.path).toSet();
      final extras = <LibraryEntry>[];
      for (final path in {..._recentOrder, ..._starred}) {
        if (!known.add(path)) continue;
        final entry = await LibraryService.describe(path);
        if (entry != null) extras.add(entry);
      }
      if (!mounted) return false;
      setState(() {
        _entries = found;
        _referenceEntries = extras;
        _access = access;
      });
      shown?.complete(found.length);
      finished = true;
    } catch (e) {
      // A failed sweep leaves whatever was already listed on screen. The one
      // outcome that must not happen is a spinner that never stops.
      logError('LibraryScreen._refresh', e);
      // An open search dialog reports the failure itself.
      if (mounted && !_searchDialogOpen) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not finish looking for PDFs. Pull down to try again.',
            ),
          ),
        );
      }
    } finally {
      if (shown != null && !shown.isCompleted) shown.complete(null);
      if (mounted) {
        setState(() {
          _isScanning = false;
          _hasScanned = true;
        });
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_refresh(prune: true));
        } else {
          unawaited(_offerAccessOnce());
        }
      }
    }
    return finished;
  }

  /// The refresh button: look through the device again now, and say what
  /// it found — pull-to-refresh does the same, but nothing on screen says so.
  Future<void> _rescan() async {
    if (_isScanning) return;
    final before = {for (final entry in _entries) entry.path};
    if (!await _refresh(prune: true) || !mounted) return;
    final added = _entries
        .where((entry) => !before.contains(entry.path))
        .length;
    // This answer replaces the last one rather than queueing behind it.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _snack(switch (added) {
      0 => 'No new files found',
      1 => 'Found 1 new file',
      _ => 'Found ${formatCount(added)} new files',
    });
  }

  /// Show the sweep that follows a new storage grant in a dialog.
  ///
  /// Routine re-sweeps — on resume, on returning to the tab — stay a thin bar
  /// under the filters; a dialog each time the app comes back would be an
  /// interruption. This one is different: the user has just granted access
  /// and is waiting to see what it finds.
  Future<void> _showSearchProgress(Future<int?> found) async {
    // A kept-alive tab, or one under a pushed route, must not put a dialog
    // over whatever the user is actually looking at.
    if (!widget.isActive || !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    var finished = false;
    unawaited(found.then((_) => finished = true));
    _searchDialogOpen = true;
    try {
      await showLibraryScanDialog(context, found: found);
    } finally {
      _searchDialogOpen = false;
    }
    final closedOnResult = finished;
    final count = await found;
    if (!mounted || count == null) return;
    if (closedOnResult) {
      // "View PDFs" means the whole library, whichever list was showing.
      if (count > 0) setState(() => _filter = LibraryFilter.all);
      return;
    }
    // Sent to the background: say how it ended once it has. A failure is
    // reported by [_refresh], now that the dialog is not there to show it.
    _snack(switch (count) {
      0 => 'No PDFs found on this device',
      1 => 'Found 1 PDF',
      _ => 'Found ${formatCount(count)} PDFs',
    });
  }

  // ------------------------------------------------------------- filtering

  List<LibraryEntry> get _visible =>
      LibraryQuery(
        filter: _filter,
        sort: _sort,
        search: _query,
        recents: _recentOrder,
        starred: _starred,
        kind: _kind,
      ).apply(
        _filter == LibraryFilter.recent || _filter == LibraryFilter.starred
            ? [..._entries, ..._referenceEntries]
            : _entries,
      );

  // --------------------------------------------------------------- actions

  Future<void> _open(LibraryEntry entry) async {
    await RecentFilesService.markOpened(entry.path);
    await _loadUserLists();
    if (!mounted) return;
    await DocumentRouter.open(context, entry.path, title: entry.name);
    if (mounted) await _refresh(prune: true);
  }

  /// Start a new, empty text file in the app's documents folder and open it.
  /// The first save also publishes a copy to Download/DocHelper or
  /// Documents/DocHelper, so it outlives the app.
  Future<void> _newTextFile() async {
    final now = DateTime.now();
    final name = await askPdfName(
      context: context,
      initialName: 'Note ${formatLibraryDate(now)}',
      title: 'Name your text file',
      confirmLabel: 'Create',
      accent: DocKind.text.color,
      extension: '.txt',
    );
    if (name == null || !mounted) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      var file = File('${dir.path}/$name.txt');
      for (var n = 2; await file.exists(); n++) {
        file = File('${dir.path}/$name ($n).txt');
      }
      await file.writeAsString('');
      await RecentFilesService.markOpened(file.path);
      if (!mounted) return;
      await DocumentRouter.open(context, file.path);
      // A note left without a word in it was never really made; do not
      // leave an empty file behind in the library.
      if (await file.exists() && await file.length() == 0) {
        await file.delete();
        await RecentFilesService.forget(file.path);
      }
      if (mounted) await _refresh(prune: true);
    } catch (e) {
      _snack('Could not create the file: $e');
    }
  }

  /// Start a new, empty spreadsheet. It exists only in memory until its
  /// first save writes it to the app's documents folder (and publishes a
  /// copy to Download/DocHelper or Documents/DocHelper).
  Future<void> _newSpreadsheet() async {
    final now = DateTime.now();
    final name = await askPdfName(
      context: context,
      initialName: 'Sheet ${formatLibraryDate(now)}',
      title: 'Name your spreadsheet',
      confirmLabel: 'Create',
      accent: DocKind.sheet.color,
      extension: '.xlsx',
    );
    if (name == null || !mounted) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      var file = File('${dir.path}/$name.xlsx');
      for (var n = 2; await file.exists(); n++) {
        file = File('${dir.path}/$name ($n).xlsx');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SheetEditorScreen(path: file.path, isNew: true),
        ),
      );
      if (mounted) await _refresh(prune: true);
    } catch (e) {
      _snack('Could not create the spreadsheet: $e');
    }
  }

  Future<void> _newDocument() async {
    final now = DateTime.now();
    final name = await askPdfName(
      context: context,
      initialName: 'Document ${formatLibraryDate(now)}',
      title: 'Name your document',
      confirmLabel: 'Create',
      accent: DocKind.word.color,
      extension: '.docx',
    );
    if (name == null || !mounted) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      var file = File('${dir.path}/$name.docx');
      for (var n = 2; await file.exists(); n++) {
        file = File('${dir.path}/$name ($n).docx');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DocumentEditorScreen(path: file.path, isNew: true),
        ),
      );
      if (mounted) await _refresh(prune: true);
    } catch (e) {
      _snack('Could not create the document: $e');
    }
  }

  Future<void> _newPresentation() async {
    final now = DateTime.now();
    final name = await askPdfName(
      context: context,
      initialName: 'Presentation ${formatLibraryDate(now)}',
      title: 'Name your presentation',
      confirmLabel: 'Create',
      accent: DocKind.slides.color,
      extension: '.pptx',
    );
    if (name == null || !mounted) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      var file = File('${dir.path}/$name.pptx');
      for (var n = 2; await file.exists(); n++) {
        file = File('${dir.path}/$name ($n).pptx');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SlideEditorScreen(path: file.path, isNew: true),
        ),
      );
      if (mounted) await _refresh(prune: true);
    } catch (e) {
      _snack('Could not create the presentation: $e');
    }
  }

  Future<void> _showAddSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(DocKind.text.icon, color: DocKind.text.color),
                title: Text(
                  'New text file',
                  style: TextStyle(color: _colors.textPrimary),
                ),
                subtitle: Text(
                  'Notes, lists, anything typed',
                  style: TextStyle(color: _colors.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _newTextFile();
                },
              ),
              ListTile(
                leading: Icon(DocKind.word.icon, color: DocKind.word.color),
                title: Text(
                  'New document',
                  style: TextStyle(color: _colors.textPrimary),
                ),
                subtitle: Text(
                  'Letters, applications, reports: a Word document',
                  style: TextStyle(color: _colors.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _newDocument();
                },
              ),
              ListTile(
                leading: Icon(DocKind.sheet.icon, color: DocKind.sheet.color),
                title: Text(
                  'New spreadsheet',
                  style: TextStyle(color: _colors.textPrimary),
                ),
                subtitle: Text(
                  'Accounts, lists, bills: rows and columns with totals',
                  style: TextStyle(color: _colors.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _newSpreadsheet();
                },
              ),
              ListTile(
                leading: Icon(DocKind.slides.icon, color: DocKind.slides.color),
                title: Text(
                  'New presentation',
                  style: TextStyle(color: _colors.textPrimary),
                ),
                subtitle: Text(
                  'Slides to show: titles, points, pictures and shapes',
                  style: TextStyle(color: _colors.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _newPresentation();
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_open_rounded, color: _accent),
                title: Text(
                  'Import a file',
                  style: TextStyle(color: _colors.textPrimary),
                ),
                subtitle: Text(
                  'Add a PDF, Word, Excel, PowerPoint or text file',
                  style: TextStyle(color: _colors.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _import();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _requestAccess() async {
    if (_isRequestingAccess) return;
    // Explain before Android's settings screen appears, not after.
    if (!await showStorageAccessDialog(context)) return;
    if (!mounted) return;
    setState(() => _isRequestingAccess = true);
    final granted = await LibraryService.requestAccess();
    if (!mounted) return;
    setState(() => _isRequestingAccess = false);
    if (granted == StorageAccess.full) {
      // Leave [_access] for the sweep to update: seeing the change itself is
      // how it knows to show this search in a dialog. Returning from Settings
      // can start that sweep first, through the resume refresh.
      await _refresh();
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'DocHelper still cannot read shared storage. Turn on '
          'storage access in Settings to find documents outside this app.',
        ),
        duration: const Duration(seconds: 6),
        // A snack bar with an action otherwise ignores its duration.
        persist: false,
        action: SnackBarAction(
          label: 'Settings',
          onPressed: LibraryService.openSettings,
        ),
      ),
    );
  }

  /// Bring a document in from the system file picker.
  ///
  /// On iOS this is the only way a document reaches the app at all, so the
  /// file is copied into app storage; on Android the picked path is already
  /// readable and is left where it is.
  Future<void> _import() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: DocKind.importExtensions,
      );
      final picked = result.map((f) => f.path).whereType<String>().toList();
      if (picked.isEmpty) return;

      final imported = <String>[];
      for (final path in picked) {
        imported.add(
          await _shouldCopy(path) ? await _copyIntoLibrary(path) : path,
        );
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
            : 'Added ${imported.length} files',
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
    return LibraryService.isTemporaryPath(path);
  }

  Future<String> _copyIntoLibrary(String path) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = path.split('/').last;
    var target = File('${dir.path}/$name');
    final base = DocKind.titleOf(name);
    final extension = DocKind.extensionOf(name);
    var counter = 1;
    while (await target.exists()) {
      target = File(
        '${dir.path}/$base ($counter)${extension.isEmpty ? '' : '.$extension'}',
      );
      counter++;
    }
    await File(path).copy(target.path);
    return target.path;
  }

  Future<void> _toggleStar(LibraryEntry entry) async {
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

  Future<void> _rename(LibraryEntry entry) async {
    final extension = DocKind.extensionOf(entry.name);
    final suffix = extension.isEmpty ? '' : '.$extension';
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
          decoration: InputDecoration(
            labelText: 'File name',
            suffixText: suffix,
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
    final typed = suffix.isNotEmpty && trimmed.toLowerCase().endsWith(suffix)
        ? trimmed.substring(0, trimmed.length - suffix.length)
        : trimmed;
    final safe = sanitizeFileName(typed);
    try {
      final result = await LibraryService.renameDocument(
        entry.path,
        '$safe$suffix',
      );
      for (final path in result.renamedPaths.keys) {
        PdfRaster.invalidate(path);
      }
      await _loadUserLists();
      await _refresh();
      if (mounted) _snack(result.warning ?? 'Renamed to $safe$suffix');
    } catch (e) {
      if (mounted) _snack('Could not rename: $e');
    }
  }

  Future<void> _delete(LibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text(
          'Delete file?',
          style: TextStyle(color: _colors.textPrimary),
        ),
        content: Text(
          'Delete ${entry.name} and its linked working and public copies? '
          'Other copies made outside this app are not included. This cannot be undone.',
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
      final result = await LibraryService.deleteDocument(entry.path);
      for (final path in result.removedPaths) {
        PdfRaster.invalidate(path);
      }
      await _loadUserLists();
      await _refresh(prune: true);
      if (mounted) _snack(result.warning ?? '${entry.name} deleted');
    } catch (e) {
      if (mounted) _snack('Could not delete: $e');
    }
  }

  Future<void> _showDetails(LibraryEntry entry) async {
    // A details sheet has no way to ask for a password, so an encrypted
    // file simply reports an unknown page count here.
    final isPdf = entry.kind == DocKind.pdf;
    final pageCount = isPdf ? await PdfRaster.pageCountOrZero(entry.path) : 0;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        scrollable: true,
        title: Text(
          entry.title,
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('Type', entry.kind.label),
            if (isPdf)
              _detailRow('Pages', pageCount > 0 ? '$pageCount' : 'Unreadable'),
            _detailRow('Size', formatFileSize(entry.sizeBytes)),
            _detailRow(
              'Modified',
              formatLibraryDate(entry.modified, long: true),
            ),
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

  Future<void> _showActions(LibraryEntry entry) async {
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
                    Icon(entry.kind.icon, color: entry.kind.color, size: 22),
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
                            '${entry.displayFolder} · ${formatFileSize(entry.sizeBytes)}',
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
                SharePlus.instance.share(
                  ShareParams(
                    files: [
                      XFile(
                        entry.path,
                        mimeType: DocKind.mimeTypeOf(entry.path),
                      ),
                    ],
                  ),
                );
              }),
              if (entry.kind == DocKind.pdf) ..._pdfActions(ctx, entry),
              Divider(color: _colors.divider, height: 20),
              _action(
                ctx,
                Icons.drive_file_rename_outline_rounded,
                'Rename',
                () {
                  _rename(entry);
                },
              ),
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

  /// The actions that only apply to PDFs.
  List<Widget> _pdfActions(BuildContext ctx, LibraryEntry entry) {
    return [
      Divider(color: _colors.divider, height: 20),
      if (Features.ai)
        _action(ctx, Icons.auto_awesome_rounded, 'Ask AI', () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => AiScreen(pdfPath: entry.path)),
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
          MaterialPageRoute(builder: (_) => ProtectScreen(pdfPath: entry.path)),
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
    ];
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
      leading: Icon(
        icon,
        color: danger ? Colors.red.shade400 : _accent,
        size: 21,
      ),
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
      body: LayoutBuilder(
        builder: (context, body) => Column(
          children: [
            _buildFilterBar(),
            _buildScanIndicator(),
            if (_access == StorageAccess.appOnly && !_isScanning)
              // At most half the tab. With the largest text on a small
              // phone the banner is taller than that, and it scrolls
              // within its half instead of pushing the list off the screen.
              // The list below keeps the screen's primary scroll controller.
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: body.maxHeight / 2),
                child: SingleChildScrollView(
                  primary: false,
                  child: _buildAccessBanner(),
                ),
              ),
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
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddSheet,
        backgroundColor: _accent,
        tooltip: 'New or import',
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
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
                hintText: 'Search files',
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
        _isScanning
            ? Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _colors.textPrimary,
                    semanticsLabel: 'Looking for files',
                  ),
                ),
              )
            : IconButton(
                tooltip: 'Look for new files',
                icon: Icon(Icons.refresh_rounded, color: _colors.textPrimary),
                onPressed: _rescan,
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

  /// The row of filter chips. Each chip is a 48 dp tap target, the smallest
  /// Android's accessibility guidelines allow, and the row grows with the
  /// text size rather than clipping the chips. A chosen chip is marked by
  /// its tint and border, with its label in the primary text colour: an
  /// accent-coloured label on its own tint read at 3:1.
  Widget _buildFilterBar() {
    Widget chip({
      required String label,
      required bool selected,
      required Color color,
      required ValueChanged<bool> onSelected,
      Widget? avatar,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          avatar: avatar,
          label: Text(label),
          selected: selected,
          onSelected: onSelected,
          showCheckmark: false,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          backgroundColor: _colors.cardBackground,
          selectedColor: color.withValues(alpha: 0.16),
          labelStyle: TextStyle(
            color: selected ? _colors.textPrimary : _colors.textSecondary,
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
          side: BorderSide(color: selected ? color : _colors.divider),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final option in LibraryFilter.values)
            chip(
              label: option.label,
              selected: _filter == option,
              color: _accent,
              onSelected: (_) => setState(() => _filter = option),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              height: 28,
              child: VerticalDivider(color: _colors.divider, width: 1),
            ),
          ),
          for (final kind in DocKind.filterable)
            chip(
              avatar: Icon(kind.icon, size: 16, color: kind.color),
              label: kind.label,
              selected: _kind == kind,
              color: kind.color,
              onSelected: (_) =>
                  setState(() => _kind = _kind == kind ? null : kind),
            ),
        ],
      ),
    );
  }

  /// A routine re-sweep, as a thin bar in a slot that is always reserved so
  /// the list never jumps when one starts or ends. A new grant's first sweep
  /// is shown in a dialog instead — see [_showSearchProgress].
  Widget _buildScanIndicator() {
    return SizedBox(
      height: 2,
      child: _isScanning
          ? LinearProgressIndicator(
              minHeight: 2,
              color: _accent,
              backgroundColor: _accent.withValues(alpha: 0.12),
              semanticsLabel: 'Looking for PDFs',
            )
          : null,
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
                      ? 'Showing only DocHelper\'s own files'
                      : 'Showing documents inside DocHelper',
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isAndroid
                      ? 'Allow all files access to find documents in '
                            'internal storage and SD/USB drives. Android keeps '
                            'other apps\' private folders restricted.'
                      : 'iOS keeps each app to its own documents. Import a '
                            'file to add it to your library.',
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
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
                    child: Text(isAndroid ? 'Allow access' : 'Import a file'),
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
    final what = _kind?.pluralLabel ?? 'files';
    if (_query.trim().isNotEmpty) {
      message = 'No $what match "${_query.trim()}".';
    } else {
      message = switch (_filter) {
        LibraryFilter.recent => 'Documents you open show up here.',
        LibraryFilter.starred => 'Star a document to keep it close at hand.',
        LibraryFilter.created =>
          'Files you make with DocHelper are collected here.',
        LibraryFilter.all =>
          _hasScanned
              ? 'No $what found on this device yet.'
              : 'Looking for $what…',
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
        Icon(Icons.folder_open_rounded, size: 54, color: _colors.textTertiary),
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
            label: const Text('Import a file'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              side: const BorderSide(color: _accent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGrid(List<LibraryEntry> entries) {
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

  Widget _buildList(List<LibraryEntry> entries) {
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
              '${entry.displayFolder} · ${formatFileSize(entry.sizeBytes)} · '
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

  final LibraryEntry entry;
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
    // Only PDFs have rendered covers; other kinds show their icon.
    if (widget.entry.kind != DocKind.pdf) return;
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
    if (!mounted ||
        widget.entry.path != path ||
        widget.entry.modifiedMs != modified ||
        _requested != longEdge) {
      return;
    }

    final bytes = await PdfRaster.libraryCover(
      path,
      modifiedMs: modified,
      longEdge: longEdge,
    );
    if (!mounted ||
        widget.entry.path != path ||
        widget.entry.modifiedMs != modified ||
        _requested != longEdge) {
      return;
    }
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
    final kind = widget.entry.kind;
    if (kind != DocKind.pdf) {
      return ColoredBox(
        color: kind.color.withValues(alpha: widget.colors.isDark ? 0.22 : 0.12),
        child: Center(child: Icon(kind.icon, color: kind.color, size: 26)),
      );
    }
    return ColoredBox(
      color: widget.colors.isDark
          ? Colors.white10
          : Colors.black.withValues(alpha: 0.04),
      child: Center(
        child: Icon(
          failed ? Icons.picture_as_pdf_rounded : Icons.hourglass_empty_rounded,
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

  final LibraryEntry entry;
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

  final LibraryEntry entry;
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
