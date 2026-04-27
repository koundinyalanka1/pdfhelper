import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/theme_provider.dart';
import '../services/permission_service.dart';
import '../widgets/settings_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeProvider get _themeProvider => context.watch<ThemeProvider>();
  bool get _isDarkMode => _themeProvider.isDarkMode;
  bool get _autoSave => _themeProvider.autoSave;
  bool get _notifications => _themeProvider.notifications;
  String get _saveLocation => _themeProvider.saveLocation;
  String get _outputQuality => _themeProvider.outputQuality;
  bool get _skipPreview => _themeProvider.skipPreview;
  AppColors get _colors => AppColors(_isDarkMode);

  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _appVersion = '${info.version}+${info.buildNumber}');
      }
    });
  }

  Future<void> _handleNotificationToggle(bool value) async {
    final provider = context.read<ThemeProvider>();
    if (!value) {
      await provider.setNotifications(false);
      return;
    }

    // Request with rationale and settings guidance when enabling
    final granted = await PermissionService.requestWithRationale(
      context: context,
      permission: Permission.notification,
      rationaleTitle: 'Notification Permission',
      rationaleMessage:
          'Get notified when PDF merge, split, or scan operations complete.',
      deniedTitle: 'Notification Access Required',
      deniedMessage:
          'Notification permission was denied. Enable it in Settings to get completion alerts.',
      settingsButtonText: 'Open Settings',
      cancelButtonText: 'Not Now',
    );

    if (granted && mounted) {
      await context.read<ThemeProvider>().setNotifications(true);
    }
  }

  // TODO: Replace these placeholder URLs with the real store listing /
  // privacy policy URLs before publishing.
  static const String _rateAppUrl = 'https://example.com/pdfhelper/rate';
  static const String _privacyPolicyUrl =
      'https://yourmateapps.github.io/pdfhelper/privacy-policy.html';

  Future<void> _launchExternalUrl(String url, String label) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        _showSnackBar('Could not open $label');
      }
    } catch (e) {
      debugPrint('Error launching $label: $e');
      if (mounted) {
        _showSnackBar('Could not open $label');
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE94560),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Settings',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // App info card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFFE94560).withValues(alpha: 0.3),
                      const Color(0xFF0F3460).withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _colors.shadowColor,
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE94560),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.picture_as_pdf_rounded,
                        color: Colors.white,
                        size: 35,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PDF Helper',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _appVersion.isEmpty ? '' : 'Version $_appVersion',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),

              // Appearance settings
              SettingsSectionHeader(title: 'Appearance', colors: _colors),
              const SizedBox(height: 15),
              SettingsCard(colors: _colors, children: [_buildThemeTile()]),
              const SizedBox(height: 25),

              // General settings
              SettingsSectionHeader(title: 'General', colors: _colors),
              const SizedBox(height: 15),
              SettingsCard(
                colors: _colors,
                children: [
                  _buildSwitchTile(
                    'Auto Save',
                    'Save to app storage (PDFHelper/$_saveLocation)',
                    Icons.save_rounded,
                    _autoSave,
                    (value) => context.read<ThemeProvider>().setAutoSave(value),
                  ),
                  SettingsDivider(colors: _colors),
                  _buildSwitchTile(
                    'Notifications',
                    _notifications
                        ? 'Get notified when operations complete'
                        : 'Tap to enable notifications',
                    Icons.notifications_rounded,
                    _notifications,
                    (value) => _handleNotificationToggle(value),
                  ),
                  SettingsDivider(colors: _colors),
                  _buildSwitchTile(
                    'Skip Preview',
                    _skipPreview
                        ? 'Save merged/scanned PDFs immediately'
                        : 'Preview before saving',
                    Icons.flash_on_rounded,
                    _skipPreview,
                    (value) =>
                        context.read<ThemeProvider>().setSkipPreview(value),
                  ),
                ],
              ),
              const SizedBox(height: 25),

              // Output settings
              SettingsSectionHeader(title: 'Output', colors: _colors),
              const SizedBox(height: 15),
              SettingsCard(
                colors: _colors,
                children: [
                  _buildDropdownTile(
                    'Output Quality',
                    'Select PDF quality',
                    Icons.high_quality_rounded,
                    _outputQuality,
                    ['Low', 'Medium', 'High', 'Maximum'],
                    (value) =>
                        context.read<ThemeProvider>().setOutputQuality(value!),
                  ),
                  SettingsDivider(colors: _colors),
                  _buildDropdownTile(
                    'Save Location',
                    'Auto-save destination',
                    Icons.folder_rounded,
                    _saveLocation,
                    ['Downloads', 'Documents'],
                    (value) =>
                        context.read<ThemeProvider>().setSaveLocation(value!),
                  ),
                ],
              ),
              const SizedBox(height: 25),

              // About section
              SettingsSectionHeader(title: 'About', colors: _colors),
              const SizedBox(height: 15),
              SettingsCard(
                colors: _colors,
                children: [
                  _buildActionTile(
                    'Rate App',
                    'Love the app? Rate us!',
                    Icons.star_rounded,
                    () => _launchExternalUrl(_rateAppUrl, 'Rate App'),
                  ),
                  SettingsDivider(colors: _colors),
                  _buildActionTile(
                    'Privacy Policy',
                    'Read our privacy policy',
                    Icons.privacy_tip_rounded,
                    () =>
                        _launchExternalUrl(_privacyPolicyUrl, 'Privacy Policy'),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              // Footer
              Center(
                child: Text(
                  'Made with ❤️ for PDF lovers',
                  style: TextStyle(color: _colors.textTertiary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThemeTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFE94560).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              color: const Color(0xFFE94560),
              size: 22,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme',
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isDarkMode ? 'Dark mode enabled' : 'Light mode enabled',
                  style: TextStyle(color: _colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          // Theme toggle buttons
          Container(
            decoration: BoxDecoration(
              color: _colors.divider,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildThemeButton(
                  icon: Icons.light_mode_rounded,
                  isSelected: !_isDarkMode,
                  onTap: () => context.read<ThemeProvider>().toggleTheme(false),
                ),
                _buildThemeButton(
                  icon: Icons.dark_mode_rounded,
                  isSelected: _isDarkMode,
                  onTap: () => context.read<ThemeProvider>().toggleTheme(true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeButton({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE94560) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: 20,
          color: isSelected ? Colors.white : _colors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    IconData icon,
    bool value,
    Function(bool) onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFE94560).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFFE94560), size: 22),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: _colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFFE94560),
            activeTrackColor: const Color(0xFFE94560).withValues(alpha: 0.4),
            inactiveThumbColor: _colors.textSecondary,
            inactiveTrackColor: _colors.divider,
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownTile(
    String title,
    String subtitle,
    IconData icon,
    String value,
    List<String> options,
    Function(String?) onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00D9FF), size: 22),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: _colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _colors.divider,
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButton<String>(
              value: value,
              onChanged: onChanged,
              underline: const SizedBox(),
              isDense: true,
              dropdownColor: _colors.cardBackground,
              style: TextStyle(color: _colors.textPrimary, fontSize: 13),
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: _colors.textSecondary,
                size: 20,
              ),
              items: options.map((option) {
                return DropdownMenuItem(value: option, child: Text(option));
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFFFFC107), size: 22),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: _colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: _colors.textTertiary),
          ],
        ),
      ),
    );
  }
}
