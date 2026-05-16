import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:crop_your_image/crop_your_image.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/theme_provider.dart';

enum ScanFilter {
  original,
  auto, // Auto enhance - smart detection
  document, // CamScanner-style document (white bg, dark text)
  magicColor, // Enhanced colors like CamScanner Magic Color
  blackWhite, // High contrast B&W for documents
  grayscale, // Clean grayscale
}

/// Data class for passing to isolate - must be a simple class with primitives
class ImageFilterRequest {
  final Uint8List imageBytes;
  final int filterIndex; // Use int instead of enum for isolate compatibility
  final int imageQuality; // JPEG quality 1-100

  ImageFilterRequest(
    this.imageBytes,
    this.filterIndex, {
    this.imageQuality = 85,
  });
}

/// Top-level function for isolate processing
Uint8List processImageInBackground(ImageFilterRequest request) {
  final img.Image? image = img.decodeImage(request.imageBytes);
  if (image == null) return request.imageBytes;

  img.Image processed;

  switch (request.filterIndex) {
    case 1: // auto
      processed = applyAutoEnhance(image);
      break;
    case 2: // document (CamScanner style)
      processed = applyDocumentFilter(image);
      break;
    case 3: // magicColor
      processed = applyMagicColorFilter(image);
      break;
    case 4: // blackWhite
      processed = applyBlackWhiteFilter(image);
      break;
    case 5: // grayscale
      processed = applyGrayscaleFilter(image);
      break;
    default:
      processed = image;
  }

  return Uint8List.fromList(
    img.encodeJpg(processed, quality: request.imageQuality),
  );
}

/// Auto enhance - intelligent enhancement based on image characteristics
img.Image applyAutoEnhance(img.Image image) {
  // Normalize the image (auto levels)
  img.Image result = img.normalize(image, min: 0, max: 255);

  // Moderate contrast boost
  result = img.contrast(result, contrast: 115);

  // Slight sharpening
  result = img.convolution(
    result,
    filter: [0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
    div: 1,
  );

  return result;
}

/// CamScanner-style document filter
/// Creates clean white background with crisp dark text.
///
/// Performance: the previous implementation iterated a 31x31 (step-3) window
/// per pixel — ~120 random reads per pixel, freezing the isolate for many
/// seconds on large photos. This version:
///   1. Downscales the input to a max dimension of 1500 px (still enough for
///      sharp document text in the final JPEG/PDF).
///   2. Builds integral images (summed-area tables) of the grayscale values
///      and their squares, so each window's mean and variance are O(1).
/// Local contrast is approximated by std-deviation/50 instead of (max-min)/255
/// — a close enough proxy that retains the original "low-contrast = background"
/// behaviour without an O(window^2) min/max scan.
img.Image applyDocumentFilter(img.Image image) {
  const int maxDim = 1500;
  img.Image src = image;
  if (image.width > maxDim || image.height > maxDim) {
    if (image.width >= image.height) {
      src = img.copyResize(image, width: maxDim);
    } else {
      src = img.copyResize(image, height: maxDim);
    }
  }

  final int width = src.width;
  final int height = src.height;
  final int n = width * height;

  // Grayscale + integral image of grayscale + integral image of grayscale^2.
  // Int64List avoids overflow on sum-of-squares for large inputs
  // (255^2 * 1500 * 1500 ~ 1.46e11, exceeds int32).
  final Uint8List gray = Uint8List(n);
  final Int64List sat = Int64List(n);
  final Int64List sat2 = Int64List(n);

  for (int y = 0; y < height; y++) {
    int rowSum = 0;
    int rowSum2 = 0;
    final int yOff = y * width;
    for (int x = 0; x < width; x++) {
      final p = src.getPixel(x, y);
      // Rec. 601 luma
      final int g = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).toInt() & 0xFF;
      gray[yOff + x] = g;
      rowSum += g;
      rowSum2 += g * g;
      final int above = y > 0 ? sat[yOff - width + x] : 0;
      final int above2 = y > 0 ? sat2[yOff - width + x] : 0;
      sat[yOff + x] = above + rowSum;
      sat2[yOff + x] = above2 + rowSum2;
    }
  }

  int areaSum(int x0, int y0, int x1, int y1, Int64List s) {
    int total = s[y1 * width + x1];
    if (x0 > 0) total -= s[y1 * width + (x0 - 1)];
    if (y0 > 0) total -= s[(y0 - 1) * width + x1];
    if (x0 > 0 && y0 > 0) total += s[(y0 - 1) * width + (x0 - 1)];
    return total;
  }

  const int block = 15;
  final result = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final int y0 = (y - block).clamp(0, height - 1);
    final int y1 = (y + block).clamp(0, height - 1);
    final int yOff = y * width;
    for (int x = 0; x < width; x++) {
      final int x0 = (x - block).clamp(0, width - 1);
      final int x1 = (x + block).clamp(0, width - 1);
      final int area = (x1 - x0 + 1) * (y1 - y0 + 1);
      final int s = areaSum(x0, y0, x1, y1, sat);
      final int s2 = areaSum(x0, y0, x1, y1, sat2);
      final double mean = s / area;
      final double variance = (s2 / area) - mean * mean;
      final double stdDev = variance > 0 ? math.sqrt(variance) : 0.0;
      // Map std-dev (~0..70 typical) to 0..1 contrast metric, replacing the
      // old (maxVal - minVal) / 255 measurement.
      final double localContrast = (stdDev / 50.0).clamp(0.0, 1.0);

      final int luminance = gray[yOff + x];
      final double threshold = mean * 0.85 - 8;

      final pixel = src.getPixel(x, y);
      int newR, newG, newB;

      if (localContrast < 0.15) {
        // Low contrast area - likely background, make it white
        newR = 255;
        newG = 255;
        newB = 255;
      } else if (luminance < threshold) {
        // Dark pixel (text) - make it darker, preserve some color hint
        final double factor = 0.3 + (luminance / 255.0) * 0.4;
        newR = (pixel.r * factor).clamp(0, 80).toInt();
        newG = (pixel.g * factor).clamp(0, 80).toInt();
        newB = (pixel.b * factor).clamp(0, 80).toInt();
      } else {
        // Light pixel (background) - push towards white
        final double factor =
            0.3 + ((luminance - threshold) / (255 - threshold)) * 0.7;
        newR = (255 - (255 - pixel.r) * (1 - factor)).clamp(240, 255).toInt();
        newG = (255 - (255 - pixel.g) * (1 - factor)).clamp(240, 255).toInt();
        newB = (255 - (255 - pixel.b) * (1 - factor)).clamp(240, 255).toInt();
      }

      result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, 255));
    }
  }

  // Slight sharpening to crisp up text edges.
  return img.convolution(
    result,
    filter: [0, -0.8, 0, -0.8, 4.2, -0.8, 0, -0.8, 0],
    div: 1,
  );
}

