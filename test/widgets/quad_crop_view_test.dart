import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/utils/perspective.dart';
import 'package:pdfhelper/widgets/quad_crop_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A square image, so the fitted rect fills the 400x400 test viewport and
  /// widget coordinates map onto normalized ones by a plain /400.
  Uint8List squareJpeg() {
    final image = img.Image(width: 200, height: 200);
    img.fill(image, color: img.ColorRgb8(220, 220, 220));
    return Uint8List.fromList(img.encodeJpg(image));
  }

  /// Pumps the view at a known size, feeding every change back in — the way
  /// the crop screen drives it. Returns the latest quad.
  Future<CropQuad Function()> pumpView(
    WidgetTester tester, {
    required ui.Image image,
    CropQuad? initial,
  }) async {
    var quad = initial ?? CropQuad.full(inset: 0.1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: StatefulBuilder(
                builder: (context, setState) => QuadCropView(
                  image: image,
                  quad: quad,
                  onChanged: (next) => setState(() => quad = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return () => quad;
  }

  /// Widget-local coordinates are what the view reasons in; the test viewport
  /// centres it, so every touch has to be offset by where it actually landed.
  Offset at(WidgetTester tester, Offset local) =>
      tester.getTopLeft(find.byType(QuadCropView)) + local;

  Future<ui.Image> decode(WidgetTester tester) async {
    late ui.Image image;
    await tester.runAsync(() async {
      image = await decodeImageFromList(squareJpeg());
    });
    return image;
  }

  testWidgets('a corner drag moves only that corner', (tester) async {
    final image = await decode(tester);
    addTearDown(image.dispose);
    final quad = await pumpView(tester, image: image);

    // Top-left handle sits at 0.1 * 400 = (40, 40).
    await tester.dragFrom(
      at(tester, const Offset(40, 40)),
      const Offset(60, 60),
    );
    await tester.pump();

    expect(quad().topLeft.dx, closeTo(0.25, 0.01));
    expect(quad().topLeft.dy, closeTo(0.25, 0.01));
    // The other three are untouched — this is a quad, not a rectangle.
    expect(quad().topRight, const Offset(0.9, 0.1));
    expect(quad().bottomRight, const Offset(0.9, 0.9));
    expect(quad().bottomLeft, const Offset(0.1, 0.9));
  });

  testWidgets('an edge handle carries both of its corners', (tester) async {
    final image = await decode(tester);
    addTearDown(image.dispose);
    final quad = await pumpView(tester, image: image);

    // Midpoint of the top edge: ((40+360)/2, 40) = (200, 40).
    await tester.dragFrom(
      at(tester, const Offset(200, 40)),
      const Offset(0, 60),
    );
    await tester.pump();

    expect(quad().topLeft.dy, closeTo(0.25, 0.01));
    expect(quad().topRight.dy, closeTo(0.25, 0.01));
    // Moved down, not sideways, and the bottom stayed put.
    expect(quad().topLeft.dx, closeTo(0.1, 0.01));
    expect(quad().topRight.dx, closeTo(0.9, 0.01));
    expect(quad().bottomLeft.dy, closeTo(0.9, 0.01));
  });

  testWidgets('a drag that would make a bow tie is refused', (tester) async {
    final image = await decode(tester);
    addTearDown(image.dispose);
    final quad = await pumpView(tester, image: image);

    // Haul the top-left corner past the bottom-right one.
    await tester.dragFrom(
      at(tester, const Offset(40, 40)),
      const Offset(340, 340),
    );
    await tester.pump();

    expect(quad().isConvex, isTrue);
  });

  testWidgets('a touch far from every handle changes nothing', (tester) async {
    final image = await decode(tester);
    addTearDown(image.dispose);
    final before = CropQuad.full(inset: 0.1);
    final quad = await pumpView(tester, image: image, initial: before);

    // Dead centre of the quad — no handle within grabbing distance.
    await tester.dragFrom(
      at(tester, const Offset(200, 200)),
      const Offset(40, 40),
    );
    await tester.pump();

    expect(quad().toList(), before.toList());
  });
}
