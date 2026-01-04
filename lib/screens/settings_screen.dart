import 'package:flutter/material.dart';
import '../providers/theme_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _outputQuality = 'High';

  ThemeProvider? get _themeProvider => ThemeNotifier.maybeOf(context);
  bool get _isDarkMode => _themeProvider?.isDarkMode ?? true;
  bool get _autoSave => _themeProvider?.autoSave ?? true;
  bool get _notifications => _themeProvider?.notifications ?? true;
  String get _saveLocation => _themeProvider?.saveLocation ?? 'Downloads';
  AppColors get _colors => AppColors(_isDarkMode);

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
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PDF Helper',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Version 1.0.0',
                          style: TextStyle(
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
              _buildSectionHeader('Appearance'),
              const SizedBox(height: 15),
              _buildSettingsCard([
                _buildThemeTile(),
              ]),
              const SizedBox(height: 25),

              // General settings
              _buildSectionHeader('General'),
              const SizedBox(height: 15),
              _buildSettingsCard([
                _buildSwitchTile(
                  'Auto Save',
                  'Save files to $_saveLocation folder',
                  Icons.save_rounded,
                  _autoSave,
                  (value) => _themeProvider?.setAutoSave(value),
                ),
                _buildDivider(),
                _buildSwitchTile(
                  'Notifications',
                  'Get notified when operations complete',
                  Icons.notifications_rounded,
                  _notifications,
                  (value) => _themeProvider?.setNotifications(value),
                ),
              ]),
              const SizedBox(height: 25),

              // Output settings
              _buildSectionHeader('Output'),
              const SizedBox(height: 15),
              _buildSettingsCard([
                _buildDropdownTile(
                  'Output Quality',
                  'Select PDF quality',
                  Icons.high_quality_rounded,
                  _outputQuality,
                  ['Low', 'Medium', 'High', 'Maximum'],
                  (value) => setState(() => _outputQuality = value!),
                ),
                _buildDivider(),
                _buildDropdownTile(
                  'Save Location',
                  'Auto-save destination',
                  Icons.folder_rounded,
                  _saveLocation,
                  ['Downloads', 'Documents'],
                  (value) => _themeProvider?.setSaveLocation(value!),
                ),
              ]),
              const SizedBox(height: 25),

              // About section
              _buildSectionHeader('About'),
              const SizedBox(height: 15),
              _buildSettingsCard([
                _buildActionTile(
                  'Rate App',
                  'Love the app? Rate us!',
                  Icons.star_rounded,
                  () {},
                ),
                _buildDivider(),
                _buildActionTile(
                  'Privacy Policy',
                  'Read our privacy policy',
                  Icons.privacy_tip_rounded,
                  () {},
                ),
                _buildDivider(),
                _buildActionTile(
                  'Terms of Service',
                  'Read terms of service',
                  Icons.description_rounded,
                  () {},
                ),
              ]),
              const SizedBox(height: 30),

              // Footer
              Center(
                child: Text(
                  'Made with ❤️ for PDF lovers',
                  style: TextStyle(
                    color: _colors.textTertiary,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: TextStyle(
        color: _colors.textSecondary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.5,
      ),
    );
  }

  Widget _buildSettingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _colors.shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider() {
    return Divider(
      color: _colors.divider,
      height: 1,
      indent: 70,
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
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12,
                  ),
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
                  onTap: () => _themeProvider?.toggleTheme(false),
                ),
                _buildThemeButton(
                  icon: Icons.dark_mode_rounded,
                  isSelected: _isDarkMode,
                  onTap: () => _themeProvider?.toggleTheme(true),
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
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFFE94560),
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
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12,
                  ),
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
              style: TextStyle(
                color: _colors.textPrimary,
                fontSize: 13,
              ),
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: _colors.textSecondary,
                size: 20,
              ),
              items: options.map((option) {
                return DropdownMenuItem(
                  value: option,
                  child: Text(option),
                );
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
            Icon(
              Icons.chevron_right_rounded,
              color: _colors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
