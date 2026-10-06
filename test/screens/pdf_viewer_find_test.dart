import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/widgets/pdf_text_selection_overlay.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// Find in document, from the viewer's top bar.
///
/// Searching needs the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/screens/pdf_viewer_find_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_find');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    // Not a PDF; tests that open a real document replace it.
    pdf = File('${root.path}/Broken.pdf')..writeAsBytesSync([0x25, 0x50]);
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Widget app() => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: PdfViewerScreen(pdfPath: pdf.path)),
  );

  testWidgets('find waits until there is a document to search', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Find in document'), findsNothing);
    expect(find.byTooltip('Share'), findsOneWidget);
  });

  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;

  /// Let isolate work (opening, rendering, reading text) finish, then
  /// rebuild. A widget test's fake-async zone never completes `Isolate.run`
  /// on its own.
  Future<void> flush(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// End a test with nothing still rendering. PdfRaster's render slots are
  /// shared across the file, and a render abandoned with its test would hold
  /// one for good, starving the tests after it.
  Future<void> finish(WidgetTester tester) async {
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> open(WidgetTester tester, List<String> pages) async {
    pdf = writeTextPdfFixture(root, pages);
    await tester.pumpWidget(app());
    await flush(tester);
    expect(find.byType(ListView), findsOneWidget);
  }

  /// Type [query] into the find bar and press the keyboard's search key.
  Future<void> findText(WidgetTester tester, String query) async {
    await tester.tap(find.byTooltip('Find in document'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await flush(tester);
  }

  double scrollOffset(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.offset;

  double zoom(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  /// Where [word] on page [pageIndex] is drawn on screen, zoom included.
  Rect wordOnScreen(WidgetTester tester, int pageIndex, String word) {
    final overlay = find.descendant(
      of: find.byKey(ValueKey('${pdf.path}#$pageIndex')),
      matching: find.byType(PdfTextSelectionOverlay),
    );
    final layout = tester.widget<PdfTextSelectionOverlay>(overlay).layout;
    final start = layout.text.indexOf(word);
    expect(start, isNonNegative);
    final glyphs = layout.glyphs
        .where((g) => g.start >= start && g.end <= start + word.length)
        .toList();
    final box = tester.renderObject<RenderBox>(overlay);
    final scaleX = box.size.width / layout.width;
    final scaleY = box.size.height / layout.height;
    return Rect.fromPoints(
      box.localToGlobal(
        Offset(glyphs.first.left * scaleX, glyphs.first.top * scaleY),
      ),
      box.localToGlobal(
        Offset(glyphs.last.right * scaleX, glyphs.last.bottom * scaleY),
      ),
    );
  }

  void expectOnScreen(WidgetTester tester, Rect word) {
    final viewport = tester.getRect(find.byType(InteractiveViewer));
    expect(
      viewport.contains(word.topLeft) && viewport.contains(word.bottomRight),
      isTrue,
      reason: '$word is outside $viewport',
    );
  }

  testWidgets('steps through matches on every page, wrapping at the end', (
    tester,
  ) async {
    await open(tester, ['Alpha beta', 'Gamma', 'beta delta']);
    await findText(tester, 'BETA');

    expect(find.text('1/2'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-find-highlights')), findsOneWidget);
    expect(scrollOffset(tester), 0);

    await tester.tap(find.byTooltip('Next match'));
    await flush(tester, rounds: 8);
    expect(find.text('2/2'), findsOneWidget);
    expect(scrollOffset(tester), greaterThan(1000));
    expectOnScreen(tester, wordOnScreen(tester, 2, 'beta'));

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(scrollOffset(tester), 0);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('searches once typing pauses', (tester) async {
    await open(tester, ['Alpha beta', 'Gamma']);
    await tester.tap(find.byTooltip('Find in document'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'gam');
    await tester.pump(const Duration(milliseconds: 300));
    await flush(tester);

    expect(find.text('1/1'), findsOneWidget);
    expect(scrollOffset(tester), greaterThan(0));
    await finish(tester);
  });

  testWidgets('a match is brought into view without losing the zoom', (
    tester,
  ) async {
    await open(tester, ['Alpha beta', 'Gamma', 'beta delta']);
    final centre = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    // Not pumpAndSettle: the next page's loading spinner never settles in
    // fake time.
    await tester.pump(const Duration(milliseconds: 300));
    await flush(tester);
    final zoomed = zoom(tester);
    expect(zoomed, greaterThan(2));

    await findText(tester, 'delta');
    expect(find.text('1/1'), findsOneWidget);
    expect(zoom(tester), closeTo(zoomed, 0.001));
    expectOnScreen(tester, wordOnScreen(tester, 2, 'delta'));
    await finish(tester);
  });

  testWidgets('Back closes find before leaving the document', (tester) async {
    await open(tester, ['Alpha beta']);
    await findText(tester, 'beta');
    expect(find.text('1/1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('pdf-find-highlights')), findsNothing);
    expect(find.byTooltip('Find in document'), findsOneWidget);
    expect(find.byType(PdfViewerScreen), findsOneWidget);

    // Reopening keeps the query and finds it again.
    await tester.tap(find.byTooltip('Find in document'));
    await flush(tester);
    expect(find.text('1/1'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('clearing the query removes the highlights', (tester) async {
    await open(tester, ['Alpha beta']);
    await findText(tester, 'alpha');
    expect(find.byKey(const ValueKey('pdf-find-highlights')), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('1/1'), findsNothing);
    expect(find.byKey(const ValueKey('pdf-find-highlights')), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
          )
          .onPressed,
      isNull,
    );
    await finish(tester);
  });

  testWidgets('a query with no match reads 0/0', (tester) async {
    await open(tester, ['Alpha beta']);
    await findText(tester, 'omega');
    expect(find.text('0/0'), findsOneWidget);
    expect(find.textContaining('no searchable text'), findsNothing);
    await finish(tester);
  });

  testWidgets('an image-only document says why nothing is found', (
    tester,
  ) async {
    await open(tester, ['', '']);
    await findText(tester, 'anything');
    expect(find.text('0/0'), findsOneWidget);
    expect(
      find.text('This PDF has no searchable text. Scanned pages need OCR.'),
      findsOneWidget,
    );
    await finish(tester);
  });
}
