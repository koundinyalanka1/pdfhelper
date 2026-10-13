// The public Dart API over the Rust word-processing engine.

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A failure reported by the word-processing engine.
class WordCoreException implements Exception {
  WordCoreException(this.code, this.message);

  /// Parse the engine's `"CODE: message"`.
  factory WordCoreException.fromNative(String raw) {
    final colon = raw.indexOf(': ');
    if (colon <= 0) return WordCoreException('ERROR', raw);
    return WordCoreException(raw.substring(0, colon), raw.substring(colon + 2));
  }

  /// Stable code: `IO`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `CORRUPT`,
  /// `ENCRYPTED`, `TOO_LARGE`, `BAD_HANDLE`, `NOT_FOUND`, `PANIC` or `ERROR`.
  final String code;

  /// For `INVALID_ARGUMENT`, `UNSUPPORTED` and `ENCRYPTED`, a sentence to
  /// show the person.
  final String message;

  @override
  String toString() => 'WordCoreException($code): $message';
}

const Object _keep = Object();

/// Character formatting.
class RunStyle {
  const RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = 'none',
    this.strike = false,
    this.size = 11,
    this.color,
    this.highlight,
    this.font = 'Calibri',
    this.vert,
    this.caps = false,
    this.smallCaps = false,
    this.hidden = false,
  });

  factory RunStyle.fromJson(Map<String, dynamic> j) => RunStyle(
    bold: j['b'] as bool? ?? false,
    italic: j['i'] as bool? ?? false,
    underline: j['u'] as String? ?? 'none',
    strike: j['s'] as bool? ?? false,
    size: (j['size'] as num?)?.toDouble() ?? 11,
    color: j['color'] as int?,
    highlight: j['hl'] as int?,
    font: j['font'] as String? ?? '',
    vert: j['vert'] as String?,
    caps: j['caps'] as bool? ?? false,
    smallCaps: j['smallCaps'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
  );

  final bool bold;
  final bool italic;

  /// `none`, `single`, `double`, `thick`, `dotted`, `dash`, `wave`, `words`...
  final String underline;
  final bool strike;

  /// Points.
  final double size;

  /// `0xRRGGBB`, or null for automatic.
  final int? color;

  /// `0xRRGGBB` behind the text, or null.
  final int? highlight;
  final String font;

  /// `super`, `sub` or null.
  final String? vert;
  final bool caps;
  final bool smallCaps;
  final bool hidden;

  bool get underlined => underline != 'none';

  Map<String, Object?> toJson() => {
    'b': bold,
    'i': italic,
    'u': underline,
    's': strike,
    'size': size,
    'color': color,
    'hl': highlight,
    'font': font,
    'vert': vert,
    'caps': caps,
    'smallCaps': smallCaps,
    'hidden': hidden,
  };

  /// A copy with some fields changed. Pass null to [color], [highlight] or
  /// [vert] to clear them.
  RunStyle copyWith({
    bool? bold,
    bool? italic,
    String? underline,
    bool? strike,
    double? size,
    Object? color = _keep,
    Object? highlight = _keep,
    String? font,
    Object? vert = _keep,
    bool? caps,
    bool? smallCaps,
    bool? hidden,
  }) => RunStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    size: size ?? this.size,
    color: identical(color, _keep) ? this.color : color as int?,
    highlight: identical(highlight, _keep)
        ? this.highlight
        : highlight as int?,
    font: font ?? this.font,
    vert: identical(vert, _keep) ? this.vert : vert as String?,
    caps: caps ?? this.caps,
    smallCaps: smallCaps ?? this.smallCaps,
    hidden: hidden ?? this.hidden,
  );

  @override
  bool operator ==(Object other) =>
      other is RunStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.size == size &&
      other.color == color &&
      other.highlight == highlight &&
      other.font == font &&
      other.vert == vert &&
      other.caps == caps &&
      other.smallCaps == smallCaps &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(
    bold,
    italic,
    underline,
    strike,
    size,
    color,
    highlight,
    font,
    vert,
    caps,
    smallCaps,
    hidden,
  );

  @override
  String toString() => 'RunStyle(${toJson()})';
}

/// Paragraph alignment.
enum ParaAlign {
  left,
  center,
  right,
  justify;

  static ParaAlign parse(String? s) => switch (s) {
    'center' => ParaAlign.center,
    'right' => ParaAlign.right,
    'justify' => ParaAlign.justify,
    _ => ParaAlign.left,
  };
}

