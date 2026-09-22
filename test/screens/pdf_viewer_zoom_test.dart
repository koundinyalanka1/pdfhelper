import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';

/// Where a point in the untransformed page lands once [matrix] is applied.
///
/// Column-major 4x4, reduced to the 2D affine part: Matrix4's own transform
/// helpers would pull in vector_math just to check two numbers.
Offset project(Matrix4 matrix, Offset point) {
  final s = matrix.storage;
  return Offset(
    s[0] * point.dx + s[4] * point.dy + s[12],
    s[1] * point.dx + s[5] * point.dy + s[13],
  );
}

void main() {
  group('shouldLockScroll', () {
    test('a single finger scrolls the document', () {
      expect(
        shouldLockScroll(isZoomed: false, activePointers: 1),
        isFalse,
      );
    });

    test('no fingers leaves the list scrollable', () {
      expect(shouldLockScroll(isZoomed: false, activePointers: 0), isFalse);
    });

    test('a second finger stands the list down so the pinch can win', () {
      // The regression this guards: with the list still holding a drag
      // recognizer, two fingers drifting downwards before they spread handed
      // the arena to the scroll and the zoom never fired — the "works
      // sometimes" bug.
      expect(shouldLockScroll(isZoomed: false, activePointers: 2), isTrue);
    });

    test('a third finger changes nothing', () {
      expect(shouldLockScroll(isZoomed: false, activePointers: 3), isTrue);
    });

    test('while zoomed, dragging pans rather than scrolls', () {
      expect(shouldLockScroll(isZoomed: true, activePointers: 1), isTrue);
      expect(shouldLockScroll(isZoomed: true, activePointers: 0), isTrue);
    });
  });

  group('doubleTapZoomTarget', () {
    test('zooming out returns to the identity', () {
      final m = doubleTapZoomTarget(
        isZoomed: true,
        focalPoint: const Offset(120, 400),
      );
      expect(m, Matrix4.identity());
    });

    test('zooming in scales by the requested factor', () {
      final m = doubleTapZoomTarget(
        isZoomed: false,
        focalPoint: Offset.zero,
        scale: 2.5,
      );
      expect(m.getMaxScaleOnAxis(), closeTo(2.5, 1e-9));
    });

    test('keeps the tapped point under the finger', () {
      // This is the property that matters: double-tapping a word should
      // magnify *that* word, not jump somewhere else on the page.
      const focal = Offset(120, 400);
      final m = doubleTapZoomTarget(isZoomed: false, focalPoint: focal);

      final landed = project(m, focal);

      expect(landed.dx, closeTo(focal.dx, 1e-6));
      expect(landed.dy, closeTo(focal.dy, 1e-6));
    });

    test('holds the focal point for any scale', () {
      for (final scale in [1.5, 2.0, 2.5, 4.0, 6.0]) {
        const focal = Offset(300, 900);
        final m = doubleTapZoomTarget(
          isZoomed: false,
          focalPoint: focal,
          scale: scale,
        );
        final landed = project(m, focal);
        expect(landed.dx, closeTo(focal.dx, 1e-6), reason: 'scale $scale');
        expect(landed.dy, closeTo(focal.dy, 1e-6), reason: 'scale $scale');
      }
    });

    test('tapping the origin does not translate', () {
      final m = doubleTapZoomTarget(
        isZoomed: false,
        focalPoint: Offset.zero,
      );
      expect(m.storage[12], closeTo(0, 1e-9));
      expect(m.storage[13], closeTo(0, 1e-9));
    });

    test('translation grows with the focal point, negatively', () {
      // A tap further down the page has to pull the view further up.
      final near = doubleTapZoomTarget(
        isZoomed: false,
        focalPoint: const Offset(0, 100),
      );
      final far = doubleTapZoomTarget(
        isZoomed: false,
        focalPoint: const Offset(0, 800),
      );
      expect(far.storage[13], lessThan(near.storage[13]));
      expect(far.storage[13], lessThan(0));
    });
  });
}
