import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/text_editor_screen.dart';
import '../utils/format_utils.dart';

/// Picks the screen for a document by its kind, so every way into a file
/// (Files, "Open with", recent lists) opens it the same way.
class DocumentRouter {
  DocumentRouter._();

  /// The screen that opens [path], or null when DocHelper cannot open its
  /// kind yet.
  static Widget? screenFor(String path, {String? title, String password = ''}) {
    final name = title ?? documentDisplayName(path);
    return switch (DocKind.ofPath(path)) {
      DocKind.pdf => PdfViewerScreen(
        pdfPath: path,
        title: name,
        password: password,
      ),
      DocKind.text => TextEditorScreen(path: path, title: name),
      _ => null,
    };
  }

  /// Open [path] on top of the current route. Kinds without a screen get a
  /// sheet offering another app instead.
  static Future<void> open(
    BuildContext context,
    String path, {
    String? title,
  }) async {
    final screen = screenFor(path, title: title);
    if (screen == null) {
      await showUnsupportedFileSheet(context, path);
      return;
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
  }
}

/// Explains that DocHelper cannot open this kind of file yet, and offers to
/// open it in another app or share it.
Future<void> showUnsupportedFileSheet(BuildContext context, String path) {
  final kind = DocKind.ofPath(path);
  final name = documentDisplayName(path);
  return showModalBottomSheet<void>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _UnsupportedFileSheet(
      kind: kind,
      name: name,
      path: path,
      outerContext: context,
    ),
  );
}

class _UnsupportedFileSheet extends StatelessWidget {
  const _UnsupportedFileSheet({
    required this.kind,
    required this.name,
    required this.path,
    required this.outerContext,
  });

  final DocKind kind;
  final String name;
  final String path;

  /// For messages after the sheet has closed.
  final BuildContext outerContext;

  @override
  Widget build(BuildContext ctx) {
    // Read in build: AppColors.of listens, which is only allowed here.
    final colors = AppColors.of(ctx);
    final context = outerContext;
    return ColoredBox(
      color: colors.cardBackground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(kind.icon, color: kind.color, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                kind == DocKind.other
                    ? 'DocHelper cannot open this kind of file.'
                    : 'Opening ${kind.label} files in DocHelper is coming soon. '
                          'Until then, you can open it in another app or '
                          'share it.',
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open with another app'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final result = await OpenFile.open(
                      path,
                      type: DocKind.mimeTypeOf(path),
                    );
                    if (result.type != ResultType.done && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            result.type == ResultType.noAppToOpen
                                ? 'No app on this phone can open $name.'
                                : 'Could not open $name: ${result.message}',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Share'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    SharePlus.instance.share(
                      ShareParams(
                        files: [
                          XFile(path, mimeType: DocKind.mimeTypeOf(path)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A whole screen saying DocHelper cannot open a document yet, for when one
/// arrives from another app with no other screen to show it on.
class UnsupportedDocumentScreen extends StatelessWidget {
  const UnsupportedDocumentScreen({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final kind = DocKind.ofPath(path);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.cardBackground,
        foregroundColor: colors.textPrimary,
        title: Text(documentDisplayName(path)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(kind.icon, size: 64, color: kind.color),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.more_horiz_rounded),
                label: const Text('What can I do with this file?'),
                onPressed: () => showUnsupportedFileSheet(context, path),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen for a document handed over by another app.
Widget externalDocumentScreen(String path) =>
    DocumentRouter.screenFor(path) ?? UnsupportedDocumentScreen(path: path);
