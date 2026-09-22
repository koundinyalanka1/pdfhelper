import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/merge_pdf_screen.dart';
import 'package:pdfhelper/screens/split_pdf_screen.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:pdfhelper/widgets/recent_pdfs_strip.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The strip is only worth anything if it actually reaches the two screens it
/// was built for, wired to the thing that consumes a file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakePathProvider paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('merge_split_recent_test');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    PdfLibraryService.resetForTesting();
  });

  tearDown(() {
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<String> seedRecent(WidgetTester tester, String name) async {
    final file = File('${paths.documents.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('%PDF-1.7 placeholder bytes');
    await tester.runAsync(() => RecentFilesService.markOpened(file.path));
    return file.path;
  }

  Future<void> flush(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Widget wrap(Widget child) => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: child),
  );

  testWidgets('Merge offers a recent document', (tester) async {
    await seedRecent(tester, 'Contract.pdf');

    await tester.pumpWidget(wrap(const MergePdfScreen()));
    await flush(tester);

    expect(find.byType(RecentPdfsStrip), findsOneWidget);
    expect(find.text('Contract'), findsOneWidget);
  });

  testWidgets('tapping a recent in Merge adds it and stops offering it',
      (tester) async {
    await seedRecent(tester, 'Contract.pdf');
    await seedRecent(tester, 'Appendix.pdf');

    await tester.pumpWidget(wrap(const MergePdfScreen()));
    await flush(tester);
    expect(find.text('Contract'), findsOneWidget);

    await tester.tap(find.text('Contract'));
    await flush(tester);

    // Now in the batch, so the strip must not offer it a second time —
    // merging the same file twice is a mistake, not a feature.
    expect(find.text('Contract'), findsNothing);
    // The other one is still on offer, because merging wants more than one.
    expect(find.text('Appendix'), findsOneWidget);
  });

  testWidgets('Split offers a recent document', (tester) async {
    await seedRecent(tester, 'Manual.pdf');

    await tester.pumpWidget(wrap(const SplitPdfScreen()));
    await flush(tester);

    expect(find.byType(RecentPdfsStrip), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
  });
}
