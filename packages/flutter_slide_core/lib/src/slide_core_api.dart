// The public Dart API over the Rust presentation engine.

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A failure reported by the presentation engine.
class SlideCoreException implements Exception {
  SlideCoreException(this.code, this.message);

  /// Parse the engine's `"CODE: message"`.
  factory SlideCoreException.fromNative(String raw) {
    final colon = raw.indexOf(': ');
    if (colon <= 0) return SlideCoreException('ERROR', raw);
    return SlideCoreException(
      raw.substring(0, colon),
      raw.substring(colon + 2),
    );
  }

  /// Stable code: `IO`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `CORRUPT`,
  /// `ENCRYPTED`, `TOO_LARGE`, `BAD_HANDLE`, `NOT_FOUND`, `PANIC` or `ERROR`.
  final String code;
  final String message;

  @override
  String toString() => 'SlideCoreException($code): $message';
}

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

/// A fill: solid colour, gradient or picture. Colours are `0xAARRGGBB`.
class SlideFill {
  const SlideFill.solid(this.color)
    : type = 'solid',
      stops = const [],
      angle = 0,
      radial = false,
      part = null;

  const SlideFill._(
    this.type, {
    this.stops = const [],
    this.angle = 0,
    this.radial = false,
    this.part,
  }) : color = 0;

  static SlideFill? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    return switch (j['type']) {
      'solid' => SlideFill.solid(j['color'] as int),
      'gradient' => SlideFill._(
        'gradient',
        stops: [
          for (final s in j['stops'] as List) (_d((s as List)[0]), s[1] as int),
        ],
        angle: _d(j['angle']),
        radial: j['radial'] as bool? ?? false,
      ),
      'image' => SlideFill._('image', part: j['part'] as String),
      _ => null,
    };
  }

  /// `solid`, `gradient` or `image`.
  final String type;
  final int color;
  final List<(double, int)> stops;

  /// Degrees.
  final double angle;
  final bool radial;

  /// The picture's part in the deck.
  final String? part;
}

class SlideLine {
  const SlideLine({
    required this.width,
    required this.color,
    this.dash = 'solid',
    this.head,
    this.tail,
  });

  static SlideLine? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    return SlideLine(
      width: _d(j['width']),
      color: j['color'] as int,
      dash: j['dash'] as String? ?? 'solid',
      head: j['head'] as String?,
      tail: j['tail'] as String?,
    );
  }

  /// Points.
  final double width;
  final int color;
  final String dash;
  final String? head;
  final String? tail;
}

/// One drawing command: `M`, `L`, `C` (with six numbers) or `Z`.
class SlideCmd {
  const SlideCmd(this.op, this.args);
  final String op;
  final List<double> args;
}

class SlidePath {
  const SlidePath({
    required this.cmds,
    this.fill = true,
    this.stroke = true,
    this.shade,
  });

  factory SlidePath.fromJson(Map<String, dynamic> j) {
    final parts = (j['d'] as String? ?? '').split(' ');
    final cmds = <SlideCmd>[];
    var i = 0;
    while (i < parts.length) {
      final op = parts[i++];
      final n = switch (op) {
        'M' || 'L' => 2,
        'C' => 6,
        _ => 0,
      };
      if (op.isEmpty) continue;
      final args = [
        for (var k = 0; k < n && i < parts.length; k++)
          double.tryParse(parts[i++]) ?? 0,
      ];
      cmds.add(SlideCmd(op, args));
    }
    return SlidePath(
      cmds: cmds,
      fill: j['fill'] as bool? ?? true,
      stroke: j['stroke'] as bool? ?? true,
      shade: j['shade'] as String?,
    );
  }

  /// In the item's box, points.
  final List<SlideCmd> cmds;
  final bool fill;
  final bool stroke;

  /// `darken`, `lighten`... for 3-D looking parts.
  final String? shade;
}

class SlideRun {
  const SlideRun({
    required this.text,
    required this.size,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color = 0xFF000000,
    this.font = '',
    this.baseline = 0,
    this.highlight,
    this.link,
  });

