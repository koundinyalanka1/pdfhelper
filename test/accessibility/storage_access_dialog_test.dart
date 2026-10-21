import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/widgets/storage_access_dialog.dart';

import 'guidelines.dart';

/// The storage disclosure at every phone width, text size and theme: it
/// scrolls rather than overflowing with the largest text, its two buttons
/// are tap targets of 48 dp, and its text has enough contrast.
void main() {
  for (final setup in phoneSetups) {
    testWidgets('the storage disclosure meets the guidelines at $setup', (
      tester,
    ) async {
      usePhone(tester, setup);
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showStorageAccessDialog(context),
                  child: const Text('ask'),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester, rounds: 3);
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      expect(find.text('Find documents on your phone'), findsOneWidget);

      // The dialog's own list; the page behind it does not scroll.
      await expectGuidelinesMet(
        tester,
        relevant: (failure) => !failure.contains('label: "ask"'),
      );
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
    });
  }
}
