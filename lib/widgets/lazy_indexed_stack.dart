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

  @override
  void initState() {
    super.initState();
    // Mark the initial screen built so the first frame shows real content.
    _markBuilt(widget.index, scheduleRebuild: false);
  }

  @override
  void didUpdateWidget(LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _markBuilt(widget.index, scheduleRebuild: true);
  }

  void _markBuilt(int index, {bool scheduleRebuild = true}) {
    if (index < 0 || index >= widget.itemCount) return;
    if (!_builtIndices.add(index)) return;
    if (scheduleRebuild && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      // IndexedStack asserts on an index past the end of its children. A null
      // index shows nothing instead, which is the right outcome for a tab
      // that does not exist and is a far better one than a crash.
      index: (widget.index >= 0 && widget.index < widget.itemCount)
          ? widget.index
          : null,
      alignment: widget.alignment,
      textDirection: widget.textDirection,
      sizing: widget.sizing,
      // itemBuilder is re-invoked for every visited index on each rebuild
      // rather than being called once and cached. Widgets are configuration,
      // not state — element and State objects are preserved across rebuilds —
      // so this costs nothing and lets a screen pick up new constructor
      // arguments (a newly handed-over PDF path, say). Caching the widget
      // instance froze those arguments at first visit.
      children: List.generate(widget.itemCount, (i) {
        if (_builtIndices.contains(i)) return widget.itemBuilder(i);
        return const SizedBox.expand();
      }),
    );
  }
}
