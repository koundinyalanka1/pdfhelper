import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/compress_screen.dart';
import 'package:pdfhelper/screens/page_images_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Compressing a PDF and saving its pages as pictures, through the native
/// core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/rust/target/release/libpdf_ffi.so \
///     flutter test test/screens/compress_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String pdf;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_compress');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    DocumentSaveService.publishOverride = false;
    pdf = '${root.path}/Report.pdf';
    File('test/fixtures/form.pdf').copySync(pdf);
  });

  tearDown(() {
    FakePathProvider.restore();
    DocumentSaveService.publishOverride = null;
    root.deleteSync(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  testWidgets('offers three levels, recommended first chosen', (tester) async {
    await tester.pumpWidget(app(CompressScreen(pdfPath: pdf)));
    await tester.pump();
    for (final level in ['Light', 'Recommended', 'Strong']) {
      expect(find.text(level), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('compress-recommended')),
        matching: find.byIcon(Icons.radio_button_checked_rounded),
      ),
      findsOneWidget,
    );
  });

  final library = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (library.isEmpty || !File(library).existsSync()) return;

  group('with the native core', () {
    setUpAll(PdfCoreService.probe);

    testWidgets('makes a named copy and says how it went', (tester) async {
      await tester.pumpWidget(app(CompressScreen(pdfPath: pdf)));
      await tester.tap(find.byKey(const ValueKey('compress-strong')));
      await tester.tap(find.byKey(const ValueKey('compress-run')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Report (compressed)'), findsOneWidget);
      await tester.tap(find.text('Compress').last);
      await until(tester, find.text('Success!'));
      expect(
        find.textContaining(RegExp(r'smaller\.|already compact')),
        findsWidgets,
      );
      final copies = Directory('${root.path}/documents')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('Report (compressed).pdf'));
      expect(copies, hasLength(1));
    });

    testWidgets('saves each page as a picture', (tester) async {
      await tester.pumpWidget(app(PageImagesScreen(pdfPath: pdf)));
      await tester.tap(find.byKey(const ValueKey('page-images-run')));
      await until(tester, find.text('Share 1 picture'));
      final pictures = Directory(
        '${root.path}/documents/Pictures/Report',
      ).listSync().map((f) => f.path.split('/').last).toList();
      expect(pictures, ['Report - page 1.jpg']);
    });
  });
}
