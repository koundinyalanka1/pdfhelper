import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/protect_screen.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget app({bool isEncrypted = false}) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: ProtectScreen(pdfPath: '/unused.pdf', isEncrypted: isEncrypted),
    ),
  );

  final notice = find.byKey(const ValueKey('non-ascii-password-notice'));

  test('only printable ASCII counts as safe everywhere', () {
    expect(usesNonAsciiPassword('Plain-Pass_123!'), isFalse);
    expect(usesNonAsciiPassword('Pässwörd1'), isTrue);
    expect(usesNonAsciiPassword('पासवर्ड'), isTrue);
    expect(usesNonAsciiPassword('tab\there'), isTrue);
  });

  testWidgets('warns while a new password would not open in Apple Preview', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final fields = find.byType(TextField);

    await tester.enterText(fields.at(0), 'plain-pass');
    await tester.pump();
    expect(notice, findsNothing);

    await tester.enterText(fields.at(0), 'Pässwörd1');
    await tester.pump();
    expect(notice, findsOneWidget);

    await tester.enterText(fields.at(0), 'plain-pass');
    await tester.enterText(fields.at(2), 'ownér');
    await tester.pump();
    expect(notice, findsOneWidget, reason: 'the owner password counts too');

    await tester.enterText(fields.at(2), '');
    await tester.pump();
    expect(notice, findsNothing);
  });

  testWidgets('removing a password never shows the notice', (tester) async {
    await tester.pumpWidget(app(isEncrypted: true));
    await tester.enterText(find.byType(TextField).first, 'Pässwörd1');
    await tester.pump();
    expect(notice, findsNothing);
  });

  group('naming the copy', () {
    final library = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
    final engine = library.isNotEmpty && File(library).existsSync();
    setUpAll(() async {
      if (engine) await PdfCoreService.probe();
    });

    Widget named(String path, {bool isEncrypted = false}) =>
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: MaterialApp(
            home: ProtectScreen(pdfPath: path, isEncrypted: isEncrypted),
          ),
        );

    testWidgets('protect offers the document name and cancelling does nothing', (
      tester,
    ) async {
      await tester.pumpWidget(named('/docs/Invoice.pdf'));
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'secret');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.text('Protect with password'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.byType(TextField)),
        findsOneWidget,
      );
      expect(find.text('Invoice (protected)'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Working…'), findsNothing);
    }, skip: !engine);

    testWidgets('a file opened from another app is named by its own name', (
      tester,
    ) async {
      await tester.pumpWidget(
        named('/cache/opened_pdfs/intent_123_Statement.pdf', isEncrypted: true),
      );
      await tester.enterText(find.byType(TextField).first, 'secret');
      // The title says "Remove password" too; tap the button.
      await tester.tap(find.byIcon(Icons.lock_open_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Statement (unlocked)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }, skip: !engine);
  });
}
