import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_router.dart';
import '../services/document_save_service.dart';
import '../services/public_pdf_save_service.dart';
import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';

/// Browses an archive (ZIP, TAR, `.tar.gz` or `.gz`) like a file manager,
/// through the archive engine (`flutter_archive_core`): open, share or save
/// one file, or extract everything.
///
/// The archive itself is never changed. Opening or sharing a file extracts it
/// into a fresh folder in the app's temporary storage. Saving writes a copy
/// in the app's documents and, where Android needs one, a public copy in
/// `Download/DocHelper` or `Documents/DocHelper`.
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  /// Files opened from an archive are kept this long in temporary storage,
  /// then removed the next time an archive opens. A document opened an hour
  /// ago may still be on screen; one opened yesterday is not.
  static const Duration keepExtracted = Duration(days: 1);

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

/// Why the archive cannot be shown, in plain words.
class _Problem {
  const _Problem(this.message, {this.detail, this.offerOtherApp = true});

  final String message;
  final String? detail;

  /// Whether another app might do better, so "Open with another app" helps.
  final bool offerOtherApp;
}

/// A file (or link) in the archive, where the browser shows it.
class _File {
  const _File(this.entry, this.path, this.name);

  final ArchiveEntry entry;

  /// The entry's safe path, `/`-separated, which the browser shows.
  final String path;
  final String name;
}

/// A folder of the archive: one it lists, or one only its files' paths
/// imply.
class _Folder {
  _Folder(this.path, this.name, this.parent);

  /// `/`-separated; empty for the archive's top level.
  final String path;
  final String name;
  final _Folder? parent;

  /// The archive's own entry for the folder, when it has one.
  ArchiveEntry? entry;

  final Map<String, _Folder> _children = {};
  List<_Folder> folders = const [];
  final List<_File> files = [];

  bool get isRoot => parent == null;

  int get itemCount => _children.length + files.length;

  /// Every folder below this one. A loop rather than recursion, since an
  /// archive can nest folders thousands deep.
  int get folderCount {
    var count = 0;
    final pending = [this];
    while (pending.isNotEmpty) {
      final folder = pending.removeLast();
      count += folder.folders.length;
      pending.addAll(folder.folders);
    }
    return count;
  }

  /// The keys of this folder's rows, subfolders then files. A file may
  /// share its path with a folder or another file; keys must still differ.
  late final List<String> rowKeys = () {
    final used = <String>{};
    String keyFor(String path, int index) =>
        used.add(path) ? 'archive-entry-$path' : 'archive-entry-$path#$index';
    return [
      for (final sub in folders) keyFor(sub.path, -1),
      for (final file in files) keyFor(file.path, file.entry.index),
    ];
  }();

  _Folder _child(String name) => _children.putIfAbsent(
    name,
    () => _Folder(path.isEmpty ? name : '$path/$name', name, this),
  );

  /// Subfolders, then files, each by name, in this folder and every one
  /// below it.
  void _sort() {
    final pending = [this];
    while (pending.isNotEmpty) {
      final folder = pending.removeLast();
      folder.folders = folder._children.values.toList()
        ..sort((a, b) => _byName(a.name, b.name));
      folder.files.sort((a, b) => _byName(a.name, b.name));
      pending.addAll(folder.folders);
    }
  }

  static int _byName(String a, String b) {
    final order = a.toLowerCase().compareTo(b.toLowerCase());
    return order != 0 ? order : a.compareTo(b);
  }

  /// The tree of folders [entries] describe, by their safe paths.
  static _Folder build(List<ArchiveEntry> entries) {
    final root = _Folder('', '', null);
    for (final entry in entries) {
      final shown = entry.safePath;
      if (shown == null) {
        // The archive's own top folder ("./") needs no row. A file whose
        // name has nothing usable in it is still listed, at the top.
        if (!entry.isDir) {
          final name = entry.name.replaceAll(RegExp(r'[\x00-\x1F]'), '_');
          root.files.add(_File(entry, name, name.isEmpty ? 'Unnamed' : name));
        }
        continue;
      }
      final parts = shown.split('/');
      var folder = root;
      final depth = entry.isDir ? parts.length : parts.length - 1;
      for (final part in parts.take(depth)) {
        folder = folder._child(part);
      }
      if (entry.isDir) {
        folder.entry ??= entry;
      } else {
        folder.files.add(_File(entry, shown, parts.last));
      }
    }
    root._sort();
    return root;
  }
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  AppColors _colors = AppColors(false);

