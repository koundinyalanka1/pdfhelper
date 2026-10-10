import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/extract_text_screen.dart';
import 'package:pdfhelper/screens/ocr_screen.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// Text recognition from the Tools screen and from Extract text.
///
/// Recognizing needs the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/screens/ocr_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakePathProvider paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_ocr');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  final start = find.widgetWithText(ElevatedButton, 'Recognize text');

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  testWidgets('says so when the native core is missing', (tester) async {
    await tester.pumpWidget(app(const OcrScreen(pdfPath: '/unused.pdf')));
    await tester.tap(start);
    await tester.pump();
    expect(find.text('Name your PDF'), findsNothing);
    expect(find.textContaining('text recognition is unavailable'), findsOne);
  });

  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;

  // The probe below must not reach the test above, so these are a group.
  group('with the native core', () {
    const scan = 'packages/flutter_pdf_core/rust/fixtures/scanned.pdf';
    const scanText = 'Scanned invoice no. 2024-117';

    setUp(() async {
      await PdfCoreService.probe();
      expect(PdfCoreService.isAvailable, isTrue);
    });

    /// Let isolate work finish, then rebuild. A widget test's fake-async zone
    /// never completes `Isolate.run` on its own.
    Future<void> flush(WidgetTester tester, {int rounds = 30}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    Future<void> recognize(WidgetTester tester) async {
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Recognize'));
      await tester.pump();
      await flush(tester);
    }

    testWidgets('a scan is saved as a searchable copy', (tester) async {
      final source = '${root.path}/Invoice.pdf';
      File(scan).copySync(source);
      await tester.pumpWidget(app(OcrScreen(pdfPath: source)));
      await recognize(tester);

      expect(find.text('Text recognized'), findsOneWidget);
      expect(find.textContaining('Recognized text on one page'), findsOne);
      final out = '${paths.documents.path}/Invoice (searchable).pdf';
      expect(
        await tester.runAsync(() => PdfCore.extractTextAsync(out)),
        contains(scanText),
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('a document with text gets no copy, and says why', (
      tester,
    ) async {
      final pdf = writeTextPdfFixture(root, ['Chapter One']);
      await tester.pumpWidget(app(OcrScreen(pdfPath: pdf.path)));
      await recognize(tester);

      expect(find.byKey(const ValueKey('ocr-outcome')), findsOneWidget);
      expect(find.textContaining('Every page already has text'), findsOne);
      expect(paths.documents.listSync(), isEmpty);
    });

    testWidgets('Extract text reads a scan once asked to', (tester) async {
      await tester.pumpWidget(app(const ExtractTextScreen(pdfPath: scan)));
      await flush(tester, rounds: 10);
      expect(find.textContaining('No text layer found'), findsOneWidget);

      await tester.tap(find.text('Recognize text'));
      await tester.pump();
      await flush(tester);

      expect(find.textContaining(scanText), findsOneWidget);
      expect(find.byKey(const ValueKey('ocr-banner')), findsOneWidget);
      expect(find.textContaining('recognized from the scan'), findsOneWidget);
    });

    testWidgets('Extract text offers OCR for the scanned pages of a mix', (
      tester,
    ) async {
      final pdf = writeTextPdfFixture(root, ['Typed page', '']);
      await tester.pumpWidget(app(ExtractTextScreen(pdfPath: pdf.path)));
      await flush(tester, rounds: 10);

      expect(find.textContaining('Typed page'), findsOneWidget);
      expect(find.textContaining('1 page has no text layer'), findsOneWidget);
      await tester.tap(find.text('Recognize'));
      await tester.pump();
      await flush(tester);

      // The grey box on the empty page holds no words to read.
      expect(find.textContaining('Typed page'), findsOneWidget);
      expect(find.byKey(const ValueKey('ocr-banner')), findsNothing);
    });
  });
}
