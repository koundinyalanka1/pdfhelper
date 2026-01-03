import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

/// Data class for merge operation
class _MergeData {
  final List<Uint8List> pdfBytes;
  _MergeData(this.pdfBytes);
}

/// Data class for image to PDF operation  
class _ImageToPdfData {
  final List<Uint8List> imageBytes;
  _ImageToPdfData(this.imageBytes);
}

/// Data class for split operation
class _SplitData {
  final Uint8List pdfBytes;
  final int startPage;
  final int endPage;
  _SplitData(this.pdfBytes, this.startPage, this.endPage);
}

/// Isolate function for merging PDFs
List<int> _mergePdfsInIsolate(_MergeData data) {
  final PdfDocument mergedDocument = PdfDocument();
  PdfSection? section;

  for (Uint8List bytes in data.pdfBytes) {
    final PdfDocument sourceDocument = PdfDocument(inputBytes: bytes);

    for (int i = 0; i < sourceDocument.pages.count; i++) {
      final PdfTemplate template = sourceDocument.pages[i].createTemplate();

      if (section == null || section.pageSettings.size != template.size) {
        section = mergedDocument.sections!.add();
        section.pageSettings.size = template.size;
        section.pageSettings.margins.all = 0;
      }

      section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
    }

    sourceDocument.dispose();
  }

  final List<int> outputBytes = mergedDocument.saveSync();
  mergedDocument.dispose();
  return outputBytes;
}

/// Isolate function for converting images to PDF
List<int> _imagesToPdfInIsolate(_ImageToPdfData data) {
  final PdfDocument document = PdfDocument();

  for (Uint8List imageBytes in data.imageBytes) {
    final PdfBitmap image = PdfBitmap(imageBytes);
    final PdfPage page = document.pages.add();
    final Size pageSize = page.getClientSize();

    double imageWidth = image.width.toDouble();
    double imageHeight = image.height.toDouble();
    double aspectRatio = imageWidth / imageHeight;

    double drawWidth, drawHeight;
    if (aspectRatio > (pageSize.width / pageSize.height)) {
      drawWidth = pageSize.width;
      drawHeight = drawWidth / aspectRatio;
    } else {
      drawHeight = pageSize.height;
      drawWidth = drawHeight * aspectRatio;
    }

    double x = (pageSize.width - drawWidth) / 2;
    double y = (pageSize.height - drawHeight) / 2;

    page.graphics.drawImage(
      image,
      Rect.fromLTWH(x, y, drawWidth, drawHeight),
    );
  }

  final List<int> bytes = document.saveSync();
  document.dispose();
  return bytes;
}

/// Isolate function for splitting PDF by range
List<int>? _splitPdfByRangeInIsolate(_SplitData data) {
  final PdfDocument sourceDocument = PdfDocument(inputBytes: data.pdfBytes);
  final int totalPages = sourceDocument.pages.count;
  
  if (data.startPage < 1 || data.endPage > totalPages || data.startPage > data.endPage) {
    sourceDocument.dispose();
    return null;
  }

  final PdfDocument newDocument = PdfDocument();
  PdfSection? section;

  for (int i = data.startPage - 1; i < data.endPage; i++) {
    final PdfTemplate template = sourceDocument.pages[i].createTemplate();

    if (section == null || section.pageSettings.size != template.size) {
      section = newDocument.sections!.add();
      section.pageSettings.size = template.size;
      section.pageSettings.margins.all = 0;
    }

    section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
  }

  sourceDocument.dispose();
  final List<int> outputBytes = newDocument.saveSync();
  newDocument.dispose();
  return outputBytes;
}

/// Isolate function for splitting PDF into all pages
List<List<int>> _splitPdfAllPagesInIsolate(Uint8List pdfBytes) {
  List<List<int>> results = [];
  final PdfDocument sourceDocument = PdfDocument(inputBytes: pdfBytes);
  final int totalPages = sourceDocument.pages.count;

  for (int i = 0; i < totalPages; i++) {
    final PdfDocument singlePageDoc = PdfDocument();
    final PdfTemplate template = sourceDocument.pages[i].createTemplate();

    final PdfSection section = singlePageDoc.sections!.add();
    section.pageSettings.size = template.size;
    section.pageSettings.margins.all = 0;
    section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);

    results.add(singlePageDoc.saveSync());
    singlePageDoc.dispose();
  }

  sourceDocument.dispose();
  return results;
}

