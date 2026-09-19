import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../utils/file_naming.dart';

/// Ask what the PDF about to be written should be called.
///
/// Returns the sanitised base name (no extension), or `null` when the user
/// backs out. Callers treat `null` as "cancel the whole operation", which is
/// why this is shown *before* any work starts rather than after.
Future<String?> askPdfName({
  required BuildContext context,
  required String initialName,
  String title = 'Name your PDF',
  String confirmLabel = 'Create',
  String? hint,
  Color accent = const Color(0xFF00D9FF),
}) {
  final colors = AppColors(context.read<ThemeProvider>().isDarkMode);
  final controller = TextEditingController(text: initialName);
  // Pre-select the whole default so typing replaces it, but tapping once
  // keeps it — the common case is "accept the default".
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: initialName.length,
  );

  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() => Navigator.pop(ctx, sanitizeFileName(controller.text));

      return AlertDialog(
        backgroundColor: colors.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.drive_file_rename_outline, color: accent, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: colors.textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
              maxLength: maxBaseNameLength,
              style: TextStyle(color: colors.textPrimary),
              // Reject the characters a filesystem would, as they are typed,
              // instead of rewriting the name under the user afterwards.
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'[<>:"/\\|?*]')),
              ],
              decoration: InputDecoration(
                counterText: '',
                suffixText: '.pdf',
                suffixStyle: TextStyle(color: colors.textTertiary),
                filled: true,
                fillColor: colors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 10),
              Text(
                hint,
                style: TextStyle(color: colors.textTertiary, fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: submit,
            style: ElevatedButton.styleFrom(backgroundColor: accent),
            child: Text(
              confirmLabel,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}
