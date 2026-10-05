import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_storage_service.dart';

/// A public copy is addressed by its provider URI under scoped storage. Its
/// path is only a library alias; lack of filesystem access does not mean gone.
class PublicPdfCopy {
  const PublicPdfCopy({required this.path, this.uri});
  final String path;
  final String? uri;
  Map<String, Object?> toJson() => {'path': path, 'uri': uri};
}

/// One document can have a working file and several explicitly saved exports.
/// Keep the ID when paths change and retain every export on repeated saves.
class PdfDocumentRecord {
  const PdfDocumentRecord({
    required this.id,
    required this.workingPath,
    required this.copies,
  });
  final String id;
  final String workingPath;
  final List<PublicPdfCopy> copies;
  Set<String> get paths => {workingPath, ...copies.map((copy) => copy.path)};
  Map<String, Object> toJson() => {
    'id': id,
    'copies': copies.map((copy) => copy.toJson()).toList(),
  };
}

/// Includes completed changes even on partial failure so every UI cache and
/// user list follows the files that actually moved or were removed.
class PdfDocumentMutation {
  const PdfDocumentMutation({
    this.removedPaths = const {},
    this.renamedPaths = const {},
    this.remainingPath,
    this.warning,
  });
  final Set<String> removedPaths;
  final Map<String, String> renamedPaths;

  /// A surviving alias after a partial delete, for stars and recent history.
  final String? remainingPath;
  final String? warning;
  bool get completed => warning == null;
}

class PublicPdfSaveService {
  static const _channel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  static const _recordsKey = 'publicPdfExports';
  static Future<void> _pendingMutation = Future<void>.value();

  @visibleForTesting
  static void resetForTesting() {
    // Widget tests replace their fake async zone between tests. A completed
    // Future owned by the previous zone cannot be the next test's queue head.
    _pendingMutation = Future<void>.value();
  }

  static Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _pendingMutation.then((_) => action());
    _pendingMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Future<void> save({
    required String sourcePath,
    required String displayName,
    required String location,
  }) => _mutate(() async {
    try {
      // Validate and persist the existing catalogue before publishing another
      // copy. A corrupt or unwritable catalogue must not create orphan exports.
      final records = await documents();
      await _store(records);
      final storage = await AndroidStorageService.read();
      if (storage.sdkInt < 29 &&
          !await Permission.storage.request().isGranted) {
        throw const PublicPdfSaveException(
          'Allow storage access to save the PDF in a public folder. '
          'Your working PDF has been kept in the app.',
        );
      }
      final saved = await _channel.invokeMapMethod<String, dynamic>(
        'savePublicPdf',
        {
          'sourcePath': sourcePath,
          'displayName': displayName,
          'location': location,
        },
      );
      final copy = _confirmedCopy(saved);
      final beforeRecords = List<PdfDocumentRecord>.of(records);
      try {
        final index = records.indexWhere(
          (record) => record.workingPath == sourcePath,
        );
        final before = index < 0 ? null : records.removeAt(index);
        records.add(
          PdfDocumentRecord(
            id: before?.id ?? sourcePath,
            workingPath: sourcePath,
            copies: [
              ...?before?.copies.where((existing) => existing.uri != copy.uri),
              copy,
            ],
          ),
        );
        await _store(records);
      } catch (error) {
        // Roll back only the exact row just created, never its pathname: a
        // provider may have resolved a collision with an existing document.
        try {
          await _deletePublic(copy);
        } catch (rollbackError) {
          throw PublicPdfSaveException(
            'The PDF was exported to ${copy.path}, but could not be linked '
            'to the library or removed again. Do not save another copy. '
            'Open that location in Files to manage the exported PDF. '
            'Your working PDF is safe in the app. '
            'Storage reference: ${copy.uri}. '
            'Library error: ${_message(error)}. '
            'Removal error: ${_message(rollbackError)}.',
          );
        }
        // SharedPreferences updates its memory cache before platform writes.
        // Restore the prior catalogue even if the persistent store stays full.
        try {
          await _store(beforeRecords);
        } catch (_) {
          // The catalogue failure is already included in the returned error.
        }
        throw PublicPdfSaveException(
          'Could not record the saved PDF: ${_message(error)} '
          'The new public copy was removed. Your working PDF is safe in the '
          'app. Free some device storage and try again.',
        );
      }
    } on PlatformException catch (error) {
      throw PublicPdfSaveException(
        'Could not save to $location/PDFHelper: '
        '${error.message ?? 'Storage is unavailable'}. '
        'Your working PDF has been kept in the app.',
      );
    }
  });

