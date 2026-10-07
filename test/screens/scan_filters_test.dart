import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/screens/scan_edit_screen.dart';

/// Camera scans now arrive at up to 3840 px, so the filters bound their
/// working size instead of processing every pixel of a large photo.
void main() {
  Uint8List photo(int width, int height, {int? orientation}) {
    final image = img.Image(width: width, height: height)
      ..clear(img.ColorRgb8(200, 200, 190));
    img.fillRect(
      image,
      x1: width ~/ 4,
      y1: height ~/ 4,
      x2: width ~/ 2,
      y2: height ~/ 2,
      color: img.ColorRgb8(20, 20, 20),
    );
    if (orientation != null) image.exif.imageIfd.orientation = orientation;
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  img.Image filtered(Uint8List bytes, ScanFilter filter, {int quality = 85}) =>
      img.decodeJpg(
        processImageInBackground(
          ImageFilterRequest(bytes, filter.index, imageQuality: quality),
        ),
      )!;

  test('large scans are filtered at the 2400 px working size', () {
    final scan = photo(3840, 2160);
    for (final filter in ScanFilter.values.skip(1)) {
      final out = filtered(scan, filter);
      expect([out.width, out.height], [2400, 1350], reason: filter.name);
    }
  });

  test('Maximum quality keeps up to 3000 px, and small images keep theirs', () {
    final atMaximum = filtered(photo(3840, 2160), ScanFilter.auto, quality: 100);
    expect([atMaximum.width, atMaximum.height], [3000, 1688]);

    final small = filtered(photo(640, 480), ScanFilter.document);
    expect([small.width, small.height], [640, 480]);
  });

  test('a sideways camera image comes back upright', () {
    // Stored landscape with "rotate 90°", as cameras store portrait shots.
    final out = filtered(photo(3000, 2000, orientation: 6), ScanFilter.grayscale);
    expect([out.width, out.height], [1600, 2400]);
    final orientation = out.exif.imageIfd.orientation;
    expect(orientation == null || orientation == 1, isTrue);
  });
}
