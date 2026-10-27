import 'dart:async';

import '../models/doc_kind.dart';
import 'analytics_service.dart';

/// Completed document operations that count toward fullscreen ads.
/// Sharing and saving a preview are intentionally absent.
enum PdfOperation {
  merge,
  split,
  create,
  organize,
  protect,
  unlock,
  metadata,
  ocr,
  compress,
  images,
  view,
}

/// Counts successful actions independently of which result button is used.
class OperationAdPolicy {
  OperationAdPolicy({required this.showInterstitial});

  final Future<void> Function(PdfOperation operation) showInterstitial;
  int _completedOperations = 0;
  int get completedOperations => _completedOperations;
  Future<void>? _presenting;

  Future<void> completed(
    PdfOperation operation, {
    bool allowPresentation = true,
  }) async {
    _completedOperations++;
    if (operation != PdfOperation.view) {
      unawaited(
        AnalyticsService.instance.logDocAction(
          action: operation.name,
          kind: DocKind.pdf,
        ),
      );
    }
    if (_completedOperations % 3 != 0 || !allowPresentation) return;

    // A second completion must never stack fullscreen presentations.
    final presenting = _presenting;
    if (presenting != null) {
      await presenting;
      return;
    }
    final presentation = showInterstitial(operation);
    _presenting = presentation;
    try {
      await presentation;
    } finally {
      _presenting = null;
    }
  }
}
