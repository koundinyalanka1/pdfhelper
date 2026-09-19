import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

/// Perspective ("keystone") correction for photographed documents.
///
/// A phone photo of a page on a desk is almost never a rectangle: the page
/// arrives as a general quadrilateral, so an axis-aligned crop either cuts a
/// corner off or keeps a wedge of desk. Mapping the four corners the user
/// marked onto a true rectangle — a homography, sampled backwards — is what
/// turns a slanted photo into something that reads like a scan.
///
/// Everything here is plain Dart on plain byte buffers, so it can run inside
/// `compute` and never touches the UI isolate.

/// The four corners of a crop region, in *normalized* image coordinates
/// (0,0 = top-left of the image, 1,1 = bottom-right).
///
/// Normalized rather than pixel coordinates so the same quad survives the
/// downscaled preview the user drags on and the full-resolution image the
/// warp finally runs against.
class CropQuad {
  const CropQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// The whole image, inset by [inset] on every side.
  factory CropQuad.full({double inset = 0}) => CropQuad(
    topLeft: Offset(inset, inset),
    topRight: Offset(1 - inset, inset),
    bottomRight: Offset(1 - inset, 1 - inset),
    bottomLeft: Offset(inset, 1 - inset),
  );

  /// `[tlX, tlY, trX, trY, brX, brY, blX, blY]` — the form the isolate
  /// entry points take, because a flat list is trivially sendable.
  factory CropQuad.fromList(List<double> v) => CropQuad(
    topLeft: Offset(v[0], v[1]),
    topRight: Offset(v[2], v[3]),
    bottomRight: Offset(v[4], v[5]),
    bottomLeft: Offset(v[6], v[7]),
  );

  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  /// Clockwise from the top-left.
  List<Offset> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  List<double> toList() => [
    topLeft.dx,
    topLeft.dy,
    topRight.dx,
    topRight.dy,
    bottomRight.dx,
    bottomRight.dy,
    bottomLeft.dx,
    bottomLeft.dy,
  ];

  CropQuad copyWithCorner(int index, Offset value) {
    final next = [...corners]..[index] = value;
    return CropQuad(
      topLeft: next[0],
      topRight: next[1],
      bottomRight: next[2],
      bottomLeft: next[3],
    );
  }

  /// `true` when the four corners still form a convex, correctly wound quad.
  ///
  /// Dragging one corner past its neighbours makes a bow-tie, and a bow-tie
  /// warps to noise — so the editor refuses the move rather than letting the
  /// user discover it at Done.
  bool get isConvex {
    int? sign;
    final pts = corners;
    for (int i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      final c = pts[(i + 2) % 4];
      final cross =
          (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross == 0) continue;
      final s = cross > 0 ? 1 : -1;
      if (sign == null) {
        sign = s;
      } else if (sign != s) {
        return false;
      }
    }
    return sign != null;
  }

  /// Fraction of the image this quad covers (shoelace formula).
  double get area {
    final pts = corners;
    double sum = 0;
    for (int i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      sum += a.dx * b.dy - b.dx * a.dy;
    }
    return sum.abs() / 2;
  }

  /// `true` when this is (near enough) an axis-aligned rectangle — the case
  /// where warping would only resample the pixels for nothing.
  bool isAxisAlignedRect({double tolerance = 0.002}) {
    return (topLeft.dy - topRight.dy).abs() < tolerance &&
        (bottomLeft.dy - bottomRight.dy).abs() < tolerance &&
        (topLeft.dx - bottomLeft.dx).abs() < tolerance &&
        (topRight.dx - bottomRight.dx).abs() < tolerance;
  }
}

