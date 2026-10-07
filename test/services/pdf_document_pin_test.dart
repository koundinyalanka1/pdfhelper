import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_raster.dart';
import 'package:pdfhelper/services/pdf_text_selection_service.dart';

import '../support/text_pdf_fixture.dart';

/// A viewer pins its document so that renders, page sizes and text share one
/// parse. Before, each of them parsed the whole file again, and a large scan
/// used enough memory for Android to kill the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (library == null || !File(library).existsSync()) return;
  if (!DynamicLibrary.open(library).providesSymbol('pdf_document_open')) {
    return;
  }

  late Directory root;
  setUp(() {
    PdfRaster.invalidate();
    root = Directory.systemTemp.createTempSync('pdf_document_pin');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a pinned document serves every read and is released', () async {
    final pdf = writeTextPdfFixture(root, ['First page', 'Second page']).path;

    expect(await PdfRaster.openDocument(pdf), 2);
    expect(PdfRaster.openDocumentCount(pdf), 1);

    final rendered = await PdfRaster.renderPage(pdf, 1, useCache: false);
    expect(rendered, isNotEmpty);
    expect(await PdfRaster.aspectRatios(pdf, 0, 2), [0.75, 0.75]);
    final layout = await PdfTextSelectionService.load(pdf, 0);
    expect(layout.text, contains('First page'));

    await PdfRaster.closeDocument(pdf);
    expect(PdfRaster.openDocumentCount(pdf), 0);
    // Reads keep working once the document is no longer pinned.
    expect(await PdfRaster.pageCountOf(pdf), 2);
  });

  test('a locked document asks for its password and pins nothing', () async {
    final plain = writeTextPdfFixture(root, ['Secret']).path;
    final locked = '${root.path}/Locked.pdf';
    await PdfCore.encryptAsync(plain, 'pass', locked);

    await expectLater(
      PdfRaster.openDocument(locked),
      throwsA(isA<PdfException>().having((e) => e.code, 'code', 'ENCRYPTED')),
    );
    await expectLater(
      PdfRaster.openDocument(locked, password: 'wrong'),
      throwsA(
        isA<PdfException>().having((e) => e.code, 'code', 'WRONG_PASSWORD'),
      ),
    );
    expect(PdfRaster.openDocumentCount(locked), 0);
    expect(PdfRaster.openDocumentCount(locked, password: 'wrong'), 0);

    expect(await PdfRaster.openDocument(locked, password: 'pass'), 1);
    expect(await PdfRaster.pageCountOf(locked, password: 'pass'), 1);
    await PdfRaster.closeDocument(locked, password: 'pass');
    expect(PdfRaster.openDocumentCount(locked, password: 'pass'), 0);
  });

  test('a file rewritten while pinned is read afresh', () async {
    final pdf = writeTextPdfFixture(root, ['One', 'Two']).path;
    expect(await PdfRaster.openDocument(pdf), 2);

    writeTextPdfFixture(root, ['One', 'Two', 'Three']);
    expect(await PdfRaster.pageCountOf(pdf), 3);

    await PdfRaster.closeDocument(pdf);
  });

  test('tool previews pin the document only while they render', () async {
    final pdf = writeTextPdfFixture(root, ['A', 'B', 'C']).path;
    final pages = await PdfRaster.renderAllPages(pdf);
    expect(pages, hasLength(3));
    expect(pages.every((page) => page != null && page.isNotEmpty), isTrue);
    expect(PdfRaster.openDocumentCount(pdf), 0);
  });

  test('a text load for a page that scrolled away is skipped', () async {
    final pdf = writeTextPdfFixture(root, ['Gone']).path;
    await expectLater(
      PdfTextSelectionService.load(pdf, 0, isWanted: () => false),
      throwsA(isA<PdfTextLoadSkipped>()),
    );
    final rendered = await PdfRaster.renderPageWithWarnings(
      pdf,
      0,
      useCache: false,
      isWanted: () => false,
    );
    expect(rendered, isNull);
  });
}
