import 'package:flutter/foundation.dart';

/// Tiny app-wide error logger. Wraps [debugPrint] with a consistent format so
/// log lines can be filtered by tag (`[Tag] message`). In release builds this
/// is a no-op via [debugPrint]'s release-mode behavior.
///
/// Replace ad-hoc `debugPrint('Error in foo: $e')` with `logError('foo', e)`.
void logError(String tag, Object error, [StackTrace? stack]) {
  debugPrint('[$tag] $error');
  if (stack != null) {
    debugPrint(stack.toString());
  }
}
