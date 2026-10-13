import 'package:flutter_sheet_core/flutter_sheet_core.dart';

/// Pixel sizes along one axis of the grid: a default size with exceptions
/// (custom widths or heights, hidden rows and columns).
class AxisMetrics {
  AxisMetrics(this.defaultSize, Map<int, double> custom, this.count)
    : _sizes = custom {
    _keys = custom.keys.toList()..sort();
    _prefix = List<double>.filled(_keys.length + 1, 0);
    for (var i = 0; i < _keys.length; i++) {
      _prefix[i + 1] = _prefix[i] + (custom[_keys[i]]! - defaultSize);
    }
  }

  final double defaultSize;
  final Map<int, double> _sizes;

  /// How many rows or columns the axis has.
  final int count;
  late final List<int> _keys;
  late final List<double> _prefix;

  int _lowerBound(int i) {
    var lo = 0, hi = _keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_keys[mid] < i) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Where row or column [i] starts.
  double start(int i) => i * defaultSize + _prefix[_lowerBound(i)];

  double size(int i) => _sizes[i] ?? defaultSize;

  double get total => start(count);

  /// The row or column at [position] (clamped to the axis).
  int indexAt(double position) {
    if (position <= 0) return 0;
    var lo = 0, hi = count - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (start(mid) <= position) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// Excel's units at 100% zoom: a column width in characters is 7 pixels a
/// character plus 5 of padding; row heights are points.
double columnPixels(double chars) => chars <= 0 ? 0 : (chars * 7 + 5).roundToDouble();
double rowPixels(double points) => points <= 0 ? 0 : points * 96 / 72;

/// The cells, styles and geometry of one sheet, fetched from the engine a
/// block at a time and cached.
class SheetGridData {
  SheetGridData(this.book, this.sheet, this.info) {
    reloadLayout();
  }

  final SheetBook book;
  final int sheet;
  SheetInfo info;

  static const int blockRows = 48;
  static const int blockCols = 16;
  static const int maxRows = 1048576;
  static const int maxCols = 16384;

  late AxisMetrics cols;
  late AxisMetrics rows;
  List<CellRange> merges = const [];

  final Map<int, Map<int, GridCell>> _cells = {};
  final Set<int> _loaded = {};
  final Map<int, CellStyleInfo> _styles = {};

  /// Bumped whenever cached content changes, so painters repaint.
  int generation = 0;

  void reloadLayout() {
    final layout = book.layout(sheet);
    merges = layout.merges;
    cols = AxisMetrics(
      columnPixels(info.defaultColWidth),
      {
        for (final e in layout.cols.entries)
          e.key: e.value.hidden ? 0 : columnPixels(e.value.width),
      },
      maxCols,
    );
    rows = AxisMetrics(
      rowPixels(info.defaultRowHeight),
      {
        for (final e in layout.rows.entries)
          e.key: e.value.hidden ? 0 : rowPixels(e.value.height),
      },
      maxRows,
    );
    generation++;
  }

  int _blockKey(int br, int bc) => br * 4096 + bc;

  void _ensureBlock(int row, int col) {
    final br = row ~/ blockRows, bc = col ~/ blockCols;
    final key = _blockKey(br, bc);
    if (_loaded.contains(key)) return;
    final r0 = br * blockRows, c0 = bc * blockCols;
    final window = book.window(
      sheet,
      r0,
      c0,
      r0 + blockRows - 1,
      c0 + blockCols - 1,
    );
    for (final cell in window.cells) {
      (_cells[cell.row] ??= {})[cell.col] = cell;
    }
    _loaded.add(key);
    final missing = {
      for (final c in window.cells)
        if (!_styles.containsKey(c.style)) c.style,
    };
    if (missing.isNotEmpty) _styles.addAll(book.styles(missing));
  }

  /// Load every block of a rectangle (before painting it).
  void ensure(int r0, int c0, int r1, int c1) {
    for (var br = r0 ~/ blockRows; br <= r1 ~/ blockRows; br++) {
      for (var bc = c0 ~/ blockCols; bc <= c1 ~/ blockCols; bc++) {
        _ensureBlock(br * blockRows, bc * blockCols);
      }
    }
  }

  GridCell? cell(int row, int col) {
    _ensureBlock(row, col);
    return _cells[row]?[col];
  }

  CellStyleInfo? style(int id) {
    final cached = _styles[id];
    if (cached != null) return cached;
    final fetched = book.styles([id])[id];
    if (fetched != null) _styles[id] = fetched;
    return fetched;
  }

  /// The merged range a cell belongs to.
  CellRange? mergeAt(int row, int col) {
    for (final m in merges) {
      if (m.contains(row, col)) return m;
    }
    return null;
  }

  /// Forget cached cells after an edit.
  void invalidate(SheetEditResult result) {
    if (result.all || result.structure) {
      clear(layout: true);
      return;
    }
    for (final c in result.changed) {
      if (c.sheet != sheet) continue;
      _loaded.remove(_blockKey(c.row ~/ blockRows, c.col ~/ blockCols));
      _cells[c.row]?.remove(c.col);
    }
    generation++;
  }

  void clear({bool layout = false}) {
    _cells.clear();
    _loaded.clear();
    _styles.clear();
    if (layout) reloadLayout();
    generation++;
  }
}
