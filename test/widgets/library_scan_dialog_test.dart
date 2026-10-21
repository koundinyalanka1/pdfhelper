import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/services/library_service.dart';
import 'package:pdfhelper/widgets/library_scan_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first sweep after a storage grant is shown in this dialog. These tests
/// hold it to showing real progress, ending on a clear outcome, and never
/// trapping the user behind a search they would rather not watch.
void main() {
  late ValueNotifier<LibraryScanProgress?> progress;
  late Completer<int?> found;
  late bool closed;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    progress = ValueNotifier(null);
    closed = false;
  });

  tearDown(() => progress.dispose());

  Widget host() {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await showLibraryScanDialog(
                  context,
                  found: found.future,
                  progress: progress,
                );
                closed = true;
              },
              child: const Text('scan'),
            ),
          ),
        ),
      ),
    );
  }

  /// The searching state animates an indeterminate bar forever, so it can
  /// only be pumped by time, never settled.
  Future<void> open(WidgetTester tester) async {
    // Created inside the test body, not in setUp: a future from outside the
    // fake-async zone delivers its result on the real event loop, which
    // pumping never reaches.
    found = Completer<int?>();
    await tester.pumpWidget(host());
    await tester.tap(find.text('scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows live counts while searching', (tester) async {
    await open(tester);
    expect(find.text('Finding your documents'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    progress.value = const LibraryScanProgress(folders: 1204, documents: 128);
    await tester.pump();

    expect(find.text('128'), findsOneWidget);
    expect(find.text('documents found'), findsOneWidget);
    expect(find.text('1,204 folders searched'), findsOneWidget);
    expect(find.text('Run in background'), findsOneWidget);
  });

  testWidgets('keeps the last count when the walk clears its progress', (
    tester,
  ) async {
    await open(tester);
    progress.value = const LibraryScanProgress(folders: 40, documents: 7);
    await tester.pump();

    // The service clears progress the moment the walk ends, before the
    // screen has the result. The count must not fall back to zero.
    progress.value = null;
    await tester.pump();

    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('ends on the number found, then closes', (tester) async {
    await open(tester);
    progress.value = const LibraryScanProgress(folders: 900, documents: 340);
    await tester.pump();

    found.complete(1342);
    await tester.pumpAndSettle();

    expect(find.text('Search complete'), findsOneWidget);
    expect(find.text('1,342'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('folders searched'), findsNothing);

    await tester.tap(find.text('View files'));
    await tester.pumpAndSettle();

    expect(find.text('Search complete'), findsNothing);
    expect(closed, isTrue);
  });

  testWidgets('says so when nothing is found', (tester) async {
    await open(tester);

    found.complete(0);
    await tester.pumpAndSettle();

    expect(find.text('No documents found'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('reports a search that could not finish', (tester) async {
    await open(tester);

    found.complete(null);
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t finish searching'), findsOneWidget);
    expect(find.textContaining('Pull down'), findsOneWidget);
  });

  testWidgets('can be sent to the background mid-search', (tester) async {
    await open(tester);

    await tester.tap(find.text('Run in background'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Finding your documents'), findsNothing);
    expect(closed, isTrue);
    expect(found.isCompleted, isFalse);
  });

  testWidgets('a stray tap outside does not hide the search', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(8, 8));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Finding your documents'), findsOneWidget);
    expect(closed, isFalse);
  });
}
