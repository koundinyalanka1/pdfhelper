import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdfrx/pdfrx.dart';
import '../services/pdf_service.dart';
import '../providers/theme_provider.dart';
import 'home_screen.dart';

/// Full-featured PDF viewer with zoom, pan, and page navigation.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.pdfPath,
    this.title,
  });

  final String pdfPath;
  final String? title;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();
  int _currentPage = 1;
  int _totalPages = 0;

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  String get _fileName =>
      widget.title ?? widget.pdfPath.split(RegExp(r'[/\\]')).last;

  void _onViewerReady(PdfDocument document, PdfViewerController ctrl) {
    if (mounted) {
      setState(() {
        _totalPages = ctrl.pageCount;
        _currentPage = ctrl.pageNumber ?? 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!File(widget.pdfPath).existsSync()) {
      return Scaffold(
        backgroundColor: _colors.background,
        appBar: AppBar(
          title: Text(_fileName, style: TextStyle(color: _colors.textPrimary)),
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const HomeScreen()),
            ),
            color: _colors.textPrimary,
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: _colors.textTertiary),
              const SizedBox(height: 16),
              Text(
                'File not found',
                style: TextStyle(color: _colors.textSecondary, fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        title: Text(
          _fileName,
          style: TextStyle(color: _colors.textPrimary, fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          ),
          color: _colors.textPrimary,
        ),
        actions: [
          if (_totalPages > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () {
              Share.shareXFiles([XFile(widget.pdfPath)], text: 'PDF');
            },
            color: _colors.textPrimary,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: () => PdfService.openPdf(widget.pdfPath),
            color: _colors.textPrimary,
          ),
        ],
      ),
      body: PdfViewer.file(
        widget.pdfPath,
        controller: _controller,
        params: PdfViewerParams(
          onViewerReady: _onViewerReady,
          onPageChanged: (pageNumber) {
            if (pageNumber != null && mounted) {
              setState(() => _currentPage = pageNumber);
            }
          },
          // fitZoom = whole page visible; coverZoom = page fills view (may crop)
          calculateInitialZoom: (_, __, fitZoom, ___) => fitZoom,
        ),
      ),
    );
  }
}
