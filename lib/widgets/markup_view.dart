import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/theme_provider.dart';
import '../utils/error_logger.dart';

/// A Markdown or HTML document as a reading view: headings, styled text,
/// lists, quotes, code, tables and pictures, laid out like a clean GitHub
/// or browser page in the app's colours.
///
/// Each top-level block is one item of a lazily built list, so a long README
/// or web page scrolls smoothly. Text can be selected and copied. Links open
/// in another app only when they are web or e-mail addresses. Pictures show
/// only from this device: a file next to the document ([baseDirectory]) or
/// one embedded in it. Pictures on the web are never downloaded; a
/// placeholder with their description stands in for them.
class MarkupView extends StatefulWidget {
  const MarkupView({
    super.key,
    required this.document,
    this.baseDirectory,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 32),
  });

  final MarkupDocument document;

  /// The folder relative picture paths are read from, usually the
  /// document's own folder. Without it only absolute paths and `file:`
  /// addresses show.
  final String? baseDirectory;

  /// Space around the content, inside the scrolling list.
  final EdgeInsets padding;

  /// Where tapping [link] goes, or null when it goes nowhere outside the
  /// document. Only web (`http`, `https`) and e-mail (`mailto`) addresses
  /// open; `javascript:`, `data:`, `file:`, `intent:` and every other
  /// scheme, relative paths and `#fragment`s do nothing.
  static Uri? linkTarget(String link) {
    final uri = Uri.tryParse(link.trim().replaceAll(' ', '%20'));
    if (uri == null) return null;
    return switch (uri.scheme) {
      'http' || 'https' => uri.host.isEmpty ? null : uri,
      'mailto' => uri.path.isEmpty && !uri.hasQuery ? null : uri,
      _ => null,
    };
  }

  /// The picture file [src] names on this device, or null when it names
  /// none: a web or embedded picture, a relative path without
  /// [baseDirectory], or no file to show. Relative paths are read against
  /// [baseDirectory]; absolute paths and `file:` addresses as they are. A
  /// path is tried as written and then percent-decoded without its `?query`
  /// or `#fragment`, the way a browser would read it.
  ///
  /// Only ordinary files of up to 50 MB count: a document naming
  /// `/dev/zero`, a pipe or a huge file would otherwise have the app read
  /// without end.
  static File? localImage(String src, String? baseDirectory) {
    final s = src.trim();
    // `//host/picture.png` is on the web, with the page's scheme.
    if (s.isEmpty || s.startsWith('//')) return null;
    final scheme = _scheme.firstMatch(s)?.group(1)?.toLowerCase();
    final candidates = <String>[];
    if (scheme == 'file') {
      try {
        final uri = Uri.parse(s);
        final host = uri.host.toLowerCase();
        // A file on another machine is not on this device.
        if (host.isNotEmpty && host != 'localhost') return null;
        candidates.add(Uri(scheme: 'file', path: uri.path).toFilePath());
      } on Object {
        return null;
      }
    } else if (scheme != null) {
      return null;
    } else {
      final String Function(String) place;
      if (s.startsWith('/')) {
        place = (p) => p;
      } else if (baseDirectory != null && baseDirectory.isNotEmpty) {
        final base = baseDirectory.endsWith('/')
            ? baseDirectory
            : '$baseDirectory/';
        place = (p) => '$base$p';
      } else {
        return null;
      }
      candidates.add(place(s));
      var bare = s;
      final cut = bare.indexOf(RegExp('[?#]'));
      if (cut >= 0) bare = bare.substring(0, cut);
      try {
        bare = Uri.decodeComponent(bare);
      } on ArgumentError {
        // A stray % that starts no escape: keep the path as written.
      }
      if (bare.isNotEmpty) candidates.add(place(bare));
    }
    for (final path in candidates) {
      final file = File(path);
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.file &&
          stat.size > 0 &&
          stat.size <= _maxImageFileBytes) {
        return file;
      }
    }
    return null;
  }

  /// The bytes of a picture embedded as a `data:` address: base64 PNG,
  /// JPEG or GIF of at most about 10 MB. Anything else is null.
  static Uint8List? dataImage(String src) {
    final s = src.trim();
    if (s.length < 5 || s.substring(0, 5).toLowerCase() != 'data:') {
      return null;
    }
    final comma = s.indexOf(',');
    if (comma < 0) return null;
    final header = s.substring(5, comma).toLowerCase().split(';');
    const types = {'image/png', 'image/jpeg', 'image/jpg', 'image/gif'};
    if (!types.contains(header.first.trim()) ||
        !header.skip(1).any((p) => p.trim() == 'base64')) {
      return null;
    }
    // Base64 is four characters for three bytes; allow an eighth more for
    // line breaks and indents, and turn away anything longer unread.
    if (s.length - comma - 1 > (_maxEmbeddedBytes ~/ 3 + 1) * 4 * 9 ~/ 8) {
      return null;
    }
    var payload = s.substring(comma + 1).replaceAll(RegExp(r'\s+'), '');
    if (payload.contains('%')) {
      try {
        payload = Uri.decodeComponent(payload);
      } on ArgumentError {
        return null;
      }
    }
    if (payload.length ~/ 4 * 3 > _maxEmbeddedBytes) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64.normalize(payload));
    } on FormatException {
      return null;
    }
    return _isPicture(bytes) ? bytes : null;
  }

  @override
  State<MarkupView> createState() => _MarkupViewState();
}

