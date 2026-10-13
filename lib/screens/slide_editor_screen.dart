import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/public_pdf_save_service.dart';
import '../services/recent_files_service.dart';
import '../utils/format_utils.dart';
import '../widgets/slide/slide_images.dart';
import '../widgets/slide/slide_painter.dart';
import 'slide_show_screen.dart';

/// Opens, edits and saves a presentation: the slide large, a strip of
/// slides below it, and tools for the slide or the selected shape.
class SlideEditorScreen extends StatefulWidget {
  const SlideEditorScreen({
    super.key,
    required this.path,
    this.title,
    this.isNew = false,
  });

  /// The file. For a new presentation, where its first save goes.
  final String path;
  final String? title;

  /// Start a new presentation instead of reading [path].
  final bool isNew;

  @override
  State<SlideEditorScreen> createState() => _SlideEditorScreenState();
}

enum _UnsavedChoice { save, discard }

/// Shapes offered by "Shape", with their names.
const slideShapePresets = <(String, String)>[
  ('rect', 'Rectangle'),
  ('roundRect', 'Rounded rectangle'),
  ('ellipse', 'Oval'),
  ('triangle', 'Triangle'),
  ('rtTriangle', 'Right triangle'),
  ('diamond', 'Diamond'),
  ('pentagon', 'Pentagon'),
  ('hexagon', 'Hexagon'),
  ('octagon', 'Octagon'),
  ('star5', 'Star'),
  ('rightArrow', 'Right arrow'),
  ('leftArrow', 'Left arrow'),
  ('upArrow', 'Up arrow'),
  ('downArrow', 'Down arrow'),
  ('leftRightArrow', 'Two-way arrow'),
  ('chevron', 'Chevron'),
  ('homePlate', 'Arrow box'),
  ('plus', 'Plus'),
  ('heart', 'Heart'),
  ('smileyFace', 'Smiley'),
  ('sun', 'Sun'),
  ('moon', 'Moon'),
  ('cloud', 'Cloud'),
  ('lightningBolt', 'Lightning'),
  ('wedgeRectCallout', 'Callout'),
  ('wedgeEllipseCallout', 'Speech bubble'),
  ('can', 'Cylinder'),
  ('cube', 'Cube'),
  ('donut', 'Ring'),
  ('line', 'Line'),
];

const _sizes = <double>[
  8,
  10,
  12,
  14,
  16,
  18,
  20,
  24,
  28,
  32,
  36,
  40,
  44,
  48,
  54,
  60,
  66,
  72,
  80,
  96,
];

const _textColors = <int>[
  0x000000,
  0x404040,
  0x7F7F7F,
  0xFFFFFF,
  0xC00000,
  0xFF0000,
  0xFFC000,
  0xFFFF00,
  0x92D050,
  0x00B050,
  0x00B0F0,
  0x0070C0,
  0x002060,
  0x7030A0,
  0xED7D31,
  0x4472C4,
];

class _SlideEditorScreenState extends State<SlideEditorScreen> {
  SlideDeck? _deck;
  SlideDeckInfo? _info;
  SlideImageCache? _images;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  late String _workingPath = widget.path;
  late bool _neverSaved = widget.isNew;
  AppColors _colors = AppColors(false);

  int _current = 0;
  final Map<int, SlideScene> _scenes = {};
  final Map<int, String> _notes = {};

  /// The selected shape on the current slide, and the table cell chosen in
  /// it.
  int? _selected;
  (int, int)? _cell;

  /// A move or resize in progress: the shape's box in points.
  Rect? _drag;
  Rect? _dragFrom;
  int _handle = -1;
  Offset _dragDelta = Offset.zero;

