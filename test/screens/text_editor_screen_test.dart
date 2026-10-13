import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The text editor, driven through the real text engine:
///   eval "$(bash scripts/build_engines.sh env)"
///   flutter test test/screens/text_editor_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_text_editor');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  /// Let isolate work (opening, saving) finish, then rebuild.
  Future<void> flush(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  String editorText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  final available = TextCore.isAvailable;

  testWidgets('says why when the file cannot be opened', (tester) async {
    await tester.pumpWidget(
      app(TextEditorScreen(path: '${root.path}/missing.txt')),
    );
    await flush(tester);
    expect(find.text('Could not open missing.txt'), findsOneWidget);
  }, skip: !available);

  testWidgets('edits and saves a Windows file keeping its line endings', (
    tester,
  ) async {
    final file = File('${root.path}/notes.txt')
      ..writeAsBytesSync('Rs. 100 paid\r\nRs. 50 due\r\n'.codeUnits);
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);

    expect(editorText(tester), 'Rs. 100 paid\nRs. 50 due\n');
    expect(find.text('UTF-8 · CRLF'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      'Rs. 100 paid\nRs. 50 paid\n',
    );
    await tester.pump();
    expect(find.text('UTF-8 · CRLF · Edited'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await flush(tester);
    expect(file.readAsStringSync(), 'Rs. 100 paid\r\nRs. 50 paid\r\n');
    expect(find.text('UTF-8 · CRLF'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  }, skip: !available);

  testWidgets('finds and replaces', (tester) async {
    final file = File('${root.path}/list.txt')
      ..writeAsStringSync('apple pie\nApple tart\npineapple\n');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);

    await tester.tap(find.byTooltip('Find'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'apple');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('2 of 3'), findsOneWidget);

    // Whole words leaves out "pineapple".
    await tester.tap(find.byTooltip('Find options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Whole words'),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Find options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Replace'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'mango');
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(editorText(tester), 'mango pie\nmango tart\npineapple\n');
    expect(find.text('No matches'), findsOneWidget);
  }, skip: !available);

  testWidgets('asks before leaving with unsaved changes', (tester) async {
    final file = File('${root.path}/draft.txt')..writeAsStringSync('first');
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => TextEditorScreen(path: file.path),
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
    // The editor shows a spinner until the engine has the file, so settle
    // the route transition by time rather than with pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await flush(tester);
    await tester.enterText(find.byType(TextField).last, 'second');
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Save your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsNothing);
    expect(file.readAsStringSync(), 'first');
  }, skip: !available);

  testWidgets('offers UTF-8 when the text no longer fits its encoding', (
    tester,
  ) async {
    final file = File('${root.path}/latin.txt')
      ..writeAsBytesSync([0x63, 0x61, 0x66, 0xE9]);
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(editorText(tester), 'café');
    expect(find.textContaining('was a guess'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'café ₹ 20');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Some characters cannot be saved'), findsOneWidget);
    await tester.tap(find.text('Use UTF-8'));
    await flush(tester);
    expect(file.readAsStringSync(), 'café ₹ 20');
  }, skip: !available);

  testWidgets('opens very large files read-only, by line', (tester) async {
    final lines = List.generate(40000, (i) => 'line number $i of a big log');
    final file = File('${root.path}/big.log')
      ..writeAsStringSync('${lines.join('\n')}\n');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(find.textContaining('opens read-only'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    expect(find.text('line number 0 of a big log'), findsOneWidget);

    await tester.tap(find.byTooltip('Find'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'number 30000 of');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1 of 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('line number 30000 of a big log'), findsOneWidget);
  }, skip: !available);
}