/// A URI scheme at the start of a string (`https:`, `data:`).
final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):');

/// Embedded pictures larger than this, decoded, are not shown.
const _maxEmbeddedBytes = 10 << 20;

/// Picture files larger than this are not decoded.
const _maxImageFileBytes = 50 << 20;

/// Embedded pictures already decoded, by the inline that holds them, for
/// as long as its document lives. Scrolling back to one then neither
/// decodes its text again nor, since the image cache knows the same bytes,
/// the picture.
final _embedded = Expando<Uint8List>('embedded pictures');

/// Whether [bytes] start like a PNG, JPEG or GIF.
bool _isPicture(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  return startsWith(const [0x89, 0x50, 0x4E, 0x47]) ||
      startsWith(const [0xFF, 0xD8, 0xFF]) ||
      startsWith(const [0x47, 0x49, 0x46, 0x38]);
}

class _MarkupViewState extends State<MarkupView> {
  final _scroll = ScrollController();

  /// The document's blocks taken apart into the list's items.
  late List<_Piece> _pieces = _Pieces.of(widget.document.blocks);

  /// Each table's column widths, worked out once for a width of the view.
  var _columns = Expando<_Columns>('table columns');

  /// The sideways scrolling each table's pieces share.
  final _sideScrolls = Map<MarkupTable, _SideScroll>.identity();

  @override
  void didUpdateWidget(MarkupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _pieces = _Pieces.of(widget.document.blocks);
      _columns = Expando<_Columns>('table columns');
      _sideScrolls.clear();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final blocks = widget.document.blocks;
    final padding = widget.padding;
    if (blocks.every(_isBlank)) {
      return Center(
        key: const ValueKey('markup-empty'),
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.article_outlined,
                size: 40,
                color: colors.textTertiary,
              ),
              const SizedBox(height: 12),
              Text(
                'Nothing to show',
                style: TextStyle(color: colors.textSecondary, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }
    final textScaler = MediaQuery.textScalerOf(context);
    final scale = textScaler.scale(16) / 16;
    final textStyle = DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.max(0.0, constraints.maxWidth - padding.horizontal)
            : 400.0;
        final look = _Look(
          colors,
          width: width,
          scale: scale,
          baseDirectory: widget.baseDirectory,
        );
        final pieces = _pieces;
        final truncated = widget.document.truncated;
        return SelectionArea(
          child: Scrollbar(
            controller: _scroll,
            interactive: true,
            child: ListView.builder(
              key: const ValueKey('markup-list'),
              controller: _scroll,
              padding: padding,
              itemCount: pieces.length + (truncated ? 1 : 0),
              itemBuilder: (context, i) => i == pieces.length
                  ? _truncatedNote(look)
                  : KeyedSubtree(
                      key: ValueKey('markup-block-$i'),
                      child: _piece(pieces[i], look, textScaler, textStyle),
                    ),
            ),
          ),
        );
      },
    );
  }

