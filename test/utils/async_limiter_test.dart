import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/utils/async_limiter.dart';

void main() {
  test('never runs more tasks at once than allowed', () async {
    final limiter = AsyncLimiter(2);
    final gates = List.generate(5, (_) => Completer<void>());
    var running = 0;
    var peak = 0;
    final done = [
      for (final gate in gates)
        limiter.run(() async {
          running++;
          peak = running > peak ? running : peak;
          await gate.future;
          running--;
        }),
    ];
    await pumpEventQueue();
    expect(limiter.active, 2);
    expect(limiter.waiting, 3);
    for (final gate in gates) {
      gate.complete();
      await pumpEventQueue();
    }
    await Future.wait(done);
    expect(peak, 2);
    expect(limiter.active, 0);
    expect(limiter.waiting, 0);
  });

  test('starts waiting tasks in the order they asked', () async {
    final limiter = AsyncLimiter(1);
    final blocker = Completer<void>();
    final started = <int>[];
    final first = limiter.run(() => blocker.future);
    final rest = [
      for (var i = 0; i < 4; i++)
        limiter.run(() async => started.add(i)),
    ];
    await pumpEventQueue();
    expect(started, isEmpty);
    blocker.complete();
    await first;
    await Future.wait(rest);
    expect(started, [0, 1, 2, 3]);
  });

  test('a failing or skipped task hands its slot to the next', () async {
    final limiter = AsyncLimiter(1);
    final failing = limiter.run<void>(() async => throw StateError('boom'));
    final skipped = limiter.run(() async => null);
    final last = limiter.run(() async => 'ran');
    await expectLater(failing, throwsStateError);
    expect(await skipped, isNull);
    expect(await last, 'ran');
    expect(limiter.active, 0);
  });
}
