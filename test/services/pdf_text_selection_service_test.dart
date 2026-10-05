import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_text_selection_service.dart';

import '../support/text_pdf_fixture.dart';

void main() {
  test(
    'negative viewer page indexes fail before native library lookup',
    () async {
      await expectLater(
        PdfTextSelectionService.load('/unused.pdf', -1),
        throwsRangeError,
      );
    },
  );

  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (library == null || !File(library).existsSync()) return;
  late Directory root;
  late String fixture;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_text_selection');
    fixture = writeTextPdfFixture(root, ['Hello world', 'Second page']).path;
  });
  tearDown(() => root.deleteSync(recursive: true));
  final supportsSelection = DynamicLibrary.open(
    library,
  ).providesSymbol('pdf_page_text_layout_json');

  if (!supportsSelection) {
    test(
      'an older engine keeps reading PDFs and reports selection unavailable',
      () async {
        expect(await PdfCore.pageCountAsync(fixture), 2);
        await expectLater(
          PdfTextSelectionService.load(fixture, 0),
          throwsA(
            isA<PdfException>().having(
              (error) => error.code,
              'code',
              'TEXT_SELECTION_UNAVAILABLE',
            ),
          ),
        );
        expect(await PdfCore.pageCountAsync(fixture), 2);
      },
    );
    return;
  }

  test(
    'viewer indexes map to the same native page and displayed dimensions',
    () async {
      for (var pageIndex = 0; pageIndex < 2; pageIndex++) {
        final layout = await PdfTextSelectionService.load(fixture, pageIndex);
        final native = await PdfCore.pageTextLayout(
          fixture,
          page: pageIndex + 1,
        );
        final size = await PdfCore.pageSizeAsync(fixture, pageIndex);
        expect(layout.text, pageIndex == 0 ? 'Hello world' : 'Second page');
        expect(layout.text, native.text);
        expect(layout.glyphs.length, native.glyphs.length);
        expect(layout.hasText, true);
        expect(layout.width, closeTo(size.width, 0.01));
        expect(layout.height, closeTo(size.height, 0.01));
      }
      await expectLater(
        PdfTextSelectionService.load(fixture, 2),
        throwsA(isA<PdfException>()),
      );
    },
  );

  test(
    'text extraction passes the password without sharing cached text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pdf_text_selection',
      );
      try {
        final protected = '${directory.path}/protected.pdf';
        await PdfCore.encryptAsync(fixture, 'correct', protected);
        final layout = await PdfTextSelectionService.load(
          protected,
          0,
          password: 'correct',
        );
        expect(layout.hasText, true);
        expect(layout.text, 'Hello world');
        await expectLater(
          PdfTextSelectionService.load(protected, 0, password: 'wrong'),
          throwsA(isA<PdfException>()),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
