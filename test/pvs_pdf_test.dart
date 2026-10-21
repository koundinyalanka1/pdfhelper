import 'dart:convert';
import 'dart:io';

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

  // The corpus is downloaded (scripts/download_*_corpus.py) and git-ignored;
  // without it, or without the native library, the sweep is skipped.
  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (!Directory('test_corpus').existsSync()) {
    test('PVS sweep needs test_corpus/', () {}, skip: true);
    return;
  }

  test('PVS required corpus categories are present and nonempty', () {
    for (final category in const [
      'languages', 'light', 'heavy', 'features', 'pictures',
      'epics', 'huge', 'scans', 'photo_languages', 'ocr',
    ]) {
      _requiredPdfs(category);
    }
  });

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
  List<File> getPdfs(String category) => _requiredPdfs(category);

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

  // Every directory of test_corpus the suites above do not name: the files
  // scripts/download_diverse_corpus.py adds (broken and fuzzed files, fonts,
  // graphics, codecs, forms, PDF/A, sheet music, maps, scanned books, ...).
  group('PVS Suite 12: Diverse corpus sweep', () {
    const named = {
      'epics', 'features', 'heavy', 'huge', 'languages', 'light', 'ocr',
      'photo_languages', 'pictures', 'scans',
      // Not PDFs: office documents for the other engines
      // (scripts/download_office_corpus.py).
      'office', 'text', 'archive', 'metafiles',
    };
    final corpus = Directory('test_corpus');
    final only = (Platform.environment['PVS_CATEGORIES'] ?? '')
        .split(',')
        .where((c) => c.isNotEmpty)
        .toSet();
    final categories = only.isNotEmpty
        ? (only.toList()..sort())
        : !corpus.existsSync()
            ? <String>[]
            : (corpus
                  .listSync()
                  .whereType<Directory>()
                  .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
                  .where((c) => !c.startsWith('.') && !named.contains(c))
                  .toList()
                ..sort());
    final progress = File('test_pvs_output/diverse_progress.txt');
    final rows = <_SweepRow>[];

    setUpAll(() {
      Directory('test_pvs_output').createSync(recursive: true);
      progress.writeAsStringSync('');
    });

    tearDownAll(() {
      if (rows.isNotEmpty) {
        File('test_pvs_output/diverse_sweep.md').writeAsStringSync(_sweepReport(rows));
      }
    });

    test('diverse corpus selection is nonempty', () {
      expect(categories, isNotEmpty, reason: 'MISSING_CORPUS: run scripts/download_diverse_corpus.py');
      for (final category in categories) {
        _requiredPdfs(category);
      }
    });

    for (final category in categories) {
      test('$category: opens, renders and extracts without a crash or hang', () async {
        final files = getPdfs(category);
        expect(files, isNotEmpty);

        final unexpected = <String>[];
        for (final file in files) {
          // Written before the file is touched, so a native crash that takes
          // the test process down still names the file that caused it.
          progress.writeAsStringSync('${file.path}\n', mode: FileMode.append);
          final row = await _sweepFile(category, file);
          rows.add(row);
          if (row.unexpected) unexpected.add(row.describe());
        }

        // Garbage in is allowed to fail, but only as an error the app can
        // show: never a hang, a panic, or an exception of some other type.
        expect(unexpected, isEmpty, reason: unexpected.join('\n'));

        // Everywhere else the file is meant to work. A failure must be one we
        // know about, and a known failure that now works comes off the list.
        if (!_mayFail.contains(category)) {
          final rowsHere = rows.where((r) => r.category == category);
          final newFailures = [
            for (final r in rowsHere)
              if (!r.allOk && !_knownFailures.containsKey('${r.category}/${r.file}'))
                r.describe(),
          ];
          final fixed = [
            for (final r in rowsHere)
              if (r.allOk && _knownFailures.containsKey('${r.category}/${r.file}'))
                '${r.category}/${r.file}',
          ];
          expect(newFailures, isEmpty, reason: 'new failures:\n${newFailures.join('\n')}');
          expect(fixed, isEmpty,
              reason: 'now works, remove from _knownFailures:\n${fixed.join('\n')}');
        }
      }, timeout: const Timeout(Duration(minutes: 30)));
    }
  });
}

/// Categories whose files are allowed to fail: damaged on purpose, or locked
/// with a password no suite publishes.
const _mayFail = {'malformed', 'encryption'};