/// Line spacing: `multiple` of single spacing, `exactly` or `atLeast` a
/// height in points.
class LineSpacing {
  const LineSpacing(this.rule, this.value);
  const LineSpacing.multiple(this.value) : rule = 'multiple';

  factory LineSpacing.fromJson(Map<String, dynamic>? j) => j == null
      ? const LineSpacing.multiple(1)
      : LineSpacing(
          j['rule'] as String? ?? 'multiple',
          (j['value'] as num?)?.toDouble() ?? 1,
        );

  final String rule;
  final double value;

  Map<String, Object?> toJson() => {'rule': rule, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is LineSpacing && other.rule == rule && other.value == value;

  @override
  int get hashCode => Object.hash(rule, value);
}

/// Effective paragraph formatting. Lengths in points.
class ParaStyle {
  const ParaStyle({
    this.styleId = '',
    this.styleName = 'Normal',
    this.align = ParaAlign.left,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.firstLine = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.line = const LineSpacing.multiple(1),
    this.keepNext = false,
    this.pageBreakBefore = false,
    this.outline,
    this.shading,
    this.mark = const RunStyle(),
    this.bidi = false,
    this.nextStyle,
  });

  factory ParaStyle.fromJson(Map<String, dynamic> j) => ParaStyle(
    styleId: j['styleId'] as String? ?? '',
    styleName: j['styleName'] as String? ?? 'Normal',
    align: ParaAlign.parse(j['align'] as String?),
    indentLeft: _d(j['indentLeft']),
    indentRight: _d(j['indentRight']),
    firstLine: _d(j['firstLine']),
    spaceBefore: _d(j['spaceBefore']),
    spaceAfter: _d(j['spaceAfter']),
    line: LineSpacing.fromJson(j['line'] as Map<String, dynamic>?),
    keepNext: j['keepNext'] as bool? ?? false,
    pageBreakBefore: j['pageBreakBefore'] as bool? ?? false,
    outline: j['outline'] as int?,
    shading: j['shading'] as int?,
    mark: RunStyle.fromJson(j['mark'] as Map<String, dynamic>? ?? const {}),
    bidi: j['bidi'] as bool? ?? false,
    nextStyle: j['nextStyle'] as String?,
  );

  final String styleId;
  final String styleName;
  final ParaAlign align;
  final double indentLeft;
  final double indentRight;

  /// First-line indent; negative for a hanging indent.
  final double firstLine;
  final double spaceBefore;
  final double spaceAfter;
  final LineSpacing line;
  final bool keepNext;
  final bool pageBreakBefore;

  /// 0 for Heading 1 ... 8; null for body text.
  final int? outline;
  final int? shading;

  /// Formatting of the paragraph mark: what typing into an empty
  /// paragraph uses.
  final RunStyle mark;
  final bool bidi;

  /// The style for a paragraph started at the end of this one.
  final String? nextStyle;
}

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

/// A list paragraph's label.
class ListLabel {
  const ListLabel({
    required this.level,
    required this.text,
    required this.bullet,
    required this.style,
  });

  factory ListLabel.fromJson(Map<String, dynamic> j) => ListLabel(
    level: j['level'] as int? ?? 0,
    text: j['text'] as String? ?? '',
    bullet: j['bullet'] as bool? ?? false,
    style: RunStyle.fromJson(j['style'] as Map<String, dynamic>? ?? const {}),
  );

  final int level;
  final String text;
  final bool bullet;
  final RunStyle style;
}

/// Kinds of non-text content in a paragraph.
enum DocObjectKind {
  image,
  pageBreak,
  columnBreak,
  field,
  note,
  equation,
  shape,
  control,
  other;

  static DocObjectKind parse(String? s) {
    for (final k in values) {
      if (k.name == s) return k;
    }
    return DocObjectKind.other;
  }
}

/// Something in a paragraph that is not plain text, kept as written.
class DocObject {
  const DocObject({
    required this.id,
    required this.kind,
    this.text = '',
    this.width = 0,
    this.height = 0,
    this.alt = '',
    this.style = const RunStyle(),
  });

