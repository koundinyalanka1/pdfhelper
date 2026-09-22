import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';

/// Explain what "All files access" is for before sending anyone to the system
/// screen that grants it.
///
/// On Android 11+ `Permission.manageExternalStorage` does not show a normal
/// permission sheet — it drops the user straight into a settings page headed
/// "Allow access to manage all files", with a warning tone and no mention of
/// this app's reason for wanting it. Arriving there cold, from a small button,
/// is a request most people decline. Asking here first means the explanation
/// arrives before the alarming screen does, and declining costs nothing.
///
/// Returns true when the user chose to continue to the system screen.
Future<bool> showStorageAccessDialog(BuildContext context) async {
  final colors = AppColors(
    // listen: false — called from an event handler, not a build.
    Provider.of<ThemeProvider>(context, listen: false).isDarkMode,
  );

  Widget point(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colors.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.cardBackground,
      title: Text(
        'Find PDFs on your phone',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Android puts files outside this app behind a permission called '
            '"All files access". Without it, PDF Helper can only show the '
            'documents it created itself.',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          point(Icons.picture_as_pdf_rounded, 'Only PDFs are read. Nothing '
              'else on your phone is opened or listed.'),
          point(Icons.phone_android_rounded, 'Everything stays on this '
              'device. No file is uploaded anywhere.'),
          point(Icons.settings_rounded, 'The next screen is Android\'s own. '
              'You can turn this off there at any time.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Not now', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return result ?? false;
}
