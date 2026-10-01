// Run on an attached Android device with:
// flutter test integration_test/pdf_workflows_test.dart -d <device-id>
//
// Exercises the actual packaged native engine. All fixtures and outputs live
// in one unique cache directory; the app's document library is never touched.
import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'packaged PDF engine completes document workflows on device',
    (tester) async {
      await tester.runAsync(() async {
        expect(PdfCore.nativeVersion, isNotEmpty);

        final cache = await getTemporaryDirectory();
        final root = await cache.createTemp('pdfhelper_native_smoke_');
        try {
          String output(String name) => '${root.path}/$name';

          final red = await _writeJpeg(
            output('red.jpg'),
            width: 24,
            height: 40,
            color: img.ColorRgb8(230, 20, 20),
          );
          final green = await _writeJpeg(
            output('green.jpg'),
            width: 40,
            height: 24,
            color: img.ColorRgb8(20, 230, 20),
          );
          final blue = await _writeJpeg(
            output('blue.jpg'),
            width: 32,
            height: 32,
            color: img.ColorRgb8(20, 20, 230),
          );

          final first = output('first.pdf');
          final second = output('second.pdf');
          await PdfCore.imagesToPdfAsync(
            [red, green],
            first,
            pageSizePoints: const PdfPageSize(72, 72),
          );
          await PdfCore.imagesToPdfAsync(
            [blue],
            second,
            pageSizePoints: const PdfPageSize(72, 72),
          );
          expect(await PdfCore.pageCountAsync(first), 2);
          expect(await PdfCore.pageCountAsync(second), 1);
          await _expectPageColor(first, 0, _PageColor.red);
          await _expectPageColor(first, 1, _PageColor.green);

          // Distinct colors detect page loss, accidental sorting and incorrect
          // resource remapping when separate PDFs are merged.
          final merged = output('merged.pdf');
          await PdfCore.mergeAsync([second, first], merged);
          expect(await PdfCore.pageCountAsync(merged), 3);
          for (final (page, color) in [
            (0, _PageColor.blue),
            (1, _PageColor.red),
            (2, _PageColor.green),
          ]) {
            await _expectPageColor(merged, page, color);
          }

          // Selections are 1-based and must preserve order and duplicates.
          final extracted = output('extracted.pdf');
          await PdfCore.extractPagesAsync(merged, '3,1,3', extracted);
          expect(await PdfCore.pageCountAsync(extracted), 3);
          for (final (page, color) in [
            (0, _PageColor.green),
            (1, _PageColor.blue),
            (2, _PageColor.green),
          ]) {
            await _expectPageColor(extracted, page, color);
          }

          final rotated = output('rotated.pdf');
          final originalSize = await PdfCore.pageSizeAsync(extracted, 0);
          expect(originalSize.width, greaterThan(originalSize.height));
          await PdfCore.rotatePagesAsync(
            extracted,
            90,
            rotated,
            pages: '1',
          );
          expect(await PdfCore.pageCountAsync(rotated), 3);
          final rotatedSize = await PdfCore.pageSizeAsync(rotated, 0);
          expect(rotatedSize.width, closeTo(originalSize.height, 0.01));
          expect(rotatedSize.height, closeTo(originalSize.width, 0.01));
          final untouchedSize = await PdfCore.pageSizeAsync(rotated, 2);
          expect(untouchedSize.width, closeTo(originalSize.width, 0.01));
          expect(untouchedSize.height, closeTo(originalSize.height, 0.01));
          await _expectPageColor(rotated, 0, _PageColor.green);

          const password = 'Device smoke test 123!';
          final protected = output('protected.pdf');
          await PdfCore.encryptAsync(rotated, password, protected);
          expect(
            (await PdfCore.inspectAsync(protected, password: password))
                .encrypted,
            isTrue,
          );
          await expectLater(
            PdfCore.pageCountAsync(protected),
            throwsA(
              isA<PdfException>().having(
                (error) => error.isEncrypted,
                'encrypted',
                isTrue,
              ),
            ),
          );
          await expectLater(
            PdfCore.pageCountAsync(protected, password: 'wrong'),
            throwsA(
              isA<PdfException>().having(
                (error) => error.isWrongPassword,
                'wrong password',
                isTrue,
              ),
            ),
          );
          await _expectPageColor(
            protected,
            0,
            _PageColor.green,
            password: password,
          );
          await expectLater(
            PdfCore.renderPagePngAsync(
              protected,
              0,
              width: 96,
              height: 96,
              password: 'wrong',
            ),
            throwsA(isA<PdfException>()),
          );

          final rejected = output('wrong_password.pdf');
          await expectLater(
            PdfCore.decryptAsync(protected, 'wrong', rejected),
            throwsA(isA<PdfException>()),
          );
          expect(await File(rejected).exists(), isFalse);

          final decrypted = output('decrypted.pdf');
          await PdfCore.decryptAsync(protected, password, decrypted);
          final info = await PdfCore.inspectAsync(decrypted);
          expect(info.encrypted, isFalse);
          expect(info.pageCount, 3);
          await _expectPageColor(decrypted, 0, _PageColor.green);
          await _expectPageColor(decrypted, 1, _PageColor.blue);
          await _expectPageColor(decrypted, 2, _PageColor.green);

          // PNG output must be decodable and honor the rotated page ratio.
          final png = await PdfCore.renderPagePngAsync(
            decrypted,
            0,
            width: 96,
            height: 96,
          );
          expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final decoded = img.decodePng(png);
          expect(decoded, isNotNull);
          expect(decoded!.width, inInclusiveRange(1, 96));
          expect(decoded.height, inInclusiveRange(1, 96));
          expect(decoded.height, greaterThan(decoded.width));
          await File(output('preview.png')).writeAsBytes(png, flush: true);
        } finally {
          await root.delete(recursive: true);
        }
        expect(await root.exists(), isFalse);
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<String> _writeJpeg(
  String path, {
  required int width,
  required int height,
  required img.Color color,
}) async {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: color);
  await File(path).writeAsBytes(img.encodeJpg(image, quality: 95), flush: true);
  return path;
}

enum _PageColor { red, green, blue }

Future<void> _expectPageColor(
  String path,
  int page,
  _PageColor expected, {
  String password = '',
}) async {
  final png = await PdfCore.renderPagePngAsync(
    path,
    page,
    width: 96,
    height: 96,
    password: password,
  );
  final image = img.decodePng(png);
  expect(image, isNotNull, reason: 'Page ${page + 1} must render as PNG');
  final pixel = image!.getPixel(image.width ~/ 2, image.height ~/ 2);
  final channels = [pixel.r, pixel.g, pixel.b];
  expect(
    channels[expected.index],
    greaterThan(180),
    reason: 'Page ${page + 1} must retain its $expected image',
  );
  for (var channel = 0; channel < channels.length; channel++) {
    if (channel != expected.index) {
      expect(channels[channel], lessThan(80));
    }
  }
}