  /// [piece] inside its quotes and list items, with the space above it.
  Widget _piece(
    _Piece piece,
    _Look base,
    TextScaler textScaler,
    TextStyle textStyle,
  ) {
    final frames = piece.frames;
    // The look where each frame starts, and the room it indents by (null
    // when nesting has used up the room to indent).
    final outer = List<_Look>.filled(frames.length, base);
    final indents = List<double?>.filled(frames.length, null);
    var look = base;
    for (var k = 0; k < frames.length; k++) {
      outer[k] = look;
      final room = look.hasRoom;
      switch (frames[k]) {
        case _QuoteFrame():
          indents[k] = room ? _quoteIndent : null;
          look = look.nested(room ? _quoteIndent : 0, quoted: true);
        case _ItemFrame(:final list):
          final marker = _markerWidth(list, look);
          indents[k] = room ? marker : null;
          look = look.nested(room ? marker : 0, listDepth: look.listDepth + 1);
      }
    }
    final block = piece.block;
    var child = block is MarkupTable
        ? _tablePiece(block, piece.rows, look, textScaler, textStyle)
        : _leaf(block, look);
    for (var k = frames.length - 1; k >= 0; k--) {
      if (k + 1 == piece.firstIn) child = _spaced(piece.gap, child);
      final first = k >= piece.firstIn;
      child = switch (frames[k]) {
        _QuoteFrame() => _quote(
          child,
          outer[k],
          indented: indents[k] != null,
          first: first,
          last: k >= piece.lastIn,
        ),
        final _ItemFrame item => _listItem(
          child,
          item,
          outer[k],
          markerWidth: indents[k],
          first: first,
        ),
      };
    }
    return piece.firstIn == 0 ? _spaced(piece.gap, child) : child;
  }

  /// Rows [rows] of [table] (the first piece also has the header), with
  /// the column widths every piece of the table shares.
  Widget _tablePiece(
    MarkupTable table,
    (int, int) rows,
    _Look look,
    TextScaler textScaler,
    TextStyle textStyle,
  ) {
    var columns = _columns[table];
    if (columns == null ||
        columns.viewWidth != look.width ||
        columns.textScaler != textScaler) {
      columns = _columns[table] = _Columns.measure(
        table,
        look,
        textScaler,
        textStyle,
      );
    }
    final widths = columns.widths;
    if (widths.isEmpty) return const SizedBox.shrink();
    TextAlign alignOf(int column) => switch (column < table.align.length
        ? table.align[column]
        : MarkupAlign.none) {
      MarkupAlign.left => TextAlign.left,
      MarkupAlign.center => TextAlign.center,
      MarkupAlign.right => TextAlign.right,
      MarkupAlign.none => TextAlign.start,
    };
    TableRow row(
      List<List<MarkupInline>> cells,
      TextStyle style, {
      Color? fill,
    }) => TableRow(
      decoration: fill == null ? null : BoxDecoration(color: fill),
      children: [
        for (var c = 0; c < widths.length; c++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: _Inlines(
              c < cells.length ? cells[c] : const [],
              look: look,
              style: style,
              textAlign: alignOf(c),
            ),
          ),
      ],
    );
    final (from, to) = rows;
    final first = from == 0;
    final side = BorderSide(color: look.line);
    final scroll = _sideScrolls.putIfAbsent(table, _SideScroll.new);
    return _TablePiece(
      // A new table gets new state, rather than taking over another's.
      key: ObjectKey(scroll),
      scrollKey: ValueKey(first ? 'markup-table' : 'markup-table-$from'),
      sideScroll: scroll,
      child: Table(
        columnWidths: {
          for (var c = 0; c < widths.length; c++)
            c: FixedColumnWidth(widths[c]),
        },
        // Each piece draws the line below its rows; only the first draws
        // the one above, so no line is drawn twice.
        border: TableBorder(
          top: first ? side : BorderSide.none,
          right: side,
          bottom: side,
          left: side,
          horizontalInside: side,
          verticalInside: side,
        ),
        children: [
          if (first && table.header.isNotEmpty)
            row(
              table.header,
              look.cell.copyWith(fontWeight: FontWeight.w700),
              fill: look.tint,
            ),
          for (var r = from; r < to; r++)
            row(table.rows[r], look.cell, fill: r.isOdd ? look.stripe : null),
        ],
      ),
    );
  }
}

/// Says, after the last block, that the document went on: it was too long
/// to read whole.
Widget _truncatedNote(_Look look) => SelectionContainer.disabled(
  child: Container(
    key: const ValueKey('markup-truncated'),
    margin: const EdgeInsets.only(top: 24),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: look.tint,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: look.colors.divider),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.content_cut_rounded,
          size: 20,
          color: look.colors.textTertiary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'This document is too long to show in full, so only its '
            'beginning is here. The text has all of it.',
            style: TextStyle(color: look.colors.textSecondary, height: 1.4),
          ),
        ),
      ],
    ),
  ),
);

/// [child] with [gap] pixels of space above it.
Widget _spaced(double gap, Widget child) => gap == 0
    ? child
    : Padding(
        padding: EdgeInsets.only(top: gap),
        child: child,
      );

