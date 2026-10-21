import 'dart:io';

import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_raster.dart';

import '../support/text_pdf_fixture.dart';

/// A page that draws a form which draws itself four times, through the
/// renderer's nesting limit: millions of forms, each clipped to the page.
/// It used to keep a render, and the viewer's spinner, going for minutes.
File writeFormBombFixture(Directory root) {
  String stream(String dictionary, String content) =>
      '<< $dictionary /Length ${content.length} >>\nstream\n$content\nendstream';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 600] '
        '/Resources << /XObject << /X0 5 0 R >> >> /Contents 4 0 R >>',
    stream('', '/X0 Do'),
    stream(
      '/Type /XObject /Subtype /Form /BBox [0 0 600 600] '
          '/Resources << /XObject << /X0 5 0 R >> >>',
      '/X0 Do /X0 Do /X0 Do /X0 Do 0 0 1 1 re f',
    ),
  ];
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return File('${root.path}/Bomb.pdf')..writeAsStringSync(output.toString());
}

/// The library grid caches failures as well as successes, so that a file it
/// cannot render is not retried on every scroll. That negative cache used to
/// be keyed without the password, which meant an encrypted PDF stayed blank
/// even after the user had unlocked it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(PdfRaster.invalidate);

  test(
    'high-resolution uncached renders return warnings without retaining them',
    () async {
      final root = Directory.systemTemp.createTempSync('raster-warnings-');
      addTearDown(() => root.deleteSync(recursive: true));
      final pdf = writeTextPdfFixture(root, [
        'Font substitution warning',
      ], baseFont: 'UnembeddedSans');
      final rendered = await PdfRaster.renderPageWithWarnings(
        pdf.path,
        0,
        longEdge: 1800,
        useCache: false,
        throwOnError: true,
      );
      expect(rendered, isNotNull);
      expect(rendered!.bytes, isNotEmpty);
      expect(rendered.warnings, isNotEmpty);
      expect(PdfRaster.warningsFor(pdf.path, 0, longEdge: 1800), isEmpty);

      final cached = await PdfRaster.renderPageWithWarnings(pdf.path, 0);
      final hit = await PdfRaster.renderPageWithWarnings(pdf.path, 0);
      expect(hit!.warnings, cached!.warnings);
      expect(hit.warnings, isNotEmpty);
      PdfRaster.invalidate(pdf.path);
      expect(PdfRaster.warningsFor(pdf.path, 0), isEmpty);
    },
    skip: Platform.environment['PDF_CORE_LIB_PATH'] == null,
  );

  test(
    'a page that takes too long gives up instead of rendering forever',
    () async {
      final root = Directory.systemTemp.createTempSync('raster-timeout-');
      addTearDown(() => root.deleteSync(recursive: true));
      final bomb = writeFormBombFixture(root);
      final ordinary = writeTextPdfFixture(root, ['Ordinary page']);
      final timeout = PdfRaster.renderTimeout;
      addTearDown(() => PdfRaster.renderTimeout = timeout);
      PdfRaster.renderTimeout = const Duration(milliseconds: 500);

      final watch = Stopwatch()..start();
      // Null, as for any page that cannot be rendered: the viewer then shows
      // its placeholder with Retry.
      final pages = await Future.wait([
        for (var i = 0; i < 4; i++)
          PdfRaster.renderPageWithWarnings(bomb.path, 0, longEdge: 600 + i),
      ]);
      expect(pages, everyElement(isNull));
      // Three renders run at a time, so the fourth waited for one of the
      // first three to give up, and did not wait for good.
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

      // A viewer that asks for the failure is told it was a timeout.
      await expectLater(
        PdfRaster.renderPageWithWarnings(
          bomb.path,
          0,
          longEdge: 700,
          throwOnError: true,
        ),
        throwsA(isA<PdfException>().having((e) => e.code, 'code', 'TIMEOUT')),
      );
      final region = await PdfRaster.renderRegion(
        bomb.path,
        0,
        pageWidth: 2400,
        pageHeight: 2400,
        x: 0,
        y: 0,
        width: 600,
        height: 600,
      );
      expect(region, isNull);

      // The turns the timed-out renders held are free again.
      PdfRaster.renderTimeout = timeout;
      final page = await PdfRaster.renderPageWithWarnings(
        ordinary.path,
        0,
        throwOnError: true,
      );
      expect(page!.bytes, isNotEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    },
    skip: Platform.environment['PDF_CORE_LIB_PATH'] == null,
  );

  test('a failed cover is remembered so it is not retried', () async {
    const path = '/nonexistent/locked.pdf';
    expect(PdfRaster.isCoverCached(path, modifiedMs: 1), isFalse);

    // No native core under `flutter test`, so this fails and caches the miss.
    final bytes = await PdfRaster.libraryCover(path, modifiedMs: 1);
    expect(bytes, isNull);
    expect(PdfRaster.isCoverCached(path, modifiedMs: 1), isTrue);
    expect(PdfRaster.cachedCover(path, modifiedMs: 1), isNull);
  });

  test(
    'a cover cached without a password does not answer for one with',
    () async {
      const path = '/nonexistent/locked.pdf';
      await PdfRaster.libraryCover(path, modifiedMs: 1);

      expect(PdfRaster.isCoverCached(path, modifiedMs: 1), isTrue);
      // The whole point: once a password is known, the earlier failure must not
      // stand in for it.
      expect(
        PdfRaster.isCoverCached(path, modifiedMs: 1, password: 'secret'),
        isFalse,
      );
    },
  );

  test('a wrong password miss does not poison another password', () async {
    const path = '/nonexistent/locked.pdf';
    await PdfRaster.libraryCover(path, modifiedMs: 1, password: 'wrong');
    expect(
      PdfRaster.isCoverCached(path, modifiedMs: 1, password: 'wrong'),
      isTrue,
    );
    expect(
      PdfRaster.isCoverCached(path, modifiedMs: 1, password: 'correct'),
      isFalse,
    );
  });

  test(
    'a modified file re-renders rather than reusing its old cover',
    () async {
      const path = '/nonexistent/edited.pdf';
      await PdfRaster.libraryCover(path, modifiedMs: 1);
      expect(PdfRaster.isCoverCached(path, modifiedMs: 1), isTrue);
      expect(PdfRaster.isCoverCached(path, modifiedMs: 2), isFalse);
    },
  );

  test('invalidate drops one document without clearing the rest', () async {
    await PdfRaster.libraryCover('/nonexistent/a.pdf', modifiedMs: 1);
    await PdfRaster.libraryCover('/nonexistent/b.pdf', modifiedMs: 1);

    PdfRaster.invalidate('/nonexistent/a.pdf');
    expect(
      PdfRaster.isCoverCached('/nonexistent/a.pdf', modifiedMs: 1),
      isFalse,
    );
    expect(
      PdfRaster.isCoverCached('/nonexistent/b.pdf', modifiedMs: 1),
      isTrue,
    );
  });

  test('uncached renders do not accumulate warning entries', () async {
    // Library covers render with useCache: false, once per file on the
    // device. Recording warnings for them would grow a map nothing ever
    // evicts, because eviction is tied to the bitmap cache.
    for (var i = 0; i < 50; i++) {
      await PdfRaster.libraryCover('/nonexistent/file$i.pdf', modifiedMs: 1);
    }
    expect(PdfRaster.warningsFor('/nonexistent/file0.pdf', 0), isEmpty);
  });

  test('pageCountOrZero absorbs a failure the caller cannot act on', () async {
    expect(await PdfRaster.pageCountOrZero('/nonexistent/missing.pdf'), 0);
  });

  test(
    'pageCountOf surfaces the failure instead of reporting no pages',
    () async {
      // The regression this guards: returning 0 here made an encrypted document
      // indistinguishable from an empty one, so nothing ever asked for a
      // password.
      await expectLater(
        PdfRaster.pageCountOf('/nonexistent/missing.pdf'),
        throwsA(isA<Object>()),
      );
    },
  );
}
