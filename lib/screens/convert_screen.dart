import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../services/pdf_service.dart';
import 'scan_edit_screen.dart';

class ConvertScreen extends StatefulWidget {
  const ConvertScreen({super.key});

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isFlashOn = false;
  bool _isProcessing = false;
  bool _isCapturing = false;
  final List<String> _capturedImages = [];
  final ImagePicker _imagePicker = ImagePicker();
  
  // Focus related
  Offset? _focusPoint;
  bool _showFocusIndicator = false;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _focusTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
      _isCameraInitialized = false;
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        _cameraController = CameraController(
          _cameras![0],
          ResolutionPreset.high,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );

        await _cameraController!.initialize();
        
        // Set continuous auto focus mode
        try {
          await _cameraController!.setFocusMode(FocusMode.auto);
        } catch (e) {
          debugPrint('Auto focus not supported: $e');
        }
        
        if (mounted) {
          setState(() {
            _isCameraInitialized = true;
          });
        }
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  Future<void> _onTapToFocus(TapUpDetails details, Size previewSize) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    // Cancel any existing focus timer to allow immediate refocus
    _focusTimer?.cancel();

    final Offset tapPosition = details.localPosition;
    
    // Calculate normalized coordinates (0.0 to 1.0)
    double x = (tapPosition.dx / previewSize.width).clamp(0.0, 1.0);
    double y = (tapPosition.dy / previewSize.height).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = tapPosition;
      _showFocusIndicator = true;
    });

    try {
      // Set focus point
      await _cameraController!.setFocusMode(FocusMode.auto);
      await _cameraController!.setFocusPoint(Offset(x, y));
      
      // Set exposure point
      try {
        await _cameraController!.setExposurePoint(Offset(x, y));
      } catch (e) {
        debugPrint('Exposure point not supported: $e');
      }
    } catch (e) {
      debugPrint('Error setting focus: $e');
    }

    // Hide focus indicator after delay
    _focusTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          _showFocusIndicator = false;
        });
      }
    });
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    
    try {
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }
      setState(() {
        _isFlashOn = !_isFlashOn;
      });
    } catch (e) {
      debugPrint('Error toggling flash: $e');
    }
  }

  Future<void> _captureImage() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      // Turn off flash for capture if it was on as torch
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      }

      final XFile image = await _cameraController!.takePicture();
      
      // Save to app's document directory
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String fileName = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String savedPath = '${appDir.path}/$fileName';
      await File(image.path).copy(savedPath);

      // Restore torch if it was on
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }

      setState(() => _isCapturing = false);

      // Navigate to edit screen
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ScanEditScreen(
              imagePath: savedPath,
              onSave: (processedPath) {
                setState(() {
                  _capturedImages.add(processedPath);
                });
                _showSnackBar('Page added! (${_capturedImages.length} total)');
              },
            ),
          ),
        );
      }
    } catch (e) {
      _showSnackBar('Error capturing image: $e', isError: true);
      setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final List<XFile> images = await _imagePicker.pickMultiImage(
        imageQuality: 90,
      );

      if (images.isNotEmpty) {
        final Directory appDir = await getApplicationDocumentsDirectory();
        
        // Process first image through the edit screen
        final image = images[0];
        final String fileName = 'picked_${DateTime.now().millisecondsSinceEpoch}_0.jpg';
        final String savedPath = '${appDir.path}/$fileName';
        await File(image.path).copy(savedPath);
        
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ScanEditScreen(
                imagePath: savedPath,
                onSave: (processedPath) async {
                  setState(() {
                    _capturedImages.add(processedPath);
                  });
                  
                  // Add remaining images directly
                  for (int i = 1; i < images.length; i++) {
                    final img = images[i];
                    final String fName = 'picked_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
                    final String sPath = '${appDir.path}/$fName';
                    await File(img.path).copy(sPath);
                    setState(() {
                      _capturedImages.add(sPath);
                    });
                  }
                  
                  if (images.length > 1) {
                    _showSnackBar('${images.length} image(s) added!');
                  }
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      _showSnackBar('Error selecting images: $e', isError: true);
    }
  }

  Future<void> _convertToPdf() async {
    if (_capturedImages.isEmpty) return;

    setState(() => _isProcessing = true);

    try {
      final String? outputPath = await PdfService.imagesToPdf(_capturedImages);

      if (outputPath != null) {
        _showSuccessDialog(outputPath);
      } else {
        _showSnackBar('Failed to create PDF', isError: true);
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
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 28),
            SizedBox(width: 10),
            Text('Success!', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          '${_capturedImages.length} page(s) converted to PDF!',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _capturedImages.clear();
              });
            },
            child: const Text('New Scan', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Share.shareXFiles([XFile(filePath)], text: 'Scanned PDF');
            },
            child: const Text('Share', style: TextStyle(color: Color(0xFFE94560))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              PdfService.openPdf(filePath);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D9FF),
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
        backgroundColor: isError ? Colors.red : const Color(0xFF00D9FF),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _removeImage(int index) {
    setState(() {
      try {
        File(_capturedImages[index]).deleteSync();
      } catch (e) {
        debugPrint('Error deleting file: $e');
      }
      _capturedImages.removeAt(index);
    });
  }

  void _editImage(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScanEditScreen(
          imagePath: _capturedImages[index],
          onSave: (processedPath) {
            setState(() {
              _capturedImages[index] = processedPath;
            });
            _showSnackBar('Page updated!');
          },
        ),
      ),
    );
  }

  void _showPreviewSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16213E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (sheetContext, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => SafeArea(
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      const Text(
                        'Scanned Pages',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_capturedImages.length} pages',
                        style: const TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.touch_app, color: Color(0xFF00D9FF), size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Tap a page to edit, crop & apply filters',
                            style: TextStyle(
                              color: Color(0xFF00D9FF),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                Expanded(
                  child: GridView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: _capturedImages.length,
                    itemBuilder: (context, index) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          _editImage(index);
                        },
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white24, width: 1),
                                image: DecorationImage(
                                  image: FileImage(File(_capturedImages[index])),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: 5,
                              left: 5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.edit, color: Colors.white70, size: 12),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 5,
                              right: 5,
                              child: GestureDetector(
                                onTap: () {
                                  _removeImage(index);
                                  if (_capturedImages.isEmpty) {
                                    Navigator.pop(context);
                                  } else {
                                    setModalState(() {});
                                    setState(() {});
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.8),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      onPressed: _isProcessing
                          ? null
                          : () {
                              Navigator.pop(context);
                              _convertToPdf();
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00D9FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.picture_as_pdf_rounded, color: Colors.white),
                          SizedBox(width: 10),
                          Text(
                            'Create PDF',
                            style: TextStyle(
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera Preview with tap to focus
          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final Size previewSize = Size(constraints.maxWidth, constraints.maxHeight);
                  return GestureDetector(
                    onTapUp: (details) => _onTapToFocus(details, previewSize),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(_cameraController!),
                        // Focus indicator
                        if (_showFocusIndicator && _focusPoint != null)
                          Positioned(
                            left: _focusPoint!.dx - 35,
                            top: _focusPoint!.dy - 35,
                            child: IgnorePointer(
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(begin: 1.2, end: 1.0),
                                duration: const Duration(milliseconds: 200),
                                builder: (context, scale, child) {
                                  return Transform.scale(
                                    scale: scale,
                                    child: Container(
                                      width: 70,
                                      height: 70,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: const Color(0xFF00D9FF),
                                          width: 2,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Center(
                                        child: Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFF00D9FF),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00D9FF)),
                  SizedBox(height: 20),
                  Text(
                    'Initializing Camera...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),

          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: topPadding + 10,
                left: 20,
                right: 20,
                bottom: 15,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Scan Document',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      // Tap to focus hint
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app, color: Colors.white60, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'Tap to focus',
                              style: TextStyle(color: Colors.white60, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _toggleFlash,
                        icon: Icon(
                          _isFlashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                          color: _isFlashOn ? const Color(0xFFFFC107) : Colors.white,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                bottom: bottomPadding + 20,
                top: 25,
                left: 30,
                right: 30,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildControlButton(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: _pickFromGallery,
                  ),
                  GestureDetector(
                    onTap: _isCapturing ? null : _captureImage,
                    child: Container(
                      width: 75,
                      height: 75,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: _isCapturing ? Colors.grey : const Color(0xFF00D9FF),
                          shape: BoxShape.circle,
                        ),
                        child: _isCapturing
                            ? const Center(
                                child: SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                ),
                              )
                            : const Icon(
                                Icons.camera_alt_rounded,
                                color: Colors.white,
                                size: 32,
                              ),
                      ),
                    ),
                  ),
                  _buildControlButton(
                    icon: _capturedImages.isEmpty
                        ? Icons.insert_drive_file_outlined
                        : Icons.collections_rounded,
                    label: _capturedImages.isEmpty ? 'Pages' : '${_capturedImages.length} Pages',
                    onTap: _capturedImages.isEmpty ? null : _showPreviewSheet,
                    badge: _capturedImages.isNotEmpty ? _capturedImages.length : null,
                  ),
                ],
              ),
            ),
          ),

          // Processing overlay
          if (_isProcessing)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.7),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF00D9FF)),
                      SizedBox(height: 20),
                      Text(
                        'Creating PDF...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    int? badge,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: onTap == null ? Colors.white38 : Colors.white,
                  size: 24,
                ),
              ),
              if (badge != null)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: const BoxDecoration(
                      color: Color(0xFFE94560),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: onTap == null ? Colors.white38 : Colors.white70,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
