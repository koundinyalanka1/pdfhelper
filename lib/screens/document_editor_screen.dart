import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_word_core/flutter_word_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/editor_draft.dart';
import '../services/export_fonts.dart';
import '../services/public_pdf_save_service.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../utils/format_utils.dart';
import '../utils/readable_color.dart';
import '../widgets/word/doc_blocks.dart';
import '../widgets/word/doc_style.dart';
import '../widgets/word/para_controller.dart';
import 'pdf_viewer_screen.dart';

/// Opens, edits and saves a Word document through the word-processing
/// engine (`flutter_word_core`).
///
/// The text reflows to the screen like a phone word processor's mobile
/// view. Tapping a paragraph edits it; everything the engine does not show
/// (headers, footers, comments, shapes, fields) stays in the file as it was.
class DocumentEditorScreen extends StatefulWidget {
  const DocumentEditorScreen({
    super.key,
    required this.path,
    this.title,
    this.isNew = false,
  });

  /// The file. For a new document, where its first save goes.
  final String path;
  final String? title;

  /// Start a new, empty document instead of reading [path].
  final bool isNew;

  @override
  State<DocumentEditorScreen> createState() => _DocumentEditorScreenState();
}

enum _UnsavedChoice { save, discard }

class _DocumentEditorScreenState extends State<DocumentEditorScreen> {
  static const Color _accent = Color(0xFF2B579A);

  /// Word's dark blue reads on white but not on the dark theme's cards:
  /// toolbar toggles there use a lighter shade of it.
  Color get _accentOnCard =>
      readableOn(_accent, _colors.cardBackground, minRatio: 3);