/// Magic Color filter - enhanced colors like CamScanner
/// Keeps colors vibrant but enhances document readability
img.Image applyMagicColorFilter(img.Image image) {
  // Step 1: Normalize to fix exposure issues
  img.Image result = img.normalize(image, min: 0, max: 255);

  // Step 2: Increase saturation slightly for vivid colors
  result = img.adjustColor(result, saturation: 1.2);

  // Step 3: Apply strong contrast for pop
  result = img.contrast(result, contrast: 140);

  // Step 4: Brighten shadows, compress highlights
  result = img.adjustColor(result, brightness: 1.08, gamma: 0.9);

  // Step 5: Sharpen for crisp details
  result = img.convolution(
    result,
    filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
    div: 1,
  );

  return result;
}

/// High contrast Black & White for documents
/// Creates ultra-clean text documents
img.Image applyBlackWhiteFilter(img.Image image) {
  final width = image.width;
  final height = image.height;

  // Convert to grayscale first
  img.Image grayImage = img.grayscale(image);

  // Normalize the grayscale
  grayImage = img.normalize(grayImage, min: 0, max: 255);

  // Apply Otsu-like thresholding for clean B&W
  // Calculate histogram
  List<int> histogram = List.filled(256, 0);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      histogram[grayImage.getPixel(x, y).r.toInt()]++;
    }
  }

  // Find optimal threshold using Otsu's method
  int total = width * height;
  double sum = 0;
  for (int i = 0; i < 256; i++) {
    sum += i * histogram[i];
  }

  double sumB = 0;
  int wB = 0;
  double maxVariance = 0;
  int threshold = 128;

  for (int i = 0; i < 256; i++) {
    wB += histogram[i];
    if (wB == 0) continue;

    int wF = total - wB;
    if (wF == 0) break;

    sumB += i * histogram[i];
    double mB = sumB / wB;
    double mF = (sum - sumB) / wF;

    double variance = wB * wF * (mB - mF) * (mB - mF);
    if (variance > maxVariance) {
      maxVariance = variance;
      threshold = i;
    }
  }

  // Adjust threshold for document scanning (slightly lower to catch more text)
  threshold = (threshold * 0.9).toInt();

  // Apply threshold with anti-aliasing for smoother edges
  img.Image result = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int gray = grayImage.getPixel(x, y).r.toInt();

      // Soft threshold for anti-aliased edges
      int value;
      if (gray < threshold - 20) {
        value = 0; // Pure black
      } else if (gray > threshold + 20) {
        value = 255; // Pure white
      } else {
        // Gradient for anti-aliasing
        value = ((gray - (threshold - 20)) * 255 / 40).clamp(0, 255).toInt();
      }

      result.setPixel(x, y, img.ColorRgba8(value, value, value, 255));
    }
  }

  return result;
}

