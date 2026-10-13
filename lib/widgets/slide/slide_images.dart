import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:path_provider/path_provider.dart';

/// Pictures of an open deck, decoded on first use and shared by the editor,
/// its thumbnails and the slide show.
class SlideImageCache extends ChangeNotifier {
  SlideImageCache(this.deck);

  final SlideDeck deck;
  final Map<String, ui.Image?> _images = {};
  Directory? _dir;
  bool _disposed = false;

  /// Bumped whenever a picture finishes loading, so painters repaint.
  int generation = 0;

  /// The picture for [part], or null while it loads (or when it is in a
  /// format Flutter cannot draw, such as EMF).
  ui.Image? get(String part) {
    if (_images.containsKey(part)) return _images[part];
    _images[part] = null;
    unawaited(_load(part));
    return null;
  }

  Future<void> _load(String part) async {
    try {
      final dir = _dir ??= await Directory(
        '${(await getTemporaryDirectory()).path}/slide_images_${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final file = File('${dir.path}/${_images.length}');
      deck.savePart(part, file.path);
      final bytes = await file.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      // Big photos are drawn small on a phone; keep memory in check.
      final wide = descriptor.width > 2048;
      final codec = await descriptor.instantiateCodec(
        targetWidth: wide ? 2048 : null,
      );
      final frame = await codec.getNextFrame();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _images[part] = frame.image;
      generation++;
      notifyListeners();
    } catch (_) {
      // Drawn as a grey box.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image?.dispose();
    }
    final dir = _dir;
    if (dir != null) {
      unawaited(dir.delete(recursive: true).catchError((_) => dir));
    }
    super.dispose();
  }
}
