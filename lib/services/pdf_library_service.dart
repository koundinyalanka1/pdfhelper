import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/error_logger.dart';
import 'android_storage_service.dart';

/// How much of the device the app can actually see.
///
/// Android reports the actual storage grant. A root directory can be listed
/// under scoped storage while PDFs inside it remain invisible.
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
    try {
      return (await AndroidStorageService.read()).hasFullAccess
          ? StorageAccess.full
          : StorageAccess.appOnly;
    } catch (e) {
      logError('PdfLibraryService.access', e);
      return StorageAccess.appOnly;
    }
  }

  /// Ask for the storage grant supported by this Android version.
  static Future<StorageAccess> requestAccess() async {
    if (!Platform.isAndroid) return StorageAccess.appOnly;
    try {
      return (await AndroidStorageService.requestAccess()).hasFullAccess
          ? StorageAccess.full
          : StorageAccess.appOnly;
    } catch (e) {
      logError('PdfLibraryService.requestAccess', e);
      return StorageAccess.appOnly;
    }
  }

  /// Open the All files access toggle, rather than the generic app-info page.
  static Future<void> openSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidStorageService.openSettings();
    } catch (e) {
      logError('PdfLibraryService.openSettings', e);
    }
  }

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
    final request = _ScanRequest(sharedRoots: sharedRoots, appRoots: appRoots);

    // Scan to completion on the worker. Returning a time/file/depth-limited
    // prefix and caching it as a complete library silently lost documents.
    // Let failures reach the screen, which retains its previous list.
    final found = await Isolate.run(() => _walk(request));

    found.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    _memory = found;
    _cacheWrite = _cacheWrite.then((_) => _writeCache(found));
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
  /// Uses the same complete walk as production against a real directory tree.
  @visibleForTesting
  static List<PdfFileEntry> walkForTesting(
    List<String> roots, {
    List<String> appRoots = const [],
  }) => _walk(_ScanRequest(sharedRoots: roots, appRoots: appRoots));

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
    final snapshot = List<PdfFileEntry>.of(_memory!);
    _cacheWrite = _cacheWrite.then((_) => _writeCache(snapshot));
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
        isAppOwned: appRoots.any((r) => _isWithin(path, r)),
      );
    } catch (e) {
      logError('PdfLibraryService.describe', e);
      return null;
    }
  }

  // ---------------------------------------------------------------- roots

  /// Primary storage for the current Android user plus mounted SD/USB volumes.
  static Future<List<String>> _sharedRoots() async {
    if (!Platform.isAndroid) return const [];
    final storage = await AndroidStorageService.read();
    return storage.hasFullAccess ? storage.roots : const [];
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
    if (Platform.isAndroid) {
      await add(getExternalStorageDirectory());
      try {
        for (final dir
            in await getExternalStorageDirectories() ?? <Directory>[]) {
          roots.add(dir.path);
        }
      } catch (e) {
        logError('PdfLibraryService._appRoots', e);
      }
    }
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
      final staging = File('${file.path}.tmp');
      await staging.writeAsString(
        jsonEncode({
          'scannedAt': DateTime.now().millisecondsSinceEpoch,
          'files': entries.map((e) => e.toJson()).toList(),
        }),
        flush: true,
      );
      await staging.rename(file.path);
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
  const _ScanRequest({required this.sharedRoots, required this.appRoots});

  final List<String> sharedRoots;
  final List<String> appRoots;
}

class _PendingDirectory {
  const _PendingDirectory(this.path, this.canonicalPath);

  final String path;
  final String canonicalPath;
}

bool _isWithin(String path, String root) =>
    path == root || path.startsWith(root.endsWith('/') ? root : '$root/');

String _canonicalRoot(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return Directory(path).absolute.path;
  }
}

String _folderLabel(String path) {
  final parts = path.split('/');
  if (parts.length < 2) return '';
  final folder = parts[parts.length - 2];
  return folder.isEmpty ? '/' : folder;
}

/// Breadth-first sweep. Runs on a background isolate.
///
/// The iterative queue handles deep trees without recursion. No arbitrary
/// file count, depth or time limit: every accessible branch is visited.
List<PdfFileEntry> _walk(_ScanRequest request) {
  final results = <PdfFileEntry>[];
  final seenFiles = <String>{};
  final seenDirs = <String>{};
  final queue = Queue<_PendingDirectory>();
  final appRoots = request.appRoots.map(_canonicalRoot).toSet();
  for (final root in [...request.appRoots, ...request.sharedRoots]) {
    final canonical = _canonicalRoot(root);
    if (seenDirs.add(canonical)) {
      // Preserve app paths used by recents/stars. Canonical paths are only
      // identity keys, so /sdcard and /storage/... cannot duplicate a tree.
      queue.add(_PendingDirectory(root, canonical));
    }
  }

  while (queue.isNotEmpty) {
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
      final path = child.path;
      final name = path.split('/').last;
      final canonical = '${current.canonicalPath}/$name';
      if (child is Directory) {
        // Do not follow links below a root: a link can lead back into the
        // tree. Android itself enforces private-folder restrictions; do not
        // exclude paths that may be readable on older OS versions.
        if (seenDirs.add(canonical)) {
          queue.add(_PendingDirectory(path, canonical));
        }
      } else if (child is File) {
        if (!name.toLowerCase().endsWith('.pdf')) continue;
        if (!seenFiles.add(canonical)) continue;
        try {
          final stat = child.statSync();
          if (stat.type != FileSystemEntityType.file) continue;
          results.add(
            PdfFileEntry(
              path: path,
              name: name,
              sizeBytes: stat.size,
              modifiedMs: stat.modified.millisecondsSinceEpoch,
              folder: _folderLabel(path),
              isAppOwned: appRoots.any((root) => _isWithin(canonical, root)),
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
