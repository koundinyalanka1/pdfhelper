import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';

/// A picture of the deck by part name, once it has been decoded.
typedef SlideImageLookup = ui.Image? Function(String part);

/// The family used for sans-serif text; the platform's when null. Tests set
/// it to a font they load.
@visibleForTesting
String? debugSlideSansFamily;

/// Fonts Android has (or close enough) for the families decks name.
String? slideFontFamily(String font) {
  final f = font.toLowerCase();
  if (f.isEmpty) return debugSlideSansFamily;
  const serif = [
    'times',
    'cambria',
    'georgia',
    'garamond',
    'book antiqua',
    'palatino',
    'century',
    'caladea',
    'liberation serif',
    'noto serif',
    'bookman',
    'constantia',
  ];
  const mono = ['courier', 'consolas', 'mono', 'lucida console'];
  if (mono.any(f.contains)) return 'monospace';
  if (serif.any(f.contains)) return 'serif';
  return debugSlideSansFamily;
}

/// Paints a slide scene to fill the canvas's width.
class SlidePainter extends CustomPainter {
  SlidePainter({
    required this.scene,
    required this.images,
    this.prompts = false,
    this.hiddenId,
    this.generation = 0,
    this.onSelect,
  });

  final ValueChanged<SlideItem>? onSelect;
  final SlideScene scene;
  final SlideImageLookup images;

  /// Show empty placeholders' prompts and outlines (the editor, not the
  /// show or thumbnails).
  final bool prompts;

  /// A shape the editor draws itself while it is being dragged.
  final int? hiddenId;

  /// Changes when pictures finish loading.
  final int generation;

  @override
  void paint(Canvas canvas, Size size) {
    paintSlideScene(
      canvas,
      scene,
      size.width / scene.width,
      images,
      prompts: prompts,
      skipId: hiddenId,
    );
  }

  @override
  SemanticsBuilderCallback? get semanticsBuilder {
    final select = onSelect;
    if (select == null) return null;
    return (size) {
      final scale = size.width / scene.width;
      final bounds = Offset.zero & size;
      return [
        for (final item in scene.items)
          if (item.editable && item.id != 0 && item.w > 0 && item.h > 0)
            CustomPainterSemantics(
              key: ValueKey(item.id),
              rect: Rect.fromCenter(
                center: Offset((item.x + item.w / 2) * scale, (item.y + item.h / 2) * scale),
                width: math.max(48, item.w * scale),
                height: math.max(48, item.h * scale),
              ).intersect(bounds),
              properties: SemanticsProperties(
                label: _itemLabel(item),
                textDirection: TextDirection.ltr,
                button: true,
                onTap: () => select(item),
              ),
            ),
      ];
    };
  }

  String _itemLabel(SlideItem item) {
    final text = item.text?.paragraphs.join(' ').trim() ?? '';
    final label = text.isNotEmpty ? text : item.text?.prompt ?? item.name;
    if (label.isNotEmpty) return label.length > 200 ? label.substring(0, 200) : label;
    return switch (item.kind) {
      SlideItemKind.picture => 'Picture',
      SlideItemKind.chart => 'Chart',
      SlideItemKind.table => 'Table',
      _ => 'Shape ${item.id}',
    };
  }

