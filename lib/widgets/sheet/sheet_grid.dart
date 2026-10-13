import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';

import 'sheet_grid_data.dart';

/// Excel's green, for the selection.
const Color sheetSelectionColor = Color(0xFF21A366);

/// The selection and the viewport of a grid, shared with its screen.
class SheetGridController extends ChangeNotifier {
  int activeRow = 0;
  int activeCol = 0;
  CellRange selection = const CellRange(0, 0, 0, 0);
  double scrollX = 0;
  double scrollY = 0;
  double zoom = 1;

  /// Set by the grid: the visible size of the scrolled part.
  Size viewport = Size.zero;

  void select(int row, int col, {bool extend = false}) {
    row = row.clamp(0, SheetGridData.maxRows - 1);
    col = col.clamp(0, SheetGridData.maxCols - 1);
    if (extend) {
      selection = CellRange(
        math.min(activeRow, row),
        math.min(activeCol, col),
        math.max(activeRow, row),
        math.max(activeCol, col),
      );
    } else {
      activeRow = row;
      activeCol = col;
      selection = CellRange(row, col, row, col);
    }
    notifyListeners();
  }

  void selectRange(CellRange range, {int? activeRow, int? activeCol}) {
    selection = range;
    this.activeRow = activeRow ?? range.r0;
    this.activeCol = activeCol ?? range.c0;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

/// Draws a sheet and handles touch: scroll, fling, pinch zoom, tap to
/// select, drag the handle or long-press and drag to select a range,
/// double-tap to edit, long-press for a menu.
class SheetGrid extends StatefulWidget {
  const SheetGrid({
    super.key,
    required this.data,
    required this.controller,
    required this.dark,
    this.onEdit,
    this.onMenu,
    this.onSelectionChanged,
  });

  final SheetGridData data;
  final SheetGridController controller;
  final bool dark;

  /// Double-tap on a cell.
  final void Function(int row, int col)? onEdit;

  /// Long-press without dragging: a menu for the selection at [position].
  final void Function(Offset position)? onMenu;
  final VoidCallback? onSelectionChanged;

  static const double headerHeight = 24;
  static const double headerWidth = 46;

  @override
  State<SheetGrid> createState() => _SheetGridState();
}

enum _DragMode { none, pan, handle }

class _SheetGridState extends State<SheetGrid>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Simulation? _flingX;
  Simulation? _flingY;
  Duration _flingStart = Duration.zero;
  double _scaleStartZoom = 1;
  Offset _lastFocal = Offset.zero;
  _DragMode _mode = _DragMode.none;
  bool _longPressMoved = false;
  Size _size = Size.zero;

  SheetGridController get _c => widget.controller;
  SheetGridData get _d => widget.data;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double get _hw => SheetGrid.headerWidth;
  double get _hh => SheetGrid.headerHeight;

  ({int row, int col})? get _freeze => _d.info.freeze;

  double get _frozenW =>
      (_freeze == null ? 0 : _d.cols.start(_freeze!.col)) * _c.zoom;
  double get _frozenH =>
      (_freeze == null ? 0 : _d.rows.start(_freeze!.row)) * _c.zoom;

  /// How far the sheet scrolls: past the used range, with room to grow.
  double get _maxScrollX {
    final used = _d.info.used;
    final lastCol = math.min(
      SheetGridData.maxCols,
      (used?.c1 ?? 0) + 30,
    );
    final visible = _size.width - _hw - _frozenW;
    return math.max(0, _d.cols.start(lastCol) * _c.zoom - _frozenW - visible);
  }

  double get _maxScrollY {
    final used = _d.info.used;
    final lastRow = math.min(SheetGridData.maxRows, (used?.r1 ?? 0) + 100);
    final visible = _size.height - _hh - _frozenH;
    return math.max(0, _d.rows.start(lastRow) * _c.zoom - _frozenH - visible);
  }

  void _clampScroll() {
    _c.scrollX = _c.scrollX.clamp(0, _maxScrollX);
    _c.scrollY = _c.scrollY.clamp(0, _maxScrollY);
  }

  void _onTick(Duration elapsed) {
    final t = (elapsed - _flingStart).inMicroseconds / 1e6;
    var done = true;
    if (_flingX != null) {
      _c.scrollX = _flingX!.x(t);
      done &= _flingX!.isDone(t);
    }
    if (_flingY != null) {
      _c.scrollY = _flingY!.x(t);
      done &= _flingY!.isDone(t);
    }
    _clampScroll();
    _c.changed();
    if (done) _ticker.stop();
  }

  void _stopFling() {
    if (_ticker.isActive) _ticker.stop();
  }

  /// The cell under a point, or a header (-1 for the header itself).
  ({int row, int col}) _hit(Offset p) {
    final z = _c.zoom;
    int col, row;
    if (p.dx < _hw) {
      col = -1;
    } else {
      final x = p.dx - _hw;
      final content = x < _frozenW ? x : x + _c.scrollX;
      col = _d.cols.indexAt(content / z);
    }
    if (p.dy < _hh) {
      row = -1;
    } else {
      final y = p.dy - _hh;
      final content = y < _frozenH ? y : y + _c.scrollY;
      row = _d.rows.indexAt(content / z);
    }
    return (row: row, col: col);
  }

  /// The selection handle's centre on screen.
  Offset _handleCenter() {
    final s = _c.selection;
    final z = _c.zoom;
    double x = _d.cols.start(s.c1 + 1) * z;
    double y = _d.rows.start(s.r1 + 1) * z;
    x += _hw - (s.c1 >= (_freeze?.col ?? 0) ? _c.scrollX : 0);
    y += _hh - (s.r1 >= (_freeze?.row ?? 0) ? _c.scrollY : 0);
    return Offset(x, y);
  }

  void _onTapUp(TapUpDetails d) {
    _stopFling();
    final hit = _hit(d.localPosition);
    if (hit.row < 0 && hit.col < 0) {
      _c.selectRange(
        const CellRange(
          0,
          0,
          SheetGridData.maxRows - 1,
          SheetGridData.maxCols - 1,
        ),
      );
    } else if (hit.row < 0) {
      _c.selectRange(
        CellRange(0, hit.col, SheetGridData.maxRows - 1, hit.col),
        activeRow: 0,
        activeCol: hit.col,
      );
    } else if (hit.col < 0) {
      _c.selectRange(
        CellRange(hit.row, 0, hit.row, SheetGridData.maxCols - 1),
        activeRow: hit.row,
        activeCol: 0,
      );
    } else {
      final merge = _d.mergeAt(hit.row, hit.col);
      if (merge != null) {
        _c.selectRange(merge);
      } else {
        _c.select(hit.row, hit.col);
      }
    }
    widget.onSelectionChanged?.call();
  }

  void _onDoubleTap(TapDownDetails d) {
    final hit = _hit(d.localPosition);
    if (hit.row < 0 || hit.col < 0) return;
    final merge = _d.mergeAt(hit.row, hit.col);
    final row = merge?.r0 ?? hit.row, col = merge?.c0 ?? hit.col;
    _c.select(row, col);
    widget.onSelectionChanged?.call();
    widget.onEdit?.call(row, col);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _stopFling();
    _scaleStartZoom = _c.zoom;
    _lastFocal = d.localFocalPoint;
    final handle = _handleCenter();
    _mode = d.pointerCount == 1 && (d.localFocalPoint - handle).distance < 28
        ? _DragMode.handle
        : _DragMode.pan;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_mode == _DragMode.handle) {
      final hit = _hit(d.localFocalPoint);
      if (hit.row >= 0 && hit.col >= 0) {
        _c.select(hit.row, hit.col, extend: true);
        widget.onSelectionChanged?.call();
      }
      return;
    }
    if (d.pointerCount > 1 && d.scale != 1) {
      // Zoom about the focal point.
      final newZoom = (_scaleStartZoom * d.scale).clamp(0.4, 3.0);
      final focal = d.localFocalPoint;
      final fx = focal.dx - _hw - _frozenW + _c.scrollX;
      final fy = focal.dy - _hh - _frozenH + _c.scrollY;
      final ratio = newZoom / _c.zoom;
      _c.zoom = newZoom;
      _c.scrollX = fx * ratio - (focal.dx - _hw - _frozenW);
      _c.scrollY = fy * ratio - (focal.dy - _hh - _frozenH);
    }
    final delta = d.localFocalPoint - _lastFocal;
    _lastFocal = d.localFocalPoint;
    _c.scrollX -= delta.dx;
    _c.scrollY -= delta.dy;
    _clampScroll();
    _c.changed();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode == _DragMode.pan && d.pointerCount == 0) {
      final v = d.velocity.pixelsPerSecond;
      if (v.distance > 100) {
        _flingX = FrictionSimulation(0.12, _c.scrollX, -v.dx);
        _flingY = FrictionSimulation(0.12, _c.scrollY, -v.dy);
        _flingStart = Duration.zero;
        _ticker.start();
      }
    }
    _mode = _DragMode.none;
  }

  void _onLongPressStart(LongPressStartDetails d) {
    _stopFling();
    _longPressMoved = false;
    final hit = _hit(d.localPosition);
    if (hit.row < 0 || hit.col < 0) return;
    if (!_c.selection.contains(hit.row, hit.col)) {
      _c.select(hit.row, hit.col);
      widget.onSelectionChanged?.call();
    }
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (d.offsetFromOrigin.distance < 8 && !_longPressMoved) return;
    _longPressMoved = true;
    final hit = _hit(d.localPosition);
    if (hit.row < 0 || hit.col < 0) return;
    _c.select(hit.row, hit.col, extend: true);
    widget.onSelectionChanged?.call();
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    if (!_longPressMoved) widget.onMenu?.call(d.globalPosition);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        _c.viewport = Size(
          math.max(0, _size.width - _hw - _frozenW),
          math.max(0, _size.height - _hh - _frozenH),
        );
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _c.scrollX += e.scrollDelta.dx;
              _c.scrollY += e.scrollDelta.dy;
              _clampScroll();
              _c.changed();
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onDoubleTapDown: _onDoubleTap,
            onDoubleTap: () {},
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMove,
            onLongPressEnd: _onLongPressEnd,
            child: CustomPaint(
              size: _size,
              painter: _SheetPainter(
                data: _d,
                controller: _c,
                dark: widget.dark,
                textDirection: Directionality.of(context),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SheetPainter extends CustomPainter {
  _SheetPainter({
    required this.data,
    required this.controller,
    required this.dark,
    required this.textDirection,
  }) : super(repaint: controller);

  final SheetGridData data;
  final SheetGridController controller;
  final bool dark;
  final TextDirection textDirection;

  static final Map<String, TextPainter> _textCache = {};

  double get z => controller.zoom;

  Color get _background => dark ? const Color(0xFF1E1E26) : Colors.white;
  Color get _gridLine => dark ? const Color(0xFF3A3A46) : const Color(0xFFE1E1E1);
  Color get _headerBg => dark ? const Color(0xFF26263A) : const Color(0xFFF3F3F3);
  Color get _headerText => dark ? Colors.white70 : const Color(0xFF555555);
  Color get _defaultText => dark ? Colors.white : Colors.black;

  @override
  void paint(Canvas canvas, Size size) {
    const hw = SheetGrid.headerWidth, hh = SheetGrid.headerHeight;
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);
    final freeze = data.info.freeze;
    final fr = freeze?.row ?? 0, fc = freeze?.col ?? 0;
    final frozenW = data.cols.start(fc) * z, frozenH = data.rows.start(fr) * z;
    final sx = controller.scrollX, sy = controller.scrollY;

    // Visible scrolled rows and columns.
    final c0 = data.cols.indexAt((frozenW + sx) / z);
    final c1 = data.cols.indexAt((frozenW + sx + size.width - hw - frozenW) / z);
    final r0 = data.rows.indexAt((frozenH + sy) / z);
    final r1 = data.rows.indexAt((frozenH + sy + size.height - hh - frozenH) / z);
    // Text can spill in from cells left of the window.
    final spill0 = math.max(0, c0 - 8);
    data.ensure(r0, spill0, r1, c1);
    if (fr > 0) data.ensure(0, spill0, fr - 1, c1);
    if (fc > 0) data.ensure(r0, 0, r1, fc - 1);

    final mainClip = Rect.fromLTRB(hw + frozenW, hh + frozenH, size.width, size.height);
    _region(canvas, mainClip, r0, r1, c0, c1, hw - sx, hh - sy);
    if (fr > 0) {
      _region(canvas, Rect.fromLTRB(hw + frozenW, hh, size.width, hh + frozenH), 0, fr - 1, c0, c1, hw - sx, hh);
    }
    if (fc > 0) {
      _region(canvas, Rect.fromLTRB(hw, hh + frozenH, hw + frozenW, size.height), r0, r1, 0, fc - 1, hw, hh - sy);
    }
    if (fr > 0 && fc > 0) {
      _region(canvas, Rect.fromLTRB(hw, hh, hw + frozenW, hh + frozenH), 0, fr - 1, 0, fc - 1, hw, hh);
    }
    // Frozen dividers.
    final divider = Paint()
      ..color = dark ? Colors.white38 : const Color(0xFF9E9E9E)
      ..strokeWidth = 1.5;
    if (fc > 0) canvas.drawLine(Offset(hw + frozenW, hh), Offset(hw + frozenW, size.height), divider);
    if (fr > 0) canvas.drawLine(Offset(hw, hh + frozenH), Offset(size.width, hh + frozenH), divider);

    _headers(canvas, size, r0, r1, c0, c1, fr, fc);
  }

  double _x(int col, double dx) => data.cols.start(col) * z + dx;
  double _y(int row, double dy) => data.rows.start(row) * z + dy;

  void _region(Canvas canvas, Rect clip, int r0, int r1, int c0, int c1, double dx, double dy) {
    if (clip.width <= 0 || clip.height <= 0) return;
    canvas.save();
    canvas.clipRect(clip);
    final grid = Paint()
      ..color = _gridLine
      ..strokeWidth = 1;
    if (data.info.showGrid) {
      for (var c = c0; c <= c1 + 1; c++) {
        final x = _x(c, dx).roundToDouble() + 0.5;
        canvas.drawLine(Offset(x, clip.top), Offset(x, clip.bottom), grid);
      }
      for (var r = r0; r <= r1 + 1; r++) {
        final y = _y(r, dy).roundToDouble() + 0.5;
        canvas.drawLine(Offset(clip.left, y), Offset(clip.right, y), grid);
      }
    }
    // Merged areas hide their inner gridlines.
    final merges = data.merges.where((m) => m.r1 >= r0 && m.r0 <= r1 && m.c1 >= c0 && m.c0 <= c1).toList();
    for (final m in merges) {
      final rect = Rect.fromLTRB(_x(m.c0, dx) + 1, _y(m.r0, dy) + 1, _x(m.c1 + 1, dx), _y(m.r1 + 1, dy));
      canvas.drawRect(rect, Paint()..color = _background);
    }
    // Fills, then text, then borders.
    final spill0 = math.max(0, c0 - 8);
    final borders = <(Rect, CellStyleInfo)>[];
    for (var r = r0; r <= r1; r++) {
      if (data.rows.size(r) == 0) continue;
      for (var c = spill0; c <= c1; c++) {
        final cell = data.cell(r, c);
        if (cell == null) continue;
        final merge = data.mergeAt(r, c);
        if (merge != null && (merge.r0 != r || merge.c0 != c)) continue;
        final style = data.style(cell.style);
        final rect = merge == null
            ? Rect.fromLTRB(_x(c, dx), _y(r, dy), _x(c + 1, dx), _y(r + 1, dy))
            : Rect.fromLTRB(_x(merge.c0, dx), _y(merge.r0, dy), _x(merge.c1 + 1, dx), _y(merge.r1 + 1, dy));
        if (c >= c0 && style?.fill != null) {
          canvas.drawRect(rect.deflate(0.0), Paint()..color = Color(style!.fill!));
        }
        if (style != null && (style.left != null || style.right != null || style.top != null || style.bottom != null)) {
          borders.add((rect, style));
        }
      }
    }
    for (var r = r0; r <= r1; r++) {
      if (data.rows.size(r) == 0) continue;
      for (var c = spill0; c <= c1; c++) {
        final cell = data.cell(r, c);
        if (cell == null || cell.text.isEmpty) continue;
        final merge = data.mergeAt(r, c);
        if (merge != null && (merge.r0 != r || merge.c0 != c)) continue;
        _text(canvas, cell, r, c, merge, dx, dy, c1);
      }
    }
    for (final (rect, style) in borders) {
      _borders(canvas, rect, style);
    }
    _selection(canvas, dx, dy);
    canvas.restore();
  }

  String _fontFamily(String font) {
    final f = font.toLowerCase();
    if (f.contains('courier') || f.contains('consol') || f.contains('mono')) return 'monospace';
    if (f.contains('times') || f.contains('cambria') || f.contains('georgia') || f.contains('serif') && !f.contains('sans')) {
      return 'serif';
    }
    return 'sans-serif';
  }

  TextPainter _painter(GridCell cell, CellStyleInfo? style, String text, double? wrapWidth) {
    final key = '${cell.style}|${cell.color}|${cell.kind}|$z|${wrapWidth?.round()}|$text';
    final cached = _textCache[key];
    if (cached != null) return cached;
    if (_textCache.length > 3000) {
      for (final p in _textCache.values) {
        p.dispose();
      }
      _textCache.clear();
    }
    final color = cell.color != null
        ? Color(cell.color!)
        : (style?.color != null ? Color(style!.color!) : _defaultText);
    final ts = TextStyle(
      color: dark && style?.color == null && cell.color == null ? Colors.white : color,
      fontSize: (style?.size ?? 11) * 96 / 72 * z,
      fontWeight: style?.bold == true ? FontWeight.bold : FontWeight.normal,
      fontStyle: style?.italic == true ? FontStyle.italic : FontStyle.normal,
      fontFamily: _fontFamily(style?.font ?? ''),
      decoration: TextDecoration.combine([
        if (style?.underline != null && style!.underline != 'none') TextDecoration.underline,
        if (style?.strike == true) TextDecoration.lineThrough,
      ]),
      height: 1.15,
    );
    final p = TextPainter(
      text: TextSpan(text: text, style: ts),
      textDirection: textDirection,
      maxLines: wrapWidth == null ? 1 : null,
    )..layout(maxWidth: wrapWidth ?? double.infinity);
    _textCache[key] = p;
    return p;
  }

  void _text(Canvas canvas, GridCell cell, int r, int c, CellRange? merge, double dx, double dy, int c1) {
    final style = data.style(cell.style);
    final left = _x(merge?.c0 ?? c, dx);
    final right = _x((merge?.c1 ?? c) + 1, dx);
    final top = _y(merge?.r0 ?? r, dy);
    final bottom = _y((merge?.r1 ?? r) + 1, dy);
    final pad = 3 * z;
    final width = right - left - 2 * pad;
    if (width <= 0 || bottom - top <= 1) return;
    final wrap = style?.wrap == true;
    var h = style?.hAlign ?? '';
    if (h.isEmpty) {
      h = switch (cell.kind) {
        'n' => 'right',
        'b' || 'e' => 'center',
        _ => 'left',
      };
    }
    var text = cell.text;
    var p = _painter(cell, style, text, wrap ? width : null);
    // Numbers that do not fit show as #####, as in Excel.
    if (!wrap && cell.kind == 'n' && p.width > width) {
      final hashWidth = _painter(cell, style, '#', null).width;
      text = '#' * math.max(1, (width / math.max(1, hashWidth)).floor());
      p = _painter(cell, style, text, null);
    }
    // Text overflowing a left- or general-aligned cell spills into empty
    // neighbours to the right.
    var clipRight = right;
    if (!wrap && merge == null && p.width > width && cell.kind == 's' && h == 'left') {
      var cc = c + 1;
      while (cc <= c1 + 8 && clipRight < left + p.width + 2 * pad) {
        final next = data.cell(r, cc);
        if (next != null && next.text.isNotEmpty) break;
        if (data.mergeAt(r, cc) != null) break;
        clipRight = _x(cc + 1, dx);
        cc++;
      }
    }
    double x;
    switch (h) {
      case 'center' || 'centerContinuous':
        x = left + (right - left - p.width) / 2;
      case 'right':
        x = right - pad - p.width;
      default:
        x = left + pad + (style?.indent ?? 0) * 9 * z;
    }
    final v = style?.vAlign ?? '';
    double y;
    switch (v) {
      case 'top':
        y = top + 1;
      case 'center':
        y = top + (bottom - top - p.height) / 2;
      default:
        y = bottom - p.height - 1;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left + 1, top + 1, clipRight - 1, bottom));
    p.paint(canvas, Offset(x, y));
    canvas.restore();
  }

  void _borders(Canvas canvas, Rect rect, CellStyleInfo s) {
    void edge(CellEdge? e, Offset a, Offset b) {
      if (e == null) return;
      final width = switch (e.style) {
        'medium' || 'mediumDashed' || 'mediumDashDot' || 'mediumDashDotDot' => 2.0,
        'thick' || 'double' => 3.0,
        _ => 1.0,
      };
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = dark && e.color == 0xFF000000 ? Colors.white70 : Color(e.color)
          ..strokeWidth = width,
      );
    }

    edge(s.top, rect.topLeft, rect.topRight);
    edge(s.bottom, rect.bottomLeft, rect.bottomRight);
    edge(s.left, rect.topLeft, rect.bottomLeft);
    edge(s.right, rect.topRight, rect.bottomRight);
  }

  void _selection(Canvas canvas, double dx, double dy) {
    final s = controller.selection;
    final rect = Rect.fromLTRB(
      _x(s.c0, dx),
      _y(s.r0, dy),
      _x(math.min(s.c1 + 1, SheetGridData.maxCols), dx),
      _y(math.min(s.r1 + 1, SheetGridData.maxRows), dy),
    );
    if (s.rows > 1 || s.cols > 1) {
      canvas.drawRect(rect, Paint()..color = sheetSelectionColor.withValues(alpha: 0.12));
      final active = Rect.fromLTRB(
        _x(controller.activeCol, dx),
        _y(controller.activeRow, dy),
        _x(controller.activeCol + 1, dx),
        _y(controller.activeRow + 1, dy),
      );
      canvas.drawRect(active, Paint()..color = _background.withValues(alpha: 0.5));
    }
    canvas.drawRect(
      rect,
      Paint()
        ..color = sheetSelectionColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // The handle for extending the selection.
    canvas.drawCircle(rect.bottomRight, 6, Paint()..color = _background);
    canvas.drawCircle(rect.bottomRight, 4.5, Paint()..color = sheetSelectionColor);
  }

  void _headers(Canvas canvas, Size size, int r0, int r1, int c0, int c1, int fr, int fc) {
    const hw = SheetGrid.headerWidth, hh = SheetGrid.headerHeight;
    final bg = Paint()..color = _headerBg;
    final line = Paint()
      ..color = _gridLine
      ..strokeWidth = 1;
    final sel = controller.selection;
    final selPaint = Paint()..color = sheetSelectionColor.withValues(alpha: 0.18);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, hh), bg);
    canvas.drawRect(Rect.fromLTWH(0, 0, hw, size.height), bg);
    final textStyle = TextStyle(color: _headerText, fontSize: 11.5);

    void label(String text, Rect r, {bool selected = false}) {
      if (selected) canvas.drawRect(r, selPaint);
      final p = TextPainter(
        text: TextSpan(text: text, style: selected ? textStyle.copyWith(color: sheetSelectionColor, fontWeight: FontWeight.w700) : textStyle),
        textDirection: textDirection,
        maxLines: 1,
      )..layout();
      if (p.width < r.width + 4 && r.height > 6) {
        p.paint(canvas, Offset(r.left + (r.width - p.width) / 2, r.top + (r.height - p.height) / 2));
      }
      p.dispose();
    }

    final frozenW = data.cols.start(fc) * z, frozenH = data.rows.start(fr) * z;
    // Column headers.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(hw, 0, size.width, hh));
    void colHeader(int c, double dx) {
      final w = data.cols.size(c) * z;
      if (w <= 0) return;
      final x = data.cols.start(c) * z + dx;
      final r = Rect.fromLTWH(x, 0, w, hh);
      label(columnName(c), r, selected: c >= sel.c0 && c <= sel.c1);
      canvas.drawLine(Offset(x + w, 0), Offset(x + w, hh), line);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(hw + frozenW, 0, size.width, hh));
    for (var c = c0; c <= c1; c++) {
      colHeader(c, hw - controller.scrollX);
    }
    canvas.restore();
    for (var c = 0; c < fc; c++) {
      colHeader(c, hw);
    }
    canvas.restore();
    // Row headers.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, hh, hw, size.height));
    void rowHeader(int r, double dy) {
      final h = data.rows.size(r) * z;
      if (h <= 0) return;
      final y = data.rows.start(r) * z + dy;
      final rect = Rect.fromLTWH(0, y, hw, h);
      label('${r + 1}', rect, selected: r >= sel.r0 && r <= sel.r1);
      canvas.drawLine(Offset(0, y + h), Offset(hw, y + h), line);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, hh + frozenH, hw, size.height));
    for (var r = r0; r <= r1; r++) {
      rowHeader(r, hh - controller.scrollY);
    }
    canvas.restore();
    for (var r = 0; r < fr; r++) {
      rowHeader(r, hh);
    }
    canvas.restore();
    canvas.drawLine(const Offset(0, hh), Offset(size.width, hh), line);
    canvas.drawLine(const Offset(hw, 0), Offset(hw, size.height), line);
    canvas.drawRect(const Rect.fromLTWH(0, 0, hw, hh), bg);
  }

  @override
  bool shouldRepaint(covariant _SheetPainter old) => true;
}
