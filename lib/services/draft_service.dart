import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../models/doc_kind.dart';

typedef DraftWriter = Future<void> Function(String snapshotPath);
typedef DraftPayloadReader = FutureOr<Object?> Function();
typedef DraftErrorHandler = void Function(Object error, StackTrace stack);
typedef DraftTimerFactory = Timer Function(Duration delay, void Function() run);

enum DraftSourceState { unchanged, changed, missing, unavailable }

class DraftException implements Exception {
  const DraftException(this.code, this.message, [this.cause]);

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'DraftException($code): $message';
}

class DraftIssue {
  const DraftIssue(this.code, this.message, {this.storageKey, this.generation});

  final String code;
  final String message;
  final String? storageKey;
  final String? generation;
}

class DraftLimits {
  const DraftLimits({
    this.maxSnapshotBytes = 256 * 1024 * 1024,
    this.maxTotalBytes = 500 * 1024 * 1024,
    this.maxSourceBytes = 1024 * 1024 * 1024,
    this.maxPayloadBytes = 16 * 1024 * 1024,
    this.maxDocuments = 50,
    this.keptGenerations = 2,
    this.orphanRetention = const Duration(days: 1),
    this.retention = const Duration(days: 30),
    this.maxEntries = 16384,
  });

  final int maxSnapshotBytes;
  final int maxTotalBytes;
  final int maxSourceBytes;
  final int maxPayloadBytes;
  final int maxDocuments;
  final int keptGenerations;
  final Duration orphanRetention;
  final Duration retention;
  final int maxEntries;

  void _validate() {
    if (maxSnapshotBytes < 1 ||
        maxTotalBytes < 1 ||
        maxSourceBytes < 1 ||
        maxPayloadBytes < 1 ||
        maxDocuments < 1 ||
        keptGenerations < 1 ||
        maxEntries < 1 ||
        orphanRetention.isNegative ||
        retention.isNegative) {
      throw ArgumentError('Draft limits must be positive.');
    }
  }
}

class DraftDocument {
  DraftDocument({
    required String sourcePath,
    required this.kind,
    required this.format,
    String? sourceName,
    this.payloadVersion = 1,
  }) : sourcePath = _sourcePath(sourcePath),
       sourceName = sourceName ?? _basename(sourcePath) {
    _validateDocument(this);
  }

  final String sourcePath;
  final String sourceName;
  final DocKind kind;
  final String format;
  final int payloadVersion;

  String get snapshotExtension => kind == DocKind.pdf ? 'json' : format;
}

class DraftFingerprint {
  const DraftFingerprint._({
    required this.exists,
    required this.size,
    required this.modifiedMicros,
    required this.sha256,
  });

  final bool exists;
  final int size;
  final int modifiedMicros;
  final String sha256;

  bool matches(DraftFingerprint other) =>
      exists == other.exists &&
      size == other.size &&
      modifiedMicros == other.modifiedMicros &&
      sha256 == other.sha256;

  Map<String, Object> _toJson() => {
    'exists': exists,
    'size': size,
    'modifiedMicros': modifiedMicros,
    'sha256': sha256,
  };
}

class DraftRecord {
  const DraftRecord._({
    required this.document,
    required this.storageKey,
    required this.generation,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    required this.sourceFingerprint,
    required this.snapshotFingerprint,
    required this.snapshotPath,
    required this.metadataPath,
    required String observedHead,
    this.issues = const [],
  }) : _observedHead = observedHead;

  final DraftDocument document;
  final String storageKey;
  final String generation;
  final int sequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DraftFingerprint sourceFingerprint;
  final DraftFingerprint snapshotFingerprint;
  final String snapshotPath;
  final String metadataPath;
  final List<DraftIssue> issues;
  final String _observedHead;

  int get sizeBytes => snapshotFingerprint.size;
  int get version => DraftService.metadataVersion;

  DraftRecord _withIssues(List<DraftIssue> issues, {String? observedHead}) =>
      DraftRecord._(
        document: document,
        storageKey: storageKey,
        generation: generation,
        sequence: sequence,
        createdAt: createdAt,
        updatedAt: updatedAt,
        sourceFingerprint: sourceFingerprint,
        snapshotFingerprint: snapshotFingerprint,
        snapshotPath: snapshotPath,
        metadataPath: metadataPath,
        observedHead: observedHead ?? _observedHead,
        issues: List.unmodifiable(issues),
      );
}

class DraftRecovery {
  const DraftRecovery({required this.draft, required this.sourceState});

  final DraftRecord draft;
  final DraftSourceState sourceState;

  bool get hasConflict => sourceState != DraftSourceState.unchanged;
}

class DraftInventory {
  const DraftInventory({required this.drafts, required this.issues});

  final List<DraftRecord> drafts;
  final List<DraftIssue> issues;
}

class DraftCleanupReport {
  const DraftCleanupReport({
    required this.removedGenerations,
    required this.retainedBytes,
    required this.oldDrafts,
    required this.overBudget,
    required this.issues,
  });

  final int removedGenerations;
  final int? retainedBytes;
  final int oldDrafts;
  final bool overBudget;
  final List<DraftIssue> issues;
}

class DraftSession {
  DraftSession._(
    this._owner,
    this.document,
    this._fingerprint,
    this._head,
    this._latest,
  );

  final DraftService _owner;
  final DraftDocument document;
  DraftFingerprint _fingerprint;
  String? _head;
  DraftRecord? _latest;
  bool _closed = false;
  int _epoch = 0;

  DraftFingerprint get sourceFingerprint => _fingerprint;
  DraftRecord? get latestDraft => _latest;
  bool get isClosed => _closed;

  void close() {
    _closed = true;
    _epoch++;
  }
}

class DraftService {
  DraftService({
    Directory? directory,
    Future<Directory> Function()? directoryProvider,
    DateTime Function()? clock,
    this.limits = const DraftLimits(),
  }) : _directoryProvider = directoryProvider ??
           (directory == null ? _defaultDirectory : () async => directory),
       _clock = clock ?? DateTime.now {
    if (directory != null && directoryProvider != null) {
      throw ArgumentError('Supply a directory or a directory provider, not both.');
    }
    limits._validate();
  }

  static const metadataVersion = 1;
  static final DraftService instance = DraftService();
  static final Map<String, _SerialQueue> _queues = {};

  final DraftLimits limits;
  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _clock;
  Future<String>? _rootFuture;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/Drafts');

  Future<String> _root() async {
    try {
      return await (_rootFuture ??= _resolveRoot());
    } catch (_) {
      _rootFuture = null;
      rethrow;
    }
  }

  Future<String> _resolveRoot() async {
    final directory = await _directoryProvider();
    final path = directory.absolute.path;
    return _prepareRootOffThread(path);
  }

  Future<T> _locked<T>(Future<T> Function(String root) work) async {
    try {
      final root = await _root();
      return await _queues.putIfAbsent(_pathIdentity(root), _SerialQueue.new)
          .run(() => work(root));
    } on FileSystemException catch (error) {
      throw DraftException('io', 'Recovery storage could not be accessed.', error);
    }
  }

  Future<DraftSession> openSession(
    DraftDocument document, {
    DraftRecord? restoredDraft,
  }) => _locked((root) async {
    final result = await _openSessionOffThread(root, document, restoredDraft, limits);
    return DraftSession._(
      this,
      document,
      result.fingerprint,
      result.head.token,
      result.head.draft,
    );
  });

  Future<DraftRecovery?> findRecovery({
    required String sourcePath,
    required DocKind kind,
  }) => _locked((root) {
    final path = _sourcePath(sourcePath);
    _checkKind(kind);
    return _findRecoveryOffThread(root, path, kind, limits);
  });

