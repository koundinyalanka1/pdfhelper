import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/utils/photo_import.dart';

/// Gallery photos the scan tools cannot read are converted at import. HEIC
/// itself is decoded on a device by integration_test/photo_import_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// How an HEIF-family file starts: an ISO-BMFF `ftyp` box and its brand.
  Uint8List ftyp(String brand) => Uint8List.fromList([
    0, 0, 0, 0x18, ...'ftyp'.codeUnits, ...brand.codeUnits, //
    0, 0, 0, 0, ...'mif1'.codeUnits,
  ]);

  test('HEIC, HEIF and AVIF are recognized; JPEG and PNG are not', () {
    for (final brand in ['heic', 'heix', 'mif1', 'avif']) {
      expect(isHeifFamily(ftyp(brand)), isTrue, reason: brand);
    }
    expect(isHeifFamily(ftyp('isom')), isFalse, reason: 'MP4 video');
    expect(isHeifFamily(img.encodeJpg(img.Image(width: 4, height: 3))), isFalse);
    expect(isHeifFamily(img.encodePng(img.Image(width: 4, height: 3))), isFalse);
    expect(isHeifFamily(Uint8List(4)), isFalse);
  });

  test('only the start of a file is read to recognize it', () {
    final root = Directory.systemTemp.createTempSync('photo_import');
    addTearDown(() => root.deleteSync(recursive: true));
    final photo = File('${root.path}/photo.heic')
      ..writeAsBytesSync([...ftyp('heic'), ...List.filled(4096, 7)]);
    final header = readFileHeader(photo.path);
    expect(header, hasLength(16));
    expect(isHeifFamily(header), isTrue);
  });

  testWidgets('the platform codec re-encodes what it decodes as JPEG', (
    tester,
  ) async {
    final png = img.encodePng(
      img.Image(width: 40, height: 30)..clear(img.ColorRgb8(10, 200, 30)),
    );
    final jpeg = await tester.runAsync(
      () => transcodeWithPlatformCodec(png, quality: 90),
    );
    final decoded = img.decodeJpg(jpeg!)!;
    expect([decoded.width, decoded.height], [40, 30]);
    expect(decoded.getPixel(20, 15).g, greaterThan(150));
  });

  testWidgets('bytes no codec can read give null instead of an exception', (
    tester,
  ) async {
    final result = await tester.runAsync(
      () => transcodeWithPlatformCodec(Uint8List.fromList([1, 2, 3]), quality: 80),
    );
    expect(result, isNull);
  });
}
