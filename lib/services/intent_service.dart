import 'dart:io';
import 'package:flutter/services.dart';

/// Handles Android intents (e.g. opening a PDF from a file manager).
///
/// The app offers exactly one "Open with" entry, because opening a PDF from
/// somewhere else means one thing: read it. Every other operation is reached
/// from the viewer once the document is on screen, so there is no action to
/// carry through here — only a path.
class IntentService {
  static const _channel = MethodChannel('com.yourmateapps.pdfhelper/pdf');

  /// The PDF this app was launched to open, or null when it was not launched
  /// from an intent (or is not on Android).
  static Future<String?> getOpenedPdfPath() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      // Prefer native getPdfIntentData - reads directly from Activity intent.
      // This works reliably when MainActivity is started by the trampoline.
      final nativeData = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getPdfIntentData',
      );
      if (nativeData != null && nativeData['path'] != null) {
        final path = nativeData['path']! as String;
        return path;
      }

      return null;
    } on PlatformException {
      return null;
    }
  }
}
