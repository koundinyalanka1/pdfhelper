import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late FakePathProvider paths;
  late File working;
  late File public;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PublicPdfSaveService.resetForTesting();
    RecentFilesService.resetCacheForTesting();
    PdfLibraryService.resetForTesting();
    root = Directory.systemTemp.createTempSync('pdf_document_lifecycle');
    paths = FakePathProvider.install(root);
    working = File('${paths.documents.path}/Report.pdf')
      ..writeAsStringSync('%PDF-1.7 working');
    final folder = Directory('${paths.documents.path}/public')..createSync();
    public = File('${folder.path}/Report.pdf')
      ..writeAsStringSync('%PDF-1.7 public');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await PdfLibraryService.settleForTesting();
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> seed({String? uri, List<PublicPdfCopy>? copies}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'publicPdfExports',
      jsonEncode({
        working.path: uri == null && copies == null
            ? public.path
            : {
                'id': 'document-42',
                'copies':
                    (copies ?? [PublicPdfCopy(path: public.path, uri: uri)])
                        .map((copy) => copy.toJson())
                        .toList(),
              },
      }),
    );
    await RecentFilesService.markOpened(working.path);
    await RecentFilesService.markOpened(public.path);
    await RecentFilesService.toggleStar(working.path);
    await RecentFilesService.toggleStar(public.path);
  }

  test(
    'deleting either alias removes both legacy copies and every list reference',
    () async {
      for (final deletePublic in [true, false]) {
        working.writeAsStringSync('%PDF-1.7 working');
        public.writeAsStringSync('%PDF-1.7 public');
        await seed();
        final found = await PdfLibraryService.scan();
        expect(found.map((entry) => entry.path), [public.path]);
        final result = await PdfLibraryService.deleteDocument(
          deletePublic ? public.path : working.path,
        );
        expect(result.completed, isTrue);
        expect(working.existsSync(), isFalse);
        expect(public.existsSync(), isFalse);
        expect(await PublicPdfSaveService.documents(), isEmpty);
        expect(await RecentFilesService.recents(), isEmpty);
        expect(await RecentFilesService.starred(), isEmpty);
        expect(
          await PdfLibraryService.scan(),
          isEmpty,
          reason: 'working copy must never reappear',
        );
      }
    },
  );

  test(
    'rename migrates legacy records and survives a cold rescan without duplicates',
    () async {
      await seed();
      final result = await PdfLibraryService.renameDocument(
        public.path,
        'Paid.pdf',
      );
      expect(result.completed, isTrue);
      final newWorking = '${working.parent.path}/Paid.pdf';
      final newPublic = '${public.parent.path}/Paid.pdf';
      expect(File(newWorking).existsSync(), isTrue);
      expect(File(newPublic).existsSync(), isTrue);
      expect(working.existsSync(), isFalse);
      expect(public.existsSync(), isFalse);
      final document = (await PublicPdfSaveService.documents()).single;
      expect(document.id, working.path);
      expect(document.workingPath, newWorking);
      expect(document.copies.single.path, newPublic);
      expect(document.copies.single.uri, Uri.file(newPublic).toString());
      await PdfLibraryService.settleForTesting();
      PdfLibraryService.resetForTesting();
      RecentFilesService.resetCacheForTesting();
      expect((await PdfLibraryService.scan()).map((entry) => entry.path), [
        newPublic,
      ]);
      expect(await RecentFilesService.recents(), [newPublic]);
      expect(await RecentFilesService.starred(), {newPublic});
    },
  );

  test('rename never replaces an existing working or public PDF', () async {
    await seed();
    final other = File('${public.parent.path}/Paid.pdf')
      ..writeAsStringSync('important');
    final result = await PdfLibraryService.renameDocument(
      working.path,
      'Paid.pdf',
    );
    expect(result.completed, isFalse);
    expect(result.warning, contains('already exists'));
    expect(other.readAsStringSync(), 'important');
    expect(working.existsSync(), isTrue);
    expect(public.existsSync(), isTrue);
    expect(
      (await PublicPdfSaveService.documents()).single.copies.single.path,
      public.path,
    );
  });

  test(
    'scoped-storage delete uses the URI when public filesystem access is unavailable',
    () async {
      const uri = 'content://media/external_primary/downloads/42';
      await seed(uri: uri);
      public
          .deleteSync(); // The sweep cannot see this copy; the provider still can.
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        expect(call.method, 'deletePublicPdf');
        expect(call.arguments, {'uri': uri, 'publicPath': public.path});
        return true;
      });
      expect((await PdfLibraryService.scan()).single.path, working.path);
      final result = await PdfLibraryService.deleteDocument(working.path);
      expect(result.completed, isTrue);
      expect(calls, hasLength(1));
      expect(working.existsSync(), isFalse);
      expect(await PublicPdfSaveService.documents(), isEmpty);
      expect(await RecentFilesService.starred(), isEmpty);
    },
  );

  test(
    'scoped-storage rename records provider collision name and stable URI',
    () async {
      const uri = 'content://media/external_primary/downloads/42';
      await seed(uri: uri);
      public.deleteSync();
      final newPublic = '${public.parent.path}/Paid (2).pdf';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'renamePublicPdf');
        expect(call.arguments, {
          'uri': uri,
          'publicPath': public.path,
          'displayName': 'Paid.pdf',
        });
        return {'uri': uri, 'name': 'Paid (2).pdf', 'publicPath': newPublic};
      });
      final result = await PdfLibraryService.renameDocument(
        working.path,
        'Paid.pdf',
      );
      expect(result.completed, isTrue);
      final record = (await PublicPdfSaveService.documents()).single;
      expect(record.id, 'document-42');
      expect(record.copies.single.path, newPublic);
      expect(record.copies.single.uri, uri);
      expect(File(record.workingPath).existsSync(), isTrue);
      expect((await PdfLibraryService.scan()).single.path, record.workingPath);
      expect(await RecentFilesService.recents(), [record.workingPath]);
      expect(await RecentFilesService.starred(), {record.workingPath});
    },
  );

  for (final rename in [false, true]) {
    test(
      'inaccessible public copy prevents ${rename ? 'rename' : 'delete'} from claiming success',
      () async {
        const uri = 'content://media/external_primary/downloads/42';
        await seed(uri: uri);
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'PUBLIC_MUTATION_FAILED',
            message: 'Access denied',
          );
        });
        final result = rename
            ? await PdfLibraryService.renameDocument(working.path, 'Paid.pdf')
            : await PdfLibraryService.deleteDocument(working.path);
        expect(result.completed, isFalse);
        expect(result.warning, contains('Access denied'));
        expect(result.removedPaths, isEmpty);
        expect(result.renamedPaths, isEmpty);
        expect(working.existsSync(), isTrue);
        expect(public.existsSync(), isTrue);
        expect(
          (await PublicPdfSaveService.documents()).single.copies.single.uri,
          uri,
        );
      },
    );
  }

  test(
    'partially deleted exports stay tracked and a retry finishes remaining copies',
    () async {
      const first = 'content://media/external_primary/downloads/1';
      const second = 'content://media/external_primary/downloads/2';
      final another = File('${public.parent.path}/Report (2).pdf')
        ..writeAsStringSync('second export');
      await seed(
        copies: [
          PublicPdfCopy(path: public.path, uri: first),
          PublicPdfCopy(path: another.path, uri: second),
        ],
      );
      var failSecond = true;
      final deleted = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final uri = (call.arguments as Map)['uri'] as String;
        if (uri == second && failSecond) {
          throw PlatformException(
            code: 'PUBLIC_MUTATION_FAILED',
            message: 'Access denied',
          );
        }
        deleted.add(uri);
        await File((call.arguments as Map)['publicPath'] as String).delete();
        return true;
      });
      final partial = await PdfLibraryService.deleteDocument(public.path);
      expect(partial.completed, isFalse);
      expect(partial.warning, contains('Some copies were deleted'));
      expect(working.existsSync(), isTrue);
      expect(
        (await PublicPdfSaveService.documents()).single.copies.single.uri,
        second,
      );
      expect((await PdfLibraryService.scan()).single.path, another.path);
      expect(
        await RecentFilesService.starred(),
        {another.path},
        reason: 'a partial deletion must preserve the surviving document star',
      );
      expect(await RecentFilesService.recents(), [another.path]);
      failSecond = false;
      expect(
        (await PdfLibraryService.deleteDocument(working.path)).completed,
        isTrue,
      );
      expect(deleted, [
        first,
        second,
      ], reason: 'retry must not repeat a successful deletion');
      expect(await PdfLibraryService.scan(), isEmpty);
      expect(await PublicPdfSaveService.documents(), isEmpty);
    },
  );

  test(
    'partial rename persists the moved public alias without exposing its working file',
    () async {
      const first = 'content://media/external_primary/downloads/1';
      const second = 'content://media/external_primary/downloads/2';
      final another = File('${public.parent.path}/Other.pdf')
        ..writeAsStringSync('second export');
      await seed(
        copies: [
          PublicPdfCopy(path: public.path, uri: first),
          PublicPdfCopy(path: another.path, uri: second),
        ],
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = call.arguments as Map;
        if (arguments['uri'] == second) {
          throw PlatformException(
            code: 'PUBLIC_MUTATION_FAILED',
            message: 'Access denied',
          );
        }
        final target = '${public.parent.path}/Paid.pdf';
        await File(arguments['publicPath'] as String).rename(target);
        return {'uri': first, 'name': 'Paid.pdf', 'publicPath': target};
      });
      final result = await PdfLibraryService.renameDocument(
        working.path,
        'Paid.pdf',
      );
      expect(result.completed, isFalse);
      expect(result.warning, contains('Some copies were renamed'));
      expect(working.existsSync(), isTrue);
      final record = (await PublicPdfSaveService.documents()).single;
      expect(record.copies.first.path, '${public.parent.path}/Paid.pdf');
      expect(record.copies.last.path, another.path);
      expect(await PdfLibraryService.scan(), hasLength(1));
    },
  );

  test(
    'aliases keep stars and recent order when storage visibility changes',
    () async {
      await seed();
      expect((await PdfLibraryService.scan()).single.path, public.path);
      expect(await RecentFilesService.recents(), [public.path]);
      expect(await RecentFilesService.starred(), {public.path});
      public
          .deleteSync(); // Simulate public path no longer available to the sweep.
      expect((await PdfLibraryService.scan()).single.path, working.path);
      expect(await RecentFilesService.recents(), [working.path]);
      expect(await RecentFilesService.starred(), {working.path});
      public.writeAsStringSync('visible again');
      expect((await PdfLibraryService.scan()).single.path, public.path);
      expect(await RecentFilesService.recents(), [public.path]);
      expect(await RecentFilesService.starred(), {public.path});
    },
  );
}
