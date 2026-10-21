import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/services/library_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// What the accessibility tests run every screen at: the phone widths,
/// text sizes and themes people actually use, every combination of them.
///
/// 320 dp is the narrowest phone still sold, 360 dp the commonest width.
/// Text at 1.5 and 2.0 is Android's "Large" and "Largest" font size.
const List<double> phoneWidths = [320, 360];
const List<double> textScales = [1.0, 1.5, 2.0];

/// The screen height used with every width: a small phone's.
const double phoneHeight = 640;

/// One combination of width, text size and theme.
class PhoneSetup {
  const PhoneSetup(this.width, this.textScale, {required this.dark});

  final double width;
  final double textScale;
  final bool dark;

  @override
  String toString() =>
      '${width.round()} dp, text x$textScale, ${dark ? 'dark' : 'light'}';
}

/// Every [PhoneSetup], light and dark.
Iterable<PhoneSetup> get phoneSetups sync* {
  for (final dark in [false, true]) {
    for (final width in phoneWidths) {
      for (final scale in textScales) {
        yield PhoneSetup(width, scale, dark: dark);
      }
    }
  }
}

/// Gives each test its own documents, support and temp folders, and
/// starts the services that cache what they found there afresh, so the
/// screens open as on a phone with nothing saved yet.
void useEmptyAppFolders() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('a11y');
    FakePathProvider.install(root);
    PublicPdfSaveService.resetForTesting();
    RecentFilesService.resetCacheForTesting();
    LibraryService.resetForTesting();
  });
  tearDown(() {
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
}

/// Sizes the test's screen like [setup]'s phone and chooses its theme. The
/// theme is read from settings when [ThemeProvider] starts, so call this
/// before pumping the app.
void usePhone(
  WidgetTester tester,
  PhoneSetup setup, {
  double height = phoneHeight,
}) {
  const pixelRatio = 2.0;
  tester.view.devicePixelRatio = pixelRatio;
  tester.view.physicalSize = Size(
    setup.width * pixelRatio,
    height * pixelRatio,
  );
  tester.platformDispatcher.textScaleFactorTestValue = setup.textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  SharedPreferences.setMockInitialValues({
    'isDarkMode': setup.dark,
    'notifications': false,
  });
}

/// [child] inside the app's theme, the way `main.dart` provides it.
Widget themedApp(Widget child) => ChangeNotifierProvider<ThemeProvider>(
  create: (_) => ThemeProvider(),
  child: Consumer<ThemeProvider>(
    builder: (_, theme, _) => MaterialApp(
      theme: theme.lightTheme,
      darkTheme: theme.darkTheme,
      themeMode: theme.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: child,
    ),
  ),
);

/// Alternates real time with frames, so settings, file listings and other
/// work off the test's fake clock finish.
Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// The checks from Android's accessibility guidelines: tap targets at
/// least 48 dp square, a label on everything that can be tapped, and text
/// contrast of at least 4.5:1 (3:1 for large text).
final List<AccessibilityGuideline> guidelines = [
  androidTapTargetGuideline,
  labeledTapTargetGuideline,
  textContrastGuideline,
];

/// What fails [guideline] on the screen as it is now, one entry per
/// semantics node.
Future<List<String>> guidelineFailures(
  WidgetTester tester,
  AccessibilityGuideline guideline,
) async {
  final evaluation = await guideline.evaluate(tester);
  if (evaluation.passed) return const [];
  final reason = evaluation.reason ?? '';
  final failures = reason
      .split(RegExp(r'(?=SemanticsNode#\d+\()'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty && entry.startsWith('SemanticsNode'))
      .toList();
  // A failure worded some other way is still a failure: report it whole
  // rather than letting the check pass.
  return failures.isEmpty
      ? [reason.isEmpty ? 'no reason given' : reason]
      : failures;
}

/// Checks [guidelines] over the whole screen.
///
/// A screen longer than the phone is first made tall enough to show all
/// of it at once. That checks what lies below the first screenful too,
/// and never measures a control half scrolled out of sight, which reads as
/// a tap target too small. Overflows are a separate matter: pump the screen
/// at the phone's own size first, where any overflow fails the test.
///
/// [relevant] narrows the check to the failures it accepts, for a screen
/// only part of which these tests cover.
Future<void> expectGuidelinesMet(
  WidgetTester tester, {
  bool Function(String failure)? relevant,
}) async {
  final semantics = tester.ensureSemantics();
  try {
    await showWholeScreen(tester);
    final failures = <String>[];
    for (final guideline in guidelines) {
      for (final failure in await guidelineFailures(tester, guideline)) {
        if (relevant == null || relevant(failure)) {
          failures.add('${guideline.description}: $failure');
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  } finally {
    semantics.dispose();
  }
}

/// Makes the test's screen tall enough that its main vertical list no
/// longer scrolls.
Future<void> showWholeScreen(WidgetTester tester) async {
  await tester.pump();
  // A list may build more of itself once there is room; a few rounds
  // catch that.
  for (var round = 0; round < 5; round++) {
    final scrollable = _mainScrollable(tester);
    final hidden = scrollable?.position.maxScrollExtent ?? 0;
    if (hidden <= 0) return;
    final view = tester.view;
    view.physicalSize = Size(
      view.physicalSize.width,
      view.physicalSize.height + (hidden * view.devicePixelRatio).ceil(),
    );
    await tester.pump();
  }
}

/// The tallest vertical scroll view on screen, if any.
ScrollableState? _mainScrollable(WidgetTester tester) {
  ScrollableState? tallest;
  var tallestHeight = 0.0;
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.down) continue;
    final box = element.renderObject as RenderBox?;
    final height = box?.size.height ?? 0;
    if (height > tallestHeight) {
      tallest = state;
      tallestHeight = height;
    }
  }
  return tallest;
}

/// The WCAG contrast ratio of [a] against [b], from 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