  @override
  bool shouldRebuildSemantics(SlidePainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.onSelect != onSelect;

  @override
  bool shouldRepaint(SlidePainter old) =>
      old.scene != scene ||
      old.generation != generation ||
      old.prompts != prompts ||
      old.hiddenId != hiddenId;
}

/// Paint [scene] with [s] pixels per point.
void paintSlideScene(
  Canvas canvas,
  SlideScene scene,
  double s,
  SlideImageLookup images, {
  bool prompts = false,
  int? skipId,
}) {
  final bounds = Rect.fromLTWH(0, 0, scene.width * s, scene.height * s);
  canvas.save();
  canvas.clipRect(bounds);
  canvas.drawRect(bounds, Paint()..color = Colors.white);
  final bg = scene.background;
  if (bg != null) {
    _fillArea(canvas, Path()..addRect(bounds), bounds, bg, images);
  }
  for (final item in scene.items) {
    if (skipId != null && item.id != 0 && item.id == skipId) continue;
    paintSlideItem(canvas, item, s, images, prompts: prompts);
  }
  canvas.restore();
}

/// Paint one item of a scene.
void paintSlideItem(
  Canvas canvas,
  SlideItem it,
  double s,
  SlideImageLookup images, {
  bool prompts = false,
}) {
  final w = it.w * s;
  final h = it.h * s;
  final box = Rect.fromLTWH(0, 0, w, h);
  canvas.save();
  canvas.translate(it.x * s + w / 2, it.y * s + h / 2);
  if (it.rot != 0) canvas.rotate(it.rot * math.pi / 180);

  canvas.save();
  canvas.scale(it.flipH ? -1 : 1, it.flipV ? -1 : 1);
  canvas.translate(-w / 2, -h / 2);
  final paths = [for (final p in it.paths) (p, _toPath(p, s))];
  switch (it.kind) {
    case SlideItemKind.table:
      if (it.table != null) _paintTable(canvas, it.table!, s, images);
    case SlideItemKind.picture:
      _paintFills(canvas, paths, box, it.fill, images);
      final image = it.imagePart == null ? null : images(it.imagePart!);
      canvas.save();
      if (paths.isNotEmpty) canvas.clipPath(paths.first.$2);
      if (image != null) {
        _drawImage(canvas, image, box, it.crop);
      } else {
        canvas.drawRect(box, Paint()..color = const Color(0xFFE9ECEF));
      }
      canvas.restore();
      _paintStrokes(canvas, paths, it.line, s);
    case SlideItemKind.chart || SlideItemKind.other || SlideItemKind.diagram
        when it.fill == null:
      _paintStandIn(canvas, box, it.kind, s);
    default:
      _paintFills(canvas, paths, box, it.fill, images);
      _paintStrokes(canvas, paths, it.line, s);
  }
  canvas.restore();

  final text = it.text;
  if (text != null) {
    canvas.save();
    // Text is never mirrored; a vertical flip turns it upside down.
    if (it.flipV) canvas.rotate(math.pi);
    canvas.translate(-w / 2, -h / 2);
    final showPrompt = prompts && it.placeholder != null;
    paintSlideText(canvas, text, box, s, prompt: showPrompt);
    if (showPrompt && text.isEmpty) _dashedRect(canvas, box);
    canvas.restore();
  }
  canvas.restore();
}

Path _toPath(SlidePath p, double s) {
  final path = Path();
  for (final c in p.cmds) {
    final a = c.args;
    switch (c.op) {
      case 'M' when a.length == 2:
        path.moveTo(a[0] * s, a[1] * s);
      case 'L' when a.length == 2:
        path.lineTo(a[0] * s, a[1] * s);
      case 'C' when a.length == 6:
        path.cubicTo(
          a[0] * s,
          a[1] * s,
          a[2] * s,
          a[3] * s,
          a[4] * s,
          a[5] * s,
        );
      case 'Z':
        path.close();
    }
  }
  return path;
}

void _paintFills(
  Canvas canvas,
  List<(SlidePath, Path)> paths,
  Rect box,
  SlideFill? fill,
  SlideImageLookup images,
) {
  if (fill == null) return;
  for (final (p, path) in paths) {
    if (!p.fill) continue;
    _fillArea(canvas, path, box, fill, images);
    final shade = switch (p.shade) {
      'darken' => const Color(0x66000000),
      'darkenLess' => const Color(0x33000000),
      'lighten' => const Color(0x66FFFFFF),
      'lightenLess' => const Color(0x33FFFFFF),
      _ => null,
    };
    if (shade != null) canvas.drawPath(path, Paint()..color = shade);
  }
}

void _fillArea(
  Canvas canvas,
  Path path,
  Rect box,
  SlideFill fill,
  SlideImageLookup images,
) {
  switch (fill.type) {
    case 'solid':
      canvas.drawPath(path, Paint()..color = Color(fill.color));
    case 'gradient':
      final stops = [...fill.stops]..sort((a, b) => a.$1.compareTo(b.$1));
      if (stops.isEmpty) return;
      if (stops.length == 1) {
        canvas.drawPath(path, Paint()..color = Color(stops.first.$2));
        return;
      }
      final colors = [for (final s in stops) Color(s.$2)];
      final pos = [for (final s in stops) s.$1.clamp(0.0, 1.0)];
      final Shader shader;
      if (fill.radial) {
        shader = ui.Gradient.radial(
          box.center,
          math.max(box.longestSide / 2, 1),
          colors,
          pos,
        );
      } else {
        final a = fill.angle * math.pi / 180;
        final d = Offset(math.cos(a), math.sin(a));
        final half = (box.width * d.dx.abs() + box.height * d.dy.abs()) / 2;
        final c = box.center;
        shader = ui.Gradient.linear(
          c - d * math.max(half, 0.5),
          c + d * math.max(half, 0.5),
          colors,
          pos,
        );
      }
      canvas.drawPath(path, Paint()..shader = shader);
    case 'image':
      final image = fill.part == null ? null : images(fill.part!);
      canvas.save();
      canvas.clipPath(path);
      if (image != null) {
        _drawImage(canvas, image, box, const [0, 0, 0, 0]);
      } else {
        canvas.drawRect(box, Paint()..color = const Color(0xFFE9ECEF));
      }
      canvas.restore();
  }
}

void _drawImage(Canvas canvas, ui.Image image, Rect dst, List<double> crop) {
  final iw = image.width.toDouble();
  final ih = image.height.toDouble();
  final src = Rect.fromLTRB(
    iw * crop[0],
    ih * crop[1],
    iw * (1 - crop[2]),
    ih * (1 - crop[3]),
  );
  if (src.width <= 0 || src.height <= 0) return;
  canvas.drawImageRect(
    image,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.medium,
  );
}

void _paintStrokes(
  Canvas canvas,
  List<(SlidePath, Path)> paths,
  SlideLine? line,
  double s,
) {
  if (line == null || (line.color >> 24) == 0) return;
  final width = math.max(line.width * s, 0.6);
  final color = Color(line.color);
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color
    ..strokeJoin = StrokeJoin.round;
  final pattern = _dashPattern(line.dash);
  final stroked = [
    for (final (p, path) in paths)
      if (p.stroke) path,
  ];
  for (final path in stroked) {
    canvas.drawPath(
      pattern == null
          ? path
          : _dashed(path, [for (final d in pattern) d * width]),
      paint,
    );
  }
  if (stroked.isEmpty || (line.head == null && line.tail == null)) return;
  final metrics = stroked.first.computeMetrics().toList();
  if (metrics.isEmpty) return;
  final first = metrics.first;
  final last = metrics.last;
  if (line.head != null && first.length > 0) {
    final t = first.getTangentForOffset(0);
    if (t != null) {
      _arrow(canvas, t.position, -t.vector, line.head!, width, color);
    }
  }
  if (line.tail != null && last.length > 0) {
    final t = last.getTangentForOffset(last.length);
    if (t != null) {
      _arrow(canvas, t.position, t.vector, line.tail!, width, color);
    }
  }
}

List<double>? _dashPattern(String dash) => switch (dash) {
  'dash' => const [4, 3],
  'sysDash' => const [3, 1],
  'dot' => const [1, 3],
  'sysDot' => const [1, 1],
  'lgDash' => const [8, 3],
  'dashDot' => const [4, 3, 1, 3],
  'lgDashDot' => const [8, 3, 1, 3],
  'lgDashDotDot' => const [8, 3, 1, 3, 1, 3],
  'sysDashDot' => const [3, 1, 1, 1],
  'sysDashDotDot' => const [3, 1, 1, 1, 1, 1],
  _ => null,
};

Path _dashed(Path src, List<double> pattern) {
  final out = Path();
  if (pattern.any((d) => d < 0.3)) return src;
  for (final m in src.computeMetrics()) {
    var d = 0.0;
    var i = 0;
    while (d < m.length) {
      final len = pattern[i % pattern.length];
      if (i.isEven) {
        out.addPath(m.extractPath(d, math.min(d + len, m.length)), Offset.zero);
      }
      d += len;
      i++;
    }
  }
  return out;
}

/// An arrowhead at [tip], pointing along [dir].
void _arrow(
  Canvas canvas,
  Offset tip,
  Offset dir,
  String kind,
  double lineWidth,
  Color color,
) {
  final len = math.max(lineWidth * 3, 6.0);
  final half = math.max(lineWidth * 1.5, 3.0);
  final n = Offset(-dir.dy, dir.dx);
  final base = tip - dir * len;
  final fill = Paint()..color = color;
  switch (kind) {
    case 'arrow':
      canvas.drawPath(
        Path()
          ..moveTo(base.dx + n.dx * half, base.dy + n.dy * half)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(base.dx - n.dx * half, base.dy - n.dy * half),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..color = color
          ..strokeJoin = StrokeJoin.miter,
      );
    case 'oval':
      canvas.drawCircle(tip, half, fill);
    case 'diamond':
      final c = tip;
      canvas.drawPath(
        Path()
          ..moveTo(c.dx + dir.dx * half, c.dy + dir.dy * half)
          ..lineTo(c.dx + n.dx * half, c.dy + n.dy * half)
          ..lineTo(c.dx - dir.dx * half, c.dy - dir.dy * half)
          ..lineTo(c.dx - n.dx * half, c.dy - n.dy * half)
          ..close(),
        fill,
      );
    case 'stealth':
      final mid = tip - dir * (len * 0.6);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(base.dx + n.dx * half, base.dy + n.dy * half)
          ..lineTo(mid.dx, mid.dy)
          ..lineTo(base.dx - n.dx * half, base.dy - n.dy * half)
          ..close(),
        fill,
      );
    default:
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(base.dx + n.dx * half, base.dy + n.dy * half)
          ..lineTo(base.dx - n.dx * half, base.dy - n.dy * half)
          ..close(),
        fill,
      );
  }
}