  Future<DraftInventory> listDrafts() =>
      _locked((root) => _listDraftsOffThread(root, limits));

  Future<DraftRecord> writeSnapshot(DraftSession session, DraftWriter writer) {
    _checkSession(session);
    if (session.document.kind == DocKind.pdf) {
      throw const DraftException(
        'unsafePayload',
        'PDF pending edits must use the password-free JSON payload API.',
      );
    }
    return _write(session, writer);
  }

  Future<DraftRecord> writePayload(DraftSession session, Object? payload) async {
    _checkSession(session);
    if (session.document.kind != DocKind.pdf) {
      throw const DraftException('invalidFormat', 'JSON payloads are for PDF edits.');
    }
    final epoch = session._epoch;
    final maxBytes = min(limits.maxPayloadBytes, limits.maxSnapshotBytes);
    final bytes = await _encodePayloadOffThread(payload, maxBytes);
    return _write(session, (path) => _writeBytesOffThread(path, bytes), epoch: epoch);
  }

  Future<Object?> readPayload(DraftRecord draft, {int expectedVersion = 1}) => _locked((root) async {
    if (draft.document.payloadVersion != expectedVersion) {
      throw const DraftException('unsupportedVersion', 'The PDF edit payload version is not supported.');
    }
    if (draft.document.kind != DocKind.pdf) {
      throw const DraftException('invalidFormat', 'This draft is not PDF edit data.');
    }
    return _readPayloadOffThread(root, draft, limits);
  });

  Future<DraftRecord> _write(DraftSession session, DraftWriter writer, {int? epoch}) {
    final requestedEpoch = epoch ?? session._epoch;
    return _locked((root) async {
        _checkSession(session);
        _checkEpoch(session, requestedEpoch);
        final document = session.document;
        final fingerprint = session._fingerprint;
        final expectedHead = session._head;
        final now = _clock().toUtc();
        final limits = this.limits;
        final intent = await _prepareIntentOffThread(
          root, document, fingerprint, expectedHead, now, limits,
          cleared: false, refreshSource: false,
        );
        var committed = false;
        try {
          await writer(intent.snapshotPath);
          _checkSession(session);
          _checkEpoch(session, requestedEpoch);
          final draft = await _commitSnapshotOffThread(intent, limits);
          committed = true;
          session._head = draft.generation;
          session._latest = draft;
          final report = await _maintain(root, now);
          final result = draft._withIssues(report.issues);
          session._latest = result;
          return result;
        } catch (error, stack) {
          if (!committed && !await _abandonOffThread(intent)) {
            Error.throwWithStackTrace(DraftException(
              'writeCleanupFailed',
              'The draft was not committed. Its incomplete files could not be removed; earlier drafts were kept.',
              error,
            ), stack);
          }
          rethrow;
        }
      });
  }

  Future<DraftCleanupReport> discard(DraftSession session) =>
      _clear(session, refreshSource: false);

  Future<DraftCleanupReport> acknowledgeSave(DraftSession session) =>
      _clear(session, refreshSource: true);

  Future<DraftCleanupReport> discardRecovery(DraftRecord draft) async {
    final session = await openSession(draft.document, restoredDraft: draft);
    try {
      return await discard(session);
    } finally {
      session.close();
    }
  }

  Future<void> refreshSource(DraftSession session) => _locked((root) async {
    _checkSession(session);
    final document = session.document;
    final limits = this.limits;
    final expectedHead = session._head;
    final fingerprint = await _refreshSourceOffThread(root, document, limits, expectedHead);
    session._fingerprint = fingerprint;
  });

  Future<DraftCleanupReport> _clear(
    DraftSession session, {
    required bool refreshSource,
  }) {
    _checkSession(session);
    session._epoch++;
    return _locked((root) async {
    _checkSession(session);
    final document = session.document;
    final limits = this.limits;
    final expectedHead = session._head;
    final oldFingerprint = session._fingerprint;
    final now = _clock().toUtc();
    final intent = await _prepareIntentOffThread(
      root, document, oldFingerprint, expectedHead, now, limits,
      cleared: true, refreshSource: refreshSource,
    );
    try {
      await _commitClearOffThread(intent, limits);
    } catch (error, stack) {
      if (!await _abandonOffThread(intent)) {
        Error.throwWithStackTrace(DraftException(
          'clearCleanupFailed',
          'The recovery draft could not be cleared. Existing recovery files were kept.',
          error,
        ), stack);
      }
      rethrow;
    }
    session._head = intent.generation;
    session._fingerprint = intent.sourceFingerprint;
    session._latest = null;
    return _maintain(root, now);
  });
  }

  Future<DraftCleanupReport> cleanup() =>
      _locked((root) => _maintain(root, _clock().toUtc()));

  Future<DraftCleanupReport> _maintain(String root, DateTime now) async {
    final limits = this.limits;
    try {
      return await _cleanupOffThread(root, now, limits);
    } catch (error) {
      return DraftCleanupReport(
        removedGenerations: 0,
        retainedBytes: null,
        oldDrafts: 0,
        overBudget: true,
        issues: const [DraftIssue(
          'cleanupFailed',
          'The recovery copy is committed, but old recovery files could not be cleaned.',
        )],
      );
    }
  }

  void _checkSession(DraftSession session) {
    if (!identical(session._owner, this) || session._closed) {
      throw const DraftException('closedSession', 'This draft session is closed.');
    }
  }

  void _checkEpoch(DraftSession session, int epoch) {
    if (session._epoch != epoch) {
      throw const DraftException('cancelled', 'This snapshot was superseded by Save or Discard.');
    }
  }
}

