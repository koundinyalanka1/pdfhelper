import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:pdfhelper/widgets/pdf_text_selection_overlay.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// Recognize text from the viewer's top bar, and where the text goes after:
/// kept in the app, or saved as a new PDF.
///
/// Recognizing needs the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/screens/pdf_viewer_ocr_test.dart
void main() {
  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  const scan = 'packages/flutter_pdf_core/rust/fixtures/scanned.pdf';
  const scanText = 'Scanned invoice no. 2024-117';
  late Directory root;
  late FakePathProvider paths;
  late String source;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pdfhelper_viewer_ocr');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    await PdfCoreService.probe();
    source = '${root.path}/Invoice.pdf';
    File(scan).copySync(source);
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  final recognize = find.byTooltip('Recognize text (OCR)');

  /// Let isolate work (opening, rendering, reading text, OCR) finish, then
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

  Future<void> open(WidgetTester tester, String path) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(home: PdfViewerScreen(pdfPath: path)),
      ),
    );
    await flush(tester);
  }

  /// Close the viewer, so the next [open] is a fresh visit.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester, rounds: 5);
  }

  Future<void> recognizeText(WidgetTester tester) async {
    await tester.tap(recognize);
    await tester.pump();
    await flush(tester, rounds: 40);
    expect(find.text('Text recognized'), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String destination) async {
    await tester.tap(find.text(destination));
    await tester.pump();
    await flush(tester);
  }

  String selectableText(WidgetTester tester) => tester
      .widget<PdfTextSelectionOverlay>(find.byType(PdfTextSelectionOverlay))
      .layout
      .text;

  List<FileSystemEntity> keptText() {
    final dir = Directory('${paths.support.path}/recognized_text');
    if (!dir.existsSync()) return const [];
    return [
      for (final file in dir.listSync())
        if (file.path.endsWith('.json.gz')) file,
    ];
  }

  testWidgets('a scan is recognized in place and kept in the app', (
    tester,
  ) async {
    await open(tester, source);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(recognize, findsOneWidget);

    await recognizeText(tester);
    expect(find.textContaining('Found text on one page'), findsOneWidget);
    await choose(tester, 'Keep in DocHelper');

    expect(selectableText(tester), contains(scanText));
    expect(recognize, findsNothing);
    // Kept by the app: the PDF is left as it was and no copy is made.
    expect(keptText(), hasLength(1));
    expect(paths.documents.listSync(), isEmpty);
    expect(
      await tester.runAsync(() => PdfCore.extractTextAsync(source)),
      isNot(contains('invoice')),
    );

    // Find reads the recognized text.
    await tester.tap(find.byTooltip('Find in document'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await flush(tester);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-find-highlights')), findsOneWidget);
    await close(tester);
  });

  testWidgets('kept text is back the next time, from any copy of the file', (
    tester,
  ) async {
    await open(tester, source);
    await recognizeText(tester);
    await choose(tester, 'Keep in DocHelper');
    await close(tester);

    // Opened again from another app, which hands over a new temporary copy.
    final again = '${root.path}/intent_7_Invoice.pdf';
    File(source).copySync(again);
    await open(tester, again);
    expect(selectableText(tester), contains(scanText));
    expect(recognize, findsNothing);
    await close(tester);

    // A different file is a different document.
    File(again).writeAsBytesSync([...File(source).readAsBytesSync(), 0x0A]);
    await open(tester, again);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(recognize, findsOneWidget);
    await close(tester);
  });

  testWidgets('a scan can be saved as a new searchable PDF instead', (
    tester,
  ) async {
    await open(tester, source);
    await recognizeText(tester);
    await tester.tap(find.text('Save as a new PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Name your PDF'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pump();
    await flush(tester);

    expect(find.text('Searchable copy saved'), findsOneWidget);
    final out = '${paths.documents.path}/Invoice (searchable).pdf';
    expect(
      await tester.runAsync(() => PdfCore.extractTextAsync(out)),
      contains(scanText),
    );
    // The text went into the copy, not into the app.
    expect(keptText(), isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(recognize, findsOneWidget);
    await close(tester);
  });

  testWidgets('backing out of the name goes back to the choice', (
    tester,
  ) async {
    await open(tester, source);
    await recognizeText(tester);
    await tester.tap(find.text('Save as a new PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Text recognized'), findsOneWidget);
    await choose(tester, 'Keep in DocHelper');
    expect(selectableText(tester), contains(scanText));
    expect(paths.documents.listSync(), isEmpty);
    await close(tester);
  });

  testWidgets('discarding keeps nothing and still offers the button', (
    tester,
  ) async {
    await open(tester, source);
    await recognizeText(tester);
    await choose(tester, 'Discard');

    expect(find.text('Text recognized'), findsNothing);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(recognize, findsOneWidget);
    expect(keptText(), isEmpty);
    expect(paths.documents.listSync(), isEmpty);
    await close(tester);
  });

  testWidgets('More actions recognizes text the same way', (tester) async {
    await open(tester, source);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Recognize text (OCR)'));
    await tester.pump();
    await flush(tester, rounds: 40);
    expect(find.text('Text recognized'), findsOneWidget);
    await choose(tester, 'Discard');
    await close(tester);
  });

  testWidgets('a document with text is left as it is, every time', (
    tester,
  ) async {
    final pdf = writeTextPdfFixture(root, ['Chapter One']);
    await open(tester, pdf.path);
    expect(recognize, findsNothing);
    for (var run = 0; run < 2; run++) {
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Recognize text (OCR)'));
      await tester.pump();
      await flush(tester, rounds: 20);
      expect(find.text('Text recognized'), findsNothing);
      expect(
        find.textContaining('Every page already has text'),
        findsOneWidget,
      );
      // Let the message go before asking again.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
    expect(paths.documents.listSync(), isEmpty);
    await close(tester);
  });
}
