import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size, TextRange;

import 'package:flutter/foundation.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';

import '../utils/error_logger.dart';

/// Find-in-document matching over the PDF text layer.
///
/// Matches are found in [PdfPageTextLayout.text] — the same text, with the
/// same UTF-16 offsets, that text selection uses — so every match maps
/// straight onto the glyph boxes drawn over the page.
class PdfTextSearch {
  PdfTextSearch._();

  /// Every occurrence of [query] in [text], in order and without overlaps.
  ///
  /// Case is ignored, and any run of whitespace matches any other: the text
  /// layer's spaces and line breaks are inferred from glyph positions, so a
  /// phrase that wraps onto the next line must still be found. Ligatures,
  /// curly quotes and invisible characters (soft hyphens, zero-width spaces)
  /// are folded too, because a PDF can encode any of them where the reader
  /// sees — and types — plain letters.
  static List<TextRange> findMatches(String text, String query) {
    final needle = _fold(query).text;
    if (needle.isEmpty) return const [];
    final haystack = _fold(text);
    final matches = <TextRange>[];
    var from = 0;
    while (true) {
      final at = haystack.text.indexOf(needle, from);
      if (at < 0) return matches;
      matches.add(
        TextRange(
          start: haystack.starts[at],
          end: haystack.ends[at + needle.length - 1],
        ),
      );
      from = at + needle.length;
    }
  }

  /// Rectangles covering each of [matches], in page points: one per line a
  /// match spans, so a phrase that wraps is marked as two bars rather than a
  /// box over both lines. A match with no visible glyph gets no rectangles.
  static List<List<Rect>> matchRects(
    PdfPageTextLayout layout,
    List<TextRange> matches,
  ) {
    if (matches.isEmpty) return const [];
    final glyphs = _byStart(layout.glyphs);
    final result = <List<Rect>>[];
    var first = 0;
    for (final match in matches) {
      while (first < glyphs.length && glyphs[first].end <= match.start) {
        first++;
      }
      final rects = <Rect>[];
      for (var i = first; i < glyphs.length; i++) {
        final glyph = glyphs[i];
        if (glyph.start >= match.end) break;
        if (!(glyph.right > glyph.left && glyph.bottom > glyph.top)) continue;
        final rect = Rect.fromLTRB(
          glyph.left,
          glyph.top,
          glyph.right,
          glyph.bottom,
        );
        if (rects.isNotEmpty && _sameLine(rects.last, rect)) {
          rects.last = rects.last.expandToInclude(rect);
        } else {
          rects.add(rect);
        }
      }
      result.add(rects);
    }
    return result;
  }

  /// What to highlight on one page for [query]: the rectangles of each match
  /// that can be seen. The viewer's pages and [PdfDocumentSearch] both count
  /// matches with this, so a page's Nth highlight is the search's Nth match
  /// on that page.
  static List<List<Rect>> highlights(PdfPageTextLayout layout, String query) {
    final rects = matchRects(layout, findMatches(layout.text, query));
    return [
      for (final match in rects)
        if (match.isNotEmpty) match,
    ];
  }

  /// Each page of [documentText], case-folded and without whitespace.
  ///
  /// [documentText] is [PdfCore.extractText] for the whole document: every
  /// page in one pass, separated by form feeds. That text differs from the
  /// layout text only in the spaces and line breaks inferred between glyphs,
  /// so a page whose entry lacks the query, also stripped of whitespace,
  /// cannot contain it.
  ///
  /// Null when the pages do not line up with [pageCount] — a document whose
  /// own text contains a form feed — so that every page gets read instead.
  static List<String>? buildIndex(String documentText, int pageCount) {
    final pages = documentText.split('\f');
    if (pages.length != pageCount) return null;
    return [for (final page in pages) _foldCompact(page)];
  }

  /// [buildIndex] for a document, read on a background isolate. Null when the
  /// text cannot be read in one pass.
  static Future<List<String>?> loadIndex(
    String path, {
    String password = '',
    required int pageCount,
  }) async {
    try {
      return await Isolate.run(
        () => buildIndex(
          PdfCore.extractText(path, password: password),
          pageCount,
        ),
      );
    } catch (error) {
      logError('PdfTextSearch.loadIndex', error);
      return null;
    }
  }
}

/// Reads one page's text layout. [pageIndex] is zero-based.
typedef PdfTextLayoutLoader = Future<PdfPageTextLayout> Function(int pageIndex);

/// The current match, located well enough to scroll it into view.
@immutable
class PdfSearchMatch {
  const PdfSearchMatch({
    required this.pageIndex,
    required this.indexOnPage,
    required this.bounds,
    required this.pageSize,
  });

  /// Zero-based, like the viewer's page indexes.
  final int pageIndex;

