import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';

/// What a touch on a page does in the PDF editor.
enum PdfEditTool {
  /// Scroll, fill fields, pick an item to move or remove.
  browse,
  highlight,
  underline,
  strikeOut,
  pen,
  text,
  note,
  rectangle,
  ellipse,
  arrow,
  signature,
  image;

  /// Tools whose drags draw rather than scroll.
  bool get draws => const {
    highlight,
    underline,
    strikeOut,
    pen,
    rectangle,
    ellipse,
    arrow,
  }.contains(this);

  /// Tools that put something where the page is tapped.
  bool get places => const {text, note, signature, image}.contains(this);

  bool get marksText => const {highlight, underline, strikeOut}.contains(this);
}

PdfBox _box(Rect r) => PdfBox(r.left, r.top, r.right, r.bottom);

int _argb(Color c) => c.toARGB32();

/// Something added on a page and not yet saved. Positions are displayed
/// page points (top-left origin), as the engine takes them.
sealed class EditItem {
  const EditItem(this.page);

  /// 1-based.
  final int page;

  Rect get bounds;

  /// Moved by dragging when selected.
  bool get movable => false;

  EditItem translated(Offset by) => this;

  PdfAnnotationEdit toEdit({bool flatten = false});
}

/// Highlight, underline or strike-out: one rectangle per line.
class MarkupItem extends EditItem {
  const MarkupItem(super.page, this.tool, this.rects, this.color);

  final PdfEditTool tool;
  final List<Rect> rects;
  final Color color;

  @override
  Rect get bounds => rects.reduce((a, b) => a.expandToInclude(b));

  PdfAnnotationType get type => switch (tool) {
    PdfEditTool.underline => PdfAnnotationType.underline,
    PdfEditTool.strikeOut => PdfAnnotationType.strikeOut,
    _ => PdfAnnotationType.highlight,
  };

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => PdfAnnotationEdit.markup(
    type,
    page: page,
    rects: [for (final r in rects) _box(r)],
    color: _argb(color),
  );
}

class InkItem extends EditItem {
  const InkItem(super.page, this.strokes, this.color, this.width);

  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  @override
  Rect get bounds {
    final all = strokes.expand((s) => s);
    var r = Rect.fromPoints(all.first, all.first);
    for (final p in all) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r.inflate(width);
  }

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) => InkItem(
    page,
    [
      for (final s in strokes) [for (final p in s) p + by],
    ],
    color,
    width,
  );

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => PdfAnnotationEdit.ink(
    page: page,
    strokes: [
      for (final s in strokes) [for (final p in s) (p.dx, p.dy)],
    ],
    color: _argb(color),
    width: width,
    flatten: flatten,
  );
}

/// A rectangle, an ellipse or an arrow from [from] to [to].
class ShapeItem extends EditItem {
  const ShapeItem(
    super.page,
    this.tool,
    this.from,
    this.to,
    this.color,
    this.width,
  );

  final PdfEditTool tool;
  final Offset from;
  final Offset to;
  final Color color;
  final double width;

  Rect get box => Rect.fromPoints(from, to);

  @override
  Rect get bounds => box.inflate(width * 4);

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) =>
      ShapeItem(page, tool, from + by, to + by, color, width);

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => tool == PdfEditTool.arrow
      ? PdfAnnotationEdit.line(
          page: page,
          from: (from.dx, from.dy),
          to: (to.dx, to.dy),
          arrow: true,
          color: _argb(color),
          width: width,
          flatten: flatten,
        )
      : PdfAnnotationEdit.shape(
          page: page,
          box: _box(box),
          ellipse: tool == PdfEditTool.ellipse,
          color: _argb(color),
          width: width,
          flatten: flatten,
        );
}

/// Typed text: a bordered text box, or plain text as a form is filled in.
class TextItem extends EditItem {
  const TextItem(
    super.page,
    this.box,
    this.text,
    this.fontSize,
    this.color, {
    this.bordered = false,
  });

  final Rect box;
  final String text;
  final double fontSize;
  final Color color;
  final bool bordered;

