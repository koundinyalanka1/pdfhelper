import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../services/notification_service.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'isDarkMode';
  static const String _autoSaveKey = 'autoSave';
  static const String _saveLocationKey = 'saveLocation';
  static const String _notificationsKey = 'notifications';
  static const String _outputQualityKey = 'outputQuality';
  static const String _skipPreviewKey = 'skipPreview';

  bool _isDarkMode = true;
  bool _isInitialized = false;
  bool _autoSave = true;
  bool _notifications =
      false; // Default to false, will be set based on permission
  String _saveLocation = 'Downloads';
  String _outputQuality = 'Maximum';
  bool _skipPreview = false;

  bool get isDarkMode => _isDarkMode;
  bool get isInitialized => _isInitialized;
  bool get autoSave => _autoSave;
  bool get notifications => _notifications;
  String get saveLocation => _saveLocation;
  String get outputQuality => _outputQuality;

  /// When true and [autoSave] is on, merge/convert skip the preview screen
  /// and save immediately. Default: false (preview shown).
  bool get skipPreview => _skipPreview;

  /// JPEG quality (1-100) for scan-to-PDF image encoding
  int get outputQualityAsImageQuality {
    switch (_outputQuality) {
      case 'Low':
        return 50;
      case 'Medium':
        return 70;
      case 'High':
        return 85;
      case 'Maximum':
        return 100;
      default:
        return 85;
    }
  }

  ThemeProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themeKey) ?? true;
    _autoSave = prefs.getBool(_autoSaveKey) ?? true;
    _saveLocation = prefs.getString(_saveLocationKey) ?? 'Downloads';
    _outputQuality = prefs.getString(_outputQualityKey) ?? 'Maximum';
    _skipPreview = prefs.getBool(_skipPreviewKey) ?? false;

    // Check if notification permission is granted
    // Only enable notifications setting if user has granted permission
    final hasNotificationPermission = await NotificationService()
        .hasPermission();
    final savedNotificationPref = prefs.getBool(_notificationsKey) ?? true;
    _notifications = hasNotificationPermission && savedNotificationPref;

    // Sync saved preference if permission was revoked
    if (!hasNotificationPermission && savedNotificationPref) {
      await prefs.setBool(_notificationsKey, false);
    }

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

  Future<void> setOutputQuality(String quality) async {
    if (_outputQuality == quality) return;

    _outputQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_outputQualityKey, quality);
    notifyListeners();
  }

  Future<void> setSkipPreview(bool value) async {
    if (_skipPreview == value) return;
    _skipPreview = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_skipPreviewKey, value);
    notifyListeners();
  }

  /// Set notifications - requests permission if turning on
  /// Returns true if setting was changed successfully
  Future<bool> setNotifications(bool value) async {
    if (_notifications == value) return true;

    // If turning on, request permission first
    if (value) {
      final granted = await NotificationService().requestPermission();
      if (!granted) {
        // Permission denied, don't turn on
        return false;
      }
    }

    _notifications = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsKey, value);
    notifyListeners();
    return true;
  }

  /// Get the auto-save directory path based on settings.
  /// Uses app-private storage (scoped storage) - no MANAGE_EXTERNAL_STORAGE needed.
  /// Files are accessible via Files app (Android) or Share.
  Future<String?> getAutoSavePath() async {
    if (!_autoSave) return null;

    try {
      final docDir = await getApplicationDocumentsDirectory();
      // Use subfolder based on user preference (Downloads/Documents)
      // Both are in app-private storage - Android 10+ compatible
      final subfolder = _saveLocation == 'Documents'
          ? 'Documents'
          : 'Downloads';
      return '${docDir.path}/PDFHelper/$subfolder';
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
        statusBarIconBrightness: _isDarkMode
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: _isDarkMode
            ? const Color(0xFF16213E)
            : Colors.white,
        systemNavigationBarIconBrightness: _isDarkMode
            ? Brightness.light
            : Brightness.dark,
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

  Color get background =>
      isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5F5F7);
  Color get cardBackground => isDark ? const Color(0xFF16213E) : Colors.white;
  Color get textPrimary => isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get textSecondary => isDark ? Colors.white70 : Colors.black54;
  Color get textTertiary => isDark ? Colors.white38 : Colors.black38;
  Color get divider => isDark ? Colors.white10 : Colors.black12;
  Color get accent => const Color(0xFFE94560);
  Color get accentSecondary => const Color(0xFF00D9FF);
  Color get bottomNavBackground =>
      isDark ? const Color(0xFF16213E) : Colors.white;
  Color get shadowColor => isDark ? Colors.black26 : Colors.black12;
}