  /// A colour button's icon whose bar shows [swatch] (the current text or
  /// highlight colour), outlined so black and white show on either theme.
  Widget _swatchIcon(IconData icon, Color? swatch) => SizedBox.square(
    dimension: 24,
    child: Stack(
      children: [
        Icon(icon, color: _colors.textPrimary),
        if (swatch != null)
          Positioned(
            left: 1,
            right: 1,
            bottom: 0,
            height: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: swatch,
                border: Border.all(color: _colors.swatchBorder),
              ),
            ),
          ),
      ],
    ),
  );
  static const int _window = 40;

  WordDocument? _doc;
  WordDocInfo? _info;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  /// A long engine call (find, replace all, undo...) is running on a
  /// background isolate; the document waits for it.
  bool _busy = false;
  late String _workingPath = widget.path;
  late bool _neverSaved = widget.isNew;

  /// Recovery copies of unsaved changes.
  EditorDraft _draft = EditorDraft.none;

  /// Opened from a recovery copy: unsaved until the next save.
  bool _restored = false;
  AppColors _colors = AppColors(false);
  double _zoom = 1;

  /// Blocks fetched so far, by index in the body.
  final Map<int, DocBlock> _blocks = {};
  int _count = 0;

  /// The paragraph being edited.
  int? _activeId;
  ParaController? _ctrl;
  final FocusNode _focus = FocusNode();
  Timer? _commitTimer;

  /// Keys of shown paragraphs' text, to find where a tap landed.
  final Map<int, GlobalKey> _textKeys = {};

  /// Keys of shown blocks, to scroll to them.
  final Map<int, GlobalKey> _blockKeys = {};
  final ScrollController _scroll = ScrollController();

  final Map<int, File?> _images = {};
  Directory? _imageDir;

  bool _findOpen = false;
  final _findController = TextEditingController();
  final _replaceController = TextEditingController();
  List<WordMatch> _matches = const [];
  int _matchIndex = -1;
  bool _matchCase = false;

  DocLook get _look => DocLook(scale: 1.3 * _zoom);
  String get _name => widget.title ?? documentDisplayName(widget.path);
  bool get _dirty =>
      (_info?.modified ?? false) || (_ctrl?.dirty ?? false) || _restored;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _draft.close();
    _doc?.close();
    _ctrl?.dispose();
    _focus.dispose();
    _scroll.dispose();
    _findController.dispose();
    _replaceController.dispose();
    final dir = _imageDir;
    if (dir != null) {
      unawaited(dir.delete(recursive: true).catchError((_) => dir));
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final found = widget.isNew
          ? null
          : await EditorDraft.find(widget.path, DocKind.word);
      var restore = false;
      if (found != null) {
        if (!mounted) return;
        restore = await EditorDraft.askRestore(context, found, _name);
      }
      final doc = widget.isNew
          ? WordCore.create()
          : restore
          ? await WordCore.open(
              found!.draft.snapshotPath,
              name: '${DocKind.titleOf(_name)}.${found.draft.document.format}',
            )
          : await WordCore.open(widget.path, name: _name);
      if (!mounted) {
        doc.close();
        return;
      }
      _doc = doc;
      _restored = restore;
      _openedFromDraft = restore;
      _reload(edited: false);
      setState(() => _loading = false);
      final warnings = _info!.warnings;
      if (warnings.isNotEmpty) _snack(warnings.first);
      if (_savesAsNewFile) {
        _snack('This file will be saved as $_saveFormatPhrase.');
      }
      if (widget.isNew) {
        final first = _block(0);
        if (first is ParaBlock) _activate(first);
      } else {
        _startDraft(found, restore);
      }
    } on WordCoreException catch (e) {
      logDocumentError('DocumentEditor.open', e, path: widget.path);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e, stack) {
      logDocumentError(
        'DocumentEditor.open',
        e,
        path: widget.path,
        stack: stack,
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// Forget fetched blocks and read the document's state again; [edited]
  /// when an edit changed it (a recovery copy is written soon after).
  void _reload({bool edited = true}) {
    final doc = _doc;
    if (doc == null) return;
    _blocks.clear();
    _info = doc.info();
    _count = _info!.blockCount;
    if (edited) _draft.changed();
  }

  void _startDraft(DraftRecovery? found, bool restored) {
    const formats = {'docx', 'docm', 'dotx', 'dotm', 'odt', 'ott'};
    final saveFormat = _info!.saveFormat;
    final format = formats.contains(saveFormat) ? saveFormat : 'docx';
    _draft = EditorDraft.start(
      path: widget.path,
      kind: DocKind.word,
      format: format,
      found: found,
      restored: restored,
      writer: (path) async {
        final doc = _doc;
        if (doc == null) throw StateError('The document is closed.');
        await doc.writeCopy(path, format: format);
      },
    );
  }

  DocBlock? _block(int index) {
    final cached = _blocks[index];
    if (cached != null) return cached;
    final doc = _doc;
    if (doc == null || index < 0 || index >= _count) return null;
    final from = index - index % _window;
    final list = doc.blockSummaries(from, _window);
    for (var k = 0; k < list.length; k++) {
      _blocks[from + k] = list[k];
    }
    return _blocks[index];
  }

  /// Run [work] on a background isolate with the busy bar showing. Null
  /// when another call is running or the screen closed meanwhile.
  Future<T?> _whileBusy<T>(Future<T> Function() work) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final result = await work();
      return mounted ? result : null;
    } finally {
      if (mounted) setState(() => _busy = false);
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

  // --------------------------------------------------------------- editing

  /// Write the paragraph being edited into the document.
  bool _commit() {
    _commitTimer?.cancel();
    final c = _ctrl;
    final id = _activeId;
    final doc = _doc;
    if (c == null || id == null || doc == null || !c.dirty) return true;
    try {
      doc.setParagraphs(id, id, [NewParagraph(c.edits)]);
      c.dirty = false;
      _reload();
      return true;
    } on WordCoreException catch (e) {
      logError('DocumentEditor.commit', e);
      _snack(e.message);
      return false;
    }
  }

  /// Whether the app bar last showed the document as edited.
  bool _shownDirty = false;

  void _onTyped() {
    _scheduleCommit();
    // The first change enables Save and marks the title "Edited".
    if (_dirty != _shownDirty) setState(() {});
  }

  void _scheduleCommit() {
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(_commit);
    });
  }

  void _activate(ParaBlock p, {int? cursor, int? selectEnd}) {
    if (!p.editable) {
      _snack(p.lockedReason ?? "This paragraph can't be edited here.");
      return;
    }
    if (_activeId == p.id && _ctrl != null) {
      if (cursor != null) _ctrl!.select(cursor, selectEnd);
      _focus.requestFocus();
      return;
    }
    _commit();
    _ctrl?.dispose();
    final c = ParaController(
      para: p,
      look: _look,
      cursor: cursor,
      onSplit: _onSplit,
      onJoinBack: _onJoinBack,
      onChanged: (_) => _onTyped(),
    );
    if (selectEnd != null && cursor != null) c.select(cursor, selectEnd);
    setState(() {
      _activeId = p.id;
      _ctrl = c;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  /// Stop editing (keeping the edits).
  void _deactivate() {
    _commit();
    _ctrl?.dispose();
    setState(() {
      _ctrl = null;
      _activeId = null;
    });
  }

  /// Edit paragraph [id] again with fresh content from the document.
  void _reactivate(int id, {int? cursor, int? selectEnd}) {
    final p = _doc?.paragraph(id);
    _ctrl?.dispose();
    _ctrl = null;
    _activeId = null;
    if (p != null) _activate(p, cursor: cursor, selectEnd: selectEnd);
  }

  ParaBlock? get _activePara {
    final id = _activeId;
    return id == null ? null : _doc?.paragraph(id);
  }

  void _onSplit(ParaController c) {
    final doc = _doc;
    final id = _activeId;
    if (doc == null || id == null || !identical(c, _ctrl)) return;
    final para = doc.paragraph(id);
    final parts = splitAtNewlines(c.segs);
    // Enter in an empty list item ends the list.
    if (para != null &&
        para.list != null &&
        parts.length == 2 &&
        parts.every((p) => p.isEmpty)) {
      try {
        doc.patch([id], list: 'none');
        _reload();
        setState(() => _reactivate(id, cursor: 0));
      } on WordCoreException catch (e) {
        logError('DocumentEditor.split', e);
        _snack(e.message);
      }
      return;
    }
    // Where the cursor goes: after the last newline before it.
    final cursor = c.modelSelection.start;
    final before = c.plain.substring(0, cursor.clamp(0, c.plain.length));
    final part = '\n'.allMatches(before).length;
    final lastNl = before.lastIndexOf('\n');
    final offset = lastNl < 0 ? cursor : cursor - lastNl - 1;
    final next = para?.style.nextStyle;
    final specs = <NewParagraph>[
      for (var k = 0; k < parts.length; k++)
        NewParagraph(
          editsOf(parts[k]),
          style:
              k > 0 && k == parts.length - 1 && parts[k].isEmpty && next != null
              ? next
              : null,
        ),
    ];
    try {
      final r = doc.setParagraphs(id, id, specs);
      c.dirty = false;
      _reload();
      final target = r.ids[part.clamp(0, r.ids.length - 1)];
      setState(() => _reactivate(target, cursor: offset));
    } on WordCoreException catch (e) {
      logError('DocumentEditor.split', e);
      _snack(e.message);
      setState(() => _reactivate(id));
    }
  }

  /// The paragraph before [id] in the same container, if it is one.
  ParaBlock? _previousSibling(int id) {
    final doc = _doc;
    if (doc == null) return null;
    final index = doc.blockIndex(id);
    if (index == null) return null;
    final block = _block(index);
    if (block is ParaBlock && block.id == id) {
      final prev = _block(index - 1);
      return prev is ParaBlock ? prev : null;
    }
    if (block is TableBlock) {
      ParaBlock? search(List<DocBlock> blocks) {
        for (var k = 0; k < blocks.length; k++) {
          final b = blocks[k];
          if (b is ParaBlock && b.id == id) {
            final prev = k > 0 ? blocks[k - 1] : null;
            return prev is ParaBlock ? prev : null;
          }
          if (b is TableBlock) {
            for (final r in b.rows) {
              for (final cell in r.cells) {
                final found = search(cell.blocks);
                if (found != null) return found;
              }
            }
          }
        }
        return null;
      }

      for (final r in block.rows) {
        for (final cell in r.cells) {
          final found = search(cell.blocks);
          if (found != null) return found;
        }
      }
    }
    return null;
  }

  void _onJoinBack(ParaController c) {
    final doc = _doc;
    final id = _activeId;
    if (doc == null || id == null || !identical(c, _ctrl)) return;
    final para = doc.paragraph(id);
    if (para == null) return;
    // Backspace at the start of a list item first ends the list.
    if (para.list != null) {
      _commit();
      try {
        doc.patch([id], list: 'none');
        _reload();
        setState(() => _reactivate(id, cursor: 0));
      } on WordCoreException catch (e) {
        logError('DocumentEditor.joinBack', e);
        _snack(e.message);
      }
      return;
    }
    final prev = _previousSibling(id);
    if (prev == null) return;
    if (!prev.editable) {
      _snack(prev.lockedReason ?? "The paragraph before can't be edited here.");
      return;
    }
    final prevSegs = segsOf(prev);
    final at = prevSegs.fold<int>(0, (a, s) => a + s.text.length);
    try {
      final r = doc.setParagraphs(prev.id, id, [
        NewParagraph([...editsOf(prevSegs), ...c.edits]),
      ]);
      c.dirty = false;
      _reload();
      setState(() => _reactivate(r.ids.first, cursor: at));
    } on WordCoreException catch (e) {
      logError('DocumentEditor.joinBack', e);
      _snack(e.message);
    }
  }

  /// Enter from the toolbar, for keyboards that show no Enter key: ends
  /// the paragraph at the cursor as a typed newline would.
  void _typeEnter() {
    final c = _ctrl;
    if (c == null) return;
    final sel = c.selection;
    if (!sel.isValid) return;
    c.value = c.value.replaced(sel, '\n');
  }

  void _format(RunStyle Function(RunStyle) change) {
    final c = _ctrl;
    if (c == null) return;
    c.format(change);
    setState(() {});
  }

  void _patch({
    ParaAlign? align,
    String? styleId,
    String? list,
    int? indentSteps,
    LineSpacing? line,
    double? spaceAfter,
  }) {
    final id = _activeId;
    final doc = _doc;
    if (id == null || doc == null) return;
    final sel = _ctrl?.modelSelection;
    if (!_commit()) return;
    try {
      doc.patch(
        [id],
        align: align,
        styleId: styleId,
        list: list,
        indentSteps: indentSteps,
        line: line,
        spaceAfter: spaceAfter,
      );
      _reload();
      setState(() => _reactivate(id, cursor: sel?.start, selectEnd: sel?.end));
    } on WordCoreException catch (e) {
      logError('DocumentEditor.format', e);
      _snack(e.message);
    }
  }

  Future<void> _undo() => _history(redo: false);

  Future<void> _redo() => _history(redo: true);

  Future<void> _history({required bool redo}) async {
    _commit();
    final doc = _doc;
    if (doc == null) return;
    try {
      final done = await _whileBusy(redo ? doc.redoAsync : doc.undoAsync);
      if (done == null) return;
    } on WordCoreException catch (e) {
      logError(redo ? 'DocumentEditor.redo' : 'DocumentEditor.undo', e);
      _snack(e.message);
      return;
    }
    _ctrl?.dispose();
    setState(() {
      _ctrl = null;
      _activeId = null;
      _reload();
    });
  }

  /// The paragraph new things go after: the one being edited, or the last.
  int? _anchorPara() {
    if (_activeId != null) return _activeId;
    for (var i = _count - 1; i >= 0; i--) {
      final b = _block(i);
      if (b is ParaBlock) return b.id;
    }
    return null;
  }

  Future<void> _insertTable() async {
    final after = _anchorPara();
    if (after == null) return;
    final size = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => const _TableSizeDialog(),
    );
    if (size == null || !mounted) return;
    _commit();
    try {
      final r = _doc!.insertTable(after, size.$1, size.$2);
      _reload();
      _ctrl?.dispose();
      _ctrl = null;
      _activeId = null;
      setState(() {});
      if (r.ids.isNotEmpty) {
        final p = _doc!.paragraph(r.ids.first);
        if (p != null) _activate(p);
      }
    } on WordCoreException catch (e) {
      logError('DocumentEditor.insertTable', e);
      _snack(e.message);
    }
  }

  void _insertPageBreak() {
    final after = _anchorPara();
    if (after == null) return;
    _commit();
    try {
      _doc!.insertPageBreak(after);
      _reload();
      setState(() {});
    } on WordCoreException catch (e) {
      logError('DocumentEditor.insertPageBreak', e);
      _snack(e.message);
    }
  }

  Future<void> _insertPicture() async {
    final after = _anchorPara();
    if (after == null) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    try {
      final bytes = await picked.readAsBytes();
      // The size comes from the header; only a conversion decodes pixels.
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      var ext = picked.name.split('.').last.toLowerCase();
      var path = picked.path;
      try {
        if (!const ['png', 'jpg', 'jpeg', 'gif', 'bmp'].contains(ext)) {
          // HEIC, WebP...: Word wants PNG or JPEG.
          final codec = await descriptor.instantiateCodec();
          final image = (await codec.getNextFrame()).image;
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          codec.dispose();
          final dir = await getTemporaryDirectory();
          path =
              '${dir.path}/picture_${DateTime.now().millisecondsSinceEpoch}.png';
          await File(path).writeAsBytes(png!.buffer.asUint8List());
          ext = 'png';
        }
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
      final page = _info!.page;
      var w = width * 0.75;
      var h = height * 0.75;
      final maxW = page.textWidth;
      if (w > maxW) {
        h = h * maxW / w;
        w = maxW;
      }
      if (!mounted) return;
      _commit();
      _doc!.insertImage(after, path, w, h);
      _reload();
      setState(() {});
    } on WordCoreException catch (e) {
      logError('DocumentEditor.insertPicture', e);
      _snack(e.message);
    } catch (e, stack) {
      logError('DocumentEditor.insertPicture', e, stack);
      _snack('Could not add the picture: $e');
    }
  }

  Future<void> _editLink() async {
    final c = _ctrl;
    if (c == null) return;
    final sel = c.modelSelection;
    final existing = c.currentLink;
    final url = TextEditingController(text: existing ?? 'https://');
    final text = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add a link' : 'Edit link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sel.isCollapsed)
              TextField(
                controller: text,
                decoration: const InputDecoration(labelText: 'Text to show'),
              ),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Web address'),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Remove link'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, url.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    final shown = text.text;
    url.dispose();
    text.dispose();
    if (result == null || !mounted) return;
    c.setLink(
      result.isEmpty ? null : result,
      text: shown.isEmpty ? result : shown,
    );
    setState(() {});
  }

  Future<void> _tableMenu(TableBlock table, int row, int col) async {
    _commit();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, icon, label) in const [
              ('rowAbove', Icons.keyboard_arrow_up, 'Insert row above'),
              ('rowBelow', Icons.keyboard_arrow_down, 'Insert row below'),
              ('colLeft', Icons.keyboard_arrow_left, 'Insert column left'),
              ('colRight', Icons.keyboard_arrow_right, 'Insert column right'),
              ('delRow', Icons.remove, 'Delete row'),
              ('delCol', Icons.remove_circle_outline, 'Delete column'),
              ('delTable', Icons.delete_outline, 'Delete table'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(ctx, value),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final doc = _doc!;
    try {
      switch (action) {
        case 'rowAbove':
          doc.tableOp(table.id, 'insertRow', row);
        case 'rowBelow':
          doc.tableOp(table.id, 'insertRow', row, after: true);
        case 'colLeft':
          doc.tableOp(table.id, 'insertCol', col);
        case 'colRight':
          doc.tableOp(table.id, 'insertCol', col, after: true);
        case 'delRow':
          doc.tableOp(table.id, 'deleteRow', row);
        case 'delCol':
          doc.tableOp(table.id, 'deleteCol', col);
        case 'delTable':
          doc.deleteBlock(table.id);
      }
      _ctrl?.dispose();
      setState(() {
        _ctrl = null;
        _activeId = null;
        _reload();
      });
    } on WordCoreException catch (e) {
      logError('DocumentEditor.tableMenu', e);
      _snack(e.message);
    }
  }

  // ------------------------------------------------------------------ find

  Future<void> _runFind() async {
    final doc = _doc;
    final q = _findController.text;
    if (doc == null) return;
    _commit();
    List<WordMatch> matches = const [];
    if (q.isNotEmpty) {
      try {
        final found = await _whileBusy(
          () => doc.findAsync(q, matchCase: _matchCase),
        );
        if (found == null) return;
        matches = found;
      } on WordCoreException catch (e) {
        logError('DocumentEditor.find', e);
        _snack(e.message);
        return;
      }
    }
    setState(() {
      _matches = matches;
      _matchIndex = _matches.isEmpty ? -1 : 0;
    });
    if (_matches.isNotEmpty) _showMatch();
  }

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + delta) % _matches.length);
    _showMatch();
  }

  void _showMatch() {
    final m = _matches[_matchIndex];
    final index = _doc?.blockIndex(m.para);
    if (index != null) _scrollTo(index);
  }

  void _replaceOne() {
    if (_matchIndex < 0 || _matchIndex >= _matches.length) return;
    final m = _matches[_matchIndex];
    final p = _doc?.paragraph(m.para);
    if (p == null) return;
    _activate(
      p,
      cursor: _viewToModel(p, m.start),
      selectEnd: _viewToModel(p, m.start + m.length),
    );
    final c = _ctrl;
    if (c == null || _activeId != m.para) return;
    c.insertText(_replaceController.text);
    _commit();
    _runFind();
  }

  Future<void> _replaceAll() async {
    final doc = _doc;
    if (doc == null || _findController.text.isEmpty) return;
    _commit();
    try {
      final r = await _whileBusy(
        () => doc.replaceAllAsync(
          _findController.text,
          _replaceController.text,
          matchCase: _matchCase,
        ),
      );
      if (r == null) return;
      _ctrl?.dispose();
      setState(() {
        _ctrl = null;
        _activeId = null;
        _reload();
        _matches = const [];
        _matchIndex = -1;
      });
      _snack(r.count == 1 ? 'Replaced 1 time' : 'Replaced ${r.count} times');
    } on WordCoreException catch (e) {
      logError('DocumentEditor.replaceAll', e);
      _snack(e.message);
    }
  }

  void _scrollTo(int index, [int attempt = 0]) {
    final key = _blockKeys[index];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.2,
        duration: const Duration(milliseconds: 250),
      );
      return;
    }
    if (attempt > 3 || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final double per = _count == 0
        ? 0
        : (pos.maxScrollExtent + pos.viewportDimension) / _count;
    _scroll.jumpTo((index * per).clamp(0.0, pos.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollTo(index, attempt + 1);
    });
  }

  // ---------------------------------------------------------------- images

  File? _imageFor(DocObject o) {
    if (_images.containsKey(o.id)) return _images[o.id];
    _images[o.id] = null;
    unawaited(_loadImage(o.id));
    return null;
  }

  Future<void> _loadImage(int id) async {
    final doc = _doc;
    if (doc == null) return;
    try {
      final dir = _imageDir ??= await Directory(
        '${(await getTemporaryDirectory()).path}/doc_images_${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final path = '${dir.path}/$id';
      final ext = await doc.saveImageAsync(id, path);
      if (!const ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext)) {
        return;
      }
      if (mounted) setState(() => _images[id] = File(path));
    } catch (e, stack) {
      logError('DocumentEditor.loadImage', e, stack);
      // Shown as a placeholder.
    }
  }

  // ---------------------------------------------------------------- saving

  /// Save, clearing the recovery copy once the file is written.
  Future<bool> _save() async {
    if (_doc == null || _saving) return false;
    if (!_commit()) return false;
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() => _saving = true);
    try {
      return await _draft.save(() => _saveNow(location));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveNow(String location) async {
    final doc = _doc;
    if (doc == null) return false;
    try {
      final target = _savesAsNewFile
          ? _convertedPath ??= await _newCopyPath()
          : _neverSaved
          ? _workingPath
          : await DocumentSaveService.workingPathFor(_workingPath);
      await doc.save(target);
      _neverSaved = false;
      _restored = false;
      _workingPath = target;
      await RecentFilesService.markOpened(target);
      _reload(edited: false);
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      _snack(message);
      return true;
    } on WordCoreException catch (e) {
      logDocumentError('DocumentEditor.save', e, path: _workingPath);
      _snack('Could not save: ${e.message}');
      return false;
    } on PublicPdfSaveException catch (e) {
      logError('DocumentEditor.publicCopy', e);
      _snack(e.message);
      return true;
    }
  }

  /// Whether saving writes a new file instead of the one opened: formats
  /// the engine reads but cannot write back (RTF, text, Word 97-2003, WPS)
  /// are saved as Word documents, and flat OpenDocument texts (`.fodt`) as
  /// packaged ones (`.odt`). A `.fodt` file is never written to, whatever
  /// the engine found in it.
  bool get _savesAsNewFile =>
      !_info!.writesBack ||
      !_sourceWritesBack ||
      DocKind.extensionOf(widget.path) == 'fodt';

  /// Whether the file opened can be written back. A recovery copy is
  /// always a Word or OpenDocument file, so for one restored this goes by
  /// the original's extension: an RTF or Word 97 original is never
  /// overwritten with a restored copy.
  bool get _sourceWritesBack =>
      !_openedFromDraft ||
      const {'docx', 'docm', 'dotx', 'dotm', 'odt', 'ott'}.contains(
        DocKind.extensionOf(widget.path),
      );
  bool _openedFromDraft = false;

  /// Whether saving writes OpenDocument text rather than Word.
  bool get _savesOpenDocument =>
      const {'odt', 'ott'}.contains(_info!.saveFormat);

  /// What saving writes, for messages: "a Word document (.docx)".
  String get _saveFormatPhrase => _savesOpenDocument
      ? 'an OpenDocument text file (.${_info!.saveFormat})'
      : 'a Word document (.${_info!.saveFormat})';

  /// Where a document that is not written back is saved: a new file in
  /// the app's storage, in the engine's save format, which then gets its
  /// public copy.
  String? _convertedPath;

  Future<String> _newCopyPath() async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/Edited',
    );
    await dir.create(recursive: true);
    final title = DocKind.titleOf(documentDisplayName(_workingPath));
    final extension = _info!.saveFormat;
    var file = File('${dir.path}/$title.$extension');
    for (var n = 2; await file.exists(); n++) {
      file = File('${dir.path}/$title ($n).$extension');
    }
    return file.path;
  }

  /// Write a copy as `txt`, `pdf` or the document's own format.
  Future<void> _writeAs(WordDocument doc, String file, String format) async {
    if (format == 'pdf') {
      await doc.exportPdf(
        file,
        fontDirs: exportFontDirs(),
        title: DocKind.titleOf(documentDisplayName(_workingPath)),
      );
    } else {
      await doc.writeCopy(file, format: format == 'txt' ? 'txt' : null);
    }
  }

  /// The document laid out on pages, shown in the PDF viewer.
  Future<void> _pageView() async {
    final doc = _doc;
    if (doc == null) return;
    _commit();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/pageview');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final file = '${dir.path}/$title.pdf';
      await _writeAs(doc, file, 'pdf');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfViewerScreen(
            pdfPath: file,
            title: '$title (page view)',
            recordRecent: false,
          ),
        ),
      );
    } catch (e, stack) {
      logError('DocumentEditor.pageView', e, stack);
      _snack('Could not lay out the pages: $e');
    }
  }

  Future<void> _share({String? format}) async {
    final doc = _doc;
    if (doc == null) return;
    _commit();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final ext = format ?? _info!.saveFormat;
      final file = '${dir.path}/$title.$ext';
      await _writeAs(doc, file, ext);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file, mimeType: DocKind.mimeTypeOf(file))]),
      );
    } catch (e, stack) {
      logError('DocumentEditor.share', e, stack);
      _snack('Could not share: $e');
    }
  }

  Future<void> _saveCopyAs() async {
    final doc = _doc;
    if (doc == null) return;
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
              leading: const Icon(Icons.description_outlined),
              title: Text(
                _savesOpenDocument
                    ? 'OpenDocument text (.${_info!.saveFormat})'
                    : 'Word document (.${_info!.saveFormat})',
              ),
              onTap: () => Navigator.pop(ctx, _info!.saveFormat),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF (.pdf)'),
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.notes_rounded),
              title: const Text('Plain text (.txt)'),
              onTap: () => Navigator.pop(ctx, 'txt'),
            ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    _commit();
    final location = context.read<ThemeProvider>().saveLocation;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/export');
      await dir.create(recursive: true);
      final title = DocKind.titleOf(documentDisplayName(_workingPath));
      final file = '${dir.path}/$title.$format';
      await _writeAs(doc, file, format);
      await PublicPdfSaveService.save(
        sourcePath: file,
        displayName: '$title.$format',
        location: location,
        mimeType: DocKind.mimeTypeOf(file),
      );
      _snack('Saved a copy to $location/DocHelper.');
    } catch (e, stack) {
      logError('DocumentEditor.saveCopyAs', e, stack);
      _snack('Could not save a copy: $e');
    }
  }

  /// A query that can take a while on a long document, off the UI isolate.
  Future<T?> _query<T>(String what, Future<T> Function(WordDocument doc) run) async {
    _commit();
    final doc = _doc;
    if (doc == null) return null;
    try {
      return await _whileBusy(() => run(doc));
    } on WordCoreException catch (e) {
      logError('DocumentEditor.$what', e);
      _snack(e.message);
      return null;
    }
  }

  Future<void> _showCounts() async {
    final c = await _query('counts', (doc) => doc.countsAsync());
    if (c == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Word count'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in [
              ('Words', c.words),
              ('Characters', c.characters),
              ('Characters without spaces', c.charactersNoSpaces),
              ('Paragraphs', c.paragraphs),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(label)),
                    Text(
                      '$value',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showOutline() async {
    final headings = await _query('outline', (doc) => doc.outlineAsync());
    if (headings == null || !mounted) return;
    if (headings.isEmpty) {
      _snack('This document has no headings.');
      return;
    }
    final id = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          children: [
            const ListTile(
              title: Text(
                'Headings',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final h in headings)
              ListTile(
                contentPadding: EdgeInsets.only(
                  left: 16.0 + h.level * 16,
                  right: 16,
                ),
                title: Text(
                  h.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, h.id),
              ),
          ],
        ),
      ),
    );
    if (id == null) return;
    final index = _doc?.blockIndex(id);
    if (index != null) _scrollTo(index);
  }

  Future<void> _copyAll() async {
    final text = await _query('plainText', (doc) => doc.plainTextAsync());
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Copied the whole text');
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
    if (choice == _UnsavedChoice.discard) await _draft.discard();
    if (!mounted) return;
    _info = null;
    _restored = false;
    _ctrl?.dirty = false;
    setState(() {});
    Navigator.of(context).pop();
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      canPop: !_dirty && !_findOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_findOpen) {
          setState(() {
            _findOpen = false;
            _matches = const [];
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
    _shownDirty = _dirty;
    final subtitle = info == null
        ? null
        : [info.format.toUpperCase(), if (_dirty) 'Edited'].join(' · ');
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
          onPressed: info?.canUndo == true || (_ctrl?.dirty ?? false)
              ? _undo
              : null,
        ),
        IconButton(
          tooltip: 'Redo',
          icon: const Icon(Icons.redo_rounded),
          onPressed: info?.canRedo == true ? _redo : null,
        ),
        TextButton(
          onPressed: (_dirty || _neverSaved) && !_saving && _doc != null
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
          enabled: _doc != null,
          onSelected: (value) => switch (value) {
            'find' => setState(() => _findOpen = !_findOpen),
            'outline' => _showOutline(),
            'count' => _showCounts(),
            'copy' => _copyAll(),
            'pageView' => _pageView(),
            'share' => _share(),
            'sharePdf' => _share(format: 'pdf'),
            'shareText' => _share(format: 'txt'),
            'copyAs' => _saveCopyAs(),
            'zoomIn' => setState(() => _zoom = math.min(_zoom + 0.15, 2.2)),
            'zoomOut' => setState(() => _zoom = math.max(_zoom - 0.15, 0.55)),
            _ => null,
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'find', child: Text('Find and replace')),
            PopupMenuItem(value: 'outline', child: Text('Headings')),
            PopupMenuItem(value: 'count', child: Text('Word count')),
            PopupMenuItem(value: 'copy', child: Text('Copy all text')),
            PopupMenuItem(value: 'pageView', child: Text('Page view')),
            PopupMenuItem(value: 'share', child: Text('Share')),
            PopupMenuItem(value: 'sharePdf', child: Text('Share as PDF')),
            PopupMenuItem(value: 'shareText', child: Text('Share as text')),
            PopupMenuItem(value: 'copyAs', child: Text('Save a copy as…')),
            PopupMenuItem(value: 'zoomIn', child: Text('Larger text')),
            PopupMenuItem(value: 'zoomOut', child: Text('Smaller text')),
          ],
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
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
                style: TextStyle(
                  color: _colors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_findOpen) _buildFindBar(),
        if (_busy)
          const LinearProgressIndicator(
            minHeight: 3,
            color: _accent,
            semanticsLabel: 'Working',
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pageWidth = math.min(constraints.maxWidth, 820.0);
              final textWidth = pageWidth - 32;
              return Semantics(
                label: 'Document',
                hint: _activeId == null ? null : 'Tap to stop editing',
                child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _activeId == null ? null : _deactivate,
                child: ColoredBox(
                  color: DocLook.paper,
                  child: DocLook.onPaper(ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.symmetric(
                      horizontal: math.max(
                        0,
                        (constraints.maxWidth - pageWidth) / 2,
                      ),
                      vertical: 8,
                    ),
                    itemCount: _count + 1,
                    itemBuilder: (context, index) {
                      if (index == _count) return _endSpace(textWidth);
                      final block = _block(index);
                      if (block == null) return const SizedBox(height: 20);
                      final key = _blockKeys.putIfAbsent(index, GlobalKey.new);
                      return Padding(
                        key: key,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildBlock(block, textWidth),
                      );
                    },
                  )),
                ),
                ),
              );
            },
          ),
        ),
        if (_ctrl != null) _buildToolbar(),
      ],
    );
  }

  /// Below the last block: room to tap that starts editing at the end.
  Widget _endSpace(double width) => Semantics(
    button: true,
    label: 'Type at the end of the document',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        for (var i = _count - 1; i >= 0; i--) {
          final b = _block(i);
          if (b is ParaBlock) {
            _activate(
              b,
              cursor: segsOf(b).fold<int>(0, (a, s) => a + s.text.length),
            );
            return;
          }
        }
      },
      child: Container(color: DocLook.paper, height: 160),
    ),
  );

  Widget _buildBlock(DocBlock block, double width) {
    switch (block) {
      case ParaBlock():
        return _buildPara(block, width);
      case TableBlock():
        return DocTableView(
          table: block,
          look: _look,
          width: width,
          buildBlock: _buildBlock,
          onCellLongPress: (r, c) => _tableMenu(block, r, c),
          loadRows: (from, count) =>
              _doc!.tableRowsAsync(block.id, from, count),
          onError: (e, stack) => logError('DocumentEditor.tableRows', e, stack),
        );
      case OtherBlock():
        return DocOtherView(block: block, look: _look);
    }
  }

  List<(int, int)> _hitsFor(int para) => [
    for (final m in _matches)
      if (m.para == para) (m.start, m.length),
  ];

  /// Maps an offset in a paragraph's shown text to one in the text being
  /// edited (objects there are one character).
  int _viewToModel(ParaBlock p, int viewOffset) {
    var view = 0;
    var model = 0;
    for (final i in p.inlines) {
      switch (i) {
        case TextInline(:final text):
          if (viewOffset <= view + text.length) {
            return model + (viewOffset - view);
          }
          view += text.length;
          model += text.length;
        case ObjectInline(:final object):
          final len = switch (object.kind) {
            DocObjectKind.image ||
            DocObjectKind.shape ||
            DocObjectKind.pageBreak ||
            DocObjectKind.columnBreak => 1,
            _ => object.text.length,
          };
          if (viewOffset < view + len) return model;
          view += len;
          model += 1;
      }
    }
    return model;
  }

  Widget _buildPara(ParaBlock p, double width) {
    final c = _ctrl;
    if (p.id == _activeId && c != null) return _buildEditor(p, c, width);
    final textKey = _textKeys.putIfAbsent(p.id, GlobalKey.new);
    (int, int)? current;
    if (_matchIndex >= 0 &&
        _matchIndex < _matches.length &&
        _matches[_matchIndex].para == p.id) {
      final m = _matches[_matchIndex];
      current = (m.start, m.length);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        var cursor = segsOf(p).fold<int>(0, (a, s) => a + s.text.length);
        final ro = textKey.currentContext?.findRenderObject();
        RenderParagraph? rp;
        void find(RenderObject o) {
          if (rp != null) return;
          if (o is RenderParagraph) {
            rp = o;
            return;
          }
          o.visitChildren(find);
        }

        if (ro != null) find(ro);
        final para = rp;
        if (para != null) {
          final local = para.globalToLocal(details.globalPosition);
          var offset = para.getPositionForOffset(local).offset;
          // The first-line indent is a spacer at the start.
          if (p.list == null && p.style.firstLine > 0) {
            offset = math.max(0, offset - 1);
          }
          cursor = _viewToModel(p, offset);
        }
        _activate(p, cursor: cursor);
      },
      child: KeyedSubtree(
        key: textKey,
        child: DocParagraphView(
          para: p,
          look: _look,
          width: width,
          imageFile: _imageFor,
          highlights: _hitsFor(p.id),
          current: current,
        ),
      ),
    );
  }

  Widget _buildEditor(ParaBlock p, ParaController c, double width) {
    final s = p.style;
    final look = _look;
    final pad = look.padding(s, width);
    Widget field = TextField(
      controller: c,
      focusNode: _focus,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      textAlign: look.align(s.align),
      textDirection: s.bidi ? TextDirection.rtl : null,
      style: look.text(s.mark, line: s.line),
      cursorColor: _accent,
      decoration: const InputDecoration.collapsed(hintText: ''),
      onTapOutside: (_) {},
    );
    final label = p.list;
    if (label != null) {
      final labelStyle = look.text(
        label.style.copyWith(size: s.mark.size),
        line: s.line,
      );
      final hanging = math.max(-s.firstLine * look.scale, 0.0);
      final labelWidth = math.max(
        hanging,
        (label.text.length + 1) * labelStyle.fontSize! * 0.6,
      );
      field = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: math.min(labelWidth, width / 3),
            child: Text(label.text, style: labelStyle),
          ),
          Expanded(child: field),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: s.shading == null
            ? const Color(0x0A2B579A)
            : Color(0xFF000000 | s.shading!),
        border: const Border(left: BorderSide(color: _accent, width: 2)),
      ),
      padding: pad,
      child: field,
    );
  }

  Widget _buildFindBar() {
    final count = _matches.isEmpty
        ? ''
        : '${_matchIndex + 1}/${_matches.length}';
    return Material(
      color: _colors.cardBackground,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: _colors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find',
                      hintStyle: TextStyle(color: _colors.textTertiary),
                      suffixText: count,
                    ),
                    onSubmitted: (_) => _runFind(),
                  ),
                ),
                IconButton(
                  tooltip: 'Match case',
                  isSelected: _matchCase,
                  icon: const Icon(Icons.text_fields),
                  color: _matchCase ? _accentOnCard : _colors.textSecondary,
                  onPressed: () {
                    setState(() => _matchCase = !_matchCase);
                    _runFind();
                  },
                ),
                IconButton(
                  tooltip: 'Previous',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: () => _stepMatch(-1),
                ),
                IconButton(
                  tooltip: 'Next',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => _stepMatch(1),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _findOpen = false;
                    _matches = const [];
                    _matchIndex = -1;
                  }),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replaceController,
                    style: TextStyle(color: _colors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Replace with',
                      hintStyle: TextStyle(color: _colors.textTertiary),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _matches.isEmpty ? null : _replaceOne,
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: _findController.text.isEmpty ? null : _replaceAll,
                  child: const Text('All'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- toolbar

  Widget _buildToolbar() {
    final c = _ctrl!;
    return Material(
      color: _colors.cardBackground,
      elevation: 6,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final style = c.currentStyle;
          final para = _blockForActive();
          final pstyle = para?.style;
          Widget toggle(IconData icon, String tip, bool on, VoidCallback tap) =>
              IconButton(
                tooltip: tip,
                isSelected: on,
                icon: Icon(icon),
                color: on ? _accentOnCard : _colors.textPrimary,
                style: on
                    ? IconButton.styleFrom(
                        backgroundColor: _accentOnCard.withValues(alpha: 0.16),
                      )
                    : null,
                onPressed: tap,
              );
          return SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                IconButton(
                  tooltip: 'New paragraph (Enter)',
                  icon: const Icon(Icons.keyboard_return_rounded),
                  onPressed: _typeEnter,
                ),
                _chip(
                  pstyle?.styleName ?? 'Normal',
                  'Paragraph style',
                  _pickStyle,
                ),
                toggle(
                  Icons.format_bold,
                  'Bold',
                  style.bold,
                  () => _format((s) => s.copyWith(bold: !style.bold)),
                ),
                toggle(
                  Icons.format_italic,
                  'Italic',
                  style.italic,
                  () => _format((s) => s.copyWith(italic: !style.italic)),
                ),
                toggle(
                  Icons.format_underline,
                  'Underline',
                  style.underlined,
                  () => _format(
                    (s) => s.copyWith(
                      underline: style.underlined ? 'none' : 'single',
                    ),
                  ),
                ),
                toggle(
                  Icons.format_strikethrough,
                  'Strikethrough',
                  style.strike,
                  () => _format((s) => s.copyWith(strike: !style.strike)),
                ),
                _chip(
                  _sizeLabel(style.size),
                  'Font size',
                  () => _pickSize(style.size),
                ),
                IconButton(
                  tooltip: 'Text colour',
                  icon: _swatchIcon(
                    Icons.format_color_text,
                    style.color == null
                        ? null
                        : Color(0xFF000000 | style.color!),
                  ),
                  onPressed: () => _pickColor(highlight: false),
                ),
                IconButton(
                  tooltip: 'Highlight',
                  icon: _swatchIcon(
                    Icons.format_color_fill,
                    style.highlight == null
                        ? null
                        : Color(0xFF000000 | style.highlight!),
                  ),
                  onPressed: () => _pickColor(highlight: true),
                ),
                IconButton(
                  tooltip: 'Alignment',
                  icon: Icon(switch (pstyle?.align ?? ParaAlign.left) {
                    ParaAlign.center => Icons.format_align_center,
                    ParaAlign.right => Icons.format_align_right,
                    ParaAlign.justify => Icons.format_align_justify,
                    ParaAlign.left => Icons.format_align_left,
                  }),
                  onPressed: () {
                    final next =
                        ParaAlign.values[((pstyle?.align ?? ParaAlign.left)
                                    .index +
                                1) %
                            ParaAlign.values.length];
                    _patch(align: next);
                  },
                ),
                toggle(
                  Icons.format_list_bulleted,
                  'Bullets',
                  para?.list?.bullet == true,
                  () => _patch(
                    list: para?.list?.bullet == true ? 'none' : 'bullet',
                  ),
                ),
                toggle(
                  Icons.format_list_numbered,
                  'Numbering',
                  para?.list != null && para?.list?.bullet == false,
                  () => _patch(
                    list: para?.list != null && para?.list?.bullet == false
                        ? 'none'
                        : 'number',
                  ),
                ),
                IconButton(
                  tooltip: 'Decrease indent',
                  icon: const Icon(Icons.format_indent_decrease),
                  onPressed: () => _patch(indentSteps: -1),
                ),
                IconButton(
                  tooltip: 'Increase indent',
                  icon: const Icon(Icons.format_indent_increase),
                  onPressed: () => _patch(indentSteps: 1),
                ),
                IconButton(
                  tooltip: 'Line spacing',
                  icon: const Icon(Icons.format_line_spacing),
                  onPressed: _pickLineSpacing,
                ),
                IconButton(
                  tooltip: 'Link',
                  icon: const Icon(Icons.link),
                  onPressed: _editLink,
                ),
                IconButton(
                  tooltip: 'Clear formatting',
                  icon: const Icon(Icons.format_clear),
                  onPressed: () {
                    final mark = pstyle?.mark;
                    if (mark != null) _format((_) => mark);
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: 'Insert',
                  icon: const Icon(Icons.add_box_outlined),
                  onSelected: (v) => switch (v) {
                    'table' => _insertTable(),
                    'picture' => _insertPicture(),
                    'break' => _insertPageBreak(),
                    'link' => _editLink(),
                    _ => null,
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'table', child: Text('Table')),
                    PopupMenuItem(value: 'picture', child: Text('Picture')),
                    PopupMenuItem(value: 'break', child: Text('Page break')),
                    PopupMenuItem(value: 'link', child: Text('Link')),
                  ],
                ),
                IconButton(
                  tooltip: 'Done',
                  icon: const Icon(Icons.keyboard_hide_outlined),
                  onPressed: _deactivate,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  ParaBlock? _activeParaCache;

  ParaBlock? _blockForActive() {
    final id = _activeId;
    if (id == null) return null;
    if (_activeParaCache?.id != id || _ctrl?.dirty == false) {
      _activeParaCache = _activePara;
    }
    return _activeParaCache;
  }

  String _sizeLabel(double size) =>
      size == size.roundToDouble() ? '${size.round()}' : '$size';

  Widget _chip(String label, String tooltip, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Center(
      child: ActionChip(
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        tooltip: tooltip,
        onPressed: onTap,
        // A full 48 dp target, though the chip is drawn smaller.
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
  );

  Future<void> _pickStyle() async {
    final styles = _info?.styles ?? const <WordStyleInfo>[];
    final id = await showModalBottomSheet<String>(
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
                'Paragraph style',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final s in styles)
              ListTile(
                title: Text(
                  s.name,
                  style: TextStyle(
                    fontSize: switch (s.outline) {
                      0 => 22,
                      1 => 19,
                      2 => 17,
                      _ => s.name == 'Title' ? 24 : 15,
                    },
                    fontWeight: s.outline != null
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, s.id),
              ),
          ],
        ),
      ),
    );
    if (id != null) _patch(styleId: id);
  }

  Future<void> _pickSize(double current) async {
    final size = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 320,
          child: ListView(
            children: [
              for (final s in docFontSizes)
                ListTile(
                  selected: s == current,
                  title: Text(_sizeLabel(s)),
                  onTap: () => Navigator.pop(ctx, s),
                ),
            ],
          ),
        ),
      ),
    );
    if (size != null) _format((s) => s.copyWith(size: size));
  }

  Future<void> _pickColor({required bool highlight}) async {
    final colors = highlight ? docHighlightColors : docTextColors;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              InkWell(
                onTap: () => Navigator.pop(ctx, -1),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.of(ctx).swatchBorder),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    highlight ? Icons.format_color_reset : Icons.auto_awesome,
                    size: 20,
                  ),
                ),
              ),
              for (final c in colors)
                InkWell(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(0xFF000000 | c),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.of(ctx).swatchBorder),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    final value = picked < 0 ? null : picked;
    _format(
      (s) =>
          highlight ? s.copyWith(highlight: value) : s.copyWith(color: value),
    );
  }

  Future<void> _pickLineSpacing() async {
    final choice = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in const [1.0, 1.15, 1.5, 2.0, 2.5, 3.0])
              ListTile(
                title: Text(v.toString()),
                onTap: () => Navigator.pop(ctx, v),
              ),
            ListTile(
              title: const Text('No space after paragraphs'),
              onTap: () => Navigator.pop(ctx, -1),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice < 0) {
      _patch(spaceAfter: 0);
    } else {
      _patch(line: LineSpacing.multiple(choice));
    }
  }
}

class _TableSizeDialog extends StatefulWidget {
  const _TableSizeDialog();

  @override
  State<_TableSizeDialog> createState() => _TableSizeDialogState();
}

class _TableSizeDialogState extends State<_TableSizeDialog> {
  int _rows = 3;
  int _cols = 3;

  Widget _stepper(String label, int value, ValueChanged<int> set) => Row(
    children: [
      Expanded(child: Text(label)),
      IconButton(
        onPressed: value > 1 ? () => set(value - 1) : null,
        icon: const Icon(Icons.remove),
      ),
      SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.center)),
      IconButton(
        onPressed: value < 30 ? () => set(value + 1) : null,
        icon: const Icon(Icons.add),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Insert a table'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepper('Rows', _rows, (v) => setState(() => _rows = v)),
        _stepper('Columns', _cols, (v) => setState(() => _cols = v)),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (_rows, _cols)),
        child: const Text('Insert'),
      ),
    ],
  );
}
