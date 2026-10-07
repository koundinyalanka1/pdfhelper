import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import '../utils/error_logger.dart';

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
    if (_initialized || !kReleaseMode) return;
    try {
      await Firebase.initializeApp();
      await _wireCrashlytics();
      _initialized = true;
      debugPrint('[FirebaseService] initialized');
    } catch (e, st) {
      // Most likely cause: missing google-services.json / GoogleService-Info.plist.
      // Don't block app startup.
      debugPrint('[FirebaseService] initialization failed: $e');
      debugPrintStack(stackTrace: st, label: 'FirebaseService');
    }
  }

  static Future<void> _wireCrashlytics() async {
    // In debug builds we don't want noisy Crashlytics reports while iterating.
    final collectionEnabled = !kDebugMode;
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
      collectionEnabled,
    );

    // Uncaught framework and async errors are reported as non-fatal: the app
    // keeps running after both (a failed build shows an error box, and
    // returning true below marks the error handled). Counting them as
    // crashes made the crash-free rate say the app crashed when it had not.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(
        FirebaseCrashlytics.instance
            .recordFlutterError(details)
            .catchError((Object _) {}),
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        FirebaseCrashlytics.instance
            .recordError(error, stack, fatal: false)
            .catchError((Object _) {}),
      );
      return true;
    };

    // Errors the app catches and logs (see logError) arrive as non-fatal
    // events naming only where they happened and their kind.
    handledErrorReporter = (error, stack) =>
        unawaited(recordError(error, stack));
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
