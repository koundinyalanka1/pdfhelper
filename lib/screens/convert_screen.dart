import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../services/ads_service.dart';
import '../services/pdf_service.dart';
import '../services/permission_service.dart';
import '../services/scan_image_store.dart';
import '../services/scan_route_observer.dart';
import '../providers/theme_provider.dart';
import '../utils/file_naming.dart';
import '../widgets/pdf_name_dialog.dart';
import 'pdf_preview_screen.dart';
import 'scan_edit_screen.dart';

class ConvertScreen extends StatefulWidget {
  const ConvertScreen({super.key, this.isActive = true});

  final bool isActive;

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin, RouteAware {
  @override
  bool get wantKeepAlive => true;

  CameraController? _cameraController;
  Future<void>? _cameraInitialization;
  bool _cameraActive = false;
  bool _appResumed = true;
  bool _routeVisible = false;
  bool _isPicking = false;
  ModalRoute<dynamic>? _scanRoute;
  Future<void>? _cameraDisposal;
  Future<XFile>? _captureInFlight;
  CameraController? _captureController;
  final ScanImageStore _images = ScanImageStore();
  int _cameraGeneration = 0;
  bool _isCameraInitialized = false;
  bool _cameraPermissionDenied = false;
  bool _cameraPermissionPermanentlyDenied = false;
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
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appResumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_scanRoute != route) {
      scanRouteObserver.unsubscribe(this);
      _scanRoute = route;
      _routeVisible = route?.isCurrent ?? false;
      if (route != null) scanRouteObserver.subscribe(this, route);
    }
    _syncCameraOwnership();
  }

  @override
  void didUpdateWidget(ConvertScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _syncCameraOwnership();
  }

  @override
  void didPush() {
    _routeVisible = _scanRoute?.isCurrent ?? false;
    _syncCameraOwnership();
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _syncCameraOwnership();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _syncCameraOwnership();
  }

  @override
  void didPop() {
    _routeVisible = false;
    _syncCameraOwnership();
  }

  @override
  void dispose() {
    _cameraActive = false;
    _cameraGeneration++;
    scanRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) unawaited(_closeCamera(controller));
    unawaited(_images.dispose());
    _focusTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncCameraOwnership();
  }

  void _syncCameraOwnership() {
    final active =
        mounted &&
        widget.isActive &&
        _routeVisible &&
        _appResumed &&
        !_isPicking;
    if (active == _cameraActive) return;
    _cameraActive = active;
    _cameraGeneration++;
    if (active) {
      unawaited(_checkCameraAndInit());
      return;
    }
    final controller = _cameraController;
    _cameraController = null;
    _focusTimer?.cancel();
    setState(() {
      _isCameraInitialized = false;
      _isFlashOn = false;
      _showFocusIndicator = false;
    });
    if (controller != null) _cameraDisposal = _closeCamera(controller);
  }

  Future<void> _closeCamera(CameraController controller) async {
    try {
      await controller.setFlashMode(FlashMode.off);
    } catch (_) {
      // Disposal still releases a controller that cannot accept flash changes.
    }
    if (identical(_captureController, controller)) {
      try {
        // CameraController updates its value when takePicture completes. Let
        // that finish before disposal so the returned cache file can be cleaned.
        await _captureInFlight;
      } catch (_) {
        // A failed exposure must still release the camera.
      }
    }
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint('Error releasing camera: $error');
    }
  }

  Future<void> _checkCameraAndInit() async {
    if (!mounted || !_cameraActive) return;
    final granted = await PermissionService.isGranted(Permission.camera);
    if (granted) {
      await _initializeCamera();
      return;
    }
    if (!mounted) return;
    final permanentlyDenied = await Permission.camera.isPermanentlyDenied;
    if (!mounted) return;
    setState(() {
      _cameraPermissionDenied = true;
      _cameraPermissionPermanentlyDenied = permanentlyDenied;
    });
  }

  Future<void> _requestCameraPermission() async {
    if (!mounted) return;
    final granted = await PermissionService.requestWithRationale(
      context: context,
      permission: Permission.camera,
      rationaleTitle: 'Camera Access',
      rationaleMessage:
          'PDF Helper needs camera access to scan documents and convert them to PDF.',
      deniedTitle: 'Camera Permission Required',
      deniedMessage:
          'Camera access was denied. Please enable it in Settings to scan documents.',
      settingsButtonText: 'Open Settings',
      cancelButtonText: 'Not Now',
    );
    if (!mounted) return;
    if (granted) {
      setState(() {
        _cameraPermissionDenied = false;
        _cameraPermissionPermanentlyDenied = false;
      });
      await _initializeCamera();
    } else {
      final permanentlyDenied = await Permission.camera.isPermanentlyDenied;
      if (!mounted) return;
      setState(() {
        _cameraPermissionDenied = true;
        _cameraPermissionPermanentlyDenied = permanentlyDenied;
      });
    }
  }

  Future<void> _openAppSettings() async {
    await openAppSettings();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    final granted = await PermissionService.isGranted(Permission.camera);
    if (granted) {
      setState(() {
        _cameraPermissionDenied = false;
        _cameraPermissionPermanentlyDenied = false;
      });
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraInitialization != null) {
      await _cameraInitialization;
      if (mounted && _cameraActive && !_isCameraInitialized) {
        await _initializeCamera();
      }
      return;
    }
    if (!mounted || !_cameraActive || _isCameraInitialized) return;
    final pending = _initializeCameraOnce();
    _cameraInitialization = pending;
    try {
      await pending;
    } finally {
      if (identical(_cameraInitialization, pending)) {
        _cameraInitialization = null;
      }
    }
  }

  Future<void> _initializeCameraOnce() async {
    final generation = _cameraGeneration;
    CameraController? controller;
    try {
      await _cameraDisposal;
      if (!mounted || !_cameraActive || generation != _cameraGeneration) return;
      final cameras = await availableCameras();
      if (!mounted ||
          !_cameraActive ||
          generation != _cameraGeneration ||
          cameras.isEmpty) {
        return;
      }
      controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {
        // Cameras without a flash can still provide a usable preview.
      }
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted || !_cameraActive || generation != _cameraGeneration) return;
      _cameraController = controller;
      controller = null; // Ownership passes to the screen.
      setState(() {
        _isCameraInitialized = true;
        _cameraPermissionDenied = false;
      });
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted && _cameraActive) {
        _showSnackBar(
          'Camera unavailable. You can still add images from the gallery.',
          isError: true,
        );
      }
    } finally {
      if (controller != null) await _closeCamera(controller);
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
    final controller = _cameraController;
    if (controller == null || !_cameraActive || _isCapturing) return;
    final next = !_isFlashOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted && identical(controller, _cameraController)) {
        setState(() => _isFlashOn = next);
      }
    } catch (error) {
      debugPrint('Error toggling flash: $error');
    }
  }

  Future<void> _captureImage() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        !_cameraActive ||
        _isCapturing ||
        _isProcessing) {
      return;
    }
    setState(() => _isCapturing = true);
    String? cameraPath;
    String? source;
    try {
      // Keep the user's preview illumination throughout the exposure.
      _captureController = controller;
      final pending = controller.takePicture();
      _captureInFlight = pending;
      final image = await pending;
      cameraPath = image.path;
      if (!mounted ||
          !_cameraActive ||
          !identical(controller, _cameraController)) {
        return;
      }
      source = await _images.importFile(cameraPath);
      if (!mounted ||
          !_cameraActive ||
          !identical(controller, _cameraController)) {
        return;
      }
      await _editNewImages([source]);
    } catch (error) {
      _showSnackBar('Error capturing image: $error', isError: true);
    } finally {
      _captureInFlight = null;
      _captureController = null;
      if (source != null) await _images.delete(source);
      if (cameraPath != null) {
        try {
          await File(cameraPath).delete();
        } on FileSystemException catch (error) {
          debugPrint('Could not remove camera temporary file: $error');
        }
      }
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isPicking || _isCapturing || _isProcessing) return;
    _isPicking = true;
    _syncCameraOwnership();
    final imported = <String>[];
    try {
      final quality = context.read<ThemeProvider>().outputQualityAsImageQuality;
      final selected = await _imagePicker.pickMultiImage(
        imageQuality: quality.clamp(1, 100),
      );
      if (!mounted || !widget.isActive || !_routeVisible) return;
      for (final image in selected) {
        imported.add(await _images.importFile(image.path));
      }
      if (mounted && widget.isActive && _routeVisible && imported.isNotEmpty) {
        await _editNewImages(imported);
      }
    } catch (error) {
      _showSnackBar('Error selecting images: $error', isError: true);
    } finally {
      // Gallery originals remain untouched. Only copies not accepted into the
      // scan draft are discarded, including every image in a cancelled batch.
      for (final path in imported) {
        if (!_capturedImages.contains(path)) await _images.delete(path);
      }
      _isPicking = false;
      if (mounted) _syncCameraOwnership();
    }
  }

  Future<void> _editNewImages(List<String> sources) async {
    if (!mounted) return;
    final quality = context.read<ThemeProvider>().outputQualityAsImageQuality;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ScanEditScreen(
          imagePath: sources.first,
          imageQuality: quality,
          onSave: (processedPath) {
            _images.adopt(processedPath);
            if (!mounted) return;
            setState(
              () => _capturedImages.addAll([processedPath, ...sources.skip(1)]),
            );
            _showSnackBar('${sources.length} page(s) added!');
          },
        ),
      ),
    );
  }

  void _clearSavedImages() {
    // Only called after saving succeeds. A failed save/preview cancellation
    // leaves all images available for retry.
    final saved = _capturedImages.toList();
    if (mounted) setState(() => _capturedImages.clear());
    for (final path in saved) {
      unawaited(_images.delete(path));
    }
  }

  Future<void> _convertToPdf() async {
    if (_isProcessing || _capturedImages.isEmpty) return;

    // Asked before any work starts: the name travels into the output file
    // itself, so there is nothing to rewrite afterwards, and backing out here
    // costs the user nothing.
    final fileName = await askPdfName(
      context: context,
      initialName: defaultPdfName('Scan'),
      hint: '${_capturedImages.length} page(s)',
    );
    if (fileName == null || !mounted) return;

    setState(() => _isProcessing = true);

    try {
      final themeProvider = context.read<ThemeProvider>();
      final outputQuality = themeProvider.outputQuality;
      final pages = List<String>.of(_capturedImages);
      final String? outputPath = await _images.retainWhile(
        () => PdfService.imagesToPdf(
          pages,
          outputQuality: outputQuality,
          fileName: fileName,
        ),
      );

      if (outputPath != null) {
        if (!mounted) return;
        await AdsService.instance.operationCompleted(
          PdfOperation.create,
          canPresent: () =>
              mounted &&
              widget.isActive &&
              (ModalRoute.of(context)?.isCurrent ?? false),
        );
        if (!mounted) return;
        if (themeProvider.skipPreview && themeProvider.autoSave) {
          // Fast path: save immediately, skip the preview screen.
          await autoSavePdfs(
            themeProvider: themeProvider,
            filePaths: [outputPath],
            sourceType: PdfPreviewSourceType.convert,
            pageCount: _capturedImages.length,
            fileName: fileName,
          );
          if (!mounted) return;
          _showSnackBar(
            'Saved $fileName.pdf to ${themeProvider.saveLocationDescription} '
            '(${_capturedImages.length} page(s))',
          );
          _clearSavedImages();
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfPreviewScreen(
                filePaths: [outputPath],
                sourceType: PdfPreviewSourceType.convert,
                pageCount: _capturedImages.length,
                fileName: fileName,
                onSaved: () {
                  if (mounted) _clearSavedImages();
                },
              ),
            ),
          );
        }
      } else {
        _showSnackBar('Failed to create PDF', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFF00D9FF),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildPermissionDeniedUi() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.camera_alt_outlined,
                size: 64,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Camera Access Required',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _cameraPermissionPermanentlyDenied
                  ? 'Camera permission was denied. Please enable it in Settings to scan documents.'
                  : 'PDF Helper needs camera access to scan documents and convert them to PDF.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 15,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (_cameraPermissionPermanentlyDenied)
              FilledButton.icon(
                onPressed: _openAppSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00D9FF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: _requestCameraPermission,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Grant Camera Access'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00D9FF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _removeImage(int index) {
    final path = _capturedImages[index];
    setState(() => _capturedImages.removeAt(index));
    unawaited(_images.delete(path));
  }

  void _editImage(int index) {
    final original = _capturedImages[index];
    final quality = context.read<ThemeProvider>().outputQualityAsImageQuality;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScanEditScreen(
          imagePath: original,
          imageQuality: quality,
          onSave: (processedPath) {
            _images.adopt(processedPath);
            if (!mounted) return;
            final currentIndex = _capturedImages.indexOf(original);
            if (currentIndex < 0) {
              unawaited(_images.delete(processedPath));
              return;
            }
            setState(() => _capturedImages[currentIndex] = processedPath);
            unawaited(_images.delete(original));
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
                        Icon(
                          Icons.touch_app,
                          color: Color(0xFF00D9FF),
                          size: 20,
                        ),
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
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
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
                                border: Border.all(
                                  color: Colors.white24,
                                  width: 1,
                                ),
                                image: DecorationImage(
                                  image: FileImage(
                                    File(_capturedImages[index]),
                                  ),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: 5,
                              left: 5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
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
                                    const Icon(
                                      Icons.edit,
                                      color: Colors.white70,
                                      size: 12,
                                    ),
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
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                    size: 16,
                                  ),
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
                          Icon(
                            Icons.picture_as_pdf_rounded,
                            color: Colors.white,
                          ),
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
    super.build(context);
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
                  final Size previewSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
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
          else if (_cameraPermissionDenied)
            _buildPermissionDeniedUi()
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.touch_app,
                              color: Colors.white60,
                              size: 14,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Tap to focus',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: _isFlashOn
                            ? 'Turn flash off'
                            : 'Turn flash on',
                        onPressed: _toggleFlash,
                        icon: Icon(
                          _isFlashOn
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          color: _isFlashOn
                              ? const Color(0xFFFFC107)
                              : Colors.white,
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
                  Semantics(
                    label: _isCapturing
                        ? 'Capturing, please wait'
                        : 'Take photo',
                    button: true,
                    enabled: !_isCapturing,
                    child: GestureDetector(
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
                            color: _isCapturing
                                ? Colors.grey
                                : const Color(0xFF00D9FF),
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
                  ),
                  _buildControlButton(
                    icon: _capturedImages.isEmpty
                        ? Icons.insert_drive_file_outlined
                        : Icons.collections_rounded,
                    label: _capturedImages.isEmpty
                        ? 'Pages'
                        : '${_capturedImages.length} Pages',
                    onTap: _capturedImages.isEmpty ? null : _showPreviewSheet,
                    badge: _capturedImages.isNotEmpty
                        ? _capturedImages.length
                        : null,
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
