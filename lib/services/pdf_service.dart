import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:image/image.dart' as img;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import 'pdf_core_service.dart';
import 'pdf_raster.dart';

/// All PDF document operations, on one engine.
///
/// Every call here goes through `flutter_pdf_core` — the from-scratch Rust
/// core vendored at `packages/flutter_pdf_core`. There is no second PDF
/// implementation in the app: parsing, rewriting, rendering and composition
/// all come from the same object model, so what the viewer draws is exactly
/// the document that was written.
///
/// Structural operations are path-in / path-out. The core reads its input
/// from disk, so streaming whole documents through Dart `Uint8List`s (which
/// is what this used to do) is both slower and far heavier on a phone.
class PdfService {
  PdfService._();

  // -------------------------------------------------------------- assembly

  /// Merge [paths] in order. Returns the output path, or null on failure.
  ///
  /// [fileName] is the title the user typed; without one the output falls
  /// back to the timestamped name.
  static Future<String?> mergeFiles(
    List<String> paths, {
    String? fileName,
  }) async {
    if (paths.length < 2) return null;
    try {
      return await PdfCoreService.merge(paths, fileName: fileName);
    } catch (e) {
      logError('PdfService.mergeFiles', e);
      return null;
    }
  }

  /// Extract the given 0-based [pageIndices] into one PDF, in the order given.
  static Future<String?> extractPagesFromFile(
    String path,
    List<int> pageIndices, {
    String password = '',
    String? fileName,
  }) async {
    if (pageIndices.isEmpty) return null;
    try {
      return await PdfCoreService.extractPages(
        path,
        pageIndices.map((page) => page + 1).join(','),
        password: password,
        fileName: fileName,
      );
    } catch (e) {
      logError('PdfService.extractPagesFromFile', e);
      return null;
    }
  }

  /// One output PDF per 1-based inclusive range.
  ///
  /// [fileName] names the *set*: each output gets the page range appended, so
  /// one title still yields distinguishable files.
  static Future<List<String>> splitRangesFromFile(
    String path,
    List<({int start, int end})> ranges, {
    String password = '',
    String? fileName,
  }) async {
    final outputs = <String>[];
    try {
      for (final range in ranges) {
        if (range.start < 1 || range.end < range.start) {
          throw ArgumentError('Invalid page range.');
        }
        outputs.add(
          await PdfCoreService.extractPages(
            path,
            '${range.start}-${range.end}',
            prefix: 'split_${range.start}_to_${range.end}',
            password: password,
            fileName: fileName == null
                ? null
                : '$fileName ${range.start}-${range.end}',
          ),
        );
      }
    } catch (e) {
      // A partial set must never be reported as a successful split.
      for (final output in outputs) {
        try {
          await File(output).delete();
        } catch (_) {}
      }
      logError('PdfService.splitRangesFromFile', e);
      return [];
    }
    return outputs;
  }

  /// One output PDF per page.
  ///
  /// [fileName] names the set; each output gets its page number appended.
  static Future<List<String>> splitAllPagesFromFile(
    String path, {
    String password = '',
    int? pageCount,
    String? fileName,
  }) async {
    try {
      return await PdfCoreService.splitAllPages(
        path,
        password: password,
        pageCount: pageCount,
        fileName: fileName,
      );
    } catch (e) {
      logError('PdfService.splitAllPagesFromFile', e);
      return [];
    }
  }

  // ------------------------------------------------------------ image → PDF

