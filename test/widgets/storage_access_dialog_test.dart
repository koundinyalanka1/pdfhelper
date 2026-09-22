import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/widgets/storage_access_dialog.dart';
import 'package:provider/provider.dart';

/// The library used to send people straight to Android's "Allow access to
/// manage all files" screen from a small button, with no explanation — a
/// warning-toned system page arriving out of nowhere. This dialog is what now
/// comes first, so these tests hold it to saying why, and to treating "no" as
/// a real answer.
void main() {
  Widget host(void Function(BuildContext) onReady) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => onReady(context),
              child: const Text('ask'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('explains what the permission is for before granting it',
      (tester) async {
    await tester.pumpWidget(host(showStorageAccessDialog));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    expect(find.text('Find PDFs on your phone'), findsOneWidget);
    // The three things a person actually wants to know.
    expect(find.textContaining('Only PDFs are read'), findsOneWidget);
    expect(find.textContaining('stays on this'), findsOneWidget);
    expect(find.textContaining('turn this off'), findsOneWidget);
  });

  testWidgets('continuing returns true', (tester) async {
    bool? result;
    await tester.pumpWidget(
      host((context) async => result = await showStorageAccessDialog(context)),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('declining returns false so nothing is requested',
      (tester) async {
    bool? result;
    await tester.pumpWidget(
      host((context) async => result = await showStorageAccessDialog(context)),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('dismissing without choosing counts as declining',
      (tester) async {
    bool? result;
    await tester.pumpWidget(
      host((context) async => result = await showStorageAccessDialog(context)),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    // Tapping the scrim, or Back, must not read as consent.
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}
