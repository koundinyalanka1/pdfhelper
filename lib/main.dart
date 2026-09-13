import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'screens/splash_screen.dart';
import 'providers/theme_provider.dart';
import 'services/firebase_service.dart';
import 'services/notification_service.dart';
import 'services/pdf_core_service.dart';
import 'widgets/pdf_intent_listener.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  runApp(const PDFHelperApp());
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class PDFHelperApp extends StatelessWidget {
  const PDFHelperApp({super.key});

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
              title: 'PDF Helper',
              debugShowCheckedModeBanner: false,
              theme: themeProvider.lightTheme,
              darkTheme: themeProvider.darkTheme,
              themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
              home: const SplashScreen(),
            ),
          );
        },
      ),
    );
  }
}
