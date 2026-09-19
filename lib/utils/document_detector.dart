import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import 'perspective.dart';

/// Finds the page in a photo, so the crop editor opens on the document
/// instead of on the whole frame.
///
/// The approach is the classic one, minus OpenCV: gradient magnitude, a
/// gradient-steered Hough transform, then the strongest pair of near-parallel
/// lines in each orientation, intersected into a quad. Voting only for the
/// handful of angles the local gradient actually supports — rather than all
/// 180 — is what keeps it to a few milliseconds on a downscaled frame and
/// keeps the peaks sharp enough to pick out of.
///
/// Detection is advisory: a page held against a same-coloured desk has no
/// edge to find, so this returns null and the caller falls back to a plain
/// inset rectangle the user can drag.

/// Side length the search runs at. Document edges are metre-scale features;
/// resolution past this buys nothing and costs a full Hough pass.
const int _workingSide = 320;

/// Fraction of pixels kept as edges.
const double _edgeFraction = 0.12;

/// Least of the frame a detected page may cover. Below this it is far more
/// likely to be a book spine, a shadow or a table edge than the page.
const double _minAreaFraction = 0.12;

/// Detect the document quad in [imageBytes].
///
/// Top-level and free of Flutter bindings so it can be a `compute` entry
/// point. Returns [CropQuad.toList] form (normalized), or null when nothing
/// convincing was found.
List<double>? detectDocumentCorners(Uint8List imageBytes) {
  final decoded = img.decodeImage(imageBytes);
  if (decoded == null) return null;
  // Same reason as the warp: the corners this returns are handed to a widget
  // showing the EXIF-rotated image, so detection has to see that orientation.
  final quad = detectQuad(img.bakeOrientation(decoded));
  return quad?.toList();
}

/// The detector proper, on an already-decoded image — the form the tests use.
CropQuad? detectQuad(img.Image image) {
  // Area-averaged, not nearest: shrinking a 12 MP photo by 12x with nearest
  // keeps one pixel in 150, which throws away the very edges being looked
  // for and leaves aliasing that votes for angles nothing in the scene has.
  final small = image.width >= image.height
      ? img.copyResize(
          image,
          width: _workingSide,
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          image,
          height: _workingSide,
          interpolation: img.Interpolation.average,
        );

  final w = small.width;
  final h = small.height;
  if (w < 32 || h < 32) return null;

  final gray = _luminance(small);
  final blurred = _boxBlur3(gray, w, h);
  final edges = _sobel(blurred, w, h);

  final lines = _houghLines(edges, w, h);
  if (lines.length < 4) return null;

  // Split by what the line *is*, not by its normal: a normal within 45° of
  // horizontal belongs to a vertical-ish line.
  final vertical = <_Line>[];
  final horizontal = <_Line>[];
  for (final line in lines) {
    final deg = line.thetaDeg;
    if (deg < 45 || deg > 135) {
      vertical.add(line);
    } else {
      horizontal.add(line);
    }
  }

  final pairV = _bestPair(vertical, w * 0.25);
  final pairH = _bestPair(horizontal, h * 0.25);
  if (pairV == null || pairH == null) return null;

  final quad = _quadFrom(pairV, pairH, w, h);
  if (quad == null) return null;

  // A quad that covers the whole frame is what you get when the detector
  // locked onto the image border itself — no better than no answer at all.
  if (quad.area < _minAreaFraction || quad.area > 0.995) return null;
  if (!quad.isConvex) return null;

  return quad;
}

// ---------------------------------------------------------------- pipeline

Uint8List _luminance(img.Image src) {
  final rgb = src.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(src.width * src.height);
  for (int i = 0, p = 0; i < out.length; i++, p += 3) {
    // Rec. 601 luma, the same weights the scan filters use.
    out[i] = (0.299 * rgb[p] + 0.587 * rgb[p + 1] + 0.114 * rgb[p + 2])
        .round()
        .clamp(0, 255);
  }
  return out;
}

/// Separable 3x3 box blur — enough to stop paper texture and JPEG noise from
/// voting, cheap enough not to matter.
Uint8List _boxBlur3(Uint8List src, int w, int h) {
  final tmp = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    final row = y * w;
    for (int x = 0; x < w; x++) {
      final x0 = x > 0 ? x - 1 : 0;
      final x1 = x < w - 1 ? x + 1 : w - 1;
      tmp[row + x] = ((src[row + x0] + src[row + x] + src[row + x1]) ~/ 3);
    }
  }
  final out = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    final y0 = (y > 0 ? y - 1 : 0) * w;
    final y1 = (y < h - 1 ? y + 1 : h - 1) * w;
    final row = y * w;
    for (int x = 0; x < w; x++) {
      out[row + x] = ((tmp[y0 + x] + tmp[row + x] + tmp[y1 + x]) ~/ 3);
    }
  }
  return out;
}

