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

/// Data class for extracting multiple specific pages
class ExtractPagesRequest {
  final Uint8List pdfBytes;
  final List<int> pageIndices; // 0-based page indices
  ExtractPagesRequest(this.pdfBytes, this.pageIndices);
}

/// OPTIMIZED: Fast merge - templates must be used before source doc is disposed
List<int> mergePdfsFastIsolate(MergeRequest request) {
  if (request.pdfBytesList.isEmpty) return [];
  
  // Create output document
  final PdfDocument outputDoc = PdfDocument();
  
  // Remove default empty page
  if (outputDoc.pages.count > 0) {
    outputDoc.pages.removeAt(0);
  }
  
  // Track current section for same-sized pages (reduces section allocation overhead)
  PdfSection? currentSection;
  double currentWidth = -1;
  double currentHeight = -1;
  
  // Process each PDF document
  for (final Uint8List pdfBytes in request.pdfBytesList) {
    final PdfDocument sourceDoc = PdfDocument(inputBytes: pdfBytes);
    final int pageCount = sourceDoc.pages.count;
    
    // Extract templates and add to output BEFORE disposing source
    for (int i = 0; i < pageCount; i++) {
      final PdfTemplate template = sourceDoc.pages[i].createTemplate();
      final double templateWidth = template.size.width;
      final double templateHeight = template.size.height;
      
      // Create new section only if page size differs
      if (currentSection == null || 
          currentWidth != templateWidth || 
          currentHeight != templateHeight) {
        currentSection = outputDoc.sections?.add();
        if (currentSection != null) {
          currentSection.pageSettings.size = Size(templateWidth, templateHeight);
          currentSection.pageSettings.margins.all = 0;
          currentWidth = templateWidth;
          currentHeight = templateHeight;
        }
      }
      
      // Add page and draw template
      if (currentSection != null) {
        currentSection.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
      }
    }
    
    // Dispose source document after all its pages are processed
    sourceDoc.dispose();
  }

  // Save and cleanup
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

  // Track current section for same-sized pages (optimization)
  PdfSection? currentSection;
  Size? currentSize;

  for (int i = request.startPage - 1; i < request.endPage; i++) {
    final PdfPage sourcePage = sourceDocument.pages[i];
    final PdfTemplate template = sourcePage.createTemplate();
    final Size templateSize = template.size;
    
    // Reuse section if page size is same
    if (currentSection == null || currentSize != templateSize) {
      currentSection = newDocument.sections!.add();
      currentSection.pageSettings.size = templateSize;
      currentSection.pageSettings.margins.all = 0;
      currentSize = templateSize;
    }
    
    currentSection.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
  }

  sourceDocument.dispose();
  final List<int> outputBytes = newDocument.saveSync();
  newDocument.dispose();
  return outputBytes;
}

/// OPTIMIZED: Extract multiple specific pages into one PDF (handles non-consecutive pages)
List<int>? extractPagesIsolate(ExtractPagesRequest request) {
  if (request.pageIndices.isEmpty) return null;
  
  final PdfDocument sourceDocument = PdfDocument(inputBytes: request.pdfBytes);
  final int totalPages = sourceDocument.pages.count;
  
  // Validate all page indices
  for (int idx in request.pageIndices) {
    if (idx < 0 || idx >= totalPages) {
      sourceDocument.dispose();
      return null;
    }
  }

  final PdfDocument newDocument = PdfDocument();
  
  // Remove default page
  if (newDocument.pages.count > 0) {
    newDocument.pages.removeAt(0);
  }

  // Track current section for same-sized pages (optimization)
  PdfSection? currentSection;
  Size? currentSize;

  for (int pageIdx in request.pageIndices) {
    final PdfPage sourcePage = sourceDocument.pages[pageIdx];
    final PdfTemplate template = sourcePage.createTemplate();
    final Size templateSize = template.size;
    
    // Reuse section if page size is same
    if (currentSection == null || currentSize != templateSize) {
      currentSection = newDocument.sections!.add();
      currentSection.pageSettings.size = templateSize;
      currentSection.pageSettings.margins.all = 0;
      currentSize = templateSize;
    }
    
    currentSection.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
  }

  sourceDocument.dispose();
  final List<int> outputBytes = newDocument.saveSync();
  newDocument.dispose();
  return outputBytes;
}

