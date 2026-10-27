import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart';
import '../models/doc_kind.dart';
import 'firebase_service.dart';

/// Privacy-respecting analytics for DocHelper.
///
/// Tracks document usage by kind and extension, and high-level actions taken,
/// without ever collecting file names, paths, content, or personal data.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  FirebaseAnalytics? get _analytics {
    if (!FirebaseService.isInitialized) return null;
    try {
      return FirebaseAnalytics.instance;
    } catch (_) {
      return null;
    }
  }

  /// Optional navigator observer for automatic route tracking.
  NavigatorObserver? get observer {
    final analytics = _analytics;
    if (analytics == null) return null;
    return FirebaseAnalyticsObserver(analytics: analytics);
  }

  /// Log when a user opens a document.
  ///
  /// Strictly records only the kind (e.g. 'pdf', 'word', 'sheet') and
  /// extension (e.g. 'pdf', 'docx', 'xlsx'). Never logs file names or paths.
  Future<void> logDocOpened({
    required DocKind kind,
    required String extension,
  }) async {
    final analytics = _analytics;
    if (analytics == null) return;
    try {
      final ext = extension.replaceAll('.', '').trim().toLowerCase();
      await analytics.logEvent(
        name: 'doc_opened',
        parameters: {
          'doc_kind': kind.name,
          'doc_extension': ext.isEmpty ? 'unknown' : ext,
        },
      );
    } catch (_) {
      // Analytics must never disrupt app execution.
    }
  }

  /// Log an action performed on a document (e.g., merge, split, compress, save).
  Future<void> logDocAction({
    required String action,
    DocKind? kind,
    Map<String, Object>? parameters,
  }) async {
    final analytics = _analytics;
    if (analytics == null) return;
    try {
      final params = <String, Object>{
        'action': action,
        if (kind != null) 'doc_kind': kind.name,
        ...?parameters,
      };
      await analytics.logEvent(
        name: 'doc_action',
        parameters: params,
      );
    } catch (_) {
      // Analytics must never disrupt app execution.
    }
  }

  /// Log screen transition or view.
  Future<void> logScreenView({required String screenName}) async {
    final analytics = _analytics;
    if (analytics == null) return;
    try {
      await analytics.logScreenView(screenName: screenName);
    } catch (_) {
      // Analytics must never disrupt app execution.
    }
  }
}