/// Sobel response, kept as gradient *vectors* — the Hough pass needs the
/// direction, not just the magnitude.
class _Edges {
  _Edges(this.gx, this.gy, this.magnitude, this.threshold);
  final Int16List gx;
  final Int16List gy;
  final Int16List magnitude;

  /// Magnitude a pixel must reach to get a vote.
  final int threshold;
}

_Edges _sobel(Uint8List src, int w, int h) {
  final gx = Int16List(w * h);
  final gy = Int16List(w * h);
  final mag = Int16List(w * h);
  final histogram = Int32List(256);

  for (int y = 1; y < h - 1; y++) {
    final row = y * w;
    final up = row - w;
    final down = row + w;
    for (int x = 1; x < w - 1; x++) {
      final tl = src[up + x - 1], t = src[up + x], tr = src[up + x + 1];
      final l = src[row + x - 1], r = src[row + x + 1];
      final bl = src[down + x - 1], b = src[down + x], br = src[down + x + 1];

      final dx = (tr + 2 * r + br) - (tl + 2 * l + bl);
      final dy = (bl + 2 * b + br) - (tl + 2 * t + tr);
      // |dx| + |dy| rather than the Euclidean norm: same ordering to within a
      // few percent, and this runs per pixel.
      final m = (dx.abs() + dy.abs()).clamp(0, 32767);
      gx[row + x] = dx.clamp(-32768, 32767);
      gy[row + x] = dy.clamp(-32768, 32767);
      mag[row + x] = m;
      histogram[(m >> 2).clamp(0, 255)]++;
    }
  }

  // Keep the strongest _edgeFraction of pixels, read off the histogram.
  final target = ((w - 2) * (h - 2) * _edgeFraction).round();
  int seen = 0;
  int threshold = 40;
  for (int bucket = 255; bucket >= 0; bucket--) {
    seen += histogram[bucket];
    if (seen >= target) {
      threshold = bucket << 2;
      break;
    }
  }
  // A flat, evenly lit frame has no real edges; the floor stops the detector
  // from finding a "page" in sensor noise.
  return _Edges(gx, gy, mag, math.max(threshold, 40));
}

/// One line in normal form: `x·cosθ + y·sinθ = ρ`, θ ∈ [0,π).
class _Line {
  _Line(this.thetaBin, this.rho, this.score, this.centerDistance);

  /// θ in whole degrees, 0..179.
  final int thetaBin;
  final double rho;
  final int score;

  /// Signed distance from the image centre. Two near-parallel lines are
  /// compared through this rather than through ρ, because ρ flips sign as θ
  /// wraps past 180° and would make a pair look coincident.
  final double centerDistance;

  double get thetaDeg => thetaBin.toDouble();
  double get cos => math.cos(thetaBin * math.pi / 180);
  double get sin => math.sin(thetaBin * math.pi / 180);
}

const int _thetaBins = 180;

