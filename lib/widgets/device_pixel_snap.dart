import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// How far, in its own coordinates, to move something painted with
/// [transform] (from its coordinates to the screen's logical pixels) so that
/// its top-left corner lands on a whole device pixel.
///
/// Zero when [transform] rotates, skews or adds perspective: there is no
/// pixel grid to line up with then.
Offset devicePixelSnap(Matrix4 transform, double devicePixelRatio) {
  final m = transform.storage;
  if (m[1] != 0 || m[4] != 0 || m[3] != 0 || m[7] != 0 || m[15] != 1) {
    return Offset.zero;
  }
  final scaleX = m[0] * devicePixelRatio;
  final scaleY = m[5] * devicePixelRatio;
  final x = m[12] * devicePixelRatio;
  final y = m[13] * devicePixelRatio;
  if (!(scaleX > 0 && scaleY > 0) || !x.isFinite || !y.isFinite) {
    return Offset.zero;
  }
  return Offset(
    (x.roundToDouble() - x) / scaleX,
    (y.roundToDouble() - y) / scaleY,
  );
}

/// Paints [child] moved by under a device pixel, so its top-left corner sits
/// on a whole device pixel wherever layout, scrolling or zoom puts it.
///
/// A bitmap drawn pixel for pixel ([FilterQuality.none]) at a fractional
/// position puts each screen pixel's centre on or beside a boundary between
/// two bitmap pixels. Exactly halfway — a 12-point margin at 1.875 or 2.625
/// device pixels per point lands there — rounding picks one side or the
/// other column by column, so some bitmap columns show twice and others not
/// at all, and text looks broken and blurred. Filtering instead would blur
/// every glyph edge by half a pixel. Aligned, the bitmap is the screen.
class SnapToDevicePixels extends SingleChildRenderObjectWidget {
  const SnapToDevicePixels({
    super.key,
    required this.devicePixelRatio,
    this.repaint,
    super.child,
  });

  final double devicePixelRatio;

  /// Fires when the child moves on screen without being repainted — a
  /// scroll that only shifts a repaint boundary above it — so the snap is
  /// worked out again for the new position.
  final Listenable? repaint;

  @override
  RenderSnapToDevicePixels createRenderObject(BuildContext context) =>
      RenderSnapToDevicePixels(
        devicePixelRatio: devicePixelRatio,
        repaint: repaint,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSnapToDevicePixels renderObject,
  ) {
    renderObject
      ..devicePixelRatio = devicePixelRatio
      ..repaint = repaint;
  }
}

class RenderSnapToDevicePixels extends RenderProxyBox {
  RenderSnapToDevicePixels({
    required double devicePixelRatio,
    Listenable? repaint,
    RenderBox? child,
  }) : _devicePixelRatio = devicePixelRatio,
       _repaint = repaint,
       super(child);

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  Listenable? get repaint => _repaint;
  Listenable? _repaint;
  set repaint(Listenable? value) {
    if (identical(value, _repaint)) return;
    if (attached) _repaint?.removeListener(markNeedsPaint);
    _repaint = value;
    if (attached) _repaint?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// The shift used for the last paint, also applied to hit testing and to
  /// [applyPaintTransform] so descendants that snap or measure themselves
  /// see where they really are.
  Offset _shift = Offset.zero;

  @visibleForTesting
  Offset get shift => _shift;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // Where this object is: its ancestors' transforms, including the shift
    // of any snapping ancestor, which painted first.
    _shift = devicePixelSnap(getTransformTo(null), _devicePixelRatio);
    context.paintChild(child, offset + _shift);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }
}
