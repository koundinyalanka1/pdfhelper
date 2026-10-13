import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_text_selection_service.dart';
import '../utils/error_logger.dart';
import '../widgets/pdf_edit/edit_items.dart';
import '../widgets/pdf_edit/signature_pad.dart';

/// Fill in, sign and mark up a PDF.
///
/// Pages are shown as they are in the file, with what the user adds drawn
/// over them; nothing is written until Save. Saving appends the changes to
/// the file (see `PdfCore.applyEdits`), in place when the app can write it,
/// otherwise to a copy that is also published (see [DocumentSaveService]).
/// The screen pops with the path it saved to.
class PdfEditScreen extends StatefulWidget {
  const PdfEditScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
    this.tool = PdfEditTool.browse,
    this.title = 'Fill & sign',
  });

  final String pdfPath;
  final String password;

  /// The tool chosen when the screen opens.
  final PdfEditTool tool;
  final String title;

  @override
  State<PdfEditScreen> createState() => _PdfEditScreenState();
}

/// What undo goes back to.
class _Snapshot {
  _Snapshot(this.items, this.values, this.removals);

  final List<EditItem> items;
  final Map<String, PdfFieldValue> values;
  final Map<String, PdfAnnotationRemoval> removals;
}

const _palette = <Color>[
  Color(0xFFFFEB3B),
  Color(0xFF66BB6A),
  Color(0xFF42A5F5),
  Color(0xFFEC407A),
  Color(0xFFE53935),
  Color(0xFFFB8C00),
  Color(0xFF0D47A1),
  Color(0xFF000000),
];

class _PdfEditScreenState extends State<PdfEditScreen> {
  static const Color _accent = Color(0xFFE94560);

  AppColors _colors = AppColors(false);
  bool _loading = true;
  String? _error;
  bool _pinned = false;
  int _pageCount = 0;

  /// Displayed page sizes in points, by 1-based page.
  final Map<int, Size> _sizes = {};
  PdfForm _form = const PdfForm();

  final Map<String, PdfFieldValue> _values = {};
  List<EditItem> _items = [];
  final Map<String, PdfAnnotationRemoval> _removals = {};
  final Map<int, List<PdfAnnotationInfo>> _existing = {};
  final Map<int, PdfPageTextLayout?> _layouts = {};
  final List<_Snapshot> _undo = [];

  late PdfEditTool _tool = widget.tool;
  final Map<PdfEditTool, Color> _toolColors = {
    PdfEditTool.highlight: const Color(0xFFFFEB3B),
    PdfEditTool.underline: const Color(0xFF42A5F5),
    PdfEditTool.strikeOut: const Color(0xFFE53935),
    PdfEditTool.pen: const Color(0xFF0D47A1),
    PdfEditTool.text: const Color(0xFF000000),
    PdfEditTool.note: const Color(0xFFFFC107),
    PdfEditTool.rectangle: const Color(0xFFE53935),
    PdfEditTool.ellipse: const Color(0xFFE53935),
    PdfEditTool.arrow: const Color(0xFFE53935),
    PdfEditTool.signature: const Color(0xFF0D47A1),
  };
  double _penWidth = 2;

  EditItem? _selected;
  EditItem? _draft;
  Offset? _dragFrom;
  bool _moving = false;
  bool _resizing = false;
  bool _saving = false;

  /// Draw the edits into the pages for good when saving.
  bool _flatten = false;

  bool get _dirty =>
      _items.isNotEmpty || _values.isNotEmpty || _removals.isNotEmpty;

