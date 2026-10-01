import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';
import 'package:pdfhelper/widgets/pdf_text_selection_overlay.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  final nativeLibrary = Platform.environment['PDF_CORE_LIB_PATH'] ?? '';
  if (nativeLibrary.isEmpty || !File(nativeLibrary).existsSync()) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;
  String? copied;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdfhelper_text_selection');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    pdf = _writePdf(root, text: 'Hello world');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(home: PdfViewerScreen(pdfPath: pdf.path)),
      ),
    );
    await flush(tester);
    expect(find.byTooltip('Select text'), findsOneWidget);
    await tester.tap(find.byTooltip('Select text'));
    await flush(tester);
  }

  testWidgets('selects and copies a word over the real rendered page', (
    tester,
  ) async {
    await open(tester);
    final overlay = find.byType(PdfTextSelectionOverlay);
    expect(overlay, findsOneWidget);
    final layout = tester.widget<PdfTextSelectionOverlay>(overlay).layout;
    expect(layout.text, contains('Hello world'));
    final glyph = layout.glyphs.first;
    final rect = tester.getRect(overlay);
    final word = Offset(
      rect.left + (glyph.left + glyph.right) / 2 * rect.width / layout.width,
      rect.top + (glyph.top + glyph.bottom) / 2 * rect.height / layout.height,
    );

    await tester.longPressAt(word);
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'Hello');
    expect(find.text('Copy'), findsNothing);
    expect(find.byType(BannerAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back exits text selection before leaving the document', (
    tester,
  ) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byTooltip('Select text'), findsOneWidget);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an image-only page explains why text cannot be selected', (
    tester,
  ) async {
    pdf = _writePdf(root, text: '');
    await open(tester);
    expect(find.byType(PdfTextSelectionOverlay), findsNothing);
    expect(
      find.text('No selectable text on this page. Scanned images need OCR.'),
      findsOneWidget,
    );
    expect(copied, isNull);
    expect(tester.takeException(), isNull);
  });
}

File _writePdf(Directory root, {required String text}) {
  final content = text.isEmpty
      ? '0.8 g 40 240 200 100 re f'
      : 'BT /F1 20 Tf 1 0 0 1 40 310 Tm ($text) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier '
        '/FirstChar 32 /LastChar 126 /Widths [${List.filled(95, '600').join(' ')}] >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return File('${root.path}/Text.pdf')..writeAsStringSync(output.toString());
}
