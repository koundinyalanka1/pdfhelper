import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/screens/convert_screen.dart';
import 'package:pdfhelper/screens/scan_edit_screen.dart';
import 'package:pdfhelper/services/scan_route_observer.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/camera');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  const codec = StandardMethodCodec();
  late Directory root;
  late ValueNotifier<bool> active;
  late GlobalKey<NavigatorState> navigator;
  late List<String> commands;
  var cameraId = 0;
  Completer<void>? initializationGate;
  Completer<void>? captureGate;
  var flashUnavailable = false;
  late List<String> pickedPaths;
  late File captured;

  setUp(() {
    root = Directory.systemTemp.createTempSync('scan_camera_test');
    FakePathProvider.install(root);
    SharedPreferences.setMockInitialValues({});
    active = ValueNotifier(true);
    navigator = GlobalKey<NavigatorState>();
    commands = [];
    initializationGate = null;
    captureGate = null;
    flashUnavailable = false;
    pickedPaths = [];
    captured = File('${root.path}/camera.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 16, height: 24)));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (_) async => 1);
    messenger.setMockMethodCallHandler(picker, (_) async => pickedPaths);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'availableCameras':
          return [
            {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
          ];
        case 'create':
          commands.add('create');
          return {'cameraId': ++cameraId};
        case 'initialize':
          final id = (call.arguments as Map)['cameraId'] as int;
          await initializationGate?.future;
          await messenger.handlePlatformMessage(
            'flutter.io/cameraPlugin/camera$id',
            codec.encodeMethodCall(
              const MethodCall('initialized', {
                'previewWidth': 640.0,
                'previewHeight': 480.0,
                'exposureMode': 'auto',
                'focusMode': 'auto',
                'exposurePointSupported': true,
                'focusPointSupported': true,
              }),
            ),
            (_) {},
          );
          return null;
        case 'setFlashMode':
          commands.add('flash:${(call.arguments as Map)['mode']}');
          if (flashUnavailable) {
            throw PlatformException(code: 'NoFlash');
          }
          return null;
        case 'dispose':
          commands.add('dispose');
          return null;
        case 'takePicture':
          commands.add('capture');
          await captureGate?.future;
          return captured.path;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(permissions, null);
    messenger.setMockMethodCallHandler(picker, null);
    active.dispose();
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 75));
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [scanRouteObserver],
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => ConvertScreen(isActive: value),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  testWidgets(
    'camera and torch stop on hidden tab and stay stopped on resume',
    (tester) async {
      await open(tester);
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.tap(find.byTooltip('Turn flash on'));
      await flush(tester);
      expect(commands.last, 'flash:torch');
      active.value = false;
      await flush(tester);
      expect(commands.sublist(commands.length - 2), ['flash:off', 'dispose']);
      expect(find.byType(CameraPreview), findsNothing);
      final count = commands.where((c) => c == 'create').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush(tester);
      expect(commands.where((c) => c == 'create').length, count);
      active.value = true;
      await flush(tester);
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(commands.where((c) => c == 'create').length, count + 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );

  testWidgets('inactive Scan never acquires a camera', (tester) async {
    active.value = false;
    await open(tester);
    expect(commands, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('camera without a flash still initializes', (tester) async {
    flashUnavailable = true;
    await open(tester);
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(commands.last, 'dispose');
  });

  testWidgets('covering Scan releases camera until the covering route closes', (
    tester,
  ) async {
    await open(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covered')),
      ),
    );
    await flush(tester);
    expect(commands.last, 'dispose');
    final count = commands.where((c) => c == 'create').length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(commands.where((c) => c == 'create').length, count);
    navigator.currentState!.pop();
    await flush(tester);
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets(
    'initialization finishing after tab hides cannot reacquire camera',
    (tester) async {
      initializationGate = Completer<void>();
      await open(tester);
      active.value = false;
      await tester.pump();
      initializationGate!.complete();
      await flush(tester);
      expect(find.byType(CameraPreview), findsNothing);
      expect(commands.last, 'dispose');
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );

  testWidgets('capture retains torch and cancelling discards owned images', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Turn flash on'));
    await flush(tester);
    await tester.tap(find.bySemanticsLabel('Take photo'));
    await flush(tester);
    final capture = commands.indexOf('capture');
    expect(capture, greaterThan(0));
    expect(commands[capture - 1], 'flash:torch');
    expect(find.byType(ScanEditScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel edit'));
    await flush(tester);
    expect(captured.existsSync(), isFalse);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('late capture after hiding Scan does not open the editor', (
    tester,
  ) async {
    captureGate = Completer<void>();
    await open(tester);
    await tester.tap(find.bySemanticsLabel('Take photo'));
    await tester.pump();
    active.value = false;
    await flush(tester);
    active.value = true;
    await flush(tester);
    captureGate!.complete();
    await flush(tester);
    expect(find.byType(ScanEditScreen), findsNothing);
    expect(captured.existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets(
    'cancelled gallery batch discards copies and preserves originals',
    (tester) async {
      final second = File('${root.path}/gallery.jpg')
        ..writeAsBytesSync(captured.readAsBytesSync());
      pickedPaths = [captured.path, second.path];
      await open(tester);
      await tester.tap(find.text('Gallery'));
      await flush(tester);
      expect(commands.last, 'dispose');
      expect(find.byType(ScanEditScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel edit'));
      await flush(tester);
      expect(captured.existsSync(), isTrue);
      expect(second.existsSync(), isTrue);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => file.path),
        unorderedEquals(pickedPaths),
      );
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );
}