/// A box for things the app cannot draw yet (charts, embedded objects).
void _paintStandIn(Canvas canvas, Rect box, SlideItemKind kind, double s) {
  canvas.drawRect(box, Paint()..color = const Color(0xFFF1F3F5));
  canvas.drawRect(
    box,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFFADB5BD),
  );
  final label = switch (kind) {
    SlideItemKind.chart => 'Chart',
    SlideItemKind.diagram => 'Diagram',
    _ => 'Object',
  };
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: const Color(0xFF6C757D),
        fontSize: math.max(10, 14 * s),
        fontFamily: debugSlideSansFamily,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(box.width, 1));
  tp.paint(canvas, box.center - Offset(tp.width / 2, tp.height / 2));
}

void _dashedRect(Canvas canvas, Rect box) {
  canvas.drawPath(
    _dashed(Path()..addRect(box), const [5, 4]),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFADB5BD),
  );
}

// ------------------------------------------------------------------ tables

void _paintTable(
  Canvas canvas,
  SlideTable t,
  double s,
  SlideImageLookup images,
) {
  final xs = <double>[0];
  for (final c in t.cols) {
    xs.add(xs.last + c * s);
  }
  final ys = slideTableRowEdges(t, s);
  final lines = <(Offset, Offset, SlideLine)>[];
  for (var r = 0; r < t.rows.length; r++) {
    final cells = t.rows[r].$2;
    for (var c = 0; c < cells.length && c < t.cols.length; c++) {
      final cell = cells[c];
      if (cell.merged) continue;
      final right = xs[math.min(c + cell.colSpan, xs.length - 1)];
      final bottom = ys[math.min(r + cell.rowSpan, ys.length - 1)];
      final rect = Rect.fromLTRB(xs[c], ys[r], right, bottom);
      if (cell.fill != null) {
        _fillArea(canvas, Path()..addRect(rect), rect, cell.fill!, images);
      }
      paintSlideText(canvas, cell.text, rect, s);
      final b = cell.borders;
      if (b.length == 4) {
        if (b[0] != null) lines.add((rect.topLeft, rect.bottomLeft, b[0]!));
        if (b[1] != null) lines.add((rect.topLeft, rect.topRight, b[1]!));
        if (b[2] != null) lines.add((rect.topRight, rect.bottomRight, b[2]!));
        if (b[3] != null) {
          lines.add((rect.bottomLeft, rect.bottomRight, b[3]!));
        }
      }
    }
  }
  for (final (a, b, l) in lines) {
    if ((l.color >> 24) == 0 || l.width <= 0) continue;
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = Color(l.color)
        ..strokeWidth = math.max(l.width * s, 0.6),
    );
  }
}

