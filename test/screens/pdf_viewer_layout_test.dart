import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Page sizing in the viewer.
///
/// Pages used to be laid out with page 1's shape until each one rendered. A
/// brochure with a portrait cover and landscape spreads therefore laid every
/// spread out twice its height, then halved it once rendered — and each of
/// those resizes above the viewport pushed the page being read out of view,
/// so scrolling bounced between the same two pages.
///
/// The widget tests need the native core:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib \
///     flutter test test/screens/pdf_viewer_layout_test.dart
void main() {
  group('pageAspectRatio', () {
    test('uses the page\'s own ratio when known', () {
      expect(pageAspectRatio({0: 0.6, 3: 1.3}, 3, 0.7), 1.3);
    });

    test('borrows the nearest earlier page, not page 1', () {
      expect(pageAspectRatio({0: 0.6, 1: 1.3}, 5, 0.7), 1.3);
    });

    test('falls back when nothing before it is known', () {
      expect(pageAspectRatio({4: 1.3}, 2, 0.7), 0.7);
      expect(pageAspectRatio({}, 0, 0.7), 0.7);
    });

    test('ignores unusable ratios', () {
      expect(pageAspectRatio({0: 0.6, 1: 0}, 1, 0.7), 0.6);
      expect(pageAspectRatio({0: 0.6, 1: double.infinity}, 1, 0.7), 0.6);
      expect(pageAspectRatio({0: 0.6, 1: double.nan}, 1, 0.7), 0.6);
    });
  });

  group('pageHeight', () {
    test('divides width by ratio', () {
      expect(pageHeight(400, 2), 200);
    });

    test('treats a missing ratio as A4 portrait', () {
      expect(pageHeight(707.1, 0), closeTo(1000, 0.01));
      expect(pageHeight(707.1, double.infinity), closeTo(1000, 0.01));
      expect(pageHeight(707.1, double.nan), closeTo(1000, 0.01));
    });
  });

  final libPath = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (libPath.isEmpty || !File(libPath).existsSync()) return;

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File pdf;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('pdfhelper_layout');
    FakePathProvider.install(root);
    // A portrait cover ahead of landscape pages, like the brochure that
    // exposed the bug.
    pdf = _writePdf(root, 'Brochure.pdf', [
      (612, 792),
      for (var i = 0; i < 5; i++) (792, 612),
    ]);
  });

  tearDown(() async {
    FakePathProvider.restore();
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Let isolate work (reading sizes, rendering) finish, then rebuild. A
  /// widget test's fake-async zone never completes `Isolate.run` on its own.
  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: PdfViewerScreen(pdfPath: pdf.path, title: 'Brochure.pdf'),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(ListView), findsOneWidget);
  }

  Finder page(int index) => find.byKey(ValueKey('${pdf.path}#$index'));

  testWidgets('a page keeps its place while the pages above it render', (
    tester,
  ) async {
    await open(tester);
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    // Past the pages rendered on opening, so the page above the one being
    // read is built fresh and still unrendered — where the bounce happened.
    controller.jumpTo(2800);
    await tester.pump();

    // The page under the top edge of the list: the page being read.
    final listTop = tester.getTopLeft(find.byType(ListView)).dy;
    final reading = [
      for (var i = 0; i < 6; i++)
        if (page(i).evaluate().isNotEmpty &&
            tester.getRect(page(i)).top <= listTop &&
            tester.getRect(page(i)).bottom > listTop)
          i,
    ].single;
    final before = tester.getTopLeft(page(reading));

    await settle(tester, rounds: 30);

    expect(
      tester.getTopLeft(page(reading)),
      before,
      reason: 'pages rendering must not move page ${reading + 1}',
    );
  });

  testWidgets('Go to page lands on the page asked for', (tester) async {
    await open(tester);
    await tester.tap(find.text('1 / 6'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Go'));
    await tester.pump();

    final listTop = tester.getTopLeft(find.byType(ListView)).dy;
    // The list pads its first page by 6, so a page scrolled to the top sits
    // 6 below the list's edge.
    expect(tester.getTopLeft(page(2)).dy, closeTo(listTop + 6, 1));

    await settle(tester, rounds: 10);
  });

  testWidgets(
    'Go to page keeps invalid input open and resets zoom on success',
    (tester) async {
      await open(tester);
      final zoom = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      zoom.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump();
      await tester.tap(find.text('1 / 6'));
      await tester.pumpAndSettle();

      for (final invalid in ['', '0', '7', 'abc']) {
        await tester.enterText(find.byType(TextField), invalid);
        await tester.tap(find.text('Go'));
        await tester.pump();
        expect(find.text('Enter a page from 1 to 6'), findsOneWidget);
        expect(find.text('Go to page'), findsOneWidget);
      }

      await tester.enterText(find.byType(TextField), '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, rounds: 10);
      expect(find.text('Go to page'), findsNothing);
      expect(zoom.value.getMaxScaleOnAxis(), 1);
      expect(find.text('3 / 6'), findsOneWidget);
    },
  );
}

/// A minimal PDF with one page per entry in [sizes] (width, height in points).
File _writePdf(Directory dir, String name, List<(int, int)> sizes) {
  final pages = sizes.length;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '', // page tree, filled in below
  ];
  final kids = <String>[];
  for (var i = 0; i < pages; i++) {
    final (width, height) = sizes[i];
    kids.add('${3 + i} 0 R');
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
      '/Contents ${3 + pages + i} 0 R >>',
    );
  }
  for (var i = 0; i < pages; i++) {
    final body = '0 0 1 rg 72 ${300 - i * 20} 300 100 re f';
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
