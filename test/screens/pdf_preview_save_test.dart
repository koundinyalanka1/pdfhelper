import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_preview_screen.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;

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
  });

  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  for (final dismissal in ['Back', 'backdrop']) {
    testWidgets('$dismissal from save result restores preview controls', (
      tester,
    ) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(),
          child: MaterialApp(
            home: PdfPreviewScreen(
              filePaths: [pdf.path],
              sourceType: PdfPreviewSourceType.merge,
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      // The intentionally unreadable thumbnail shows a temporary snackbar
      // over the bottom controls. Let it dismiss before tapping Save.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsOneWidget);

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
      expect(tester.takeException(), isNull);
    });
  }
}
