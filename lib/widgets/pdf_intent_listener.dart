import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_intent/receive_intent.dart';
import '../services/intent_service.dart';
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
      _intentSubscription = ReceiveIntent.receivedIntentStream.listen(
        _onNewIntent,
      );
    }
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _onNewIntent(dynamic intent) async {
    if (intent == null) return;

    // ReceiveIntent may have data: null even when trampoline sent a PDF - the native
    // PendingPdfIntent holds the URI. So if we have PDF_ACTION extra or VIEW action,
    // always call getOpenedPdfIntent to read from native.
    final hasPdfIntent =
        intent.action == 'android.intent.action.VIEW' ||
        (intent.extra != null &&
            intent.extra.toString().contains(
              'com.yourmateapps.pdfhelper.PDF_ACTION',
            ));
    if (!hasPdfIntent) {
      return;
    }

    // If intent has data, validate it's a PDF; otherwise rely on native getPdfIntentData
    if (intent.data != null && intent.data.isNotEmpty) {
      final uri = intent.data as String;
      if (!uri.toLowerCase().contains('.pdf') &&
          !uri.toLowerCase().startsWith('content://') &&
          !uri.toLowerCase().startsWith('file://')) {
        return;
      }
    }

    try {
      final path = await IntentService.getOpenedPdfPath();
      if (!mounted ||
          path == null ||
          !(widget.navigatorKey.currentState?.mounted ?? false)) {
        return;
      }

      // Straight to the document. The viewer's own menu is where merge,
      // split and the rest are reached from here.
      widget.navigatorKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) =>
              PdfViewerScreen(pdfPath: path, title: getPdfDisplayTitle(path)),
        ),
        (route) => route.isFirst,
      );
    } on PlatformException {
      // Ignore
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
