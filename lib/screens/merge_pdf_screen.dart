import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../services/pdf_service.dart';
import '../main.dart';
import '../providers/theme_provider.dart';

class SelectedPdfFile {
  final String path;
  final String name;

  SelectedPdfFile({required this.path, required this.name});
}

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key});

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen> {
  final List<SelectedPdfFile> _selectedFiles = [];
  bool _isProcessing = false;

  bool get _isDarkMode => PDFHelperApp.of(context)?.themeProvider.isDarkMode ?? true;
  AppColors get _colors => AppColors(_isDarkMode);

  Future<void> _pickPdfFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );

      if (result != null) {
        setState(() {
          for (var file in result.files) {
            if (file.path != null) {
              _selectedFiles.add(SelectedPdfFile(
                path: file.path!,
                name: file.name,
              ));
            }
          }
        });
      }
    } catch (e) {
      _showSnackBar('Error selecting files: $e', isError: true);
    }
  }

  Future<void> _mergePdfs() async {
    if (_selectedFiles.length < 2) return;

    setState(() => _isProcessing = true);

    try {
      final List<String> paths = _selectedFiles.map((f) => f.path).toList();
      final String? outputPath = await PdfService.mergePdfs(paths);

      if (outputPath != null) {
        _showSuccessDialog(outputPath);
      } else {
        _showSnackBar('Failed to merge PDFs', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showSuccessDialog(String filePath) {
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
          'PDFs merged successfully!',
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
              Share.shareXFiles([XFile(filePath)], text: 'Merged PDF');
            },
            child: const Text('Share', style: TextStyle(color: Color(0xFF00D9FF))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              PdfService.openPdf(filePath);
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
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // Upload area
              GestureDetector(
                onTap: _isProcessing ? null : _pickPdfFiles,
                child: Container(
                  width: double.infinity,
                  height: 180,
                  decoration: BoxDecoration(
                    color: _colors.cardBackground,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFE94560).withValues(alpha: 0.3),
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _colors.shadowColor,
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE94560).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 50,
                          color: Color(0xFFE94560),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Text(
                        'Tap to select PDF files',
                        style: TextStyle(
                          color: _colors.textSecondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Select multiple files to merge',
                        style: TextStyle(
                          color: _colors.textTertiary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 25),
              // Selected files list
              if (_selectedFiles.isNotEmpty) ...[
                Row(
                  children: [
                    Text(
                      'Selected Files',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_selectedFiles.length} files',
                      style: const TextStyle(
                        color: Color(0xFFE94560),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
              ],
              Expanded(
                child: _selectedFiles.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              size: 80,
                              color: _colors.textTertiary,
                            ),
                            const SizedBox(height: 15),
                            Text(
                              'No files selected',
                              style: TextStyle(
                                color: _colors.textTertiary,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ReorderableListView.builder(
                        itemCount: _selectedFiles.length,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex--;
                            final item = _selectedFiles.removeAt(oldIndex);
                            _selectedFiles.insert(newIndex, item);
                          });
                        },
                        itemBuilder: (context, index) {
                          return Container(
                            key: ValueKey(_selectedFiles[index].path),
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(15),
                            decoration: BoxDecoration(
                              color: _colors.cardBackground,
                              borderRadius: BorderRadius.circular(15),
                              boxShadow: [
                                BoxShadow(
                                  color: _colors.shadowColor,
                                  blurRadius: 5,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE94560).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.picture_as_pdf_rounded,
                                    color: Color(0xFFE94560),
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 15),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _selectedFiles[index].name,
                                        style: TextStyle(
                                          color: _colors.textPrimary,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Order: ${index + 1}',
                                        style: TextStyle(
                                          color: _colors.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedFiles.removeAt(index);
                                    });
                                  },
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: _colors.textSecondary,
                                  ),
                                ),
                                Icon(
                                  Icons.drag_handle_rounded,
                                  color: _colors.textTertiary,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              // Merge button
              if (_selectedFiles.length >= 2)
                Container(
                  width: double.infinity,
                  height: 60,
                  margin: const EdgeInsets.only(top: 20),
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _mergePdfs,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE94560),
                      disabledBackgroundColor: const Color(0xFFE94560).withValues(alpha: 0.5),
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
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 15),
                              Text(
                                'Merging...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.merge_rounded, color: Colors.white),
                              SizedBox(width: 10),
                              Text(
                                'Merge PDFs',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
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
      ),
    );
  }
}
