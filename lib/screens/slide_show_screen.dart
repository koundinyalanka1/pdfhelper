import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';

import '../utils/error_logger.dart';
import '../widgets/slide/slide_images.dart';
import '../widgets/slide/slide_painter.dart';

/// A deck shown full screen, one slide at a time: tap or swipe to move on.
/// Hidden slides are skipped unless the show starts on one.
class SlideShowScreen extends StatefulWidget {
  const SlideShowScreen({
    super.key,
    required this.deck,
    required this.images,
    this.start = 0,
  });

  final SlideDeck deck;
  final SlideImageCache images;
  final int start;

  @override
  State<SlideShowScreen> createState() => _SlideShowScreenState();
}

class _SlideShowScreenState extends State<SlideShowScreen> {
  final Map<int, Future<SlideScene>> _scenes = {};
  List<int> _order = const [];
  PageController? _pages;
  bool _loading = true;
  String? _error;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _pages?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final order = await widget.deck.showOrderAsync(start: widget.start);
      if (!mounted) return;
      setState(() {
        _order = order;
        _page = order.indexOf(widget.start).clamp(0, order.length);
        _pages = PageController(initialPage: _page);
        _loading = false;
      });
    } catch (e, stack) {
      logError('SlideShow.open', e, stack);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is SlideCoreException ? e.message : 'The slide show could not be opened.';
      });
    }
  }

  Future<SlideScene> _scene(int i) => _scenes.putIfAbsent(i, () async {
    try {
      return await widget.deck.sceneAsync(i);
    } catch (e, stack) {
      logError('SlideShow.scene', e, stack);
      rethrow;
    }
  });

  void _go(int delta) {
    final next = _page + delta;
    if (next < 0) return;
    if (next > _order.length) {
      Navigator.of(context).pop();
      return;
    }
    _pages?.animateToPage(
      next,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator(semanticsLabel: 'Loading slide show'))
          else if (_error != null)
            Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, style: const TextStyle(color: Colors.white)),
            ))
          else GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final width = MediaQuery.sizeOf(context).width;
              _go(d.localPosition.dx < width / 3 ? -1 : 1);
            },
            child: PageView.builder(
              controller: _pages,
              itemCount: _order.length + 1,
              onPageChanged: (p) => setState(() {
                _page = p;
                final keep = _order.skip((p - 1).clamp(0, _order.length)).take(3).toSet();
                _scenes.removeWhere((i, _) => !keep.contains(i));
              }),
              itemBuilder: (context, p) {
                if (p == _order.length) {
                  return const Center(
                    child: Text(
                      'End of slide show. Tap to exit.',
                      style: TextStyle(color: Colors.white70, fontSize: 18),
                    ),
                  );
                }
                return FutureBuilder<SlideScene>(
                  future: _scene(_order[p]),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      final error = snapshot.error;
                      return Center(child: Text(
                        error is SlideCoreException ? error.message : 'This slide could not be shown.',
                        style: const TextStyle(color: Colors.white),
                      ));
                    }
                    final scene = snapshot.data;
                    if (scene == null) {
                      return const Center(child: CircularProgressIndicator(semanticsLabel: 'Loading slide'));
                    }
                    final size = MediaQuery.sizeOf(context);
                    final edge = (size.longestSide * MediaQuery.devicePixelRatioOf(context)).ceil();
                    return Semantics(
                      label: 'Slide ${_order[p] + 1}',
                      onIncrease: () => _go(1),
                      onDecrease: () => _go(-1),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: scene.width / scene.height,
                          child: ListenableBuilder(
                            listenable: widget.images,
                            builder: (context, _) => CustomPaint(
                              painter: SlidePainter(
                                scene: scene,
                                images: (part) => widget.images.get(part, maxDimension: edge),
                                generation: widget.images.generation,
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                tooltip: 'End show',
                color: Colors.white70,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          if (_page < _order.length)
            Positioned(
              bottom: 8,
              right: 16,
              child: Text(
                '${_page + 1} / ${_order.length}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