  factory SlideRun.fromJson(Map<String, dynamic> j) => SlideRun(
    text: j['t'] as String? ?? '',
    size: _d(j['size']),
    bold: j['b'] as bool? ?? false,
    italic: j['i'] as bool? ?? false,
    underline: j['u'] as bool? ?? false,
    strike: j['s'] as bool? ?? false,
    color: j['color'] as int? ?? 0xFF000000,
    font: j['font'] as String? ?? '',
    baseline: j['baseline'] as int? ?? 0,
    highlight: j['hl'] as int?,
    link: j['link'] as String?,
  );

  final String text;

  /// Points.
  final double size;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int color;
  final String font;

  /// Percent up (superscript) or down.
  final int baseline;
  final int? highlight;
  final String? link;
}

class SlideBullet {
  const SlideBullet(this.text, this.color, this.font, this.size);
  final String text;
  final int color;
  final String font;
  final double size;
}

class SlidePara {
  const SlidePara({
    this.align = 'l',
    this.level = 0,
    this.marginLeft = 0,
    this.indent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.line = 1,
    this.linePoints = false,
    this.endSize = 18,
    this.bullet,
    this.runs = const [],
  });

  factory SlidePara.fromJson(Map<String, dynamic> j) {
    final b = j['bullet'];
    return SlidePara(
      align: j['align'] as String? ?? 'l',
      level: j['level'] as int? ?? 0,
      marginLeft: _d(j['marginLeft']),
      indent: _d(j['indent']),
      spaceBefore: _d(j['spaceBefore']),
      spaceAfter: _d(j['spaceAfter']),
      line: _d(j['line']),
      linePoints: j['linePoints'] as bool? ?? false,
      endSize: _d(j['endSize']),
      bullet: b is Map<String, dynamic>
          ? SlideBullet(
              b['text'] as String,
              b['color'] as int,
              b['font'] as String? ?? '',
              _d(b['size']),
            )
          : null,
      runs: [
        for (final r in j['runs'] as List)
          SlideRun.fromJson(r as Map<String, dynamic>),
      ],
    );
  }

  /// `l`, `ctr`, `r`, `just`.
  final String align;
  final int level;
  final double marginLeft;
  final double indent;
  final double spaceBefore;
  final double spaceAfter;

  /// A multiple of single spacing, or points when [linePoints].
  final double line;
  final bool linePoints;
  final double endSize;
  final SlideBullet? bullet;
  final List<SlideRun> runs;

  String get text => runs.map((r) => r.text).join();
}

class SlideTextBox {
  const SlideTextBox({
    this.insets = const [7.2, 3.6, 7.2, 3.6],
    this.anchor = 't',
    this.wrap = true,
    this.vertical,
    this.prompt,
    this.paras = const [],
  });

  factory SlideTextBox.fromJson(Map<String, dynamic> j) => SlideTextBox(
    insets: [for (final v in j['insets'] as List) _d(v)],
    anchor: j['anchor'] as String? ?? 't',
    wrap: j['wrap'] as bool? ?? true,
    vertical: j['vertical'] as String?,
    prompt: j['prompt'] as String?,
    paras: [
      for (final p in j['paras'] as List)
        SlidePara.fromJson(p as Map<String, dynamic>),
    ],
  );

  /// Left, top, right, bottom, points.
  final List<double> insets;
  final String anchor;
  final bool wrap;
  final String? vertical;

  /// What an empty placeholder shows while editing.
  final String? prompt;
  final List<SlidePara> paras;

  bool get isEmpty => paras.every((p) => p.text.isEmpty);

  /// One string per paragraph, as edits take them.
  List<String> get paragraphs => [for (final p in paras) p.text];
}

class SlideCell {
  const SlideCell({
    required this.text,
    this.fill,
    this.borders = const [null, null, null, null],
    this.colSpan = 1,
    this.rowSpan = 1,
    this.merged = false,
  });

