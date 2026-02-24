import 'package:flutter/material.dart';

/// A stack that lazily builds children only when first visited.
/// Reduces initial memory and build cost by deferring screen creation
/// until the user switches to that tab.
class LazyIndexedStack extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.itemCount,
    required this.itemBuilder,
    this.alignment = AlignmentDirectional.topStart,
    this.textDirection,
    this.sizing = StackFit.loose,
  });

  final int index;
  final int itemCount;
  final Widget Function(int index) itemBuilder;
  final AlignmentGeometry alignment;
  final TextDirection? textDirection;
  final StackFit sizing;

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final Set<int> _builtIndices = {};
  late List<Widget?> _children;

  @override
  void initState() {
    super.initState();
    _children = List.filled(widget.itemCount, null);
    // Build initial screen synchronously so first frame shows correct content
    _ensureBuilt(widget.index, scheduleRebuild: false);
  }

  @override
  void didUpdateWidget(LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureBuilt(widget.index, scheduleRebuild: true);
  }

  void _ensureBuilt(int index, {bool scheduleRebuild = true}) {
    if (index >= 0 && index < widget.itemCount && !_builtIndices.contains(index)) {
      _builtIndices.add(index);
      _children[index] = widget.itemBuilder(index);
      if (scheduleRebuild && mounted) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      alignment: widget.alignment,
      textDirection: widget.textDirection,
      sizing: widget.sizing,
      children: List.generate(widget.itemCount, (i) {
        if (_children[i] != null) {
          return _children[i]!;
        }
        return const SizedBox.expand();
      }),
    );
  }
}
