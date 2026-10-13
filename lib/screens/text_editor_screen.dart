import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/public_pdf_save_service.dart';
import '../services/recent_files_service.dart';
import '../utils/format_utils.dart';

/// Opens, edits and saves a plain-text file through the text engine
/// (`flutter_text_core`).
///
/// The engine keeps the file's encoding, byte-order mark and line endings,
/// so saving changes only what was edited. Files too large to edit
/// comfortably on a phone open read-only, a page of lines at a time.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  /// Bigger files (in UTF-16 code units) open read-only: a text field
  /// re-lays out all of its text on every keystroke.
  static const int editableLimit = 300000;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

enum _UnsavedChoice { save, discard }

enum _EncodingChoice { utf8, saveAnyway }

class _TextEditorScreenState extends State<TextEditorScreen> {
  static const _fontSizeKey = 'textEditor.fontSize';
  static const _pageSize = 200;
  static const Color _accent = Color(0xFF78909C);

  TextDocument? _doc;
  TextFileInfo? _info;
  String? _error;
  bool _loading = true;
  late String _workingPath = widget.path;

  final _controller = _MatchHighlightController();
  final _undo = UndoHistoryController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String _lastText = '';

  /// Edits not yet saved to the file.
  bool _dirty = false;

  /// The text field holds edits the engine has not seen yet.
  bool _engineStale = false;

  /// A large file, shown read-only by line.
  bool _readOnly = false;
  bool _saving = false;
  double _fontSize = 16;

  bool _searchOpen = false;
  bool _replaceOpen = false;
  bool _matchCase = false;
  bool _wholeWord = false;
  final _queryController = TextEditingController();
  final _replaceController = TextEditingController();
  List<TextMatch> _matches = const [];
  int _current = -1;
  Timer? _searchDebounce;

  final Map<int, List<String>> _pages = {};
  final _lineScroll = ScrollController();

  AppColors _colors = AppColors(false);

  String get _name => widget.title ?? documentDisplayName(widget.path);

  bool get _monospace {
    const prose = {'txt', 'text', 'md', 'markdown', 'srt', 'vtt', 'nfo'};
    return !prose.contains(DocKind.extensionOf(widget.path));
  }

  @override
  void initState() {
    super.initState();
    _restoreFontSize();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _doc?.close();
    _controller.dispose();
    _undo.dispose();
    _focus.dispose();
    _scroll.dispose();
    _lineScroll.dispose();
    _queryController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<void> _restoreFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final size = prefs.getDouble(_fontSizeKey);
    if (size != null && mounted) setState(() => _fontSize = size);
  }

