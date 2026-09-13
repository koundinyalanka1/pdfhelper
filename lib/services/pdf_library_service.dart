import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/error_logger.dart';

/// How much of the device the app can actually see.
///
/// This is deliberately probed rather than inferred from a permission status:
/// the permission model changed three times across Android 10/11/13 and
/// `permission_handler` reports the same `granted` for grants that do and do
/// not let us list shared storage. Trying to list the root is the only answer
/// that is always true.
enum StorageAccess {
  /// Shared storage is readable — Android "All files access", or a
  /// pre-scoped-storage device that granted `READ_EXTERNAL_STORAGE`.
  full,

  /// Only this app's own directories. Always the case on iOS; the default on
  /// Android 11+ until the user grants All files access.
  appOnly,
}

/// One PDF found on the device.
class PdfFileEntry {
  const PdfFileEntry({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.folder,
    required this.isAppOwned,
  });

  final String path;
  final String name;
  final int sizeBytes;

  /// Epoch millis. Stored as an int rather than a [DateTime] so the whole
  /// entry survives a round trip through the scan cache unchanged.
  final int modifiedMs;

  /// Name of the containing directory, shown as the subtitle ("Download",
  /// "WhatsApp Documents", …).
  final String folder;

  /// Produced by this app — the Files tab can filter down to just these.
  final bool isAppOwned;

  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  /// File name without the `.pdf` extension.
  String get title {
    final dot = name.toLowerCase().lastIndexOf('.pdf');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Map<String, Object> toJson() => {
    'p': path,
    'n': name,
    's': sizeBytes,
    'm': modifiedMs,
    'f': folder,
    'a': isAppOwned,
  };

  static PdfFileEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['p'];
    final name = json['n'];
    if (path is! String || name is! String) return null;
    return PdfFileEntry(
      path: path,
      name: name,
      sizeBytes: json['s'] is int ? json['s'] as int : 0,
      modifiedMs: json['m'] is int ? json['m'] as int : 0,
      folder: json['f'] is String ? json['f'] as String : '',
      isAppOwned: json['a'] == true,
    );
  }
}

/// Finds every PDF the app is allowed to read, the way a document reader does.
///
/// The walk runs on a background isolate — a full sweep of shared storage
/// touches thousands of directories and would drop frames for seconds on the
/// UI isolate. Results are cached to disk so reopening the Files tab is
/// instant while a fresh scan runs behind it.
class PdfLibraryService {
  PdfLibraryService._();

  /// Stop after this many files. A phone with more PDFs than this has a
  /// pathological directory (a synced corpus, a dev checkout); the list would
  /// be unusable anyway and the memory is not worth it.
  static const int maxFiles = 5000;

  /// Hard ceiling on one sweep, so a slow SD card or a deep tree can never
  /// leave the Files tab spinning forever.
  static const Duration scanBudget = Duration(seconds: 30);

  /// Directories are never descended past this depth.
  static const int maxDepth = 12;

  static const String _cacheFileName = 'pdf_library_cache.json';

  static List<PdfFileEntry>? _memory;
  static Future<List<PdfFileEntry>>? _inFlight;

  /// The cache write started by the last completed sweep. Writing is
  /// deliberately not awaited by [scan] — the list should reach the screen
  /// before a hundred kilobytes of JSON is encoded — so this is how a test
  /// waits for it to land.
  static Future<void> _cacheWrite = Future<void>.value();

  /// Last completed scan, if the Files tab has already run one this session.
  static List<PdfFileEntry>? get lastResult => _memory;

  // --------------------------------------------------------------- access

  /// What the app can currently see. Never throws.
  static Future<StorageAccess> access() async {
    if (!Platform.isAndroid) return StorageAccess.appOnly;
    for (final root in const ['/storage/emulated/0', '/sdcard']) {
      if (await _canList(root)) return StorageAccess.full;
    }
    return StorageAccess.appOnly;
  }

  /// Ask for device-wide read access.
  ///
  /// Android 11+ gates shared storage behind All files access
  /// (`MANAGE_EXTERNAL_STORAGE`), which is the grant a document reader needs
  /// and the one Play's policy contemplates for this app category. Older
  /// releases only need `READ_EXTERNAL_STORAGE`, so both are attempted and
  /// the probe — not the returned status — decides whether it worked.
  static Future<StorageAccess> requestAccess() async {
    if (!Platform.isAndroid) return StorageAccess.appOnly;
    try {
      if (!await Permission.manageExternalStorage.isGranted) {
        await Permission.manageExternalStorage.request();
      }
    } catch (e) {
      logError('PdfLibraryService.requestAccess', e);
    }
    if (await access() == StorageAccess.full) return StorageAccess.full;
    try {
      await Permission.storage.request();
    } catch (e) {
      logError('PdfLibraryService.requestAccess', e);
    }
    return access();
  }

  /// Send the user to the OS screen where All files access is toggled.
  static Future<void> openSettings() => openAppSettings();

  // ----------------------------------------------------------------- scan

  /// Everything the app can see, newest first.
  ///
  /// Concurrent calls share one sweep rather than starting a second walk.
  static Future<List<PdfFileEntry>> scan() {
    return _inFlight ??= _scan().whenComplete(() => _inFlight = null);
  }

