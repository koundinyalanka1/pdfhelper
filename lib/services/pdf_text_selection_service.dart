import 'package:flutter_pdf_core/flutter_pdf_core.dart';

import '../utils/async_limiter.dart';

export 'package:flutter_pdf_core/flutter_pdf_core.dart'
    show PdfException, PdfPageTextLayout, PdfTextGlyph;

/// Loads geometry on demand for the page currently being selected. The viewer
/// owns the result, so changing/reopening a file or entering another password
/// never reuses cached text from a previous document version.
class PdfTextSelectionService {
  PdfTextSelectionService._();

  /// Every built page asks for its text as soon as it appears, and a fling
  /// builds dozens. Each load is an isolate reading the document, so they run
  /// two at a time, like find's own reads, instead of all at once.
  static final AsyncLimiter _loads = AsyncLimiter(2);

  /// [pageIndex] is zero-based, matching the viewer and raster APIs.
  ///
  /// [isWanted] is asked when the load's turn comes. A page that has
  /// scrolled away by then is skipped with [PdfTextLoadSkipped].
  static Future<PdfPageTextLayout> load(
    String path,
    int pageIndex, {
    String password = '',
    bool Function()? isWanted,
  }) async {
    if (pageIndex < 0) {
      throw RangeError.range(pageIndex, 0, null, 'pageIndex');
    }
    return _loads.run(() async {
      if (isWanted != null && !isWanted()) throw const PdfTextLoadSkipped();
      return PdfCore.pageTextLayout(
        path,
        page: pageIndex + 1,
        password: password,
      );
    });
  }
}

/// A text load whose page was no longer wanted by the time it could start.
class PdfTextLoadSkipped implements Exception {
  const PdfTextLoadSkipped();
}