  Future<void> _load() async {
    try {
      final doc = await TextCore.open(widget.path);
      if (!mounted) {
        doc.close();
        return;
      }
      final info = doc.info(withStats: true);
      _readOnly = (info.length ?? 0) > TextEditorScreen.editableLimit;
      if (!_readOnly) {
        _controller.text = doc.text;
        _lastText = _controller.text;
      }
      _controller.addListener(_onTextChanged);
      setState(() {
        _doc = doc;
        _info = info;
        _loading = false;
      });
    } on TextCoreException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      // A missing or outdated native library fails here (for example a
      // symbol the Dart side expects is absent); say what actually failed.
      if (mounted) {
        setState(() {
          _error = 'The text engine could not start: $e';
          _loading = false;
        });
      }
    }
  }

  void _onTextChanged() {
    final text = _controller.text;
    if (text == _lastText) return; // Only the selection moved.
    _lastText = text;
    _engineStale = true;
    if (!_dirty) setState(() => _dirty = true);
    if (_searchOpen && _queryController.text.isNotEmpty) {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(
        const Duration(milliseconds: 250),
        () => _runSearch(keepPosition: true),
      );
    }
  }

  /// Hand pending edits to the engine.
  void _flush() {
    final doc = _doc;
    if (doc == null || !_engineStale) return;
    doc.setText(_controller.text);
    _engineStale = false;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ saving

  Future<bool> _save() async {
    final doc = _doc;
    if (doc == null || _saving) return false;
    _flush();
    final unmappable = doc.info(withStats: true).unmappable ?? 0;
    if (unmappable > 0) {
      final choice = await _askEncodingProblem(unmappable, doc.info().encoding);
      if (choice == null) return false;
      if (choice == _EncodingChoice.utf8) doc.setFormat(encoding: 'UTF-8');
    }
    if (!mounted) return false;
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() => _saving = true);
    try {
      final target = await DocumentSaveService.workingPathFor(_workingPath);
      await doc.save(target);
      if (target != _workingPath) {
        await RecentFilesService.markOpened(target);
        _workingPath = target;
      }
      if (mounted) setState(() => _dirty = false);
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      _snack(message);
      return true;
    } on TextCoreException catch (e) {
      _snack('Could not save: ${e.message}');
      return false;
    } on PublicPdfSaveException catch (e) {
      // The edits are saved in the app; only the public copy failed.
      _snack(e.message);
      return true;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _info = _doc?.info(withStats: true);
        });
      }
    }
  }

  Future<_EncodingChoice?> _askEncodingProblem(int count, String encoding) {
    return showDialog<_EncodingChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Some characters cannot be saved'),
        content: Text(
          '$count ${count == 1 ? 'character' : 'characters'} in this text '
          'cannot be stored in the $encoding encoding the file uses, and '
          'would be saved as "?".\n\nSave in UTF-8 instead? It keeps every '
          'character, and almost every app reads it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _EncodingChoice.saveAnyway),
            child: const Text('Save anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _EncodingChoice.utf8),
            child: const Text('Use UTF-8'),
          ),
        ],
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
    setState(() => _dirty = false);
    Navigator.of(context).pop();
  }

  Future<void> _share() async {
    final doc = _doc;
    if (doc == null) return;
    _flush();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final file = '${dir.path}/${documentDisplayName(_workingPath)}';
      await doc.writeCopy(file);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file, mimeType: DocKind.mimeTypeOf(file))]),
      );
    } catch (e) {
      _snack('Could not share: $e');
    }
  }

  // ----------------------------------------------------------------- search

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _replaceOpen = false;
        _matches = const [];
        _current = -1;
        _controller.setMatches(const [], -1);
      }
    });
  }

  void _runSearch({bool keepPosition = false}) {
    final doc = _doc;
    final query = _queryController.text;
    if (doc == null) return;
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _current = -1;
      });
      _controller.setMatches(const [], -1);
      return;
    }
    _flush();
    final matches = doc.find(
      query,
      matchCase: _matchCase,
      wholeWord: _wholeWord,
      limit: 5000,
    );
    var current = -1;
    if (matches.isNotEmpty) {
      final from = keepPosition && _current >= 0 && _current < _matches.length
          ? _matches[_current].start
          : (_readOnly ? 0 : _controller.selection.start.clamp(0, 1 << 30));
      current = matches.indexWhere((m) => m.start >= from);
      if (current < 0) current = 0;
    }
    setState(() {
      _matches = matches;
      _current = current;
    });
    _controller.setMatches(_readOnly ? const [] : matches, current);
    if (!keepPosition && current >= 0) _reveal(matches[current]);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    final next = (_current + delta) % _matches.length;
    setState(() => _current = next < 0 ? next + _matches.length : next);
    _controller.setMatches(_readOnly ? const [] : _matches, _current);
    _reveal(_matches[_current]);
  }

  /// Scroll a match into view.
  void _reveal(TextMatch match) {
    if (_readOnly) {
      if (_lineScroll.hasClients) {
        final extent = _lineExtent;
        _lineScroll.animateTo(
          (match.line * extent - 3 * extent).clamp(
            0,
            _lineScroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    // Lay the text out the way the field does to find the match's height.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final width = box.size.width - 32;
    final painter = TextPainter(
      text: TextSpan(text: _controller.text, style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: match.start),
      Rect.zero,
    );
    painter.dispose();
    final target = (caret.dy - _scroll.position.viewportDimension / 3).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _replaceCurrent() {
    if (_current < 0 || _current >= _matches.length || _readOnly) return;
    final match = _matches[_current];
    final text = _controller.text;
    final replacement = _replaceController.text;
    _controller.value = TextEditingValue(
      text: text.replaceRange(match.start, match.end, replacement),
      selection: TextSelection.collapsed(
        offset: match.start + replacement.length,
      ),
    );
    _onTextChanged();
    _runSearch(keepPosition: true);
  }

  void _replaceAll() {
    final doc = _doc;
    final query = _queryController.text;
    if (doc == null || query.isEmpty || _readOnly) return;
    _flush();
    final count = doc.replaceAll(
      query,
      _replaceController.text,
      matchCase: _matchCase,
      wholeWord: _wholeWord,
    );
    if (count > 0) {
      _controller.value = TextEditingValue(
        text: doc.text,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _lastText = _controller.text;
      _engineStale = false;
      setState(() => _dirty = true);
    }
    _runSearch(keepPosition: true);
    _snack(count == 1 ? 'Replaced 1 match' : 'Replaced $count matches');
  }

  // ------------------------------------------------------------------ menus

  Future<void> _chooseEncoding() async {
    final doc = _doc;
    final info = _info;
    if (doc == null || info == null) return;
    final reinterpret = info.canReinterpret && !_dirty;
    final encodings = TextCore.encodings();
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(reinterpret ? 'Read the file as' : 'Save the file as'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              reinterpret
                  ? 'If letters look wrong, choose the encoding the file was '
                        'written in.'
                  : 'Choose how the text is stored when you save. UTF-8 '
                        'works almost everywhere.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          for (final e in encodings)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.name),
              child: Row(
                children: [
                  Icon(
                    e.name == info.encoding
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(e.name)),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == info.encoding) return;
    try {
      if (reinterpret) {
        doc.reinterpret(chosen);
        if (!_readOnly) {
          _controller.removeListener(_onTextChanged);
          _controller.text = doc.text;
          _lastText = _controller.text;
          _controller.addListener(_onTextChanged);
        }
        _pages.clear();
      } else {
        doc.setFormat(encoding: chosen);
        _dirty = true;
      }
      setState(() => _info = doc.info(withStats: true));
    } on TextCoreException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _chooseLineEnding() async {
    final doc = _doc;
    final info = _info;
    if (doc == null || info == null) return;
    final chosen = await showDialog<LineEnding>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Line endings'),
        children: [
          for (final ending in LineEnding.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ending),
              child: Row(
                children: [
                  Icon(
                    ending == info.lineEnding
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(ending.label)),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == info.lineEnding) return;
    doc.setFormat(lineEnding: chosen);
    setState(() {
      _dirty = true;
      _info = doc.info(withStats: true);
    });
  }

  Future<void> _chooseFontSize() async {
    var size = _fontSize;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Text size'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sample text', style: TextStyle(fontSize: size)),
              Slider(
                value: size,
                min: 12,
                max: 32,
                divisions: 10,
                label: size.round().toString(),
                onChanged: (v) {
                  setLocal(() => size = v);
                  setState(() => _fontSize = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, _fontSize);
  }

  void _formatJson() {
    if (_readOnly) return;
    try {
      final formatted = TextCore.formatJson(_controller.text);
      _controller.value = TextEditingValue(
        text: formatted,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _onTextChanged();
      _snack('Formatted');
    } on TextCoreException catch (e) {
      _snack('Not valid JSON: ${e.message}');
    }
  }

  Future<void> _showInfo() async {
    _flush();
    final info = _doc?.info(withStats: true);
    if (info == null) return;
    int? size;
    try {
      size = await File(_workingPath).length();
    } catch (_) {}
    if (!mounted) return;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: _colors.textTertiary,
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(value, style: TextStyle(color: _colors.textSecondary)),
        ],
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(_name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(
              'Encoding',
              info.bom ? '${info.encoding} with BOM' : info.encoding,
            ),
            row('Line endings', info.lineEnding.label),
            row('Lines', formatCount(info.lines)),
            if (info.words != null) row('Words', formatCount(info.words!)),
            if (info.characters != null)
              row('Characters', formatCount(info.characters!)),
            if (size != null) row('Size', formatFileSize(size)),
            row('Location', _workingPath),
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

  // ------------------------------------------------------------------ build

  TextStyle get _textStyle => TextStyle(
    fontSize: _fontSize,
    height: 1.45,
    color: _colors.textPrimary,
    fontFamily: _monospace ? 'monospace' : null,
  );

  double get _lineExtent => (_fontSize * 1.45).ceilToDouble() + 2;

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onWillLeave();
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
            info.encoding,
            info.lineEnding.code,
            if (_readOnly) 'Read-only',
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
        if (!_readOnly)
          TextButton(
            onPressed: _dirty && !_saving ? _save : null,
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
            'share' => _share(),
            'encoding' => _chooseEncoding(),
            'endings' => _chooseLineEnding(),
            'size' => _chooseFontSize(),
            'json' => _formatJson(),
            'info' => _showInfo(),
            _ => null,
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'share', child: Text('Share')),
            PopupMenuItem(
              value: 'encoding',
              child: Text(
                (_info?.canReinterpret ?? false) && !_dirty
                    ? 'Fix garbled text (encoding)'
                    : 'Encoding',
              ),
            ),
            if (!_readOnly)
              const PopupMenuItem(
                value: 'endings',
                child: Text('Line endings'),
              ),
            const PopupMenuItem(value: 'size', child: Text('Text size')),
            if (!_readOnly && DocKind.extensionOf(widget.path) == 'json')
              const PopupMenuItem(value: 'json', child: Text('Format JSON')),
            const PopupMenuItem(value: 'info', child: Text('File info')),
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
    final info = _info!;
    return Column(
      children: [
        if (_searchOpen) _buildSearchBar(),
        if (info.binary)
          _notice(
            Icons.warning_amber_rounded,
            'This file may not be text. Saving it here could damage it.',
          )
        else if (_readOnly)
          _notice(
            Icons.lock_outline_rounded,
            'This file is large (${formatCount(info.lines)} lines), so it '
            'opens read-only.',
          )
        else if (info.decodeErrors > 0 || !info.confident)
          _notice(
            Icons.translate_rounded,
            info.decodeErrors > 0
                ? 'Some characters could not be read. If letters look '
                      'wrong, use "Fix garbled text" in the menu.'
                : 'The encoding (${info.encoding}) was a guess. If letters '
                      'look wrong, use "Fix garbled text" in the menu.',
          ),
        Expanded(child: _readOnly ? _buildLines(info) : _buildEditor()),
        _buildToolbar(),
      ],
    );
  }

  /// Undo, redo and find, at the bottom where a thumb reaches them, and
  /// above the keyboard while typing. The title bar keeps the room it needs
  /// for the file's name.
  Widget _buildToolbar() {
    Widget undoButton(bool redo) => ValueListenableBuilder<UndoHistoryValue>(
      valueListenable: _undo,
      builder: (_, value, _) => IconButton(
        tooltip: redo ? 'Redo' : 'Undo',
        icon: Icon(redo ? Icons.redo_rounded : Icons.undo_rounded),
        onPressed: (redo ? value.canRedo : value.canUndo)
            ? (redo ? _undo.redo : _undo.undo)
            : null,
      ),
    );
    return Material(
      color: _colors.cardBackground,
      elevation: 3,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 4),
            if (!_readOnly) ...[undoButton(false), undoButton(true)],
            const Spacer(),
            IconButton(
              tooltip: _searchOpen ? 'Close find' : 'Find',
              icon: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
              ),
              onPressed: _toggleSearch,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _notice(IconData icon, String text) {
    return Container(
      width: double.infinity,
      color: Colors.amber.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.amber.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: _colors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          undoController: _undo,
          // A new, empty file is for typing into: start with the keyboard.
          autofocus: _lastText.isEmpty,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: _textStyle,
          cursorColor: _colors.accent,
          decoration: InputDecoration.collapsed(
            hintText: 'Start typing',
            hintStyle: TextStyle(color: _colors.textTertiary),
          ),
        ),
      ),
    );
  }

  List<String>? _page(int index) {
    final cached = _pages[index];
    if (cached != null) return cached;
    final doc = _doc;
    if (doc == null) return null;
    final lines = doc.lines(index * _pageSize, _pageSize);
    if (_pages.length > 50) _pages.remove(_pages.keys.first);
    return _pages[index] = lines;
  }

  Widget _buildLines(TextFileInfo info) {
    final current = _current >= 0 && _current < _matches.length
        ? _matches[_current].line
        : -1;
    return Scrollbar(
      controller: _lineScroll,
      child: ListView.builder(
        controller: _lineScroll,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
        itemExtent: _lineExtent,
        itemCount: info.lines,
        itemBuilder: (context, index) {
          final page = _page(index ~/ _pageSize);
          final line = page == null || index % _pageSize >= page.length
              ? ''
              : page[index % _pageSize];
          return GestureDetector(
            onLongPress: () => _showLine(index + 1, line),
            child: Container(
              color: index == current
                  ? Colors.orange.withValues(alpha: 0.25)
                  : null,
              child: Text(
                line,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: _textStyle,
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showLine(int number, String line) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Line $number'),
        content: SingleChildScrollView(
          child: SelectableText(line, style: _textStyle),
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

  Widget _buildSearchBar() {
    final count = _matches.isEmpty
        ? (_queryController.text.isEmpty ? '' : 'No matches')
        : '${_current + 1} of ${_matches.length}';
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
                    controller: _queryController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: field('Find'),
                    onChanged: (_) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 200),
                        _runSearch,
                      );
                    },
                    onSubmitted: (_) => _step(1),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  count,
                  style: TextStyle(color: _colors.textTertiary, fontSize: 12),
                ),
                IconButton(
                  tooltip: 'Previous match',
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  onPressed: _matches.isEmpty ? null : () => _step(-1),
                ),
                IconButton(
                  tooltip: 'Next match',
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: _matches.isEmpty ? null : () => _step(1),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Find options',
                  icon: const Icon(Icons.tune_rounded),
                  onSelected: (value) {
                    setState(() {
                      if (value == 'case') _matchCase = !_matchCase;
                      if (value == 'word') _wholeWord = !_wholeWord;
                      if (value == 'replace') _replaceOpen = !_replaceOpen;
                    });
                    if (value != 'replace') _runSearch();
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'case',
                      checked: _matchCase,
                      child: const Text('Match case'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'word',
                      checked: _wholeWord,
                      child: const Text('Whole words'),
                    ),
                    if (!_readOnly)
                      CheckedPopupMenuItem(
                        value: 'replace',
                        checked: _replaceOpen,
                        child: const Text('Replace'),
                      ),
                  ],
                ),
              ],
            ),
            if (_replaceOpen && !_readOnly) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replaceController,
                      decoration: field('Replace with'),
                    ),
                  ),
                  TextButton(
                    onPressed: _matches.isEmpty ? null : _replaceCurrent,
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    onPressed: _matches.isEmpty ? null : _replaceAll,
                    child: const Text('All'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A text controller that paints search matches behind the text.
class _MatchHighlightController extends TextEditingController {
  List<TextMatch> _matches = const [];
  int _current = -1;

  void setMatches(List<TextMatch> matches, int current) {
    _matches = matches;
    _current = current;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = value.isComposingRangeValid && withComposing;
    if (_matches.isEmpty || composing) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final text = value.text;
    final spans = <TextSpan>[];
    var at = 0;
    for (var i = 0; i < _matches.length; i++) {
      final match = _matches[i];
      if (match.start < at || match.end > text.length) continue;
      if (match.start > at) {
        spans.add(TextSpan(text: text.substring(at, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: i == _current
                ? Colors.orange.withValues(alpha: 0.55)
                : Colors.yellow.withValues(alpha: 0.45),
          ),
        ),
      );
      at = match.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}
