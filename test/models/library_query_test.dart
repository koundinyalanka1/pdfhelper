import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/library_query.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';

PdfFileEntry entry(
  String name, {
  int size = 1000,
  int modified = 0,
  String folder = 'Documents',
  bool appOwned = false,
  String? path,
}) {
  return PdfFileEntry(
    path: path ?? '/storage/$folder/$name',
    name: name,
    sizeBytes: size,
    modifiedMs: modified,
    folder: folder,
    isAppOwned: appOwned,
  );
}

void main() {
  final alpha = entry('Alpha.pdf', size: 300, modified: 300);
  final beta = entry('beta.pdf', size: 100, modified: 100);
  final gamma = entry('Gamma.pdf', size: 200, modified: 200, appOwned: true);
  final all = [alpha, beta, gamma];

  List<String> names(List<PdfFileEntry> entries) =>
      entries.map((e) => e.name).toList();

  group('filters', () {
    test('all returns everything', () {
      expect(const LibraryQuery().apply(all), hasLength(3));
    });

    test('created keeps only app-owned files', () {
      final result = const LibraryQuery(filter: LibraryFilter.created).apply(all);
      expect(names(result), ['Gamma.pdf']);
    });

    test('starred keeps only starred paths', () {
      final result = LibraryQuery(
        filter: LibraryFilter.starred,
        starred: {beta.path},
      ).apply(all);
      expect(names(result), ['beta.pdf']);
    });

    test('starred is empty when nothing is starred', () {
      expect(
        const LibraryQuery(filter: LibraryFilter.starred).apply(all),
        isEmpty,
      );
    });

    test('recent keeps recency order, not the sort order', () {
      // beta was opened most recently, so it leads — even though the query
      // asks for name sorting, which would put Alpha first.
      final result = LibraryQuery(
        filter: LibraryFilter.recent,
        sort: LibrarySort.name,
        recents: [beta.path, gamma.path, alpha.path],
      ).apply(all);
      expect(names(result), ['beta.pdf', 'Gamma.pdf', 'Alpha.pdf']);
    });

    test('recent drops entries that were never opened', () {
      final result = LibraryQuery(
        filter: LibraryFilter.recent,
        recents: [gamma.path],
      ).apply(all);
      expect(names(result), ['Gamma.pdf']);
    });

    test('recent ignores a recorded path with no matching entry', () {
      final result = LibraryQuery(
        filter: LibraryFilter.recent,
        recents: ['/gone/deleted.pdf', alpha.path],
      ).apply(all);
      expect(names(result), ['Alpha.pdf']);
    });
  });

  group('sorting', () {
    test('newest first by modified time', () {
      final result = const LibraryQuery(sort: LibrarySort.newest).apply(all);
      expect(names(result), ['Alpha.pdf', 'Gamma.pdf', 'beta.pdf']);
    });

    test('by name, case-insensitively', () {
      // A case-sensitive sort would put every capitalised name before
      // "beta.pdf", which is not what a person reading the list expects.
      final result = const LibraryQuery(sort: LibrarySort.name).apply(all);
      expect(names(result), ['Alpha.pdf', 'beta.pdf', 'Gamma.pdf']);
    });

    test('by size, largest first', () {
      final result = const LibraryQuery(sort: LibrarySort.largest).apply(all);
      expect(names(result), ['Alpha.pdf', 'Gamma.pdf', 'beta.pdf']);
    });

    test('does not mutate the input list', () {
      final input = [...all];
      const LibraryQuery(sort: LibrarySort.name).apply(input);
      expect(identical(input[0], alpha), isTrue);
      expect(names(input), ['Alpha.pdf', 'beta.pdf', 'Gamma.pdf']);
    });
  });

  group('search', () {
    test('matches file names case-insensitively', () {
      final result = const LibraryQuery(search: 'GAMMA').apply(all);
      expect(names(result), ['Gamma.pdf']);
    });

    test('matches the containing folder', () {
      final invoice = entry('x.pdf', folder: 'Invoices');
      final result = const LibraryQuery(search: 'invoice').apply([...all, invoice]);
      expect(names(result), ['x.pdf']);
    });

    test('whitespace-only search is treated as no search', () {
      expect(const LibraryQuery(search: '   ').apply(all), hasLength(3));
    });

    test('returns empty rather than everything when nothing matches', () {
      expect(const LibraryQuery(search: 'zzzz').apply(all), isEmpty);
    });

    test('applies within a filter, not instead of it', () {
      final result = LibraryQuery(
        filter: LibraryFilter.starred,
        starred: {alpha.path, beta.path},
        search: 'beta',
      ).apply(all);
      expect(names(result), ['beta.pdf']);
    });

    test('applies within the recent filter too', () {
      final result = LibraryQuery(
        filter: LibraryFilter.recent,
        recents: [beta.path, alpha.path],
        search: 'alpha',
      ).apply(all);
      expect(names(result), ['Alpha.pdf']);
    });
  });

  test('every filter and sort has a label', () {
    for (final filter in LibraryFilter.values) {
      expect(filter.label, isNotEmpty);
    }
    for (final sort in LibrarySort.values) {
      expect(sort.label, isNotEmpty);
    }
  });

  test('handles an empty library', () {
    for (final filter in LibraryFilter.values) {
      expect(LibraryQuery(filter: filter).apply(const []), isEmpty);
    }
  });
}
