import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/pdf_library_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../support/fake_path_provider.dart';

class _FaultStore extends InMemorySharedPreferencesStore {
  _FaultStore(super.data) : super.withData();

  int exportWrites = 0;
  bool failRepeatedly = false;
  bool throwOnFailure = false;
  void Function()? onFailure;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.publicPdfExports' &&
        ++exportWrites >= 3 &&
        (exportWrites == 3 || failRepeatedly)) {
      onFailure?.call();
      if (throwOnFailure) {
        throw PlatformException(code: 'WRITE_FAILED', message: 'Disk full');
      }
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  const uri = 'content://media/external_primary/downloads/42';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late File working;
  late File public;
  late String renamedWorking;
  late String renamedPublic;
  late _FaultStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PublicPdfSaveService.resetForTesting();
    PdfLibraryService.resetForTesting();
    RecentFilesService.resetCacheForTesting();
    root = Directory.systemTemp.createTempSync('rename_persistence');
    final paths = FakePathProvider.install(root);
    working = File('${paths.documents.path}/Report.pdf')
      ..writeAsStringSync('%PDF-1.7 working');
    final publicFolder = Directory('${paths.documents.path}/public')
      ..createSync();
    public = File('${publicFolder.path}/Report.pdf')
      ..writeAsStringSync('%PDF-1.7 public');
    renamedWorking = '${working.parent.path}/Paid.pdf';
    renamedPublic = '${public.parent.path}/Paid.pdf';
    store = _FaultStore({
      'flutter.publicPdfExports': jsonEncode({
        working.path: {
          'id': 'document-42',
          'copies': [
            {'path': public.path, 'uri': uri},
          ],
        },
      }),
    });
    SharedPreferencesStorePlatform.instance = store;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map;
      expect(arguments['uri'], uri);
      switch (call.method) {
        case 'renamePublicPdf':
          await File(arguments['publicPath'] as String).rename(renamedPublic);
          return {'uri': uri, 'name': 'Paid.pdf', 'publicPath': renamedPublic};
        case 'deletePublicPdf':
          await File(arguments['publicPath'] as String).delete();
          return true;
        default:
          fail('Unexpected storage operation: ${call.method}');
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await PdfLibraryService.settleForTesting();
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> reloadCatalogue() async {
    await (await SharedPreferences.getInstance()).reload();
    PublicPdfSaveService.resetForTesting();
    await PdfLibraryService.settleForTesting();
    PdfLibraryService.resetForTesting();
    RecentFilesService.resetCacheForTesting();
  }

  for (final throws in [false, true]) {
    test(
      'final rename write ${throws ? 'exception' : 'failure'} restores private file and keeps confirmed public rename',
      () async {
        store.throwOnFailure = throws;
        final result = await PublicPdfSaveService.renameDocument(
          working.path,
          'Paid.pdf',
        );
        expect(result.completed, isFalse);
        expect(result.renamedPaths, {public.path: renamedPublic});
        expect(working.readAsStringSync(), '%PDF-1.7 working');
        expect(File(renamedWorking).existsSync(), isFalse);
        expect(File(renamedPublic).readAsStringSync(), '%PDF-1.7 public');

        await reloadCatalogue();
        final document = (await PublicPdfSaveService.documents()).single;
        expect(document.workingPath, working.path);
        expect(document.copies.single.path, renamedPublic);
        expect((await PdfLibraryService.scan()).map((file) => file.path), [
          renamedPublic,
        ]);
        expect(
          (await PublicPdfSaveService.deleteDocument(renamedPublic)).completed,
          isTrue,
        );
        expect(working.existsSync(), isFalse);
        expect(File(renamedPublic).existsSync(), isFalse);
      },
    );
  }

  test(
    'continued write failure leaves cache and durable catalogue aligned',
    () async {
      store.failRepeatedly = true;
      final result = await PublicPdfSaveService.renameDocument(
        working.path,
        'Paid.pdf',
      );
      expect(result.completed, isFalse);
      expect(result.renamedPaths, {public.path: renamedPublic});
      expect(
        (await PublicPdfSaveService.documents()).single.workingPath,
        working.path,
      );
      await reloadCatalogue();
      final document = (await PublicPdfSaveService.documents()).single;
      expect(document.workingPath, working.path);
      expect(document.copies.single.path, renamedPublic);
      expect(working.existsSync(), isTrue);
      expect(File(renamedWorking).existsSync(), isFalse);
      expect((await PdfLibraryService.scan()).map((file) => file.path), [
        renamedPublic,
      ]);
    },
  );

  test(
    'rollback preserves replacement at original path and reports surviving private path',
    () async {
      store.onFailure = () => working.writeAsStringSync('replacement document');
      final result = await PublicPdfSaveService.renameDocument(
        working.path,
        'Paid.pdf',
      );
      expect(result.completed, isFalse);
      expect(working.readAsStringSync(), 'replacement document');
      expect(File(renamedWorking).readAsStringSync(), '%PDF-1.7 working');
      expect(result.renamedPaths, {
        public.path: renamedPublic,
        working.path: renamedWorking,
      });
      expect(result.warning, contains('The working PDF is at $renamedWorking'));
      expect(result.warning, contains('Its library link could not be saved'));
      expect(result.warning, isNot(contains('copies remain linked')));
    },
  );

  test(
    'final delete write failure does not return a removed file as surviving',
    () async {
      final result = await PublicPdfSaveService.deleteDocument(working.path);
      expect(result.completed, isFalse);
      expect(result.removedPaths, {working.path, public.path});
      expect(result.remainingPath, isNull);
      expect(result.warning, contains('document files were deleted'));
      expect(result.warning, isNot(contains('remaining copies')));
      expect(working.existsSync(), isFalse);
      expect(public.existsSync(), isFalse);
      await reloadCatalogue();
      expect(await PdfLibraryService.scan(), isEmpty);
    },
  );
}
