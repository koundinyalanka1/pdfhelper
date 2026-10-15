import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/sheet_editor_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:pdfhelper/widgets/sheet/sheet_grid.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The spreadsheet screen, driven through the real spreadsheet engine:
///   eval "$(bash scripts/build_engines.sh env)"
///   flutter test test/screens/sheet_editor_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_sheet_editor');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    // A save records the file in Recent; a record left waiting by an
    // earlier test would hold this test's saves up behind it.
    RecentFilesService.resetCacheForTesting();
    DocumentSaveService.publishOverride = false;
  });

  tearDown(() {
    DocumentSaveService.publishOverride = null;
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  Future<void> flush(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Flushes until [finder] finds something: for steps that wait on the
  /// engine and the file system, which take longer on a busy machine.
  Future<void> until(
    WidgetTester tester,
    Finder finder, {
    int rounds = 100,
  }) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await flush(tester, rounds: 1);
    }
  }

  final available = SheetCore.isAvailable;

  String formulaText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  /// Tap a cell at 100% zoom with default sizes (64 by 20 pixels).
  Future<void> tapCell(WidgetTester tester, int row, int col) async {
    final origin = tester.getTopLeft(find.byType(SheetGrid));
    await tester.tapAt(
      origin +
          Offset(
            SheetGrid.headerWidth + col * 64 + 30,
            SheetGrid.headerHeight + row * 20 + 10,
          ),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<String> makeBook() async {
    final path = '${root.path}/accounts.xlsx';
    final book = SheetCore.create();
    book.setCell(0, 0, 0, '10');
    book.setCell(0, 1, 0, '20');
    book.setCell(0, 2, 0, '=SUM(A1:A2)');
    await saveBook(book, path);
    book.close();
    return path;
  }

  testWidgets('says why when the file cannot be opened', (tester) async {
    await tester.pumpWidget(
      app(SheetEditorScreen(path: '${root.path}/missing.xlsx')),
    );
    await flush(tester);
    expect(find.text('Could not open missing.xlsx'), findsOneWidget);
  }, skip: !available);

  testWidgets('types into a cell, recalculates and saves', (tester) async {
    late String path;
    await tester.runAsync(() async => path = await makeBook());
    await tester.pumpWidget(app(SheetEditorScreen(path: path)));
    await flush(tester);

    expect(find.text('A1'), findsOneWidget);
    expect(formulaText(tester), '10');
    await tapCell(tester, 2, 0);
    expect(find.text('A3'), findsOneWidget);
    expect(formulaText(tester), '=SUM(A1:A2)');

    await tapCell(tester, 0, 0);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '15');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    // Enter moved down to A2, ready to type.
    expect(find.text('A2'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(find.text('XLSX · Edited'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await flush(tester);
    expect(find.text('XLSX'), findsOneWidget);

    late String total;
    await tester.runAsync(() async {
      final book = await SheetCore.open(path);
      total = book.cell(0, 2, 0).text;
      book.close();
    });
    expect(total, '35');
  }, skip: !available);

  testWidgets('a new spreadsheet is written by its first save', (
    tester,
  ) async {
    final path = '${root.path}/new.xlsx';
    await tester.pumpWidget(app(SheetEditorScreen(path: path, isNew: true)));
    await flush(tester);
    expect(File(path).existsSync(), isFalse);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Name');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await flush(tester);
    expect(File(path).existsSync(), isTrue);
  }, skip: !available);

  testWidgets('a flat OpenDocument spreadsheet is saved as a new .ods', (
    tester,
  ) async {
    final path = '${root.path}/bills.fods';
    File(path).writeAsStringSync(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<office:document '
      'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
      'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
      'office:version="1.3" '
      'office:mimetype="application/vnd.oasis.opendocument.spreadsheet">'
      '<office:body><office:spreadsheet><table:table table:name="Bills">'
      '<table:table-row><table:table-cell office:value-type="float" '
      'office:value="12"><text:p>12</text:p></table:table-cell>'
      '</table:table-row></table:table></office:spreadsheet></office:body>'
      '</office:document>\n',
    );
    final original = File(path).readAsBytesSync();
    await tester.pumpWidget(app(SheetEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('Bills'), findsOneWidget);
    expect(
      find.textContaining(
        'It will be saved as an OpenDocument spreadsheet (.ods).',
      ),
      findsOneWidget,
    );

    await tapCell(tester, 0, 1);
    expect(find.text('B1'), findsOneWidget);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '=A1*2');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(find.text('ODS · Edited'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pump();
    // The button shows again once the save has finished.
    await until(tester, find.text('Save'));

    final edited = Directory('${root.path}/documents/Edited');
    final saved = File('${edited.path}/bills.ods');
    expect(
      saved.existsSync(),
      isTrue,
      reason: Directory(root.path).listSync(recursive: true).join('\n'),
    );
    late String doubled;
    late WorkbookInfo info;
    await tester.runAsync(() async {
      final book = await SheetCore.open(saved.path);
      doubled = book.cell(0, 0, 1).text;
      info = book.info();
      book.close();
    });
    expect(doubled, '24');
    expect(info.format, SheetFormat.ods);
    expect(info.writesBack, isTrue);
    // The flat original is left exactly as it was.
    expect(File(path).readAsBytesSync(), original);

    // A second save goes to the same copy.
    await tapCell(tester, 0, 2);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'paid');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await until(tester, find.text('Save'));
    expect(
      edited.listSync().map((e) => e.path.split('/').last).toList(),
      ['bills.ods'],
    );
    late String note;
    await tester.runAsync(() async {
      final book = await SheetCore.open(saved.path);
      note = book.cell(0, 0, 2).text;
      book.close();
    });
    expect(note, 'paid');
    expect(File(path).readAsBytesSync(), original);
  }, skip: !available);
}

Future<void> saveBook(SheetBook book, String path) async {
  await book.save(path, SheetFormat.xlsx);
}
