import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';

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
  final Map<int, SlideScene> _scenes = {};
  late final List<int> _order;
  late final PageController _pages;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    final count = widget.deck.info().slideCount;
    _order = [
      for (var i = 0; i < count; i++)
        if (i == widget.start || !_scene(i).hidden) i,
    ];
    _page = _order.indexOf(widget.start).clamp(0, _order.length);
    _pages = PageController(initialPage: _page);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _pages.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  SlideScene _scene(int i) => _scenes[i] ??= () {
    try {
      return widget.deck.scene(i);
    } on SlideCoreException {
      final info = widget.deck.info();
      return SlideScene(width: info.width, height: info.height);
    }
  }();

  void _go(int delta) {
    final next = _page + delta;
    if (next < 0) return;
    if (next > _order.length) {
      Navigator.of(context).pop();
      return;
    }
    _pages.animateToPage(
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final width = MediaQuery.sizeOf(context).width;
              _go(d.localPosition.dx < width / 3 ? -1 : 1);
            },
            child: PageView.builder(
              controller: _pages,
              itemCount: _order.length + 1,
              onPageChanged: (p) => setState(() => _page = p),
              itemBuilder: (context, p) {
                if (p == _order.length) {
                  return const Center(
                    child: Text(
                      'End of slide show. Tap to exit.',
                      style: TextStyle(color: Colors.white70, fontSize: 18),
                    ),
                  );
                }
                final scene = _scene(_order[p]);
                return Center(
                  child: AspectRatio(
                    aspectRatio: scene.width / scene.height,
                    child: ListenableBuilder(
                      listenable: widget.images,
                      builder: (context, _) => CustomPaint(
                        painter: SlidePainter(
                          scene: scene,
                          images: widget.images.get,
                          generation: widget.images.generation,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
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
                color: Colors.white38,
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
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
