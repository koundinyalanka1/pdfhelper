import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import 'pdf_raster.dart';

export 'package:flutter_pdf_core/flutter_pdf_core.dart'
    show PdfException, PdfInfo, PdfMetadata, PdfOcrPage, PdfOcrStatus;

/// Availability of the `flutter_pdf_core` native (Rust) library.
///
/// The plugin ships source only — the `.so` / `.xcframework` has to be built
/// once with `./scripts/build_pdf_core.sh`. Until that happens the very first
/// FFI symbol lookup throws, so every call site would blow up at runtime.
/// [probe] resolves that once at startup and [isAvailable] lets screens say
/// so plainly instead of failing with a confusing FFI error.
///
/// There is no fallback engine: this *is* the app's PDF implementation.
enum PdfCoreStatus { unknown, available, unavailable }

/// App-facing wrapper over `PdfCore`.
///
/// Everything here is path-in / path-out and runs on a background isolate:
/// the native core reads files itself, so streaming whole PDFs through Dart
/// `Uint8List`s is both slower and far heavier on a phone.
class PdfCoreService {
  PdfCoreService._();

  static PdfCoreStatus _status = PdfCoreStatus.unknown;
  static String _version = '';
  static String _unavailableReason = '';

  static PdfCoreStatus get status => _status;
  static bool get isAvailable => _status == PdfCoreStatus.available;

  /// Native core version, empty when unavailable.
  static String get version => _version;

  /// Why the native core could not be loaded (for the Settings diagnostics row).
  static String get unavailableReason => _unavailableReason;

  /// Resolve the native library once. Never throws.
  ///
  /// Call during startup, before any screen touches [PdfCoreService].
  static Future<void> probe() async {
    if (_status != PdfCoreStatus.unknown) return;
    try {
      // Cheapest possible symbol: forces DynamicLibrary resolution + lookup.
      _version = PdfCore.nativeVersion;
      _status = PdfCoreStatus.available;
      debugPrint('[PdfCoreService] native core $_version');
    } catch (e) {
      _status = PdfCoreStatus.unavailable;
      _unavailableReason = e.toString();
      logError('PdfCoreService', 'native core unavailable: $e');
    }
  }

  // ---------------------------------------------------------------- queries

  /// Document summary (version, page count, encryption flag, metadata).
  static Future<PdfInfo?> inspect(String path, {String password = ''}) async {
    if (!isAvailable) return null;
    try {
      return await PdfCore.inspectAsync(path, password: password);
    } catch (e) {
      logError('PdfCoreService.inspect', e);
      rethrow;
    }
  }

