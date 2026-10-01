import 'package:flutter_pdf_core/flutter_pdf_core.dart';

export 'package:flutter_pdf_core/flutter_pdf_core.dart'
    show PdfException, PdfPageTextLayout, PdfTextGlyph;

/// Loads geometry on demand for the page currently being selected. The viewer
/// owns the result, so changing/reopening a file or entering another password
/// never reuses cached text from a previous document version.
class PdfTextSelectionService {
  PdfTextSelectionService._();

  /// [pageIndex] is zero-based, matching the viewer and raster APIs.
  static Future<PdfPageTextLayout> load(
    String path,
    int pageIndex, {
    String password = '',
  }) async {
    if (pageIndex < 0) {
      throw RangeError.range(pageIndex, 0, null, 'pageIndex');
    }
    return PdfCore.pageTextLayout(
      path,
      page: pageIndex + 1,
      password: password,
    );
  }
}
