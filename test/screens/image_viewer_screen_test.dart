import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/image_viewer_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/pdf_core_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// The picture viewer. Making a PDF goes through the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/rust/target/release/libpdf_ffi.so \
///     flutter test test/screens/image_viewer_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String png;
  late String jpeg;

  img.Image picture(int width, int height) => img.fill(
    img.Image(width: width, height: height),
    color: img.ColorRgb8(30, 120, 200),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_image');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    DocumentSaveService.publishOverride = false;
    png = '${root.path}/Chart.png';
    File(png).writeAsBytesSync(img.encodePng(picture(40, 30)));
    jpeg = '${root.path}/Photo.jpg';
    File(jpeg).writeAsBytesSync(img.encodeJpg(picture(64, 48)));
  });

  tearDown(() {
    FakePathProvider.restore();
    DocumentSaveService.publishOverride = null;
    root.deleteSync(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: home),
  );

  /// Reading the file and decoding the picture happen outside the test's
  /// fake clock.
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  /// Lets sheets and dialogs finish animating.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The picture has been decoded and drawn.
  final shown = find.byType(RawImage);

  IconButton button(WidgetTester tester, String key) =>
      tester.widget<IconButton>(find.byKey(ValueKey(key)));

  TransformationController zoom(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!;

  testWidgets('shows a PNG, with its details in a sheet', (tester) async {
    await tester.pumpWidget(app(ImageViewerScreen(path: png)));
    await until(tester, shown);
    expect(find.text('Chart.png'), findsOneWidget);
    for (final key in ['image-rotate', 'image-info', 'image-share']) {
      expect(button(tester, key).onPressed, isNotNull, reason: key);
      expect(button(tester, key).tooltip, isNotEmpty, reason: key);
    }
    expect(button(tester, 'image-to-pdf').tooltip, 'Make a PDF');

    await tester.tap(find.byKey(const ValueKey('image-info')));
    await settle(tester);
    expect(find.byKey(const ValueKey('image-details')), findsOneWidget);
    expect(find.text('Chart.png'), findsNWidgets(2));
    expect(find.text('40 × 30'), findsOneWidget);
    expect(find.text('PNG'), findsOneWidget);
    expect(find.text('${File(png).lengthSync()} B'), findsOneWidget);
    expect(find.text('MODIFIED'), findsOneWidget);
  });

  testWidgets('a JPEG shows under the title it was given', (tester) async {
    await tester.pumpWidget(
      app(ImageViewerScreen(path: jpeg, title: 'Holiday')),
    );
    await until(tester, shown);
    expect(find.text('Holiday'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('image-info')));
    await settle(tester);
    expect(find.text('64 × 48'), findsOneWidget);
    expect(find.text('JPEG'), findsOneWidget);
  });

  testWidgets('says when a GIF is animated', (tester) async {
    final gif = '${root.path}/Wave.gif';
    final first = picture(8, 8)..addFrame(picture(8, 8));
    File(gif).writeAsBytesSync(img.encodeGif(first));
    await tester.pumpWidget(app(ImageViewerScreen(path: gif)));
    await until(tester, shown);
    await tester.tap(find.byKey(const ValueKey('image-info')));
    await settle(tester);
    expect(find.text('GIF, animated, 2 frames'), findsOneWidget);
    // Stop the animation's timers.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turns the view a quarter at a time', (tester) async {
    await tester.pumpWidget(app(ImageViewerScreen(path: png)));
    await until(tester, shown);
    int turns() =>
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns;
    expect(turns(), 0);
    await tester.tap(find.byKey(const ValueKey('image-rotate')));
    await tester.pump();
    expect(turns(), 1);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('image-rotate')));
      await tester.pump();
    }
    expect(turns(), 0);
    // The file itself is untouched.
    expect(img.decodePng(File(png).readAsBytesSync())!.width, 40);
  });

  testWidgets('double-tap zooms in where tapped, and out again', (
    tester,
  ) async {
    await tester.pumpWidget(app(ImageViewerScreen(path: png)));
    await until(tester, shown);
    final centre = tester.getCenter(find.byType(InteractiveViewer));

    Future<void> doubleTap() async {
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(centre);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await doubleTap();
    expect(zoom(tester).value.getMaxScaleOnAxis(), closeTo(2.5, 1e-6));
    // The tapped point stays where it was.
    final local = tester
        .renderObject<RenderBox>(find.byType(InteractiveViewer))
        .globalToLocal(centre);
    expect(zoom(tester).toScene(local).dx, closeTo(local.dx, 1e-3));

    await doubleTap();
    expect(zoom(tester).value.getMaxScaleOnAxis(), closeTo(1, 1e-6));

    // Turning resets the zoom.
    await doubleTap();
    await tester.tap(find.byKey(const ValueKey('image-rotate')));
    await tester.pump();
    expect(zoom(tester).value.getMaxScaleOnAxis(), closeTo(1, 1e-6));
  });

  testWidgets('shares the picture with its type', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(app(ImageViewerScreen(path: png)));
    await until(tester, shown);
    await tester.tap(find.byKey(const ValueKey('image-share')));
    for (var i = 0; i < 20 && calls.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(calls.single.method, 'share');
    final arguments = calls.single.arguments as Map;
    expect(arguments['paths'], [png]);
    expect(arguments['mimeTypes'], ['image/png']);
  });

  testWidgets('a file that is not a picture says so and offers other apps', (
    tester,
  ) async {
    final broken = '${root.path}/Broken.jpg';
    File(broken).writeAsStringSync('This is not a picture at all.');
    await tester.pumpWidget(app(ImageViewerScreen(path: broken)));
    await until(tester, find.text('This picture cannot be shown'));
    expect(find.textContaining('may be damaged'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-open-with')), findsOneWidget);
    expect(find.text('Open with another app'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-problem-share')), findsOneWidget);
    expect(button(tester, 'image-to-pdf').onPressed, isNull);
    expect(button(tester, 'image-rotate').onPressed, isNull);
    expect(button(tester, 'image-share').onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('image-info')));
    await settle(tester);
    expect(find.text('Unreadable'), findsOneWidget);
    // Nothing in the content says otherwise, so the name gives the type.
    expect(find.text('JPEG'), findsOneWidget);
  });

  testWidgets('a picture damaged past its header says so too', (tester) async {
    // The size reads, so the viewer starts showing it, but the pixels
    // are garbage the decoder gives up on.
    final header = img.encodePng(picture(40, 30)).sublist(0, 33);
    final damaged = '${root.path}/Damaged.png';
    File(damaged).writeAsBytesSync([
      ...header,
      ...[0, 0, 0, 16, ...'IDAT'.codeUnits, ...List.filled(16, 0x5A)],
      ...[1, 2, 3, 4, 0, 0, 0, 0, ...'IEND'.codeUnits, 0xAE, 0x42, 0x60, 0x82],
    ]);
    await tester.pumpWidget(app(ImageViewerScreen(path: damaged)));
    await until(tester, find.text('This picture cannot be shown'));
    expect(find.byType(RawImage), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('image-open-with')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-info')));
    await settle(tester);
    expect(find.text('Unreadable'), findsOneWidget);
    expect(find.text('PNG'), findsOneWidget);
  });

  testWidgets('a file that has gone says so', (tester) async {
    await tester.pumpWidget(
      app(ImageViewerScreen(path: '${root.path}/Gone.png')),
    );
    await until(tester, find.text('This picture is not there any more'));
    expect(find.byKey(const ValueKey('image-open-with')), findsNothing);
    expect(button(tester, 'image-share').onPressed, isNull);
  });

  final library = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (library.isEmpty || !File(library).existsSync()) return;

  group('with the native core', () {
    setUpAll(PdfCoreService.probe);

    Future<String> makePdf(WidgetTester tester, String expectedName) async {
      await tester.tap(find.byKey(const ValueKey('image-to-pdf')));
      await settle(tester);
      expect(find.text('Name your PDF'), findsOneWidget);
      expect(find.text(expectedName), findsOneWidget);
      await tester.tap(find.text('Create'));
      await until(tester, find.text('Success!'));
      final output = '${root.path}/documents/$expectedName.pdf';
      expect(File(output).existsSync(), isTrue);
      await tester.tap(find.text('Close'));
      await settle(tester);
      return output;
    }

    testWidgets('makes a one-page PDF of a JPEG', (tester) async {
      await tester.pumpWidget(app(ImageViewerScreen(path: jpeg)));
      await until(tester, shown);
      final output = await makePdf(tester, 'Photo');
      expect(PdfCore.pageCount(output), 1);
      final page = PdfCore.pageSize(output, 0);
      expect(page.width / page.height, closeTo(64 / 48, 0.02));
      // Nothing left over beside it.
      final left = Directory(
        '${root.path}/documents',
      ).listSync().map((entry) => entry.path.split('/').last).toList();
      expect(left, ['Photo.pdf']);
    });

    testWidgets('a turned PNG makes a turned page', (tester) async {
      await tester.pumpWidget(app(ImageViewerScreen(path: png)));
      await until(tester, shown);
      await tester.tap(find.byKey(const ValueKey('image-rotate')));
      await tester.pump();
      final output = await makePdf(tester, 'Chart');
      expect(PdfCore.pageCount(output), 1);
      final page = PdfCore.pageSize(output, 0);
      expect(page.width / page.height, closeTo(30 / 40, 0.02));
      final left = Directory(
        '${root.path}/documents',
      ).listSync().map((entry) => entry.path.split('/').last).toList();
      expect(left, ['Chart.pdf']);
    });

    testWidgets('offers a given title whole, or without its extension', (
      tester,
    ) async {
      for (final (title, offered) in [
        ('Mr. Bean', 'Mr. Bean'),
        ('Receipt.jpeg', 'Receipt'),
      ]) {
        await tester.pumpWidget(
          app(
            ImageViewerScreen(key: ValueKey(title), path: jpeg, title: title),
          ),
        );
        await until(tester, shown);
        await tester.tap(find.byKey(const ValueKey('image-to-pdf')));
        await settle(tester);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, offered);
        await tester.tap(find.text('Cancel'));
        await settle(tester);
      }
      // Backing out writes nothing.
      final documents = Directory('${root.path}/documents');
      expect(
        documents.existsSync() && documents.listSync().isNotEmpty,
        isFalse,
      );
    });

    testWidgets('a format only the phone decodes still makes a PDF', (
      tester,
    ) async {
      // WBMP: the engine reads it, the image package does not, so this goes
      // the way HEIC photos do, through the platform's own codec.
      final wbmp = '${root.path}/Dots.wbmp';
      File(wbmp).writeAsBytesSync([
        0, 0, 16, 8, // type, header, width, height
        for (var row = 0; row < 8; row++) ...[0xF0, 0x0F],
      ]);
      expect(img.decodeImage(File(wbmp).readAsBytesSync()), isNull);
      await tester.pumpWidget(app(ImageViewerScreen(path: wbmp)));
      await until(tester, shown);
      final output = await makePdf(tester, 'Dots');
      expect(PdfCore.pageCount(output), 1);
      final page = PdfCore.pageSize(output, 0);
      expect(page.width / page.height, closeTo(2, 0.02));
      final left = Directory(
        '${root.path}/documents',
      ).listSync().map((entry) => entry.path.split('/').last).toList();
      expect(left, ['Dots.pdf']);
      // The temporary JPEG is gone too.
      final temporary = Directory('${root.path}/temporary');
      expect(
        temporary.existsSync()
            ? temporary.listSync(recursive: true).whereType<File>()
            : const <File>[],
        isEmpty,
      );
    });
  });
}
