import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/services/pdf_raster.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// The viewer keeps its document parsed in the engine while it is open, so
/// its pages, page sizes and text share one parse. It must let go when it
/// closes, or every document ever viewed would stay in memory.
void main() {
  final library = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (library.isEmpty || !File(library).existsSync()) return;
  if (!DynamicLibrary.open(library).providesSymbol('pdf_document_open')) {
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File pdf;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_viewer_pin');
    FakePathProvider.install(root);
    pdf = writeTextPdfFixture(root, ['First', 'Second', 'Third']);
  });

  tearDown(() async {
    FakePathProvider.restore();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('opening pins the document once and closing releases it', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: PdfViewerScreen(pdfPath: pdf.path, title: 'Text.pdf'),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(ListView).evaluate().isNotEmpty) break;
    }
    expect(find.byType(ListView), findsOneWidget);
    expect(PdfRaster.openDocumentCount(pdf.path), 1);

    // Let the pages' renders and text loads finish against the pin.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(PdfRaster.openDocumentCount(pdf.path), 1);

    await tester.pumpWidget(const SizedBox());
    expect(PdfRaster.openDocumentCount(pdf.path), 0);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  });
}
