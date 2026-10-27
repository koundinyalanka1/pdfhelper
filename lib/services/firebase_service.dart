import 'dart:async';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/error_logger.dart';

/// Android stopped the app for memory (or excessive resource use) while it
/// was not looking: no crash report exists for it, so it is recorded as a
/// non-fatal event on the next start.
class MemoryExit implements Exception {
  const MemoryExit(this.reason, {required this.foreground, this.pssKb});

  /// `low_memory` or `excessive_resource_usage`.
  final String reason;
  final bool foreground;
  final int? pssKb;

  /// The event a platform exit record describes, or null for one that is
  /// not about memory.
  static MemoryExit? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final reason = raw['reason'];
    if (reason is! String || reason.isEmpty) return null;
    final pss = raw['pssKb'];
    return MemoryExit(
      reason,
      foreground: raw['foreground'] == true,
      pssKb: pss is int && pss > 0 ? pss : null,
    );
  }

  @override
  String toString() =>
      'MemoryExit($reason, ${foreground ? 'foreground' : 'background'}'
      '${pssKb == null ? '' : ', ${pssKb! ~/ 1024} MB'})';
}

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
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
      _initialized = true;
      debugPrint('[FirebaseService] initialized');
      unawaited(_reportMemoryExits());
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

  static const _diagnostics = MethodChannel(
    'com.yourmateapps.pdfhelper/diagnostics',
  );

  /// Times Android stopped the app for memory since the last start
  /// (Android 11 and later), each as a non-fatal event.
  static Future<void> _reportMemoryExits() async {
    if (!Platform.isAndroid) return;
    try {
      final exits = await _diagnostics.invokeListMethod<Object?>('recentExits');
      for (final exit in exits ?? const <Object?>[]) {
        final event = MemoryExit.fromMap(exit);
        if (event == null) continue;
        await FirebaseCrashlytics.instance.recordError(
          event,
          StackTrace.empty,
          reason: 'the app was stopped by Android for memory',
          fatal: false,
        );
      }
    } catch (_) {
      // Diagnostics never get in the way of starting the app.
    }
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
