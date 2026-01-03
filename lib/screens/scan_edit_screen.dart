import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:crop_your_image/crop_your_image.dart';
import 'package:path_provider/path_provider.dart';

enum ScanFilter {
  original,
  document,
  blackWhite,
  sharpen,
  brighten,
}

/// Data class for passing to isolate
class _ImageProcessData {
  final Uint8List imageBytes;
  final ScanFilter filter;
  
  _ImageProcessData(this.imageBytes, this.filter);
}

/// Top-level function for isolate processing
Uint8List _processImageInIsolate(_ImageProcessData data) {
  final img.Image? image = img.decodeImage(data.imageBytes);
  if (image == null) return data.imageBytes;

  img.Image processed;

  switch (data.filter) {
    case ScanFilter.document:
      processed = _applyDocumentFilterStatic(image);
      break;
    case ScanFilter.blackWhite:
      processed = _applyBlackWhiteFilterStatic(image);
      break;
    case ScanFilter.sharpen:
      processed = _applySharpenFilterStatic(image);
      break;
    case ScanFilter.brighten:
      processed = _applyBrightenFilterStatic(image);
      break;
    default:
      processed = image;
  }

  return Uint8List.fromList(img.encodeJpg(processed, quality: 95));
}

img.Image _applyDocumentFilterStatic(img.Image image) {
  img.Image result = img.copyResize(image, width: image.width);
  result = img.contrast(result, contrast: 130);
  result = img.adjustColor(result, brightness: 1.1);
  result = img.adjustColor(result, saturation: 0.8);
  result = img.convolution(result, filter: [
    0, -0.5, 0,
    -0.5, 3, -0.5,
    0, -0.5, 0,
  ], div: 1);
  return result;
}

img.Image _applyBlackWhiteFilterStatic(img.Image image) {
  img.Image result = img.grayscale(image);
  result = img.contrast(result, contrast: 150);
  result = img.adjustColor(result, brightness: 1.15);
  return result;
}

img.Image _applySharpenFilterStatic(img.Image image) {
  img.Image result = img.convolution(image, filter: [
    0, -1, 0,
    -1, 5, -1,
    0, -1, 0,
  ], div: 1);
  result = img.contrast(result, contrast: 110);
  return result;
}

img.Image _applyBrightenFilterStatic(img.Image image) {
  img.Image result = img.adjustColor(image, brightness: 1.25);
  result = img.contrast(result, contrast: 115);
  return result;
}

class ScanEditScreen extends StatefulWidget {
  final String imagePath;
  final Function(String) onSave;

  const ScanEditScreen({
    super.key,
    required this.imagePath,
    required this.onSave,
  });

  @override
  State<ScanEditScreen> createState() => _ScanEditScreenState();
}

class _ScanEditScreenState extends State<ScanEditScreen> {
  ScanFilter _selectedFilter = ScanFilter.original;
  bool _isProcessing = false;
  Uint8List? _processedImageBytes;
  Uint8List? _originalImageBytes;
  String _currentImagePath = '';

  @override
  void initState() {
    super.initState();
    _currentImagePath = widget.imagePath;
    _loadOriginalImage();
  }

  Future<void> _loadOriginalImage() async {
    final bytes = await File(_currentImagePath).readAsBytes();
    setState(() {
      _originalImageBytes = bytes;
      _processedImageBytes = bytes;
    });
  }

