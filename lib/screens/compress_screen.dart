import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';

import '../providers/theme_provider.dart';
import '../services/operation_ad_policy.dart';
import '../services/pdf_core_service.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/pdf_result_dialog.dart';

/// Make a smaller copy of a PDF: its pictures at a lower resolution and
/// quality, everything else packed tighter. The original is kept, since a
/// signed document's signatures do not survive the rewrite.
class CompressScreen extends StatefulWidget {
  const CompressScreen({super.key, required this.pdfPath, this.password = ''});

  final String pdfPath;
  final String password;

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  static const Color _accent = Color(0xFF26A69A);

  AppColors _colors = AppColors(false);
  PdfCompressLevel _level = PdfCompressLevel.recommended;
  bool _working = false;
  String? _error;
  int? _size;

  static const _levels = <(PdfCompressLevel, String, String)>[
    (PdfCompressLevel.light, 'Light', 'Print quality. Pictures stay sharp.'),
    (
      PdfCompressLevel.recommended,
      'Recommended',
      'Good on screen, much smaller.',
    ),
    (PdfCompressLevel.strong, 'Strong', 'Smallest file. Pictures look softer.'),
  ];

  @override
  void initState() {
    super.initState();
    File(widget.pdfPath).length().then((v) {
      if (mounted) setState(() => _size = v);
    }, onError: (_) {});
  }

  Future<void> _compress() async {
    if (!PdfCoreService.isAvailable) {
      setState(
        () => _error =
            'The native PDF core is not built, so compressing is unavailable.',
      );
      return;
    }
    final title = stripPdfExtension(getPdfDisplayTitle(widget.pdfPath));
    final base = title == 'View PDF' ? 'Document' : title;
    final name = await askPdfName(
      context: context,
      initialName: '$base (compressed)',
      confirmLabel: 'Compress',
      accent: _accent,
    );
    if (name == null || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final (output, report) = await PdfCoreService.compress(
        widget.pdfPath,
        _level,
        password: widget.password,
        fileName: name,
      );
      if (!mounted) return;
      final message = report.shrank
          ? 'From ${formatFileSize(report.bytesBefore)} to ${formatFileSize(report.bytesAfter)}, '
                '${(report.saving * 100).round()}% smaller.'
          : 'This PDF is already compact, so the copy is the same size.';
      await showPdfResultDialog(
        context: context,
        filePaths: [output],
        accent: _accent,
        operation: PdfOperation.compress,
        message: message,
      );
      if (mounted) Navigator.pop(context, output);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = PdfCoreService.describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final size = _size;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        foregroundColor: _colors.textPrimary,
        title: const Text('Compress PDF'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            size == null
                ? getPdfDisplayTitle(widget.pdfPath)
                : '${getPdfDisplayTitle(widget.pdfPath)} · ${formatFileSize(size)}',
            style: TextStyle(color: _colors.textSecondary),
          ),
          const SizedBox(height: 16),
          for (final (level, title, detail) in _levels)
            Card(
              color: _colors.cardBackground,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: _level == level ? _accent : _colors.divider,
                  width: _level == level ? 2 : 1,
                ),
              ),
              child: ListTile(
                key: ValueKey('compress-${level.name}'),
                leading: Icon(
                  _level == level
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: _level == level ? _accent : _colors.textTertiary,
                ),
                onTap: _working ? null : () => setState(() => _level = level),
                title: Text(
                  title,
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  detail,
                  style: TextStyle(color: _colors.textSecondary),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'A new copy is made; the original stays as it is. '
            'A digitally signed PDF loses its signatures in the copy.',
            style: TextStyle(color: _colors.textTertiary, fontSize: 12.5),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFE53935))),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('compress-run'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _working ? null : _compress,
            icon: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.compress_rounded),
            label: Text(_working ? 'Compressing…' : 'Compress'),
          ),
        ],
      ),
    );
  }
}
