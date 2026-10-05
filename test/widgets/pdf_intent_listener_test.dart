import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/main.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/home_screen.dart';
import 'package:pdfhelper/screens/pdf_viewer_screen.dart';
import 'package:pdfhelper/screens/splash_screen.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';
import 'package:pdfhelper/widgets/pdf_intent_listener.dart';
import 'package:provider/provider.dart';
import 'package:receive_intent/receive_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late StreamController<Intent?> intents;
  late GlobalKey<NavigatorState> key;
  String? pendingPath;
  Object? pendingError;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdf_intent_test');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
    intents = StreamController<Intent?>();
    key = GlobalKey<NavigatorState>();
    pendingPath = null;
    pendingError = null;
  });

  tearDown(() {
    // Cold-launch coverage does not subscribe to the injected warm stream.
    unawaited(intents.close());
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String pdf(String name) {
    final file = File('${root.path}/$name.pdf')..writeAsStringSync('%PDF-1.7');
    return file.path;
  }

  Future<String?> resolvePath() async {
    final error = pendingError;
    pendingError = null;
    if (error != null) throw error;
    final path = pendingPath;
    pendingPath = null;
    return path;
  }

  Widget app({bool splash = false}) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: PdfIntentListener(
        navigatorKey: key,
        intentStream: intents.stream,
        resolvePdfPath: resolvePath,
        child: MaterialApp(
          navigatorKey: key,
          routes: {'/': (_) => const Scaffold(body: Text('Existing library'))},
          onGenerateInitialRoutes: (_) => [
            MaterialPageRoute<void>(
              settings: RouteSettings(
                name: splash ? SplashScreen.routeName : '/',
              ),
              builder: (_) => splash
                  ? const SplashScreen()
                  : const Scaffold(body: Text('Existing library')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
  }

  void open(String path) {
    pendingPath = path;
    intents.add(const Intent(action: 'android.intent.action.VIEW'));
  }

  void expectViewerWithBanner() {
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PdfViewerScreen, skipOffstage: false),
        matching: find.byType(BannerAdWidget, skipOffstage: false),
      ),
      findsOneWidget,
    );
  }

  testWidgets('cold external launch builds viewer without splash or library', (
    tester,
  ) async {
    final path = pdf('Cold launch');
    await tester.pumpWidget(PDFHelperApp(initialPdfPath: path));
    await frames(tester);

    expectViewerWithBanner();
    expect(find.byType(BannerAdWidget, skipOffstage: false), findsOneWidget);
    expect(find.byType(SplashScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('intent during splash removes its timer and opens directly', (
    tester,
  ) async {
    await tester.pumpWidget(app(splash: true));
    await frames(tester);
    expect(find.byType(SplashScreen), findsOneWidget);

    open(pdf('During startup'));
    await frames(tester);
    expectViewerWithBanner();
    expect(find.byType(SplashScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    expect(key.currentState!.canPop(), isFalse);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expectViewerWithBanner();
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('startup drains deliveries received before stream subscribed', (
    tester,
  ) async {
    pendingPath = pdf('Pending launch');
    await tester.pumpWidget(app(splash: true));
    await frames(tester);
    expectViewerWithBanner();
    expect(find.byType(SplashScreen, skipOffstage: false), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('another intent replaces an external root viewer', (
    tester,
  ) async {
    pendingPath = pdf('First');
    await tester.pumpWidget(app(splash: true));
    await frames(tester);

    final second = pdf('Second');
    open(second);
    await frames(tester);
    final viewers = tester.widgetList<PdfViewerScreen>(
      find.byType(PdfViewerScreen, skipOffstage: false),
    );
    expect(viewers.map((viewer) => viewer.pdfPath), [second]);
    expectViewerWithBanner();
    expect(key.currentState!.canPop(), isFalse);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'warm intent preserves the existing library as Back destination',
    (tester) async {
      await tester.pumpWidget(app());
      await frames(tester);
      open(pdf('Warm launch'));
      await frames(tester);

      expectViewerWithBanner();
      key.currentState!.pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Existing library'), findsOneWidget);
    },
  );

  testWidgets('a failed provider does not block later intents', (tester) async {
    await tester.pumpWidget(app());
    await frames(tester);
    pendingError = StateError('Provider failed');
    intents.add(const Intent(action: 'android.intent.action.VIEW'));
    await frames(tester);

    open(pdf('Recovery'));
    await frames(tester);
    expectViewerWithBanner();
    expect(tester.takeException(), isNull);
  });
}
