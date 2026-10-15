import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_preview_screen.dart';
import 'package:pdfhelper/services/library_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../support/fake_path_provider.dart';

class _AndroidSettings extends ThemeProvider {
  @override
  bool get usesPublicStorage => true;
}

class _FailingExportStore extends InMemorySharedPreferencesStore {
  _FailingExportStore() : super.empty();

  int exportWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.publicPdfExports' && ++exportWrites == 2) {
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

/// Counts writes of the export catalogue, and fails the [failAt]th.
class _CountingExportStore extends InMemorySharedPreferencesStore {
  _CountingExportStore({this.failAt}) : super.empty();

  final int? failAt;
  int exportWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.publicPdfExports' && ++exportWrites == failAt) {
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late File source;
  late int sdk;
  late bool grantStorage;
  late bool failSave;
  late String? failSource;
  late List<MethodCall> saves;
  late List<int> requested;

  setUp(() {
    SharedPreferences.setMockInitialValues({'notifications': false});
    PublicPdfSaveService.resetForTesting();
    root = Directory.systemTemp.createTempSync('public_pdf_save');
    final paths = FakePathProvider.install(root);
    source = File('${paths.documents.path}/Report.pdf')
      ..writeAsStringSync('%PDF-1.7\nworking document');
    sdk = 36;
    grantStorage = true;
    failSave = false;
    failSource = null;
    saves = [];
    requested = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStorageInfo') {
        return {
          'sdkInt': sdk,
          'hasFullAccess': false,
          'roots': ['/storage/emulated/0'],
        };
      }
      expect(call.method, 'savePublicPdf');
      saves.add(call);
      if (failSave || (call.arguments as Map)['sourcePath'] == failSource) {
        throw PlatformException(
          code: 'PUBLIC_SAVE_FAILED',
          message: 'Disk full',
        );
      }
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(
        await File(args['sourcePath'] as String).readAsString(),
        contains('%PDF-'),
      );
      return {
        'uri': 'content://media/external_primary/downloads/42',
        'name': 'Report (2).pdf',
        'publicPath':
            '/storage/emulated/0/${args['location']}/DocHelper/Report (2).pdf',
      };
    });
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'checkPermissionStatus') return 0;
      expect(call.method, 'requestPermissions');
      final values = List<int>.from(call.arguments as List);
      requested.addAll(values);
      return {for (final value in values) value: grantStorage ? 1 : 0};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(permissions, null);
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<_AndroidSettings> settings() async {
    final provider = _AndroidSettings();
    for (var i = 0; i < 100 && !provider.isInitialized; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.isInitialized, isTrue);
    addTearDown(provider.dispose);
    return provider;
  }

  for (final location in ['Downloads', 'Documents']) {
    test(
      'exports $location publicly and keeps a usable path for the engine',
      () async {
        final provider = await settings();
        await provider.setSaveLocation(location);
        final saved = await provider.autoSaveFile(
          source.path,
          'merged',
          fileName: 'Report/2026',
        );
        expect(saved, source.path);
        expect(await File(saved!).readAsString(), contains('%PDF-'));
        expect(saves.single.arguments, {
          'sourcePath': source.path,
          'displayName': 'Report 2026.pdf',
          'location': location,
          'mimeType': 'application/pdf',
        });
        expect(
          requested,
          isEmpty,
          reason: 'Public exports must not require all-files access',
        );
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('publicPdfExports')!), {
          source.path: {
            'id': source.path,
            'copies': [
              {
                'path':
                    '/storage/emulated/0/$location/DocHelper/Report (2).pdf',
                'uri': 'content://media/external_primary/downloads/42',
              },
            ],
          },
        });
        expect(
          provider.saveLocationDescription,
          '$location/DocHelper (device storage)',
        );
      },
    );
  }

  test(
    'a failed export preserves the working PDF and reports failure',
    () async {
      final provider = await settings();
      failSave = true;
      await expectLater(
        autoSavePdfs(
          themeProvider: provider,
          filePaths: [source.path],
          sourceType: PdfPreviewSourceType.merge,
          pageCount: 1,
        ),
        throwsA(
          isA<PublicPdfSaveException>().having(
            (e) => e.message,
            'message',
            contains('Disk full'),
          ),
        ),
      );
      expect(source.existsSync(), isTrue);
      expect(await PublicPdfSaveService.documents(), isEmpty);
    },
  );

  test('saves into a folder below DocHelper when given one', () async {
    await PublicPdfSaveService.save(
      sourcePath: source.path,
      displayName: 'Report.pdf',
      location: 'Downloads',
      subfolder: 'Ölfeld/2024 Reports/日本語',
    );
    expect(saves.single.arguments, {
      'sourcePath': source.path,
      'displayName': 'Report.pdf',
      'location': 'Downloads',
      'mimeType': 'application/pdf',
      'subfolder': 'Ölfeld/2024 Reports/日本語',
    });
    final record = (await PublicPdfSaveService.documents()).single;
    expect(record.workingPath, source.path);
    expect(record.copies.single.uri, isNotNull);
  });

  test('a failed save into a folder names that folder', () async {
    failSave = true;
    await expectLater(
      PublicPdfSaveService.save(
        sourcePath: source.path,
        displayName: 'Report.pdf',
        location: 'Documents',
        subfolder: 'Photos/2024',
      ),
      throwsA(
        isA<PublicPdfSaveException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Documents/DocHelper/Photos/2024'),
            contains('Disk full'),
          ),
        ),
      ),
    );
    expect(await PublicPdfSaveService.documents(), isEmpty);
  });

  test('accepts plain relative folders up to the limits', () {
    final deepest = List.generate(16, (i) => 'level$i').join('/');
    for (final folder in [
      'Photos',
      'Photos/2024',
      'रिपोर्ट/日本語/Ölfeld',
      'a.b/..c/name.',
      deepest,
      'x' * 100,
      '${'😀' * 50}/inner',
    ]) {
      expect(
        PublicPdfSaveService.isValidSubfolder(folder),
        isTrue,
        reason: folder,
      );
    }
  });

  final invalidFolders = <String, String>{
    'empty': '',
    'absolute': '/Photos',
    'trailing slash': 'Photos/',
    'empty name': 'Photos//2024',
    'dot': 'Photos/./2024',
    'dot dot': '../Photos',
    'nested dot dot': 'Photos/../../x',
    'backslash': r'Photos\2024',
    'NUL': 'Photos${String.fromCharCode(0)}x',
    'tab': 'Photos\tx',
    'newline': 'Photos\nx',
    'DEL': 'Photos${String.fromCharCode(0x7F)}',
    'C1 control': 'Photos${String.fromCharCode(0x85)}',
    'long name': 'x' * 101,
    'too deep': List.generate(17, (i) => 'level$i').join('/'),
  };
  for (final MapEntry(key: what, value: folder) in invalidFolders.entries) {
    test('refuses a folder with $what before publishing anything', () async {
      expect(PublicPdfSaveService.isValidSubfolder(folder), isFalse);
      await expectLater(
        PublicPdfSaveService.save(
          sourcePath: source.path,
          displayName: 'Report.pdf',
          location: 'Downloads',
          subfolder: folder,
        ),
        throwsA(isA<PublicPdfSaveException>()),
      );
      expect(saves, isEmpty);
      expect(await PublicPdfSaveService.documents(), isEmpty);
      expect(source.existsSync(), isTrue);
    });
  }

  group('saving many files at once', () {
    /// Publishes each file with its own content address, as MediaStore
    /// would; [failOn] (1-based) fails that file. Records deletions.
    late List<Map<String, dynamic>> published;
    late List<Map<String, dynamic>> deleted;
    void answer({int? failOn}) {
      published = [];
      deleted = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getStorageInfo':
            return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
          case 'deletePublicPdf':
            deleted.add(Map<String, dynamic>.from(call.arguments as Map));
            return true;
        }
        expect(call.method, 'savePublicPdf');
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (published.length + 1 == failOn) {
          throw PlatformException(code: 'PUBLIC_SAVE_FAILED', message: 'Full');
        }
        published.add(args);
        final folder = args['subfolder'] ?? '';
        return {
          'uri':
              'content://media/external_primary/downloads/'
              '${published.length}',
          'publicPath':
              '/storage/emulated/0/Download/DocHelper/$folder/'
              '${args['displayName']}',
        };
      });
    }

    List<PublicFileRequest> requests(int count) => [
      for (var i = 0; i < count; i++)
        PublicFileRequest(
          sourcePath: '${root.path}/Photos/$i.jpg',
          displayName: '$i.jpg',
          mimeType: 'image/jpeg',
          subfolder: 'Photos/${i ~/ 100}',
        ),
    ];

    test('writes the catalogue a few times, not once per file', () async {
      final store = _CountingExportStore();
      SharedPreferencesStorePlatform.instance = store;
      answer();
      final progress = <int>[];
      final count = await PublicPdfSaveService.saveAll(
        files: requests(1000),
        location: 'Downloads',
        onProgress: progress.add,
      );
      expect(count, 1000);
      expect(published, hasLength(1000));
      expect(published[250], {
        'sourcePath': '${root.path}/Photos/250.jpg',
        'displayName': '250.jpg',
        'location': 'Downloads',
        'mimeType': 'image/jpeg',
        'subfolder': 'Photos/2',
      });
      // One write to check the catalogue, then at 64, 128, 256 and 512
      // files, and the rest at the end; one write per file made a
      // thousand-photo ZIP cost minutes.
      expect(store.exportWrites, 6);
      expect(progress, List.generate(1000, (i) => i + 1));

      final records = await PublicPdfSaveService.documents();
      expect(records, hasLength(1000));
      expect(records[999].workingPath, '${root.path}/Photos/999.jpg');
      expect(
        records[999].copies.single.path,
        '/storage/emulated/0/Download/DocHelper/Photos/9/999.jpg',
      );
      expect(
        records[999].copies.single.uri,
        'content://media/external_primary/downloads/1000',
      );
    });

    test('keeps what was published before a file fails, linked', () async {
      answer(failOn: 3);
      await expectLater(
        PublicPdfSaveService.saveAll(files: requests(5), location: 'Downloads'),
        throwsA(
          isA<PublicPdfBatchException>()
              .having((e) => e.published, 'published', 2)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('2.jpg'), contains('Full')),
              ),
        ),
      );
      expect(published, hasLength(2));
      expect(deleted, isEmpty);
      expect(
        (await PublicPdfSaveService.documents()).map((r) => r.workingPath),
        ['${root.path}/Photos/0.jpg', '${root.path}/Photos/1.jpg'],
      );
    });

    test('removes the copies it cannot record', () async {
      // The first write checks the catalogue; the second records the
      // three copies, and fails.
      SharedPreferencesStorePlatform.instance = _CountingExportStore(failAt: 2);
      answer();
      await expectLater(
        PublicPdfSaveService.saveAll(files: requests(3), location: 'Downloads'),
        throwsA(
          isA<PublicPdfBatchException>()
              .having((e) => e.published, 'published', 0)
              .having(
                (e) => e.message,
                'message',
                contains('The last 3 public copies were removed again.'),
              ),
        ),
      );
      expect(published, hasLength(3));
      expect(deleted.map((d) => d['uri']), [
        'content://media/external_primary/downloads/1',
        'content://media/external_primary/downloads/2',
        'content://media/external_primary/downloads/3',
      ]);
      expect(await PublicPdfSaveService.documents(), isEmpty);
    });

    test('checks every folder before publishing anything', () async {
      answer();
      await expectLater(
        PublicPdfSaveService.saveAll(
          files: [
            ...requests(3),
            const PublicFileRequest(
              sourcePath: '/x/evil.txt',
              displayName: 'evil.txt',
              subfolder: 'Photos/../..',
            ),
          ],
          location: 'Downloads',
        ),
        throwsA(isA<PublicPdfSaveException>()),
      );
      expect(published, isEmpty);
      expect(await PublicPdfSaveService.documents(), isEmpty);
    });
  });

  test('auto-save disabled does not create a public copy', () async {
    final provider = await settings();
    await provider.setAutoSave(false);
    expect(await provider.autoSaveFile(source.path, 'merged'), isNull);
    expect(saves, isEmpty);
    expect(source.existsSync(), isTrue);
  });

  test(
    'repeated exports retain all provider copies under one document',
    () async {
      var nextId = 1;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getStorageInfo') {
          return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
        }
        final id = nextId++;
        return {
          'uri': 'content://media/external_primary/downloads/$id',
          'name': 'Report ($id).pdf',
          'publicPath':
              '/storage/emulated/0/Download/DocHelper/Report ($id).pdf',
        };
      });
      final provider = await settings();
      await provider.autoSaveFile(source.path, 'merged');
      await provider.autoSaveFile(source.path, 'merged');
      final record = (await PublicPdfSaveService.documents()).single;
      expect(record.id, source.path);
      expect(record.copies.map((copy) => copy.uri), [
        'content://media/external_primary/downloads/1',
        'content://media/external_primary/downloads/2',
      ]);
    },
  );

  test(
    'invalid export catalogue prevents publication of an untracked copy',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('publicPdfExports', 'invalid JSON');
      await expectLater(
        PublicPdfSaveService.save(
          sourcePath: source.path,
          displayName: 'Report.pdf',
          location: 'Downloads',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(saves, isEmpty);
      expect(source.existsSync(), isTrue);
    },
  );

  for (final rollbackFails in [false, true]) {
    test(
      'catalogue write failure ${rollbackFails ? 'reports retained export' : 'rolls back exact new export'}',
      () async {
        SharedPreferencesStorePlatform.instance = _FailingExportStore();
        const uri = 'content://media/external_primary/downloads/123';
        const publicPath =
            '/storage/emulated/0/Download/DocHelper/Report (2).pdf';
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getStorageInfo':
              return {
                'sdkInt': 36,
                'hasFullAccess': false,
                'roots': <String>[],
              };
            case 'savePublicPdf':
              return {
                'uri': uri,
                'name': 'Report (2).pdf',
                'publicPath': publicPath,
              };
            case 'deletePublicPdf':
              expect(call.arguments, {'uri': uri, 'publicPath': publicPath});
              if (rollbackFails) {
                throw PlatformException(
                  code: 'PUBLIC_MUTATION_FAILED',
                  message: 'Provider unavailable',
                );
              }
              return true;
            default:
              fail('Unexpected storage operation: ${call.method}');
          }
        });
        await expectLater(
          PublicPdfSaveService.save(
            sourcePath: source.path,
            displayName: 'Report.pdf',
            location: 'Downloads',
          ),
          throwsA(
            isA<PublicPdfSaveException>().having(
              (error) => error.message,
              'recovery instructions',
              rollbackFails
                  ? allOf(
                      contains(publicPath),
                      contains(uri),
                      contains('Do not save another copy'),
                    )
                  : contains('The new public copy was removed'),
            ),
          ),
        );
        expect(calls.map((call) => call.method), [
          'getStorageInfo',
          'savePublicPdf',
          'deletePublicPdf',
        ]);
        expect(source.existsSync(), isTrue);
        if (!rollbackFails) {
          expect(await PublicPdfSaveService.documents(), isEmpty);
        }
      },
    );
  }

  test('explicit Save publishes even when Auto Save is off', () async {
    final provider = await settings();
    await provider.setAutoSave(false);
    final paths = await autoSavePdfs(
      themeProvider: provider,
      filePaths: [source.path],
      sourceType: PdfPreviewSourceType.convert,
      pageCount: 1,
      explicitlySave: true,
    );
    expect(paths, [source.path]);
    expect(saves, hasLength(1));
    expect(source.existsSync(), isTrue);
    expect(provider.autoSave, isFalse);
  });

  test('partial save retry only publishes remaining PDFs', () async {
    final provider = await settings();
    final second = File('${source.parent.path}/Second.pdf')
      ..writeAsStringSync('%PDF-1.7\\nsecond working document');
    final completed = <String, String>{};
    Future<List<String>> saveBatch() => autoSavePdfs(
      themeProvider: provider,
      filePaths: [source.path, second.path],
      sourceType: PdfPreviewSourceType.merge,
      pageCount: 2,
      completedFiles: completed,
    );
    failSource = second.path;
    await expectLater(saveBatch(), throwsA(isA<PublicPdfSaveException>()));
    expect(completed, {source.path: source.path});
    expect(source.existsSync(), isTrue);
    expect(second.existsSync(), isTrue);

    failSource = null;
    expect(await saveBatch(), [source.path, second.path]);
    expect(saves.map((call) => (call.arguments as Map)['sourcePath']), [
      source.path,
      second.path,
      second.path,
    ]);
  });

  test(
    'non-Android explicit saves keep using the app documents folder',
    () async {
      final provider = ThemeProvider();
      for (var i = 0; i < 100 && !provider.isInitialized; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      addTearDown(provider.dispose);
      await provider.setAutoSave(false);
      final saved = await provider.saveFile(
        source.path,
        'merged',
        fileName: 'Report',
      );
      expect(saved, '${source.parent.path}/PDFHelper/Downloads/Report.pdf');
      expect(await File(saved).readAsString(), contains('%PDF-'));
      expect(source.existsSync(), isFalse);
      expect(saves, isEmpty);
    },
  );

  test('non-Android copy failure preserves the original PDF', () async {
    final provider = ThemeProvider();
    for (var i = 0; i < 100 && !provider.isInitialized; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    addTearDown(provider.dispose);
    // Block directory creation with a regular file.
    File('${source.parent.path}/PDFHelper').writeAsStringSync('occupied');
    await expectLater(
      provider.saveFile(source.path, 'merged'),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(saves, isEmpty);
  });

  test(
    'Android 9 asks for legacy write access, never all-files access',
    () async {
      sdk = 28;
      final provider = await settings();
      await provider.autoSaveFile(source.path, 'merged');
      expect(requested, [Permission.storage.value]);
      expect(saves, hasLength(1));
    },
  );

  test('denied legacy write access cannot claim a successful save', () async {
    sdk = 28;
    grantStorage = false;
    final provider = await settings();
    await expectLater(
      provider.autoSaveFile(source.path, 'merged'),
      throwsA(isA<PublicPdfSaveException>()),
    );
    expect(saves, isEmpty);
    expect(source.existsSync(), isTrue);
  });

  test('Android 10 needs no storage permission for its own exports', () async {
    sdk = 29;
    await (await settings()).autoSaveFile(source.path, 'merged');
    expect(requested, isEmpty);
    expect(saves, hasLength(1));
  });

  test('an unconfirmed native response is a failure', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'getStorageInfo'
          ? {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]}
          : null,
    );
    final provider = await settings();
    await expectLater(
      provider.autoSaveFile(source.path, 'merged'),
      throwsA(isA<PublicPdfSaveException>()),
    );
    expect(source.existsSync(), isTrue);
  });

  LibraryEntry entry(String path, {bool appOwned = false}) => LibraryEntry(
    path: path,
    name: 'Report.pdf',
    sizeBytes: 100,
    modifiedMs: 1,
    folder: 'DocHelper',
    isAppOwned: appOwned,
  );

  test(
    'public files replace their mirrors and remain app-created in Files',
    () {
      final files = LibraryService.reconcilePublicExports(
        [
          entry('/private/report.pdf', appOwned: true),
          entry('/public/report.pdf'),
          entry('/other.pdf'),
        ],
        {'/private/report.pdf': '/public/report.pdf'},
      );
      expect(files.map((file) => file.path), [
        '/public/report.pdf',
        '/other.pdf',
      ]);
      expect(files.first.isAppOwned, isTrue);
      expect(files.last.isAppOwned, isFalse);
    },
  );

  test(
    'restricted storage or a moved public file leaves working copy visible',
    () {
      final files = LibraryService.reconcilePublicExports(
        [entry('/private/report.pdf', appOwned: true)],
        {'/private/report.pdf': '/public/report.pdf'},
      );
      expect(files.single.path, '/private/report.pdf');
    },
  );
}
