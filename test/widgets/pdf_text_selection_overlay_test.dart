import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:pdfhelper/widgets/pdf_text_selection_overlay.dart';

PdfPageTextLayout layout([String text = 'Hello world\nSecond line']) {
  final glyphs = <PdfTextGlyph>[];
  var offset = 0;
  var x = 30.0;
  var y = 100.0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    if (character == '\n') {
      x = 30;
      y += 40;
    } else {
      glyphs.add(
        PdfTextGlyph(
          start: offset,
          end: offset + character.length,
          left: x,
          top: y,
          right: x + 10,
          bottom: y + 18,
        ),
      );
      x += 10;
    }
    offset += character.length;
  }
  return PdfPageTextLayout(text: text, width: 300, height: 400, glyphs: glyphs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget page({
    String id = 'page',
    PdfPageTextLayout? textLayout,
    bool enabled = true,
    PdfTextSelectionController? controller,
    ValueChanged<bool>? onSelectionChanged,
    double scale = 1,
  }) => SizedBox(
    width: 300 * scale,
    height: 400 * scale,
    child: PdfTextSelectionOverlay(
      key: ValueKey(id),
      layout: textLayout ?? layout(),
      enabled: enabled,
      controller: controller,
      onSelectionChanged: onSelectionChanged,
      child: const ColoredBox(color: Colors.white, child: SizedBox.expand()),
    ),
  );

  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  Offset point(WidgetTester tester, Offset local, {String id = 'page'}) =>
      tester.getTopLeft(find.byKey(ValueKey(id))) + local;

  Future<void> select(
    WidgetTester tester,
    Offset local, {
    String id = 'page',
  }) async {
    await tester.longPressAt(point(tester, local, id: id));
    await tester.pump();
  }

  Future<void> copy(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Copy'));
    await tester.pump();
  }

  testWidgets('long press selects a word and copies its actual PDF text', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(app(page(onSelectionChanged: changes.add)));
    await select(tester, const Offset(45, 108));

    expect(find.text('Copy'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pdf-selection-start-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pdf-selection-end-handle')),
      findsOneWidget,
    );
    await copy(tester);

    expect(clipboard, 'Hello');
    expect(changes, [true, false]);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('long-press dragging extends selection across lines', (
    tester,
  ) async {
    await tester.pumpWidget(app(page()));
    final gesture = await tester.startGesture(
      point(tester, const Offset(45, 108)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(point(tester, const Offset(85, 148)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await copy(tester);

    expect(clipboard, 'Hello world\nSecond');
  });

  testWidgets('start handle extends selection to earlier text', (tester) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(110, 108));
    await tester.drag(
      find.byKey(const ValueKey('pdf-selection-start-handle')),
      const Offset(-60, 0),
    );
    await tester.pump();
    await copy(tester);

    expect(clipboard, 'Hello world');
  });

  testWidgets('end handle extends selection to later text', (tester) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(45, 108));
    await tester.drag(
      find.byKey(const ValueKey('pdf-selection-end-handle')),
      const Offset(60, 0),
    );
    await tester.pump();
    await copy(tester);

    expect(clipboard, 'Hello world');
  });

  testWidgets('Select all copies this page including line breaks', (
    tester,
  ) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(45, 108));
    await tester.tap(find.widgetWithText(TextButton, 'Select all'));
    await tester.pump();
    await copy(tester);

    expect(clipboard, 'Hello world\nSecond line');
  });

  testWidgets('tap elsewhere clears selection without copying', (tester) async {
    final controller = PdfTextSelectionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(page(controller: controller)));
    await select(tester, const Offset(45, 108));
    expect(controller.hasSelection, isTrue);

    await tester.tapAt(point(tester, const Offset(250, 280)));
    await tester.pump();

    expect(controller.hasSelection, isFalse);
    expect(find.text('Copy'), findsNothing);
    expect(clipboard, isNull);
  });

  testWidgets('shared controller keeps selection on only one page', (
    tester,
  ) async {
    final controller = PdfTextSelectionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            page(id: 'first', controller: controller),
            page(id: 'second', controller: controller),
          ],
        ),
      ),
    );
    await select(tester, const Offset(45, 108), id: 'first');
    await select(tester, const Offset(110, 108), id: 'second');

    expect(find.text('Copy'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('first')),
        matching: find.byKey(const ValueKey('pdf-selection-start-handle')),
      ),
      findsNothing,
    );
    expect(controller.hasSelection, isTrue);

    controller.clear();
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    expect(controller.hasSelection, isFalse);
  });

  testWidgets('ordinary drags still scroll the surrounding document', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      app(
        SingleChildScrollView(
          controller: scroll,
          child: Column(children: [page(), const SizedBox(height: 800)]),
        ),
      ),
    );
    await tester.dragFrom(
      point(tester, const Offset(250, 280)),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();

    expect(scroll.offset, greaterThan(50));
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('disabled selection and blank pages do not select', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(enabled: false)));
    await select(tester, const Offset(45, 108));
    expect(find.text('Copy'), findsNothing);

    await tester.pumpWidget(app(page(textLayout: layout(''))));
    await select(tester, const Offset(45, 108));
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank page margins do not select distant text', (tester) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(250, 280));
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('display scaling maps touches to page glyph coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(scale: 1.5)));
    await select(tester, const Offset(67.5, 162));
    await copy(tester);
    expect(clipboard, 'Hello');
  });

  testWidgets('UTF-16 glyph offsets preserve supplementary characters', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(textLayout: layout('A 😀 word'))));
    await select(tester, const Offset(55, 108));
    await copy(tester);
    expect(clipboard, '😀');
  });

  testWidgets('unmounting after controller disposal is safe', (tester) async {
    final controller = PdfTextSelectionController();
    await tester.pumpWidget(app(page(controller: controller)));
    await select(tester, const Offset(45, 108));
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