class DraftController extends ChangeNotifier with WidgetsBindingObserver {
  DraftController({
    required this.service,
    required this.session,
    this.writeSnapshot,
    this.readPayload,
    this.onError,
    this.debounceDelay = const Duration(seconds: 3),
    this.retryDelay = const Duration(seconds: 30),
    this.maxAutomaticRetries = 3,
    bool observeLifecycle = true,
    DraftTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new,
       _observesLifecycle = observeLifecycle {
    if ((writeSnapshot == null) == (readPayload == null) ||
        (session.document.kind == DocKind.pdf) != (readPayload != null)) {
      throw ArgumentError('Supply writeSnapshot, or readPayload for PDF edits.');
    }
    if (debounceDelay.isNegative || retryDelay.isNegative || maxAutomaticRetries < 0) {
      throw ArgumentError('Draft delays and retry count cannot be negative.');
    }
    service._checkSession(session);
    if (session.latestDraft != null) {
      _revision = 1;
      _draftedRevision = 1;
    }
    if (_observesLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  final DraftService service;
  final DraftSession session;
  final DraftWriter? writeSnapshot;
  final DraftPayloadReader? readPayload;
  final DraftErrorHandler? onError;
  final Duration debounceDelay;
  final Duration retryDelay;
  final int maxAutomaticRetries;
  final DraftTimerFactory _timerFactory;
  final bool _observesLifecycle;
  final _SerialQueue _queue = _SerialQueue();
  Timer? _timer;
  int _timerEpoch = 0;
  int _operationEpoch = 0;
  int _revision = 0;
  int _savedRevision = 0;
  int _draftedRevision = 0;
  int _suspended = 0;
  int _retries = 0;
  bool _writing = false;
  bool _disposed = false;
  Object? _lastError;

  bool get hasPendingChanges => _revision > _savedRevision;
  bool get needsSnapshot => _revision > _draftedRevision && hasPendingChanges;
  bool get isWriting => _writing;
  bool get isSaving => _suspended > 0;
  Object? get lastError => _lastError;
  DraftRecord? get latestDraft => session.latestDraft;
  Future<void> get settled => _queue.settled;

  void markChanged() {
    if (_disposed) return;
    _revision++;
    _retries = 0;
    if (_suspended == 0) _schedule(debounceDelay);
    _notify();
  }

  Future<DraftRecord?> flush() {
    _cancelTimer();
    final epoch = _operationEpoch;
    return _queue.run(() async {
      if (_disposed || _suspended > 0 || epoch != _operationEpoch || !needsSnapshot) {
        return latestDraft;
      }
      final revision = _revision;
      _writing = true;
      _notify();
      try {
        final reader = readPayload;
        final draft = reader == null
            ? await service.writeSnapshot(session, writeSnapshot!)
            : await service.writePayload(session, await reader());
        _draftedRevision = revision;
        _lastError = null;
        _retries = 0;
        if (draft.issues.isNotEmpty) {
          _report(const DraftException(
            'maintenance',
            'The draft was saved, but recovery storage needs attention.',
          ), StackTrace.current);
        }
        return draft;
      } catch (error, stack) {
        _report(error, stack);
        if (!_disposed && _suspended == 0 && _retries < maxAutomaticRetries) {
          _retries++;
          _schedule(retryDelay);
        }
        rethrow;
      } finally {
        _writing = false;
        if (!_disposed && _suspended == 0 && needsSnapshot && _timer == null &&
            _lastError == null) {
          _schedule(debounceDelay);
        }
        _notify();
      }
    });
  }

  Future<T> runUserSave<T>(Future<T> Function() save) {
    if (_disposed) return Future.error(StateError('The draft controller is closed.'));
    _pause();
    return _queue.run(() async {
      final revision = _revision;
      var saved = false;
      try {
        final result = await save();
        saved = true;
        if (_revision == revision) {
          final report = await service.acknowledgeSave(session);
          _savedRevision = revision;
          _draftedRevision = revision;
          _lastError = null;
          _reportCleanup(report);
        } else {
          await service.refreshSource(session);
          _savedRevision = revision;
          _draftedRevision = min(_draftedRevision, revision);
          _lastError = null;
        }
        return result;
      } catch (error, stack) {
        final reported = saved
            ? DraftException(
                'saveCleanupFailed',
                'The document was saved, but its recovery draft could not be cleared.',
                error,
              )
            : error;
        _report(reported, stack);
        Error.throwWithStackTrace(reported, stack);
      } finally {
        _resume();
      }
    });
  }

  Future<void> runUserDiscard({Future<void> Function()? discardChanges}) {
    if (_disposed) return Future.error(StateError('The draft controller is closed.'));
    _pause();
    return _queue.run(() async {
      final revision = _revision;
      try {
        if (discardChanges != null) await discardChanges();
        if (_revision != revision) {
          throw const DraftException(
            'editsDuringDiscard',
            'New edits arrived during discard. Their recovery draft was kept.',
          );
        }
        final report = await service.discard(session);
        _savedRevision = revision;
        _draftedRevision = revision;
        _lastError = null;
        _reportCleanup(report);
      } catch (error, stack) {
        _report(error, stack);
        rethrow;
      } finally {
        _resume();
      }
    });
  }

  void _reportCleanup(DraftCleanupReport report) {
    if (report.issues.isNotEmpty) {
      _report(const DraftException(
        'cleanupFailed',
        'The recovery draft was cleared, but some old files could not be removed.',
      ), StackTrace.current);
    }
  }

  void _pause() {
    _suspended++;
    _operationEpoch++;
    _cancelTimer();
    _notify();
  }

  void _resume() {
    _suspended--;
    if (!_disposed && _suspended == 0 && needsSnapshot) _schedule(debounceDelay);
    _notify();
  }

  void _cancelTimer() {
    _timerEpoch++;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay) {
    _cancelTimer();
    final epoch = _timerEpoch;
    _timer = _timerFactory(delay, () {
      if (_disposed || epoch != _timerEpoch || _suspended > 0) return;
      _timer = null;
      _backgroundFlush();
    });
  }

  void _backgroundFlush() {
    unawaited(flush().then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_disposed && _suspended == 0 &&
        (state == AppLifecycleState.hidden || state == AppLifecycleState.paused)) {
      _backgroundFlush();
    }
  }

  void _report(Object error, StackTrace stack) {
    _lastError = error;
    if (!_disposed && onError != null) {
      try {
        onError!(error, stack);
      } catch (callbackError, callbackStack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: callbackError,
          stack: callbackStack,
          library: 'draft recovery',
        ));
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close({bool flushPending = true}) async {
    try {
      if (flushPending && !_disposed) await flush();
    } finally {
      dispose();
      await settled;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operationEpoch++;
    _cancelTimer();
    if (_observesLifecycle) WidgetsBinding.instance.removeObserver(this);
    unawaited(settled.then((_) => session.close()));
    super.dispose();
  }
}

class _SerialQueue {
  Future<void> _tail = Future.value();

  Future<void> get settled => _tail;

  Future<T> run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Future<String> _prepareRootOffThread(String path) =>
    Isolate.run(() => _prepareRoot(path));

Future<({DraftFingerprint fingerprint, _Head head})> _openSessionOffThread(
  String root,
  DraftDocument document,
  DraftRecord? restoredDraft,
  DraftLimits limits,
) => Isolate.run(() async {
  final key = _documentKey(document.sourcePath, document.kind);
  _ensureSourceOutsideStore(document.sourcePath, root);
  final store = await _scan(root, limits);
  final head = await _readHead(store.documents[key], limits);
  if (head.draft != null) {
    if (restoredDraft == null) {
      throw const DraftException(
        'recoveryRequired',
        'Recover or explicitly discard the existing draft before editing.',
      );
    }
    if (restoredDraft.storageKey != key ||
        restoredDraft._observedHead != head.token ||
        restoredDraft.generation != head.draft!.generation ||
        restoredDraft.document.format != document.format ||
        restoredDraft.document.payloadVersion != document.payloadVersion) {
      throw const DraftException(
        'staleSession',
        'The recovery draft changed. Check recovery again before editing.',
      );
    }
  } else if (restoredDraft != null || head.hasBrokenCommit) {
    throw const DraftException(
      'invalidMetadata',
      'Recovery data exists but cannot safely be opened or replaced.',
    );
  }
  final fingerprint = head.draft?.sourceFingerprint ??
      _fingerprint(document.sourcePath, limits.maxSourceBytes);
  return (head: head, fingerprint: fingerprint);
});

Future<DraftRecovery?> _findRecoveryOffThread(
  String root, String path, DocKind kind, DraftLimits limits,
) => Isolate.run(() async {
  _ensureSourceOutsideStore(path, root);
  final store = await _scan(root, limits);
  final head = await _readHead(store.documents[_documentKey(path, kind)], limits);
  final draft = head.draft;
  if (draft == null) {
    if (head.hasBrokenCommit) {
      throw const DraftException(
        'invalidMetadata',
        'A recovery draft is damaged. It has been kept, not overwritten.',
      );
    }
    return null;
  }
  return DraftRecovery(draft: draft, sourceState: _sourceState(draft, limits));
});

Future<DraftInventory> _listDraftsOffThread(String root, DraftLimits limits) =>
    Isolate.run(() async {
  final store = await _scan(root, limits);
  final drafts = <DraftRecord>[];
  final issues = <DraftIssue>[...store.issues];
  for (final document in store.documents.values) {
    final head = await _readHead(document, limits);
    if (head.draft case final draft?) drafts.add(draft);
    issues.addAll(head.issues);
  }
  drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return DraftInventory(drafts: List.unmodifiable(drafts), issues: List.unmodifiable(issues));
});

Future<Object?> _readPayloadOffThread(String root, DraftRecord draft, DraftLimits limits) =>
    Isolate.run(() {
  _verifyRecordLocation(root, draft);
  _verifySnapshot(draft, limits);
  final text = _readLimitedText(draft.snapshotPath, limits.maxPayloadBytes);
  _checkJsonDepth(text);
  final payload = jsonDecode(text);
  _validatePayload(payload, limits.maxPayloadBytes);
  return payload;
});

Future<_WriteIntent> _prepareIntentOffThread(
  String root, DraftDocument document, DraftFingerprint fingerprint,
  String? expectedHead, DateTime now, DraftLimits limits, {
  required bool cleared, required bool refreshSource,
}) => Isolate.run(() => _prepareIntent(
  root, document,
  refreshSource ? _fingerprint(document.sourcePath, limits.maxSourceBytes) : fingerprint,
  expectedHead, now, limits, cleared: cleared,
));

Future<DraftRecord> _commitSnapshotOffThread(_WriteIntent intent, DraftLimits limits) =>
    Isolate.run(() => _commitSnapshot(intent, limits));

Future<void> _commitClearOffThread(_WriteIntent intent, DraftLimits limits) =>
    Isolate.run(() => _commitClear(intent, limits));

Future<bool> _abandonOffThread(_WriteIntent intent) =>
    Isolate.run(() => _abandonIntent(intent));

Future<DraftFingerprint> _refreshSourceOffThread(
  String root, DraftDocument document, DraftLimits limits, String? expectedHead,
) => Isolate.run(() async {
  final store = await _scan(root, limits);
  _checkHead(store.documents[_documentKey(document.sourcePath, document.kind)], expectedHead);
  return _fingerprint(document.sourcePath, limits.maxSourceBytes);
});

Future<DraftCleanupReport> _cleanupOffThread(String root, DateTime now, DraftLimits limits) =>
    Isolate.run(() => _cleanup(root, now, limits));

const _metadataBytes = 64 * 1024;
const _maxSequence = 9999999999999999;
final _keyPattern = RegExp(r'^d-[0-9a-f]{64}$');
final _generationPattern = RegExp(r'^g-([0-9]{16})-[0-9a-f]{32}$');
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _controlPattern = RegExp(r'[\x00-\x1f\x7f]');

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

String _pathIdentity(String path) => Platform.isWindows ? path.toLowerCase() : path;

String _sourcePath(String path) {
  if (path.isEmpty || path.length > 32768 || _controlPattern.hasMatch(path) ||
      path.contains('://') || path.startsWith(r'\\.\') || path.startsWith(r'\\?\')) {
    throw const DraftException('unsafePath', 'A local document path is required.');
  }
  return File(path).absolute.uri.normalizePath().toFilePath();
}

bool _isAbsolute(String path) => Platform.isWindows
    ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
    : path.startsWith('/');

void _checkKind(DocKind kind) {
  if (!const {DocKind.word, DocKind.sheet, DocKind.slides, DocKind.text, DocKind.pdf}
      .contains(kind)) {
    throw const DraftException('invalidFormat', 'This document kind has no draft format.');
  }
}

void _validateDocument(DraftDocument document) {
  _checkKind(document.kind);
  if (document.sourceName.isEmpty || document.sourceName.length > 1024 ||
      document.sourceName == '.' || document.sourceName == '..' ||
      document.sourceName.contains('/') || document.sourceName.contains('\\') ||
      _controlPattern.hasMatch(document.sourceName) || document.payloadVersion < 1 ||
      document.payloadVersion > 1000000) {
    throw const DraftException('invalidMetadata', 'The draft description is invalid.');
  }
  final formats = switch (document.kind) {
    DocKind.word => const {'docx', 'docm', 'dotx', 'dotm', 'odt', 'ott'},
    DocKind.sheet => const {'xlsx', 'xlsm', 'xltx', 'xltm', 'ods', 'ots', 'csv', 'tsv'},
    DocKind.slides => const {'pptx', 'pptm', 'ppsx', 'ppsm', 'potx', 'potm', 'odp', 'otp'},
    DocKind.pdf => const {'pdf-edits'},
    DocKind.text => const {'txt'},
    _ => const <String>{},
  };
  if (!formats.contains(document.format)) {
    throw const DraftException('invalidFormat', 'The draft snapshot format is not supported.');
  }
}

String _documentKey(String path, DocKind kind) {
  final digest = _Sha256()..add(utf8.encode('${kind.name}\n${_pathIdentity(path)}'));
  return 'd-${digest.finish()}';
}

String _prepareRoot(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory) {
    throw const DraftException('unsafePath', 'Recovery storage must be a private directory.');
  }
  Directory(path).createSync(recursive: true);
  final root = Directory(path).resolveSymbolicLinksSync();
  _checkDirectory(root);
  return root;
}

void _checkDirectory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
    throw const DraftException('unsafePath', 'A recovery directory was replaced or moved.');
  }
  if (_pathIdentity(_sourcePath(Directory(path).resolveSymbolicLinksSync())) !=
      _pathIdentity(_sourcePath(path))) {
    throw const DraftException('unsafePath', 'Recovery directories cannot follow links.');
  }
}

void _ensureSourceOutsideStore(String source, String root) {
  final sourceKey = _pathIdentity(_sourcePath(source));
  final rootKey = _pathIdentity(_sourcePath(root));
  if (sourceKey == rootKey || sourceKey.startsWith('$rootKey${Platform.pathSeparator}')) {
    throw const DraftException('unsafePath', 'A recovery snapshot is not a source document.');
  }
}

void _verifyRecordLocation(String root, DraftRecord record) {
  if (!_keyPattern.hasMatch(record.storageKey) ||
      !_generationPattern.hasMatch(record.generation) ||
      record.storageKey != _documentKey(record.document.sourcePath, record.document.kind)) {
    throw const DraftException('unsafePath', 'The recovery location is invalid.');
  }
  final directory = '$root/${record.storageKey}/${record.generation}';
  _checkDirectory(root);
  _checkDirectory('$root/${record.storageKey}');
  _checkDirectory(directory);
  if (_sourcePath(record.snapshotPath) !=
          _sourcePath('$directory/snapshot.${record.document.snapshotExtension}') ||
      _sourcePath(record.metadataPath) != _sourcePath('$directory/draft.json')) {
    throw const DraftException('unsafePath', 'The recovery location does not match its metadata.');
  }
}

class _Generation {
  _Generation(this.key, this.name, this.path, this.sequence, this.modified);

  final String key;
  final String name;
  final String path;
  final int sequence;
  final DateTime modified;
  int bytes = 0;
  bool hasManifest = false;
  bool safe = true;
  _Manifest? manifest;
  final List<DraftIssue> issues = [];
}

class _StoredDocument {
  _StoredDocument(this.key, this.path);

  final String key;
  final String path;
  final List<_Generation> generations = [];

  List<_Generation> get committed => generations.where((g) => g.hasManifest).toList()
    ..sort((a, b) {
      final order = b.sequence.compareTo(a.sequence);
      return order != 0 ? order : b.name.compareTo(a.name);
    });

  int get nextSequence => generations.fold(0, (int n, g) => max(n, g.sequence)) + 1;
}

class _Store {
  final Map<String, _StoredDocument> documents = {};
  final List<DraftIssue> issues = [];
  int bytes = 0;
  bool unknownContents = false;
}

class _EntryBudget {
  _EntryBudget(this.remaining);

  int remaining;

  void take() {
    if (--remaining < 0) {
      throw const DraftException('capacity', 'There are too many recovery files to safely scan.');
    }
  }
}

Future<_Store> _scan(String root, DraftLimits limits, {String? ignoreGeneration}) async {
  _checkDirectory(root);
  final store = _Store();
  final budget = _EntryBudget(limits.maxEntries);
  await for (final entry in Directory(root).list(followLinks: false)) {
    budget.take();
    final key = _basename(entry.path);
    if (!_keyPattern.hasMatch(key) ||
        FileSystemEntity.typeSync(entry.path, followLinks: false) != FileSystemEntityType.directory) {
      store.unknownContents = true;
      store.issues.add(const DraftIssue('unsafePath', 'Unexpected recovery storage contents were kept.'));
      continue;
    }
    _checkDirectory(entry.path);
    final document = _StoredDocument(key, entry.path);
    store.documents[key] = document;
    await for (final child in Directory(entry.path).list(followLinks: false)) {
      budget.take();
      final name = _basename(child.path);
      if (name == ignoreGeneration) continue;
      final match = _generationPattern.firstMatch(name);
      if (match == null ||
          FileSystemEntity.typeSync(child.path, followLinks: false) != FileSystemEntityType.directory) {
        store.unknownContents = true;
        store.issues.add(DraftIssue('unsafePath', 'Unexpected recovery files were kept.', storageKey: key));
        continue;
      }
      _checkDirectory(child.path);
      final generation = _Generation(key, name, child.path,
          int.parse(match.group(1)!), child.statSync().modified.toUtc());
      document.generations.add(generation);
      await for (final file in Directory(child.path).list(followLinks: false)) {
        budget.take();
        final filename = _basename(file.path);
        final type = FileSystemEntity.typeSync(file.path, followLinks: false);
        if (filename == 'draft.json') generation.hasManifest = true;
        if (type != FileSystemEntityType.file) {
          generation.safe = false;
          store.unknownContents = true;
        } else {
          generation.bytes += file.statSync().size;
          if (filename != 'draft.json' && filename != '.draft.pending' &&
              !RegExp(r'^snapshot\.[a-z0-9]+$').hasMatch(filename) &&
              !(filename.startsWith('.') && filename.endsWith('.tmp'))) {
            generation.safe = false;
            store.unknownContents = true;
          }
        }
      }
      store.bytes += generation.bytes;
      if (generation.hasManifest) {
        try {
          if (!generation.safe) {
            throw const DraftException('unsafePath', 'Recovery data contains an unsafe file.');
          }
          generation.manifest = _readManifest(root, generation, limits);
        } catch (error) {
          generation.issues.add(DraftIssue(
            error is DraftException ? error.code : 'invalidMetadata',
            'A recovery generation could not be validated and was kept.',
            storageKey: key,
            generation: name,
          ));
        }
      }
    }
  }
  return store;
}

class _Manifest {
  const _Manifest(this.document, this.cleared, this.record);

  final DraftDocument document;
  final bool cleared;
  final DraftRecord? record;
}

String _readLimitedText(String path, int maxBytes) {
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
    throw const DraftException('unsafePath', 'Recovery data must be a regular file.');
  }
  final handle = File(path).openSync();
  try {
    if (handle.lengthSync() > maxBytes) {
      throw const DraftException('tooLarge', 'Recovery metadata or payload is too large.');
    }
    final bytes = handle.readSync(maxBytes + 1);
    if (bytes.length > maxBytes) {
      throw const DraftException('tooLarge', 'Recovery metadata or payload is too large.');
    }
    return utf8.decode(bytes);
  } finally {
    handle.closeSync();
  }
}

_Manifest _readManifest(String root, _Generation generation, DraftLimits limits) {
  final text = _readLimitedText('${generation.path}/draft.json', _metadataBytes);
  _checkJsonDepth(text);
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['version'] is! int ||
      json['version'] != DraftService.metadataVersion) {
    throw const DraftException('unsupportedVersion', 'The recovery metadata version is not supported.');
  }
  const fields = {
    'version', 'generation', 'sequence', 'state', 'createdAt', 'updatedAt',
    'sourcePath', 'sourceName', 'kind', 'format', 'payloadVersion',
    'sourceFingerprint', 'snapshot', 'snapshotFingerprint',
  };
  if (json.keys.toSet().difference(fields).isNotEmpty ||
      json.length != fields.length || json['generation'] != generation.name ||
      json['sequence'] is! int || json['sequence'] != generation.sequence || generation.sequence < 1 ||
      generation.sequence > _maxSequence) {
    throw const DraftException('invalidMetadata', 'The recovery generation does not match its metadata.');
  }
  final path = _jsonString(json, 'sourcePath', 32768);
  if (!_isAbsolute(path) || _sourcePath(path) != path) {
    throw const DraftException('unsafePath', 'The recovery source path is not an absolute local path.');
  }
  _ensureSourceOutsideStore(path, root);
  final kindName = _jsonString(json, 'kind', 16);
  final kinds = DocKind.values.where((kind) => kind.name == kindName);
  if (kinds.length != 1) {
    throw const DraftException('invalidFormat', 'The recovery document kind is invalid.');
  }
  final document = DraftDocument(
    sourcePath: path,
    sourceName: _jsonString(json, 'sourceName', 1024),
    kind: kinds.single,
    format: _jsonString(json, 'format', 16),
    payloadVersion: _jsonInt(json, 'payloadVersion', 1, 1000000),
  );
  if (_documentKey(path, document.kind) != generation.key) {
    throw const DraftException('unsafePath', 'The recovery source does not match its directory.');
  }
  final created = _jsonInt(json, 'createdAt', 0, 8640000000000000);
  final updated = _jsonInt(json, 'updatedAt', created, 8640000000000000);
  final sourceFingerprint = _readFingerprint(json['sourceFingerprint'], limits.maxSourceBytes);
  if (json['state'] == 'cleared') {
    if (json['snapshot'] != null || json['snapshotFingerprint'] != null) {
      throw const DraftException('invalidMetadata', 'A cleared recovery entry cannot contain a snapshot.');
    }
    return _Manifest(document, true, null);
  }
  if (json['state'] != 'draft' || json['snapshot'] != 'snapshot.${document.snapshotExtension}') {
    throw const DraftException('unsafePath', 'The recovery snapshot path or state is invalid.');
  }
  final snapshot = _readFingerprint(json['snapshotFingerprint'], limits.maxSnapshotBytes);
  if (!snapshot.exists) {
    throw const DraftException('invalidMetadata', 'The recovery snapshot fingerprint is missing.');
  }
  return _Manifest(document, false, DraftRecord._(
    document: document,
    storageKey: generation.key,
    generation: generation.name,
    sequence: generation.sequence,
    createdAt: DateTime.fromMillisecondsSinceEpoch(created, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
    sourceFingerprint: sourceFingerprint,
    snapshotFingerprint: snapshot,
    snapshotPath: '${generation.path}/${json['snapshot']}',
    metadataPath: '${generation.path}/draft.json',
    observedHead: generation.name,
  ));
}

String _jsonString(Map<String, dynamic> json, String key, int maximum) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maximum ||
      _controlPattern.hasMatch(value)) {
    throw const DraftException('invalidMetadata', 'A recovery metadata string is invalid.');
  }
  return value;
}

int _jsonInt(Map<String, dynamic> json, String key, int minimum, int maximum) {
  final value = json[key];
  if (value is! int || value < minimum || value > maximum) {
    throw const DraftException('invalidMetadata', 'A recovery metadata number is invalid.');
  }
  return value;
}

DraftFingerprint _readFingerprint(Object? value, int maxBytes) {
  if (value is! Map<String, dynamic> || value.length != 4 || value['exists'] is! bool) {
    throw const DraftException('invalidMetadata', 'The recovery fingerprint is invalid.');
  }
  final size = _jsonInt(value, 'size', 0, maxBytes);
  final modified = _jsonInt(value, 'modifiedMicros', -8640000000000000000, 8640000000000000000);
  final digest = value['sha256'];
  final exists = value['exists'] as bool;
  if (digest is! String || (exists ? !_digestPattern.hasMatch(digest)
      : (digest.isNotEmpty || size != 0 || modified != 0))) {
    throw const DraftException('invalidMetadata', 'The recovery fingerprint digest is invalid.');
  }
  return DraftFingerprint._(exists: exists, size: size, modifiedMicros: modified, sha256: digest);
}

class _Head {
  const _Head(this.token, this.draft, this.hasBrokenCommit, this.issues);

  final String? token;
  final DraftRecord? draft;
  final bool hasBrokenCommit;
  final List<DraftIssue> issues;
}

Future<_Head> _readHead(_StoredDocument? document, DraftLimits limits) async {
  if (document == null) return const _Head(null, null, false, []);
  final committed = document.committed;
  final token = committed.isEmpty ? null : committed.first.name;
  final issues = <DraftIssue>[
    for (final generation in document.generations)
      if (!generation.hasManifest &&
          (committed.isEmpty || generation.sequence > committed.first.sequence))
        DraftIssue(
          'incompleteDraft',
          'An unfinished recovery write was found. Only committed copies can be restored.',
          storageKey: document.key,
          generation: generation.name,
        ),
  ];
  for (final generation in committed) {
    issues.addAll(generation.issues);
    final manifest = generation.manifest;
    if (manifest == null) continue;
    if (manifest.cleared) return _Head(token, null, issues.isNotEmpty, issues);
    final draft = manifest.record!;
    try {
      _verifySnapshot(draft, limits);
      return _Head(token, draft._withIssues(issues, observedHead: token), issues.isNotEmpty, issues);
    } catch (error) {
      issues.add(DraftIssue(
        error is DraftException ? error.code : 'invalidSnapshot',
        'A recovery snapshot is damaged; earlier committed copies were checked.',
        storageKey: document.key,
        generation: generation.name,
      ));
    }
  }
  return _Head(token, null, document.generations.isNotEmpty, issues);
}

void _verifySnapshot(DraftRecord draft, DraftLimits limits) {
  _checkDirectory(File(draft.metadataPath).parent.path);
  if (FileSystemEntity.typeSync(draft.snapshotPath, followLinks: false) != FileSystemEntityType.file) {
    throw const DraftException('unsafePath', 'The recovery snapshot is missing or is not a regular file.');
  }
  final actual = _fingerprint(draft.snapshotPath, limits.maxSnapshotBytes);
  if (!actual.exists || actual.size != draft.snapshotFingerprint.size ||
      actual.sha256 != draft.snapshotFingerprint.sha256) {
    throw const DraftException('invalidSnapshot', 'The recovery snapshot failed its integrity check.');
  }
  if (draft.document.kind == DocKind.pdf) {
    final text = _readLimitedText(draft.snapshotPath, limits.maxPayloadBytes);
    _checkJsonDepth(text);
    _validatePayload(jsonDecode(text), limits.maxPayloadBytes);
  }
}

DraftSourceState _sourceState(DraftRecord draft, DraftLimits limits) {
  try {
    final current = _fingerprint(draft.document.sourcePath, limits.maxSourceBytes);
    if (!current.exists && draft.sourceFingerprint.exists) return DraftSourceState.missing;
    return current.matches(draft.sourceFingerprint)
        ? DraftSourceState.unchanged : DraftSourceState.changed;
  } catch (_) {
    return DraftSourceState.unavailable;
  }
}

DraftFingerprint _fingerprint(String path, int maxBytes) {
  final before = File(path).statSync();
  if (before.type == FileSystemEntityType.notFound) {
    return const DraftFingerprint._(exists: false, size: 0, modifiedMicros: 0, sha256: '');
  }
  if (before.type != FileSystemEntityType.file) {
    throw const DraftException('sourceUnavailable', 'The document is not a readable regular file.');
  }
  if (before.size > maxBytes) {
    throw const DraftException('tooLarge', 'The document exceeds the recovery size limit.');
  }
  final handle = File(path).openSync();
  final hash = _Sha256();
  var count = 0;
  try {
    while (true) {
      final bytes = handle.readSync(min(64 * 1024, maxBytes - count + 1));
      if (bytes.isEmpty) break;
      count += bytes.length;
      if (count > maxBytes) {
        throw const DraftException('tooLarge', 'The document exceeds the recovery size limit.');
      }
      hash.add(bytes);
    }
    final after = File(path).statSync();
    if (count != before.size || count != handle.lengthSync() ||
        after.type != FileSystemEntityType.file || after.size != before.size ||
        after.modified != before.modified || after.changed != before.changed) {
      throw const DraftException('sourceChanged', 'The document changed while its recovery fingerprint was read.');
    }
    return DraftFingerprint._(
      exists: true,
      size: count,
      modifiedMicros: after.modified.microsecondsSinceEpoch,
      sha256: hash.finish(),
    );
  } finally {
    handle.closeSync();
  }
}

void _checkHead(_StoredDocument? document, String? expected) {
  final committed = document?.committed ?? [];
  final actual = committed.isEmpty ? null : committed.first.name;
  if (actual != expected) {
    throw const DraftException('staleSession', 'Another editing session changed this draft. Recovery data was kept.');
  }
}

class _WriteIntent {
  const _WriteIntent({
    required this.root,
    required this.key,
    required this.generation,
    required this.sequence,
    required this.document,
    required this.sourceFingerprint,
    required this.expectedHead,
    required this.createdAt,
    required this.updatedAt,
    required this.cleared,
  });

  final String root;
  final String key;
  final String generation;
  final int sequence;
  final DraftDocument document;
  final DraftFingerprint sourceFingerprint;
  final String? expectedHead;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool cleared;

  String get directory => '$root/$key/$generation';
  String get snapshotPath => '$directory/snapshot.${document.snapshotExtension}';
}

Future<_WriteIntent> _prepareIntent(
  String root,
  DraftDocument document,
  DraftFingerprint fingerprint,
  String? expectedHead,
  DateTime now,
  DraftLimits limits, {
  required bool cleared,
}) async {
  now = DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch, isUtc: true);
  _ensureSourceOutsideStore(document.sourcePath, root);
  final store = await _scan(root, limits);
  final key = _documentKey(document.sourcePath, document.kind);
  final previous = store.documents[key];
  _checkHead(previous, expectedHead);
  if (!cleared) {
    if (store.unknownContents) {
      throw const DraftException('unsafePath', 'Unexpected recovery data must be reviewed before more drafts can be stored.');
    }
    final count = store.documents.values.where((doc) {
      final committed = doc.committed;
      return committed.isNotEmpty && committed.first.manifest?.cleared != true;
    }).length;
    final old = previous?.committed ?? [];
    if ((old.isEmpty || old.first.manifest?.cleared == true) && count >= limits.maxDocuments) {
      throw const DraftException('capacity', 'Recovery storage is full. Save or discard an existing draft first.');
    }
  }
  final sequence = previous?.nextSequence ?? 1;
  if (sequence > _maxSequence) {
    throw const DraftException('capacity', 'The recovery generation limit has been reached.');
  }
  final prior = previous?.committed.firstOrNull?.manifest?.record;
  final createdAt = prior?.createdAt ?? now;
  final updatedAt = now.isBefore(prior?.updatedAt ?? createdAt) ? prior?.updatedAt ?? createdAt : now;
  if (createdAt.millisecondsSinceEpoch < 0) {
    throw const DraftException('invalidMetadata', 'The recovery clock is invalid.');
  }
  final directory = Directory('$root/$key');
  if (!directory.existsSync()) directory.createSync();
  _checkDirectory(directory.path);
  final random = Random.secure();
  String generation;
  do {
    final token = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    generation = 'g-${sequence.toString().padLeft(16, '0')}-$token';
  } while (FileSystemEntity.typeSync('${directory.path}/$generation', followLinks: false) !=
      FileSystemEntityType.notFound);
  Directory('${directory.path}/$generation').createSync();
  return _WriteIntent(root: root, key: key, generation: generation, sequence: sequence,
      document: document, sourceFingerprint: fingerprint, expectedHead: expectedHead,
      createdAt: createdAt, updatedAt: updatedAt, cleared: cleared);
}

Map<String, Object?> _metadata(_WriteIntent intent, DraftFingerprint? snapshot) => {
  'version': DraftService.metadataVersion,
  'generation': intent.generation,
  'sequence': intent.sequence,
  'state': intent.cleared ? 'cleared' : 'draft',
  'createdAt': intent.createdAt.millisecondsSinceEpoch,
  'updatedAt': intent.updatedAt.millisecondsSinceEpoch,
  'sourcePath': intent.document.sourcePath,
  'sourceName': intent.document.sourceName,
  'kind': intent.document.kind.name,
  'format': intent.document.format,
  'payloadVersion': intent.document.payloadVersion,
  'sourceFingerprint': intent.sourceFingerprint._toJson(),
  'snapshot': snapshot == null ? null : 'snapshot.${intent.document.snapshotExtension}',
  'snapshotFingerprint': snapshot?._toJson(),
};

Future<DraftRecord> _commitSnapshot(_WriteIntent intent, DraftLimits limits) async {
  _checkIntentDirectories(intent);
  if (FileSystemEntity.typeSync(intent.snapshotPath, followLinks: false) != FileSystemEntityType.file) {
    throw const DraftException('invalidSnapshot', 'The draft writer did not produce a regular snapshot file.');
  }
  final handle = File(intent.snapshotPath).openSync(mode: FileMode.append);
  try {
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
  final fingerprint = _fingerprint(intent.snapshotPath, limits.maxSnapshotBytes);
  if (!fingerprint.exists) {
    throw const DraftException('invalidSnapshot', 'The recovery snapshot disappeared before it could be committed.');
  }
  final bytes = utf8.encode(jsonEncode(_metadata(intent, fingerprint)));
  if (bytes.length > _metadataBytes) {
    throw const DraftException('tooLarge', 'The recovery metadata is too large.');
  }
  final store = await _scan(intent.root, limits, ignoreGeneration: intent.generation);
  _checkHead(store.documents[intent.key], intent.expectedHead);
  var projectedBytes = store.bytes + fingerprint.size + bytes.length;
  if (projectedBytes > limits.maxTotalBytes) {
    final removable = await _removableGenerations(store, limits, keep: 1);
    final current = store.documents[intent.key]?.committed.firstOrNull;
    projectedBytes -= removable.fold(0, (int sum, generation) => sum + generation.bytes);
    if (current?.manifest?.record != null && !removable.contains(current)) {
      projectedBytes -= current!.bytes;
    }
  }
  if (store.unknownContents || projectedBytes > limits.maxTotalBytes) {
    throw const DraftException('capacity', 'Recovery storage is full. Existing unsaved drafts have been kept.');
  }
  _commitMetadata(intent, bytes);
  return DraftRecord._(
    document: intent.document,
    storageKey: intent.key,
    generation: intent.generation,
    sequence: intent.sequence,
    createdAt: intent.createdAt,
    updatedAt: intent.updatedAt,
    sourceFingerprint: intent.sourceFingerprint,
    snapshotFingerprint: fingerprint,
    snapshotPath: intent.snapshotPath,
    metadataPath: '${intent.directory}/draft.json',
    observedHead: intent.generation,
  );
}

Future<void> _commitClear(_WriteIntent intent, DraftLimits limits) async {
  final store = await _scan(intent.root, limits, ignoreGeneration: intent.generation);
  _checkHead(store.documents[intent.key], intent.expectedHead);
  _commitMetadata(intent, utf8.encode(jsonEncode(_metadata(intent, null))));
}

void _checkIntentDirectories(_WriteIntent intent) {
  _checkDirectory(intent.root);
  _checkDirectory('${intent.root}/${intent.key}');
  _checkDirectory(intent.directory);
}

void _commitMetadata(_WriteIntent intent, List<int> bytes) {
  _checkIntentDirectories(intent);
  final target = '${intent.directory}/draft.json';
  if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
    throw const DraftException('invalidMetadata', 'A recovery commit cannot overwrite an existing generation.');
  }
  final pending = File('${intent.directory}/.draft.pending');
  if (FileSystemEntity.typeSync(pending.path, followLinks: false) != FileSystemEntityType.notFound) {
    throw const DraftException('unsafePath', 'The recovery commit staging path is not empty.');
  }
  pending.createSync(exclusive: true);
  pending.writeAsBytesSync(bytes, flush: true);
  _checkIntentDirectories(intent);
  pending.renameSync(target);
}

bool _abandonIntent(_WriteIntent intent) {
  try {
    _checkIntentDirectories(intent);
    if (FileSystemEntity.typeSync('${intent.directory}/draft.json', followLinks: false) ==
        FileSystemEntityType.file) {
      return true;
    }
    Directory(intent.directory).deleteSync(recursive: true);
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<_Generation>> _removableGenerations(_Store store, DraftLimits limits, {required int keep}) async {
  final removable = <_Generation>[];
  for (final document in store.documents.values) {
    final committed = document.committed;
    if (committed.isEmpty || committed.first.manifest == null) continue;
    if (committed.first.manifest!.cleared) {
      removable.addAll(document.generations.where((g) => g != committed.first && g.safe));
      continue;
    }
    if (committed.length <= keep) continue;
    try {
      _verifySnapshot(committed.first.manifest!.record!, limits);
    } catch (_) {
      continue;
    }
    var retained = 0;
    for (final generation in committed) {
      if (generation.manifest == null || !generation.safe) continue;
      retained++;
      if (retained > keep) removable.add(generation);
    }
  }
  return removable;
}

Future<DraftCleanupReport> _cleanup(String root, DateTime now, DraftLimits limits) async {
  final store = await _scan(root, limits);
  final issues = <DraftIssue>[...store.issues];
  var removed = 0;
  var bytes = store.bytes;
  var oldDrafts = 0;
  final deleted = <String>{};
  void remove(_Generation generation) {
    if (deleted.contains(generation.path)) return;
    try {
      _checkDirectory(root);
      _checkDirectory('$root/${generation.key}');
      _checkDirectory(generation.path);
      Directory(generation.path).deleteSync(recursive: true);
      deleted.add(generation.path);
      bytes -= generation.bytes;
      removed++;
    } catch (_) {
      issues.add(DraftIssue('cleanupFailed', 'An old recovery generation could not be removed.',
          storageKey: generation.key, generation: generation.name));
    }
  }

  for (final document in store.documents.values) {
    final committed = document.committed;
    final oldOrphans = document.generations.where((generation) =>
        !generation.hasManifest && generation.safe &&
        now.difference(generation.modified) >= limits.orphanRetention).toList();
    final head = oldOrphans.isEmpty ? null : await _readHead(document, limits);
    final hasCompleteCopy = head?.draft != null ||
        committed.firstOrNull?.manifest?.cleared == true;
    for (final generation in document.generations) {
      issues.addAll(generation.issues);
      if (oldOrphans.contains(generation)) {
        if (hasCompleteCopy) {
          remove(generation);
        } else {
          issues.add(DraftIssue(
            'incompleteDraft',
            'An incomplete recovery copy was kept because no committed copy remains.',
            storageKey: document.key,
            generation: generation.name,
          ));
        }
      }
    }
    if (committed.isNotEmpty && committed.first.manifest?.cleared == true) {
      for (final generation in document.generations) {
        if (generation != committed.first && generation.safe) remove(generation);
      }
      if (now.difference(committed.first.modified) >= limits.retention &&
          document.generations.every((g) => g == committed.first || deleted.contains(g.path))) {
        remove(committed.first);
      }
    } else if (committed.firstOrNull?.manifest?.record case final draft?) {
      if (now.difference(draft.updatedAt) >= limits.retention) oldDrafts++;
    }
  }
  for (final generation in await _removableGenerations(store, limits, keep: limits.keptGenerations)) {
    remove(generation);
  }
  if (bytes > limits.maxTotalBytes) {
    final candidates = await _removableGenerations(store, limits, keep: 1);
    candidates.sort((a, b) => a.modified.compareTo(b.modified));
    for (final generation in candidates) {
      if (bytes <= limits.maxTotalBytes) break;
      remove(generation);
    }
  }
  for (final document in store.documents.values) {
    if (document.generations.every((generation) => deleted.contains(generation.path))) {
      try {
        _checkDirectory(root);
        _checkDirectory(document.path);
        Directory(document.path).deleteSync();
      } catch (_) {}
    }
  }
  issues.removeWhere((issue) => issue.storageKey != null && issue.generation != null &&
      deleted.contains('$root/${issue.storageKey}/${issue.generation}'));
  if (bytes > limits.maxTotalBytes || store.unknownContents) {
    issues.add(const DraftIssue('capacity', 'Recovery storage needs attention; unsaved documents were not evicted.'));
  }
  return DraftCleanupReport(
    removedGenerations: removed,
    retainedBytes: bytes,
    oldDrafts: oldDrafts,
    overBudget: bytes > limits.maxTotalBytes || store.unknownContents,
    issues: List.unmodifiable(issues),
  );
}

void _checkJsonDepth(String text) {
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final code in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (code == 92) {
        escaped = true;
      } else if (code == 34) {
        quoted = false;
      }
    } else if (code == 34) {
      quoted = true;
    } else if (code == 123 || code == 91) {
      if (++depth > 64) {
        throw const DraftException('invalidMetadata', 'Recovery JSON is nested too deeply.');
      }
    } else if (code == 125 || code == 93) {
      depth--;
    }
  }
}

Future<List<int>> _encodePayloadOffThread(Object? payload, int maxBytes) =>
    Isolate.run(() => _payloadBytes(payload, maxBytes));

Future<void> _writeBytesOffThread(String path, List<int> bytes) => Isolate.run(() {
  File(path).writeAsBytesSync(bytes, flush: true);
});

List<int> _payloadBytes(Object? payload, int maxBytes) {
  _validatePayload(payload, maxBytes);
  final bytes = utf8.encode(jsonEncode(payload));
  if (bytes.length > maxBytes) {
    throw const DraftException('tooLarge', 'The PDF edit recovery payload is too large.');
  }
  return bytes;
}

void _validatePayload(Object? payload, int maxBytes) {
  final pending = <(Object?, int)>[(payload, 0)];
  final seen = HashSet<Object>.identity();
  var nodes = 0;
  var characters = 0;
  void key(String key) {
    characters += key.length;
    final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    if (normalized.contains('password') || normalized.contains('passphrase') ||
        normalized.contains('passwd') || normalized == 'pwd' ||
        normalized == 'credentials') {
      throw const DraftException('unsafePayload', 'Passwords and credentials cannot be stored in PDF recovery data.');
    }
  }
  while (pending.isNotEmpty) {
    final (value, depth) = pending.removeLast();
    if (++nodes > 1000000 || depth > 64 || characters > maxBytes) {
      throw const DraftException('tooLarge', 'The PDF edit recovery payload is too large or too deeply nested.');
    }
    if (value is String) {
      characters += value.length;
    } else if (value == null || value is bool) {
      continue;
    } else if (value is num) {
      if (!value.isFinite) {
        throw const DraftException('unsafePayload', 'Recovery JSON cannot contain non-finite numbers.');
      }
    } else if (value is List) {
      if (!seen.add(value) || value.length + pending.length > 1000000) {
        throw const DraftException('unsafePayload', 'Recovery JSON must be a bounded tree of values.');
      }
      for (final child in value) {
        pending.add((child, depth + 1));
      }
    } else if (value is Map) {
      if (!seen.add(value) || value.length + pending.length > 1000000) {
        throw const DraftException('unsafePayload', 'Recovery JSON must be a bounded tree of values.');
      }
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const DraftException('unsafePayload', 'Recovery JSON keys must be strings.');
        }
        key(entry.key as String);
        pending.add((entry.value, depth + 1));
      }
    } else {
      throw const DraftException('unsafePayload', 'Recovery data must contain only JSON values.');
    }
  }
  if (characters > maxBytes) {
    throw const DraftException('tooLarge', 'The PDF edit recovery payload is too large.');
  }
}

