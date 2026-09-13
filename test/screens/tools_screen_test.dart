import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/home_tabs.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/tools_screen.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<(DocHandoff, String?)> sent;
  late List<int> tabs;

  setUp(() {
    sent = [];
    tabs = [];
  });

  Widget app({bool wired = true}) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: ToolsScreen(
          onSendTo: wired ? (action, path) => sent.add((action, path)) : null,
          onGoToTab: wired ? tabs.add : null,
        ),
      ),
    );
  }

  /// Pumps the screen into a viewport tall enough to build the whole
  /// catalogue at once.
  ///
  /// A ListView only builds what is near the viewport, so an off-screen tool
  /// is not merely invisible — it does not exist to a finder. Giving the test
  /// room to render everything is what makes "is every tool still here?" a
  /// question the test can actually answer.
  Future<void> pumpTall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pump();
  }

  /// Scrolls a tool into view and taps it.
  ///
  /// The catalogue is taller than the 800x600 test viewport, so the lower
  /// sections have to be brought on screen before they can be hit.
  Future<void> tapTool(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every tool without a document being chosen first', (
    tester,
  ) async {
    // The point of the redesign: the catalogue is the screen, not a reward
    // for having already picked a file.
    await pumpTall(tester);

    for (final tool in [
      'Scan to PDF',
      'Merge PDFs',
      'Split PDF',
      'Organize pages',
      'Document details',
      'Protect with a password',
      'Open in viewer',
      'Extract text',
      'Ask AI',
      'AI models',
    ]) {
      expect(find.text(tool), findsOneWidget, reason: '$tool is missing');
    }
  });

  testWidgets('groups the tools under headings', (tester) async {
    await pumpTall(tester);

    for (final section in [
      'Create',
      'Combine & split',
      'Edit document',
      'Read & extract',
      'On-device AI',
    ]) {
      expect(find.text(section), findsOneWidget);
    }
  });

  testWidgets('invites the user to choose a working document', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Choose a PDF'), findsOneWidget);
  });

  testWidgets('Merge hands off with no document selected', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tapTool(tester, 'Merge PDFs');

    // Null, not a silent no-op: merge picks its own files.
    expect(sent, [(DocHandoff.merge, null)]);
  });

  testWidgets('Split hands off', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tapTool(tester, 'Split PDF');

    expect(sent, [(DocHandoff.split, null)]);
  });

  testWidgets('Scan to PDF switches to the Scan tab', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tapTool(tester, 'Scan to PDF');

    expect(tabs, [HomeTabs.scan]);
  });

  testWidgets('Scan to PDF is disabled when there is no tab bar to drive', (
    tester,
  ) async {
    await tester.pumpWidget(app(wired: false));
    await tester.pump();
    await tapTool(tester, 'Scan to PDF');

    expect(tabs, isEmpty);
  });
}
