import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/selected_pdf_file.dart';
import '../services/pdf_service.dart';
import '../providers/theme_provider.dart';
import '../utils/format_utils.dart';
import 'pdf_preview_screen.dart';
import 'pdf_viewer_screen.dart';

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key, this.initialPdfPath});

  final String? initialPdfPath;

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<List<SelectedPdfFile>> _batches = [[]];
  bool _isProcessing = false;
  double _mergeProgress = 0.0;
  String _mergeStatus = '';

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  @override
  void initState() {
    super.initState();
    if (widget.initialPdfPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _addInitialPdf(widget.initialPdfPath!);
      });
    }
  }

  Future<void> _addInitialPdf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final name = path.split(RegExp(r'[/\\]')).last;
      final size = await file.length();
      final newFile = SelectedPdfFile(
        path: path,
        name: name,
        fileSize: size,
        isLoading: true,
      );
      if (mounted) {
        setState(() {
          if (_batches.isEmpty) _batches.add([]);
          _batches.last.insert(0, newFile);
        });
        _loadPdfDetails(newFile);
      }
    } catch (e) {
      debugPrint('Error adding initial PDF: $e');
    }
  }

  Future<void> _pickPdfFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        // Add all files immediately with loading state
        final List<SelectedPdfFile> newFiles = [];
        for (var file in result.files) {
          if (file.path != null) {
            final newFile = SelectedPdfFile(
              path: file.path!,
              name: file.name,
              fileSize: file.size,
              isLoading: true,
            );
            newFiles.add(newFile);
          }
        }

        setState(() {
          if (_batches.isEmpty) _batches.add([]);
          _batches.last.addAll(newFiles);
        });

        // Load all files in PARALLEL (not sequential)
        for (final file in newFiles) {
          _loadPdfDetails(file);
        }
      }
    } catch (e) {
      _showSnackBar('Error selecting files: $e', isError: true);
    }
  }

  Future<void> _loadPdfDetails(SelectedPdfFile file) async {
    try {
      final Uint8List pdfBytes = await File(file.path).readAsBytes();

      if (mounted) {
        setState(() => file.cachedBytes = pdfBytes);
      }

      final results = await Future.wait([
        PdfService.getPageCountFromBytes(pdfBytes),
        PdfService.generateThumbnail(pdfBytes),
        PdfService.getFirstPageAspectRatioFromBytes(pdfBytes),
      ]);
      final pageCount = results[0] as int;
      final thumbnail = results[1] as Uint8List?;
      final aspectRatio = results[2] as double?;

      if (mounted) {
        setState(() {
          file.pageCount = pageCount;
          file.thumbnail = thumbnail;
          file.aspectRatio = aspectRatio;
          file.isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading PDF: $e');
      if (mounted) {
        setState(() => file.isLoading = false);
      }
    }
  }

  bool get _allFilesLoaded =>
      _batches.every((b) => b.every((f) => !f.isLoading));
  int get _mergeableBatchCount => _batches.where((b) => b.length >= 2).length;
  int get _totalBatchesPages =>
      _batches.fold(0, (sum, b) => sum + b.fold(0, (s, f) => s + f.pageCount));
  int get _totalFileCount => _batches.fold(0, (sum, b) => sum + b.length);
  int get _loadingCount =>
      _batches.fold(0, (sum, b) => sum + b.where((f) => f.isLoading).length);

  void _addNewBatch() {
    setState(() => _batches.add([]));
  }

  void _removeBatch(int batchIndex) {
    setState(() {
      _batches.removeAt(batchIndex);
      if (_batches.isEmpty) _batches.add([]);
    });
  }

  Future<void> _mergePdfs() async {
    if (_mergeableBatchCount == 0) return;

    if (!_allFilesLoaded) {
      _showSnackBar('Please wait for all files to load', isError: false);
      return;
    }

    setState(() {
      _isProcessing = true;
      _mergeProgress = 0.05;
      _mergeStatus = 'Preparing $_mergeableBatchCount batch(es)...';
    });

    try {
      final themeProvider = context.read<ThemeProvider>();
      final outputQuality = themeProvider.outputQuality;

      // Build batch bytes
      final List<List<Uint8List>> batchBytesList = [];
      for (final batch in _batches) {
        if (batch.length < 2) continue;
        final List<Uint8List> bytes = [];
        for (final file in batch) {
          if (file.cachedBytes != null) {
            bytes.add(file.cachedBytes!);
          } else {
            bytes.add(await File(file.path).readAsBytes());
          }
        }
        batchBytesList.add(bytes);
      }

      setState(() {
        _mergeProgress = 0.2;
        _mergeStatus = 'Merging ${batchBytesList.length} batch(es)...';
      });

      final outputPaths = await PdfService.mergePdfsBatch(
        batchBytesList,
        outputQuality: outputQuality,
      );

      setState(() {
        _mergeProgress = 0.8;
        _mergeStatus = 'Saving...';
      });

      if (outputPaths.isNotEmpty) {
        setState(() => _mergeProgress = 1.0);
        if (!mounted) return;
        if (themeProvider.skipPreview && themeProvider.autoSave) {
          // Fast path: save immediately, skip the preview screen.
          await autoSavePdfs(
            themeProvider: themeProvider,
            filePaths: outputPaths,
            sourceType: PdfPreviewSourceType.merge,
            pageCount: _totalBatchesPages,
          );
          if (!mounted) return;
          _showSnackBar(
            'Merged ${outputPaths.length} PDF${outputPaths.length > 1 ? "s" : ""}',
          );
          setState(() => _batches = [[]]);
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfPreviewScreen(
                filePaths: outputPaths,
                sourceType: PdfPreviewSourceType.merge,
                pageCount: _totalBatchesPages,
                onSaved: () {
                  setState(() => _batches = [[]]);
                },
              ),
            ),
          );
        }
      } else {
        _showSnackBar('Failed to merge PDFs', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() {
        _isProcessing = false;
        _mergeProgress = 0.0;
      });
    }
  }

  Widget _buildBatchesList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _batches.length,
      itemBuilder: (context, batchIndex) {
        final batch = _batches[batchIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (batchIndex > 0) const SizedBox(height: 8),
            if (batchIndex > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Batch ${batchIndex + 1}',
                        style: const TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (batch.isEmpty)
                      TextButton.icon(
                        onPressed: () => _removeBatch(batchIndex),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Remove'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                  ],
                ),
              ),
            ...batch.asMap().entries.map((entry) {
              final fileIndex = entry.key;
              final file = entry.value;
              return _buildPdfCard(file, batchIndex, fileIndex);
            }),
          ],
        );
      },
    );
  }

  Widget _buildPdfCard(SelectedPdfFile file, int batchIndex, int fileIndex) {
    return Container(
      key: ValueKey('${file.path}_${batchIndex}_$fileIndex'),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _colors.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFFE94560),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '${fileIndex + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final ratio = file.aspectRatio ?? 0.7;
                const base = 88.0;
                final w = ratio >= 1 ? base : (base * ratio).clamp(50.0, 90.0);
                final h = ratio >= 1 ? (base / ratio).clamp(55.0, 110.0) : base;
                return Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: _isDarkMode
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _colors.divider, width: 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: file.isLoading
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFE94560),
                              ),
                            ),
                          )
                        : file.thumbnail != null
                        ? Image.memory(file.thumbnail!, fit: BoxFit.contain)
                        : Center(
                            child: Icon(
                              Icons.picture_as_pdf_rounded,
                              color: const Color(0xFFE94560),
                              size: 28,
                            ),
                          ),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: TextStyle(
                      color: _colors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE94560).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: file.isLoading
                            ? const Text(
                                'Loading...',
                                style: TextStyle(
                                  color: Color(0xFFE94560),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : Text(
                                '${file.pageCount} page${file.pageCount != 1 ? 's' : ''}',
                                style: const TextStyle(
                                  color: Color(0xFFE94560),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatFileSize(file.fileSize),
                        style: TextStyle(
                          color: _colors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!file.isLoading)
              Semantics(
                label: 'View ${file.name}',
                button: true,
                child: IconButton(
                  onPressed: () async {
                    HapticFeedback.lightImpact();
                    String path = file.path;
                    if (!File(path).existsSync() && file.cachedBytes != null) {
                      try {
                        final dir = await getTemporaryDirectory();
                        final temp = File(
                          '${dir.path}/view_${DateTime.now().millisecondsSinceEpoch}.pdf',
                        );
                        await temp.writeAsBytes(file.cachedBytes!);
                        path = temp.path;
                      } catch (e) {
                        debugPrint('Error writing temp PDF: $e');
                        if (mounted)
                          _showSnackBar('Could not open PDF', isError: true);
                        return;
                      }
                    }
                    if (mounted) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              PdfViewerScreen(pdfPath: path, title: file.name),
                        ),
                      );
                    }
                  },
                  icon: Icon(
                    Icons.visibility_rounded,
                    color: _colors.textSecondary,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),
            Semantics(
              label: 'Remove ${file.name} from batch',
              button: true,
              child: IconButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _batches[batchIndex].removeAt(fileIndex);
                    if (_batches[batchIndex].isEmpty && _batches.length > 1) {
                      _batches.removeAt(batchIndex);
                    }
                  });
                },
                icon: Icon(
                  Icons.close_rounded,
                  color: Colors.red.shade400,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFFE94560),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Semantics(
          label: 'New batch',
          button: true,
          child: IconButton(
            onPressed: _isProcessing ? null : _addNewBatch,
            icon: Text(
              '+B',
              style: TextStyle(
                color: _colors.textTertiary.withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            tooltip: 'New batch',
          ),
        ),
        title: Text(
          'Merge PDF',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_batches.any((b) => b.isNotEmpty))
            Semantics(
              label: 'Clear all batches',
              button: true,
              child: IconButton(
                onPressed: () {
                  setState(() => _batches = [[]]);
                },
                icon: Icon(Icons.delete_outline, color: _colors.textSecondary),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Add files button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Semantics(
                label: _batches.every((b) => b.isEmpty)
                    ? 'Tap to select PDF files to merge'
                    : 'Add more PDF files to current batch',
                button: true,
                enabled: !_isProcessing,
                child: GestureDetector(
                  onTap: _isProcessing ? null : _pickPdfFiles,
                  child: Container(
                    width: double.infinity,
                    height: _batches.every((b) => b.isEmpty) ? 140 : 70,
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFE94560).withValues(alpha: 0.3),
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
                    child: _batches.every((b) => b.isEmpty)
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFE94560,
                                  ).withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add_circle_outline_rounded,
                                  size: 36,
                                  color: Color(0xFFE94560),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Tap to select PDF files',
                                style: TextStyle(
                                  color: _colors.textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFE94560,
                                  ).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  size: 24,
                                  color: Color(0xFFE94560),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Add more PDFs',
                                style: TextStyle(
                                  color: _colors.textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),

            // Stats bar
            if (_batches.any((b) => b.isNotEmpty))
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      'Batches',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE94560).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _loadingCount > 0
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: Color(0xFFE94560),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$_totalFileCount files loading...',
                                  style: const TextStyle(
                                    color: Color(0xFFE94560),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              '${_batches.where((b) => b.isNotEmpty).length} batch(es) • $_totalFileCount files',
                              style: const TextStyle(
                                color: Color(0xFFE94560),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

            // Hint
            if (_mergeableBatchCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.swap_vert_rounded,
                        size: 16,
                        color: Color(0xFF00D9FF),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _batches.length > 1
                              ? 'Long press to reorder. Use "New batch" for separate merge groups.'
                              : 'Long press and drag to reorder',
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

            const SizedBox(height: 10),

            // PDF grid with previews
            Expanded(
              child: _batches.every((b) => b.isEmpty)
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            size: 70,
                            color: _colors.textTertiary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No files selected',
                            style: TextStyle(
                              color: _colors.textTertiary,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _buildBatchesList(),
            ),

            // Merge button
            if (_mergeableBatchCount > 0)
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
                                  _mergeStatus,
                                  style: TextStyle(
                                    color: _colors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${(_mergeProgress * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Color(0xFFE94560),
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
                                value: _mergeProgress,
                                minHeight: 8,
                                backgroundColor: _colors.cardBackground,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFE94560),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Semantics(
                      label: _isProcessing
                          ? 'Merging PDFs in progress'
                          : _allFilesLoaded
                          ? 'Merge $_totalBatchesPages pages'
                          : 'Loading files, please wait',
                      button: true,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: (_isProcessing || !_allFilesLoaded)
                              ? null
                              : _mergePdfs,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE94560),
                            disabledBackgroundColor: const Color(
                              0xFFE94560,
                            ).withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                            elevation: 0,
                          ),
                          child: _isProcessing
                              ? const Text(
                                  'Merging...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.merge_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      _allFilesLoaded
                                          ? 'Merge $_mergeableBatchCount Batch(es)'
                                          : 'Loading files...',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
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
}
