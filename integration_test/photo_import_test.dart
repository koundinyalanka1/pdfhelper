// Run on an attached Android device with:
// flutter test integration_test/photo_import_test.dart -d <device-id>
//
// HEIC needs the platform's decoder, which host tests do not have.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:pdfhelper/utils/photo_import.dart';

import 'support/heic_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a HEIC photo from the gallery becomes a JPEG the scan tools read', (
    tester,
  ) async {
    final heic = base64Decode(heicPhotoBase64);
    expect(isHeifFamily(heic), isTrue);
    expect(img.findDecoderForData(heic), isNull);

    final jpeg = await tester.runAsync(
      () => transcodeWithPlatformCodec(heic, quality: 90),
    );
    expect(jpeg, isNotNull);
    expect(isHeifFamily(jpeg!), isFalse);
    final decoded = img.decodeJpg(jpeg)!;
    expect([decoded.width, decoded.height], [64, 48]);
  });
}
