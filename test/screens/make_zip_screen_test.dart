import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/archive_screen.dart';
import 'package:pdfhelper/screens/make_zip_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Making a ZIP, through the real archive engine:
///   eval "$(bash scripts/build_engines.sh env)"
///   flutter test test/screens/make_zip_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('com.yourmateapps.pdfhelper/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late FakePathProvider paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_make_zip');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    PublicPdfSaveService.resetForTesting();
    DocumentSaveService.publishOverride = false;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(storage, null);
    DocumentSaveService.publishOverride = null;
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, List<String> initialPaths) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(home: MakeZipScreen(initialPaths: initialPaths)),
      ),
    );
  }

  /// Let isolate and file work finish until [finder] shows.
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  String write(String path, String text) {
    final file = File('${root.path}/$path')..createSync(recursive: true);
    file.writeAsStringSync(text);
    return file.path;
  }

  final create = find.byKey(const ValueKey('make-zip-create'));
  final result = find.byKey(const ValueKey('make-zip-result'));

  FilledButton createButton(WidgetTester tester) =>
      tester.widget<FilledButton>(create);

  String nameField(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('make-zip-name')))
      .controller!
      .text;

  test('names that clash are numbered, ignoring letter case', () {
    expect(
      MakeZipScreen.entryNames([
        'notes.txt',
        'Notes.TXT',
        'notes.txt',
        'notes (2).txt',
        'archive.tar.gz',
        'archive.tar.gz',
        'README',
        'readme',
        '.profile',
        '.profile',
      ]),
      [
        'notes.txt',
        'Notes (2).TXT',
        'notes (3).txt',
        'notes (2) (2).txt',
        'archive.tar.gz',
        'archive.tar (2).gz',
        'README',
        'readme (2)',
        '.profile',
        '.profile (2)',
      ],
    );
  });

  testWidgets('Create waits for files', (tester) async {
    await pump(tester, const []);
    await tester.pump();
    expect(find.byKey(const ValueKey('make-zip-empty')), findsOneWidget);
    expect(find.text('Add files'), findsOneWidget);
    expect(createButton(tester).onPressed, isNull);
    expect(nameField(tester), 'Archive');
  });

  testWidgets('says when the archive engine is missing', (tester) async {
    final a = write('src/a.txt', 'a');
    await pump(tester, [a]);
    await until(tester, find.byKey(const ValueKey('make-zip-file-0')));
    expect(find.byKey(const ValueKey('make-zip-missing')), findsOneWidget);
    expect(createButton(tester).onPressed, isNull);
  }, skip: ArchiveCore.isAvailable);

  final library = Platform.environment['ARCHIVE_CORE_LIB_PATH'] ?? '';
  if (library.isEmpty || !File(library).existsSync()) return;

  group('with the archive engine', () {
    testWidgets('packs two files into Archive.zip', (tester) async {
      final notes = write('src/notes.txt', 'Hello from the ZIP');
      final sheet = write('other/Ölpreise.csv', 'Jahr,Preis\n2024,3\n');
      await pump(tester, [notes, sheet]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('Ölpreise.csv'), findsOneWidget);
      expect(find.text('2 items · 36 B'), findsOneWidget);
      expect(nameField(tester), 'Archive');
      expect(find.byKey(const ValueKey('make-zip-missing')), findsNothing);

      await tester.tap(create);
      await until(tester, result);
      final zip = '${paths.documents.path}/Archive.zip';
      expect(find.text('Archive.zip'), findsOneWidget);
      expect(find.textContaining('2 files'), findsOneWidget);
      expect(find.text("Saved in DocHelper's documents."), findsOneWidget);

      final listing = ArchiveCore.list(zip);
      expect(listing.format, ArchiveFormat.zip);
      expect(listing.entries.map((e) => e.path), ['notes.txt', 'Ölpreise.csv']);
      final out = '${root.path}/out.txt';
      ArchiveCore.extract(zip, 0, out);
      expect(File(out).readAsStringSync(), 'Hello from the ZIP');
      // The files themselves are only read.
      expect(File(notes).readAsStringSync(), 'Hello from the ZIP');
    });

    testWidgets('two files of the same name are both kept', (tester) async {
      final first = write('January/report.txt', 'January');
      final second = write('February/report.txt', 'February');
      final third = write('March/Report.TXT', 'March');
      await pump(tester, [first, second, third]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-2')));
      expect(find.textContaining('packed as report (2).txt'), findsOneWidget);
      expect(find.textContaining('packed as Report (3).TXT'), findsOneWidget);

      await tester.tap(create);
      await until(tester, result);
      final zip = '${paths.documents.path}/Archive.zip';
      final entries = ArchiveCore.list(zip).entries;
      expect(entries.map((e) => e.path), [
        'report.txt',
        'report (2).txt',
        'Report (3).TXT',
      ]);
      for (final (index, text) in [
        (0, 'January'),
        (1, 'February'),
        (2, 'March'),
      ]) {
        final out = '${root.path}/out$index.txt';
        ArchiveCore.extract(zip, entries[index].index, out);
        expect(File(out).readAsStringSync(), text);
      }
    });

    testWidgets('one file names the ZIP; a taken name gets (2)', (
      tester,
    ) async {
      final report = write('src/Q3 Report.pdf', '%PDF-1.4 not really');
      File('${paths.documents.path}/Q3 Report.zip').writeAsStringSync('old');
      await pump(tester, [report, report]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-0')));
      // The same file picked twice is packed once.
      expect(find.byKey(const ValueKey('make-zip-file-1')), findsNothing);
      expect(nameField(tester), 'Q3 Report');

      await tester.tap(create);
      await until(tester, result);
      expect(find.text('Q3 Report (2).zip'), findsOneWidget);
      expect(
        File('${paths.documents.path}/Q3 Report.zip').readAsStringSync(),
        'old',
      );
      expect(
        ArchiveCore.list(
          '${paths.documents.path}/Q3 Report (2).zip',
        ).entries.single.path,
        'Q3 Report.pdf',
      );
    });

    testWidgets('a typed name is kept and cleaned', (tester) async {
      final a = write('src/a.txt', 'a');
      final b = write('src/b.txt', 'b');
      await pump(tester, [a, b]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      await tester.enterText(
        find.byKey(const ValueKey('make-zip-name')),
        '  Tax: 2024/25.zip ',
      );
      await tester.pump();
      // Characters a file system refuses are not typed at all.
      expect(nameField(tester), '  Tax 202425.zip ');

      // Removing a file no longer renames a ZIP the user named.
      await tester.tap(find.byKey(const ValueKey('make-zip-remove-1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('make-zip-file-1')), findsNothing);
      expect(nameField(tester), '  Tax 202425.zip ');

      await tester.tap(create);
      await until(tester, result);
      expect(
        File('${paths.documents.path}/Tax 202425.zip').existsSync(),
        isTrue,
      );
    });

    testWidgets('removing files changes the suggested name', (tester) async {
      final a = write('src/Minutes.docx', 'a');
      final b = write('src/Agenda.docx', 'b');
      await pump(tester, [a, b]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      expect(nameField(tester), 'Archive');
      await tester.tap(find.byKey(const ValueKey('make-zip-remove-0')));
      await tester.pump();
      expect(nameField(tester), 'Agenda');
      await tester.tap(find.byKey(const ValueKey('make-zip-remove-0')));
      await tester.pump();
      expect(nameField(tester), 'Archive');
      expect(createButton(tester).onPressed, isNull);
    });

    testWidgets('publishes a public copy where Android needs one', (
      tester,
    ) async {
      DocumentSaveService.publishOverride = true;
      final saves = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(storage, (call) async {
        if (call.method == 'getStorageInfo') {
          return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
        }
        expect(call.method, 'savePublicPdf');
        final args = Map<String, dynamic>.from(call.arguments as Map);
        saves.add(args);
        return {
          'uri': 'content://media/external_primary/downloads/1',
          'name': args['displayName'],
          'publicPath':
              '/storage/emulated/0/Download/DocHelper/${args['displayName']}',
        };
      });
      final a = write('src/a.txt', 'a');
      final b = write('src/b.txt', 'b');
      await pump(tester, [a, b]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      await tester.tap(create);
      await until(tester, result);

      expect(saves, [
        {
          'sourcePath': '${paths.documents.path}/Archive.zip',
          'displayName': 'Archive.zip',
          'location': 'Downloads',
          'mimeType': 'application/zip',
        },
      ]);
      expect(
        find.text('Saved to Download/DocHelper/Archive.zip.'),
        findsOneWidget,
      );
    });

    testWidgets('says when the public copy fails, keeping the ZIP', (
      tester,
    ) async {
      DocumentSaveService.publishOverride = true;
      messenger.setMockMethodCallHandler(storage, (call) async {
        if (call.method == 'getStorageInfo') {
          return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
        }
        throw PlatformException(code: 'IO', message: 'Disk full');
      });
      final a = write('src/a.txt', 'a');
      await pump(tester, [a]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-0')));
      await tester.tap(create);
      await until(tester, result);
      expect(
        find.textContaining(
          "It is saved in DocHelper's documents, but not in "
          'Download/DocHelper',
        ),
        findsOneWidget,
      );
      expect(File('${paths.documents.path}/a.zip').existsSync(), isTrue);
    });

    testWidgets('says why a file could not be packed', (tester) async {
      final a = write('src/a.txt', 'a');
      final b = write('src/b.txt', 'b');
      await pump(tester, [a, b]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      File(b).deleteSync();
      await tester.tap(create);
      await until(tester, find.byKey(const ValueKey('make-zip-error')));
      final error = tester
          .widget<Text>(find.byKey(const ValueKey('make-zip-error')))
          .data!;
      expect(error, startsWith('A file could not be read. It may have been '));
      expect(error, contains('b.txt'));
      expect(result, findsNothing);
      expect(File('${paths.documents.path}/Archive.zip').existsSync(), isFalse);
    });

    testWidgets('Open shows the new ZIP in the archive screen', (tester) async {
      final a = write('src/a.txt', 'a');
      final b = write('src/b.txt', 'b');
      await pump(tester, [a, b]);
      await until(tester, find.byKey(const ValueKey('make-zip-file-1')));
      await tester.tap(create);
      await until(tester, result);

      await tester.tap(find.byKey(const ValueKey('make-zip-open')));
      await until(tester, find.byKey(const ValueKey('archive-entry-b.txt')));
      expect(find.byType(ArchiveScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-entry-a.txt')), findsOneWidget);
    });
  });
}