  /// Position among the page's own matches, in text order.
  final int indexOnPage;

  /// The whole match in page points with a top-left origin — the
  /// coordinates of [PdfTextGlyph].
  final Rect bounds;

  /// The page's size in the same points.
  final Size pageSize;
}

typedef _Position = ({int page, int index});

/// Searches a whole document and steps through the matches in page order.
///
/// Counting matches means reading every page, and each page's text layout
/// costs a fresh parse of the document. Two things keep that quick. Pages
/// are read starting from the reader's page, so the nearest match appears
/// at once. And one plain-text read of the whole document
/// ([PdfTextSearch.loadIndex], kept for later queries) rules out the pages
/// that cannot contain the query before their layouts are read at all.
///
/// Only a bounding box per match is kept. Pages work out their own
/// highlights from the layout they already hold for text selection.
class PdfDocumentSearch extends ChangeNotifier {
  PdfDocumentSearch({
    required this.pageCount,
    required PdfTextLayoutLoader loadLayout,
    Future<List<String>?> Function()? loadIndex,
    this.onMatch,
    this.maxMatches = 100000,
    this.concurrency = 2,
  }) : _loadLayout = loadLayout,
       _loadIndex = loadIndex,
       _pages = List.filled(pageCount, null);

  final int pageCount;

  /// Called whenever a different match becomes current, to bring it into
  /// view.
  final ValueChanged<PdfSearchMatch>? onMatch;

  /// Matches stop being collected past this many, and [isCapped] says so.
  /// A one-letter query in a long book would otherwise hold millions.
  final int maxMatches;

  /// Pages read at once. Rendering has its own slots in `PdfRaster`; keeping
  /// this low leaves the visible pages drawing while a long document is
  /// searched.
  final int concurrency;

  final PdfTextLayoutLoader _loadLayout;
  final Future<List<String>?> Function()? _loadIndex;
  Future<List<String>?>? _index;

  /// Bumped by every new search, so work for an old one discards itself.
  int _generation = 0;
  String _query = '';
  List<_PageMatches?> _pages;
  final Queue<int> _queue = Queue();
  int? _candidates;
  int _read = 0;
  int _failures = 0;
  int _total = 0;
  bool _searching = false;
  bool _capped = false;
  bool? _hasText;
  _Position? _current;

  /// A step waiting on pages not yet read: where it starts, and which way.
  _Position? _from;
  int _step = 0;

  /// The query the current results are for; empty when there is none.
  String get query => _query;

  /// True until every page that could contain the query has been read.
  bool get isSearching => _searching;

  /// Share of the pages to read that have been read, or null while it is
  /// still being worked out which pages those are.
  double? get progress {
    final candidates = _candidates;
    if (candidates == null) return null;
    return candidates == 0 ? 1 : _read / candidates;
  }

  /// Matches found so far.
  int get matchCount => _total;

  /// Whether [maxMatches] was reached and the remaining pages left unread.
  bool get isCapped => _capped;

  /// False once it is known that no page has text — an image-only scan — so
  /// the viewer can say why nothing was found. Null until then.
  bool? get documentHasText => _hasText;

  /// One-based position of [current] among the matches found so far. It can
  /// still grow while pages before the current one are being read.
  int? get currentNumber {
    final current = _current;
    if (current == null) return null;
    var before = 0;
    for (var page = 0; page < current.page; page++) {
      before += _pages[page]?.length ?? 0;
    }
    return before + current.index + 1;
  }

  PdfSearchMatch? get current {
    final current = _current;
    if (current == null) return null;
    final matches = _pages[current.page]!;
    return PdfSearchMatch(
      pageIndex: current.page,
      indexOnPage: current.index,
      bounds: matches.bounds(current.index),
      pageSize: matches.pageSize,
    );
  }

  /// Which of page [pageIndex]'s matches is current, if any is.
  int? currentIndexOn(int pageIndex) {
    final current = _current;
    return current != null && current.page == pageIndex ? current.index : null;
  }

  /// Start over with [query], reading pages from [startPage] on and wrapping
  /// round to the beginning. The first match on [startPage] or after it
  /// becomes current.
  void search(String query, {int startPage = 0}) {
    _reset();
    if (_fold(query).text.isEmpty || pageCount == 0) {
      notifyListeners();
      return;
    }
    _query = query;
    _searching = true;
    final start = startPage.clamp(0, pageCount - 1);
    // Just before the start page's first match, so stepping forward lands on
    // it.
    _from = (page: start, index: -1);
    _step = 1;
    notifyListeners();
    unawaited(_run(_generation, query, start));
  }

  /// Move to the following match, wrapping from the last to the first.
  void next() => _move(1);

  /// Move to the preceding match, wrapping from the first to the last.
  void previous() => _move(-1);