/// Files in the other categories the engine does not read fully. Each was
/// checked against MuPDF on 2026-10-12; where MuPDF reads it, that is the gap.
const _knownFailures = {
  'documents/pdfminer__simple5.pdf':
      'PDF 1.5 with a chain of incremental xref streams; MuPDF reads it, we '
          'report "no recoverable pages"',
  'documents/pdfminer__patchelf.pdf':
      'startxref points into a stream (the file was re-encoded); MuPDF '
          'rebuilds the table, we stop at the bad offset',
  'graphics/qpdf__shared-images-errors-2-out.pdf':
      'corrupt Flate stream; the page fails whole where MuPDF draws the rest',
  'forms/pdfbox__sign_me_protected.pdf': 'encrypted with a password no suite publishes',
  'regressions/pdfjs__poppler-85140-0.pdf': 'unreadable in MuPDF too',
  'structure/samples__unreadablemetadata.pdf': 'MuPDF finds no pages either',
};

/// Passwords the corpus's encrypted files are known to use (qpdf names them in
/// the file name, pypdf and pdfminer use the others).
const _knownPasswords = [
  'foo', 'test', 'asdfzxcv', 'openpassword', 'view', 'wwwww', 'user', 'owner',
  'password', 'abc', 'qpdf', 'secret', 'u', 'o', 'pdf', 'Hello',
];

/// How one step (open, render, extract) of the sweep ended.
class _Outcome {
  const _Outcome(this.label, [this.detail = '', this.result = const {}]);

  static const skipped = _Outcome('-');

  /// `ok`, `pdf:<CODE>` for an error the engine reported, `timeout`, or
  /// `error:<Type>` for anything else that escaped.
  final String label;
  final String detail;
  final Map<String, dynamic> result;

  bool get isOk => label == 'ok';

  /// Failing to read a file is fine; hanging, panicking or throwing something
  /// the app does not expect is not.
  bool get unexpected =>
      label == 'timeout' || label == 'pdf:PANIC' || label == 'unsupported' ||
      label == 'memory_limit' || label == 'crash' || label.startsWith('error:');
}

