import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/widgets/lazy_indexed_stack.dart';

void main() {
  Widget host({
    required int index,
    required Widget Function(int) itemBuilder,
    int itemCount = 3,
  }) {
    return MaterialApp(
      home: LazyIndexedStack(
        index: index,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }

  testWidgets('builds only the initial tab', (tester) async {
    final built = <int>[];
    await tester.pumpWidget(
      host(
        index: 0,
        itemBuilder: (i) {
          built.add(i);
          return Text('tab $i');
        },
      ),
    );

    expect(find.text('tab 0'), findsOneWidget);
    // skipOffstage: false, because IndexedStack keeps unselected children in
    // the tree but offstage — the default finder would report "not found" for
    // a tab that was in fact built, which is the opposite of what this checks.
    expect(find.text('tab 1', skipOffstage: false), findsNothing);
    expect(built.toSet(), {0});
  });

  testWidgets('builds a tab the first time it is visited', (tester) async {
    Widget build(int index) => host(index: index, itemBuilder: (i) => Text('tab $i'));

    await tester.pumpWidget(build(0));
    expect(find.text('tab 2', skipOffstage: false), findsNothing);

    await tester.pumpWidget(build(2));
    await tester.pump();

    expect(find.text('tab 2'), findsOneWidget);
  });

  testWidgets('keeps a visited tab alive after moving away', (tester) async {
    Widget build(int index) => host(index: index, itemBuilder: (i) => Text('tab $i'));

    await tester.pumpWidget(build(1));
    await tester.pump();
    expect(find.text('tab 1'), findsOneWidget);

    await tester.pumpWidget(build(0));
    await tester.pump();

    // Still in the tree (that is the point of an IndexedStack), just offstage.
    expect(find.text('tab 1', skipOffstage: false), findsOneWidget);
    expect(find.text('tab 1'), findsNothing);
  });

  testWidgets('a visited tab picks up new constructor arguments', (
    tester,
  ) async {
    // The regression this guards: the stack used to cache the built widget for
    // each index, so a tab handed a new PDF path after its first visit kept
    // showing the old one forever.
    var payload = 'first';
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LazyIndexedStack(
              index: 0,
              itemCount: 2,
              itemBuilder: (i) => Text('$i-$payload'),
            );
          },
        ),
      ),
    );

    expect(find.text('0-first'), findsOneWidget);

    update(() => payload = 'second');
    await tester.pump();

    expect(find.text('0-second'), findsOneWidget);
    expect(find.text('0-first'), findsNothing);
  });

  testWidgets('preserves child State across an unrelated rebuild', (
    tester,
  ) async {
    // Re-invoking itemBuilder must not throw away the tab's State — a half
    // filled form or a scroll position has to survive a parent rebuild.
    late StateSetter update;
    var unrelated = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LazyIndexedStack(
              index: 0,
              itemCount: 2,
              itemBuilder: (i) => _Counter(key: ValueKey(i), tag: '$unrelated'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('count 0'));
    await tester.pump();
    expect(find.text('count 1'), findsOneWidget);

    update(() => unrelated = 1);
    await tester.pump();

    expect(find.text('count 1'), findsOneWidget);
  });

  testWidgets('ignores an out-of-range index', (tester) async {
    await tester.pumpWidget(
      host(index: 9, itemCount: 3, itemBuilder: (i) => Text('tab $i')),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key, required this.tag});
  final String tag;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _count++),
      child: Text('count $_count'),
    );
  }
}
