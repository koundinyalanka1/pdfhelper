import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/services/ads_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:pdfhelper/widgets/pdf_result_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

class _AndroidSettings extends ThemeProvider {
  @override
  bool get usesPublicStorage => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late bool callerReturned;
  late int publicExports;
  late bool failExport;
  Object? saveError;
  const storageChannel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_result');
    FakePathProvider.install(root);
    callerReturned = false;
    publicExports = 0;
    failExport = false;
    saveError = null;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'getStorageInfo') {
        return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
      }
      expect(call.method, 'savePublicPdf');
      publicExports++;
      if (failExport) {
        throw PlatformException(
          code: 'PUBLIC_SAVE_FAILED',
          message: 'Disk full',
        );
      }
      return {
        'uri': 'content://media/external_primary/downloads/42',
        'publicPath': '/storage/emulated/0/Download/PDFHelper/Result.pdf',
      };
    });
  });

  tearDown(() async {
    FakePathProvider.restore();
    messenger.setMockMethodCallHandler(storageChannel, null);
    await root.delete(recursive: true);
  });

  Widget app({
    bool android = false,
    List<String>? savedPaths,
  }) => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => android ? _AndroidSettings() : ThemeProvider(),
    child: MaterialApp(
      home: Builder(
        builder: (homeContext) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(homeContext).push<void>(
              MaterialPageRoute(
                builder: (toolContext) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      try {
                        await showPdfResultDialog(
                          context: toolContext,
                          filePaths: ['${root.path}/Result.pdf'],
                          message: 'Document created successfully.',
                          operation: PdfOperation.organize,
                          autoSavedPaths: savedPaths,
                        );
                        callerReturned = true;
                        // Protect, metadata and organize all finish their route
                        // this way after the result action completes.
                        if (toolContext.mounted) Navigator.pop(toolContext);
                      } catch (error) {
                        saveError = error;
                      }
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
    expect(
      AdsService.instance.completedOperationCount,
      previousCompletions + 1,
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.text('Result.pdf'), findsOneWidget);
    expect(callerReturned, false);
    expect(
      AdsService.instance.completedOperationCount,
      previousCompletions + 1,
    );

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(callerReturned, true);
    expect(find.byType(PdfViewerScreen), findsNothing);
    expect(find.text('Open tool'), findsOneWidget);
    expect(find.text('Finish operation'), findsNothing);
    expect(
      AdsService.instance.completedOperationCount,
      previousCompletions + 1,
    );
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

  testWidgets('Android publishes before showing success', (tester) async {
    PublicPdfSaveService.resetForTesting();
    await tester.pumpWidget(app(android: true));
    await tester.tap(find.text('Open tool'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish operation'));
    await tester.pumpAndSettle();
    expect(publicExports, 1);
    expect(
      find.text('Saved to Downloads/PDFHelper (device storage)'),
      findsOneWidget,
    );
    expect(saveError, isNull);
  });

  testWidgets('already saved split outputs are not published a second time', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(android: true, savedPaths: ['${root.path}/Result.pdf']),
    );
    await tester.tap(find.text('Open tool'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish operation'));
    await tester.pumpAndSettle();
    expect(publicExports, 0);
    expect(
      find.text('Saved to Downloads/PDFHelper (device storage)'),
      findsOneWidget,
    );
    expect(saveError, isNull);
  });

  testWidgets('export failure cannot show success or count an ad operation', (
    tester,
  ) async {
    PublicPdfSaveService.resetForTesting();
    failExport = true;
    final before = AdsService.instance.completedOperationCount;
    await tester.pumpWidget(app(android: true));
    await tester.tap(find.text('Open tool'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish operation'));
    await tester.pumpAndSettle();
    expect(saveError, isA<PublicPdfSaveException>());
    expect(AdsService.instance.completedOperationCount, before);
    expect(find.byType(AlertDialog), findsNothing);
    expect(callerReturned, isFalse);
    expect(tester.takeException(), isNull);
  });
}
