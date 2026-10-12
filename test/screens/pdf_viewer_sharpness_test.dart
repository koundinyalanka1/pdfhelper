import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';
import '../support/text_pdf_fixture.dart';

/// How sharp pages are on screen.
///
/// Pages used to be rendered into a square box the width of the screen, so a
/// portrait page came out at 70% of the screen's resolution and was then
/// stretched — text looked soft next to Drive, worst of all in scripts with
/// fine detail. Zooming in re-rendered the whole page and only past 1.4x.
///
/// The widget tests need the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/screens/pdf_viewer_sharpness_test.dart
void main() {
  group('pageRenderSize', () {
    test('is exactly as wide as the page on screen, in device pixels', () {
      final size = pageRenderSize(
        displayWidth: 409.8,
        devicePixelRatio: 2.8125,
        aspectRatio: 595 / 842,
      );
      expect(size.width, 1152);
      // Room to spare below, so the engine's fit is set by the width.
      expect(size.height, greaterThan(1152 * 842 / 595));
    });

    test('keeps the shape of a page too long for full resolution', () {
      final size = pageRenderSize(
        displayWidth: 400,
        devicePixelRatio: 3,
        aspectRatio: 0.05, // a till receipt
        maxPixels: 4000000,
      );
      expect(size.width * size.height, lessThanOrEqualTo(4000000 + size.width));
      expect(size.width / (size.height - 1), closeTo(0.05, 0.001));
    });

    test('treats an unknown shape as A4 and never asks for nothing', () {
      expect(
        pageRenderSize(
          displayWidth: 100,
          devicePixelRatio: 2,
          aspectRatio: double.nan,
        ).height,
        (200 / 0.7071).ceil() + 1,
      );
      expect(
        pageRenderSize(
          displayWidth: 0,
          devicePixelRatio: 3,
          aspectRatio: 0.7,
        ).width,
        1,
      );
    });
  });

  group('zoomTileRegion', () {
    const page = Size(400, 500);

    test('covers what is on screen plus a margin, in page pixels', () {
      final region = zoomTileRegion(
        visible: const Rect.fromLTWH(100, 200, 50, 60),
        pageSize: page,
        pixelWidth: 2400, // 6 pixels to a logical pixel
        aspectRatio: 0.8,
        margin: 10,
      )!;
      expect(region.scale, 6);
      expect((region.x, region.y), (590, 1190));
      expect((region.width, region.height), (320, 380));
    });

    test('stays on the page at its edges', () {
      final region = zoomTileRegion(
        visible: const Rect.fromLTWH(0, 450, 400, 50),
        pageSize: page,
        pixelWidth: 800,
        aspectRatio: 0.8,
      )!;
      expect(region.x, 0);
      expect(region.x + region.width, 800);
      expect(region.y + region.height, 1000);
    });

    test('is nothing when none of the page is on screen', () {
      expect(
        zoomTileRegion(
          visible: Rect.zero,
          pageSize: page,
          pixelWidth: 800,
          aspectRatio: 0.8,
        ),
        isNull,
      );
    });
  });

  final libPath = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (libPath.isEmpty || !File(libPath).existsSync()) return;

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File pdf;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_sharpness');
    FakePathProvider.install(root);
    pdf = writeTextPdfFixture(root, ['First page text', 'Second page']);
  });

  tearDown(() async {
    FakePathProvider.restore();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: PdfViewerScreen(pdfPath: pdf.path, title: 'Text.pdf'),
        ),
      ),
    );
    await settle(tester);
  }

  (int, int) pngSize(Uint8List png) {
    final data = ByteData.sublistView(png);
    return (data.getUint32(16), data.getUint32(20));
  }

  Finder pageImage(int index) => find
      .descendant(
        of: find.byKey(ValueKey('${pdf.path}#$index')),
        matching: find.byType(Image),
      )
      .first;

  testWidgets('a page is rendered at the screen\'s resolution, pixel for '
      'pixel', (tester) async {
    await open(tester);
    final image = tester.widget<Image>(pageImage(0));
    final bytes = (image.image as MemoryImage).bytes;
    final view = tester.view;
    final pageWidth = view.physicalSize.width / view.devicePixelRatio - 24;
    final (width, height) = pngSize(bytes);
    expect(width, (pageWidth * view.devicePixelRatio).floor());
    expect(height, closeTo(width / 0.75, 1));
    // Drawn at its own size and copied, not resampled.
    expect(image.fit, BoxFit.none);
    expect(image.filterQuality, FilterQuality.none);
    expect(
      tester.getSize(pageImage(0)).width,
      closeTo(width / view.devicePixelRatio, 0.01),
    );
  });

  testWidgets('a page is redrawn for a new width rather than stretched', (
    tester,
  ) async {
    await open(tester);
    // A rotation: 600 logical pixels wide instead of 800.
    tester.view.physicalSize = const Size(1800, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await settle(tester);
    final image = tester.widget<Image>(pageImage(0));
    final (width, _) = pngSize((image.image as MemoryImage).bytes);
    expect(width, (600 - 24) * 3);
    expect(image.fit, BoxFit.none);
  });

  testWidgets('zooming in lays the part on screen over the page, sharp at '
      'that zoom, and zooming out takes it away', (tester) async {
    await open(tester);
    final zoom = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    zoom.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump();
    await settle(tester);

    final tile = find.byKey(const ValueKey('pdf-zoom-tile'));
    expect(tile, findsWidgets);
    final widget = tester.widget<Image>(tile.first);
    final (width, height) = pngSize((widget.image as MemoryImage).bytes);
    // One tile pixel per device pixel at 3x.
    final size = tester.getSize(tile.first);
    final scale = 3 * tester.view.devicePixelRatio;
    expect(width, closeTo(size.width * scale, 1));
    expect(height, closeTo(size.height * scale, 1));
    expect(widget.filterQuality, FilterQuality.none);
    // Only about a screenful, not the whole page at 3x.
    final pageWidth = tester.getSize(find.byKey(ValueKey('${pdf.path}#0'))).width;
    expect(size.width, lessThan(pageWidth));

    zoom.value = Matrix4.identity();
    await tester.pump();
    await settle(tester, rounds: 4);
    expect(find.byKey(const ValueKey('pdf-zoom-tile')), findsNothing);
  });
}