/// Whether [block] shows nothing: a paragraph of white space, or a kind of
/// block this version does not know.
bool _isBlank(MarkupBlock block) =>
    block is MarkupParagraph &&
    block.inlines.every(
      (inline) => switch (inline) {
        MarkupText(:final text) => text.trim().isEmpty,
        MarkupImage() => false,
        MarkupBreak() => true,
      },
    );

/// The space above [next] when it follows [before]: more above a heading,
/// less under one, and half as much inside list items.
double _gapBetween(MarkupBlock before, MarkupBlock next, {bool tight = false}) {
  final double gap = switch (next) {
    MarkupHeading(:final level) => level <= 2 ? 24 : 20,
    _ => before is MarkupHeading ? 10 : 14,
  };
  return tight ? gap / 2 : gap;
}

/// Colours, sizes and the place in the document shared by the blocks of
/// one view. Made in [_MarkupViewState.build], so the colours follow the
/// theme.
class _Look {
  const _Look(
    this.colors, {
    required this.width,
    required this.scale,
    required this.baseDirectory,
    this.quoted = false,
    this.indent = 0,
    this.listDepth = 0,
  });

  final AppColors colors;

  /// The width of the view's content, in pixels.
  final double width;

  /// How much the reader's text size setting enlarges text.
  final double scale;

  final String? baseDirectory;

  /// Inside a block quote, where text is muted.
  final bool quoted;

  /// How far quotes and lists have pushed the text in, in pixels.
  final double indent;

  /// How many lists, numbered or not, the text is inside: a bullet list
  /// inside a numbered one gets circles, as in a browser.
  final int listDepth;

  /// A look for blocks [by] pixels further in.
  _Look nested(double by, {bool? quoted, int? listDepth}) => _Look(
    colors,
    width: width,
    scale: scale,
    baseDirectory: baseDirectory,
    quoted: quoted ?? this.quoted,
    indent: indent + by,
    listDepth: listDepth ?? this.listDepth,
  );

  /// Whether there is room to indent further. Quotes and lists nested
  /// deeper than this stack up without indenting, so pathological nesting
  /// never squeezes the text to nothing.
  bool get hasRoom => indent + 48 * scale <= width * 0.6;

  Color get ink => quoted ? colors.textSecondary : colors.textPrimary;

  Color get link =>
      colors.isDark ? const Color(0xFF64B5F6) : const Color(0xFF0563C1);

  /// Table borders and the bar beside quotes.
  Color get line => colors.isDark ? Colors.white24 : Colors.black26;

  /// Behind code blocks, table headers and picture placeholders.
  Color get tint =>
      colors.isDark ? const Color(0x14FFFFFF) : const Color(0x0A000000);

  /// Behind every other table row.
  Color get stripe =>
      colors.isDark ? const Color(0x08FFFFFF) : const Color(0x05000000);

  /// Behind inline code.
  Color get codeTint =>
      colors.isDark ? const Color(0x33656C76) : const Color(0x1F818B98);

  /// One line of body text, in pixels.
  double get lineHeight => 16 * 1.5 * scale;

  TextStyle get body => TextStyle(fontSize: 16, height: 1.5, color: ink);

  TextStyle get cell => TextStyle(fontSize: 15, height: 1.4, color: ink);

  TextStyle get code => TextStyle(
    fontFamily: 'monospace',
    fontSize: 13.5,
    height: 1.45,
    color: ink,
  );

  TextStyle heading(int level) => TextStyle(
    fontSize: const [28.0, 22.0, 19.0, 17.0, 15.5, 14.5][level.clamp(1, 6) - 1],
    height: 1.3,
    fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
    color: level == 6 ? colors.textSecondary : ink,
  );

