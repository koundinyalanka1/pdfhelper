import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';

import '../utils/error_logger.dart';

/// Page rasterization, backed entirely by `flutter_pdf_core`'s Rust renderer.
///
/// This is the app's only source of page pixels. It exists as a separate
/// service (rather than calls scattered through the screens) so that the
/// renderer stays swappable and so every caller shares one bounded cache —
/// page bitmaps are by far the largest thing this app holds in memory.
///
/// Everything returns PNG bytes: the native side encodes them, Flutter decodes
/// them off the UI isolate, and the result is a plain `Uint8List` the garbage
/// collector reclaims on its own. That avoids the manual `ui.Image` lifetime
/// management a raw-RGBA path would need. `PdfCore.renderPageRgba` is still
/// there for a future zero-copy texture path.
class PdfRaster {
  PdfRaster._();

  /// Roughly 24 MB of decoded PNGs at typical page sizes.
  static const int _maxCacheEntries = 40;
  static final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();

  /// Thumbnail long edge, in pixels. Sized for grid cells, which are never
  /// shown above ~180 logical px.
  static const int thumbnailSize = 420;

  /// Fallback long edge for a library cover when the caller cannot measure
  /// its tile. Real callers pass the tile's size in *device* pixels — see
  /// [libraryCover] — because a cover rendered at logical-pixel size looks
  /// soft on every phone made in the last decade.
  static const int libraryThumbnailSize = 240;

  /// Cover requests are rounded up to a multiple of this before rendering, so
  /// every tile in a grid shares one cache entry instead of each asking for
  /// its own slightly different size.
  static const int _coverSizeStep = 96;

  /// Covers are larger now that they are rendered at device resolution, so
  /// fewer are held.
  static const int _maxLibraryCacheEntries = 70;
  static final LinkedHashMap<String, Uint8List?> _libraryCache =
      LinkedHashMap();

  /// Renders are serialized to [_maxConcurrentRenders] at a time.
  ///
  /// Every render hands off to `Isolate.run`, so an unthrottled grid would
  /// spawn one isolate per visible tile — dozens at once during a fling, each
  /// holding a decoded page. Three keeps the queue saturated without the
  /// memory spike.
  static const int _maxConcurrentRenders = 3;
  static int _activeRenders = 0;
  static final Queue<Completer<void>> _renderQueue = Queue();

  /// Render page [pageIndex] (0-based) to PNG, fitted inside a
  /// [longEdge]-pixel box.
  ///
  /// Returns null rather than throwing when the page cannot be rendered, so a
  /// single bad page never takes down a grid.
  static Future<Uint8List?> renderPage(
    String path,
    int pageIndex, {
    int longEdge = thumbnailSize,
    String password = '',
    bool useCache = true,
  }) async {
    final key = '$path|$pageIndex|$longEdge|${password.isEmpty ? 0 : 1}';
    if (useCache) {
      final hit = _cache.remove(key);
      if (hit != null) {
        _cache[key] = hit; // refresh LRU position
        return hit;
      }
    }
    await _acquire();
    try {
      final bytes = await PdfCore.renderPagePngAsync(
        path,
        pageIndex,
        width: longEdge,
        height: longEdge,
        password: password,
      );
      if (useCache) _store(key, bytes);
      return bytes;
    } on PdfException catch (e) {
      logError('PdfRaster.renderPage', '${e.code}: ${e.message}');
      return null;
    } catch (e) {
      logError('PdfRaster.renderPage', e);
      return null;
    } finally {
      _release();
    }
  }

  /// First-page thumbnail — the one every file card shows.
  static Future<Uint8List?> thumbnail(String path, {String password = ''}) =>
      renderPage(path, 0, password: password);

  /// Cover image for the Files library.
  ///
  /// Unlike [thumbnail] this caches failures too. The library lists whatever
  /// is on the device, including PDFs that are encrypted, truncated or not
  /// really PDFs at all; without a negative cache every one of those would be
  /// re-attempted on each scroll past its tile.
  ///
  /// [modifiedMs] is part of the cache key so an edited file re-renders.
  ///
  /// [longEdge] must be in *device* pixels (logical size x devicePixelRatio).
  /// It is rounded up to [_coverSizeStep] so tiles of the same size share a
  /// cache entry.
  static Future<Uint8List?> libraryCover(
    String path, {
    int modifiedMs = 0,
    int longEdge = libraryThumbnailSize,
    String password = '',
  }) async {
    final target = coverSizeFor(longEdge);
    final key = _coverKey(path, modifiedMs, target);
    if (_libraryCache.containsKey(key)) {
      final hit = _libraryCache.remove(key);
      _libraryCache[key] = hit; // refresh LRU position
      return hit;
    }
    final bytes = await renderPage(
      path,
      0,
      longEdge: target,
      password: password,
      useCache: false,
    );
    _libraryCache[key] = bytes;
    while (_libraryCache.length > _maxLibraryCacheEntries) {
      _libraryCache.remove(_libraryCache.keys.first);
    }
    return bytes;
  }

