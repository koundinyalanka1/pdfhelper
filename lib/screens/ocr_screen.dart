import 'package:flutter/material.dart';

import '../providers/theme_provider.dart';
import '../services/ads_service.dart';
import '../services/pdf_core_service.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/pdf_result_dialog.dart';

/// Make a scanned PDF searchable.
///
/// The engine's on-device OCR reads the text on each scanned page, and a copy
/// is saved with that text as an invisible layer over the page images. The
/// pages look exactly as they did; their text can now be found, selected,
/// copied and extracted, here and in any other PDF app.
///
/// Pages are read one at a time rather than in one native call, so the
/// screen can show which page it is on and stop between pages.
class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key, required this.pdfPath, this.password = ''});

  final String pdfPath;

  /// Password already used to open the document, if any.
  final String password;

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  static const Color _accent = Color(0xFFE94560);

  bool _isWorking = false;
  bool _cancelRequested = false;

  /// Pages read so far and the total, once the document is open.
  (int, int)? _progress;

  /// Why the last run wrote nothing, when it finished without a copy to show.
  String? _outcome;
  String? _error;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  Future<void> _start() async {
    if (!PdfCoreService.isAvailable) {
      setState(() {
        _error =
            'The native PDF core is not built, so text recognition is '
            'unavailable. Run ./scripts/build_pdf_core.sh.';
      });
      return;
    }
    final title = stripPdfExtension(getPdfDisplayTitle(widget.pdfPath));
    // An opened file whose provider gave no name is titled generically.
    final base = title == 'View PDF' ? 'Document' : title;
    final fileName = await askPdfName(
      context: context,
      initialName: '$base (searchable)',
      confirmLabel: 'Recognize',
      accent: _accent,
    );
    if (fileName == null || !mounted) return;

    setState(() {
      _isWorking = true;
      _cancelRequested = false;
      _progress = null;
      _outcome = null;
      _error = null;
    });
    try {
      final copy = await PdfCoreService.makeSearchable(
        widget.pdfPath,
        password: widget.password,
        fileName: fileName,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
        isCancelled: () => _cancelRequested || !mounted,
      );
      if (!mounted) return;
      final output = copy.outputPath;
      if (output == null) {
        setState(() {
          _isWorking = false;
          _outcome = _nothingWritten(copy);
        });
        return;
      }
      await showPdfResultDialog(
        context: context,
        filePaths: [output],
        accent: _accent,
        operation: PdfOperation.ocr,
        title: 'Text recognized',
        message: _summary(copy),
      );
      if (mounted) Navigator.pop(context, output);
    } on OcrCancelled {
      if (mounted) setState(() => _isWorking = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWorking = false;
          _error = PdfCoreService.describeError(e);
        });
      }
    }
  }

  void _cancel() {
    if (_isWorking) setState(() => _cancelRequested = true);
  }

  String _summary(SearchableCopy copy) {
    final parts = [
      'Recognized text on ${_pages(copy.recognized)}. It can now be '
          'searched, selected and copied in any PDF app.',
      if (copy.hadText > 0)
        '${_pages(copy.hadText, capital: true)} already had text and '
            '${copy.hadText == 1 ? 'was' : 'were'} left as '
            '${copy.hadText == 1 ? 'it was' : 'they were'}.',
      if (copy.blank > 0)
        'No readable text was found on ${_pages(copy.blank)}.',
      if (widget.password.isNotEmpty)
        'The copy opens with the same password as the original.',
    ];
    return parts.join(' ');
  }

  String _nothingWritten(SearchableCopy copy) {
    if (copy.pages.isNotEmpty && copy.hadText == copy.pages.length) {
      return 'Every page already has text, so there was nothing to '
          'recognize. Search, selection and Extract text work on this PDF '
          'as it is.';
    }
    return 'No readable text was found, so no copy was saved. Text '
        'recognition reads printed text; handwriting and text inside photos '
        'are not recognized.';
  }

  static String _pages(int count, {bool capital = false}) {
    final word = count == 1 ? 'page' : 'pages';
    if (count == 1) return capital ? 'One $word' : 'one $word';
    return '$count $word';
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      // Going back while pages are being read stops the run first, rather
      // than leaving it working on behind a screen that has gone.
      canPop: !_isWorking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: _colors.background,
        appBar: AppBar(
          backgroundColor: _colors.cardBackground,
          elevation: 0,
          iconTheme: IconThemeData(color: _colors.textPrimary),
          title: Text(
            'Recognize text',
            style: TextStyle(color: _colors.textPrimary, fontSize: 17),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            _buildBanner(),
            const SizedBox(height: 20),
            _buildNotes(),
            if (_outcome != null) ...[
              const SizedBox(height: 20),
              _buildOutcome(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(color: Colors.red.shade400, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            if (_isWorking) _buildProgress() else _buildStartButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.manage_search_rounded, color: _accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Reads the text on scanned pages and saves a copy you can '
              'search, select and copy from. The pages look exactly the same, '
              'and the original file is left untouched.',
              style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotes() {
    Widget note(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: _colors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: _colors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        note(
          Icons.translate_rounded,
          'Reads printed text in English and other languages written in the '
          'Latin alphabet. Handwriting is not recognized.',
        ),
        note(
          Icons.text_snippet_outlined,
          'Pages that already have text are left as they are.',
        ),
        note(
          Icons.phonelink_lock_rounded,
          'Everything runs on this device. Nothing is uploaded.',
        ),
      ],
    );
  }

  Widget _buildOutcome() {
    return Container(
      key: const ValueKey('ocr-outcome'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: _colors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _outcome!,
              style: TextStyle(color: _colors.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final progress = _progress;
    final String label;
    double? value;
    if (_cancelRequested) {
      label = 'Stopping after this page…';
    } else if (progress == null) {
      label = 'Opening the document…';
    } else {
      final (done, total) = progress;
      value = total == 0 ? null : done / total;
      label = done < total
          ? 'Reading page ${done + 1} of $total…'
          : 'Saving the searchable copy…';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: LinearProgressIndicator(
              value: value,
              color: _accent,
              backgroundColor: _accent.withValues(alpha: 0.15),
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: _colors.textSecondary, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _cancelRequested ? null : _cancel,
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: _cancelRequested
                        ? _colors.textTertiary
                        : _colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: _start,
        icon: const Icon(Icons.manage_search_rounded),
        label: const Text('Recognize text'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
