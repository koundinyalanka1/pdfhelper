import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';

/// Coordinates selection across page overlays in one document.
class PdfTextSelectionController extends ChangeNotifier {
  Object? _owner;
  VoidCallback? _clearOwner;
  bool _disposed = false;

  bool get hasSelection => _owner != null;

  void clear() {
    if (_disposed || _owner == null) return;
    final clearOwner = _clearOwner;
    _owner = null;
    _clearOwner = null;
    clearOwner?.call();
    notifyListeners();
  }

  void _claim(Object owner, VoidCallback clearOwner) {
    if (_disposed || identical(_owner, owner)) return;
    _clearOwner?.call();
    _owner = owner;
    _clearOwner = clearOwner;
    notifyListeners();
  }

  void _release(Object owner) {
    if (_disposed || !identical(_owner, owner)) return;
    _owner = null;
    _clearOwner = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    _clearOwner = null;
    super.dispose();
  }
}

/// Selects extracted PDF text over the exact, bounded page image rectangle.
///
/// Page geometry uses top-left page coordinates and UTF-16 text offsets.
/// The overlay and image must share the viewer's zoom transform. Ordinary
/// drags remain available to the surrounding scroll view: selection begins
/// only after a long press, or when a selection handle is dragged.
class PdfTextSelectionOverlay extends StatefulWidget {
  const PdfTextSelectionOverlay({
    super.key,
    required this.layout,
    this.enabled = true,
    required this.child,
    this.controller,
    this.onSelectionChanged,
  });

  final PdfPageTextLayout layout;
  final bool enabled;
  final Widget child;
  final PdfTextSelectionController? controller;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<PdfTextSelectionOverlay> createState() =>
      _PdfTextSelectionOverlayState();
}

