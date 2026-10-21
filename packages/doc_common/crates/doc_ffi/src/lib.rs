//! Shared plumbing for the engines' FFI layers, written in Rust.
//!
//! `extern "C"` on the exported functions is only the calling convention
//! `dart:ffi` uses; there is no C code in DocHelper.
//!
//! Every DocHelper engine library exposes `extern "C"` functions to Dart
//! with the same conventions as the PDF engine:
//!
//! * Strings are UTF-8 and NUL-terminated. Strings returned to the caller
//!   are owned by it and released with the library's `*_free_string`.
//! * Integer-returning calls return a negative value on failure; pointer
//!   calls return NULL. The library's `*_last_error` then returns
//!   `"CODE: message"`, valid until the next call on the same thread.
//! * Panics never cross the boundary: they become a `PANIC` error.
//! * Every call runs on a thread with a 16 MB stack, so a deeply nested
//!   document cannot overflow the caller's small one (see [`CALL_STACK_BYTES`]).
//! * Documents being edited live in a [`Registry`] of sessions, addressed by
//!   positive integer handles. A session that a panic interrupted can only
//!   be closed.
//! * Files are saved so that the one replaced is never damaged
//!   ([`save_verified`], [`write_file_atomically`]).
//!
//! This crate holds that plumbing once; each library's FFI crate only
//! declares its exported functions.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

mod files;
mod stack;

pub use files::{
    backup_dir, read_file, remove_stale_temp_files, remove_stale_temp_files_c, save_verified, set_backup_dir,
    set_backup_dir_c, write_file_atomically, BACKUP_CAP_BYTES,
};
pub use stack::CALL_STACK_BYTES;

/// Stable error codes. The Dart side switches on these, so never rename one.
pub mod codes {
    pub const ERROR: &str = "ERROR";
    pub const IO: &str = "IO";
    pub const INVALID_ARGUMENT: &str = "INVALID_ARGUMENT";
    pub const BAD_HANDLE: &str = "BAD_HANDLE";
    pub const UNSUPPORTED: &str = "UNSUPPORTED";
    pub const ENCRYPTED: &str = "ENCRYPTED";
    pub const WRONG_PASSWORD: &str = "WRONG_PASSWORD";
    pub const CORRUPT: &str = "CORRUPT";
    pub const TOO_LARGE: &str = "TOO_LARGE";
    pub const NOT_FOUND: &str = "NOT_FOUND";
    pub const PANIC: &str = "PANIC";
}

/// An error crossing the boundary: a stable code and a readable message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiError {
    pub code: &'static str,
    pub message: String,
}

impl FfiError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(codes::INVALID_ARGUMENT, message)
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(codes::UNSUPPORTED, message)
    }

    pub fn corrupt(message: impl Into<String>) -> Self {
        Self::new(codes::CORRUPT, message)
    }

    /// An I/O failure on `path`, worded for a person.
    pub fn io(path: &str, error: &std::io::Error) -> Self {
        let what = match error.kind() {
            std::io::ErrorKind::NotFound => "the file does not exist".to_owned(),
            std::io::ErrorKind::PermissionDenied => "permission was denied".to_owned(),
            std::io::ErrorKind::StorageFull => "the device is out of space".to_owned(),
            _ => error.to_string(),
        };
        let name = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_owned());
        Self::new(codes::IO, format!("{name}: {what}"))
    }
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for FfiError {}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

/// Record `error` as this thread's last error.
pub fn set_last_error(error: &FfiError) {
    let text = error.to_string().replace('\0', " ");
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new(text).unwrap_or_default());
}

/// Borrowed pointer to this thread's last error (`""` when there is none).
pub fn last_error_ptr() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// The last error as text (for tests).
pub fn last_error() -> String {
    LAST_ERROR.with(|slot| slot.borrow().to_string_lossy().into_owned())
}

/// Read a string argument.
///
/// # Safety
/// `ptr` must be NULL or a valid NUL-terminated string.
pub unsafe fn str_arg<'a>(ptr: *const c_char, what: &str) -> Result<&'a str, FfiError> {
    if ptr.is_null() {
        return Err(FfiError::invalid(format!("{what} is missing")));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|_| FfiError::invalid(format!("{what} is not valid UTF-8")))
}

/// Read an optional string argument: NULL and `""` are `None`.
///
/// # Safety
/// `ptr` must be NULL or a valid NUL-terminated string.
pub unsafe fn opt_str_arg<'a>(ptr: *const c_char, what: &str) -> Result<Option<&'a str>, FfiError> {
    if ptr.is_null() {
        return Ok(None);
    }
    let text = str_arg(ptr, what)?;
    Ok(Some(text).filter(|t| !t.is_empty()))
}

