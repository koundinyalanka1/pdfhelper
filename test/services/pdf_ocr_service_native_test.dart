import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:pdfhelper/services/pdf_raster.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// Text recognition through the real engine:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/services/pdf_ocr_service_native_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (library == null || !File(library).existsSync()) {
    test('OCR needs PDF_CORE_LIB_PATH', () {}, skip: true);
    return;
  }

  const scan = 'packages/flutter_pdf_core/rust/fixtures/scanned.pdf';
  const scanText = 'Scanned invoice no. 2024-117';

  late Directory root;
  late FakePathProvider paths;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_ocr_service');
    paths = FakePathProvider.install(root);
    PdfRaster.invalidate();
  });
  tearDown(() async {
    PdfRaster.invalidate();
    FakePathProvider.restore();
    await root.delete(recursive: true);
  });

  test('reads a scan page by page and releases the document', () async {
    final progress = <(int, int)>[];
    final pages = await PdfCoreService.recognizeText(
      scan,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(pages, hasLength(1));
    expect(pages.single.status, PdfOcrStatus.recognized);
    expect(pages.single.text, contains(scanText));
    expect(progress, [(0, 1), (1, 1)]);
    expect(PdfRaster.openDocumentCount(scan), 0);
  });

  test('saves a searchable copy, and only once', () async {
    final copy = await PdfCoreService.makeSearchable(
      scan,
      fileName: 'Invoice (searchable)',
    );
    expect(copy.recognized, 1);
    expect(copy.hadText, 0);
    expect(copy.blank, 0);
    final out = copy.outputPath!;
    expect(out, '${paths.documents.path}/Invoice (searchable).pdf');
    expect(await PdfCore.extractTextAsync(out), contains(scanText));

    // Its text is now there, so a second pass has nothing to add.
    final again = await PdfCoreService.makeSearchable(out);
    expect(again.outputPath, isNull);
    expect(again.hadText, 1);
    expect(paths.documents.listSync(), hasLength(1));
  });

  test('a protected scan stays protected', () async {
    final locked = '${root.path}/locked.pdf';
    await PdfCore.encryptAsync(scan, 'secret', locked);
    final copy = await PdfCoreService.makeSearchable(
      locked,
      password: 'secret',
    );
    final out = copy.outputPath!;
    expect(
      () => PdfCore.extractText(out),
      throwsA(isA<PdfException>().having((e) => e.isEncrypted, 'locked', true)),
    );
    expect(
      await PdfCore.extractTextAsync(out, password: 'secret'),
      contains(scanText),
    );
    // Nothing unlocked is left behind in temporary storage.
    expect(
      paths.temporary.listSync(recursive: true).whereType<File>(),
      isEmpty,
    );
  });

  test('a new scan gains its text layer in place', () async {
    final made = '${paths.documents.path}/Scan.pdf';
    File(scan).copySync(made);
    final read = await PdfCoreService.addTextLayer(made);
    expect(read, 1);
    expect(await PdfCore.extractTextAsync(made), contains(scanText));
    expect(paths.documents.listSync().map((e) => e.path), [made]);
  });

  test('a cancelled run writes nothing', () async {
    await expectLater(
      PdfCoreService.makeSearchable(scan, isCancelled: () => true),
      throwsA(isA<OcrCancelled>().having((e) => e.pages, 'pages', isEmpty)),
    );
    expect(paths.documents.listSync(), isEmpty);
    expect(PdfRaster.openDocumentCount(scan), 0);

    final made = '${paths.documents.path}/Scan.pdf';
    File(scan).copySync(made);
    final before = File(made).readAsBytesSync();
    await expectLater(
      PdfCoreService.addTextLayer(made, isCancelled: () => true),
      throwsA(isA<OcrCancelled>()),
    );
    expect(File(made).readAsBytesSync(), before);
  });

  test('a born-digital document is left alone', () async {
    final pdf = writeTextPdfFixture(root, [
      'The quick brown fox jumps over the lazy dog, twice: '
          'the quick brown fox jumps over the lazy dog.',
      // A cover page's few words: reading them again would double them.
      'Chapter One',
    ]);
    final copy = await PdfCoreService.makeSearchable(pdf.path);
    expect(copy.outputPath, isNull);
    expect(copy.hadText, 2);
  });
}