  Color get _accent => DocKind.slides.color;
  String get _name => widget.title ?? documentDisplayName(widget.path);
  bool get _dirty => _info?.modified ?? false;
  int get _count => _info?.slideCount ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _images?.dispose();
    _deck?.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final deck = widget.isNew
          ? SlideCore.create()
          : await SlideCore.open(widget.path, name: _name);
      if (!mounted) {
        deck.close();
        return;
      }
      _deck = deck;
      _images = SlideImageCache(deck);
      _info = deck.info();
      setState(() => _loading = false);
      final warnings = _info!.warnings;
      if (warnings.isNotEmpty) _snack(warnings.first);
    } on SlideCoreException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  SlideScene _scene(int i) => _scenes[i] ??= () {
    try {
      return _deck!.scene(i);
    } on SlideCoreException {
      return SlideScene(width: _info!.width, height: _info!.height);
    }
  }();

  String _notesOf(int i) => _notes[i] ??= () {
    try {
      return _deck!.notes(i);
    } on SlideCoreException {
      return '';
    }
  }();

  SlideItem? get _sel {
    final id = _selected;
    if (id == null || _deck == null || _count == 0) return null;
    for (final it in _scene(_current).items) {
      if (it.id == id) return it;
    }
    return null;
  }

  // --------------------------------------------------------------- editing

  /// Read the deck again after a change and show [slide], selecting
  /// [select].
  void _refresh({int? slide, int? select, bool keepSelection = false}) {
    final deck = _deck;
    if (deck == null) return;
    _scenes.clear();
    _notes.clear();
    _info = deck.info();
    if (slide != null) _current = slide;
    _current = _current.clamp(0, math.max(_count - 1, 0));
    if (!keepSelection) {
      _selected = select;
      _cell = null;
    } else if (_sel == null) {
      _selected = null;
      _cell = null;
    }
  }

  /// Apply an edit; returns what it did, or null when it failed.
  SlideEditResult? _apply(
    SlideEditResult Function(SlideDeck deck) edit, {
    bool selectResult = true,
    bool keepSelection = false,
  }) {
    final deck = _deck;
    if (deck == null) return null;
    try {
      final r = edit(deck);
      setState(
        () => _refresh(
          slide: r.slide,
          select: selectResult ? r.shape : null,
          keepSelection: keepSelection,
        ),
      );
      return r;
    } on SlideCoreException catch (e) {
      _snack(e.message);
      return null;
    }
  }

  void _undo() {
    final deck = _deck;
    if (deck == null) return;
    try {
      deck.undo();
    } on SlideCoreException catch (e) {
      _snack(e.message);
    }
    setState(() => _refresh(keepSelection: true));
  }

  void _redo() {
    final deck = _deck;
    if (deck == null) return;
    try {
      deck.redo();
    } on SlideCoreException catch (e) {
      _snack(e.message);
    }
    setState(() => _refresh(keepSelection: true));
  }

  void _goTo(int slide) {
    setState(() {
      _current = slide.clamp(0, math.max(_count - 1, 0));
      _selected = null;
      _cell = null;
    });
  }

  /// The box new things go in: centred, a share of the slide.
  Rect _centred(double wShare, double hShare) {
    final info = _info!;
    final w = info.width * wShare;
    final h = info.height * hShare;
    return Rect.fromLTWH((info.width - w) / 2, (info.height - h) / 2, w, h);
  }

  Future<void> _newSlide() async {
    final layouts = _info?.layouts ?? const [];
    String? layout;
    if (layouts.length > 1) {
      layout = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            children: [
              const ListTile(
                title: Text(
                  'New slide',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              for (final l in layouts)
                ListTile(
                  leading: Icon(_layoutIcon(l.name)),
                  title: Text(l.name),
                  onTap: () => Navigator.pop(ctx, l.id),
                ),
            ],
          ),
        ),
      );
      if (layout == null) return;
    }
    _apply(
      (d) => d.addSlide(after: _count == 0 ? null : _current, layout: layout),
      selectResult: false,
    );
    _scrollStripTo(_current);
  }

  IconData _layoutIcon(String name) {
    final n = name.toLowerCase();
    if (n.contains('blank')) return Icons.crop_landscape_rounded;
    if (n.contains('two') || n.contains('comparison')) {
      return Icons.view_column_outlined;
    }
    if (n.contains('section')) return Icons.horizontal_split_outlined;
    if (n.contains('title only')) return Icons.title_rounded;
    if (n.contains('title slide')) return Icons.featured_video_outlined;
    if (n.contains('picture')) return Icons.image_outlined;
    return Icons.view_agenda_outlined;
  }

  Future<void> _addTextBox() async {
    final box = _centred(0.5, 0.12);
    final r = _apply(
      (d) => d.addTextBox(_current, box.left, box.top, box.width, box.height),
    );
    final id = r?.shape;
    if (id == null) return;
    final item = _sel;
    if (item == null) return;
    final typed = await _editText(item);
    // An empty new box is not kept, as in PowerPoint.
    if (!typed && mounted) _undo();
  }

  Future<void> _addShape() async {
    final preset = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (ctx, scroll) => GridView.builder(
            controller: scroll,
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 96,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.85,
            ),
            itemCount: slideShapePresets.length,
            itemBuilder: (ctx, i) {
              final (preset, label) = slideShapePresets[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.pop(ctx, preset),
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: CustomPaint(
                          painter: _PresetPainter(preset, _accent),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    if (preset == null) return;
    final box = preset == 'line' ? _centred(0.3, 0) : _centred(0.25, 0.3);
    final size = math.min(box.width, box.height);
    final square = preset == 'line'
        ? box
        : Rect.fromCenter(center: box.center, width: size * 1.3, height: size);
    _apply(
      (d) => d.addShape(
        _current,
        preset,
        square.left,
        square.top,
        square.width,
        square.height,
      ),
    );
  }

  Future<void> _addPicture() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      _snack('Could not open your pictures: $e');
      return;
    }
    if (picked == null || !mounted) return;
    var aspect = 4 / 3;
    try {
      final bytes = await File(picked.path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.height > 0) aspect = descriptor.width / descriptor.height;
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {
      // Keep 4:3.
    }
    if (!mounted) return;
    final info = _info!;
    var w = info.width * 0.6;
    var h = w / aspect;
    if (h > info.height * 0.7) {
      h = info.height * 0.7;
      w = h * aspect;
    }
    final x = (info.width - w) / 2;
    final y = (info.height - h) / 2;
    _apply((d) => d.addImage(_current, picked!.path, x, y, w, h));
  }

  void _deleteSelected() {
    final it = _sel;
    if (it == null) return;
    if (it.grouped) {
      _snack('This shape is part of a group; it cannot be deleted alone.');
      return;
    }
    _apply((d) => d.deleteShape(_current, it.id), selectResult: false);
  }

  /// Edit a shape's text (or a table cell's) in a sheet. Returns whether
  /// the text ends up non-empty.
  Future<bool> _editText(SlideItem it, {(int, int)? cell}) async {
    final box = cell != null
        ? it.table!.rows[cell.$1].$2[cell.$2].text
        : it.text;
    if (it.kind != SlideItemKind.shape && cell == null) {
      _snack('Pictures and charts have no text to edit.');
      return false;
    }
    final initial = (box?.paragraphs ?? const ['']).join('\n');
    final title = cell != null
        ? 'Cell text'
        : switch (it.placeholder) {
            'title' || 'ctrTitle' => 'Title',
            'subTitle' => 'Subtitle',
            null => 'Text',
            _ => 'Text',
          };
    var latest = initial;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TextSheet(
        title: title,
        initial: initial,
        hint: box?.prompt ?? 'Type here',
        onChanged: (t) => latest = t,
      ),
    );
    if (!mounted) return false;
    if (latest != initial) {
      _apply(
        (d) => d.setText(_current, it.id, latest.split('\n'), cell: cell),
        keepSelection: true,
      );
    }
    return latest.trim().isNotEmpty;
  }

  Future<void> _editNotes() async {
    if (_deck == null || _count == 0) return;
    final initial = _notesOf(_current);
    var latest = initial;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TextSheet(
        title: 'Speaker notes, slide ${_current + 1}',
        initial: initial,
        hint: 'What to say while this slide shows',
        onChanged: (t) => latest = t,
      ),
    );
    if (!mounted || latest == initial) return;
    _apply((d) => d.setNotes(_current, latest), keepSelection: true);
  }

  // ------------------------------------------------------------ formatting

  SlideRun? get _firstRun {
    final box = _textBox;
    if (box == null) return null;
    for (final p in box.paras) {
      for (final r in p.runs) {
        if (r.text.isNotEmpty) return r;
      }
    }
    return null;
  }

  SlideTextBox? get _textBox {
    final it = _sel;
    if (it == null) return null;
    final cell = _cell;
    if (cell != null && it.table != null) {
      final rows = it.table!.rows;
      if (cell.$1 < rows.length && cell.$2 < rows[cell.$1].$2.length) {
        return rows[cell.$1].$2[cell.$2].text;
      }
      return null;
    }
    return it.text;
  }

  void _format({
    bool? bold,
    bool? italic,
    bool? underline,
    double? size,
    int? color,
    String? align,
  }) {
    final it = _sel;
    if (it == null) return;
    if (it.kind == SlideItemKind.table && _cell == null) {
      _snack('Tap a cell of the table first.');
      return;
    }
    _apply(
      (d) => d.formatText(
        _current,
        it.id,
        cell: _cell,
        bold: bold,
        italic: italic,
        underline: underline,
        size: size,
        color: color,
        align: align,
      ),
      keepSelection: true,
    );
  }

  Future<void> _pickSize() async {
    final current = _firstRun?.size;
    final size = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 360,
          child: ListView(
            children: [
              for (final s in _sizes)
                ListTile(
                  selected: current != null && (s - current).abs() < 0.5,
                  title: Text('${s.toInt()} pt'),
                  onTap: () => Navigator.pop(ctx, s),
                ),
            ],
          ),
        ),
      ),
    );
    if (size != null) _format(size: size);
  }

  Future<void> _pickColor() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in _textColors)
                InkWell(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(0xFF000000 | c),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _format(color: picked);
  }

  // ---------------------------------------------------------- slide menu

  Future<void> _slideMenu(int slide) async {
    if (slide != _current) _goTo(slide);
    final hidden = _scene(slide).hidden;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Slide ${slide + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_box_outlined),
                title: const Text('New slide after this one'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: const Text('Duplicate'),
                onTap: () => Navigator.pop(ctx, 'duplicate'),
              ),
              if (slide > 0)
                ListTile(
                  leading: const Icon(Icons.arrow_back_rounded),
                  title: const Text('Move earlier'),
                  onTap: () => Navigator.pop(ctx, 'left'),
                ),
              if (slide < _count - 1)
                ListTile(
                  leading: const Icon(Icons.arrow_forward_rounded),
                  title: const Text('Move later'),
                  onTap: () => Navigator.pop(ctx, 'right'),
                ),
              ListTile(
                leading: Icon(
                  hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                title: Text(
                  hidden ? 'Show in slide show' : 'Hide in slide show',
                ),
                onTap: () => Navigator.pop(ctx, 'hide'),
              ),
              ListTile(
                leading: const Icon(Icons.speaker_notes_outlined),
                title: const Text('Speaker notes'),
                onTap: () => Navigator.pop(ctx, 'notes'),
              ),
              if (_count > 1)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Delete slide'),
                  onTap: () => Navigator.pop(ctx, 'delete'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'new':
        await _newSlide();
      case 'duplicate':
        _apply((d) => d.duplicateSlide(slide), selectResult: false);
      case 'left':
        _apply((d) => d.moveSlide(slide, slide - 1), selectResult: false);
        _current = slide - 1;
      case 'right':
        _apply((d) => d.moveSlide(slide, slide + 1), selectResult: false);
        _current = slide + 1;
      case 'hide':
        _apply((d) => d.hideSlide(slide, !hidden), selectResult: false);
      case 'notes':
        await _editNotes();
      case 'delete':
        _apply((d) => d.deleteSlide(slide), selectResult: false);
    }
    if (mounted) setState(() {});
    _scrollStripTo(_current);
  }

  final ScrollController _strip = ScrollController();

  void _scrollStripTo(int slide) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_strip.hasClients) return;
      final target = (slide * _thumbExtent - 80).clamp(
        0.0,
        _strip.position.maxScrollExtent,
      );
      _strip.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  double get _thumbExtent {
    final info = _info;
    if (info == null || info.height == 0) return 120;
    return 60 * info.width / info.height + 12;
  }

  // --------------------------------------------------------------- gestures

  /// The topmost of the slide's own shapes under [pt] (points).
  SlideItem? _hit(Offset pt, double s) {
    final items = _scene(_current).items;
    final tol = 10 / s;
    for (var k = items.length - 1; k >= 0; k--) {
      final it = items[k];
      if (it.id == 0) continue;
      var d = pt - Offset(it.x + it.w / 2, it.y + it.h / 2);
      if (it.rot != 0) {
        final a = -it.rot * math.pi / 180;
        d = Offset(
          d.dx * math.cos(a) - d.dy * math.sin(a),
          d.dx * math.sin(a) + d.dy * math.cos(a),
        );
      }
      if (d.dx.abs() <= it.w / 2 + tol && d.dy.abs() <= it.h / 2 + tol) {
        return it;
      }
    }
    return null;
  }

  /// The table cell under [pt] (points) in [it].
  (int, int)? _cellAt(SlideItem it, Offset pt, double s) {
    final t = it.table;
    if (t == null) return null;
    final local = Offset((pt.dx - it.x) * s, (pt.dy - it.y) * s);
    final ys = slideTableRowEdges(t, s);
    var row = -1;
    for (var r = 0; r + 1 < ys.length; r++) {
      if (local.dy >= ys[r] && local.dy < ys[r + 1]) row = r;
    }
    var col = -1;
    var x = 0.0;
    for (var c = 0; c < t.cols.length; c++) {
      final next = x + t.cols[c] * s;
      if (local.dx >= x && local.dx < next) col = c;
      x = next;
    }
    if (row < 0 || col < 0) return null;
    // A covered cell belongs to the cell spanning it.
    for (var r = row; r >= 0; r--) {
      for (var c = col; c >= 0; c--) {
        final cells = t.rows[r].$2;
        if (c >= cells.length) continue;
        final cell = cells[c];
        if (!cell.merged && r + cell.rowSpan > row && c + cell.colSpan > col) {
          return (r, c);
        }
      }
    }
    return (row, col);
  }

  void _onTap(Offset local, double s) {
    final pt = local / s;
    final hit = _hit(pt, s);
    if (hit == null) {
      setState(() {
        _selected = null;
        _cell = null;
      });
      return;
    }
    if (hit.kind == SlideItemKind.table) {
      final cell = _cellAt(hit, pt, s);
      final again = hit.id == _selected && cell != null && cell == _cell;
      setState(() {
        _selected = hit.id;
        _cell = cell;
      });
      if (again) _editText(hit, cell: cell);
      return;
    }
    final again = hit.id == _selected;
    setState(() {
      _selected = hit.id;
      _cell = null;
    });
    final emptyPlaceholder =
        hit.placeholder != null && (hit.text?.isEmpty ?? false);
    if ((again || emptyPlaceholder) && hit.kind == SlideItemKind.shape) {
      _editText(hit);
    }
  }

  List<Offset> _corners(SlideItem it, Rect box) {
    final c = box.center;
    final a = it.rot * math.pi / 180;
    Offset rot(Offset p) {
      final d = p - c;
      return c +
          Offset(
            d.dx * math.cos(a) - d.dy * math.sin(a),
            d.dx * math.sin(a) + d.dy * math.cos(a),
          );
    }

    return [
      rot(box.topLeft),
      rot(box.topRight),
      rot(box.bottomRight),
      rot(box.bottomLeft),
    ];
  }

  void _onPanStart(Offset local, double s) {
    final pt = local / s;
    var it = _sel;
    _handle = -1;
    if (it != null && !it.grouped) {
      final box = Rect.fromLTWH(it.x, it.y, it.w, it.h);
      final corners = _corners(it, box);
      for (var k = 0; k < 4; k++) {
        if ((corners[k] - pt).distance * s < 24) _handle = k;
      }
    }
    if (_handle < 0 || it == null) {
      final hit = _hit(pt, s);
      if (hit == null) return;
      if (hit.id != _selected) {
        setState(() {
          _selected = hit.id;
          _cell = null;
        });
      }
      it = hit;
    }
    if (it.grouped) {
      _snack('This shape is part of a group; it moves with the group.');
      return;
    }
    _dragFrom = Rect.fromLTWH(it.x, it.y, it.w, it.h);
    _dragDelta = Offset.zero;
    setState(() => _drag = _dragFrom);
  }

  void _onPanUpdate(Offset delta, double s) {
    final from = _dragFrom;
    final it = _sel;
    if (from == null || it == null) return;
    _dragDelta += delta / s;
    Rect next;
    if (_handle < 0) {
      next = from.shift(_dragDelta);
    } else {
      // Resize in the shape's own frame.
      final a = -it.rot * math.pi / 180;
      final d = Offset(
        _dragDelta.dx * math.cos(a) - _dragDelta.dy * math.sin(a),
        _dragDelta.dx * math.sin(a) + _dragDelta.dy * math.cos(a),
      );
      var l = from.left, t = from.top, r = from.right, b = from.bottom;
      switch (_handle) {
        case 0:
          l += d.dx;
          t += d.dy;
        case 1:
          r += d.dx;
          t += d.dy;
        case 2:
          r += d.dx;
          b += d.dy;
        default:
          l += d.dx;
          b += d.dy;
      }
      const min = 4.0;
      if (r - l < min) {
        if (_handle == 0 || _handle == 3) {
          l = r - min;
        } else {
          r = l + min;
        }
      }
      // Lines may be flat; other shapes keep some height.
      final minH = from.height == 0 ? 0.0 : min;
      if (b - t < minH) {
        if (_handle == 0 || _handle == 1) {
          t = b - minH;
        } else {
          b = t + minH;
        }
      }
      next = Rect.fromLTRB(l, t, r, b);
      if (it.kind == SlideItemKind.picture && from.height > 0) {
        // Pictures keep their shape.
        final aspect = from.width / from.height;
        final w = next.width;
        final h = w / aspect;
        next = _handle == 0 || _handle == 1
            ? Rect.fromLTWH(next.left, next.bottom - h, w, h)
            : Rect.fromLTWH(next.left, next.top, w, h);
      }
    }
    setState(() => _drag = next);
  }

  void _onPanEnd() {
    final from = _dragFrom;
    final to = _drag;
    final it = _sel;
    _dragFrom = null;
    if (from == null || to == null || it == null) {
      setState(() => _drag = null);
      return;
    }
    if ((to.topLeft - from.topLeft).distance < 0.5 &&
        (to.width - from.width).abs() + (to.height - from.height).abs() < 0.5) {
      setState(() => _drag = null);
      return;
    }
    _drag = null;
    _apply(
      (d) => d.moveShape(_current, it.id, to.left, to.top, to.width, to.height),
      keepSelection: true,
    );
  }

  // ---------------------------------------------------------------- saving

  Future<bool> _save() async {
    final deck = _deck;
    if (deck == null || _saving) return false;
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() => _saving = true);
    try {
      final target = _neverSaved
          ? _workingPath
          : await DocumentSaveService.workingPathFor(_workingPath);
      await deck.save(target);
      _neverSaved = false;
      _workingPath = target;
      await RecentFilesService.markOpened(target);
      _info = deck.info();
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      _snack(message);
      return true;
    } on SlideCoreException catch (e) {
      _snack('Could not save: ${e.message}');
      return false;
    } on PublicPdfSaveException catch (e) {
      _snack(e.message);
      return true;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _extension {
    final ext = DocKind.extensionOf(_workingPath);
    return ext.isEmpty ? 'pptx' : ext;
  }

  Future<void> _share({bool asText = false}) async {
    final deck = _deck;
    if (deck == null) return;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final ext = asText ? 'txt' : _extension;
      final file = '${dir.path}/$title.$ext';
      await deck.writeCopy(file, format: asText ? 'txt' : null);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file, mimeType: DocKind.mimeTypeOf(file))]),
      );
    } catch (e) {
      _snack('Could not share: $e');
    }
  }

  Future<void> _saveCopyAs() async {
    final deck = _deck;
    if (deck == null) return;
    final format = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Save a copy as',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.slideshow_outlined),
              title: Text(
                _info?.format == 'odp'
                    ? 'OpenDocument presentation (.$_extension)'
                    : 'PowerPoint (.$_extension)',
              ),
              onTap: () => Navigator.pop(ctx, _extension),
            ),
            ListTile(
              leading: const Icon(Icons.notes_rounded),
              title: const Text('Slide text (.txt)'),
              onTap: () => Navigator.pop(ctx, 'txt'),
            ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    final location = context.read<ThemeProvider>().saveLocation;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/export');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final file = '${dir.path}/$title.$format';
      await deck.writeCopy(file, format: format == 'txt' ? 'txt' : null);
      await PublicPdfSaveService.save(
        sourcePath: file,
        displayName: '$title.$format',
        location: location,
        mimeType: DocKind.mimeTypeOf(file),
      );
      _snack('Saved a copy to $location/DocHelper.');
    } catch (e) {
      _snack('Could not save a copy: $e');
    }
  }

  Future<void> _copyAll() async {
    final text = _deck?.plainText();
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Copied the text of every slide');
  }

  Future<void> _present() async {
    final deck = _deck;
    final images = _images;
    if (deck == null || images == null || _count == 0) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SlideShowScreen(deck: deck, images: images, start: _current),
      ),
    );
  }

  Future<void> _onWillLeave() async {
    final choice = await showDialog<_UnsavedChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save your changes?'),
        content: Text('$_name has changes that are not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UnsavedChoice.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _UnsavedChoice.save),
            child: const Text('Save'),
          ),
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

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      canPop: !_dirty && _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selected != null) {
          setState(() {
            _selected = null;
            _cell = null;
          });
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
            _extension.toUpperCase(),
            '${info.slideCount} slide${info.slideCount == 1 ? '' : 's'}',
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
            style: TextStyle(
              color: _colors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle,
              style: TextStyle(color: _colors.textTertiary, fontSize: 12),
            ),
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
        IconButton(
          tooltip: 'Present',
          icon: const Icon(Icons.play_arrow_rounded),
          onPressed: _deck != null && _count > 0 ? _present : null,
        ),
        TextButton(
          onPressed: (_dirty || _neverSaved) && !_saving && _deck != null
              ? _save
              : null,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'Save',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          enabled: _deck != null,
          onSelected: (value) => switch (value) {
            'notes' => _editNotes(),
            'copy' => _copyAll(),
            'share' => _share(),
            'shareText' => _share(asText: true),
            'copyAs' => _saveCopyAs(),
            _ => null,
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'notes', child: Text('Speaker notes')),
            PopupMenuItem(value: 'copy', child: Text('Copy all text')),
            PopupMenuItem(value: 'share', child: Text('Share')),
            PopupMenuItem(value: 'shareText', child: Text('Share as text')),
            PopupMenuItem(value: 'copyAs', child: Text('Save a copy as…')),
          ],
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null || _deck == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: _accent),
              const SizedBox(height: 12),
              Text(
                error ?? 'This presentation could not be opened.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.textPrimary, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      children: [
        Expanded(child: _buildStage()),
        if (!keyboard && _count > 0) _buildNotesBar(),
        if (!keyboard) _buildStrip(),
        _buildToolbar(),
      ],
    );
  }

  Widget _buildStage() {
    if (_count == 0) {
      return Center(
        child: FilledButton.icon(
          onPressed: _newSlide,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add a slide'),
        ),
      );
    }
    final scene = _scene(_current);
    final images = _images!;
    return LayoutBuilder(
      builder: (context, box) {
        const pad = 12.0;
        final s = math.min(
          (box.maxWidth - pad * 2) / scene.width,
          (box.maxHeight - pad * 2) / scene.height,
        );
        if (s <= 0) return const SizedBox.shrink();
        final size = Size(scene.width * s, scene.height * s);
        final sel = _sel;
        final drag = _drag;
        return Center(
          child: Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: _colors.shadowColor,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: GestureDetector(
              key: const Key('slide-stage'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onTap(d.localPosition, s),
              onPanStart: (d) => _onPanStart(d.localPosition, s),
              onPanUpdate: (d) => _onPanUpdate(d.delta, s),
              onPanEnd: (_) => _onPanEnd(),
              onPanCancel: _onPanEnd,
              child: ListenableBuilder(
                listenable: images,
                builder: (context, _) => CustomPaint(
                  size: size,
                  painter: SlidePainter(
                    scene: scene,
                    images: images.get,
                    prompts: true,
                    hiddenId: drag != null ? sel?.id : null,
                    generation: images.generation,
                  ),
                  foregroundPainter: _OverlayPainter(
                    item: sel,
                    drag: drag,
                    scale: s,
                    images: images.get,
                    accent: _accent,
                    cell: _cell,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNotesBar() {
    final notes = _notesOf(_current).trim();
    return Material(
      color: _colors.cardBackground,
      child: InkWell(
        onTap: _editNotes,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _colors.divider)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.speaker_notes_outlined,
                size: 18,
                color: _colors.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  notes.isEmpty ? 'Tap to add speaker notes' : notes,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: notes.isEmpty
                        ? _colors.textTertiary
                        : _colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStrip() {
    final images = _images!;
    final info = _info!;
    final thumbW = 60 * info.width / math.max(info.height, 1);
    return Container(
      height: 92,
      color: _colors.cardBackground,
      child: ReorderableListView.builder(
        scrollController: _strip,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        itemCount: _count,
        onReorderItem: (from, to) {
          if (to == from) return;
          _apply((d) => d.moveSlide(from, to), selectResult: false);
          setState(() => _current = to);
        },
        footer: Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 18),
          child: SizedBox(
            width: thumbW * 0.7,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: _newSlide,
              child: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        itemBuilder: (context, i) {
          final scene = _scene(i);
          final current = i == _current;
          return Padding(
            key: ValueKey(i),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: GestureDetector(
              onTap: () => current ? _slideMenu(i) : _goTo(i),
              child: Column(
                children: [
                  Container(
                    width: thumbW,
                    height: 60,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: current ? _accent : _colors.divider,
                        width: current ? 2.5 : 1,
                      ),
                    ),
                    child: Opacity(
                      opacity: scene.hidden ? 0.4 : 1,
                      child: RepaintBoundary(
                        child: ListenableBuilder(
                          listenable: images,
                          builder: (context, _) => CustomPaint(
                            painter: SlidePainter(
                              scene: scene,
                              images: images.get,
                              generation: images.generation,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: current ? _accent : _colors.textTertiary,
                        ),
                      ),
                      if (scene.hidden)
                        Icon(
                          Icons.visibility_off_outlined,
                          size: 11,
                          color: _colors.textTertiary,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tool(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool active = false,
  }) {
    final color = onTap == null
        ? _colors.textTertiary
        : active
        ? _accent
        : _colors.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 60),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: active
            ? BoxDecoration(
                color: _accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final it = _sel;
    final List<Widget> tools;
    if (it == null) {
      tools = [
        _tool(Icons.add_box_outlined, 'New slide', _newSlide),
        _tool(
          Icons.text_fields_rounded,
          'Text box',
          _count > 0 ? _addTextBox : null,
        ),
        _tool(Icons.category_outlined, 'Shape', _count > 0 ? _addShape : null),
        _tool(Icons.image_outlined, 'Picture', _count > 0 ? _addPicture : null),
        _tool(
          Icons.view_carousel_outlined,
          'Slide',
          _count > 0 ? () => _slideMenu(_current) : null,
        ),
        _tool(
          Icons.play_arrow_rounded,
          'Present',
          _count > 0 ? _present : null,
        ),
      ];
    } else {
      final run = _firstRun;
      final hasText =
          it.kind == SlideItemKind.shape ||
          (it.kind == SlideItemKind.table && _cell != null);
      final align = _textBox?.paras.firstOrNull?.align ?? 'l';
      final nextAlign = switch (align) {
        'l' => 'ctr',
        'ctr' => 'r',
        _ => 'l',
      };
      tools = [
        _tool(Icons.check_rounded, 'Done', () {
          setState(() {
            _selected = null;
            _cell = null;
          });
        }),
        _tool(
          Icons.edit_outlined,
          'Edit text',
          hasText ? () => _editText(it, cell: _cell) : null,
        ),
        _tool(
          Icons.format_bold_rounded,
          'Bold',
          hasText ? () => _format(bold: !(run?.bold ?? false)) : null,
          active: run?.bold ?? false,
        ),
        _tool(
          Icons.format_italic_rounded,
          'Italic',
          hasText ? () => _format(italic: !(run?.italic ?? false)) : null,
          active: run?.italic ?? false,
        ),
        _tool(
          Icons.format_underlined_rounded,
          'Underline',
          hasText ? () => _format(underline: !(run?.underline ?? false)) : null,
          active: run?.underline ?? false,
        ),
        _tool(
          Icons.format_size_rounded,
          run == null ? 'Size' : '${run.size.round()} pt',
          hasText ? _pickSize : null,
        ),
        _tool(
          Icons.format_color_text_rounded,
          'Colour',
          hasText ? _pickColor : null,
        ),
        _tool(
          switch (align) {
            'ctr' => Icons.format_align_center_rounded,
            'r' => Icons.format_align_right_rounded,
            'just' => Icons.format_align_justify_rounded,
            _ => Icons.format_align_left_rounded,
          },
          'Align',
          hasText ? () => _format(align: nextAlign) : null,
        ),
        _tool(
          Icons.delete_outline_rounded,
          'Delete',
          it.grouped ? null : _deleteSelected,
        ),
      ];
    }
    return Material(
      color: _colors.cardBackground,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _colors.divider)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(children: tools),
        ),
      ),
    );
  }
}

/// A sheet with one text field; reports every change so closing it any
/// way keeps what was typed.
class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.title,
    required this.initial,
    required this.hint,
    required this.onChanged,
  });

  final String title;
  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: widget.onChanged,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The selection frame and handles, and the shape being dragged.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.item,
    required this.drag,
    required this.scale,
    required this.images,
    required this.accent,
    required this.cell,
  });

  final SlideItem? item;
  final Rect? drag;
  final double scale;
  final SlideImageLookup images;
  final Color accent;
  final (int, int)? cell;

  @override
  void paint(Canvas canvas, Size size) {
    final it = item;
    if (it == null) return;
    final s = scale;
    final box = drag ?? Rect.fromLTWH(it.x, it.y, it.w, it.h);
    if (drag != null) {
      // The shape itself, stretched from its box to the new one.
      canvas.save();
      final sx = it.w == 0 ? 1.0 : box.width / it.w;
      final sy = it.h == 0 ? 1.0 : box.height / it.h;
      canvas.translate(box.left * s, box.top * s);
      canvas.scale(sx, sy);
      canvas.translate(-it.x * s, -it.y * s);
      paintSlideItem(canvas, it, s, images);
      canvas.restore();
    }
    final r = Rect.fromLTWH(
      box.left * s,
      box.top * s,
      box.width * s,
      box.height * s,
    );
    canvas.save();
    canvas.translate(r.center.dx, r.center.dy);
    if (it.rot != 0) canvas.rotate(it.rot * math.pi / 180);
    final local = Rect.fromCenter(
      center: Offset.zero,
      width: r.width,
      height: r.height,
    );
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = accent;
    canvas.drawRect(local.inflate(1), frame);
    final c = cell;
    final t = it.table;
    if (c != null && t != null && drag == null) {
      final ys = slideTableRowEdges(t, s);
      var x = 0.0;
      for (var k = 0; k < c.$2 && k < t.cols.length; k++) {
        x += t.cols[k] * s;
      }
      final cells = t.rows[c.$1].$2;
      final span = c.$2 < cells.length ? cells[c.$2] : null;
      var w = 0.0;
      for (
        var k = c.$2;
        k < c.$2 + (span?.colSpan ?? 1) && k < t.cols.length;
        k++
      ) {
        w += t.cols[k] * s;
      }
      final bottom = ys[math.min(c.$1 + (span?.rowSpan ?? 1), ys.length - 1)];
      canvas.drawRect(
        Rect.fromLTRB(x, ys[c.$1], x + w, bottom).shift(local.topLeft),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = accent,
      );
    }
    if (!it.grouped) {
      final fill = Paint()..color = Colors.white;
      for (final p in [
        local.topLeft,
        local.topRight,
        local.bottomRight,
        local.bottomLeft,
      ]) {
        canvas.drawCircle(p, 7, fill);
        canvas.drawCircle(p, 7, frame);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.item != item ||
      old.drag != drag ||
      old.scale != scale ||
      old.cell != cell;
}

/// A preset's outline for the shape picker.
class _PresetPainter extends CustomPainter {
  _PresetPainter(this.preset, this.color);

  final String preset;
  final Color color;

  static final Map<String, List<SlidePath>> _cache = {};

  @override
  void paint(Canvas canvas, Size size) {
    const w = 64.0;
    final h = preset == 'line' ? 0.0 : 48.0;
    List<SlidePath> paths;
    try {
      paths = _cache[preset] ??= SlideCore.presetPaths(preset, w, h);
    } catch (_) {
      return;
    }
    final s = math.min(size.width / w, size.height / 48);
    canvas.translate(
      (size.width - w * s) / 2,
      (size.height - (h == 0 ? 0 : h) * s) / 2,
    );
    final item = SlideItem(
      id: 0,
      kind: SlideItemKind.shape,
      x: 0,
      y: 0,
      w: w,
      h: h,
      paths: paths,
      fill: SlideFill.solid(color.toARGB32()),
      line: SlideLine(width: 1, color: color.toARGB32()),
    );
    paintSlideItem(canvas, item, s, (_) => null);
  }

  @override
  bool shouldRepaint(_PresetPainter old) =>
      old.preset != preset || old.color != color;
}