  factory SlideCell.fromJson(Map<String, dynamic> j) => SlideCell(
    text: SlideTextBox.fromJson(j['text'] as Map<String, dynamic>),
    fill: SlideFill.fromJson(j['fill']),
    borders: [for (final b in j['borders'] as List) SlideLine.fromJson(b)],
    colSpan: j['colSpan'] as int? ?? 1,
    rowSpan: j['rowSpan'] as int? ?? 1,
    merged: j['merged'] as bool? ?? false,
  );

  final SlideTextBox text;
  final SlideFill? fill;

  /// Left, top, right, bottom.
  final List<SlideLine?> borders;
  final int colSpan;
  final int rowSpan;
  final bool merged;
}

class SlideTable {
  const SlideTable(this.cols, this.rows);

  factory SlideTable.fromJson(Map<String, dynamic> j) => SlideTable(
    [for (final c in j['cols'] as List) _d(c)],
    [
      for (final r in j['rows'] as List)
        (
          _d(r['height']),
          [
            for (final c in r['cells'] as List)
              SlideCell.fromJson(c as Map<String, dynamic>),
          ],
        ),
    ],
  );

  final List<double> cols;

  /// Row height (points) and cells.
  final List<(double, List<SlideCell>)> rows;
}

/// Kinds of thing on a slide.
enum SlideItemKind {
  shape,
  picture,
  table,
  chart,
  diagram,
  other;

  static SlideItemKind parse(String? s) {
    for (final k in values) {
      if (k.name == s) return k;
    }
    return SlideItemKind.other;
  }
}

class SlideItem {
  const SlideItem({
    required this.id,
    required this.kind,
    this.name = '',
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.rot = 0,
    this.flipH = false,
    this.flipV = false,
    this.paths = const [],
    this.fill,
    this.line,
    this.text,
    this.imagePart,
    this.crop = const [0, 0, 0, 0],
    this.table,
    this.placeholder,
    this.editable = false,
    this.grouped = false,
  });

  factory SlideItem.fromJson(Map<String, dynamic> j) {
    final image = j['image'];
    return SlideItem(
      id: j['id'] as int? ?? 0,
      kind: SlideItemKind.parse(j['kind'] as String?),
      name: j['name'] as String? ?? '',
      x: _d(j['x']),
      y: _d(j['y']),
      w: _d(j['w']),
      h: _d(j['h']),
      rot: _d(j['rot']),
      flipH: j['flipH'] as bool? ?? false,
      flipV: j['flipV'] as bool? ?? false,
      paths: [
        for (final p in j['paths'] as List)
          SlidePath.fromJson(p as Map<String, dynamic>),
      ],
      fill: SlideFill.fromJson(j['fill']),
      line: SlideLine.fromJson(j['line']),
      text: j['text'] == null
          ? null
          : SlideTextBox.fromJson(j['text'] as Map<String, dynamic>),
      imagePart: image is Map<String, dynamic> ? image['part'] as String : null,
      crop: image is Map<String, dynamic>
          ? [for (final c in image['crop'] as List) _d(c)]
          : const [0, 0, 0, 0],
      table: j['table'] == null
          ? null
          : SlideTable.fromJson(j['table'] as Map<String, dynamic>),
      placeholder: j['placeholder'] as String?,
      editable: j['editable'] as bool? ?? false,
      grouped: j['grouped'] as bool? ?? false,
    );
  }

  /// The shape's id on its slide (0 for layout and master decoration).
  final int id;
  final SlideItemKind kind;
  final String name;

  /// Points, before rotation.
  final double x;
  final double y;
  final double w;
  final double h;

  /// Degrees clockwise.
  final double rot;
  final bool flipH;
  final bool flipV;
  final List<SlidePath> paths;
  final SlideFill? fill;
  final SlideLine? line;
  final SlideTextBox? text;
  final String? imagePart;

  /// Crop fractions: left, top, right, bottom.
  final List<double> crop;
  final SlideTable? table;
  final String? placeholder;
  final bool editable;
  final bool grouped;
}

/// A slide, ready to draw.
class SlideScene {
  const SlideScene({
    required this.width,
    required this.height,
    this.hidden = false,
    this.background,
    this.items = const [],
  });

