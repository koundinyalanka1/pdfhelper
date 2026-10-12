import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/recognized_text_store.dart';

import '../support/fake_path_provider.dart';

/// Text kept in the app is filed under the document's content, so it comes
/// back for any copy of the same file and never for a changed one.
void main() {
  late Directory root;
  late FakePathProvider paths;
  late File pdf;

  const page = PdfOcrPage(
    page: 2,
    status: PdfOcrStatus.recognized,
    text: 'Hello world',
    confidence: 0.9,
    lines: [
      PdfOcrLine(
        text: 'Hello world',
        confidence: 0.9,
        left: 10,
        top: 20,
        right: 120,
        bottom: 40,
        words: [
          PdfOcrWord(
            text: 'Hello',
            confidence: 0.92,
            left: 10,
            top: 20,
            right: 60,
            bottom: 40,
            quad: [10, 20, 60, 20, 60, 40, 10, 40],
          ),
          PdfOcrWord(
            text: 'world',
            confidence: 0.88,
            left: 70,
            top: 20,
            right: 120,
            bottom: 40,
            quad: [70, 20, 120, 20, 120, 40, 70, 40],
          ),
        ],
      ),
    ],
    layout: PdfPageTextLayout(
      text: 'Hello world',
      width: 300,
      height: 400,
      glyphs: [
        PdfTextGlyph(
          start: 0,
          end: 5,
          left: 10.123,
          top: 20,
          right: 60,
          bottom: 40,
        ),
        PdfTextGlyph(
          start: 6,
          end: 11,
          left: 70,
          top: 20,
          right: 120.456,
          bottom: 40,
        ),
      ],
    ),
  );
  const text = RecognizedText(pages: {1: page}, skipped: {0, 2});

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_kept_text');
    paths = FakePathProvider.install(root);
    // Bigger than the sampled start, middle and end together.
    pdf = File('${root.path}/Scan.pdf')
      ..writeAsBytesSync([for (var i = 0; i < 300 * 1024; i++) i * 7 % 251]);
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  test('what was kept comes back as it was', () async {
    await RecognizedTextStore.save(pdf.path, pageCount: 3, text: text);
    final kept = await RecognizedTextStore.load(pdf.path, pageCount: 3);

    expect(kept.skipped, {0, 2});
    expect(kept.pages.keys, [1]);
    final back = kept.pages[1]!;
    expect(back.page, 2);
    expect(back.status, PdfOcrStatus.recognized);
    expect(back.text, 'Hello world');
    expect(back.lines.single.words.map((w) => w.text), ['Hello', 'world']);
    expect(back.toJson(), page.toJson());
    final layout = back.layout!;
    expect(layout.text, 'Hello world');
    expect((layout.width, layout.height), (300, 400));
    expect(layout.glyphs, hasLength(2));
    expect(layout.glyphs.first.left, closeTo(10.12, 1e-9));
    expect(layout.glyphs.last.right, closeTo(120.46, 1e-9));
    expect(kept.hasRead(0) && kept.hasRead(1) && kept.hasRead(2), isTrue);
  });

  test('any copy of the same file finds it', () async {
    await RecognizedTextStore.save(pdf.path, pageCount: 3, text: text);
    final copy = pdf.copySync('${root.path}/Elsewhere.pdf');
    final kept = await RecognizedTextStore.load(copy.path, pageCount: 3);
    expect(kept.pages.keys, [1]);
  });

  test('a changed file does not', () async {
    await RecognizedTextStore.save(pdf.path, pageCount: 3, text: text);
    // Same length, different last byte: where an edited PDF's index goes.
    final bytes = pdf.readAsBytesSync();
    bytes[bytes.length - 1] ^= 0xFF;
    pdf.writeAsBytesSync(bytes);
    expect(
      (await RecognizedTextStore.load(pdf.path, pageCount: 3)).isEmpty,
      isTrue,
    );
  });

  test('a different page count does not', () async {
    await RecognizedTextStore.save(pdf.path, pageCount: 3, text: text);
    expect(
      (await RecognizedTextStore.load(pdf.path, pageCount: 4)).isEmpty,
      isTrue,
    );
  });

  test('nothing kept, or a missing file, reads as nothing', () async {
    expect(
      (await RecognizedTextStore.load(pdf.path, pageCount: 3)).isEmpty,
      isTrue,
    );
    expect(
      (await RecognizedTextStore.load(
        '${root.path}/Missing.pdf',
        pageCount: 3,
      )).isEmpty,
      isTrue,
    );
  });

  test('saving again replaces what was kept', () async {
    await RecognizedTextStore.save(pdf.path, pageCount: 3, text: text);
    await RecognizedTextStore.save(
      pdf.path,
      pageCount: 3,
      text: const RecognizedText(skipped: {0, 1, 2}),
    );
    final kept = await RecognizedTextStore.load(pdf.path, pageCount: 3);
    expect(kept.pages, isEmpty);
    expect(kept.skipped, {0, 1, 2});
    final dir = Directory('${paths.support.path}/recognized_text');
    expect(dir.listSync(), hasLength(1));
  });
}
