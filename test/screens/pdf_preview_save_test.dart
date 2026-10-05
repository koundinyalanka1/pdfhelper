import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_preview_screen.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

class _AndroidSettings extends ThemeProvider {
  @override
  bool get usesPublicStorage => true;
}

Future<void> _waitForFailedPreview(WidgetTester tester) async {
  // Native thumbnail work runs outside the fake test clock. Wait for its
  // observable completion instead of assuming an isolate finishes in 250 ms.
  final elapsed = Stopwatch()..start();
  while (find.text('No pages to preview').evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 10)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(find.text('No pages to preview'), findsOneWidget);
  expect(find.textContaining('Could not load PDF preview'), findsOneWidget);
  await _dismissSnackBar(tester);
}

Future<void> _dismissSnackBar(WidgetTester tester) async {
  tester
      .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
      .removeCurrentSnackBar();
  await tester.pumpAndSettle();
  expect(
    find.widgetWithText(ElevatedButton, 'Save').hitTestable(),
    findsOneWidget,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;
  late int exports;
  late int savedCallbacks;
  late bool failExport;
  const channel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'autoSave': false,
      'notifications': false,
    });
    root = Directory.systemTemp.createTempSync('pdfhelper_preview_save');
    FakePathProvider.install(root);
    // Saving and dismissing the result must work even if page thumbnails
    // cannot render. This test exercises the dialog, not the PDF engine.
    pdf = File('${root.path}/Result.pdf')..writeAsStringSync('%PDF-1.7');
    exports = 0;
    savedCallbacks = 0;
    failExport = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStorageInfo') {
        return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
      }
      expect(call.method, 'savePublicPdf');
      exports++;
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

  tearDown(() {
    FakePathProvider.restore();
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  for (final dismissal in ['Back', 'backdrop']) {
    testWidgets('$dismissal from save result restores preview controls', (
      tester,
    ) async {
      PublicPdfSaveService.resetForTesting();
      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => _AndroidSettings(),
          child: MaterialApp(
            home: PdfPreviewScreen(
              filePaths: [pdf.path],
              sourceType: PdfPreviewSourceType.merge,
              onSaved: () => savedCallbacks++,
            ),
          ),
        ),
      );
      await _waitForFailedPreview(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text('Saved to Downloads/PDFHelper (device storage)'),
        findsOneWidget,
      );
      expect(exports, 1);
      expect(savedCallbacks, 1);

      if (dismissal == 'Back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(10, 10));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Save'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Back'))
            .onPressed,
        isNotNull,
      );
      expect(find.byType(BannerAdWidget), findsNothing);
      // A second Save after dismissing the dialog reopens that result without
      // writing another public copy or notifying the operation caller again.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(exports, 1);
      expect(savedCallbacks, 1);
      expect(pdf.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('public export failure keeps source and lets Save retry', (
    tester,
  ) async {
    PublicPdfSaveService.resetForTesting();
    failExport = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => _AndroidSettings(),
        child: MaterialApp(
          home: PdfPreviewScreen(
            filePaths: [pdf.path],
            sourceType: PdfPreviewSourceType.convert,
            onSaved: () => savedCallbacks++,
          ),
        ),
      ),
    );
    await _waitForFailedPreview(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Disk full'), findsOneWidget);
    expect(savedCallbacks, 0);
    expect(pdf.existsSync(), isTrue);
    expect(exports, 1);
    failExport = false;
    await _dismissSnackBar(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(savedCallbacks, 1);
    expect(exports, 2);
    expect(tester.takeException(), isNull);
  });
}
