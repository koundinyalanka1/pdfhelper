import '../services/library_service.dart';
import 'doc_kind.dart';

/// Which slice of the library is on screen.
enum LibraryFilter { all, recent, starred, created }

extension LibraryFilterLabel on LibraryFilter {
  String get label => switch (this) {
    LibraryFilter.all => 'All files',
    LibraryFilter.recent => 'Recent',
    LibraryFilter.starred => 'Starred',
    LibraryFilter.created => 'Created',
  };
}

enum LibrarySort { newest, name, largest }

extension LibrarySortLabel on LibrarySort {
  String get label => switch (this) {
    LibrarySort.newest => 'Date modified',
    LibrarySort.name => 'Name',
    LibrarySort.largest => 'Size',
  };
}

/// Turns the scanned library into the list the Files tab draws.
///
/// Pulled out of the screen so the rules — which filter wins, what sorting
/// means for Recent, what "search" matches — can be tested directly instead
/// of through a pumped widget tree.
class LibraryQuery {
  const LibraryQuery({
    this.filter = LibraryFilter.all,
    this.sort = LibrarySort.newest,
    this.search = '',
    this.recents = const [],
    this.starred = const {},
    this.kind,
  });

  final LibraryFilter filter;

  /// Only files of this kind; null for every kind.
  final DocKind? kind;
  final LibrarySort sort;
  final String search;

  /// Paths in most-recently-opened order.
  final List<String> recents;
  final Set<String> starred;

  List<LibraryEntry> apply(List<LibraryEntry> entries) {
    Iterable<LibraryEntry> list = entries;
    final kind = this.kind;
    if (kind != null) list = list.where((e) => e.kind == kind);

    switch (filter) {
      case LibraryFilter.all:
        break;
      case LibraryFilter.starred:
        list = list.where((e) => starred.contains(e.path));
      case LibraryFilter.created:
        list = list.where((e) => e.isAppOwned);
      case LibraryFilter.recent:
        // Recent has an order of its own — most recently opened first — and
        // the sort menu deliberately does not override it. Sorting a Recent
        // list by name would make it something other than a recent list.
        final rank = <String, int>{
          for (var i = 0; i < recents.length; i++) recents[i]: i,
        };
        final recent = list.where((e) => rank.containsKey(e.path)).toList()
          ..sort((a, b) => rank[a.path]!.compareTo(rank[b.path]!));
        return _search(recent).toList();
    }

    final result = _search(list).toList();
    switch (sort) {
      case LibrarySort.newest:
        result.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      case LibrarySort.name:
        result.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case LibrarySort.largest:
        result.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    }
    return result;
  }

  Iterable<LibraryEntry> _search(Iterable<LibraryEntry> list) {
    final query = search.trim().toLowerCase();
    if (query.isEmpty) return list;
    return list.where(
      (e) =>
          e.name.toLowerCase().contains(query) ||
          e.folder.toLowerCase().contains(query),
    );
  }
}
