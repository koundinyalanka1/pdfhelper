import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/export_fonts.dart';
import '../services/public_pdf_save_service.dart';
import '../services/recent_files_service.dart';
import '../utils/format_utils.dart';
import '../widgets/sheet/sheet_grid.dart';
import '../widgets/sheet/sheet_grid_data.dart';

/// Opens, edits and saves a spreadsheet (XLSX, XLSM, ODS, CSV, TSV) through
/// the spreadsheet engine (`flutter_sheet_core`).
///
/// The engine keeps everything it does not edit (charts, pivot tables,
/// macros, comments) and recalculates only the formulas an edit affects.
class SheetEditorScreen extends StatefulWidget {
  const SheetEditorScreen({
    super.key,
    required this.path,
    this.title,
    this.isNew = false,
  });

  /// The file. For a new workbook, where its first save goes.
  final String path;
  final String? title;

  /// Start a new, empty workbook instead of reading [path].
  final bool isNew;

  @override
  State<SheetEditorScreen> createState() => _SheetEditorScreenState();
}

enum _UnsavedChoice { save, discard }

/// The date order of the device's locale.
SheetDateOrder deviceDateOrder() {
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  return switch (locale.countryCode) {
    'US' || 'PH' || 'FM' || 'MH' || 'PW' => SheetDateOrder.mdy,
    'CN' || 'JP' || 'KR' || 'TW' || 'HU' || 'LT' || 'SE' => SheetDateOrder.ymd,
    _ => SheetDateOrder.dmy,
  };
}

class _SheetEditorScreenState extends State<SheetEditorScreen> {
  static const Color _accent = Color(0xFF21A366);

  SheetBook? _book;
  WorkbookInfo? _info;
  SheetGridData? _data;
  final _grid = SheetGridController();
  String? _error;
  bool _loading = true;
  bool _saving = false;
  late String _workingPath = widget.path;
  late bool _neverSaved = widget.isNew;

  final _formula = TextEditingController();
  final _formulaFocus = FocusNode();
  bool _editing = false;
  CellDetail? _detail;
  List<String> _functions = const [];
  String _status = '';

  bool _findOpen = false;
  final _findController = TextEditingController();
  final _replaceController = TextEditingController();
  List<({int sheet, int row, int col})> _found = const [];
  int _foundIndex = -1;

  /// Copied cells, to paste with formulas moved; and the text put on the
  /// clipboard, to recognise our own copy.
  ({int sheet, CellRange range, bool cut, String text})? _clip;

  AppColors _colors = AppColors(false);

  String get _name => widget.title ?? documentDisplayName(widget.path);
  int get _sheet => _info?.active ?? 0;

  @override
  void initState() {
    super.initState();
    _grid.addListener(_onGridChanged);
    _formulaFocus.addListener(() {
      if (_formulaFocus.hasFocus && !_editing) setState(() => _editing = true);
    });
    _load();
  }