  static PublicPdfCopy _confirmedCopy(Map<String, dynamic>? saved) {
    final path = saved?['publicPath'];
    final uri = saved?['uri'];
    if (path is! String || path.isEmpty || uri is! String || uri.isEmpty) {
      throw const PublicPdfSaveException(
        'Android did not confirm the PDF location.',
      );
    }
    return PublicPdfCopy(path: path, uri: uri);
  }

  /// Reads both the old working-path -> public-path map and URI-aware records.
  static Future<List<PdfDocumentRecord>> documents() async {
    final prefs = await SharedPreferences.getInstance();
    final value = jsonDecode(prefs.getString(_recordsKey) ?? '{}');
    if (value is! Map) {
      throw const FormatException('Invalid PDF export records');
    }
    final records = <PdfDocumentRecord>[];
    for (final entry in value.entries) {
      if (entry.key is! String) continue;
      final working = entry.key as String;
      final data = entry.value;
      if (data is String) {
        records.add(
          PdfDocumentRecord(
            id: working,
            workingPath: working,
            copies: [PublicPdfCopy(path: data)],
          ),
        );
      } else if (data is Map && data['copies'] is List) {
        records.add(
          PdfDocumentRecord(
            id: data['id'] is String ? data['id'] as String : working,
            workingPath: working,
            copies: [
              for (final copy in data['copies'] as List)
                if (copy is Map && copy['path'] is String)
                  PublicPdfCopy(
                    path: copy['path'] as String,
                    uri: copy['uri'] as String?,
                  ),
            ],
          ),
        );
      }
    }
    return records;
  }

