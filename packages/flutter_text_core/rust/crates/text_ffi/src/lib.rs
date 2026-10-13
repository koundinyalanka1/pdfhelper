//! The FFI layer of the text engine, in Rust, for `dart:ffi`.
//!
//! Conventions are those of `doc_ffi`: UTF-8 strings, caller-owned results
//! freed with [`text_free_string`], negative or NULL results on failure with
//! the reason in [`text_last_error`]. Offsets given to and returned from
//! Dart are in UTF-16 code units, which is how Dart strings count.

use std::ffi::c_char;

use doc_ffi::{
    call_i64, call_str, codes, last_error_ptr, opt_str_arg, read_file, str_arg, write_file_atomically,
    FfiError, Registry,
};
use serde::Serialize;
use text_core::search::{self, SearchOptions};
use text_core::{json, Encoding, LineEnding, TextDocument};

pub use text_core;

/// Files larger than this are refused rather than read into memory.
const MAX_FILE_BYTES: u64 = 256 << 20;

static DOCS: Registry<TextDocument> = Registry::new();

fn encoding(label: &str) -> Result<Encoding, FfiError> {
    Encoding::from_label(label).ok_or_else(|| FfiError::unsupported(format!("unknown encoding '{label}'")))
}

/// Library version (static; do not free).
#[no_mangle]
pub extern "C" fn text_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// This thread's last error, `"CODE: message"` (borrowed; do not free).
#[no_mangle]
pub extern "C" fn text_last_error() -> *const c_char {
    last_error_ptr()
}

/// Free a string returned by this library.
///
/// # Safety
/// `ptr` must be NULL or a string from this library, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn text_free_string(ptr: *mut c_char) {
    doc_ffi::free_c_string(ptr)
}

/// Open a text file. `fallback_encoding` (a label such as `windows-1252`)
/// is used when the bytes could be any single-byte code page; NULL means
/// Windows-1252. Returns a handle, or -1.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_open(path: *const c_char, fallback_encoding: *const c_char) -> i64 {
    call_i64(|| {
        let path = str_arg(path, "path")?;
        let fallback = match opt_str_arg(fallback_encoding, "fallback encoding")? {
            Some(label) => encoding(label)?,
            None => Encoding::WINDOWS_1252,
        };
        let bytes = read_file(path, MAX_FILE_BYTES)?;
        Ok(DOCS.insert(TextDocument::from_bytes(bytes, fallback)))
    })
}

/// A new, empty UTF-8 document. Returns a handle.
#[no_mangle]
pub extern "C" fn text_new() -> i64 {
    call_i64(|| Ok(DOCS.insert(TextDocument::new())))
}