  /// Drop the query and its results.
  void clear() {
    if (_query.isEmpty && !_searching) return;
    _reset();
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _reset() {
    _generation++;
    _query = '';
    _pages = List.filled(pageCount, null);
    _queue.clear();
    _candidates = null;
    _read = 0;
    _failures = 0;
    _total = 0;
    _searching = false;
    _capped = false;
    _hasText = null;
    _current = null;
    _from = null;
    _step = 0;
  }

  Future<void> _run(int generation, String query, int start) async {
    final index = await (_index ??= _readIndex());
    if (generation != _generation) return;
    final needle = _foldCompact(query);
    for (var i = 0; i < pageCount; i++) {
      final page = (start + i) % pageCount;
      if (index == null || index[page].contains(needle)) {
        _queue.add(page);
      } else {
        _pages[page] = _PageMatches.none;
      }
    }
    if (index != null) _hasText = index.any((page) => page.isNotEmpty);
    _candidates = _queue.length;
    _settle();
    notifyListeners();
    await Future.wait([
      for (var i = 0; i < concurrency; i++) _work(generation, query),
    ]);
    if (generation != _generation) return;
    _searching = false;
    // Every page was read and none had text. A page that failed to load
    // leaves the question open rather than blaming the document.
    if (_failures == 0) _hasText ??= false;
    _settle();
    notifyListeners();
  }

  Future<List<String>?> _readIndex() async {
    final load = _loadIndex;
    if (load == null) return null;
    try {
      final index = await load();
      return index != null && index.length == pageCount ? index : null;
    } catch (error) {
      logError('PdfDocumentSearch.index', error);
      return null;
    }
  }

  Future<void> _work(int generation, String query) async {
    while (generation == _generation && _queue.isNotEmpty) {
      final page = _queue.removeFirst();
      _PageMatches matches;
      try {
        final layout = await _loadLayout(page);
        if (generation != _generation) return;
        if (layout.hasText) _hasText = true;
        matches = _PageMatches.of(layout, query, maxMatches - _total);
      } catch (error) {
        if (generation != _generation) return;
        logError('PdfDocumentSearch.page', error);
        _failures++;
        matches = _PageMatches.none;
      }
      _pages[page] = matches;
      _read++;
      _total += matches.length;
      if (_total >= maxMatches) {
        _capped = true;
        _queue.clear();
      }
      _settle();
      notifyListeners();
    }
  }

  void _move(int step) {
    final from = _from ?? _current;
    if (from == null) return;
    _from = from;
    _step = step;
    _settle();
    notifyListeners();
  }

  /// Complete a pending step once the pages it depends on have been read.
  void _settle() {
    final from = _from;
    if (_step == 0 || from == null) return;
    final (:hit, :wait) = _seek(from, _step);
    if (wait != null) {
      // Read the page in the way next instead of when the scan reaches it.
      if (_queue.remove(wait)) _queue.addFirst(wait);
      return;
    }
    _from = null;
    _step = 0;
    if (hit == null) return;
    _current = hit;
    onMatch?.call(current!);
  }

  /// The match [step] (±1) away from [from], in page order, wrapping at
  /// either end of the document. While pages are still being read, an
  /// unread page in the way is named in `wait` instead: it might hold the
  /// match, and skipping it would step out of order.
  ({_Position? hit, int? wait}) _seek(_Position from, int step) {
    final here = _pages[from.page];
    if (here == null && _searching) return (hit: null, wait: from.page);
    final index = from.index + step;
    if (here != null && index >= 0 && index < here.length) {
      return (hit: (page: from.page, index: index), wait: null);
    }
    for (var i = 1; i <= pageCount; i++) {
      final page = (from.page + step * i) % pageCount;
      final matches = _pages[page];
      if (matches == null) {
        if (_searching) return (hit: null, wait: page);
        continue;
      }
      if (matches.length > 0) {
        final index = step > 0 ? 0 : matches.length - 1;
        return (hit: (page: page, index: index), wait: null);
      }
    }
    return (hit: null, wait: null);
  }
}

/// One page's matches as bounding boxes, four floats per match.
class _PageMatches {
  _PageMatches(this._boxes, this.pageSize);

  static final none = _PageMatches(Float32List(0), Size.zero);

  factory _PageMatches.of(PdfPageTextLayout layout, String query, int limit) {
    final matches = PdfTextSearch.highlights(layout, query);
    final count = math.min(matches.length, math.max(0, limit));
    if (count == 0) return none;
    final boxes = Float32List(count * 4);
    for (var i = 0; i < count; i++) {
      final box = matches[i].reduce((a, b) => a.expandToInclude(b));
      boxes
        ..[i * 4] = box.left
        ..[i * 4 + 1] = box.top
        ..[i * 4 + 2] = box.right
        ..[i * 4 + 3] = box.bottom;
    }
    return _PageMatches(boxes, Size(layout.width, layout.height));
  }