  bool _loading = true;
  _Problem? _problem;
  ArchiveListing? _listing;
  _Folder? _folder;

  /// The header's counts and size, worked out once: the header is built
  /// again on every progress update.
  String _totals = '';

  /// What the screen is doing, shown above the list; null when idle.
  String? _busy;

  /// How far along [_busy] is, from 0 to 1; null when unknown.
  double? _progress;

  String get _name => widget.title ?? documentDisplayName(widget.path);

  @override
  void initState() {
    super.initState();
    unawaited(_removeOldExtractions());
    if (ArchiveCore.isAvailable) {
      _load();
    } else {
      _loading = false;
      _problem = const _Problem(
        'The archive engine is missing from this copy of DocHelper, so it '
        'cannot open archives.',
        detail: 'Another app may be able to open this one.',
      );
    }
  }

  Future<void> _load() async {
    try {
      final listing = await ArchiveCore.listAsync(widget.path);
      if (!mounted) return;
      final root = _Folder.build(listing.entries);
      final files = listing.entries.where((e) => !e.isDir).length;
      final folders = root.folderCount;
      final size = listing.entries.fold<int>(0, (sum, e) => sum + e.size);
      setState(() {
        _listing = listing;
        _folder = root;
        _totals = [
          _count(files, 'file'),
          if (folders > 0) _count(folders, 'folder'),
          formatFileSize(size),
        ].join(' · ');
        _loading = false;
      });
    } catch (e) {
      logError('Archive.list', e);
      if (!mounted) return;
      setState(() {
        _problem = _problemFor(e);
        _loading = false;
      });
    }
  }

  /// Remove what earlier archives extracted for opening, once it is older
  /// than [ArchiveScreen.keepExtracted].
  static Future<void> _removeOldExtractions() async {
    try {
      final base = Directory(
        '${(await getTemporaryDirectory()).path}/archives',
      );
      if (!await base.exists()) return;
      final cutoff = DateTime.now().subtract(ArchiveScreen.keepExtracted);
      await for (final item in base.list(followLinks: false)) {
        final stat = await item.stat();
        if (stat.modified.isBefore(cutoff)) {
          await item.delete(recursive: true);
        }
      }
    } catch (e) {
      logError('Archive.removeOld', e);
    }
  }

  // ------------------------------------------------------------- describing

  /// [text] as a sentence: a capital first letter and a full stop.
  static String _sentence(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    final capital = trimmed[0].toUpperCase() + trimmed.substring(1);
    return RegExp(r'[.!?]$').hasMatch(capital) ? capital : '$capital.';
  }

  static String _count(int n, String one) =>
      '${formatCount(n)} $one${n == 1 ? '' : 's'}';

  static String _date(DateTime date, {bool long = false}) =>
      formatLibraryDate(date.toLocal(), long: long);

  _Problem _problemFor(Object error) {
    if (error is! ArchiveCoreException) {
      return _Problem('This archive could not be opened.', detail: '$error');
    }
    final detail = _sentence(error.message);
    return switch (error.code) {
      // The engine names the format: "RAR archives are not supported".
      'UNSUPPORTED' => _Problem(
        detail,
        detail: 'Another app may be able to open it.',
      ),
      'CORRUPT' => _Problem(
        'This archive is damaged, so DocHelper cannot read it.',
        detail: detail,
      ),
      'TOO_LARGE' => _Problem(
        'This archive is too large to open on the phone.',
        detail: detail,
      ),
      'ENCRYPTED' => const _Problem(
        'This archive is protected with a password: DocHelper cannot open '
        'it yet.',
      ),
      'NOT_FOUND' || 'IO' => _Problem(
        'This archive could not be read. It may have been moved or deleted.',
        detail: detail,
        offerOtherApp: File(widget.path).existsSync(),
      ),
      _ => _Problem('This archive could not be opened.', detail: detail),
    };
  }

