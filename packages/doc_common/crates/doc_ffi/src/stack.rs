//! The stack backstop: engine calls run on a thread with a large stack.
//!
//! Dart calls into an engine on its isolate's thread, whose stack is about
//! 1 MB (512 KB on 32-bit phones). Reading a deeply nested document can need
//! more than that, and running out of stack is not a panic that can be
//! caught: it ends the app. So each call runs on a worker thread with a
//! [`CALL_STACK_BYTES`] stack while the calling thread waits for it.
//!
//! Starting a thread for every call was measured at 60 µs back to back and
//! 180 to 260 µs for calls a frame apart (0.7 ms when the call used 1 MB of
//! the fresh stack, whose pages each fault in), too much for the calls made
//! while scrolling. So each calling thread keeps one worker. Both spin for a
//! moment before they sleep, so handing over a call to a worker that has
//! just finished one costs under a microsecond; waking a worker that has
//! gone to sleep costs what the system takes to wake a thread (60 to 150 µs
//! on the machine measured). A worker ends with its calling thread, or after
//! [`IDLE_EXIT`] without a call; the calling thread starts another when it
//! next needs one.
//!
//! The call runs on another thread, so it must not depend on the calling
//! thread's thread-locals. The only one the engines have is the last error,
//! which the wrappers in this crate set on the calling thread after the
//! call returns.

use std::cell::{Cell, RefCell, UnsafeCell};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::thread::Thread;
use std::time::{Duration, Instant};

/// The stack each call runs on.
pub const CALL_STACK_BYTES: usize = 16 << 20;

/// How long a thread spins before it sleeps while waiting for the other.
const SPIN: Duration = Duration::from_micros(50);

/// How long a worker waits for a call before it ends.
pub(crate) const IDLE_EXIT: Duration = if cfg!(test) {
    Duration::from_millis(300)
} else {
    Duration::from_secs(20)
};

/// The worker is ready for a call.
const IDLE: u32 = 0;
/// A call is waiting for the worker, or running on it.
const CALL: u32 = 1;
/// The call has returned; the calling thread has not seen it yet.
const DONE: u32 = 2;
/// The worker has ended, or must end.
const GONE: u32 = 3;

/// A call lent to the worker. Its real lifetime is that of the calling
/// thread's borrow, which outlasts every use (see [`hand_over`]).
type CallPtr = *mut (dyn FnMut() + 'static);

/// Where a calling thread and its worker meet.
struct Slot {
    state: AtomicU32,
    /// The call to run; written by the calling thread before it sets
    /// [`CALL`], read by the worker only after it sees [`CALL`].
    call: UnsafeCell<Option<CallPtr>>,
}

// SAFETY: `call` is only touched by one thread at a time, as the state
// says: the calling thread while it is IDLE (or GONE), the worker while it
// is CALL.
unsafe impl Send for Slot {}
unsafe impl Sync for Slot {}

/// A calling thread's handle on its worker. Dropping it (when the calling
/// thread ends) tells the worker to end.
struct Worker {
    slot: Arc<Slot>,
    thread: Thread,
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.slot.state.store(GONE, Ordering::Release);
        self.thread.unpark();
    }
}

impl Worker {
    fn start() -> Option<Worker> {
        let slot = Arc::new(Slot {
            state: AtomicU32::new(IDLE),
            call: UnsafeCell::new(None),
        });
        let shared = Arc::clone(&slot);
        let caller = std::thread::current();
        let handle = std::thread::Builder::new()
            .name("engine call".into())
            .stack_size(CALL_STACK_BYTES)
            .spawn(move || serve(&shared, &caller))
            .ok()?;
        Some(Worker {
            thread: handle.thread().clone(),
            slot,
        })
    }
}

thread_local! {
    /// This thread's worker, started on its first call.
    static WORKER: RefCell<Option<Worker>> = const { RefCell::new(None) };
    /// Whether this thread is a worker, so that a call made from inside a
    /// call runs where it is.
    static IS_WORKER: Cell<bool> = const { Cell::new(false) };
}

