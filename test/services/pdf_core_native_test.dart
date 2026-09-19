import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_raster.dart';

/// Exercises the real Rust core through the same Dart API the app uses.
///
/// The rest of the suite runs without the native library, so the FFI path —
/// including the warnings channel, which is a thread-local read immediately
/// after the render that set it — is otherwise never executed at all.
///
/// Run with the library path set:
///   PDF_CORE_LIB_PATH=packages/flutter_pdf_core/rust/target/release/libpdf_ffi.dylib \
///     flutter test test/services/pdf_core_native_test.dart
void main() {
  final libPath = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (libPath.isEmpty || !File(libPath).existsSync()) {
    // Nothing to test against; `flutter test` on a machine without a built
    // core should stay green.
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pdfcore_native');
    PdfRaster.invalidate();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Smallest possible one-page PDF with the given page body.
  File writePdf(String name, String content, {String extraResources = ''}) {
    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Resources << /Font << /F1 5 0 R >> $extraResources >> /Contents 4 0 R >>',
      '<< /Length ${content.length} >>\nstream\n$content\nendstream',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ];
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

  test('renders a page and reports the substituted font', () async {
    final pdf = writePdf(
      'text.pdf',
      'BT /F1 36 Tf 72 700 Td (Hello) Tj ET',
    );

    final bytes = await PdfRaster.renderPage(pdf.path, 0, longEdge: 400);
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(100));
    // PNG magic, so we know a real image came back.
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

    // Helvetica is not embedded, so the page is drawn with a stand-in — and
    // the renderer has to say so rather than passing it off as exact.
    final warnings = PdfRaster.warningsFor(pdf.path, 0, longEdge: 400);
    expect(warnings, isNotEmpty);
    expect(warnings.first, contains('substitute font'));
  });

  test('a page drawn exactly reports no warnings', () async {
    final pdf = writePdf('shapes.pdf', '0 0 1 rg 72 600 300 100 re f');
    final bytes = await PdfRaster.renderPage(pdf.path, 0, longEdge: 400);
    expect(bytes, isNotNull);
    expect(PdfRaster.warningsFor(pdf.path, 0, longEdge: 400), isEmpty);
  });

  test('page count comes back for a readable file', () async {
    final pdf = writePdf('count.pdf', '0 0 1 rg 10 10 50 50 re f');
    expect(await PdfRaster.pageCountOf(pdf.path), 1);
  });

  test('a file that is not a PDF surfaces an error rather than zero pages',
      () async {
    final junk = File('${dir.path}/not.pdf')..writeAsBytesSync([1, 2, 3, 4]);
    // The regression that started all this: reporting 0 here made a locked or
    // broken file look like an empty one, so nothing ever asked why.
    await expectLater(PdfRaster.pageCountOf(junk.path), throwsA(isA<Object>()));
    expect(await PdfRaster.pageCountOrZero(junk.path), 0);
  });
}