/// Close a document. Returns 0, or -1 for an unknown handle.
#[no_mangle]
pub extern "C" fn text_close(handle: i64) -> i64 {
    call_i64(|| {
        if DOCS.remove(handle) {
            Ok(0)
        } else {
            Err(FfiError::new(codes::BAD_HANDLE, format!("no open document has handle {handle}")))
        }
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Info {
    encoding: &'static str,
    bom: bool,
    line_ending: &'static str,
    mixed_line_endings: bool,
    decode_errors: usize,
    confident: bool,
    binary: bool,
    modified: bool,
    can_reinterpret: bool,
    lines: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    words: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    characters: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    length: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    unmappable: Option<usize>,
}

/// The document's format and, when `with_stats` is non-zero, its word,
/// character and UTF-16 length counts and unmappable characters (these read
/// the whole text).
#[no_mangle]
pub extern "C" fn text_info_json(handle: i64, with_stats: i32) -> *mut c_char {
    call_str(|| {
        DOCS.with(handle, |doc| {
            let stats = (with_stats != 0).then(|| doc.stats());
            let info = Info {
                encoding: doc.encoding.name(),
                bom: doc.bom,
                line_ending: doc.line_ending.name(),
                mixed_line_endings: doc.mixed_line_endings,
                decode_errors: doc.decode_errors,
                confident: doc.confident,
                binary: doc.binary,
                modified: doc.is_modified(),
                can_reinterpret: doc.can_reinterpret(),
                lines: doc.line_count(),
                words: stats.map(|s| s.words),
                characters: stats.map(|s| s.characters),
                length: stats.map(|s| s.utf16_len),
                unmappable: (with_stats != 0).then(|| doc.unmappable()),
            };
            serde_json::to_string(&info).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
        })
    })
}

/// The whole text, with `\n` line breaks.
#[no_mangle]
pub extern "C" fn text_get(handle: i64) -> *mut c_char {
    call_str(|| DOCS.with(handle, |doc| Ok(doc.text().to_owned())))
}

/// Replace the whole text. Returns 1 if it changed, 0 if not.
///
/// # Safety
/// `text` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_set(handle: i64, text: *const c_char) -> i64 {
    call_i64(|| {
        let text = str_arg(text, "text")?.to_owned();
        DOCS.with(handle, |doc| {
            let before = doc.is_modified();
            let old_len = doc.text().len();
            doc.set_text(text);
            Ok((doc.is_modified() != before || doc.text().len() != old_len) as i64)
        })
    })
}

/// Lines `first..first + count` as a JSON array of strings.
#[no_mangle]
pub extern "C" fn text_lines_json(handle: i64, first: i64, count: i64) -> *mut c_char {
    call_str(|| {
        let first = usize::try_from(first).map_err(|_| FfiError::invalid("first line is negative"))?;
        let count = usize::try_from(count).map_err(|_| FfiError::invalid("line count is negative"))?;
        DOCS.with(handle, |doc| {
            serde_json::to_string(&doc.lines(first, count.min(100_000)))
                .map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
        })
    })
}

fn options(flags: i32) -> SearchOptions {
    SearchOptions {
        case_sensitive: flags & 1 != 0,
        whole_word: flags & 2 != 0,
    }
}

/// Find `query`: a JSON array of `[start, end, line]`, with UTF-16 offsets
/// and 0-based line numbers, at most `limit` of them. `flags`: 1 = match
/// case, 2 = whole words.
///
/// # Safety
/// `query` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_find_json(handle: i64, query: *const c_char, flags: i32, limit: i64) -> *mut c_char {
    call_str(|| {
        let query = str_arg(query, "query")?;
        let limit = usize::try_from(limit).unwrap_or(0);
        DOCS.with(handle, |doc| {
            let matches = search::find_all(doc.text(), query, options(flags), limit);
            let lines: Vec<usize> = matches.iter().map(|m| doc.line_of(m.start)).collect();
            let bytes: Vec<usize> = matches.iter().flat_map(|m| [m.start, m.end]).collect();
            let offsets = search::utf16_offsets(doc.text(), &bytes);
            let found: Vec<[usize; 3]> = offsets
                .chunks(2)
                .zip(lines)
                .map(|(p, line)| [p[0], p[1], line])
                .collect();
            serde_json::to_string(&found).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
        })
    })
}

/// Replace every match of `query`. Returns the number replaced.
///
/// # Safety
/// String arguments must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_replace_all(
    handle: i64,
    query: *const c_char,
    replacement: *const c_char,
    flags: i32,
) -> i64 {
    call_i64(|| {
        let query = str_arg(query, "query")?;
        let replacement = str_arg(replacement, "replacement")?;
        DOCS.with(handle, |doc| {
            let (text, count) = search::replace_all(doc.text(), query, replacement, options(flags));
            if count > 0 {
                doc.set_text(text);
            }
            Ok(count as i64)
        })
    })
}

/// Choose how the file is written. NULL leaves a setting alone; `bom` is
/// -1 (leave), 0 or 1. Returns 0.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_set_format(
    handle: i64,
    encoding_label: *const c_char,
    bom: i32,
    line_ending: *const c_char,
) -> i64 {
    call_i64(|| {
        let new_encoding = opt_str_arg(encoding_label, "encoding")?.map(encoding).transpose()?;
        let new_ending = match opt_str_arg(line_ending, "line ending")? {
            Some(name) => Some(
                LineEnding::from_name(name).ok_or_else(|| FfiError::invalid(format!("unknown line ending '{name}'")))?,
            ),
            None => None,
        };
        DOCS.with(handle, |doc| {
            if let Some(e) = new_encoding {
                doc.encoding = e;
                if !e.is_unicode() {
                    doc.bom = false;
                }
            }
            if let Some(ending) = new_ending {
                doc.line_ending = ending;
                doc.mixed_line_endings = false;
            }
            if bom >= 0 && doc.encoding.is_unicode() {
                doc.bom = bom != 0;
            }
            Ok(0)
        })
    })
}

/// Re-read the unedited file in another encoding. Returns 0.
///
/// # Safety
/// `encoding_label` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_reinterpret(handle: i64, encoding_label: *const c_char) -> i64 {
    call_i64(|| {
        let target = encoding(str_arg(encoding_label, "encoding")?)?;
        DOCS.with(handle, |doc| {
            doc.reinterpret(target).map_err(FfiError::unsupported)?;
            Ok(0)
        })
    })
}

/// Write the current text to `path` (atomically) without marking the
/// document saved, for sharing a snapshot. Returns the number of
/// characters the encoding could not represent.
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_write_copy(handle: i64, path: *const c_char) -> i64 {
    call_i64(|| {
        let path = str_arg(path, "path")?;
        DOCS.with(handle, |doc| {
            let (bytes, unmappable) = doc.encode();
            write_file_atomically(path, &bytes)?;
            Ok(unmappable as i64)
        })
    })
}

/// Save to `path` (atomically). Returns the number of characters the
/// encoding could not represent, which were written as `?`; the caller
/// should have warned about them first.
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_save(handle: i64, path: *const c_char) -> i64 {
    call_i64(|| {
        let path = str_arg(path, "path")?;
        DOCS.with(handle, |doc| {
            let (bytes, unmappable) = doc.encode();
            write_file_atomically(path, &bytes)?;
            doc.mark_saved();
            Ok(unmappable as i64)
        })
    })
}

#[derive(Serialize)]
struct EncodingInfo {
    name: &'static str,
    unicode: bool,
}