/// Hand a string to the caller, who frees it with [`free_c_string`].
pub fn into_c_string(text: String) -> *mut c_char {
    CString::new(text.replace('\0', " "))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Free a string made by [`into_c_string`].
///
/// # Safety
/// `ptr` must be NULL or a pointer returned by [`into_c_string`] that has
/// not been freed.
pub unsafe fn free_c_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_owned()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "internal error".to_owned()
    }
}

fn guarded<T>(f: impl FnOnce() -> Result<T, FfiError>) -> Result<T, FfiError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(payload) => Err(FfiError::new(codes::PANIC, panic_message(payload))),
    }
}

/// Run `f` on this thread's worker, which has a [`CALL_STACK_BYTES`]
/// stack, with panics caught, and hand back its result; run it here when
/// there is no worker to run it on.
fn on_call_stack<T>(f: impl FnOnce() -> Result<T, FfiError>) -> Result<T, FfiError> {
    let mut f = Some(f);
    let mut result = None;
    stack::hand_over(&mut || {
        if let Some(f) = f.take() {
            result = Some(guarded(f));
        }
    });
    match (result, f) {
        (Some(result), _) => result,
        (None, Some(f)) => guarded(f),
        (None, None) => Err(FfiError::new(codes::PANIC, "the call ended without a result")),
    }
}

/// Run a call that returns a string: NULL and a last error on failure.
pub fn call_str(f: impl FnOnce() -> Result<String, FfiError>) -> *mut c_char {
    match on_call_stack(f) {
        Ok(text) => into_c_string(text),
        Err(e) => {
            set_last_error(&e);
            std::ptr::null_mut()
        }
    }
}

/// Run a call that returns a non-negative integer: -1 and a last error on
/// failure.
pub fn call_i64(f: impl FnOnce() -> Result<i64, FfiError>) -> i64 {
    match on_call_stack(f) {
        Ok(value) => value,
        Err(e) => {
            set_last_error(&e);
            -1
        }
    }
}

/// Run a call that returns bytes: the buffer (freed with [`free_buffer`])
/// and its length in `out_len`, or NULL and a last error on failure.
///
/// # Safety
/// `out_len` must be NULL or valid for a write.
pub unsafe fn call_buffer(f: impl FnOnce() -> Result<Vec<u8>, FfiError>, out_len: *mut i64) -> *mut u8 {
    match on_call_stack(f) {
        Ok(bytes) => {
            let boxed = bytes.into_boxed_slice();
            if !out_len.is_null() {
                *out_len = boxed.len() as i64;
            }
            Box::into_raw(boxed) as *mut u8
        }
        Err(e) => {
            set_last_error(&e);
            if !out_len.is_null() {
                *out_len = 0;
            }
            std::ptr::null_mut()
        }
    }
}

/// Free a buffer returned through [`call_buffer`].
///
/// # Safety
/// `ptr`/`len` must come from [`call_buffer`] and not have been freed.
pub unsafe fn free_buffer(ptr: *mut u8, len: i64) {
    if !ptr.is_null() && len >= 0 {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len as usize)));
    }
}

/// Open documents, addressed by handles that start at 1.
///
/// Each session has its own lock, so different documents can be worked on
/// from different threads at once, while calls on one document serialize.
/// A panic while a session is locked may have left it half-changed, so from
/// then on [`Registry::with`] refuses it, and only closing it works: a
/// half-made edit is never saved over the user's file.
pub struct Registry<T> {
    inner: Mutex<RegistryInner<T>>,
}

struct RegistryInner<T> {
    next: u64,
    sessions: BTreeMap<u64, Arc<Mutex<T>>>,
}

/// Why a session a panic interrupted is refused.
const INTERRUPTED: &str = "an error interrupted a change to this document, so it can no longer be edited or \
                           saved (the file itself was not touched); reopen the document";