  /// `true` when the file needs a password to open.
  static Future<bool> isEncrypted(String path) async {
    if (!isAvailable) return false;
    try {
      final info = await PdfCore.inspectAsync(path);
      return info.encrypted;
    } on PdfException catch (e) {
      return e.isEncrypted;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> pageCount(String path, {String password = ''}) async {
    if (!isAvailable) return null;
    try {
      return await PdfCore.pageCountAsync(path, password: password);
    } catch (e) {
      logError('PdfCoreService.pageCount', e);
      return null;
    }
  }

  // -------------------------------------------------------- transformations

  /// Merge [inputPaths] in order. Returns the output path.
  ///
  /// [fileName] is the user-chosen title; without one the output keeps the
  /// old `merged_pdf_<millis>.pdf` form.
  ///
  /// [passwords] runs parallel to [inputPaths]. The native merge opens every
  /// input without a password, so each protected input is first decrypted to
  /// a scratch copy, which is deleted once the merge is done.
  static Future<String> merge(
    List<String> inputPaths, {
    List<String>? passwords,
    String? fileName,
  }) async {
    final out = await _outputPath('merged_pdf', fileName: fileName);
    Directory? scratch;
    try {
      final sources = <String>[];
      for (int i = 0; i < inputPaths.length; i++) {
        final password = passwords != null && i < passwords.length
            ? passwords[i]
            : '';
        if (password.isEmpty) {
          sources.add(inputPaths[i]);
          continue;
        }
        scratch ??= await (await getTemporaryDirectory()).createTemp('merge_');
        final unlocked = '${scratch.path}/$i.pdf';
        await PdfCore.decryptAsync(inputPaths[i], password, unlocked);
        sources.add(unlocked);
      }
      await PdfCore.mergeAsync(sources, out);
    } finally {
      if (scratch != null) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {}
      }
    }
    return out;
  }

  /// Copy [pages] (1-based selection string, e.g. `'1-3,7'`) into a new file.
  static Future<String> extractPages(
    String path,
    String pages, {
    String prefix = 'extracted_pages',
    String password = '',
    String? fileName,
  }) async {
    final out = await _outputPath(prefix, fileName: fileName);
    await PdfCore.extractPagesAsync(path, pages, out, password: password);
    return out;
  }

  /// Delete [pages] (1-based selection string) and keep the rest.
  static Future<String> deletePages(
    String path,
    String pages, {
    String password = '',
  }) async {
    final out = await _outputPath('pages_removed');
    await PdfCore.deletePagesAsync(path, pages, out, password: password);
    return out;
  }

  /// [order] must mention every page exactly once, e.g. `'3,1,2'`.
  static Future<String> reorderPages(
    String path,
    String order, {
    String password = '',
  }) async {
    final out = await _outputPath('reordered');
    await PdfCore.reorderPagesAsync(path, order, out, password: password);
    return out;
  }

  /// Rotate by [degrees] (multiple of 90). Empty [pages] rotates everything.
  static Future<String> rotatePages(
    String path,
    int degrees, {
    String pages = '',
    String password = '',
  }) async {
    final out = await _outputPath('rotated');
    await PdfCore.rotatePagesAsync(
      path,
      degrees,
      out,
      pages: pages,
      password: password,
    );
    return out;
  }

  /// Write `/Info` metadata. `null` fields are left untouched, `''` deletes.
  static Future<String> setMetadata(
    String path,
    PdfMetadata metadata, {
    String password = '',
  }) async {
    final out = await _outputPath('metadata');
    // setMetadata has no async variant upstream; keep the UI thread clear.
    await Isolate.run(
      () => PdfCore.setMetadata(path, metadata, out, password: password),
    );
    return out;
  }

  /// AES-256 (PDF 2.0) password protection.
  static Future<String> protect(
    String path,
    String userPassword, {
    String ownerPassword = '',
    String password = '',
    String? fileName,
  }) async {
    final out = await _outputPath('protected', fileName: fileName);
    await PdfCore.encryptAsync(
      path,
      userPassword,
      out,
      ownerPassword: ownerPassword,
      password: password,
    );
    return out;
  }

  /// Remove encryption (needs the correct [password]).
  static Future<String> unlock(
    String path,
    String password, {
    String? fileName,
  }) async {
    final out = await _outputPath('unlocked', fileName: fileName);
    await PdfCore.decryptAsync(path, password, out);
    return out;
  }

  /// Split into one file per page. Returns the output paths in page order.
  static Future<List<String>> splitAllPages(
    String path, {
    String password = '',
    int? pageCount,
    String? fileName,
  }) async {
    final total =
        pageCount ?? await PdfCore.pageCountAsync(path, password: password);
    final outputs = <String>[];
    try {
      for (int i = 1; i <= total; i++) {
        final out = await _outputPath(
          'page_$i',
          fileName: fileName == null ? null : '$fileName $i',
        );
        await PdfCore.extractPagesAsync(path, '$i', out, password: password);
        outputs.add(out);
      }
    } catch (_) {
      for (final output in outputs) {
        try {
          await File(output).delete();
        } catch (_) {}
      }
      rethrow;
    }
    return outputs;
  }

  // -------------------------------------------------------------- text / AI

  /// Plain text. With [page] (1-based) a single page, otherwise the whole
  /// document with pages separated by form feed (`\f`).
  static Future<String> extractText(
    String path, {
    int? page,
    String password = '',
  }) {
    return PdfCore.extractTextAsync(path, page: page, password: password);
  }

  /// AI-ready export: paragraph-aware overlapping chunks with page ranges,
  /// ready to feed an on-device model. See [AiDocumentIndex] for the consumer.
  static Future<AiExport> exportForAi(
    String path, {
    String password = '',
    int maxChars = 1200,
    int overlap = 150,
  }) async {
    final raw = await PdfCore.exportForAiAsync(
      path,
      password: password,
      maxChars: maxChars,
      overlap: overlap,
    );
    return AiExport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  // -------------------------------------------------------------------- OCR

  /// Read the text on [pages] (1-based; null means every page) with the
  /// engine's on-device OCR, one page at a time, so that [onProgress] can
  /// report each page and [isCancelled] can stop between them.
  ///
  /// Pages that already carry text come back as [PdfOcrStatus.hasText] or
  /// [PdfOcrStatus.hasOcrLayer] without being read. The document stays
  /// parsed for the whole run instead of once per page.
  ///
  /// Throws [OcrCancelled], holding the pages read so far, once
  /// [isCancelled] returns true. The page being read at that moment is
  /// finished first: a native call cannot be interrupted.
  static Future<List<PdfOcrPage>> recognizeText(
    String path, {
    String password = '',
    List<int>? pages,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final pageCount = await PdfRaster.openDocument(path, password: password);
    try {
      final selected =
          pages ?? [for (var page = 1; page <= pageCount; page++) page];
      final results = <PdfOcrPage>[];
      onProgress?.call(0, selected.length);
      for (final page in selected) {
        if (isCancelled?.call() ?? false) throw OcrCancelled(results);
        results.add(
          await PdfCore.ocrPage(path, page: page, password: password),
        );
        onProgress?.call(results.length, selected.length);
      }
      return results;
    } finally {
      unawaited(PdfRaster.closeDocument(path, password: password));
    }
  }

  /// Save a copy of [path] with an invisible layer of recognized text over
  /// its scanned pages, so the text can be searched, selected and copied
  /// while the pages look exactly as before.
  ///
  /// No file is written when no page gained text: every page had text
  /// already, or none had any that could be read. [SearchableCopy.pages]
  /// says which.
  ///
  /// The engine writes the copy without encryption, as it does for every
  /// operation. A protected original is not quietly unlocked by being made
  /// searchable: the copy is locked again with the same password.
  static Future<SearchableCopy> makeSearchable(
    String path, {
    String password = '',
    String? fileName,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final pages = await recognizeText(
      path,
      password: password,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    final read = _withText(pages);
    if (read.isEmpty) return SearchableCopy(pages: pages);
    if (isCancelled?.call() ?? false) throw OcrCancelled(pages);
    final out = await _outputPath('searchable', fileName: fileName);
    if (password.isEmpty) {
      await PdfCore.applyOcrAsync(path, read, out);
      return SearchableCopy(pages: pages, outputPath: out);
    }
    final scratch = await (await getTemporaryDirectory()).createTemp('ocr_');
    try {
      final unlocked = '${scratch.path}/searchable.pdf';
      await PdfCore.applyOcrAsync(path, read, unlocked, password: password);
      await PdfCore.encryptAsync(unlocked, password, out);
    } finally {
      try {
        await scratch.delete(recursive: true);
      } catch (_) {}
    }
    return SearchableCopy(pages: pages, outputPath: out);
  }

  /// [makeSearchable] for a PDF this app has just built from photos, writing
  /// over [path] itself rather than a copy. Returns how many pages gained
  /// text. The file is replaced only once the new one is complete, so a
  /// failure or [OcrCancelled] leaves it as it was.
  static Future<int> addTextLayer(
    String path, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final pages = await recognizeText(
      path,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    final read = _withText(pages);
    if (read.isEmpty) return 0;
    if (isCancelled?.call() ?? false) throw OcrCancelled(pages);
    // Beside the original, so the rename cannot cross filesystems; not
    // ending in .pdf, so the library never lists it.
    final layered = '$path.ocr';
    try {
      await PdfCore.applyOcrAsync(path, read, layered);
      await File(layered).rename(path);
    } catch (_) {
      try {
        await File(layered).delete();
      } catch (_) {}
      rethrow;
    }
    return read.length;
  }

  static List<PdfOcrPage> _withText(List<PdfOcrPage> pages) => [
    for (final page in pages)
      if (page.status == PdfOcrStatus.recognized && page.lines.isNotEmpty) page,
  ];

  // ------------------------------------------------------------------ utils

  /// Turn a set of 0-based page indices into the 1-based range string the
  /// native core expects (`{0,1,2,5}` → `'1-3,6'`).
  static String toPageSelection(Iterable<int> zeroBasedPages) {
    final pages = zeroBasedPages.map((p) => p + 1).toSet().toList()..sort();
    if (pages.isEmpty) return '';
    final parts = <String>[];
    int start = pages.first;
    int prev = pages.first;
    for (final p in pages.skip(1)) {
      if (p == prev + 1) {
        prev = p;
        continue;
      }
      parts.add(start == prev ? '$start' : '$start-$prev');
      start = p;
      prev = p;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    return parts.join(',');
  }

  /// Human-readable message for a [PdfException] (or anything else).
  static String describeError(Object error) {
    if (error is! PdfException) return 'Something went wrong: $error';
    switch (error.code) {
      case 'ENCRYPTED':
        return 'This PDF is password protected. Enter its password to continue.';
      case 'WRONG_PASSWORD':
        return 'That password does not open this PDF.';
      case 'NOT_A_PDF':
        return 'That file is not a readable PDF.';
      case 'PAGE_OUT_OF_RANGE':
        return 'The selected pages are outside this document.';
      default:
        return error.message.isEmpty ? 'PDF operation failed.' : error.message;
    }
  }

  /// Where an operation's output goes.
  ///
  /// A [fileName] the user typed wins over [prefix]; it is sanitised and
  /// de-duplicated, because two PDFs called "Invoice" is an ordinary thing to
  /// ask for and the second must not overwrite the first.
  static Future<String> _outputPath(String prefix, {String? fileName}) async {
    final dir = await getApplicationDocumentsDirectory();
    if (fileName != null && fileName.trim().isNotEmpty) {
      return uniqueFilePath(
        dir.path,
        withPdfExtension(sanitizeFileName(fileName)),
      );
    }
    final ts = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/${prefix}_$ts.pdf';
  }
}

// ---------------------------------------------------------------------------
// AI export model (schema: flutter_pdf_core/export/v1)
// ---------------------------------------------------------------------------

/// One paragraph-aware chunk of document text, with the pages it came from.
class AiChunk {
  const AiChunk({
    required this.id,
    required this.pageStart,
    required this.pageEnd,
    required this.text,
  });

  factory AiChunk.fromJson(Map<String, dynamic> json) => AiChunk(
    id: json['id'] as int? ?? 0,
    pageStart: json['page_start'] as int? ?? 0,
    pageEnd: json['page_end'] as int? ?? 0,
    text: json['text'] as String? ?? '',
  );

  final int id;

  /// 0-based first page contributing to this chunk.
  final int pageStart;

  /// 0-based last page contributing to this chunk.
  final int pageEnd;
  final String text;

  /// `p. 4` or `pp. 4–6`, 1-based, for citations in answers.
  String get citation => pageStart == pageEnd
      ? 'p. ${pageStart + 1}'
      : 'pp. ${pageStart + 1}–${pageEnd + 1}';
}

/// Parsed `PdfCore.exportForAi` document.
class AiExport {
  const AiExport({
    required this.schema,
    required this.pageCount,
    required this.title,
    required this.author,
    required this.pages,
    required this.chunks,
  });

  factory AiExport.fromJson(Map<String, dynamic> json) {
    final metadata =
        (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AiExport(
      schema: json['schema'] as String? ?? '',
      pageCount: json['page_count'] as int? ?? 0,
      title: metadata['title'] as String?,
      author: metadata['author'] as String?,
      pages: ((json['pages'] as List?) ?? const [])
          .map(
            (p) => (p as Map).cast<String, dynamic>()['text'] as String? ?? '',
          )
          .toList(),
      chunks: ((json['chunks'] as List?) ?? const [])
          .map((c) => AiChunk.fromJson((c as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  final String schema;
  final int pageCount;
  final String? title;
  final String? author;

  /// Full text per page, 0-based.
  final List<String> pages;
  final List<AiChunk> chunks;

  /// `true` when the PDF has no extractable text layer (scan-only document) —
  /// the point where OCR would have to step in.
  bool get hasTextLayer => chunks.any((c) => c.text.trim().length > 20);

  int get totalChars => pages.fold(0, (sum, p) => sum + p.length);
}

// ---------------------------------------------------------------------------
// OCR
// ---------------------------------------------------------------------------

/// What [PdfCoreService.makeSearchable] did.
class SearchableCopy {
  const SearchableCopy({required this.pages, this.outputPath});

  /// Every page, in order, as OCR found it.
  final List<PdfOcrPage> pages;

  /// The searchable copy; null when no page gained text, so none was written.
  final String? outputPath;

  /// Pages that now carry recognized text.
  int get recognized => _count(PdfOcrStatus.recognized);

  /// Pages left alone because they had text already, born-digital or from an
  /// earlier OCR pass.
  int get hadText =>
      _count(PdfOcrStatus.hasText) + _count(PdfOcrStatus.hasOcrLayer);

  /// Pages read without finding anything legible.
  int get blank => pages.length - recognized - hadText;

  int _count(PdfOcrStatus status) => pages
      .where(
        (page) =>
            page.status == status &&
            (status != PdfOcrStatus.recognized || page.lines.isNotEmpty),
      )
      .length;
}

/// Thrown when OCR is stopped part way.
class OcrCancelled implements Exception {
  const OcrCancelled(this.pages);

  /// The pages read before it stopped, in order.
  final List<PdfOcrPage> pages;

  @override
  String toString() => 'OcrCancelled after ${pages.length} page(s)';
}

/// Convenience: write extracted text next to the PDF for sharing.
Future<String> writeTextFile(String baseName, String text) async {
  final dir = await getApplicationDocumentsDirectory();
  final safe = sanitizeFileName(baseName);
  final file = File(await uniqueFilePath(dir.path, '$safe.txt'));
  await file.writeAsString(text);
  return file.path;
}