  /// The style of [run] on top of [base].
  TextStyle run(MarkupText run, TextStyle base) {
    var style = base;
    if (run.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (run.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (run.code) {
      style = style.copyWith(
        fontFamily: 'monospace',
        fontSize: (base.fontSize ?? 16) * 0.88,
        backgroundColor: codeTint,
      );
    }
    final isLink = run.link != null;
    if (isLink) style = style.copyWith(color: link);
    if (isLink || run.strike) {
      style = style.copyWith(
        decoration: TextDecoration.combine([
          if (isLink) TextDecoration.underline,
          if (run.strike) TextDecoration.lineThrough,
        ]),
        decorationColor: style.color,
      );
    }
    return style;
  }
}

/// A block that holds no other blocks, as one item of the list. Quotes,
/// lists and tables were taken apart into pieces before this.
Widget _leaf(MarkupBlock block, _Look look) => switch (block) {
  MarkupHeading() => _heading(block, look),
  MarkupParagraph(:final inlines) =>
    inlines.isEmpty
        ? const SizedBox.shrink()
        : _Inlines(inlines, look: look, style: look.body),
  MarkupCode() => _code(block, look),
  MarkupRule() => Divider(height: 16, thickness: 2, color: look.line),
  MarkupQuote() || MarkupList() || MarkupTable() => const SizedBox.shrink(),
};

/// A quote or a list item, which the pieces of its blocks sit inside.
sealed class _Frame {
  const _Frame();
}

final class _QuoteFrame extends _Frame {
  const _QuoteFrame();
}

final class _ItemFrame extends _Frame {
  const _ItemFrame(this.list, this.index);

  final MarkupList list;
  final int index;
}

/// One item of the view's list: a heading, paragraph, code block or rule,
/// or some rows of a table, with the quotes and list items it is inside.
///
/// Taking quotes, lists and tables apart into pieces means only what is on
/// screen is built and laid out: a task list of thousands of items or a
/// table of thousands of rows scrolls like any other page.
class _Piece {
  _Piece(
    this.block,
    this.frames, {
    required this.gap,
    required this.firstIn,
    required this.rows,
  }) : lastIn = frames.length;

  final MarkupBlock block;

  /// The quotes and list items around it, outermost first.
  final List<_Frame> frames;

  /// The space above it, inside the frames it shares with the piece above
  /// and outside those it is the first piece of.
  final double gap;

  /// It is the first piece of `frames[firstIn]` and of every frame inside
  /// that one, so it shows their list markers and the top of their quotes.
  final int firstIn;

  /// It is the last piece of `frames[lastIn]` and of every frame inside
  /// that one, so it shows the bottom of their quotes.
  int lastIn;

  /// For a table: the rows it shows, from and to. The first piece of a
  /// table also shows the header.
  final (int, int) rows;
}

/// Takes blocks apart into [_Piece]s, in reading order.
class _Pieces {
  _Pieces._();

  /// Rows of a table in one piece.
  static const int tableRows = 20;

  static List<_Piece> of(List<MarkupBlock> blocks) =>
      (_Pieces._().._blocks(blocks))._out;

  final _out = <_Piece>[];
  final _frames = <_Frame>[];

  /// How many pieces there were when each frame in [_frames] began.
  final _starts = <int>[];

  /// [_frames] as the pieces share it, until it next changes.
  List<_Frame>? _shared;

  /// The space above the next piece.
  double _gap = 0;

  /// Frames from this index on began after the last piece.
  int _fresh = 0;

  void _blocks(List<MarkupBlock> blocks, {bool tight = false}) {
    for (var i = 0; i < blocks.length; i++) {
      // The first block's space is its container's, already set.
      if (i > 0) _gap = _gapBetween(blocks[i - 1], blocks[i], tight: tight);
      _block(blocks[i]);
    }
  }

  void _block(MarkupBlock block) {
    switch (block) {
      case MarkupQuote(:final blocks):
        _enter(const _QuoteFrame());
        _blocks(blocks);
        _leave();
      case MarkupList(:final items):
        for (var i = 0; i < items.length; i++) {
          if (i > 0) _gap = _itemGap;
          _enter(_ItemFrame(block, i));
          _blocks(items[i].blocks, tight: true);
          _leave();
        }
      case MarkupTable(:final rows):
        var from = 0;
        do {
          final to = math.min(from + tableRows, rows.length);
          _add(block, rows: (from, to));
          from = to;
        } while (from < rows.length);
      default:
        _add(block);
    }
  }

  void _enter(_Frame frame) {
    _frames.add(frame);
    _starts.add(_out.length);
    _shared = null;
  }

  void _leave() {
    // An empty quote or list item still shows its bar or marker.
    if (_out.length == _starts.removeLast()) _add(const MarkupParagraph([]));
    _frames.removeLast();
    _shared = null;
    final last = _out.last;
    last.lastIn = math.min(last.lastIn, _frames.length);
    _fresh = math.min(_fresh, _frames.length);
  }

  void _add(MarkupBlock block, {(int, int) rows = (0, 0)}) {
    _out.add(
      _Piece(
        block,
        _shared ??= List.unmodifiable(_frames),
        gap: _gap,
        firstIn: _fresh,
        rows: rows,
      ),
    );
    _gap = 0;
    _fresh = _frames.length;
  }
}

/// Space between list items.
const double _itemGap = 4;

/// How far a quote pushes its text in: its bar and the space after it.
const double _quoteBar = 3;
const double _quoteIndent = _quoteBar + 12;

/// A heading; the two biggest levels have a thin rule under them, as on
/// GitHub.
Widget _heading(MarkupHeading heading, _Look look) {
  final text = _Inlines(
    heading.inlines,
    look: look,
    style: look.heading(heading.level),
  );
  return Semantics(
    header: true,
    child: heading.level > 2
        ? text
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              text,
              const SizedBox(height: 6),
              Divider(height: 1, thickness: 1, color: look.colors.divider),
            ],
          ),
  );
}