  factory DocObject.fromJson(Map<String, dynamic> j) => DocObject(
    id: j['id'] as int,
    kind: DocObjectKind.parse(j['kind'] as String?),
    text: j['text'] as String? ?? '',
    width: _d(j['width']),
    height: _d(j['height']),
    alt: j['alt'] as String? ?? '',
    style: RunStyle.fromJson(j['style'] as Map<String, dynamic>? ?? const {}),
  );

  final int id;
  final DocObjectKind kind;

  /// What it shows as text (a field's result, a note's number).
  final String text;

  /// Size in points, for images and shapes.
  final double width;
  final double height;
  final String alt;
  final RunStyle style;
}

/// Content of a paragraph.
sealed class Inline {
  const Inline();
}

class TextInline extends Inline {
  const TextInline(this.text, this.style, [this.link]);
  final String text;
  final RunStyle style;
  final String? link;
}

class ObjectInline extends Inline {
  const ObjectInline(this.object);
  final DocObject object;
}

Inline _inline(Map<String, dynamic> j) {
  final o = j['o'];
  if (o is Map<String, dynamic>) return ObjectInline(DocObject.fromJson(o));
  return TextInline(
    j['t'] as String? ?? '',
    RunStyle.fromJson(j['style'] as Map<String, dynamic>? ?? const {}),
    j['link'] as String?,
  );
}

/// A block of the body.
sealed class DocBlock {
  const DocBlock(this.id);
  final int id;

  static DocBlock fromJson(Map<String, dynamic> j) => switch (j['type']) {
    'para' => ParaBlock.fromJson(j),
    'table' => TableBlock.fromJson(j),
    _ => OtherBlock(j['id'] as int, j['text'] as String? ?? ''),
  };
}

/// A paragraph.
class ParaBlock extends DocBlock {
  const ParaBlock({
    required int id,
    required this.style,
    this.list,
    required this.inlines,
    this.editable = true,
    this.lockedReason,
  }) : super(id);

  factory ParaBlock.fromJson(Map<String, dynamic> j) => ParaBlock(
    id: j['id'] as int,
    style: ParaStyle.fromJson(j['style'] as Map<String, dynamic>),
    list: j['list'] == null
        ? null
        : ListLabel.fromJson(j['list'] as Map<String, dynamic>),
    inlines: [
      for (final i in j['inlines'] as List) _inline(i as Map<String, dynamic>),
    ],
    editable: j['editable'] as bool? ?? true,
    lockedReason: j['locked'] as String?,
  );

  final ParaStyle style;
  final ListLabel? list;
  final List<Inline> inlines;

  /// False when editing here could lose something (tracked changes...).
  final bool editable;
  final String? lockedReason;

  /// The text (objects as their text).
  String get text => inlines
      .map(
        (i) => switch (i) {
          TextInline(:final text) => text,
          ObjectInline(:final object) => object.text,
        },
      )
      .join();

  /// The paragraph as edit content, unchanged.
  List<InlineEdit> get edits => [
    for (final i in inlines)
      switch (i) {
        TextInline(:final text, :final style, :final link) => TextEdit(
          text,
          style,
          link,
        ),
        ObjectInline(:final object) => ObjectEdit(object.id),
      },
  ];
}

class TableCell {
  const TableCell({
    required this.blocks,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.mergedUp = false,
    this.fill,
    this.width = 0,
  });

  factory TableCell.fromJson(Map<String, dynamic> j) => TableCell(
    blocks: [
      for (final b in j['blocks'] as List)
        DocBlock.fromJson(b as Map<String, dynamic>),
    ],
    colSpan: j['colSpan'] as int? ?? 1,
    rowSpan: j['rowSpan'] as int? ?? 1,
    mergedUp: j['mergedUp'] as bool? ?? false,
    fill: j['fill'] as int?,
    width: _d(j['width']),
  );

  final List<DocBlock> blocks;
  final int colSpan;
  final int rowSpan;

  /// Continues the cell above (vertically merged).
  final bool mergedUp;
  final int? fill;

  /// Points.
  final double width;
}

class TableRow {
  const TableRow({required this.cells, this.header = false});

  factory TableRow.fromJson(Map<String, dynamic> j) => TableRow(
    cells: [
      for (final c in j['cells'] as List)
        TableCell.fromJson(c as Map<String, dynamic>),
    ],
    header: j['header'] as bool? ?? false,
  );

  final List<TableCell> cells;
  final bool header;
}

class TableBlock extends DocBlock {
  const TableBlock({
    required int id,
    required this.rows,
    required this.colWidths,
    this.borders = true,
  }) : super(id);

