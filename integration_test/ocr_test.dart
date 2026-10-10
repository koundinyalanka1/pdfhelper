// Run on an attached Android device with:
// flutter test integration_test/ocr_test.dart -d <device-id>
//
// A typed page is photographed (rendered at camera resolution and saved as a
// JPEG), made into a PDF the way Scan makes one, and then made searchable by
// the packaged OCR engine. The time it takes is printed: it is what a person
// waits for after every scan.
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';

const _lines = [
  'Invoice 2026-0412',
  'Thank you for shopping with us.',
  'The quick brown fox jumps over the lazy dog.',
  'Total due by the end of October: 1,234.56',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a photographed page becomes searchable on device', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await (await getTemporaryDirectory()).createTemp(
        'pdfhelper_ocr_',
      );
      try {
        final typed = '${root.path}/typed.pdf';
        await File(typed).writeAsString(_typedPage(_lines), flush: true);
        // About 8 MP, a phone camera's photo of a letter-size page.
        final page = await PdfCore.renderPageRgbaAsync(
          typed,
          0,
          width: 2550,
          height: 3300,
        );
        final photo = '${root.path}/photo.jpg';
        final jpeg = await Isolate.run(
          () => img.encodeJpg(
            img.Image.fromBytes(
              width: page.width,
              height: page.height,
              bytes: page.pixels.buffer,
              numChannels: 4,
            ),
            quality: 90,
          ),
        );
        await File(photo).writeAsBytes(jpeg, flush: true);

        const pages = 3;
        final scan = '${root.path}/scan.pdf';
        await PdfCore.imagesToPdfAsync(
          List.filled(pages, photo),
          scan,
          fit: PdfImageFit.imageAspect,
        );
        expect((await PdfCore.extractTextAsync(scan)).trim(), isEmpty);

        final timer = Stopwatch()..start();
        final read = await PdfCoreService.addTextLayer(scan);
        timer.stop();
        debugPrint(
          'OCR on device: $pages pages in ${timer.elapsedMilliseconds} ms '
          '(${timer.elapsedMilliseconds ~/ pages} ms a page)',
        );

        expect(read, pages);
        final text = await PdfCore.extractTextAsync(scan, page: pages);
        for (final word in ['Invoice', 'shopping', 'quick', 'lazy', 'Total']) {
          expect(text, contains(word));
        }
      } finally {
        await root.delete(recursive: true);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// A letter-size page with [lines] set in 14-point Helvetica.
String _typedPage(List<String> lines) {
  final text = StringBuffer('BT /F1 14 Tf 22 TL 72 700 Td\n');
  for (final line in lines) {
    text.write(
      '(${line.replaceAll('(', r'\(').replaceAll(')', r'\)')}) Tj T*\n',
    );
  }
  text.write('ET');
  final content = text.toString();
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
        '/Encoding /WinAnsiEncoding >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final out = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return out.toString();
}
