import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/pdf_service.dart';
import '../services/notification_service.dart';
import '../providers/theme_provider.dart';
import 'pdf_viewer_screen.dart';

/// Preview screen for merged or converted PDFs before saving.
/// Shows page thumbnails with Save and Back actions.
class PdfPreviewScreen extends StatefulWidget {
  const PdfPreviewScreen({
    super.key,
    required this.filePaths,
    required this.sourceType,
    this.onSaved,
    this.pageCount,
  });

  final List<String> filePaths;
  final PdfPreviewSourceType sourceType;
  final VoidCallback? onSaved;
  final int? pageCount;

  @override
  State<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

enum PdfPreviewSourceType { merge, convert }

class _PdfPreviewScreenState extends State<PdfPreviewScreen> {
  List<Uint8List?> _previews = [];
  double _previewAspectRatio = 0.7;
  bool _isLoading = true;
  bool _isSaving = false;
  int _currentFileIndex = 0;

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  @override
  void initState() {
    super.initState();
    _loadPreviews();
  }

  Future<void> _loadPreviews([int? fileIndex]) async {
    if (widget.filePaths.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }
    final idx = fileIndex ?? _currentFileIndex;
    setState(() {
      _isLoading = true;
      _currentFileIndex = idx;
    });
    try {
      final path = widget.filePaths[idx];
      final results = await Future.wait([
        PdfService.loadPagePreviews(path),
        PdfService.getFirstPageAspectRatio(path),
      ]);
      final previews = results[0] as List<Uint8List?>;
      final aspectRatio = results[1] as double?;
      if (mounted) {
        setState(() {
          _previews = previews;
          _previewAspectRatio = aspectRatio?.clamp(0.5, 1.5) ?? 0.7;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading previews: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _onSave() async {
    final themeProvider = context.read<ThemeProvider>();
    setState(() => _isSaving = true);

    try {
      List<String>? autoSavedPaths;
      if (themeProvider.autoSave) {
        autoSavedPaths = [];
        for (int i = 0; i < widget.filePaths.length; i++) {
          final prefix = widget.sourceType == PdfPreviewSourceType.merge
              ? 'merged_${i + 1}'
              : 'scanned';
          final saved =
              await themeProvider.autoSaveFile(widget.filePaths[i], prefix);
          if (saved != null) autoSavedPaths.add(saved);
        }
      }

      if (themeProvider.notifications) {
        if (widget.sourceType == PdfPreviewSourceType.merge) {
          NotificationService().showMergeComplete(
              widget.pageCount ?? _previews.length);
        } else {
          NotificationService().showScanComplete(
              widget.pageCount ?? _previews.length);
        }
      }

      widget.onSaved?.call();

      if (mounted) {
        _showSuccessDialog(autoSavedPaths);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    }
  }

  void _showSuccessDialog(List<String>? autoSavedPaths) {
    final themeProvider = context.read<ThemeProvider>();
    final saveLocation = themeProvider.saveLocation;
    final hasAutoSaved =
        autoSavedPaths != null && autoSavedPaths.isNotEmpty;
    final shareFiles = hasAutoSaved ? autoSavedPaths! : widget.filePaths;
    final nav = Navigator.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 28),
            const SizedBox(width: 10),
            Text('Success!', style: TextStyle(color: _colors.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.sourceType == PdfPreviewSourceType.merge
                  ? '${widget.filePaths.length} PDF${widget.filePaths.length > 1 ? 's' : ''} merged successfully!'
                  : '${widget.pageCount ?? _previews.length} page(s) converted to PDF!',
              style: TextStyle(color: _colors.textSecondary),
            ),
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
                    const Icon(Icons.folder_rounded,
                        color: Color(0xFF4CAF50), size: 18),
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
              nav.pop(true);
            },
            child: Text('Close', style: TextStyle(color: _colors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              nav.pop(true);
              Share.shareXFiles(
                shareFiles.map((p) => XFile(p)).toList(),
                text: widget.sourceType == PdfPreviewSourceType.merge
                    ? 'Merged PDFs'
                    : 'Scanned PDF',
              );
            },
            child: const Text('Share', style: TextStyle(color: Color(0xFF00D9FF))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              final path = shareFiles.first;
              final name = path.split(RegExp(r'[/\\]')).last;
              nav.pushReplacement(
                MaterialPageRoute(
                  builder: (_) => PdfViewerScreen(
                    pdfPath: path,
                    title: name,
                  ),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
            ),
            child: Text(
              shareFiles.length == 1 ? 'Open' : 'View first PDF',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _onBack() {
    HapticFeedback.lightImpact();
    for (final path in widget.filePaths) {
      unawaited(File(path).delete().catchError((_) {}));
    }
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        title: Text(
          widget.filePaths.length > 1
              ? 'Preview PDF (${_currentFileIndex + 1}/${widget.filePaths.length})'
              : widget.sourceType == PdfPreviewSourceType.merge
                  ? 'Preview merged PDF'
                  : 'Preview PDF',
          style: TextStyle(color: _colors.textPrimary),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.visibility_rounded),
            onPressed: _isLoading
                ? null
                : () {
                    final path = widget.filePaths[_currentFileIndex];
                    final name = path.split(RegExp(r'[/\\]')).last;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PdfViewerScreen(
                          pdfPath: path,
                          title: name,
                        ),
                      ),
                    );
                  },
            color: _colors.textPrimary,
            tooltip: 'View PDF',
          ),
          if (widget.filePaths.length > 1) ...[
            if (_currentFileIndex > 0)
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _isLoading
                    ? null
                    : () => _loadPreviews(_currentFileIndex - 1),
                color: _colors.textPrimary,
              ),
            if (_currentFileIndex < widget.filePaths.length - 1)
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _isLoading
                    ? null
                    : () => _loadPreviews(_currentFileIndex + 1),
                color: _colors.textPrimary,
              ),
          ],
        ],
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _isSaving ? null : _onBack,
          color: _colors.textPrimary,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(
                          color: Color(0xFFE94560),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Loading preview...',
                          style: TextStyle(color: _colors.textSecondary),
                        ),
                      ],
                    ),
                  )
                : _previews.isEmpty
                    ? Center(
                        child: Text(
                          'No pages to preview',
                          style: TextStyle(color: _colors.textSecondary),
                        ),
                      )
                    : _buildPreviewsGrid(),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildPreviewsGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: _previewAspectRatio,
      ),
      itemCount: _previews.length,
      itemBuilder: (context, index) {
        final bytes = _previews[index];
        return Container(
          decoration: BoxDecoration(
            color: _colors.cardBackground,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: _colors.shadowColor,
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: bytes != null
                ? Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                  )
                : Center(
                    child: Icon(
                      Icons.picture_as_pdf,
                      size: 48,
                      color: _colors.textTertiary,
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        boxShadow: [
          BoxShadow(
            color: _colors.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isSaving ? null : _onBack,
                icon: const Icon(Icons.arrow_back, size: 20),
                label: const Text('Back'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _colors.textSecondary,
                  side: BorderSide(color: _colors.divider),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _onSave,
                icon: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save, size: 20),
                label: Text(_isSaving ? 'Saving...' : 'Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE94560),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
