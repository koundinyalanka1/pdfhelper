import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/widgets/markup_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Markdown and HTML reading view. Most tests build documents by hand;
/// the last group reads real Markdown and HTML through the text engine:
///   eval "$(bash scripts/build_libs.sh env)"
///   flutter test test/widgets/markup_view_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<Map<Object?, Object?>> launched;

  // url_launcher's own channel: what a tapped link asks the platform for.
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // A 4 x 3 red PNG.
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGP4z8AARww4OQD1MQv1NXv7ggAAAABJRU5ErkJggg==';
  final png = base64.decode(pngBase64);

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_markup_view');
    SharedPreferences.setMockInitialValues({});
    launched = [];
    messenger.setMockMethodCallHandler(launcher, (call) async {
      if (call.method == 'launch') {
        launched.add(call.arguments as Map<Object?, Object?>);
      }
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(launcher, null);
    root.deleteSync(recursive: true);
  });

  Widget app(MarkupDocument document, {String? base, ThemeProvider? theme}) {
    final home = MaterialApp(
      home: Scaffold(
        body: MarkupView(document: document, baseDirectory: base),
      ),
    );
    return theme == null
        ? ChangeNotifierProvider(create: (_) => ThemeProvider(), child: home)
        : ChangeNotifierProvider.value(value: theme, child: home);
  }

  MarkupDocument doc(List<MarkupBlock> blocks) =>
      MarkupDocument(blocks: blocks);

  MarkupParagraph para(String text) => MarkupParagraph([MarkupText(text)]);

  /// Every run of text drawn, in order.
  List<TextSpan> runs(WidgetTester tester) {
    final out = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) out.add(span);
        return true;
      });
    }
    return out;
  }

  TextSpan run(WidgetTester tester, String text) =>
      runs(tester).singleWhere((span) => span.text == text);

  /// The paragraph showing [text] somewhere in it.
  RichText paragraphOf(WidgetTester tester, String text) => tester
      .widgetList<RichText>(find.byType(RichText))
      .singleWhere((rich) => rich.text.toPlainText().contains(text));

  /// The provider an [Image] reads from, under any resizing.
  ImageProvider providerOf(Image image) {
    final provider = image.image;
    return provider is ResizeImage ? provider.imageProvider : provider;
  }

  /// The view's own scrolling, not that of a code block or table in it.
  Finder listScrollable() => find
      .descendant(
        of: find.byKey(const ValueKey('markup-list')),
        matching: find.byType(Scrollable),
      )
      .first;

  File writePng(String path) => File('${root.path}/$path')
    ..createSync(recursive: true)
    ..writeAsBytesSync(png);

  testWidgets('headings shrink by level and the first two have a rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        doc([
          for (var level = 1; level <= 6; level++)
            MarkupHeading(level, [MarkupText('Heading $level')]),
          para('Body text'),
        ]),
      ),
    );
    final sizes = [
      for (var level = 1; level <= 6; level++)
        run(tester, 'Heading $level').style!.fontSize!,
    ];
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i], lessThan(sizes[i - 1]));
    }
    expect(sizes.last, lessThan(run(tester, 'Body text').style!.fontSize!));
    expect(run(tester, 'Heading 1').style!.fontWeight, FontWeight.w700);
    expect(run(tester, 'Body text').style!.fontWeight, isNull);
    // Only the level-1 and level-2 headings are underlined by a rule.
    expect(find.byType(Divider), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('markup-block-2')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
  });

  testWidgets('styled runs carry their styles', (tester) async {
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupText('plain '),
            MarkupText('bold', bold: true),
            MarkupText(' '),
            MarkupText('italic', italic: true),
            MarkupText(' '),
            MarkupText('code', code: true),
            MarkupText(' '),
            MarkupText('gone', strike: true),
            MarkupText(' '),
            MarkupText('both', bold: true, italic: true),
            MarkupText(' '),
            MarkupText('site', link: 'https://example.com'),
            MarkupText(' '),
            MarkupText('old site', strike: true, link: 'https://old.example'),
            MarkupBreak(),
            MarkupText('next line'),
          ]),
        ]),
      ),
    );
    final plain = run(tester, 'plain ').style!;
    expect(plain.fontWeight, isNull);
    expect(plain.fontStyle, isNull);
    expect(plain.decoration, isNull);
    expect(plain.backgroundColor, isNull);
    expect(run(tester, 'plain ').recognizer, isNull);

    expect(run(tester, 'bold').style!.fontWeight, FontWeight.w700);
    expect(run(tester, 'italic').style!.fontStyle, FontStyle.italic);
    final both = run(tester, 'both').style!;
    expect(both.fontWeight, FontWeight.w700);
    expect(both.fontStyle, FontStyle.italic);

    final code = run(tester, 'code').style!;
    expect(code.fontFamily, 'monospace');
    expect(code.backgroundColor, isNotNull);
    expect(code.fontSize, lessThan(plain.fontSize!));

    expect(run(tester, 'gone').style!.decoration, TextDecoration.lineThrough);

    final site = run(tester, 'site');
    expect(site.style!.decoration, TextDecoration.underline);
    expect(site.style!.color, isNot(plain.color));
    expect(site.recognizer, isA<TapGestureRecognizer>());
    final oldSite = run(tester, 'old site').style!.decoration!;
    expect(oldSite.contains(TextDecoration.underline), isTrue);
    expect(oldSite.contains(TextDecoration.lineThrough), isTrue);

    // A hard break is a new line within the same paragraph.
    expect(
      paragraphOf(tester, 'plain').text.toPlainText(),
      endsWith('old site\nnext line'),
    );
  });

  test('only web and e-mail links lead anywhere', () {
    for (final link in [
      'https://example.com/a?b=c#d',
      'http://example.com',
      'HTTPS://Example.com/Path',
      ' https://example.com/padded ',
      'mailto:me@example.com',
      'mailto:?to=me@example.com',
    ]) {
      expect(MarkupView.linkTarget(link), isNotNull, reason: link);
    }
    expect(
      MarkupView.linkTarget('https://example.com/a b').toString(),
      'https://example.com/a%20b',
    );
    for (final link in [
      'javascript:alert(1)',
      'JavaScript:alert(1)',
      'data:text/html,<b>hi</b>',
      'file:///sdcard/secret.txt',
      'intent://scan/#Intent;scheme=zxing;end',
      'content://media/external/1',
      'tel:123',
      'ftp://example.com/file',
      'notes/other.md',
      '../up.md',
      '/absolute/path.md',
      '#section',
      '?query',
      '',
      'https://',
      'https:///no-host',
      'mailto:',
      'www.example.com',
    ]) {
      expect(MarkupView.linkTarget(link), isNull, reason: link);
    }
  });

  testWidgets('tapping a web or e-mail link opens it outside the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupText('Read '),
            MarkupText('the site', link: 'https://example.com/docs'),
            MarkupText(', '),
            MarkupText('mail us', link: 'mailto:me@example.com'),
            MarkupText(', '),
            MarkupText('the script', link: 'javascript:alert(1)'),
            MarkupText(', '),
            MarkupText('the next page', link: 'next.md'),
            MarkupText(' or '),
            MarkupText('the top', link: '#top'),
            MarkupText('.'),
          ]),
        ]),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('the site'));
    await tester.pump();
    expect(launched, hasLength(1));
    expect(launched.single['url'], 'https://example.com/docs');
    // Out to the browser, not into a web view inside the app.
    expect(launched.single['useWebView'], isFalse);
    expect(launched.single['useSafariVC'], isFalse);

    await tester.tapOnText(find.textRange.ofSubstring('mail us'));
    await tester.pump();
    expect(launched.map((l) => l['url']), [
      'https://example.com/docs',
      'mailto:me@example.com',
    ]);

    // Links that would run script, or point inside the document or next
    // to it, look like links but do nothing.
    for (final text in ['the script', 'the next page', 'the top']) {
      expect(run(tester, text).recognizer, isNull, reason: text);
      expect(run(tester, text).style!.decoration, TextDecoration.underline);
      await tester.tapOnText(find.textRange.ofSubstring(text));
      await tester.pump();
    }
    expect(launched, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('says so when no app can open a link', (tester) async {
    messenger.setMockMethodCallHandler(launcher, (call) async => false);
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupText('site', link: 'https://example.com'),
          ]),
        ]),
      ),
    );
    await tester.tapOnText(find.textRange.ofSubstring('site'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No app can open this link.'), findsOneWidget);
  });

  test('finds pictures on the device the way a browser would', () {
    final logo = writePng('img/logo.png');
    final spaced = writePng('my pic.png');
    final hashed = writePng('odd#name.png');
    Directory('${root.path}/docs').createSync();
    final base = root.path;
    final docs = '${root.path}/docs';
    String? found(String src, [String? base]) =>
        MarkupView.localImage(src, base)?.path;

    expect(found('img/logo.png', base), logo.path);
    expect(found('./img/logo.png', base), endsWith('img/logo.png'));
    expect(
      File(found('../img/logo.png', docs)!).absolute.resolveSymbolicLinksSync(),
      logo.resolveSymbolicLinksSync(),
    );
    expect(found('img/logo.png', '$base/'), logo.path);
    expect(found('img/logo.png?raw=true', base), logo.path);
    expect(found('img/logo.png#dark', base), logo.path);
    expect(found('my%20pic.png', base), spaced.path);
    expect(found('my pic.png', base), spaced.path);
    expect(found('odd#name.png', base), hashed.path);
    expect(found(' img/logo.png ', base), logo.path);

    // Absolute paths and file: addresses need no folder.
    expect(found(logo.path), logo.path);
    expect(found(Uri.file(spaced.path).toString()), spaced.path);
    expect(found('file://localhost${logo.path}'), logo.path);

    for (final src in [
      'img/logo.png', // relative, but no folder to read it against
      'https://example.com/img/logo.png',
      '//example.com/img/logo.png',
      'data:image/png;base64,$pngBase64',
      'file://otherhost${logo.path}',
      'content://media/external/images/1',
      '',
    ]) {
      expect(found(src), isNull, reason: src);
    }
    expect(found('img/missing.png', base), isNull);
    expect(found('img', base), isNull, reason: 'a folder is not a picture');
    File('${root.path}/empty.png').createSync();
    expect(found('empty.png', base), isNull);
    // Devices and the like would be read without end.
    for (final device in ['/dev/zero', '/dev/urandom', '/proc/self/status']) {
      if (File(device).existsSync()) {
        expect(found(device), isNull, reason: device);
        expect(found('file://$device'), isNull, reason: device);
      }
    }
    expect(found('../../../../../../../../dev/zero', base), isNull);
    expect(found('https://example.com/img/logo.png', base), isNull);
  });

  test('reads embedded pictures only when they are small PNG, JPEG or GIF', () {
    expect(MarkupView.dataImage('data:image/png;base64,$pngBase64'), png);
    expect(MarkupView.dataImage('DATA:Image/PNG;Base64,$pngBase64'), png);
    // Wrapped lines and missing padding, as pages carry them.
    final wrapped = pngBase64
        .replaceAll('=', '')
        .replaceAllMapped(RegExp('.{20}'), (m) => '${m[0]}\n  ');
    expect(MarkupView.dataImage('data:image/png;base64,$wrapped'), png);
    // Labelled as a JPEG but a PNG inside: still a picture we can show.
    expect(MarkupView.dataImage('data:image/jpeg;base64,$pngBase64'), png);
    final gif = base64.encode([...'GIF89a'.codeUnits, 1, 0, 1, 0]);
    expect(MarkupView.dataImage('data:image/gif;base64,$gif'), isNotNull);
    final jpeg = base64.encode([0xFF, 0xD8, 0xFF, 0xE0, 0, 16]);
    expect(MarkupView.dataImage('data:image/jpg;base64,$jpeg'), isNotNull);

    final text = base64.encode(utf8.encode('<svg/>'));
    for (final src in [
      'data:image/svg+xml;base64,$text',
      'data:image/png;base64,$text', // says PNG, is not
      'data:image/png,$pngBase64', // not base64-encoded
      'data:image/png;base64,not*base64!',
      'data:image/png;base64',
      'data:text/html;base64,$pngBase64',
      'https://example.com/a.png',
      'image.png',
      '',
    ]) {
      expect(MarkupView.dataImage(src), isNull, reason: src);
    }

    // About 12 MB decoded: too big to decode on the reader's phone.
    final huge = 'data:image/png;base64,$pngBase64${'A' * (16 << 20)}';
    final watch = Stopwatch()..start();
    expect(MarkupView.dataImage(huge), isNull);
    expect(watch.elapsedMilliseconds, lessThan(500));
  });

  testWidgets('shows pictures beside the document from the device', (
    tester,
  ) async {
    final logo = writePng('img/logo.png');
    final spaced = writePng('my pic.png');
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupImage(alt: 'Logo', src: 'img/logo.png'),
            MarkupText(' and '),
            MarkupImage(alt: 'Spaced', src: 'my%20pic.png'),
            MarkupText(' but not '),
            MarkupImage(alt: 'Missing', src: 'img/missing.png'),
          ]),
        ]),
        base: root.path,
      ),
    );
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    expect(
      [for (final image in images) (providerOf(image) as FileImage).file.path],
      [logo.path, spaced.path],
    );
    expect(images.first.semanticLabel, 'Logo');
    // Decoded no wider than the screen shows.
    expect((images.first.image as ResizeImage).width, isNotNull);
    expect(find.text('Missing'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('markup-image-placeholder')),
      findsOneWidget,
    );

    // Without the document's folder, relative pictures cannot be found.
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupImage(alt: 'Logo', src: 'img/logo.png'),
          ]),
        ]),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('Logo'), findsOneWidget);
  });

  testWidgets('never downloads web pictures', (tester) async {
    final previous = HttpOverrides.current;
    final clients = _CountingHttpOverrides();
    HttpOverrides.global = clients;
    addTearDown(() => HttpOverrides.global = previous);

    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupImage(
              alt: 'Build status',
              src: 'https://ci.example/badge.svg',
              link: 'https://ci.example/runs',
            ),
            MarkupText(' '),
            MarkupImage(alt: '', src: 'http://example.com/a.png'),
            MarkupText(' '),
            MarkupImage(alt: 'Tracker', src: '//example.com/pixel.gif'),
          ]),
        ]),
        base: root.path,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Image), findsNothing);
    expect(
      find.byKey(const ValueKey('markup-image-placeholder')),
      findsNWidgets(3),
    );
    expect(find.byIcon(Icons.image_outlined), findsNWidgets(3));
    expect(find.text('Build status'), findsOneWidget);
    expect(find.text('Tracker'), findsOneWidget);
    expect(clients.created, 0);

    // A picture that links somewhere opens its link when tapped.
    await tester.tap(find.text('Build status'));
    await tester.pump();
    expect(launched.single['url'], 'https://ci.example/runs');
  });

  testWidgets('fits a wide picture to the view', (tester) async {
    File(
      '${root.path}/wide.png',
    ).writeAsBytesSync(img.encodePng(img.Image(width: 2000, height: 100)));
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([MarkupImage(alt: 'Wide', src: 'wide.png')]),
        ]),
        base: root.path,
      ),
    );
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (tester.getSize(find.byType(Image)).width > 0) break;
    }
    // 800 wide, less the padding on either side.
    final size = tester.getSize(find.byType(Image));
    expect(size.width, closeTo(768, 1));
    expect(size.height, closeTo(768 / 20, 1));
  });

  testWidgets('stands in for a file that is not a picture', (tester) async {
    File('${root.path}/broken.png').writeAsStringSync('not a picture');
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupImage(alt: 'Broken', src: 'broken.png'),
          ]),
        ]),
        base: root.path,
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    for (var i = 0; i < 100 && find.text('Broken').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.text('Broken'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows small embedded pictures and not others', (tester) async {
    final svg = base64.encode(utf8.encode('<svg/>'));
    await tester.pumpWidget(
      app(
        doc([
          MarkupParagraph([
            const MarkupImage(
              alt: 'Dot',
              src: 'data:image/png;base64,$pngBase64',
            ),
            const MarkupText(' '),
            MarkupImage(alt: 'Vector', src: 'data:image/svg+xml;base64,$svg'),
          ]),
        ]),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final bytes = (providerOf(image) as MemoryImage).bytes;
    expect(bytes, png);
    expect(find.text('Vector'), findsOneWidget);

    // Shown again, the picture is not decoded again: the same bytes are
    // what the image cache knows it by.
    final document = doc([
      const MarkupParagraph([
        MarkupImage(alt: 'Dot', src: 'data:image/png;base64,$pngBase64'),
      ]),
    ]);
    await tester.pumpWidget(app(document));
    final first = providerOf(tester.widget<Image>(find.byType(Image)));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(document));
    final again = providerOf(tester.widget<Image>(find.byType(Image)));
    expect(
      identical((first as MemoryImage).bytes, (again as MemoryImage).bytes),
      isTrue,
    );
  });

  testWidgets('numbers lists from their start and bullets them by depth', (
    tester,
  ) async {
    MarkupListItem item(String text, [List<MarkupBlock> more = const []]) =>
        MarkupListItem(blocks: [para(text), ...more]);
    await tester.pumpWidget(
      app(
        doc([
          MarkupList(
            ordered: true,
            start: 3,
            items: [item('three'), item('four'), item('five')],
          ),
          MarkupList(
            ordered: false,
            items: [
              item('top', [
                MarkupList(
                  ordered: false,
                  items: [
                    item('middle', [
                      MarkupList(
                        ordered: false,
                        items: [
                          item('bottom', [
                            MarkupList(
                              ordered: false,
                              items: [item('round again')],
                            ),
                          ]),
                        ],
                      ),
                    ]),
                  ],
                ),
              ]),
            ],
          ),
          MarkupList(
            ordered: true,
            start: -1,
            items: [item('minus one'), item('zero')],
          ),
        ]),
      ),
    );
    for (final number in ['3.', '4.', '5.', '-1.', '0.']) {
      expect(find.text(number), findsOneWidget, reason: number);
    }
    expect(find.text('1.'), findsNothing);
    expect(find.text('2.'), findsNothing);
    expect(find.byKey(const ValueKey('markup-bullet-disc')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('markup-bullet-circle')), findsOneWidget);
    expect(find.byKey(const ValueKey('markup-bullet-square')), findsOneWidget);

    // Each level sits further right than the one holding it.
    final lefts = [
      for (final text in ['top', 'middle', 'bottom', 'round again'])
        tester.getTopLeft(find.text(text)).dx,
    ];
    for (var i = 1; i < lefts.length; i++) {
      expect(lefts[i], greaterThan(lefts[i - 1]));
    }
    // The number sits on the line of its item, to the left of it.
    expect(
      tester.getTopLeft(find.text('3.')).dy,
      tester.getTopLeft(find.text('three')).dy,
    );
    expect(
      tester.getTopRight(find.text('3.')).dx,
      lessThan(tester.getTopLeft(find.text('three')).dx),
    );
  });

  testWidgets('shows task items as read-only checkboxes', (tester) async {
    await tester.pumpWidget(
      app(
        doc([
          MarkupList(
            ordered: false,
            items: [
              MarkupListItem(checked: true, blocks: [para('done')]),
              MarkupListItem(checked: false, blocks: [para('to do')]),
              MarkupListItem(blocks: [para('plain')]),
            ],
          ),
          MarkupList(
            ordered: true,
            items: [
              MarkupListItem(checked: true, blocks: [para('first done')]),
            ],
          ),
        ]),
      ),
    );
    expect(find.byIcon(Icons.check_box), findsNWidgets(2));
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    // A task item has its checkbox instead of a bullet; a numbered one
    // keeps its number too.
    expect(find.byKey(const ValueKey('markup-bullet-disc')), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.byIcon(Icons.check_box_outline_blank));
    await tester.pump();
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
  });

  testWidgets('shows code blocks monospaced, scrolling sideways', (
    tester,
  ) async {
    final source =
        'void main() {\n'
        '  print("${'a very long line of code that will not wrap ' * 4}");\n'
        '}';
    await tester.pumpWidget(
      app(
        doc([
          MarkupCode(language: 'dart', text: source),
          const MarkupCode(text: 'no language'),
        ]),
      ),
    );
    final code = tester.widget<Text>(find.text(source));
    expect(code.style!.fontFamily, 'monospace');
    expect(code.softWrap, isFalse);
    expect(find.text('dart'), findsOneWidget);
    // The language label is at the top right of its block.
    final block = tester.getRect(
      find.byKey(const ValueKey('markup-code')).first,
    );
    final label = tester.getRect(find.text('dart'));
    expect(label.right, closeTo(block.right - 10, 1));
    expect(label.top, lessThan(tester.getTopLeft(find.text(source)).dy));

    final scroller = tester.widget<SingleChildScrollView>(
      find.ancestor(
        of: find.text(source),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(scroller.scrollDirection, Axis.horizontal);
    expect(tester.getSize(find.text(source)).width, greaterThan(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('draws a thematic break as a divider', (tester) async {
    await tester.pumpWidget(
      app(doc([para('above'), const MarkupRule(), para('below')])),
    );
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('lays out tables with a bold header and aligned cells', (
    tester,
  ) async {
    const long =
        'A note long enough that its column would be wider than any phone '
        'if it were not wrapped inside its cell like this one is';
    await tester.pumpWidget(
      app(
        doc([
          const MarkupTable(
            align: [
              MarkupAlign.left,
              MarkupAlign.right,
              MarkupAlign.center,
              MarkupAlign.none,
            ],
            header: [
              [MarkupText('Item')],
              [MarkupText('Qty')],
              [MarkupText('Colour')],
              [MarkupText('Note')],
            ],
            rows: [
              [
                [MarkupText('Pen')],
                [MarkupText('10')],
                [MarkupText('blue')],
                [MarkupText(long)],
              ],
              // A short row is padded out with empty cells.
              [
                [MarkupText('Pad', bold: true)],
              ],
            ],
          ),
        ]),
      ),
    );
    expect(tester.takeException(), isNull);
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(3));
    for (final row in table.children) {
      expect(row.children, hasLength(4));
    }
    expect(table.border, isNotNull);

    for (final header in ['Item', 'Qty', 'Colour', 'Note']) {
      expect(run(tester, header).style!.fontWeight, FontWeight.w700);
    }
    expect(run(tester, 'Pen').style!.fontWeight, isNull);
    expect(run(tester, 'Pad').style!.fontWeight, FontWeight.w700);

    expect(paragraphOf(tester, 'Pen').textAlign, TextAlign.left);
    expect(paragraphOf(tester, '10').textAlign, TextAlign.right);
    expect(paragraphOf(tester, 'blue').textAlign, TextAlign.center);
    expect(paragraphOf(tester, 'long enough').textAlign, TextAlign.start);
    // Right-aligned numbers end at the same place as their header.
    expect(
      tester.getTopRight(find.text('10')).dx,
      closeTo(tester.getTopRight(find.text('Qty')).dx, 1),
    );

    // Long text wraps inside a column of sensible width.
    final note = tester.getSize(find.text(long));
    expect(note.width, lessThanOrEqualTo(320));
    expect(note.height, greaterThan(40));

    final scroller = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('markup-table')),
    );
    expect(scroller.scrollDirection, Axis.horizontal);
  });

  testWidgets('lays out tables without a header row', (tester) async {
    await tester.pumpWidget(
      app(
        doc([
          const MarkupTable(
            align: [MarkupAlign.none, MarkupAlign.none],
            rows: [
              [
                [MarkupText('a')],
                [MarkupText('b')],
              ],
            ],
          ),
          const MarkupTable(align: []),
        ]),
      ),
    );
    expect(tester.widget<Table>(find.byType(Table)).children, hasLength(1));
    expect(run(tester, 'a').style!.fontWeight, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nests quotes with a bar and muted text', (tester) async {
    await tester.pumpWidget(
      app(
        doc([
          para('outside'),
          MarkupQuote([
            para('outer'),
            MarkupQuote([para('inner')]),
          ]),
        ]),
      ),
    );
    // Each paragraph draws the bars of the quotes it is in: one beside
    // "outer", two beside "inner".
    expect(find.byKey(const ValueKey('markup-quote')), findsNWidgets(3));
    expect(
      find.ancestor(
        of: find.text('inner'),
        matching: find.byKey(const ValueKey('markup-quote')),
      ),
      findsNWidgets(2),
    );
    final outside = tester.getTopLeft(find.text('outside')).dx;
    final outer = tester.getTopLeft(find.text('outer')).dx;
    final inner = tester.getTopLeft(find.text('inner')).dx;
    expect(outer, greaterThan(outside));
    expect(inner, greaterThan(outer));
    final dark = AppColors(true);
    expect(run(tester, 'outside').style!.color, dark.textPrimary);
    expect(run(tester, 'inner').style!.color, dark.textSecondary);
  });

  testWidgets('survives nesting deeper than the screen is wide', (
    tester,
  ) async {
    MarkupBlock nest(int depth) {
      if (depth == 0) return para('the bottom');
      return depth.isEven
          ? MarkupQuote([para('quote $depth'), nest(depth - 1)])
          : MarkupList(
              ordered: depth % 3 == 0,
              items: [
                MarkupListItem(blocks: [para('item $depth'), nest(depth - 1)]),
              ],
            );
    }

    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(doc([nest(48)])));
    expect(tester.takeException(), isNull);
    expect(find.text('the bottom'), findsOneWidget);
    // Text never runs off the screen or shrinks to nothing.
    final bottom = tester.getRect(find.text('the bottom'));
    expect(bottom.left, lessThan(360 * 0.6));
    expect(bottom.width, greaterThan(40));
  });

  testWidgets('builds only what is on screen of a long document', (
    tester,
  ) async {
    final blocks = [
      for (var i = 0; i < 5000; i++)
        i % 50 == 0
            ? MarkupHeading(2, [MarkupText('Section ${i ~/ 50}')])
            : MarkupParagraph([
                MarkupText('Paragraph $i with '),
                const MarkupText('some bold', bold: true),
                const MarkupText(' text in it.'),
              ]),
    ];
    final watch = Stopwatch()..start();
    await tester.pumpWidget(app(doc(blocks)));
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(3000));

    final built = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('markup-block-');
    });
    expect(built.evaluate().length, lessThan(60));
    expect(find.byKey(const ValueKey('markup-block-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('markup-block-4999')), findsNothing);

    // A fling's worth of scrolling builds the blocks scrolled to and lets
    // go of those scrolled past.
    await tester.drag(
      find.byKey(const ValueKey('markup-list')),
      const Offset(0, -4000),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('markup-block-0')), findsNothing);
    final shown = [
      for (final element in built.evaluate())
        int.parse(
          (element.widget.key! as ValueKey<String>).value.substring(13),
        ),
    ];
    expect(shown.reduce((a, b) => a < b ? a : b), greaterThan(50));
    expect(shown.length, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds only what is on screen of one long list', (tester) async {
    // A task list of thousands of items is one block; it used to be built
    // and laid out whole, taking seconds.
    final list = MarkupList(
      ordered: true,
      items: [
        for (var i = 0; i < 4000; i++)
          MarkupListItem(
            checked: i.isOdd,
            blocks: [
              para('buy milk $i'),
              if (i == 0) para('and a second paragraph'),
            ],
          ),
      ],
    );
    final watch = Stopwatch()..start();
    await tester.pumpWidget(app(doc([list])));
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(3000));
    final built = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('markup-block-');
    });
    expect(built.evaluate().length, lessThan(60));
    expect(find.text('buy milk 0'), findsOneWidget);
    expect(find.text('buy milk 3999'), findsNothing);

    // An item's second paragraph lines up with its first, with no number
    // of its own.
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('and a second paragraph')).dx,
      tester.getTopLeft(find.text('buy milk 0')).dx,
    );
    expect(
      tester.getTopLeft(find.text('and a second paragraph')).dy,
      greaterThan(tester.getBottomLeft(find.text('buy milk 0')).dy),
    );
    expect(
      tester.getTopLeft(find.text('buy milk 1')).dy,
      greaterThan(tester.getBottomLeft(find.text('and a second paragraph')).dy),
    );

    await tester.scrollUntilVisible(
      find.text('buy milk 3999'),
      3000,
      scrollable: listScrollable(),
      maxScrolls: 2000,
    );
    expect(find.text('4000.'), findsOneWidget);
    expect(find.text('buy milk 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds only what is on screen of a long table, lined up', (
    tester,
  ) async {
    final table = MarkupTable(
      align: const [MarkupAlign.left, MarkupAlign.right, MarkupAlign.none],
      header: const [
        [MarkupText('Name')],
        [MarkupText('Amount')],
        [MarkupText('Note')],
      ],
      rows: [
        for (var r = 0; r < 3000; r++)
          [
            [MarkupText('Row $r')],
            [MarkupText('${r * 7}')],
            [MarkupText(r == 2990 ? 'a wider note than any before it' : 'ok')],
          ],
      ],
    );
    final watch = Stopwatch()..start();
    await tester.pumpWidget(app(doc([para('Above'), table])));
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(3000));
    expect(find.byType(Table).evaluate().length, lessThan(6));
    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Row 2999'), findsNothing);
    final amountRight = tester.getTopRight(find.text('Amount')).dx;
    final nameLeft = tester.getTopLeft(find.text('Name')).dx;

    await tester.scrollUntilVisible(
      find.text('Row 2990'),
      2000,
      scrollable: listScrollable(),
      maxScrolls: 2000,
    );
    // Later rows keep the header's column widths, and still the stripes.
    expect(tester.getTopLeft(find.text('Row 2990')).dx, nameLeft);
    expect(tester.getTopRight(find.text('${2990 * 7}')).dx, amountRight);
    expect(find.text('Name'), findsNothing);
    expect(find.text('a wider note than any before it'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolls a wide table sideways as one', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final table = MarkupTable(
      align: List.filled(8, MarkupAlign.none),
      header: [
        for (var c = 0; c < 8; c++) [MarkupText('Column number $c')],
      ],
      rows: [
        for (var r = 0; r < 60; r++)
          [
            for (var c = 0; c < 8; c++) [MarkupText('cell $r.$c')],
          ],
      ],
    );
    await tester.pumpWidget(app(doc([table])));
    final pieces = find.descendant(
      of: find.byKey(const ValueKey('markup-list')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(pieces.evaluate().length, greaterThan(1));
    final before = tester.getTopLeft(find.text('cell 25.0')).dx;
    expect(tester.getTopLeft(find.text('Column number 0')).dx, before);

    // Dragging the header's piece moves the rows of the next piece too.
    await tester.dragFrom(
      tester.getCenter(find.text('Column number 0')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    final header = tester.getTopLeft(find.text('Column number 0')).dx;
    expect(header, lessThan(before - 200));
    expect(tester.getTopLeft(find.text('cell 25.0')).dx, header);

    // A piece built later starts where the others are.
    final position = tester.state<ScrollableState>(listScrollable()).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(find.text('Column number 0'), findsNothing);
    expect(tester.getTopLeft(find.text('cell 59.0')).dx, header);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps a quote\'s bar unbroken down its paragraphs', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        doc([
          para('before'),
          MarkupQuote([para('one'), para('two'), para('three')]),
          para('after'),
        ]),
      ),
    );
    final bars = [
      for (final text in ['one', 'two', 'three'])
        tester.getRect(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byKey(const ValueKey('markup-quote')),
              )
              .first,
        ),
    ];
    // Each bar reaches down to where the next begins, and all share a left
    // edge, so they read as one.
    expect(bars[0].bottom, bars[1].top);
    expect(bars[1].bottom, bars[2].top);
    expect(bars.map((r) => r.left).toSet(), hasLength(1));
    // The space between quote and paragraphs around it is outside the bar.
    expect(
      bars[0].top,
      greaterThan(tester.getBottomLeft(find.text('before')).dy),
    );
    expect(
      tester.getTopLeft(find.text('after')).dy,
      greaterThan(bars[2].bottom),
    );
  });

  testWidgets('says when a document was cut short', (tester) async {
    await tester.pumpWidget(app(doc([para('only this')])));
    expect(find.byKey(const ValueKey('markup-truncated')), findsNothing);
    await tester.pumpWidget(
      app(MarkupDocument(blocks: [para('the beginning')], truncated: true)),
    );
    expect(find.text('the beginning'), findsOneWidget);
    expect(find.byKey(const ValueKey('markup-truncated')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('markup-truncated'))).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('the beginning')).dy),
    );
  });

  testWidgets('says so quietly when there is nothing to show', (tester) async {
    await tester.pumpWidget(app(const MarkupDocument()));
    expect(find.text('Nothing to show'), findsOneWidget);
    expect(find.byKey(const ValueKey('markup-list')), findsNothing);

    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([]),
          const MarkupParagraph([MarkupText('  '), MarkupBreak()]),
        ]),
      ),
    );
    expect(find.text('Nothing to show'), findsOneWidget);

    // A picture alone is something to show.
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([MarkupImage(alt: 'Only', src: 'a.png')]),
        ]),
      ),
    );
    expect(find.text('Nothing to show'), findsNothing);
    expect(find.text('Only'), findsOneWidget);
  });

  testWidgets('lets the reader select and copy text', (tester) async {
    await tester.pumpWidget(
      app(doc([para('Select me'), const MarkupCode(text: 'code too')])),
    );
    expect(find.byType(SelectionArea), findsOneWidget);
    for (final text in ['Select me', 'code too']) {
      expect(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
    }
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    // Holding a finger on a word selects it and offers to copy it.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('Select me'),
        matching: find.byType(RichText),
      ),
    );
    // Text registers for selection a frame after it is built.
    await tester.pump();
    final inSelect = paragraph.localToGlobal(
      paragraph.getOffsetForCaret(const TextPosition(offset: 2), Rect.zero) +
          const Offset(2, 8),
    );
    final hold = await tester.startGesture(inSelect);
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await tester.pump();
    expect(paragraph.selections, [
      const TextSelection(baseOffset: 0, extentOffset: 6),
    ]);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'Select');
  });

  testWidgets('follows the light and dark themes', (tester) async {
    final document = doc([
      const MarkupParagraph([
        MarkupText('ink '),
        MarkupText('link', link: 'https://example.com'),
      ]),
    ]);
    await tester.pumpWidget(app(document));
    final darkInk = run(tester, 'ink ').style!.color;
    final darkLink = run(tester, 'link').style!.color;
    expect(darkInk, AppColors(true).textPrimary);

    SharedPreferences.setMockInitialValues({'isDarkMode': false});
    final theme = ThemeProvider();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(theme.isDarkMode, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(document, theme: theme));
    await tester.pump();
    expect(run(tester, 'ink ').style!.color, AppColors(false).textPrimary);
    expect(run(tester, 'link').style!.color, isNot(darkLink));
    expect(run(tester, 'link').style!.color, isNot(darkInk));

    // Switching back while the view is open recolours it in place.
    await tester.runAsync(() => theme.toggleTheme(true));
    await tester.pump();
    expect(run(tester, 'ink ').style!.color, darkInk);
    expect(run(tester, 'link').style!.color, darkLink);
  });

  testWidgets('updates when given a new document', (tester) async {
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupText('old', link: 'https://old.example'),
          ]),
        ]),
      ),
    );
    await tester.pumpWidget(
      app(
        doc([
          const MarkupParagraph([
            MarkupText('new', link: 'https://new.example'),
          ]),
        ]),
      ),
    );
    expect(find.text('old'), findsNothing);
    await tester.tapOnText(find.textRange.ofSubstring('new'));
    await tester.pump();
    expect(launched.single['url'], 'https://new.example');
  });

  group('reading through the text engine', () {
    final available = TextCore.isAvailable && TextCore.canReadMarkup;

    testWidgets('shows a README as GitHub would', (tester) async {
      writePng('img/logo.png');
      const readme = '''
# Project

Some **bold**, *italic*, `code`, ~~gone~~ and [a link](https://example.com/a).
Bare www.example.org and me@example.com link too.

![Logo](img/logo.png) [![CI](https://ci.example/badge.svg)](https://ci.example)

3. three
4. four
   - nested
     - deeper

- [x] done
- [ ] todo

> quoted
> > nested quote

```dart
void main() {}
```

---

| Left | Center | Right |
|:-----|:------:|------:|
| first | middle | 1,250 |
''';
      final document = TextCore.markdown(readme);
      expect(document.title, 'Project');
      await tester.pumpWidget(app(document, base: root.path));
      expect(tester.takeException(), isNull);

      expect(run(tester, 'Project').style!.fontSize, 28);
      expect(run(tester, 'bold').style!.fontWeight, FontWeight.w700);
      expect(run(tester, 'italic').style!.fontStyle, FontStyle.italic);
      expect(run(tester, 'code').style!.fontFamily, 'monospace');
      expect(run(tester, 'gone').style!.decoration, TextDecoration.lineThrough);

      expect(
        (providerOf(tester.widget<Image>(find.byType(Image))) as FileImage)
            .file
            .path,
        '${root.path}/img/logo.png',
      );
      expect(find.text('CI'), findsOneWidget);

      await tester.tapOnText(find.textRange.ofSubstring('a link'));
      await tester.tapOnText(find.textRange.ofSubstring('www.example.org'));
      await tester.tapOnText(find.textRange.ofSubstring('me@example.com'));
      await tester.tap(find.text('CI'));
      await tester.pump();
      expect(launched.map((l) => l['url']), [
        'https://example.com/a',
        'http://www.example.org',
        'mailto:me@example.com',
        'https://ci.example',
      ]);

      expect(find.text('3.'), findsOneWidget);
      expect(find.text('4.'), findsOneWidget);
      // Bullets inside a numbered list start at the second depth.
      expect(find.byKey(const ValueKey('markup-bullet-disc')), findsNothing);
      expect(
        find.byKey(const ValueKey('markup-bullet-circle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('markup-bullet-square')),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.byType(Table),
        300,
        scrollable: listScrollable(),
      );
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      // A bar beside "quoted", and two beside "nested quote".
      expect(find.byKey(const ValueKey('markup-quote')), findsNWidgets(3));
      expect(find.text('void main() {}'), findsOneWidget);
      expect(find.text('dart'), findsOneWidget);
      expect(find.byType(Divider), findsWidgets);
      expect(paragraphOf(tester, 'Right').textAlign, TextAlign.right);
      expect(paragraphOf(tester, '1,250').textAlign, TextAlign.right);
      expect(paragraphOf(tester, 'middle').textAlign, TextAlign.center);
      expect(paragraphOf(tester, 'first').textAlign, TextAlign.left);
      expect(run(tester, 'Center').style!.fontWeight, FontWeight.w700);
      expect(tester.takeException(), isNull);
    }, skip: !available);

    testWidgets('shows a web page without its scripts', (tester) async {
      final page =
          '''
<!doctype html>
<html><head><title>The page</title><script>alert("no")</script>
<style>p { color: red }</style></head>
<body>
<h1>Hello</h1>
<p>A <b>bold</b> word, <a href="javascript:alert(1)">a trap</a> and
<a href="https://example.com/">a way out</a>.
<img alt="Dot" src="data:image/png;base64,$pngBase64">
<img alt="Remote" src="https://example.com/photo.jpg"></p>
<ol start="0"><li>zero<li>one</ol>
<table><tr><th>Name<th align="right">Qty<tr><td>Pen<td>10</table>
</body></html>
''';
      final document = (await tester.runAsync(() => TextCore.htmlAsync(page)))!;
      expect(document.title, 'The page');
      await tester.pumpWidget(app(document));
      expect(tester.takeException(), isNull);

      expect(find.textContaining('alert'), findsNothing);
      expect(find.textContaining('color: red'), findsNothing);
      expect(run(tester, 'Hello').style!.fontSize, 28);
      expect(run(tester, 'bold').style!.fontWeight, FontWeight.w700);
      expect(
        runs(tester).where((s) => s.recognizer != null).map((s) => s.text),
        ['a way out'],
      );
      await tester.tapOnText(find.textRange.ofSubstring('a way out'));
      await tester.pump();
      expect(launched.single['url'], 'https://example.com/');

      final image = tester.widget<Image>(find.byType(Image));
      expect((providerOf(image) as MemoryImage).bytes, png);
      expect(find.text('Remote'), findsOneWidget);

      expect(find.text('0.'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(run(tester, 'Name').style!.fontWeight, FontWeight.w700);
      expect(paragraphOf(tester, '10').textAlign, TextAlign.right);
    }, skip: !available);

    testWidgets('reads the app\'s own documents end to end', (tester) async {
      final files = [
        for (final path in [
          'README.md',
          'PLAN.md',
          'packages/flutter_text_core/README.md',
          'web/index.html',
        ])
          if (File(path).existsSync()) File(path),
      ];
      expect(files, isNotEmpty);
      for (final file in files) {
        final text = file.readAsStringSync();
        final document = file.path.endsWith('.html')
            ? TextCore.html(text)
            : TextCore.markdown(text);
        await tester.pumpWidget(app(document, base: file.parent.path));
        expect(tester.takeException(), isNull, reason: file.path);
        if (!file.path.endsWith('.html')) {
          expect(document.blocks, isNotEmpty, reason: file.path);
        }
        if (document.blocks.isEmpty) continue;
        // Scroll through to the end, building every piece.
        final scrollable = listScrollable();
        ScrollPosition position() =>
            tester.state<ScrollableState>(scrollable).position;
        for (
          var i = 0;
          i < 4000 && position().pixels < position().maxScrollExtent;
          i++
        ) {
          position().jumpTo(
            math.min(position().pixels + 500, position().maxScrollExtent),
          );
          await tester.pump();
          expect(tester.takeException(), isNull, reason: file.path);
        }
        // At the end: the list's estimate of its length can shrink as the
        // last pieces are laid out, leaving the jump a little past it.
        expect(
          position().pixels,
          greaterThanOrEqualTo(position().maxScrollExtent),
          reason: file.path,
        );
      }
    }, skip: !available);
  });
}

/// Counts the HTTP clients anything tries to make.
class _CountingHttpOverrides extends HttpOverrides {
  int created = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}
