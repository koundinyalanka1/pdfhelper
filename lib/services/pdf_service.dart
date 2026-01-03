import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

class PdfService {
  /// Merge multiple PDF files into one
  static Future<String?> mergePdfs(List<String> pdfPaths) async {
    if (pdfPaths.length < 2) return null;

    try {
      // Create a new PDF document
      final PdfDocument mergedDocument = PdfDocument();
      PdfSection? section;

      for (String path in pdfPaths) {
        // Load each PDF file
        final File file = File(path);
        final Uint8List bytes = await file.readAsBytes();
        final PdfDocument sourceDocument = PdfDocument(inputBytes: bytes);

        // Import all pages from source document
        for (int i = 0; i < sourceDocument.pages.count; i++) {
          // Create a template from the source page
          final PdfTemplate template = sourceDocument.pages[i].createTemplate();

          // Create a new section if page settings differ
          if (section == null || section.pageSettings.size != template.size) {
            section = mergedDocument.sections!.add();
            section.pageSettings.size = template.size;
            section.pageSettings.margins.all = 0;
          }

          // Add the template to the new document
          section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
        }

        sourceDocument.dispose();
      }

      // Save the merged document
      final String outputPath = await _getOutputPath('merged_pdf');
      final List<int> outputBytes = await mergedDocument.save();
      final File outputFile = File(outputPath);
      await outputFile.writeAsBytes(outputBytes);
      mergedDocument.dispose();

      return outputPath;
    } catch (e) {
      print('Error merging PDFs: $e');
      return null;
    }
  }

  /// Convert images to PDF
  static Future<String?> imagesToPdf(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return null;

    try {
      final PdfDocument document = PdfDocument();

      for (String imagePath in imagePaths) {
        final File imageFile = File(imagePath);
        final Uint8List imageBytes = await imageFile.readAsBytes();

        // Create a bitmap from image bytes
        final PdfBitmap image = PdfBitmap(imageBytes);

        // Add a page with the appropriate size
        final PdfPage page = document.pages.add();

        // Get client size of the page
        final Size pageSize = page.getClientSize();

        // Scale image to fit page while maintaining aspect ratio
        double imageWidth = image.width.toDouble();
        double imageHeight = image.height.toDouble();
        double aspectRatio = imageWidth / imageHeight;

        double drawWidth, drawHeight;
        if (aspectRatio > (pageSize.width / pageSize.height)) {
          // Image is wider than page ratio
          drawWidth = pageSize.width;
          drawHeight = drawWidth / aspectRatio;
        } else {
          // Image is taller than page ratio
          drawHeight = pageSize.height;
          drawWidth = drawHeight * aspectRatio;
        }

        // Center the image on the page
        double x = (pageSize.width - drawWidth) / 2;
        double y = (pageSize.height - drawHeight) / 2;

        // Draw image on the page
        page.graphics.drawImage(
          image,
          Rect.fromLTWH(x, y, drawWidth, drawHeight),
        );
      }

      // Save the document
      final String outputPath = await _getOutputPath('images_to_pdf');
      final List<int> bytes = await document.save();
      final File outputFile = File(outputPath);
      await outputFile.writeAsBytes(bytes);
      document.dispose();

      return outputPath;
    } catch (e) {
      print('Error converting images to PDF: $e');
      return null;
    }
  }

  /// Split PDF by page range
  static Future<String?> splitPdfByRange(
      String pdfPath, int startPage, int endPage) async {
    try {
      final File file = File(pdfPath);
      final Uint8List bytes = await file.readAsBytes();
      final PdfDocument sourceDocument = PdfDocument(inputBytes: bytes);

      // Validate page range
      final int totalPages = sourceDocument.pages.count;
      if (startPage < 1 || endPage > totalPages || startPage > endPage) {
        sourceDocument.dispose();
        return null;
      }

      // Create new document with selected pages
      final PdfDocument newDocument = PdfDocument();
      PdfSection? section;

      for (int i = startPage - 1; i < endPage; i++) {
        final PdfTemplate template = sourceDocument.pages[i].createTemplate();

        // Create a new section if page settings differ
        if (section == null || section.pageSettings.size != template.size) {
          section = newDocument.sections!.add();
          section.pageSettings.size = template.size;
          section.pageSettings.margins.all = 0;
        }

        section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);
      }

      sourceDocument.dispose();

      // Save the new document
      final String outputPath =
          await _getOutputPath('split_${startPage}_to_$endPage');
      final List<int> outputBytes = await newDocument.save();
      final File outputFile = File(outputPath);
      await outputFile.writeAsBytes(outputBytes);
      newDocument.dispose();

      return outputPath;
    } catch (e) {
      print('Error splitting PDF: $e');
      return null;
    }
  }

  /// Split PDF into individual pages
  static Future<List<String>> splitPdfAllPages(String pdfPath) async {
    List<String> outputPaths = [];

    try {
      final File file = File(pdfPath);
      final Uint8List bytes = await file.readAsBytes();
      final PdfDocument sourceDocument = PdfDocument(inputBytes: bytes);

      final int totalPages = sourceDocument.pages.count;

      for (int i = 0; i < totalPages; i++) {
        final PdfDocument singlePageDoc = PdfDocument();
        final PdfTemplate template = sourceDocument.pages[i].createTemplate();

        // Set up section with same size as source
        final PdfSection section = singlePageDoc.sections!.add();
        section.pageSettings.size = template.size;
        section.pageSettings.margins.all = 0;

        section.pages.add().graphics.drawPdfTemplate(template, Offset.zero);

        final String outputPath = await _getOutputPath('page_${i + 1}');
        final List<int> outputBytes = await singlePageDoc.save();
        final File outputFile = File(outputPath);
        await outputFile.writeAsBytes(outputBytes);
        singlePageDoc.dispose();

        outputPaths.add(outputPath);
      }

      sourceDocument.dispose();
    } catch (e) {
      print('Error splitting PDF into pages: $e');
    }

    return outputPaths;
  }

  /// Get the page count of a PDF file
  static Future<int> getPageCount(String pdfPath) async {
    try {
      final File file = File(pdfPath);
      final Uint8List bytes = await file.readAsBytes();
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      final int pageCount = document.pages.count;
      document.dispose();
      return pageCount;
    } catch (e) {
      print('Error getting page count: $e');
      return 0;
    }
  }

  /// Open a PDF file with the default viewer
  static Future<void> openPdf(String filePath) async {
    try {
      await OpenFile.open(filePath);
    } catch (e) {
      print('Error opening PDF: $e');
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
