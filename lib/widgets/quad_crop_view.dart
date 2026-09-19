import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../utils/perspective.dart';

/// The four-corner crop surface.
///
/// A rectangle crop can only ever take a rectangle out of a photo, so cutting
/// a page out of a frame taken at an angle costs you a corner or keeps a
/// wedge of desk. This draws the crop as a *quadrilateral*: four corner
/// handles that move independently, plus a handle on each edge that carries
/// the whole edge with it — eight points, which is what it takes to follow a
/// page that is not square to the camera.
///
/// The widget is controlled: it never holds the quad, it reports moves
/// through [onChanged] and paints whatever it is given back.
class QuadCropView extends StatefulWidget {
  const QuadCropView({
    super.key,
    required this.image,
    required this.quad,
    required this.onChanged,
    this.accent = const Color(0xFF00D9FF),
    this.isDarkMode = true,
  });

  /// The photo, already decoded (and already EXIF-rotated by Flutter).
  final ui.Image image;

  final CropQuad quad;
  final ValueChanged<CropQuad> onChanged;
  final Color accent;
  final bool isDarkMode;

  @override
  State<QuadCropView> createState() => _QuadCropViewState();
}

class _QuadCropViewState extends State<QuadCropView> {
  /// 0-3 are corners (clockwise from top-left); 4-7 are the edge handles,
  /// where handle `4 + i` sits between corner `i` and corner `i + 1`.
  int? _activeHandle;

  /// Where the finger is, in widget coordinates — the magnifier follows it.
  Offset? _activePoint;

  /// How far a touch may land from a handle and still grab it. A fingertip is
  /// about this wide; anything tighter and the corners feel unreachable.
  static const double _grabRadius = 44;

  /// Shortest an edge may become, as a fraction of the image. Stops a drag
  /// from collapsing the quad into something that cannot be warped.
  static const double _minEdge = 0.06;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = _fitRect(size);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _onPanStart(details.localPosition, rect),
          onPanUpdate: (details) => _onPanUpdate(details.localPosition, rect),
          onPanEnd: (_) => setState(() {
            _activeHandle = null;
            _activePoint = null;
          }),
          onPanCancel: () => setState(() {
            _activeHandle = null;
            _activePoint = null;
          }),
          child: CustomPaint(
            size: size,
            painter: _QuadPainter(
              image: widget.image,
              imageRect: rect,
              quad: widget.quad,
              accent: widget.accent,
              activeHandle: _activeHandle,
              activePoint: _activePoint,
              maskColor: widget.isDarkMode
                  ? Colors.black.withValues(alpha: 0.62)
                  : Colors.black.withValues(alpha: 0.45),
            ),
          ),
        );
      },
    );
  }

  /// The image, letterboxed into [size] — the same geometry `BoxFit.contain`
  /// would produce, computed here because the painter needs it too.
  Rect _fitRect(Size size) {
    final imageAspect = widget.image.width / widget.image.height;
    final boxAspect = size.width / size.height;
    double w, h;
    if (imageAspect > boxAspect) {
      w = size.width;
      h = size.width / imageAspect;
    } else {
      h = size.height;
      w = size.height * imageAspect;
    }
    return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  Offset _toWidget(Offset normalized, Rect rect) => Offset(
    rect.left + normalized.dx * rect.width,
    rect.top + normalized.dy * rect.height,
  );

  Offset _toNormalized(Offset local, Rect rect) => Offset(
    ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0),
    ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0),
  );

  void _onPanStart(Offset local, Rect rect) {
    final corners = widget.quad.corners;
    int? nearest;
    double nearestDistance = _grabRadius;

    // Corners win ties against edge handles: they are the ones people reach
    // for, and near a corner the two handles are only a few pixels apart.
    for (int i = 0; i < 4; i++) {
      final d = (_toWidget(corners[i], rect) - local).distance;
      if (d < nearestDistance) {
        nearestDistance = d;
        nearest = i;
      }
    }
    if (nearest == null) {
      for (int i = 0; i < 4; i++) {
        final mid = _toWidget(
          Offset.lerp(corners[i], corners[(i + 1) % 4], 0.5)!,
          rect,
        );
        final d = (mid - local).distance;
        if (d < nearestDistance) {
          nearestDistance = d;
          nearest = 4 + i;
        }
      }
    }

    if (nearest != null) {
      setState(() {
        _activeHandle = nearest;
        _activePoint = local;
      });
    }
  }

  void _onPanUpdate(Offset local, Rect rect) {
    final handle = _activeHandle;
    if (handle == null) return;

    final target = _toNormalized(local, rect);
    final CropQuad next;

    if (handle < 4) {
      next = widget.quad.copyWithCorner(handle, target);
    } else {
      // Edge handle: carry both of its endpoints, by the delta that keeps the
      // whole edge on the image. Clamping each endpoint separately would
      // shear the edge instead of moving it.
      final i = handle - 4;
      final j = (i + 1) % 4;
      final corners = widget.quad.corners;
      final mid = Offset.lerp(corners[i], corners[j], 0.5)!;
      var delta = target - mid;
      delta = Offset(
        _clampDelta(delta.dx, corners[i].dx, corners[j].dx),
        _clampDelta(delta.dy, corners[i].dy, corners[j].dy),
      );
      next = widget.quad
          .copyWithCorner(i, corners[i] + delta)
          .copyWithCorner(j, corners[j] + delta);
    }

    setState(() => _activePoint = local);
    if (_isUsable(next)) widget.onChanged(next);
  }

  /// The largest part of [delta] that leaves both [a] and [b] inside 0..1.
  double _clampDelta(double delta, double a, double b) {
    final low = -math.min(a, b);
    final high = 1 - math.max(a, b);
    return delta.clamp(low, high).toDouble();
  }

  /// A move is rejected outright rather than corrected, so the handle simply
  /// stops instead of jumping somewhere the user did not put it.
  bool _isUsable(CropQuad quad) {
    if (!quad.isConvex) return false;
    final corners = quad.corners;
    for (int i = 0; i < 4; i++) {
      if ((corners[i] - corners[(i + 1) % 4]).distance < _minEdge) return false;
    }
    return true;
  }
}

