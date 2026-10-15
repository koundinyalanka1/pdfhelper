import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/doc_kind.dart';
import 'package:pdfhelper/services/library_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Content does not have to be a valid PDF — the sweep matches on
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
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    root = Directory.systemTemp.createTempSync('pdf_library_test');
    // Static sweep state is process-wide; without this a later test would
    // read the previous test's results out of memory.
    LibraryService.resetForTesting();
  });

  tearDown(() async {
    await LibraryService.settleForTesting();
    if (root.existsSync()) root.deleteSync(recursive: true);
    FakePathProvider.restore();
  });

  group('walk', () {
    test('reports final counts of folders searched and PDFs found', () {
      _pdf('${root.path}/top.pdf');
      _pdf('${root.path}/a/one.pdf');
      _pdf('${root.path}/a/b/two.pdf');
      Directory('${root.path}/empty').createSync();
      final reports = <(int, int)>[];

      LibraryService.walkForTesting([
        root.path,
      ], onProgress: (folders, pdfs) => reports.add((folders, pdfs)));

      // root, a, a/b and empty: the last report is always the finished walk.
      expect(reports.last, (4, 3));
    });

    test('finds PDFs regardless of extension case', () {
      _pdf('${root.path}/lower.pdf');
      _pdf('${root.path}/UPPER.PDF');
      _pdf('${root.path}/Mixed.Pdf');

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'lower.pdf',
        'UPPER.PDF',
        'Mixed.Pdf',
      });
    });

    test('lists documents of every kind and nothing else', () {
      _pdf('${root.path}/keep.pdf');
      for (final name in [
        'letter.docx',
        'old letter.doc',
        'accounts.xlsx',
        'list.csv',
        'talk.pptx',
        'report.odt',
        'notes.txt',
        'readme.md',
        'photo.jpg',
        'archive.pdf.zip',
        'backup.tar',
        'backup.tar.gz',
        'photos.7z',
        'script.py',
        'data.json',
      ]) {
        File('${root.path}/$name').writeAsStringSync('hello');
      }

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'keep.pdf',
        'letter.docx',
        'old letter.doc',
        'accounts.xlsx',
        'list.csv',
        'talk.pptx',
        'report.odt',
        'notes.txt',
        'readme.md',
        'archive.pdf.zip',
      });
      final kinds = {for (final e in found) e.name: e.kind};
      expect(kinds['letter.docx'], DocKind.word);
      expect(kinds['list.csv'], DocKind.sheet);
      expect(kinds['talk.pptx'], DocKind.slides);
      expect(kinds['notes.txt'], DocKind.text);
      expect(kinds['archive.pdf.zip'], DocKind.archive);
      expect(found.firstWhere((e) => e.name == 'old letter.doc').title, 'old letter');
      expect(found.firstWhere((e) => e.name == 'archive.pdf.zip').title, 'archive.pdf');
    });

    test('lists ZIP files and flat OpenDocument files wherever they are', () {
      for (final name in [
        'Download/Statements 2026.zip',
        'WhatsApp/Media/Documents/Photos.ZIP',
        'Documents/Budget.fods',
        'Documents/Letter.fodt',
        'Documents/Talk.fodp',
        'Android/media/app/cache.tar.gz',
        'DCIM/Camera/IMG_0001.jpg',
        'Pictures/scan.heic',
      ]) {
        File('${root.path}/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('hello');
      }

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'Statements 2026.zip',
        'Photos.ZIP',
        'Budget.fods',
        'Letter.fodt',
        'Talk.fodp',
      });
      final zip = found.firstWhere((e) => e.name == 'Photos.ZIP');
      expect(zip.kind, DocKind.archive);
      expect(zip.title, 'Photos');
      expect(zip.folder, 'Documents');
      expect(found.firstWhere((e) => e.name == 'Budget.fods').kind, DocKind.sheet);
    });

    test(
      'includes empty PDFs so the file list does not silently hide them',
      () {
        _pdf('${root.path}/real.pdf');
        File('${root.path}/empty.pdf').writeAsStringSync('');

        final found = LibraryService.walkForTesting([root.path]);

        expect(found.map((e) => e.name).toSet(), {'real.pdf', 'empty.pdf'});
      },
    );

    test('includes hidden PDFs and PDFs in hidden directories', () {
      _pdf('${root.path}/visible.pdf');
      _pdf('${root.path}/.secret.pdf');
      _pdf('${root.path}/.hidden/inside.pdf');

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'visible.pdf',
        '.secret.pdf',
        'inside.pdf',
      });
    });

    test('does not exclude user folders based on their names', () {
      _pdf('${root.path}/keep.pdf');
      _pdf('${root.path}/cache/cached.pdf');
      _pdf('${root.path}/Caches/cached2.pdf');
      _pdf('${root.path}/lost+found/orphan.pdf');
      _pdf('${root.path}/node_modules/dep/doc.pdf');

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'keep.pdf',
        'cached.pdf',
        'cached2.pdf',
        'orphan.pdf',
        'doc.pdf',
      });
    });

    test('scans every readable Android folder, including Android/media', () {
      // Android/media is shared storage used by messaging apps. It must be
      // included in the full-storage scan.
      _pdf('${root.path}/Android/data/com.example/private.pdf');
      _pdf('${root.path}/Android/obb/com.example/blob.pdf');
      _pdf('${root.path}/Android/media/com.whatsapp/Documents/invoice.pdf');

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name).toSet(), {
        'private.pdf',
        'blob.pdf',
        'invoice.pdf',
      });
    });

    test('finds PDFs below the old twelve-level depth limit', () {
      var path = root.path;
      for (var i = 0; i < 20; i++) {
        path = '$path/d$i';
      }
      _pdf('$path/deep.pdf');
      _pdf('${root.path}/shallow.pdf');

      expect(
        LibraryService.walkForTesting([
          root.path,
        ]).map((e) => e.name).toSet(),
        {'shallow.pdf', 'deep.pdf'},
      );
    });

    test('finds more than 5000 PDFs and continues to a second volume', () {
      for (var i = 0; i < 5001; i++) {
        _pdf('${root.path}/internal/file$i.pdf');
      }
      _pdf('${root.path}/sdcard/Documents/on-card.pdf');

      final found = LibraryService.walkForTesting([
        '${root.path}/internal',
        '${root.path}/sdcard',
      ]);

      expect(found, hasLength(5002));
      expect(found.map((e) => e.name), contains('on-card.pdf'));
    });

    test(
      'keeps app-owned PDFs under Android/data while scanning shared media',
      () {
        final own =
            '${root.path}/Android/data/com.yourmateapps.pdfhelper/files';
        _pdf('$own/mine.pdf');
        _pdf('${root.path}/Android/data/com.other/private.pdf');
        _pdf(
          '${root.path}/Android/media/com.whatsapp/Media/.Documents/invoice.pdf',
        );
        _pdf('${root.path}/Documents/Android/data/backup.pdf');

        final found = LibraryService.walkForTesting(
          [root.path],
          appRoots: [own],
        );

        expect(found.map((e) => e.name).toSet(), {
          'mine.pdf',
          'private.pdf',
          'invoice.pdf',
          'backup.pdf',
        });
        expect(
          found.singleWhere((e) => e.name == 'mine.pdf').isAppOwned,
          isTrue,
        );
      },
    );

    test('deduplicates primary storage aliases', () {
      final volume = Directory('${root.path}/volume')..createSync();
      _pdf('${volume.path}/Download/one.pdf');
      final alias = Link('${root.path}/sdcard')..createSync(volume.path);

      final found = LibraryService.walkForTesting([alias.path, volume.path]);

      expect(found, hasLength(1));
      expect(found.single.path, '${alias.path}/Download/one.pdf');
    });

    test('excludes app cache copies without hiding user cache folders', () {
      final volume = Directory('${root.path}/volume')..createSync();
      final cache = '${volume.path}/Android/data/pdfhelper/cache';
      _pdf('$cache/opened_pdfs/intent_123_Report.pdf');
      _pdf('${volume.path}/Download/Report.pdf');
      _pdf('${volume.path}/Documents/cache/Saved.pdf');
      _pdf('${volume.path}/Android/data/pdfhelper/cache-backup/Backup.pdf');
      final alias = Link('${root.path}/sdcard')..createSync(volume.path);

      final found = LibraryService.walkForTesting(
        [alias.path, volume.path],
        excludedRoots: [cache],
      );

      expect(found.map((entry) => entry.name).toSet(), {
        'Report.pdf',
        'Saved.pdf',
        'Backup.pdf',
      });
      expect(found, hasLength(3));
    });

    test('uses the supplied current-user storage root', () {
      _pdf('${root.path}/storage/emulated/10/Download/work.pdf');
      _pdf('${root.path}/storage/emulated/0/Download/personal.pdf');

      final found = LibraryService.walkForTesting([
        '${root.path}/storage/emulated/10',
      ]);

      expect(found.map((e) => e.name), ['work.pdf']);
    });

    test('does not follow a directory symlink back into itself', () {
      _pdf('${root.path}/docs/a.pdf');
      Link('${root.path}/docs/loop').createSync(root.path);

      final found = LibraryService.walkForTesting([root.path]);

      expect(found.map((e) => e.name), ['a.pdf']);
    });

    test('survives an unreadable directory', () {
      _pdf('${root.path}/readable.pdf');
      final locked = Directory('${root.path}/locked')..createSync();
      _pdf('${locked.path}/hidden.pdf');
      Process.runSync('chmod', ['000', locked.path]);

      try {
        final found = LibraryService.walkForTesting([root.path]);
        expect(found.map((e) => e.name), contains('readable.pdf'));
      } finally {
        Process.runSync('chmod', ['755', locked.path]);
      }
    });

    test('records size, folder and modified time', () {
      final file = _pdf('${root.path}/Reports/Q3.pdf', body: '%PDF-1.7 xxxxx');

      final found = LibraryService.walkForTesting([root.path]);

      expect(found, hasLength(1));
      final entry = found.single;
      expect(entry.name, 'Q3.pdf');
      expect(entry.title, 'Q3');
      expect(entry.folder, 'Reports');
      expect(entry.sizeBytes, file.lengthSync());
      expect(entry.modifiedMs, file.statSync().modified.millisecondsSinceEpoch);
    });

    test('flags files under an app root as app-owned', () {
      _pdf('${root.path}/shared/outside.pdf');
      _pdf('${root.path}/appdir-backup/not-mine.pdf');
      _pdf('${root.path}/appdir/mine.pdf');

      final found = LibraryService.walkForTesting(
        [root.path],
        appRoots: ['${root.path}/appdir'],
      );

      final byName = {for (final e in found) e.name: e};
      expect(byName['mine.pdf']!.isAppOwned, isTrue);
      expect(byName['outside.pdf']!.isAppOwned, isFalse);
      expect(byName['not-mine.pdf']!.isAppOwned, isFalse);
    });

    test('never returns the same file twice from overlapping roots', () {
      _pdf('${root.path}/docs/a.pdf');

      final found = LibraryService.walkForTesting([
        root.path,
        '${root.path}/docs',
      ]);

      expect(found, hasLength(1));
    });

    test('returns nothing for a root that does not exist', () {
      final found = LibraryService.walkForTesting(['${root.path}/nope']);
      expect(found, isEmpty);
    });

    test('an unavailable volume does not prevent scanning the next one', () {
      _pdf('${root.path}/mounted/Download/keep.pdf');

      final found = LibraryService.walkForTesting([
        '${root.path}/unmounted',
        '${root.path}/mounted',
      ]);

      expect(found.map((e) => e.name), ['keep.pdf']);
    });
  });

  group('LibraryEntry serialization', () {
    test('round-trips through JSON', () {
      const entry = LibraryEntry(
        path: '/a/b/Report.pdf',
        name: 'Report.pdf',
        sizeBytes: 4096,
        modifiedMs: 1700000000000,
        folder: 'b',
        isAppOwned: true,
      );

      final restored = LibraryEntry.fromJson(entry.toJson())!;

      expect(restored.path, entry.path);
      expect(restored.name, entry.name);
      expect(restored.sizeBytes, entry.sizeBytes);
      expect(restored.modifiedMs, entry.modifiedMs);
      expect(restored.folder, entry.folder);
      expect(restored.isAppOwned, entry.isAppOwned);
    });

    test('rejects malformed records instead of throwing', () {
      expect(LibraryEntry.fromJson(null), isNull);
      expect(LibraryEntry.fromJson('nonsense'), isNull);
      expect(LibraryEntry.fromJson({'n': 'no path.pdf'}), isNull);
      expect(LibraryEntry.fromJson({'p': '/a.pdf'}), isNull);
    });

    test('tolerates missing optional fields', () {
      final entry = LibraryEntry.fromJson({'p': '/a.pdf', 'n': 'a.pdf'})!;
      expect(entry.sizeBytes, 0);
      expect(entry.modifiedMs, 0);
      expect(entry.folder, '');
      expect(entry.isAppOwned, isFalse);
    });

    test('title strips only a trailing .pdf', () {
      LibraryEntry named(String name) => LibraryEntry(
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

      final found = await LibraryService.scan();
      await LibraryService.settleForTesting();

      expect(found.map((e) => e.name).toSet(), {'merged.pdf', 'support.pdf'});
      expect(found.every((e) => e.isAppOwned), isTrue);
      expect(
        File('${fake.support.path}/pdf_library_cache.json').existsSync(),
        isTrue,
        reason: 'a completed sweep should be readable on the next cold start',
      );
    });

    test('publishes progress while sweeping and clears it after', () async {
      final fake = FakePathProvider.install(root);
      _pdf('${fake.documents.path}/one.pdf');
      final seen = <LibraryScanProgress?>[];
      void record() => seen.add(LibraryService.progress.value);
      LibraryService.progress.addListener(record);
      addTearDown(() => LibraryService.progress.removeListener(record));

      expect(LibraryService.progress.value, isNull);
      await LibraryService.scan();

      expect(seen.first, isNotNull, reason: 'a sweep announces itself');
      expect(LibraryService.progress.value, isNull);
    });

    test('cached() returns the previous sweep', () async {
      final fake = FakePathProvider.install(root);
      _pdf('${fake.documents.path}/one.pdf');

      await LibraryService.scan();
      final cached = await LibraryService.cached();

      expect(cached.map((e) => e.name), contains('one.pdf'));
    });

    test('a cold start reads back the ZIP files a sweep found', () async {
      final fake = FakePathProvider.install(root);
      _pdf('${fake.documents.path}/Report.pdf');
      File('${fake.documents.path}/Statements.zip').writeAsStringSync('PK');

      final scanned = await LibraryService.scan();
      await LibraryService.settleForTesting();
      expect(scanned.map((e) => e.name).toSet(), {
        'Report.pdf',
        'Statements.zip',
      });

      // Drop the sweep from memory, as a relaunch would.
      LibraryService.resetForTesting();
      final cached = await LibraryService.cached();

      expect(cached.map((e) => e.name).toSet(), {
        'Report.pdf',
        'Statements.zip',
      });
      expect(
        cached.firstWhere((e) => e.name == 'Statements.zip').kind,
        DocKind.archive,
      );
    });

    test('prune drops entries whose file is gone', () async {
      final fake = FakePathProvider.install(root);
      final keep = _pdf('${fake.documents.path}/keep.pdf');
      final gone = _pdf('${fake.documents.path}/gone.pdf');

      final scanned = await LibraryService.scan();
      expect(scanned, hasLength(2));

      gone.deleteSync();
      final alive = await LibraryService.prune(scanned);

      expect(alive.map((e) => e.path), [keep.path]);
    });

    test('describe builds an entry for a file outside every root', () async {
      FakePathProvider.install(root);
      final outside = _pdf('${root.path}/elsewhere/external.pdf');

      final entry = await LibraryService.describe(outside.path);

      expect(entry, isNotNull);
      expect(entry!.name, 'external.pdf');
      expect(entry.folder, 'elsewhere');
      expect(entry.isAppOwned, isFalse);
    });

    test('describe returns null for a missing file', () async {
      FakePathProvider.install(root);
      expect(await LibraryService.describe('${root.path}/nope.pdf'), isNull);
    });

    test('temporary files are recognized by directory identity', () async {
      final paths = FakePathProvider.install(root);
      final temp = _pdf('${paths.temporary.path}/opened_pdfs/report.pdf');
      final durable = _pdf('${paths.documents.path}/cache/report.pdf');
      final alias = Link('${root.path}/temp-alias')
        ..createSync(paths.temporary.path);

      expect(await LibraryService.isTemporaryPath(temp.path), isTrue);
      expect(
        await LibraryService.isTemporaryPath(
          '${alias.path}/opened_pdfs/report.pdf',
        ),
        isTrue,
      );
      expect(await LibraryService.isTemporaryPath(durable.path), isFalse);
    });

    test('access is app-only off Android', () async {
      expect(await LibraryService.access(), StorageAccess.appOnly);
      expect(await LibraryService.requestAccess(), StorageAccess.appOnly);
    });
  });
}