  factory SlideScene.fromJson(Map<String, dynamic> j) => SlideScene(
    width: _d(j['width']),
    height: _d(j['height']),
    hidden: j['hidden'] as bool? ?? false,
    background: SlideFill.fromJson(j['background']),
    items: [
      for (final i in j['items'] as List)
        SlideItem.fromJson(i as Map<String, dynamic>),
    ],
  );

  /// Points.
  final double width;
  final double height;
  final bool hidden;
  final SlideFill? background;
  final List<SlideItem> items;
}

class SlideLayoutInfo {
  const SlideLayoutInfo(this.id, this.name);
  final String id;
  final String name;
}

class SlideDeckInfo {
  const SlideDeckInfo({
    required this.format,
    required this.slideCount,
    required this.width,
    required this.height,
    required this.layouts,
    required this.modified,
    required this.canUndo,
    required this.canRedo,
    required this.warnings,
  });

  factory SlideDeckInfo.fromJson(Map<String, dynamic> j) => SlideDeckInfo(
    format: j['format'] as String,
    slideCount: j['slideCount'] as int,
    width: _d(j['width']),
    height: _d(j['height']),
    layouts: [
      for (final l in j['layouts'] as List)
        SlideLayoutInfo(l['id'] as String, l['name'] as String),
    ],
    modified: j['modified'] as bool? ?? false,
    canUndo: j['canUndo'] as bool? ?? false,
    canRedo: j['canRedo'] as bool? ?? false,
    warnings: (j['warnings'] as List? ?? const []).cast<String>(),
  );

  final String format;
  final int slideCount;
  final double width;
  final double height;
  final List<SlideLayoutInfo> layouts;
  final bool modified;
  final bool canUndo;
  final bool canRedo;
  final List<String> warnings;
}

/// What an edit did: the slide to show and the shape it made or changed.
class SlideEditResult {
  const SlideEditResult(this.slide, this.shape);
  final int? slide;
  final int? shape;
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

SlideCoreException _lastError(SlideBindings b) =>
    SlideCoreException.fromNative(b.lastError().toDartString());

String _takeString(SlideBindings b, Pointer<Utf8> ptr) {
  if (ptr == nullptr) throw _lastError(b);
  try {
    return ptr.toDartString();
  } finally {
    b.freeString(ptr);
  }
}

int _checked(SlideBindings b, int result) {
  if (result < 0) throw _lastError(b);
  return result;
}

/// Entry points of the presentation engine.
class SlideCore {
  SlideCore._();