class _PdfTextSelectionOverlayState extends State<PdfTextSelectionOverlay> {
  final _pageKey = GlobalKey();
  final _controls = OverlayPortalController();
  List<PdfTextGlyph> _glyphs = const [];
  List<PdfTextGlyph> _hitGlyphs = const [];
  List<int> _clusterStarts = const [];
  List<int> _clusterEnds = const [];
  TextPainter? _wordPainter;
  Timer? _hapticCooldown;
  TextRange? _selection;
  TextRange? _anchorWord;
  int? _handleAnchor;
  Offset _handleGrabOffset = Offset.zero;
  bool _dragging = false;
  bool _copying = false;
  Offset _lastPosition = Offset.zero;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _readGlyphs();
  }

  void _readGlyphs() {
    _wordPainter?.dispose();
    _wordPainter = null;
    final text = widget.layout.text;
    _clusterStarts = List.filled(text.length, 0);
    _clusterEnds = List.filled(text.length, 0);
    var offset = 0;
    for (final character in text.characters) {
      final end = offset + character.length;
      for (var i = offset; i < end; i++) {
        _clusterStarts[i] = offset;
        _clusterEnds[i] = end;
      }
      offset = end;
    }
    _glyphs = widget.layout.glyphs.where((glyph) {
      return glyph.start >= 0 &&
          glyph.end <= widget.layout.text.length &&
          glyph.end > glyph.start &&
          glyph.left.isFinite &&
          glyph.top.isFinite &&
          glyph.right.isFinite &&
          glyph.bottom.isFinite &&
          glyph.right > glyph.left &&
          glyph.bottom > glyph.top;
    }).toList()..sort((a, b) => a.start.compareTo(b.start));
    // Whitespace stays in copied text, but needn't be inspected for every
    // pointer move on a dense page.
    _hitGlyphs = _glyphs.where((glyph) {
      return text.substring(glyph.start, glyph.end).trim().isNotEmpty;
    }).toList();
  }

  @override
  void didUpdateWidget(PdfTextSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout ||
        oldWidget.controller != widget.controller ||
        !widget.enabled) {
      final hadSelection = _selection != null;
      _selection = null;
      _anchorWord = null;
      _dragging = false;
      _readGlyphs();
      // A parent can disable selection during its own build. Notify only
      // after that frame, avoiding a controller-driven rebuild mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldWidget.controller?._release(this);
        if (mounted && _selection == null) _controls.hide();
        if (mounted && hadSelection && _selection == null) {
          widget.onSelectionChanged?.call(false);
        }
      });
    }
  }

  @override
  void dispose() {
    _hapticCooldown?.cancel();
    _wordPainter?.dispose();
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller?._release(this);
    });
    super.dispose();
  }

  Rect _rect(PdfTextGlyph glyph) => Rect.fromLTRB(
    glyph.left * _size.width / widget.layout.width,
    glyph.top * _size.height / widget.layout.height,
    glyph.right * _size.width / widget.layout.width,
    glyph.bottom * _size.height / widget.layout.height,
  );

  PdfTextGlyph? _nearest(Offset position, {bool nearby = false}) {
    PdfTextGlyph? nearest;
    var distance = double.infinity;
    for (final glyph in _hitGlyphs) {
      final rect = _rect(glyph);
      final dx = position.dx - position.dx.clamp(rect.left, rect.right);
      final dy = position.dy - position.dy.clamp(rect.top, rect.bottom);
      final candidate = dx * dx + dy * dy;
      if (candidate < distance) {
        distance = candidate;
        nearest = glyph;
      }
    }
    if (nearby) {
      final box = _pageKey.currentContext?.findRenderObject() as RenderBox?;
      final scale = box?.getTransformTo(null).getMaxScaleOnAxis() ?? 1;
      final tolerance = 24 / math.max(scale, 0.001);
      if (distance > tolerance * tolerance) return null;
    }
    return nearest;
  }

  TextRange _word(PdfTextGlyph glyph) {
    // Use Flutter's Unicode word boundaries instead of an ASCII punctuation
    // list. This paragraph is only for logical offsets; PDF geometry remains
    // the source of truth for hit testing and painting.
    final painter = _wordPainter ??= (TextPainter(
      text: TextSpan(text: widget.layout.text),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: widget.layout.width));
    final word = painter.getWordBoundary(TextPosition(offset: glyph.start));
    return _wholeCharacters(
      TextRange(
        start: math.min(word.start, glyph.start),
        end: math.max(word.end, glyph.end),
      ),
    );
  }

  TextRange _wholeCharacters(TextRange range) => TextRange(
    start: _clusterStarts[range.start],
    end: _clusterEnds[range.end - 1],
  );

  void _setSelection(TextRange selection, {bool feedback = true}) {
    selection = _wholeCharacters(selection);
    if (_selection == selection) return;
    final first = _selection == null;
    setState(() => _selection = selection);
    _controls.show();
    widget.controller?._claim(this, _clearFromController);
    if (first) widget.onSelectionChanged?.call(true);
    if (feedback) _selectionTick();
  }

  void _selectionTick() {
    // Moving within one glyph does nothing; fast drags get at most one tick
    // per 70 ms, without scheduling any delayed feedback after the gesture.
    if (_hapticCooldown != null) return;
    _hapticCooldown = Timer(const Duration(milliseconds: 70), () {
      _hapticCooldown = null;
    });
    unawaited(_feedback(selection: true));
  }

  Future<void> _feedback({bool selection = false}) async {
    try {
      if (selection) {
        await HapticFeedback.selectionClick();
      } else {
        await HapticFeedback.lightImpact();
      }
    } on PlatformException {
      // Optional platform feedback must never interrupt selection or copying.
    } on MissingPluginException {
      // Some desktop/test hosts have no haptic implementation.
    }
  }

  void _clearFromController() {
    if (!mounted || _selection == null) return;
    setState(() {
      _selection = null;
      _anchorWord = null;
      _dragging = false;
    });
    _controls.hide();
    widget.onSelectionChanged?.call(false);
  }

  void _clear() {
    _clearFromController();
    widget.controller?._release(this);
  }

  void _begin(LongPressStartDetails details) {
    final glyph = _nearest(details.localPosition, nearby: true);
    if (glyph == null) {
      _clear();
      return;
    }
    _lastPosition = details.localPosition;
    _anchorWord = _word(glyph);
    setState(() => _dragging = true);
    _setSelection(_anchorWord!, feedback: false);
    _hapticCooldown?.cancel();
    _hapticCooldown = Timer(const Duration(milliseconds: 70), () {
      _hapticCooldown = null;
    });
    unawaited(_feedback());
  }

  void _extend(LongPressMoveUpdateDetails details) {
    final anchor = _anchorWord;
    final glyph = _nearest(details.localPosition);
    if (anchor == null || glyph == null) return;
    _lastPosition = details.localPosition;
    final word = _word(glyph);
    _setSelection(
      TextRange(
        start: math.min(anchor.start, word.start),
        end: math.max(anchor.end, word.end),
      ),
    );
  }

  void _endDrag() {
    if (!mounted) return;
    setState(() => _dragging = false);
  }

  void _moveHandle(DragUpdateDetails details) {
    final box = _pageKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = _handleAnchor;
    if (box == null || anchor == null) return;
    _lastPosition =
        box.globalToLocal(details.globalPosition) - _handleGrabOffset;
    final glyph = _nearest(_lastPosition);
    if (glyph == null) return;
    _setSelection(
      TextRange(
        start: math.min(anchor, glyph.start),
        end: math.max(anchor, glyph.end),
      ),
    );
  }

  Future<void> _copy() async {
    final range = _selection;
    if (range == null || _copying) return;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(
        ClipboardData(
          text: widget.layout.text.substring(range.start, range.end),
        ),
      );
    } catch (error) {
      if (error is! PlatformException && error is! MissingPluginException) {
        rethrow;
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not copy text. Try again.')),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _copying = false);
    }
    if (mounted && _selection == range) {
      _clear();
      unawaited(_feedback());
    }
  }

  static const _handleSize = 44.0;

  Rect _handleBounds(
    Rect glyph, {
    required bool start,
    required Size viewport,
  }) {
    final x = start ? glyph.left - _handleSize : glyph.right;
    return Rect.fromLTWH(
      x.clamp(0.0, math.max(0, viewport.width - _handleSize)),
      (glyph.bottom - 6).clamp(0.0, math.max(0, viewport.height - _handleSize)),
      _handleSize,
      _handleSize,
    );
  }

  Widget _handle(
    Rect touchBounds, {
    required bool start,
    required Rect pageRect,
  }) {
    return Positioned(
      // Put touch targets outside the selected span so even a single narrow
      // character has two distinct, reachable handles.
      left: touchBounds.left,
      top: touchBounds.top,
      child: Semantics(
        label: start ? 'Adjust selection start' : 'Adjust selection end',
        child: GestureDetector(
          key: ValueKey(
            start ? 'pdf-selection-start-handle' : 'pdf-selection-end-handle',
          ),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (details) {
            _handleAnchor = start ? _selection!.end : _selection!.start;
            final box =
                _pageKey.currentContext!.findRenderObject() as RenderBox;
            _handleGrabOffset =
                box.globalToLocal(details.globalPosition) -
                Offset(
                  start ? pageRect.left : pageRect.right,
                  pageRect.center.dy,
                );
            setState(() => _dragging = true);
          },
          onPanUpdate: _moveHandle,
          onPanEnd: (_) => _endDrag(),
          onPanCancel: _endDrag,
          child: SizedBox(
            width: touchBounds.width,
            height: touchBounds.height,
            child: Align(
              alignment: start ? Alignment.topRight : Alignment.topLeft,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color:
                      Theme.of(
                        context,
                      ).textSelectionTheme.selectionHandleColor ??
                      const Color(0xFF1976D2),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(Offset anchor, Rect bounds) {
    return CustomSingleChildLayout(
      delegate: _ToolbarLayout(anchor, bounds),
      child: Material(
        key: const ValueKey('pdf-selection-toolbar'),
        elevation: 4,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surface,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: _copying ? null : _copy,
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => _setSelection(
                TextRange(start: 0, end: widget.layout.text.length),
              ),
              child: const Text('Select all'),
            ),
            IconButton(
              tooltip: 'Clear selection',
              onPressed: _clear,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, OverlayChildLayoutInfo info) {
    final range = _selection;
    if (range == null) return const SizedBox.shrink();
    final selected = _glyphs.where(
      (glyph) => glyph.end > range.start && glyph.start < range.end,
    );
    if (selected.isEmpty) return const SizedBox.shrink();

    final padding = MediaQuery.viewPaddingOf(context);
    final bounds = Rect.fromLTRB(
      padding.left + 8,
      padding.top + 8,
      info.overlaySize.width - padding.right - 8,
      info.overlaySize.height - padding.bottom - 8,
    );
    final start = _rect(selected.first);
    final end = _rect(selected.last);
    final startInOverlay = MatrixUtils.transformRect(
      info.childPaintTransform,
      start,
    );
    final endInOverlay = MatrixUtils.transformRect(
      info.childPaintTransform,
      end,
    );
    var startTouch = _handleBounds(
      startInOverlay,
      start: true,
      viewport: info.overlaySize,
    );
    var endTouch = _handleBounds(
      endInOverlay,
      start: false,
      viewport: info.overlaySize,
    );
    if (startTouch.overlaps(endTouch)) {
      // Clamping near a screen edge can bring otherwise separate targets back
      // together. Keep both reachable by fitting them side by side.
      final left =
          ((startTouch.center.dx + endTouch.center.dx) / 2 - _handleSize).clamp(
            0.0,
            math.max(0, info.overlaySize.width - 2 * _handleSize),
          );
      final startOnLeft = startInOverlay.center.dx <= endInOverlay.center.dx;
      startTouch = startTouch.shift(
        Offset(left + (startOnLeft ? 0 : _handleSize) - startTouch.left, 0),
      );
      endTouch = endTouch.shift(
        Offset(left + (startOnLeft ? _handleSize : 0) - endTouch.left, 0),
      );
    }
    final anchor = MatrixUtils.transformPoint(
      info.childPaintTransform,
      _lastPosition,
    );
    final viewport = Offset.zero & info.overlaySize;
    return Stack(
      children: [
        if (bounds.overlaps(startInOverlay))
          _handle(startTouch, start: true, pageRect: start),
        if (bounds.overlaps(endInOverlay))
          _handle(endTouch, start: false, pageRect: end),
        if (!_dragging && viewport.contains(anchor)) _toolbar(anchor, bounds),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSelect =
        widget.enabled &&
        _glyphs.isNotEmpty &&
        widget.layout.width.isFinite &&
        widget.layout.height.isFinite &&
        widget.layout.width > 0 &&
        widget.layout.height > 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        final range = canSelect ? _selection : null;
        final selected = range == null
            ? <PdfTextGlyph>[]
            : _glyphs
                  .where(
                    (glyph) =>
                        glyph.end > range.start && glyph.start < range.end,
                  )
                  .toList();
        return OverlayPortal.overlayChildLayoutBuilder(
          controller: _controls,
          overlayChildBuilder: _buildControls,
          child: Stack(
            key: _pageKey,
            clipBehavior: Clip.hardEdge,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: canSelect ? _begin : null,
                onLongPressMoveUpdate: canSelect ? _extend : null,
                onLongPressEnd: canSelect ? (_) => _endDrag() : null,
                onLongPressCancel: canSelect ? _endDrag : null,
                onTap: range != null ? _clear : null,
                child: widget.child,
              ),
              if (selected.isNotEmpty) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SelectionPainter(
                        selected.map(_rect).toList(),
                        Theme.of(context).textSelectionTheme.selectionColor ??
                            const Color(0x401976D2),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Measures the controls in screen coordinates, independent of page zoom.
class _ToolbarLayout extends SingleChildLayoutDelegate {
  const _ToolbarLayout(this.anchor, this.bounds);

  final Offset anchor;
  final Rect bounds;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: math.max(0, bounds.width));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final above = anchor.dy - childSize.height - 20;
    final top = above >= bounds.top ? above : anchor.dy + 36;
    return Offset(
      (anchor.dx - childSize.width / 2).clamp(
        bounds.left,
        math.max(bounds.left, bounds.right - childSize.width),
      ),
      top.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(_ToolbarLayout oldDelegate) =>
      anchor != oldDelegate.anchor || bounds != oldDelegate.bounds;
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter(this.rectangles, this.color);

  final List<Rect> rectangles;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final rect in rectangles) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) =>
      color != oldDelegate.color ||
      !listEquals(rectangles, oldDelegate.rectangles);
}
