import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../screens/pdf_viewer_screen.dart';
import '../services/ads_service.dart';

/// The "operation finished" dialog shared by every tool.
///
/// Previously merge, split and preview each carried their own near-identical
/// copy of this; behaviour (auto-save wording, share targets, interstitial
/// timing) drifted between them.
Future<void> showPdfResultDialog({
  required BuildContext context,
  required List<String> filePaths,
  required String message,
  String title = 'Success!',
  List<String>? autoSavedPaths,
  String adTrigger = 'operation',
  Color accent = const Color(0xFFE94560),
}) {
  final colors = AppColors(context.read<ThemeProvider>().isDarkMode);
  final saveLocation = context.read<ThemeProvider>().saveLocation;
  final hasAutoSaved = autoSavedPaths != null && autoSavedPaths.isNotEmpty;
  final shareFiles = hasAutoSaved ? autoSavedPaths : filePaths;

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: TextStyle(color: colors.textPrimary)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TextStyle(color: colors.textSecondary)),
          if (hasAutoSaved) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_rounded,
                    color: Color(0xFF4CAF50),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Saved to app storage (PDFHelper/$saveLocation)',
                      style: const TextStyle(
                        color: Color(0xFF4CAF50),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            // The user is finished and is not heading into Share or the
            // viewer — the least intrusive moment for an interstitial.
            AdsService.instance.maybeShowInterstitial(trigger: adTrigger);
          },
          child: Text('Close', style: TextStyle(color: colors.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            SharePlus.instance.share(
              ShareParams(files: shareFiles.map((p) => XFile(p)).toList()),
            );
          },
          child: Text('Share', style: TextStyle(color: accent)),
        ),
        ElevatedButton(
          onPressed: () {
            final navigator = Navigator.of(context);
            Navigator.pop(ctx);
            final path = shareFiles.first;
            navigator.push(
              MaterialPageRoute(
                builder: (_) => PdfViewerScreen(
                  pdfPath: path,
                  title: path.split(RegExp(r'[/\\]')).last,
                ),
              ),
            );
          },
          style: ElevatedButton.styleFrom(backgroundColor: accent),
          child: Text(
            shareFiles.length == 1 ? 'Open' : 'View first PDF',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    ),
  );
}
