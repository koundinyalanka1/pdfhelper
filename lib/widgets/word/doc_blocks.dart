import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_word_core/flutter_word_core.dart';

import 'doc_style.dart';

/// A paragraph as it reads: list label, indents, spacing, alignment, styled
/// text, pictures and other objects.
class DocParagraphView extends StatelessWidget {
  const DocParagraphView({
    super.key,
    required this.para,
    required this.look,
    required this.width,
    this.imageFile,
    this.highlights = const [],
    this.current,
  });

  final ParaBlock para;
  final DocLook look;

  /// The width available, in pixels.
  final double width;

  /// The file an image object's bytes were saved to (null while loading
  /// or when there is none).
  final File? Function(DocObject object)? imageFile;

  /// Ranges of the text to mark (search matches), UTF-16 offsets.
  final List<(int, int)> highlights;

  /// The match being looked at, marked more strongly.
  final (int, int)? current;

  static const Color _hit = Color(0x66FFEB3B);
  static const Color _currentHit = Color(0xCCFF9800);

  @override
  Widget build(BuildContext context) {
    final s = para.style;
    final pad = look.padding(s, width);
    final textWidth = math.max(40.0, width - pad.horizontal);
    final spans = <InlineSpan>[];
    final firstLine = s.firstLine * look.scale;
    if (para.list == null && firstLine > 0) {
      spans.add(
        WidgetSpan(child: SizedBox(width: math.min(firstLine, textWidth / 3))),
      );
    }
    var pos = 0;
    for (final inline in para.inlines) {
      switch (inline) {
        case TextInline(:final text, :final style, :final link):
          _addText(spans, text, style, link, pos);
          pos += text.length;
        case ObjectInline(:final object):
          spans.add(_object(object, textWidth));
          pos += object.text.length;
      }
    }
    if (spans.isEmpty || para.inlines.isEmpty) {
      // An empty paragraph is still a line high.
      spans.add(
        TextSpan(
          text: '​',
          style: look.text(s.mark, line: s.line),
        ),
      );
    }
    Widget text = Text.rich(
      TextSpan(children: spans),
      textAlign: look.align(s.align),
      textDirection: s.bidi ? TextDirection.rtl : null,
      style: look.text(s.mark, line: s.line),
    );
    final label = para.list;
    if (label != null) {
      final labelStyle = look.text(
        label.style.copyWith(size: s.mark.size),
        line: s.line,
      );
      final hanging = math.max(-firstLine, 0.0);
      final labelWidth = math.max(
        hanging,
        (label.text.length + 1) * labelStyle.fontSize! * 0.6,
      );
      text = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: math.min(labelWidth, textWidth / 3),
            child: Text(
              label.text,
              style: labelStyle,
              maxLines: 1,
              softWrap: false,
            ),
          ),
          Expanded(child: text),
        ],
      );
    }
    Widget out = Padding(padding: pad, child: text);
    if (s.shading != null) {
      out = ColoredBox(color: Color(0xFF000000 | s.shading!), child: out);
    }
    if (!para.editable) {
      out = Stack(
        children: [
          out,
          Positioned(
            right: 0,
            top: pad.top,
            child: const Icon(
              Icons.lock_outline,
              size: 14,
              color: Color(0x66000000),
            ),
          ),
        ],
      );
    }
    return out;
  }

  void _addText(
    List<InlineSpan> spans,
    String text,
    RunStyle style,
    String? link,
    int start,
  ) {
    final shown = DocLook.shown(text, style);
    final base = look.text(style, line: para.style.line, link: link);
    if (highlights.isEmpty && current == null) {
      spans.add(TextSpan(text: shown, style: base));
      return;
    }
    // Cut the text where marked ranges begin and end.
    final end = start + text.length;
    final cuts = <int>{start, end};
    for (final (a, l) in [...highlights, ?current]) {
      if (a > start && a < end) cuts.add(a);
      if (a + l > start && a + l < end) cuts.add(a + l);
    }
    final sorted = cuts.toList()..sort();
    for (var k = 0; k + 1 < sorted.length; k++) {
      final a = sorted[k];
      final b = sorted[k + 1];
      bool inside((int, int) r) => a >= r.$1 && b <= r.$1 + r.$2;
      final isCurrent = current != null && inside(current!);
      final isHit = highlights.any(inside);
      spans.add(
        TextSpan(
          text: shown.substring(a - start, b - start),
          style: isCurrent
              ? base.copyWith(backgroundColor: _currentHit)
              : isHit
              ? base.copyWith(backgroundColor: _hit)
              : base,
        ),
      );
    }
  }

  InlineSpan _object(DocObject o, double textWidth) {
    switch (o.kind) {
      case DocObjectKind.image:
      case DocObjectKind.shape:
        final file = imageFile?.call(o);
        var w = o.width > 0 ? o.width * look.scale : 120.0;
        var h = o.height > 0 ? o.height * look.scale : 80.0;
        if (w > textWidth) {
          h = h * textWidth / w;
          w = textWidth;
        }
        final Widget child = file == null
            ? _placeholder(o, w, h)
            : Image.file(
                file,
                width: w,
                height: h,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _placeholder(o, w, h),
              );
        return WidgetSpan(alignment: PlaceholderAlignment.bottom, child: child);
      case DocObjectKind.pageBreak:
        return WidgetSpan(child: _PageBreak(width: textWidth));
      case DocObjectKind.columnBreak:
        return const TextSpan(text: '\n');
      case DocObjectKind.note:
        return TextSpan(
          text: o.text,
          style: look.text(o.style.copyWith(vert: 'super')),
        );
      case DocObjectKind.equation:
        return TextSpan(
          text: o.text,
          style: look
              .text(o.style.copyWith(italic: true))
              .copyWith(fontFamily: 'serif'),
        );
      case DocObjectKind.field:
      case DocObjectKind.control:
      case DocObjectKind.other:
        return TextSpan(
          text: o.text,
          style: look.text(o.style, line: para.style.line),
        );
    }
  }

  Widget _placeholder(DocObject o, double w, double h) => Container(
    width: w,
    height: h,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFF1F3F4),
      border: Border.all(color: const Color(0xFFDADCE0)),
    ),
    child: Icon(
      o.kind == DocObjectKind.image
          ? Icons.image_outlined
          : Icons.category_outlined,
      color: const Color(0xFF9AA0A6),
      size: math.min(32, math.min(w, h) * 0.6),
    ),
  );
}

