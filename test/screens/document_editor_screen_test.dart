import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_word_core/flutter_word_core.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/document_editor_screen.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/draft_service.dart';
import 'package:pdfhelper/services/editor_draft.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:pdfhelper/widgets/word/para_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The document screen, driven through the real word-processing engine:
///   eval "$(bash scripts/build_libs.sh env)"
///   flutter test test/screens/document_editor_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_document_editor');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    // A save records the file in Recent; a record left waiting by an
    // earlier test would hold this test's saves up behind it.
    RecentFilesService.resetCacheForTesting();
    DocumentSaveService.publishOverride = false;
    EditorDraft.serviceOverride = DraftService(
      directory: Directory('${root.path}/Drafts'),
    );
  });

  tearDown(() {
    EditorDraft.serviceOverride = null;
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

  final available = WordCore.isAvailable;

  Future<String> makeLetter() async {
    final path = '${root.path}/letter.docx';
    final doc = WordCore.create();
    final p = doc.blocks(0, 1).first as ParaBlock;
    doc.setParagraphs(p.id, p.id, [
      NewParagraph([TextEdit('Dear Sir,', p.style.mark)]),
      NewParagraph([TextEdit('Hello world', p.style.mark)]),
    ]);
    await doc.save(path);
    doc.close();
    return path;
  }

  Future<List<String>> paragraphsOf(String path) async {
    final doc = await WordCore.open(path);
    final out = [
      for (final b in doc.blocks(0, 100))
        if (b is ParaBlock) b.text,
    ];
    doc.close();
    return out;
  }

  ParaController editor(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!
          as ParaController;

  testWidgets('says why when the file cannot be opened', (tester) async {
    await tester.pumpWidget(
      app(DocumentEditorScreen(path: '${root.path}/missing.docx')),
    );
    await flush(tester);
    expect(find.text('Could not open missing.docx'), findsOneWidget);
  }, skip: !available);

  testWidgets('unsaved changes are offered back; Discard drops them', (
    tester,
  ) async {
    late String path;
    await tester.runAsync(() async => path = await makeLetter());
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);

    final hello = find.textContaining('Hello world', findRichText: true);
    await tester.tap(hello);
    await tester.pump();
    editor(tester)
      ..select(11)
      ..insertText(' again');
    // The paragraph is written to the document, then the recovery copy.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 4));
    await flush(tester, rounds: 30);

    await tester.pumpWidget(const SizedBox());
    await flush(tester, rounds: 4);
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await until(tester, find.text('Restore unsaved changes?'));
    await tester.tap(find.text('Restore'));
    await until(tester, find.text('DOCX · Edited'));
    expect(
      find.textContaining('Hello world again', findRichText: true),
      findsOneWidget,
    );
    // The file itself is untouched until Save.
    late List<String> paras;
    await tester.runAsync(() async => paras = await paragraphsOf(path));
    expect(paras, ['Dear Sir,', 'Hello world']);

    // Leave and discard: nothing is offered next time.
    await tester.binding.handlePopRoute();
    await until(tester, find.text('Discard'));
    await tester.tap(find.text('Discard'));
    await flush(tester, rounds: 20);
    await tester.pumpWidget(const SizedBox());
    await flush(tester, rounds: 4);
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester, rounds: 20);
    expect(find.text('Restore unsaved changes?'), findsNothing);
    expect(
      find.textContaining('Hello world', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('DOCX'), findsOneWidget);
  }, skip: !available);

  testWidgets('edits a paragraph, splits it with Enter and saves', (
    tester,
  ) async {
    late String path;
    await tester.runAsync(() async => path = await makeLetter());
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);

    expect(find.text('DOCX'), findsOneWidget);
    final hello = find.textContaining('Hello world', findRichText: true);
    expect(hello, findsOneWidget);
    await tester.tap(hello);
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(editor(tester).plain, 'Hello world');

    // Type at the end, then press Enter in the middle.
    final c = editor(tester);
    c.select(11);
    c.insertText('!');
    expect(c.plain, 'Hello world!');
    c.select(5);
    c.insertText('\n');
    await flush(tester, rounds: 4);
    expect(editor(tester).plain, ' world!');
    expect(editor(tester).modelSelection.start, 0);

    // Bold the new paragraph's first word.
    editor(tester).select(1, 6);
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();
    expect(find.text('DOCX · Edited'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await flush(tester);
    expect(find.text('DOCX'), findsOneWidget);

    late List<String> paras;
    await tester.runAsync(() async => paras = await paragraphsOf(path));
    expect(paras, ['Dear Sir,', 'Hello', ' world!']);
    late bool bold;
    await tester.runAsync(() async {
      final doc = await WordCore.open(path);
      final p = doc.blocks(0, 10)[2] as ParaBlock;
      bold = (p.inlines[1] as TextInline).style.bold;
      doc.close();
    });
    expect(bold, isTrue);
  }, skip: !available);

  testWidgets(
    'backspace at the start joins paragraphs; undo splits them again',
    (tester) async {
      late String path;
      await tester.runAsync(() async => path = await makeLetter());
      await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
      await flush(tester);

      await tester.tap(find.textContaining('Hello world', findRichText: true));
      await tester.pump();
      final c = editor(tester);
      c.select(0);
      // A soft keyboard's backspace deletes the character before the cursor.
      final v = c.value;
      c.value = TextEditingValue(
        text: v.text.substring(1),
        selection: const TextSelection.collapsed(offset: 0),
      );
      await flush(tester, rounds: 4);
      expect(editor(tester).plain, 'Dear Sir,Hello world');
      expect(editor(tester).modelSelection.start, 9);

      await tester.tap(find.byTooltip('Undo'));
      await flush(tester, rounds: 4);
      expect(
        find.textContaining('Hello world', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Dear Sir,', findRichText: true),
        findsOneWidget,
      );
    },
    skip: !available,
  );

  testWidgets('a new document starts editing its first paragraph', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(DocumentEditorScreen(path: '${root.path}/new.docx', isNew: true)),
    );
    await flush(tester);
    expect(find.byType(TextField), findsOneWidget);
    editor(tester).insertText('Shopping list');
    await tester.tap(find.byTooltip('Bullets'));
    await flush(tester, rounds: 4);
    await tester.tap(find.text('Save'));
    await flush(tester);
    late List<String> paras;
    await tester.runAsync(
      () async => paras = await paragraphsOf('${root.path}/new.docx'),
    );
    expect(paras, ['Shopping list']);
  }, skip: !available);

  testWidgets('an RTF file is edited and saved as a Word document', (
    tester,
  ) async {
    final path = '${root.path}/memo.rtf';
    File(path).writeAsStringSync(
      r'{\rtf1\ansi{\fonttbl{\f0 Arial;}}\pard Hello from {\b RTF}\par}',
    );
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('RTF'), findsOneWidget);
    expect(
      find.text('This file will be saved as a Word document (.docx).'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Hello from', findRichText: true));
    await tester.pump();
    editor(tester).insertText('!');
    await tester.pump();
    expect(find.text('RTF · Edited'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await flush(tester);
    final saved = File('${root.path}/documents/Edited/memo.docx');
    expect(
      saved.existsSync(),
      isTrue,
      reason: Directory(root.path).listSync(recursive: true).join('\n'),
    );
    late List<String> paras;
    await tester.runAsync(() async => paras = await paragraphsOf(saved.path));
    expect(paras, ['Hello from RTF!']);
    // The original is left as it was.
    expect(File(path).readAsStringSync(), contains('Hello from'));
  }, skip: !available);

  testWidgets('a Word 97-2003 document is read and saved as a new .docx', (
    tester,
  ) async {
    // Made by LibreOffice from a letter with a bold phrase and a table.
    final path = '${root.path}/letter.doc';
    File('test/fixtures/letter.doc').copySync(path);
    final original = File(path).readAsBytesSync();
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('DOC'), findsOneWidget);
    expect(
      find.text('This file will be saved as a Word document (.docx).'),
      findsOneWidget,
    );
    expect(find.text('Rent'), findsOneWidget);
    await tester.tap(find.textContaining('Yours faithfully', findRichText: true));
    await tester.pump();
    editor(tester).insertText(',');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await flush(tester);
    final saved = File('${root.path}/documents/Edited/letter.docx');
    expect(saved.existsSync(), isTrue);
    late List<String> paras;
    await tester.runAsync(() async => paras = await paragraphsOf(saved.path));
    expect(paras.first, 'Dear Sir, please find the figures below.');
    expect(paras.last, 'Yours faithfully,');
    // The original is left as it was.
    expect(File(path).readAsBytesSync(), original);
  }, skip: !available);

  testWidgets('a flat OpenDocument text is saved as a new .odt', (
    tester,
  ) async {
    final path = '${root.path}/minutes.fodt';
    File(path).writeAsStringSync(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<office:document '
      'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
      'office:version="1.3" '
      'office:mimetype="application/vnd.oasis.opendocument.text">'
      '<office:body><office:text><text:p>Hello flat</text:p></office:text>'
      '</office:body></office:document>\n',
    );
    final original = File(path).readAsBytesSync();
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('FODT'), findsOneWidget);
    expect(
      find.text(
        'This file will be saved as an OpenDocument text file (.odt).',
      ),
      findsOneWidget,
    );

    // Save a copy offers the format saving writes.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save a copy as…'));
    await tester.pumpAndSettle();
    expect(find.text('OpenDocument text (.odt)'), findsOneWidget);
    expect(find.text('Word document (.docx)'), findsNothing);
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Hello flat', findRichText: true));
    await tester.pump();
    final c = editor(tester);
    c.select(c.plain.length);
    c.insertText('!');
    await tester.pump();
    expect(find.text('FODT · Edited'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    // The button shows again once the save has finished.
    await until(tester, find.text('Save'));

    final edited = Directory('${root.path}/documents/Edited');
    final saved = File('${edited.path}/minutes.odt');
    expect(
      saved.existsSync(),
      isTrue,
      reason: Directory(root.path).listSync(recursive: true).join('\n'),
    );
    late List<String> paras;
    late String format;
    await tester.runAsync(() async {
      paras = await paragraphsOf(saved.path);
      final doc = await WordCore.open(saved.path);
      format = doc.info().format;
      doc.close();
    });
    expect(format, 'odt');
    expect(paras, ['Hello flat!']);
    // The flat original is left exactly as it was.
    expect(File(path).readAsBytesSync(), original);

    // A second save goes to the same copy.
    await tester.tap(find.textContaining('Hello flat', findRichText: true));
    await tester.pump();
    final again = editor(tester);
    again.select(again.plain.length);
    again.insertText('!');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await until(tester, find.text('Save'));
    expect(
      edited.listSync().map((e) => e.uri.pathSegments.last).toList(),
      ['minutes.odt'],
    );
    await tester.runAsync(() async => paras = await paragraphsOf(saved.path));
    expect(paras, ['Hello flat!!']);
    expect(File(path).readAsBytesSync(), original);
  }, skip: !available);

  testWidgets('shows the document laid out on pages', (tester) async {
    final path = (await tester.runAsync(makeLetter))!;
    await tester.pumpWidget(app(DocumentEditorScreen(path: path)));
    await flush(tester);
    await tester.tap(find.byTooltip('More'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Page view'));
    await flush(tester, rounds: 30);
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.textContaining('page view'), findsWidgets);
  }, skip: !available);
}
