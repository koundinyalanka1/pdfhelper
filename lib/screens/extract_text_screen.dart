import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';

/// Extract the text layer, page by page.
///
/// Text comes from the native core's content-stream parser (encodings,
/// ToUnicode CMaps, CID fonts), not from OCR — so a scanned PDF with no text
/// layer legitimately comes back empty, and the screen says so rather than
/// showing a blank page.
class ExtractTextScreen extends StatefulWidget {
  const ExtractTextScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
  });

  final String pdfPath;
  final String password;

  @override
  State<ExtractTextScreen> createState() => _ExtractTextScreenState();
}

class _ExtractTextScreenState extends State<ExtractTextScreen> {
  static const Color _accent = Color(0xFFE94560);

  List<String> _pages = [];
  bool _isLoading = true;
  String? _error;
  int _selectedPage = 0;
  bool _showAllPages = true;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  String get _visibleText => _showAllPages
      ? _pages
            .asMap()
            .entries
            .where((e) => e.value.trim().isNotEmpty)
            .map((e) => '— Page ${e.key + 1} —\n${e.value.trim()}')
            .join('\n\n')
      : (_pages.isEmpty ? '' : _pages[_selectedPage].trim());

  @override
  void initState() {
    super.initState();
    _extract();
  }

  Future<void> _extract() async {
    if (!PdfCoreService.isAvailable) {
      setState(() {
        _isLoading = false;
        _error = 'The native PDF core is not built, so text extraction is '
            'unavailable. Run ./scripts/build_pdf_core.sh.';
      });
      return;
    }
    try {
      final raw = await PdfCoreService.extractText(
        widget.pdfPath,
        password: widget.password,
      );
      // The core separates pages with a form feed.
      final pages = raw.split('\f');
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _isLoading = false;
        if (pages.every((p) => p.trim().isEmpty)) {
          _error = 'No text layer found. This looks like a scanned document — '
              'it needs OCR before its text can be read.';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = PdfCoreService.describeError(e);
        });
      }
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _visibleText));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Text copied')));
    }
  }

  Future<void> _saveAsTxt() async {
    try {
      final name = widget.pdfPath.split(RegExp(r'[/\\]')).last.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final path = await writeTextFile(name, _visibleText);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save text: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final hasText = _visibleText.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        iconTheme: IconThemeData(color: _colors.textPrimary),
        title: Text(
          'Extracted text',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
        actions: [
          if (hasText) ...[
            IconButton(
              tooltip: 'Copy',
              onPressed: _copy,
              icon: Icon(Icons.copy_rounded, color: _colors.textSecondary),
            ),
            IconButton(
              tooltip: 'Save as .txt',
              onPressed: _saveAsTxt,
              icon: Icon(
                Icons.ios_share_rounded,
                color: _colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: _accent),
                  const SizedBox(height: 16),
                  Text(
                    'Reading text layer…',
                    style: TextStyle(color: _colors.textSecondary),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (_pages.length > 1) _buildPageSelector(),
                Expanded(
                  child: _error != null
                      ? _buildEmptyState()
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(
                            _visibleText,
                            style: TextStyle(
                              color: _colors.textPrimary,
                              fontSize: 14,
                              height: 1.55,
                            ),
                          ),
                        ),
                ),
                if (!_isLoading && _error == null) _buildStats(),
              ],
            ),
    );
  }

  Widget _buildPageSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _colors.cardBackground,
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('All pages')),
                ButtonSegment(value: false, label: Text('Single page')),
              ],
              selected: {_showAllPages},
              onSelectionChanged: (s) =>
                  setState(() => _showAllPages = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: _accent.withValues(alpha: 0.18),
                selectedForegroundColor: _accent,
                foregroundColor: _colors.textSecondary,
                textStyle: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
          if (!_showAllPages) ...[
            const SizedBox(width: 12),
            IconButton(
              onPressed: _selectedPage > 0
                  ? () => setState(() => _selectedPage--)
                  : null,
              icon: const Icon(Icons.chevron_left),
              color: _colors.textPrimary,
            ),
            Text(
              '${_selectedPage + 1}/${_pages.length}',
              style: TextStyle(color: _colors.textSecondary, fontSize: 13),
            ),
            IconButton(
              onPressed: _selectedPage < _pages.length - 1
                  ? () => setState(() => _selectedPage++)
                  : null,
              icon: const Icon(Icons.chevron_right),
              color: _colors.textPrimary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 56,
              color: _colors.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: _colors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStats() {
    final words = _visibleText.trim().isEmpty
        ? 0
        : _visibleText.trim().split(RegExp(r'\s+')).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: _colors.cardBackground,
      child: SafeArea(
        top: false,
        child: Text(
          '$words words · ${_visibleText.length} characters · '
          '${_pages.length} page${_pages.length == 1 ? '' : 's'}',
          textAlign: TextAlign.center,
          style: TextStyle(color: _colors.textTertiary, fontSize: 12),
        ),
      ),
    );
  }
}
