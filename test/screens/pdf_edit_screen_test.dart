import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_edit_screen.dart';
import 'package:pdfhelper/screens/pdf_stamp_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/widgets/pdf_edit/edit_items.dart';
import 'package:pdfhelper/widgets/pdf_edit/signature_pad.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Fill & sign, annotate, and page stamps. Saving goes through the native
/// core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/rust/target/release/libpdf_ffi.so \
///     flutter test test/screens/pdf_edit_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String pdf;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_edit');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    DocumentSaveService.publishOverride = false;
    SignatureStore.directoryOverride = root;
    pdf = '${root.path}/Form.pdf';
    File('test/fixtures/form.pdf').copySync(pdf);
  });

  tearDown(() {
    FakePathProvider.restore();
    DocumentSaveService.publishOverride = null;
    SignatureStore.directoryOverride = null;
    root.deleteSync(recursive: true);
  });

  /// Opening, rendering and saving run in isolates, which only advance
  /// outside the test's fake clock.
  Future<void> flush(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Flushes until [finder] finds something, or gives up.
  Future<void> until(
    WidgetTester tester,
    Finder finder, {
    int rounds = 100,
  }) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await flush(tester, rounds: 1);
    }
    expect(finder, findsWidgets);
  }

  /// Lets dialogs and sheets finish animating. Not `pumpAndSettle`: a page
  /// still rendering shows a spinner, which never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The screen over a home page that records what it popped with.
  Future<List<String?>> open(WidgetTester tester, Widget screen) async {
    final results = <String?>[];
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await Navigator.push<String>(
                    context,
                    MaterialPageRoute(builder: (_) => screen),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await flush(tester);
    return results;
  }

  testWidgets('says why when the file cannot be opened', (tester) async {
    await open(tester, PdfEditScreen(pdfPath: '${root.path}/missing.pdf'));
    await flush(tester);
    expect(find.byKey(const ValueKey('tool-pen')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test('a drawn signature is fitted to its own bounds and kept', () async {
    final signature = SavedSignature.fromDrawing([
      [const Offset(10, 10), const Offset(110, 60)],
    ])!;
    expect(signature.aspect, closeTo(112 / 62, 1e-9));
    expect(signature.strokes.first.first.dx, closeTo(6 / 112, 1e-9));
    await SignatureStore.add(signature);
    final kept = await SignatureStore.load();
    expect(kept.single.aspect, closeTo(signature.aspect, 1e-9));
  });

  test('pending items become the engine\'s edits', () {
    final item = SignatureItem(
      2,
      const Rect.fromLTWH(100, 100, 200, 50),
      const [
        [Offset(0, 0), Offset(1, 1)],
      ],
      const Color(0xFF0D47A1),
      2,
    );
    final json = item.toEdit(flatten: true).toJson();
    expect(json['type'], 'signature');
    expect(json['flatten'], isTrue);
    expect(json['strokes'], [
      [
        [100.0, 100.0],
        [300.0, 150.0],
      ],
    ]);
    final moved = item.translated(const Offset(10, 5)) as SignatureItem;
    expect(moved.box.topLeft, const Offset(110, 105));
    final text = TextItem(
      1,
      const Rect.fromLTWH(0, 0, 50, 20),
      'Hi',
      12,
      Colors.black,
    );
    expect(text.toEdit().toJson()['type'], 'text');
  });

  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;

  group('with the native core', () {
    testWidgets('fills a form and saves it in place', (tester) async {
      final results = await open(tester, PdfEditScreen(pdfPath: pdf));
      await until(tester, find.byKey(const ValueKey('field-name#0')));
      await tester.tap(find.byKey(const ValueKey('field-name#0')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Ada Lovelace');
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(
        find.text('Ada Lovelace'),
        findsOneWidget,
        reason: 'shown over the field',
      );
      await tester.tap(find.byKey(const ValueKey('field-agree#0')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('pdf-edit-save')));
      await until(tester, find.text('open'));
      expect(results, [pdf], reason: 'saved where it was');
      final form = PdfCore.formFields(pdf);
      expect(
        form.fields.firstWhere((f) => f.name == 'name').value,
        'Ada Lovelace',
      );
      expect(form.fields.firstWhere((f) => f.name == 'agree').value, 'Yes');
    });

    testWidgets('a note is placed where the page is tapped', (tester) async {
      final results = await open(tester, PdfEditScreen(pdfPath: pdf));
      await until(tester, find.byKey(const ValueKey('tool-note')));
      await tester.tap(find.byKey(const ValueKey('tool-note')));
      await tester.pump();
      final page = tester.getTopLeft(find.byType(CustomPaint).first);
      await tester.tapAt(page + const Offset(40, 300));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Check the date');
      await tester.tap(find.text('OK'));
      await settle(tester);

      // Undo takes it away again; the note is put back for the save.
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('pdf-edit-save')))
            .onPressed,
        isNull,
      );
      await tester.tapAt(page + const Offset(40, 300));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Check the date');
      await tester.tap(find.text('OK'));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('pdf-edit-save')));
      await until(tester, find.text('open'));
      expect(results, [pdf]);
      final notes = PdfCore.annotations(pdf, 1).where((a) => a.ours).toList();
      expect(notes.single.subtype, 'Text');
      expect(notes.single.contents, 'Check the date');
    });

    testWidgets('signs with a saved signature', (tester) async {
      await tester.runAsync(
        () => SignatureStore.add(
          SavedSignature.fromDrawing([
            [const Offset(0, 0), const Offset(40, 20), const Offset(80, 0)],
          ])!,
        ),
      );
      final results = await open(tester, PdfEditScreen(pdfPath: pdf));
      await until(tester, find.byKey(const ValueKey('tool-signature')));
      await tester.tap(find.byKey(const ValueKey('tool-signature')));
      await tester.pump();
      final page = tester.getTopLeft(find.byType(CustomPaint).first);
      await tester.tapAt(page + const Offset(150, 400));
      await until(tester, find.byType(SignaturePreview));
      await settle(tester);
      await tester.tap(find.byType(SignaturePreview));
      await settle(tester);
      expect(find.text('Drag to move, or the dot to resize'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pdf-edit-save')));
      await until(tester, find.text('open'));
      expect(results, [pdf]);
      final stamps = PdfCore.annotations(pdf, 1).where((a) => a.ours).toList();
      expect(stamps.single.subtype, 'Stamp');
    });

    testWidgets('numbers the pages', (tester) async {
      final results = await open(tester, PdfStampScreen(pdfPath: pdf));
      await tester.tap(find.text('Page 1 of 9'));
      await until(tester, find.byType(Image));
      expect(find.byType(Image), findsOneWidget, reason: 'a preview');
      await tester.tap(find.byKey(const ValueKey('stamp-save')));
      await until(tester, find.text('open'));
      expect(results, [pdf]);
      final layout = (await tester.runAsync(
        () => PdfCore.pageTextLayout(pdf, page: 1),
      ))!;
      expect(layout.text, contains('Page 1 of 1'));
    });
  });
}
