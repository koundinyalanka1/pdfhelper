import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/home_tabs.dart';
import 'package:pdfhelper/config/features.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/image_viewer_screen.dart';
import 'package:pdfhelper/screens/make_zip_screen.dart';
import 'package:pdfhelper/screens/text_editor_screen.dart';
import 'package:pdfhelper/screens/tools_screen.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

/// A file on this machine, as the picker hands it over.
final class _Picked extends PlatformFile {
  _Picked(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  XFile get xFile => XFile(file.path);

  @override
  int? lengthSync() => file.lengthSync();

  @override
  Future<int?> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

/// Picks [file] whatever is asked for, and records what was asked.
class _FakePicker extends FilePickerPlatform {
  File? file;
  final types = <FileType>[];

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    types.add(type);
    final picked = file;
    return picked == null ? null : _Picked(picked);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<(DocHandoff, String?)> sent;

  setUp(() {
    sent = [];
  });

  Widget app() {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: ToolsScreen(onSendTo: (action, path) => sent.add((action, path))),
      ),
    );
  }

  /// Pumps the screen into a viewport tall enough to build the whole
  /// catalogue at once.
  ///
  /// A ListView only builds what is near the viewport, so an off-screen tool
  /// is not merely invisible — it does not exist to a finder. Giving the test
  /// room to render everything is what makes "is every tool still here?" a
  /// question the test can actually answer.
  Future<void> pumpTall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pump();
  }

  /// Scrolls a tool into view and taps it.
  ///
  /// The catalogue is taller than the 800x600 test viewport, so the lower
  /// sections have to be brought on screen before they can be hit.
  Future<void> tapTool(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every tool without a document being chosen first', (
    tester,
  ) async {
    // The point of the redesign: the catalogue is the screen, not a reward
    // for having already picked a file.
    await pumpTall(tester);

    for (final tool in [
      'Merge PDFs',
      'Split PDF',
      'Fill & sign',
      'Annotate',
      'Page numbers & watermark',
      'Compress PDF',
      'Pages as pictures',
      'Organize pages',
      'Document details',
      'Protect with a password',
      'Remove password',
      'Open in viewer',
      'Extract text',
      'Recognize text (OCR)',
      'Open a file',
      'Make a ZIP',
      'Open a ZIP',
    ]) {
      expect(find.text(tool), findsOneWidget, reason: '$tool is missing');
    }

    // Scanning has its own tab in the bar; an entry here that only switched
    // to it was a second door to the same room.
    expect(find.text('Scan to PDF'), findsNothing);

    // The AI tools are built but not shipped yet; they are hidden behind
    // Features.ai. Asserted against the flag rather than simply dropped, so
    // turning it on is a deliberate change that shows up here.
    for (final tool in ['Ask AI', 'AI models']) {
      expect(
        find.text(tool),
        Features.ai ? findsOneWidget : findsNothing,
        reason: '$tool should follow Features.ai',
      );
    }
  });

  testWidgets('groups the tools under headings', (tester) async {
    await pumpTall(tester);

    for (final section in [
      'Combine & split',
      'Fill, sign & mark up',
      'Edit document',
      'Read & extract',
      'Files',
    ]) {
      expect(find.text(section), findsOneWidget);
    }

    expect(
      find.text('On-device AI'),
      Features.ai ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('invites the user to choose a working document', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('Choose a PDF'), findsOneWidget);
  });

  testWidgets('Merge hands off with no document selected', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tapTool(tester, 'Merge PDFs');

    // Null, not a silent no-op: merge picks its own files.
    expect(sent, [(DocHandoff.merge, null)]);
  });

  testWidgets('Split hands off', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tapTool(tester, 'Split PDF');

    expect(sent, [(DocHandoff.split, null)]);
  });

  testWidgets('Make a ZIP opens its screen without a PDF chosen', (
    tester,
  ) async {
    // The Files section is below the first screenful, which a list does
    // not build.
    await pumpTall(tester);
    await tapTool(tester, 'Make a ZIP');

    expect(find.byType(MakeZipScreen), findsOneWidget);
    expect(sent, isEmpty);
  });

  group('Open a file', () {
    late Directory root;
    late _FakePicker picker;
    late FilePickerPlatform original;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      root = Directory.systemTemp.createTempSync('dochelper_open_file');
      original = FilePickerPlatform.instance;
      picker = _FakePicker();
      FilePickerPlatform.instance = picker;
    });

    tearDown(() {
      FilePickerPlatform.instance = original;
      root.deleteSync(recursive: true);
    });

    /// Taps the tool. The screen it opens shows a spinner while it reads
    /// the file, so the test pumps by time rather than until it settles.
    Future<void> openFile(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Open a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open a file'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('opens a picture from the phone in the picture viewer', (
      tester,
    ) async {
      // A picture never shows in Files, so this is its way in.
      picker.file = File('${root.path}/photo.png')
        ..writeAsBytesSync(base64Decode(_png));
      await pumpTall(tester);
      await openFile(tester);

      expect(picker.types, [FileType.any]);
      final viewer = tester.widget<ImageViewerScreen>(
        find.byType(ImageViewerScreen),
      );
      expect(viewer.path, picker.file!.path);
      expect(viewer.title, 'photo.png');
      expect(sent, isEmpty);
    });

    testWidgets('opens a web page in the text editor', (tester) async {
      picker.file = File('${root.path}/page.html')
        ..writeAsStringSync('<h1>Hello</h1>');
      await pumpTall(tester);
      await openFile(tester);

      final editor = tester.widget<TextEditorScreen>(
        find.byType(TextEditorScreen),
      );
      expect(editor.path, picker.file!.path);
    });

    testWidgets('does nothing when nothing is picked', (tester) async {
      await pumpTall(tester);
      await tapTool(tester, 'Open a file');
      expect(find.byType(ToolsScreen), findsOneWidget);
      expect(picker.types, [FileType.any]);
    });
  });
}

/// A 4 x 3 red PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGP4z8AARww4OQD1MQv1NXv7ggAAAABJRU5ErkJggg==';
