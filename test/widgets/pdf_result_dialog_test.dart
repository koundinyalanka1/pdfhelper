import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/services/ads_service.dart';
import 'package:pdfhelper/widgets/pdf_result_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late bool callerReturned;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_result');
    FakePathProvider.install(root);
    callerReturned = false;
  });

  tearDown(() async {
    FakePathProvider.restore();
    await root.delete(recursive: true);
  });

  Widget app() => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: Builder(
        builder: (homeContext) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(homeContext).push<void>(
              MaterialPageRoute(
                builder: (toolContext) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      await showPdfResultDialog(
                        context: toolContext,
                        filePaths: ['${root.path}/Result.pdf'],
                        message: 'Document created successfully.',
                        operation: PdfOperation.organize,
                      );
                      callerReturned = true;
                      // Protect, metadata and organize all finish their route
                      // this way after the result action completes.
                      if (toolContext.mounted) Navigator.pop(toolContext);
                    },
                    child: const Text('Finish operation'),
                  ),
                ),
              ),
            ),
            child: const Text('Open tool'),
          ),
        ),
      ),
    ),
  );

  Future<void> openResult(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open tool'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish operation'));
    await tester.pumpAndSettle();
    expect(find.text('Success!'), findsOneWidget);
  }

  testWidgets('Open keeps result viewer open until Back before tool returns', (
    tester,
  ) async {
    final previousCompletions = AdsService.instance.completedOperationCount;
    await openResult(tester);
    expect(AdsService.instance.completedOperationCount, previousCompletions + 1);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.text('Result.pdf'), findsOneWidget);
    expect(callerReturned, false);
    expect(AdsService.instance.completedOperationCount, previousCompletions + 1);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(callerReturned, true);
    expect(find.byType(PdfViewerScreen), findsNothing);
    expect(find.text('Open tool'), findsOneWidget);
    expect(find.text('Finish operation'), findsNothing);
    expect(AdsService.instance.completedOperationCount, previousCompletions + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Close returns directly to the tool caller', (tester) async {
    await openResult(tester);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(callerReturned, true);
    expect(find.text('Open tool'), findsOneWidget);
    expect(find.byType(PdfViewerScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
