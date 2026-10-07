import 'dart:async';
import 'dart:collection';

/// Runs at most [maxConcurrent] tasks at a time. Waiting tasks start in the
/// order they asked, so a page list or a grid fills in reading order rather
/// than at random.
///
/// A task that is no longer wanted by the time its slot arrives (its page
/// scrolled away) should check for that first thing and return early; its
/// slot then passes straight to the next task.
class AsyncLimiter {
  AsyncLimiter(this.maxConcurrent) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  /// Tasks running now; at most [maxConcurrent].
  int get active => _active;

  /// Tasks waiting for a slot.
  int get waiting => _waiting.length;

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // Hand the slot straight to the next waiter rather than decrementing;
      // otherwise a burst of new callers could jump the queue.
      _waiting.removeFirst().complete();
      return;
    }
    if (_active > 0) _active--;
  }
}