class _PageBreak extends StatelessWidget {
  const _PageBreak({required this.width});
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: Color(0xFFBDC1C6), thickness: 1)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Page break',
              style: TextStyle(fontSize: 11, color: Color(0xFF80868B)),
            ),
          ),
          Expanded(child: Divider(color: Color(0xFFBDC1C6), thickness: 1)),
        ],
      ),
    ),
  );
}

/// A table: cells sized from the document's column widths, merged cells
/// spanning their columns, and each cell's blocks.
class DocTableView extends StatelessWidget {
  const DocTableView({
    super.key,
    required this.table,
    required this.look,
    required this.width,
    required this.buildBlock,
    this.onCellLongPress,
  });

  final TableBlock table;
  final DocLook look;
  final double width;

  /// Builds a cell's block at a width.
  final Widget Function(DocBlock block, double width) buildBlock;

  /// Long press on a cell: its row and column.
  final void Function(int row, int col)? onCellLongPress;

  static const Color _line = Color(0xFF9AA0A6);

  List<double> _columns() {
    final cols = table.rows.fold<int>(
      0,
      (m, r) => math.max(m, r.cells.fold<int>(0, (a, c) => a + c.colSpan)),
    );
    var widths = [for (final w in table.colWidths) w * look.scale];
    if (widths.length < cols || widths.any((w) => w <= 1)) {
      widths = List.filled(cols, width / math.max(cols, 1));
    }
    // A table wider than the screen shrinks to fit, as far as its columns
    // stay wide enough to read; beyond that it scrolls sideways.
    final total = widths.fold<double>(0, (a, b) => a + b);
    if (total > width) {
      widths = [for (final w in widths) w * width / total];
    }
    return [for (final w in widths) math.max(w, 48.0)];
  }

  @override
  Widget build(BuildContext context) {
    final cols = _columns();
    final total = cols.fold<double>(0, (a, b) => a + b);
    final rows = <Widget>[];
    for (var r = 0; r < table.rows.length; r++) {
      final row = table.rows[r];
      final cells = <Widget>[];
      var g = 0;
      for (var c = 0; c < row.cells.length; c++) {
        final cell = row.cells[c];
        final int span = cell.colSpan
            .clamp(1, math.max(1, cols.length - g))
            .toInt();
        final w = g < cols.length
            ? cols
                  .sublist(g, math.min(cols.length, g + span))
                  .fold<double>(0, (a, b) => a + b)
            : 60.0;
        g += span;
        final side = BorderSide(
          color: table.borders ? _line : const Color(0x22000000),
          width: table.borders ? 0.8 : 0.5,
        );
        final content = cell.mergedUp
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [for (final b in cell.blocks) buildBlock(b, w - 8)],
              );
        Widget box = Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: cell.fill == null ? null : Color(0xFF000000 | cell.fill!),
            border: Border(
              left: side,
              right: side,
              top: cell.mergedUp ? BorderSide.none : side,
              bottom: cell.rowSpan > 1 ? BorderSide.none : side,
            ),
          ),
          child: content,
        );
        if (onCellLongPress != null) {
          final rr = r;
          final cc = c;
          box = GestureDetector(
            onLongPress: () => onCellLongPress!(rr, cc),
            child: box,
          );
        }
        cells.add(box);
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    final grid = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: grid,
    );
    if (total <= width + 0.5) return body;
    return SingleChildScrollView(scrollDirection: Axis.horizontal, child: body);
  }
}

/// Content shown only as its text.
class DocOtherView extends StatelessWidget {
  const DocOtherView({super.key, required this.block, required this.look});

  final OtherBlock block;
  final DocLook look;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0x22000000)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      block.text.trim().isEmpty ? 'Content this app does not show' : block.text,
      style: look
          .text(const RunStyle())
          .copyWith(color: const Color(0xFF5F6368)),
    ),
  );
}
