import 'package:flutter/material.dart';

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
