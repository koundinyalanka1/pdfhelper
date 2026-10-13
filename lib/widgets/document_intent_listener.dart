import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart' hide Intent;
import 'package:flutter/services.dart';
import 'package:receive_intent/receive_intent.dart';
import '../services/intent_service.dart';
import '../screens/splash_screen.dart';
import '../services/document_router.dart';

/// Listens for documents opened from other apps while DocHelper is already
/// running (e.g. the user taps a file in WhatsApp with the app in the
/// background).
/// Must wrap the app and have access to navigator.
class DocumentIntentListener extends StatefulWidget {
  const DocumentIntentListener({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.intentStream,
    this.resolvePdfPath,
  });

  static const viewerRouteName = '/external-pdf';

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final Stream<Intent?>? intentStream;
  final Future<String?> Function()? resolvePdfPath;

  @override
  State<DocumentIntentListener> createState() => _DocumentIntentListenerState();
}

class _DocumentIntentListenerState extends State<DocumentIntentListener> {
  StreamSubscription<Intent?>? _intentSubscription;
  Future<void> _pendingOpen = Future<void>.value();

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || widget.intentStream != null) {
      _intentSubscription =
          (widget.intentStream ?? ReceiveIntent.receivedIntentStream).listen(
            _onNewIntent,
            onError: (Object error) => debugPrint('[PdfIntent] $error'),
          );
      // A delivery can arrive after main() consumed the cold-start intent but
      // before this stream subscribed. Native storage keeps it until consumed.
      WidgetsBinding.instance.addPostFrameCallback((_) => _queuePendingPdf());
    }
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    super.dispose();
  }

  void _onNewIntent(Intent? intent) {
    if (intent == null) return;

    // ReceiveIntent can omit data even though native PendingPdfIntent has it.
    final hasPdfIntent =
        intent.action == 'android.intent.action.VIEW' ||
        (intent.extra?.containsKey('com.yourmateapps.pdfhelper.PDF_ACTION') ??
            false);
    if (!hasPdfIntent) {
      return;
    }

    // Only local documents: content:// from a provider, or file://. The
    // native side checks the type and content before handing a path over.
    final uri = intent.data;
    if (uri != null && uri.isNotEmpty) {
      final lower = uri.toLowerCase();
      if (!lower.startsWith('content://') && !lower.startsWith('file://')) {
        return;
      }
    }

    _queuePendingPdf();
  }

  void _queuePendingPdf() {
    // Serialize URI resolution so two closely spaced intents cannot display
    // their documents in the opposite order when provider I/O completes.
    _pendingOpen = _pendingOpen.then((_) => _openPendingPdf());
  }

  Future<void> _openPendingPdf() async {
    if (!mounted) return;
    try {
      final path =
          await (widget.resolvePdfPath ??
              IntentService.getOpenedDocumentPath)();
      if (!mounted ||
          path == null ||
          !(widget.navigatorKey.currentState?.mounted ?? false)) {
        return;
      }

      final navigator = widget.navigatorKey.currentState!;
      navigator.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          settings: const RouteSettings(
            name: DocumentIntentListener.viewerRouteName,
          ),
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => externalDocumentScreen(path),
        ),
        // Preserve an existing library, but remove startup and old external
        // viewers. Direct viewing must not build a hidden library or ask for
        // storage access until the user chooses to browse it.
        (route) =>
            route.isFirst &&
            route.settings.name != SplashScreen.routeName &&
            route.settings.name != DocumentIntentListener.viewerRouteName,
      );
    } on PlatformException catch (error) {
      debugPrint('[PdfIntent] ${error.message}');
    } on MissingPluginException {
      // The Android channel is absent on other hosts and in widget tests.
    } catch (error) {
      // A bad provider response must not poison the queue for later intents.
      debugPrint('[PdfIntent] $error');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
