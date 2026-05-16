import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:open_file/open_file.dart';

/// PDF service using pdfrx - single library for merge, split, create, and render.
/// pdfrx is MIT licensed and flexible for future features (viewing, text search, etc).
class PdfService {
  static String? _cachedOutputDir;

  /// Map the user-facing quality string to a JPEG encoder quality (1-100).
  /// Used when re-encoding images during image-to-PDF conversion.
  static int qualityStringToJpegQuality(String quality) {
    switch (quality) {
      case 'Low':
        return 50;
      case 'Medium':
        return 70;
      case 'High':
        return 85;
      case 'Maximum':
        return 100;
      default:
        return 85;
    }
  }

  static Future<String> _getOutputDir() async {
    _cachedOutputDir ??= (await getApplicationDocumentsDirectory()).path;
    return _cachedOutputDir!;
  }

  static Future<String> _getOutputPath(String prefix) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.pdf';
  }

  /// Merge PDFs from pre-loaded bytes.
  /// Source PDF quality is preserved by design (no re-encode).
  static Future<String?> mergePdfsFromBytes(
    List<Uint8List> pdfBytesList,
  ) async {
    if (pdfBytesList.length < 2) return null;

    try {
      final outputDir = await _getOutputDir();
      final outputPath =
          '$outputDir/merged_pdf_${DateTime.now().millisecondsSinceEpoch}.pdf';

      final List<PdfDocument> sourceDocs = [];
      for (final bytes in pdfBytesList) {
        sourceDocs.add(
          await PdfDocument.openData(bytes, sourceName: 'memory:'),
        );
      }

      final outputDoc = await PdfDocument.createNew(sourceName: 'merged.pdf');
      final List<PdfPage> allPages = [];
      for (final doc in sourceDocs) {
        await doc.loadPagesProgressively();
        allPages.addAll(doc.pages);
      }
      outputDoc.pages = allPages;

      final pdfData = await outputDoc.encodePdf();
      await File(outputPath).writeAsBytes(pdfData);

      for (final doc in sourceDocs) {
        doc.dispose();
      }
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error merging PDFs: $e');
      return null;
    }
  }

  /// Merge multiple batches of PDFs - each batch becomes one output file
  static Future<List<String>> mergePdfsBatch(
    List<List<Uint8List>> batches,
  ) async {
    final List<String> outputPaths = [];
    for (final batch in batches) {
      if (batch.length >= 2) {
        final path = await mergePdfsFromBytes(batch);
        if (path != null) outputPaths.add(path);
      }
    }
    return outputPaths;
  }

  /// Convert images to PDF.
  /// Each image is decoded and re-encoded as JPEG at the requested quality so
  /// the user-selected Output Quality setting actually controls file size.
  static Future<String?> imagesToPdf(
    List<String> imagePaths, {
    String outputQuality = 'High',
  }) async {
    if (imagePaths.isEmpty) return null;

    try {
      final jpegQuality = qualityStringToJpegQuality(outputQuality);
      final imageBytesList = await Future.wait(
        imagePaths.map((p) => File(p).readAsBytes()),
      );

      // Re-encode every image as JPEG at the chosen quality off the UI thread.
      final List<Uint8List> jpegBytesList = await compute(
        _reencodeImagesAsJpeg,
        _ReencodeRequest(imageBytesList, jpegQuality),
      );

      final List<PdfDocument> imageDocs = [];
      for (final bytes in jpegBytesList) {
        imageDocs.add(
          await PdfDocument.createFromJpegData(
            bytes,
            width: 595,
            height: 842,
            sourceName: 'image.pdf',
          ),
        );
      }

      final outputDoc = await PdfDocument.createNew(sourceName: 'images.pdf');
      final List<PdfPage> allPages = [];
      for (final doc in imageDocs) {
        allPages.addAll(doc.pages);
      }
      outputDoc.pages = allPages;

      final pdfData = await outputDoc.encodePdf();
      final outputPath = await _getOutputPath('images_to_pdf');
      await File(outputPath).writeAsBytes(pdfData);

      for (final doc in imageDocs) {
        doc.dispose();
      }
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error converting images to PDF: $e');
      return null;
    }
  }

  /// Split PDF by page range
  static Future<String?> splitPdfByRange(
    String pdfPath,
    int startPage,
    int endPage,
  ) async {
    try {
      final bytes = await File(pdfPath).readAsBytes();
      return splitPdfByRangeFromBytes(bytes, startPage, endPage);
    } catch (e) {
      debugPrint('Error splitting PDF: $e');
      return null;
    }
  }

  /// Split PDF into multiple ranges - each range becomes one output file
  static Future<List<String>> splitPdfByRangesFromBytes(
    Uint8List pdfBytes,
    List<({int start, int end})> ranges,
  ) async {
    final List<String> outputPaths = [];
    for (final range in ranges) {
      final path = await splitPdfByRangeFromBytes(
        pdfBytes,
        range.start,
        range.end,
      );
      if (path != null) outputPaths.add(path);
    }
    return outputPaths;
  }

  /// Split PDF by page range from pre-loaded bytes.
  /// Source quality is preserved by design (no re-encode).
  static Future<String?> splitPdfByRangeFromBytes(
    Uint8List pdfBytes,
    int startPage,
    int endPage,
  ) async {
    try {
      final sourceDoc = await PdfDocument.openData(
        pdfBytes,
        sourceName: 'memory:',
      );
      await sourceDoc.loadPagesProgressively();

      final totalPages = sourceDoc.pages.length;
      if (startPage < 1 || endPage > totalPages || startPage > endPage) {
        sourceDoc.dispose();
        return null;
      }

      final selectedPages = sourceDoc.pages.sublist(startPage - 1, endPage);
      final outputDoc = await PdfDocument.createNew(sourceName: 'split.pdf');
      outputDoc.pages = List.from(selectedPages);

      final pdfData = await outputDoc.encodePdf();
      final outputPath = await _getOutputPath('split_${startPage}_to_$endPage');
      await File(outputPath).writeAsBytes(pdfData);

      sourceDoc.dispose();
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error splitting PDF: $e');
      return null;
    }
  }

  /// Extract multiple specific pages into one PDF.
  /// Source quality is preserved by design (no re-encode).
  static Future<String?> extractPagesFromBytes(
    Uint8List pdfBytes,
    List<int> pageIndices,
  ) async {
    try {
      final sourceDoc = await PdfDocument.openData(
        pdfBytes,
        sourceName: 'memory:',
      );
      await sourceDoc.loadPagesProgressively();

      final totalPages = sourceDoc.pages.length;
      for (final idx in pageIndices) {
        if (idx < 0 || idx >= totalPages) {
          sourceDoc.dispose();
          return null;
        }
      }

      final selectedPages = pageIndices.map((i) => sourceDoc.pages[i]).toList();
      final outputDoc = await PdfDocument.createNew(
        sourceName: 'extracted.pdf',
      );
      outputDoc.pages = selectedPages;

      final pdfData = await outputDoc.encodePdf();
      final outputPath = await _getOutputPath('extracted_pages');
      await File(outputPath).writeAsBytes(pdfData);

      sourceDoc.dispose();
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error extracting pages: $e');
      return null;
    }
  }

  /// Split PDF into individual pages
  static Future<List<String>> splitPdfAllPages(String pdfPath) async {
    try {
      final bytes = await File(pdfPath).readAsBytes();
      return splitPdfAllPagesFromBytes(bytes);
    } catch (e) {
      debugPrint('Error splitting PDF into pages: $e');
      return [];
    }
  }

  /// Split PDF into individual pages from cached bytes.
  /// Source quality is preserved by design (no re-encode).
  static Future<List<String>> splitPdfAllPagesFromBytes(
    Uint8List pdfBytes,
  ) async {
    final List<String> outputPaths = [];

    try {
      final sourceDoc = await PdfDocument.openData(
        pdfBytes,
        sourceName: 'memory:',
      );
      await sourceDoc.loadPagesProgressively();

      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch.toString();

      for (int i = 0; i < sourceDoc.pages.length; i++) {
        final outputDoc = await PdfDocument.createNew(
          sourceName: 'page_${i + 1}.pdf',
        );
        outputDoc.pages = [sourceDoc.pages[i]];

        final pdfData = await outputDoc.encodePdf();
        final path = '${dir.path}/page_${i + 1}_$ts.pdf';
        await File(path).writeAsBytes(pdfData);
        outputPaths.add(path);

        outputDoc.dispose();
      }

      sourceDoc.dispose();
    } catch (e) {
      debugPrint('Error splitting PDF into pages: $e');
    }

    return outputPaths;
  }

  /// Get the page count of a PDF file
  static Future<int> getPageCount(String pdfPath) async {
    try {
      final doc = await PdfDocument.openFile(pdfPath);
      final count = doc.pages.length;
      doc.dispose();
      return count;
    } catch (e) {
      debugPrint('Error getting page count: $e');
      return 0;
    }
  }

  /// Get page count from bytes (for merge screen)
  static Future<int> getPageCountFromBytes(Uint8List bytes) async {
    try {
      final doc = await PdfDocument.openData(bytes, sourceName: 'memory:');
      final count = doc.pages.length;
      doc.dispose();
      return count;
    } catch (e) {
      debugPrint('Error getting page count: $e');
      return 0;
    }
  }

  /// Get first page aspect ratio (width/height) from bytes. Returns null on error.
  static Future<double?> getFirstPageAspectRatioFromBytes(
    Uint8List bytes,
  ) async {
    try {
      final doc = await PdfDocument.openData(bytes, sourceName: 'memory:');
      if (doc.pages.isEmpty) {
        doc.dispose();
        return null;
      }
      final page = doc.pages.first;
      final ratio = page.width / page.height;
      doc.dispose();
      return ratio;
    } catch (e) {
      debugPrint('Error getting aspect ratio: $e');
      return null;
    }
  }

  /// Get first page aspect ratio (width/height) from file path. Returns null on error.
  static Future<double?> getFirstPageAspectRatio(String pdfPath) async {
    try {
      final doc = await PdfDocument.openFile(pdfPath);
      if (doc.pages.isEmpty) {
        doc.dispose();
        return null;
      }
      final page = doc.pages.first;
      final ratio = page.width / page.height;
      doc.dispose();
      return ratio;
    } catch (e) {
      debugPrint('Error getting aspect ratio: $e');
      return null;
    }
  }

  /// Load page preview thumbnails for a PDF file (for preview/grid screens).
  ///
  /// These are grid thumbnails — never displayed larger than ~half the
  /// screen — so we render at ~400px on the long side and use moderate JPEG
  /// quality. A 30-page PDF previously held ~30–60MB of decoded bitmaps; this
  /// keeps the entire grid well under ~5MB.
  static Future<List<Uint8List?>> loadPagePreviews(String pdfPath) async {
    try {
      final doc = await PdfDocument.openFile(pdfPath);
      await doc.loadPagesProgressively();
      final List<Uint8List?> previews = [];
      const maxLongEdge = 400.0;
      for (final page in doc.pages) {
        final pw = page.width;
        final ph = page.height;
        final scale = pw >= ph ? maxLongEdge / pw : maxLongEdge / ph;
        final w = (pw * scale).clamp(120.0, maxLongEdge);
        final h = (ph * scale).clamp(120.0, maxLongEdge);
        final pageImage = await page.render(fullWidth: w, fullHeight: h);
        Uint8List? bytes;
        if (pageImage != null) {
          final imgObj = pageImage.createImageNF();
          bytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 80));
          pageImage.dispose();
        }
        previews.add(bytes);
      }
      doc.dispose();
      return previews;
    } catch (e) {
      debugPrint('Error loading page previews: $e');
      return [];
    }
  }

  /// Generate thumbnail from PDF bytes (for merge screen)
  static Future<Uint8List?> generateThumbnail(Uint8List pdfBytes) async {
    try {
      final doc = await PdfDocument.openData(pdfBytes, sourceName: 'memory:');
      await doc.loadPagesProgressively();
      if (doc.pages.isEmpty) {
        doc.dispose();
        return null;
      }

      final page = doc.pages.first;
      final scale = 1.0;
      final w = (page.width * scale).round().clamp(280, 1100).toDouble();
      final h = (page.height * scale).round().clamp(280, 1500).toDouble();

      final pageImage = await page.render(fullWidth: w, fullHeight: h);

      Uint8List? bytes;
      if (pageImage != null) {
        final imgObj = pageImage.createImageNF();
        bytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 95));
        pageImage.dispose();
      }

      doc.dispose();
      return bytes;
    } catch (e) {
      debugPrint('Error generating thumbnail: $e');
      return null;
    }
  }

  /// Open a PDF file with the default viewer
  static Future<void> openPdf(String filePath) async {
    try {
      await OpenFile.open(filePath);
    } catch (e) {
      debugPrint('Error opening PDF: $e');
    }
  }

  static Future<String> getOutputDirectory() async {
    return (await getApplicationDocumentsDirectory()).path;
  }
}

/// Payload for [_reencodeImagesAsJpeg] (must be a top-level / simple class for `compute`).
class _ReencodeRequest {
  const _ReencodeRequest(this.imageBytesList, this.jpegQuality);
  final List<Uint8List> imageBytesList;
  final int jpegQuality;
}

/// Top-level helper run via [compute] to decode arbitrary image formats and
/// re-encode them as JPEG at the requested quality. Falls back to the original
/// bytes if decoding fails (assumed already-JPEG).
List<Uint8List> _reencodeImagesAsJpeg(_ReencodeRequest request) {
  final out = <Uint8List>[];
  for (final bytes in request.imageBytesList) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      out.add(bytes);
      continue;
    }
    out.add(
      Uint8List.fromList(img.encodeJpg(decoded, quality: request.jpegQuality)),
    );
  }
  return out;
}