/// Clean grayscale filter for documents
img.Image applyGrayscaleFilter(img.Image image) {
  // Convert to grayscale
  img.Image result = img.grayscale(image);

  // Normalize levels
  result = img.normalize(result, min: 0, max: 255);

  // Moderate contrast
  result = img.contrast(result, contrast: 125);

  // Slight brightness boost
  result = img.adjustColor(result, brightness: 1.05);

  // Light sharpening
  result = img.convolution(
    result,
    filter: [0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
    div: 1,
  );

  return result;
}

class ScanEditScreen extends StatefulWidget {
  final String imagePath;
  final Function(String) onSave;
  final int imageQuality; // JPEG quality 1-100 for filter output

  const ScanEditScreen({
    super.key,
    required this.imagePath,
    required this.onSave,
    this.imageQuality = 85,
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

  // Undo/redo history (capped). Each entry snapshots the post-edit state.
  static const int _maxHistory = 10;
  final List<_EditSnapshot> _undoStack = [];
  final List<_EditSnapshot> _redoStack = [];

  bool get _canUndo => _undoStack.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty;

  /// Snapshot of the *current* state, ready to push onto the undo stack
  /// before applying a new edit.
  _EditSnapshot _currentSnapshot() => _EditSnapshot(
    originalBytes: _originalImageBytes,
    processedBytes: _processedImageBytes,
    imagePath: _currentImagePath,
    filter: _selectedFilter,
  );

  /// Push the current state onto undo and clear the redo stack
  /// (called before any user-driven edit: crop or filter).
  void _pushUndo() {
    if (_originalImageBytes == null) return;
    _undoStack.add(_currentSnapshot());
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (!_canUndo) return;
    final snapshot = _undoStack.removeLast();
    _redoStack.add(_currentSnapshot());
    setState(() {
      _originalImageBytes = snapshot.originalBytes;
      _processedImageBytes = snapshot.processedBytes;
      _currentImagePath = snapshot.imagePath;
      _selectedFilter = snapshot.filter;
    });
  }

  void _redo() {
    if (!_canRedo) return;
    final snapshot = _redoStack.removeLast();
    _undoStack.add(_currentSnapshot());
    setState(() {
      _originalImageBytes = snapshot.originalBytes;
      _processedImageBytes = snapshot.processedBytes;
      _currentImagePath = snapshot.imagePath;
      _selectedFilter = snapshot.filter;
    });
  }

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

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
        final String fileName =
            'cropped_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final String savedPath = '${appDir.path}/$fileName';
        await File(savedPath).writeAsBytes(result);

        // Snapshot the pre-crop state so the user can undo.
        _pushUndo();

        // Update state (do NOT delete the previous file: undo may need it)
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
    if (filter == _selectedFilter) return;

    // Snapshot current state so the user can undo this filter change.
    _pushUndo();

    setState(() {
      _isProcessing = true;
      _selectedFilter = filter;
    });

    try {
      final Uint8List resultBytes;

      if (filter == ScanFilter.original) {
        resultBytes = _originalImageBytes!;
      } else {
        // Process image in background isolate using int index for better serialization
        resultBytes = await compute(
          processImageInBackground,
          ImageFilterRequest(
            _originalImageBytes!,
            filter.index,
            imageQuality: widget.imageQuality,
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Filter error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveAndReturn() async {
    if (_processedImageBytes == null) return;

    setState(() => _isProcessing = true);

    try {
      // Save the processed image
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String fileName =
          'processed_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        leading: IconButton(
          icon: Icon(Icons.close, color: _colors.textPrimary),
          onPressed: () {
            // Delete the captured image asynchronously and go back.
            final originalPath = widget.imagePath;
            final currentPath = _currentImagePath;
            unawaited(
              File(originalPath).delete().catchError((Object e) {
                debugPrint('Error deleting: $e');
                return File(originalPath);
              }),
            );
            if (currentPath != originalPath) {
              unawaited(
                File(currentPath).delete().catchError((Object e) {
                  debugPrint('Error deleting: $e');
                  return File(currentPath);
                }),
              );
            }
            Navigator.pop(context);
          },
        ),
        title: Text(
          'Edit Scan',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: Icon(
              Icons.undo_rounded,
              color: _canUndo
                  ? _colors.textPrimary
                  : _colors.textPrimary.withValues(alpha: 0.3),
            ),
            onPressed: _canUndo && !_isProcessing ? _undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: Icon(
              Icons.redo_rounded,
              color: _canRedo
                  ? _colors.textPrimary
                  : _colors.textPrimary.withValues(alpha: 0.3),
            ),
            onPressed: _canRedo && !_isProcessing ? _redo : null,
          ),
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
                color: _colors.cardBackground,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _colors.shadowColor,
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_processedImageBytes != null)
                      Image.memory(_processedImageBytes!, fit: BoxFit.contain)
                    else
                      const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00D9FF),
                        ),
                      ),
                    if (_isProcessing)
                      Container(
                        color: _isDarkMode ? Colors.black54 : Colors.white54,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                color: Color(0xFF00D9FF),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Processing...',
                                style: TextStyle(
                                  color: _colors.textPrimary,
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
            decoration: BoxDecoration(
              color: _colors.cardBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(25),
              ),
              boxShadow: [
                BoxShadow(
                  color: _colors.shadowColor,
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // Crop button
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _cropImage,
                      icon: const Icon(
                        Icons.crop_rounded,
                        color: Color(0xFF00D9FF),
                      ),
                      label: const Text(
                        'Crop Image',
                        style: TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                          color: Color(0xFF00D9FF),
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Text(
                    'Select Filter',
                    style: TextStyle(
                      color: _colors.textSecondary,
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
                        ScanFilter.auto,
                        'Auto',
                        Icons.auto_fix_high,
                      ),
                      _buildFilterOption(
                        ScanFilter.document,
                        'Document',
                        Icons.article_outlined,
                      ),
                      _buildFilterOption(
                        ScanFilter.magicColor,
                        'Magic',
                        Icons.auto_awesome,
                      ),
                      _buildFilterOption(
                        ScanFilter.blackWhite,
                        'B&W',
                        Icons.contrast,
                      ),
                      _buildFilterOption(
                        ScanFilter.grayscale,
                        'Gray',
                        Icons.filter_b_and_w,
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
                    : _isDarkMode
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? const Color(0xFF00D9FF) : _colors.divider,
                  width: 2,
                ),
              ),
              child: Icon(
                icon,
                color: isSelected ? Colors.white : _colors.textSecondary,
                size: 28,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFF00D9FF)
                    : _colors.textSecondary,
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

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  void _onCrop() {
    setState(() => _isCropping = true);
    _cropController.crop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        leading: IconButton(
          icon: Icon(Icons.close, color: _colors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Crop Document',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
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
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Crop(
                  image: widget.imageBytes,
                  controller: _cropController,
                  aspectRatio: _aspectRatio,
                  baseColor: _colors.background,
                  maskColor: _isDarkMode
                      ? Colors.black.withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.7),
                  initialSize: 0.9,
                  onStatusChanged: (status) {
                    if (status == CropStatus.cropping) {
                      setState(() => _isCropping = true);
                    }
                  },
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

            // Aspect ratio controls
            Container(
              padding: const EdgeInsets.only(
                top: 16,
                bottom: 16,
                left: 16,
                right: 16,
              ),
              decoration: BoxDecoration(
                color: _colors.cardBackground,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(25),
                ),
                boxShadow: [
                  BoxShadow(
                    color: _colors.shadowColor,
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Aspect Ratio',
                      style: TextStyle(
                        color: _colors.textSecondary,
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
                        // Free first
                        _buildAspectButton('Free', null),
                        // Paper sizes
                        _buildAspectButton('A4', 210 / 297),
                        _buildAspectButton('Letter', 8.5 / 11),
                        _buildAspectButton('Legal', 8.5 / 14),
                        _buildAspectButton('A5', 148 / 210),
                        // Common ratios
                        _buildAspectButton('1:1', 1.0),
                        _buildAspectButton('4:3', 4 / 3),
                        _buildAspectButton('3:2', 3 / 2),
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
              : _isDarkMode
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF00D9FF) : _colors.divider,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : _colors.textSecondary,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// Immutable snapshot used by the undo/redo stacks in [_ScanEditScreenState].
class _EditSnapshot {
  const _EditSnapshot({
    required this.originalBytes,
    required this.processedBytes,
    required this.imagePath,
    required this.filter,
  });

  final Uint8List? originalBytes;
  final Uint8List? processedBytes;
  final String imagePath;
  final ScanFilter filter;
}