class _Sha256 {
  final _state = Uint32List.fromList([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final _buffer = Uint8List(64);
  final _words = Uint32List(64);
  int _used = 0;
  int _length = 0;

  static const _rounds = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  void add(List<int> bytes) {
    _length += bytes.length;
    var offset = 0;
    while (offset < bytes.length) {
      final count = min(64 - _used, bytes.length - offset);
      _buffer.setRange(_used, _used + count, bytes, offset);
      _used += count;
      offset += count;
      if (_used == 64) {
        _block();
        _used = 0;
      }
    }
  }

  int _rotate(int value, int count) =>
      (value >>> count) | ((value << (32 - count)) & 0xffffffff);

  void _block() {
    for (var i = 0; i < 16; i++) {
      final offset = i * 4;
      _words[i] = (_buffer[offset] << 24) | (_buffer[offset + 1] << 16) |
          (_buffer[offset + 2] << 8) | _buffer[offset + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = _words[i - 15];
      final y = _words[i - 2];
      final s0 = _rotate(x, 7) ^ _rotate(x, 18) ^ (x >>> 3);
      final s1 = _rotate(y, 17) ^ _rotate(y, 19) ^ (y >>> 10);
      _words[i] = (_words[i - 16] + s0 + _words[i - 7] + s1) & 0xffffffff;
    }
    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotate(e, 6) ^ _rotate(e, 11) ^ _rotate(e, 25);
      final choice = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + choice + _rounds[i] + _words[i]) & 0xffffffff;
      final s0 = _rotate(a, 2) ^ _rotate(a, 13) ^ _rotate(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }

  String finish() {
    final bits = _length * 8;
    add(const [0x80]);
    while (_used != 56) {
      add(const [0]);
    }
    add([for (var shift = 56; shift >= 0; shift -= 8) (bits >>> shift) & 0xff]);
    return _state.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
  }
}
