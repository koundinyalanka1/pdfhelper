import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
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

  bool get _isDarkMode => ThemeNotifier.maybeOf(context)?.isDarkMode ?? true;
  AppColors get _colors => AppColors(_isDarkMode);

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
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
        });
      }
    } catch (e) {
      _showSnackBar('Error selecting file: $e', isError: true);
    }
  }

  Future<void> _splitPdf() async {
    if (_selectedFilePath == null) return;

    setState(() => _isProcessing = true);

    try {
      if (_splitMode == 'range') {
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
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Upload area
              GestureDetector(
                onTap: _isProcessing ? null : _pickPdfFile,
                child: Container(
                  width: double.infinity,
                  height: 160,
                  decoration: BoxDecoration(
                    color: _colors.cardBackground,
                    borderRadius: BorderRadius.circular(20),
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
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFC107).withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.upload_file_rounded,
                                size: 45,
                                color: Color(0xFFFFC107),
                              ),
                            ),
                            const SizedBox(height: 15),
                            Text(
                              'Tap to select a PDF',
                              style: TextStyle(
                                color: _colors.textSecondary,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        )
                      : Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(15),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFC107).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const Icon(
                                  Icons.picture_as_pdf_rounded,
                                  color: Color(0xFFFFC107),
                                  size: 40,
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _selectedFileName!,
                                      style: TextStyle(
                                        color: _colors.textPrimary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFC107).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        '$_totalPages pages',
                                        style: const TextStyle(
                                          color: Color(0xFFFFC107),
                                          fontSize: 13,
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
              if (_selectedFilePath != null) ...[
                const SizedBox(height: 30),
                Text(
                  'Split Mode',
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 15),
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
                const SizedBox(height: 25),
                // Page range input
                if (_splitMode == 'range') ...[
                  Text(
                    'Select Page Range',
                    style: TextStyle(
                      color: _colors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 15),
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
                        padding: const EdgeInsets.symmetric(horizontal: 15),
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
                            borderRadius: BorderRadius.circular(15),
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
                  const SizedBox(height: 15),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: _colors.textSecondary,
                          size: 20,
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
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFC107).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.info_outline_rounded,
                            color: Color(0xFFFFC107),
                          ),
                        ),
                        const SizedBox(width: 15),
                        Expanded(
                          child: Text(
                            'Each of the $_totalPages pages will be extracted as a separate PDF file',
                            style: TextStyle(
                              color: _colors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 30),
                // Split button
                SizedBox(
                  width: double.infinity,
                  height: 60,
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
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.black87,
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 15),
                              Text(
                                'Splitting...',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.content_cut_rounded, color: Colors.black87),
                              SizedBox(width: 10),
                              Text(
                                'Split PDF',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
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
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFFFC107).withValues(alpha: 0.15)
              : _colors.cardBackground,
          borderRadius: BorderRadius.circular(15),
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
              size: 30,
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFFFFC107) : _colors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