  Future<void> _cropImage() async {
    if (_originalImageBytes == null) return;
    
    final result = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (context) => _CropScreen(imageBytes: _originalImageBytes!),
      ),
    );

    if (result != null) {
      try {
        // Save cropped image
        final Directory appDir = await getApplicationDocumentsDirectory();
        final String fileName = 'cropped_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final String savedPath = '${appDir.path}/$fileName';
        await File(savedPath).writeAsBytes(result);

        // Delete old file if different
        if (_currentImagePath != widget.imagePath) {
          try {
            await File(_currentImagePath).delete();
          } catch (e) {
            debugPrint('Could not delete old file: $e');
          }
        }

        // Update state
        setState(() {
          _currentImagePath = savedPath;
          _originalImageBytes = result;
          _processedImageBytes = result;
          _selectedFilter = ScanFilter.original;
        });
      } catch (e) {
        debugPrint('Error saving cropped image: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error cropping: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _applyFilter(ScanFilter filter) async {
    if (_originalImageBytes == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _selectedFilter = filter;
    });

    try {
      final Uint8List resultBytes;
      
      if (filter == ScanFilter.original) {
        resultBytes = _originalImageBytes!;
      } else {
        // Process image in background isolate
        resultBytes = await compute(
          _processImageInIsolate,
          _ImageProcessData(_originalImageBytes!, filter),
        );
      }

      if (mounted) {
        setState(() {
          _processedImageBytes = resultBytes;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('Error applying filter: $e');
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _saveAndReturn() async {
    if (_processedImageBytes == null) return;

    setState(() => _isProcessing = true);

    try {
      // Save the processed image
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String fileName = 'processed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String savedPath = '${appDir.path}/$fileName';
      
      await File(savedPath).writeAsBytes(_processedImageBytes!);
      
      // Delete temporary files
      if (_currentImagePath != widget.imagePath) {
        try {
          await File(_currentImagePath).delete();
        } catch (e) {
          debugPrint('Could not delete temp file: $e');
        }
      }
      try {
        await File(widget.imagePath).delete();
      } catch (e) {
        debugPrint('Could not delete original: $e');
      }

      widget.onSave(savedPath);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error saving: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving image: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () {
            // Delete the captured image and go back
            try {
              File(widget.imagePath).deleteSync();
              if (_currentImagePath != widget.imagePath) {
                File(_currentImagePath).deleteSync();
              }
            } catch (e) {
              debugPrint('Error deleting: $e');
            }
            Navigator.pop(context);
          },
        ),
        title: const Text(
          'Edit Scan',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _isProcessing ? null : _saveAndReturn,
            child: const Text(
              'Done',
              style: TextStyle(
                color: Color(0xFF00D9FF),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Image preview
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16213E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_processedImageBytes != null)
                      Image.memory(
                        _processedImageBytes!,
                        fit: BoxFit.contain,
                      )
                    else
                      const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00D9FF),
                        ),
                      ),
                    if (_isProcessing)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                color: Color(0xFF00D9FF),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Processing...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
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
          ),

          // Bottom controls
          Container(
            padding: EdgeInsets.only(
              top: 16,
              bottom: MediaQuery.of(context).padding.bottom + 16,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFF16213E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
            ),
            child: Column(
              children: [
                // Crop button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _cropImage,
                      icon: const Icon(Icons.crop_rounded, color: Color(0xFF00D9FF)),
                      label: const Text(
                        'Crop Image',
                        style: TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF00D9FF), width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                
                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 12),
                  child: Text(
                    'Select Filter',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _buildFilterOption(
                        ScanFilter.original,
                        'Original',
                        Icons.image_outlined,
                      ),
                      _buildFilterOption(
                        ScanFilter.document,
                        'Document',
                        Icons.description_outlined,
                      ),
                      _buildFilterOption(
                        ScanFilter.blackWhite,
                        'B&W',
                        Icons.contrast,
                      ),
                      _buildFilterOption(
                        ScanFilter.sharpen,
                        'Sharpen',
                        Icons.center_focus_strong,
                      ),
                      _buildFilterOption(
                        ScanFilter.brighten,
                        'Brighten',
                        Icons.wb_sunny_outlined,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterOption(ScanFilter filter, String label, IconData icon) {
    final isSelected = _selectedFilter == filter;
    
    return GestureDetector(
      onTap: () => _applyFilter(filter),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 65,
              height: 65,
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF00D9FF)
                    : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF00D9FF)
                      : Colors.white24,
                  width: 2,
                ),
              ),
              child: Icon(
                icon,
                color: isSelected ? Colors.white : Colors.white70,
                size: 28,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFF00D9FF) : Colors.white70,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pure Flutter crop screen that respects all phone boundaries
class _CropScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const _CropScreen({required this.imageBytes});

  @override
  State<_CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<_CropScreen> {
  final CropController _cropController = CropController();
  bool _isCropping = false;
  double? _aspectRatio;

  void _onCrop() {
    setState(() => _isCropping = true);
    _cropController.crop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Crop Document',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _isCropping ? null : _onCrop,
            child: _isCropping
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Color(0xFF00D9FF),
                      strokeWidth: 2,
                    ),
                  )
                : const Text(
                    'Done',
                    style: TextStyle(
                      color: Color(0xFF00D9FF),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Crop area
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Crop(
                    image: widget.imageBytes,
                    controller: _cropController,
                    aspectRatio: _aspectRatio,
                    baseColor: const Color(0xFF16213E),
                    maskColor: Colors.black.withValues(alpha: 0.7),
                    cornerDotBuilder: (size, edgeAlignment) => Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF),
                        borderRadius: BorderRadius.circular(size / 2),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                    onCropped: (croppedImage) {
                      setState(() => _isCropping = false);
                      Navigator.pop(context, croppedImage);
                    },
                  ),
                ),
              ),
            ),

            // Aspect ratio controls
            Container(
              padding: const EdgeInsets.only(
                top: 16,
                bottom: 16,
                left: 16,
                right: 16,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF16213E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Aspect Ratio',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildAspectButton('Free', null),
                        _buildAspectButton('1:1', 1.0),
                        _buildAspectButton('4:3', 4 / 3),
                        _buildAspectButton('3:2', 3 / 2),
                        _buildAspectButton('16:9', 16 / 9),
                        _buildAspectButton('A4', 210 / 297),
                      ],
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

  Widget _buildAspectButton(String label, double? ratio) {
    final isSelected = _aspectRatio == ratio;

    return GestureDetector(
      onTap: () {
        setState(() {
          _aspectRatio = ratio;
        });
        if (ratio != null) {
          _cropController.aspectRatio = ratio;
        } else {
          _cropController.aspectRatio = null;
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00D9FF)
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF00D9FF) : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
