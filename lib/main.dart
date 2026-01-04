import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';
import 'providers/theme_provider.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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

class PDFHelperApp extends StatefulWidget {
  const PDFHelperApp({super.key});

  @override
  State<PDFHelperApp> createState() => _PDFHelperAppState();
}

class _PDFHelperAppState extends State<PDFHelperApp> {
  final ThemeProvider _themeProvider = ThemeProvider();

  @override
  void initState() {
    super.initState();
    _themeProvider.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeProvider.removeListener(_onThemeChanged);
    _themeProvider.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeNotifier(
      themeProvider: _themeProvider,
      child: MaterialApp(
        title: 'PDF Helper',
        debugShowCheckedModeBanner: false,
        theme: _themeProvider.lightTheme,
        darkTheme: _themeProvider.darkTheme,
        themeMode: _themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
        home: const SplashScreen(),
      ),
    );
  }
}
