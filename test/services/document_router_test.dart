import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/archive_screen.dart';
import 'package:pdfhelper/screens/document_editor_screen.dart';
import 'package:pdfhelper/screens/image_viewer_screen.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/screens/sheet_editor_screen.dart';
import 'package:pdfhelper/screens/slide_editor_screen.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/services/ads_service.dart';
import 'package:pdfhelper/services/document_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

/// Which screen each kind of file opens in, whichever way it arrives
/// (Files, recents, "Open with" from another app).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('screenFor', () {
    void expectScreen(List<String> paths, Type screen) {
      for (final path in paths) {
        final built = DocumentRouter.screenFor('/storage/$path');
        expect(built.runtimeType, screen, reason: path);
      }
    }

    test('PDFs open in the viewer', () {
      expectScreen(['a.pdf', 'B.PDF'], PdfViewerScreen);
    });

    test('text, Markdown, HTML and JSON open in the text editor', () {
      expectScreen([
        'a.txt',
        'b.md',
        'c.markdown',
        'd.html',
        'e.htm',
        'f.json',
        'g.log',
      ], TextEditorScreen);
    });

    test('Office files open in their editors, flat OpenDocument too', () {
      expectScreen([
        'a.xlsx',
        'b.csv',
        'c.ods',
        'd.fods',
        'e.xls',
      ], SheetEditorScreen);
      expectScreen([
        'a.docx',
        'b.odt',
        'c.fodt',
        'd.rtf',
        'e.doc',
      ], DocumentEditorScreen);
      expectScreen(['a.pptx', 'b.odp', 'c.fodp', 'd.ppt'], SlideEditorScreen);
    });

    test('pictures open in the image viewer', () {
      expectScreen([
        'a.jpg',
        'b.JPEG',
        'c.png',
        'd.webp',
        'e.gif',
        'f.bmp',
        'g.heic',
        'h.heif',
      ], ImageViewerScreen);
    });

    test('ZIP, TAR and gzip open in the archive screen', () {
      expectScreen([
        'a.zip',
        'b.tar',
        'backup.tar.gz',
        'c.tgz',
        'd.gz',
      ], ArchiveScreen);
    });

    test('formats DocHelper cannot open have no screen', () {
      for (final path in ['a.7z', 'b.rar', 'c.exe', 'noextension', 'd.']) {
        expect(
          DocumentRouter.screenFor('/storage/$path'),
          isNull,
          reason: path,
        );
      }
    });

    test('screens get the title given, or the file name', () {
      final named =
          DocumentRouter.screenFor('/x/IMG_1.jpg', title: 'Holiday')
              as ImageViewerScreen;
      expect(named.title, 'Holiday');
      expect(named.path, '/x/IMG_1.jpg');

      // A copy handed over by "Open with" loses its temporary prefix.
      final handed =
          DocumentRouter.screenFor('/cache/intent_1712_Bills.zip')
              as ArchiveScreen;
      expect(handed.title, 'Bills.zip');
      expect(handed.path, '/cache/intent_1712_Bills.zip');
    });

    test('a file from another app gets a screen, or an explanation', () {
      expect(externalDocumentScreen('/cache/a.zip'), isA<ArchiveScreen>());
      expect(externalDocumentScreen('/cache/a.png'), isA<ImageViewerScreen>());
      expect(
        externalDocumentScreen('/cache/a.rar'),
        isA<UnsupportedDocumentScreen>(),
      );
    });
  });

  group('open', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dochelper_router');
      FakePathProvider.install(root);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      FakePathProvider.restore();
      root.deleteSync(recursive: true);
    });

    Future<void> pumpOpener(WidgetTester tester, String path) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => DocumentRouter.open(context, path),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('an archive DocHelper cannot unpack offers another app', (
      tester,
    ) async {
      await pumpOpener(tester, '${root.path}/photos.7z');
      expect(
        find.text(
          'DocHelper cannot open this archive format (.7z) yet. Until then, '
          'you can open it in another app or share it.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open with another app'), findsOneWidget);
      expect(find.byType(ArchiveScreen), findsNothing);
    });

    testWidgets('a ZIP opens in the archive screen', (tester) async {
      await pumpOpener(tester, '${root.path}/missing.zip');
      // Let the archive screen's background listing fail and settle.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(ArchiveScreen), findsOneWidget);
      expect(find.textContaining('DocHelper cannot open this'), findsNothing);
    });

    testWidgets('opening a document counts toward ad operations', (
      tester,
    ) async {
      final before = AdsService.instance.completedOperationCount;
      await pumpOpener(tester, '${root.path}/notes.txt');
      expect(AdsService.instance.completedOperationCount, before + 1);
    });
  });
}
