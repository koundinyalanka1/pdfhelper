import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android's storage grant and volume paths, obtained from the OS rather than
/// guessed from /sdcard listings (which can succeed under scoped storage).
class AndroidStorageInfo {
  const AndroidStorageInfo({
    required this.sdkInt,
    required this.hasFullAccess,
    required this.roots,
  });

  final int sdkInt;
  final bool hasFullAccess;
  final List<String> roots;
}

class AndroidStorageService {
  AndroidStorageService._();

  static const _channel = MethodChannel('com.yourmateapps.pdfhelper/storage');

  static Future<AndroidStorageInfo> read() async {
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'getStorageInfo',
    );
    if (data == null) {
      throw StateError('Android storage information unavailable');
    }
    return AndroidStorageInfo(
      sdkInt: data['sdkInt'] as int,
      hasFullAccess: data['hasFullAccess'] == true,
      roots: List<String>.from(data['roots'] as List),
    );
  }

  static Future<AndroidStorageInfo> requestAccess() async {
    final before = await read();
    if (before.hasFullAccess) return before;
    // READ_EXTERNAL_STORAGE does not grant access to other apps' PDFs under
    // scoped storage. Request only the permission appropriate for this OS.
    if (before.sdkInt >= 30) {
      await Permission.manageExternalStorage.request();
    } else {
      await Permission.storage.request();
    }
    return read();
  }

  static Future<void> openSettings() =>
      _channel.invokeMethod<void>('openStorageSettings');
}
