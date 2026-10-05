import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Drives real pointers at the real viewer to prove the pinch cannot be
/// stolen by the page list.
///
/// Zoom used to fire only sometimes for the same gesture:
/// `InteractiveViewer`'s scale recognizer and the list's vertical-drag
/// recognizer both enter the gesture arena when a second finger lands, and
/// whichever crosses its threshold first wins outright — so two fingers that
/// drifted down before spreading lost the pinch entirely. The list now stands
/// down the moment a second finger arrives, which is what these tests pin.
///
/// Needs the native core, since the viewer only builds its page list once a
/// document has actually been read:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/rust/target/release/libpdf_ffi.dylib \
///     flutter test test/screens/pdf_viewer_gesture_test.dart
void main() {
  final libPath = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (libPath.isEmpty || !File(libPath).existsSync()) return;

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File pdf;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_gesture');
    FakePathProvider.install(root);
    pdf = _writePdf(root, 'Doc.pdf', pages: 6);
  });

  tearDown(() async {
    FakePathProvider.restore();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Widget app() => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: PdfViewerScreen(pdfPath: pdf.path, title: 'Doc.pdf'),
    ),
  );

  /// Builds the viewer and waits for the document to actually be read.
  ///
  /// Reading hands off to `Isolate.run`, and a widget test's fake-async zone
  /// never lets that finish — only [WidgetTester.runAsync] does. Pumping is
  /// forbidden inside `runAsync`, so the wait and the rebuild are separate
  /// steps.
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(app());
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(ListView).evaluate().isNotEmpty) break;
    }
    expect(
      find.byType(ListView),
      findsOneWidget,
      reason: 'the page list should have been built',
    );
  }

  ScrollPhysics? physics(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).physics;

  /// The double-tap recognizer arms a ~300ms countdown on every pointer it
  /// sees. Let those retire, or the binding reports them as leaked timers.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('one finger leaves the list free to scroll', (tester) async {
    await open(tester);
    expect(physics(tester), isA<AlwaysScrollableScrollPhysics>());

    final finger = await tester.startGesture(const Offset(200, 400));
    await tester.pump();

    expect(
      physics(tester),
      isA<AlwaysScrollableScrollPhysics>(),
      reason: 'a single finger is a scroll, not a pinch',
    );

    await finger.up();
    await flush(tester);
  });

  testWidgets('a second finger stands the list down', (tester) async {
    await open(tester);

    final first = await tester.startGesture(const Offset(180, 400));
    await tester.pump();
    final second = await tester.startGesture(const Offset(220, 400));
    await tester.pump();

    // With no drag recognizer left in the arena, nothing can outrace the
    // pinch — which is the whole of the fix.
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());

    await first.up();
    await second.up();
    await flush(tester);
  });

  testWidgets('lifting back to one finger restores scrolling', (tester) async {
    await open(tester);

    final first = await tester.startGesture(const Offset(180, 400));
    final second = await tester.startGesture(const Offset(220, 400));
    await tester.pump();
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());

    await second.up();
    await tester.pump();

    expect(
      physics(tester),
      isA<AlwaysScrollableScrollPhysics>(),
      reason: 'the remaining finger should be able to scroll again',
    );

    await first.up();
    await flush(tester);
  });

  testWidgets('a cancelled pointer is not counted forever', (tester) async {
    await open(tester);

    final first = await tester.startGesture(const Offset(180, 400));
    final second = await tester.startGesture(const Offset(220, 400));
    await tester.pump();
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());

    // A pointer the system takes away (a notification shade, a phone call)
    // must not leave the list permanently locked.
    await first.cancel();
    await second.cancel();
    await tester.pump();

    expect(physics(tester), isA<AlwaysScrollableScrollPhysics>());
    await flush(tester);
  });

  testWidgets('a two-finger spread actually zooms', (tester) async {
    await open(tester);

    final centre = tester.getCenter(find.byType(ListView));
    final a = await tester.startGesture(centre - const Offset(40, 0));
    final b = await tester.startGesture(centre + const Offset(40, 0));
    await tester.pump();

    // Drift downwards first — the movement that used to hand the arena to the
    // scroll view and lose the pinch — then spread.
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-6, 4));
      await b.moveBy(const Offset(6, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }

    final matrix = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value;
    expect(
      matrix.getMaxScaleOnAxis(),
      greaterThan(1.0),
      reason: 'the spread should have zoomed despite the downward drift',
    );

    await a.up();
    await b.up();
    await flush(tester);
  });

  testWidgets('zoomed reading reaches the last page and returns to the first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);

    final list = find.byType(ListView);
    final viewer = find.byType(InteractiveViewer);
    final scroll = tester.widget<ListView>(list).controller!;
    final zoom = tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!;
    zoom.value = doubleTapZoomTarget(
      isZoomed: false,
      focalPoint: const Offset(160, 300),
    );
    await tester.pump();
    final horizontalOffset = zoom.value.storage[12];
    final viewport = tester.getRect(viewer);

    for (var i = 0; i < 22; i++) {
      await tester.dragFrom(
        Offset(viewport.center.dx, viewport.bottom - 60),
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(find.text('6 / 6'), findsOneWidget);
    final lastPage = find.byKey(ValueKey('${pdf.path}#5'));
    expect(lastPage, findsOneWidget);
    expect(
      tester.getBottomRight(lastPage).dy,
      lessThanOrEqualTo(viewport.bottom),
    );
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, 0.001));
    expect(zoom.value.storage[12], closeTo(horizontalOffset, 0.001));

    for (var i = 0; i < 22; i++) {
      await tester.dragFrom(
        Offset(viewport.center.dx, viewport.top + 60),
        const Offset(0, 500),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(scroll.offset, closeTo(0, 1));
    expect(find.text('1 / 6'), findsOneWidget);
    expect(zoom.value.storage[13], closeTo(0, 1));
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, 0.001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('zoomed fling continues until a new touch stops it', (
    tester,
  ) async {
    await open(tester);
    final viewer = find.byType(InteractiveViewer);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    final zoom = tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!;
    zoom.value = doubleTapZoomTarget(
      isZoomed: false,
      focalPoint: const Offset(200, 240),
    );
    await tester.pump();

    await tester.flingFrom(
      tester.getCenter(viewer) + const Offset(0, 100),
      const Offset(0, -180),
      1800,
    );
    final releasedAt = scroll.offset;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(scroll.offset, greaterThan(releasedAt + 20));

    final finger = await tester.startGesture(tester.getCenter(viewer));
    await tester.pump();
    final stoppedAt = scroll.offset;
    await tester.pump(const Duration(milliseconds: 160));
    expect(scroll.offset, closeTo(stoppedAt, 0.01));
    await finger.cancel();
    await tester.pump(const Duration(milliseconds: 400));
    expect(scroll.offset, closeTo(stoppedAt, 0.01));
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, 0.001));
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('horizontal pan and focal pinch work after zoomed scrolling', (
    tester,
  ) async {
    await open(tester);
    final viewer = find.byType(InteractiveViewer);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    final zoom = tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!;
    zoom.value = doubleTapZoomTarget(
      isZoomed: false,
      focalPoint: const Offset(200, 240),
    );
    await tester.pump();
    await tester.dragFrom(tester.getCenter(viewer), const Offset(0, -300));
    await flush(tester);
    expect(scroll.offset, greaterThan(50));
    final scrolledAt = scroll.offset;
    final oldX = zoom.value.storage[12];
    await tester.dragFrom(tester.getCenter(viewer), const Offset(-120, 0));
    await flush(tester);
    expect(zoom.value.storage[12], lessThan(oldX - 50));
    expect(scroll.offset, closeTo(scrolledAt, 0.01));

    final centre = tester.getCenter(viewer);
    final a = await tester.startGesture(centre - const Offset(60, 0));
    final b = await tester.startGesture(centre + const Offset(60, 0));
    await tester.pump();
    // Establish the pinch, then check that subsequent scaling keeps the same
    // document point at its centre even though the list is already scrolled.
    await a.moveBy(const Offset(-12, 0));
    await b.moveBy(const Offset(12, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final localY = centre.dy - tester.getTopLeft(viewer).dy;
    double focalDocumentY() =>
        scroll.offset +
        (localY - zoom.value.storage[13]) / zoom.value.getMaxScaleOnAxis();
    final focalBefore = focalDocumentY();
    final scaleBefore = zoom.value.getMaxScaleOnAxis();
    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(-8, 0));
      await b.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(zoom.value.getMaxScaleOnAxis(), greaterThan(scaleBefore));
    expect(focalDocumentY(), closeTo(focalBefore, 1));
    await a.up();
    await b.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });
}

/// A minimal multi-page PDF; the viewer only needs it to parse and count.
File _writePdf(Directory dir, String name, {required int pages}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '', // page tree, filled in below
  ];
  final kids = <String>[];
  for (var i = 0; i < pages; i++) {
    final contentId = 3 + pages + i;
    kids.add('${3 + i} 0 R');
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Contents $contentId 0 R >>',
    );
  }
  for (var i = 0; i < pages; i++) {
    final body = '0 0 1 rg 72 ${600 - i * 20} 300 100 re f';
    objects.add('<< /Length ${body.length} >>\nstream\n$body\nendstream');
  }
  objects[1] = '<< /Type /Pages /Kids [${kids.join(' ')}] /Count $pages >>';

  final out = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );

  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(Uint8List.fromList(out.toString().codeUnits));
  return file;
}
