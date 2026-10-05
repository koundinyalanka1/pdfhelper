import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'screens/pdf_viewer_screen.dart';
import 'screens/splash_screen.dart';
import 'providers/theme_provider.dart';
import 'services/firebase_service.dart';
import 'services/intent_service.dart';
import 'services/notification_service.dart';
import 'services/pdf_core_service.dart';
import 'services/scan_route_observer.dart';
import 'widgets/pdf_intent_listener.dart';
import 'utils/format_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve external documents while startup services initialize. Choose the
  // initial routes before the first Flutter frame so viewing skips the splash.
  final openedPdf = IntentService.getOpenedPdfPath();

  // Crash reporting first: anything that fails during the rest of startup
  // should be reported rather than lost. Safe if the config file is missing.
  await FirebaseService.initialize();

  // Resolve the native PDF core once. Never throws — screens check
  // PdfCoreService.isAvailable and explain themselves if it is missing.
  await PdfCoreService.probe();

  // Initialize notifications
  await NotificationService().initialize();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF16213E),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(PDFHelperApp(initialPdfPath: await openedPdf));
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class PDFHelperApp extends StatelessWidget {
  const PDFHelperApp({super.key, this.initialPdfPath});

  final String? initialPdfPath;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return PdfIntentListener(
            navigatorKey: navigatorKey,
            child: MaterialApp(
              navigatorKey: navigatorKey,
              navigatorObservers: [scanRouteObserver],
              title: 'PDF Helper',
              debugShowCheckedModeBanner: false,
              theme: themeProvider.lightTheme,
              darkTheme: themeProvider.darkTheme,
              themeMode: themeProvider.isDarkMode
                  ? ThemeMode.dark
                  : ThemeMode.light,
              onGenerateInitialRoutes: (_) {
                final path = initialPdfPath;
                if (path == null) {
                  return [
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(
                        name: SplashScreen.routeName,
                      ),
                      builder: (_) => const SplashScreen(),
                    ),
                  ];
                }
                return [
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(
                      name: PdfIntentListener.viewerRouteName,
                    ),
                    builder: (_) => PdfViewerScreen(
                      pdfPath: path,
                      title: getPdfDisplayTitle(path),
                    ),
                  ),
                ];
              },
              // Also gives Flutter a valid default route when rebuilding the
              // application (for example after a theme change).
              routes: {'/': (_) => const HomeScreen()},
            ),
          );
        },
      ),
    );
  }
}