/// Where a table's rows start, in pixels: rows grow to fit their text.
List<double> slideTableRowEdges(SlideTable t, double s) {
  final ys = <double>[0];
  for (final (height, cells) in t.rows) {
    var need = height * s;
    var x = 0;
    for (final cell in cells) {
      final span = cell.colSpan;
      if (!cell.merged && cell.rowSpan == 1 && x < t.cols.length) {
        var width = 0.0;
        for (var k = x; k < x + span && k < t.cols.length; k++) {
          width += t.cols[k] * s;
        }
        final box = cell.text;
        final inner = width - (box.insets[0] + box.insets[2]) * s;
        final h =
            layoutSlideText(box, math.max(inner, 1), s).height +
            (box.insets[1] + box.insets[3]) * s;
        need = math.max(need, h);
      }
      x++;
    }
    ys.add(ys.last + need);
  }
  return ys;
}

// -------------------------------------------------------------------- text

class _LaidPara {
  _LaidPara(this.painter, this.left, this.top, this.bullet, this.bulletLeft);
  final TextPainter painter;
  final double left;
  final double top;
  final TextPainter? bullet;
  final double bulletLeft;
}

/// A text box laid out at a width, ready to paint.
class SlideTextLayout {
  SlideTextLayout._(this._paras, this.height);
  final List<_LaidPara> _paras;
  final double height;

