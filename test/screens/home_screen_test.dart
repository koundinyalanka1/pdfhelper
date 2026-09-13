import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/home_screen.dart';
import 'package:pdfhelper/screens/library_screen.dart';
import 'package:pdfhelper/screens/settings_screen.dart';
import 'package:pdfhelper/screens/tools_screen.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('home_screen_test');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    PdfLibraryService.resetForTesting();
  });

  tearDown(() {
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Widget app({int initialTab = HomeTabs.files}) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: HomeScreen(initialTab: initialTab)),
    );
  }

  /// Alternates real time with frames so the library's file I/O can land.
  Future<void> flush(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  testWidgets('shows the four destinations', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    // One tab per place in the app. Settings is one of them now — it used to
    // be an icon buried in the Files app bar.
    expect(find.text('Files'), findsWidgets);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('starts on Files', (tester) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 20);

    expect(find.byType(LibraryScreen), findsOneWidget);
    // skipOffstage: false — an inactive IndexedStack child is offstage, not
    // absent, so only an offstage-inclusive finder can tell "never built"
    // from "built and parked".
    expect(find.byType(ToolsScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('tapping Tools opens the tool catalogue', (tester) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 20);

    await tester.tap(find.text('Tools'));
    await tester.pump();

    expect(find.byType(ToolsScreen), findsOneWidget);
    expect(find.text('Merge PDFs'), findsOneWidget);
    expect(find.text('Split PDF'), findsOneWidget);
  });

  testWidgets('Settings is reachable in one tap', (tester) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 20);

    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets('a visited tab is kept alive rather than rebuilt', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 20);

    await tester.tap(find.text('Tools'));
    await tester.pump();
    await tester.tap(find.text('Files'));
    await flush(tester);

    // Still in the tree, just not on top: LazyIndexedStack keeps what it has
    // built so a round trip does not throw away in-progress work.
    expect(find.byType(ToolsScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets('back from another tab returns to Files instead of exiting', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 20);

    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(find.text('Appearance'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await flush(tester);

    // Files is on top again, and the app is still running.
    expect(find.text('All PDFs'), findsOneWidget);
  });

  testWidgets('can be launched straight onto a tab', (tester) async {
    await tester.pumpWidget(app(initialTab: HomeTabs.tools));
    await tester.pump();

    expect(find.byType(ToolsScreen), findsOneWidget);
    expect(find.byType(LibraryScreen, skipOffstage: false), findsNothing);
  });
}
