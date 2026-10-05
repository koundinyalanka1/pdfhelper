import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/crop_screen.dart';
import 'package:pdfhelper/screens/scan_edit_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File original;
  late Uint8List imageBytes;
  late GlobalKey<NavigatorState> navigator;
  setUp(() {
    root = Directory.systemTemp.createTempSync('scan_edit_test');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    imageBytes = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 16, height: 24)),
    );
    original = File('${root.path}/existing.jpg')..writeAsBytesSync(imageBytes);
    navigator = GlobalKey<NavigatorState>();
  });
  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (i >= 5 && (until == null || until())) return;
    }
    fail('Timed out waiting for scan image I/O to finish');
  }

  Future<void> open(WidgetTester tester, {ValueChanged<String>? onSave}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Scan home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ScanEditScreen(
          imagePath: original.path,
          onSave: onSave ?? (_) => fail('Cancel must not save'),
        ),
      ),
    );
    await flush(tester);
  }

  for (final systemBack in [false, true]) {
    testWidgets(
      'cancel existing edit with ${systemBack ? 'Back' : 'X'} preserves source',
      (tester) async {
        await open(tester);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('Cancel edit'));
        }
        await flush(tester);
        expect(find.text('Scan home'), findsOneWidget);
        expect(original.readAsBytesSync(), imageBytes);
      },
    );
  }

  testWidgets('repeated crops and undo create no retained intermediate files', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Crop & Straighten'));
      await flush(tester);
      expect(find.byType(CropScreen), findsOneWidget);
      navigator.currentState!.pop(imageBytes);
      await flush(tester);
    }
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel edit'));
    await flush(tester);
    expect(original.readAsBytesSync(), imageBytes);
    expect(
      root.listSync(recursive: true).whereType<File>().map((f) => f.path),
      [original.path],
    );
  });

  testWidgets(
    'save delivers a separate complete file and preserves borrowed source',
    (tester) async {
      String? replacement;
      await open(tester, onSave: (path) => replacement = path);
      await tester.tap(find.text('Done'));
      await flush(tester, until: () => replacement != null);
      expect(replacement, isNotNull);
      expect(replacement, isNot(original.path));
      expect(File(replacement!).readAsBytesSync(), imageBytes);
      expect(original.readAsBytesSync(), imageBytes);
      expect(find.text('Scan home'), findsOneWidget);
    },
  );

  testWidgets(
    'owner rejecting replacement retains the original and cleans output',
    (tester) async {
      await open(
        tester,
        onSave: (_) => throw StateError('owner rejected replacement'),
      );
      await tester.tap(find.text('Done'));
      await flush(
        tester,
        until: () =>
            find.textContaining('Error saving image:').evaluate().isNotEmpty,
      );
      expect(find.byType(ScanEditScreen), findsOneWidget);
      expect(original.readAsBytesSync(), imageBytes);
      expect(
        root.listSync(recursive: true).whereType<File>().map((f) => f.path),
        [original.path],
      );
    },
  );
}
