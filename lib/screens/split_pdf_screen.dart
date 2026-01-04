import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdfx/pdfx.dart';
import '../services/pdf_service.dart';
import '../providers/theme_provider.dart';

class SplitPdfScreen extends StatefulWidget {
  const SplitPdfScreen({super.key});

  @override
  State<SplitPdfScreen> createState() => _SplitPdfScreenState();
}

class _SplitPdfScreenState extends State<SplitPdfScreen> {
  String? _selectedFilePath;
  String? _selectedFileName;
  int _totalPages = 0;
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController = TextEditingController();
  String _splitMode = 'range';
  bool _isProcessing = false;
  bool _isLoadingPreviews = false;
  
  // For page previews (PDFs < 20 pages)
  List<Uint8List?> _pagePreviews = [];
  Set<int> _selectedPages = {};
  PdfDocument? _pdfDocument;

  bool get _isDarkMode => ThemeNotifier.maybeOf(context)?.isDarkMode ?? true;
  AppColors get _colors => AppColors(_isDarkMode);
  
  // Show preview mode for PDFs with less than 20 pages
  bool get _usePreviewMode => _totalPages > 0 && _totalPages < 20;

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    _pdfDocument?.close();
    super.dispose();
  }

  Future<void> _pickPdfFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final String path = result.files.single.path!;
        final int pageCount = await PdfService.getPageCount(path);

        setState(() {
          _selectedFilePath = path;
          _selectedFileName = result.files.single.name;
          _totalPages = pageCount;
          _fromController.clear();
          _toController.clear();
          _selectedPages.clear();
          _pagePreviews = [];
        });

        // Load previews for small PDFs
        if (_usePreviewMode) {
          await _loadPagePreviews(path);
        }
      }
    } catch (e) {
      _showSnackBar('Error selecting file: $e', isError: true);
    }
  }

  Future<void> _loadPagePreviews(String path) async {
    setState(() => _isLoadingPreviews = true);

    try {
      _pdfDocument?.close();
      _pdfDocument = await PdfDocument.openFile(path);
      
      List<Uint8List?> previews = [];
      
      for (int i = 1; i <= _totalPages; i++) {
        final page = await _pdfDocument!.getPage(i);
        final pageImage = await page.render(
          width: page.width * 0.5,
          height: page.height * 0.5,
          format: PdfPageImageFormat.jpeg,
          quality: 80,
        );
        previews.add(pageImage?.bytes);
        await page.close();
      }

      if (mounted) {
        setState(() {
          _pagePreviews = previews;
          _isLoadingPreviews = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading previews: $e');
      if (mounted) {
        setState(() => _isLoadingPreviews = false);
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

  Future<void> _splitPdf() async {
    if (_selectedFilePath == null) return;

    setState(() => _isProcessing = true);

    try {
      if (_usePreviewMode) {
        // Extract selected pages
        if (_selectedPages.isEmpty) {
          _showSnackBar('Please select at least one page', isError: true);
          setState(() => _isProcessing = false);
          return;
        }

        final sortedPages = _selectedPages.toList()..sort();
        
        // If consecutive pages, use range split
        bool isConsecutive = true;
        for (int i = 1; i < sortedPages.length; i++) {
          if (sortedPages[i] != sortedPages[i - 1] + 1) {
            isConsecutive = false;
            break;
          }
        }

        if (isConsecutive && sortedPages.length > 1) {
          // Use range split for consecutive pages
          final String? outputPath = await PdfService.splitPdfByRange(
            _selectedFilePath!,
            sortedPages.first + 1, // Convert to 1-based
            sortedPages.last + 1,
          );
          if (outputPath != null) {
            _showSuccessDialog([outputPath]);
          } else {
            _showSnackBar('Failed to split PDF', isError: true);
          }
        } else {
          // Extract individual pages and merge them
          List<String> outputPaths = [];
          for (int pageIndex in sortedPages) {
            final String? outputPath = await PdfService.splitPdfByRange(
              _selectedFilePath!,
              pageIndex + 1,
              pageIndex + 1,
            );
            if (outputPath != null) {
              outputPaths.add(outputPath);
            }
          }
          
          if (outputPaths.isNotEmpty) {
            if (outputPaths.length == 1) {
              _showSuccessDialog(outputPaths);
            } else {
              // Merge the extracted pages into one PDF
              final String? mergedPath = await PdfService.mergePdfs(outputPaths);
              // Clean up individual files
              for (String path in outputPaths) {
                try {
                  await File(path).delete();
                } catch (_) {}
              }
              if (mergedPath != null) {
                _showSuccessDialog([mergedPath]);
              } else {
                _showSnackBar('Failed to merge extracted pages', isError: true);
              }
            }
          } else {
            _showSnackBar('Failed to extract pages', isError: true);
          }
        }
      } else if (_splitMode == 'range') {
        final int fromPage = int.tryParse(_fromController.text) ?? 1;
        final int toPage = int.tryParse(_toController.text) ?? _totalPages;

        if (fromPage < 1 || toPage > _totalPages || fromPage > toPage) {
          _showSnackBar('Invalid page range', isError: true);
          setState(() => _isProcessing = false);
          return;
        }

        final String? outputPath = await PdfService.splitPdfByRange(
          _selectedFilePath!,
          fromPage,
          toPage,
        );

        if (outputPath != null) {
          _showSuccessDialog([outputPath]);
        } else {
          _showSnackBar('Failed to split PDF', isError: true);
        }
      } else {
        // Split all pages
        final List<String> outputPaths =
            await PdfService.splitPdfAllPages(_selectedFilePath!);

        if (outputPaths.isNotEmpty) {
          _showSuccessDialog(outputPaths);
        } else {
          _showSnackBar('Failed to split PDF', isError: true);
        }
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showSuccessDialog(List<String> filePaths) {
    // Clear selection after success
    setState(() {
      _selectedPages.clear();
    });
    
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
        content: Text(
          filePaths.length == 1
              ? 'PDF split successfully!'
              : '${filePaths.length} pages extracted successfully!',
          style: TextStyle(color: _colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: _colors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Share.shareXFiles(
                filePaths.map((p) => XFile(p)).toList(),
                text: 'Split PDF',
              );
            },
            child: const Text('Share', style: TextStyle(color: Color(0xFFE94560))),
          ),
          if (filePaths.length == 1)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                PdfService.openPdf(filePaths.first);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFC107),
              ),
              child: const Text('Open', style: TextStyle(color: Colors.black87)),
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
                                color: const Color(0xFFFFC107).withValues(alpha: 0.1),
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
                                  color: const Color(0xFFFFC107).withValues(alpha: 0.1),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                        color: const Color(0xFFFFC107).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(12),
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
                                    _selectedPages.clear();
                                    _pagePreviews = [];
                                  });
                                  _pdfDocument?.close();
                                  _pdfDocument = null;
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
            
            // Content area
            Expanded(
              child: _selectedFilePath == null
                  ? const SizedBox()
                  : _usePreviewMode
                      ? _buildPreviewMode()
                      : _buildRangeMode(),
            ),
            
            // Split button
            if (_selectedFilePath != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _splitPdf,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFC107),
                      disabledBackgroundColor: const Color(0xFFFFC107).withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                      elevation: 0,
                    ),
                    child: _isProcessing
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.black87,
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Processing...',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.content_cut_rounded, color: Colors.black87, size: 22),
                              const SizedBox(width: 10),
                              Text(
                                _usePreviewMode
                                    ? 'Extract ${_selectedPages.length} Page${_selectedPages.length != 1 ? 's' : ''}'
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
              ),
          ],
        ),
      ),
    );
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
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  _selectedPages.length == _totalPages ? 'Deselect All' : 'Select All',
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
                      const CircularProgressIndicator(
                        color: Color(0xFFFFC107),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Loading previews...',
                        style: TextStyle(
                          color: _colors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.7,
                  ),
                  itemCount: _totalPages,
                  itemBuilder: (context, index) {
                    final isSelected = _selectedPages.contains(index);
                    final hasPreview = index < _pagePreviews.length && _pagePreviews[index] != null;
                    
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
                                    color: const Color(0xFFFFC107).withValues(alpha: 0.3),
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
                                  fit: BoxFit.cover,
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
                                  color: const Color(0xFFFFC107).withValues(alpha: 0.2),
                                ),
                              
                              // Page number badge
                              Positioned(
                                bottom: 4,
                                left: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isSelected 
                                        ? const Color(0xFFFFC107)
                                        : Colors.black.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: isSelected ? Colors.black87 : Colors.white,
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
          Text(
            'Split Mode',
            style: TextStyle(
              color: _colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          // Split mode options
          Row(
            children: [
              Expanded(
                child: _buildModeCard(
                  'range',
                  'Page Range',
                  Icons.horizontal_rule_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildModeCard(
                  'all',
                  'Extract All',
                  Icons.layers_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
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
                        labelStyle: TextStyle(
                          color: _colors.textSecondary,
                        ),
                        hintText: '1',
                        hintStyle: TextStyle(
                          color: _colors.textTertiary,
                        ),
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
                        labelStyle: TextStyle(
                          color: _colors.textSecondary,
                        ),
                        hintText: '$_totalPages',
                        hintStyle: TextStyle(
                          color: _colors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
                      'Extract pages 1 to $_totalPages into a new PDF',
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
      onTap: () {
        setState(() {
          _splitMode = mode;
        });
      },
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
              color: isSelected ? const Color(0xFFFFC107) : _colors.textSecondary,
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFFFFC107) : _colors.textSecondary,
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
