import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';
import 'providers/theme_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

  // Static method to access state from anywhere
  static _PDFHelperAppState? of(BuildContext context) {
    return context.findAncestorStateOfType<_PDFHelperAppState>();
  }

  @override
  State<PDFHelperApp> createState() => _PDFHelperAppState();
}

class _PDFHelperAppState extends State<PDFHelperApp> {
  final ThemeProvider _themeProvider = ThemeProvider();

  ThemeProvider get themeProvider => _themeProvider;

  @override
  void initState() {
    super.initState();
    _themeProvider.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeProvider.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Helper',
      debugShowCheckedModeBanner: false,
      theme: _themeProvider.lightTheme,
      darkTheme: _themeProvider.darkTheme,
      themeMode: _themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: const SplashScreen(),
    );
  }
}
