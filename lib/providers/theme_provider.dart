import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'isDarkMode';
  
  bool _isDarkMode = true;
  bool get isDarkMode => _isDarkMode;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themeKey) ?? true;
    _updateSystemUI();
    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    _isDarkMode = isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, isDark);
    _updateSystemUI();
    notifyListeners();
  }

  void _updateSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _isDarkMode ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: _isDarkMode ? const Color(0xFF16213E) : Colors.white,
        systemNavigationBarIconBrightness: _isDarkMode ? Brightness.light : Brightness.dark,
      ),
    );
  }

  // Dark Theme
  ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFE94560),
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF1A1A2E),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: Colors.white),
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardColor: const Color(0xFF16213E),
    dividerColor: Colors.white10,
  );

  // Light Theme
  ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFE94560),
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFF5F5F7),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
      titleTextStyle: TextStyle(
        color: Color(0xFF1A1A2E),
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardColor: Colors.white,
    dividerColor: Colors.black12,
  );

  ThemeData get currentTheme => _isDarkMode ? darkTheme : lightTheme;
}

// App Colors helper class
class AppColors {
  final bool isDark;
  
  AppColors(this.isDark);
  
  Color get background => isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5F5F7);
  Color get cardBackground => isDark ? const Color(0xFF16213E) : Colors.white;
  Color get textPrimary => isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get textSecondary => isDark ? Colors.white70 : Colors.black54;
  Color get textTertiary => isDark ? Colors.white38 : Colors.black38;
  Color get divider => isDark ? Colors.white10 : Colors.black12;
  Color get accent => const Color(0xFFE94560);
  Color get accentSecondary => const Color(0xFF00D9FF);
  Color get bottomNavBackground => isDark ? const Color(0xFF16213E) : Colors.white;
  Color get shadowColor => isDark ? Colors.black26 : Colors.black12;
}