/// Solve the homography taking the four points in [from] to those in [to].
///
/// Points are flat `[x0,y0, x1,y1, x2,y2, x3,y3]`. Returns the eight free
/// parameters `h0..h7` of
///
/// ```text
/// x' = (h0·x + h1·y + h2) / (h6·x + h7·y + 1)
/// y' = (h3·x + h4·y + h5) / (h6·x + h7·y + 1)
/// ```
///
/// or null when the correspondences are degenerate (three points on a line).
List<double>? solveHomography(List<double> from, List<double> to) {
  // One 8x9 augmented matrix: two equations per point correspondence.
  final m = List.generate(8, (_) => Float64List(9));
  for (int i = 0; i < 4; i++) {
    final x = from[i * 2], y = from[i * 2 + 1];
    final u = to[i * 2], v = to[i * 2 + 1];

    final rx = m[i * 2];
    rx[0] = x;
    rx[1] = y;
    rx[2] = 1;
    rx[6] = -x * u;
    rx[7] = -y * u;
    rx[8] = u;

    final ry = m[i * 2 + 1];
    ry[3] = x;
    ry[4] = y;
    ry[5] = 1;
    ry[6] = -x * v;
    ry[7] = -y * v;
    ry[8] = v;
  }

  // Gauss-Jordan with partial pivoting.
  for (int col = 0; col < 8; col++) {
    int pivot = col;
    for (int row = col + 1; row < 8; row++) {
      if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
    }
    if (m[pivot][col].abs() < 1e-9) return null;
    if (pivot != col) {
      final tmp = m[pivot];
      m[pivot] = m[col];
      m[col] = tmp;
    }

    final p = m[col][col];
    for (int c = col; c < 9; c++) {
      m[col][c] /= p;
    }
    for (int row = 0; row < 8; row++) {
      if (row == col) continue;
      final factor = m[row][col];
      if (factor == 0) continue;
      for (int c = col; c < 9; c++) {
        m[row][c] -= factor * m[col][c];
      }
    }
  }

  return [for (int i = 0; i < 8; i++) m[i][8]];
}

/// What [warpDocument] is handed. A plain class so it survives `compute`.
class WarpRequest {
  const WarpRequest({
    required this.imageBytes,
    required this.corners,
    this.jpegQuality = 92,
    this.maxOutputSide = 2400,
  });

  /// The encoded source image (JPEG/PNG), exactly as it sits on disk.
  final Uint8List imageBytes;

  /// The crop quad, normalized, flattened — see [CropQuad.toList].
  final List<double> corners;

  final int jpegQuality;

  /// Longest side of the result. 2400 px is ~200 DPI across A4: past the
  /// point where document text gains anything, and well inside what a phone
  /// can hold while both the source and the output are decoded at once.
  final int maxOutputSide;
}

/// Crop to [WarpRequest.corners] and flatten the perspective.
///
/// Top-level and side-effect free so it can be the entry point of a
/// `compute` call. Returns re-encoded JPEG bytes, or the input unchanged when
/// the image cannot be decoded — a failed straighten must not lose the page.
Uint8List warpDocument(WarpRequest request) {
  final raw = img.decodeImage(request.imageBytes);
  if (raw == null) return request.imageBytes;

  // Flutter's own decoder applies EXIF orientation before the editor ever
  // draws the photo, but `image` leaves it as a tag. Baking it here is what
  // keeps the corners the user dragged pointing at the same pixels.
  final decoded = img.bakeOrientation(raw);

  final quad = CropQuad.fromList(request.corners);
  final warped = warpImage(decoded, quad, maxOutputSide: request.maxOutputSide);
  return Uint8List.fromList(
    img.encodeJpg(warped ?? decoded, quality: request.jpegQuality),
  );
}