  /// The box text of [fontSize] needs, its top-left at [at].
  static Rect boxFor(String text, double fontSize, Offset at, bool bordered) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: 'Helvetica',
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = bordered ? 6.0 : 2.0;
    return Rect.fromLTWH(
      at.dx,
      at.dy,
      painter.width * 1.08 + pad * 2,
      painter.height + pad * 2,
    );
  }

  @override
  Rect get bounds => box;

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) =>
      TextItem(page, box.shift(by), text, fontSize, color, bordered: bordered);

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => PdfAnnotationEdit.textBox(
    page: page,
    box: _box(box),
    text: text,
    fontSize: fontSize,
    color: _argb(color),
    border: bordered ? 1 : 0,
    flatten: flatten,
  );
}

class NoteItem extends EditItem {
  const NoteItem(super.page, this.at, this.text, this.color);

  final Offset at;
  final String text;
  final Color color;

  @override
  Rect get bounds => Rect.fromLTWH(at.dx, at.dy, 24, 24);

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) => NoteItem(page, at + by, text, color);

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => PdfAnnotationEdit.note(
    page: page,
    at: (at.dx, at.dy),
    text: text,
    color: _argb(color),
  );
}

/// A drawn signature: strokes in a unit box, drawn into [box].
class SignatureItem extends EditItem {
  const SignatureItem(
    super.page,
    this.box,
    this.strokes,
    this.color,
    this.width,
  );

  final Rect box;

  /// Each point 0–1 across and down the box.
  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  Offset place(Offset unit) =>
      Offset(box.left + unit.dx * box.width, box.top + unit.dy * box.height);

  @override
  Rect get bounds => box;

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) =>
      SignatureItem(page, box.shift(by), strokes, color, width);

  SignatureItem resized(Rect to) =>
      SignatureItem(page, to, strokes, color, width);

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) =>
      PdfAnnotationEdit.signature(
        page: page,
        box: _box(box),
        strokes: [
          for (final s in strokes)
            [for (final p in s) (place(p).dx, place(p).dy)],
        ],
        color: _argb(color),
        width: width,
        flatten: flatten,
      );
}

/// A picture, kept as raw RGBA in a file for the engine.
class ImageItem extends EditItem {
  const ImageItem(
    super.page,
    this.box,
    this.rgbaPath,
    this.pixelWidth,
    this.pixelHeight,
    this.preview,
  );

  final Rect box;
  final String rgbaPath;
  final int pixelWidth;
  final int pixelHeight;
  final ui.Image preview;

  @override
  Rect get bounds => box;

  @override
  bool get movable => true;

  @override
  EditItem translated(Offset by) => ImageItem(
    page,
    box.shift(by),
    rgbaPath,
    pixelWidth,
    pixelHeight,
    preview,
  );

  ImageItem resized(Rect to) =>
      ImageItem(page, to, rgbaPath, pixelWidth, pixelHeight, preview);

  @override
  PdfAnnotationEdit toEdit({bool flatten = false}) => PdfAnnotationEdit.image(
    page: page,
    box: _box(box),
    image: PdfImageSource.rgba(rgbaPath, pixelWidth, pixelHeight),
    flatten: flatten,
  );
}

