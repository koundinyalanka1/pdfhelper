import 'dart:async';
import 'dart:ui';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_text_search.dart';

/// A layout like monospaced text: every character 10 points wide, every line
/// 20 points apart. Spaces get no glyph, as in a real text layer, where most
/// of them are inferred from gaps between glyphs.
PdfPageTextLayout layoutOf(String text) {
  final glyphs = <PdfTextGlyph>[];
  var x = 0.0;
  var line = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\n') {
      line++;
      x = 0;
      continue;
    }
    if (text[i] != ' ') {
      glyphs.add(
        PdfTextGlyph(
          start: i,
          end: i + 1,
          left: x,
          top: line * 20.0,
          right: x + 10,
          bottom: line * 20.0 + 16,
        ),
      );
    }
    x += 10;
  }
  return PdfPageTextLayout(text: text, width: 600, height: 800, glyphs: glyphs);
}

void main() {
  group('findMatches', () {
    List<String> found(String text, String query) => [
      for (final match in PdfTextSearch.findMatches(text, query))
        text.substring(match.start, match.end),
    ];

    test('ignores case', () {
      expect(found('Invoice INVOICE invoice', 'invoice'), [
        'Invoice',
        'INVOICE',
        'invoice',
      ]);
    });

    test('finds a phrase across a line break or extra spaces', () {
      expect(found('total due\nnow: total   due', 'Total due'), [
        'total due',
        'total   due',
      ]);
      expect(found('see page\n\n12', 'page 12'), ['page\n\n12']);
    });

    test('trims the query and reads its spacing loosely', () {
      expect(found('a quick fox', '  quick   fox '), ['quick fox']);
    });

    test('a blank query finds nothing', () {
      expect(PdfTextSearch.findMatches('a b', ''), isEmpty);
      expect(PdfTextSearch.findMatches('a b', '  \n '), isEmpty);
    });

    test('folds ligatures, curly quotes and invisible characters', () {
      expect(found('the ﬁnal ﬂow', 'final flow'), ['ﬁnal ﬂow']);
      expect(found('don’t panic', "don't"), ['don’t']);
      expect(found("don't panic", 'don’t'), ["don't"]);
      expect(found('co­operate', 'cooperate'), ['co­operate']);
      expect(found('zero​width', 'zerowidth'), ['zero​width']);
    });

    test('a letter inside a ligature matches the whole ligature', () {
      // "ffi" is one character holding two f's.
      expect(found('oﬃce', 'f'), ['ﬃ', 'ﬃ']);
      expect(found('oﬃce', 'ice'), ['ﬃce']);
    });

    test('offsets are UTF-16 code units, as in the text layer', () {
      expect(PdfTextSearch.findMatches('\u{1F600} Hello', 'hello'), [
        const TextRange(start: 3, end: 8),
      ]);
    });

    test('matches do not overlap', () {
      expect(PdfTextSearch.findMatches('aaaa', 'aa'), [
        const TextRange(start: 0, end: 2),
        const TextRange(start: 2, end: 4),
      ]);
    });
  });

  group('highlights', () {
    test('a match gets one rectangle per line it covers', () {
      final layout = layoutOf('pay the total\ndue today');
      expect(PdfTextSearch.highlights(layout, 'total due'), [
        [
          const Rect.fromLTRB(80, 0, 130, 16),
          const Rect.fromLTRB(0, 20, 30, 36),
        ],
      ]);
    });

    test('the gap between two words is covered', () {
      final layout = layoutOf('a quick fox');
      expect(PdfTextSearch.highlights(layout, 'quick fox'), [
        [const Rect.fromLTRB(20, 0, 110, 16)],
      ]);
    });

    test('text with no visible glyph is not a match', () {
      // Text outside the crop box is in the text layer, but has no box.
      const layout = PdfPageTextLayout(
        text: 'shown hidden',
        width: 100,
        height: 100,
        glyphs: [
          PdfTextGlyph(
            start: 0,
            end: 5,
            left: 0,
            top: 0,
            right: 50,
            bottom: 10,
          ),
        ],
      );
      expect(PdfTextSearch.highlights(layout, 'hidden'), isEmpty);
      expect(PdfTextSearch.highlights(layout, 'shown'), hasLength(1));
    });
  });

  group('buildIndex', () {
    test('folds each page and drops its whitespace', () {
      expect(PdfTextSearch.buildIndex('Total Due\n12\f\fThe ﬁnal', 3), [
        'totaldue12',
        '',
        'thefinal',
      ]);
    });

    test('is null when the pages do not line up', () {
      expect(PdfTextSearch.buildIndex('one\ftwo\fthree', 2), isNull);
    });
  });

  group('PdfDocumentSearch', () {
    late List<int> reads;
    late List<PdfSearchMatch> shown;

    PdfDocumentSearch searchOver(
      List<String> pages, {
      bool index = true,
      int concurrency = 2,
      int maxMatches = 100000,
      Map<int, Completer<void>> gates = const {},
    }) {
      reads = [];
      shown = [];
      final search = PdfDocumentSearch(
        pageCount: pages.length,
        loadLayout: (page) async {
          reads.add(page);
          await gates[page]?.future;
          return layoutOf(pages[page]);
        },
        loadIndex: index
            ? () async =>
                  PdfTextSearch.buildIndex(pages.join('\f'), pages.length)
            : null,
        onMatch: shown.add,
        concurrency: concurrency,
        maxMatches: maxMatches,
      );
      addTearDown(search.dispose);
      return search;
    }

    test('starts at the reading position and numbers in page order', () async {
      final search = searchOver([
        'alpha',
        'beta alpha',
        'alpha and alpha',
        'gamma',
      ]);
      search.search('ALPHA', startPage: 2);
      expect(search.isSearching, isTrue);
      await pumpEventQueue();

      expect(search.isSearching, isFalse);
      expect(search.matchCount, 4);
      expect(search.currentNumber, 3);
      expect(reads.first, 2, reason: 'the reading page is read first');
      final current = search.current!;
      expect(current.pageIndex, 2);
      expect(current.indexOnPage, 0);
      expect(current.bounds, const Rect.fromLTRB(0, 0, 50, 16));
      expect(current.pageSize, const Size(600, 800));
      expect(shown.single.pageIndex, 2);
      expect(search.currentIndexOn(2), 0);
      expect(search.currentIndexOn(0), isNull);
    });

    test('next and previous wrap around the document', () async {
      final search = searchOver(['alpha', 'beta', 'alpha and alpha']);
      search.search('alpha');
      await pumpEventQueue();
      expect(search.currentNumber, 1);

      search.next();
      expect(search.currentNumber, 2);
      search.next();
      expect(search.currentNumber, 3);
      search.next();
      expect(search.currentNumber, 1);
      search.previous();
      expect(search.currentNumber, 3);
      expect(search.current!.indexOnPage, 1);
      expect(shown, hasLength(5));
    });

    test('pages the plain-text index rules out are never read', () async {
      final search = searchOver(['alpha', 'beta', 'gamma alpha', 'delta']);
      search.search('alpha');
      await pumpEventQueue();
      expect(search.matchCount, 2);
      expect(reads.toSet(), {0, 2});
    });

    test('without an index every page is read', () async {
      final search = searchOver(['alpha', 'beta', 'gamma alpha'], index: false);
      search.search('alpha');
      await pumpEventQueue();
      expect(search.matchCount, 2);
      expect(reads.toSet(), {0, 1, 2});
    });

    test('a new query discards what the old one was still reading', () async {
      final gate = Completer<void>();
      final search = searchOver(
        ['alpha', 'alpha gamma'],
        index: false,
        gates: {0: gate},
      );
      search.search('alpha');
      await pumpEventQueue();
      expect(search.isSearching, isTrue);

      search.search('gamma', startPage: 1);
      gate.complete();
      await pumpEventQueue();

      expect(search.query, 'gamma');
      expect(search.matchCount, 1);
      expect(search.current!.pageIndex, 1);
      expect(shown.map((match) => match.pageIndex), [1]);
    });

    test('a step waits for an unread page instead of skipping it', () async {
      final gate = Completer<void>();
      final search = searchOver(
        ['alpha', 'x', 'alpha'],
        index: false,
        gates: {0: gate},
      );
      search.search('alpha', startPage: 2);
      await pumpEventQueue();
      expect(search.current!.pageIndex, 2);

      search.previous();
      expect(
        search.current!.pageIndex,
        2,
        reason: 'page 1 has no match, but page 0 is still being read',
      );

      gate.complete();
      await pumpEventQueue();
      expect(search.current!.pageIndex, 0);
      expect(search.currentNumber, 1);
    });

    test('the page a step waits for is read next', () async {
      final gate = Completer<void>();
      final search = searchOver(
        ['alpha', 'b', 'c', 'd', 'alpha'],
        index: false,
        concurrency: 1,
        gates: {1: gate},
      );
      search.search('alpha');
      await pumpEventQueue();
      expect(search.current!.pageIndex, 0);

      search.previous();
      gate.complete();
      await pumpEventQueue();

      expect(reads, [0, 1, 4, 2, 3]);
      expect(search.current!.pageIndex, 4);
    });

    test('knows when the document has no text at all', () async {
      final scan = searchOver(['', '', '']);
      scan.search('anything');
      await pumpEventQueue();
      expect(scan.isSearching, isFalse);
      expect(scan.matchCount, 0);
      expect(scan.current, isNull);
      expect(scan.documentHasText, isFalse);
      expect(reads, isEmpty, reason: 'the index rules out every page');

      final unindexed = searchOver(['', ''], index: false);
      unindexed.search('anything');
      await pumpEventQueue();
      expect(unindexed.documentHasText, isFalse);

      final text = searchOver(['some text']);
      text.search('anything');
      await pumpEventQueue();
      expect(text.matchCount, 0);
      expect(text.documentHasText, isTrue);
    });

    test('stops collecting at the match limit', () async {
      final search = searchOver(
        ['a a a', 'a a', 'a'],
        concurrency: 1,
        maxMatches: 4,
      );
      search.search('a');
      await pumpEventQueue();
      expect(search.isSearching, isFalse);
      expect(search.isCapped, isTrue);
      expect(search.matchCount, 4);
      expect(reads, [0, 1]);

      search.previous();
      expect(search.currentNumber, 4, reason: 'steps stay among those found');
    });

    test(
      'a blank query searches nothing, and clear forgets the query',
      () async {
        final search = searchOver(['alpha']);
        search.search('   ');
        expect(search.isSearching, isFalse);
        expect(search.query, isEmpty);

        search.search('alpha');
        await pumpEventQueue();
        expect(search.matchCount, 1);
        search.clear();
        expect(search.query, isEmpty);
        expect(search.matchCount, 0);
        expect(search.current, isNull);
        expect(search.currentIndexOn(0), isNull);
      },
    );
  });
}
