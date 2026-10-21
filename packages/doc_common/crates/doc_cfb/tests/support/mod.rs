//! Bounds for the hostile-input tests: an allocator that counts the bytes
//! each thread holds and refuses to let one thread hold more than its
//! limit, a runner that gives a test a 512 KiB stack and a deadline, and
//! the xorshift mutator the fuzzing loops use.
//!
//! The limit stands in for `prlimit --as`: an allocation past it fails, so
//! a decoder that asks for too much aborts the test (or, through
//! `try_reserve`, reports the picture too large) instead of exhausting the
//! machine.

#![allow(dead_code)]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::mpsc;
use std::time::{Duration, Instant};

struct Counting;

thread_local! {
    static HELD: Cell<usize> = const { Cell::new(0) };
    static PEAK: Cell<usize> = const { Cell::new(0) };
    static LIMIT: Cell<usize> = const { Cell::new(usize::MAX) };
}

fn grow(n: usize) -> bool {
    HELD.try_with(|h| {
        let v = h.get().saturating_add(n);
        if v > LIMIT.try_with(Cell::get).unwrap_or(usize::MAX) {
            return false;
        }
        h.set(v);
        let _ = PEAK.try_with(|p| p.set(p.get().max(v)));
        true
    })
    .unwrap_or(true)
}

fn shrink(n: usize) {
    let _ = HELD.try_with(|h| h.set(h.get().saturating_sub(n)));
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        if !grow(l.size()) {
            return std::ptr::null_mut();
        }
        let p = System.alloc(l);
        if p.is_null() {
            shrink(l.size());
        }
        p
    }

    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        if !grow(l.size()) {
            return std::ptr::null_mut();
        }
        let p = System.alloc_zeroed(l);
        if p.is_null() {
            shrink(l.size());
        }
        p
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l);
        shrink(l.size());
    }

    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        if new > l.size() && !grow(new - l.size()) {
            return std::ptr::null_mut();
        }
        let q = System.realloc(p, l, new);
        if q.is_null() {
            if new > l.size() {
                shrink(new - l.size());
            }
        } else if new < l.size() {
            shrink(l.size() - new);
        }
        q
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// What a bounded run measured.
#[derive(Debug)]
pub struct Run<T> {
    pub value: T,
    /// The most bytes the run's thread held at once.
    pub peak: usize,
    pub time: Duration,
}

/// Run `f` on a thread with a 512 KiB stack that may hold at most
/// `max_bytes`, and fail the test unless it finishes within `limit`.
pub fn bounded<T: Send + 'static>(name: &str, max_bytes: usize, limit: Duration, f: impl FnOnce() -> T + Send + 'static) -> Run<T> {
    let (tx, rx) = mpsc::channel();
    let start = Instant::now();
    std::thread::Builder::new()
        .name(name.into())
        .stack_size(512 * 1024)
        .spawn(move || {
            LIMIT.with(|l| l.set(max_bytes));
            let value = f();
            let peak = PEAK.with(Cell::get);
            let _ = tx.send((value, peak));
        })
        .expect("a thread");
    match rx.recv_timeout(limit) {
        Ok((value, peak)) => Run { value, peak, time: start.elapsed() },
        Err(mpsc::RecvTimeoutError::Timeout) => panic!("{name}: still running after {limit:?}"),
        Err(mpsc::RecvTimeoutError::Disconnected) => panic!("{name}: panicked"),
    }
}

/// Run `f` under the hostile-input bounds: 512 KiB of stack, 256 MB of
/// memory and 2 s, the bounds the hostile files must finish within.
pub fn hostile<T: Send + 'static>(name: &str, f: impl FnOnce() -> T + Send + 'static) -> Run<T> {
    let run = bounded(name, 256 << 20, Duration::from_secs(2), f);
    eprintln!("{name}: {:?}, peak {} KB", run.time, run.peak / 1024);
    run
}

/// A xorshift64 generator: the same seed gives the same mutations.
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
}

/// Values that tend to reach edge cases when written over a field.
const INTERESTING: [u32; 12] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF];

/// A mutated copy of `seed`: a few bytes flipped, fields overwritten with
/// edge values, pieces cut, repeated or spliced from `other`.
pub fn mutate(rng: &mut Rng, seed: &[u8], other: &[u8]) -> Vec<u8> {
    let mut b = seed.to_vec();
    for _ in 0..1 + rng.below(4) {
        if b.is_empty() {
            b.push(rng.next() as u8);
        }
        let at = rng.below(b.len());
        match rng.below(8) {
            0 => b[at] ^= 1 << rng.below(8),
            1 => b[at] = rng.next() as u8,
            2 | 3 => {
                let v = INTERESTING[rng.below(INTERESTING.len())].to_le_bytes();
                let n = [1, 2, 4][rng.below(3)];
                for (k, byte) in v.iter().take(n).enumerate() {
                    if let Some(x) = b.get_mut(at + k) {
                        *x = *byte;
                    }
                }
            }
            4 => b.truncate(at),
            5 => {
                let n = rng.below(64).min(b.len() - at);
                b.drain(at..at + n);
            }
            6 => {
                let n = rng.below(64).min(b.len() - at);
                let piece = b[at..at + n].to_vec();
                for _ in 0..1 + rng.below(8) {
                    b.splice(at..at, piece.iter().copied());
                }
            }
            _ => {
                if !other.is_empty() {
                    let from = rng.below(other.len());
                    let n = rng.below(256).min(other.len() - from);
                    b.splice(at..at, other[from..from + n].iter().copied());
                }
            }
        }
    }
    b
}
