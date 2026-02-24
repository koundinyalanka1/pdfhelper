import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:receive_intent/receive_intent.dart';

/// Action chosen from the "Open with" menu (View PDF, Merge PDF, Split PDF).
enum PdfIntentAction { view, merge, split }

/// Result of opening app via PDF intent: path + which option user selected.
class PdfIntentResult {
  const PdfIntentResult(this.path, this.action);
  final String path;
  final PdfIntentAction action;
}

/// Handles Android intents (e.g. opening PDF from file manager).
/// Returns resolved file path or null.
class IntentService {
  static const _channel = MethodChannel('com.example.pdfhelper/pdf');

  /// Gets the PDF path and action if app was launched via one of the PDF aliases.
  /// Returns null if not launched via PDF intent or on non-Android.
  static Future<PdfIntentResult?> getOpenedPdfIntent() async {
    if (!Platform.isAndroid) {
      debugPrint('[IntentService] getOpenedPdfIntent: not Android, returning null');
      return null;
    }

    try {
      // Prefer native getPdfIntentData - reads directly from Activity intent.
      // This works reliably when MainActivity is started by the trampoline.
      final nativeData = await _channel.invokeMethod<Map<Object?, Object?>>('getPdfIntentData');
      debugPrint('[IntentService] getOpenedPdfIntent: nativeData=$nativeData');
      if (nativeData != null &&
          nativeData['path'] != null &&
          nativeData['action'] != null) {
        final path = nativeData['path']! as String;
        final actionStr = nativeData['action']! as String;
        final action = _parseAction(actionStr);
        debugPrint('[IntentService] getOpenedPdfIntent: from native path=$path actionStr=$actionStr action=$action');
        return PdfIntentResult(path, action ?? PdfIntentAction.view);
      }

      // Fallback: receive_intent (e.g. if opened directly without trampoline)
      debugPrint('[IntentService] getOpenedPdfIntent: nativeData null/incomplete, trying receive_intent');
      final intent = await ReceiveIntent.getInitialIntent();
      debugPrint('[IntentService] getOpenedPdfIntent: ReceiveIntent.getInitialIntent=$intent');
      if (intent == null || intent.data == null || intent.data!.isEmpty) {
        debugPrint('[IntentService] getOpenedPdfIntent: no intent data, returning null');
        return null;
      }
      if (intent.action != 'android.intent.action.VIEW') {
        debugPrint('[IntentService] getOpenedPdfIntent: action=${intent.action} not VIEW, returning null');
        return null;
      }

      final uri = intent.data!;
      if (!_isPdfUri(uri)) {
        debugPrint('[IntentService] getOpenedPdfIntent: uri=$uri not PDF, returning null');
        return null;
      }

      final path = await _resolveUriToPath(uri);
      debugPrint('[IntentService] getOpenedPdfIntent: resolved path=$path');
      if (path == null) return null;

      final actionStr = await _channel.invokeMethod<String>('getPdfIntentAction');
      final action = _parseAction(actionStr) ?? PdfIntentAction.view;
      debugPrint('[IntentService] getOpenedPdfIntent: from receive_intent path=$path action=$action');

      return PdfIntentResult(path, action);
    } on PlatformException catch (e) {
      debugPrint('[IntentService] getOpenedPdfIntent: PlatformException $e');
      return null;
    }
  }

  static PdfIntentAction? _parseAction(String? s) {
    switch (s) {
      case 'view':
        return PdfIntentAction.view;
      case 'merge':
        return PdfIntentAction.merge;
      case 'split':
        return PdfIntentAction.split;
      default:
        return null;
    }
  }

  /// Legacy: gets only the PDF path. Prefer [getOpenedPdfIntent].
  static Future<String?> getOpenedPdfPath() async {
    final result = await getOpenedPdfIntent();
    return result?.path;
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
