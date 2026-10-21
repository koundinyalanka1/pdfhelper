import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/services/draft_service.dart';
import 'package:pdfhelper/services/editor_draft.dart';
import 'package:pdfhelper/widgets/json_tree_view.dart';
import 'package:pdfhelper/widgets/markup_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The text editor, driven through the real text engine:
///   eval "$(bash scripts/build_libs.sh env)"
///   flutter test test/screens/text_editor_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_text_editor');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    EditorDraft.serviceOverride = DraftService(
      directory: Directory('${root.path}/Drafts'),
    );
  });

  tearDown(() {
    EditorDraft.serviceOverride = null;
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

  /// Let isolate work finish until [finder] shows.
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  /// Text drawn anywhere, including inside a page's styled paragraphs.
  Finder shows(String text) => find.textContaining(text, findRichText: true);

  final toggle = find.byKey(const ValueKey('text-preview-toggle'));

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

  testWidgets('typing is kept for recovery and offered back', (tester) async {
    final file = File('${root.path}/shopping.txt')
      ..writeAsStringSync('milk\n');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    await tester.enterText(find.byType(TextField).last, 'milk\nbread\n');
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await flush(tester, rounds: 30);

    await tester.pumpWidget(const SizedBox());
    await flush(tester, rounds: 4);
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await until(tester, find.text('Restore unsaved changes?'));
    await tester.tap(find.text('Restore'));
    await until(tester, find.text('UTF-8 · LF · Edited'));
    expect(editorText(tester), 'milk\nbread\n');
    expect(file.readAsStringSync(), 'milk\n');

    await tester.tap(find.text('Save'));
    await until(tester, find.text('UTF-8 · LF'));
    expect(file.readAsStringSync(), 'milk\nbread\n');
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
    await until(tester, find.text('1 of 3'));
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
    await until(tester, find.text('1 of 2'));
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Find options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Replace'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'mango');
    await tester.tap(find.text('All'));
    await until(tester, find.text('No matches'));
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
    // Discarding also drops the recovery copy, off the UI isolate.
    for (var i = 0; i < 100 && find.byType(TextEditorScreen).evaluate().isNotEmpty; i++) {
      await flush(tester, rounds: 1);
    }
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
    await until(tester, find.text('Some characters cannot be saved'));
    expect(find.text('Some characters cannot be saved'), findsOneWidget);
    await tester.tap(find.text('Use UTF-8'));
    await flush(tester, rounds: 30);
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
    await until(tester, find.text('1 of 1'));
    expect(find.text('1 of 1'), findsOneWidget);
    await until(tester, find.text('line number 30000 of a big log'));
    expect(find.text('line number 30000 of a big log'), findsOneWidget);
  }, skip: !available);

  testWidgets('opens Markdown as a page, and previews edits not yet saved', (
    tester,
  ) async {
    final file = File('${root.path}/notes.md')
      ..writeAsStringSync('# Shopping list\n\nBuy **milk** and eggs.\n');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await until(tester, find.byType(MarkupView));
    expect(shows('Shopping list'), findsWidgets);
    expect(find.byTooltip('Edit'), findsOneWidget);
    // Editing-only tools stay out of the way while reading.
    expect(find.byTooltip('Find'), findsNothing);
    expect(find.byTooltip('Undo'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byType(MarkupView), findsNothing);
    expect(find.byTooltip('Preview'), findsOneWidget);
    expect(find.byTooltip('Find'), findsOneWidget);
    expect(editorText(tester), '# Shopping list\n\nBuy **milk** and eggs.\n');

    await tester.enterText(
      find.byType(TextField).last,
      '# Groceries\n\n- rice\n- dal\n',
    );
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const ValueKey('text-preview-busy')), findsOneWidget);
    await until(tester, shows('Groceries'));
    expect(shows('Shopping list'), findsNothing);
    expect(shows('dal'), findsWidgets);

    // Unchanged text is not read again.
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const ValueKey('text-preview-busy')), findsNothing);
    expect(shows('Groceries'), findsWidgets);

    // Saving works from the preview too.
    await tester.tap(find.text('Save'));
    await flush(tester);
    expect(file.readAsStringSync(), '# Groceries\n\n- rice\n- dal\n');
  }, skip: !available);

  testWidgets('opens an empty Markdown file for typing', (tester) async {
    final file = File('${root.path}/empty.md')..writeAsStringSync('');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Preview'), findsOneWidget);
  }, skip: !available);

  testWidgets('shows HTML as a page with pictures next to it', (tester) async {
    final file = File('${root.path}/page.html')
      ..writeAsStringSync(
        '<html><head><title>Hidden title</title>'
        '<script>var hidden = 1;</script></head>'
        '<body><h1>Welcome</h1><p>Hello <b>there</b></p>'
        '<img src="logo.png" alt="Logo"></body></html>',
      );
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await until(tester, find.byType(MarkupView));
    expect(shows('Welcome'), findsWidgets);
    expect(shows('there'), findsWidgets);
    expect(shows('hidden = 1'), findsNothing);
    final view = tester.widget<MarkupView>(find.byType(MarkupView));
    expect(view.baseDirectory, root.path);

    await tester.tap(toggle);
    await tester.pump();
    expect(editorText(tester), contains('<h1>Welcome</h1>'));
  }, skip: !available);

  testWidgets('shows JSON as a tree, opening as text', (tester) async {
    final file = File('${root.path}/data.json')
      ..writeAsStringSync('{"name": "Asha", "items": [10, 20, 30]}');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(JsonTreeView), findsNothing);

    await tester.tap(toggle);
    await until(tester, find.byType(JsonTreeView));
    expect(find.text('name'), findsOneWidget);
    expect(find.text('"Asha"'), findsOneWidget);
    expect(find.text('[3]'), findsOneWidget);

    // A look at the text and back keeps what was opened in the tree.
    await tester.tap(find.text('items'));
    await tester.pump();
    expect(find.text('20'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('20'), findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('20'), findsOneWidget);

    // Formatting is an edit, so it waits for the text.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Format JSON'), findsNothing);
    expect(find.text('Share'), findsOneWidget);
  }, skip: !available);

  testWidgets('a JSON mistake goes to its line in the text', (tester) async {
    const text = '{\n  "a": 1,\n  "b": ,\n  "c": 3\n}\n';
    final file = File('${root.path}/broken.json')..writeAsStringSync(text);
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    await tester.tap(toggle);
    await until(tester, find.byKey(const ValueKey('text-preview-problem')));
    expect(find.text('This is not valid JSON'), findsOneWidget);
    expect(shows("Unexpected ',' at line 3, column 8."), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('text-preview-go-to-line')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final field = tester.widget<TextField>(find.byType(TextField).last);
    final offset = field.controller!.selection.baseOffset;
    expect(text[offset], ',');
    expect(text.substring(0, offset).split('\n').length, 3);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.byTooltip('Preview'), findsOneWidget);

    // Fixed, the tree shows.
    await tester.enterText(
      find.byType(TextField).last,
      '{"a": 1, "b": 2, "c": 3}',
    );
    await tester.pump();
    await tester.tap(toggle);
    await until(tester, find.byType(JsonTreeView));
    expect(find.text('This is not valid JSON'), findsNothing);
  }, skip: !available);

  testWidgets('a large Markdown file opens as a page, its text read-only', (
    tester,
  ) async {
    final sections = [
      for (var i = 0; i < 6000; i++)
        '## Section $i\n\nSome words about section $i of a long file.\n',
    ];
    final file = File('${root.path}/long.md')
      ..writeAsStringSync(sections.join('\n'));
    expect(file.lengthSync(), greaterThan(TextEditorScreen.editableLimit));
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await until(tester, find.byType(MarkupView));
    expect(shows('Section 0'), findsWidgets);
    expect(find.text('Save'), findsNothing);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.textContaining('opens read-only'), findsOneWidget);
    expect(find.text('## Section 0'), findsOneWidget);
  }, skip: !available);

  testWidgets('a Markdown file too large to read as a page opens as text', (
    tester,
  ) async {
    // A quarter of a million list items would take hundreds of megabytes.
    final file = File('${root.path}/huge.md')
      ..writeAsStringSync('- a\n' * 260000);
    expect(
      file.lengthSync(),
      greaterThan(TextEditorScreen.markdownPreviewLimit),
    );
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(find.textContaining('opens read-only'), findsOneWidget);
    expect(find.byType(MarkupView), findsNothing);
    expect(toggle, findsNothing);
  }, skip: !available);

  testWidgets('a long Markdown page is read up to the engine\'s limit', (
    tester,
  ) async {
    final file = File('${root.path}/tasks.md')
      ..writeAsStringSync('- [ ] buy milk\n' * 40000);
    expect(file.lengthSync(), lessThan(TextEditorScreen.markdownPreviewLimit));
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await until(tester, find.byType(MarkupView));
    // The view ends with a note saying so (see markup_view_test.dart).
    final view = tester.widget<MarkupView>(find.byType(MarkupView));
    expect(view.document.truncated, isTrue);
    expect(shows('buy milk'), findsWidgets);
  }, skip: !available);

  testWidgets('a JSON mistake in a large file marks its line', (tester) async {
    final rows = [for (var i = 0; i < 30000; i++) '  {"n": $i},'];
    rows[20000] = '  {"n": 20000 x},';
    final file = File('${root.path}/big.json')
      ..writeAsStringSync('[\n${rows.join('\n')}\n  {}\n]\n');
    await tester.pumpWidget(app(TextEditorScreen(path: file.path)));
    await flush(tester);
    expect(find.textContaining('opens read-only'), findsOneWidget);
    await tester.tap(toggle);
    await until(tester, find.byKey(const ValueKey('text-preview-go-to-line')));
    expect(shows('line 20002'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('text-preview-go-to-line')));
    await until(tester, find.text('  {"n": 20000 x},'));
    expect(find.text('  {"n": 20000 x},'), findsOneWidget);
  }, skip: !available);
}