impl<T> Default for Registry<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Registry<T> {
    pub const fn new() -> Self {
        Self {
            inner: Mutex::new(RegistryInner {
                next: 1,
                sessions: BTreeMap::new(),
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, RegistryInner<T>> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Store a session and return its handle.
    pub fn insert(&self, value: T) -> i64 {
        let mut inner = self.lock();
        let handle = inner.next;
        inner.next += 1;
        inner.sessions.insert(handle, Arc::new(Mutex::new(value)));
        handle as i64
    }

    pub fn get(&self, handle: i64) -> Result<Arc<Mutex<T>>, FfiError> {
        u64::try_from(handle)
            .ok()
            .and_then(|h| self.lock().sessions.get(&h).cloned())
            .ok_or_else(|| FfiError::new(codes::BAD_HANDLE, format!("no open document has handle {handle}")))
    }

    /// Run `f` on a session while holding its lock. A session a panic
    /// interrupted is refused with a `PANIC` error.
    pub fn with<R>(&self, handle: i64, f: impl FnOnce(&mut T) -> Result<R, FfiError>) -> Result<R, FfiError> {
        let session = self.get(handle)?;
        let mut guard = session.lock().map_err(|_| FfiError::new(codes::PANIC, INTERRUPTED))?;
        f(&mut guard)
    }

    /// Drop a session. Returns whether it existed.
    pub fn remove(&self, handle: i64) -> bool {
        u64::try_from(handle)
            .ok()
            .and_then(|h| self.lock().sessions.remove(&h))
            .is_some()
    }

    pub fn len(&self) -> usize {
        self.lock().sessions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calls_report_errors_and_panics() {
        let ok = call_str(|| Ok("value".to_owned()));
        assert_eq!(unsafe { CStr::from_ptr(ok) }.to_str().unwrap(), "value");
        unsafe { free_c_string(ok) };

        assert!(call_str(|| Err(FfiError::invalid("bad input"))).is_null());
        assert_eq!(last_error(), "INVALID_ARGUMENT: bad input");

        assert_eq!(call_i64(|| panic!("boom")), -1);
        assert_eq!(last_error(), "PANIC: boom");

        let mut len = 0i64;
        let buffer = unsafe { call_buffer(|| Ok(vec![1, 2, 3]), &mut len) };
        assert_eq!(len, 3);
        assert_eq!(unsafe { std::slice::from_raw_parts(buffer, 3) }, [1, 2, 3]);
        unsafe { free_buffer(buffer, len) };
    }

    #[test]
    fn string_arguments() {
        let text = CString::new("héllo").unwrap();
        assert_eq!(unsafe { str_arg(text.as_ptr(), "name") }.unwrap(), "héllo");
        assert!(unsafe { str_arg(std::ptr::null(), "name") }.is_err());
        let empty = CString::new("").unwrap();
        assert_eq!(unsafe { opt_str_arg(empty.as_ptr(), "x") }.unwrap(), None);
        assert_eq!(unsafe { opt_str_arg(std::ptr::null(), "x") }.unwrap(), None);
    }

    #[test]
    fn registry_hands_out_handles() {
        static REG: Registry<Vec<u32>> = Registry::new();
        let a = REG.insert(vec![1]);
        let b = REG.insert(vec![2]);
        assert!(a > 0 && b > a);
        REG.with(a, |v| {
            v.push(10);
            Ok(())
        })
        .unwrap();
        assert_eq!(REG.with(a, |v| Ok(v.clone())).unwrap(), vec![1, 10]);
        assert!(REG.remove(a));
        assert!(!REG.remove(a));
        assert_eq!(REG.get(a).unwrap_err().code, codes::BAD_HANDLE);
        assert_eq!(REG.get(-5).unwrap_err().code, codes::BAD_HANDLE);
        assert_eq!(REG.len(), 1);
    }

    #[test]
    fn a_session_a_panic_interrupted_can_only_be_closed() {
        static REG: Registry<Vec<u32>> = Registry::new();
        let broken = REG.insert(vec![1]);
        let other = REG.insert(vec![2]);
        // An edit that panics halfway, as an engine bug might.
        let edit = call_i64(|| {
            REG.with(broken, |v| {
                v.push(10);
                panic!("index out of bounds");
            })
        });
        assert_eq!(edit, -1);
        assert_eq!(last_error(), "PANIC: index out of bounds");

        // Neither another edit nor a save may touch the half-made change.
        for _ in 0..2 {
            let refused = REG.with(broken, |v| Ok(v.clone())).unwrap_err();
            assert_eq!(refused.code, codes::PANIC);
            assert!(refused.message.contains("reopen the document"), "{refused}");
        }
        assert_eq!(call_str(|| REG.with(broken, |_| Ok("saved".to_owned()))), std::ptr::null_mut());
        assert!(last_error().starts_with("PANIC: ") && last_error().contains("reopen"), "{}", last_error());

        // Other documents are unaffected, and closing still works.
        assert_eq!(REG.with(other, |v| Ok(v.clone())).unwrap(), vec![2]);
        assert!(REG.remove(broken));
        assert_eq!(REG.with(broken, |v| Ok(v.clone())).unwrap_err().code, codes::BAD_HANDLE);
        assert_eq!(REG.len(), 1);
    }

    #[test]
    fn atomic_writes_replace_files() {
        let dir = std::env::temp_dir().join(format!("doc_ffi_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.txt");
        let path_str = path.to_str().unwrap();
        write_file_atomically(path_str, b"first").unwrap();
        write_file_atomically(path_str, b"second").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"second");
        assert_eq!(read_file(path_str, 100).unwrap(), b"second");
        assert_eq!(read_file(path_str, 2).unwrap_err().code, codes::TOO_LARGE);
        let leftovers = std::fs::read_dir(&dir).unwrap().count();
        assert_eq!(leftovers, 1, "no temporary files left behind");
        let missing = dir.join("nope/out.txt");
        assert_eq!(write_file_atomically(missing.to_str().unwrap(), b"x").unwrap_err().code, codes::IO);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
