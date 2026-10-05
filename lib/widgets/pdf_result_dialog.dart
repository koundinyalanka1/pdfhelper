import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../screens/pdf_viewer_screen.dart';
import '../services/ads_service.dart';

enum _ResultAction { close, share, open }

/// The "operation finished" dialog shared by every tool.
///
/// Previously merge, split and preview each carried their own near-identical
/// copy of this; behaviour (auto-save wording, share targets, interstitial
/// timing) drifted between them.
Future<void> showPdfResultDialog({
  required BuildContext context,
  required List<String> filePaths,
  required String message,
  required PdfOperation operation,
  String title = 'Success!',
  List<String>? autoSavedPaths,
  Color accent = const Color(0xFFE94560),
}) async {
  final settings = context.read<ThemeProvider>();
  // Split has already saved its outputs; other tools arrive with local
  // working files. Export those before claiming success or showing an ad.
  if (settings.usesPublicStorage &&
      settings.autoSave &&
      autoSavedPaths == null) {
    autoSavedPaths = [];
    for (final path in filePaths) {
      final saved = await settings.autoSaveFile(path, operation.name);
      if (saved != null) autoSavedPaths.add(saved);
    }
    if (!context.mounted) return;
  }
  await AdsService.instance.operationCompleted(
    operation,
    canPresent: () =>
        context.mounted && (ModalRoute.of(context)?.isCurrent ?? false),
  );
  if (!context.mounted) return;
  final colors = AppColors(context.read<ThemeProvider>().isDarkMode);
  final hasAutoSaved = autoSavedPaths != null && autoSavedPaths.isNotEmpty;
  final shareFiles = hasAutoSaved ? autoSavedPaths : filePaths;

  final action = await showDialog<_ResultAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
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
                      'Saved to ${settings.saveLocationDescription}',
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
          onPressed: () => Navigator.pop(ctx, _ResultAction.close),
          child: Text('Close', style: TextStyle(color: colors.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _ResultAction.share),
          child: Text('Share', style: TextStyle(color: accent)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, _ResultAction.open),
          style: ElevatedButton.styleFrom(backgroundColor: accent),
          child: Text(
            shareFiles.length == 1 ? 'Open' : 'View first PDF',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (action == _ResultAction.share) {
    await SharePlus.instance.share(
      ShareParams(files: shareFiles.map((path) => XFile(path)).toList()),
    );
  } else if (action == _ResultAction.open) {
    final path = shareFiles.first;
    // Keep the operation's caller pending until the viewer closes. Otherwise
    // callers that pop their tool screen accidentally pop the new viewer.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
          pdfPath: path,
          title: path.split(RegExp(r'[/\\]')).last,
        ),
      ),
    );
  }
}
