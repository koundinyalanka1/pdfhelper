import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';

/// Ask for a PDF's open password.
///
/// Lives here rather than on one screen because every way into a document —
/// the library, a share intent, the splash route, the Tools tab — has to be
/// able to ask. When only Tools could, an encrypted file opened from anywhere
/// else looked like a damaged one.
///
/// Returns the entered password, or null if the user backed out.
Future<String?> showPdfPasswordPrompt(
  BuildContext context, {
  bool retry = false,
  String? fileName,
}) {
  // listen: false — this runs from an event handler, not a build.
  final colors = AppColors(
    Provider.of<ThemeProvider>(context, listen: false).isDarkMode,
  );
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.cardBackground,
      title: Text(
        retry ? 'Wrong password' : 'Password required',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            retry
                ? 'That password did not work. Try again.'
                : fileName == null
                ? 'This PDF is protected. Enter its password to open it.'
                : '"$fileName" is protected. Enter its password to open it.',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            style: TextStyle(color: colors.textPrimary),
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (value) => Navigator.pop(ctx, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
