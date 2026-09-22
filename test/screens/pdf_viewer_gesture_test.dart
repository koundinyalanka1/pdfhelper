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

  testWidgets('lifting back to one finger restores scrolling',
      (tester) async {
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
    objects.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Contents $contentId 0 R >>');
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
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');

  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(Uint8List.fromList(out.toString().codeUnits));
  return file;
}
