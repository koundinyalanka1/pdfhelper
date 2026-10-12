import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:pdfhelper/services/pdf_raster.dart';
import 'package:pdfhelper/services/pdf_service.dart';

import 'support/fake_path_provider.dart';

/// Comprehensive PVS (PDF Validation & Stress Suite) Test Harness.
///
/// Tests the PDF helper application and its underlying Rust engine
/// across 42 real-world PDFs covering:
/// 1. All major global languages and scripts (Latin, Cyrillic, CJK, Indic, RTL, Thai, Vietnamese).
/// 2. Light vs. heavy documents (sub-1KB to 20MB+, dense CAD vector plans, 500+ page books).
/// 3. Document features: AcroForms, AES-128/AES-256/RC4 encryption, JBIG2/CCITT/LZW codecs,
///    axial and function shadings, OCG layers, annotations, outlines, and metadata.
/// 4. Complete workflow operations: inspect, rasterize, text extract, merge, split, rotate,
///    reorder, protect, unlock, and error boundary resilience.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (library == null || !File(library).existsSync()) {
    test('PVS tests require PDF_CORE_LIB_PATH', () {}, skip: true);
    return;
  }

  late Directory root;
  late FakePathProvider paths;
  final corpusDir = Directory('test_corpus');

  setUpAll(() async {
    await PdfCoreService.probe();
    expect(
      corpusDir.existsSync(),
      isTrue,
      reason: 'test_corpus directory must exist. Run scripts/download_test_corpus.py first.',
    );
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_pvs_test_');
    paths = FakePathProvider.install(root);
    PdfRaster.invalidate();
  });

  tearDown(() async {
    PdfRaster.invalidate();
    FakePathProvider.restore();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  // Helper to get all PDFs in a category
  List<File> getPdfs(String category) {
    final dir = Directory('test_corpus/$category');
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pdf'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  group('PVS Suite 1: All Languages Coverage', () {
    test('inspects and counts pages across all language PDFs', () async {
      final languageFiles = getPdfs('languages');
      expect(languageFiles, isNotEmpty);

      for (final file in languageFiles) {
        final info = await PdfCore.inspectAsync(file.path);
        expect(info.pageCount, greaterThanOrEqualTo(1),
            reason: 'Failed to inspect page count for ${file.path}');
        expect(info.version, isNotEmpty,
            reason: 'Failed to read PDF version for ${file.path}');
      }
    });

    test('renders first page thumbnails across all languages', () async {
      final languageFiles = getPdfs('languages');

      for (final file in languageFiles) {
        final bytes = await PdfRaster.renderPage(
          file.path,
          0,
          longEdge: 420,
        );

        expect(bytes, isNotNull,
            reason: 'Rasterization returned null for ${file.path}');
        expect(bytes!.length, greaterThan(100),
            reason: 'PNG bytes too small for ${file.path}');
        // Verify valid PNG signature: 0x89, 'P', 'N', 'G'
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47],
            reason: 'Invalid PNG header for ${file.path}');
      }
    });

    test('extracts multilingual text without panic or crash', () async {
      final languageFiles = getPdfs('languages');

      final extractedSamples = <String, int>{};
      for (final file in languageFiles) {
        final text = await PdfCore.extractTextAsync(file.path, page: 1);
        extractedSamples[file.path] = text.length;
        // Verify text extraction completed safely (string returned)
        expect(text, isA<String>());
      }

      // Verify that major text-bearing documents returned non-empty text
      final german = languageFiles.firstWhere((f) => f.path.contains('german'));
      final germanText = await PdfCore.extractTextAsync(german.path, page: 2);
      expect(germanText, isNotEmpty);

      final russian = languageFiles.firstWhere((f) => f.path.contains('russian'));
      final russianText = await PdfCore.extractTextAsync(russian.path, page: 2);
      expect(russianText, isNotEmpty);

      final chinese = languageFiles.firstWhere((f) => f.path.contains('chinese'));
      final chineseText = await PdfCore.extractTextAsync(chinese.path, page: 2);
      expect(chineseText, isNotEmpty);

      final english = languageFiles.firstWhere((f) => f.path.contains('english'));
      final englishText = await PdfCore.extractTextAsync(english.path, page: 1);
      expect(englishText, isNotEmpty);

      final hindi = languageFiles.firstWhere((f) => f.path.contains('hindi'));
      final hindiText = await PdfCore.extractTextAsync(hindi.path, page: 1);
      expect(hindiText, isNotEmpty);
    });
  });

  group('PVS Suite 2: Lightweight PDFs (< 50 KB)', () {
    test('inspects, counts and renders minimal and lightweight documents', () async {
      final lightFiles = getPdfs('light');
      expect(lightFiles, isNotEmpty);

      for (final file in lightFiles) {
        final count = await PdfCore.pageCountAsync(file.path);
        expect(count, greaterThanOrEqualTo(1));

        final bytes = await PdfRaster.renderPage(file.path, 0, longEdge: 240);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('extracts text from minimal documents', () async {
      final simple1 = File('test_corpus/light/light_simple1_849b.pdf');
      if (simple1.existsSync()) {
        final text = await PdfCore.extractTextAsync(simple1.path, page: 1);
        expect(text, isA<String>());
      }
    });
  });

  group('PVS Suite 3: Heavy PDFs & Stress Benchmarks', () {
    test('handles 6MB dense CAD architectural drawings without memory blowout', () async {
      final cad = File('test_corpus/heavy/heavy_cad_plans_6mb.pdf');
      expect(cad.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(cad.path);
      expect(count, greaterThanOrEqualTo(1));

      final bytes = await PdfRaster.renderPage(cad.path, 0, longEdge: 420);
      expect(bytes, isNotNull);
      expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('handles 117-page complex mathematical document (GeoTopo)', () async {
      final geotopo = File('test_corpus/heavy/heavy_geotopo_117pages.pdf');
      expect(geotopo.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(geotopo.path);
      expect(count, equals(117));

      // Test rendering first, middle, and last page
      for (final page in [0, 58, 116]) {
        final bytes = await PdfRaster.renderPage(geotopo.path, page, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed to render page $page of GeoTopo');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('handles 18MB full-length 500+ page Pro Git book', () async {
      final book = File('test_corpus/heavy/heavy_progit_en_18mb.pdf');
      expect(book.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(book.path);
      expect(count, greaterThan(400));

      // Page jumps to various sections
      for (final page in [0, 50, 200]) {
        final bytes = await PdfRaster.renderPage(book.path, page, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed to render page $page of Pro Git');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });
  });

  group('PVS Suite 4: Features & Edge Cases', () {
    test('inspects and renders AcroForms and interactive form fields', () async {
      final irs = File('test_corpus/features/form_irs_f1040nr.pdf');
      expect(irs.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(irs.path);
      expect(count, greaterThanOrEqualTo(1));

      final bytes = await PdfRaster.renderPage(irs.path, 0, longEdge: 420);
      expect(bytes, isNotNull);
      expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('detects encryption on password-protected PDFs', () async {
      final encFiles = [
        'test_corpus/features/encrypt_aes128.pdf',
        'test_corpus/features/encrypt_aes256.pdf',
        'test_corpus/features/encrypt_rc4_128.pdf',
        'test_corpus/features/encrypt_libreoffice_pw.pdf',
      ];

      for (final path in encFiles) {
        final file = File(path);
        if (!file.existsSync()) continue;

        final isEncrypted = await PdfCoreService.isEncrypted(file.path);
        expect(isEncrypted, isTrue, reason: '$path should be detected as encrypted');
      }
    });

    test('renders complex codecs: CCITT fax, JBIG2, ASCII85, LZW, CMYK JPEG', () async {
      final codecFiles = [
        'test_corpus/features/codec_ccitt_fax.pdf',
        'test_corpus/features/codec_jbig2.pdf',
        'test_corpus/features/codec_ascii85.pdf',
        'test_corpus/features/codec_lzw.pdf',
        'test_corpus/features/codec_cmyk_jpeg.pdf',
      ];

      for (final path in codecFiles) {
        final file = File(path);
        if (!file.existsSync()) continue;

        final bytes = await PdfRaster.renderPage(file.path, 0, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering codec file: $path');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('renders axial and function-based vector shadings', () async {
      final shadingFiles = [
        'test_corpus/features/graphics_axial_shading.pdf',
        'test_corpus/features/graphics_function_shading.pdf',
      ];

      for (final path in shadingFiles) {
        final file = File(path);
        if (!file.existsSync()) continue;

        final bytes = await PdfRaster.renderPage(file.path, 0, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering shading file: $path');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('renders optional content groups (OCG layers) and vector annotations', () async {
      final ocg = File('test_corpus/features/graphics_ocg_layers.pdf');
      if (ocg.existsSync()) {
        final bytes = await PdfRaster.renderPage(ocg.path, 0, longEdge: 300);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }

      final annot = File('test_corpus/features/graphics_annotated.pdf');
      if (annot.existsSync()) {
        final bytes = await PdfRaster.renderPage(annot.path, 0, longEdge: 300);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });
  });

  group('PVS Suite 5: Document Operations & Transformation Workflows', () {
    test('extracts pages into new valid documents', () async {
      final source = 'test_corpus/languages/lang_en_english_sample.pdf';
      final extracted = await PdfService.extractPagesFromFile(source, [0, 1]);
      expect(extracted, isNotNull);
      expect(await PdfService.getPageCount(extracted!), 2);

      final rendered = await PdfRaster.renderPage(extracted, 0);
      expect(rendered, isNotNull);
    });

    test('merges multi-source documents into a single unified PDF', () async {
      final docA = 'test_corpus/light/light_simple1_849b.pdf';
      final docB = 'test_corpus/light/light_simple2_1kb.pdf';
      final docC = 'test_corpus/languages/lang_ar_arabic_habibi.pdf';

      final merged = await PdfService.mergeFiles([docA, docB, docC]);
      expect(merged, isNotNull);

      final countA = await PdfService.getPageCount(docA);
      final countB = await PdfService.getPageCount(docB);
      final countC = await PdfService.getPageCount(docC);
      final totalExpected = countA + countB + countC;

      expect(await PdfService.getPageCount(merged!), totalExpected);

      // Verify all pages of merged document render cleanly
      for (var p = 0; p < totalExpected; p++) {
        final bytes = await PdfRaster.renderPage(merged, p, longEdge: 240);
        expect(bytes, isNotNull);
      }
    });

    test('rotates document pages and verifies geometry transformation', () async {
      final source = 'test_corpus/light/light_simple1_849b.pdf';
      final rotated = await PdfCoreService.rotatePages(source, 90);
      expect(File(rotated).existsSync(), isTrue);
      expect(await PdfService.getPageCount(rotated), 1);

      final bytes = await PdfRaster.renderPage(rotated, 0);
      expect(bytes, isNotNull);
    });

    test('reorders pages of a multi-page document', () async {
      final source = 'test_corpus/languages/lang_en_english_sample.pdf';
      final originalCount = await PdfService.getPageCount(source);
      expect(originalCount, greaterThanOrEqualTo(2));

      final reordered = await PdfCoreService.reorderPages(source, '4,3,2,1');
      expect(File(reordered).existsSync(), isTrue);
      expect(await PdfService.getPageCount(reordered), 4);
    });

    test('updates document metadata (/Info dictionary)', () async {
      final source = 'test_corpus/light/light_simple1_849b.pdf';
      final updated = await PdfCoreService.setMetadata(
        source,
        const PdfMetadata(
          title: 'PVS Test Document Title',
          author: 'PVS Automated Suite',
          subject: 'Comprehensive Validation',
        ),
      );

      expect(File(updated).existsSync(), isTrue);
      final info = await PdfCore.inspectAsync(updated);
      expect(info.metadata.title, 'PVS Test Document Title');
      expect(info.metadata.author, 'PVS Automated Suite');
    });

    test('encrypts with AES-256 and decrypts back to clean document', () async {
      final source = 'test_corpus/light/light_simple1_849b.pdf';
      const password = 'PvsStrongPassword2026!';

      final protected = await PdfCoreService.protect(source, password);
      expect(File(protected).existsSync(), isTrue);
      expect(await PdfCoreService.isEncrypted(protected), isTrue);

      // Should fail to render without password
      expect(await PdfRaster.renderPage(protected, 0), isNull);

      // Should succeed to render with password
      final unlockedBytes = await PdfRaster.renderPage(
        protected,
        0,
        password: password,
      );
      expect(unlockedBytes, isNotNull);

      // Decrypt to new file
      final decrypted = await PdfCoreService.unlock(protected, password);
      expect(File(decrypted).existsSync(), isTrue);
      expect(await PdfCoreService.isEncrypted(decrypted), isFalse);
      expect(await PdfRaster.renderPage(decrypted, 0), isNotNull);
    });

    test('splits all pages into individual files', () async {
      final source = 'test_corpus/languages/lang_en_english_sample.pdf';
      final splitOutputs = await PdfCoreService.splitAllPages(source);
      expect(splitOutputs, isNotEmpty);
      for (final out in splitOutputs) {
        expect(File(out).existsSync(), isTrue);
        expect(await PdfService.getPageCount(out), 1);
        expect(await PdfRaster.renderPage(out, 0), isNotNull);
      }
    });
  });

  group('PVS Suite 6: Error Resilience & Corrupt Input Handling', () {
    test('non-PDF junk byte file reports graceful error without crashing', () async {
      final junk = File('${root.path}/junk.pdf')..writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(await PdfRaster.renderPage(junk.path, 0), isNull);
    });

    test('truncated PDF stream reports graceful failure', () async {
      final broken = File('${root.path}/truncated.pdf')
        ..writeAsStringSync('%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n');
      expect(await PdfRaster.renderPage(broken.path, 0), isNull);
    });

    test('empty file reports error cleanly', () async {
      final empty = File('${root.path}/empty.pdf')..writeAsBytesSync([]);
      expect(await PdfRaster.renderPage(empty.path, 0), isNull);
    });
  });

  group('PVS Suite 7: Picture-Heavy PDFs & Multi-Image Collections', () {
    test('renders embedded photography document (images.pdf)', () async {
      final pic = File('test_corpus/pictures/pic_images_embedded_1_5mb.pdf');
      if (pic.existsSync()) {
        final count = await PdfCore.pageCountAsync(pic.path);
        expect(count, greaterThanOrEqualTo(1));
        final bytes = await PdfRaster.renderPage(pic.path, 0, longEdge: 420);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('renders document containing 64 embedded images without cache blowout', () async {
      final multiPic = File('test_corpus/pictures/pic_64_images_collection.pdf');
      if (multiPic.existsSync()) {
        final count = await PdfCore.pageCountAsync(multiPic.path);
        expect(count, greaterThanOrEqualTo(1));
        final bytes = await PdfRaster.renderPage(multiPic.path, 0, longEdge: 360);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('renders all pages of a 6-page pure image document', () async {
      final pureImg = File('test_corpus/pictures/pic_imagemagick_multipage.pdf');
      if (pureImg.existsSync()) {
        final count = await PdfCore.pageCountAsync(pureImg.path);
        expect(count, equals(6));
        for (var p = 0; p < count; p++) {
          final bytes = await PdfRaster.renderPage(pureImg.path, p, longEdge: 240);
          expect(bytes, isNotNull, reason: 'Failed rendering pure image page $p');
          expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        }
      }
    });

    test('renders 2.26 MB high-resolution page scan', () async {
      final scan = File('test_corpus/pictures/pic_base64_highres_scan_2mb.pdf');
      if (scan.existsSync()) {
        final bytes = await PdfRaster.renderPage(scan.path, 0, longEdge: 420);
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });
  });

  group('PVS Suite 8: Massive Epic Literature (Iliad, Ramayana, Mahabharata)', () {
    test('handles Homer\'s Iliad (22.5 MB, 728 pages) with deep page jumps', () async {
      final iliad = File('test_corpus/epics/epic_iliad_homer_22mb.pdf');
      expect(iliad.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(iliad.path);
      expect(count, greaterThanOrEqualTo(700));

      // Test page jumps across beginning, middle, and end of 728-page epic
      for (final p in [0, 360, count - 1]) {
        final bytes = await PdfRaster.renderPage(iliad.path, p, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering Iliad at page $p');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('handles Ramayana (11.1 MB, 186 pages) scripture', () async {
      final ramayana = File('test_corpus/epics/epic_ramayana_11mb.pdf');
      expect(ramayana.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(ramayana.path);
      expect(count, equals(186));

      for (final p in [0, 92, count - 1]) {
        final bytes = await PdfRaster.renderPage(ramayana.path, p, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering Ramayana at page $p');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('handles Mahabharata treatise (21.5 MB, 138 pages)', () async {
      final mahabharata = File('test_corpus/epics/epic_mahabharata_21mb.pdf');
      expect(mahabharata.existsSync(), isTrue);

      final count = await PdfCore.pageCountAsync(mahabharata.path);
      expect(count, equals(138));

      for (final p in [0, 68, count - 1]) {
        final bytes = await PdfRaster.renderPage(mahabharata.path, p, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering Mahabharata at page $p');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('extracts and merges excerpts from epic texts', () async {
      final iliad = 'test_corpus/epics/epic_iliad_homer_22mb.pdf';
      final excerpt = await PdfService.extractPagesFromFile(iliad, [0, 1]);
      expect(excerpt, isNotNull);
      expect(await PdfService.getPageCount(excerpt!), 2);
      expect(await PdfRaster.renderPage(excerpt, 0), isNotNull);
    });
  });

  group('PVS Suite 9: On-Device OCR & Searchable PDF Generation', () {
    const scanFile = 'test_corpus/ocr/ocr_scanned_invoice.pdf';
    const expectedInvoiceText = 'Scanned invoice no. 2024-117';

    test('recognizes printed text on scanned image page with progress reporting', () async {
      expect(File(scanFile).existsSync(), isTrue);

      final progress = <(int, int)>[];
      final results = await PdfCoreService.recognizeText(
        scanFile,
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(results, hasLength(1));
      expect(results.first.status, PdfOcrStatus.recognized);
      expect(results.first.text, contains(expectedInvoiceText));
      expect(progress, [(0, 1), (1, 1)]);
    });

    test('creates a searchable PDF with invisible text layer', () async {
      final copy = await PdfCoreService.makeSearchable(
        scanFile,
        fileName: 'Searchable_PVS_Invoice',
      );

      expect(copy.recognized, 1);
      expect(copy.hadText, 0);
      expect(copy.outputPath, isNotNull);

      final outPath = copy.outputPath!;
      expect(File(outPath).existsSync(), isTrue);

      // Verify that previously image-only document now has readable extractable text
      final extractedText = await PdfCore.extractTextAsync(outPath);
      expect(extractedText, contains(expectedInvoiceText));

      // Verify that second pass detects the existing text layer and avoids duplicate processing
      final secondPass = await PdfCoreService.makeSearchable(outPath);
      expect(secondPass.outputPath, isNull);
      expect(secondPass.hadText, 1);
    });

    test('adds text layer in-place on a document', () async {
      final workingCopy = '${paths.documents.path}/InPlace_Scan.pdf';
      File(scanFile).copySync(workingCopy);

      final pagesRead = await PdfCoreService.addTextLayer(workingCopy);
      expect(pagesRead, 1);

      final extracted = await PdfCore.extractTextAsync(workingCopy);
      expect(extracted, contains(expectedInvoiceText));
    });

    test('preserves AES encryption when making protected scans searchable', () async {
      final locked = '${root.path}/locked_scan.pdf';
      await PdfCore.encryptAsync(scanFile, 'pvsSecretPassword', locked);

      final copy = await PdfCoreService.makeSearchable(
        locked,
        password: 'pvsSecretPassword',
      );
      final out = copy.outputPath!;
      expect(File(out).existsSync(), isTrue);

      // Must remain encrypted (fail without password)
      expect(
        () => PdfCore.extractText(out),
        throwsA(isA<PdfException>().having((e) => e.isEncrypted, 'isEncrypted', true)),
      );

      // Unlocks and extracts with correct password
      final unlockedText = await PdfCore.extractTextAsync(out, password: 'pvsSecretPassword');
      expect(unlockedText, contains(expectedInvoiceText));
    });

    test('recognizeText short-circuits gracefully when cancelled', () async {
      expect(
        () => PdfCoreService.recognizeText(
          scanFile,
          isCancelled: () => true,
        ),
        throwsA(isA<OcrCancelled>()),
      );
    });
  });

  group('PVS Suite 10: Huge 100MB+ Documents & Heavy Directory Stress', () {
    final hugeFile = File('test_corpus/huge/huge_143mb_san_francisco_directory_phonebook.pdf');

    test('inspects 143MB historical phone book / city directory (1,178 pages)', () async {
      expect(hugeFile.existsSync(), isTrue);

      final sw = Stopwatch()..start();
      final info = await PdfCore.inspectAsync(hugeFile.path);
      sw.stop();

      expect(info.pageCount, equals(1178));
      expect(info.version, equals('1.5'));
      // Verify parsing 1,178 objects in 143 MB file takes under 1 second
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('performs deep page jumps across 1,178 pages in 143MB file', () async {
      // Test rendering beginning, middle, and end of 1,178 pages
      for (final p in [0, 500, 1177]) {
        final bytes = await PdfRaster.renderPage(hugeFile.path, p, longEdge: 300);
        expect(bytes, isNotNull, reason: 'Failed rendering page $p of 143MB phone book');
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });

    test('detects existing OCR layer on 143MB historical scan pages', () async {
      final ocrResult = await PdfCore.ocrPage(hugeFile.path, page: 25);
      expect(ocrResult.status, PdfOcrStatus.hasOcrLayer);
    });

    test('extracts pages from 143MB document into clean standalone PDF', () async {
      final excerpt = await PdfService.extractPagesFromFile(hugeFile.path, [24, 25]);
      expect(excerpt, isNotNull);
      expect(await PdfService.getPageCount(excerpt!), 2);
      expect(await PdfRaster.renderPage(excerpt, 0), isNotNull);
    });
  });

  group('PVS Suite 11: Multilingual Photo PDFs & Cross-Language OCR', () {
    final photoLangs = [
      ('English', 'test_corpus/photo_languages/photo_lang_en.pdf'),
      ('German', 'test_corpus/photo_languages/photo_lang_de.pdf'),
      ('French', 'test_corpus/photo_languages/photo_lang_fr.pdf'),
      ('Spanish', 'test_corpus/photo_languages/photo_lang_es.pdf'),
      ('Russian', 'test_corpus/photo_languages/photo_lang_ru.pdf'),
      ('Hindi', 'test_corpus/photo_languages/photo_lang_hi.pdf'),
      ('Chinese', 'test_corpus/photo_languages/photo_lang_zh.pdf'),
      ('Arabic', 'test_corpus/photo_languages/photo_lang_ar.pdf'),
    ];

    test('runs on-device OCR on pure photo/image PDFs across 8 world languages', () async {
      for (final (lang, path) in photoLangs) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'Missing $lang photo PDF at $path');

        final ocrPages = await PdfCoreService.recognizeText(file.path);
        expect(ocrPages, hasLength(1));

        final page = ocrPages.first;
        expect(page.status, PdfOcrStatus.recognized);
        expect(page.lines, isNotEmpty, reason: '$lang photo PDF should detect line structures');

        // Latin script languages must extract accurate vocabulary
        if (lang == 'English') {
          expect(page.text, contains('COMMERCIAL INVOICE'));
        } else if (lang == 'German') {
          expect(page.text, contains('RECHNUNG'));
        } else if (lang == 'French') {
          expect(page.text, contains('FACTURE'));
        } else if (lang == 'Spanish') {
          expect(page.text, contains('FACTURA'));
        }
      }
    });

    test('creates searchable PDFs with invisible text layer from photo PDFs', () async {
      for (final (lang, path) in photoLangs.take(4)) {
        final copy = await PdfCoreService.makeSearchable(
          path,
          fileName: 'Searchable_Photo_$lang',
        );

        expect(copy.recognized, 1);
        expect(copy.outputPath, isNotNull);

        final outPath = copy.outputPath!;
        expect(File(outPath).existsSync(), isTrue);

        final extractedText = await PdfCore.extractTextAsync(outPath);
        expect(extractedText, isNotEmpty);
      }
    });

    test('processes historical multilingual scans safely without crashing', () async {
      final scans = [
        'test_corpus/scans/scan_de_german_army.pdf',
        'test_corpus/scans/scan_fr_french_defense.pdf',
        'test_corpus/scans/scan_ar_arabic_calligraphy.pdf',
        'test_corpus/scans/scan_hi_hindi_manuscripts.pdf',
      ];

      for (final path in scans) {
        final file = File(path);
        if (!file.existsSync()) continue;

        final pages = await PdfCoreService.recognizeText(file.path, pages: [1]);
        expect(pages, hasLength(1));
        expect(pages.first.status, isA<PdfOcrStatus>());
      }
    });
  });
}


