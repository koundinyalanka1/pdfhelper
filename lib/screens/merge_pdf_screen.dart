import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdfx/pdfx.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sync_pdf;
import '../services/pdf_service.dart';
import '../services/notification_service.dart';
import '../providers/theme_provider.dart';

typedef SyncPdfDocument = sync_pdf.PdfDocument;

class SelectedPdfFile {
  final String path;
  final String name;
  int pageCount;
  final int fileSize;
  Uint8List? thumbnail;
  Uint8List? cachedBytes; // Cache PDF bytes for faster merge
  bool isLoading; // Loading state for background processing

  SelectedPdfFile({
    required this.path,
    required this.name,
    this.pageCount = 0,
    required this.fileSize,
    this.thumbnail,
    this.cachedBytes,
    this.isLoading = true,
  });
}

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key});

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen> {
  final List<SelectedPdfFile> _selectedFiles = [];
  bool _isProcessing = false;
  double _mergeProgress = 0.0;
  String _mergeStatus = '';

  bool get _isDarkMode => ThemeNotifier.maybeOf(context)?.isDarkMode ?? true;
  AppColors get _colors => AppColors(_isDarkMode);

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
          _selectedFiles.addAll(newFiles);
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
      // Read file bytes
      final Uint8List pdfBytes = await File(file.path).readAsBytes();
      
      // Cache bytes immediately so merge can proceed even if thumbnail fails
      if (mounted) {
        setState(() {
          file.cachedBytes = pdfBytes;
        });
      }
      
      // Run page count in isolate and thumbnail generation in parallel
      final pageCountFuture = compute(_getPageCountFromBytes, pdfBytes);
      final thumbnailFuture = _generateThumbnail(pdfBytes);
      
      final results = await Future.wait([pageCountFuture, thumbnailFuture]);
      final int pageCount = results[0] as int;
      final Uint8List? thumbnail = results[1] as Uint8List?;

      // Update file in list
      if (mounted) {
        setState(() {
          file.pageCount = pageCount;
          file.thumbnail = thumbnail;
          file.isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading PDF: $e');
      if (mounted) {
        setState(() {
          file.isLoading = false;
        });
      }
    }
  }
  
  Future<Uint8List?> _generateThumbnail(Uint8List pdfBytes) async {
    try {
      final pdfDoc = await PdfDocument.openData(pdfBytes);
      final page = await pdfDoc.getPage(1);
      final pageImage = await page.render(
        width: page.width * 0.25, // Slightly smaller for faster rendering
        height: page.height * 0.25,
        format: PdfPageImageFormat.jpeg,
        quality: 60, // Lower quality for faster rendering (still looks good as thumbnail)
      );
      final bytes = pageImage?.bytes;
      await page.close();
      await pdfDoc.close();
      return bytes;
    } catch (e) {
      debugPrint('Error generating thumbnail: $e');
      return null;
    }
  }
  
  // Isolate function for getting page count
  static int _getPageCountFromBytes(Uint8List bytes) {
    final doc = SyncPdfDocument(inputBytes: bytes);
    final count = doc.pages.count;
    doc.dispose();
    return count;
  }

  bool get _allFilesLoaded => _selectedFiles.every((f) => !f.isLoading);

  Future<void> _mergePdfs() async {
    if (_selectedFiles.length < 2) return;
    
    // Wait for all files to finish loading
    if (!_allFilesLoaded) {
      _showSnackBar('Please wait for all files to load', isError: false);
      return;
    }

    setState(() {
      _isProcessing = true;
      _mergeProgress = 0.1;
      _mergeStatus = 'Preparing ${_selectedFiles.length} files...';
    });

    try {
      // OPTIMIZED: Use cached bytes directly (already loaded in parallel)
      // Only read missing files in parallel if any
      final List<Uint8List> pdfBytesList = [];
      final List<int> missingIndices = [];
      
      for (int i = 0; i < _selectedFiles.length; i++) {
        if (_selectedFiles[i].cachedBytes != null) {
          pdfBytesList.add(_selectedFiles[i].cachedBytes!);
        } else {
          pdfBytesList.add(Uint8List(0)); // Placeholder
          missingIndices.add(i);
        }
      }
      
      // Read any missing files in parallel
      if (missingIndices.isNotEmpty) {
        final missingBytes = await Future.wait(
          missingIndices.map((i) => File(_selectedFiles[i].path).readAsBytes()),
        );
        for (int j = 0; j < missingIndices.length; j++) {
          pdfBytesList[missingIndices[j]] = missingBytes[j];
        }
      }

      setState(() {
        _mergeProgress = 0.2;
        _mergeStatus = 'Merging $_totalPages pages...';
      });

      final String? outputPath = await PdfService.mergePdfsFromBytes(pdfBytesList);

      setState(() {
        _mergeProgress = 0.9;
        _mergeStatus = 'Saving...';
      });

      if (outputPath != null) {
        // Auto-save to user-accessible location if enabled
        String? autoSavedPath;
        final themeProvider = ThemeNotifier.maybeOf(context);
        if (themeProvider != null && themeProvider.autoSave) {
          autoSavedPath = await themeProvider.autoSaveFile(outputPath, 'merged');
        }
        
        // Show notification if enabled
        if (themeProvider != null && themeProvider.notifications) {
          NotificationService().showMergeComplete(_totalPages);
        }
        
        setState(() {
          _mergeProgress = 1.0;
          _selectedFiles.clear();
        });
        _showSuccessDialog(outputPath, autoSavedPath);
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

  void _showSuccessDialog(String filePath, [String? autoSavedPath]) {
    final themeProvider = ThemeNotifier.maybeOf(context);
    final saveLocation = themeProvider?.saveLocation ?? 'Downloads';
    
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
              'PDFs merged successfully!',
              style: TextStyle(color: _colors.textSecondary),
            ),
            if (autoSavedPath != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_rounded, color: Color(0xFF4CAF50), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Saved to $saveLocation/PDFHelper',
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
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: _colors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // Share the auto-saved file if available, otherwise use original
              final shareFile = autoSavedPath ?? filePath;
              Share.shareXFiles([XFile(shareFile)], text: 'Merged PDF');
            },
            child: const Text('Share', style: TextStyle(color: Color(0xFF00D9FF))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // Open the auto-saved file if available, otherwise use original
              PdfService.openPdf(autoSavedPath ?? filePath);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
            ),
            child: const Text('Open', style: TextStyle(color: Colors.white)),
          ),
        ],
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

  int get _totalPages => _selectedFiles.fold(0, (sum, file) => sum + file.pageCount);
  int get _loadingCount => _selectedFiles.where((f) => f.isLoading).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Merge PDF',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_selectedFiles.isNotEmpty)
            IconButton(
              onPressed: () {
                setState(() => _selectedFiles.clear());
              },
              icon: Icon(Icons.delete_outline, color: _colors.textSecondary),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Add files button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: GestureDetector(
                onTap: _isProcessing ? null : _pickPdfFiles,
                child: Container(
                  width: double.infinity,
                  height: _selectedFiles.isEmpty ? 140 : 70,
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
                  child: _selectedFiles.isEmpty
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE94560).withValues(alpha: 0.1),
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
                                color: const Color(0xFFE94560).withValues(alpha: 0.1),
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

            // Stats bar
            if (_selectedFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      'Selected PDFs',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                                  '${_selectedFiles.length - _loadingCount}/${_selectedFiles.length} loaded',
                                  style: const TextStyle(
                                    color: Color(0xFFE94560),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              '${_selectedFiles.length} files • $_totalPages pages',
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
            if (_selectedFiles.length > 1)
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
                        Icons.swap_vert_rounded,
                        size: 16,
                        color: Color(0xFF00D9FF),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Long press and drag to reorder',
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
              child: _selectedFiles.isEmpty
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
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _selectedFiles.length,
                      proxyDecorator: (child, index, animation) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            final double elevation = Tween<double>(begin: 0, end: 8)
                                .animate(animation)
                                .value;
                            return Material(
                              elevation: elevation,
                              borderRadius: BorderRadius.circular(16),
                              shadowColor: const Color(0xFFE94560).withValues(alpha: 0.4),
                              child: child,
                            );
                          },
                          child: child,
                        );
                      },
                      onReorder: (oldIndex, newIndex) {
                        HapticFeedback.mediumImpact();
                        setState(() {
                          if (newIndex > oldIndex) newIndex--;
                          final item = _selectedFiles.removeAt(oldIndex);
                          _selectedFiles.insert(newIndex, item);
                        });
                      },
                      itemBuilder: (context, index) {
                        final file = _selectedFiles[index];
                        
                        return ReorderableDragStartListener(
                          key: ValueKey('${file.path}_$index'),
                          index: index,
                          child: Container(
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
                                  // Order badge
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE94560),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${index + 1}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),

                                  // Thumbnail
                                  Container(
                                    width: 60,
                                    height: 80,
                                    decoration: BoxDecoration(
                                      color: _isDarkMode 
                                          ? Colors.white.withValues(alpha: 0.1)
                                          : Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _colors.divider,
                                        width: 1,
                                      ),
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
                                              ? Image.memory(
                                                  file.thumbnail!,
                                                  fit: BoxFit.cover,
                                                )
                                              : Center(
                                                  child: Icon(
                                                    Icons.picture_as_pdf_rounded,
                                                    color: const Color(0xFFE94560),
                                                    size: 28,
                                                  ),
                                                ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),

                                  // File info
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
                                              _formatFileSize(file.fileSize),
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

                                  // Delete button
                                  IconButton(
                                    onPressed: () {
                                      HapticFeedback.lightImpact();
                                      setState(() {
                                        _selectedFiles.removeAt(index);
                                      });
                                    },
                                    icon: Icon(
                                      Icons.close_rounded,
                                      color: Colors.red.shade400,
                                      size: 20,
                                    ),
                                    constraints: const BoxConstraints(
                                      minWidth: 40,
                                      minHeight: 40,
                                    ),
                                    padding: EdgeInsets.zero,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),

            // Merge button
            if (_selectedFiles.length >= 2)
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
                                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE94560)),
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
                        onPressed: (_isProcessing || !_allFilesLoaded) ? null : _mergePdfs,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE94560),
                          disabledBackgroundColor: const Color(0xFFE94560).withValues(alpha: 0.5),
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
                                  const Icon(Icons.merge_rounded, color: Colors.white, size: 22),
                                  const SizedBox(width: 10),
                                  Text(
                                    _allFilesLoaded 
                                        ? 'Merge $_totalPages Pages'
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
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
