import 'dart:ui' as ui;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../providers/theme_provider.dart';
import '../utils/document_detector.dart';
import '../utils/error_logger.dart';
import '../utils/perspective.dart';
import '../widgets/quad_crop_view.dart';

/// Which kind of crop the user is making.
enum CropMode {
  /// Four independent corners, warped back to a rectangle. The mode that
  /// handles a page photographed at an angle.
  corners,

  /// An axis-aligned rectangle, optionally locked to a paper ratio. Nothing
  /// is resampled, so it stays the right choice for a photo that is already
  /// square to the camera.
  rectangle,
}

/// Crop and straighten one captured page.
///
/// Pops [Uint8List] JPEG bytes, or null when the user backs out.
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.imageBytes,
    this.jpegQuality = 92,
  });

  final Uint8List imageBytes;

  /// Quality the straightened result is re-encoded at. Perspective correction
  /// resamples every pixel, so unlike a rectangle crop it cannot hand the
  /// original bytes back untouched.
  final int jpegQuality;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  static const Color _accent = Color(0xFF00D9FF);

  /// Preview decode ceiling. The warp runs against the original bytes, so
  /// this only bounds what the GPU holds while the user is dragging.
  static const int _previewMaxSide = 1600;

  CropMode _mode = CropMode.corners;

  ui.Image? _preview;
  CropQuad _quad = CropQuad.full(inset: 0.06);

  bool _detecting = true;
  bool _processing = false;

  /// The preview could not be decoded at all. Rare (a truncated capture, an
  /// unsupported colour profile) but it must not look like a spinner that
  /// never finishes.
  bool _previewFailed = false;

  /// Whether the quad on screen came from the detector or is just the default
  /// box — worth saying, because it tells the user whether to trust it.
  bool _detected = false;

  // Rectangle mode.
  final CropController _cropController = CropController();
  double? _aspectRatio;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    _loadPreview();
    _detectEdges();
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.imageBytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final longest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final scale = longest > _previewMaxSide ? _previewMaxSide / longest : 1.0;
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round(),
        targetHeight: (descriptor.height * scale).round(),
      );
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _preview = frame.image);
    } catch (e) {
      logError('CropScreen.loadPreview', e);
      if (mounted) {
        setState(() {
          _preview = null;
          _previewFailed = true;
        });
      }
    }
  }

  /// Ask the detector where the page is. Advisory: a failure just leaves the
  /// default box in place.
  Future<void> _detectEdges({bool announce = false}) async {
    setState(() => _detecting = true);
    List<double>? corners;
    try {
      corners = await compute(detectDocumentCorners, widget.imageBytes);
    } catch (e) {
      logError('CropScreen.detectEdges', e);
    }
    if (!mounted) return;
    setState(() {
      _detecting = false;
      _detected = corners != null;
      if (corners != null) _quad = CropQuad.fromList(corners);
    });
    if (announce) {
      _toast(
        corners != null
            ? 'Page edges detected'
            : 'No page edges found — drag the corners yourself',
      );
    }
  }

  Future<void> _done() async {
    if (_mode == CropMode.rectangle) {
      setState(() => _processing = true);
      _cropController.crop();
      return;
    }

    final preview = _preview;
    if (preview == null) return;
    setState(() => _processing = true);
    try {
      final bytes = await compute(
        warpDocument,
        WarpRequest(
          imageBytes: widget.imageBytes,
          corners: _quad.toList(),
          jpegQuality: widget.jpegQuality,
          // "Maximum" quality asks for the detail to be kept, so give the
          // resampled page more room before the cap bites.
          maxOutputSide: widget.jpegQuality >= 95 ? 3000 : 2400,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, bytes);
    } catch (e) {
      logError('CropScreen.warp', e);
      if (!mounted) return;
      setState(() => _processing = false);
      _toast('Could not straighten that image.');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        leading: IconButton(
          icon: Icon(Icons.close, color: _colors.textPrimary),
          onPressed: _processing ? null : () => Navigator.pop(context),
        ),
        title: Text(
          _mode == CropMode.corners ? 'Crop & Straighten' : 'Crop Document',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _processing ? null : _done,
            child: _processing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: _accent,
                      strokeWidth: 2,
                    ),
                  )
                : const Text(
                    'Done',
                    style: TextStyle(
                      color: _accent,
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
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _mode == CropMode.corners
                    ? _buildCornerMode()
                    : _buildRectangleMode(),
              ),
            ),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildCornerMode() {
    final preview = _preview;
    if (preview == null) {
      if (!_previewFailed) {
        return const Center(child: CircularProgressIndicator(color: _accent));
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 40,
              color: _colors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              'Could not open that photo for corner editing.\nTry the '
              'Rectangle mode instead.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _colors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        QuadCropView(
          image: preview,
          quad: _quad,
          onChanged: (quad) => setState(() {
            _quad = quad;
            _detected = false;
          }),
          accent: _accent,
          isDarkMode: _colors.isDark,
        ),
        if (_detecting)
          Align(
            alignment: Alignment.topCenter,
            child: _pill(
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
              'Looking for the page…',
            ),
          )
        else if (_detected)
          Align(
            alignment: Alignment.topCenter,
            child: _pill(
              const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
              'Page edges detected',
            ),
          ),
      ],
    );
  }

  Widget _pill(Widget leading, String label) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildRectangleMode() {
    return Crop(
      image: widget.imageBytes,
      controller: _cropController,
      aspectRatio: _aspectRatio,
      baseColor: _colors.background,
      maskColor: _colors.isDark
          ? Colors.black.withValues(alpha: 0.7)
          : Colors.white.withValues(alpha: 0.7),
      initialRectBuilder: InitialRectBuilder.withSizeAndRatio(
        size: 0.9,
        aspectRatio: _aspectRatio,
      ),
      onStatusChanged: (status) {
        if (status == CropStatus.cropping) setState(() => _processing = true);
      },
      cornerDotBuilder: (size, edgeAlignment) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _accent,
          borderRadius: BorderRadius.circular(size / 2),
          border: Border.all(color: Colors.white, width: 2),
        ),
      ),
      onCropped: (result) {
        setState(() => _processing = false);
        switch (result) {
          case CropSuccess(:final croppedImage):
            Navigator.pop(context, croppedImage);
          case CropFailure(:final cause):
            logError('CropScreen', cause);
            _toast('Could not crop that image.');
        }
      },
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        boxShadow: [
          BoxShadow(
            color: _colors.shadowColor,
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeToggle(),
          const SizedBox(height: 14),
          if (_mode == CropMode.corners)
            ..._cornerControls()
          else
            ..._rectangleControls(),
        ],
      ),
    );
  }

  Widget _buildModeToggle() {
    Widget tab(CropMode mode, IconData icon, String label) {
      final selected = _mode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: _processing ? null : () => setState(() => _mode = mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? _accent : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? Colors.white : _colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : _colors.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _colors.isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          tab(CropMode.corners, Icons.transform_rounded, 'Corners'),
          tab(CropMode.rectangle, Icons.crop_rounded, 'Rectangle'),
        ],
      ),
    );
  }

  List<Widget> _cornerControls() {
    return [
      Text(
        'Drag the four corners — or an edge — onto the page. '
        'The crop is flattened back to a rectangle.',
        textAlign: TextAlign.center,
        style: TextStyle(color: _colors.textSecondary, fontSize: 12),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _processing || _detecting
                  ? null
                  : () => _detectEdges(announce: true),
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Detect edges'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accent,
                side: const BorderSide(color: _accent, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _processing
                  ? null
                  : () => setState(() {
                      _quad = CropQuad.full();
                      _detected = false;
                    }),
              icon: const Icon(Icons.select_all_rounded, size: 18),
              label: const Text('Whole photo'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _colors.textSecondary,
                side: BorderSide(color: _colors.divider, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _rectangleControls() {
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          'Aspect Ratio',
          style: TextStyle(
            color: _colors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _aspectButton('Free', null),
            _aspectButton('A4', 210 / 297),
            _aspectButton('Letter', 8.5 / 11),
            _aspectButton('Legal', 8.5 / 14),
            _aspectButton('A5', 148 / 210),
            _aspectButton('1:1', 1.0),
            _aspectButton('4:3', 4 / 3),
            _aspectButton('3:2', 3 / 2),
          ],
        ),
      ),
    ];
  }

  Widget _aspectButton(String label, double? ratio) {
    final isSelected = _aspectRatio == ratio;

    return GestureDetector(
      onTap: () {
        setState(() => _aspectRatio = ratio);
        _cropController.aspectRatio = ratio;
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? _accent
              : _colors.isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _accent : _colors.divider,
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