  /// Why [entry] cannot be opened, shared or saved; null when it can.
  static String? _whyNot(ArchiveEntry entry) {
    if (entry.encrypted) {
      return 'Protected with a password: DocHelper cannot open it yet.';
    }
    return switch (entry.kind) {
      ArchiveEntryKind.symlink || ArchiveEntryKind.hardLink =>
        'This is a link to another file. Links are listed, but never '
            'extracted.',
      ArchiveEntryKind.special =>
        'This is a device or other special file, which is never extracted.',
      _ =>
        entry.canExtract
            ? null
            : 'It is packed with ${entry.method}, which DocHelper cannot '
                  'unpack yet.',
    };
  }

  /// A failure to extract one file, in plain words.
  static String _entryError(String name, Object error) {
    if (error is! ArchiveCoreException) {
      return 'Could not extract $name: $error';
    }
    return switch (error.code) {
      'ENCRYPTED' => 'Protected with a password: DocHelper cannot open it yet.',
      'CORRUPT' =>
        '$name is damaged in the archive, so it cannot be extracted.',
      'TOO_LARGE' =>
        '$name is too large to extract. ${_sentence(error.message)}',
      'UNSUPPORTED' => _sentence(error.message),
      _ => 'Could not extract $name: ${error.message}',
    };
  }

  /// The second line of a file's row.
  static String _fileSummary(ArchiveEntry entry) {
    final size = formatFileSize(entry.size);
    if (entry.encrypted) return 'Protected with a password · $size';
    return switch (entry.kind) {
      ArchiveEntryKind.symlink ||
      ArchiveEntryKind.hardLink => 'Link · not extracted',
      ArchiveEntryKind.special => 'Special file · not extracted',
      _ when !entry.canExtract => '$size · packed with ${entry.method}',
      _ => [
        size,
        if (entry.modified != null) _date(entry.modified!),
      ].join(' · '),
    };
  }

  /// Hand the archive to another app. The problem shown already says why
  /// DocHelper cannot open it, so no sheet repeats that (wrongly, for a
  /// damaged ZIP: DocHelper opens ZIP files).
  Future<void> _openElsewhere() async {
    try {
      final result = await OpenFile.open(
        widget.path,
        type: DocKind.mimeTypeOf(widget.path),
      );
      if (result.type == ResultType.done) return;
      _snack(
        result.type == ResultType.noAppToOpen
            ? 'No app on this phone can open $_name.'
            : 'Could not open $_name: ${result.message}',
      );
    } catch (e) {
      logError('Archive.openElsewhere', e);
      _snack('Could not open $_name.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _setBusy(String? busy, [double? progress]) {
    if (!mounted) return;
    setState(() {
      _busy = busy;
      _progress = progress;
    });
  }

  // ------------------------------------------------------------- navigating

  void _enter(_Folder folder) => setState(() => _folder = folder);

  void _goUp() {
    final parent = _folder?.parent;
    if (parent != null) setState(() => _folder = parent);
  }

  // ------------------------------------------------------------ one file

  /// The name to write [file] under: the last part of its safe path, which
  /// the engine has already made fit for any file system.
  static String _fileName(_File file) => file.entry.safePath == null
      ? sanitizeFileName(file.name, fallback: 'File')
      : file.name;

  /// Extract [file] into a fresh folder in temporary storage, for opening or
  /// sharing. Null when it failed (the reason has been shown).
  Future<String?> _extractToTemp(_File file, String doing) async {
    if (_busy != null) return null;
    _setBusy('$doing ${file.name}…');
    try {
      final base = Directory(
        '${(await getTemporaryDirectory()).path}/archives',
      );
      await base.create(recursive: true);
      final folder = await base.createTemp();
      final out = '${folder.path}/${_fileName(file)}';
      await ArchiveCore.extractAsync(widget.path, file.entry.index, out);
      return out;
    } catch (e) {
      logError('Archive.extract', e);
      _snack(_entryError(file.name, e));
      return null;
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _open(_File file) async {
    final why = _whyNot(file.entry);
    if (why != null) {
      _snack(why);
      return;
    }
    final path = await _extractToTemp(file, 'Opening');
    if (path == null || !mounted) return;
    await DocumentRouter.open(context, path, title: file.name);
  }

  Future<void> _share(_File file) async {
    final why = _whyNot(file.entry);
    if (why != null) {
      _snack(why);
      return;
    }
    final path = await _extractToTemp(file, 'Preparing');
    if (path == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path, mimeType: DocKind.mimeTypeOf(path))]),
      );
    } catch (e) {
      logError('Archive.share', e);
      _snack('Could not share ${file.name}.');
    }
  }