/// Every supported encoding: `[{"name": "UTF-8", "unicode": true}, ...]`.
#[no_mangle]
pub extern "C" fn text_encodings_json() -> *mut c_char {
    call_str(|| {
        let all: Vec<EncodingInfo> = Encoding::all()
            .into_iter()
            .map(|e| EncodingInfo {
                name: e.name(),
                unicode: e.is_unicode(),
            })
            .collect();
        serde_json::to_string(&all).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
    })
}

/// Re-indent JSON (`indent` spaces; 0 compacts it). On invalid JSON returns
/// NULL with an `INVALID_ARGUMENT` error naming the line and column.
///
/// # Safety
/// `text` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn text_format_json(text: *const c_char, indent: i32) -> *mut c_char {
    call_str(|| {
        let text = str_arg(text, "text")?;
        json::format(text, indent.max(0) as usize).map_err(|e| FfiError::invalid(e.to_string()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn take(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "{}", doc_ffi::last_error());
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { text_free_string(ptr) };
        text
    }

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    #[test]
    fn open_edit_save_round_trip() {
        let dir = std::env::temp_dir().join(format!("text_ffi_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("note.txt");
        std::fs::write(&path, b"Total: 100\r\ntotal again\r\n").unwrap();
        let cpath = c(path.to_str().unwrap());
        let handle = unsafe { text_open(cpath.as_ptr(), std::ptr::null()) };
        assert!(handle > 0, "{}", doc_ffi::last_error());

        let info: serde_json::Value = serde_json::from_str(&take(text_info_json(handle, 1))).unwrap();
        assert_eq!(info["encoding"], "UTF-8");
        assert_eq!(info["lineEnding"], "CRLF");
        assert_eq!(info["lines"], 3);
        assert_eq!(info["words"], 4);
        assert_eq!(take(text_get(handle)), "Total: 100\ntotal again\n");

        let found = take(unsafe { text_find_json(handle, c("total").as_ptr(), 0, 10) });
        assert_eq!(found, "[[0,5,0],[11,16,1]]");
        assert_eq!(take(unsafe { text_find_json(handle, c("total").as_ptr(), 1, 10) }), "[[11,16,1]]");
        assert_eq!(unsafe { text_replace_all(handle, c("total").as_ptr(), c("Sum").as_ptr(), 0) }, 2);
        assert_eq!(take(text_lines_json(handle, 0, 2)), r#"["Sum: 100","Sum again"]"#);

        assert_eq!(unsafe { text_set(handle, c("₹ 500\nend").as_ptr()) }, 1);
        assert_eq!(unsafe { text_set_format(handle, c("windows-1252").as_ptr(), -1, std::ptr::null()) }, 0);
        assert_eq!(unsafe { text_save(handle, cpath.as_ptr()) }, 1);
        assert_eq!(std::fs::read(&path).unwrap(), b"? 500\r\nend");
        assert_eq!(unsafe { text_set_format(handle, c("UTF-8").as_ptr(), 1, c("LF").as_ptr()) }, 0);
        assert_eq!(unsafe { text_save(handle, cpath.as_ptr()) }, 0);
        assert_eq!(std::fs::read(&path).unwrap(), "\u{FEFF}₹ 500\nend".as_bytes());

        assert_eq!(text_close(handle), 0);
        assert_eq!(text_close(handle), -1);
        assert!(doc_ffi::last_error().starts_with("BAD_HANDLE"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn errors_are_reported() {
        let missing = c("/definitely/not/here.txt");
        assert_eq!(unsafe { text_open(missing.as_ptr(), std::ptr::null()) }, -1);
        assert!(doc_ffi::last_error().starts_with("IO: here.txt"));
        assert_eq!(unsafe { text_open(missing.as_ptr(), c("klingon").as_ptr()) }, -1);
        assert!(doc_ffi::last_error().starts_with("UNSUPPORTED"));
        assert!(unsafe { text_format_json(c("{oops}").as_ptr(), 2) }.is_null());
        assert_eq!(doc_ffi::last_error(), "INVALID_ARGUMENT: line 1, column 2: expected a key in double quotes");
        assert_eq!(take(unsafe { text_format_json(c("[1,2]").as_ptr(), 0) }), "[1,2]");
        let encodings = take(text_encodings_json());
        assert!(encodings.starts_with(r#"[{"name":"UTF-8","unicode":true}"#));
    }

    #[test]
    fn reinterpret_before_editing() {
        let dir = std::env::temp_dir().join(format!("text_ffi_re_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ru.txt");
        std::fs::write(&path, [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, b'!']).unwrap();
        let handle = unsafe { text_open(c(path.to_str().unwrap()).as_ptr(), std::ptr::null()) };
        let info: serde_json::Value = serde_json::from_str(&take(text_info_json(handle, 0))).unwrap();
        assert_eq!(info["confident"], false);
        assert_eq!(unsafe { text_reinterpret(handle, c("windows-1251").as_ptr()) }, 0);
        assert_eq!(take(text_get(handle)), "Привет!");
        text_close(handle);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
