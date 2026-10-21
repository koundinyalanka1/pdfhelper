import 'package:flutter/material.dart';

import '../models/doc_kind.dart';
import '../utils/error_logger.dart';
import 'draft_service.dart';

export 'draft_service.dart' show DraftRecovery;

/// Recovery copies for an editor screen: written a few seconds after each
/// change and when the app is hidden, offered back when the document opens
/// again, and cleared by Save or Discard. Drafting never stops editing: a
/// failure is logged and the editor carries on without a recovery copy.
class EditorDraft {
  EditorDraft._(this._controller);

  /// No recovery copies (new documents, or drafting failed to start).
  static EditorDraft get none => EditorDraft._(null);

  /// Tests point this at their own folder.
  static DraftService? serviceOverride;
  static DraftService get service => serviceOverride ?? DraftService.instance;

  DraftController? _controller;

  /// The newest recovery copy's file, or null.
  String? get latestPath => _controller?.latestDraft?.snapshotPath;

  /// The recovery copy left for [path], or null (also when the recovery
  /// folder cannot be read).
  static Future<DraftRecovery?> find(String path, DocKind kind) async {
    try {
      return await service.findRecovery(sourcePath: path, kind: kind);
    } catch (e, stack) {
      logError('EditorDraft.find', e, stack);
      return null;
    }
  }

  /// Ask whether to restore [found]; true to restore, false to discard it.
  static Future<bool> askRestore(
    BuildContext context,
    DraftRecovery found,
    String name,
  ) async {
    final when = found.draft.updatedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${two(when.hour)}:${two(when.minute)} on '
        '${when.day}/${when.month}/${when.year}';
    final changed = switch (found.sourceState) {
      DraftSourceState.unchanged => '',
      DraftSourceState.missing =>
        '\n\nThe file itself is no longer there; saving writes it again.',
      _ =>
        '\n\nThe file has changed since then. Restoring and saving replaces '
            'those changes.',
    };
    final restore = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore unsaved changes?'),
        content: Text(
          'DocHelper kept changes to $name that were not saved '
          '(last at $stamp).$changed',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    return restore ?? false;
  }

  /// Start keeping recovery copies of [path], written by [writer]. A copy
  /// [found] earlier is carried on when [restored], otherwise removed.
  /// [format] is the snapshot's extension (what [writer] writes). Returns
  /// at once; changes, saves and discards made while the recovery folder
  /// is being prepared wait for it.
  static EditorDraft start({
    required String path,
    required DocKind kind,
    required String format,
    required DraftWriter writer,
    DraftRecovery? found,
    bool restored = false,
  }) {
    final draft = EditorDraft._(null);
    draft._ready = () async {
      try {
        if (found != null && !restored) {
          await service.discardRecovery(found.draft);
        }
        final session = await service.openSession(
          DraftDocument(sourcePath: path, kind: kind, format: format),
          restoredDraft: restored ? found?.draft : null,
        );
        final controller = DraftController(
          service: service,
          session: session,
          writeSnapshot: writer,
          onError: (e, stack) => logError('EditorDraft', e, stack),
        );
        if (draft._closed) {
          controller.dispose();
          return null;
        }
        draft._controller = controller;
        if (draft._changedEarly) controller.markChanged();
        return controller;
      } catch (e, stack) {
        logError('EditorDraft.start', e, stack);
        return null;
      }
    }();
    return draft;
  }

  /// Set while the recovery folder is being prepared.
  Future<DraftController?>? _ready;
  bool _changedEarly = false;
  bool _closed = false;

  Future<DraftController?> _controllerWhenReady() async =>
      _ready == null ? _controller : await _ready;

  /// The document changed: write a recovery copy once editing pauses.
  void changed() {
    final controller = _controller;
    if (controller == null) {
      _changedEarly = true;
    } else {
      controller.markChanged();
    }
  }

  /// Run the user's save; the recovery copy is cleared only when [run]
  /// reports success.
  Future<bool> save(Future<bool> Function() run) async {
    final controller = await _controllerWhenReady();
    if (controller == null || _closed) return run();
    var ok = false;
    try {
      await controller.runUserSave(() async {
        ok = await run();
        if (!ok) throw const _NotSaved();
      });
    } on _NotSaved {
      return false;
    } catch (e, stack) {
      // The document was saved; only clearing its recovery copy failed.
      logError('EditorDraft.save', e, stack);
    }
    return ok;
  }

  /// The user discarded their changes: drop the recovery copy.
  Future<void> discard() async {
    try {
      final controller = await _controllerWhenReady();
      if (!_closed) await controller?.runUserDiscard();
    } catch (e, stack) {
      logError('EditorDraft.discard', e, stack);
    }
  }

  /// The screen is closing (after Save or Discard, or with nothing to
  /// keep): stop. The document is closed right after, so nothing more is
  /// written; the last recovery copy stays until Save or Discard.
  void close() {
    _closed = true;
    _controller?.dispose();
  }
}

class _NotSaved implements Exception {
  const _NotSaved();
}
