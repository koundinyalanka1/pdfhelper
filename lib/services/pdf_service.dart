import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:open_file/open_file.dart';

/// PDF service using pdfrx - single library for merge, split, create, and render.
/// pdfrx is MIT licensed and flexible for future features (viewing, text search, etc).
class PdfService {
  static String? _cachedOutputDir;

  static Future<String> _getOutputDir() async {
    _cachedOutputDir ??= (await getApplicationDocumentsDirectory()).path;
    return _cachedOutputDir!;
  }

  static Future<String> _getOutputPath(String prefix) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.pdf';
  }

  /// Merge PDFs from pre-loaded bytes
  static Future<String?> mergePdfsFromBytes(
    List<Uint8List> pdfBytesList, {
    String outputQuality = 'High',
  }) async {
    if (pdfBytesList.length < 2) return null;

    try {
      final outputDir = await _getOutputDir();
      final outputPath =
          '$outputDir/merged_pdf_${DateTime.now().millisecondsSinceEpoch}.pdf';

      final List<PdfDocument> sourceDocs = [];
      for (final bytes in pdfBytesList) {
        sourceDocs.add(
            await PdfDocument.openData(bytes, sourceName: 'memory:'));
      }

      final outputDoc =
          await PdfDocument.createNew(sourceName: 'merged.pdf');
      final List<PdfPage> allPages = [];
      for (final doc in sourceDocs) {
        await doc.loadPagesProgressively();
        allPages.addAll(doc.pages);
      }
      outputDoc.pages = allPages;

      final pdfData = await outputDoc.encodePdf();
      await File(outputPath).writeAsBytes(pdfData);

      for (final doc in sourceDocs) doc.dispose();
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error merging PDFs: $e');
      return null;
    }
  }

  /// Merge multiple batches of PDFs - each batch becomes one output file
  static Future<List<String>> mergePdfsBatch(
    List<List<Uint8List>> batches, {
    String outputQuality = 'High',
  }) async {
    final List<String> outputPaths = [];
    for (final batch in batches) {
      if (batch.length >= 2) {
        final path = await mergePdfsFromBytes(batch, outputQuality: outputQuality);
        if (path != null) outputPaths.add(path);
      }
    }
    return outputPaths;
  }

  /// Merge multiple PDF files into one
  static Future<String?> mergePdfs(
    List<String> pdfPaths, {
    String outputQuality = 'High',
  }) async {
    if (pdfPaths.length < 2) return null;
    try {
      final bytesList =
          await Future.wait(pdfPaths.map((p) => File(p).readAsBytes()));
      return mergePdfsFromBytes(bytesList, outputQuality: outputQuality);
    } catch (e) {
      debugPrint('Error merging PDFs: $e');
      return null;
    }
  }

  /// Convert images to PDF
  static Future<String?> imagesToPdf(
    List<String> imagePaths, {
    String outputQuality = 'High',
  }) async {
    if (imagePaths.isEmpty) return null;

    try {
      final imageBytesList =
          await Future.wait(imagePaths.map((p) => File(p).readAsBytes()));

      final List<PdfDocument> imageDocs = [];
      for (final bytes in imageBytesList) {
        imageDocs.add(await PdfDocument.createFromJpegData(
          bytes,
          width: 595,
          height: 842,
          sourceName: 'image.pdf',
        ));
      }

      final outputDoc =
          await PdfDocument.createNew(sourceName: 'images.pdf');
      final List<PdfPage> allPages = [];
      for (final doc in imageDocs) allPages.addAll(doc.pages);
      outputDoc.pages = allPages;

      final pdfData = await outputDoc.encodePdf();
      final outputPath = await _getOutputPath('images_to_pdf');
      await File(outputPath).writeAsBytes(pdfData);

      for (final doc in imageDocs) doc.dispose();
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
    int endPage, {
    String outputQuality = 'High',
  }) async {
    try {
      final bytes = await File(pdfPath).readAsBytes();
      return splitPdfByRangeFromBytes(bytes, startPage, endPage,
          outputQuality: outputQuality);
    } catch (e) {
      debugPrint('Error splitting PDF: $e');
      return null;
    }
  }

  /// Split PDF into multiple ranges - each range becomes one output file
  static Future<List<String>> splitPdfByRangesFromBytes(
    Uint8List pdfBytes,
    List<({int start, int end})> ranges, {
    String outputQuality = 'High',
  }) async {
    final List<String> outputPaths = [];
    for (final range in ranges) {
      final path = await splitPdfByRangeFromBytes(
        pdfBytes,
        range.start,
        range.end,
        outputQuality: outputQuality,
      );
      if (path != null) outputPaths.add(path);
    }
    return outputPaths;
  }

  /// Split PDF by page range from pre-loaded bytes
  static Future<String?> splitPdfByRangeFromBytes(
    Uint8List pdfBytes,
    int startPage,
    int endPage, {
    String outputQuality = 'High',
  }) async {
    try {
      final sourceDoc =
          await PdfDocument.openData(pdfBytes, sourceName: 'memory:');
      await sourceDoc.loadPagesProgressively();

      final totalPages = sourceDoc.pages.length;
      if (startPage < 1 || endPage > totalPages || startPage > endPage) {
        sourceDoc.dispose();
        return null;
      }

      final selectedPages = sourceDoc.pages.sublist(startPage - 1, endPage);
      final outputDoc =
          await PdfDocument.createNew(sourceName: 'split.pdf');
      outputDoc.pages = List.from(selectedPages);

      final pdfData = await outputDoc.encodePdf();
      final outputPath =
          await _getOutputPath('split_${startPage}_to_$endPage');
      await File(outputPath).writeAsBytes(pdfData);

      sourceDoc.dispose();
      outputDoc.dispose();

      return outputPath;
    } catch (e) {
      debugPrint('Error splitting PDF: $e');
      return null;
    }
  }

  /// Extract multiple specific pages into one PDF
  static Future<String?> extractPagesFromBytes(
    Uint8List pdfBytes,
    List<int> pageIndices, {
    String outputQuality = 'High',
  }) async {
    try {
      final sourceDoc =
          await PdfDocument.openData(pdfBytes, sourceName: 'memory:');
      await sourceDoc.loadPagesProgressively();

      final totalPages = sourceDoc.pages.length;
      for (final idx in pageIndices) {
        if (idx < 0 || idx >= totalPages) {
          sourceDoc.dispose();
          return null;
        }
      }

      final selectedPages =
          pageIndices.map((i) => sourceDoc.pages[i]).toList();
      final outputDoc =
          await PdfDocument.createNew(sourceName: 'extracted.pdf');
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
  static Future<List<String>> splitPdfAllPages(
    String pdfPath, {
    String outputQuality = 'High',
  }) async {
    try {
      final bytes = await File(pdfPath).readAsBytes();
      return splitPdfAllPagesFromBytes(bytes, outputQuality: outputQuality);
    } catch (e) {
      debugPrint('Error splitting PDF into pages: $e');
      return [];
    }
  }

  /// Split PDF into individual pages from cached bytes
  static Future<List<String>> splitPdfAllPagesFromBytes(
    Uint8List pdfBytes, {
    String outputQuality = 'High',
  }) async {
    final List<String> outputPaths = [];

    try {
      final sourceDoc =
          await PdfDocument.openData(pdfBytes, sourceName: 'memory:');
      await sourceDoc.loadPagesProgressively();

      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch.toString();

      for (int i = 0; i < sourceDoc.pages.length; i++) {
        final outputDoc =
            await PdfDocument.createNew(sourceName: 'page_${i + 1}.pdf');
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
  static Future<double?> getFirstPageAspectRatioFromBytes(Uint8List bytes) async {
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

  /// Load page preview thumbnails for a PDF file (for preview screen)
  static Future<List<Uint8List?>> loadPagePreviews(String pdfPath) async {
    try {
      final doc = await PdfDocument.openFile(pdfPath);
      await doc.loadPagesProgressively();
      final List<Uint8List?> previews = [];
      for (final page in doc.pages) {
        final w = (page.width * 1.0).round().clamp(350, 1500).toDouble();
        final h = (page.height * 1.0).round().clamp(350, 1700).toDouble();
        final pageImage = await page.render(fullWidth: w, fullHeight: h);
        Uint8List? bytes;
        if (pageImage != null) {
          final imgObj = pageImage.createImageNF();
          if (imgObj != null) {
            bytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 92));
          }
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
        if (imgObj != null) {
            bytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 95));
        }
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
