import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/doc_kind.dart';
import 'package:pdfhelper/services/draft_service.dart';

import '../support/fake_path_provider.dart';

Matcher draftError(String code) => isA<DraftException>().having(
  (error) => error.code,
  'code',
  code,
);

class ManualDraftTimer implements Timer {
  ManualDraftTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  void fire({bool evenIfCancelled = false}) {
    if (!_active && !evenIfCancelled) return;
    _active = false;
    _tick++;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

class ManualDraftClock {
  final List<ManualDraftTimer> timers = [];

  Timer schedule(Duration delay, void Function() callback) {
    final timer = ManualDraftTimer(delay, callback);
    timers.add(timer);
    return timer;
  }

  List<ManualDraftTimer> get active => timers.where((timer) => timer.isActive).toList();

  void fire() => active.single.fire();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory drafts;
  late File source;
  late FakePathProvider paths;
  late DateTime now;
  late DraftService service;
  final controllers = <DraftController>[];
  final sessions = <DraftSession>[];

  DraftDocument document({File? file, DocKind kind = DocKind.text, String format = 'txt', int payloadVersion = 1}) =>
      DraftDocument(
        sourcePath: (file ?? source).path,
        sourceName: (file ?? source).uri.pathSegments.last,
        kind: kind,
        format: format,
        payloadVersion: payloadVersion,
      );

  Future<DraftSession> open({DraftService? using, DraftDocument? description, DraftRecord? restored}) async {
    final session = await (using ?? service).openSession(
      description ?? document(),
      restoredDraft: restored,
    );
    sessions.add(session);
    return session;
  }

  Future<DraftRecord> write(DraftSession session, String value, {DraftService? using}) =>
      (using ?? service).writeSnapshot(session, (path) async {
        await File(path).writeAsString(value);
      });

  Future<DraftRecovery?> recover({File? file, DocKind kind = DocKind.text, DraftService? using}) =>
      (using ?? service).findRecovery(sourcePath: (file ?? source).path, kind: kind);

  Future<DraftController> controller({
    DraftWriter? writer,
    ManualDraftClock? timer,
    DraftErrorHandler? onError,
    int maxRetries = 3,
    DraftRecord? restored,
    bool observeLifecycle = false,
  }) async {
    final result = DraftController(
      service: service,
      session: await open(restored: restored),
      writeSnapshot: writer ?? (path) async {
        await File(path).writeAsString('draft');
      },
      timerFactory: timer?.schedule,
      onError: onError,
      maxAutomaticRetries: maxRetries,
      observeLifecycle: observeLifecycle,
    );
    controllers.add(result);
    return result;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('dochelper_drafts_');
    paths = FakePathProvider.install(root);
    drafts = Directory('${root.path}/Drafts');
    source = File('${root.path}/notes.txt')..writeAsStringSync('original');
    now = DateTime.now().toUtc();
    service = DraftService(directory: drafts, clock: () => now);
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
      await controller.settled;
    }
    controllers.clear();
    for (final session in sessions) {
      session.close();
    }
    sessions.clear();
    FakePathProvider.restore();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('durable copies', () {
    test('defaults to the private support Drafts directory', () async {
      final defaultService = DraftService();
      final session = await open(using: defaultService);
      final draft = await write(session, 'private', using: defaultService);
      final expected = Directory('${paths.support.path}/Drafts').resolveSymbolicLinksSync();
      expect(File(draft.snapshotPath).parent.parent.parent.path, expected);
      expect(source.readAsStringSync(), 'original');
      expect(File(draft.metadataPath).existsSync(), isTrue);
    });

    test('reopens a flushed snapshot with its version and original source', () async {
      final session = await open();
      final draft = await write(session, 'unsaved text');
      final coldService = DraftService(directory: drafts);
      final recovery = (await recover(using: coldService))!;
      final note = jsonDecode(File(draft.metadataPath).readAsStringSync()) as Map;

      expect(draft.version, 1);
      expect(draft.document.sourceName, 'notes.txt');
      expect(draft.document.sourcePath, source.absolute.uri.normalizePath().toFilePath());
      expect(draft.document.kind, DocKind.text);
      expect(draft.document.format, 'txt');
      expect(draft.document.payloadVersion, 1);
      expect(draft.sizeBytes, utf8.encode('unsaved text').length);
      expect(recovery.sourceState, DraftSourceState.unchanged);
      expect(recovery.draft.generation, draft.generation);
      expect(File(recovery.draft.snapshotPath).readAsStringSync(), 'unsaved text');
      expect(source.readAsStringSync(), 'original');
      expect(note['snapshot'], 'snapshot.txt');
      expect(note['state'], 'draft');
      expect(note['sourceFingerprint']['exists'], isTrue);
      expect(File('${File(draft.metadataPath).parent.path}/.draft.pending').existsSync(), isFalse);
    });

    test('monotonic unique generations do not depend on a moving clock', () async {
      final session = await open();
      final first = await write(session, 'one');
      final second = await write(session, 'two');
      now = now.subtract(const Duration(days: 1));
      final third = await write(session, 'three');
      expect([first.sequence, second.sequence, third.sequence], [1, 2, 3]);
      expect({first.generation, second.generation, third.generation}, hasLength(3));
      expect(third.updatedAt, second.updatedAt);
      expect(File(second.snapshotPath).readAsStringSync(), 'two');
      expect(File(first.snapshotPath).existsSync(), isFalse);
      expect((await recover())!.draft.generation, third.generation);
    });

    test('a partly written failed copy leaves the previous draft intact and retries', () async {
      final session = await open();
      final first = await write(session, 'valuable edits');
      String? partial;
      await expectLater(service.writeSnapshot(session, (path) async {
        partial = path;
        await File(path).writeAsString('partial');
        throw StateError('disk failure');
      }), throwsStateError);
      expect(File(partial!).existsSync(), isFalse);
      expect((await recover())!.draft.generation, first.generation);
      expect(File(first.snapshotPath).readAsStringSync(), 'valuable edits');
      expect(source.readAsStringSync(), 'original');
      final retried = await write(session, 'retry succeeded');
      expect((await recover())!.draft.generation, retried.generation);
    });

    test('a failed metadata rename never replaces the previous committed copy', () async {
      final session = await open();
      final previous = await write(session, 'safe copy');
      await expectLater(service.writeSnapshot(session, (path) async {
        await File(path).writeAsString('new copy');
        Directory('${File(path).parent.path}/draft.json').createSync();
      }), throwsA(draftError('invalidMetadata')));
      expect((await recover())!.draft.generation, previous.generation);
      expect(File(previous.snapshotPath).readAsStringSync(), 'safe copy');
      final next = await write(session, 'retry after rename failure');
      expect((await recover())!.draft.generation, next.generation);
    });

    test('a writer that produces no file cannot commit', () async {
      final session = await open();
      await expectLater(service.writeSnapshot(session, (_) async {}), throwsA(draftError('invalidSnapshot')));
      expect(await recover(), isNull);
      expect((await service.listDrafts()).drafts, isEmpty);
    });

    test('directory resolution retries rather than caching a failed future', () async {
      var calls = 0;
      final flaky = DraftService(directoryProvider: () async {
        if (++calls == 1) throw const FileSystemException('not mounted');
        return drafts;
      });
      await expectLater(open(using: flaky), throwsA(draftError('io')));
      final session = await open(using: flaky);
      await write(session, 'after mount', using: flaky);
      expect((await recover(using: flaky))!.draft.sizeBytes, 11);
      expect(calls, 2);
    });

    test('all supported editor kinds retain their own snapshot formats', () async {
      final formats = <DocKind, String>{
        DocKind.word: 'docx',
        DocKind.sheet: 'ods',
        DocKind.slides: 'pptx',
        DocKind.text: 'txt',
      };
      for (final entry in formats.entries) {
        final session = await open(description: document(kind: entry.key, format: entry.value));
        final draft = await write(session, '${entry.key.name} snapshot');
        expect(draft.snapshotPath, endsWith('.${entry.value}'));
        expect((await recover(kind: entry.key))!.draft.document.format, entry.value);
      }
      expect((await service.listDrafts()).drafts, hasLength(4));
      expect(source.readAsStringSync(), 'original');
    });

    test('known SHA-256 vectors cover empty, padded, multi-block, and streamed input', () async {
      final vectors = <String, String>{
        '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq':
            '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
        List.filled(1000000, 'a').join():
            'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      };
      for (final entry in vectors.entries) {
        source.writeAsStringSync(entry.key);
        final session = await open();
        expect(session.sourceFingerprint.sha256, entry.value);
        expect(session.sourceFingerprint.size, entry.key.length);
        session.close();
      }
    });
  });

  group('serialization and conflicts', () {
    test('in-flight file writers are serialized across service instances', () async {
      final otherSource = File('${root.path}/other.txt')..writeAsStringSync('other');
      final otherService = DraftService(directory: drafts);
      final firstSession = await open();
      final secondSession = await open(using: otherService, description: document(file: otherSource));
      final started = Completer<void>();
      final release = Completer<void>();
      var secondStarted = false;
      final first = service.writeSnapshot(firstSession, (path) async {
        started.complete();
        await release.future;
        await File(path).writeAsString('first');
      });
      await started.future;
      final second = otherService.writeSnapshot(secondSession, (path) async {
        secondStarted = true;
        await File(path).writeAsString('second');
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondStarted, isFalse);
      release.complete();
      await first;
      await second;
      expect(secondStarted, isTrue);
      expect((await service.listDrafts()).drafts, hasLength(2));
    });

    test('another session cannot overwrite a newer draft or resurrect a discarded one', () async {
      final first = await open();
      final stale = await open();
      final current = await write(first, 'first editor');
      await expectLater(write(stale, 'other editor'), throwsA(draftError('staleSession')));
      expect((await recover())!.draft.generation, current.generation);
      await service.discard(first);
      await expectLater(write(stale, 'late timer'), throwsA(draftError('staleSession')));
      expect(await recover(), isNull);
      await write(first, 'intentional new edits');
      expect(File((await recover())!.draft.snapshotPath).readAsStringSync(), 'intentional new edits');
    });

    test('discard invalidates already requested and in-flight snapshots', () async {
      final session = await open();
      await write(session, 'previous');
      final started = Completer<void>();
      final release = Completer<void>();
      final pending = service.writeSnapshot(session, (path) async {
        started.complete();
        await release.future;
        await File(path).writeAsString('late data');
      });
      final failed = expectLater(pending, throwsA(draftError('cancelled')));
      await started.future;
      final discarded = service.discard(session);
      release.complete();
      await failed;
      await discarded;
      expect(await recover(), isNull);
    });

    test('open requires an explicit recovery decision before replacing unsaved work', () async {
      final first = await open();
      final record = await write(first, 'old unsaved work');
      await expectLater(open(), throwsA(draftError('recoveryRequired')));
      final resumed = await open(restored: (await recover())!.draft);
      expect(resumed.latestDraft!.generation, record.generation);
      await write(resumed, 'recovered and edited');
      await expectLater(service.discardRecovery(record), throwsA(draftError('staleSession')));
      expect(File((await recover())!.draft.snapshotPath).readAsStringSync(), 'recovered and edited');
    });

    test('source changes do not get adopted as a new baseline by autosave', () async {
      final session = await open();
      final baseline = session.sourceFingerprint;
      await write(session, 'draft one');
      source.writeAsStringSync('external edit');
      final second = await write(session, 'draft two');
      expect(second.sourceFingerprint.matches(baseline), isTrue);
      expect((await recover())!.sourceState, DraftSourceState.changed);
      expect(source.readAsStringSync(), 'external edit');
    });

    test('full fingerprints detect same-length middle edits with restored mtime', () async {
      final bytes = List<int>.generate(400 * 1024, (i) => i % 251);
      source.writeAsBytesSync(bytes);
      final modified = source.lastModifiedSync();
      final session = await open();
      await write(session, 'unsaved');
      bytes[125 * 1024] ^= 0xff;
      source.writeAsBytesSync(bytes);
      source.setLastModifiedSync(modified);
      expect((await recover())!.sourceState, DraftSourceState.changed);
    });

    test('missing and unreadable sources are distinct from unchanged documents', () async {
      final session = await open();
      await write(session, 'recoverable');
      source.deleteSync();
      expect((await recover())!.sourceState, DraftSourceState.missing);
      Directory(source.path).createSync();
      expect((await recover())!.sourceState, DraftSourceState.unavailable);
    });

    test('a new unsaved document can recover even before its source file exists', () async {
      source.deleteSync();
      final session = await open();
      expect(session.sourceFingerprint.exists, isFalse);
      await write(session, 'brand new note');
      expect((await recover())!.sourceState, DraftSourceState.unchanged);
      source.writeAsStringSync('another application created this path');
      expect((await recover())!.sourceState, DraftSourceState.changed);
    });

    test('acknowledging a successful save rebases the next editing session', () async {
      final session = await open();
      final old = await write(session, 'saved content');
      source.writeAsStringSync('saved content');
      await service.acknowledgeSave(session);
      expect(await recover(), isNull);
      expect(File(old.snapshotPath).existsSync(), isFalse);
      final next = await write(session, 'later edits');
      expect(next.sourceFingerprint.sha256, session.sourceFingerprint.sha256);
      expect((await recover())!.sourceState, DraftSourceState.unchanged);
    });
  });

  group('hostile and corrupt recovery data', () {
    test('a corrupt newest manifest offers the previous copy with an explicit warning', () async {
      final session = await open();
      final first = await write(session, 'previous good copy');
      final second = await write(session, 'latest copy');
      File(second.metadataPath).writeAsStringSync('{broken');
      final found = (await recover())!.draft;
      expect(found.generation, first.generation);
      expect(found.issues.map((issue) => issue.code), contains('invalidMetadata'));
      expect(File(second.snapshotPath).existsSync(), isTrue);
      await service.cleanup();
      expect(File(first.snapshotPath).existsSync(), isTrue);
      expect(File(second.snapshotPath).existsSync(), isTrue);
      final resumed = await open(restored: found);
      await write(resumed, 'recovered previous and edited');
      expect(File((await recover())!.draft.snapshotPath).readAsStringSync(), 'recovered previous and edited');
    });

    test('a changed snapshot is not trusted even when its length has not changed', () async {
      final session = await open();
      final first = await write(session, 'safe');
      final second = await write(session, 'edit');
      File(second.snapshotPath).writeAsStringSync('evil');
      final found = (await recover())!.draft;
      expect(found.generation, first.generation);
      expect(found.issues.map((issue) => issue.code), contains('invalidSnapshot'));
    });

    final mutations = <String, void Function(Map<String, dynamic>, File)>{
      'relative snapshot': (json, _) => json['snapshot'] = '../../outside.txt',
      'absolute snapshot': (json, outside) => json['snapshot'] = outside.path,
      'windows snapshot escape': (json, _) => json['snapshot'] = r'..\..\outside.txt',
      'relative source': (json, _) => json['sourcePath'] = 'notes.txt',
      'different source': (json, outside) => json['sourcePath'] = outside.absolute.path,
      'unsafe source name': (json, _) => json['sourceName'] = '../source.txt',
      'unsafe format': (json, _) => json['format'] = '../txt',
      'mismatched format': (json, _) => json['format'] = 'docx',
      'mismatched kind': (json, _) => json['kind'] = 'word',
      'unknown kind': (json, _) => json['kind'] = 'unknown',
      'future schema': (json, _) => json['version'] = 2,
      'wrong generation': (json, _) => json['generation'] = 'elsewhere',
      'wrong sequence': (json, _) => json['sequence'] = 0,
      'invalid payload version': (json, _) => json['payloadVersion'] = 0,
      'invalid source hash': (json, _) => json['sourceFingerprint']['sha256'] = 'not a hash',
      'negative snapshot length': (json, _) => json['snapshotFingerprint']['size'] = -1,
      'unknown metadata field': (json, _) => json['password'] = 'not accepted',
    };
    for (final mutation in mutations.entries) {
      test('rejects ${mutation.key} without reading or deleting the referenced source', () async {
        final session = await open();
        final record = await write(session, 'unsaved');
        final outside = File('${root.path}/outside.txt')..writeAsStringSync('do not touch');
        final json = jsonDecode(File(record.metadataPath).readAsStringSync()) as Map<String, dynamic>;
        mutation.value(json, outside);
        File(record.metadataPath).writeAsStringSync(jsonEncode(json));
        await expectLater(recover(), throwsA(draftError('invalidMetadata')));
        final inventory = await service.listDrafts();
        expect(inventory.drafts, isEmpty);
        expect(inventory.issues, isNotEmpty);
        await service.cleanup();
        expect(outside.readAsStringSync(), 'do not touch');
        expect(source.readAsStringSync(), 'original');
        expect(File(record.snapshotPath).readAsStringSync(), 'unsaved');
      });
    }

    test('bounds metadata size and nesting before JSON decoding', () async {
      final session = await open();
      final record = await write(session, 'safe');
      for (final text in [List.filled(70 * 1024, ' ').join(), '${List.filled(80, '[').join()}0${List.filled(80, ']').join()}']) {
        File(record.metadataPath).writeAsStringSync(text);
        await expectLater(recover(), throwsA(draftError('invalidMetadata')));
        expect(File(record.snapshotPath).readAsStringSync(), 'safe');
      }
    });

    test('cannot accidentally treat a private recovery snapshot as a source', () async {
      final session = await open();
      final record = await write(session, 'safe');
      await expectLater(open(description: document(file: File(record.snapshotPath))), throwsA(draftError('unsafePath')));
    });

    test('linked snapshots are rejected and cleanup never follows their target', () async {
      final session = await open();
      final record = await write(session, 'safe');
      final external = File('${root.path}/external.txt')..writeAsStringSync('external');
      File(record.snapshotPath).deleteSync();
      Link(record.snapshotPath).createSync(external.path);
      await expectLater(recover(), throwsA(draftError('invalidMetadata')));
      await service.cleanup();
      expect(external.readAsStringSync(), 'external');
    }, skip: Platform.isWindows ? 'Creating symbolic links requires Windows developer mode.' : false);

    test('unexpected files are retained and new writes fail honestly', () async {
      final session = await open();
      final first = await write(session, 'safe');
      final unexpected = File('${drafts.path}/unknown.bin')..writeAsStringSync('unknown data');
      await expectLater(write(session, 'new'), throwsA(draftError('unsafePath')));
      final report = await service.cleanup();
      expect(report.overBudget, isTrue);
      expect(report.issues, isNotEmpty);
      expect(unexpected.readAsStringSync(), 'unknown data');
      expect((await recover())!.draft.generation, first.generation);
    });
  });

  group('bounded retention', () {
    test('expired unsaved documents are counted, not silently evicted', () async {
      final session = await open();
      final first = await write(session, 'months of unsaved work');
      now = now.add(const Duration(days: 365));
      final report = await service.cleanup();
      expect(report.oldDrafts, 1);
      expect(report.removedGenerations, 0);
      expect(File(first.snapshotPath).readAsStringSync(), 'months of unsaved work');
      expect((await recover())!.draft.generation, first.generation);
    });

    test('cleans abandoned uncommitted generations only after the orphan grace period', () async {
      final session = await open();
      final record = await write(session, 'committed');
      final parent = File(record.metadataPath).parent.parent;
      final orphan = Directory('${parent.path}/g-0000000000000009-${List.filled(32, 'a').join()}')..createSync();
      File('${orphan.path}/snapshot.txt').writeAsStringSync('partial');
      await service.cleanup();
      expect(orphan.existsSync(), isTrue);
      now = now.add(const Duration(days: 2));
      final report = await service.cleanup();
      expect(report.removedGenerations, 1);
      expect(orphan.existsSync(), isFalse);
      expect((await recover())!.draft.generation, record.generation);
    });

    test('cleared history is removed and cannot be rediscovered after restart', () async {
      final session = await open();
      final first = await write(session, 'one');
      final second = await write(session, 'two');
      final report = await service.discard(session);
      expect(report.removedGenerations, 2);
      expect(File(first.snapshotPath).existsSync(), isFalse);
      expect(File(second.snapshotPath).existsSync(), isFalse);
      expect(await recover(using: DraftService(directory: drafts)), isNull);
      now = now.add(const Duration(days: 31));
      await service.cleanup();
      expect(await recover(using: DraftService(directory: drafts)), isNull);
    });

    test('snapshot limits preserve the previous generation and source', () async {
      final limited = DraftService(directory: drafts, limits: const DraftLimits(maxSnapshotBytes: 8));
      final session = await open(using: limited);
      final first = await write(session, 'small', using: limited);
      await expectLater(write(session, '123456789', using: limited), throwsA(draftError('tooLarge')));
      expect((await recover(using: limited))!.draft.generation, first.generation);
      expect(source.readAsStringSync(), 'original');
    });

    test('total quota refuses another document instead of dropping unsaved work', () async {
      final limited = DraftService(directory: drafts, limits: const DraftLimits(maxTotalBytes: 3000));
      final firstSession = await open(using: limited);
      final first = await write(firstSession, List.filled(1200, 'a').join(), using: limited);
      final other = File('${root.path}/other.txt')..writeAsStringSync('other');
      final secondSession = await open(using: limited, description: document(file: other));
      await expectLater(write(secondSession, List.filled(1200, 'b').join(), using: limited), throwsA(draftError('capacity')));
      expect((await recover(using: limited))!.draft.generation, first.generation);
      expect(await recover(using: limited, file: other), isNull);
      expect((await limited.cleanup()).retainedBytes, lessThanOrEqualTo(3000));
    });

    test('quota may prune a superseded generation only after its replacement commits', () async {
      final limited = DraftService(directory: drafts, limits: const DraftLimits(maxTotalBytes: 3000));
      final session = await open(using: limited);
      final first = await write(session, List.filled(1200, 'a').join(), using: limited);
      final next = await write(session, List.filled(1200, 'b').join(), using: limited);
      expect((await recover(using: limited))!.draft.generation, next.generation);
      expect(File(first.snapshotPath).existsSync(), isFalse);
      expect((await limited.cleanup()).retainedBytes, lessThanOrEqualTo(3000));
    });

    test('document count limits refuse new work before invoking a writer', () async {
      final limited = DraftService(directory: drafts, limits: const DraftLimits(maxDocuments: 1));
      final firstSession = await open(using: limited);
      await write(firstSession, 'one', using: limited);
      final other = File('${root.path}/other.txt')..writeAsStringSync('other');
      final secondSession = await open(using: limited, description: document(file: other));
      var called = false;
      await expectLater(limited.writeSnapshot(secondSession, (path) async {
        called = true;
        await File(path).writeAsString('two');
      }), throwsA(draftError('capacity')));
      expect(called, isFalse);
      expect((await limited.listDrafts()).drafts, hasLength(1));
    });
  });

  group('PDF payload privacy', () {
    Future<DraftSession> pdfSession({int version = 1}) => open(
      description: document(kind: DocKind.pdf, format: 'pdf-edits', payloadVersion: version),
    );

    test('opaque pending JSON round trips without writing a PDF or source', () async {
      final session = await pdfSession();
      final payload = <String, Object?>{
        'items': [{'page': 1, 'text': 'A note', 'points': [1.5, 2.0]}],
        'fields': {'Name': 'Alice'},
        'removals': [42],
        'flatten': false,
      };
      final draft = await service.writePayload(session, payload);
      expect(draft.snapshotPath, endsWith('snapshot.json'));
      expect(await service.readPayload(draft), payload);
      expect((await recover(kind: DocKind.pdf))!.draft.generation, draft.generation);
      expect(source.readAsStringSync(), 'original');
    });

    for (final key in ['password', 'userPassword', 'OWNER_PASSWORD', 'pass-phrase', 'credentials', 'pwd', 'passwd']) {
      test('rejects nested $key before writing even a temporary payload', () async {
        final session = await pdfSession();
        final first = await service.writePayload(session, {'items': <Object>[]});
        final before = drafts.listSync(recursive: true).map((entry) => entry.path).toSet();
        await expectLater(service.writePayload(session, {
          'items': [{'nested': {key: 'never persist this'}}],
        }), throwsA(draftError('unsafePayload')));
        expect(drafts.listSync(recursive: true).map((entry) => entry.path).toSet(), before);
        expect((await recover(kind: DocKind.pdf))!.draft.generation, first.generation);
      });
    }

    test('PDF cannot bypass password validation through a file writer', () async {
      final session = await pdfSession();
      var called = false;
      expect(() => service.writeSnapshot(session, (_) async { called = true; }), throwsA(draftError('unsafePayload')));
      expect(called, isFalse);
    });

    test('rejects cycles, deep nesting, invalid numbers, and custom values', () async {
      final session = await pdfSession();
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      Object? nested = 0;
      for (var i = 0; i < 70; i++) {
        nested = [nested];
      }
      for (final payload in [cyclic, nested, {'x': double.infinity}, {'x': Object()}, {1: 'value'}]) {
        await expectLater(service.writePayload(session, payload), throwsA(isA<DraftException>()));
      }
      expect(await recover(kind: DocKind.pdf), isNull);
    });

    test('payload version must be explicitly supported by the recovering caller', () async {
      final session = await pdfSession(version: 2);
      final draft = await service.writePayload(session, {'v2': true});
      await expectLater(service.readPayload(draft), throwsA(draftError('unsupportedVersion')));
      expect(await service.readPayload(draft, expectedVersion: 2), {'v2': true});
    });

    test('discard during off-thread JSON preparation cannot recreate a draft', () async {
      final session = await pdfSession();
      await service.writePayload(session, {'items': []});
      final pending = service.writePayload(session, {'items': List.filled(30000, 'annotation')});
      final rejected = expectLater(pending, throwsA(draftError('cancelled')));
      await service.discard(session);
      await rejected;
      expect(await recover(kind: DocKind.pdf), isNull);
    });
  });

  group('lifecycle and debounce controller', () {
    test('debounces for three seconds and ignores callbacks from cancelled timers', () async {
      final clock = ManualDraftClock();
      var calls = 0;
      final ctrl = await controller(timer: clock, writer: (path) async {
        calls++;
        await File(path).writeAsString('typing');
      });
      ctrl.markChanged();
      final stale = clock.active.single;
      expect(stale.delay, const Duration(seconds: 3));
      ctrl.markChanged();
      stale.fire(evenIfCancelled: true);
      await ctrl.settled;
      expect(calls, 0);
      clock.fire();
      await ctrl.settled;
      expect(calls, 1);
      expect(ctrl.hasPendingChanges, isTrue);
      expect(ctrl.needsSnapshot, isFalse);
      expect(ctrl.lastError, isNull);
      expect(clock.active, isEmpty);
    });

    test('hidden and paused flush immediately; inactive and repeated flushes do not write', () async {
      final clock = ManualDraftClock();
      var writes = 0;
      final ctrl = await controller(timer: clock, writer: (path) async {
        await File(path).writeAsString('${++writes}');
      });
      ctrl.markChanged();
      ctrl.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await ctrl.settled;
      expect(writes, 0);
      ctrl.didChangeAppLifecycleState(AppLifecycleState.hidden);
      ctrl.didChangeAppLifecycleState(AppLifecycleState.paused);
      await ctrl.settled;
      expect(writes, 1);
      expect(clock.active, isEmpty);
      ctrl.markChanged();
      ctrl.didChangeAppLifecycleState(AppLifecycleState.paused);
      await ctrl.settled;
      expect(writes, 2);
    });

    test('edits arriving during a write schedule another snapshot rather than being marked saved', () async {
      final clock = ManualDraftClock();
      final started = Completer<void>();
      final release = Completer<void>();
      var text = 'first';
      var writes = 0;
      final ctrl = await controller(timer: clock, writer: (path) async {
        final captured = text;
        if (++writes == 1) {
          started.complete();
          await release.future;
        }
        await File(path).writeAsString(captured);
      });
      ctrl.markChanged();
      final first = ctrl.flush();
      await started.future;
      text = 'second';
      ctrl.markChanged();
      release.complete();
      await first;
      expect(ctrl.needsSnapshot, isTrue);
      clock.fire();
      await ctrl.settled;
      expect(writes, 2);
      expect(File(ctrl.latestDraft!.snapshotPath).readAsStringSync(), 'second');
      expect(ctrl.hasPendingChanges, isTrue);
    });

    test('background failure is observable and gets a bounded retry', () async {
      final clock = ManualDraftClock();
      final errors = <Object>[];
      var writes = 0;
      final ctrl = await controller(timer: clock, onError: (error, _) => errors.add(error), writer: (path) async {
        if (++writes == 1) throw StateError('temporary failure');
        await File(path).writeAsString('retry');
      });
      ctrl.markChanged();
      clock.fire();
      await ctrl.settled;
      expect(ctrl.lastError, isA<StateError>());
      expect(ctrl.needsSnapshot, isTrue);
      expect(errors, hasLength(1));
      expect(clock.active.single.delay, const Duration(seconds: 30));
      clock.fire();
      await ctrl.settled;
      expect(writes, 2);
      expect(ctrl.lastError, isNull);
      expect(ctrl.needsSnapshot, isFalse);
      expect(File(ctrl.latestDraft!.snapshotPath).readAsStringSync(), 'retry');
    });

    test('repeated failure stops automatic retries but a new edit can retry', () async {
      final clock = ManualDraftClock();
      var writes = 0;
      final ctrl = await controller(timer: clock, maxRetries: 1, writer: (_) async {
        writes++;
        throw StateError('still full');
      });
      ctrl.markChanged();
      clock.fire();
      await ctrl.settled;
      clock.fire();
      await ctrl.settled;
      expect(writes, 2);
      expect(clock.active, isEmpty);
      expect(ctrl.needsSnapshot, isTrue);
      ctrl.markChanged();
      expect(clock.active, hasLength(1));
    });

    test('successful user save drains the writer and invalidates every old timer', () async {
      final clock = ManualDraftClock();
      final started = Completer<void>();
      final release = Completer<void>();
      var writing = false;
      var calls = 0;
      final ctrl = await controller(timer: clock, writer: (path) async {
        writing = true;
        calls++;
        started.complete();
        await release.future;
        await File(path).writeAsString('copied');
        writing = false;
      });
      ctrl.markChanged();
      final staleTimer = clock.active.single;
      final flush = ctrl.flush();
      await started.future;
      var saveCalled = false;
      final saved = ctrl.runUserSave(() async {
        expect(writing, isFalse);
        saveCalled = true;
        source.writeAsStringSync('saved');
        return 'published';
      });
      staleTimer.fire(evenIfCancelled: true);
      expect(saveCalled, isFalse);
      release.complete();
      await flush;
      expect(await saved, 'published');
      staleTimer.fire(evenIfCancelled: true);
      ctrl.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await ctrl.settled;
      expect(calls, 1);
      expect(ctrl.hasPendingChanges, isFalse);
      expect(ctrl.needsSnapshot, isFalse);
      expect(await recover(), isNull);
      expect(clock.active, isEmpty);
    });

    test('failed user save preserves the draft until the full save operation succeeds', () async {
      final clock = ManualDraftClock();
      final ctrl = await controller(timer: clock);
      ctrl.markChanged();
      final draft = (await ctrl.flush())!;
      await expectLater(ctrl.runUserSave(() async {
        source.writeAsStringSync('working file saved, public copy failed');
        throw StateError('public copy failed');
      }), throwsStateError);
      expect(ctrl.hasPendingChanges, isTrue);
      expect(File(draft.snapshotPath).existsSync(), isTrue);
      expect((await recover())!.draft.generation, draft.generation);
      await ctrl.runUserSave(() async {});
      expect(await recover(), isNull);
      expect(ctrl.hasPendingChanges, isFalse);
    });

    test('edits made during user save remain dirty and receive their own snapshot', () async {
      final clock = ManualDraftClock();
      var text = 'before';
      final ctrl = await controller(timer: clock, writer: (path) async {
        await File(path).writeAsString(text);
      });
      ctrl.markChanged();
      final previous = (await ctrl.flush())!;
      final saving = Completer<void>();
      final release = Completer<void>();
      final save = ctrl.runUserSave(() async {
        saving.complete();
        await release.future;
        source.writeAsStringSync('before');
      });
      await saving.future;
      text = 'after';
      ctrl.markChanged();
      release.complete();
      await save;
      expect(ctrl.hasPendingChanges, isTrue);
      expect(File(previous.snapshotPath).existsSync(), isTrue);
      expect(ctrl.needsSnapshot, isTrue);
      clock.fire();
      await ctrl.settled;
      expect(File(ctrl.latestDraft!.snapshotPath).readAsStringSync(), 'after');
      expect((await recover())!.sourceState, DraftSourceState.unchanged);
    });

    test('discard cancels queued flushes and timers without recreating a draft', () async {
      final clock = ManualDraftClock();
      var writes = 0;
      final ctrl = await controller(timer: clock, writer: (path) async {
        writes++;
        await File(path).writeAsString('draft');
      });
      ctrl.markChanged();
      await ctrl.flush();
      ctrl.markChanged();
      final old = clock.active.single;
      final queued = ctrl.flush();
      final discarded = ctrl.runUserDiscard();
      old.fire(evenIfCancelled: true);
      await queued;
      await discarded;
      old.fire(evenIfCancelled: true);
      await ctrl.settled;
      expect(writes, 1);
      expect(await recover(), isNull);
      expect(ctrl.hasPendingChanges, isFalse);
    });

    test('a failed explicit discard action keeps the old draft', () async {
      final ctrl = await controller(timer: ManualDraftClock());
      ctrl.markChanged();
      final previous = (await ctrl.flush())!;
      await expectLater(ctrl.runUserDiscard(discardChanges: () async {
        throw StateError('failed to reload');
      }), throwsStateError);
      expect(ctrl.hasPendingChanges, isTrue);
      expect((await recover())!.draft.generation, previous.generation);
    });

    test('new edits during discard are not silently cleared', () async {
      final clock = ManualDraftClock();
      final ctrl = await controller(timer: clock);
      ctrl.markChanged();
      final previous = (await ctrl.flush())!;
      await expectLater(ctrl.runUserDiscard(discardChanges: () async {
        ctrl.markChanged();
      }), throwsA(draftError('editsDuringDiscard')));
      expect(ctrl.hasPendingChanges, isTrue);
      expect((await recover())!.draft.generation, previous.generation);
    });

    test('restored sessions remain dirty without rewriting their recovery copy', () async {
      final session = await open();
      final record = await write(session, 'restored');
      final clock = ManualDraftClock();
      final ctrl = await controller(timer: clock, restored: (await recover())!.draft);
      expect(ctrl.hasPendingChanges, isTrue);
      expect(ctrl.needsSnapshot, isFalse);
      expect(ctrl.latestDraft!.generation, record.generation);
      ctrl.didChangeAppLifecycleState(AppLifecycleState.paused);
      await ctrl.settled;
      expect(ctrl.latestDraft!.generation, record.generation);
      expect(clock.active, isEmpty);
    });

    test('dispose cancels timers and drains active writers without deleting a draft', () async {
      final clock = ManualDraftClock();
      final started = Completer<void>();
      final release = Completer<void>();
      final ctrl = await controller(timer: clock, writer: (path) async {
        started.complete();
        await release.future;
        await File(path).writeAsString('last snapshot');
      });
      ctrl.markChanged();
      final timer = clock.active.single;
      final pending = ctrl.flush();
      await started.future;
      ctrl.dispose();
      timer.fire(evenIfCancelled: true);
      release.complete();
      await pending;
      await ctrl.settled;
      expect(clock.active, isEmpty);
      expect(File((await recover())!.draft.snapshotPath).readAsStringSync(), 'last snapshot');
    });

    testWidgets('binding lifecycle flushes a real controller and removal unregisters it', (tester) async {
      late DraftController ctrl;
      var writes = 0;
      await tester.runAsync(() async {
        ctrl = await controller(observeLifecycle: true, writer: (path) async {
          writes++;
          await File(path).writeAsString('background recovery');
        });
      });
      await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SizedBox()));
      await tester.runAsync(() async {
        ctrl.markChanged();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await ctrl.settled;
      });
      await tester.pump();
      expect(writes, 1);
      expect(ctrl.latestDraft, isNotNull);
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await ctrl.settled;
      });
      expect(writes, 1);
      await tester.runAsync(() async {
        ctrl.markChanged();
        ctrl.dispose();
        await ctrl.settled;
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 4));
      expect(writes, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });
}