  @override
  void dispose() {
    _book?.close();
    _grid.dispose();
    _formula.dispose();
    _formulaFocus.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  int get _utcOffset => DateTime.now().timeZoneOffset.inMinutes;

  Future<void> _load() async {
    try {
      final book = widget.isNew
          ? SheetCore.create(
              dateOrder: deviceDateOrder(),
              utcOffsetMinutes: _utcOffset,
            )
          : await SheetCore.open(
              widget.path,
              name: _name,
              dateOrder: deviceDateOrder(),
              utcOffsetMinutes: _utcOffset,
            );
      if (!mounted) {
        book.close();
        return;
      }
      _book = book;
      _functions = SheetCore.functionNames();
      _refreshInfo();
      _showSheet(_info!.active);
      setState(() => _loading = false);
      final warnings = _info!.warnings;
      if (warnings.isNotEmpty) _snack(warnings.first);
    } on SheetCoreException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.code == 'ENCRYPTED'
              ? 'This spreadsheet is protected with a password. Opening '
                    'password-protected spreadsheets is not supported yet.'
              : e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'The spreadsheet engine could not start: $e';
          _loading = false;
        });
      }
    }
  }

  void _refreshInfo() {
    final book = _book;
    if (book == null) return;
    _info = book.info();
  }

  void _showSheet(int index) {
    final book = _book!;
    final info = _info!;
    _data = SheetGridData(book, index, info.sheets[index]);
    _grid
      ..scrollX = 0
      ..scrollY = 0
      ..select(0, 0);
    _loadDetail();
  }

  bool get _dirty => _info?.modified ?? false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // -------------------------------------------------------------- selection

  void _onGridChanged() {
    // Repaints come through the controller; nothing else to do here.
  }

  void _onSelectionChanged() {
    if (_editing) _commit(move: false);
    _loadDetail();
  }

  void _loadDetail() {
    final book = _book;
    if (book == null) return;
    final detail = book.cell(_sheet, _grid.activeRow, _grid.activeCol);
    _detail = detail;
    if (!_editing) _formula.text = detail.edit;
    _updateStatus();
    if (mounted) setState(() {});
  }

  void _updateStatus() {
    final book = _book;
    final s = _grid.selection;
    if (book == null || (s.rows == 1 && s.cols == 1)) {
      _status = '';
      return;
    }
    final ref = _rangeRef(s);
    try {
      final count = book.evaluate(_sheet, 0, 0, 'COUNT($ref)');
      if (count == '0') {
        final all = book.evaluate(_sheet, 0, 0, 'COUNTA($ref)');
        _status = 'Count: $all';
        return;
      }
      final sum = book.evaluate(_sheet, 0, 0, 'SUM($ref)');
      final avg = book.evaluate(_sheet, 0, 0, 'AVERAGE($ref)');
      _status = 'Sum: $sum   Average: $avg   Count: $count';
    } on SheetCoreException {
      _status = '';
    }
  }

  /// A1 text for a selection, with whole rows and columns as `A:A`, `3:3`.
  String _rangeRef(CellRange s) {
    final wholeCols = s.r0 == 0 && s.r1 == SheetGridData.maxRows - 1;
    final wholeRows = s.c0 == 0 && s.c1 == SheetGridData.maxCols - 1;
    if (wholeCols && wholeRows) return 'A:XFD';
    if (wholeCols) return '${columnName(s.c0)}:${columnName(s.c1)}';
    if (wholeRows) return '${s.r0 + 1}:${s.r1 + 1}';
    return s.toString();
  }

  // ---------------------------------------------------------------- editing

  /// Apply an edit and refresh what it changed. Returns false when the
  /// engine refused it (the reason is shown).
  bool _apply(Map<String, Object?> op) {
    final book = _book;
    final data = _data;
    if (book == null || data == null) return false;
    try {
      final result = book.apply(op);
      _afterEdit(result);
      return true;
    } on SheetCoreException catch (e) {
      _snack(e.message);
      return false;
    }
  }

  Future<bool> _applyAsync(Map<String, Object?> op) async {
    final book = _book;
    if (book == null) return false;
    try {
      final result = await book.applyAsync(op);
      if (!mounted) return false;
      _afterEdit(result);
      return true;
    } on SheetCoreException catch (e) {
      _snack(e.message);
      return false;
    }
  }

  void _afterEdit(SheetEditResult result) {
    final previous = _info;
    _refreshInfo();
    final info = _info!;
    if (result.structure ||
        previous == null ||
        previous.sheets.length != info.sheets.length ||
        previous.active != info.active) {
      if (_sheet >= info.sheets.length) {
        _apply({'op': 'setActive', 'sheet': info.sheets.length - 1});
        _refreshInfo();
      }
      final keep = (_grid.selection, _grid.activeRow, _grid.activeCol, _grid.scrollX, _grid.scrollY);
      _data = SheetGridData(_book!, _sheet, _info!.sheets[_sheet]);
      _grid
        ..scrollX = keep.$4
        ..scrollY = keep.$5
        ..selectRange(keep.$1, activeRow: keep.$2, activeCol: keep.$3);
    } else {
      _data!.info = info.sheets[_sheet];
      _data!.invalidate(result);
      if (result.all) _data!.clear(layout: true);
    }
    if (result.circular.isNotEmpty) {
      final c = result.circular.first;
      _snack(
        'A formula refers to its own cell (${cellName(c.row, c.col)}), '
        'so it cannot be worked out. Its last value is kept.',
      );
    }
    _loadDetail();
    _grid.changed();
  }

  void _startEditing({String? replaceWith}) {
    final detail = _detail;
    if (detail?.array == true) {
      _snack("This cell is part of an array formula, which can't be changed here.");
      return;
    }
    setState(() => _editing = true);
    if (replaceWith != null) {
      _formula.text = replaceWith;
    }
    _formula.selection = TextSelection.collapsed(offset: _formula.text.length);
    _formulaFocus.requestFocus();
  }

  void _cancelEditing() {
    setState(() => _editing = false);
    _formula.text = _detail?.edit ?? '';
    _formulaFocus.unfocus();
  }

  /// Put the formula bar's text into the active cell; [move] goes down (or
  /// right) like Enter (or Tab).
  void _commit({bool move = true, bool right = false}) {
    if (!_editing) return;
    final text = _formula.text;
    if (text != (_detail?.edit ?? '')) {
      final ok = _apply({
        'op': 'set',
        'sheet': _sheet,
        'row': _grid.activeRow,
        'col': _grid.activeCol,
        'input': text,
      });
      if (!ok) return;
    }
    setState(() => _editing = false);
    if (move) {
      _grid.select(_grid.activeRow + (right ? 0 : 1), _grid.activeCol + (right ? 1 : 0));
      _ensureVisible();
      _loadDetail();
      _startEditing();
    } else {
      _formulaFocus.unfocus();
    }
  }

  void _ensureVisible() {
    final data = _data;
    if (data == null) return;
    final z = _grid.zoom;
    final freeze = data.info.freeze;
    final fx = data.cols.start(freeze?.col ?? 0) * z;
    final fy = data.rows.start(freeze?.row ?? 0) * z;
    final r = _grid.activeRow, c = _grid.activeCol;
    if (c >= (freeze?.col ?? 0)) {
      final left = data.cols.start(c) * z - fx;
      final right = data.cols.start(c + 1) * z - fx;
      if (left < _grid.scrollX) _grid.scrollX = left;
      if (right > _grid.scrollX + _grid.viewport.width) {
        _grid.scrollX = right - _grid.viewport.width;
      }
    }
    if (r >= (freeze?.row ?? 0)) {
      final top = data.rows.start(r) * z - fy;
      final bottom = data.rows.start(r + 1) * z - fy;
      if (top < _grid.scrollY) _grid.scrollY = top;
      if (bottom > _grid.scrollY + _grid.viewport.height) {
        _grid.scrollY = bottom - _grid.viewport.height;
      }
    }
    _grid.scrollX = math.max(0, _grid.scrollX);
    _grid.scrollY = math.max(0, _grid.scrollY);
    _grid.changed();
  }

  /// The function name being typed at the end of a formula, if any.
  String? get _typedFunction {
    final t = _formula.text;
    if (!_editing || !t.startsWith('=')) return null;
    final cursor = _formula.selection.baseOffset.clamp(0, t.length);
    final before = t.substring(0, cursor);
    final match = RegExp(r'([A-Za-z][A-Za-z0-9.]*)$').firstMatch(before);
    if (match == null) return null;
    final word = match.group(1)!;
    if (RegExp(r'^[A-Za-z]{1,3}[0-9]+$').hasMatch(word)) return null;
    return word;
  }

  void _insertFunction(String name) {
    final t = _formula.text;
    final cursor = _formula.selection.baseOffset.clamp(0, t.length);
    final typed = _typedFunction ?? '';
    final start = cursor - typed.length;
    final text = '${t.substring(0, start)}$name(${t.substring(cursor)}';
    _formula.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + name.length + 1),
    );
    setState(() {});
  }

  // ----------------------------------------------------------------- styles

  Map<String, Object?> _rangesOp(String op, [Map<String, Object?>? extra]) => {
    'op': op,
    'sheet': _sheet,
    'ranges': [_clipped(_grid.selection).toJson()],
    ...?extra,
  };

  /// A selection with whole rows or columns cut to the used part.
  CellRange _clipped(CellRange s) => s;

  CellStyleInfo? get _activeStyle {
    final data = _data;
    final detail = _detail;
    if (data == null || detail == null) return null;
    return data.style(detail.style);
  }

  void _format(Map<String, Object?> patch) {
    _commit(move: false);
    _apply(_rangesOp('format', {'patch': patch}));
  }

  Future<void> _pickColor({required bool fill}) async {
    const palette = [
      0x000000, 0x434343, 0x666666, 0x999999, 0xCCCCCC, 0xFFFFFF,
      0xC00000, 0xFF0000, 0xFFC000, 0xFFFF00, 0x92D050, 0x00B050,
      0x00B0F0, 0x0070C0, 0x002060, 0x7030A0, 0xF4B183, 0xFFE699,
      0xC5E0B4, 0xBDD7EE, 0xD9D2E9, 0xFCE4D6, 0xE2EFDA, 0xDDEBF7,
    ];
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return ColoredBox(
          color: colors.cardBackground,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fill ? 'Fill colour' : 'Text colour',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final c in palette)
                        InkWell(
                          onTap: () => Navigator.pop(ctx, c),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Color(0xFF000000 | c),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: colors.divider),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    icon: const Icon(Icons.format_color_reset_rounded),
                    label: Text(fill ? 'No fill' : 'Automatic'),
                    onPressed: () => Navigator.pop(ctx, -1),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (chosen == null) return;
    final hex = chosen < 0 ? '' : '#${chosen.toRadixString(16).padLeft(6, '0')}';
    _format({fill ? 'fill' : 'color': hex});
  }

  Future<void> _pickNumberFormat() async {
    final order = deviceDateOrder();
    final dateCode = switch (order) {
      SheetDateOrder.mdy => 'm/d/yyyy',
      SheetDateOrder.ymd => 'yyyy-mm-dd',
      SheetDateOrder.dmy => 'dd/mm/yyyy',
    };
    final formats = <(String, String, double)>[
      ('General', 'General', 1234.5),
      ('Number', '#,##0.00', 1234.5),
      ('Indian (lakh, crore)', '[>=10000000]##\\,##\\,##\\,##0.00;[>=100000]##\\,##\\,##0.00;##,##0.00', 1234567.5),
      ('Rupees', '[>=10000000]"₹"##\\,##\\,##\\,##0.00;[>=100000]"₹"##\\,##\\,##0.00;"₹"##,##0.00', 1234567.5),
      ('Currency', '"₹"#,##0.00', 1234.5),
      ('Whole number', '0', 1234.5),
      ('Percent', '0%', 0.125),
      ('Percent (2 places)', '0.00%', 0.125),
      ('Date', dateCode, 46308),
      ('Long date', 'd mmmm yyyy', 46308),
      ('Time', 'h:mm AM/PM', 0.75),
      ('Date and time', '$dateCode h:mm', 46308.75),
      ('Scientific', '0.00E+00', 1234.5),
      ('Text', '@', 1234.5),
    ];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return ColoredBox(
          color: colors.cardBackground,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text(
                      'Number format',
                      style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final (label, code, sample) in formats)
                    ListTile(
                      title: Text(label, style: TextStyle(color: colors.textPrimary)),
                      trailing: Text(
                        SheetCore.formatPreview(sample, code, dateOrder: order).text,
                        style: TextStyle(color: colors.textSecondary),
                      ),
                      onTap: () => Navigator.pop(ctx, code),
                    ),
                  ListTile(
                    leading: const Icon(Icons.exposure_plus_1_rounded),
                    title: Text('More decimal places', style: TextStyle(color: colors.textPrimary)),
                    onTap: () => Navigator.pop(ctx, '+'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.exposure_neg_1_rounded),
                    title: Text('Fewer decimal places', style: TextStyle(color: colors.textPrimary)),
                    onTap: () => Navigator.pop(ctx, '-'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (chosen == null) return;
    if (chosen == '+' || chosen == '-') {
      _format({'decimals': chosen == '+' ? 1 : -1});
    } else {
      _format({'numFmt': chosen});
    }
  }

  Future<void> _pickAlignment() async {
    final s = _activeStyle;
    final chosen = await _menu<String>('Alignment', [
      ('left', Icons.format_align_left_rounded, 'Left'),
      ('center', Icons.format_align_center_rounded, 'Centre'),
      ('right', Icons.format_align_right_rounded, 'Right'),
      ('general', Icons.format_textdirection_l_to_r_rounded, 'Automatic'),
      ('top', Icons.vertical_align_top_rounded, 'Top'),
      ('vcenter', Icons.vertical_align_center_rounded, 'Middle'),
      ('bottom', Icons.vertical_align_bottom_rounded, 'Bottom'),
      ('wrap', Icons.wrap_text_rounded, s?.wrap == true ? 'Stop wrapping text' : 'Wrap text'),
    ]);
    switch (chosen) {
      case 'left' || 'center' || 'right' || 'general':
        _format({'hAlign': chosen});
      case 'top' || 'bottom':
        _format({'vAlign': chosen});
      case 'vcenter':
        _format({'vAlign': 'center'});
      case 'wrap':
        _format({'wrap': !(s?.wrap ?? false)});
    }
  }

  Future<void> _pickBorders() async {
    final chosen = await _menu<String>('Borders', [
      ('all', Icons.border_all_rounded, 'All borders'),
      ('outline', Icons.border_outer_rounded, 'Outside borders'),
      ('bottom', Icons.border_bottom_rounded, 'Bottom border'),
      ('thick', Icons.border_bottom_rounded, 'Thick bottom border'),
      ('none', Icons.border_clear_rounded, 'No borders'),
    ]);
    if (chosen == null) return;
    _format({
      'border': {
        'kind': chosen == 'thick' ? 'bottom' : chosen,
        'style': chosen == 'thick' ? 'medium' : 'thin',
        'color': '#000000',
      },
    });
  }

  Future<T?> _menu<T>(String title, List<(T, IconData, String)> items) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return ColoredBox(
          color: colors.cardBackground,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text(title, style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600)),
                  ),
                  for (final (value, icon, label) in items)
                    ListTile(
                      leading: Icon(icon, color: colors.textSecondary),
                      title: Text(label, style: TextStyle(color: colors.textPrimary)),
                      onTap: () => Navigator.pop(ctx, value),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------- operations

  void _autoSum() {
    _commit(move: false);
    final data = _data;
    if (data == null) return;
    final s = _grid.selection;
    bool numeric(int r, int c) => data.cell(r, c)?.kind == 'n';
    if (s.rows == 1 && s.cols == 1) {
      final r = s.r0, c = s.c0;
      var top = r - 1;
      while (top >= 0 && numeric(top, c)) {
        top--;
      }
      String? range;
      if (top < r - 1) {
        range = '${cellName(top + 1, c)}:${cellName(r - 1, c)}';
      } else {
        var left = c - 1;
        while (left >= 0 && numeric(r, left)) {
          left--;
        }
        if (left < c - 1) range = '${cellName(r, left + 1)}:${cellName(r, c - 1)}';
      }
      _startEditing(replaceWith: '=SUM(${range ?? ''})');
      if (range == null) {
        _formula.selection = TextSelection.collapsed(offset: _formula.text.length - 1);
      }
      return;
    }
    // A range: totals under each column.
    final below = s.r1 + 1;
    final cells = <List<String>>[
      [for (var c = s.c0; c <= s.c1; c++) '=SUM(${cellName(s.r0, c)}:${cellName(s.r1, c)})'],
    ];
    _apply({'op': 'setBlock', 'sheet': _sheet, 'row': below, 'col': s.c0, 'rows': cells});
  }

  Future<void> _insertDelete() async {
    final s = _grid.selection;
    final rows = s.rows, cols = s.cols;
    final wholeRows = s.c0 == 0 && s.c1 == SheetGridData.maxCols - 1;
    final wholeCols = s.r0 == 0 && s.r1 == SheetGridData.maxRows - 1;
    final chosen = await _menu<String>('Rows and columns', [
      if (!wholeCols) ('rowAbove', Icons.table_rows_rounded, rows > 1 ? 'Insert $rows rows above' : 'Insert row above'),
      if (!wholeCols) ('rowBelow', Icons.table_rows_rounded, rows > 1 ? 'Insert $rows rows below' : 'Insert row below'),
      if (!wholeRows) ('colLeft', Icons.view_column_rounded, cols > 1 ? 'Insert $cols columns left' : 'Insert column left'),
      if (!wholeRows) ('colRight', Icons.view_column_rounded, cols > 1 ? 'Insert $cols columns right' : 'Insert column right'),
      if (!wholeCols) ('delRows', Icons.delete_sweep_rounded, rows > 1 ? 'Delete $rows rows' : 'Delete row'),
      if (!wholeRows) ('delCols', Icons.delete_sweep_rounded, cols > 1 ? 'Delete $cols columns' : 'Delete column'),
      if (!wholeCols) ('hideRows', Icons.visibility_off_rounded, 'Hide rows'),
      if (!wholeRows) ('hideCols', Icons.visibility_off_rounded, 'Hide columns'),
      ('unhide', Icons.visibility_rounded, 'Unhide rows and columns here'),
      ('width', Icons.width_normal_rounded, 'Column width'),
      ('height', Icons.height_rounded, 'Row height'),
    ]);
    switch (chosen) {
      case 'rowAbove':
        await _applyAsync({'op': 'insertRows', 'sheet': _sheet, 'at': s.r0, 'count': rows});
      case 'rowBelow':
        await _applyAsync({'op': 'insertRows', 'sheet': _sheet, 'at': s.r1 + 1, 'count': rows});
      case 'colLeft':
        await _applyAsync({'op': 'insertCols', 'sheet': _sheet, 'at': s.c0, 'count': cols});
      case 'colRight':
        await _applyAsync({'op': 'insertCols', 'sheet': _sheet, 'at': s.c1 + 1, 'count': cols});
      case 'delRows':
        await _applyAsync({'op': 'deleteRows', 'sheet': _sheet, 'at': s.r0, 'count': rows});
      case 'delCols':
        await _applyAsync({'op': 'deleteCols', 'sheet': _sheet, 'at': s.c0, 'count': cols});
      case 'hideRows':
        _apply({'op': 'hideRows', 'sheet': _sheet, 'first': s.r0, 'last': s.r1, 'hidden': true});
      case 'hideCols':
        _apply({'op': 'hideCols', 'sheet': _sheet, 'first': s.c0, 'last': s.c1, 'hidden': true});
      case 'unhide':
        _apply({'op': 'hideRows', 'sheet': _sheet, 'first': math.max(0, s.r0 - 1), 'last': math.min(SheetGridData.maxRows - 1, s.r1 + 1), 'hidden': false});
        _apply({'op': 'hideCols', 'sheet': _sheet, 'first': math.max(0, s.c0 - 1), 'last': math.min(SheetGridData.maxCols - 1, s.c1 + 1), 'hidden': false});
      case 'width':
        final current = _info!.sheets[_sheet].defaultColWidth;
        final w = await _askNumber('Column width', 'Width in characters', current);
        if (w != null) _apply({'op': 'colWidth', 'sheet': _sheet, 'first': s.c0, 'last': s.c1, 'width': w});
      case 'height':
        final current = _info!.sheets[_sheet].defaultRowHeight;
        final h = await _askNumber('Row height', 'Height in points', current);
        if (h != null) _apply({'op': 'rowHeight', 'sheet': _sheet, 'first': s.r0, 'last': s.r1, 'height': h});
    }
  }

  Future<double?> _askNumber(String title, String label, double initial) async {
    final controller = TextEditingController(text: initial.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), ''));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(controller.text)),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value < 0 || value > 409) return null;
    return value;
  }

  Future<void> _freeze() async {
    final freeze = _info!.sheets[_sheet].freeze;
    final chosen = await _menu<String>('Freeze', [
      ('row', Icons.border_top_rounded, 'Freeze top row'),
      ('col', Icons.border_left_rounded, 'Freeze first column'),
      ('here', Icons.grid_on_rounded, 'Freeze rows above and columns left of ${cellName(_grid.activeRow, _grid.activeCol)}'),
      if (freeze != null) ('none', Icons.grid_off_rounded, 'Unfreeze'),
    ]);
    final (row, col) = switch (chosen) {
      'row' => (1, 0),
      'col' => (0, 1),
      'here' => (_grid.activeRow, _grid.activeCol),
      'none' => (0, 0),
      _ => (-1, -1),
    };
    if (row < 0) return;
    _apply({'op': 'freeze', 'sheet': _sheet, 'row': row, 'col': col});
  }

  Future<void> _sort(bool ascending) async {
    _commit(move: false);
    final data = _data;
    if (data == null) return;
    var s = _grid.selection;
    final used = data.info.used;
    if (used == null) return;
    // One cell or a whole column: sort the table around it.
    final single = s.rows == 1 && s.cols == 1;
    final wholeCols = s.r0 == 0 && s.r1 == SheetGridData.maxRows - 1;
    if (single || wholeCols) s = CellRange(0, used.c0, used.r1, used.c1);
    final header = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ascending ? 'Sort A to Z' : 'Sort Z to A'),
        content: Text('Sort rows ${s.r0 + 1} to ${s.r1 + 1} by column ${columnName(_grid.activeCol)}. Does the first row hold headings?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No headings')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('First row is headings')),
        ],
      ),
    );
    if (header == null) return;
    await _applyAsync({
      'op': 'sort',
      'sheet': _sheet,
      'range': s.toJson(),
      'keys': [
        {'col': _grid.activeCol, 'asc': ascending},
      ],
      'header': header,
    });
  }

  Future<void> _clear() async {
    final chosen = await _menu<String>('Clear', [
      ('contents', Icons.backspace_rounded, 'Clear contents'),
      ('formats', Icons.format_clear_rounded, 'Clear formatting'),
      ('all', Icons.delete_outline_rounded, 'Clear everything'),
    ]);
    if (chosen == null) return;
    _apply(_rangesOp('clear', {'what': chosen}));
  }

  String _selectionText() {
    final data = _data!;
    var s = _grid.selection;
    final used = data.info.used;
    if (used != null) {
      s = CellRange(s.r0, s.c0, math.min(s.r1, used.r1), math.min(s.c1, used.c1));
    }
    final lines = <String>[];
    for (var r = s.r0; r <= s.r1 && r - s.r0 < 10000; r++) {
      final fields = <String>[];
      for (var c = s.c0; c <= s.c1 && c - s.c0 < 500; c++) {
        final text = data.cell(r, c)?.text ?? '';
        fields.add(text.contains(RegExp('[\t\n"]')) ? '"${text.replaceAll('"', '""')}"' : text);
      }
      lines.add(fields.join('\t'));
    }
    return lines.join('\n');
  }

  Future<void> _copy({bool cut = false}) async {
    _commit(move: false);
    final text = _selectionText();
    await Clipboard.setData(ClipboardData(text: text));
    _clip = (sheet: _sheet, range: _grid.selection, cut: cut, text: text);
    _snack(cut ? 'Cut. Choose where to paste.' : 'Copied');
  }

  Future<void> _paste({String what = 'all'}) async {
    _commit(move: false);
    final clip = _clip;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (clip != null && (text == null || text == clip.text)) {
      final ok = await _applyAsync({
        'op': 'paste',
        'fromSheet': clip.sheet,
        'from': clip.range.toJson(),
        'toSheet': _sheet,
        'row': _grid.activeRow,
        'col': _grid.activeCol,
        'what': what,
        'cut': clip.cut,
      });
      if (ok && clip.cut) _clip = null;
      return;
    }
    if (text == null || text.isEmpty) return;
    final rows = _parseClipboard(text);
    await _applyAsync({'op': 'setBlock', 'sheet': _sheet, 'row': _grid.activeRow, 'col': _grid.activeCol, 'rows': rows});
  }

  /// Tab- (or comma-) separated text from another app, as rows of entries.
  List<List<String>> _parseClipboard(String text) {
    final delimiter = text.contains('\t') ? '\t' : null;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return [
      for (final line in lines.take(100000)) delimiter == null ? [line] : line.split(delimiter),
    ];
  }

  Future<void> _showCellMenu(Offset position) async {
    final chosen = await _menu<String>(_rangeRef(_grid.selection), [
      ('cut', Icons.content_cut_rounded, 'Cut'),
      ('copy', Icons.content_copy_rounded, 'Copy'),
      ('paste', Icons.content_paste_rounded, 'Paste'),
      ('pasteValues', Icons.content_paste_go_rounded, 'Paste values only'),
      ('clear', Icons.backspace_rounded, 'Clear'),
      ('rows', Icons.table_rows_rounded, 'Insert or delete…'),
      ('fillDown', Icons.south_rounded, 'Fill down'),
      ('fillRight', Icons.east_rounded, 'Fill right'),
      ('merge', Icons.call_merge_rounded, 'Merge or unmerge'),
    ]);
    switch (chosen) {
      case 'cut':
        await _copy(cut: true);
      case 'copy':
        await _copy();
      case 'paste':
        await _paste();
      case 'pasteValues':
        await _paste(what: 'values');
      case 'clear':
        await _clear();
      case 'rows':
        await _insertDelete();
      case 'fillDown':
        _apply({'op': 'fill', 'sheet': _sheet, 'range': _grid.selection.toJson(), 'down': true});
      case 'fillRight':
        _apply({'op': 'fill', 'sheet': _sheet, 'range': _grid.selection.toJson(), 'down': false});
      case 'merge':
        _toggleMerge();
    }
  }

  void _toggleMerge() {
    final s = _grid.selection;
    final merged = _data?.mergeAt(s.r0, s.c0);
    if (merged != null && (s.rows == 1 && s.cols == 1 || merged == s)) {
      _apply({'op': 'unmerge', 'sheet': _sheet, 'range': merged.toJson()});
    } else if (s.rows > 1 || s.cols > 1) {
      _apply({'op': 'merge', 'sheet': _sheet, 'range': s.toJson()});
    }
  }

  Future<void> _goTo() async {
    final controller = TextEditingController(text: cellName(_grid.activeRow, _grid.activeCol));
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to cell'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'For example B12'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Go')),
        ],
      ),
    );
    controller.dispose();
    if (target == null) return;
    final m = RegExp(r'^\$?([A-Za-z]{1,3})\$?([0-9]+)$').firstMatch(target.trim());
    if (m == null) {
      _snack('"$target" is not a cell name.');
      return;
    }
    var col = 0;
    for (final ch in m.group(1)!.toUpperCase().codeUnits) {
      col = col * 26 + (ch - 64);
    }
    final row = int.parse(m.group(2)!) - 1;
    _grid.select(row, col - 1);
    _ensureVisible();
    _loadDetail();
  }

  // ------------------------------------------------------------------ find

  void _runFind() {
    final book = _book;
    final q = _findController.text;
    if (book == null || q.isEmpty) {
      setState(() {
        _found = const [];
        _foundIndex = -1;
      });
      return;
    }
    final found = book.find(q, limit: 5000);
    setState(() {
      _found = found;
      _foundIndex = found.isEmpty ? -1 : 0;
    });
    if (found.isNotEmpty) _showFound();
  }

  void _showFound() {
    final f = _found[_foundIndex];
    if (f.sheet != _sheet) {
      _apply({'op': 'setActive', 'sheet': f.sheet});
      _refreshInfo();
      _showSheet(f.sheet);
    }
    _grid.select(f.row, f.col);
    _ensureVisible();
    _loadDetail();
  }

  void _stepFound(int delta) {
    if (_found.isEmpty) return;
    setState(() => _foundIndex = (_foundIndex + delta) % _found.length);
    _showFound();
  }

  void _replaceAll() {
    final q = _findController.text;
    if (q.isEmpty) return;
    _apply({'op': 'replace', 'sheet': null, 'find': q, 'replace': _replaceController.text});
    _runFind();
  }

  // ----------------------------------------------------------------- sheets

  Future<void> _switchSheet(int index) async {
    _commit(move: false);
    if (index == _sheet) return;
    _apply({'op': 'setActive', 'sheet': index});
    _refreshInfo();
    setState(() => _showSheet(index));
  }

  Future<void> _sheetMenu(int index) async {
    final info = _info!;
    final sheet = info.sheets[index];
    final hidden = info.sheets.where((s) => !s.visible).toList();
    final chosen = await _menu<String>(sheet.name, [
      ('rename', Icons.drive_file_rename_outline_rounded, 'Rename'),
      ('duplicate', Icons.copy_all_rounded, 'Duplicate'),
      if (index > 0) ('left', Icons.chevron_left_rounded, 'Move left'),
      if (index < info.sheets.length - 1) ('right', Icons.chevron_right_rounded, 'Move right'),
      ('hide', Icons.visibility_off_rounded, 'Hide'),
      if (hidden.isNotEmpty) ('unhide', Icons.visibility_rounded, 'Unhide a sheet…'),
      ('delete', Icons.delete_outline_rounded, 'Delete'),
    ]);
    if (!mounted) return;
    switch (chosen) {
      case 'rename':
        final name = await _askText('Rename sheet', sheet.name);
        if (name != null && name != sheet.name) _apply({'op': 'renameSheet', 'sheet': index, 'name': name});
      case 'duplicate':
        _apply({'op': 'duplicateSheet', 'sheet': index});
      case 'left':
        _apply({'op': 'moveSheet', 'sheet': index, 'to': index - 1});
      case 'right':
        _apply({'op': 'moveSheet', 'sheet': index, 'to': index + 1});
      case 'hide':
        _apply({'op': 'hideSheet', 'sheet': index, 'hidden': true});
      case 'unhide':
        final pick = await _menu<int>('Unhide', [
          for (var i = 0; i < info.sheets.length; i++)
            if (!info.sheets[i].visible) (i, Icons.visibility_rounded, info.sheets[i].name),
        ]);
        if (pick != null) _apply({'op': 'hideSheet', 'sheet': pick, 'hidden': false});
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete "${sheet.name}"?'),
            content: const Text('Formulas on other sheets that use it will show #REF!. You can undo this.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) _apply({'op': 'deleteSheet', 'sheet': index});
    }
    if (mounted) setState(() {});
  }

  Future<String?> _askText(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    return value == null || value.isEmpty ? null : value;
  }

  void _undo() {
    _commit(move: false);
    final r = _book?.undo();
    if (r != null) _afterEdit(r);
  }

  void _redo() {
    _commit(move: false);
    final r = _book?.redo();
    if (r != null) _afterEdit(r);
  }

  // ----------------------------------------------------------------- saving

  SheetFormat get _saveFormat => SheetFormat.forName(_workingPath) ?? SheetFormat.xlsx;

  Future<bool> _save() async {
    final book = _book;
    if (book == null || _saving) return false;
    _commit(move: false);
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() => _saving = true);
    try {
      final target = _neverSaved ? _workingPath : await DocumentSaveService.workingPathFor(_workingPath);
      final warnings = await book.save(target, _saveFormat);
      _neverSaved = false;
      if (target != _workingPath) _workingPath = target;
      await RecentFilesService.markOpened(target);
      _refreshInfo();
      final message = await DocumentSaveService.afterSave(workingPath: target, location: location);
      _snack(warnings.isEmpty ? message : '$message. ${warnings.join(' ')}');
      return true;
    } on SheetCoreException catch (e) {
      _snack('Could not save: ${e.message}');
      return false;
    } on PublicPdfSaveException catch (e) {
      _snack(e.message);
      return true;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Write a copy as [code]: a workbook format, or `pdf`.
  Future<List<String>> _writeAs(SheetBook book, String file, String code) async {
    if (code == 'pdf') {
      await book.exportPdf(
        file,
        fontDirs: exportFontDirs(),
        title: DocKind.titleOf(documentDisplayName(_workingPath)),
      );
      return const [];
    }
    return book.writeCopy(file, SheetFormat.forName('x.$code') ?? SheetFormat.xlsx);
  }

  Future<void> _share({String? as}) async {
    final book = _book;
    if (book == null) return;
    _commit(move: false);
    final code = as ?? _saveFormat.code;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final file = '${dir.path}/$title.$code';
      final warnings = await _writeAs(book, file, code);
      if (warnings.isNotEmpty) _snack(warnings.join(' '));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file, mimeType: DocKind.mimeTypeOf(file))]),
      );
    } catch (e) {
      _snack('Could not share: $e');
    }
  }

  Future<void> _saveCopyAs() async {
    final code = await _menu<String>('Save a copy as', [
      ('xlsx', Icons.table_chart_rounded, 'Excel workbook (.xlsx)'),
      ('ods', Icons.table_chart_outlined, 'OpenDocument spreadsheet (.ods)'),
      ('pdf', Icons.picture_as_pdf_outlined, 'PDF, every sheet (.pdf)'),
      ('csv', Icons.notes_rounded, 'CSV, this sheet only (.csv)'),
    ]);
    if (code == null || !mounted) return;
    final location = context.read<ThemeProvider>().saveLocation;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/export');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final file = '${dir.path}/$title.$code';
      final warnings = await _writeAs(_book!, file, code);
      await PublicPdfSaveService.save(
        sourcePath: file,
        displayName: '$title.$code',
        location: location,
        mimeType: DocKind.mimeTypeOf(file),
      );
      _snack(['Saved a copy to $location/DocHelper.', ...warnings].join(' '));
    } catch (e) {
      _snack('Could not save a copy: $e');
    }
  }

  Future<void> _onWillLeave() async {
    final choice = await showDialog<_UnsavedChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save your changes?'),
        content: Text('$_name has changes that are not saved yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(ctx, _UnsavedChoice.discard), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, _UnsavedChoice.save), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == _UnsavedChoice.save && !await _save()) return;
    if (!mounted) return;
    _info = null;
    setState(() {});
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      canPop: !_dirty && !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editing) {
          _cancelEditing();
          return;
        }
        _onWillLeave();
      },
      child: Scaffold(
        backgroundColor: _colors.background,
        appBar: _buildAppBar(),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final info = _info;
    final subtitle = info == null
        ? null
        : [
            (info.format ?? _saveFormat).code.toUpperCase(),
            if (_dirty) 'Edited',
          ].join(' · ');
    return AppBar(
      backgroundColor: _colors.cardBackground,
      foregroundColor: _colors.textPrimary,
      elevation: 0,
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _colors.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) Text(subtitle, style: TextStyle(color: _colors.textTertiary, fontSize: 12)),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Undo',
          icon: const Icon(Icons.undo_rounded),
          onPressed: info?.canUndo == true ? _undo : null,
        ),
        IconButton(
          tooltip: 'Redo',
          icon: const Icon(Icons.redo_rounded),
          onPressed: info?.canRedo == true ? _redo : null,
        ),
        TextButton(
          onPressed: (_dirty || _neverSaved) && !_saving && _book != null ? _save : null,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          enabled: _book != null,
          onSelected: (value) => switch (value) {
            'find' => setState(() => _findOpen = !_findOpen),
            'goto' => _goTo(),
            'share' => _share(),
            'shareCsv' => _share(as: 'csv'),
            'sharePdf' => _share(as: 'pdf'),
            'copyAs' => _saveCopyAs(),
            'recalc' => _recalc(),
            'zoomReset' => setState(() {
              _grid.zoom = 1;
              _grid.changed();
            }),
            _ => null,
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'find', child: Text('Find and replace')),
            PopupMenuItem(value: 'goto', child: Text('Go to cell')),
            PopupMenuItem(value: 'share', child: Text('Share')),
            PopupMenuItem(value: 'sharePdf', child: Text('Share as PDF')),
            PopupMenuItem(value: 'shareCsv', child: Text('Share this sheet as CSV')),
            PopupMenuItem(value: 'copyAs', child: Text('Save a copy as…')),
            PopupMenuItem(value: 'recalc', child: Text('Recalculate')),
            PopupMenuItem(value: 'zoomReset', child: Text('Zoom to 100%')),
          ],
        ),
      ],
    );
  }

  void _recalc() {
    final r = _book?.recalculate();
    if (r != null) {
      _afterEdit(r);
      _snack('Recalculated');
    }
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _accent));
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: _colors.textTertiary),
              const SizedBox(height: 12),
              Text(
                'Could not open $_name',
                style: TextStyle(color: _colors.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(error, textAlign: TextAlign.center, style: TextStyle(color: _colors.textSecondary)),
            ],
          ),
        ),
      );
    }
    final data = _data!;
    final chart = data.info.chart;
    return Column(
      children: [
        if (_findOpen) _buildFindBar(),
        _buildFormulaBar(),
        if (_editing && _typedFunction != null) _buildFunctionHints(),
        Expanded(
          child: chart
              ? Center(
                  child: Text(
                    'This is a chart sheet. Its chart is kept but cannot be shown yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _colors.textSecondary),
                  ),
                )
              : SheetGrid(
                  key: ValueKey(data),
                  data: data,
                  controller: _grid,
                  dark: _colors.isDark,
                  onEdit: (_, _) => _startEditing(),
                  onMenu: _showCellMenu,
                  onSelectionChanged: _onSelectionChanged,
                ),
        ),
        if (_status.isNotEmpty)
          Container(
            width: double.infinity,
            color: _colors.cardBackground,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(_status, style: TextStyle(color: _colors.textSecondary, fontSize: 12)),
          ),
        if (!_editing) _buildToolbar(),
        _buildTabs(),
      ],
    );
  }

  Widget _buildFormulaBar() {
    final s = _grid.selection;
    final name = s.rows == 1 && s.cols == 1 ? cellName(s.r0, s.c0) : _rangeRef(s);
    return Material(
      color: _colors.cardBackground,
      elevation: 1,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            InkWell(
              onTap: _goTo,
              child: Container(
                width: 76,
                alignment: Alignment.center,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _colors.textPrimary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            Container(width: 1, height: 28, color: _colors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('fx', style: TextStyle(color: _colors.textTertiary, fontStyle: FontStyle.italic)),
            ),
            Expanded(
              child: TextField(
                controller: _formula,
                focusNode: _formulaFocus,
                style: TextStyle(color: _colors.textPrimary, fontSize: 15),
                cursorColor: _accent,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _commit(),
                decoration: InputDecoration.collapsed(
                  hintText: 'Type a value or =formula',
                  hintStyle: TextStyle(color: _colors.textTertiary),
                ),
              ),
            ),
            if (_editing) ...[
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close_rounded),
                onPressed: _cancelEditing,
              ),
              IconButton(
                tooltip: 'Next column',
                icon: const Icon(Icons.keyboard_tab_rounded),
                onPressed: () => _commit(right: true),
              ),
              IconButton(
                tooltip: 'Enter',
                icon: const Icon(Icons.check_rounded, color: _accent),
                onPressed: () => _commit(move: false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFunctionHints() {
    final typed = _typedFunction!.toUpperCase();
    final matches = _functions.where((f) => f.startsWith(typed)).take(30).toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 44,
      color: _colors.cardBackground,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final f in matches)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ActionChip(label: Text(f), onPressed: () => _insertFunction(f)),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final s = _activeStyle;
    Widget toggle(IconData icon, String tip, bool on, VoidCallback onTap) => IconButton(
      tooltip: tip,
      isSelected: on,
      icon: Icon(icon),
      selectedIcon: Icon(icon, color: _accent),
      style: on ? IconButton.styleFrom(backgroundColor: _accent.withValues(alpha: 0.12)) : null,
      onPressed: onTap,
    );
    Widget button(IconData icon, String tip, VoidCallback onTap) =>
        IconButton(tooltip: tip, icon: Icon(icon), onPressed: onTap);
    return Material(
      color: _colors.cardBackground,
      elevation: 3,
      child: SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            button(Icons.functions_rounded, 'AutoSum', _autoSum),
            toggle(Icons.format_bold_rounded, 'Bold', s?.bold ?? false, () => _format({'bold': !(s?.bold ?? false)})),
            toggle(Icons.format_italic_rounded, 'Italic', s?.italic ?? false, () => _format({'italic': !(s?.italic ?? false)})),
            toggle(
              Icons.format_underlined_rounded,
              'Underline',
              (s?.underline ?? 'none') != 'none',
              () => _format({'underline': (s?.underline ?? 'none') != 'none' ? 'none' : 'single'}),
            ),
            button(Icons.format_color_fill_rounded, 'Fill colour', () => _pickColor(fill: true)),
            button(Icons.format_color_text_rounded, 'Text colour', () => _pickColor(fill: false)),
            button(Icons.format_align_left_rounded, 'Alignment', _pickAlignment),
            button(Icons.onetwothree_rounded, 'Number format', _pickNumberFormat),
            button(Icons.border_all_rounded, 'Borders', _pickBorders),
            button(Icons.call_merge_rounded, 'Merge cells', _toggleMerge),
            button(Icons.table_rows_rounded, 'Rows and columns', _insertDelete),
            button(Icons.arrow_downward_rounded, 'Sort A to Z', () => _sort(true)),
            button(Icons.arrow_upward_rounded, 'Sort Z to A', () => _sort(false)),
            button(Icons.ac_unit_rounded, 'Freeze', _freeze),
            button(Icons.content_copy_rounded, 'Copy', _copy),
            button(Icons.content_paste_rounded, 'Paste', _paste),
            button(Icons.backspace_outlined, 'Clear', _clear),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    final info = _info!;
    return Material(
      color: _colors.background,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Add sheet',
              icon: const Icon(Icons.add_rounded),
              onPressed: () {
                _apply({'op': 'addSheet', 'name': null, 'at': null});
                setState(() {});
              },
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < info.sheets.length; i++)
                    if (info.sheets[i].visible)
                      GestureDetector(
                        onTap: () => _switchSheet(i),
                        onLongPress: () => _sheetMenu(i),
                        child: Container(
                          margin: const EdgeInsets.only(right: 2, top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: i == _sheet ? _colors.cardBackground : Colors.transparent,
                            border: Border(
                              bottom: BorderSide(color: i == _sheet ? _accent : Colors.transparent, width: 3),
                            ),
                          ),
                          child: Text(
                            info.sheets[i].name,
                            style: TextStyle(
                              color: i == _sheet ? _accent : _colors.textSecondary,
                              fontWeight: i == _sheet ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFindBar() {
    final count = _found.isEmpty
        ? (_findController.text.isEmpty ? '' : 'No matches')
        : '${_foundIndex + 1} of ${_found.length}';
    InputDecoration field(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Material(
      color: _colors.cardBackground,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    decoration: field('Find'),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _runFind(),
                  ),
                ),
                if (count.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(count, style: TextStyle(color: _colors.textTertiary, fontSize: 12)),
                  ),
                IconButton(icon: const Icon(Icons.search_rounded), onPressed: _runFind),
                IconButton(icon: const Icon(Icons.keyboard_arrow_up_rounded), onPressed: () => _stepFound(-1)),
                IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: () => _stepFound(1)),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _findOpen = false),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: TextField(controller: _replaceController, decoration: field('Replace with'))),
                TextButton(onPressed: _replaceAll, child: const Text('Replace all')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
