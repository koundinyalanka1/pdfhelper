import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/sheet_editor_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
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
}

Future<void> saveBook(SheetBook book, String path) async {
  await book.save(path, SheetFormat.xlsx);
}
