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

import 'support/pdf_fidelity_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('packaged PDF engine completes document workflows on device', (
    tester,
  ) async {
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
        await PdfCore.rotatePagesAsync(extracted, 90, rotated, pages: '1');
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
          (await PdfCore.inspectAsync(protected, password: password)).encrypted,
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
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'packaged native repairs preserve dashed strokes, layers and sparse PDFs',
    (tester) async {
      await tester.runAsync(() async {
        final cache = await getTemporaryDirectory();
        final root = await cache.createTemp('pdfhelper_fidelity_smoke_');
        try {
          final fixtures = writePdfFidelityFixtures(root);
          String output(String name) => '${root.path}/$name';

          // Old packaged engines drew one solid line. Counting ink and checking
          // an interior gap also rejects a render which drops the line entirely.
          final dashed = await _renderFaithfully(fixtures.dashed.path);
          expect(_countPixels(dashed, _isBlack), closeTo(200, 8));
          expect(_isBlack(dashed.getPixel(15, 40)), isTrue);
          expect(_isWhite(dashed.getPixel(25, 40)), isTrue);

          Future<void> expectHiddenLayer(String path, {int page = 0}) async {
            final rendered = await _renderFaithfully(path, page: page);
            expect(
              _countPixels(rendered, _isRed),
              0,
              reason: 'The default OFF layer must stay hidden in $path',
            );
            expect(
              _countPixels(rendered, _isBlue),
              closeTo(100, 4),
              reason: 'Ordinary content must survive beside the hidden layer',
            );
          }

          await expectHiddenLayer(fixtures.layered.path);
          final extracted = output('layer-extracted.pdf');
          await PdfCore.extractPagesAsync(
            fixtures.layered.path,
            '1',
            extracted,
          );
          final merged = output('layers-merged.pdf');
          await PdfCore.mergeAsync([fixtures.layered.path, extracted], merged);
          expect(await PdfCore.pageCountAsync(merged), 2);
          for (final path in [extracted, merged]) {
            // The catalog configuration must survive serialization, so another
            // PDF reader can also keep the layer hidden.
            final bytes = await File(path).readAsBytes();
            expect(String.fromCharCodes(bytes), contains('/OCProperties'));
            expect(String.fromCharCodes(bytes), contains('/OFF'));
            await expectHiddenLayer(path);
          }
          await expectHiddenLayer(merged, page: 1);

          // The original bug inflated this tiny file to approximately 20 MB.
          // Test the packaged writer, not just the source-level unit tests.
          expect(await fixtures.sparse.length(), lessThan(1024));
          final rotated = output('sparse-rotated.pdf');
          await PdfCore.rotatePagesAsync(fixtures.sparse.path, 90, rotated);
          expect(await File(rotated).length(), lessThan(2048));
          expect(await PdfCore.pageCountAsync(rotated), 1);
          final page = await _renderFaithfully(rotated);
          expect(page.width, 80);
          expect(page.height, 120);
          expect(_countPixels(page, _isBlue), closeTo(900, 8));
        } finally {
          await root.delete(recursive: true);
        }
        expect(await root.exists(), isFalse);
      });
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  testWidgets(
    'packaged renderer fixes indirect widths and paints advanced graphics',
    (tester) async {
      await tester.runAsync(() async {
        final root = await (await getTemporaryDirectory()).createTemp(
          'pdfhelper_renderer_',
        );
        try {
          final fixtures = writeRendererCompletionFixtures(root);
          final direct = await PdfCore.renderPagePngWithWarningsAsync(
            fixtures['fontDirect']!.path,
            0,
            width: 120,
            height: 80,
          );
          final indirect = await PdfCore.renderPagePngWithWarningsAsync(
            fixtures['fontIndirect']!.path,
            0,
            width: 120,
            height: 80,
          );
          expect(indirect.bytes, orderedEquals(direct.bytes));
          expect(indirect.warnings, orderedEquals(direct.warnings));
          expect(
            _countPixels(img.decodePng(indirect.bytes)!, _isBlack),
            greaterThan(30),
          );
          final group = await _renderFaithfully(fixtures['group']!.path);
          expect(group.getPixel(20, 40).r, 255);
          expect(group.getPixel(20, 40).g, closeTo(128, 2));
          expect(group.getPixel(60, 40).r, closeTo(128, 2));
          expect(group.getPixel(60, 40).g, closeTo(128, 2));
          expect(group.getPixel(60, 40).b, 255);
          final mask = await _renderFaithfully(fixtures['softMask']!.path);
          expect(mask.getPixel(20, 40).r, closeTo(128, 2));
          expect(_isBlack(mask.getPixel(90, 40)), isTrue);
          final shading = await _renderFaithfully(fixtures['function']!.path);
          expect(shading.getPixel(10, 40).b, greaterThan(225));
          expect(shading.getPixel(110, 40).r, greaterThan(225));
        } finally {
          await root.delete(recursive: true);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Future<img.Image> _renderFaithfully(String path, {int page = 0}) async {
  final rendered = await PdfCore.renderPagePngWithWarningsAsync(
    path,
    page,
    width: 120,
    height: 120,
  );
  expect(rendered.warnings, isEmpty, reason: 'Valid supported fixture: $path');
  final image = img.decodePng(rendered.bytes);
  expect(image, isNotNull);
  return image!;
}

int _countPixels(img.Image image, bool Function(img.Pixel) matches) =>
    image.where(matches).length;

bool _isBlack(img.Pixel pixel) => pixel.r < 10 && pixel.g < 10 && pixel.b < 10;
bool _isWhite(img.Pixel pixel) =>
    pixel.r > 240 && pixel.g > 240 && pixel.b > 240;
bool _isRed(img.Pixel pixel) => pixel.r > 240 && pixel.g < 10 && pixel.b < 10;
bool _isBlue(img.Pixel pixel) => pixel.r < 10 && pixel.g < 10 && pixel.b > 240;

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