  /// Whether the native library could be loaded.
  static bool get isAvailable {
    try {
      SlideBindings.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  static String get version => SlideBindings.instance.version().toDartString();

  /// Open a deck on a background isolate.
  static Future<SlideDeck> open(String path, {String? name}) async {
    final handle = await Isolate.run(() {
      final b = SlideBindings.instance;
      return _withStrings([path, name], (p) => _checked(b, b.open(p[0], p[1])));
    });
    return SlideDeck._(handle);
  }

  /// A new 16:9 deck with one title slide.
  static SlideDeck create() {
    final b = SlideBindings.instance;
    return SlideDeck._(_checked(b, b.create()));
  }
}

/// An open deck. Call [close] when done with it.
class SlideDeck {
  SlideDeck._(this.handle);

  /// The engine's handle; usable from any isolate.
  final int handle;

  SlideBindings get _b => SlideBindings.instance;

  SlideDeckInfo info() => SlideDeckInfo.fromJson(
    jsonDecode(_takeString(_b, _b.infoJson(handle))) as Map<String, dynamic>,
  );

  SlideScene scene(int index) => SlideScene.fromJson(
    jsonDecode(_takeString(_b, _b.sceneJson(handle, index)))
        as Map<String, dynamic>,
  );

  /// A slide's scene on a background isolate (thumbnails).
  Future<SlideScene> sceneAsync(int index) {
    final h = handle;
    return Isolate.run(() {
      final b = SlideBindings.instance;
      return SlideScene.fromJson(
        jsonDecode(_takeString(b, b.sceneJson(h, index)))
            as Map<String, dynamic>,
      );
    });
  }

  String notes(int index) => _takeString(_b, _b.notes(handle, index));

  SlideEditResult apply(Map<String, Object?> op) {
    final j =
        jsonDecode(
              _withStrings([
                jsonEncode(op),
              ], (p) => _takeString(_b, _b.apply(handle, p[0]))),
            )
            as Map<String, dynamic>;
    return SlideEditResult(j['slide'] as int?, j['shape'] as int?);
  }

  /// New text for a shape (or a table cell): one string per paragraph,
  /// U+2028 for a line break inside one.
  SlideEditResult setText(
    int slide,
    int shape,
    List<String> paras, {
    (int, int)? cell,
  }) => apply({
    'op': 'setText',
    'slide': slide,
    'shape': shape,
    'cell': cell == null ? null : [cell.$1, cell.$2],
    'paras': paras,
  });

  SlideEditResult formatText(
    int slide,
    int shape, {
    (int, int)? cell,
    bool? bold,
    bool? italic,
    bool? underline,
    double? size,
    int? color,
    String? align,
  }) => apply({
    'op': 'formatText',
    'slide': slide,
    'shape': shape,
    'cell': cell == null ? null : [cell.$1, cell.$2],
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'size': size,
    'color': color,
    'align': align,
  });

  SlideEditResult addTextBox(
    int slide,
    double x,
    double y,
    double w,
    double h, [
    String text = '',
  ]) => apply({
    'op': 'addTextBox',
    'slide': slide,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'text': text,
  });

  SlideEditResult addShape(
    int slide,
    String preset,
    double x,
    double y,
    double w,
    double h,
  ) => apply({
    'op': 'addShape',
    'slide': slide,
    'preset': preset,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  });

  SlideEditResult addImage(
    int slide,
    String path,
    double x,
    double y,
    double w,
    double h,
  ) => apply({
    'op': 'addImage',
    'slide': slide,
    'path': path,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  });

  SlideEditResult deleteShape(int slide, int shape) =>
      apply({'op': 'deleteShape', 'slide': slide, 'shape': shape});

  SlideEditResult moveShape(
    int slide,
    int shape,
    double x,
    double y,
    double w,
    double h,
  ) => apply({
    'op': 'moveShape',
    'slide': slide,
    'shape': shape,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  });

  SlideEditResult addSlide({int? after, String? layout}) =>
      apply({'op': 'addSlide', 'after': after, 'layout': layout});

  SlideEditResult duplicateSlide(int slide) =>
      apply({'op': 'duplicateSlide', 'slide': slide});

  SlideEditResult deleteSlide(int slide) =>
      apply({'op': 'deleteSlide', 'slide': slide});

  SlideEditResult moveSlide(int from, int to) =>
      apply({'op': 'moveSlide', 'from': from, 'to': to});

  SlideEditResult hideSlide(int slide, bool hidden) =>
      apply({'op': 'hideSlide', 'slide': slide, 'hidden': hidden});

  SlideEditResult setNotes(int slide, String text) =>
      apply({'op': 'setNotes', 'slide': slide, 'text': text});

  bool undo() => _checked(_b, _b.undo(handle)) == 1;
  bool redo() => _checked(_b, _b.redo(handle)) == 1;

  /// Write a picture of the deck to [path].
  void savePart(String part, String path) => _withStrings([
    part,
    path,
  ], (p) => _checked(_b, _b.partSave(handle, p[0], p[1])));

  /// Every slide's text and notes.
  String plainText() => _takeString(_b, _b.text(handle));

  /// Save to [path] on a background isolate; returns the format written.
  Future<String> save(String path) {
    final h = handle;
    return Isolate.run(() {
      final b = SlideBindings.instance;
      final j =
          jsonDecode(
                _withStrings([path], (p) => _takeString(b, b.save(h, p[0]))),
              )
              as Map<String, dynamic>;
      return j['format'] as String;
    });
  }

  /// Write a copy to [path] (`txt` for the text) without marking it saved.
  Future<String> writeCopy(String path, {String? format}) {
    final h = handle;
    return Isolate.run(() {
      final b = SlideBindings.instance;
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
