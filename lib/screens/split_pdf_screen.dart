import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/ads_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_service.dart';
import '../services/notification_service.dart';
import '../providers/theme_provider.dart';
import '../utils/file_naming.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/recent_pdfs_strip.dart';
import 'pdf_viewer_screen.dart';

class SplitPdfScreen extends StatefulWidget {
  const SplitPdfScreen({super.key, this.initialPdfPath});

  final String? initialPdfPath;

  @override
  State<SplitPdfScreen> createState() => _SplitPdfScreenState();
}

class _SplitPdfScreenState extends State<SplitPdfScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String? _selectedFilePath;
  String? _selectedFileName;
  int _totalPages = 0;
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController = TextEditingController();
  String _splitMode = 'pages';
  final List<({int start, int end})> _ranges = [];
  bool _isProcessing = false;
  bool _isLoadingPreviews = false;
  double _splitProgress = 0.0;
  String _splitStatus = '';

  // Page thumbnails, rendered on demand by the native rasterizer.
  List<Uint8List?> _pagePreviews = [];
  Set<int> _selectedPages = {};
  double _firstPageAspectRatio = 0.7;
  int _previewsRendered = 0;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  /// Page-thumbnail picking is only offered for smaller documents (rendering
  /// 100+ previews is slow and memory-hungry), and only while the user has
  /// actually chosen that mode — previously it silently overrode the
  /// "Page Range" and "Extract All" modes for every PDF under 30 pages,
  /// making them unreachable.
  bool get _canUsePreviewMode =>
      _totalPages > 0 && _totalPages < _previewModeMaxPages;
  bool get _usePreviewMode => _canUsePreviewMode && _splitMode == 'pages';

  static const int _previewModeMaxPages = 30;

  @override
  void initState() {
    super.initState();
    if (widget.initialPdfPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadPdfFromPath(widget.initialPdfPath!);
      });
    }
  }

  Future<void> _loadPdfFromPath(String path) async {
    try {
      final int pageCount = await PdfService.getPageCount(path);
      final String name = path.split(RegExp(r'[/\\]')).last;

      if (mounted) {
        setState(() {
          _selectedFilePath = path;
          _selectedFileName = name;
          _totalPages = pageCount;
          _fromController.clear();
          _toController.clear();
          _ranges.clear();
          _selectedPages.clear();
          _pagePreviews = [];
        });
        if (_usePreviewMode) {
          await _loadPagePreviews(path);
        } else if (!_canUsePreviewMode && _splitMode == 'pages') {
          // Too many pages to thumbnail — fall back to range entry.
          setState(() => _splitMode = 'range');
        }
      }
    } catch (e) {
      debugPrint('Error loading PDF from intent: $e');
    }
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  Future<void> _pickPdfFile() async {
    try {
      final PlatformFile? result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result?.path != null) {
        final String path = result!.path!;
        final int pageCount = await PdfService.getPageCount(path);

        setState(() {
          _selectedFilePath = path;
          _selectedFileName = result.name;
          _totalPages = pageCount;
          _fromController.clear();
          _toController.clear();
          _ranges.clear();
          _selectedPages.clear();
          _pagePreviews = [];
        });

        // Render thumbnails only when the page-picker mode is active.
        if (_usePreviewMode) {
          await _loadPagePreviews(path);
        } else if (!_canUsePreviewMode && _splitMode == 'pages') {
          setState(() => _splitMode = 'range');
        }
      }
    } catch (e) {
      _showSnackBar('Error selecting file: $e', isError: true);
    }
  }

  Future<void> _loadPagePreviews(String path) async {
    setState(() {
      _isLoadingPreviews = true;
      _previewsRendered = 0;
    });

    try {
      final ratio = await PdfRaster.aspectRatio(path);
      final previews = await PdfRaster.renderAllPages(
        path,
        pageCount: _totalPages,
        onProgress: (done, total) {
          if (mounted) setState(() => _previewsRendered = done);
        },
        // Abandon the render loop if the user moves on.
        isCancelled: () => !mounted || _selectedFilePath != path,
      );

      if (mounted) {
        setState(() {
          _pagePreviews = previews;
          _firstPageAspectRatio = ratio ?? 0.7;
          _isLoadingPreviews = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading previews: $e');
      if (mounted) {
        setState(() => _isLoadingPreviews = false);
        _showSnackBar('Could not load page previews', isError: true);
      }
    }
  }

  void _togglePageSelection(int pageIndex) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_selectedPages.contains(pageIndex)) {
        _selectedPages.remove(pageIndex);
      } else {
        _selectedPages.add(pageIndex);
      }
    });
  }

  void _selectAllPages() {
    HapticFeedback.lightImpact();
    setState(() {
      if (_selectedPages.length == _totalPages) {
        _selectedPages.clear();
      } else {
        _selectedPages = Set.from(List.generate(_totalPages, (i) => i));
      }
    });
  }

  void _addRange() {
    final from = int.tryParse(_fromController.text) ?? 1;
    final to = int.tryParse(_toController.text) ?? _totalPages;
    final start = from.clamp(1, _totalPages);
    final end = to.clamp(1, _totalPages);
    if (start <= end) {
      setState(() {
        _ranges.add((start: start, end: end));
        _fromController.clear();
        _toController.clear();
      });
    } else {
      _showSnackBar('Invalid range: From must be ≤ To', isError: true);
    }
  }

  void _removeRange(int index) {
    setState(() => _ranges.removeAt(index));
  }

  Future<void> _splitPdf() async {
    if (_selectedFilePath == null) return;

    // Named before the work starts, like every other tool. Outputs that come
    // in sets get the page number or range appended to this title.
    final fileName = await askPdfName(
      context: context,
      initialName: defaultPdfName(_usePreviewMode ? 'Extracted' : 'Split'),
      confirmLabel: _usePreviewMode ? 'Extract' : 'Split',
      accent: const Color(0xFFE94560),
    );
    if (fileName == null || !mounted) return;

    setState(() {
      _isProcessing = true;
      _splitProgress = 0.0;
      _splitStatus = 'Preparing...';
    });

    try {
      if (_usePreviewMode) {
        // Extract selected pages
        if (_selectedPages.isEmpty) {
          _showSnackBar('Please select at least one page', isError: true);
          setState(() => _isProcessing = false);
          return;
        }

        final sortedPages = _selectedPages.toList()..sort();

        setState(() {
          _splitProgress = 0.2;
          _splitStatus =
              'Extracting ${sortedPages.length} page${sortedPages.length > 1 ? 's' : ''}...';
        });

        // OPTIMIZED: Extract all selected pages at once using cached bytes
        final themeProvider = context.read<ThemeProvider>();
        final String? outputPath = await PdfService.extractPagesFromFile(
          _selectedFilePath!,
          sortedPages, // Already 0-based
          fileName: fileName,
        );

        setState(() => _splitProgress = 0.9);

        if (outputPath != null) {
          // Auto-save if enabled
          String? autoSavedPath;
          if (themeProvider.autoSave) {
            autoSavedPath = await themeProvider.autoSaveFile(
              outputPath,
              'extracted',
              fileName: fileName,
            );
          }
          // Show notification if enabled
          if (themeProvider.notifications) {
            NotificationService().showSplitComplete(sortedPages.length);
          }
          setState(() => _splitProgress = 1.0);
          _showSuccessDialog([
            outputPath,
          ], autoSavedPath != null ? [autoSavedPath] : null);
        } else {
          _showSnackBar('Failed to extract pages', isError: true);
        }
      } else if (_splitMode == 'range') {
        final themeProvider = context.read<ThemeProvider>();
        List<({int start, int end})> rangesToUse = [];

        if (_ranges.isNotEmpty) {
          rangesToUse = List.from(_ranges);
        } else {
          final fromPage = int.tryParse(_fromController.text) ?? 1;
          final toPage = int.tryParse(_toController.text) ?? _totalPages;
          if (fromPage < 1 || toPage > _totalPages || fromPage > toPage) {
            _showSnackBar('Invalid page range', isError: true);
            setState(() => _isProcessing = false);
            return;
          }
          rangesToUse = [(start: fromPage, end: toPage)];
        }

        setState(() {
          _splitProgress = 0.3;
          _splitStatus = 'Extracting ${rangesToUse.length} range(s)...';
        });

        final outputPaths = await PdfService.splitRangesFromFile(
          _selectedFilePath!,
          rangesToUse,
          fileName: fileName,
        );

        setState(() => _splitProgress = 0.9);

        if (outputPaths.isNotEmpty) {
          List<String>? autoSavedPaths;
          if (themeProvider.autoSave) {
            autoSavedPaths = [];
            for (int i = 0; i < outputPaths.length; i++) {
              final saved = await themeProvider.autoSaveFile(
                outputPaths[i],
                'split_${i + 1}',
                fileName:
                    '$fileName ${rangesToUse[i].start}-${rangesToUse[i].end}',
              );
              if (saved != null) autoSavedPaths.add(saved);
            }
          }
          if (themeProvider.notifications) {
            NotificationService().showSplitComplete(outputPaths.length);
          }
          setState(() => _splitProgress = 1.0);
          _showSuccessDialog(outputPaths, autoSavedPaths);
        } else {
          _showSnackBar('Failed to split PDF', isError: true);
        }
      } else {
        // Split all pages - use cached bytes
        setState(() {
          _splitProgress = 0.2;
          _splitStatus = 'Extracting $_totalPages pages...';
        });

        final themeProvider = context.read<ThemeProvider>();
        final List<String> outputPaths = await PdfService.splitAllPagesFromFile(
          _selectedFilePath!,
          pageCount: _totalPages,
          fileName: fileName,
        );

        setState(() => _splitProgress = 0.9);

        if (outputPaths.isNotEmpty) {
          // Auto-save all pages if enabled
          List<String>? autoSavedPaths;
          if (themeProvider.autoSave) {
            autoSavedPaths = [];
            for (int i = 0; i < outputPaths.length; i++) {
              final saved = await themeProvider.autoSaveFile(
                outputPaths[i],
                'page_${i + 1}',
                fileName: '$fileName ${i + 1}',
              );
              if (saved != null) autoSavedPaths.add(saved);
            }
          }
          // Show notification if enabled
          if (themeProvider.notifications) {
            NotificationService().showSplitComplete(outputPaths.length);
          }
          setState(() => _splitProgress = 1.0);
          _showSuccessDialog(outputPaths, autoSavedPaths);
        } else {
          _showSnackBar('Failed to split PDF', isError: true);
        }
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() {
        _isProcessing = false;
        _splitProgress = 0.0;
      });
    }
  }

  void _showSuccessDialog(
    List<String> filePaths, [
    List<String>? autoSavedPaths,
  ]) {
    // Clear selection after success
    setState(() {
      _selectedPages.clear();
    });

    final themeProvider = context.read<ThemeProvider>();
    final saveLocation = themeProvider.saveLocation;
    final hasAutoSaved = autoSavedPaths != null && autoSavedPaths.isNotEmpty;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
              filePaths.length == 1
                  ? 'PDF split successfully!'
                  : '${filePaths.length} pages extracted successfully!',
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
              Navigator.pop(context);
              // Friendliest moment for an interstitial: user is done and not
              // navigating into Share / Viewer.
              AdsService.instance.maybeShowInterstitial(trigger: 'split_close');
            },
            child: Text(
              'Close',
              style: TextStyle(color: _colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // Share auto-saved files if available
              final shareFiles = hasAutoSaved ? autoSavedPaths : filePaths;
              SharePlus.instance.share(
                ShareParams(
                  files: shareFiles.map((p) => XFile(p)).toList(),
                  text: 'Split PDF',
                ),
              );
            },
            child: const Text(
              'Share',
              style: TextStyle(color: Color(0xFFE94560)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final openFile = hasAutoSaved
                  ? autoSavedPaths.first
                  : filePaths.first;
              final name = openFile.split(RegExp(r'[/\\]')).last;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PdfViewerScreen(pdfPath: openFile, title: name),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFC107),
            ),
            child: Text(
              filePaths.length == 1 ? 'Open' : 'View first PDF',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFFFFC107),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Split PDF',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_selectedFilePath != null)
            IconButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PdfViewerScreen(
                    pdfPath: _selectedFilePath!,
                    title: _selectedFileName,
                  ),
                ),
              ),
              icon: const Icon(Icons.visibility_rounded),
              tooltip: 'View PDF',
            ),
          if (_usePreviewMode && _selectedPages.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _selectedPages.clear()),
              child: const Text(
                'Clear',
                style: TextStyle(color: Color(0xFFFFC107)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Upload area (smaller when file is selected)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Semantics(
                label: _selectedFilePath == null
                    ? 'Tap to select a PDF file to split'
                    : 'Change selected PDF file',
                button: true,
                enabled: !_isProcessing,
                child: GestureDetector(
                  onTap: _isProcessing ? null : _pickPdfFile,
                  child: Container(
                    width: double.infinity,
                    height: _selectedFilePath == null ? 140 : 80,
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFFFC107).withValues(alpha: 0.3),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _colors.shadowColor,
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: _selectedFilePath == null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFFFC107,
                                  ).withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.upload_file_rounded,
                                  size: 36,
                                  color: Color(0xFFFFC107),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Tap to select a PDF',
                                style: TextStyle(
                                  color: _colors.textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFFFFC107,
                                    ).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.picture_as_pdf_rounded,
                                    color: Color(0xFFFFC107),
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _selectedFileName!,
                                        style: TextStyle(
                                          color: _colors.textPrimary,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFFFFC107,
                                          ).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          '$_totalPages pages',
                                          style: const TextStyle(
                                            color: Color(0xFFFFC107),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedFilePath = null;
                                      _selectedFileName = null;
                                      _totalPages = 0;
                                      _fromController.clear();
                                      _toController.clear();
                                      _ranges.clear();
                                      _selectedPages.clear();
                                      _pagePreviews = [];
                                    });
                                  },
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: _colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
            // Splitting nearly always means the document just being read, so
            // offer it directly. Hidden once a file is chosen: the screen's
            // job from then on is the split itself.
            if (_selectedFilePath == null)
              RecentPdfsStrip(
                onSelected: _loadPdfFromPath,
                accent: const Color(0xFFFFC107),
              ),

            // Content area
            Expanded(
              child: _selectedFilePath == null
                  ? const SizedBox()
                  : Column(
                      children: [
                        _buildModeSelector(),
                        Expanded(
                          child: _usePreviewMode
                              ? _buildPreviewMode()
                              : _buildRangeMode(),
                        ),
                      ],
                    ),
            ),

            // Split button
            if (_selectedFilePath != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    if (_isProcessing) ...[
                      // Progress bar
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _splitStatus,
                                  style: TextStyle(
                                    color: _colors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${(_splitProgress * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Color(0xFFFFC107),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _splitProgress,
                                minHeight: 8,
                                backgroundColor: _colors.cardBackground,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFFFC107),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _isProcessing ? null : _splitPdf,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFC107),
                          disabledBackgroundColor: const Color(
                            0xFFFFC107,
                          ).withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                          elevation: 0,
                        ),
                        child: _isProcessing
                            ? const Text(
                                'Processing...',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.content_cut_rounded,
                                    color: Colors.black87,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _usePreviewMode
                                        ? 'Extract ${_selectedPages.length} Page${_selectedPages.length != 1 ? 's' : ''}'
                                        : _ranges.isNotEmpty
                                        ? 'Split into ${_ranges.length} PDF${_ranges.length > 1 ? 's' : ''}'
                                        : 'Split PDF',
                                    style: const TextStyle(
                                      color: Colors.black87,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Split modes, shown for every document. "Select Pages" is only offered
  /// when the document is small enough to render thumbnails for.
  Widget _buildModeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          if (_canUsePreviewMode) ...[
            Expanded(
              child: _buildModeCard(
                'pages',
                'Select Pages',
                Icons.grid_view_rounded,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _buildModeCard(
              'range',
              'Page Range',
              Icons.horizontal_rule_rounded,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildModeCard('all', 'Extract All', Icons.layers_rounded),
          ),
        ],
      ),
    );
  }

  /// Switch split mode, rendering page thumbnails the first time the user
  /// opens "Select Pages" (rather than eagerly on every file pick).
  void _setSplitMode(String mode) {
    if (_splitMode == mode) return;
    setState(() => _splitMode = mode);
    if (mode == 'pages' &&
        _pagePreviews.isEmpty &&
        !_isLoadingPreviews &&
        _selectedFilePath != null) {
      _loadPagePreviews(_selectedFilePath!);
    }
  }

  Widget _buildPreviewMode() {
    return Column(
      children: [
        // Selection header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Text(
                'Select Pages',
                style: TextStyle(
                  color: _colors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_selectedPages.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFC107).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_selectedPages.length} selected',
                    style: const TextStyle(
                      color: Color(0xFFFFC107),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _selectAllPages,
                child: Text(
                  _selectedPages.length == _totalPages
                      ? 'Deselect All'
                      : 'Select All',
                  style: const TextStyle(
                    color: Color(0xFF00D9FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Hint
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.touch_app_rounded,
                  size: 16,
                  color: Color(0xFF00D9FF),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tap pages to select, then extract them into a new PDF',
                    style: TextStyle(
                      color: const Color(0xFF00D9FF),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Page grid
        Expanded(
          child: _isLoadingPreviews
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Color(0xFFFFC107)),
                      const SizedBox(height: 16),
                      Text(
                        _totalPages > 0
                            ? 'Rendering page $_previewsRendered of $_totalPages...'
                            : 'Loading previews...',
                        style: TextStyle(
                          color: _colors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                    childAspectRatio: _firstPageAspectRatio.clamp(0.5, 1.5),
                  ),
                  itemCount: _totalPages,
                  itemBuilder: (context, index) {
                    final isSelected = _selectedPages.contains(index);
                    final hasPreview =
                        index < _pagePreviews.length &&
                        _pagePreviews[index] != null;

                    return GestureDetector(
                      onTap: () => _togglePageSelection(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFFFFC107)
                                : _colors.divider,
                            width: isSelected ? 3 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFFC107,
                                    ).withValues(alpha: 0.3),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : [
                                  BoxShadow(
                                    color: _colors.shadowColor,
                                    blurRadius: 4,
                                  ),
                                ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Page preview or placeholder
                              if (hasPreview)
                                Image.memory(
                                  _pagePreviews[index]!,
                                  fit: BoxFit.contain,
                                )
                              else
                                Container(
                                  color: _colors.cardBackground,
                                  child: Center(
                                    child: Icon(
                                      Icons.description_outlined,
                                      color: _colors.textTertiary,
                                      size: 40,
                                    ),
                                  ),
                                ),

                              // Selection overlay
                              if (isSelected)
                                Container(
                                  color: const Color(
                                    0xFFFFC107,
                                  ).withValues(alpha: 0.2),
                                ),

                              // Page number badge
                              Positioned(
                                bottom: 4,
                                left: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? const Color(0xFFFFC107)
                                        : Colors.black.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.black87
                                          : Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),

                              // Selection checkmark
                              if (isSelected)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFFFC107),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.check,
                                      color: Colors.black87,
                                      size: 14,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildRangeMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          // Page range input
          if (_splitMode == 'range') ...[
            Text(
              'Select Page Range',
              style: TextStyle(
                color: _colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: _colors.shadowColor,
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _fromController,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: _colors.textPrimary),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        labelText: 'From',
                        labelStyle: TextStyle(color: _colors.textSecondary),
                        hintText: '1',
                        hintStyle: TextStyle(color: _colors.textTertiary),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    color: _colors.textSecondary,
                  ),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: _colors.shadowColor,
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _toController,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: _colors.textPrimary),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        labelText: 'To',
                        labelStyle: TextStyle(color: _colors.textSecondary),
                        hintText: '$_totalPages',
                        hintStyle: TextStyle(color: _colors.textTertiary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_ranges.isNotEmpty) ...[
              Text(
                'Ranges to extract',
                style: TextStyle(
                  color: _colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ...List.generate(_ranges.length, (i) {
                final r = _ranges[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _colors.cardBackground,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_rounded,
                        color: const Color(0xFFFFC107),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Pages ${r.start}-${r.end}',
                          style: TextStyle(
                            color: _colors.textPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _removeRange(i),
                        icon: Icon(
                          Icons.close_rounded,
                          color: Colors.red.shade400,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: _addRange,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(_ranges.isEmpty ? 'Add range' : 'Add another range'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _colors.cardBackground,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: _colors.textSecondary,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _ranges.isEmpty
                          ? 'Enter range above and tap "Add range", or split with a single range'
                          : '${_ranges.length} range(s) will be extracted into separate PDFs',
                      style: TextStyle(
                        color: _colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_splitMode == 'all') ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _colors.cardBackground,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC107).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.info_outline_rounded,
                      color: Color(0xFFFFC107),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Each of the $_totalPages pages will be extracted as a separate PDF file',
                      style: TextStyle(
                        color: _colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeCard(String mode, String label, IconData icon) {
    final isSelected = _splitMode == mode;
    return GestureDetector(
      onTap: () => _setSplitMode(mode),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFFFC107).withValues(alpha: 0.15)
              : _colors.cardBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFFFFC107) : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _colors.shadowColor,
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected
                  ? const Color(0xFFFFC107)
                  : _colors.textSecondary,
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFFFFC107)
                    : _colors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
