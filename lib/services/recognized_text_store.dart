import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/error_logger.dart';

/// What OCR found on a document's scanned pages, by 0-based page index.
class RecognizedText {
  const RecognizedText({this.pages = const {}, this.skipped = const {}});

  static const none = RecognizedText();

  /// Pages with recognized text, each with the layout selection and find use.
  final Map<int, PdfOcrPage> pages;

  /// Pages OCR went through without adding text — nothing legible on them,
  /// or text of their own already — so they are not offered again.
  final Set<int> skipped;

  bool get isEmpty => pages.isEmpty && skipped.isEmpty;

  /// Whether OCR has already been through page [index].
  bool hasRead(int index) =>
      pages.containsKey(index) || skipped.contains(index);
}

/// Text recognized in a scanned document that the reader chose to keep in
/// the app ("Keep in DocHelper") instead of saving a new PDF.
///
/// It is filed under the document's content, not its path. A PDF opened from
/// another app arrives as a new temporary copy every time, and a library
/// file can be renamed or moved, yet each is still the document whose pages
/// were read. A file whose bytes change is a different document and has to
/// be read again.
///
/// Callers keep password-protected documents out of here: their text would
/// sit on disk without the protection the PDF itself has.
class RecognizedTextStore {
  RecognizedTextStore._();

  /// Stored text is kept to about this many bytes on disk, the documents
  /// opened least recently dropped first.
  static const int maxBytes = 64 * 1024 * 1024;

  static const int _version = 1;

  /// What was kept for [path]. [RecognizedText.none] when nothing was kept,
  /// when the file has changed since, or when what was kept cannot be read.
  static Future<RecognizedText> load(
    String path, {
    required int pageCount,
  }) async {
    try {
      final dir = await _directory();
      final found = await Isolate.run(() async {
        final file = File('${dir.path}/${await _fingerprint(path)}.json.gz');
        if (!file.existsSync()) return null;
        final json = jsonDecode(
          utf8.decode(gzip.decode(file.readAsBytesSync())),
        );
        return (file: file, text: _decode(json, pageCount));
      });
      if (found == null) return RecognizedText.none;
      // Opening a document counts as using it, so it is kept the longest.
      unawaited(
        found.file.setLastModified(DateTime.now()).catchError((Object _) {}),
      );
      return found.text;
    } catch (error) {
      logError('RecognizedTextStore.load', error);
      return RecognizedText.none;
    }
  }

  /// Keep [text], recognized in [path], for the next time it is opened.
  /// Replaces whatever was kept for it before.
  static Future<void> save(
    String path, {
    required int pageCount,
    required RecognizedText text,
  }) async {
    final dir = await _directory();
    final json = _encode(pageCount, text);
    await Isolate.run(() async {
      final file = File('${dir.path}/${await _fingerprint(path)}.json.gz');
      final partial = File('${file.path}.partial');
      partial.writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(json))));
      partial.renameSync(file.path);
      _trim(dir, keep: file.path);
    });
  }

  static Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/recognized_text').create(recursive: true);
  }

  /// Drop the least recently opened documents until the rest fit in
  /// [maxBytes]. [keep], just saved, always stays.
  static void _trim(Directory dir, {required String keep}) {
    final files = [
      for (final entity in dir.listSync())
        if (entity is File && entity.path.endsWith('.json.gz'))
          (file: entity, stat: entity.statSync()),
    ]..sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var total = files.fold(0, (sum, entry) => sum + entry.stat.size);
    for (final entry in files) {
      if (total <= maxBytes) break;
      if (entry.file.path == keep) continue;
      try {
        entry.file.deleteSync();
        total -= entry.stat.size;
      } catch (_) {}
    }
  }
}

/// Bytes read from each of the start, middle and end of a file to tell it
/// apart from others of the same length.
const int _sampleBytes = 64 * 1024;

