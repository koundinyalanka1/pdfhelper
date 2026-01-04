import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

/// Data class for merge operation - contains raw bytes list
class MergeRequest {
  final List<Uint8List> pdfBytesList;
  MergeRequest(this.pdfBytesList);
}

/// Data class for image to PDF operation  
class ImageToPdfRequest {
  final List<Uint8List> imageBytes;
  ImageToPdfRequest(this.imageBytes);
}

/// Data class for split operation
class SplitRequest {
  final Uint8List pdfBytes;
  final int startPage;
  final int endPage;
  SplitRequest(this.pdfBytes, this.startPage, this.endPage);
}

/// OPTIMIZED: Fast merge using sections for proper page sizing
List<int> mergePdfsFastIsolate(MergeRequest request) {
  if (request.pdfBytesList.isEmpty) return [];
  
  final PdfDocument outputDoc = PdfDocument();
  
  // Remove default empty page
  if (outputDoc.pages.count > 0) {
    outputDoc.pages.removeAt(0);
  }
  
  // Track current section for same-sized pages
  PdfSection? currentSection;
  Size? currentSize;
  
  for (final Uint8List pdfBytes in request.pdfBytesList) {
    final PdfDocument sourceDoc = PdfDocument(inputBytes: pdfBytes);
    
    for (int i = 0; i < sourceDoc.pages.count; i++) {
      final PdfTemplate template = sourceDoc.pages[i].createTemplate();
      final Size templateSize = template.size;
      
      // Create new section if page size differs
      if (currentSection == null || currentSize != templateSize) {
        currentSection = outputDoc.sections!.add();
        currentSection.pageSettings.size = templateSize;
        currentSection.pageSettings.margins.all = 0;
        currentSize = templateSize;
      }
      
      // Add page and draw template
      currentSection.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
    }
    
    sourceDoc.dispose();
  }

  final List<int> result = outputDoc.saveSync();
  outputDoc.dispose();
  return result;
}

/// Optimized isolate function for converting images to PDF
List<int> imagesToPdfIsolate(ImageToPdfRequest request) {
  final PdfDocument document = PdfDocument();

  for (Uint8List imageBytes in request.imageBytes) {
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
List<int>? splitPdfByRangeIsolate(SplitRequest request) {
  final PdfDocument sourceDocument = PdfDocument(inputBytes: request.pdfBytes);
  final int totalPages = sourceDocument.pages.count;
  
  if (request.startPage < 1 || request.endPage > totalPages || request.startPage > request.endPage) {
    sourceDocument.dispose();
    return null;
  }

  final PdfDocument newDocument = PdfDocument();
  
  // Remove default page
  if (newDocument.pages.count > 0) {
    newDocument.pages.removeAt(0);
  }

  for (int i = request.startPage - 1; i < request.endPage; i++) {
    final PdfPage sourcePage = sourceDocument.pages[i];
    final PdfTemplate template = sourcePage.createTemplate();
    
    final PdfSection section = newDocument.sections!.add();
    section.pageSettings.size = template.size;
    section.pageSettings.margins.all = 0;
    
    section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
  }

  sourceDocument.dispose();
  final List<int> outputBytes = newDocument.saveSync();
  newDocument.dispose();
  return outputBytes;
}

/// Isolate function for splitting PDF into all pages
List<List<int>> splitPdfAllPagesIsolate(Uint8List pdfBytes) {
  List<List<int>> results = [];
  final PdfDocument sourceDocument = PdfDocument(inputBytes: pdfBytes);
  final int totalPages = sourceDocument.pages.count;

  for (int i = 0; i < totalPages; i++) {
    final PdfDocument singlePageDoc = PdfDocument();
    
    // Remove default page
    if (singlePageDoc.pages.count > 0) {
      singlePageDoc.pages.removeAt(0);
    }
    
    final PdfPage sourcePage = sourceDocument.pages[i];
    final PdfTemplate template = sourcePage.createTemplate();

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
  /// Merge multiple PDF files into one - OPTIMIZED
  static Future<String?> mergePdfs(List<String> pdfPaths) async {
    if (pdfPaths.length < 2) return null;

    try {
      // Read all PDF files in PARALLEL for speed
      final List<Future<Uint8List>> readFutures = pdfPaths
          .map((path) => File(path).readAsBytes())
          .toList();
      
      final List<Uint8List> pdfBytesList = await Future.wait(readFutures);

      // Process merge in background isolate
      final List<int> outputBytes = await compute(
        mergePdfsFastIsolate,
        MergeRequest(pdfBytesList),
      );

      // Save the merged document
      final String outputPath = await _getOutputPath('merged_pdf');
      await File(outputPath).writeAsBytes(outputBytes, flush: true);

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
      // Read all image files in PARALLEL
      final List<Future<Uint8List>> readFutures = imagePaths
          .map((path) => File(path).readAsBytes())
          .toList();
      
      final List<Uint8List> imageBytes = await Future.wait(readFutures);

      // Process in background isolate
      final List<int> outputBytes = await compute(
        imagesToPdfIsolate,
        ImageToPdfRequest(imageBytes),
      );

      // Save the document
      final String outputPath = await _getOutputPath('images_to_pdf');
      await File(outputPath).writeAsBytes(outputBytes, flush: true);

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
        splitPdfByRangeIsolate,
        SplitRequest(bytes, startPage, endPage),
      );

      if (outputBytes == null) return null;

      // Save the new document
      final String outputPath =
          await _getOutputPath('split_${startPage}_to_$endPage');
      await File(outputPath).writeAsBytes(outputBytes, flush: true);

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
        splitPdfAllPagesIsolate,
        bytes,
      );

      // Save each page in parallel
      final List<Future<void>> saveFutures = [];
      for (int i = 0; i < results.length; i++) {
        final String outputPath = await _getOutputPath('page_${i + 1}');
        outputPaths.add(outputPath);
        saveFutures.add(File(outputPath).writeAsBytes(results[i], flush: true));
      }
      await Future.wait(saveFutures);
      
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
