import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/doc_kind.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';
import 'library_service.dart';
import 'public_pdf_save_service.dart';

/// Where an edited document's changes go when the user taps Save.
///
/// An editor saves through its engine to the document's *working file*.
///
/// * A file in shared storage that the app can write (one found in Files, or
///   opened from a file manager) is saved where it is. Nothing else happens.
/// * A temporary copy (from "Open with" or a picker) or a file in the app's
///   private storage would not survive on its own: the cache can be emptied
///   and uninstalling removes app storage. Those are also published as a
///   public copy in `Download/DocHelper` or `Documents/DocHelper`, and later
///   saves of the same working file update that copy instead of adding
///   another.
class DocumentSaveService {
  DocumentSaveService._();

  /// Lets tests run the policy without a platform channel.
  @visibleForTesting
  static bool? publishOverride;

  /// Whether the app can write to [path] where it is.
  static Future<bool> canWrite(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      // Opening for append changes nothing but fails without write access.
      final handle = await file.open(mode: FileMode.append);
      await handle.close();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// The working file to save [path]'s edits to: [path] itself when it is
  /// writable, otherwise a copy in the app's own storage (which then gets a
  /// public copy on every save).
  static Future<String> workingPathFor(String path) async {
    if (await canWrite(path)) return path;
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/Edited',
    );
    await dir.create(recursive: true);
    final name = sanitizeFileName(documentDisplayName(path));
    var target = File('${dir.path}/$name');
    final title = DocKind.titleOf(name);
    final extension = DocKind.extensionOf(name);
    for (var n = 2; await target.exists(); n++) {
      target = File(
        '${dir.path}/$title ($n)${extension.isEmpty ? '' : '.$extension'}',
      );
    }
    return target.path;
  }

  /// Whether a save of [workingPath] also needs a public copy.
  static Future<bool> needsPublicCopy(String workingPath) async {
    final override = publishOverride;
    if (override != null) return override;
    if (!Platform.isAndroid) return false;
    return LibraryService.isAppStoragePath(workingPath);
  }

  /// Finish a save after the engine wrote [workingPath]. Returns what to tell
  /// the user, such as "Saved" or "Saved to Download/DocHelper/notes.txt".
  ///
  /// [location] is `Downloads` or `Documents`, the user's save setting.
  static Future<String> afterSave({
    required String workingPath,
    required String location,
  }) async {
    if (!await needsPublicCopy(workingPath)) return 'Saved';
    final existing = await PublicPdfSaveService.latestCopy(workingPath);
    if (existing != null) {
      final updated = await PublicPdfSaveService.updateCopy(
        sourcePath: workingPath,
        copy: existing,
      );
      return 'Saved to ${describePublicPath(updated.path)}';
    }
    await PublicPdfSaveService.save(
      sourcePath: workingPath,
      displayName: documentDisplayName(workingPath),
      location: location,
      mimeType: DocKind.mimeTypeOf(workingPath),
    );
    final copy = await PublicPdfSaveService.latestCopy(workingPath);
    return copy == null ? 'Saved' : 'Saved to ${describePublicPath(copy.path)}';
  }

  /// `/storage/emulated/0/Download/DocHelper/a.txt` -> `Download/DocHelper/a.txt`.
  static String describePublicPath(String path) {
    final marker = RegExp(r'/(Download|Documents)/');
    final match = marker.firstMatch(path);
    return match == null
        ? path.split('/').last
        : path.substring(match.start + 1);
  }
}