  factory TableBlock.fromJson(Map<String, dynamic> j) => TableBlock(
    id: j['id'] as int,
    rows: [
      for (final r in j['rows'] as List)
        TableRow.fromJson(r as Map<String, dynamic>),
    ],
    colWidths: [for (final w in j['colWidths'] as List) _d(w)],
    borders: j['borders'] as bool? ?? true,
  );

  final List<TableRow> rows;

  /// Points.
  final List<double> colWidths;
  final bool borders;
}

/// Content the engine shows only as its text.
class OtherBlock extends DocBlock {
  const OtherBlock(super.id, this.text);
  final String text;
}

/// Page size and margins, in points.
class PageSetup {
  const PageSetup({
    this.width = 595.3,
    this.height = 841.9,
    this.marginTop = 72,
    this.marginBottom = 72,
    this.marginLeft = 72,
    this.marginRight = 72,
  });

  factory PageSetup.fromJson(Map<String, dynamic> j) => PageSetup(
    width: _d(j['width']),
    height: _d(j['height']),
    marginTop: _d(j['marginTop']),
    marginBottom: _d(j['marginBottom']),
    marginLeft: _d(j['marginLeft']),
    marginRight: _d(j['marginRight']),
  );

  final double width;
  final double height;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  double get textWidth => width - marginLeft - marginRight;
}

/// A paragraph style to offer.
class WordStyleInfo {
  const WordStyleInfo({
    required this.id,
    required this.name,
    this.outline,
    this.defined = true,
  });

  final String id;
  final String name;
  final int? outline;

  /// Whether the document defines it already (others are added on use).
  final bool defined;
}

/// What the document is.
class WordDocInfo {
  const WordDocInfo({
    required this.format,
    required this.saveFormat,
    required this.writesBack,
    required this.blockCount,
    required this.page,
    required this.styles,
    required this.modified,
    required this.canUndo,
    required this.canRedo,
    required this.warnings,
  });

  factory WordDocInfo.fromJson(Map<String, dynamic> j) => WordDocInfo(
    format: j['format'] as String,
    saveFormat: j['saveFormat'] as String,
    writesBack: j['writesBack'] as bool? ?? true,
    blockCount: j['blockCount'] as int? ?? 0,
    page: PageSetup.fromJson(j['page'] as Map<String, dynamic>),
    styles: [
      for (final s in j['styles'] as List)
        WordStyleInfo(
          id: s['id'] as String,
          name: s['name'] as String,
          outline: s['outline'] as int?,
          defined: s['defined'] as bool? ?? true,
        ),
    ],
    modified: j['modified'] as bool? ?? false,
    canUndo: j['canUndo'] as bool? ?? false,
    canRedo: j['canRedo'] as bool? ?? false,
    warnings: (j['warnings'] as List? ?? const []).cast<String>(),
  );

  /// The format read: `docx`, `docm`, `dotx`...
  final String format;

  /// The format saving writes.
  final String saveFormat;

  /// Whether saving writes the file back in its own format.
  final bool writesBack;
  final int blockCount;
  final PageSetup page;
  final List<WordStyleInfo> styles;
  final bool modified;
  final bool canUndo;
  final bool canRedo;
  final List<String> warnings;
}

/// A search match: a paragraph and a UTF-16 range of its text.
class WordMatch {
  const WordMatch(this.para, this.start, this.length);
  final int para;
  final int start;
  final int length;
}

class WordHeading {
  const WordHeading(this.id, this.level, this.text);
  final int id;
  final int level;
  final String text;
}

class WordCounts {
  const WordCounts({
    required this.words,
    required this.characters,
    required this.charactersNoSpaces,
    required this.paragraphs,
  });

  final int words;
  final int characters;
  final int charactersNoSpaces;
  final int paragraphs;
}

/// Content for a paragraph being written.
sealed class InlineEdit {
  const InlineEdit();
  Map<String, Object?> toJson();
}

class TextEdit extends InlineEdit {
  const TextEdit(this.text, this.style, [this.link]);
  final String text;
  final RunStyle style;
  final String? link;

  @override
  Map<String, Object?> toJson() => {
    'text': text,
    'style': style.toJson(),
    'link': link,
  };
}

/// An object of the document, kept as it is.
class ObjectEdit extends InlineEdit {
  const ObjectEdit(this.id);
  final int id;

