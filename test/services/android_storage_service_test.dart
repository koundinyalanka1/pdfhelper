import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/android_storage_service.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storageChannel = MethodChannel('com.yourmateapps.pdfhelper/storage');
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late int sdkInt;
  late bool fullAccess;
  late bool grantOnRequest;
  late List<int> requested;
  late List<String> storageCalls;

  setUp(() {
    sdkInt = 36;
    fullAccess = false;
    grantOnRequest = true;
    requested = [];
    storageCalls = [];
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      storageCalls.add(call.method);
      if (call.method == 'openStorageSettings') return null;
      return {
        'sdkInt': sdkInt,
        'hasFullAccess': fullAccess,
        'roots': ['/storage/emulated/10', '/storage/ABCD-1234'],
      };
    });
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      expect(call.method, 'requestPermissions');
      final permissions = List<int>.from(call.arguments as List);
      requested.addAll(permissions);
      fullAccess = grantOnRequest;
      // Even a reported granted status cannot replace the native access check.
      return {for (final permission in permissions) permission: 1};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(permissionChannel, null);
  });

  test('volume paths do not imply full access under scoped storage', () async {
    final storage = await AndroidStorageService.read();
    expect(storage.hasFullAccess, isFalse);
    expect(storage.roots, ['/storage/emulated/10', '/storage/ABCD-1234']);
  });

  for (final sdk in [30, 32, 33, 36]) {
    test(
      'Android API $sdk requests All files access without legacy storage',
      () async {
        sdkInt = sdk;
        final storage = await AndroidStorageService.requestAccess();
        expect(requested, [Permission.manageExternalStorage.value]);
        expect(storage.hasFullAccess, isTrue);
        expect(storageCalls, ['getStorageInfo', 'getStorageInfo']);
      },
    );
  }

  for (final sdk in [28, 29]) {
    test('Android API $sdk requests the legacy storage permission', () async {
      sdkInt = sdk;
      final storage = await AndroidStorageService.requestAccess();
      expect(requested, [Permission.storage.value]);
      expect(storage.hasFullAccess, isTrue);
    });
  }

  test('keeps access limited if the native grant is still missing', () async {
    grantOnRequest = false;
    final storage = await AndroidStorageService.requestAccess();
    expect(storage.hasFullAccess, isFalse);
    expect(requested, [Permission.manageExternalStorage.value]);
  });

  test('does not request access again when already granted', () async {
    fullAccess = true;
    expect((await AndroidStorageService.requestAccess()).hasFullAccess, isTrue);
    expect(requested, isEmpty);
  });

  test('opens the native storage settings route', () async {
    await AndroidStorageService.openSettings();
    expect(storageCalls, ['openStorageSettings']);
  });

  test('reports missing native storage information as a failure', () async {
    messenger.setMockMethodCallHandler(storageChannel, (_) async => null);
    await expectLater(AndroidStorageService.read(), throwsStateError);
  });
}
