import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/widgets/json_tree_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The JSON tree: opening and closing, Expand all and its limit, copying,
/// big and deep documents, and the parse helper's error positions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget app(Object? value, {int depth = 1}) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: Scaffold(
        body: JsonTreeView(value: value, initiallyExpandedDepth: depth),
      ),
    ),
  );

  /// The row widgets built right now.
  final rows = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith('json-row-');
  });

  ScrollController controller(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  /// How many rows the list holds, from its scroll extent.
  int rowCount(WidgetTester tester) {
    final position = controller(tester).position;
    final extent = tester.widget<ListView>(find.byType(ListView)).itemExtent!;
    return ((position.maxScrollExtent + position.viewportDimension - 24) /
            extent)
        .round();
  }

  /// Captures what is put on the clipboard.
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> copy(WidgetTester tester, Finder row, String what) async {
    await tester.longPress(row);
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('json-copy-$what')));
    await settle(tester);
  }

  final sample = {
    'name': 'Ada',
    'items': [10, 20, 30],
    'meta': {'a': 1.5, 'b': null},
    'ok': true,
  };

  testWidgets('shows the members closed, with counts and typed values', (
    tester,
  ) async {
    await tester.pumpWidget(app(sample));
    expect(find.text('Object · 4 keys'), findsOneWidget);
    expect(find.text('name'), findsOneWidget);
    expect(find.text('"Ada"'), findsOneWidget);
    expect(find.text('[3]'), findsOneWidget);
    expect(find.text('{2}'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
    // Closed containers build nothing inside them.
    expect(find.text('10'), findsNothing);
    expect(find.text('null'), findsNothing);
    expect(rows, findsNWidgets(4));
  });

  testWidgets('a tap opens a container and another closes it', (tester) async {
    await tester.pumpWidget(app(sample));
    await tester.tap(find.text('items'));
    await tester.pump();
    for (final text in ['0', '1', '2', '10', '20', '30']) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    expect(rows, findsNWidgets(7));

    await tester.tap(find.text('meta'));
    await tester.pump();
    expect(find.text('1.5'), findsOneWidget);
    expect(find.text('null'), findsOneWidget);

    await tester.tap(find.text('items'));
    await tester.pump();
    expect(find.text('10'), findsNothing);
    expect(find.text('1.5'), findsOneWidget);
    expect(rows, findsNWidgets(6));
  });

  testWidgets('expand all opens every level and collapse all closes them', (
    tester,
  ) async {
    final value = {
      'a': {
        'b': {
          'c': {'d': 'deep'},
        },
      },
      'list': [
        [
          1,
          [2],
        ],
      ],
    };
    await tester.pumpWidget(app(value));
    expect(find.text('b'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('json-expand-all')));
    await tester.pump();
    expect(find.text('"deep"'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byKey(const ValueKey('json-expand-capped')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('json-collapse-all')));
    await tester.pump();
    expect(find.text('b'), findsNothing);
    expect(find.text('"deep"'), findsNothing);
    expect(rows, findsNWidgets(2));

    // Opening a container again does not bring back what was open inside.
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsNothing);
  });

  testWidgets('starts open to the depth asked for', (tester) async {
    await tester.pumpWidget(app(sample, depth: 2));
    expect(find.text('30'), findsOneWidget);
    expect(find.text('null'), findsOneWidget);

    await tester.pumpWidget(app(sample, depth: 0));
    expect(find.text('items'), findsOneWidget);
    expect(find.text('30'), findsNothing);
  });

  testWidgets('a single value and an empty document show plainly', (
    tester,
  ) async {
    await tester.pumpWidget(app(42));
    expect(find.text('Number'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);

    await tester.pumpWidget(app(<String, dynamic>{}));
    expect(find.text('This object is empty.'), findsOneWidget);
    final expandAll = tester.widget<TextButton>(
      find.byKey(const ValueKey('json-expand-all')),
    );
    expect(expandAll.onPressed, isNull);
  });

  testWidgets('a long string is cut short, and a tap shows all of it', (
    tester,
  ) async {
    final long = List.generate(100, (i) => 'word$i').join(' ');
    await tester.pumpWidget(app({'text': long, 'short': 'fits'}));
    final preview = tester.widget<Text>(find.textContaining('"word0 word1'));
    expect(preview.data, endsWith('…"'));
    expect(preview.data!.length, lessThan(210));

    // A string that already shows whole has nothing to open.
    await tester.tap(find.text('"fits"'));
    await tester.pump();
    expect(rows, findsNWidgets(2));

    await tester.tap(find.text('text'));
    await tester.pump();
    expect(find.text('${long.length} characters'), findsOneWidget);
    final lines = rows.evaluate().length - 2;
    expect(lines, greaterThan(3));
    // Every word is on one of the lines, in order.
    final shown = [
      for (var i = 0; i < lines; i++)
        tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('json-row-${i + 1}')),
            matching: find.byType(Text),
          ),
        ),
    ].map((text) => text.data!).join();
    expect(shown.replaceAll(' ', ''), long.replaceAll(' ', ''));

    // Tapping one of its lines closes it again.
    await tester.tap(find.byKey(const ValueKey('json-row-2')));
    await tester.pump();
    expect(rows, findsNWidgets(2));
  });

  testWidgets('a string with line breaks opens one row per line', (
    tester,
  ) async {
    await tester.pumpWidget(
      app({
        'lf': 'line one\nline two\n\nafter a blank line',
        'crlf': 'a\r\nb\r\nc',
      }),
    );
    List<String> opened(int from, int count) => [
      for (var i = from; i < from + count; i++)
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(ValueKey('json-row-$i')),
                matching: find.byType(Text),
              ),
            )
            .data!,
    ];

    await tester.tap(find.text('lf'));
    await tester.pump();
    // No empty row after each break; the real blank line stays.
    expect(rows, findsNWidgets(6));
    expect(opened(1, 4), ['line one', 'line two', '', 'after a blank line']);

    await tester.tap(find.text('crlf'));
    await tester.pump();
    expect(rows, findsNWidgets(9));
    expect(opened(6, 3), ['a', 'b', 'c']);
  });

  testWidgets('long-press copies the path, quoting keys that need it', (
    tester,
  ) async {
    final value = {
      'items': [
        {
          'odd key': {'name': 'x', "it's": 1},
        },
      ],
    };
    await tester.pumpWidget(app(value, depth: 10));

    await copy(tester, find.text('name'), 'path');
    expect(clipboard, r"$.items[0]['odd key'].name");
    expect(find.text('Path copied'), findsOneWidget);

    await copy(tester, find.text("it's"), 'path');
    expect(clipboard, r"$.items[0]['odd key']['it\'s']");

    await copy(tester, find.text('"x"'), 'value');
    expect(clipboard, 'x');

    await copy(tester, find.text('odd key'), 'value');
    expect(
      clipboard,
      const JsonEncoder.withIndent('  ').convert({'name': 'x', "it's": 1}),
    );
    expect(find.text('Copied as JSON'), findsOneWidget);
  });

  testWidgets('a document 500 levels deep opens and scrolls quickly', (
    tester,
  ) async {
    Object? value = 'bottom';
    for (var i = 0; i < 500; i++) {
      value = i.isEven ? {'k': value} : [value];
    }
    await tester.pumpWidget(app(value));
    final watch = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('json-expand-all')));
    await tester.pump();
    watch.stop();
    debugPrint('Expand all, 500 levels: ${watch.elapsedMilliseconds} ms');
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect(rowCount(tester), 500);
    expect(rows.evaluate().length, lessThan(60));
    expect(find.byKey(const ValueKey('json-expand-capped')), findsNothing);

    controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
    await tester.pump();
    expect(find.text('"bottom"'), findsOneWidget);
    expect(rows.evaluate().length, lessThan(60));

    await copy(tester, find.text('"bottom"'), 'path');
    expect(clipboard, startsWith(r'$[0].k[0].k'));
    expect('['.allMatches(clipboard!).length, 250);
  });

  testWidgets('a hundred thousand values build only the rows on screen', (
    tester,
  ) async {
    final value = List.generate(100000, (i) => {'id': i, 'name': 'item $i'});
    final watch = Stopwatch()..start();
    await tester.pumpWidget(app(value));
    watch.stop();
    debugPrint('First build, 100,000 items: ${watch.elapsedMilliseconds} ms');
    expect(watch.elapsedMilliseconds, lessThan(3000));
    expect(find.text('Array · 100,000 items'), findsOneWidget);
    expect(rowCount(tester), 100000);
    expect(rows.evaluate().length, lessThan(60));

    controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
    await tester.pump();
    expect(find.text('99999'), findsOneWidget);
    expect(rows.evaluate().length, lessThan(60));

    // Opening one of them splices its rows in without rebuilding the rest.
    watch
      ..reset()
      ..start();
    await tester.tap(find.text('99999'));
    await tester.pump();
    watch.stop();
    debugPrint('Opening one item: ${watch.elapsedMilliseconds} ms');
    expect(rowCount(tester), 100002);

    // Already past the limit: Expand all opens nothing more and says so.
    await tester.tap(find.byKey(const ValueKey('json-expand-all')));
    await tester.pump();
    expect(find.byKey(const ValueKey('json-expand-capped')), findsOneWidget);
    expect(find.textContaining('Stopped at 100,002 rows'), findsOneWidget);
    expect(rowCount(tester), 100002);
  });

  testWidgets('expand all stops near the limit and says so', (tester) async {
    final value = List.generate(
      300,
      (i) => {for (var j = 0; j < 100; j++) 'k$j': j},
    );
    await tester.pumpWidget(app(value));
    await tester.tap(find.byKey(const ValueKey('json-expand-all')));
    await tester.pump();
    final count = rowCount(tester);
    expect(count, greaterThanOrEqualTo(JsonTreeView.expandAllLimit));
    expect(count, lessThanOrEqualTo(JsonTreeView.expandAllLimit + 100));
    expect(find.byKey(const ValueKey('json-expand-capped')), findsOneWidget);
    expect(rows.evaluate().length, lessThan(60));

    // The notice goes once the tree changes again.
    await tester.tap(find.byKey(const ValueKey('json-collapse-all')));
    await tester.pump();
    expect(find.byKey(const ValueKey('json-expand-capped')), findsNothing);
    expect(rowCount(tester), 300);
  });

  group('parseJsonForTree', () {
    test('returns the decoded value', () async {
      final result = await parseJsonForTree('{"a": [1, 2], "b": null}');
      expect(result.ok, isTrue);
      expect(result.value, {
        'a': [1, 2],
        'b': null,
      });
    });

    test('says where the JSON goes wrong', () async {
      final result = await parseJsonForTree('{\n  "a": 1,\n  "b": ,\n}');
      expect(result.ok, isFalse);
      expect(result.line, 3);
      expect(result.column, 8);
      expect(result.error, "Unexpected ',' at line 3, column 8.");
    });

    test('counts CR LF and lone CR as one line break each', () async {
      final crlf = await parseJsonForTree('{\r\n"a": 1,\r\n"b": }');
      expect((crlf.line, crlf.column), (3, 6));
      final cr = await parseJsonForTree('[1,\r2,\r]');
      expect((cr.line, cr.column), (3, 1));
    });

    test('explains unfinished JSON and strings', () async {
      final open = await parseJsonForTree('{"a": [1, 2');
      expect(open.error, startsWith('The JSON ends before it is complete'));
      expect((open.line, open.column), (1, 12));
      final quote = await parseJsonForTree('{"a": "x');
      expect(quote.error, contains('no closing quote'));
    });

    test('an empty file is not an error with a position', () async {
      final result = await parseJsonForTree('  \n ');
      expect(result.ok, isFalse);
      expect(result.error, contains('empty'));
      expect(result.line, isNull);
    });

    test('skips a byte-order mark', () async {
      final result = await parseJsonForTree(
        '${String.fromCharCode(0xFEFF)}[true]',
      );
      expect(result.value, [true]);
    });

    test('keeps numbers a Dart number would show differently', () async {
      final result = await parseJsonForTree(
        '{"id": 12345678901234567890, "price": 1.50, "huge": 1e400,\n'
        ' "n": 3, "f": 0.25, "list": [1.0, 2E3, -0, {}], '
        '"s": "a\\"b\\u00e9\\ud83d\\ude00", "id": 7}',
      );
      final value = result.value as Map;
      expect(value['price'], const JsonNumber('1.50'));
      expect(value['huge'], const JsonNumber('1e400'));
      expect(value['n'], 3);
      expect(value['f'], 0.25);
      expect(value['list'], [
        1.0,
        const JsonNumber('2E3'),
        const JsonNumber('-0'),
        <String, Object?>{},
      ]);
      expect(value['s'], 'a"bé😀');
      // A repeated key keeps its first place and its last value, as
      // jsonDecode has it.
      expect(value['id'], 7);
      expect(value.keys.toList(), [
        'id',
        'price',
        'huge',
        'n',
        'f',
        'list',
        's',
      ]);
      expect(const JsonNumber('1.50').value, 1.5);

      // Documents whose numbers all show as written decode as before.
      final plain = await parseJsonForTree('{"a": [1, 2.5, -3, 1.0e0]}');
      expect(plain.value, {
        'a': [1, 2.5, -3, const JsonNumber('1.0e0')],
      });
      final none = await parseJsonForTree('[1, 2.5, "1.50"]');
      expect(none.value, [1, 2.5, '1.50']);
    });

    test('reads with numbers kept exactly as jsonDecode reads', () async {
      // Random documents, each with one number that needs its text kept,
      // which makes the reader read the whole of it.
      var seed = 42;
      int next(int below) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        return seed % below;
      }

      Object? random(int depth) => switch (depth > 4 ? next(5) : next(7)) {
        0 => next(1000) - 500,
        1 => next(1000) / 8,
        2 => ['', 'a', 'é😀', 'tab\there', 'quote"', r'back\slash'][next(6)],
        3 => next(2) == 0,
        4 => null,
        5 => [for (var i = next(4); i > 0; i--) random(depth + 1)],
        _ => {
          for (var i = next(4); i > 0; i--) 'k${next(9)}': random(depth + 1),
        },
      };
      for (var round = 0; round < 200; round++) {
        final doc = {'kept': 1, 'body': random(0)};
        final text = jsonEncode(doc).replaceFirst('"kept":1', '"kept":1.50');
        final result = await parseJsonForTree(text);
        final expected = jsonDecode(text) as Map;
        expected['kept'] = const JsonNumber('1.50');
        expect(result.value, expected, reason: text);
      }
    });
  });

  testWidgets('shows and copies numbers as the file writes them', (
    tester,
  ) async {
    final parsed = await tester.runAsync(
      () => parseJsonForTree(
        '{"order": {"id": 12345678901234567890, "total": 10.50}}',
      ),
    );
    await tester.pumpWidget(app(parsed!.value, depth: 3));
    expect(find.text('12345678901234567890'), findsOneWidget);
    expect(find.text('10.50'), findsOneWidget);
    expect(find.text('Object · 1 key'), findsOneWidget);

    await copy(tester, find.text('order'), 'value');
    expect(clipboard, '{\n  "id": 12345678901234567890,\n  "total": 10.50\n}');
    await copy(tester, find.text('total'), 'value');
    expect(clipboard, '10.50');
  });

  testWidgets('copies containers exactly as JsonEncoder indents them', (
    tester,
  ) async {
    final inner = {
      'empty map': <String, Object?>{},
      'empty list': <Object?>[],
      'text': 'quote " back \\ tab \t newline \n é 😀',
      'numbers': [0, -1, 2.5, 1e21, double.infinity],
      'nested': [
        [
          [1],
        ],
        {
          'a': {'b': null},
        },
        true,
      ],
    };
    await tester.pumpWidget(app({'root': inner}));
    await copy(tester, find.text('root'), 'value');
    expect(
      clipboard,
      const JsonEncoder.withIndent('  ', _textOf).convert(inner),
    );
  });
}

/// How the tree writes what JSON cannot hold, such as Infinity: as text.
Object? _textOf(Object? value) => '$value';
