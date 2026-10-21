import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/screens/merge_pdf_screen.dart';

import 'guidelines.dart';

/// Merge PDFs at every phone width, text size and theme: the file picker
/// box grows with large text instead of overflowing (at 320 dp it did), and
/// the screen meets the tap target, label and contrast guidelines.
void main() {
  useEmptyAppFolders();

  for (final setup in phoneSetups) {
    testWidgets('Merge PDFs meets the guidelines at $setup', (tester) async {
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(const MergePdfScreen()));
      await settle(tester);
      expect(find.text('Tap to select PDF files'), findsOneWidget);
      await expectGuidelinesMet(tester);
    });
  }
}