/// [child], a piece of a block quote: a bar down the left and the text
/// indented, in muted text (the look inside says so). Once nesting has used
/// up the room to indent ([indented] false), deeper quotes are only muted.
/// The quote's first and last pieces have a little space inside the bar.
Widget _quote(
  Widget child,
  _Look look, {
  required bool indented,
  required bool first,
  required bool last,
}) {
  if (!indented) {
    return KeyedSubtree(key: const ValueKey('markup-quote'), child: child);
  }
  return Container(
    key: const ValueKey('markup-quote'),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: look.line, width: _quoteBar),
      ),
    ),
    padding: EdgeInsets.only(
      left: _quoteIndent - _quoteBar,
      top: first ? 2 : 0,
      bottom: last ? 2 : 0,
    ),
    child: child,
  );
}

/// How wide [list]'s bullets or numbers are, in [look].
double _markerWidth(MarkupList list, _Look look) {
  if (!list.ordered) return 24.0 * look.scale;
  final last = list.start + list.items.length - 1;
  final chars = math.max('${list.start}.'.length, '$last.'.length);
  return math.max(24.0, chars * 9.5 + 8) * look.scale;
}

/// [child], a piece of a list item, beside the item's marker when it is
/// the item's [first] piece: a bullet (disc, circle, square by depth), a
/// number counted from the list's start, or a task's checkbox. Without
/// [markerWidth] nesting has used up the room, and the piece shows alone.
Widget _listItem(
  Widget child,
  _ItemFrame frame,
  _Look look, {
  required double? markerWidth,
  required bool first,
}) {
  if (markerWidth == null) return child;
  final list = frame.list;
  final checked = list.items[frame.index].checked;
  final boxSize = 18 * look.scale;
  final Widget? box = checked == null || !first
      ? null
      : SizedBox(
          height: look.lineHeight,
          child: Icon(
            checked ? Icons.check_box : Icons.check_box_outline_blank,
            size: boxSize,
            color: checked ? look.link : look.colors.textTertiary,
            semanticLabel: checked ? 'Done' : 'Not done',
          ),
        );
  Widget? marker;
  var content = child;
  if (list.ordered) {
    if (first) {
      marker = Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(
          '${list.start + frame.index}.',
          textAlign: TextAlign.right,
          softWrap: false,
          style: look.body.copyWith(color: look.colors.textSecondary),
        ),
      );
    }
    if (checked != null) {
      // A numbered task keeps its number, with the checkbox beside it.
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          box ?? SizedBox(width: boxSize),
          const SizedBox(width: 6),
          Expanded(child: child),
        ],
      );
    }
  } else if (first) {
    marker = Align(alignment: Alignment.topLeft, child: box ?? _bullet(look));
  }
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Copying a list copies its text, not its bullets and numbers.
      SelectionContainer.disabled(
        child: SizedBox(width: markerWidth, child: marker),
      ),
      Expanded(child: content),
    ],
  );
}

/// The bullet of a list [look.listDepth] lists deep: a disc, then a circle,
/// then a square, and round again.
Widget _bullet(_Look look) {
  final size = 6.0 * look.scale;
  final ink = look.ink;
  final (name, decoration) = switch (look.listDepth % 3) {
    0 => ('disc', BoxDecoration(color: ink, shape: BoxShape.circle)),
    1 => (
      'circle',
      BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ink, width: 1.2),
      ),
    ),
    _ => ('square', BoxDecoration(color: ink)),
  };
  return SizedBox(
    width: 18 * look.scale,
    height: look.lineHeight,
    child: Center(
      child: Container(
        key: ValueKey('markup-bullet-$name'),
        width: size,
        height: size,
        decoration: decoration,
      ),
    ),
  );
}

/// A code block: monospaced on a tinted background, scrolling sideways
/// rather than wrapping, with its language small at the top right.
Widget _code(MarkupCode code, _Look look) {
  final language = code.language.trim();
  return DecoratedBox(
    key: const ValueKey('markup-code'),
    decoration: BoxDecoration(
      color: look.tint,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: look.colors.divider),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (language.isNotEmpty)
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 10, 0),
              child: Text(
                language,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: look.colors.textTertiary),
              ),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(12, language.isEmpty ? 10 : 2, 12, 10),
          child: Text(code.text, softWrap: false, style: look.code),
        ),
      ],
    ),
  );
}