/// The pixel half of [warpDocument], split out so it can be tested without
/// a JPEG round trip. Returns null when the quad is degenerate.
img.Image? warpImage(
  img.Image source,
  CropQuad quad, {
  int maxOutputSide = 2400,
}) {
  final sw = source.width;
  final sh = source.height;

  // Nothing to straighten: the user only moved edges, so resampling would
  // cost sharpness (and the size cap would cost resolution) for no gain.
  if (quad.isAxisAlignedRect()) {
    final x0 = (quad.topLeft.dx * sw).round().clamp(0, sw - 1);
    final y0 = (quad.topLeft.dy * sh).round().clamp(0, sh - 1);
    final x1 = (quad.bottomRight.dx * sw).round().clamp(x0 + 1, sw);
    final y1 = (quad.bottomRight.dy * sh).round().clamp(y0 + 1, sh);
    if (x1 - x0 < 8 || y1 - y0 < 8) return null;
    return img.copyCrop(source, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  }

  // Output size from the longer of each pair of opposite edges: the near edge
  // of a tilted page is the one that kept its detail, so sizing to it is what
  // avoids throwing resolution away.
  final pts = quad.corners;
  double edge(int a, int b) {
    final dx = (pts[a].dx - pts[b].dx) * sw;
    final dy = (pts[a].dy - pts[b].dy) * sh;
    return math.sqrt(dx * dx + dy * dy);
  }

  double outW = math.max(edge(0, 1), edge(3, 2));
  double outH = math.max(edge(0, 3), edge(1, 2));
  if (outW < 8 || outH < 8) return null;

  // Past the cap, shrink the *source* too. Point-sampling a 12 MP photo down
  // to a 2400 px page aliases badly, and holding both decoded at once is the
  // peak memory of the whole operation; an area-averaged downscale to just
  // over the output size fixes both. Corners are normalized, so resizing the
  // source leaves them pointing at the same place.
  var working = source;
  final longest = math.max(outW, outH);
  if (longest > maxOutputSide) {
    final scale = maxOutputSide / longest;
    outW *= scale;
    outH *= scale;
    // 1.3x the output: enough oversampling for bilinear to stay sharp.
    final sourceScale = scale * 1.3;
    if (sourceScale < 1.0) {
      working = img.copyResize(
        source,
        width: math.max(8, (sw * sourceScale).round()),
        height: math.max(8, (sh * sourceScale).round()),
        interpolation: img.Interpolation.average,
      );
    }
  }

  final int ow = outW.round().clamp(8, 10000);
  final int oh = outH.round().clamp(8, 10000);

  // Denormalize onto the (possibly downscaled) source, allowing a hair of
  // overshoot to be clamped rather than rejected — a corner dragged to the
  // very edge lands on exactly 1.0.
  final int ww = working.width;
  final int wh = working.height;
  final src = [
    for (final c in pts) ...[
      (c.dx * ww).clamp(0.0, ww.toDouble()),
      (c.dy * wh).clamp(0.0, wh.toDouble()),
    ],
  ];

  // Solved output → source, so each destination pixel reads straight back
  // into the photo; a forward map would leave holes to fill in.
  final h = solveHomography([
    0,
    0,
    ow.toDouble(),
    0,
    ow.toDouble(),
    oh.toDouble(),
    0,
    oh.toDouble(),
  ], src);
  if (h == null) return null;

  final srcRgb = working.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(ow * oh * 3);
  final int maxX = ww - 1;
  final int maxY = wh - 1;

  for (int y = 0; y < oh; y++) {
    final dy = y.toDouble();
    // The homography is affine in x for a fixed y, so the three numerators
    // advance by a constant per column — one multiply-add instead of six.
    double nx = h[1] * dy + h[2];
    double ny = h[4] * dy + h[5];
    double nw = h[7] * dy + 1;
    int outIndex = y * ow * 3;

    for (int x = 0; x < ow; x++, nx += h[0], ny += h[3], nw += h[6]) {
      if (nw == 0) {
        outIndex += 3;
        continue;
      }
      final sx = nx / nw;
      final sy = ny / nw;

      // Outside the photo: white, not black. These pixels only appear along a
      // corner the user dragged past the edge, and a white margin reads as
      // paper while a black one reads as a mistake.
      if (sx < 0 || sy < 0 || sx > maxX || sy > maxY) {
        out[outIndex++] = 255;
        out[outIndex++] = 255;
        out[outIndex++] = 255;
        continue;
      }

      final x0 = sx.floor();
      final y0 = sy.floor();
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final fx = sx - x0;
      final fy = sy - y0;
      final w00 = (1 - fx) * (1 - fy);
      final w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy;
      final w11 = fx * fy;

      final i00 = (y0 * ww + x0) * 3;
      final i10 = (y0 * ww + x1) * 3;
      final i01 = (y1 * ww + x0) * 3;
      final i11 = (y1 * ww + x1) * 3;

      for (int c = 0; c < 3; c++) {
        out[outIndex++] =
            (srcRgb[i00 + c] * w00 +
                    srcRgb[i10 + c] * w10 +
                    srcRgb[i01 + c] * w01 +
                    srcRgb[i11 + c] * w11)
                .round()
                .clamp(0, 255);
      }
    }
  }

  return img.Image.fromBytes(
    width: ow,
    height: oh,
    bytes: out.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}