List<_Line> _houghLines(_Edges edges, int w, int h) {
  final cosTable = Float64List(_thetaBins);
  final sinTable = Float64List(_thetaBins);
  for (int t = 0; t < _thetaBins; t++) {
    final radians = t * math.pi / _thetaBins;
    cosTable[t] = math.cos(radians);
    sinTable[t] = math.sin(radians);
  }

  final int rhoOffset = math.sqrt(w * w + h * h).ceil();
  final int rhoBins = rhoOffset * 2 + 1;
  final accumulator = Int32List(_thetaBins * rhoBins);

  for (int y = 1; y < h - 1; y++) {
    final row = y * w;
    for (int x = 1; x < w - 1; x++) {
      final m = edges.magnitude[row + x];
      if (m < edges.threshold) continue;

      // The gradient points across the edge, so it *is* the line's normal:
      // vote for that angle and its immediate neighbours instead of the whole
      // circle. ~7 votes per pixel rather than 180.
      final angle = math.atan2(
        edges.gy[row + x].toDouble(),
        edges.gx[row + x].toDouble(),
      );
      int center = (angle * 180 / math.pi).round() % 180;
      if (center < 0) center += 180;

      for (int d = -3; d <= 3; d++) {
        final t = (center + d + 180) % 180;
        final rho = x * cosTable[t] + y * sinTable[t];
        final bin = rho.round() + rhoOffset;
        if (bin < 0 || bin >= rhoBins) continue;
        accumulator[t * rhoBins + bin] += m;
      }
    }
  }

  // Candidate peaks: anything worth a fifth of the best cell.
  int best = 0;
  for (final value in accumulator) {
    if (value > best) best = value;
  }
  if (best == 0) return const [];
  final cutoff = best ~/ 5;

  final cx = w / 2;
  final cy = h / 2;
  final candidates = <_Line>[];
  for (int t = 0; t < _thetaBins; t++) {
    for (int bin = 0; bin < rhoBins; bin++) {
      final score = accumulator[t * rhoBins + bin];
      if (score < cutoff) continue;
      final rho = (bin - rhoOffset).toDouble();
      candidates.add(
        _Line(t, rho, score, rho - (cx * cosTable[t] + cy * sinTable[t])),
      );
    }
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));

  // Non-maximum suppression: one line per ridge in the accumulator, or the
  // "two strongest" of a family would both sit on the same page edge.
  final minSeparation = math.min(w, h) * 0.08;
  final kept = <_Line>[];
  for (final line in candidates) {
    final duplicate = kept.any(
      (other) =>
          _angleDistance(line.thetaBin, other.thetaBin) <= 8 &&
          (line.centerDistance - other.centerDistance).abs() < minSeparation,
    );
    if (!duplicate) kept.add(line);
    if (kept.length >= 24) break;
  }
  return kept;
}

/// Smallest angle between two θ bins, remembering that θ wraps at 180°.
int _angleDistance(int a, int b) {
  final diff = (a - b).abs();
  return math.min(diff, 180 - diff);
}

/// Strongest pair of lines that could be opposite edges of a page: nearly
/// parallel, and at least [minSeparation] pixels apart.
List<_Line>? _bestPair(List<_Line> lines, double minSeparation) {
  _Line? bestA;
  _Line? bestB;
  int bestScore = -1;

  for (int i = 0; i < lines.length; i++) {
    for (int j = i + 1; j < lines.length; j++) {
      final a = lines[i];
      final b = lines[j];
      if (_angleDistance(a.thetaBin, b.thetaBin) > 25) continue;
      if ((a.centerDistance - b.centerDistance).abs() < minSeparation) continue;
      final score = a.score + b.score;
      if (score > bestScore) {
        bestScore = score;
        bestA = a;
        bestB = b;
      }
    }
  }
  if (bestA == null || bestB == null) return null;
  return [bestA, bestB];
}

/// Intersect the two line pairs and sort the results into corner order.
CropQuad? _quadFrom(
  List<_Line> vertical,
  List<_Line> horizontal,
  int w,
  int h,
) {
  final points = <Offset>[];
  for (final v in vertical) {
    for (final hLine in horizontal) {
      final point = _intersect(v, hLine);
      if (point == null) return null;
      // Corners are allowed slightly outside the frame — a page can run off
      // the edge of the photo — but not wildly so.
      if (point.dx < -0.15 * w ||
          point.dx > 1.15 * w ||
          point.dy < -0.15 * h ||
          point.dy > 1.15 * h) {
        return null;
      }
      points.add(
        Offset((point.dx / w).clamp(0.0, 1.0), (point.dy / h).clamp(0.0, 1.0)),
      );
    }
  }
  if (points.length != 4) return null;

  // Deterministic corner assignment: x+y is smallest at the top-left and
  // largest at the bottom-right; x−y separates the other two.
  points.sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
  final topLeft = points.first;
  final bottomRight = points.last;
  final middle = [points[1], points[2]]
    ..sort((a, b) => (a.dx - a.dy).compareTo(b.dx - b.dy));
  final bottomLeft = middle.first;
  final topRight = middle.last;

  return CropQuad(
    topLeft: topLeft,
    topRight: topRight,
    bottomRight: bottomRight,
    bottomLeft: bottomLeft,
  );
}

Offset? _intersect(_Line a, _Line b) {
  final det = a.cos * b.sin - a.sin * b.cos;
  // Near-parallel lines meet somewhere out at infinity; that is not a corner.
  if (det.abs() < 0.5) return null;
  return Offset(
    (a.rho * b.sin - b.rho * a.sin) / det,
    (a.cos * b.rho - b.cos * a.rho) / det,
  );
}