/// The widths of a table's columns, which every piece of it uses so its
/// columns line up: each fits its text up to a limit, past which the text
/// wraps.
class _Columns {
  const _Columns(
    this.widths, {
    required this.viewWidth,
    required this.textScaler,
  });

  final List<double> widths;

  /// The view's content width and text scaling they were worked out for.
  final double viewWidth;
  final TextScaler textScaler;

  /// Rows measured beyond the header: the first half of them, and the rest
  /// spread over the table. Laying out every cell of a long table to size
  /// its columns would take seconds; a cell wider than the sample wraps.
  static const int sampleRows = 200;

  /// Room a picture takes in a cell, besides its description.
  static const double pictureWidth = 40;

  static _Columns measure(
    MarkupTable table,
    _Look look,
    TextScaler textScaler,
    TextStyle textStyle,
  ) {
    var count = math.max(table.align.length, table.header.length);
    for (final row in table.rows) {
      count = math.max(count, row.length);
    }
    final natural = List<double>.filled(count, 0);
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    void measureRow(List<List<MarkupInline>> cells, TextStyle style) {
      for (var c = 0; c < cells.length && c < count; c++) {
        var pictures = 0;
        final spans = <InlineSpan>[];
        for (final inline in cells[c]) {
          switch (inline) {
            case MarkupText(:final text):
              spans.add(TextSpan(text: text, style: look.run(inline, style)));
            case MarkupImage(:final alt):
              pictures++;
              spans.add(TextSpan(text: alt));
            case MarkupBreak():
              spans.add(const TextSpan(text: '\n'));
          }
        }
        if (spans.isEmpty) continue;
        painter.text = TextSpan(style: style, children: spans);
        painter.layout();
        natural[c] = math.max(
          natural[c],
          painter.maxIntrinsicWidth + pictures * pictureWidth,
        );
      }
    }

    try {
      final cell = textStyle.merge(look.cell);
      measureRow(table.header, cell.copyWith(fontWeight: FontWeight.w700));
      final rows = table.rows;
      if (rows.length <= sampleRows) {
        for (final row in rows) {
          measureRow(row, cell);
        }
      } else {
        const half = sampleRows ~/ 2;
        for (var r = 0; r < half; r++) {
          measureRow(rows[r], cell);
        }
        final step = (rows.length - half) / half;
        for (var i = 0; i < half; i++) {
          measureRow(rows[half + (i * step).floor()], cell);
        }
      }
    } finally {
      painter.dispose();
    }
    final widest = (look.width * 0.75).clamp(140.0, 320.0) * look.scale;
    return _Columns(
      [
        // The cell's padding, and a pixel so rounding never wraps a word.
        for (final width in natural)
          math.min(width.ceilToDouble() + 21, widest),
      ],
      viewWidth: look.width,
      textScaler: textScaler,
    );
  }
}

/// Keeps the pieces of one table scrolled sideways together, so a table
/// wider than the screen moves as one and its columns stay lined up.
class _SideScroll {
  double _offset = 0;
  final _controllers = <ScrollController>[];
  bool _following = false;

  /// A controller for a piece coming on screen, scrolled where the others
  /// are.
  ScrollController attach() {
    final controller = ScrollController(
      initialScrollOffset: _offset,
      keepScrollOffset: false,
    );
    controller.addListener(() => _follow(controller));
    _controllers.add(controller);
    return controller;
  }

  void detach(ScrollController controller) {
    _controllers.remove(controller);
    controller.dispose();
  }

  void _follow(ScrollController leader) {
    if (_following || !leader.hasClients) return;
    _following = true;
    _offset = leader.offset;
    for (final other in _controllers) {
      if (!identical(other, leader) &&
          other.hasClients &&
          other.offset != _offset) {
        other.jumpTo(_offset);
      }
    }
    _following = false;
  }
}

/// Some rows of a table, scrolling sideways with the table's other pieces.
class _TablePiece extends StatefulWidget {
  const _TablePiece({
    super.key,
    required this.scrollKey,
    required this.sideScroll,
    required this.child,
  });

  final Key scrollKey;
  final _SideScroll sideScroll;
  final Widget child;

  @override
  State<_TablePiece> createState() => _TablePieceState();
}

class _TablePieceState extends State<_TablePiece> {
  late final ScrollController _controller = widget.sideScroll.attach();

