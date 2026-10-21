import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/doc_kind.dart';
import 'package:pdfhelper/models/library_query.dart';
import 'package:pdfhelper/screens/library_screen.dart';

import 'guidelines.dart';

/// The Files tab at every phone width, text size and theme. Its filter
/// chips are each a 48 dp tap target (they were 34 dp), named, and readable
/// in their chosen and unchosen state; and the tab fits the phone, the
/// storage banner included. The rest of the Files tab is checked against
/// the guidelines with the work that changes it.
void main() {
  useEmptyAppFolders();

  final labels = [
    for (final filter in LibraryFilter.values) filter.label,
    for (final kind in DocKind.filterable) kind.label,
  ];
  bool isChip(String failure) =>
      labels.any((label) => failure.contains('label: "$label"'));

  for (final setup in phoneSetups) {
    testWidgets('the filter chips meet the guidelines at $setup', (
      tester,
    ) async {
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(const LibraryScreen()));
      await settle(tester);

      final chips = find.byType(ChoiceChip);
      expect(chips, findsNWidgets(labels.length));
      // Every chip, including those scrolled out of sight to the right.
      for (final chip in chips.evaluate()) {
        expect(
          (chip.renderObject! as RenderBox).size.height,
          greaterThanOrEqualTo(48),
        );
      }
      await expectGuidelinesMet(tester, relevant: isChip);

      // A chosen kind chip reads as well as a chosen filter chip.
      await tester.tap(find.widgetWithText(ChoiceChip, DocKind.pdf.label));
      await settle(tester, rounds: 3);
      await expectGuidelinesMet(tester, relevant: isChip);
    });
  }

  for (final setup in phoneSetups) {
    // At 320 dp and the largest text the storage banner alone was 567 px
    // tall, and the tab overflowed by 39 px.
    testWidgets('the Files tab fits the phone at $setup', (tester) async {
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(const LibraryScreen()));
      await settle(tester);
      // An overflow fails the test by itself. The banner takes at most half
      // the tab and scrolls within it, so the list keeps the other half.
      final body = tester.getSize(find.byType(Scaffold).first).height - 56;
      final banner = find.ancestor(
        of: find.textContaining('Showing documents inside DocHelper'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(banner).height, lessThanOrEqualTo(body / 2));
      // Room for a few files below it, even with the largest text.
      expect(
        tester.getSize(find.byType(RefreshIndicator)).height,
        greaterThanOrEqualTo(150),
      );
      // Its button can still be reached.
      final button = find.descendant(
        of: banner,
        matching: find.byType(FilledButton),
      );
      await tester.ensureVisible(button);
      await tester.pump();
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(body + 56));
    });
  }
}
