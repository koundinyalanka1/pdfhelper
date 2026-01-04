import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'isDarkMode';
  static const String _autoSaveKey = 'autoSave';
  static const String _saveLocationKey = 'saveLocation';
  static const String _notificationsKey = 'notifications';
  
  bool _isDarkMode = true;
  bool _isInitialized = false;
  bool _autoSave = true;
  bool _notifications = true;
  String _saveLocation = 'Downloads';
  
  bool get isDarkMode => _isDarkMode;
  bool get isInitialized => _isInitialized;
  bool get autoSave => _autoSave;
  bool get notifications => _notifications;
  String get saveLocation => _saveLocation;

  ThemeProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themeKey) ?? true;
    _autoSave = prefs.getBool(_autoSaveKey) ?? true;
    _notifications = prefs.getBool(_notificationsKey) ?? true;
    _saveLocation = prefs.getString(_saveLocationKey) ?? 'Downloads';
    _isInitialized = true;
    _updateSystemUI();
    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    if (_isDarkMode == isDark) return;
    
    _isDarkMode = isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, isDark);
    _updateSystemUI();
    notifyListeners();
  }

  Future<void> setAutoSave(bool value) async {
    if (_autoSave == value) return;
    
    _autoSave = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSaveKey, value);
    notifyListeners();
  }

  Future<void> setSaveLocation(String location) async {
    if (_saveLocation == location) return;
    
    _saveLocation = location;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saveLocationKey, location);
    notifyListeners();
  }

  Future<void> setNotifications(bool value) async {
    if (_notifications == value) return;
    
    _notifications = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsKey, value);
    notifyListeners();
  }

  /// Get the auto-save directory path based on settings
  Future<String?> getAutoSavePath() async {
    if (!_autoSave) return null;
    
    try {
      if (Platform.isAndroid) {
        // On Android, save to Downloads or Documents in external storage
        if (_saveLocation == 'Downloads') {
          final dir = Directory('/storage/emulated/0/Download');
          if (await dir.exists()) {
            return '${dir.path}/PDFHelper';
          }
        } else if (_saveLocation == 'Documents') {
          final dir = Directory('/storage/emulated/0/Documents');
          if (await dir.exists()) {
            return '${dir.path}/PDFHelper';
          }
        }
        // Fallback to external storage directory
        final extDir = await getExternalStorageDirectory();
        return extDir?.path;
      } else if (Platform.isIOS) {
        final docDir = await getApplicationDocumentsDirectory();
        return docDir.path;
      }
    } catch (e) {
      debugPrint('Error getting auto-save path: $e');
    }
    return null;
  }

  /// Auto-save a file to the configured location
  Future<String?> autoSaveFile(String sourcePath, String prefix) async {
    if (!_autoSave) return null;
    
    try {
      final savePath = await getAutoSavePath();
      if (savePath == null) return null;
      
      // Create directory if it doesn't exist
      final saveDir = Directory(savePath);
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }
      
      // Generate unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${prefix}_$timestamp.pdf';
      final destPath = '$savePath/$fileName';
      
      // Copy file to save location
      final sourceFile = File(sourcePath);
      await sourceFile.copy(destPath);
      
      return destPath;
    } catch (e) {
      debugPrint('Error auto-saving file: $e');
      return null;
    }
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

/// InheritedWidget to provide theme to all descendants
class ThemeNotifier extends InheritedNotifier<ThemeProvider> {
  const ThemeNotifier({
    super.key,
    required ThemeProvider themeProvider,
    required super.child,
  }) : super(notifier: themeProvider);

  static ThemeProvider of(BuildContext context) {
    final ThemeNotifier? result = context.dependOnInheritedWidgetOfExactType<ThemeNotifier>();
    assert(result != null, 'No ThemeNotifier found in context');
    return result!.notifier!;
  }
  
  static ThemeProvider? maybeOf(BuildContext context) {
    final ThemeNotifier? result = context.dependOnInheritedWidgetOfExactType<ThemeNotifier>();
    return result?.notifier;
  }
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