/// The worker's loop: wait for a call, run it, say it is done.
fn serve(slot: &Slot, caller: &Thread) {
    IS_WORKER.with(|w| w.set(true));
    loop {
        let idle_since = Instant::now();
        loop {
            match slot.state.load(Ordering::Acquire) {
                CALL => break,
                GONE => return,
                _ => {}
            }
            let idle = idle_since.elapsed();
            if idle < SPIN {
                std::hint::spin_loop();
            } else if idle < IDLE_EXIT {
                std::thread::park_timeout(IDLE_EXIT - idle);
            } else if slot
                .state
                .compare_exchange(IDLE, GONE, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                // Idle for too long; a call that comes later starts a new
                // worker.
                return;
            }
        }
        // SAFETY: the state is CALL, so the calling thread wrote the call
        // and is waiting for DONE.
        if let Some(call) = unsafe { *slot.call.get() } {
            // The calls given to `hand_over` catch their own panics; this
            // only keeps the worker alive if one does not.
            let _ = catch_unwind(AssertUnwindSafe(|| unsafe { (*call)() }));
        }
        slot.state.store(DONE, Ordering::Release);
        caller.unpark();
    }
}

/// Run `call` on this thread's worker and wait for it. Returns false when
/// it did not run there (this thread is a worker itself, a worker could not
/// be started, or the thread is ending), and the caller should run it here.
pub(crate) fn hand_over(call: &mut dyn FnMut()) -> bool {
    if IS_WORKER.with(Cell::get) {
        return false;
    }
    // SAFETY: only the lifetime is changed. The worker uses the pointer
    // while the state is CALL, and this function does not return until the
    // state is DONE, so the borrow outlives every use.
    let call: *mut (dyn FnMut() + '_) = call;
    let ptr: CallPtr = unsafe { std::mem::transmute::<*mut (dyn FnMut() + '_), CallPtr>(call) };
    WORKER
        .try_with(|cell| {
            let Ok(mut worker) = cell.try_borrow_mut() else {
                return false;
            };
            // A worker that ended while idle is replaced; so is one that ends
            // just as this call reaches it.
            for _ in 0..2 {
                if worker.as_ref().is_none_or(|w| w.slot.state.load(Ordering::Acquire) == GONE) {
                    *worker = Worker::start();
                }
                let Some(w) = worker.as_ref() else {
                    return false;
                };
                // SAFETY: the state is IDLE or GONE, so the worker is not
                // reading the call.
                unsafe { *w.slot.call.get() = Some(ptr) };
                if w
                    .slot
                    .state
                    .compare_exchange(IDLE, CALL, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    unsafe { *w.slot.call.get() = None };
                    continue;
                }
                w.thread.unpark();
                let waiting_since = Instant::now();
                while w.slot.state.load(Ordering::Acquire) != DONE {
                    if waiting_since.elapsed() < SPIN {
                        std::hint::spin_loop();
                    } else {
                        std::thread::park();
                    }
                }
                // SAFETY: the state is DONE: the worker is finished with it.
                unsafe { *w.slot.call.get() = None };
                w.slot.state.store(IDLE, Ordering::Release);
                return true;
            }
            false
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{call_i64, call_str, last_error, FfiError};
    use std::sync::mpsc;

    /// The stack of a Dart isolate's thread on a 32-bit phone.
    const SMALL_STACK: usize = 512 << 10;

    /// Run `f` on a new thread with a [`SMALL_STACK`], failing the test if
    /// it takes more than 20 seconds (a hand-over that never completes).
    fn on_small_stack<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
        let (send, receive) = mpsc::channel();
        std::thread::Builder::new()
            .name("small stack".into())
            .stack_size(SMALL_STACK)
            .spawn(move || {
                let _ = send.send(f());
            })
            .unwrap();
        receive.recv_timeout(Duration::from_secs(20)).expect("the calls did not finish in time")
    }

    /// Recurse `depth` times with a frame of over 1 KB each (several in a
    /// debug build), as a parser reading a deeply nested document might.
    #[inline(never)]
    fn deep(depth: u32) -> u64 {
        let mut frame = [0u8; 1024];
        frame[depth as usize % frame.len()] = depth as u8;
        let frame = std::hint::black_box(frame);
        if depth == 0 {
            return 0;
        }
        deep(depth - 1) + u64::from(frame[depth as usize % frame.len()])
    }

    fn worker_thread() -> std::thread::ThreadId {
        let mut id = None;
        assert!(hand_over(&mut || id = Some(std::thread::current().id())));
        id.unwrap()
    }

    /// Wait up to two seconds for `done`.
    fn eventually(mut done: impl FnMut() -> bool) -> bool {
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            if done() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn a_call_deeper_than_the_callers_stack_completes() {
        // 2 to 6 MB of stack, called from a 512 KB thread: without the
        // backstop the process dies of a stack overflow.
        let expected: u64 = (1..=2000u32).map(|d| u64::from(d as u8)).sum();
        let got = on_small_stack(|| call_i64(|| Ok(deep(2000) as i64)));
        assert_eq!(got, expected as i64);
        // Repeated deep calls reuse the worker's stack.
        let got = on_small_stack(|| (0..20).map(|_| call_i64(|| Ok(deep(2000) as i64))).sum::<i64>());
        assert_eq!(got, 20 * expected as i64);
    }

    #[test]
    fn calls_run_on_the_worker_and_errors_reach_the_caller() {
        let (name, nested, error, flagged) = on_small_stack(|| {
            let name = call_str(|| Ok(std::thread::current().name().unwrap_or_default().to_owned()));
            let name = unsafe { std::ffi::CStr::from_ptr(name) }.to_string_lossy().into_owned();
            // A call made from inside a call runs where it is.
            let nested = call_i64(|| {
                let outer = std::thread::current().id();
                Ok(call_i64(|| Ok(i64::from(std::thread::current().id() == outer))))
            });
            // The error is the calling thread's, set after the call returns.
            assert!(call_str(|| Err(FfiError::invalid("bad input"))).is_null());
            let flagged = call_i64(|| Ok(i64::from(IS_WORKER.with(Cell::get))));
            (name, nested, last_error(), flagged)
        });
        assert_eq!(name, "engine call");
        assert_eq!(nested, 1);
        assert_eq!(error, "INVALID_ARGUMENT: bad input");
        assert_eq!(flagged, 1);
        assert_eq!(last_error(), "", "another thread's error is not this one's");
    }

    #[test]
    fn calls_borrow_the_callers_data() {
        let total = on_small_stack(|| {
            let numbers: Vec<i64> = (1..=1000).collect();
            let mut seen = Vec::new();
            let total = call_i64(|| {
                seen.extend_from_slice(&numbers[..3]);
                Ok(numbers.iter().sum())
            });
            assert_eq!(seen, [1, 2, 3]);
            total
        });
        assert_eq!(total, 500_500);
    }

    #[test]
    fn a_worker_survives_a_panic() {
        let (before, panicked, error, after, answer) = on_small_stack(|| {
            let before = worker_thread();
            let panicked = call_i64(|| panic!("boom"));
            let error = last_error();
            (before, panicked, error, worker_thread(), call_i64(|| Ok(42)))
        });
        assert_eq!((panicked, error.as_str()), (-1, "PANIC: boom"));
        assert_eq!(before, after, "the same worker serves the next call");
        assert_eq!(answer, 42);
    }

    #[test]
    fn an_idle_worker_ends_and_the_next_call_starts_another() {
        let (first, ended, second, answer) = on_small_stack(|| {
            let first = worker_thread();
            let slot = WORKER.with(|w| Arc::clone(&w.borrow().as_ref().unwrap().slot));
            std::thread::sleep(IDLE_EXIT + Duration::from_millis(100));
            // The worker has gone, and dropped its share of the slot.
            let ended = eventually(|| slot.state.load(Ordering::Acquire) == GONE && Arc::strong_count(&slot) == 2);
            (first, ended, worker_thread(), call_i64(|| Ok(7)))
        });
        assert!(ended, "an idle worker ends");
        assert_ne!(first, second, "a new worker serves the next call");
        assert_eq!(answer, 7);
    }

    #[test]
    fn a_worker_ends_with_its_calling_thread() {
        let slot = on_small_stack(|| {
            assert_eq!(call_i64(|| Ok(1)), 1);
            WORKER.with(|w| Arc::clone(&w.borrow().as_ref().unwrap().slot))
        });
        // Only this test's copy is left once both threads have ended.
        assert!(eventually(|| Arc::strong_count(&slot) == 1), "the worker ended");
        assert_eq!(slot.state.load(Ordering::Acquire), GONE);
    }

    #[test]
    fn many_calling_threads_each_get_their_own_answers() {
        let threads: Vec<_> = (0..8i64)
            .map(|t| {
                let (send, receive) = mpsc::channel();
                std::thread::Builder::new()
                    .stack_size(SMALL_STACK)
                    .spawn(move || {
                        let mut sum = 0;
                        for i in 0..2000i64 {
                            let value = call_i64(|| Ok(t * 1_000_000 + i));
                            assert_eq!(value, t * 1_000_000 + i);
                            sum += value;
                        }
                        let _ = send.send(sum);
                    })
                    .unwrap();
                receive
            })
            .collect();
        for (t, receive) in threads.into_iter().enumerate() {
            let sum = receive.recv_timeout(Duration::from_secs(30)).expect("a thread's calls did not finish");
            let t = t as i64;
            assert_eq!(sum, (0..2000).map(|i| t * 1_000_000 + i).sum::<i64>());
        }
    }
}
