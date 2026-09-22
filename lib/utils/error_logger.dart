import 'package:flutter/foundation.dart';

/// Tiny app-wide error logger. Wraps [debugPrint] with a consistent format so
/// log lines can be filtered by tag (`[Tag] message`). In release builds this
/// is explicitly disabled to avoid logging document names and paths.
///
/// Replace ad-hoc `debugPrint('Error in foo: $e')` with `logError('foo', e)`.
void logError(String tag, Object error, [StackTrace? stack]) {
  if (!kDebugMode) return;
  debugPrint('[$tag] $error');
  if (stack != null) {
    debugPrint(stack.toString());
  }
}
