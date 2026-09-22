import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_raster.dart';

/// The library grid caches failures as well as successes, so that a file it
/// cannot render is not retried on every scroll. That negative cache used to
/// be keyed without the password, which meant an encrypted PDF stayed blank
/// even after the user had unlocked it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(PdfRaster.invalidate);

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
