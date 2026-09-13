import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';

import '../support/fake_path_provider.dart';

/// Writes a file with enough bytes that the scanner's zero-length filter
/// keeps it. Content does not have to be a valid PDF — the sweep matches on
/// the extension, exactly like a file manager.
File _pdf(String path, {String body = '%PDF-1.7 test'}) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_library_test');
    // Static sweep state is process-wide; without this a later test would
    // read the previous test's results out of memory.
    PdfLibraryService.resetForTesting();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    FakePathProvider.restore();
  });

  group('walk', () {
    test('finds PDFs regardless of extension case', () {
      _pdf('${root.path}/lower.pdf');
      _pdf('${root.path}/UPPER.PDF');
      _pdf('${root.path}/Mixed.Pdf');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(
        found.map((e) => e.name).toSet(),
        {'lower.pdf', 'UPPER.PDF', 'Mixed.Pdf'},
      );
    });

    test('ignores non-PDF files', () {
      _pdf('${root.path}/keep.pdf');
      File('${root.path}/notes.txt').writeAsStringSync('hello');
      File('${root.path}/archive.pdf.zip').writeAsStringSync('hello');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['keep.pdf']);
    });

    test('skips zero-length files', () {
      _pdf('${root.path}/real.pdf');
      File('${root.path}/empty.pdf').writeAsStringSync('');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['real.pdf']);
    });

    test('skips hidden files and hidden directories', () {
      _pdf('${root.path}/visible.pdf');
      _pdf('${root.path}/.secret.pdf');
      _pdf('${root.path}/.hidden/inside.pdf');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['visible.pdf']);
    });

    test('skips cache-like directories', () {
      _pdf('${root.path}/keep.pdf');
      _pdf('${root.path}/cache/cached.pdf');
      _pdf('${root.path}/Caches/cached2.pdf');
      _pdf('${root.path}/lost+found/orphan.pdf');
      _pdf('${root.path}/node_modules/dep/doc.pdf');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['keep.pdf']);
    });

    test('skips Android/data and Android/obb but keeps Android/media', () {
      // Android/media is where messaging apps put received documents, and it
      // stays readable without All files access — excluding it would drop the
      // single largest source of PDFs on a real phone.
      _pdf('${root.path}/Android/data/com.example/private.pdf');
      _pdf('${root.path}/Android/obb/com.example/blob.pdf');
      _pdf('${root.path}/Android/media/com.whatsapp/Documents/invoice.pdf');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['invoice.pdf']);
    });

    test('honours the depth cap', () {
      var path = root.path;
      for (var i = 0; i < 15; i++) {
        path = '$path/d$i';
      }
      _pdf('$path/deep.pdf');
      _pdf('${root.path}/shallow.pdf');

      expect(
        PdfLibraryService.walkForTesting([root.path], maxDepth: 12)
            .map((e) => e.name),
        ['shallow.pdf'],
      );
      expect(
        PdfLibraryService.walkForTesting([root.path], maxDepth: 20)
            .map((e) => e.name)
            .toSet(),
        {'shallow.pdf', 'deep.pdf'},
      );
    });

    test('honours the file cap', () {
      for (var i = 0; i < 12; i++) {
        _pdf('${root.path}/file$i.pdf');
      }

      final found = PdfLibraryService.walkForTesting([root.path], maxFiles: 5);

      expect(found, hasLength(5));
    });

    test('reaches shallow files before deep ones', () {
      // Breadth-first matters: when the cap or the budget cuts a sweep short,
      // what survives should be the documents nearest the top of the tree.
      _pdf('${root.path}/a/b/c/d/deep.pdf');
      _pdf('${root.path}/top.pdf');

      final found = PdfLibraryService.walkForTesting([root.path], maxFiles: 1);

      expect(found.map((e) => e.name), ['top.pdf']);
    });

    test('does not follow a directory symlink back into itself', () {
      _pdf('${root.path}/docs/a.pdf');
      Link('${root.path}/docs/loop').createSync(root.path);

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['a.pdf']);
    });

    test('survives an unreadable directory', () {
      _pdf('${root.path}/readable.pdf');
      final locked = Directory('${root.path}/locked')..createSync();
      _pdf('${locked.path}/hidden.pdf');
      Process.runSync('chmod', ['000', locked.path]);

      try {
        final found = PdfLibraryService.walkForTesting([root.path]);
        expect(found.map((e) => e.name), contains('readable.pdf'));
      } finally {
        Process.runSync('chmod', ['755', locked.path]);
      }
    });

    test('records size, folder and modified time', () {
      final file = _pdf('${root.path}/Reports/Q3.pdf', body: '%PDF-1.7 xxxxx');

      final found = PdfLibraryService.walkForTesting([root.path]);

      expect(found, hasLength(1));
      final entry = found.single;
      expect(entry.name, 'Q3.pdf');
      expect(entry.title, 'Q3');
      expect(entry.folder, 'Reports');
      expect(entry.sizeBytes, file.lengthSync());
      expect(
        entry.modifiedMs,
        file.statSync().modified.millisecondsSinceEpoch,
      );
    });

    test('flags files under an app root as app-owned', () {
      _pdf('${root.path}/shared/outside.pdf');
      _pdf('${root.path}/appdir/mine.pdf');

      final found = PdfLibraryService.walkForTesting(
        [root.path],
        appRoots: ['${root.path}/appdir'],
      );

      final byName = {for (final e in found) e.name: e};
      expect(byName['mine.pdf']!.isAppOwned, isTrue);
      expect(byName['outside.pdf']!.isAppOwned, isFalse);
    });

    test('never returns the same file twice from overlapping roots', () {
      _pdf('${root.path}/docs/a.pdf');

      final found = PdfLibraryService.walkForTesting([
        root.path,
        '${root.path}/docs',
      ]);

      expect(found, hasLength(1));
    });

    test('returns nothing for a root that does not exist', () {
      final found = PdfLibraryService.walkForTesting(['${root.path}/nope']);
      expect(found, isEmpty);
    });
  });

  group('PdfFileEntry serialization', () {
    test('round-trips through JSON', () {
      const entry = PdfFileEntry(
        path: '/a/b/Report.pdf',
        name: 'Report.pdf',
        sizeBytes: 4096,
        modifiedMs: 1700000000000,
        folder: 'b',
        isAppOwned: true,
      );

      final restored = PdfFileEntry.fromJson(entry.toJson())!;

      expect(restored.path, entry.path);
      expect(restored.name, entry.name);
      expect(restored.sizeBytes, entry.sizeBytes);
      expect(restored.modifiedMs, entry.modifiedMs);
      expect(restored.folder, entry.folder);
      expect(restored.isAppOwned, entry.isAppOwned);
    });

    test('rejects malformed records instead of throwing', () {
      expect(PdfFileEntry.fromJson(null), isNull);
      expect(PdfFileEntry.fromJson('nonsense'), isNull);
      expect(PdfFileEntry.fromJson({'n': 'no path.pdf'}), isNull);
      expect(PdfFileEntry.fromJson({'p': '/a.pdf'}), isNull);
    });

    test('tolerates missing optional fields', () {
      final entry = PdfFileEntry.fromJson({'p': '/a.pdf', 'n': 'a.pdf'})!;
      expect(entry.sizeBytes, 0);
      expect(entry.modifiedMs, 0);
      expect(entry.folder, '');
      expect(entry.isAppOwned, isFalse);
    });

    test('title strips only a trailing .pdf', () {
      PdfFileEntry named(String name) => PdfFileEntry(
        path: '/x/$name',
        name: name,
        sizeBytes: 1,
        modifiedMs: 0,
        folder: 'x',
        isAppOwned: false,
      );

      expect(named('Report.pdf').title, 'Report');
      expect(named('My.pdf.backup.pdf').title, 'My.pdf.backup');
      expect(named('nodotpdf').title, 'nodotpdf');
      expect(named('.pdf').title, '.pdf');
    });
  });

  group('scan', () {
    test('walks the app directories and caches the result', () async {
      final fake = FakePathProvider.install(root);
      _pdf('${fake.documents.path}/merged.pdf');
      _pdf('${fake.support.path}/notes/support.pdf');

      final found = await PdfLibraryService.scan();
      await PdfLibraryService.settleForTesting();

      expect(found.map((e) => e.name).toSet(), {'merged.pdf', 'support.pdf'});
      expect(found.every((e) => e.isAppOwned), isTrue);
      expect(
        File('${fake.support.path}/pdf_library_cache.json').existsSync(),
        isTrue,
        reason: 'a completed sweep should be readable on the next cold start',
      );
    });

    test('cached() returns the previous sweep', () async {
      final fake = FakePathProvider.install(root);
      _pdf('${fake.documents.path}/one.pdf');

      await PdfLibraryService.scan();
      final cached = await PdfLibraryService.cached();

      expect(cached.map((e) => e.name), contains('one.pdf'));
    });

    test('prune drops entries whose file is gone', () async {
      final fake = FakePathProvider.install(root);
      final keep = _pdf('${fake.documents.path}/keep.pdf');
      final gone = _pdf('${fake.documents.path}/gone.pdf');

      final scanned = await PdfLibraryService.scan();
      expect(scanned, hasLength(2));

      gone.deleteSync();
      final alive = await PdfLibraryService.prune(scanned);

      expect(alive.map((e) => e.path), [keep.path]);
    });

    test('describe builds an entry for a file outside every root', () async {
      FakePathProvider.install(root);
      final outside = _pdf('${root.path}/elsewhere/external.pdf');

      final entry = await PdfLibraryService.describe(outside.path);

      expect(entry, isNotNull);
      expect(entry!.name, 'external.pdf');
      expect(entry.folder, 'elsewhere');
      expect(entry.isAppOwned, isFalse);
    });

    test('describe returns null for a missing file', () async {
      FakePathProvider.install(root);
      expect(await PdfLibraryService.describe('${root.path}/nope.pdf'), isNull);
    });

    test('access is app-only off Android', () async {
      expect(await PdfLibraryService.access(), StorageAccess.appOnly);
      expect(await PdfLibraryService.requestAccess(), StorageAccess.appOnly);
    });
  });
}