  static Future<void> _store(List<PdfDocumentRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      _recordsKey,
      jsonEncode({
        for (final record in records) record.workingPath: record.toJson(),
      }),
    )) {
      throw const PublicPdfSaveException(
        'Could not update the document library.',
      );
    }
  }

  /// Compatibility API for callers interested only in the latest export.
  static Future<Map<String, String>> exportedCopies() async => {
    for (final record in await documents())
      if (record.copies.isNotEmpty) record.workingPath: record.copies.last.path,
  };

  static Future<PdfDocumentMutation> deleteDocument(
    String path,
  ) => _mutate(() async {
    final records = await documents();
    final index = records.indexWhere((record) => record.paths.contains(path));
    if (index < 0) {
      await _deleteFile(path);
      return PdfDocumentMutation(removedPaths: {path});
    }
    var record = records[index];
    // Fail before deleting anything if the bookkeeping store is unwritable.
    await _store(records);
    final removed = <String>{};
    try {
      for (final copy in List<PublicPdfCopy>.of(record.copies)) {
        await _deletePublic(copy);
        removed.add(copy.path);
        record = PdfDocumentRecord(
          id: record.id,
          workingPath: record.workingPath,
          copies: record.copies.where((value) => value != copy).toList(),
        );
        records[index] = record;
        await _store(records);
      }
      // Keep a usable working PDF when a public export cannot be removed.
      await _deleteFile(record.workingPath);
      removed.add(record.workingPath);
      records.removeAt(index);
      await _store(records);
      return PdfDocumentMutation(removedPaths: removed);
    } catch (error) {
      final workingRemoved = removed.contains(record.workingPath);
      return PdfDocumentMutation(
        removedPaths: removed,
        remainingPath: workingRemoved ? null : record.workingPath,
        warning: workingRemoved
            ? 'The document files were deleted, but the library update could '
                  'not be saved: ${_message(error)} '
                  'Refresh the library and try again.'
            : '${removed.isEmpty ? 'Nothing was deleted.' : 'Some copies were deleted.'} '
                  'Could not finish deleting this document: ${_message(error)} '
                  'The remaining copies are still tracked. Check storage access and try again.',
      );
    }
  });

  static Future<PdfDocumentMutation> renameDocument(
    String path,
    String name,
  ) => _mutate(() async {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const PublicPdfSaveException('Invalid file name.');
    }
    final records = await documents();
    final index = records.indexWhere((record) => record.paths.contains(path));
    if (index < 0) {
      final target = await _renameFile(path, name);
      return PdfDocumentMutation(renamedPaths: {path: target});
    }
    var record = records[index];
    await _store(records);
    // Detect a local conflict before changing any public copy.
    await _checkRenameTarget(record.workingPath, name);
    final renamed = <String, String>{};
    try {
      for (var i = 0; i < record.copies.length; i++) {
        final old = record.copies[i];
        final copy = await _renamePublic(old, name);
        renamed[old.path] = copy.path;
        final copies = List<PublicPdfCopy>.of(record.copies)..[i] = copy;
        record = PdfDocumentRecord(
          id: record.id,
          workingPath: record.workingPath,
          copies: copies,
        );
        records[index] = record;
        await _store(records);
      }
      final old = record.workingPath;
      final target = await File(old).exists()
          ? await _renameFile(old, name)
          : old;
      if (old != target) renamed[old] = target;
      records[index] = PdfDocumentRecord(
        id: record.id,
        workingPath: target,
        copies: record.copies,
      );
      try {
        await _store(records);
      } catch (error) {
        if (old != target) {
          try {
            // The last confirmed catalogue still names the original working
            // path. Restore it without replacing a file created there since
            // the move. Public renames above are already confirmed and stay.
            if (await FileSystemEntity.type(old, followLinks: false) !=
                FileSystemEntityType.notFound) {
              throw const PublicPdfSaveException(
                'Another file now occupies the original working location.',
              );
            }
            await File(target).rename(old);
            renamed.remove(old);
          } catch (rollbackError) {
            final location = await File(target).exists()
                ? 'The working PDF is at $target.'
                : 'Check the working PDF location $target.';
            return PdfDocumentMutation(
              renamedPaths: renamed,
              warning:
                  'Could not record the renamed document: ${_message(error)} '
                  '$location Its library link could not be saved. '
                  'Could not restore it to $old: ${_message(rollbackError)}',
            );
          }
        }
        records[index] = record;
        // setString changes its cache before the platform write. Restore the
        // confirmed catalogue in memory even when persistent writes keep
        // failing, so a refresh and a restart agree about the restored file.
        try {
          await _store(records);
        } catch (_) {
          // The original persistence error is returned below.
        }
        rethrow;
      }
      return PdfDocumentMutation(renamedPaths: renamed);
    } catch (error) {
      return PdfDocumentMutation(
        renamedPaths: renamed,
        warning:
            '${renamed.isEmpty ? 'Nothing was renamed.' : 'Some copies were renamed.'} '
            'Could not finish renaming this document: ${_message(error)} '
            'The copies remain linked. Check storage access and try again.',
      );
    }
  });

  static String _message(Object error) => error is PlatformException
      ? error.message ?? 'Storage is unavailable'
      : error.toString();

  static Future<void> _deletePublic(PublicPdfCopy copy) async {
    if (Platform.isAndroid || copy.uri?.startsWith('content:') == true) {
      final deleted = await _channel.invokeMethod<bool>('deletePublicPdf', {
        'uri': copy.uri,
        'publicPath': copy.path,
      });
      if (deleted != true) {
        throw const PublicPdfSaveException(
          'Android did not confirm the public copy was deleted.',
        );
      }
    } else {
      await _deleteFile(copy.path);
    }
  }

  static Future<PublicPdfCopy> _renamePublic(
    PublicPdfCopy copy,
    String name,
  ) async {
    if (Platform.isAndroid || copy.uri?.startsWith('content:') == true) {
      return _confirmedCopy(
        await _channel.invokeMapMethod<String, dynamic>('renamePublicPdf', {
          'uri': copy.uri,
          'publicPath': copy.path,
          'displayName': name,
        }),
      );
    }
    final path = await _renameFile(copy.path, name);
    return PublicPdfCopy(path: path, uri: Uri.file(path).toString());
  }

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException catch (error) {
      // ENOENT is safe to retry. Permission errors must never count as deleted.
      if (error.osError?.errorCode != 2) rethrow;
    }
  }

  static Future<String> _checkRenameTarget(String path, String name) async {
    final target = '${File(path).parent.path}/$name';
    if (target != path &&
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const PublicPdfSaveException(
        'A file with that name already exists.',
      );
    }
    return target;
  }

  static Future<String> _renameFile(String path, String name) async {
    final target = await _checkRenameTarget(path, name);
    if (target != path) await File(path).rename(target);
    return target;
  }
}

class PublicPdfSaveException implements Exception {
  const PublicPdfSaveException(this.message);
  final String message;
  @override
  String toString() => message;
}