  @override
  Map<String, Object?> toJson() => {'object': id};
}

/// A paragraph an edit writes.
class NewParagraph {
  const NewParagraph(this.inlines, {this.style});
  final List<InlineEdit> inlines;

  /// Another paragraph style (style id).
  final String? style;

  Map<String, Object?> toJson() => {
    'inlines': [for (final i in inlines) i.toJson()],
    'style': style,
  };
}

/// What an edit did.
class WordEditResult {
  const WordEditResult(this.ids, this.count);

  /// The paragraphs written, in order.
  final List<int> ids;

  /// Replacements made (replace all).
  final int count;
}

T _withStrings<T>(List<String?> values, T Function(List<Pointer<Utf8>>) body) {
  final pointers = [
    for (final value in values) value == null ? nullptr : value.toNativeUtf8(),
  ];
  try {
    return body(pointers);
  } finally {
    for (final p in pointers) {
      if (p != nullptr) malloc.free(p);
    }
  }
}

WordCoreException _lastError(WordBindings b) =>
    WordCoreException.fromNative(b.lastError().toDartString());

String _takeString(WordBindings b, Pointer<Utf8> ptr) {
  if (ptr == nullptr) throw _lastError(b);
  try {
    return ptr.toDartString();
  } finally {
    b.freeString(ptr);
  }
}

int _checked(WordBindings b, int result) {
  if (result < 0) throw _lastError(b);
  return result;
}

/// Entry points of the word-processing engine.
class WordCore {
  WordCore._();

