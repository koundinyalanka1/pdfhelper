import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:pdfhelper/services/pdf_raster.dart';
import 'package:pdfhelper/services/pdf_service.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['PDF_CORE_LIB_PATH'];
  if (library == null || !File(library).existsSync()) {
    test('native workflows need PDF_CORE_LIB_PATH', () {}, skip: true);
    return;
  }
  late Directory root;
  late FakePathProvider paths;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_workflow');
    paths = FakePathProvider.install(root);
    PdfRaster.invalidate();
  });
  tearDown(() async {
    PdfRaster.invalidate();
    FakePathProvider.restore();
    await root.delete(recursive: true);
  });

  const simple = 'packages/flutter_pdf_core/rust/fixtures/simple.pdf';
  const twoPages = 'packages/flutter_pdf_core/rust/fixtures/two_pages.pdf';

  test(
    'merge, extract in requested order, and split use the real engine',
    () async {
      final merged = await PdfService.mergeFiles([simple, twoPages]);
      expect(merged, isNotNull);
      expect(await PdfService.getPageCount(merged!), 3);
      final extracted = await PdfService.extractPagesFromFile(merged, [
        2,
        0,
        2,
      ]);
      expect(extracted, isNotNull);
      expect(await PdfService.getPageCount(extracted!), 3);
      for (final (index, sourceIndex) in [(0, 2), (1, 0), (2, 2)]) {
        expect(
          await PdfCore.extractTextAsync(extracted, page: index + 1),
          await PdfCore.extractTextAsync(merged, page: sourceIndex + 1),
        );
      }
      final split = await PdfCoreService.splitAllPages(extracted);
      expect(split, hasLength(3));
      for (final output in split) {
        expect(await PdfService.getPageCount(output), 1);
      }
    },
  );

  test('failed multi-range split removes its partial outputs', () async {
    final outputs = await PdfService.splitRangesFromFile(twoPages, [
      (start: 1, end: 1),
      (start: 100, end: 101),
    ]);
    expect(outputs, isEmpty);
    expect(paths.documents.listSync(), isEmpty);
  });

  test(
    'encrypted rendering does not reuse a different password cache',
    () async {
      final encrypted = '${root.path}/protected.pdf';
      await PdfCore.encryptAsync(simple, 'correct', encrypted);
      final unlocked = await PdfRaster.renderPage(
        encrypted,
        0,
        password: 'correct',
      );
      expect(unlocked, isNotNull);
      expect(
        await PdfRaster.renderPage(encrypted, 0, password: 'wrong'),
        isNull,
      );
      expect(await PdfRaster.renderPage(encrypted, 0), isNull);
      final decrypted = await PdfCoreService.unlock(encrypted, 'correct');
      expect(await PdfService.getPageCount(decrypted), 1);
    },
  );

  test(
    'merge unlocks protected inputs and leaves no unlocked copies behind',
    () async {
      final encrypted = '${root.path}/protected.pdf';
      await PdfCore.encryptAsync(simple, 'correct', encrypted);
      for (final passwords in [
        null,
        ['wrong', ''],
      ]) {
        expect(
          await PdfService.mergeFiles([
            encrypted,
            twoPages,
          ], passwords: passwords),
          isNull,
        );
      }
      expect(paths.documents.listSync(), isEmpty);
      final merged = await PdfService.mergeFiles(
        [encrypted, twoPages],
        passwords: ['correct', ''],
      );
      expect(merged, isNotNull);
      expect(await PdfService.getPageCount(merged!), 3);
      expect(await PdfCoreService.isEncrypted(merged), isFalse);
      expect(paths.temporary.listSync(), isEmpty);
    },
  );

  test(
    'invalid image batches fail without dropping pages or leaving files',
    () async {
      final image = File('${root.path}/valid.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 10, height: 20)));
      final corrupt = File('${root.path}/corrupt.png')
        ..writeAsStringSync('bad image');
      for (final bad in [corrupt.path, '${root.path}/missing.png']) {
        expect(
          await PdfService.imagesToPdf([
            image.path,
            bad,
          ], outputQuality: 'High'),
          isNull,
        );
        expect(paths.documents.listSync(), isEmpty);
        expect(paths.temporary.listSync(), isEmpty);
      }
    },
  );

  test(
    'image conversion preserves all pages and corrects EXIF orientation',
    () async {
      final photo = img.Image(width: 30, height: 10);
      photo.exif.imageIfd.orientation = 6;
      final input = File('${root.path}/rotated.jpg')
        ..writeAsBytesSync(img.encodeJpg(photo));
      final output = await PdfService.imagesToPdf([
        input.path,
        input.path,
      ], outputQuality: 'Maximum');
      expect(output, isNotNull);
      expect(await PdfService.getPageCount(output!), 2);
      final size = await PdfCore.pageSizeAsync(output, 0);
      expect(size.height, greaterThan(size.width));
      expect(paths.temporary.listSync(), isEmpty);
    },
  );
}
