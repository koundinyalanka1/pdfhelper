import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/widgets/device_pixel_snap.dart';

/// The top-left corner of [box] in device pixels.
Offset devicePosition(RenderBox box, double devicePixelRatio) =>
    MatrixUtils.transformPoint(box.getTransformTo(null), Offset.zero) *
    devicePixelRatio;

bool onWholePixels(Offset device) =>
    (device.dx - device.dx.roundToDouble()).abs() < 1e-6 &&
    (device.dy - device.dy.roundToDouble()).abs() < 1e-6;

void main() {
  group('devicePixelSnap', () {
    test('moves a half-pixel origin onto the grid', () {
      // A 12 pt margin at 1.875 device pixels per point: 22.5 pixels.
      final shift = devicePixelSnap(
        Matrix4.translationValues(12, 6.1, 0),
        1.875,
      );
      expect((12 + shift.dx) * 1.875, closeTo(23, 1e-9));
      expect((6.1 + shift.dy) * 1.875, closeTo(11, 1e-9));
      expect(shift.dx.abs() * 1.875, lessThanOrEqualTo(0.5));
    });

    test('is measured in the zoomed coordinates', () {
      final transform = Matrix4.identity()
        ..translateByDouble(-40.3, 10.7, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1, 1);
      final shift = devicePixelSnap(transform, 2.625);
      final x = (-40.3 + 2.5 * shift.dx) * 2.625;
      final y = (10.7 + 2.5 * shift.dy) * 2.625;
      expect(x, closeTo(x.roundToDouble(), 1e-9));
      expect(y, closeTo(y.roundToDouble(), 1e-9));
    });

    test('leaves aligned, rotated and degenerate transforms alone', () {
      expect(
        devicePixelSnap(Matrix4.translationValues(8, 16, 0), 2),
        Offset.zero,
      );
      expect(devicePixelSnap(Matrix4.rotationZ(0.3), 2), Offset.zero);
      expect(devicePixelSnap(Matrix4.diagonal3Values(0, 1, 1), 2), Offset.zero);
    });
  });

  group('SnapToDevicePixels', () {
    testWidgets('keeps a scrolled page on whole device pixels', (tester) async {
      tester.view.devicePixelRatio = 1.875;
      tester.view.physicalSize = const Size(720, 1608);
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const dpr = 1.875;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView.builder(
            controller: controller,
            // Repaint boundaries around each item, as in the viewer: the
            // page is moved, not repainted, unless it asks to be.
            itemCount: 20,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6.3,
              ),
              child: SnapToDevicePixels(
                devicePixelRatio: dpr,
                repaint: controller,
                child: SizedBox(key: ValueKey(index), height: 333.3),
              ),
            ),
          ),
        ),
      );

      RenderBox page(int index) =>
          tester.renderObject<RenderBox>(find.byKey(ValueKey(index)));
      // Unsnapped, the first page would start at 22.5 by 11.8 pixels.
      expect(onWholePixels(devicePosition(page(0), dpr)), isTrue);
      expect(onWholePixels(devicePosition(page(1), dpr)), isTrue);

      for (final offset in [3.3, 41.77, 400.05]) {
        controller.jumpTo(offset);
        await tester.pump();
        for (final index in [1, 2]) {
          expect(
            onWholePixels(devicePosition(page(index), dpr)),
            isTrue,
            reason: 'page $index after scrolling to $offset',
          );
        }
      }
    });

    testWidgets('a snap inside a snap sees where its parent put it', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      const dpr = 2.625;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 12, top: 7.1),
              child: SnapToDevicePixels(
                devicePixelRatio: dpr,
                child: Padding(
                  padding: EdgeInsets.only(left: 30.3, top: 0.7),
                  child: SnapToDevicePixels(
                    devicePixelRatio: dpr,
                    child: SizedBox(
                      key: ValueKey('tile'),
                      width: 50,
                      height: 50,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final tile = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('tile')),
      );
      expect(onWholePixels(devicePosition(tile, dpr)), isTrue);
    });

    testWidgets('taps land where the shifted child is painted', (tester) async {
      tester.view.devicePixelRatio = 1.875;
      addTearDown(tester.view.reset);
      Offset? tapped;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 12),
              child: SnapToDevicePixels(
                devicePixelRatio: 1.875,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => tapped = details.localPosition,
                  child: const SizedBox(width: 100, height: 100),
                ),
              ),
            ),
          ),
        ),
      );
      final box = tester.renderObject<RenderSnapToDevicePixels>(
        find.byType(SnapToDevicePixels),
      );
      await tester.tapAt(const Offset(62, 62));
      // The child is painted `shift` further on, so the same screen point
      // is that much nearer its origin.
      expect(tapped!.dx, closeTo(50 - box.shift.dx, 1e-9));
      expect(tapped!.dy, closeTo(50 - box.shift.dy, 1e-9));
      expect(box.shift, isNot(Offset.zero));
    });
  });
}
