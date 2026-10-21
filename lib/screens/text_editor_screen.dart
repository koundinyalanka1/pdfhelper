import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/editor_draft.dart';
import '../services/public_pdf_save_service.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../utils/format_utils.dart';
import '../widgets/json_tree_view.dart';
import '../widgets/markup_view.dart';

/// Opens, edits and saves a plain-text file through the text engine
/// (`flutter_text_core`).
///
/// The engine keeps the file's encoding, byte-order mark and line endings,
/// so saving changes only what was edited. Files too large to edit
/// comfortably on a phone open read-only, a page of lines at a time.
///
/// Markdown and HTML files can also be read as a page, and JSON as a tree.
/// Markdown and HTML open that way; a button switches between the preview
/// and the text.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  /// Bigger files (in UTF-16 code units) open read-only: a text field
  /// re-lays out all of its text on every keystroke.
  static const int editableLimit = 300000;

  /// Bigger files (in UTF-16 code units, about 5 MB of text) get no
  /// preview: a page or tree of that much would be slow to build and of
  /// little use on a phone.
  static const int previewLimit = 5000000;

  /// Bigger Markdown files (about 1 MB) get no preview. Markdown is dense:
  /// a megabyte of one-word list items is a quarter of a million of them,
  /// and reading it takes hundreds of megabytes before the engine cuts the
  /// page short. HTML is mostly tags and scripts, and the engine stops
  /// building its tree in time.
  static const int markdownPreviewLimit = 1000000;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

enum _UnsavedChoice { save, discard }

enum _EncodingChoice { utf8, saveAnyway }