  /// Build a PDF from images, one page each.
  ///
  /// JPEG inputs are embedded as `DCTDecode` streams *without* being decoded,
  /// so at Maximum quality the camera's own bytes end up in the PDF untouched.
  /// Anything else (PNG, HEIC) — or any lower quality setting — is transcoded
  /// to JPEG first, on a background isolate.
  static Future<String?> imagesToPdf(
    List<String> imagePaths, {
    String outputQuality = 'High',
    bool fitToPage = false,
    String? fileName,
  }) async {
    if (imagePaths.isEmpty) return null;
    Directory? workDir;
    String? outputPath;
    try {
      final quality = qualityStringToJpegQuality(outputQuality);
      final tempDir = await getTemporaryDirectory();
      workDir = await tempDir.createTemp('pdf_images_');
      final jpegPaths = await _prepareJpegs(imagePaths, quality, workDir);

      final dir = await getApplicationDocumentsDirectory();
      outputPath = await uniqueFilePath(
        dir.path,
        fileName != null && fileName.trim().isNotEmpty
            ? withPdfExtension(sanitizeFileName(fileName))
            : 'images_to_pdf_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await PdfCore.imagesToPdfAsync(
        jpegPaths,
        outputPath,
        fit: fitToPage ? PdfImageFit.contain : PdfImageFit.imageAspect,
      );
      return outputPath;
    } catch (e) {
      if (outputPath != null) {
        try {
          await File(outputPath).delete();
        } catch (_) {}
      }
      logError('PdfService.imagesToPdf', e);
      return null;
    } finally {
      if (workDir != null) {
        try {
          await workDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Map the user-facing quality setting to a JPEG encoder quality (1-100).
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

  /// Return a JPEG path for every input, transcoding only what needs it.
  static Future<List<String>> _prepareJpegs(
    List<String> imagePaths,
    int quality,
    Directory workDir,
  ) async {
    final results = <String>[];

    for (int i = 0; i < imagePaths.length; i++) {
      final path = imagePaths[i];
      final file = File(path);

      final bytes = await file.readAsBytes();
      // Lossless pass-through: already JPEG and no quality reduction asked for.
      if (quality >= 100 &&
          _isJpeg(bytes) &&
          (img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1) == 1) {
        results.add(path);
        continue;
      }

      final jpeg = await compute(
        _transcodeToJpeg,
        _TranscodeRequest(bytes, quality),
      );
      if (jpeg == null) {
        throw FormatException('Image ${i + 1} could not be decoded.');
      }
      final out = File('${workDir.path}/page_$i.jpg');
      await out.writeAsBytes(jpeg);
      results.add(out.path);
    }
    return results;
  }

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  // ------------------------------------------------------------------ queries

  /// Page count, straight from the cross-reference table.
  static Future<int> getPageCount(String pdfPath, {String password = ''}) =>
      PdfRaster.pageCountOf(pdfPath, password: password);

  /// First page's width/height ratio.
  static Future<double?> getFirstPageAspectRatio(
    String pdfPath, {
    String password = '',
  }) => PdfRaster.aspectRatio(pdfPath, password: password);

  /// First-page thumbnail as PNG bytes.
  static Future<Uint8List?> generateThumbnail(
    String pdfPath, {
    String password = '',
  }) => PdfRaster.thumbnail(pdfPath, password: password);

  /// Page previews for the grid screens.
  static Future<List<Uint8List?>> loadPagePreviews(
    String pdfPath, {
    String password = '',
    int? pageCount,
    void Function(int done, int total)? onProgress,
  }) => PdfRaster.renderAllPages(
    pdfPath,
    password: password,
    pageCount: pageCount,
    onProgress: onProgress,
  );

  // ----------------------------------------------------------------- plumbing

  /// Hand the file to whatever app the OS uses for PDFs.
  static Future<void> openPdf(String filePath) async {
    try {
      await OpenFile.open(filePath);
    } catch (e) {
      logError('PdfService.openPdf', e);
    }
  }

  static Future<String> getOutputDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;
}

/// Payload for [_transcodeToJpeg] (must be sendable to an isolate).
class _TranscodeRequest {
  const _TranscodeRequest(this.bytes, this.quality);
  final Uint8List bytes;
  final int quality;
}

/// Decode any supported image format and re-encode it as JPEG.
/// Returns null when the input cannot be decoded.
Uint8List? _transcodeToJpeg(_TranscodeRequest request) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) return null;
  return Uint8List.fromList(
    img.encodeJpg(img.bakeOrientation(decoded), quality: request.quality),
  );
}
