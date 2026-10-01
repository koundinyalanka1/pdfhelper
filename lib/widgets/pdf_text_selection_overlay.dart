import 'dart:math' as math;

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
    required this.enabled,
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
  List<PdfTextGlyph> _glyphs = const [];
  TextRange? _selection;
  TextRange? _anchorWord;
  int? _handleAnchor;
  Offset _handleGrabOffset = Offset.zero;
  bool _dragging = false;
  Offset _lastPosition = Offset.zero;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _readGlyphs();
  }

  void _readGlyphs() {
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
        if (mounted && hadSelection && _selection == null) {
          widget.onSelectionChanged?.call(false);
        }
      });
    }
  }

  @override
  void dispose() {
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
    for (final glyph in _glyphs) {
      if (widget.layout.text.substring(glyph.start, glyph.end).trim().isEmpty) {
        continue;
      }
      final rect = _rect(glyph);
      final dx = position.dx - position.dx.clamp(rect.left, rect.right);
      final dy = position.dy - position.dy.clamp(rect.top, rect.bottom);
      final candidate = dx * dx + dy * dy;
      if (candidate < distance) {
        distance = candidate;
        nearest = glyph;
      }
    }
    return nearby && distance > 24 * 24 ? null : nearest;
  }

  static final _wordBoundary = RegExp(r'''[\s.,;:!?()\[\]{}"“”‘’<>/\\|=+]''');

  TextRange _word(PdfTextGlyph glyph) {
    final text = widget.layout.text;
    var start = glyph.start;
    var end = glyph.end;
    if (!_wordBoundary.hasMatch(text.substring(start, end))) {
      while (start > 0 && !_wordBoundary.hasMatch(text[start - 1])) {
        start--;
      }
      while (end < text.length && !_wordBoundary.hasMatch(text[end])) {
        end++;
      }
    }
    return TextRange(start: start, end: end);
  }

  void _setSelection(TextRange selection) {
    final first = _selection == null;
    setState(() => _selection = selection);
    widget.controller?._claim(this, _clearFromController);
    if (first) widget.onSelectionChanged?.call(true);
  }

  void _clearFromController() {
    if (!mounted || _selection == null) return;
    setState(() {
      _selection = null;
      _anchorWord = null;
      _dragging = false;
    });
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
    _dragging = true;
    _setSelection(_anchorWord!);
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
    if (range == null) return;
    await Clipboard.setData(
      ClipboardData(text: widget.layout.text.substring(range.start, range.end)),
    );
    if (mounted && _selection == range) _clear();
  }

  Widget _handle(Rect rect, {required bool start}) {
    const touchSize = 44.0;
    final x = start ? rect.left : rect.right;
    return Positioned(
      left: (x - touchSize / 2).clamp(
        0.0,
        math.max(0, _size.width - touchSize),
      ),
      top: (rect.bottom - 6).clamp(0.0, math.max(0, _size.height - touchSize)),
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
                Offset(start ? rect.left : rect.right, rect.center.dy);
            setState(() => _dragging = true);
          },
          onPanUpdate: _moveHandle,
          onPanEnd: (_) => _endDrag(),
          onPanCancel: _endDrag,
          child: SizedBox(
            width: touchSize,
            height: touchSize,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final top = _lastPosition.dy > 64
        ? _lastPosition.dy - 60
        : _lastPosition.dy + 32;
    return Positioned(
      left: 8,
      right: 8,
      top: top.clamp(0.0, math.max(0, _size.height - 56)),
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surface,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(onPressed: _copy, child: const Text('Copy')),
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
      ),
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
        return Stack(
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
                      Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                ),
              ),
              _handle(_rect(selected.first), start: true),
              _handle(_rect(selected.last), start: false),
              if (!_dragging) _toolbar(),
            ],
          ],
        );
      },
    );
  }
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
  bool shouldRepaint(_SelectionPainter oldDelegate) => true;
}
