import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/library_screen.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakePathProvider paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_screen_test');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    PdfLibraryService.resetForTesting();
  });

  tearDown(() {
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void seed(String name, {String body = '%PDF-1.7 placeholder bytes'}) {
    File('${paths.documents.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }

  Widget app({int refreshToken = 0}) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: LibraryScreen(refreshToken: refreshToken)),
    );
  }

  /// Alternates real time with frames.
  ///
  /// Actions like delete and rename interleave real file I/O and
  /// SharedPreferences channel round trips with `setState`. Pumping alone
  /// never lets the I/O land; `runAsync` alone never produces a frame — so
  /// the two have to take turns.
  Future<void> flush(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      // Pumped with a duration, not bare: the cover debounce is a real Timer,
      // and only advancing the test clock lets it fire and retire.
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// Taps an item in the per-file actions sheet.
  ///
  /// The sheet lists more actions than fit in the 800x600 test viewport, so
  /// items near the bottom have to be scrolled into view before they can be
  /// hit — tapping blind would silently miss.
  Future<void> tapSheetItem(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// Pumps the screen and lets the real sweep finish.
  ///
  /// `runAsync` is required: the scan hands the directory walk to a background
  /// isolate and reads the cache off disk, neither of which advances under the
  /// test binding's fake clock.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await flush(tester, rounds: 25);
  }

  testWidgets('shows its chrome on the first frame', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('All PDFs'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Starred'), findsOneWidget);
    expect(find.text('Created'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('lists the PDFs it finds', (tester) async {
    seed('Invoice.pdf');
    seed('Contract.pdf');

    await settle(tester);

    // Titles are shown without the extension, the way a reader lists them.
    expect(find.text('Invoice'), findsOneWidget);
    expect(find.text('Contract'), findsOneWidget);
  });

  testWidgets('rescans after a short trip to another app', (tester) async {
    seed('Before.pdf');
    await settle(tester);
    expect(find.text('Before'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    seed('Downloaded.pdf');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester, rounds: 25);

    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
  });

  testWidgets('explains an empty library instead of showing a blank page', (
    tester,
  ) async {
    await settle(tester);

    expect(find.text('No PDFs found on this device yet.'), findsOneWidget);
    expect(find.text('Import a PDF'), findsWidgets);
  });

  testWidgets('pull-to-refresh works on an empty library', (tester) async {
    await settle(tester);
    expect(find.text('No PDFs found on this device yet.'), findsOneWidget);

    // The empty state is shorter than the viewport, so this only works if it
    // opts into always-scrollable physics. Dragging the message itself avoids
    // the horizontal filter bar, which is also a ListView.
    await tester.drag(
      find.text('No PDFs found on this device yet.'),
      const Offset(0, 260),
    );
    await tester.pump();

    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    await flush(tester, rounds: 25);
  });

  testWidgets('search narrows the list', (tester) async {
    seed('Invoice.pdf');
    seed('Contract.pdf');
    await settle(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'invo');
    await tester.pump();

    expect(find.text('Invoice'), findsOneWidget);
    expect(find.text('Contract'), findsNothing);
  });

  testWidgets('closing search restores the full list', (tester) async {
    seed('Invoice.pdf');
    seed('Contract.pdf');
    await settle(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'invo');
    await tester.pump();
    expect(find.text('Contract'), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(find.text('Contract'), findsOneWidget);
    expect(find.text('Invoice'), findsOneWidget);
  });

  testWidgets('a search with no matches says so', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();

    expect(find.textContaining('No PDFs match'), findsOneWidget);
  });

  testWidgets('toggles between grid and list', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pump();

    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListView), findsWidgets);

    // Switching view builds fresh covers, each with a debounce timer; let
    // them retire so the binding does not flag them as leaked.
    await flush(tester);
  });

  testWidgets('the view mode is remembered', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);
    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Rebuild from scratch, as a relaunch would.
    PdfLibraryService.resetForTesting();
    await settle(tester);

    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('Recent is empty until something is opened', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.tap(find.text('Recent'));
    await tester.pump();

    expect(find.text('Documents you open show up here.'), findsOneWidget);
    expect(find.text('Invoice'), findsNothing);
  });

  testWidgets('Recent lists a file that has been opened', (tester) async {
    seed('Invoice.pdf');
    await tester.runAsync(() async {
      await RecentFilesService.markOpened('${paths.documents.path}/Invoice.pdf');
    });

    await settle(tester);
    await tester.tap(find.text('Recent'));
    await tester.pump();

    expect(find.text('Invoice'), findsOneWidget);
  });

  testWidgets('Starred lists only starred files', (tester) async {
    seed('Invoice.pdf');
    seed('Contract.pdf');
    await tester.runAsync(() async {
      await RecentFilesService.toggleStar('${paths.documents.path}/Invoice.pdf');
    });

    await settle(tester);
    await tester.tap(find.text('Starred'));
    await tester.pump();

    expect(find.text('Invoice'), findsOneWidget);
    expect(find.text('Contract'), findsNothing);
  });

  testWidgets('Created lists app-owned files', (tester) async {
    seed('Merged.pdf');

    await settle(tester);
    await tester.tap(find.text('Created'));
    await tester.pump();

    // Everything the fake resolves lives under the app's own directories.
    expect(find.text('Merged'), findsOneWidget);
  });

  testWidgets('offers to widen access when only app files are visible', (
    tester,
  ) async {
    seed('Invoice.pdf');
    await settle(tester);

    // The host is not Android, so the screen reports app-only access and
    // explains the iOS sandbox rather than offering an Android grant.
    expect(
      find.textContaining('Showing documents inside PDF Helper'),
      findsOneWidget,
    );
  });

  testWidgets('sort menu offers every option', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Date modified'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
  });

  testWidgets('sorting by name reorders the list', (tester) async {
    seed('Zebra.pdf');
    seed('Apple.pdf');
    await settle(tester);

    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();

    final apple = tester.getTopLeft(find.text('Apple'));
    final zebra = tester.getTopLeft(find.text('Zebra'));
    expect(apple.dy, lessThan(zebra.dy));
  });

  testWidgets('long-pressing a file opens the actions sheet', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Ask AI'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('the actions sheet hides tab hand-offs when standalone', (
    tester,
  ) async {
    // onSendTo is null here, so "Merge with…" would go nowhere and must not
    // be offered.
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();

    expect(find.text('Merge with…'), findsNothing);
    expect(find.text('Split'), findsNothing);
  });

  testWidgets('starring from the sheet moves the file into Starred', (
    tester,
  ) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();
    await tapSheetItem(tester, 'Star');

    await tester.tap(find.text('Starred'));
    await tester.pump();

    expect(find.text('Invoice'), findsOneWidget);
  });

  testWidgets('deleting removes the file from disk and from the list', (
    tester,
  ) async {
    seed('Invoice.pdf');
    seed('Contract.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();
    await tapSheetItem(tester, 'Delete');

    expect(find.text('Delete file?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await flush(tester);

    expect(
      File('${paths.documents.path}/Invoice.pdf').existsSync(),
      isFalse,
    );
    expect(find.text('Invoice'), findsNothing);
    expect(find.text('Contract'), findsOneWidget);
  });

  testWidgets('cancelling a delete keeps the file', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();
    await tapSheetItem(tester, 'Delete');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(File('${paths.documents.path}/Invoice.pdf').existsSync(), isTrue);
    expect(find.text('Invoice'), findsOneWidget);
  });

  testWidgets('renaming moves the file and keeps it listed', (tester) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();
    await tapSheetItem(tester, 'Rename');

    await tester.enterText(find.byType(TextField).last, 'Paid Invoice');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await flush(tester, rounds: 20);

    expect(
      File('${paths.documents.path}/Paid Invoice.pdf').existsSync(),
      isTrue,
    );
    expect(File('${paths.documents.path}/Invoice.pdf').existsSync(), isFalse);
  });

  testWidgets('revisiting the tab picks up a newly created PDF', (
    tester,
  ) async {
    // The case this covers: the user makes a PDF in Merge or Scan and comes
    // back to Files. An IndexedStack child gets no visibility callback, so
    // HomeScreen bumps refreshToken instead.
    seed('First.pdf');
    await tester.pumpWidget(app());
    await flush(tester, rounds: 25);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing);

    seed('Second.pdf');
    await tester.pumpWidget(app(refreshToken: 1));
    await flush(tester, rounds: 25);

    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('an unchanged refreshToken does not re-sweep', (tester) async {
    seed('First.pdf');
    await tester.pumpWidget(app());
    await flush(tester, rounds: 25);

    seed('Second.pdf');
    await tester.pumpWidget(app());
    await flush(tester, rounds: 10);

    expect(find.text('Second'), findsNothing);
  });

  testWidgets('queues a refresh requested while a scan is in progress', (
    tester,
  ) async {
    seed('First.pdf');
    await settle(tester);
    final gated = _GatedPathProvider(root);
    PathProviderPlatform.instance = gated;

    await tester.pumpWidget(app(refreshToken: 1));
    await flush(tester, rounds: 2);
    expect(gated.documentRequests, 1);

    await tester.pumpWidget(app(refreshToken: 2));
    gated.release.complete();
    await flush(tester, rounds: 25);

    expect(gated.documentRequests, 2);
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('a rename with path separators cannot escape the folder', (
    tester,
  ) async {
    seed('Invoice.pdf');
    await settle(tester);

    await tester.longPress(find.text('Invoice'));
    await tester.pumpAndSettle();
    await tapSheetItem(tester, 'Rename');

    await tester.enterText(find.byType(TextField).last, '../escaped');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await flush(tester, rounds: 20);

    expect(
      File('${root.path}/escaped.pdf').existsSync(),
      isFalse,
      reason: 'the new name must stay inside the original directory',
    );
    expect(
      File('${paths.documents.path}/.._escaped.pdf').existsSync(),
      isTrue,
    );
  });
}

/// Holds the next scan before it obtains its roots so a second refresh can
/// arrive deterministically while that scan is active.
class _GatedPathProvider extends FakePathProvider {
  _GatedPathProvider(super.root);

  final release = Completer<void>();
  int documentRequests = 0;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentRequests++;
    if (documentRequests == 1) await release.future;
    return documents.path;
  }
}
