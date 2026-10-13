// The public Dart API over the Rust text engine.

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A failure reported by the text engine.
class TextCoreException implements Exception {
  TextCoreException(this.code, this.message);

  /// Parse the engine's `"CODE: message"`.
  factory TextCoreException.fromNative(String raw) {
    final colon = raw.indexOf(': ');
    if (colon <= 0) return TextCoreException('ERROR', raw);
    return TextCoreException(
      raw.substring(0, colon),
      raw.substring(colon + 2),
    );
  }

  /// Stable code: `IO`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `TOO_LARGE`,
  /// `BAD_HANDLE`, `PANIC` or `ERROR`.
  final String code;
  final String message;

  @override
  String toString() => 'TextCoreException($code): $message';
}

/// How a file breaks its lines.
enum LineEnding {
  lf('LF', 'Android, Linux, Mac (LF)'),
  crlf('CRLF', 'Windows (CRLF)'),
  cr('CR', 'Old Mac (CR)');

  const LineEnding(this.code, this.label);

  /// The engine's name for it.
  final String code;

  /// How to describe it to a person.
  final String label;

  static LineEnding fromCode(String? code) =>
      values.firstWhere((e) => e.code == code, orElse: () => LineEnding.lf);
}

/// What the engine knows about an open text file.
class TextFileInfo {
  const TextFileInfo({
    required this.encoding,
    required this.bom,
    required this.lineEnding,
    required this.mixedLineEndings,
    required this.decodeErrors,
    required this.confident,
    required this.binary,
    required this.modified,
    required this.canReinterpret,
    required this.lines,
    this.words,
    this.characters,
    this.length,
    this.unmappable,
  });

  factory TextFileInfo.fromJson(Map<String, dynamic> json) => TextFileInfo(
    encoding: json['encoding'] as String? ?? 'UTF-8',
    bom: json['bom'] == true,
    lineEnding: LineEnding.fromCode(json['lineEnding'] as String?),
    mixedLineEndings: json['mixedLineEndings'] == true,
    decodeErrors: json['decodeErrors'] as int? ?? 0,
    confident: json['confident'] != false,
    binary: json['binary'] == true,
    modified: json['modified'] == true,
    canReinterpret: json['canReinterpret'] == true,
    lines: json['lines'] as int? ?? 0,
    words: json['words'] as int?,
    characters: json['characters'] as int?,
    length: json['length'] as int?,
    unmappable: json['unmappable'] as int?,
  );

  /// The encoding's name, e.g. `UTF-8` or `windows-1252`.
  final String encoding;

  /// Whether the file starts with a byte-order mark (and will be saved
  /// with one).
  final bool bom;
  final LineEnding lineEnding;

  /// The file mixed line-ending styles; saving uses [lineEnding] throughout.
  final bool mixedLineEndings;

  /// Characters that could not be read and show as U+FFFD.
  final int decodeErrors;

  /// False when the encoding was a guess (the user may need to pick one).
  final bool confident;

  /// The file looks like binary data rather than text.
  final bool binary;
  final bool modified;

  /// The file is unedited and can still be re-read in another encoding.
  final bool canReinterpret;
  final int lines;

  /// Only present when requested with `withStats`.
  final int? words;
  final int? characters;

  /// Length in UTF-16 code units (Dart string length).
  final int? length;

  /// Characters the chosen encoding cannot save (written as `?`).
  final int? unmappable;
}

/// An encoding the engine supports.
class TextEncodingInfo {
  const TextEncodingInfo(this.name, {required this.unicode});

  final String name;

  /// Unicode encodings can save any text.
  final bool unicode;
}

/// A match, as UTF-16 offsets into the document's text, and the 0-based
/// line it starts on.
class TextMatch {
  const TextMatch(this.start, this.end, [this.line = 0]);

  final int start;
  final int end;
  final int line;

  @override
  bool operator ==(Object other) =>
      other is TextMatch &&
      other.start == start &&
      other.end == end &&
      other.line == line;

  @override
  int get hashCode => Object.hash(start, end, line);

  @override
  String toString() => 'TextMatch($start, $end, line $line)';
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

TextCoreException _lastError(TextBindings b) =>
    TextCoreException.fromNative(b.lastError().toDartString());

String _takeString(TextBindings b, Pointer<Utf8> ptr) {
  if (ptr == nullptr) throw _lastError(b);
  try {
    return ptr.toDartString();
  } finally {
    b.freeString(ptr);
  }
}

int _checked(TextBindings b, int result) {
  if (result < 0) throw _lastError(b);
  return result;
}

/// Entry points of the text engine.
class TextCore {
  TextCore._();

