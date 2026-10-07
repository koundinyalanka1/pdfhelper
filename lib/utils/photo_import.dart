import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'error_logger.dart';

/// HEIF-family brands: HEIC/HEIF, which many phones save photos as, and AVIF.
const _heifBrands = {
  'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs', //
  'mif1', 'msf1', 'avif', 'avis',
};

/// Whether [header], a file's first 12 or more bytes, starts an HEIF-family
/// image. The `image` package, which cropping, the scan filters and PDF
/// conversion decode with, reads none of them.
bool isHeifFamily(Uint8List header) {
  if (header.length < 12) return false;
  if (String.fromCharCodes(header.sublist(4, 8)) != 'ftyp') return false;
  return _heifBrands.contains(String.fromCharCodes(header.sublist(8, 12)));
}

/// The first [length] bytes of the file at [path], enough to recognize its
/// format without reading a large photo into memory.
Uint8List readFileHeader(String path, {int length = 16}) {
  final file = File(path).openSync();
  try {
    return file.readSync(length);
  } finally {
    file.closeSync();
  }
}

/// [bytes] re-encoded as JPEG at [quality], decoded by the platform's own
/// codecs, which read HEIC/HEIF on Android 9+ and apply the photo's
/// rotation. Null when the platform cannot decode it either.
Future<Uint8List?> transcodeWithPlatformCodec(
  Uint8List bytes, {
  required int quality,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width;
    final height = image.height;
    final ByteData? pixels;
    try {
      pixels = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
    } finally {
      image.dispose();
    }
    if (pixels == null) return null;
    return await compute(
      _encodeJpeg,
      _RgbaFrame(pixels.buffer.asUint8List(), width, height, quality),
    );
  } catch (e) {
    logError('transcodeWithPlatformCodec', e);
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Payload for [_encodeJpeg] (must be sendable to an isolate).
class _RgbaFrame {
  const _RgbaFrame(this.pixels, this.width, this.height, this.quality);
  final Uint8List pixels;
  final int width;
  final int height;
  final int quality;
}

Uint8List _encodeJpeg(_RgbaFrame frame) {
  final image = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.pixels.buffer,
    bytesOffset: frame.pixels.offsetInBytes,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: frame.quality));
}