/// OPTIMIZED: Isolate function for splitting PDF into all pages
/// Pre-creates all templates first to minimize repeated parsing
List<List<int>> splitPdfAllPagesIsolate(Uint8List pdfBytes) {
  final PdfDocument sourceDocument = PdfDocument(inputBytes: pdfBytes);
  final int totalPages = sourceDocument.pages.count;
  
  // Pre-create all templates first (faster than recreating source doc each time)
  final List<PdfTemplate> templates = [];
  for (int i = 0; i < totalPages; i++) {
    templates.add(sourceDocument.pages[i].createTemplate());
  }
  
  // Now create individual page PDFs
  List<List<int>> results = [];
  for (int i = 0; i < totalPages; i++) {
    final PdfDocument singlePageDoc = PdfDocument();
    
    // Remove default page
    if (singlePageDoc.pages.count > 0) {
      singlePageDoc.pages.removeAt(0);
    }
    
    final PdfTemplate template = templates[i];
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
  // Pre-cached directory path for faster file operations
  static String? _cachedOutputDir;
  
  /// Get or cache the output directory
  static Future<String> _getOutputDir() async {
    if (_cachedOutputDir == null) {
      final Directory directory = await getApplicationDocumentsDirectory();
      _cachedOutputDir = directory.path;
    }
    return _cachedOutputDir!;
  }

  /// Merge PDFs from pre-loaded bytes (fastest - no file I/O)
  static Future<String?> mergePdfsFromBytes(List<Uint8List> pdfBytesList) async {
    if (pdfBytesList.length < 2) return null;

    try {
      // Pre-compute output path BEFORE isolate work (parallel preparation)
      final String outputDir = await _getOutputDir();
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String outputPath = '$outputDir/merged_pdf_$timestamp.pdf';
      
      // Process merge in background isolate (bytes already loaded)
      final List<int> outputBytes = await compute(
        mergePdfsFastIsolate,
        MergeRequest(pdfBytesList),
      );

      // Save with explicit buffer size for large files
      final File outputFile = File(outputPath);
      final IOSink sink = outputFile.openWrite(mode: FileMode.writeOnly);
      sink.add(outputBytes);
      await sink.flush();
      await sink.close();

      return outputPath;
    } catch (e) {
      debugPrint('Error merging PDFs: $e');
      return null;
    }
  }

  /// Merge multiple PDF files into one - OPTIMIZED
  static Future<String?> mergePdfs(List<String> pdfPaths) async {
    if (pdfPaths.length < 2) return null;

    try {
      // Read all PDF files in PARALLEL for speed
      final List<Uint8List> pdfBytesList = await Future.wait(
        pdfPaths.map((path) => File(path).readAsBytes()),
      );

      return mergePdfsFromBytes(pdfBytesList);
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

  /// OPTIMIZED: Split PDF by page range from pre-loaded bytes (avoids re-reading file)
  static Future<String?> splitPdfByRangeFromBytes(
      Uint8List pdfBytes, int startPage, int endPage) async {
    try {
      // Process in background isolate
      final List<int>? outputBytes = await compute(
        splitPdfByRangeIsolate,
        SplitRequest(pdfBytes, startPage, endPage),
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

  /// OPTIMIZED: Extract multiple specific pages into one PDF (handles non-consecutive pages)
  static Future<String?> extractPagesFromBytes(
      Uint8List pdfBytes, List<int> pageIndices) async {
    try {
      // Process in background isolate
      final List<int>? outputBytes = await compute(
        extractPagesIsolate,
        ExtractPagesRequest(pdfBytes, pageIndices),
      );

      if (outputBytes == null) return null;

      // Save the new document
      final String outputPath = await _getOutputPath('extracted_pages');
      await File(outputPath).writeAsBytes(outputBytes, flush: true);

      return outputPath;
    } catch (e) {
      debugPrint('Error extracting pages: $e');
      return null;
    }
  }

  /// Split PDF into individual pages
  static Future<List<String>> splitPdfAllPages(String pdfPath) async {
    try {
      final Uint8List bytes = await File(pdfPath).readAsBytes();
      return splitPdfAllPagesFromBytes(bytes);
    } catch (e) {
      debugPrint('Error splitting PDF into pages: $e');
      return [];
    }
  }

  /// OPTIMIZED: Split PDF into individual pages from cached bytes
  static Future<List<String>> splitPdfAllPagesFromBytes(Uint8List pdfBytes) async {
    List<String> outputPaths = [];

    try {
      // Process in background isolate
      final List<List<int>> results = await compute(
        splitPdfAllPagesIsolate,
        pdfBytes,
      );

      // Generate all output paths first
      final Directory directory = await getApplicationDocumentsDirectory();
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      
      for (int i = 0; i < results.length; i++) {
        outputPaths.add('${directory.path}/page_${i + 1}_$timestamp.pdf');
      }

      // Save all pages in parallel
      await Future.wait(
        List.generate(results.length, (i) => 
          File(outputPaths[i]).writeAsBytes(results[i], flush: true)
        ),
      );
      
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
