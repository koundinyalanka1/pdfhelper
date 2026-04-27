import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_intent/receive_intent.dart';
import '../services/intent_service.dart';
import '../screens/home_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../utils/format_utils.dart';

/// Listens for new PDF intents when app is resumed (e.g. user opens PDF while app in background).
/// Must wrap the app and have access to navigator.
class PdfIntentListener extends StatefulWidget {
  const PdfIntentListener({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<PdfIntentListener> createState() => _PdfIntentListenerState();
}

class _PdfIntentListenerState extends State<PdfIntentListener> {
  StreamSubscription? _intentSubscription;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _intentSubscription = ReceiveIntent.receivedIntentStream.listen(_onNewIntent);
    }
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _onNewIntent(dynamic intent) async {
    debugPrint('[PdfIntentListener] _onNewIntent: intent=$intent');
    if (intent == null) return;

    // ReceiveIntent may have data: null even when trampoline sent a PDF - the native
    // PendingPdfIntent holds the URI. So if we have PDF_ACTION extra or VIEW action,
    // always call getOpenedPdfIntent to read from native.
    final hasPdfIntent = intent.action == 'android.intent.action.VIEW' ||
        (intent.extra != null &&
            intent.extra.toString().contains('com.example.pdfhelper.PDF_ACTION'));
    if (!hasPdfIntent) {
      debugPrint('[PdfIntentListener] _onNewIntent: not a PDF intent, ignoring');
      return;
    }

    // If intent has data, validate it's a PDF; otherwise rely on native getPdfIntentData
    if (intent.data != null && intent.data.isNotEmpty) {
      final uri = intent.data as String;
      if (!uri.toLowerCase().contains('.pdf') &&
          !uri.toLowerCase().startsWith('content://') &&
          !uri.toLowerCase().startsWith('file://')) {
        debugPrint('[PdfIntentListener] _onNewIntent: data not a PDF uri');
        return;
      }
    }

    try {
      final result = await IntentService.getOpenedPdfIntent();
      debugPrint('[PdfIntentListener] _onNewIntent: result=$result action=${result?.action}');
      if (result == null || !(widget.navigatorKey.currentState?.mounted ?? false)) {
        debugPrint('[PdfIntentListener] _onNewIntent: result null or navigator not mounted');
        return;
      }

      final path = result.path;
      final title = getPdfDisplayTitle(path);

      switch (result.action) {
        case PdfIntentAction.view:
          widget.navigatorKey.currentState!.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => PdfViewerScreen(pdfPath: path, title: title),
            ),
            (route) => false,
          );
          break;
        case PdfIntentAction.merge:
          widget.navigatorKey.currentState!.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => HomeScreen(initialPdfPath: path, initialTab: 0),
            ),
            (route) => false,
          );
          break;
        case PdfIntentAction.split:
          widget.navigatorKey.currentState!.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => HomeScreen(initialPdfPath: path, initialTab: 2),
            ),
            (route) => false,
          );
          break;
      }
    } on PlatformException {
      // Ignore
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