  Color get _color => _toolColors[_tool] ?? Colors.black;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_pinned) {
      unawaited(
        PdfRaster.closeDocument(widget.pdfPath, password: widget.password),
      );
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final count = await PdfRaster.openDocument(
        widget.pdfPath,
        password: widget.password,
      );
      _pinned = true;
      final path = widget.pdfPath;
      final password = widget.password;
      final sizes = await _measure(path, password, count);
      PdfForm form;
      try {
        form = await PdfCore.formFieldsAsync(path, password: password);
      } catch (e) {
        logError('PdfEdit.formFields', e);
        form = const PdfForm();
      }
      if (!mounted) return;
      setState(() {
        _pageCount = count;
        for (var i = 0; i < sizes.length; i++) {
          _sizes[i + 1] = Size(sizes[i].width, sizes[i].height);
        }
        _form = form;
        _loading = false;
        if (count == 0) _error = 'This PDF has no pages.';
      });
      if (_tool.marksText) _preloadText();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = PdfCoreService.describeError(e);
      });
    }
  }

  /// Every page's displayed size, in one isolate. Static, so the closure
  /// sent to the isolate holds nothing of the screen.
  static Future<List<PdfPageSize>> _measure(
    String path,
    String password,
    int count,
  ) => Isolate.run(
    () => [
      for (var i = 0; i < count; i++)
        PdfCore.pageSize(path, i, password: password),
    ],
  );

  Future<void> _loadExisting(int page) async {
    if (_existing.containsKey(page)) return;
    _existing[page] = const [];
    try {
      final list = await PdfCore.annotationsAsync(
        widget.pdfPath,
        page,
        password: widget.password,
      );
      if (mounted) setState(() => _existing[page] = list);
    } catch (e) {
      logError('PdfEdit.annotations', e);
    }
  }

  Future<void> _loadText(int page) async {
    if (_layouts.containsKey(page)) return;
    _layouts[page] = null;
    try {
      final layout = await PdfTextSelectionService.load(
        widget.pdfPath,
        page - 1,
        password: widget.password,
      );
      if (mounted) setState(() => _layouts[page] = layout);
    } catch (e) {
      logError('PdfEdit.text', e);
    }
  }

  void _preloadText() {
    for (var page = 1; page <= _pageCount && page <= 40; page++) {
      unawaited(_loadText(page));
    }
  }

  // -------------------------------------------------------------- history

  void _remember() {
    _undo.add(_Snapshot(List.of(_items), Map.of(_values), Map.of(_removals)));
    if (_undo.length > 100) _undo.removeAt(0);
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    final last = _undo.removeLast();
    setState(() {
      _items = last.items;
      _values
        ..clear()
        ..addAll(last.values);
      _removals
        ..clear()
        ..addAll(last.removals);
      _selected = null;
    });
  }

  void _addItem(EditItem item) {
    _remember();
    setState(() {
      _items = [..._items, item];
      _selected = item.movable ? item : null;
    });
  }

  void _replace(EditItem old, EditItem now) {
    setState(() {
      _items = [for (final i in _items) identical(i, old) ? now : i];
      if (identical(_selected, old)) _selected = now;
    });
  }

  void _deleteSelected() {
    final selected = _selected;
    if (selected == null) return;
    _remember();
    setState(() {
      _items = [
        for (final i in _items)
          if (!identical(i, selected)) i,
      ];
      _selected = null;
    });
  }

  // -------------------------------------------------------------- gestures

  EditItem? _itemAt(int page, Offset point) {
    for (final item in _items.reversed) {
      if (item.page == page && item.bounds.inflate(6).contains(point)) {
        return item;
      }
    }
    return null;
  }

  Future<void> _tapPage(int page, Offset point) async {
    switch (_tool) {
      case PdfEditTool.browse:
        setState(() => _selected = _itemAt(page, point));
      case PdfEditTool.text:
        await _addText(page, point);
      case PdfEditTool.note:
        await _addNote(page, point);
      case PdfEditTool.signature:
        await _addSignature(page, point);
      case PdfEditTool.image:
        await _addImage(page, point);
      default:
        break;
    }
  }

  Future<void> _longPressPage(int page, Offset point) async {
    final mine = _itemAt(page, point);
    if (mine != null) {
      setState(() => _selected = mine);
      return;
    }
    final hits = (_existing[page] ?? const [])
        .where(
          (a) =>
              a.isMarkup &&
              !_removals.containsKey(a.id) &&
              Rect.fromLTRB(
                a.box.left,
                a.box.top,
                a.box.right,
                a.box.bottom,
              ).inflate(4).contains(point),
        )
        .toList();
    if (hits.isEmpty) return;
    final target = hits.last;
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this annotation?'),
        content: Text(
          [
            _describe(target.subtype),
            if (target.contents.isNotEmpty) '“${target.contents}”',
            if (target.author.isNotEmpty) 'by ${target.author}',
          ].join(' '),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    _remember();
    setState(
      () => _removals[target.id] = PdfAnnotationRemoval(page, target.id),
    );
  }

  static String _describe(String subtype) => switch (subtype) {
    'Text' => 'A note',
    'FreeText' => 'A text box',
    'Highlight' => 'A highlight',
    'Underline' => 'An underline',
    'StrikeOut' => 'A strike-out',
    'Squiggly' => 'A squiggly underline',
    'Ink' => 'A drawing',
    'Square' => 'A rectangle',
    'Circle' => 'An ellipse',
    'Line' => 'A line',
    'Stamp' => 'A stamp or signature',
    _ => 'An annotation',
  };

  void _panStart(int page, Offset point, double scale) {
    _dragFrom = point;
    if (_tool == PdfEditTool.browse) {
      final selected = _selected;
      if (selected == null || selected.page != page) return;
      final handle = selected.bounds.inflate(3).bottomRight;
      _resizing =
          (selected is SignatureItem || selected is ImageItem) &&
          (point - handle).distance < 24 / scale;
      _moving = !_resizing && selected.bounds.inflate(8).contains(point);
      if (_moving || _resizing) _remember();
      return;
    }
    if (_tool.marksText) unawaited(_loadText(page));
    _draft = _draftFor(page, point, point);
    setState(() {});
  }

  void _panUpdate(int page, Offset point) {
    final from = _dragFrom;
    if (from == null) return;
    final selected = _selected;
    if (_tool == PdfEditTool.browse) {
      if (selected == null) return;
      if (_moving) {
        _replace(selected, selected.translated(point - from));
        _dragFrom = point;
      } else if (_resizing) {
        final box = selected.bounds;
        // Keep the proportions: the drag sets the width.
        final width = (point.dx - box.left).clamp(16.0, 2000.0);
        final height = width * box.height / box.width;
        final to = Rect.fromLTWH(box.left, box.top, width, height);
        if (selected is SignatureItem) _replace(selected, selected.resized(to));
        if (selected is ImageItem) _replace(selected, selected.resized(to));
      }
      return;
    }
    final draft = _draft;
    if (draft is InkItem) {
      // A new item, so the painter sees the change.
      final stroke = [...draft.strokes.last, point];
      setState(
        () => _draft = InkItem(draft.page, [stroke], draft.color, draft.width),
      );
      return;
    }
    setState(() => _draft = _draftFor(page, from, point));
  }

  void _panEnd(int page) {
    _dragFrom = null;
    if (_moving || _resizing) {
      _moving = _resizing = false;
      return;
    }
    final draft = _draft;
    _draft = null;
    if (draft == null) return;
    final big = draft.bounds.width > 2 || draft.bounds.height > 2;
    if (draft is InkItem || big) {
      _addItem(draft);
      if (draft is! InkItem) _selected = null;
    } else {
      setState(() {});
    }
  }

  EditItem _draftFor(int page, Offset from, Offset to) {
    switch (_tool) {
      case PdfEditTool.pen:
        return InkItem(
          page,
          [
            [from],
          ],
          _color,
          _penWidth,
        );
      case PdfEditTool.rectangle:
      case PdfEditTool.ellipse:
      case PdfEditTool.arrow:
        return ShapeItem(page, _tool, from, to, _color, _penWidth);
      default:
        return MarkupItem(page, _tool, _markupRects(page, from, to), _color);
    }
  }

  /// The lines of text between two points, one rectangle each; a plain
  /// rectangle on a page without text.
  List<Rect> _markupRects(int page, Offset a, Offset b) {
    final glyphs = _layouts[page]?.glyphs ?? const <PdfTextGlyph>[];
    if (glyphs.isEmpty) return [Rect.fromPoints(a, b)];
    int nearest(Offset p) {
      var best = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < glyphs.length; i++) {
        final g = glyphs[i];
        final dx = p.dx < g.left
            ? g.left - p.dx
            : (p.dx > g.right ? p.dx - g.right : 0.0);
        final dy = p.dy < g.top
            ? g.top - p.dy
            : (p.dy > g.bottom ? p.dy - g.bottom : 0.0);
        final d = dx * dx + dy * dy;
        if (d < bestDistance) {
          bestDistance = d;
          best = i;
        }
      }
      return best;
    }

    final i = nearest(a), j = nearest(b);
    final rects = <Rect>[];
    for (var k = i < j ? i : j; k <= (i < j ? j : i); k++) {
      final g = glyphs[k];
      final r = Rect.fromLTRB(g.left, g.top, g.right, g.bottom);
      if (r.width <= 0 || r.height <= 0) continue;
      if (rects.isNotEmpty) {
        final last = rects.last;
        final overlap =
            (last.bottom < r.bottom ? last.bottom : r.bottom) -
            (last.top > r.top ? last.top : r.top);
        final sameLine =
            overlap > 0.5 * (last.height < r.height ? last.height : r.height) &&
            r.left >= last.left - r.height;
        if (sameLine) {
          rects[rects.length - 1] = last.expandToInclude(r);
          continue;
        }
      }
      rects.add(r);
    }
    return rects.isEmpty ? [Rect.fromPoints(a, b)] : rects;
  }

  // -------------------------------------------------------------- adding

  Future<String?> _askText({
    required String title,
    String initial = '',
    bool multiline = true,
    int? maxLength,
  }) => showDialog<String>(
    context: context,
    builder: (ctx) => _AskTextDialog(
      title: title,
      initial: initial,
      multiline: multiline,
      maxLength: maxLength,
    ),
  );

  Future<void> _addText(int page, Offset at) async {
    final result = await showDialog<(String, double, bool)>(
      context: context,
      builder: (ctx) => _TextDialog(color: _color),
    );
    if (result == null || result.$1.trim().isEmpty || !mounted) return;
    final (text, size, bordered) = result;
    final box = TextItem.boxFor(text, size, at, bordered);
    _addItem(TextItem(page, box, text, size, _color, bordered: bordered));
  }

  Future<void> _editText(TextItem item) async {
    final text = await _askText(title: 'Edit text', initial: item.text);
    if (text == null || text.trim().isEmpty || !mounted) return;
    _remember();
    final box = TextItem.boxFor(
      text,
      item.fontSize,
      item.box.topLeft,
      item.bordered,
    );
    _replace(
      item,
      TextItem(
        item.page,
        box,
        text,
        item.fontSize,
        item.color,
        bordered: item.bordered,
      ),
    );
  }

  Future<void> _addNote(int page, Offset at) async {
    final text = await _askText(title: 'Note');
    if (text == null || text.trim().isEmpty || !mounted) return;
    _addItem(NoteItem(page, at, text, _color));
  }

  Future<void> _editNote(NoteItem item) async {
    final text = await _askText(title: 'Note', initial: item.text);
    if (text == null || text.trim().isEmpty || !mounted) return;
    _remember();
    _replace(item, NoteItem(item.page, item.at, text, item.color));
  }

  /// Pick or draw a signature and place it centred on [at], or fitted to
  /// [into] (a signature field).
  Future<void> _addSignature(int page, Offset at, {Rect? into}) async {
    final signature = await _pickSignature();
    if (signature == null || !mounted) return;
    final Rect box;
    if (into != null) {
      final fit = into.deflate(2);
      var width = fit.width;
      var height = width / signature.aspect;
      if (height > fit.height) {
        height = fit.height;
        width = height * signature.aspect;
      }
      box = Rect.fromCenter(center: fit.center, width: width, height: height);
    } else {
      final pageWidth = _sizes[page]?.width ?? 600;
      final width = (pageWidth * 0.3).clamp(80.0, 220.0);
      box = Rect.fromCenter(
        center: at,
        width: width,
        height: width / signature.aspect,
      );
    }
    _addItem(
      SignatureItem(
        page,
        box,
        signature.strokes,
        _toolColors[PdfEditTool.signature]!,
        2,
      ),
    );
  }

  Future<SavedSignature?> _pickSignature() async {
    final saved = await SignatureStore.load();
    if (!mounted) return null;
    if (saved.isEmpty) return _drawNewSignature();
    final colors = _colors;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: colors.cardBackground,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Your signatures',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Tap one to place it. Press and hold to forget it.',
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
            ),
            for (final s in saved)
              InkWell(
                onTap: () => Navigator.pop(ctx, s),
                onLongPress: () => Navigator.pop(ctx, ('forget', s)),
                child: Container(
                  height: 72,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.divider),
                  ),
                  child: Center(child: SignaturePreview(s)),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.draw_rounded, color: _accent),
              title: Text(
                'Draw a new signature',
                style: TextStyle(color: colors.textPrimary),
              ),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return null;
    if (choice is SavedSignature) return choice;
    if (choice == 'new') return _drawNewSignature();
    if (choice is (String, SavedSignature)) {
      await SignatureStore.save([
        for (final s in saved)
          if (!identical(s, choice.$2)) s,
      ]);
      return _pickSignature();
    }
    return null;
  }

  Future<SavedSignature?> _drawNewSignature() async {
    final signature = await drawSignature(context);
    if (signature != null) await SignatureStore.add(signature);
    return signature;
  }

  Future<void> _addImage(int page, Offset at) async {
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
      );
    } catch (e) {
      _snack('Could not open your pictures: $e');
      return;
    }
    if (file == null || !mounted) return;
    try {
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw StateError('no pixels');
      final dir = Directory('${(await getTemporaryDirectory()).path}/pdf_edit');
      await dir.create(recursive: true);
      final raw = File(
        '${dir.path}/picture_${DateTime.now().microsecondsSinceEpoch}.rgba',
      );
      await raw.writeAsBytes(data.buffer.asUint8List());
      if (!mounted) return;
      final pageWidth = _sizes[page]?.width ?? 600;
      final width = (pageWidth * 0.4).clamp(60.0, 300.0);
      final box = Rect.fromCenter(
        center: at,
        width: width,
        height: width * image.height / image.width,
      );
      _addItem(
        ImageItem(page, box, raw.path, image.width, image.height, image),
      );
    } catch (e) {
      _snack('That picture could not be read.');
      logError('PdfEdit.addImage', e);
    }
  }

  // -------------------------------------------------------------- fields

  PdfFieldValue? _pending(PdfFormField field) => _values[field.name];

  void _setValue(PdfFieldValue value) {
    _remember();
    setState(() => _values[value.name] = value);
  }

  Future<void> _editField(PdfFormField field, PdfFieldWidget widget) async {
    if (field.kind == PdfFieldKind.signature) {
      await _addSignature(
        widget.page,
        Offset.zero,
        into: Rect.fromLTRB(
          widget.box.left,
          widget.box.top,
          widget.box.right,
          widget.box.bottom,
        ),
      );
      return;
    }
    if (!field.fillable) {
      _snack('This field cannot be changed.');
      return;
    }
    final pending = _pending(field);
    switch (field.kind) {
      case PdfFieldKind.checkbox:
        final checked = pending?.checked ?? field.isChecked;
        _setValue(PdfFieldValue.checked(field.name, !checked));
      case PdfFieldKind.radio:
        final state = widget.onState;
        if (state != null) _setValue(PdfFieldValue.text(field.name, state));
      case PdfFieldKind.choice:
        await _editChoice(field);
      default:
        final text = await _askText(
          title: field.tooltip.isNotEmpty
              ? field.tooltip
              : _shortName(field.name),
          initial: pending?.value ?? field.value,
          multiline: field.multiline,
          maxLength: field.maxLength,
        );
        if (text != null && mounted) {
          _setValue(PdfFieldValue.text(field.name, text));
        }
    }
  }

  static String _shortName(String name) {
    final last = name.split('.').last.replaceAll(RegExp(r'\[\d+\]$'), '');
    return last.isEmpty ? name : last;
  }

  Future<void> _editChoice(PdfFormField field) async {
    final pending = _pending(field);
    final current =
        pending?.selected ??
        (pending?.value != null
            ? [pending!.value!]
            : (field.values.isNotEmpty
                  ? field.values
                  : [if (field.value.isNotEmpty) field.value]));
    final colors = _colors;
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.cardBackground,
      builder: (ctx) =>
          _ChoiceSheet(field: field, selected: current, colors: colors),
    );
    if (result == null || !mounted) return;
    _setValue(
      field.multiSelect
          ? PdfFieldValue.selected(field.name, result)
          : PdfFieldValue.text(field.name, result.isEmpty ? '' : result.first),
    );
  }

  // -------------------------------------------------------------- saving

  Future<bool> _save() async {
    if (_saving || !_dirty) return true;
    setState(() => _saving = true);
    final location = context.read<ThemeProvider>().saveLocation;
    try {
      final edits = PdfEdits(
        fields: _values.values.toList(),
        annotations: [for (final i in _items) i.toEdit(flatten: _flatten)],
        remove: _removals.values.toList(),
      );
      final target = await DocumentSaveService.workingPathFor(widget.pdfPath);
      final warnings = await PdfCore.applyEditsAsync(
        widget.pdfPath,
        edits,
        target,
        password: widget.password,
      );
      PdfRaster.invalidate(target);
      PdfRaster.invalidate(widget.pdfPath);
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      if (!mounted) return true;
      _items = [];
      _values.clear();
      _removals.clear();
      _snackOnRoot([message, ...warnings].join(' '));
      Navigator.pop(context, target);
      return true;
    } catch (e) {
      logError('PdfEdit.save', e);
      if (mounted) {
        setState(() => _saving = false);
        _snack('Could not save: ${PdfCoreService.describeError(e)}');
      }
      return false;
    }
  }

  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save your changes?'),
        content: const Text('What you added to this PDF is not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'save') {
      await _save();
      return;
    }
    setState(() {
      _items = [];
      _values.clear();
      _removals.clear();
    });
    Navigator.pop(context);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// A message that outlives this screen.
  void _snackOnRoot(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: _colors.background,
        appBar: AppBar(
          backgroundColor: _colors.cardBackground,
          foregroundColor: _colors.textPrimary,
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Undo',
              onPressed: _undo.isEmpty ? null : _undoLast,
              icon: const Icon(Icons.undo_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: 'Options',
              onSelected: (v) {
                if (v == 'flatten') setState(() => _flatten = !_flatten);
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'flatten',
                  checked: _flatten,
                  child: const Text('Lock what I add into the pages'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                key: const ValueKey('pdf-edit-save'),
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: _dirty && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        ),
        body: _body(),
        bottomNavigationBar: _loading || _error != null ? null : _toolbar(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: _colors.textSecondary, fontSize: 16),
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_form.xfa && _form.fields.isNotEmpty || _form.signed) _formNotice(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth - 16;
              return ListView.builder(
                physics: _tool.draws || _moving || _resizing
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _pageCount,
                itemBuilder: (context, index) => _page(index + 1, width),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _formNotice() => Container(
    width: double.infinity,
    color: const Color(0x1AFFC107),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      _form.signed
          ? 'This PDF is signed. Saving adds your changes after the signature, so it stays valid.'
          : 'This form also has an XFA layout. Saving keeps the standard form so every reader shows your answers.',
      style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
    ),
  );

  Widget _page(int page, double width) {
    final size = _sizes[page] ?? const Size(612, 792);
    final scale = width / size.width;
    final height = size.height * scale;
    unawaited(_loadExisting(page));
    final onPage = [
      for (final i in _items)
        if (i.page == page) i,
    ];
    final removed = [
      for (final a in _existing[page] ?? const <PdfAnnotationInfo>[])
        if (_removals.containsKey(a.id))
          Rect.fromLTRB(a.box.left, a.box.top, a.box.right, a.box.bottom),
    ];
    final drags =
        _tool.draws || (_tool == PdfEditTool.browse && _selected?.page == page);
    final draft = _draft?.page == page ? _draft : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: _PageImage(
                key: ValueKey('${widget.pdfPath}#$page'),
                path: widget.pdfPath,
                password: widget.password,
                pageIndex: page - 1,
                width: width,
                height: height,
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _tapPage(page, d.localPosition / scale),
                onLongPressStart: (d) =>
                    _longPressPage(page, d.localPosition / scale),
                onPanStart: drags
                    ? (d) => _panStart(page, d.localPosition / scale, scale)
                    : null,
                onPanUpdate: drags
                    ? (d) => _panUpdate(page, d.localPosition / scale)
                    : null,
                onPanEnd: drags ? (_) => _panEnd(page) : null,
                child: CustomPaint(
                  painter: EditItemsPainter(
                    items: onPage,
                    scale: scale,
                    selected: _selected?.page == page ? _selected : null,
                    draft: draft,
                    removed: removed,
                  ),
                ),
              ),
            ),
            if (_tool == PdfEditTool.browse) ..._fieldBoxes(page, scale),
          ],
        ),
      ),
    );
  }

  List<Widget> _fieldBoxes(int page, double scale) => [
    for (final field in _form.fields)
      if (field.kind != PdfFieldKind.button)
        for (final (i, w) in field.widgets.indexed)
          if (w.page == page)
            Positioned(
              key: ValueKey('field-${field.name}#$i'),
              left: w.box.left * scale,
              top: w.box.top * scale,
              width: (w.box.width * scale).clamp(8.0, double.infinity),
              height: (w.box.height * scale).clamp(8.0, double.infinity),
              child: GestureDetector(
                onTap: () => _editField(field, w),
                child: _FieldBox(
                  field: field,
                  widget: w,
                  pending: _pending(field),
                  scale: scale,
                ),
              ),
            ),
  ];

  Widget _toolbar() {
    final selected = _selected;
    return SafeArea(
      child: Container(
        color: _colors.cardBackground,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected != null) _selectionBar(selected),
            if (_tool != PdfEditTool.browse && _tool != PdfEditTool.image)
              _optionsBar(),
            SizedBox(
              height: 70,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                children: [
                  _toolButton(
                    PdfEditTool.browse,
                    Icons.pan_tool_alt_rounded,
                    _form.isEmpty ? 'Move' : 'Fill',
                  ),
                  _toolButton(
                    PdfEditTool.signature,
                    Icons.draw_rounded,
                    'Sign',
                  ),
                  _toolButton(
                    PdfEditTool.text,
                    Icons.text_fields_rounded,
                    'Text',
                  ),
                  _toolButton(
                    PdfEditTool.highlight,
                    Icons.border_color_rounded,
                    'Highlight',
                  ),
                  _toolButton(
                    PdfEditTool.underline,
                    Icons.format_underline_rounded,
                    'Underline',
                  ),
                  _toolButton(
                    PdfEditTool.strikeOut,
                    Icons.format_strikethrough_rounded,
                    'Strike',
                  ),
                  _toolButton(PdfEditTool.pen, Icons.gesture_rounded, 'Pen'),
                  _toolButton(
                    PdfEditTool.note,
                    Icons.sticky_note_2_rounded,
                    'Note',
                  ),
                  _toolButton(
                    PdfEditTool.rectangle,
                    Icons.crop_square_rounded,
                    'Box',
                  ),
                  _toolButton(
                    PdfEditTool.ellipse,
                    Icons.circle_outlined,
                    'Circle',
                  ),
                  _toolButton(
                    PdfEditTool.arrow,
                    Icons.north_east_rounded,
                    'Arrow',
                  ),
                  _toolButton(
                    PdfEditTool.image,
                    Icons.image_rounded,
                    'Picture',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton(PdfEditTool tool, IconData icon, String label) {
    final active = _tool == tool;
    return InkWell(
      key: ValueKey('tool-${tool.name}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _tool = tool;
          _selected = null;
        });
        if (tool.marksText) _preloadText();
      },
      child: Container(
        width: 68,
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: active ? _accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        // Scaled down rather than cut off under a large text setting.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: active ? _accent : _colors.textSecondary,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: active ? _accent : _colors.textSecondary,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionsBar() {
    final hint = switch (_tool) {
      PdfEditTool.highlight ||
      PdfEditTool.underline ||
      PdfEditTool.strikeOut => 'Drag across the text',
      PdfEditTool.pen => 'Draw with your finger',
      PdfEditTool.rectangle ||
      PdfEditTool.ellipse ||
      PdfEditTool.arrow => 'Drag to draw',
      PdfEditTool.text => 'Tap where the text goes',
      PdfEditTool.note => 'Tap where the note goes',
      PdfEditTool.signature => 'Tap where you sign',
      _ => '',
    };
    final widths =
        _tool == PdfEditTool.pen ||
        _tool == PdfEditTool.rectangle ||
        _tool == PdfEditTool.ellipse ||
        _tool == PdfEditTool.arrow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hint,
              style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
            ),
          ),
          if (widths)
            for (final w in const [1.0, 2.0, 4.0])
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Line width $w',
                onPressed: () => setState(() => _penWidth = w),
                icon: Container(
                  width: 18,
                  height: w + 1,
                  color: _penWidth == w ? _accent : _colors.textSecondary,
                ),
              ),
          InkWell(
            key: const ValueKey('pdf-edit-colour'),
            onTap: _pickColor,
            customBorder: const CircleBorder(),
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _color,
                shape: BoxShape.circle,
                border: Border.all(color: _colors.divider, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickColor() async {
    final colors = _colors;
    final picked = await showModalBottomSheet<Color>(
      context: context,
      backgroundColor: colors.cardBackground,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final c in _palette)
                InkWell(
                  onTap: () => Navigator.pop(ctx, c),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.divider, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _toolColors[_tool] = picked);
  }

  Widget _selectionBar(EditItem selected) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            selected is SignatureItem || selected is ImageItem
                ? 'Drag to move, or the dot to resize'
                : selected.movable
                ? 'Drag to move'
                : 'Selected',
            style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
          ),
        ),
        if (selected is TextItem)
          TextButton(
            onPressed: () => _editText(selected),
            child: const Text('Edit'),
          ),
        if (selected is NoteItem)
          TextButton(
            onPressed: () => _editNote(selected),
            child: const Text('Edit'),
          ),
        TextButton.icon(
          onPressed: _deleteSelected,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('Remove'),
        ),
        TextButton(
          onPressed: () => setState(() => _selected = null),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// A form field over the page: a tint to show it can be filled, and its
/// new value once given.
class _FieldBox extends StatelessWidget {
  const _FieldBox({
    required this.field,
    required this.widget,
    required this.pending,
    required this.scale,
  });

  final PdfFormField field;
  final PdfFieldWidget widget;
  final PdfFieldValue? pending;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final fillable = field.fillable || field.kind == PdfFieldKind.signature;
    final tint = BoxDecoration(
      color: pending == null
          ? (fillable ? const Color(0x221E88E5) : null)
          : const Color(0xF7FFFFFF),
      border: Border.all(
        color: fillable ? const Color(0x661E88E5) : const Color(0x22000000),
        width: 0.8,
      ),
    );
    final value = pending;
    if (value == null) return DecoratedBox(decoration: tint);
    final h = widget.box.height * scale;
    switch (field.kind) {
      case PdfFieldKind.checkbox:
        return DecoratedBox(
          decoration: tint,
          child: value.checked == true
              ? FittedBox(
                  child: Icon(
                    Icons.check_rounded,
                    size: h,
                    color: Colors.black,
                  ),
                )
              : null,
        );
      case PdfFieldKind.radio:
        final on = value.value == widget.onState;
        return DecoratedBox(
          decoration: tint,
          child: on
              ? Center(
                  child: Container(
                    width: h * 0.5,
                    height: h * 0.5,
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                  ),
                )
              : null,
        );
      default:
        final text =
            value.selected?.join(', ') ??
            (field.password
                ? '•' * (value.value ?? '').length
                : _label(value.value ?? ''));
        final size =
            (widget.fontSize > 0
                ? widget.fontSize
                : (widget.box.height * 0.7).clamp(6.0, 12.0)) *
            scale;
        return DecoratedBox(
          decoration: tint,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2 * scale),
            child: Align(
              alignment: field.multiline
                  ? Alignment.topLeft
                  : Alignment.centerLeft,
              child: Text(
                text,
                maxLines: field.multiline ? null : 1,
                overflow: field.multiline
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: size,
                  height: 1.15,
                ),
              ),
            ),
          ),
        );
    }
  }

  String _label(String value) {
    for (final o in field.options) {
      if (o.value == value && o.label.isNotEmpty) return o.label;
    }
    return value;
  }
}