/// The file's length and an FNV-1a hash of its sampled bytes, as a name.
///
/// Hashing all of a large scan on every open would be slow. Edits change a
/// PDF's length or its final bytes, where the cross-reference table is
/// written, so sampling still sees them.
Future<String> _fingerprint(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    var hash = 0xcbf29ce484222325;
    final starts = {
      0,
      math.max(0, length ~/ 2 - _sampleBytes ~/ 2),
      math.max(0, length - _sampleBytes),
    };
    for (final start in starts) {
      await file.setPosition(start);
      for (final byte in await file.read(_sampleBytes)) {
        hash = (hash ^ byte) * 0x100000001b3;
      }
    }
    String hex(int value) => value.toRadixString(16).padLeft(8, '0');
    return '${length.toRadixString(16)}-'
        '${hex(hash >>> 32)}${hex(hash & 0xffffffff)}';
  } finally {
    await file.close();
  }
}

Map<String, Object?> _encode(int pageCount, RecognizedText text) => {
  'version': RecognizedTextStore._version,
  'pageCount': pageCount,
  'skipped': [for (final index in text.skipped) index + 1],
  'pages': [
    for (final page in text.pages.values)
      if (page.layout case final layout?)
        {
          'page': page.page,
          'text': page.text,
          'confidence': page.confidence,
          'lines': [for (final line in page.lines) line.toJson()],
          'layout': {
            'text': layout.text,
            'width': layout.width,
            'height': layout.height,
            // Six numbers per glyph rather than an object each: a dense page
            // has thousands of glyphs.
            'glyphs': [
              for (final glyph in layout.glyphs) ...[
                glyph.start,
                glyph.end,
                _round(glyph.left),
                _round(glyph.top),
                _round(glyph.right),
                _round(glyph.bottom),
              ],
            ],
          },
        },
  ],
};

/// Hundredths of a point are far finer than any glyph box needs.
double _round(double value) => (value * 100).roundToDouble() / 100;

RecognizedText _decode(Object? json, int pageCount) {
  if (json is! Map ||
      json['version'] != RecognizedTextStore._version ||
      json['pageCount'] != pageCount) {
    return RecognizedText.none;
  }
  bool inRange(int number) => number >= 1 && number <= pageCount;
  final pages = <int, PdfOcrPage>{};
  for (final raw in json['pages'] as List) {
    final page = (raw as Map).cast<String, dynamic>();
    final number = page['page'] as int;
    if (!inRange(number)) continue;
    final layout = (page['layout'] as Map).cast<String, dynamic>();
    final text = layout['text'] as String;
    final numbers = (layout['glyphs'] as List).cast<num>();
    pages[number - 1] = PdfOcrPage(
      page: number,
      status: PdfOcrStatus.recognized,
      text: page['text'] as String,
      confidence: (page['confidence'] as num).toDouble(),
      lines: List.unmodifiable([
        for (final line in page['lines'] as List)
          PdfOcrLine.fromJson((line as Map).cast<String, dynamic>()),
      ]),
      layout: PdfPageTextLayout(
        text: text,
        width: (layout['width'] as num).toDouble(),
        height: (layout['height'] as num).toDouble(),
        glyphs: List.unmodifiable([
          for (var i = 0; i + 5 < numbers.length; i += 6)
            if (numbers[i + 1].toInt() <= text.length)
              PdfTextGlyph(
                start: numbers[i].toInt(),
                end: numbers[i + 1].toInt(),
                left: numbers[i + 2].toDouble(),
                top: numbers[i + 3].toDouble(),
                right: numbers[i + 4].toDouble(),
                bottom: numbers[i + 5].toDouble(),
              ),
        ]),
      ),
    );
  }
  return RecognizedText(
    pages: pages,
    skipped: {
      for (final number in (json['skipped'] as List? ?? const []).cast<int>())
        if (inRange(number) && !pages.containsKey(number - 1)) number - 1,
    },
  );
}
