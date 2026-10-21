import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/backups_screen.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/services/draft_service.dart';
import 'package:pdfhelper/services/editor_draft.dart';
import 'package:pdfhelper/services/engine_backups.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakePathProvider paths;
  late Directory backups;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_backups');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    EditorDraft.serviceOverride = DraftService(
      directory: Directory('${root.path}/Drafts'),
    );
    backups = Directory('${paths.support.path}/Backups')..createSync();
    File('${backups.path}/report.docx')
      ..writeAsBytesSync([0x50, 0x4b, 3, 4])
      ..setLastModifiedSync(DateTime(2026, 1, 2, 9, 30));
    File('${backups.path}/notes.txt')
      ..writeAsStringSync('the old notes')
      ..setLastModifiedSync(DateTime(2026, 3, 4, 18, 5));
    // Half-written backups are hidden and never listed.
    File('${backups.path}/.notes.txt.1-2-3.tmp').writeAsStringSync('partial');
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

  Future<void> flush(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  test('lists backups newest first, leaving out hidden files', () async {
    final found = await EngineBackups.list();
    expect(found.map((b) => b.name), ['notes.txt', 'report.docx']);
    expect(found.first.size, 'the old notes'.length);
  });

  test('a missing folder lists nothing', () async {
    backups.deleteSync(recursive: true);
    expect(await EngineBackups.list(), isEmpty);
  });

  testWidgets('shows each backup with when it was replaced', (tester) async {
    await tester.pumpWidget(app(const BackupsScreen()));
    await flush(tester);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('report.docx'), findsOneWidget);
    expect(find.textContaining('2026-03-04 18:05'), findsOneWidget);
    expect(find.textContaining('.tmp'), findsNothing);
    expect(find.byTooltip('Share notes.txt'), findsOneWidget);
  });

  testWidgets('says so when there are none', (tester) async {
    backups.deleteSync(recursive: true);
    await tester.pumpWidget(app(const BackupsScreen()));
    await flush(tester);
    expect(find.text('No backups yet.'), findsOneWidget);
  });

  testWidgets(
    'opening a backup works on a copy and leaves the backup as it was',
    (tester) async {
      // A copy already there keeps its name; the new one gets a number.
      File(
        '${paths.documents.path}/notes (backup).txt',
      ).writeAsStringSync('someone else');
      await tester.pumpWidget(app(const BackupsScreen()));
      await flush(tester);
      await tester.tap(find.text('notes.txt'));
      await flush(tester, rounds: 20);

      final copy = File('${paths.documents.path}/notes (backup 2).txt');
      expect(copy.readAsStringSync(), 'the old notes');
      expect(
        File('${paths.documents.path}/notes (backup).txt').readAsStringSync(),
        'someone else',
      );
      expect(
        File('${backups.path}/notes.txt').readAsStringSync(),
        'the old notes',
      );
      expect(find.byType(TextEditorScreen), findsOneWidget);
    },
    skip: !TextCore.isAvailable,
  );
}