class PdfService {
  /// Merge multiple PDF files into one
  static Future<String?> mergePdfs(List<String> pdfPaths) async {
    if (pdfPaths.length < 2) return null;

    try {
      // Read all PDF bytes first (IO on main thread is fine)
      List<Uint8List> pdfBytes = [];
      for (String path in pdfPaths) {
        pdfBytes.add(await File(path).readAsBytes());
      }

      // Process in background isolate
      final List<int> outputBytes = await compute(
        _mergePdfsInIsolate,
        _MergeData(pdfBytes),
      );

      // Save the merged document
      final String outputPath = await _getOutputPath('merged_pdf');
      await File(outputPath).writeAsBytes(outputBytes);

      return outputPath;
    } catch (e) {
      debugPrint('Error merging PDFs: $e');
      return null;
    }
  }

  /// Convert images to PDF
  static Future<String?> imagesToPdf(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return null;

    try {
      // Read all image bytes first
      List<Uint8List> imageBytes = [];
      for (String path in imagePaths) {
        imageBytes.add(await File(path).readAsBytes());
      }

      // Process in background isolate
      final List<int> outputBytes = await compute(
        _imagesToPdfInIsolate,
        _ImageToPdfData(imageBytes),
      );

      // Save the document
      final String outputPath = await _getOutputPath('images_to_pdf');
      await File(outputPath).writeAsBytes(outputBytes);

      return outputPath;
    } catch (e) {
      debugPrint('Error converting images to PDF: $e');
      return null;
    }
  }

  /// Split PDF by page range
  static Future<String?> splitPdfByRange(
      String pdfPath, int startPage, int endPage) async {
    try {
      final Uint8List bytes = await File(pdfPath).readAsBytes();

      // Process in background isolate
      final List<int>? outputBytes = await compute(
        _splitPdfByRangeInIsolate,
        _SplitData(bytes, startPage, endPage),
      );

      if (outputBytes == null) return null;

      // Save the new document
      final String outputPath =
          await _getOutputPath('split_${startPage}_to_$endPage');
      await File(outputPath).writeAsBytes(outputBytes);

      return outputPath;
    } catch (e) {
      debugPrint('Error splitting PDF: $e');
      return null;
    }
  }

  /// Split PDF into individual pages
  static Future<List<String>> splitPdfAllPages(String pdfPath) async {
    List<String> outputPaths = [];

    try {
      final Uint8List bytes = await File(pdfPath).readAsBytes();

      // Process in background isolate
      final List<List<int>> results = await compute(
        _splitPdfAllPagesInIsolate,
        bytes,
      );

      // Save each page
      for (int i = 0; i < results.length; i++) {
        final String outputPath = await _getOutputPath('page_${i + 1}');
        await File(outputPath).writeAsBytes(results[i]);
        outputPaths.add(outputPath);
      }
    } catch (e) {
      debugPrint('Error splitting PDF into pages: $e');
    }

    return outputPaths;
  }

  /// Get the page count of a PDF file
  static Future<int> getPageCount(String pdfPath) async {
    try {
      final Uint8List bytes = await File(pdfPath).readAsBytes();
      // Page count is fast enough to do on main thread
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      final int pageCount = document.pages.count;
      document.dispose();
      return pageCount;
    } catch (e) {
      debugPrint('Error getting page count: $e');
      return 0;
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

  /// Get output file path with timestamp
  static Future<String> _getOutputPath(String prefix) async {
    final Directory directory = await getApplicationDocumentsDirectory();
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    return '${directory.path}/${prefix}_$timestamp.pdf';
  }

  /// Get the output directory path
  static Future<String> getOutputDirectory() async {
    final Directory directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }
}
