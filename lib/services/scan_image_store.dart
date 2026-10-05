import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Owns only the image files created for one scan/editor session.
///
/// Imported originals are borrowed, and must never be deleted by this store.
/// Ownership of a completed edit can transfer to the parent scan with [release]
/// and [adopt]. Temporary files are removed when the session is discarded.
class ScanImageStore {
  static int _nextId = 0;
  final Set<String> _paths = {};
  bool _disposed = false;
  int _readers = 0;

  Future<String> importFile(String source) =>
      _create((path) async => File(source).copy(path));

  Future<String> write(Uint8List bytes) =>
      _create((path) => File(path).writeAsBytes(bytes));

  Future<String> _create(Future<File> Function(String) write) async {
    if (_disposed) throw StateError('Scan session is closed');
    final temporary = await getTemporaryDirectory();
    final directory = Directory('${temporary.path}/scan_images');
    await directory.create(recursive: true);
    final path =
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}_${_nextId++}.jpg';
    try {
      await write(path);
      if (_disposed) throw StateError('Scan session is closed');
      _paths.add(path);
      return path;
    } catch (_) {
      await _deleteFile(path);
      rethrow;
    }
  }

  void adopt(String path) {
    _paths.add(path);
    if (_disposed && _readers == 0) unawaited(clear());
  }

  void release(String path) => _paths.remove(path);

  Future<void> delete(String path) async {
    if (_paths.remove(path)) await _deleteFile(path);
  }

  Future<void> clear() async {
    final paths = _paths.toList();
    _paths.clear();
    await Future.wait(paths.map(_deleteFile));
  }

  /// A conversion already reading images must finish before disposal removes
  /// them. Failed output operations otherwise leave the session's draft intact.
  Future<T> retainWhile<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('Scan session is closed');
    _readers++;
    try {
      return await operation();
    } finally {
      _readers--;
      if (_disposed && _readers == 0) await clear();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    if (_readers == 0) await clear();
  }

  static Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not remove a scan temporary file: $error');
    }
  }
}