/// A smooth path through points, as the engine draws them.
Path smoothPath(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  if (points.length < 3) {
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (points.length == 1) {
      path.lineTo(points.first.dx + 0.01, points.first.dy);
    }
    return path;
  }
  for (var i = 1; i < points.length - 1; i++) {
    final mid = (points[i] + points[i + 1]) / 2;
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

/// Draws a page's pending items, scaled from page points to the screen.
class EditItemsPainter extends CustomPainter {
  EditItemsPainter({
    required this.items,
    required this.scale,
    this.selected,
    this.draft,
    this.removed = const [],
  });

  final List<EditItem> items;
  final double scale;
  final EditItem? selected;

  /// What is being drawn right now.
  final EditItem? draft;

  /// Existing annotations marked for removal.
  final List<Rect> removed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    for (final item in [...items, ?draft]) {
      _paint(canvas, item);
    }
    final cross = Paint()
      ..color = const Color(0xCCE53935)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / scale;
    for (final r in removed) {
      canvas.drawRect(r, cross);
      canvas.drawLine(r.topLeft, r.bottomRight, cross);
      canvas.drawLine(r.topRight, r.bottomLeft, cross);
    }
    if (selected != null) {
      final r = selected!.bounds.inflate(3);
      canvas.drawRect(
        r,
        Paint()
          ..color = const Color(0xFF1E88E5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / scale,
      );
      if (selected is SignatureItem || selected is ImageItem) {
        canvas.drawCircle(
          r.bottomRight,
          7 / scale,
          Paint()..color = const Color(0xFF1E88E5),
        );
      }
    }
    canvas.restore();
  }

  void _paint(Canvas canvas, EditItem item) {
    switch (item) {
      case MarkupItem(:final tool, :final rects, :final color):
        for (final r in rects) {
          if (tool == PdfEditTool.highlight) {
            canvas.drawRect(
              r,
              Paint()
                ..color = color.withValues(alpha: 0.45)
                ..blendMode = BlendMode.multiply,
            );
          } else {
            final y = tool == PdfEditTool.underline
                ? r.bottom - r.height * 0.08
                : r.bottom - r.height * 0.42;
            canvas.drawLine(
              Offset(r.left, y),
              Offset(r.right, y),
              Paint()
                ..color = color
                ..strokeWidth = (r.height / 14).clamp(0.5, 4),
            );
          }
        }
      case InkItem(:final strokes, :final color, :final width):
        final paint = _pen(color, width);
        for (final s in strokes) {
          canvas.drawPath(smoothPath(s), paint);
        }
      case ShapeItem(
        :final tool,
        :final from,
        :final to,
        :final color,
        :final width,
      ):
        final paint = _pen(color, width);
        final box = Rect.fromPoints(from, to);
        switch (tool) {
          case PdfEditTool.rectangle:
            canvas.drawRect(box.deflate(width / 2), paint);
          case PdfEditTool.ellipse:
            canvas.drawOval(box.deflate(width / 2), paint);
          default:
            canvas.drawLine(from, to, paint);
            final d = to - from;
            if (d.distance > 0) {
              final u = d / d.distance;
              final head = (width * 3).clamp(8.0, 40.0);
              for (final s in [1.0, -1.0]) {
                final angle = 0.45 * s;
                final c = Offset(
                  u.dx * math.cos(angle) - u.dy * math.sin(angle),
                  u.dy * math.cos(angle) + u.dx * math.sin(angle),
                );
                canvas.drawLine(to, to - c * head, paint);
              }
            }
        }
      case TextItem(
        :final box,
        :final text,
        :final fontSize,
        :final color,
        :final bordered,
      ):
        if (bordered) {
          canvas.drawRect(
            box.deflate(0.5),
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
        final pad = bordered ? 3.0 : 0.0;
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(color: color, fontSize: fontSize, height: 1.2),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: (box.width - pad * 2).clamp(1, double.infinity));
        canvas.save();
        canvas.clipRect(box);
        painter.paint(canvas, box.topLeft + Offset(pad, pad));
        canvas.restore();
      case NoteItem(:final at, :final color):
        final r = Rect.fromLTWH(at.dx + 3, at.dy + 2, 18, 14);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)),
          Paint()..color = color,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)),
          Paint()
            ..color = const Color(0xFF404040)
            ..style = PaintingStyle.stroke,
        );
      case SignatureItem(:final strokes, :final color, :final width):
        final paint = _pen(color, width);
        for (final s in strokes) {
          canvas.drawPath(
            smoothPath([for (final p in s) item.place(p)]),
            paint,
          );
        }
      case ImageItem(:final box, :final preview):
        paintImage(canvas: canvas, rect: box, image: preview, fit: BoxFit.fill);
    }
  }

  static Paint _pen(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  bool shouldRepaint(EditItemsPainter old) =>
      old.items != items ||
      old.scale != scale ||
      old.selected != selected ||
      old.draft != draft ||
      old.removed != removed;
}