  static Future<List<PdfFileEntry>> _scan() async {
    final appRoots = await _appRoots();
    final sharedRoots = await _sharedRoots();
    final request = _ScanRequest(
      sharedRoots: sharedRoots,
      appRoots: appRoots,
      maxFiles: maxFiles,
      maxDepth: maxDepth,
      budgetMs: scanBudget.inMilliseconds,
    );

    List<PdfFileEntry> found;
    try {
      found = await Isolate.run(() => _walk(request));
    } catch (e) {
      logError('PdfLibraryService.scan', e);
      // A failed isolate must not leave the tab empty — fall back to the
      // app's own directories on this isolate, which is a small, fast walk.
      found = _walk(
        _ScanRequest(
          sharedRoots: const [],
          appRoots: appRoots,
          maxFiles: maxFiles,
          maxDepth: maxDepth,
          budgetMs: 5000,
        ),
      );
    }

    found.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    _memory = found;
    _cacheWrite = _writeCache(found);
    unawaited(_cacheWrite);
    return found;
  }

  /// The previous scan, read from disk. Returns an empty list when there
  /// isn't one — this is a warm start, never an error path.
  static Future<List<PdfFileEntry>> cached() async {
    if (_memory != null) return _memory!;
    try {
      final file = File(await _cachePath());
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['files'] is! List) return const [];
      final entries = <PdfFileEntry>[];
      for (final raw in decoded['files'] as List) {
        final entry = PdfFileEntry.fromJson(raw);
        if (entry != null) entries.add(entry);
      }
      // Entries may name files that have since been deleted or moved. They
      // are filtered on display rather than here, so a warm start stays
      // synchronous-fast; see [prune].
      _memory = entries;
      return entries;
    } catch (e) {
      logError('PdfLibraryService.cached', e);
      return const [];
    }
  }

  /// Drop the in-memory sweep so the next call starts cold.
  @visibleForTesting
  static void resetForTesting() {
    _memory = null;
    _inFlight = null;
    _cacheWrite = Future<void>.value();
  }

  /// Resolves once the cache write from the last sweep has finished.
  @visibleForTesting
  static Future<void> settleForTesting() => _cacheWrite;

  /// Run the sweep against explicit roots, on this isolate.
  ///
  /// The production path resolves roots from the platform and hands the walk
  /// to a background isolate, neither of which a unit test can do. This is
  /// the same walk with both of those removed, so the rules it encodes —
  /// which directories are skipped, the depth cap, the file cap — are
  /// directly testable.
  @visibleForTesting
  static List<PdfFileEntry> walkForTesting(
    List<String> roots, {
    List<String> appRoots = const [],
    int maxFiles = maxFiles,
    int maxDepth = maxDepth,
    int budgetMs = 10000,
  }) {
    return _walk(
      _ScanRequest(
        sharedRoots: roots,
        appRoots: appRoots,
        maxFiles: maxFiles,
        maxDepth: maxDepth,
        budgetMs: budgetMs,
      ),
    );
  }

  /// Drop cache entries whose file no longer exists.
  static Future<List<PdfFileEntry>> prune(List<PdfFileEntry> entries) async {
    final alive = <PdfFileEntry>[];
    for (final entry in entries) {
      if (await File(entry.path).exists()) alive.add(entry);
    }
    return alive;
  }

  /// Forget one file (after deleting it) without re-scanning.
  static void forget(String path) {
    final memory = _memory;
    if (memory == null) return;
    _memory = memory.where((e) => e.path != path).toList();
    _cacheWrite = _writeCache(_memory!);
    unawaited(_cacheWrite);
  }

  /// Add or replace a single entry (after a rename or a new export).
  static Future<PdfFileEntry?> describe(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final appRoots = await _appRoots();
      return PdfFileEntry(
        path: path,
        name: path.split(Platform.pathSeparator).last,
        sizeBytes: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
        folder: _folderLabel(path),
        isAppOwned: appRoots.any((r) => path.startsWith(r)),
      );
    } catch (e) {
      logError('PdfLibraryService.describe', e);
      return null;
    }
  }

  // ---------------------------------------------------------------- roots

  static Future<bool> _canList(String path) async {
    try {
      await Directory(path).list(followLinks: false).take(1).toList();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Readable volume roots: primary shared storage plus any SD card.
  static Future<List<String>> _sharedRoots() async {
    if (!Platform.isAndroid) return const [];
    final roots = <String>[];
    // /sdcard is a symlink to /storage/emulated/0 — take whichever lists and
    // stop, so the same tree is never walked twice.
    for (final root in const ['/storage/emulated/0', '/sdcard']) {
      if (await _canList(root)) {
        roots.add(root);
        break;
      }
    }
    // Removable volumes: derive the mount point from the app-specific
    // directory Android hands out on each one.
    try {
      final dirs = await getExternalStorageDirectories();
      for (final dir in dirs ?? const <Directory>[]) {
        final marker = dir.path.indexOf('/Android/data');
        if (marker <= 0) continue;
        final volume = dir.path.substring(0, marker);
        if (roots.contains(volume)) continue;
        if (await _canList(volume)) roots.add(volume);
      }
    } catch (e) {
      logError('PdfLibraryService._sharedRoots', e);
    }
    return roots;
  }

  /// Directories this app owns — always readable, on every platform.
  static Future<List<String>> _appRoots() async {
    final roots = <String>{};
    Future<void> add(Future<Directory?> future) async {
      try {
        final dir = await future;
        if (dir != null) roots.add(dir.path);
      } catch (_) {
        // A platform that does not implement this directory is not an error.
      }
    }

    await add(getApplicationDocumentsDirectory());
    await add(getApplicationSupportDirectory());
    if (Platform.isAndroid) await add(getExternalStorageDirectory());
    return roots.toList();
  }

  // ---------------------------------------------------------------- cache

  static Future<String> _cachePath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/$_cacheFileName';
  }

  static Future<void> _writeCache(List<PdfFileEntry> entries) async {
    try {
      final file = File(await _cachePath());
      await file.writeAsString(
        jsonEncode({
          'scannedAt': DateTime.now().millisecondsSinceEpoch,
          'files': entries.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      logError('PdfLibraryService._writeCache', e);
    }
  }
}

// ---------------------------------------------------------------------------
// Isolate worker
// ---------------------------------------------------------------------------

/// Plain, sendable description of one sweep.
class _ScanRequest {
  const _ScanRequest({
    required this.sharedRoots,
    required this.appRoots,
    required this.maxFiles,
    required this.maxDepth,
    required this.budgetMs,
  });

  final List<String> sharedRoots;
  final List<String> appRoots;
  final int maxFiles;
  final int maxDepth;
  final int budgetMs;
}

class _Pending {
  const _Pending(this.path, this.depth);
  final String path;
  final int depth;
}

/// Directory names that never hold user documents, or that cost far more to
/// walk than they return.
const Set<String> _skipDirNames = {
  'cache',
  'caches',
  'node_modules',
  'lost+found',
  'obb',
  'thumbnails',
};

/// Absolute path fragments to skip. `Android/data` and `Android/obb` are
/// unreadable on Android 11+ anyway; `Android/media` is deliberately kept,
/// because that is where messaging apps now store received documents.
const List<String> _skipPathFragments = ['/Android/data', '/Android/obb'];

bool _isExcludedDir(String path, String name) {
  if (name.startsWith('.')) return true;
  if (_skipDirNames.contains(name.toLowerCase())) return true;
  for (final fragment in _skipPathFragments) {
    if (path.endsWith(fragment)) return true;
  }
  return false;
}

String _folderLabel(String path) {
  final parts = path.split('/');
  if (parts.length < 2) return '';
  final folder = parts[parts.length - 2];
  return folder.isEmpty ? '/' : folder;
}

/// Breadth-first sweep. Runs on a background isolate.
///
/// Breadth-first rather than recursive so the depth cap, the file cap and the
/// time budget can all be enforced between directories instead of unwinding a
/// deep stack, and so shallow directories (where user documents actually
/// live) are reached before deep ones when the budget runs out.
List<PdfFileEntry> _walk(_ScanRequest request) {
  final stopwatch = Stopwatch()..start();
  final results = <PdfFileEntry>[];
  final seenFiles = <String>{};
  final seenDirs = <String>{};
  final queue = Queue<_Pending>();

  for (final root in [...request.appRoots, ...request.sharedRoots]) {
    if (seenDirs.add(root)) queue.add(_Pending(root, 0));
  }

  while (queue.isNotEmpty) {
    if (results.length >= request.maxFiles) break;
    if (stopwatch.elapsedMilliseconds >= request.budgetMs) break;

    final current = queue.removeFirst();
    List<FileSystemEntity> children;
    try {
      children = Directory(current.path).listSync(followLinks: false);
    } catch (_) {
      // Unreadable directory (permissions, a vanished mount). Skipping one
      // branch must never abort the sweep.
      continue;
    }

    for (final child in children) {
      // Checked per file, not just per directory: a single folder holding
      // more than the cap would otherwise sail straight past it.
      if (results.length >= request.maxFiles) break;
      final path = child.path;
      final name = path.split('/').last;
      if (child is Directory) {
        if (current.depth + 1 > request.maxDepth) continue;
        if (_isExcludedDir(path, name)) continue;
        if (seenDirs.add(path)) queue.add(_Pending(path, current.depth + 1));
      } else if (child is File) {
        if (!name.toLowerCase().endsWith('.pdf')) continue;
        if (name.startsWith('.')) continue;
        if (!seenFiles.add(path)) continue;
        try {
          final stat = child.statSync();
          if (stat.size <= 0) continue;
          results.add(
            PdfFileEntry(
              path: path,
              name: name,
              sizeBytes: stat.size,
              modifiedMs: stat.modified.millisecondsSinceEpoch,
              folder: _folderLabel(path),
              isAppOwned: request.appRoots.any(path.startsWith),
            ),
          );
        } catch (_) {
          // Raced with a delete, or an unreadable entry. Skip it.
        }
      }
    }
  }

  return results;
}
