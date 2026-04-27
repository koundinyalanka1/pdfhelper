import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'merge_pdf_screen.dart';
import 'convert_screen.dart';
import 'split_pdf_screen.dart';
import 'settings_screen.dart';
import '../providers/theme_provider.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/lazy_indexed_stack.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialPdfPath, this.initialTab = 0});

  final String? initialPdfPath;
  final int initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab;
  }

  Widget _buildScreen(int index) {
    switch (index) {
      case 0:
        return MergePdfScreen(initialPdfPath: widget.initialPdfPath);
      case 1:
        return const ConvertScreen();
      case 2:
        return SplitPdfScreen(initialPdfPath: widget.initialPdfPath);
      case 3:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LazyIndexedStack(
        index: _currentIndex,
        itemCount: 4,
        itemBuilder: _buildScreen,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: _colors.bottomNavBackground,
              boxShadow: [
                BoxShadow(
                  color: _colors.shadowColor,
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildNavItem(0, Icons.merge_rounded, 'Merge'),
                    _buildNavItem(1, Icons.camera_alt_rounded, 'Convert'),
                    _buildNavItem(2, Icons.content_cut_rounded, 'Split'),
                    _buildNavItem(3, Icons.settings_rounded, 'Settings'),
                  ],
                ),
              ),
            ),
          ),
          // Banner ad sits below the nav, inside the device safe area so it
          // doesn't get clipped by the iOS home indicator / Android gesture bar.
          Container(
            color: _colors.bottomNavBackground,
            width: double.infinity,
            child: SafeArea(
              top: false,
              child: const Center(child: BannerAdWidget()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    final Color activeColor = _getActiveColor(index);
    final Color inactiveColor = _isDarkMode ? Colors.white54 : Colors.black45;

    return Semantics(
      label: '$label tab, ${isSelected ? "selected" : "not selected"}',
      button: true,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _currentIndex = index;
          });
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? activeColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected ? activeColor : inactiveColor,
                size: 26,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? activeColor : inactiveColor,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getActiveColor(int index) {
    switch (index) {
      case 0:
        return const Color(0xFFE94560); // Merge - Red/Pink
      case 1:
        return const Color(0xFF00D9FF); // Convert - Cyan
      case 2:
        return const Color(0xFFFFC107); // Split - Amber
      case 3:
        return const Color(0xFF4CAF50); // Settings - Green
      default:
        return const Color(0xFFE94560);
    }
  }
}