  /// [name] in [folder], or `name (2).ext` and so on when it is taken.
  /// Folders keep any dots as part of their name.
  static Future<String> _freePath(
    String folder,
    String name, {
    bool isFolder = false,
  }) async {
    final dot = isFolder ? -1 : name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var candidate = '$folder/$name';
    for (
      var n = 2;
      await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      candidate = '$folder/$stem ($n)$extension';
    }
    return candidate;
  }

  /// `Download/DocHelper` or `Documents/DocHelper`, as a file manager shows
  /// the folder for the save setting [location].
  static String _publicFolder(String location) =>
      location == 'Documents' ? 'Documents/DocHelper' : 'Download/DocHelper';

  /// Keep a copy of [file]: in the app's documents, and in
  /// `Download/DocHelper` when that copy alone would not last.
  Future<void> _save(_File file) async {
    final why = _whyNot(file.entry);
    if (why != null) {
      _snack(why);
      return;
    }
    if (_busy != null) return;
    final location = context.read<ThemeProvider>().saveLocation;
    _setBusy('Saving ${file.name}…');
    final String target;
    try {
      final documents = (await getApplicationDocumentsDirectory()).path;
      target = await _freePath(documents, _fileName(file));
      await ArchiveCore.extractAsync(widget.path, file.entry.index, target);
    } catch (e) {
      logError('Archive.save', e);
      _setBusy(null);
      _snack(_entryError(file.name, e));
      return;
    }
    final saved = target.split('/').last;
    try {
      if (await DocumentSaveService.needsPublicCopy(target)) {
        await PublicPdfSaveService.save(
          sourcePath: target,
          displayName: saved,
          location: location,
          mimeType: DocKind.mimeTypeOf(target),
        );
        final copy = await PublicPdfSaveService.latestCopy(target);
        _snack(
          copy == null
              ? 'Saved $saved to ${_publicFolder(location)}.'
              : 'Saved to ${DocumentSaveService.describePublicPath(copy.path)}.',
        );
      } else {
        _snack("Saved $saved in DocHelper's documents.");
      }
    } catch (e) {
      logError('Archive.publish', e);
      _snack(
        "Saved $saved in DocHelper's documents, but not to "
        '${_publicFolder(location)}: $e',
      );
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _showMenu(_File file) {
    final why = _whyNot(file.entry);
    final kind = DocKind.ofPath(file.name);
    final modified = file.entry.modified;
    return showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (ctx) {
        // Read in the builder: AppColors.of listens, which is only allowed
        // while building.
        final colors = AppColors.of(ctx);
        Widget action(
          String key,
          IconData icon,
          String label,
          VoidCallback run,
        ) => ListTile(
          key: ValueKey('archive-menu-$key'),
          enabled: why == null,
          leading: Icon(icon, color: colors.textSecondary),
          title: Text(label, style: TextStyle(color: colors.textPrimary)),
          onTap: () {
            Navigator.pop(ctx);
            run();
          },
        );
        return Material(
          color: colors.cardBackground,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: Icon(kind.icon, color: kind.color, size: 30),
                  title: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    [
                      formatFileSize(file.entry.size),
                      if (modified != null) _date(modified, long: true),
                    ].join(' · '),
                    style: TextStyle(color: colors.textTertiary),
                  ),
                ),
                if (why != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      why,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                action('open', Icons.open_in_new_rounded, 'Open', () {
                  _open(file);
                }),
                action('share', Icons.share_rounded, 'Share', () {
                  _share(file);
                }),
                action('save', Icons.save_alt_rounded, 'Save', () {
                  _save(file);
                }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ everything

  /// The archive's name without its extension (`.tar.gz` counts as one),
  /// for the folder Extract all makes.
  String get _folderBaseName {
    var name = _name;
    final lower = name.toLowerCase();
    final compound = RegExp(r'\.tar\.[a-z0-9]+$').firstMatch(lower);
    if (compound != null) {
      name = name.substring(0, compound.start);
    } else {
      final dot = name.lastIndexOf('.');
      if (dot > 0) name = name.substring(0, dot);
    }
    return sanitizeFileName(name, fallback: 'Archive');
  }

  /// The public folder below DocHelper for a file extracted into
  /// [folder]/[relative]: the archive's folders are kept, cut to what
  /// Android accepts.
  static String _publicSubfolder(String folder, String relative) {
    String clip(String name) {
      var end = name.length;
      if (end > PublicPdfSaveService.maxSubfolderNameLength) {
        end = PublicPdfSaveService.maxSubfolderNameLength;
        // Never split a character outside the Basic Multilingual Plane.
        final last = name.codeUnitAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) end--;
      }
      final clipped = name.substring(0, end).replaceAll(RegExp(r'[. ]+$'), '');
      return clipped.isEmpty ? '_' : clipped;
    }

    final parts = relative.split('/');
    final names = [
      folder,
      ...parts.take(parts.length - 1),
    ].take(PublicPdfSaveService.maxSubfolderDepth).map(clip).join('/');
    return PublicPdfSaveService.isValidSubfolder(names) ? names : folder;
  }

  Future<void> _extractAll() async {
    if (_busy != null || _listing == null) return;
    final location = context.read<ThemeProvider>().saveLocation;
    _setBusy('Extracting $_name…');
    final String folderName;
    final String outDir;
    final ArchiveExtraction report;
    try {
      final documents = (await getApplicationDocumentsDirectory()).path;
      outDir = await _freePath(documents, _folderBaseName, isFolder: true);
      folderName = outDir.split('/').last;
      report = await ArchiveCore.extractAllAsync(widget.path, outDir);
    } catch (e) {
      logError('Archive.extractAll', e);
      _setBusy(null);
      // Only an archive that cannot be read, or a folder that cannot be
      // written (a full phone), stops everything.
      _snack(
        'Could not extract $_name. '
        '${e is ArchiveCoreException ? _sentence(e.message) : e}',
      );
      return;
    }

    var where = "the folder “$folderName” in DocHelper's documents";
    String? publishFailure;
    final written = report.written;
    final public = _publicFolder(location);
    try {
      if (written.isEmpty) {
        // Only folders, or nothing that could be extracted: no files to
        // show for the folders the engine made.
        await _removeIfNoFiles(outDir);
      } else if (await DocumentSaveService.needsPublicCopy(outDir)) {
        // Redrawing the screen for each of thousands of files would cost
        // more than copying them: the progress shows ten times a second.
        final clock = Stopwatch()..start();
        var shownAt = 0;
        void show(int published) => _setBusy(
          'Saving ${published + 1} of ${written.length} to $public…',
          published / written.length,
        );
        show(0);
        await PublicPdfSaveService.saveAll(
          files: [
            for (final file in written)
              _publicRequest(file, outDir: outDir, folderName: folderName),
          ],
          location: location,
          onProgress: (published) {
            final now = clock.elapsedMilliseconds;
            if (published >= written.length || now - shownAt < 100) return;
            shownAt = now;
            show(published);
          },
        );
        where = '$public/$folderName';
      }
    } on PublicPdfBatchException catch (e) {
      // Later files would fail the same way; the extracted ones stay.
      logError('Archive.publishAll', e);
      publishFailure =
          'Only ${e.published} of ${written.length} could be copied to '
          '$public: $e';
    } catch (e) {
      logError('Archive.publishAll', e);
      publishFailure = 'The files could not be copied to $public: $e';
    }
    _setBusy(null);
    if (!mounted) return;
    await _showSummary(
      written: written.length,
      where: where,
      skipped: report.skipped,
      publishFailure: publishFailure,
    );
  }

  /// The public copy of [file], extracted into [outDir], which is named
  /// [folderName]: it keeps its place among the archive's folders.
  static PublicFileRequest _publicRequest(
    String file, {
    required String outDir,
    required String folderName,
  }) {
    final relative = file.startsWith('$outDir/')
        ? file.substring(outDir.length + 1)
        : file.split('/').last;
    return PublicFileRequest(
      sourcePath: file,
      displayName: relative.split('/').last,
      mimeType: DocKind.mimeTypeOf(file),
      subfolder: _publicSubfolder(folderName, relative),
    );
  }

  /// Delete [folder], which Extract all made, when nothing but empty
  /// folders is in it.
  static Future<void> _removeIfNoFiles(String folder) async {
    try {
      final directory = Directory(folder);
      if (!await directory.exists()) return;
      await for (final item in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (item is! Directory) return;
      }
      await directory.delete(recursive: true);
    } catch (e) {
      logError('Archive.removeEmpty', e);
    }
  }

  Future<void> _showSummary({
    required int written,
    required String where,
    required List<ArchiveSkipped> skipped,
    String? publishFailure,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        // Read in the builder: AppColors.of listens, which is only allowed
        // while building.
        final colors = AppColors.of(ctx);
        return AlertDialog(
          key: const ValueKey('archive-summary'),
          scrollable: true,
          backgroundColor: colors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            written == 0 ? 'Nothing extracted' : 'Extracted',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: SizedBox(
            // A fixed width spares the dialog measuring the list below.
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  written > 0
                      ? '${_count(written, 'file')} extracted to $where.'
                      : skipped.isEmpty
                      ? 'This archive holds only empty folders, so there was '
                            'nothing to extract.'
                      : 'No files could be extracted.',
                  style: TextStyle(color: colors.textSecondary),
                ),
                if (publishFailure != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    publishFailure,
                    style: const TextStyle(color: Color(0xFFE53935)),
                  ),
                ],
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const ValueKey('archive-skipped'),
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '${_count(skipped.length, 'item')} not extracted',
                      style: TextStyle(color: colors.textPrimary),
                    ),
                    children: [
                      for (final s in skipped)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            s.path,
                            style: TextStyle(color: colors.textPrimary),
                          ),
                          subtitle: Text(
                            _sentence(s.reason),
                            style: TextStyle(color: colors.textTertiary),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(
                backgroundColor: DocKind.archive.color,
              ),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------- building

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final folder = _folder;
    final canExtract = _busy == null && (_listing?.entries.isNotEmpty ?? false);
    return PopScope(
      // The system back goes up a folder before it leaves the archive.
      canPop: folder == null || folder.isRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        backgroundColor: _colors.background,
        appBar: AppBar(
          backgroundColor: _colors.cardBackground,
          foregroundColor: _colors.textPrimary,
          title: Text(_name, overflow: TextOverflow.ellipsis),
          actions: [
            if (_listing != null)
              IconButton(
                key: const ValueKey('archive-extract-all'),
                tooltip: 'Extract all',
                icon: const Icon(Icons.unarchive_rounded),
                onPressed: canExtract ? _extractAll : null,
              ),
          ],
        ),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final problem = _problem;
    if (problem != null) return _buildProblem(problem);
    final folder = _folder!;
    final busy = _busy;
    // The header or the up row, and the path line, come before the rows;
    // a note follows when the folder is empty. Only the rows on screen are
    // built, so a folder of thousands of files stays quick.
    const top = 2;
    final subfolders = folder.folders.length;
    final rows = subfolders + folder.files.length;
    return Column(
      children: [
        if (busy != null) _buildBusy(busy),
        Expanded(
          child: ListView.builder(
            // A fresh scroll position for each folder.
            key: ValueKey('archive-list-${folder.path}'),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: top + (rows == 0 ? 1 : rows),
            itemBuilder: (context, i) {
              if (i == 0) {
                return folder.isRoot
                    ? _buildHeader(_listing!)
                    : _buildUpRow(folder.parent!);
              }
              if (i == 1) return _buildPathLine(folder);
              final row = i - top;
              if (rows == 0) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    folder.isRoot
                        ? 'This archive is empty.'
                        : 'This folder is empty.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _colors.textTertiary),
                  ),
                );
              }
              final key = ValueKey(folder.rowKeys[row]);
              return row < subfolders
                  ? _buildFolderRow(folder.folders[row], key)
                  : _buildFileRow(folder.files[row - subfolders], key);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBusy(String busy) {
    return Material(
      key: const ValueKey('archive-busy'),
      color: _colors.cardBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: _progress,
            color: DocKind.archive.color,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    busy,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProblem(_Problem problem) {
    final detail = problem.detail;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(DocKind.archive.icon, size: 64, color: DocKind.archive.color),
            const SizedBox(height: 16),
            Text(
              problem.message,
              key: const ValueKey('archive-error'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.textSecondary),
              ),
            ],
            if (problem.offerOtherApp) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const ValueKey('archive-open-other'),
                style: FilledButton.styleFrom(
                  backgroundColor: DocKind.archive.color,
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open with another app'),
                onPressed: _openElsewhere,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ArchiveListing listing) {
    final comment = listing.comment.trim();
    return Container(
      key: const ValueKey('archive-header'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(DocKind.archive.icon, color: DocKind.archive.color, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${listing.format.label} archive',
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(_totals, style: TextStyle(color: _colors.textSecondary)),
                if (comment.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    comment,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _colors.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathLine(_Folder folder) {
    return Padding(
      key: const ValueKey('archive-path'),
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: 18,
            color: _colors.textTertiary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                _name,
                if (!folder.isRoot) ...folder.path.split('/'),
              ].join(' › '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _colors.textTertiary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required Key key,
    required Widget leading,
    required String title,
    required String subtitle,
    Widget? trailing,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: key,
        tileColor: _colors.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: leading,
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _colors.textTertiary, fontSize: 12),
        ),
        trailing: trailing,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }

  Widget _buildUpRow(_Folder parent) {
    return _row(
      key: const ValueKey('archive-up'),
      leading: Icon(Icons.arrow_upward_rounded, color: _colors.textSecondary),
      title: 'Up',
      subtitle: 'Back to ${parent.isRoot ? _name : parent.name}',
      onTap: _goUp,
    );
  }

  Widget _buildFolderRow(_Folder sub, Key key) {
    return _row(
      key: key,
      leading: Icon(
        Icons.folder_rounded,
        color: DocKind.archive.color,
        size: 30,
      ),
      title: sub.name,
      subtitle: [
        _count(sub.itemCount, 'item'),
        if (sub.entry?.modified != null) _date(sub.entry!.modified!),
      ].join(' · '),
      trailing: Icon(Icons.chevron_right_rounded, color: _colors.textTertiary),
      onTap: () => _enter(sub),
    );
  }

  Widget _buildFileRow(_File file, Key key) {
    final kind = DocKind.ofPath(file.name);
    final entry = file.entry;
    return _row(
      key: key,
      leading: SizedBox(
        width: 34,
        height: 34,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(kind.icon, color: kind.color, size: 30),
            if (entry.encrypted)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    color: _colors.cardBackground,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    size: 14,
                    color: Color(0xFFE53935),
                  ),
                ),
              )
            else if (_whyNot(entry) != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: Icon(
                  Icons.block_rounded,
                  size: 14,
                  color: _colors.textTertiary,
                ),
              ),
          ],
        ),
      ),
      title: file.name,
      subtitle: _fileSummary(entry),
      trailing: IconButton(
        tooltip: 'More',
        icon: Icon(Icons.more_vert_rounded, color: _colors.textTertiary),
        onPressed: () => _showMenu(file),
      ),
      onTap: () => _open(file),
      onLongPress: () => _showMenu(file),
    );
  }
}
