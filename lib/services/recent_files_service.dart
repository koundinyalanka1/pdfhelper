import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/error_logger.dart';

/// Recently-opened and starred documents.
///
/// Both lists are stored as paths, not copies of the files: a document reader
/// should point at where a file already lives rather than duplicating it. A
/// path whose file has since been deleted is dropped on read, so the lists
/// never surface entries that cannot be opened.
class RecentFilesService {
  RecentFilesService._();

  static const String _recentsKey = 'library.recents.v1';
  static const String _starredKey = 'library.starred.v1';

  /// Recents past this count are dropped, oldest first.
  static const int maxRecents = 40;

  static List<_Recent>? _recents;
  static Set<String>? _starred;

  // -------------------------------------------------------------- recents

  /// Paths in most-recently-opened order.
  static Future<List<String>> recents() async {
    final loaded = await _loadRecents();
    return loaded.map((r) => r.path).toList();
  }

  /// When [path] was last opened, or null if it has not been.
  static Future<DateTime?> lastOpened(String path) async {
    final loaded = await _loadRecents();
    for (final entry in loaded) {
      if (entry.path == path) {
        return DateTime.fromMillisecondsSinceEpoch(entry.openedAtMs);
      }
    }
    return null;
  }

  /// Record that [path] was opened. Moves it to the front if already present.
  static Future<void> markOpened(String path) async {
    if (path.isEmpty) return;
    final loaded = await _loadRecents();
    loaded.removeWhere((r) => r.path == path);
    loaded.insert(0, _Recent(path, DateTime.now().millisecondsSinceEpoch));
    if (loaded.length > maxRecents) loaded.removeRange(maxRecents, loaded.length);
    _recents = loaded;
    await _saveRecents(loaded);
  }

  /// Remove [path] from recents and stars — call after deleting a file.
  static Future<void> forget(String path) async {
    final loaded = await _loadRecents();
    final before = loaded.length;
    loaded.removeWhere((r) => r.path == path);
    if (loaded.length != before) {
      _recents = loaded;
      await _saveRecents(loaded);
    }
    final starred = await _loadStarred();
    if (starred.remove(path)) {
      _starred = starred;
      await _saveStarred(starred);
    }
  }

  /// Follow a file that moved (rename keeps its place in both lists).
  static Future<void> rename(String from, String to) async {
    final loaded = await _loadRecents();
    var changed = false;
    for (var i = 0; i < loaded.length; i++) {
      if (loaded[i].path == from) {
        loaded[i] = _Recent(to, loaded[i].openedAtMs);
        changed = true;
      }
    }
    if (changed) {
      _recents = loaded;
      await _saveRecents(loaded);
    }
    final starred = await _loadStarred();
    if (starred.remove(from)) {
      starred.add(to);
      _starred = starred;
      await _saveStarred(starred);
    }
  }

  static Future<void> clearRecents() async {
    _recents = [];
    await _saveRecents(const []);
  }

  // -------------------------------------------------------------- starred

  static Future<Set<String>> starred() async => Set.of(await _loadStarred());

  static Future<bool> isStarred(String path) async =>
      (await _loadStarred()).contains(path);

  /// Returns the new state: true when the file is now starred.
  static Future<bool> toggleStar(String path) async {
    final starred = await _loadStarred();
    final nowStarred = !starred.remove(path);
    if (nowStarred) starred.add(path);
    _starred = starred;
    await _saveStarred(starred);
    return nowStarred;
  }

  // ------------------------------------------------------------ internals

  static Future<List<_Recent>> _loadRecents() async {
    final cached = _recents;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recentsKey);
      if (raw == null || raw.isEmpty) return _recents = [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _recents = [];
      final entries = <_Recent>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final path = item['p'];
        if (path is! String || path.isEmpty) continue;
        entries.add(_Recent(path, item['t'] is int ? item['t'] as int : 0));
      }
      return _recents = entries;
    } catch (e) {
      logError('RecentFilesService._loadRecents', e);
      return _recents = [];
    }
  }

  static Future<void> _saveRecents(List<_Recent> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _recentsKey,
        jsonEncode([
          for (final entry in entries) {'p': entry.path, 't': entry.openedAtMs},
        ]),
      );
    } catch (e) {
      logError('RecentFilesService._saveRecents', e);
    }
  }

  static Future<Set<String>> _loadStarred() async {
    final cached = _starred;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      return _starred = (prefs.getStringList(_starredKey) ?? const []).toSet();
    } catch (e) {
      logError('RecentFilesService._loadStarred', e);
      return _starred = <String>{};
    }
  }

  static Future<void> _saveStarred(Set<String> paths) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_starredKey, paths.toList());
    } catch (e) {
      logError('RecentFilesService._saveStarred', e);
    }
  }

  /// Test seam: drop the in-memory copies so the next read hits storage.
  static void resetCacheForTesting() {
    _recents = null;
    _starred = null;
  }
}

class _Recent {
  const _Recent(this.path, this.openedAtMs);
  final String path;
  final int openedAtMs;
}
