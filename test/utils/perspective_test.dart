import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/utils/document_detector.dart';
import 'package:pdfhelper/utils/perspective.dart';

/// Apply a solved homography to one point.
Offset _project(List<double> h, double x, double y) {
  final w = h[6] * x + h[7] * y + 1;
  return Offset(
    (h[0] * x + h[1] * y + h[2]) / w,
    (h[3] * x + h[4] * y + h[5]) / w,
  );
}

void main() {
  group('solveHomography', () {
    test('maps each correspondence exactly', () {
      // A deliberately keystoned quad: the top edge is shorter than the
      // bottom, which is what a page photographed at an angle looks like.
      final from = [0.0, 0.0, 100.0, 0.0, 100.0, 100.0, 0.0, 100.0];
      final to = [20.0, 10.0, 90.0, 4.0, 110.0, 95.0, 5.0, 88.0];

      final h = solveHomography(from, to)!;

      for (int i = 0; i < 4; i++) {
        final p = _project(h, from[i * 2], from[i * 2 + 1]);
        expect(p.dx, closeTo(to[i * 2], 1e-6));
        expect(p.dy, closeTo(to[i * 2 + 1], 1e-6));
      }
    });

    test('returns null for collinear points', () {
      final from = [0.0, 0.0, 1.0, 0.0, 2.0, 0.0, 3.0, 0.0];
      final to = [0.0, 0.0, 1.0, 1.0, 2.0, 2.0, 3.0, 3.0];
      expect(solveHomography(from, to), isNull);
    });
  });

  group('CropQuad', () {
    test('full covers the whole image', () {
      expect(CropQuad.full().area, closeTo(1.0, 1e-9));
      expect(CropQuad.full(inset: 0.1).area, closeTo(0.64, 1e-9));
    });

    test('rejects a bow tie', () {
      expect(CropQuad.full().isConvex, isTrue);
      final crossed = CropQuad(
        topLeft: const Offset(0, 0),
        topRight: const Offset(1, 0),
        bottomRight: const Offset(0, 1),
        bottomLeft: const Offset(1, 1),
      );
      expect(crossed.isConvex, isFalse);
    });

    test('round trips through a flat list', () {
      final quad = CropQuad.full(inset: 0.05);
      expect(CropQuad.fromList(quad.toList()).toList(), quad.toList());
    });
  });

  group('warpImage', () {
    test('straightens a skewed quad back to a rectangle', () {
      // Paint a distinctive colour into each corner of a skewed quad; after
      // warping, each colour must land in the matching corner of the result.
      final source = img.Image(width: 300, height: 300);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));

      final quad = CropQuad(
        topLeft: const Offset(0.20, 0.10),
        topRight: const Offset(0.85, 0.22),
        bottomRight: const Offset(0.78, 0.90),
        bottomLeft: const Offset(0.10, 0.75),
      );

      const colors = [
        [255, 0, 0], // top-left
        [0, 255, 0], // top-right
        [0, 0, 255], // bottom-right
        [255, 255, 0], // bottom-left
      ];
      final corners = quad.corners;
      for (int i = 0; i < 4; i++) {
        final cx = (corners[i].dx * source.width).round();
        final cy = (corners[i].dy * source.height).round();
        img.fillRect(
          source,
          x1: cx - 12,
          y1: cy - 12,
          x2: cx + 12,
          y2: cy + 12,
          color: img.ColorRgb8(colors[i][0], colors[i][1], colors[i][2]),
        );
      }

      final warped = warpImage(source, quad)!;

      // Output is sized from the quad's own edges, so it stays document-shaped.
      expect(warped.width, greaterThan(150));
      expect(warped.height, greaterThan(150));

      final probes = [
        (4, 4, colors[0]),
        (warped.width - 5, 4, colors[1]),
        (warped.width - 5, warped.height - 5, colors[2]),
        (4, warped.height - 5, colors[3]),
      ];
      for (final (x, y, expected) in probes) {
        final pixel = warped.getPixel(x, y);
        expect(
          (pixel.r - expected[0]).abs() +
              (pixel.g - expected[1]).abs() +
              (pixel.b - expected[2]).abs(),
          lessThan(90),
          reason: 'corner ($x,$y) should carry colour $expected',
        );
      }
    });

    test('caps the output at maxOutputSide', () {
      final source = img.Image(width: 4000, height: 3000);
      img.fill(source, color: img.ColorRgb8(200, 200, 200));
      // Skewed, so it takes the resampling path the cap guards.
      final skewed = CropQuad(
        topLeft: const Offset(0.02, 0.05),
        topRight: const Offset(0.98, 0.0),
        bottomRight: const Offset(0.97, 0.99),
        bottomLeft: const Offset(0.0, 0.95),
      );
      final warped = warpImage(source, skewed, maxOutputSide: 800)!;
      expect(math.max(warped.width, warped.height), 800);
    });

    test('crops without resampling when the quad is already a rectangle', () {
      final source = img.Image(width: 400, height: 400);
      img.fill(source, color: img.ColorRgb8(10, 20, 30));
      img.fillRect(
        source,
        x1: 100,
        y1: 100,
        x2: 299,
        y2: 299,
        color: img.ColorRgb8(200, 100, 50),
      );

      final warped = warpImage(source, CropQuad.full(inset: 0.25))!;

      // Full source resolution, not the warp path's capped output.
      expect(warped.width, 200);
      expect(warped.height, 200);
      final pixel = warped.getPixel(100, 100);
      expect([pixel.r, pixel.g, pixel.b], [200, 100, 50]);
    });

    test('returns null for a collapsed quad', () {
      final source = img.Image(width: 100, height: 100);
      final degenerate = CropQuad(
        topLeft: const Offset(0.5, 0.5),
        topRight: const Offset(0.5, 0.5),
        bottomRight: const Offset(0.5, 0.5),
        bottomLeft: const Offset(0.5, 0.5),
      );
      expect(warpImage(source, degenerate), isNull);
    });
  });

  group('detectQuad', () {
    /// A dark frame with a light, rotated page in it — the shape the detector
    /// is built to find.
    img.Image pageOn(
      List<Offset> corners, {
      int width = 600,
      int height = 800,
    }) {
      final image = img.Image(width: width, height: height);
      img.fill(image, color: img.ColorRgb8(30, 34, 40));
      img.fillPolygon(
        image,
        vertices: [
          for (final c in corners)
            img.Point((c.dx * width).round(), (c.dy * height).round()),
        ],
        color: img.ColorRgb8(240, 240, 235),
      );
      return image;
    }

    test('finds a tilted page', () {
      final truth = CropQuad(
        topLeft: const Offset(0.18, 0.12),
        topRight: const Offset(0.86, 0.20),
        bottomRight: const Offset(0.80, 0.86),
        bottomLeft: const Offset(0.12, 0.78),
      );

      final found = detectQuad(pageOn(truth.corners));

      expect(found, isNotNull);
      for (int i = 0; i < 4; i++) {
        expect(
          (found!.corners[i] - truth.corners[i]).distance,
          lessThan(0.05),
          reason: 'corner $i drifted',
        );
      }
    });

    test('finds an axis-aligned page', () {
      final truth = CropQuad.full(inset: 0.15);
      final found = detectQuad(pageOn(truth.corners));

      expect(found, isNotNull);
      for (int i = 0; i < 4; i++) {
        expect((found!.corners[i] - truth.corners[i]).distance, lessThan(0.05));
      }
    });

    test('returns null on a blank frame', () {
      final blank = img.Image(width: 600, height: 800);
      img.fill(blank, color: img.ColorRgb8(180, 180, 180));
      expect(detectQuad(blank), isNull);
    });
  });
}