/// Choose a list's option (or options, when it takes several).
class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({
    required this.field,
    required this.selected,
    required this.colors,
  });

  final PdfFormField field;
  final List<String> selected;
  final AppColors colors;

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  late final Set<String> _chosen = {...widget.selected};
  late final TextEditingController _typed = TextEditingController(
    text: widget.field.editable && widget.selected.isNotEmpty
        ? widget.selected.first
        : '',
  );

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final colors = widget.colors;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (field.editable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: TextField(
                  controller: _typed,
                  decoration: InputDecoration(
                    labelText: 'Type an answer',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.check_rounded),
                      onPressed: () => Navigator.pop(context, [_typed.text]),
                    ),
                  ),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in field.options)
                    field.multiSelect
                        ? CheckboxListTile(
                            value: _chosen.contains(o.value),
                            title: Text(
                              o.label,
                              style: TextStyle(color: colors.textPrimary),
                            ),
                            onChanged: (on) => setState(
                              () => on == true
                                  ? _chosen.add(o.value)
                                  : _chosen.remove(o.value),
                            ),
                          )
                        : ListTile(
                            title: Text(
                              o.label,
                              style: TextStyle(color: colors.textPrimary),
                            ),
                            trailing: _chosen.contains(o.value)
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: Color(0xFFE94560),
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, [o.value]),
                          ),
                ],
              ),
            ),
            if (field.multiSelect)
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, [
                    for (final o in field.options)
                      if (_chosen.contains(o.value)) o.value,
                  ]),
                  child: const Text('Done'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One piece of text: a field's value, a note. The dialog owns its
/// controller, so it outlives the dialog's closing animation.
class _AskTextDialog extends StatefulWidget {
  const _AskTextDialog({
    required this.title,
    required this.initial,
    required this.multiline,
    this.maxLength,
  });

  final String title;
  final String initial;
  final bool multiline;
  final int? maxLength;

  @override
  State<_AskTextDialog> createState() => _AskTextDialogState();
}

class _AskTextDialogState extends State<_AskTextDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      minLines: 1,
      maxLines: widget.multiline ? 6 : 1,
      keyboardType: widget.multiline
          ? TextInputType.multiline
          : TextInputType.text,
      decoration: const InputDecoration(border: OutlineInputBorder()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Text to type onto the page, its size, and whether it has a box.
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.color});

  final Color color;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();
  double _size = 12;
  bool _boxed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add text'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('pdf-edit-text'),
          controller: _controller,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        SegmentedButton<double>(
          segments: const [
            ButtonSegment(value: 9, label: Text('Small')),
            ButtonSegment(value: 12, label: Text('Medium')),
            ButtonSegment(value: 18, label: Text('Large')),
          ],
          selected: {_size},
          onSelectionChanged: (s) => setState(() => _size = s.first),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _boxed,
          onChanged: (v) => setState(() => _boxed = v ?? false),
          title: const Text('Draw a box around it'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (_controller.text, _size, _boxed)),
        child: const Text('Add'),
      ),
    ],
  );
}

/// A page as it is in the file.
class _PageImage extends StatefulWidget {
  const _PageImage({
    super.key,
    required this.path,
    required this.password,
    required this.pageIndex,
    required this.width,
    required this.height,
  });

  final String path;
  final String password;
  final int pageIndex;
  final double width;
  final double height;

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  Uint8List? _bytes;
  int _renderedWidth = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _render();
  }

  @override
  void didUpdateWidget(_PageImage old) {
    super.didUpdateWidget(old);
    if (old.width != widget.width) _render();
  }

  Future<void> _render() async {
    final ratio = MediaQuery.of(context).devicePixelRatio;
    final width = (widget.width * ratio).round();
    final height = (widget.height * ratio).round();
    if (width == _renderedWidth || width <= 0) return;
    _renderedWidth = width;
    final rendered = await PdfRaster.renderPageWithWarnings(
      widget.path,
      widget.pageIndex,
      width: width,
      height: height,
      password: widget.password,
      isWanted: () => mounted,
    );
    if (mounted && rendered != null) setState(() => _bytes = rendered.bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 4)],
      ),
      child: bytes == null
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
    );
  }
}