/// How a file's text can be shown other than as text.
enum _PreviewKind { markdown, html, json }

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

  /// Recovery copies of unsaved changes.
  EditorDraft _draft = EditorDraft.none;

  /// The text field holds edits the engine has not seen yet.
  bool _engineStale = false;

  /// A large file, shown read-only by line.
  bool _readOnly = false;
  bool _saving = false;
  bool _textEdited = false;
  bool _replacing = false;
  bool _formatting = false;
  bool _searching = false;
  bool _searchAgain = false;
  int _searchRun = 0;
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
  final Set<int> _pagesLoading = {};
  int _pageEpoch = 0;
  final _lineScroll = ScrollController();

  /// A line (0-based) marked in the read-only view by "Go to line".
  int _markedLine = -1;

  /// Counts changes to the text, so the preview is rebuilt only when the
  /// text changed since it was last built.
  int _textVersion = 0;

  /// Showing the preview instead of the text.
  bool _previewing = false;

  /// The [_textVersion] the preview was built from; null when there is no
  /// preview yet, or building it failed.
  int? _previewVersion;

  /// The [_textVersion] the preview is being built from; null when idle.
  int? _parsingVersion;
  bool get _parsing => _parsingVersion != null;

  /// Counts preview builds, so one that finishes after a newer one started
  /// is dropped.
  int _previewRun = 0;
  MarkupDocument? _markup;
  JsonParseResult? _json;
  String? _previewError;

  AppColors _colors = AppColors(false);

  String get _name => widget.title ?? documentDisplayName(widget.path);

  bool get _monospace {
    const prose = {'txt', 'text', 'md', 'markdown', 'srt', 'vtt', 'nfo'};
    return !prose.contains(DocKind.extensionOf(widget.path));
  }

  /// How this file can be previewed, or null when it is plain text.
  late final _PreviewKind? _previewKind = switch (DocKind.extensionOf(
    widget.path,
  )) {
    'md' || 'markdown' => _PreviewKind.markdown,
    'html' || 'htm' => _PreviewKind.html,
    'json' => _PreviewKind.json,
    _ => null,
  };

  /// Whether the preview button is offered for the file as it is now.
  bool get _canPreview {
    final kind = _previewKind;
    final info = _info;
    if (kind == null || info == null || _doc == null) return false;
    // An engine built before Markdown and HTML reading cannot make pages.
    if (kind != _PreviewKind.json && !TextCore.canReadMarkup) return false;
    final length = _readOnly ? (info.length ?? 0) : _controller.text.length;
    return length <=
        (kind == _PreviewKind.markdown
            ? TextEditorScreen.markdownPreviewLimit
            : TextEditorScreen.previewLimit);
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
    _draft.close();
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
    TextDocument? opening;
    try {
      final found = await EditorDraft.find(widget.path, DocKind.text);
      var restore = false;
      if (found != null) {
        if (!mounted) return;
        restore = await EditorDraft.askRestore(context, found, _name);
      }
      final doc = await TextCore.open(
        restore ? found!.draft.snapshotPath : widget.path,
      );
      opening = doc;
      if (!mounted) {
        doc.close();
        return;
      }
      final info = await doc.infoAsync(withStats: true);
      final readOnly = (info.length ?? 0) > TextEditorScreen.editableLimit;
      final text = readOnly ? null : await doc.textAsync();
      if (!mounted) {
        doc.close();
        return;
      }
      _readOnly = readOnly;
      if (text != null) {
        _controller.text = text;
        _lastText = _controller.text;
      }
      _controller.addListener(_onTextChanged);
      setState(() {
        _doc = doc;
        _info = info;
        _loading = false;
        if (restore) {
          _dirty = true;
          _textEdited = true;
        }
      });
      if (!readOnly) {
        _draft = EditorDraft.start(
          path: widget.path,
          kind: DocKind.text,
          format: 'txt',
          found: found,
          restored: restore,
          writer: (path) async {
            final doc = _doc;
            if (doc == null) throw StateError('The file is closed.');
            await _flush();
            await doc.writeCopy(path);
          },
        );
      } else if (found != null && !restore) {
        // Too large to edit here: a copy declined is still removed.
        unawaited(EditorDraft.service.discardRecovery(found.draft).then<void>(
          (_) {},
          onError: (Object e, StackTrace s) => logError('TextEditor.draft', e, s),
        ));
      }
      // Markdown and HTML are mostly read, so they open as a page. An empty
      // file is for typing into, and JSON opens as text, as it always has.
      if (_canPreview &&
          _previewKind != _PreviewKind.json &&
          !info.binary &&
          (_readOnly || _lastText.trim().isNotEmpty)) {
        _togglePreview();
      }
    } on TextCoreException catch (e) {
      logDocumentError('TextEditor.open', e, path: widget.path);
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e, stack) {
      logDocumentError('TextEditor.open', e, path: widget.path, stack: stack);
      // A missing or outdated native library fails here (for example a
      // symbol the Dart side expects is absent); say what actually failed.
      if (mounted) {
        setState(() {
          _error = 'The text engine could not start: $e';
          _loading = false;
        });
      }
    } finally {
      if (opening != _doc) opening?.close();
    }
  }

  void _onTextChanged() {
    final text = _controller.text;
    if (text == _lastText) return; // Only the selection moved.
    _lastText = text;
    _textVersion++;
    _textEdited = true;
    _engineStale = true;
    _searchRun++;
    _draft.changed();
    setState(() {
      _dirty = true;
      _matches = const [];
      _current = -1;
    });
    _controller.setMatches(const [], -1);
    if (_searchOpen && _queryController.text.isNotEmpty) {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(
        const Duration(milliseconds: 250),
        () => _runSearch(keepPosition: true),
      );
    }
  }

  /// Hand pending edits to the engine.
  Future<void> _flush() async {
    final doc = _doc;
    if (doc == null || !_engineStale) return;
    final version = _textVersion;
    await doc.setTextAsync(_controller.text);
    if (version == _textVersion) _engineStale = false;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ saving

  Future<bool> _prepareSave(TextDocument doc) async {
    if (_textEdited && (_info?.mixedLineEndings ?? false)) {
      final ending = await showDialog<LineEnding>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Mixed line endings'),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text('The original line endings are kept until you edit. '
                  'Choose the line endings to use when saving these changes.'),
            ),
            for (final ending in LineEnding.values)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, ending),
                child: Text(ending.label),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (ending == null || !mounted) return false;
      await doc.setFormatAsync(lineEnding: ending);
    }
    await _flush();
    final info = await doc.infoAsync(withStats: true);
    if (!mounted) return false;
    setState(() => _info = info);
    final unmappable = info.unmappable ?? 0;
    if (unmappable > 0) {
      final choice = await _askEncodingProblem(unmappable, info.encoding,
          canUseUtf8: info.decodeErrors == 0);
      if (choice == null || !mounted) return false;
      if (choice == _EncodingChoice.utf8) await doc.setFormatAsync(encoding: 'UTF-8');
    }
    return mounted;
  }

  Future<bool> _save() async {
    if (_doc == null || _saving || _replacing) return false;
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() => _saving = true);
    try {
      return await _draft.save(() => _saveNow(location));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Save, clearing the recovery copy once the file is written.
  Future<bool> _saveNow(String location) async {
    final doc = _doc;
    if (doc == null) return false;
    final version = _textVersion;
    try {
      if (!await _prepareSave(doc)) return false;
      final target = await DocumentSaveService.workingPathFor(_workingPath);
      await doc.save(target);
      if (target != _workingPath) {
        await RecentFilesService.markOpened(target);
        _workingPath = target;
      }
      final info = await doc.infoAsync(withStats: true);
      if (mounted) {
        setState(() {
          _info = info;
          _dirty = version != _textVersion;
          if (!_dirty) _textEdited = false;
        });
      }
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      _snack(message);
      return true;
    } on TextCoreException catch (e) {
      logDocumentError('TextEditor.save', e, path: _workingPath);
      _snack('Could not save: ${e.message}');
      return false;
    } on PublicPdfSaveException catch (e) {
      logError('TextEditor.publicCopy', e);
      // The edits are saved in the app; only the public copy failed.
      _snack(e.message);
      return true;
    } catch (e, stack) {
      logDocumentError('TextEditor.save', e, path: _workingPath, stack: stack);
      _snack('Could not save: $e');
      return false;
    }
  }

  Future<_EncodingChoice?> _askEncodingProblem(int count, String encoding, {bool canUseUtf8 = true}) {
    return showDialog<_EncodingChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Some characters cannot be saved'),
        content: Text(
          '$count ${count == 1 ? 'character' : 'characters'} in this text '
          'cannot be stored in the $encoding encoding the file uses, and '
          'would be saved as "?".\n\n${canUseUtf8 ? 'Save in UTF-8 instead? It keeps every '
          'character, and almost every app reads it.' : 'Unreadable bytes can only be kept in their original encoding. '
          'Cancel to keep editing or choose that encoding before saving.'}',
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
          if (canUseUtf8)
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
    if (choice == _UnsavedChoice.discard) await _draft.discard();
    if (!mounted) return;
    setState(() => _dirty = false);
    Navigator.of(context).pop();
  }

  Future<void> _share() async {
    final doc = _doc;
    if (doc == null || _saving || _replacing) return;
    setState(() => _saving = true);
    try {
      if (!await _prepareSave(doc)) return;
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final file = '${dir.path}/${documentDisplayName(_workingPath)}';
      await doc.writeCopy(file);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file, mimeType: DocKind.mimeTypeOf(file))]),
      );
    } catch (e, stack) {
      logError('TextEditor.share', e, stack);
      _snack('Could not share: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ----------------------------------------------------------------- search

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchRun++;
        _searchAgain = false;
        _searchDebounce?.cancel();
        _replaceOpen = false;
        _matches = const [];
        _current = -1;
        _controller.setMatches(const [], -1);
      }
    });
  }

  Future<void> _runSearch({bool keepPosition = false}) async {
    final doc = _doc;
    if (doc == null || !mounted || !_searchOpen) return;
    final run = ++_searchRun;
    if (_searching) {
      _searchAgain = true;
      return;
    }
    _searchAgain = false;
    final query = _queryController.text;
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _current = -1;
      });
      _controller.setMatches(const [], -1);
      return;
    }
    final version = _textVersion;
    final matchCase = _matchCase;
    final wholeWord = _wholeWord;
    setState(() => _searching = true);
    try {
      await _flush();
      final matches = await doc.findAsync(
        query,
        matchCase: matchCase,
        wholeWord: wholeWord,
        limit: 5000,
      );
      if (!mounted || run != _searchRun || version != _textVersion || !_searchOpen) return;
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
        _markedLine = -1;
      });
      _controller.setMatches(_readOnly ? const [] : matches, current);
      if (!keepPosition && current >= 0) _reveal(matches[current]);
    } catch (e, stack) {
      logDocumentError('TextEditor.find', e, path: _workingPath, stack: stack);
      if (run == _searchRun) _snack('Could not find: $e');
    } finally {
      if (mounted) {
        setState(() => _searching = false);
        if (_searchAgain && _searchOpen) unawaited(_runSearch(keepPosition: keepPosition));
      }
    }
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
      _revealLine(match.line);
    } else {
      _revealOffset(match.start);
    }
  }

  /// Scroll the read-only view to [line] (0-based).
  void _revealLine(int line) {
    if (!_lineScroll.hasClients) return;
    final extent = _lineExtent;
    _lineScroll.animateTo(
      (line * extent - 3 * extent).clamp(
        0,
        _lineScroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Scroll the editor to the text at [offset].
  void _revealOffset(int offset) {
    // Lay the text out the way the field does to find the offset's height.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final width = box.size.width - 32;
    final painter = TextPainter(
      text: TextSpan(text: _controller.text, style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: offset),
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
    if (_current < 0 || _current >= _matches.length || _readOnly || _saving || _replacing || _searching) return;
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

  Future<void> _replaceAll() async {
    final doc = _doc;
    final query = _queryController.text;
    if (doc == null || query.isEmpty || _readOnly || _replacing || _saving) return;
    final version = _textVersion;
    final replacement = _replaceController.text;
    final matchCase = _matchCase;
    final wholeWord = _wholeWord;
    _searchRun++;
    setState(() => _replacing = true);
    try {
      await _flush();
      final count = await doc.replaceAllAsync(
        query,
        replacement,
        matchCase: matchCase,
        wholeWord: wholeWord,
        maxBytes: TextEditorScreen.editableLimit * 4,
      );
      final text = count > 0 ? await doc.textAsync() : null;
      if (!mounted) return;
      if (version != _textVersion) {
        _engineStale = true;
        return;
      }
      if (text != null) {
        _controller.value = TextEditingValue(
          text: text,
          selection: const TextSelection.collapsed(offset: 0),
        );
        _engineStale = false;
      }
      unawaited(_runSearch(keepPosition: true));
      _snack(count == 1 ? 'Replaced 1 match' : 'Replaced $count matches');
    } catch (e, stack) {
      logDocumentError('TextEditor.replaceAll', e, path: _workingPath, stack: stack);
      _snack('Could not replace: $e');
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
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
    if (chosen == null || chosen == info.encoding || !mounted) return;
    try {
      if (reinterpret && !_dirty) {
        _pageEpoch++;
        _pagesLoading.clear();
        await doc.reinterpretAsync(chosen);
        final updated = await doc.infoAsync(withStats: true);
        final readOnly = (updated.length ?? 0) > TextEditorScreen.editableLimit;
        final text = readOnly ? null : await doc.textAsync();
        if (!mounted) return;
        _readOnly = readOnly;
        if (text != null) {
          _controller.removeListener(_onTextChanged);
          _controller.text = text;
          _lastText = _controller.text;
          _controller.addListener(_onTextChanged);
        }
        _pages.clear();
        _pagesLoading.clear();
        _textVersion++;
        _info = updated;
      } else {
        await _flush();
        await doc.setFormatAsync(encoding: chosen);
        final updated = await doc.infoAsync(withStats: true);
        if (!mounted) return;
        _dirty = true;
        _draft.changed();
        _info = updated;
      }
      setState(() {});
      if (_previewing) unawaited(_updatePreview());
    } catch (e, stack) {
      logError('TextEditor.encoding', e, stack);
      _snack(e is TextCoreException ? e.message : '$e');
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
    if (chosen == null || (chosen == info.lineEnding && !info.mixedLineEndings) || !mounted) return;
    try {
      await doc.setFormatAsync(lineEnding: chosen);
      final updated = await doc.infoAsync(withStats: true);
      if (!mounted) return;
      _draft.changed();
      setState(() {
        _dirty = true;
        _info = updated;
      });
    } catch (e, stack) {
      logError('TextEditor.lineEndings', e, stack);
      _snack('Could not change line endings: $e');
    }
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

  Future<void> _formatJson() async {
    if (_readOnly || _formatting || _saving || _replacing) return;
    final text = _controller.text;
    setState(() => _formatting = true);
    try {
      // Off the UI isolate: a large file takes a moment to format.
      final formatted = await TextCore.formatJsonAsync(text);
      // Typing meanwhile wins over the formatted copy of the old text.
      if (!mounted || _controller.text != text) return;
      if (formatted.length > TextEditorScreen.editableLimit * 4) {
        throw TextCoreException('TOO_LARGE', 'The formatted JSON is too large to edit here.');
      }
      _controller.value = TextEditingValue(
        text: formatted,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _onTextChanged();
      _snack('Formatted');
    } on TextCoreException catch (e) {
      logError('TextEditor.formatJson', e);
      _snack(
        e.code == 'TOO_LARGE' ? e.message : 'Not valid JSON: ${e.message}',
      );
    } catch (e, stack) {
      logError('TextEditor.formatJson', e, stack);
      _snack('Could not format JSON: $e');
    } finally {
      if (mounted) setState(() => _formatting = false);
    }
  }

  Future<void> _showInfo() async {
    final doc = _doc;
    if (doc == null) return;
    late final TextFileInfo info;
    try {
      await _flush();
      info = await doc.infoAsync(withStats: true);
    } catch (e, stack) {
      logDocumentError('TextEditor.info', e, path: _workingPath, stack: stack);
      _snack('Could not read file info: $e');
      return;
    }
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
            row('Line endings', info.mixedLineEndings ? 'Mixed (kept until editing)' : info.lineEnding.label),
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

  // ---------------------------------------------------------------- preview

  /// Switch between the text and the preview.
  void _togglePreview() {
    if (_previewing) {
      setState(() => _previewing = false);
      return;
    }
    // Find, the caret and the keyboard belong to the text.
    if (_searchOpen) _toggleSearch();
    _focus.unfocus();
    setState(() => _previewing = true);
    unawaited(_updatePreview());
  }

  /// Build the preview from the text as it is now, unless it was already
  /// built from this text.
  Future<void> _updatePreview() async {
    final kind = _previewKind;
    final doc = _doc;
    if (kind == null || doc == null) return;
    final version = _textVersion;
    if (_previewVersion == version || _parsingVersion == version) return;
    // A large file is not in the text field. Nothing is edited there, so
    // the engine has the text.
    final snapshot = _controller.text;
    final run = ++_previewRun;
    setState(() => _parsingVersion = version);
    MarkupDocument? markup;
    JsonParseResult? json;
    String? error;
    try {
      final text = _readOnly ? await doc.textAsync() : snapshot;
      switch (kind) {
        case _PreviewKind.markdown:
          markup = await TextCore.markdownAsync(text);
        case _PreviewKind.html:
          markup = await TextCore.htmlAsync(text);
        case _PreviewKind.json:
          json = await parseJsonForTree(text);
      }
    } on TextCoreException catch (e) {
      logError('TextEditor.preview', e);
      error = e.message;
    } catch (e, stack) {
      logError('TextEditor.preview', e, stack);
      error = 'The preview could not be made: $e';
    }
    if (!mounted || run != _previewRun) return;
    setState(() {
      _parsingVersion = null;
      _markup = markup;
      _json = json;
      _previewError = error;
      _previewVersion = error == null ? version : null;
    });
  }

  /// Show the text at [line] and [column] (both 1-based), where the JSON
  /// preview found a problem.
  void _goToLine(int line, int column) {
    setState(() {
      _previewing = false;
      if (_readOnly) _markedLine = line - 1;
    });
    if (_readOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealLine(line - 1);
      });
      return;
    }
    final offset = _offsetOf(_controller.text, line, column);
    _controller.selection = TextSelection.collapsed(offset: offset);
    // The field takes focus once it is back on screen: while hidden it
    // cannot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _revealOffset(offset);
    });
  }

  /// Where [line] and [column] are in [text], counted as [parseJsonForTree]
  /// counts them: after a byte-order mark, with CR LF or a lone CR as one
  /// line break. A column past the end of its line means the line's end.
  static int _offsetOf(String text, int line, int column) {
    var at = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
    for (var current = 1; current < line && at < text.length;) {
      final unit = text.codeUnitAt(at++);
      if (unit == 0x0D && at < text.length && text.codeUnitAt(at) == 0x0A) {
        at++;
      }
      if (unit == 0x0A || unit == 0x0D) current++;
    }
    var end = at;
    while (end < text.length) {
      final unit = text.codeUnitAt(end);
      if (unit == 0x0A || unit == 0x0D) break;
      end++;
    }
    return math.min(at + math.max(column - 1, 0), end);
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
            info.mixedLineEndings ? 'Mixed endings' : info.lineEnding.code,
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
        if (_previewing || _canPreview)
          IconButton(
            key: const ValueKey('text-preview-toggle'),
            tooltip: _previewing ? 'Edit' : 'Preview',
            icon: Icon(
              _previewing ? Icons.edit_rounded : Icons.visibility_rounded,
            ),
            onPressed: _togglePreview,
          ),
        if (!_readOnly)
          TextButton(
            onPressed: _dirty && !_saving && !_replacing ? _save : null,
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
          enabled: _doc != null && !_saving && !_replacing,
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
            // The text's size and layout are not what the preview shows.
            if (!_previewing) ...[
              const PopupMenuItem(value: 'size', child: Text('Text size')),
              if (!_readOnly && DocKind.extensionOf(widget.path) == 'json')
                const PopupMenuItem(value: 'json', child: Text('Format JSON')),
            ],
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
    final garbled = info.decodeErrors > 0 || !info.confident;
    return Column(
      children: [
        if (_searchOpen) _buildSearchBar(),
        if (_replacing || _formatting)
          LinearProgressIndicator(
            key: const ValueKey('text-operation-busy'),
            semanticsLabel: _replacing ? 'Replacing matches' : 'Formatting JSON',
          ),
        // While previewing only a doubt about the letters matters: the
        // preview shows the same letters.
        if (info.binary && !_previewing)
          _notice(
            Icons.warning_amber_rounded,
            'This file may not be text. Saving it here could damage it.',
          )
        else if (_readOnly && !_previewing)
          _notice(
            Icons.lock_outline_rounded,
            'This file is large (${formatCount(info.lines)} lines), so it '
            'opens read-only.',
          )
        else if (garbled)
          _notice(
            Icons.translate_rounded,
            info.decodeErrors > 0
                ? '${info.decodeErrors} unreadable sequences are kept as special '
                      'characters. Keep those characters and the original encoding '
                      'to preserve their bytes.'
                : 'The encoding (${info.encoding}) was a guess. If letters '
                      'look wrong, use "Fix garbled text" in the menu.',
          ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Both stay built while the other shows, so the text's undo
              // history and each one's place are there on coming back.
              Visibility(
                visible: !_previewing,
                maintainState: true,
                child: _readOnly ? _buildLines(info) : _buildEditor(),
              ),
              if (_previewing || _hasPreview)
                Visibility(
                  visible: _previewing,
                  maintainState: true,
                  child: _buildPreview(),
                ),
            ],
          ),
        ),
        if (!_previewing) _buildToolbar(),
      ],
    );
  }

  /// The preview, with a spinner over it while it is being made from new
  /// text. The one before stays underneath, so the page keeps its place.
  Widget _buildPreview() {
    final content = _previewContent;
    return Stack(
      fit: StackFit.expand,
      children: [
        ?content,
        if (_parsing)
          Align(
            key: const ValueKey('text-preview-busy'),
            alignment: content == null
                ? Alignment.center
                : const Alignment(0, -0.9),
            child: Material(
              color: _colors.cardBackground,
              shape: const CircleBorder(),
              elevation: content == null ? 0 : 2,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _accent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool get _hasPreview =>
      _markup != null || _json != null || _previewError != null;

  /// What the preview shows once made; null before then.
  Widget? get _previewContent {
    final error = _previewError;
    if (error != null) {
      return _previewProblem(
        Icons.error_outline_rounded,
        'The preview could not be made',
        error,
      );
    }
    final markup = _markup;
    if (markup != null) {
      return MarkupView(
        key: const ValueKey('text-preview'),
        document: markup,
        // Pictures are found next to the file, not next to a saved copy.
        baseDirectory: File(widget.path).parent.path,
      );
    }
    final json = _json;
    if (json == null) return null;
    if (json.ok) {
      return JsonTreeView(
        key: const ValueKey('text-preview'),
        value: json.value,
      );
    }
    final line = json.line;
    return _previewProblem(
      Icons.data_object_rounded,
      'This is not valid JSON',
      json.error!,
      action: line == null
          ? null
          : FilledButton.icon(
              key: const ValueKey('text-preview-go-to-line'),
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('Go to line'),
              onPressed: () => _goToLine(line, json.column ?? 1),
            ),
    );
  }

  Widget _previewProblem(
    IconData icon,
    String title,
    String message, {
    Widget? action,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const ValueKey('text-preview-problem'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: _colors.textTertiary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _colors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: _colors.textSecondary),
            ),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
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
            if (!_readOnly) ...[
              undoButton(false),
              undoButton(true),
              IconButton(
                tooltip: 'New line (Enter)',
                icon: const Icon(Icons.keyboard_return_rounded),
                onPressed: _saving ? null : _typeEnter,
              ),
            ],
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

  /// Enter from the toolbar, for keyboards that show no Enter key.
  void _typeEnter() {
    final sel = _controller.selection;
    final at = sel.isValid
        ? sel
        : TextSelection.collapsed(offset: _controller.text.length);
    _controller.value = _controller.value.replaced(at, '\n');
    if (!_focus.hasFocus) _focus.requestFocus();
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
          readOnly: _saving,
          // A new, empty file is for typing into: start with the keyboard.
          autofocus: _lastText.isEmpty,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
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
    if (doc != null && _pagesLoading.length < 4 && _pagesLoading.add(index)) {
      unawaited(_loadPage(doc, index, _pageEpoch));
    }
    return null;
  }

  Future<void> _loadPage(TextDocument doc, int index, int epoch) async {
    List<String> lines;
    try {
      lines = await doc.linesAsync(index * _pageSize, _pageSize);
    } catch (e, stack) {
      logDocumentError('TextEditor.lines', e, path: _workingPath, stack: stack);
      lines = [e is TextCoreException ? e.message : 'These lines could not be read.'];
    }
    if (!mounted || epoch != _pageEpoch) return;
    setState(() {
      _pagesLoading.remove(index);
      _pages[index] = lines;
      var characters = _pages.values.expand((page) => page).fold<int>(0, (sum, line) => sum + line.length);
      while (_pages.length > 1 && (_pages.length > 8 || characters > 2000000)) {
        final removed = _pages.remove(_pages.keys.first)!;
        characters -= removed.fold<int>(0, (sum, line) => sum + line.length);
      }
    });
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
              color: index == current || index == _markedLine
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
    final count = _searching
        ? 'Finding…'
        : _matches.isEmpty
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
                      _searchRun++;
                      setState(() {
                        _matches = const [];
                        _current = -1;
                      });
                      _controller.setMatches(const [], -1);
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
                    onPressed: _matches.isEmpty || _saving || _replacing || _searching ? null : _replaceCurrent,
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    onPressed: _matches.isEmpty || _saving || _replacing || _searching ? null : _replaceAll,
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
