import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/archive_screen.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/services/document_save_service.dart';
import 'package:pdfhelper/services/public_pdf_save_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// One entry of a ZIP made by hand.
class _ZipEntry {
  const _ZipEntry(
    this.name,
    this.text, {
    this.encrypted = false,
    this.symlink = false,
  });

  final String name;
  final String text;

  /// Flagged as protected with a password.
  final bool encrypted;

  /// Recorded by a Unix writer as a symbolic link to [text].
  final bool symlink;
}

/// The CRC-32 a ZIP stores for each entry.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A ZIP of uncompressed entries with UTF-8 names, dated 5 March 2024 at
/// 14:00, written byte by byte so it can hold names and flags that no
/// careful tool would write.
Uint8List _storedZip(List<_ZipEntry> entries, {String comment = ''}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  const time = 0x7000;
  const date = 0x5865;
  for (final entry in entries) {
    final data = utf8.encode(entry.text);
    final name = utf8.encode(entry.name);
    final crc = _crc32(data);
    // Bit 11: the name is UTF-8. Bit 0: encrypted.
    final flags = 0x0800 | (entry.encrypted ? 1 : 0);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, flags);
    u16(out, 0);
    u16(out, time);
    u16(out, date);
    u32(out, crc);
    u32(out, data.length);
    u32(out, data.length);
    u16(out, name.length);
    u16(out, 0);
    out
      ..add(name)
      ..add(data);
    u32(central, 0x02014b50);
    // Made by Unix (3) for the link, whose mode says what it is.
    u16(central, entry.symlink ? (3 << 8) | 20 : 20);
    u16(central, 20);
    u16(central, flags);
    u16(central, 0);
    u16(central, time);
    u16(central, date);
    u32(central, crc);
    u32(central, data.length);
    u32(central, data.length);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, entry.symlink ? 0xA1FF << 16 : 0);
    u32(central, offset);
    central.add(name);
  }
  final start = out.length;
  final directory = central.takeBytes();
  out.add(directory);
  final note = utf8.encode(comment);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, directory.length);
  u32(out, start);
  u16(out, note.length);
  out.add(note);
  return out.takeBytes();
}

