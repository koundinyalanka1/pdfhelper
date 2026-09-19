import 'package:flutter/material.dart';

import '../models/home_tabs.dart';
import '../providers/theme_provider.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'convert_screen.dart';
import 'library_screen.dart';
import 'merge_pdf_screen.dart';
import 'settings_screen.dart';
import 'split_pdf_screen.dart';
import 'tools_screen.dart';

export '../models/home_tabs.dart';

/// The tab scaffold: Files, Tools, Scan, Settings.
///
/// The tabs are the four *places* in the app. Everything you do to a document
/// is a route pushed over them, which is why merge and split no longer sit in
/// the bar — see [DocHandoff].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = HomeTabs.files});

  final int initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _currentIndex;

  /// The document Tools is working on, when one arrived from outside it —
  /// "Open in Tools" from Files.
  ///
  /// [_toolsEpoch] keys the tab so that handing it a *second* document
  /// rebuilds it instead of leaving it showing the first: it reads
  /// `initialPdfPath` in `initState` only.
  String? _toolsPath;
  int _toolsEpoch = 0;

  /// Bumped whenever the user lands back on Files, so the library re-sweeps
  /// and picks up whatever another tab — or a tool route — just produced.
  int _filesVisitToken = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab;
  }

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() {
      if (index == HomeTabs.files) _filesVisitToken++;
      _currentIndex = index;
    });
  }

  /// Hand a document to Tools and show it.
  void _openInTools(String path) {
    setState(() {
      _toolsPath = path;
      _toolsEpoch++;
      _currentIndex = HomeTabs.tools;
    });
  }

  /// Push merge or split over the tabs.
  Future<void> _openHandoff(DocHandoff action, String? path) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => switch (action) {
          DocHandoff.merge => MergePdfScreen(initialPdfPath: path),
          DocHandoff.split => SplitPdfScreen(initialPdfPath: path),
        },
      ),
    );
    // Whatever it produced belongs in the library by the time we are back.
    if (mounted) setState(() => _filesVisitToken++);
  }

  Widget _buildScreen(int index) {
    switch (index) {
      case HomeTabs.files:
        return LibraryScreen(
          refreshToken: _filesVisitToken,
          onSendTo: _openHandoff,
          onOpenInTools: _openInTools,
        );
      case HomeTabs.tools:
        return ToolsScreen(
          key: ValueKey('tools-$_toolsEpoch'),
          initialPdfPath: _toolsPath,
          onSendTo: _openHandoff,
          onGoToTab: _goToTab,
        );
      case HomeTabs.scan:
        return const ConvertScreen();
      case HomeTabs.settings:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    // Back from any other tab returns to Files rather than leaving the app —
    // the Android convention, and the reason a stray back press no longer
    // closes a session mid-task.
    return PopScope(
      canPop: _currentIndex == HomeTabs.files,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goToTab(HomeTabs.files);
      },
      child: Scaffold(
        body: LazyIndexedStack(
          index: _currentIndex,
          itemCount: HomeTabs.count,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      _buildNavItem(
                        HomeTabs.files,
                        Icons.folder_rounded,
                        Icons.folder_outlined,
                        'Files',
                      ),
                      _buildNavItem(
                        HomeTabs.tools,
                        Icons.handyman_rounded,
                        Icons.handyman_outlined,
                        'Tools',
                      ),
                      _buildNavItem(
                        HomeTabs.scan,
                        Icons.camera_alt_rounded,
                        Icons.camera_alt_outlined,
                        'Scan',
                      ),
                      _buildNavItem(
                        HomeTabs.settings,
                        Icons.settings_rounded,
                        Icons.settings_outlined,
                        'Settings',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Banner ad sits below the nav, inside the device safe area so it
            // doesn't get clipped by the iOS home indicator / Android gesture
            // bar.
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
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData activeIcon,
    IconData inactiveIcon,
    String label,
  ) {
    final isSelected = _currentIndex == index;
    final Color activeColor = _tabColor(index);
    final Color inactiveColor = _colors.isDark
        ? Colors.white54
        : Colors.black45;

    // Expanded rather than spaceAround: with four destinations the tap target
    // should be the whole quarter of the bar, not just the glyph.
    return Expanded(
      child: Semantics(
        label: '$label tab, ${isSelected ? "selected" : "not selected"}',
        button: true,
        selected: isSelected,
        child: GestureDetector(
          onTap: () => _goToTab(index),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            margin: const EdgeInsets.symmetric(horizontal: 3),
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
                  isSelected ? activeIcon : inactiveIcon,
                  color: isSelected ? activeColor : inactiveColor,
                  size: 25,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? activeColor : inactiveColor,
                    fontSize: 11.5,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _tabColor(int index) {
    switch (index) {
      case HomeTabs.files:
        return const Color(0xFFE94560); // Files - Red/Pink
      case HomeTabs.tools:
        return const Color(0xFF7C4DFF); // Tools - Violet
      case HomeTabs.scan:
        return const Color(0xFF00D9FF); // Scan - Cyan
      case HomeTabs.settings:
        return const Color(0xFF00BFA5); // Settings - Teal
      default:
        return const Color(0xFFE94560);
    }
  }
}
