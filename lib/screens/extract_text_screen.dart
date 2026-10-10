import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';

/// Extract the text layer, page by page.
///
/// Text comes from the native core's content-stream parser (encodings,
/// ToUnicode CMaps, CID fonts). A scanned page has no text layer and comes
/// back empty; for those pages the screen offers to read the text with OCR
/// instead, and says which pages it read that way.
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

  /// Pages (0-based) whose text was read by OCR rather than extracted.
  final Set<int> _recognizedPages = {};

  /// Whether OCR has been run here, so an image-only document that still
  /// has no text can say that it was tried.
  bool _recognitionTried = false;

  /// Pages read and the total while OCR runs; null otherwise.
  (int, int)? _ocrProgress;
  bool _ocrCancelRequested = false;

  /// Pages (0-based) with no text to show.
  List<int> get _emptyPages => [
    for (var i = 0; i < _pages.length; i++)
      if (_pages[i].trim().isEmpty) i,
  ];

  bool get _allEmpty =>
      _pages.isNotEmpty && _emptyPages.length == _pages.length;

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

  /// Read the pages that have no text layer with OCR, and show what it
  /// found in their place. Pages read before a cancel are kept, and the
  /// rest can be read later.
  Future<void> _recognize() async {
    final targets = _emptyPages;
    if (targets.isEmpty || _ocrProgress != null) return;
    setState(() {
      _ocrProgress = (0, targets.length);
      _ocrCancelRequested = false;
    });
    List<PdfOcrPage> results;
    var finished = true;
    try {
      results = await PdfCoreService.recognizeText(
        widget.pdfPath,
        password: widget.password,
        pages: [for (final index in targets) index + 1],
        onProgress: (done, total) {
          if (mounted) setState(() => _ocrProgress = (done, total));
        },
        isCancelled: () => _ocrCancelRequested || !mounted,
      );
    } on OcrCancelled catch (e) {
      results = e.pages;
      finished = false;
    } catch (e) {
      if (mounted) {
        setState(() {
          _ocrProgress = null;
          _error = PdfCoreService.describeError(e);
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      for (final page in results) {
        final text = page.text.trim();
        if (text.isEmpty) continue;
        _pages[page.page - 1] = text;
        _recognizedPages.add(page.page - 1);
      }
      _recognitionTried = _recognitionTried || finished;
      _ocrProgress = null;
    });
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
      body: _ocrProgress != null
          ? _buildRecognizing()
          : _isLoading
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
                if (_error == null && !_allEmpty) _buildOcrBanner(),
                Expanded(
                  child: _error != null
                      ? _buildEmptyState()
                      : _allEmpty
                      ? _buildNoTextState()
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
                if (!_isLoading && _error == null && !_allEmpty) _buildStats(),
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

  /// A scanned document: nothing to extract until OCR has read it.
  Widget _buildNoTextState() {
    final canRecognize = PdfCoreService.isAvailable && !_recognitionTried;
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
              _recognitionTried
                  ? 'No readable text was found. Text recognition reads '
                        'printed text; handwriting and text inside photos are '
                        'not recognized.'
                  : 'No text layer found. This looks like a scanned '
                        'document, so its text has to be recognized before it '
                        'can be read.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _colors.textSecondary, fontSize: 14),
            ),
            if (canRecognize) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _recognize,
                icon: const Icon(Icons.manage_search_rounded),
                label: Text(
                  _pages.length == 1
                      ? 'Recognize text'
                      : 'Recognize text on ${_pages.length} pages',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecognizing() {
    final (done, total) = _ocrProgress!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: LinearProgressIndicator(
                value: total == 0 ? null : done / total,
                color: _accent,
                backgroundColor: _accent.withValues(alpha: 0.15),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _ocrCancelRequested
                  ? 'Stopping after this page…'
                  : 'Recognizing text: page ${done < total ? done + 1 : total} '
                        'of $total…',
              style: TextStyle(color: _colors.textSecondary),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _ocrCancelRequested
                  ? null
                  : () => setState(() => _ocrCancelRequested = true),
              child: Text(
                'Stop',
                style: TextStyle(color: _colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Above text that is partly extracted: offers OCR for the pages that have
  /// none, or says which pages it read, since recognized text can be wrong
  /// where extracted text cannot.
  Widget _buildOcrBanner() {
    final empty = _emptyPages.length;
    final String message;
    Widget? action;
    if (_recognizedPages.isNotEmpty) {
      final count = _recognizedPages.length;
      message =
          'Text on $count ${count == 1 ? 'page' : 'pages'} was '
          'recognized from the scan. Check names and numbers before relying '
          'on them.';
    } else if (empty > 0 && !_recognitionTried && PdfCoreService.isAvailable) {
      message =
          '$empty ${empty == 1 ? 'page has' : 'pages have'} no text layer, '
          'probably scanned.';
      action = TextButton(
        onPressed: _recognize,
        child: const Text('Recognize', style: TextStyle(color: _accent)),
      );
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      key: const ValueKey('ocr-banner'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16, 10, action == null ? 16 : 6, 10),
      color: _accent.withValues(alpha: 0.08),
      child: Row(
        children: [
          const Icon(Icons.manage_search_rounded, color: _accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
            ),
          ),
          ?action,
        ],
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
