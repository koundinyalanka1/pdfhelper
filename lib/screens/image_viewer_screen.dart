import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/ads_service.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_service.dart';
import '../utils/error_logger.dart';
import '../utils/format_utils.dart';
import '../utils/photo_import.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/pdf_result_dialog.dart';
import 'pdf_viewer_screen.dart' show doubleTapZoomTarget;

/// Shows a picture (JPEG, PNG, WebP, GIF, BMP, and HEIC/HEIF where the
/// phone decodes it) on a dark background, as a photo viewer does: pinch or
/// double-tap to zoom, turn the view, see its details, share it, or make a
/// one-page PDF of it.
///
/// The file itself is never changed. Turning only turns the view (and the
/// page of a PDF made from it).
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  /// Pictures longer than this on either side are decoded smaller. A 50 MP
  /// photo decoded whole takes 200 MB; this keeps it near 50 MB and still
  /// sharp at the zoom a phone screen can show.
  static const int maxDecodeSide = 4096;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

enum _Problem { missing, unreadable }

class _ImageViewerScreenState extends State<ImageViewerScreen>
    with SingleTickerProviderStateMixin {
  final _zoom = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onZoomAnimation);
  Animation<Matrix4>? _zoomTween;

  bool _loading = true;
  _Problem? _problem;
  _PictureFacts? _facts;
  ImageProvider? _image;

  /// Quarter turns clockwise the view is turned by.
  int _turns = 0;

  /// Fingers on the picture. A double-tap recognizer competing with a pinch
  /// delays or swallows the zoom (flutter/flutter#58636), so it stands down
  /// while two are down, as in the PDF viewer.
  int _pointers = 0;

  bool _makingPdf = false;

  Color get _accent => DocKind.image.color;

  String get _name => widget.title ?? documentDisplayName(widget.path);

  /// The name offered for a PDF of the picture: [_name] without its
  /// extension. A title given by the caller loses only an extension known to
  /// be one, so "Mr. Bean" stays whole.
  String get _pdfName {
    final name = _name;
    final extension = DocKind.extensionOf(name);
    final known =
        DocKind.ofPath(name) != DocKind.other ||
        _ImageFormat.ofExtension(extension) != null;
    if (extension.isEmpty || (widget.title != null && !known)) return name;
    return name.substring(0, name.length - extension.length - 1);
  }

  String get _mimeType =>
      (_facts?.format ??
              _ImageFormat.ofExtension(DocKind.extensionOf(widget.path)))
          ?.mimeType ??
      DocKind.mimeTypeOf(widget.path);

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void dispose() {
    // A decoded photo can hold tens of megabytes in the image cache; nothing
    // else shows it once the viewer closes.
    unawaited(_image?.evict());
    _zoomAnimation.dispose();
    _zoom.dispose();
    super.dispose();
  }

  /// Reads what the details sheet shows, and whether the picture can be
  /// decoded at all, from its header: the pixels are not decoded here.
  Future<void> _inspect() async {
    final file = File(widget.path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      if (mounted) {
        setState(() {
          _loading = false;
          _problem = _Problem.missing;
        });
      }
      return;
    }
    _ImageFormat? format;
    try {
      format = _ImageFormat.sniff(await _readHead(widget.path));
    } catch (e) {
      logError('ImageViewer.readHead', e);
    }
    format ??= _ImageFormat.ofExtension(DocKind.extensionOf(widget.path));

    int? width;
    int? height;
    int? frames;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(widget.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
      // Creating the codec reads the frame count without decoding a frame.
      codec = await descriptor.instantiateCodec();
      frames = codec.frameCount;
    } catch (e) {
      logError('ImageViewer.inspect', e);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _facts = _PictureFacts(
        format: format,
        bytes: stat.size,
        modified: stat.modified,
        width: width,
        height: height,
        frames: frames,
      );
      if (width == null || height == null || width <= 0 || height <= 0) {
        _problem = _Problem.unreadable;
      } else {
        _image = _providerFor(width, height);
      }
    });
  }

  static Future<Uint8List> _readHead(String path) async {
    final file = await File(path).open();
    try {
      return await file.read(32);
    } finally {
      await file.close();
    }
  }

  ImageProvider _providerFor(int width, int height) {
    final image = FileImage(File(widget.path));
    const limit = ImageViewerScreen.maxDecodeSide;
    if (math.max(width, height) <= limit) return image;
    return ResizeImage(
      image,
      width: limit,
      height: limit,
      policy: ResizeImagePolicy.fit,
    );
  }

  /// The header read, but the picture itself would not decode (a damaged
  /// file, usually). Called from the image's error builder, during a build.
  void _onDecodeFailed(Object error) {
    logError('ImageViewer.decode', error);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _problem == null) {
        setState(() => _problem = _Problem.unreadable);
      }
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // -------------------------------------------------------------- zooming

  void _onZoomAnimation() {
    final tween = _zoomTween;
    if (tween != null) _zoom.value = tween.value;
  }

  /// Double-tap toggles between the whole picture and 2.5x, centred on the
  /// tap, as in the PDF viewer.
  void _onDoubleTap(TapDownDetails details) {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    _zoomTween =
        Matrix4Tween(
          begin: _zoom.value,
          end: doubleTapZoomTarget(
            isZoomed: zoomed,
            focalPoint: details.localPosition,
          ),
        ).animate(
          CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic),
        );
    _zoomAnimation.forward(from: 0);
  }

  void _setPointers(int count) {
    final wasMulti = _pointers >= 2;
    _pointers = math.max(0, count);
    if (wasMulti != (_pointers >= 2)) setState(() {});
  }

  void _rotate() {
    _zoomAnimation.stop();
    setState(() {
      _turns = (_turns + 1) % 4;
      _zoom.value = Matrix4.identity();
    });
  }

  // ------------------------------------------------------------- actions

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(widget.path, mimeType: _mimeType)]),
      );
    } catch (e) {
      logError('ImageViewer.share', e);
    }
  }

  Future<void> _openElsewhere() async {
    try {
      final result = await OpenFile.open(widget.path, type: _mimeType);
      if (result.type == ResultType.done) return;
      _snack(
        result.type == ResultType.noAppToOpen
            ? 'No app on this phone can open $_name.'
            : 'Could not open $_name: ${result.message}',
      );
    } catch (e) {
      logError('ImageViewer.openElsewhere', e);
      _snack('Could not open $_name.');
    }
  }

  Future<void> _makePdf() async {
    if (_makingPdf) return;
    if (!PdfCoreService.isAvailable) {
      _snack('The native PDF core is not built, so this is unavailable.');
      return;
    }
    final name = await askPdfName(
      context: context,
      initialName: _pdfName,
      hint: _turns == 0
          ? 'One page, shaped like the picture.'
          : 'One page, turned the way it is shown.',
      accent: _accent,
    );
    if (name == null || !mounted) return;
    final settings = context.read<ThemeProvider>();
    setState(() => _makingPdf = true);
    String? output;
    try {
      output = await _pictureToPdf(
        widget.path,
        name,
        quality: settings.outputQuality,
        qualityPercent: settings.outputQualityAsImageQuality,
        turns: _turns,
        platformFirst: _facts?.format?.needsPlatformCodec ?? false,
      );
    } catch (e) {
      logError('ImageViewer.makePdf', e);
    }
    if (!mounted) return;
    setState(() => _makingPdf = false);
    if (output == null) {
      _snack('Could not make a PDF of this picture.');
      return;
    }
    await showPdfResultDialog(
      context: context,
      filePaths: [output],
      operation: PdfOperation.create,
      accent: _accent,
      message: 'The picture is now a one-page PDF.',
    );
  }

  Future<void> _showDetails() {
    final facts = _facts;
    final width = facts?.width;
    final height = facts?.height;
    final frames = facts?.frames ?? 1;
    final format = facts?.format;
    final extension = DocKind.extensionOf(widget.path);
    final rows = <(String, String)>[
      ('Name', _name),
      (
        'Pixels',
        width == null || height == null || _problem != null
            ? 'Unreadable'
            : _pixelSize(width, height),
      ),
      (
        'Type',
        [
          format?.label ??
              (extension.isEmpty ? 'Unknown' : extension.toUpperCase()),
          if (frames > 1) 'animated, ${formatCount(frames)} frames',
        ].join(', '),
      ),
      if (facts != null) ('Size', formatFileSize(facts.bytes)),
      if (facts != null)
        ('Modified', formatLibraryDate(facts.modified, long: true)),
    ];
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DetailsSheet(rows: rows),
    );
  }

  static String _pixelSize(int width, int height) {
    final megapixels = width * height / 1000000;
    final size = '${formatCount(width)} × ${formatCount(height)}';
    return megapixels >= 1
        ? '$size (${megapixels.toStringAsFixed(1)} MP)'
        : size;
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _problem == null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('image-rotate'),
            tooltip: 'Rotate',
            icon: const Icon(Icons.rotate_right_rounded),
            onPressed: ready ? _rotate : null,
          ),
          IconButton(
            key: const ValueKey('image-info'),
            tooltip: 'Details',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _loading ? null : _showDetails,
          ),
          IconButton(
            key: const ValueKey('image-share'),
            tooltip: 'Share',
            icon: const Icon(Icons.share_rounded),
            onPressed: _problem == _Problem.missing ? null : _share,
          ),
          IconButton(
            key: const ValueKey('image-to-pdf'),
            tooltip: 'Make a PDF',
            icon: _makingPdf
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.picture_as_pdf_rounded),
            onPressed: ready && !_makingPdf ? _makePdf : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            )
          : _problem != null
          ? _buildProblem(_problem!)
          : _buildPicture(_image!),
    );
  }

  Widget _buildPicture(ImageProvider image) {
    final multiTouch = _pointers >= 2;
    return Listener(
      onPointerDown: (_) => _setPointers(_pointers + 1),
      onPointerUp: (_) => _setPointers(_pointers - 1),
      onPointerCancel: (_) => _setPointers(_pointers - 1),
      child: GestureDetector(
        onDoubleTapDown: multiTouch ? null : _onDoubleTap,
        // The handler lives on onDoubleTapDown so the tap position is known;
        // onDoubleTap still has to be present for the recognizer to fire.
        onDoubleTap: multiTouch ? null : () {},
        child: InteractiveViewer(
          transformationController: _zoom,
          minScale: 1,
          maxScale: 8,
          onInteractionStart: (_) => _zoomAnimation.stop(),
          child: SizedBox.expand(
            child: RotatedBox(
              quarterTurns: _turns,
              child: Image(
                image: image,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                semanticLabel: _name,
                frameBuilder: (context, child, frame, synchronous) =>
                    synchronous || frame != null
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(color: Colors.white54),
                      ),
                errorBuilder: (context, error, stack) {
                  _onDecodeFailed(error);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProblem(_Problem problem) {
    final missing = problem == _Problem.missing;
    final extension = DocKind.extensionOf(widget.path);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              missing
                  ? Icons.image_not_supported_outlined
                  : Icons.broken_image_outlined,
              size: 64,
              color: Colors.white38,
            ),
            const SizedBox(height: 16),
            Text(
              missing
                  ? 'This picture is not there any more'
                  : 'This picture cannot be shown',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              missing
                  ? 'It may have been moved, renamed or deleted.'
                  : 'The file may be damaged, or its format'
                        '${extension.isEmpty ? '' : ' (.$extension)'} is one '
                        'this phone cannot read. Another app may still open '
                        'it.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            if (!missing) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('image-open-with'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  minimumSize: const Size(240, 46),
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open with another app'),
                onPressed: _openElsewhere,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('image-problem-share'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  minimumSize: const Size(240, 46),
                ),
                icon: const Icon(Icons.share_rounded),
                label: const Text('Share'),
                onPressed: _share,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the header and the file system say about the picture.
class _PictureFacts {
  const _PictureFacts({
    required this.format,
    required this.bytes,
    required this.modified,
    required this.width,
    required this.height,
    required this.frames,
  });

  final _ImageFormat? format;
  final int bytes;
  final DateTime modified;
  final int? width;
  final int? height;
  final int? frames;
}

/// Picture formats, told apart by their first bytes rather than the name,
/// which "Open with" copies often lack.
enum _ImageFormat {
  jpeg('JPEG', 'image/jpeg'),
  png('PNG', 'image/png'),
  gif('GIF', 'image/gif'),
  webp('WebP', 'image/webp'),
  bmp('BMP', 'image/bmp'),
  heic('HEIC', 'image/heic'),
  heif('HEIF', 'image/heif'),
  avif('AVIF', 'image/avif'),
  tiff('TIFF', 'image/tiff'),
  ico('ICO', 'image/x-icon');

  const _ImageFormat(this.label, this.mimeType);

  final String label;
  final String mimeType;

  /// The `image` package, which the scan flow converts with, cannot read
  /// these; the phone's own codecs can (HEIF on Android 9 and later).
  bool get needsPlatformCodec => this == heic || this == heif || this == avif;

  static _ImageFormat? sniff(Uint8List head) {
    bool at(int offset, List<int> magic) {
      if (head.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (head[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (at(0, const [0xFF, 0xD8, 0xFF])) return jpeg;
    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return png;
    }
    if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) return gif;
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return webp;
    if (at(0, 'BM'.codeUnits)) return bmp;
    if (at(0, const [0x49, 0x49, 0x2A, 0x00]) ||
        at(0, const [0x4D, 0x4D, 0x00, 0x2A])) {
      return tiff;
    }
    if (at(0, const [0x00, 0x00, 0x01, 0x00])) return ico;
    if (isHeifFamily(head)) {
      final brand = String.fromCharCodes(head.sublist(8, 12));
      if (brand.startsWith('avi')) return avif;
      return brand.startsWith('he') ? heic : heif;
    }
    return null;
  }

  static _ImageFormat? ofExtension(String extension) => switch (extension) {
    'jpg' || 'jpeg' || 'jpe' || 'jfif' => jpeg,
    'png' => png,
    'gif' => gif,
    'webp' => webp,
    'bmp' || 'dib' => bmp,
    'heic' => heic,
    'heif' => heif,
    'avif' => avif,
    'tif' || 'tiff' => tiff,
    'ico' => ico,
    _ => null,
  };
}

/// Writes the picture at [path] as a one-page PDF called [name] in the
/// app's documents, and returns its path; null when it could not be
/// converted.
///
/// Pictures the `image` package reads go through the scan flow's conversion
/// ([PdfService.imagesToPdf]): at Maximum quality an upright JPEG goes in
/// byte for byte, and anything else becomes JPEG first on a background
/// isolate. HEIC, HEIF and AVIF, and anything that conversion fails on, are
/// turned into JPEG by the phone's own codecs instead. A turned view turns
/// the page through its rotation, which loses nothing.
Future<String?> _pictureToPdf(
  String path,
  String name, {
  required String quality,
  required int qualityPercent,
  required int turns,
  required bool platformFirst,
}) async {
  String? output;
  if (!platformFirst) {
    output = await PdfService.imagesToPdf(
      [path],
      outputQuality: quality,
      fileName: name,
    );
  }
  output ??= await _pictureToPdfWithPlatformCodec(path, name, qualityPercent);
  if (output == null || turns % 4 == 0) return output;
  // Next to the output, so the rename that replaces it is atomic.
  final turned = '$output.turning';
  try {
    await PdfCore.rotatePagesAsync(output, turns % 4 * 90, turned);
    await File(turned).rename(output);
    return output;
  } catch (e) {
    for (final leftover in [turned, output]) {
      try {
        await File(leftover).delete();
      } catch (_) {}
    }
    rethrow;
  }
}

Future<String?> _pictureToPdfWithPlatformCodec(
  String path,
  String name,
  int quality,
) async {
  final jpeg = await transcodeWithPlatformCodec(
    await File(path).readAsBytes(),
    quality: quality,
  );
  if (jpeg == null) return null;
  final temporary = await getTemporaryDirectory();
  final file = File(
    '${temporary.path}/picture_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  try {
    await file.writeAsBytes(jpeg, flush: true);
    // Already encoded at the chosen quality: Maximum embeds it as it is
    // instead of encoding it a second time.
    return await PdfService.imagesToPdf(
      [file.path],
      outputQuality: 'Maximum',
      fileName: name,
    );
  } finally {
    try {
      await file.delete();
    } catch (_) {}
  }
}

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    // Read in build: AppColors.of listens, which is only allowed here.
    final colors = AppColors.of(context);
    return ColoredBox(
      key: const ValueKey('image-details'),
      color: colors.cardBackground,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(DocKind.image.icon, color: DocKind.image.color),
                  const SizedBox(width: 12),
                  Text(
                    'Details',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label.toUpperCase(),
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 10,
                          letterSpacing: 0.8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
