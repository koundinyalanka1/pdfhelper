import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:receive_intent/receive_intent.dart';

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
      debugPrint(
        '[IntentService] getOpenedPdfPath: not Android, returning null',
      );
      return null;
    }

    try {
      // Prefer native getPdfIntentData - reads directly from Activity intent.
      // This works reliably when MainActivity is started by the trampoline.
      final nativeData = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getPdfIntentData',
      );
      debugPrint('[IntentService] getOpenedPdfPath: nativeData=$nativeData');
      if (nativeData != null && nativeData['path'] != null) {
        final path = nativeData['path']! as String;
        debugPrint('[IntentService] getOpenedPdfPath: from native path=$path');
        return path;
      }

      // Fallback: receive_intent (e.g. if opened directly without trampoline)
      debugPrint(
        '[IntentService] getOpenedPdfPath: nativeData null/incomplete, trying receive_intent',
      );
      final intent = await ReceiveIntent.getInitialIntent();
      debugPrint(
        '[IntentService] getOpenedPdfPath: ReceiveIntent.getInitialIntent=$intent',
      );
      if (intent == null || intent.data == null || intent.data!.isEmpty) {
        debugPrint(
          '[IntentService] getOpenedPdfPath: no intent data, returning null',
        );
        return null;
      }
      if (intent.action != 'android.intent.action.VIEW') {
        debugPrint(
          '[IntentService] getOpenedPdfPath: action=${intent.action} not VIEW, returning null',
        );
        return null;
      }

      final uri = intent.data!;
      if (!_isPdfUri(uri)) {
        debugPrint(
          '[IntentService] getOpenedPdfPath: uri=$uri not PDF, returning null',
        );
        return null;
      }

      final path = await _resolveUriToPath(uri);
      debugPrint('[IntentService] getOpenedPdfPath: resolved path=$path');
      return path;
    } on PlatformException catch (e) {
      debugPrint('[IntentService] getOpenedPdfPath: PlatformException $e');
      return null;
    }
  }

  static bool _isPdfUri(String uri) {
    final lower = uri.toLowerCase();
    if (lower.contains('.pdf')) return true;
    // content:// with type application/pdf
    return lower.startsWith('content://') || lower.startsWith('file://');
  }

  static Future<String?> _resolveUriToPath(String uriString) async {
    try {
      final path = await _channel.invokeMethod<String>('resolvePdfUri', {
        'uri': uriString,
      });
      return path;
    } on PlatformException {
      return null;
    }
  }
}