/// The archive screen, driven through the real archive engine:
///   eval "$(bash scripts/build_libs.sh env)"
///   flutter test test/screens/archive_screen_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('com.yourmateapps.pdfhelper/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late FakePathProvider paths;
  late GlobalKey<NavigatorState> navigator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_archive');
    paths = FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    PublicPdfSaveService.resetForTesting();
    DocumentSaveService.publishOverride = false;
    navigator = GlobalKey<NavigatorState>();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(storage, null);
    DocumentSaveService.publishOverride = null;
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  /// Open [path] in the archive screen, over a home screen to come back to.
  Future<void> open(WidgetTester tester, String path) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => ArchiveScreen(path: path)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Let isolate work finish until [finder] shows.
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  Finder entry(String path) => find.byKey(ValueKey('archive-entry-$path'));

  testWidgets('says when the archive engine is missing', (tester) async {
    final zip = File('${root.path}/a.zip')
      ..writeAsBytesSync(_storedZip([const _ZipEntry('a.txt', 'a')]));
    await open(tester, zip.path);
    expect(find.textContaining('archive engine is missing'), findsOneWidget);
    expect(find.byKey(const ValueKey('archive-open-other')), findsOneWidget);
  }, skip: ArchiveCore.isAvailable);

  final library = Platform.environment['ARCHIVE_CORE_LIB_PATH'] ?? '';
  if (library.isEmpty || !File(library).existsSync()) return;

  group('with the archive engine', () {
    /// A ZIP made by the engine from folders with names in several
    /// scripts: Reports/, Reports/2024/, and four files.
    Future<String> treeZip(WidgetTester tester) async {
      final src = Directory('${root.path}/src')..createSync();
      Directory('${src.path}/Reports/2024').createSync(recursive: true);
      File(
        '${src.path}/Reports/रिपोर्ट.txt',
      ).writeAsStringSync('हिंदी में रिपोर्ट');
      File('${src.path}/Reports/2024/日本語.md').writeAsStringSync('# 日本語のメモ');
      File('${src.path}/notes.txt').writeAsStringSync('Hello from the archive');
      File('${src.path}/Ölpreise.csv').writeAsStringSync('Jahr,Preis\n2024,3');
      final out = '${root.path}/Tree.zip';
      final packed = await tester.runAsync(
        () => ArchiveCore.createAsync([
          ArchiveSource('${src.path}/Reports'),
          ArchiveSource('${src.path}/notes.txt'),
          ArchiveSource('${src.path}/Ölpreise.csv'),
        ], out),
      );
      expect(packed, 4);
      return out;
    }

    /// A ZIP holding what extracting has to be careful with: a folder only
    /// its file's path implies, a name that climbs out, a password-protected
    /// file and a link.
    String carefulZip() {
      final file = File('${root.path}/Bundle.zip')
        ..writeAsBytesSync(
          _storedZip([
            const _ZipEntry('readme.txt', 'Read me first'),
            const _ZipEntry('docs/inner/deep.txt', 'Deep inside'),
            const _ZipEntry('../evil.txt', 'Climbed out'),
            const _ZipEntry('locked.txt', 'secret!', encrypted: true),
            const _ZipEntry('shortcut', 'readme.txt', symlink: true),
          ], comment: 'Packed by hand'),
        );
      return file.path;
    }

    testWidgets('lists folders first, then files, with their names', (
      tester,
    ) async {
      await open(tester, await treeZip(tester));
      await until(tester, find.byKey(const ValueKey('archive-header')));

      expect(find.text('ZIP archive'), findsOneWidget);
      final size = [
        'हिंदी में रिपोर्ट',
        '# 日本語のメモ',
        'Hello from the archive',
        'Jahr,Preis\n2024,3',
      ].fold<int>(0, (sum, text) => sum + utf8.encode(text).length);
      expect(find.text('4 files · 2 folders · $size B'), findsOneWidget);

      final folder = tester.getTopLeft(entry('Reports')).dy;
      final notes = tester.getTopLeft(entry('notes.txt')).dy;
      final prices = tester.getTopLeft(entry('Ölpreise.csv')).dy;
      expect(folder, lessThan(notes));
      expect(notes, lessThan(prices));
      expect(find.textContaining('2 items'), findsOneWidget);
      expect(entry('Reports/रिपोर्ट.txt'), findsNothing);
      expect(find.byKey(const ValueKey('archive-up')), findsNothing);
    });

    testWidgets('goes into folders and back up, then leaves', (tester) async {
      await open(tester, await treeZip(tester));
      await until(tester, entry('Reports'));

      await tester.tap(entry('Reports'));
      await tester.pump();
      expect(entry('Reports/रिपोर्ट.txt'), findsOneWidget);
      expect(find.text('रिपोर्ट.txt'), findsOneWidget);
      expect(find.text('Tree.zip › Reports'), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-header')), findsNothing);

      await tester.tap(entry('Reports/2024'));
      await tester.pump();
      expect(entry('Reports/2024/日本語.md'), findsOneWidget);
      expect(find.text('Tree.zip › Reports › 2024'), findsOneWidget);

      // The up row goes up one folder.
      await tester.tap(find.byKey(const ValueKey('archive-up')));
      await tester.pump();
      expect(entry('Reports/रिपोर्ट.txt'), findsOneWidget);

      // So does the system back, until the top, where it leaves.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('archive-header')), findsOneWidget);
      expect(find.byType(ArchiveScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveScreen), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('opens a text file in the text editor', (tester) async {
      await open(tester, await treeZip(tester));
      await until(tester, entry('notes.txt'));

      await tester.tap(entry('notes.txt'));
      await until(tester, find.byType(TextEditorScreen));
      final editor = tester.widget<TextEditorScreen>(
        find.byType(TextEditorScreen),
      );
      expect(editor.title, 'notes.txt');
      expect(editor.path, startsWith('${paths.temporary.path}/archives/'));
      expect(editor.path, endsWith('/notes.txt'));
      expect(File(editor.path).readAsStringSync(), 'Hello from the archive');
      // Let the editor finish opening before the test ends.
      if (TextCore.isAvailable) {
        await until(tester, find.text('Hello from the archive'));
      }
    });

    testWidgets('shows a folder only paths imply, a lock and links', (
      tester,
    ) async {
      await open(tester, carefulZip());
      await until(tester, find.byKey(const ValueKey('archive-header')));

      expect(find.text('Packed by hand'), findsOneWidget);
      expect(find.text('5 files · 2 folders · 52 B'), findsOneWidget);
      expect(entry('docs'), findsOneWidget);
      // The climbing name is shown where it would be extracted.
      expect(entry('evil.txt'), findsOneWidget);
      expect(find.text('Link · not extracted'), findsOneWidget);
      expect(find.text('11 B · Mar 2024'), findsWidgets);
      expect(
        find.descendant(
          of: entry('locked.txt'),
          matching: find.byIcon(Icons.lock_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(entry('locked.txt'));
      await tester.pump();
      expect(
        find.text('Protected with a password: DocHelper cannot open it yet.'),
        findsWidgets,
      );

      await tester.tap(entry('docs'));
      await tester.pump();
      await tester.tap(entry('docs/inner'));
      await tester.pump();
      expect(entry('docs/inner/deep.txt'), findsOneWidget);
    });

    testWidgets('extract all writes the files and lists what it skipped', (
      tester,
    ) async {
      await open(tester, carefulZip());
      await until(tester, entry('readme.txt'));

      await tester.tap(find.byKey(const ValueKey('archive-extract-all')));
      await until(tester, find.byKey(const ValueKey('archive-summary')));

      final out = '${paths.documents.path}/Bundle';
      expect(File('$out/readme.txt').readAsStringSync(), 'Read me first');
      expect(
        File('$out/docs/inner/deep.txt').readAsStringSync(),
        'Deep inside',
      );
      // Nothing lands outside the folder.
      expect(File('$out/evil.txt').readAsStringSync(), 'Climbed out');
      expect(File('${paths.documents.path}/evil.txt').existsSync(), isFalse);
      expect(File('${root.path}/evil.txt').existsSync(), isFalse);
      expect(File('$out/locked.txt').existsSync(), isFalse);
      expect(File('$out/shortcut').existsSync(), isFalse);

      expect(
        find.text(
          "3 files extracted to the folder “Bundle” in DocHelper's documents.",
        ),
        findsOneWidget,
      );
      expect(find.text('2 items not extracted'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('archive-skipped')));
      await tester.pumpAndSettle();
      expect(find.text('locked.txt'), findsWidgets);
      expect(find.textContaining('protected with a password'), findsOneWidget);
      expect(find.text('shortcut'), findsWidgets);
      expect(find.textContaining('symbolic link'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('archive-summary')), findsNothing);

      // A second time goes into a new folder rather than mixing files.
      await tester.tap(find.byKey(const ValueKey('archive-extract-all')));
      await until(tester, find.byKey(const ValueKey('archive-summary')));
      expect(
        File('${paths.documents.path}/Bundle (2)/readme.txt').existsSync(),
        isTrue,
      );
    });

    testWidgets('extract all of empty folders says so and leaves nothing', (
      tester,
    ) async {
      final src = Directory('${root.path}/src/a/b')
        ..createSync(recursive: true);
      final out = '${root.path}/Folders.zip';
      await tester.runAsync(
        () => ArchiveCore.createAsync([
          ArchiveSource(src.parent.parent.path),
        ], out),
      );
      await open(tester, out);
      await until(tester, entry('src'));

      await tester.tap(find.byKey(const ValueKey('archive-extract-all')));
      await until(tester, find.byKey(const ValueKey('archive-summary')));
      expect(find.text('Nothing extracted'), findsOneWidget);
      expect(
        find.text(
          'This archive holds only empty folders, so there was nothing to '
          'extract.',
        ),
        findsOneWidget,
      );
      // The folders the engine made for them are gone again.
      expect(Directory('${paths.documents.path}/Folders').existsSync(), false);
    });

    testWidgets('builds only the rows on screen of a large folder', (
      tester,
    ) async {
      final src = Directory('${root.path}/many')..createSync();
      for (var i = 0; i < 2000; i++) {
        File(
          '${src.path}/${i.toString().padLeft(4, '0')}.txt',
        ).writeAsStringSync('$i');
      }
      final out = '${root.path}/Many.zip';
      await tester.runAsync(
        () => ArchiveCore.createAsync([ArchiveSource(src.path)], out),
      );
      await open(tester, out);
      await until(tester, entry('many'));
      await tester.tap(entry('many'));
      await tester.pump();
      expect(entry('many/0000.txt'), findsOneWidget);
      expect(entry('many/1999.txt'), findsNothing);
      final built = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('archive-entry-many/');
      });
      expect(built.evaluate().length, lessThan(60));
    });

    testWidgets('extract all publishes each file in the matching folder', (
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
        final folder = args['subfolder'] as String;
        return {
          'uri': 'content://media/external_primary/downloads/${saves.length}',
          'name': args['displayName'],
          'publicPath':
              '/storage/emulated/0/Download/DocHelper/$folder/${args['displayName']}',
        };
      });
      await open(tester, carefulZip());
      await until(tester, entry('readme.txt'));

      await tester.tap(find.byKey(const ValueKey('archive-extract-all')));
      await until(tester, find.byKey(const ValueKey('archive-summary')));

      final out = '${paths.documents.path}/Bundle';
      expect(saves, [
        {
          'sourcePath': '$out/readme.txt',
          'displayName': 'readme.txt',
          'location': 'Downloads',
          'mimeType': 'text/plain',
          'subfolder': 'Bundle',
        },
        {
          'sourcePath': '$out/docs/inner/deep.txt',
          'displayName': 'deep.txt',
          'location': 'Downloads',
          'mimeType': 'text/plain',
          'subfolder': 'Bundle/docs/inner',
        },
        {
          'sourcePath': '$out/evil.txt',
          'displayName': 'evil.txt',
          'location': 'Downloads',
          'mimeType': 'text/plain',
          'subfolder': 'Bundle',
        },
      ]);
      expect(
        find.text('3 files extracted to Download/DocHelper/Bundle.'),
        findsOneWidget,
      );
      final records = await tester.runAsync(PublicPdfSaveService.documents);
      expect(records!.map((r) => r.workingPath), [
        '$out/readme.txt',
        '$out/docs/inner/deep.txt',
        '$out/evil.txt',
      ]);
    });

    testWidgets('says when copying to Download stops partway', (tester) async {
      DocumentSaveService.publishOverride = true;
      var calls = 0;
      messenger.setMockMethodCallHandler(storage, (call) async {
        if (call.method == 'getStorageInfo') {
          return {'sdkInt': 36, 'hasFullAccess': false, 'roots': <String>[]};
        }
        if (++calls == 2) {
          throw PlatformException(code: 'PUBLIC_SAVE_FAILED', message: 'Full');
        }
        return {
          'uri': 'content://media/external_primary/downloads/$calls',
          'name': 'readme.txt',
          'publicPath': '/storage/emulated/0/Download/DocHelper/Bundle/x',
        };
      });
      await open(tester, carefulZip());
      await until(tester, entry('readme.txt'));

      await tester.tap(find.byKey(const ValueKey('archive-extract-all')));
      await until(tester, find.byKey(const ValueKey('archive-summary')));

      expect(calls, 2, reason: 'Stops at the first failure');
      expect(
        find.text(
          "3 files extracted to the folder “Bundle” in DocHelper's documents.",
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Only 1 of 3 could be copied to Download/DocHelper',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Full'), findsOneWidget);
      final out = '${paths.documents.path}/Bundle';
      expect(File('$out/docs/inner/deep.txt').existsSync(), isTrue);
    });

    testWidgets('saves one file from its menu into the app documents', (
      tester,
    ) async {
      await open(tester, carefulZip());
      await until(tester, entry('readme.txt'));

      for (final expected in ['readme.txt', 'readme (2).txt']) {
        await tester.longPress(entry('readme.txt'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('archive-menu-save')));
        await until(
          tester,
          find.text("Saved $expected in DocHelper's documents."),
        );
        expect(
          File('${paths.documents.path}/$expected').readAsStringSync(),
          'Read me first',
        );
      }

      // A link's menu says why it cannot be saved, and offers nothing.
      await tester.tap(
        find.descendant(
          of: entry('shortcut'),
          matching: find.byTooltip('More'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Links are listed'), findsOneWidget);
      final save = tester.widget<ListTile>(
        find.byKey(const ValueKey('archive-menu-save')),
      );
      expect(save.enabled, isFalse);
    });

    testWidgets('removes what it extracted for opening a day later', (
      tester,
    ) async {
      final base = Directory('${paths.temporary.path}/archives');
      final old = Directory('${base.path}/old')..createSync(recursive: true);
      File('${old.path}/a.txt').writeAsStringSync('old');
      final fresh = Directory('${base.path}/fresh')..createSync();
      Process.runSync('touch', ['-t', '202001010000', old.path]);

      await open(tester, carefulZip());
      for (var i = 0; i < 50 && old.existsSync(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    testWidgets('says a damaged archive is damaged', (tester) async {
      final file = File('${root.path}/broken.zip')
        ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, ...List.filled(60, 7)]);
      await open(tester, file.path);
      await until(tester, find.byKey(const ValueKey('archive-error')));
      expect(
        find.text('This archive is damaged, so DocHelper cannot read it.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('archive-open-other')), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-extract-all')), findsNothing);
    });

    testWidgets('names a RAR archive as not supported', (tester) async {
      final file = File('${root.path}/old.rar')
        ..writeAsBytesSync([
          ...'Rar!'.codeUnits,
          0x1A,
          0x07,
          0x00,
          ...List.filled(40, 0),
        ]);
      await open(tester, file.path);
      await until(tester, find.byKey(const ValueKey('archive-error')));
      expect(
        find.textContaining('RAR archives are not supported'),
        findsOneWidget,
      );

      // The archive goes straight to another app: no sheet repeats that
      // DocHelper cannot open it.
      const openFile = MethodChannel('open_file');
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(openFile, (call) async {
        calls.add(call);
        return '{"type": -1, "message": "No app"}';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(openFile, null));
      await tester.tap(find.byKey(const ValueKey('archive-open-other')));
      await tester.pumpAndSettle();
      expect(calls.single.arguments, containsPair('file_path', file.path));
      expect(
        calls.single.arguments,
        containsPair('type', 'application/vnd.rar'),
      );
      expect(find.textContaining('cannot open this'), findsNothing);
      expect(
        find.text('No app on this phone can open old.rar.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'offers a damaged ZIP to another app without saying ZIP is unsupported',
      (tester) async {
        final file = File('${root.path}/broken.zip')
          ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, ...List.filled(60, 7)]);
        const openFile = MethodChannel('open_file');
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(openFile, (call) async {
          calls.add(call);
          return '{"type": 0, "message": "done"}';
        });
        addTearDown(() => messenger.setMockMethodCallHandler(openFile, null));
        await open(tester, file.path);
        await until(tester, find.byKey(const ValueKey('archive-error')));
        await tester.tap(find.byKey(const ValueKey('archive-open-other')));
        await tester.pumpAndSettle();
        expect(calls.single.arguments, containsPair('type', 'application/zip'));
        expect(find.textContaining('cannot open this'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });
}
