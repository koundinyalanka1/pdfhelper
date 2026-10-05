import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';
import 'package:pdfhelper/widgets/pdf_text_selection_overlay.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

void main() {
  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;
  String? copied;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_text_selection');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    pdf = writeTextPdfFixture(root, ['Hello world']);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(home: PdfViewerScreen(pdfPath: pdf.path)),
      ),
    );
    await flush(tester);
    expect(find.byTooltip('Select text'), findsNothing);
    expect(find.byTooltip('Finish selecting text'), findsNothing);
  }

  Offset firstWord(WidgetTester tester) {
    final overlay = find.byType(PdfTextSelectionOverlay).first;
    final layout = tester.widget<PdfTextSelectionOverlay>(overlay).layout;
    expect(layout.text, contains('Hello world'));
    final glyph = layout.glyphs.first;
    final box = tester.renderObject<RenderBox>(overlay);
    return box.localToGlobal(
      Offset(
        (glyph.left + glyph.right) / 2 * box.size.width / layout.width,
        (glyph.top + glyph.bottom) / 2 * box.size.height / layout.height,
      ),
    );
  }

  testWidgets('selects and copies directly over the real rendered page', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(PdfTextSelectionOverlay), findsOneWidget);
    final word = firstWord(tester);
    await tester.longPressAt(word);
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'Hello');
    expect(find.text('Copy'), findsNothing);
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back exits text selection before leaving the document', (
    tester,
  ) async {
    await open(tester);
    await tester.longPressAt(firstWord(tester));
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    expect(find.byType(PdfTextSelectionOverlay), findsOneWidget);
    await tester.longPressAt(firstWord(tester));
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an image-only page explains why text cannot be selected', (
    tester,
  ) async {
    pdf = writeTextPdfFixture(root, ['']);
    await open(tester);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(find.textContaining('Scanned images need OCR'), findsNothing);
    await tester.longPress(find.byType(Image).first);
    await tester.pump();
    expect(
      find.text('No selectable text on this page. Scanned images need OCR.'),
      findsOneWidget,
    );
    expect(copied, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('More actions has no selection mode option', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Select text'), findsNothing);
    expect(find.text('Extract text'), findsOneWidget);
  });

  testWidgets('ordinary drag scrolls while text selection is available', (
    tester,
  ) async {
    await open(tester);
    final list = tester.widget<ListView>(find.byType(ListView));
    final before = list.controller!.offset;
    await tester.dragFrom(firstWord(tester), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(list.controller!.offset, greaterThan(before));
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling dismisses selection controls before they leave the page',
    (tester) async {
      await open(tester);
      await tester.longPressAt(firstWord(tester));
      await tester.pump();
      expect(find.text('Copy'), findsOneWidget);

      final list = tester.widget<ListView>(find.byType(ListView));
      final before = list.controller!.offset;
      await tester.dragFrom(
        tester.getCenter(find.byType(InteractiveViewer)),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();

      expect(list.controller!.offset, greaterThan(before));
      expect(find.text('Copy'), findsNothing);
      expect(
        find.byKey(const ValueKey('pdf-selection-start-handle')),
        findsNothing,
      );
      expect(copied, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging a selection handle keeps the document selection active',
    (tester) async {
      await open(tester);
      await tester.longPressAt(firstWord(tester));
      await tester.pump();
      final list = tester.widget<ListView>(find.byType(ListView));
      final before = list.controller!.offset;

      await tester.drag(
        find.byKey(const ValueKey('pdf-selection-end-handle')),
        const Offset(40, 0),
      );
      await tester.pump();

      expect(list.controller!.offset, before);
      expect(find.text('Copy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('double tap zooms and selection still copies while zoomed', (
    tester,
  ) async {
    await open(tester);
    final word = firstWord(tester);
    await tester.tapAt(word);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(word);
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await tester.longPressAt(firstWord(tester));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'Hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('panning a zoomed page dismisses selection controls', (
    tester,
  ) async {
    await open(tester);
    final word = firstWord(tester);
    await tester.tapAt(word);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(word);
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final before = Matrix4.copy(viewer.transformationController!.value);
    expect(before.getMaxScaleOnAxis(), greaterThan(1));
    await tester.longPressAt(firstWord(tester));
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);

    await tester.dragFrom(
      tester.getCenter(find.byType(InteractiveViewer)),
      const Offset(-80, -40),
    );
    await tester.pumpAndSettle();

    expect(viewer.transformationController!.value, isNot(before));
    expect(find.text('Copy'), findsNothing);
    expect(copied, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinching clears selection and zooms a text page', (
    tester,
  ) async {
    await open(tester);
    await tester.longPressAt(firstWord(tester));
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    final centre = tester.getCenter(find.byType(InteractiveViewer));
    final a = await tester.startGesture(centre - const Offset(40, 0));
    final b = await tester.startGesture(centre + const Offset(40, 0));
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-6, 4));
      await b.moveBy(const Offset(6, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
}
