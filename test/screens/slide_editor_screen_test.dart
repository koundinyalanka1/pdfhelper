import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/slide_editor_screen.dart';
import 'package:pdfhelper/screens/slide_show_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/store_zip.dart';

/// The slides screen, driven through the real presentation engine:
///   eval "$(bash scripts/build_engines.sh env)"
///   flutter test test/screens/slide_editor_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_slide_editor');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    DocumentSaveService.publishOverride = false;
  });

  tearDown(() {
    DocumentSaveService.publishOverride = null;
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  Future<void> flush(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Let sheets and routes finish animating.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Tap the slide at a fraction of its width and height.
  Future<void> tapSlide(WidgetTester tester, double fx, double fy) async {
    final stage = find.byKey(const Key('slide-stage'));
    final box = tester.getRect(stage);
    await tester.tapAt(
      Offset(box.left + box.width * fx, box.top + box.height * fy),
    );
    await settle(tester);
  }

  final available = SlideCore.isAvailable;

  Future<String> makeDeck() async {
    final path = '${root.path}/talk.pptx';
    final deck = SlideCore.create();
    final title = deck
        .scene(0)
        .items
        .firstWhere((i) => i.placeholder == 'ctrTitle');
    deck.setText(0, title.id, ['Garden club']);
    deck.addSlide(after: 0);
    deck.setNotes(0, 'Welcome everyone');
    await deck.save(path);
    deck.close();
    return path;
  }

  testWidgets('says why when the file cannot be opened', (tester) async {
    await tester.pumpWidget(
      app(SlideEditorScreen(path: '${root.path}/missing.pptx')),
    );
    await flush(tester);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
  }, skip: !available);

  testWidgets('types a title into a new presentation and saves it', (
    tester,
  ) async {
    final path = '${root.path}/new.pptx';
    await tester.pumpWidget(app(SlideEditorScreen(path: path, isNew: true)));
    await flush(tester);
    expect(find.text('PPTX · 1 slide'), findsOneWidget);

    // One tap on the empty title placeholder opens its text.
    await tapSlide(tester, 0.5, 0.34);
    expect(find.text('Title'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Family trip');
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await settle(tester);
    expect(find.text('PPTX · 1 slide · Edited'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await flush(tester);
    final deck = await tester.runAsync(() => SlideCore.open(path));
    final title = deck!
        .scene(0)
        .items
        .firstWhere((i) => i.placeholder == 'ctrTitle');
    expect(title.text!.paragraphs, ['Family trip']);
    deck.close();
  }, skip: !available);

  testWidgets('adds a slide from a layout, then undoes it', (tester) async {
    final path = (await tester.runAsync(makeDeck))!;
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('PPTX · 2 slides'), findsOneWidget);

    await tester.tap(find.text('New slide'));
    await settle(tester);
    await tester.tap(find.text('Section Header'));
    await settle(tester);
    expect(find.text('PPTX · 3 slides · Edited'), findsOneWidget);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PPTX · 2 slides'), findsOneWidget);
  }, skip: !available);

  testWidgets('adds a shape, selects it and deletes it', (tester) async {
    final path = (await tester.runAsync(makeDeck))!;
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);

    await tester.tap(find.text('Shape'));
    await settle(tester);
    await tester.tap(find.text('Oval'));
    await settle(tester);
    // The new shape is selected: its tools show.
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Bold'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Picture'), findsOneWidget);
    expect(find.text('PPTX · 2 slides · Edited'), findsOneWidget);
  }, skip: !available);

  testWidgets('shows and edits speaker notes', (tester) async {
    final path = (await tester.runAsync(makeDeck))!;
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('Welcome everyone'), findsOneWidget);

    await tester.tap(find.text('Welcome everyone'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Welcome, friends');
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await settle(tester);
    expect(find.text('Welcome, friends'), findsOneWidget);
  }, skip: !available);

  testWidgets('duplicates and hides a slide from its menu', (tester) async {
    final path = (await tester.runAsync(makeDeck))!;
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);

    await tester.tap(find.text('Slide'));
    await settle(tester);
    await tester.tap(find.text('Duplicate'));
    await settle(tester);
    expect(find.text('PPTX · 3 slides · Edited'), findsOneWidget);

    await tester.tap(find.text('Slide'));
    await settle(tester);
    await tester.tap(find.text('Hide in slide show'));
    await settle(tester);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  }, skip: !available);

  testWidgets('presents the deck and comes back', (tester) async {
    final path = (await tester.runAsync(makeDeck))!;
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);

    await tester.tap(find.byTooltip('Present'));
    await settle(tester);
    expect(find.byType(SlideShowScreen), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tapAt(const Offset(700, 300));
    await settle(tester);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('End show'));
    await settle(tester);
    expect(find.byType(SlideShowScreen), findsNothing);
  }, skip: !available);

  testWidgets('opens an OpenDocument presentation and saves it in place', (
    tester,
  ) async {
    const ns =
        'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
        'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
        'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
        'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
        'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"';
    final path = '${root.path}/club.odp';
    File(path).writeAsBytesSync(
      storeZip({
        'mimetype': 'application/vnd.oasis.opendocument.presentation',
        'META-INF/manifest.xml':
            '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.presentation"/></manifest:manifest>',
        'styles.xml':
            '<office:document-styles $ns><office:automatic-styles><style:page-layout style:name="PM1"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Default" style:page-layout-name="PM1"/></office:master-styles></office:document-styles>',
        'content.xml':
            '<office:document-content $ns><office:body><office:presentation><draw:page draw:name="page1" draw:master-page-name="Default"><draw:frame svg:x="2cm" svg:y="2cm" svg:width="20cm" svg:height="3cm" presentation:class="title"><draw:text-box><text:p>Garden club</text:p></draw:text-box></draw:frame></draw:page></office:presentation></office:body></office:document-content>',
      }),
    );
    await tester.pumpWidget(app(SlideEditorScreen(path: path)));
    await flush(tester);
    expect(find.text('ODP · 1 slide'), findsOneWidget);

    // Select the title, then tap it again to edit it.
    await tapSlide(tester, 0.4, 0.2);
    await tapSlide(tester, 0.4, 0.2);
    await tester.enterText(find.byType(TextField), 'Garden club meeting');
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await settle(tester);
    await tester.tap(find.text('Save'));
    await flush(tester);

    final deck = await tester.runAsync(() => SlideCore.open(path));
    expect(deck!.info().format, 'odp');
    expect(deck.plainText(), contains('Garden club meeting'));
    deck.close();
  }, skip: !available);
}