  @override
  void dispose() {
    widget.sideScroll.detach(_controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: widget.scrollKey,
    controller: _controller,
    scrollDirection: Axis.horizontal,
    child: widget.child,
  );
}

/// Opens [target] in another app, and says so when no app can.
Future<void> _launch(BuildContext context, Uri target) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var opened = false;
  try {
    opened = await launchUrl(target, mode: LaunchMode.externalApplication);
  } catch (e) {
    logError('MarkupView.launch', e);
  }
  if (!opened) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No app can open this link.')),
    );
  }
}

/// Styled text: a paragraph, a heading or a table cell, with pictures
/// inline. Owns the tap recognizers of its links.
class _Inlines extends StatefulWidget {
  const _Inlines(
    this.inlines, {
    required this.look,
    required this.style,
    this.textAlign,
  });

  final List<MarkupInline> inlines;
  final _Look look;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  State<_Inlines> createState() => _InlinesState();
}

class _InlinesState extends State<_Inlines> {
  final _recognizers = <TapGestureRecognizer>[];
  late TextSpan _span;

  @override
  void initState() {
    super.initState();
    _span = _spans();
  }

  @override
  void didUpdateWidget(_Inlines oldWidget) {
    super.didUpdateWidget(oldWidget);
    _forgetRecognizers();
    _span = _spans();
  }

  @override
  void dispose() {
    _forgetRecognizers();
    super.dispose();
  }

  void _forgetRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  TextSpan _spans() {
    final look = widget.look;
    final base = widget.style;
    final children = <InlineSpan>[];
    for (final inline in widget.inlines) {
      switch (inline) {
        case MarkupText(:final text, :final link):
          if (text.isEmpty) continue;
          final target = link == null ? null : MarkupView.linkTarget(link);
          TapGestureRecognizer? recognizer;
          if (target != null) {
            recognizer = TapGestureRecognizer()
              ..onTap = () => _launch(context, target);
            _recognizers.add(recognizer);
          }
          children.add(
            TextSpan(
              text: text,
              style: look.run(inline, base),
              recognizer: recognizer,
            ),
          );
        case MarkupImage():
          children.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _Picture(inline, look: look),
            ),
          );
        case MarkupBreak():
          children.add(const TextSpan(text: '\n'));
      }
    }
    return TextSpan(style: base, children: children);
  }

  @override
  Widget build(BuildContext context) =>
      Text.rich(_span, textAlign: widget.textAlign);
}

/// A picture from this device, or a placeholder naming it: web pictures
/// are never downloaded. Tapping it follows its link, if it has one.
class _Picture extends StatefulWidget {
  const _Picture(this.image, {required this.look});

  final MarkupImage image;
  final _Look look;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  File? _file;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void didUpdateWidget(_Picture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.src != widget.image.src ||
        oldWidget.look.baseDirectory != widget.look.baseDirectory) {
      _find();
    }
  }

  /// Where the picture's bytes come from, once, rather than on every
  /// rebuild: a file's existence is a disk access, an embedded picture a
  /// decode.
  void _find() {
    final image = widget.image;
    _file = MarkupView.localImage(image.src, widget.look.baseDirectory);
    _bytes = _file == null
        ? _embedded[image] ??= MarkupView.dataImage(image.src)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final look = widget.look;
    // Decode no wider than the view shows: a photo from a camera would
    // otherwise take tens of megabytes of memory.
    final cacheWidth = math.max(
      1,
      (look.width * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    final alt = image.alt.trim();
    Widget placeholder() => _ImagePlaceholder(alt: alt, look: look);
    final Widget picture;
    if (_file != null) {
      picture = Image.file(
        _file!,
        cacheWidth: cacheWidth,
        semanticLabel: alt.isEmpty ? null : alt,
        errorBuilder: (_, _, _) => placeholder(),
      );
    } else if (_bytes != null) {
      picture = Image.memory(
        _bytes!,
        cacheWidth: cacheWidth,
        semanticLabel: alt.isEmpty ? null : alt,
        errorBuilder: (_, _, _) => placeholder(),
      );
    } else {
      picture = placeholder();
    }
    final link = image.link;
    final target = link == null ? null : MarkupView.linkTarget(link);
    if (target == null) return picture;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _launch(context, target),
        child: picture,
      ),
    );
  }
}

/// Stands in for a picture that is not shown: an image icon and its
/// description.
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.alt, required this.look});

  final String alt;
  final _Look look;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('markup-image-placeholder'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: look.tint,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: look.colors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 16,
            color: look.colors.textTertiary,
            semanticLabel: alt.isEmpty ? 'Picture' : null,
          ),
          if (alt.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                alt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: look.colors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
