import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/error_logger.dart';

/// Pictures of an open deck, decoded on first use and shared by the editor,
/// its thumbnails and the slide show.
class SlideImageCache extends ChangeNotifier {
  SlideImageCache(this.deck, {this.maxBytes = 64 * 1024 * 1024})
    : _decodeForTest = null;

  @visibleForTesting
  SlideImageCache.forTesting(this._decodeForTest, {this.maxBytes = 64 * 1024 * 1024})
    : deck = null;

  final SlideDeck? deck;
  final int maxBytes;
  final Future<ui.Image?> Function(String, int)? _decodeForTest;
  final _images = <(String, int, bool), ui.Image>{};
  final _pending = <(String, int, bool)>{};
  final _failed = <(String, int, bool)>{};
  final _queue = Queue<(String, int, bool)>();
  Future<Directory>? _directory;
  Future<void>? _draining;
  int _nextFile = 0;
  int _bytes = 0;
  bool _disposed = false;

  @visibleForTesting
  int get decodedBytes => _bytes;

  @visibleForTesting
  int get imageCount => _images.length;

  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Bumped whenever a picture finishes loading, so painters repaint.
  int generation = 0;

  /// The picture for [part], or null while it loads (or when it is in a
  /// format Flutter cannot draw, such as EMF).
  ui.Image? get(String part, {int maxDimension = 2048, bool thumbnail = false}) {
    if (_disposed) return null;
    final edge = maxDimension.clamp(1, thumbnail ? 512 : 2048);
    var bucket = 64;
    while (bucket < edge) { bucket *= 2; }
    final key = (part, bucket, thumbnail);
    final image = _images.remove(key);
    if (image != null) {
      _images[key] = image;
      return image;
    }
    if (!_failed.contains(key) && _pending.add(key)) {
      _queue.add(key);
      _draining ??= Future<void>.microtask(_drain);
    }
    return null;
  }

  /// The largest picture decoded, in pixels.
  static const maxPixels = 50 * 1000 * 1000;

  Future<void> _drain() async {
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final key = _queue.removeFirst();
        ui.Image? image;
        try {
          image = _decodeForTest == null
              ? await _load(key.$1, key.$2)
              : await _decodeForTest(key.$1, key.$2);
          if (_disposed) {
            image?.dispose();
            continue;
          }
          final bytes = image == null ? 0 : image.width * image.height * 4;
          if (image == null || bytes > maxBytes) {
            image?.dispose();
            _rememberFailure(key);
            continue;
          }
          while (_images.isNotEmpty && _bytes + bytes > maxBytes) {
            final oldest = _images.remove(_images.keys.first)!;
            _bytes -= oldest.width * oldest.height * 4;
            oldest.dispose();
          }
          _images[key] = image;
          _bytes += bytes;
          generation++;
          notifyListeners();
        } catch (error, stack) {
          if (!_disposed) {
            _rememberFailure(key);
            logError('SlideImages.load', error, stack);
          }
        } finally {
          _pending.remove(key);
        }
      }
    } finally {
      _draining = null;
    }
  }

  void _rememberFailure((String, int, bool) key) {
    _failed.add(key);
    if (_failed.length > 256) _failed.remove(_failed.first);
  }

  Future<ui.Image?> _load(String part, int edge) async {
    File? file;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final dir = await (_directory ??= () async {
        final root = await getTemporaryDirectory();
        return Directory(root.path).createTemp('slide_images_');
      }());
      if (_disposed) return null;
      file = File('${dir.path}/${_nextFile++}');
      await deck!.savePartAsync(part, file.path);
      if (_disposed) return null;
      final bytes = await file.readAsBytes();
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // A picture past about 50 megapixels could fill the phone's memory
      // as it decodes: it is drawn as a grey box instead.
      final (w, h) = (descriptor.width, descriptor.height);
      if (w <= 0 || h <= 0 || w * h > maxPixels) return null;
      // Big photos are drawn small on a phone; keep memory in check by
      // decoding them with their longer side at 2048 pixels.
      final scale = math.min(1.0, edge / math.max(w, h));
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * scale).round()),
        targetHeight: math.max(1, (h * scale).round()),
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      // Drawn as a grey box.
      rethrow;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      if (file != null && await file.exists()) await file.delete();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _pending.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _failed.clear();
    _bytes = 0;
    final directory = _directory;
    if (directory != null) {
      unawaited(() async {
        try {
          await _draining;
          final dir = await directory;
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (error, stack) {
          logError('SlideImages.dispose', error, stack);
        }
      }());
    }
    super.dispose();
  }
}
