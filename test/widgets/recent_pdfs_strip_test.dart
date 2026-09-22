import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:pdfhelper/widgets/recent_pdfs_strip.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Merge and Split used to offer only the system file browser, which meant
/// leaving the app to find a document the app had just had open. The strip is
/// the shortcut; these tests hold it to the things that make it trustworthy —
/// it only offers files that still exist, never offers one already chosen,
/// and takes up no room when it has nothing to say.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakePathProvider paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('recent_strip_test');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    PdfLibraryService.resetForTesting();
  });

  tearDown(() {
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String seed(String name) {
    final file = File('${paths.documents.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('%PDF-1.7 placeholder bytes');
    return file.path;
  }

  Future<void> markOpened(WidgetTester tester, List<String> paths) async {
    await tester.runAsync(() async {
      for (final path in paths) {
        await RecentFilesService.markOpened(path);
      }
    });
  }

  Widget host({
    ValueChanged<String>? onSelected,
    Set<String> exclude = const {},
  }) => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: Scaffold(
        body: RecentPdfsStrip(
          onSelected: onSelected ?? (_) {},
          excludePaths: exclude,
        ),
      ),
    ),
  );

  /// Alternates real time with frames.
  ///
  /// The strip stats each recent file to find out whether it still exists,
  /// which is real I/O: pumping alone never lets it land, and `runAsync`
  /// alone never produces a frame — so the two have to take turns.
  Future<void> flush(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('offers nothing when there are no recents', (tester) async {
    await tester.pumpWidget(host());
    await flush(tester);

    expect(find.text('Recent'), findsNothing);
    // It must occupy no space, or both screens would show an empty heading.
    expect(tester.getSize(find.byType(RecentPdfsStrip)).height, 0);
  });

  testWidgets('lists recently opened documents, newest first', (tester) async {
    final older = seed('Older.pdf');
    final newer = seed('Newer.pdf');
    await markOpened(tester, [older, newer]);

    await tester.pumpWidget(host());
    await flush(tester);

    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    expect(find.text('Newer'), findsOneWidget);

    // Most recently opened leads.
    expect(
      tester.getTopLeft(find.text('Newer')).dx,
      lessThan(tester.getTopLeft(find.text('Older')).dx),
    );
  });

  testWidgets('tapping a document reports its path', (tester) async {
    final path = seed('Invoice.pdf');
    await markOpened(tester, [path]);

    String? chosen;
    await tester.pumpWidget(host(onSelected: (p) => chosen = p));
    await flush(tester);

    await tester.tap(find.text('Invoice'));
    await tester.pump();

    expect(chosen, path);
  });

  testWidgets('a document already chosen is not offered again',
      (tester) async {
    final kept = seed('Kept.pdf');
    final taken = seed('Taken.pdf');
    await markOpened(tester, [kept, taken]);

    await tester.pumpWidget(host(exclude: {taken}));
    await flush(tester);

    expect(find.text('Kept'), findsOneWidget);
    expect(find.text('Taken'), findsNothing);
  });

  testWidgets('a file deleted since it was opened is dropped', (tester) async {
    final alive = seed('Alive.pdf');
    final deleted = seed('Deleted.pdf');
    await markOpened(tester, [alive, deleted]);
    File(deleted).deleteSync();

    await tester.pumpWidget(host());
    await flush(tester);

    expect(find.text('Alive'), findsOneWidget);
    expect(find.text('Deleted'), findsNothing);
  });

  testWidgets('excluding every recent collapses the strip', (tester) async {
    final only = seed('Only.pdf');
    await markOpened(tester, [only]);

    await tester.pumpWidget(host(exclude: {only}));
    await flush(tester);

    expect(find.text('Recent'), findsNothing);
    expect(tester.getSize(find.byType(RecentPdfsStrip)).height, 0);
  });

  testWidgets('the name is shown without its .pdf extension', (tester) async {
    final path = seed('Quarterly Report.pdf');
    await markOpened(tester, [path]);

    await tester.pumpWidget(host());
    await flush(tester);

    expect(find.text('Quarterly Report'), findsOneWidget);
    expect(find.text('Quarterly Report.pdf'), findsNothing);
  });
}