  /// Whether the native library could be loaded.
  static bool get isAvailable {
    try {
      TextBindings.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Open a text file on a background isolate. [fallbackEncoding] is used
  /// when the bytes could be any single-byte code page (defaults to
  /// windows-1252).
  static Future<TextDocument> open(
    String path, {
    String? fallbackEncoding,
  }) async {
    final handle = await Isolate.run(() {
      final b = TextBindings.instance;
      return _withStrings([path, fallbackEncoding], (p) {
        final h = b.open(p[0], p[1]);
        if (h < 0) throw _lastError(b);
        return h;
      });
    });
    return TextDocument._(handle);
  }

  /// A new, empty UTF-8 document.
  static TextDocument create() {
    final b = TextBindings.instance;
    return TextDocument._(_checked(b, b.create()));
  }

  /// Every encoding a file can be read or saved in.
  static List<TextEncodingInfo> encodings() {
    final b = TextBindings.instance;
    final list = jsonDecode(_takeString(b, b.encodingsJson())) as List;
    return [
      for (final e in list.cast<Map<String, dynamic>>())
        TextEncodingInfo(e['name'] as String, unicode: e['unicode'] == true),
    ];
  }

  /// Re-indent JSON with [indent] spaces, or compact it when [indent] is 0.
  /// Invalid JSON throws a [TextCoreException] whose message names the line
  /// and column.
  static String formatJson(String text, {int indent = 2}) {
    final b = TextBindings.instance;
    return _withStrings([text], (p) => _takeString(b, b.formatJson(p[0], indent)));
  }
}

/// An open text file. Call [close] when done with it.
class TextDocument {
  TextDocument._(this.handle);

  /// The engine's handle; usable from any isolate.
  final int handle;
  bool _closed = false;

  bool get isClosed => _closed;

  TextBindings get _b {
    if (_closed) throw StateError('The document is closed.');
    return TextBindings.instance;
  }

  /// The file's format. [withStats] adds word, character and length counts
  /// and the number of unsavable characters, which reads the whole text.
  TextFileInfo info({bool withStats = false}) {
    final b = _b;
    final json = _takeString(b, b.infoJson(handle, withStats ? 1 : 0));
    return TextFileInfo.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// The whole text, with `\n` line breaks.
  String get text => _takeString(_b, _b.get(handle));

  /// Replace the whole text. Returns whether anything changed.
  bool setText(String text) {
    final b = _b;
    return _withStrings([text], (p) => _checked(b, b.set(handle, p[0])) == 1);
  }

  /// Lines `first` to `first + count - 1` (0-based), without line breaks.
  List<String> lines(int first, int count) {
    final b = _b;
    final list = jsonDecode(_takeString(b, b.linesJson(handle, first, count)));
    return (list as List).cast<String>();
  }

  /// Find [query] in the text.
  List<TextMatch> find(
    String query, {
    bool matchCase = false,
    bool wholeWord = false,
    int limit = 10000,
  }) {
    final b = _b;
    final flags = (matchCase ? 1 : 0) | (wholeWord ? 2 : 0);
    final json = _withStrings(
      [query],
      (p) => _takeString(b, b.findJson(handle, p[0], flags, limit)),
    );
    return [
      for (final found in (jsonDecode(json) as List).cast<List>())
        TextMatch(found[0] as int, found[1] as int, found[2] as int),
    ];
  }

  /// Replace every match of [query]. Returns how many were replaced.
  int replaceAll(
    String query,
    String replacement, {
    bool matchCase = false,
    bool wholeWord = false,
  }) {
    final b = _b;
    final flags = (matchCase ? 1 : 0) | (wholeWord ? 2 : 0);
    return _withStrings(
      [query, replacement],
      (p) => _checked(b, b.replaceAll(handle, p[0], p[1], flags)),
    );
  }

  /// Choose how the file will be saved. Null leaves a setting unchanged.
  void setFormat({String? encoding, bool? bom, LineEnding? lineEnding}) {
    final b = _b;
    _withStrings(
      [encoding, lineEnding?.code],
      (p) => _checked(
        b,
        b.setFormat(handle, p[0], bom == null ? -1 : (bom ? 1 : 0), p[1]),
      ),
    );
  }

  /// Re-read the unedited file in [encoding].
  void reinterpret(String encoding) {
    final b = _b;
    _withStrings([encoding], (p) => _checked(b, b.reinterpret(handle, p[0])));
  }

  /// Save to [path] atomically on a background isolate. Returns how many
  /// characters the encoding could not represent (written as `?`).
  Future<int> save(String path) {
    _b; // Throws if closed.
    final handle = this.handle;
    return Isolate.run(() {
      final b = TextBindings.instance;
      return _withStrings([path], (p) => _checked(b, b.save(handle, p[0])));
    });
  }

  /// Write the current text to [path] without marking the document saved
  /// (for sharing a snapshot). Returns how many characters the encoding
  /// could not represent.
  Future<int> writeCopy(String path) {
    _b; // Throws if closed.
    final handle = this.handle;
    return Isolate.run(() {
      final b = TextBindings.instance;
      return _withStrings(
        [path],
        (p) => _checked(b, b.writeCopy(handle, p[0])),
      );
    });
  }

  /// Free the document. Safe to call twice.
  void close() {
    if (_closed) return;
    _closed = true;
    TextBindings.instance.close(handle);
  }
}
