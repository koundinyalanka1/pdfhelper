import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/screens/settings_screen.dart';

import 'guidelines.dart';

/// Settings at every phone width, text size and theme: nothing overflows
/// (an overflow fails the test by itself), every control is at least 48 dp
/// and named, and its text has enough contrast.
void main() {
  useEmptyAppFolders();

  for (final setup in phoneSetups) {
    testWidgets('Settings meets the guidelines at $setup', (tester) async {
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(const SettingsScreen()));
      await settle(tester);
      await expectGuidelinesMet(tester);
    });
  }

  testWidgets('the theme buttons and the switches are named', (tester) async {
    usePhone(tester, const PhoneSetup(360, 1.0, dark: false));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(themedApp(const SettingsScreen()));
    await settle(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Light theme')),
      isSemantics(
        label: 'Light theme',
        isButton: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Dark theme')),
      isSemantics(
        label: 'Dark theme',
        isButton: true,
        isSelected: false,
        hasTapAction: true,
      ),
    );
    // Each switch is read with its title and what it does, not as a bare
    // "switch, off".
    for (final title in [
      'Auto Save',
      'Notifications',
      'Skip Preview',
      'Searchable Scans',
    ]) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^$title\n'))),
        isSemantics(hasToggledState: true, hasTapAction: true),
        reason: title,
      );
    }
    semantics.dispose();
  });

  testWidgets('tapping a named theme button switches the theme', (
    tester,
  ) async {
    usePhone(tester, const PhoneSetup(360, 1.0, dark: false));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(themedApp(const SettingsScreen()));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Dark theme'));
    await settle(tester);
    expect(find.text('Dark mode enabled'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('saves without public storage go to plain "app storage"', (
    tester,
  ) async {
    usePhone(tester, const PhoneSetup(360, 1.0, dark: false));
    await tester.pumpWidget(themedApp(const SettingsScreen()));
    await settle(tester);
    // Tests run off Android, where saves stay in the app's own folder.
    expect(find.text('Save to app storage'), findsOneWidget);
    expect(find.textContaining('PDFHelper'), findsNothing);
  });
}
