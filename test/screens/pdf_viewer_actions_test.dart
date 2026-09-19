import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_path_provider.dart';

/// The viewer is the app's single "Open with" entry, so its actions menu is
/// the only route from a PDF opened elsewhere to merge, split and the rest.
/// These tests are what stop an entry quietly going missing from it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File pdf;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pdfhelper_viewer');
    FakePathProvider.install(root);
    // The file only has to exist: rendering needs the native core, which a
    // `flutter test` run does not load, so the viewer settles on its error
    // state — with the app bar and its actions fully built.
    pdf = File('${root.path}/Report.pdf')..writeAsBytesSync([0x25, 0x50, 0x44]);
  });

  tearDown(() async {
    FakePathProvider.restore();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Widget app({bool asRoot = true}) {
    final viewer = PdfViewerScreen(pdfPath: pdf.path, title: 'Report.pdf');
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: asRoot
            ? viewer
            // A viewer reached from inside the app has something to go back
            // to; one opened from another app does not.
            : Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    body: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(builder: (_) => viewer),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// Pumps frames without waiting for the tree to go still.
  ///
  /// `pumpAndSettle` never returns here: opening a document hands off to
  /// `Isolate.run`, which a `flutter test` run does not schedule, so the
  /// loading spinner animates forever. The app bar — the part under test — is
  /// built either way.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openSheet(WidgetTester tester, {bool asRoot = true}) async {
    await tester.pumpWidget(app(asRoot: asRoot));
    await settle(tester);
    if (!asRoot) {
      await tester.tap(find.text('open'));
      await settle(tester);
    }
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
  }

  testWidgets('every tool is reachable from the viewer', (tester) async {
    await openSheet(tester);

    for (final label in const [
      'Merge with…',
      'Split',
      'Organize pages',
      'Ask AI',
      'Extract text',
      'Protect',
      'Document details',
      'Open in another app',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is missing');
    }
  });

  testWidgets('a viewer opened from another app offers a way into the app', (
    tester,
  ) async {
    await openSheet(tester);
    expect(find.text('Browse all PDFs'), findsOneWidget);
  });

  testWidgets('a viewer reached from inside the app does not', (tester) async {
    // There is already a back stack, so a second route into the library would
    // be a dead end rather than a way out.
    await openSheet(tester, asRoot: false);
    expect(find.text('Browse all PDFs'), findsNothing);
    expect(find.text('Merge with…'), findsOneWidget);
  });

  testWidgets('share stays a one-tap action, not a menu entry', (tester) async {
    await tester.pumpWidget(app());
    await settle(tester);
    expect(find.byTooltip('Share'), findsOneWidget);
  });
}
