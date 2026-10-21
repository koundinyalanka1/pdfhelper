import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:flutter_word_core/flutter_word_core.dart';
import 'package:pdfhelper/screens/document_editor_screen.dart';
import 'package:pdfhelper/screens/sheet_editor_screen.dart';
import 'package:pdfhelper/screens/slide_editor_screen.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/services/draft_service.dart';
import 'package:pdfhelper/services/editor_draft.dart';

import 'guidelines.dart';

/// The four editors at every phone width, text size and theme: nothing
/// overflows, and every control, including the drawn document areas (the
/// sheet grid, the slide, the space after the last paragraph), meets the
/// tap target, label and contrast guidelines.
void main() {
  useEmptyAppFolders();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('a11y_editors');
    EditorDraft.serviceOverride = DraftService(
      directory: Directory('${dir.path}/Drafts'),
    );
  });

  tearDown(() {
    EditorDraft.serviceOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Wait for the engine's isolate to open the file.
  Future<void> open(WidgetTester tester) => settle(tester, rounds: 25);

  for (final setup in phoneSetups) {
    testWidgets('the text editor meets the guidelines at $setup', (
      tester,
    ) async {
      final file = File('${dir.path}/notes.txt')
        ..writeAsStringSync('Rs. 100 paid\nRs. 50 due\n');
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(TextEditorScreen(path: file.path)));
      await open(tester);
      expect(find.textContaining('UTF-8'), findsWidgets);
      await expectGuidelinesMet(tester);
    }, skip: !TextCore.isAvailable);

    testWidgets('the spreadsheet editor meets the guidelines at $setup', (
      tester,
    ) async {
      final path = '${dir.path}/accounts.xlsx';
      await tester.runAsync(() async {
        final book = SheetCore.create();
        book.setCell(0, 0, 0, 'Rice');
        book.setCell(0, 0, 1, '10');
        await book.save(path, SheetFormat.xlsx);
        book.close();
      });
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(SheetEditorScreen(path: path)));
      await open(tester);
      expect(find.text('A1'), findsOneWidget);
      await expectGuidelinesMet(tester);
    }, skip: !SheetCore.isAvailable);

    testWidgets('the document editor meets the guidelines at $setup', (
      tester,
    ) async {
      final path = '${dir.path}/letter.docx';
      await tester.runAsync(() async {
        final doc = WordCore.create();
        final p = doc.blocks(0, 1).first as ParaBlock;
        doc.setParagraphs(p.id, p.id, [
          NewParagraph([TextEdit('Dear Sir,', p.style.mark)]),
        ]);
        await doc.save(path);
        doc.close();
      });
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(DocumentEditorScreen(path: path)));
      await open(tester);
      expect(find.text('DOCX'), findsOneWidget);
      await expectGuidelinesMet(tester);
    }, skip: !WordCore.isAvailable);

    testWidgets('the document editor while typing meets the guidelines at '
        '$setup', (tester) async {
      final path = '${dir.path}/letter.docx';
      await tester.runAsync(() async {
        final doc = WordCore.create();
        final p = doc.blocks(0, 1).first as ParaBlock;
        doc.setParagraphs(p.id, p.id, [
          NewParagraph([TextEdit('Dear Sir,', p.style.mark)]),
        ]);
        await doc.save(path);
        doc.close();
      });
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(DocumentEditorScreen(path: path)));
      await open(tester);
      await tester.tap(find.textContaining('Dear Sir', findRichText: true));
      await open(tester);
      // The formatting toolbar, with its style and size pickers, is up.
      expect(find.byType(EditableText), findsOneWidget);
      await expectGuidelinesMet(tester);
    }, skip: !WordCore.isAvailable);

    testWidgets('the slides editor meets the guidelines at $setup', (
      tester,
    ) async {
      final path = '${dir.path}/talk.pptx';
      await tester.runAsync(() async {
        final deck = SlideCore.create();
        await deck.save(path);
        deck.close();
      });
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(SlideEditorScreen(path: path)));
      await open(tester);
      expect(find.textContaining('PPTX'), findsWidgets);
      await expectGuidelinesMet(tester);
    }, skip: !SlideCore.isAvailable);
  }
}