  void paint(Canvas canvas, Offset origin) {
    for (final p in _paras) {
      p.painter.paint(canvas, origin + Offset(p.left, p.top));
      final b = p.bullet;
      if (b != null) {
        final base = p.painter.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final bb = b.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        b.paint(canvas, origin + Offset(p.bulletLeft, p.top + base - bb));
      }
    }
  }
}

final String _zeroWidth = String.fromCharCode(0x200B);
final String _lineSep = String.fromCharCode(0x2028);

TextStyle _runStyle(SlideRun r, double s, {int? color}) {
  final small = r.baseline != 0;
  return TextStyle(
    fontSize: math.max(r.size * s * (small ? 0.66 : 1), 0.5),
    fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
    color: Color(color ?? r.color),
    fontFamily: slideFontFamily(r.font),
    backgroundColor: r.highlight == null ? null : Color(r.highlight!),
    decoration: TextDecoration.combine([
      if (r.underline || r.link != null) TextDecoration.underline,
      if (r.strike) TextDecoration.lineThrough,
    ]),
    decorationColor: Color(color ?? r.color),
  );
}

/// Lay out a text box's paragraphs at [width] pixels.
SlideTextLayout layoutSlideText(
  SlideTextBox box,
  double width,
  double s, {
  bool prompt = false,
}) {
  final out = <_LaidPara>[];
  var y = 0.0;
  final showPrompt = prompt && box.isEmpty && (box.prompt ?? '').isNotEmpty;
  for (var i = 0; i < box.paras.length; i++) {
    final p = box.paras[i];
    if (showPrompt && i > 0) break;
    final runs = showPrompt
        ? [
            SlideRun(
              text: box.prompt!,
              size: p.endSize,
              color: 0xFF8A8A8A,
              font: p.runs.isEmpty ? '' : p.runs.first.font,
            ),
          ]
        : p.runs.where((r) => r.text.isNotEmpty).toList();
    final empty = runs.isEmpty;
    var maxSize = empty ? p.endSize : 0.0;
    for (final r in runs) {
      maxSize = math.max(maxSize, r.size);
    }
    if (maxSize <= 0) maxSize = 18;
    final spans = <InlineSpan>[
      for (final r in runs)
        TextSpan(
          text: r.text.replaceAll(_lineSep, '\n'),
          style: _runStyle(r, s),
        ),
      if (empty)
        TextSpan(
          text: _zeroWidth,
          style: TextStyle(
            fontSize: p.endSize * s,
            fontFamily: debugSlideSansFamily,
          ),
        ),
    ];

    final bullet = p.bullet == null || empty || showPrompt
        ? null
        : (TextPainter(
            text: TextSpan(
              text: p.bullet!.text,
              style: TextStyle(
                fontSize: math.max(p.bullet!.size * s, 0.5),
                color: Color(p.bullet!.color),
                fontFamily: slideFontFamily(p.bullet!.font),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout());
    final marL = p.marginLeft * s;
    final firstLeft = bullet != null
        ? math.max(marL, (p.marginLeft + p.indent) * s + bullet.width * 1.4)
        : (p.marginLeft + p.indent) * s;
    final left = math.max(0.0, math.min(marL, firstLeft));
    final lead = firstLeft - left;
    if (lead > 0.5) {
      spans.insert(0, WidgetSpan(child: SizedBox(width: lead)));
    }

    final lineHeight = p.linePoints
        ? (p.line / maxSize).clamp(0.5, 6.0)
        : (1.2 * p.line).clamp(0.5, 6.0);
    final align = switch (p.align) {
      'ctr' => TextAlign.center,
      'r' => TextAlign.right,
      'just' || 'dist' || 'justLow' || 'thaiDist' => TextAlign.justify,
      _ => TextAlign.left,
    };
    final painter = TextPainter(
      text: TextSpan(children: spans),
      textAlign: box.wrap ? align : TextAlign.left,
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle(
        fontSize: maxSize * s,
        height: lineHeight.toDouble(),
        forceStrutHeight: true,
      ),
    );
    if (lead > 0.5) {
      painter.setPlaceholderDimensions([
        PlaceholderDimensions(
          size: Size(lead, 0),
          alignment: PlaceholderAlignment.bottom,
        ),
      ]);
    }
    final avail = math.max(width - left, 1.0);
    double x = left;
    if (box.wrap) {
      painter.layout(minWidth: avail, maxWidth: avail);
    } else {
      painter.layout();
      x += switch (align) {
        TextAlign.center => (avail - painter.width) / 2,
        TextAlign.right => avail - painter.width,
        _ => 0,
      };
    }
    if (i > 0) y += p.spaceBefore * s;
    out.add(
      _LaidPara(
        painter,
        x,
        y,
        bullet,
        math.max(0, (p.marginLeft + p.indent) * s),
      ),
    );
    y += painter.height + p.spaceAfter * s;
  }
  return SlideTextLayout._(out, y);
}

/// Paint a text box inside [rect] (the shape's box, before insets).
void paintSlideText(
  Canvas canvas,
  SlideTextBox box,
  Rect rect,
  double s, {
  bool prompt = false,
}) {
  if (box.paras.isEmpty) return;
  if (box.isEmpty && !prompt) return;
  var r = Rect.fromLTRB(
    rect.left + box.insets[0] * s,
    rect.top + box.insets[1] * s,
    rect.right - box.insets[2] * s,
    rect.bottom - box.insets[3] * s,
  );
  canvas.save();
  switch (box.vertical) {
    case 'vert' || 'eaVert' || 'mongolianVert':
      canvas.translate(r.right, r.top);
      canvas.rotate(math.pi / 2);
      r = Rect.fromLTWH(0, 0, r.height, r.width);
    case 'vert270':
      canvas.translate(r.left, r.bottom);
      canvas.rotate(-math.pi / 2);
      r = Rect.fromLTWH(0, 0, r.height, r.width);
  }
  final laid = layoutSlideText(box, math.max(r.width, 1), s, prompt: prompt);
  final top = switch (box.anchor) {
    'ctr' => r.top + (r.height - laid.height) / 2,
    'b' => r.bottom - laid.height,
    _ => r.top,
  };
  laid.paint(canvas, Offset(r.left, top));
  canvas.restore();
}
