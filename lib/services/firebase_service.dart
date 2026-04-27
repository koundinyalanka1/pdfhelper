import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Initializes Firebase + Crashlytics defensively.
///
/// If `google-services.json` (Android) or `GoogleService-Info.plist` (iOS)
/// are missing or misconfigured, initialization fails silently so the app
/// still runs. Crashlytics is only wired up after a successful init.
class FirebaseService {
  FirebaseService._();

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  /// Call once during app startup. Safe to call multiple times — it's a no-op
  /// after the first success.
  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      await Firebase.initializeApp();
      _initialized = true;
      _wireCrashlytics();
      debugPrint('[FirebaseService] initialized');
    } catch (e, st) {
      // Most likely cause: missing google-services.json / GoogleService-Info.plist.
      // Don't block app startup.
      debugPrint('[FirebaseService] initialization failed: $e');
      debugPrintStack(stackTrace: st, label: 'FirebaseService');
    }
  }

  static void _wireCrashlytics() {
    // In debug builds we don't want noisy Crashlytics reports while iterating.
    final collectionEnabled = !kDebugMode;
    FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
      collectionEnabled,
    );

    // Capture all uncaught Flutter framework errors.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };

    // Capture errors that escape the Flutter framework (async / isolate).
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  /// Records a non-fatal exception. No-op if Firebase isn't initialized.
  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
  }) async {
    if (!_initialized) return;
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        reason: reason,
        fatal: false,
      );
    } catch (_) {
      // Swallow — never let logging crash the app.
    }
  }
}