  /// Whether [libraryCover] would answer without rendering.
  ///
  /// Lets a grid tile paint a cached cover in its very first frame instead of
  /// flashing a placeholder while an already-finished render is looked up
  /// asynchronously.
  static bool isCoverCached(
    String path, {
    int modifiedMs = 0,
    int longEdge = libraryThumbnailSize,
  }) => _libraryCache.containsKey(
    _coverKey(path, modifiedMs, coverSizeFor(longEdge)),
  );

  /// The cached cover, or null when absent *or* known to be unrenderable.
  /// Pair with [isCoverCached] to tell those two apart.
  static Uint8List? cachedCover(
    String path, {
    int modifiedMs = 0,
    int longEdge = libraryThumbnailSize,
  }) => _libraryCache[_coverKey(path, modifiedMs, coverSizeFor(longEdge))];

  /// Round a requested cover size up to the shared step, clamped to something
  /// a phone can afford.
  static int coverSizeFor(int longEdge) {
    final clamped = longEdge.clamp(_coverSizeStep, 768);
    return ((clamped + _coverSizeStep - 1) ~/ _coverSizeStep) * _coverSizeStep;
  }

  static String _coverKey(String path, int modifiedMs, int longEdge) =>
      '$path|$modifiedMs|$longEdge';

  /// Render every page, reporting progress as it goes.
  ///
  /// Pages are rendered one at a time on a background isolate rather than
  /// with `Future.wait`: a 200-page document would otherwise try to hold 200
  /// decoded bitmaps at once.
  static Future<List<Uint8List?>> renderAllPages(
    String path, {
    int longEdge = thumbnailSize,
    String password = '',
    int? pageCount,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = pageCount ?? await pageCountOf(path, password: password);
    final pages = <Uint8List?>[];
    for (int i = 0; i < total; i++) {
      if (isCancelled?.call() ?? false) break;
      pages.add(
        await renderPage(path, i, longEdge: longEdge, password: password),
      );
      onProgress?.call(i + 1, total);
    }
    return pages;
  }

  /// Page count straight from the xref — no rendering involved.
  static Future<int> pageCountOf(String path, {String password = ''}) async {
    try {
      return await PdfCore.pageCountAsync(path, password: password);
    } catch (e) {
      logError('PdfRaster.pageCountOf', e);
      return 0;
    }
  }

  /// First page's width/height ratio, used to size thumbnail boxes before the
  /// image itself has rendered.
  static Future<double?> aspectRatio(
    String path, {
    int pageIndex = 0,
    String password = '',
  }) async {
    try {
      final size = await PdfCore.pageSizeAsync(
        path,
        pageIndex,
        password: password,
      );
      return size.aspectRatio;
    } catch (e) {
      logError('PdfRaster.aspectRatio', e);
      return null;
    }
  }

  /// Drop cached bitmaps for one document (after it has been rewritten) or,
  /// with no argument, everything.
  static void invalidate([String? path]) {
    if (path == null) {
      _cache.clear();
      _libraryCache.clear();
      return;
    }
    _cache.removeWhere((key, _) => key.startsWith('$path|'));
    _libraryCache.removeWhere((key, _) => key.startsWith('$path|'));
  }

  static void _store(String key, Uint8List bytes) {
    _cache[key] = bytes;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Wait for a render slot. FIFO, so the first tile asked for is the first
  /// one drawn — out-of-order completion makes a grid look like it is
  /// filling in at random.
  static Future<void> _acquire() {
    if (_activeRenders < _maxConcurrentRenders) {
      _activeRenders++;
      return Future.value();
    }
    final completer = Completer<void>();
    _renderQueue.add(completer);
    return completer.future;
  }

  static void _release() {
    if (_renderQueue.isNotEmpty) {
      // Hand the slot straight to the next waiter rather than decrementing;
      // otherwise a burst of new callers could jump the queue.
      _renderQueue.removeFirst().complete();
      return;
    }
    if (_activeRenders > 0) _activeRenders--;
  }
}
