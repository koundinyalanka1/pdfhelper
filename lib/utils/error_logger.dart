import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:flutter_word_core/flutter_word_core.dart';

import '../models/doc_kind.dart';

/// Tiny app-wide error logger. Wraps [debugPrint] with a consistent format so
/// log lines can be filtered by tag (`[Tag] message`).
///
/// Replace ad-hoc `debugPrint('Error in foo: $e')` with `logError('foo', e)`.
///
/// Outside debug builds nothing is printed, and the error goes to crash
/// reporting as a non-fatal [HandledError]: its tag and kind, never its
/// message, which can contain document names and paths.
void logError(String tag, Object error, [StackTrace? stack]) {
  _log(tag, error, stack, null);
}

/// [logError] for a failure with the document at [path]: the report also
/// says what kind of file it was and roughly how big (see
/// [describeDocument]), never its name or path.
///
/// Engines fail differently on a 20 KB letter and a 200 MB workbook, and on
/// `.doc` and `.docx`; this is what tells those apart in crash reporting.
/// [sizeBytes] saves looking the size up when the caller already knows it.
void logDocumentError(
  String tag,
  Object error, {
  required String path,
  StackTrace? stack,
  int? sizeBytes,
}) {
  _log(tag, error, stack, describeDocument(path, sizeBytes: sizeBytes));
}

void _log(String tag, Object error, StackTrace? stack, String? document) {
  if (kDebugMode) {
    debugPrint(
      document == null ? '[$tag] $error' : '[$tag] $error ($document)',
    );
    if (stack != null) {
      debugPrint(stack.toString());
    }
    return;
  }
  reportHandledError(tag, error, stack: stack, document: document);
}

/// Receives handled errors once crash reporting is set up (installed by
/// `FirebaseService` in release builds); null until then, so nothing is
/// reported before that.
void Function(Object error, StackTrace stack)? handledErrorReporter;

/// Send a handled error to [handledErrorReporter] as a [HandledError].
/// [document] is what [describeDocument] said about the file involved.
@visibleForTesting
void reportHandledError(
  String tag,
  Object error, {
  StackTrace? stack,
  String? document,
}) {
  handledErrorReporter?.call(
    HandledError(tag, error, document: document),
    stack ?? StackTrace.current,
  );
}

/// A handled failure as crash reporting sees it: where it happened, what
/// kind of error it was and, for a document, its kind and size bucket.
class HandledError implements Exception {
  HandledError(this.tag, Object error, {this.document})
    : kind = describeErrorKind(error);

  final String tag;
  final String kind;

  /// The document's kind and size bucket, such as `word/docx, 1-10 MB`, or
  /// null when the failure did not involve one.
  final String? document;

  @override
  String toString() =>
      document == null ? '$tag: $kind' : '$tag: $kind [$document]';
}

/// The kind of [error] without its message: the type, plus the stable code
/// of errors that carry one, such as `WordCoreException(PANIC)`.
String describeErrorKind(Object error) => switch (error) {
  PdfException(:final code) => 'PdfException(${_engineCode(code)})',
  TextCoreException(:final code) => 'TextCoreException(${_engineCode(code)})',
  SheetCoreException(:final code) => 'SheetCoreException(${_engineCode(code)})',
  WordCoreException(:final code) => 'WordCoreException(${_engineCode(code)})',
  SlideCoreException(:final code) => 'SlideCoreException(${_engineCode(code)})',
  ArchiveCoreException(:final code) =>
    'ArchiveCoreException(${_engineCode(code)})',
  PlatformException(:final code) => 'PlatformException(${_platformCode(code)})',
  FileSystemException(:final osError) =>
    'FileSystemException(${osError?.errorCode ?? 'no OS error'})',
  _ => error.runtimeType.toString(),
};

/// [code] when it is one of the engines' codes, which are capitals, digits
/// and underscores (`PANIC`, `TOO_LARGE`), otherwise `?`.
///
/// The engines split `"CODE: message"` at its first `": "`, so a message
/// that arrived without a code would put its own start, perhaps a path or
/// a file name such as `Salaries.xlsx`, in the code's place.
String _engineCode(String code) =>
    RegExp(r'^[A-Z][A-Z0-9_]{0,47}$').hasMatch(code) ? code : '?';

/// [code] when it looks like a platform channel's code
/// (`PUBLIC_SAVE_FAILED`, `camera_access_denied`, `channel-error`),
/// otherwise `?`. Only letters, digits, `_` and `-` pass, so a file name
/// with its extension, such as `Will.docx`, does not.
String _platformCode(String code) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,47}$').hasMatch(code) ? code : '?';

/// What crash reporting may know about the document at [path]: its kind and
/// extension when DocHelper knows the extension (`word/docx`), and a size
/// bucket (`1-10 MB`). Never the name, the folder or the exact size.
///
/// [sizeBytes] is used when given; otherwise the file is looked up, and a
/// file that cannot be read has the size `unknown size`.
String describeDocument(String path, {int? sizeBytes}) {
  final kind = DocKind.ofPath(path);
  // ofPath knows the extension only when it is one of DocHelper's own, so
  // nothing the person typed can get through.
  final label = kind == DocKind.other
      ? kind.name
      : '${kind.name}/${DocKind.extensionOf(path)}';
  return '$label, ${sizeBucket(sizeBytes ?? _sizeOf(path))}';
}

int? _sizeOf(String path) {
  try {
    return File(path).statSync().size;
  } catch (_) {
    return null;
  }
}

/// [bytes] rounded to a bucket ten times the size of the one below, such as
/// `100 KB-1 MB`, so reports from files of a similar size group together.
/// Kilobytes are 1024 bytes, as the app shows sizes elsewhere.
String sizeBucket(int? bytes) {
  if (bytes == null || bytes < 0) return 'unknown size';
  if (bytes == 0) return 'empty';
  const kb = 1024;
  const mb = 1024 * kb;
  const buckets = [
    (10 * kb, 'under 10 KB'),
    (100 * kb, '10-100 KB'),
    (mb, '100 KB-1 MB'),
    (10 * mb, '1-10 MB'),
    (100 * mb, '10-100 MB'),
    (1024 * mb, '100 MB-1 GB'),
  ];
  for (final (limit, name) in buckets) {
    if (bytes < limit) return name;
  }
  return '1 GB or more';
}
