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
            onPressed: () {
              Navigator.pop(ctx, true);
              openAppSettings();
            },
            child: Text(settingsButtonText),
          ),
        ],
      ),
    );
    if (result != true) return false;
    // User tapped Settings - wait for return and recheck
    await Future.delayed(const Duration(milliseconds: 500));
    return false; // Caller should re-check permission after settings
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