  final Float32List _boxes;
  final Size pageSize;

  int get length => _boxes.length ~/ 4;

  Rect bounds(int index) => Rect.fromLTRB(
    _boxes[index * 4],
    _boxes[index * 4 + 1],
    _boxes[index * 4 + 2],
    _boxes[index * 4 + 3],
  );
}

/// [source] folded for matching, with the source range each folded UTF-16
/// code unit came from.
class _Folded {
  const _Folded(this.text, this.starts, this.ends);

  final String text;
  final List<int> starts;
  final List<int> ends;
}

/// Folds case and look-alike characters, and turns each run of whitespace
/// into one space. Leading and trailing whitespace is dropped.
_Folded _fold(String source) {
  final out = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var spaceStart = -1;
  var spaceEnd = -1;
  var i = 0;
  while (i < source.length) {
    var rune = source.codeUnitAt(i);
    var end = i + 1;
    if (rune >= 0xD800 && rune <= 0xDBFF && end < source.length) {
      final trail = source.codeUnitAt(end);
      if (trail >= 0xDC00 && trail <= 0xDFFF) {
        rune = 0x10000 + ((rune - 0xD800) << 10) + (trail - 0xDC00);
        end++;
      }
    }
    if (_isSpace(rune)) {
      if (spaceStart < 0) spaceStart = i;
      spaceEnd = end;
    } else {
      final folded = _foldRune(rune);
      // Invisible characters fold to nothing, and don't end a whitespace run.
      if (folded.isNotEmpty) {
        if (spaceStart >= 0 && starts.isNotEmpty) {
          out.writeCharCode(0x20);
          starts.add(spaceStart);
          ends.add(spaceEnd);
        }
        spaceStart = -1;
        out.write(folded);
        for (var k = 0; k < folded.length; k++) {
          starts.add(i);
          ends.add(end);
        }
      }
    }
    i = end;
  }
  return _Folded(out.toString(), starts, ends);
}

/// [_fold] without whitespace or offsets, for [PdfTextSearch.buildIndex].
/// It has to fold exactly as [_fold] does, or the index would rule out pages
/// that match.
String _foldCompact(String source) {
  final out = StringBuffer();
  for (final rune in source.runes) {
    if (!_isSpace(rune)) out.write(_foldRune(rune));
  }
  return out.toString();
}

String _foldRune(int rune) {
  if (rune < 0x80) return _asciiFolds[rune];
  return _folds[rune] ??= String.fromCharCode(rune).toLowerCase();
}

/// Lower-cased ASCII, built once: by far most of the text in most PDFs.
final List<String> _asciiFolds = List.generate(
  0x80,
  (c) => String.fromCharCode(c >= 0x41 && c <= 0x5A ? c + 0x20 : c),
  growable: false,
);

/// Characters a reader cannot tell from what they type, then a cache of
/// every other lower-cased character as it is met.
final Map<int, String> _folds = {
  // Soft hyphen, zero-width space and joiners, word joiner, byte order mark.
  0x00AD: '',
  0x200B: '',
  0x200C: '',
  0x200D: '',
  0x2060: '',
  0xFEFF: '',
  // Curly quotes: phone keyboards type them, and PDFs print them.
  0x2018: "'",
  0x2019: "'",
  0x201A: "'",
  0x201B: "'",
  0x201C: '"',
  0x201D: '"',
  0x201E: '"',
  0x201F: '"',
  // Hyphen and non-breaking hyphen, drawn exactly like '-'.
  0x2010: '-',
  0x2011: '-',
  // Latin ligatures, as some fonts encode "fi" and friends.
  0xFB00: 'ff',
  0xFB01: 'fi',
  0xFB02: 'fl',
  0xFB03: 'ffi',
  0xFB04: 'ffl',
  0xFB05: 'st',
  0xFB06: 'st',
};

/// The characters [String.trim] treats as whitespace.
bool _isSpace(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000;

/// The native layout lists glyphs in text order; sort a copy if a future
/// engine does not.
List<PdfTextGlyph> _byStart(List<PdfTextGlyph> glyphs) {
  for (var i = 1; i < glyphs.length; i++) {
    if (glyphs[i].start < glyphs[i - 1].start) {
      return [...glyphs]..sort((a, b) => a.start.compareTo(b.start));
    }
  }
  return glyphs;
}

/// Whether two glyph boxes sit on one line: they overlap vertically by more
/// than half the shorter one.
bool _sameLine(Rect a, Rect b) =>
    math.min(a.bottom, b.bottom) - math.max(a.top, b.top) >
    0.5 * math.min(a.height, b.height);
