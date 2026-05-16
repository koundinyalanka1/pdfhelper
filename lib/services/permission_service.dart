import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles permission requests with rationale dialogs and settings guidance.
class PermissionService {
  /// Request permission with optional rationale and settings guidance.
  /// Returns true if granted.
  static Future<bool> requestWithRationale({
    required BuildContext context,
    required Permission permission,
    required String rationaleTitle,
    required String rationaleMessage,
    required String deniedTitle,
    required String deniedMessage,
    required String settingsButtonText,
    required String cancelButtonText,
  }) async {
    var status = await permission.status;

    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      if (!context.mounted) return false;
      return await _showSettingsDialog(
        context: context,
        permission: permission,
        title: deniedTitle,
        message: deniedMessage,
        settingsButtonText: settingsButtonText,
        cancelButtonText: cancelButtonText,
      );
    }

    // Show rationale if previously denied (Android) or first time
    final shouldShow = await permission.shouldShowRequestRationale;
    if (shouldShow && context.mounted) {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(rationaleTitle),
          content: Text(rationaleMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelButtonText),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return false;
    }

    status = await permission.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied && context.mounted) {
      return await _showSettingsDialog(
        context: context,
        permission: permission,
        title: deniedTitle,
        message: deniedMessage,
        settingsButtonText: settingsButtonText,
        cancelButtonText: cancelButtonText,
      );
    }
    return false;
  }

  static Future<bool> _showSettingsDialog({
    required BuildContext context,
    required Permission permission,
    required String title,
    required String message,
    required String settingsButtonText,
    required String cancelButtonText,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelButtonText),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(settingsButtonText),
          ),
        ],
      ),
    );
    if (result != true) return false;

    // Open the OS app-info screen, then wait for the app to resume so we can
    // re-check the permission. permission_handler's openAppSettings() returns
    // as soon as the settings UI is launched, NOT when the user comes back —
    // so we register a one-shot lifecycle observer.
    await openAppSettings();
    await _waitForAppResume();
    return await permission.isGranted;
  }

  /// Resolves the next time the app transitions back to [AppLifecycleState.resumed].
  /// Caps at 60s so a misbehaving platform never deadlocks the future.
  static Future<void> _waitForAppResume() {
    final completer = Completer<void>();
    late final _ResumeObserver observer;
    observer = _ResumeObserver(() {
      if (!completer.isCompleted) completer.complete();
      WidgetsBinding.instance.removeObserver(observer);
    });
    WidgetsBinding.instance.addObserver(observer);
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        WidgetsBinding.instance.removeObserver(observer);
      },
    );
  }

  /// Check if permission is permanently denied (user must open settings).
  static Future<bool> isPermanentlyDenied(Permission permission) async {
    final status = await permission.status;
    return status.isPermanentlyDenied;
  }

  /// Check if permission is granted.
  static Future<bool> isGranted(Permission permission) async {
    final status = await permission.status;
    return status.isGranted;
  }
}

class _ResumeObserver extends WidgetsBindingObserver {
  _ResumeObserver(this._onResumed);
  final VoidCallback _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