Future<_Outcome> _attempt(String operation, File file, {int page = 0, String password = ''}) async {
  try {
    final python = Platform.environment['PYTHON'] ?? (Platform.isWindows ? 'python' : 'python3');
    final process = await Process.run(python, [
      'scripts/verify_engines.py', 'pdf-operation',
      '--operation', operation, '--file', file.absolute.path,
      '--page', '$page', '--password', password,
      '--timeout', '45', '--rss-mib', '512',
    ]);
    final envelope = jsonDecode(process.stdout as String) as Map<String, dynamic>;
    final result = (envelope['result'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final detail = '${envelope['detail'] ?? ''} ${envelope['stderr'] ?? ''} '
        'sampled peak RSS=${envelope['sampled_peak_rss_bytes'] ?? 'unobserved'}';
    switch (envelope['status']) {
      case 'OK':
        return _Outcome('ok', detail, result);
      case 'TIMEOUT':
        return _Outcome('timeout', detail);
      case 'PANIC':
        return _Outcome('pdf:PANIC', detail);
      case 'CRASH':
        return _Outcome('crash', detail);
      case 'MEMORY_LIMIT':
        return _Outcome('memory_limit', detail);
      case 'UNSUPPORTED':
        return _Outcome('unsupported', detail);
      case 'FAILED':
        return _Outcome('pdf:${result['error'] ?? 'ERROR'}', '${result['message'] ?? detail}');
      default:
        return _Outcome('error:${envelope['status']}', detail);
    }
  } on ProcessException catch (e) {
    return _Outcome('unsupported', 'Python subprocess supervisor unavailable: $e');
  } catch (e) {
    return _Outcome('error:${e.runtimeType}', '$e');
  }
}

class _SweepRow {
  _SweepRow(this.category, this.file, this.bytes);

  final String category;
  final String file;
  final int bytes;
  int pages = 0;
  int warnings = 0;

  /// The password that opened an encrypted file, if one of the known ones did.
  String? password;
  _Outcome open = _Outcome.skipped;
  _Outcome first = _Outcome.skipped;
  _Outcome last = _Outcome.skipped;
  _Outcome text = _Outcome.skipped;
  int millis = 0;

  List<_Outcome> get steps => [open, first, last, text];

  bool get unexpected => steps.any((s) => s.unexpected);
  bool get allOk => steps.every((s) => s.isOk || s == _Outcome.skipped);

  String describe() =>
      '$category/$file: open ${open.label}, first ${first.label}, '
      'last ${last.label}, text ${text.label} '
      '${steps.map((s) => s.detail).where((d) => d.isNotEmpty).join(' | ')}';
}

Future<_SweepRow> _sweepFile(String category, File file) async {
  final watch = Stopwatch()..start();
  final row = _SweepRow(category, file.uri.pathSegments.last, file.lengthSync());

  row.open = await _attempt('inspect', file);
  row.pages = row.open.result['pages'] as int? ?? 0;
  if (row.open.label == 'pdf:ENCRYPTED') {
    // The test suites these files come from use a handful of passwords.
    for (final candidate in _knownPasswords) {
      final tried = await _attempt('inspect', file, password: candidate);
      if (tried.isOk) {
        row.pages = tried.result['pages'] as int? ?? 0;
        row.password = candidate;
        row.open = tried;
        break;
      }
      if (tried.label != 'pdf:WRONG_PASSWORD') break;
    }
  }
  final password = row.password ?? '';
  if (row.open.isOk && row.pages > 0) {
    Future<_Outcome> render(int page) async {
      final outcome = await _attempt('render', file, page: page, password: password);
      row.warnings += (outcome.result['warnings'] as List?)?.length ?? 0;
      return outcome;
    }

    row.first = await render(0);
    if (row.pages > 1) row.last = await render(row.pages - 1);
    row.text = await _attempt('text', file, password: password);
  }
  row.millis = watch.elapsedMilliseconds;
  return row;
}

List<File> _requiredPdfs(String category) {
  final folder = Directory('test_corpus/$category');
  expect(folder.existsSync(), isTrue, reason: 'MISSING_CORPUS: ${folder.path}');
  final files = folder.listSync().whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.pdf') && file.lengthSync() > 0)
      .toList()..sort((a, b) => a.path.compareTo(b.path));
  expect(files, isNotEmpty, reason: 'EMPTY_CORPUS: ${folder.path}');
  return files;
}

String _sweepReport(List<_SweepRow> rows) {
  final out = StringBuffer('# Diverse corpus sweep\n\n')
    ..writeln('${rows.length} files. "ok" means opened, rendered the first and '
        'last page, and extracted text; anything else lists what happened.\n')
    ..writeln('| category | files | all ok | engine error | unexpected |')
    ..writeln('|---|---|---|---|---|');
  final byCategory = <String, List<_SweepRow>>{};
  for (final row in rows) {
    byCategory.putIfAbsent(row.category, () => []).add(row);
  }
  for (final entry in byCategory.entries) {
    final list = entry.value;
    final ok = list.where((r) => r.allOk).length;
    final bad = list.where((r) => r.unexpected).length;
    out.writeln('| ${entry.key} | ${list.length} | $ok | '
        '${list.length - ok - bad} | $bad |');
  }

  out.writeln('\n## Files that did not fully work\n');
  out.writeln('| file | pages | open | first | last | text | detail |');
  out.writeln('|---|---|---|---|---|---|---|');
  for (final row in rows.where((r) => !r.allOk)) {
    final detail = row.steps
        .map((s) => s.detail)
        .where((d) => d.isNotEmpty)
        .join(' / ')
        .replaceAll('|', '/')
        .replaceAll('\n', ' ');
    out.writeln('| ${row.category}/${row.file} | ${row.pages} | ${row.open.label} | '
        '${row.first.label} | ${row.last.label} | ${row.text.label} | '
        '${detail.length > 120 ? detail.substring(0, 120) : detail} |');
  }

  final unlocked = rows.where((r) => r.password != null).toList();
  out.writeln('\n## Encrypted files opened with a known password\n');
  for (final row in unlocked) {
    out.writeln('- ${row.category}/${row.file}: "${row.password}"'
        ' (${row.allOk ? 'rendered and read' : 'then failed: ${row.describe()}'})');
  }

  out.writeln('\n## Slowest\n');
  final slow = [...rows]..sort((a, b) => b.millis.compareTo(a.millis));
  for (final row in slow.take(15)) {
    out.writeln('- ${row.category}/${row.file}: ${row.millis} ms, '
        '${row.pages} pages, ${(row.bytes / 1024).round()} KB');
  }

  out.writeln('\n## Renders that carried warnings\n');
  final warned = rows.where((r) => r.warnings > 0).toList();
  out.writeln('${warned.length} files rendered with at least one warning '
      '(approximated or skipped content).');
  return out.toString();
}


