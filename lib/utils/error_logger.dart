import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';

/// Tiny app-wide error logger. Wraps [debugPrint] with a consistent format so
/// log lines can be filtered by tag (`[Tag] message`).
///
/// Replace ad-hoc `debugPrint('Error in foo: $e')` with `logError('foo', e)`.
///
/// Outside debug builds nothing is printed, and the error goes to crash
/// reporting as a non-fatal [HandledError]: its tag and kind, never its
/// message, which can contain document names and paths.
void logError(String tag, Object error, [StackTrace? stack]) {
  if (kDebugMode) {
    debugPrint('[$tag] $error');
    if (stack != null) {
      debugPrint(stack.toString());
    }
    return;
  }
  reportHandledError(tag, error, stack);
}

/// Receives handled errors once crash reporting is set up (installed by
/// `FirebaseService` in release builds); null until then, so nothing is
/// reported before that.
void Function(Object error, StackTrace stack)? handledErrorReporter;

/// Send a handled error to [handledErrorReporter] as a [HandledError].
@visibleForTesting
void reportHandledError(String tag, Object error, [StackTrace? stack]) {
  handledErrorReporter?.call(
    HandledError(tag, error),
    stack ?? StackTrace.current,
  );
}

/// A handled failure as crash reporting sees it: where it happened and what
/// kind of error it was.
class HandledError implements Exception {
  HandledError(this.tag, Object error) : kind = describeErrorKind(error);

  final String tag;
  final String kind;

  @override
  String toString() => '$tag: $kind';
}

/// The kind of [error] without its message: the type, plus the stable code
/// of errors that carry one.
String describeErrorKind(Object error) => switch (error) {
  PdfException(:final code) => 'PdfException($code)',
  PlatformException(:final code) => 'PlatformException($code)',
  FileSystemException(:final osError) =>
    'FileSystemException(${osError?.errorCode ?? 'no OS error'})',
  _ => error.runtimeType.toString(),
};
