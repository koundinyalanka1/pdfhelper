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
  final haptics = <String>[];
  var clipboardFails = false;
  var hapticsFail = false;

  setUp(() {
    clipboard = null;
    haptics.clear();
    clipboardFails = false;
    hapticsFail = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (clipboardFails) throw PlatformException(code: 'unavailable');
            clipboard = (call.arguments as Map)['text'] as String;
          } else if (call.method == 'HapticFeedback.vibrate') {
            if (hapticsFail) throw PlatformException(code: 'unavailable');
            haptics.add(call.arguments as String);
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
      tester
          .renderObject<RenderBox>(find.byKey(ValueKey(id)))
          .localToGlobal(local);

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
    expect(haptics, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.lightImpact',
    ]);
  });

  testWidgets('selection ticks follow changed ranges and are rate limited', (
    tester,
  ) async {
    await tester.pumpWidget(app(page()));
    final gesture = await tester.startGesture(
      point(tester, const Offset(45, 108)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(2, 0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(haptics, ['HapticFeedbackType.lightImpact']);

    await gesture.moveTo(point(tester, const Offset(110, 108)));
    await tester.pump();
    await gesture.moveTo(point(tester, const Offset(85, 148)));
    await tester.pump();
    expect(haptics, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.selectionClick',
    ]);

    await tester.pump(const Duration(milliseconds: 80));
    await gesture.moveTo(point(tester, const Offset(120, 148)));
    await tester.pump();
    expect(
      haptics.where((value) => value.endsWith('selectionClick')),
      hasLength(2),
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(haptics, hasLength(3));
  });

  testWidgets('clipboard failure retains selection and allows retry', (
    tester,
  ) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(45, 108));
    clipboardFails = true;
    await copy(tester);
    expect(clipboard, isNull);
    expect(find.text('Could not copy text. Try again.'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    clipboardFails = false;
    await copy(tester);
    expect(clipboard, 'Hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported haptics do not interrupt selection or copying', (
    tester,
  ) async {
    hapticsFail = true;
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(45, 108));
    await copy(tester);
    expect(clipboard, 'Hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('both handles remain reachable for a single narrow character', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(textLayout: layout('A B'))));
    await select(tester, const Offset(55, 108));
    final start = find.byKey(const ValueKey('pdf-selection-start-handle'));
    final end = find.byKey(const ValueKey('pdf-selection-end-handle'));
    expect(tester.getRect(start).overlaps(tester.getRect(end)), isFalse);
    await tester.drag(start, const Offset(-25, 0));
    await tester.pump();
    await copy(tester);
    expect(clipboard, 'A B');
  });

  testWidgets('handle selection preserves combining character clusters', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(textLayout: layout('Ae\u0301B'))));
    await select(tester, const Offset(35, 108));
    await tester.drag(
      find.byKey(const ValueKey('pdf-selection-start-handle')),
      const Offset(25, 0),
    );
    await tester.pump();
    await copy(tester);
    expect(clipboard, 'e\u0301B');
  });

  testWidgets('handles stay separate when clamped against the screen edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Align(
          alignment: Alignment.centerLeft,
          child: page(textLayout: layout('A B')),
        ),
      ),
    );
    await select(tester, const Offset(35, 108));
    final start = find.byKey(const ValueKey('pdf-selection-start-handle'));
    final end = find.byKey(const ValueKey('pdf-selection-end-handle'));
    expect(tester.getRect(start).overlaps(tester.getRect(end)), isFalse);
    expect(tester.getRect(start).left, greaterThanOrEqualTo(0));
    await tester.drag(end, const Offset(25, 0));
    await tester.pump();
    await copy(tester);
    expect(clipboard, 'A B');
  });

  testWidgets('long press respects Unicode apostrophes and punctuation', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(textLayout: layout('don’t—stop'))));
    await select(tester, const Offset(45, 108));
    await copy(tester);
    expect(clipboard, 'don’t');
  });

  testWidgets('handle selection preserves a joined emoji across PDF glyphs', (
    tester,
  ) async {
    await tester.pumpWidget(app(page(textLayout: layout('A👩‍💻B'))));
    await select(tester, const Offset(35, 108));
    await tester.drag(
      find.byKey(const ValueKey('pdf-selection-end-handle')),
      const Offset(15, 0),
    );
    await tester.pump();
    await copy(tester);
    expect(clipboard, 'A👩‍💻');
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
    expect(haptics, isEmpty);
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
    expect(haptics, isEmpty);
  });

  testWidgets('blank page margins do not select distant text', (tester) async {
    await tester.pumpWidget(app(page()));
    await select(tester, const Offset(250, 280));
    expect(find.text('Copy'), findsNothing);
    expect(haptics, isEmpty);
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

  testWidgets('zoomed selection controls remain visible at normal touch size', (
    tester,
  ) async {
    final transform = TransformationController(
      Matrix4.diagonal3Values(3, 3, 1)..setTranslationRaw(-30, -230, 0),
    );
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 300,
          height: 400,
          child: InteractiveViewer(
            transformationController: transform,
            minScale: 1,
            maxScale: 4,
            child: page(),
          ),
        ),
      ),
    );
    await select(tester, const Offset(45, 108));

    final toolbar = tester.getRect(
      find.byKey(const ValueKey('pdf-selection-toolbar')),
    );
    expect(toolbar.width, lessThan(300));
    expect(toolbar.left, greaterThanOrEqualTo(8));
    expect(toolbar.right, lessThanOrEqualTo(792));
    expect(toolbar.top, greaterThanOrEqualTo(8));
    expect(toolbar.bottom, lessThanOrEqualTo(592));
    final endHandle = find.byKey(const ValueKey('pdf-selection-end-handle'));
    expect(tester.getSize(endHandle), const Size(44, 44));

    await tester.drag(endHandle, const Offset(180, 0));
    await tester.pump();
    await copy(tester);
    expect(clipboard, 'Hello world');
    // A nearby page-space gap is a larger visible gap after zooming.
    await select(tester, const Offset(45, 80));
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default long press does not prevent two-finger zoom', (
    tester,
  ) async {
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 300,
          height: 400,
          child: InteractiveViewer(
            transformationController: transform,
            minScale: 1,
            maxScale: 4,
            child: page(),
          ),
        ),
      ),
    );
    final first = await tester.startGesture(
      point(tester, const Offset(100, 200)),
      pointer: 1,
    );
    final second = await tester.startGesture(
      point(tester, const Offset(200, 200)),
      pointer: 2,
    );
    await first.moveBy(const Offset(-30, 0));
    await second.moveBy(const Offset(30, 0));
    await tester.pump();
    await first.moveBy(const Offset(-20, 0));
    await second.moveBy(const Offset(20, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('updating a selected page clears its controls safely', (
    tester,
  ) async {
    final controller = PdfTextSelectionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(page(controller: controller)));
    await select(tester, const Offset(45, 108));
    await tester.pumpWidget(
      app(page(controller: controller, textLayout: layout('Changed'))),
    );
    await tester.pump();

    expect(controller.hasSelection, isFalse);
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
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