  /// Whether the native library could be loaded.
  static bool get isAvailable {
    try {
      WordBindings.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The native library's version, e.g. `0.1.0`.
  static String get version => WordBindings.instance.version().toDartString();

  /// Open a document on a background isolate. [name] supplies the file
  /// name when [path] has no extension.
  static Future<WordDocument> open(String path, {String? name}) async {
    final handle = await Isolate.run(() {
      final b = WordBindings.instance;
      return _withStrings([path, name], (p) => _checked(b, b.open(p[0], p[1])));
    });
    return WordDocument._(handle);
  }

  /// A new, empty Word document.
  static WordDocument create() {
    final b = WordBindings.instance;
    return WordDocument._(_checked(b, b.create()));
  }
}

/// An open document. Call [close] when done with it.
class WordDocument {
  WordDocument._(this.handle);

  /// The engine's handle; usable from any isolate.
  final int handle;

  WordBindings get _b => WordBindings.instance;

  WordDocInfo info() => WordDocInfo.fromJson(
    jsonDecode(_takeString(_b, _b.infoJson(handle))) as Map<String, dynamic>,
  );

  /// Blocks `from..from + count` of the body.
  List<DocBlock> blocks(int from, int count) {
    final list =
        jsonDecode(_takeString(_b, _b.blocksJson(handle, from, count))) as List;
    return [for (final b in list) DocBlock.fromJson(b as Map<String, dynamic>)];
  }

  /// One paragraph, anywhere (including table cells); null when gone.
  ParaBlock? paragraph(int id) {
    final j = jsonDecode(_takeString(_b, _b.paragraphJson(handle, id)));
    return j == null ? null : ParaBlock.fromJson(j as Map<String, dynamic>);
  }

  /// Where a block (or the block holding a paragraph) is in the body.
  int? blockIndex(int id) {
    final i = _b.blockIndex(handle, id);
    return i < 0 ? null : i;
  }

  /// Apply an edit (see `word_apply` in the Rust FFI layer).
  WordEditResult apply(Map<String, Object?> op) {
    final j =
        jsonDecode(
              _withStrings([
                jsonEncode(op),
              ], (p) => _takeString(_b, _b.apply(handle, p[0]))),
            )
            as Map<String, dynamic>;
    return WordEditResult(
      (j['ids'] as List).cast<int>(),
      j['count'] as int? ?? 0,
    );
  }

  /// Replace paragraphs [first]..[last] (siblings) by [paras].
  WordEditResult setParagraphs(
    int first,
    int last,
    List<NewParagraph> paras,
  ) => apply({
    'op': 'setParas',
    'first': first,
    'last': last,
    'paras': [for (final p in paras) p.toJson()],
  });

  /// Change paragraph properties; null leaves a property as it is.
  WordEditResult patch(
    List<int> ids, {
    ParaAlign? align,
    String? styleId,
    String? list,
    int? indentSteps,
    double? spaceBefore,
    double? spaceAfter,
    LineSpacing? line,
    bool? pageBreakBefore,
    bool? keepNext,
  }) => apply({
    'op': 'patch',
    'ids': ids,
    'align': align?.name,
    'styleId': styleId,
    'list': list,
    'indentSteps': indentSteps,
    'spaceBefore': spaceBefore,
    'spaceAfter': spaceAfter,
    'line': line?.toJson(),
    'pageBreakBefore': pageBreakBefore,
    'keepNext': keepNext,
  });

  WordEditResult insertTable(int after, int rows, int cols) =>
      apply({'op': 'insertTable', 'after': after, 'rows': rows, 'cols': cols});

  WordEditResult insertPageBreak(int after) =>
      apply({'op': 'insertPageBreak', 'after': after});

  /// Put the picture at [path] after paragraph [after], [width] x [height]
  /// points.
  WordEditResult insertImage(
    int after,
    String path,
    double width,
    double height,
  ) => apply({
    'op': 'insertImage',
    'after': after,
    'path': path,
    'width': width,
    'height': height,
  });

  WordEditResult deleteBlock(int id) => apply({'op': 'deleteBlock', 'id': id});

  /// `insertRow`, `deleteRow`, `insertCol` or `deleteCol` at row or column
  /// [at]; [after] puts an inserted one below or to the right.
  WordEditResult tableOp(
    int table,
    String action,
    int at, {
    bool after = false,
  }) => apply({
    'op': 'table',
    'id': table,
    'action': action,
    'at': at,
    'after': after,
  });

  WordEditResult replaceAll(
    String find,
    String replace, {
    bool matchCase = false,
    bool wholeWord = false,
  }) => apply({
    'op': 'replaceAll',
    'find': find,
    'replace': replace,
    'matchCase': matchCase,
    'wholeWord': wholeWord,
  });

  bool undo() => _checked(_b, _b.undo(handle)) == 1;
  bool redo() => _checked(_b, _b.redo(handle)) == 1;

  List<WordMatch> find(
    String query, {
    bool matchCase = false,
    bool wholeWord = false,
  }) {
    final options = jsonEncode({'matchCase': matchCase, 'wholeWord': wholeWord});
    final list =
        jsonDecode(
              _withStrings([
                query,
                options,
              ], (p) => _takeString(_b, _b.findJson(handle, p[0], p[1]))),
            )
            as List;
    return [
      for (final m in list)
        WordMatch(m['para'] as int, m['start'] as int, m['len'] as int),
    ];
  }

  List<WordHeading> outline() {
    final list = jsonDecode(_takeString(_b, _b.outlineJson(handle))) as List;
    return [
      for (final h in list)
        WordHeading(h['id'] as int, h['level'] as int, h['text'] as String),
    ];
  }

  WordCounts counts() {
    final j =
        jsonDecode(_takeString(_b, _b.countsJson(handle)))
            as Map<String, dynamic>;
    return WordCounts(
      words: j['words'] as int,
      characters: j['characters'] as int,
      charactersNoSpaces: j['charactersNoSpaces'] as int,
      paragraphs: j['paragraphs'] as int,
    );
  }

  /// The document as plain text.
  String plainText() => _takeString(_b, _b.text(handle));

  /// Write an image object's bytes to [path]; returns its extension.
  String saveImage(int object, String path) => _withStrings([
    path,
  ], (p) => _takeString(_b, _b.imageSave(handle, object, p[0])));

  /// Save to [path] on a background isolate; returns the format written
  /// (`docx`...).
  Future<String> save(String path) {
    final h = handle;
    return Isolate.run(() {
      final b = WordBindings.instance;
      final j =
          jsonDecode(_withStrings([path], (p) => _takeString(b, b.save(h, p[0]))))
              as Map<String, dynamic>;
      return j['format'] as String;
    });
  }

  /// Write a copy to [path] (`txt` for plain text) without marking the
  /// document saved.
  Future<String> writeCopy(String path, {String? format}) {
    final h = handle;
    return Isolate.run(() {
      final b = WordBindings.instance;
      final j =
          jsonDecode(
                _withStrings([
                  path,
                  format,
                ], (p) => _takeString(b, b.writeCopy(h, p[0], p[1]))),
              )
              as Map<String, dynamic>;
      return j['format'] as String;
    });
  }

  void close() => _b.close(handle);
}