class _QuadPainter extends CustomPainter {
  const _QuadPainter({
    required this.image,
    required this.imageRect,
    required this.quad,
    required this.accent,
    required this.maskColor,
    this.activeHandle,
    this.activePoint,
  });

  final ui.Image image;
  final Rect imageRect;
  final CropQuad quad;
  final Color accent;
  final Color maskColor;
  final int? activeHandle;
  final Offset? activePoint;

  static const double _cornerRadius = 11;
  static const double _edgeRadius = 7;
  static const double _loupeRadius = 54;
  static const double _loupeZoom = 2.4;

  Offset _toWidget(Offset normalized) => Offset(
    imageRect.left + normalized.dx * imageRect.width,
    imageRect.top + normalized.dy * imageRect.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      src,
      imageRect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final points = [for (final c in quad.corners) _toWidget(c)];
    final path = Path()..addPolygon(points, true);

    // Everything outside the quad dims, so the crop reads as a cut-out.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        path,
      ),
      Paint()..color = maskColor,
    );

    _paintThirds(canvas, points);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );

    for (int i = 0; i < 4; i++) {
      final mid = Offset.lerp(points[i], points[(i + 1) % 4], 0.5)!;
      _paintHandle(canvas, mid, _edgeRadius, active: activeHandle == 4 + i);
    }
    for (int i = 0; i < 4; i++) {
      _paintHandle(canvas, points[i], _cornerRadius, active: activeHandle == i);
    }

    if (activePoint != null) _paintLoupe(canvas, size, src, points);
  }

  /// Rule-of-thirds guides, interpolated along the edges rather than drawn on
  /// a grid — under perspective the thirds of a page are not parallel to the
  /// screen.
  void _paintThirds(Canvas canvas, List<Offset> points) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.35);
    for (final t in const [1 / 3, 2 / 3]) {
      canvas.drawLine(
        Offset.lerp(points[0], points[1], t)!,
        Offset.lerp(points[3], points[2], t)!,
        paint,
      );
      canvas.drawLine(
        Offset.lerp(points[0], points[3], t)!,
        Offset.lerp(points[1], points[2], t)!,
        paint,
      );
    }
  }

  void _paintHandle(
    Canvas canvas,
    Offset center,
    double radius, {
    required bool active,
  }) {
    final r = active ? radius + 3 : radius;
    canvas.drawCircle(
      center,
      r + 1.5,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(center, r, Paint()..color = accent);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  /// The magnifier. Without it the handle you are dragging is under your
  /// finger exactly when you need to see it, which is the whole difficulty of
  /// corner-accurate cropping on a phone.
  void _paintLoupe(Canvas canvas, Size size, Rect src, List<Offset> points) {
    final target = activePoint!;
    // Park it in the far corner from the finger.
    final center = Offset(
      target.dx < size.width / 2
          ? size.width - _loupeRadius - 12
          : _loupeRadius + 12,
      target.dy < size.height / 2
          ? size.height - _loupeRadius - 12
          : _loupeRadius + 12,
    );
    final bounds = Rect.fromCircle(center: center, radius: _loupeRadius);

    canvas.save();
    canvas.clipPath(Path()..addOval(bounds));
    canvas.drawColor(Colors.black, BlendMode.src);
    // Put the pixel under the finger at the centre of the loupe, magnified.
    canvas.translate(
      center.dx - target.dx * _loupeZoom,
      center.dy - target.dy * _loupeZoom,
    );
    canvas.scale(_loupeZoom);
    canvas.drawImageRect(
      image,
      src,
      imageRect,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.drawPath(
      Path()..addPolygon(points, true),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 / _loupeZoom
        ..color = accent,
    );
    canvas.restore();

    final crosshair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawLine(
      Offset(center.dx - 10, center.dy),
      Offset(center.dx + 10, center.dy),
      crosshair,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 10),
      Offset(center.dx, center.dy + 10),
      crosshair,
    );
    canvas.drawCircle(
      center,
      _loupeRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_QuadPainter old) =>
      old.image != image ||
      old.imageRect != imageRect ||
      !_sameQuad(old.quad, quad) ||
      old.activeHandle != activeHandle ||
      old.activePoint != activePoint ||
      old.accent != accent ||
      old.maskColor != maskColor;

  static bool _sameQuad(CropQuad a, CropQuad b) {
    for (int i = 0; i < 4; i++) {
      if (a.corners[i] != b.corners[i]) return false;
    }
    return true;
  }
}
