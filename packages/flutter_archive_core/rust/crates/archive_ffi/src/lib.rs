//! The FFI layer of the archive engine, in Rust, for `dart:ffi`.
//!
//! Conventions are those of `doc_ffi`: UTF-8 strings, caller-owned results
//! freed with [`archive_free_string`], negative or NULL results on failure
//! with the reason in [`archive_last_error`]. Each call names the archive by
//! its path and opens it afresh, so there are no handles to close.
//! Structured data crosses as JSON.

use std::ffi::c_char;
use std::path::Path;

use archive_core::{create_zip, Archive, ArchiveError, CreateOptions, Entry, Source};
use doc_ffi::{call_i64, call_str, codes, last_error_ptr, str_arg, FfiError};
use serde::{Deserialize, Serialize};

pub use archive_core;

fn archive_error(e: ArchiveError) -> FfiError {
    let message = e.to_string();
    match e {
        ArchiveError::Io { path, source } => FfiError::io(&path.to_string_lossy(), &source),
        ArchiveError::Unsupported(m) => FfiError::unsupported(m),
        ArchiveError::Corrupt(m) => FfiError::corrupt(m),
        ArchiveError::Encrypted(_) => FfiError::new(codes::ENCRYPTED, message),
        ArchiveError::TooLarge(m) => FfiError::new(codes::TOO_LARGE, m),
        ArchiveError::NotFound(m) => FfiError::new(codes::NOT_FOUND, m),
        ArchiveError::Invalid(m) => FfiError::invalid(m),
    }
}

fn to_json(value: &impl Serialize) -> Result<String, FfiError> {
    serde_json::to_string(value).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
}

/// # Safety
/// `path` must be NULL or valid NUL-terminated UTF-8.
unsafe fn open(path: *const c_char) -> Result<Archive, FfiError> {
    let path = str_arg(path, "path")?;
    Archive::open(path).map_err(archive_error)
}

/// Library version (static; do not free).
#[no_mangle]
pub extern "C" fn archive_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// This thread's last error, `"CODE: message"` (borrowed; do not free).
#[no_mangle]
pub extern "C" fn archive_last_error() -> *const c_char {
    last_error_ptr()
}

/// Free a string returned by this library.
///
/// # Safety
/// `ptr` must be NULL or a string from this library, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn archive_free_string(ptr: *mut c_char) {
    doc_ffi::free_c_string(ptr)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EntryJson<'a> {
    index: usize,
    path: &'a str,
    name: &'a str,
    safe_path: Option<&'a str>,
    kind: &'static str,
    is_dir: bool,
    size: u64,
    compressed_size: Option<u64>,
    modified: Option<&'a str>,
    encrypted: bool,
    method: &'a str,
}

impl<'a> From<&'a Entry> for EntryJson<'a> {
    fn from(e: &'a Entry) -> Self {
        Self {
            index: e.index,
            path: &e.path,
            name: &e.name,
            safe_path: e.safe_path.as_deref(),
            kind: e.kind.name(),
            is_dir: e.is_dir(),
            size: e.size,
            compressed_size: e.compressed_size,
            modified: e.modified.as_deref(),
            encrypted: e.encrypted,
            method: e.method.name(),
        }
    }
}

#[derive(Serialize)]
struct Listing<'a> {
    format: &'static str,
    entries: Vec<EntryJson<'a>>,
    comment: &'a str,
}

/// What an archive (ZIP, TAR, gzip or gzipped TAR) holds:
/// `{"format": "zip", "entries": [...], "comment": ""}`. Each entry is
/// `{"index", "path" (as stored), "name" (to show), "safePath" (where
/// extracting everything puts it, or null), "kind" ("file", "dir",
/// "symlink", "hardlink", "special"), "isDir", "size", "compressedSize"
/// (or null), "modified" (ISO 8601, or null), "encrypted", "method"}`.
/// Archives that would expand like a zip bomb fail with `TOO_LARGE`.
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn archive_list_json(path: *const c_char) -> *mut c_char {
    call_str(|| {
        let archive = open(path)?;
        to_json(&Listing {
            format: archive.format().name(),
            entries: archive.entries().iter().map(EntryJson::from).collect(),
            comment: archive.comment(),
        })
    })
}

/// Extract entry `index` (from [`archive_list_json`]) to `out_path`,
/// replacing that file atomically. Returns the number of bytes written.
/// Fails with `ENCRYPTED` for a password-protected entry, `UNSUPPORTED` for a
/// link or an unsupported method, `INVALID_ARGUMENT` for a folder and
/// `NOT_FOUND` for an index past the end.
///
/// # Safety
/// String arguments must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn archive_extract(path: *const c_char, index: i64, out_path: *const c_char) -> i64 {
    call_i64(|| {
        let out = str_arg(out_path, "output path")?;
        let index = usize::try_from(index).map_err(|_| FfiError::invalid("the entry index is negative"))?;
        let written = open(path)?.extract(index, Path::new(out)).map_err(archive_error)?;
        Ok(written as i64)
    })
}

#[derive(Serialize)]
struct SkippedJson<'a> {
    index: usize,
    path: &'a str,
    reason: &'a str,
}

#[derive(Serialize)]
struct ExtractionJson<'a> {
    written: Vec<String>,
    skipped: Vec<SkippedJson<'a>>,
}

/// Extract everything into the folder `out_dir` (created if needed):
/// `{"written": [paths], "skipped": [{"index", "path", "reason"}]}`.
/// Nothing is written outside `out_dir`, files already there are kept (a
/// new file whose name is taken becomes `name (2).ext`), and links,
/// password-protected and damaged entries are skipped with their reason.
/// Fails only when the archive cannot be read or the folder written (for
/// example, the device is full).
///
/// # Safety
/// String arguments must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn archive_extract_all_json(path: *const c_char, out_dir: *const c_char) -> *mut c_char {
    call_str(|| {
        let out_dir = str_arg(out_dir, "output folder")?;
        let report = open(path)?.extract_all(Path::new(out_dir)).map_err(archive_error)?;
        to_json(&ExtractionJson {
            written: report.written.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
            skipped: report
                .skipped
                .iter()
                .map(|s| SkippedJson { index: s.index, path: &s.path, reason: &s.reason })
                .collect(),
        })
    })
}

#[derive(Deserialize)]
struct SourceJson {
    path: String,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum CreateRequest {
    Sources(Vec<SourceJson>),
    #[serde(rename_all = "camelCase")]
    WithOptions {
        sources: Vec<SourceJson>,
        #[serde(default)]
        utc_offset_minutes: i32,
    },
}

/// Write a ZIP of files and folders to `out_path`, atomically. `sources_json`
/// is `[{"path": "/sdcard/a.pdf", "name": "docs/a.pdf"}, ...]` (`name` is
/// optional and defaults to the file's own), or
/// `{"sources": [...], "utcOffsetMinutes": 330}` to stamp entries with the
/// phone's local time, as ZIP expects. Folders are added with everything in
/// them; clashing names are numbered. Returns the number of files packed.
///
/// # Safety
/// String arguments must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn archive_create(sources_json: *const c_char, out_path: *const c_char) -> i64 {
    call_i64(|| {
        let request: CreateRequest = serde_json::from_str(str_arg(sources_json, "sources")?)
            .map_err(|e| FfiError::invalid(format!("bad sources: {e}")))?;
        let out = str_arg(out_path, "output path")?;
        let (sources, utc_offset_minutes) = match request {
            CreateRequest::Sources(sources) => (sources, 0),
            CreateRequest::WithOptions { sources, utc_offset_minutes } => (sources, utc_offset_minutes),
        };
        let sources: Vec<Source> = sources
            .into_iter()
            .map(|s| Source { path: s.path.into(), name: s.name.filter(|n| !n.is_empty()) })
            .collect();
        let options = CreateOptions { utc_offset_minutes, ..CreateOptions::default() };
        let created = create_zip(&sources, Path::new(out), &options).map_err(archive_error)?;
        Ok(created.files as i64)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn take(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "{}", doc_ffi::last_error());
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { archive_free_string(ptr) };
        text
    }

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("archive_ffi_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn create_list_extract_round_trip() {
        let dir = scratch("round");
        std::fs::create_dir_all(dir.join("src/inner")).unwrap();
        std::fs::write(dir.join("src/inner/नोट.txt"), "नमस्ते").unwrap();
        std::fs::write(dir.join("photo.jpg"), [0xFF, 0xD8, 0xFF]).unwrap();
        let zip = dir.join("out.zip");
        let sources = serde_json::json!({
            "sources": [
                {"path": dir.join("src").to_str().unwrap()},
                {"path": dir.join("photo.jpg").to_str().unwrap(), "name": "pics/p.jpg"},
            ],
            "utcOffsetMinutes": 330,
        });
        let zip_c = c(zip.to_str().unwrap());
        assert_eq!(unsafe { archive_create(c(&sources.to_string()).as_ptr(), zip_c.as_ptr()) }, 2);

        let listing: serde_json::Value =
            serde_json::from_str(&take(unsafe { archive_list_json(zip_c.as_ptr()) })).unwrap();
        assert_eq!(listing["format"], "zip");
        assert_eq!(listing["comment"], "");
        let entries = listing["entries"].as_array().unwrap();
        let paths: Vec<_> = entries.iter().map(|e| e["path"].as_str().unwrap()).collect();
        assert_eq!(paths, ["src/", "src/inner/", "src/inner/नोट.txt", "pics/", "pics/p.jpg"]);
        let note = &entries[2];
        assert_eq!(note["name"], "नोट.txt");
        assert_eq!(note["safePath"], "src/inner/नोट.txt");
        assert_eq!(note["kind"], "file");
        assert_eq!(note["isDir"], false);
        assert_eq!(note["size"], "नमस्ते".len());
        assert_eq!(note["method"], "deflated");
        assert_eq!(note["encrypted"], false);
        assert!(note["modified"].as_str().unwrap().starts_with("20"));
        assert_eq!(entries[0]["kind"], "dir");
        assert_eq!(entries[4]["method"], "stored");

        let one = dir.join("one.txt");
        let one_c = c(one.to_str().unwrap());
        assert_eq!(unsafe { archive_extract(zip_c.as_ptr(), 2, one_c.as_ptr()) }, "नमस्ते".len() as i64);
        assert_eq!(std::fs::read_to_string(&one).unwrap(), "नमस्ते");

        let out = dir.join("out");
        let report: serde_json::Value = serde_json::from_str(&take(unsafe {
            archive_extract_all_json(zip_c.as_ptr(), c(out.to_str().unwrap()).as_ptr())
        }))
        .unwrap();
        let written: Vec<_> = report["written"].as_array().unwrap().iter().map(|p| p.as_str().unwrap()).collect();
        assert_eq!(
            written,
            [out.join("src/inner/नोट.txt").to_str().unwrap(), out.join("pics/p.jpg").to_str().unwrap()]
        );
        assert_eq!(report["skipped"], serde_json::json!([]));
        assert_eq!(std::fs::read(out.join("pics/p.jpg")).unwrap(), [0xFF, 0xD8, 0xFF]);

        // A bare list of sources works too.
        let plain = serde_json::json!([{"path": dir.join("photo.jpg").to_str().unwrap()}]);
        let zip2 = c(dir.join("plain.zip").to_str().unwrap());
        assert_eq!(unsafe { archive_create(c(&plain.to_string()).as_ptr(), zip2.as_ptr()) }, 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn errors_are_reported() {
        let dir = scratch("errors");
        let missing = c(dir.join("missing.zip").to_str().unwrap());
        assert!(unsafe { archive_list_json(missing.as_ptr()) }.is_null());
        assert_eq!(doc_ffi::last_error(), "IO: missing.zip: the file does not exist");
        assert!(unsafe { archive_list_json(std::ptr::null()) }.is_null());
        assert_eq!(doc_ffi::last_error(), "INVALID_ARGUMENT: path is missing");

        let text = dir.join("notes.txt");
        std::fs::write(&text, "just text").unwrap();
        assert!(unsafe { archive_list_json(c(text.to_str().unwrap()).as_ptr()) }.is_null());
        assert_eq!(doc_ffi::last_error(), "UNSUPPORTED: this is not a ZIP, TAR or GZ archive");

        // One stored entry, then its "encrypted" flag set in both headers.
        let mut writer = doc_zip::ZipWriter::new();
        writer.add("secret.txt", b"scrambled", doc_zip::Compression::Stored).unwrap();
        let mut bytes = writer.finish();
        bytes[6] |= 1;
        let central = bytes.windows(4).position(|w| w == b"PK\x01\x02").unwrap();
        bytes[central + 8] |= 1;
        let locked = dir.join("locked.zip");
        std::fs::write(&locked, &bytes).unwrap();
        let locked_c = c(locked.to_str().unwrap());
        let listing: serde_json::Value =
            serde_json::from_str(&take(unsafe { archive_list_json(locked_c.as_ptr()) })).unwrap();
        assert_eq!(listing["entries"][0]["encrypted"], true);
        let out = c(dir.join("secret.txt").to_str().unwrap());
        assert_eq!(unsafe { archive_extract(locked_c.as_ptr(), 0, out.as_ptr()) }, -1);
        assert_eq!(doc_ffi::last_error(), "ENCRYPTED: 'secret.txt' is protected with a password");
        assert_eq!(unsafe { archive_extract(locked_c.as_ptr(), 5, out.as_ptr()) }, -1);
        assert_eq!(doc_ffi::last_error(), "NOT_FOUND: the archive has no entry 5");
        assert_eq!(unsafe { archive_extract(locked_c.as_ptr(), -1, out.as_ptr()) }, -1);
        assert!(doc_ffi::last_error().starts_with("INVALID_ARGUMENT"));
        let report: serde_json::Value = serde_json::from_str(&take(unsafe {
            archive_extract_all_json(locked_c.as_ptr(), c(dir.join("all").to_str().unwrap()).as_ptr())
        }))
        .unwrap();
        assert_eq!(report["written"], serde_json::json!([]));
        assert_eq!(report["skipped"][0]["path"], "secret.txt");
        assert_eq!(report["skipped"][0]["reason"], "'secret.txt' is protected with a password");

        let zip = c(dir.join("x.zip").to_str().unwrap());
        assert_eq!(unsafe { archive_create(c("{oops").as_ptr(), zip.as_ptr()) }, -1);
        assert!(doc_ffi::last_error().starts_with("INVALID_ARGUMENT: bad sources"));
        assert_eq!(unsafe { archive_create(c("[]").as_ptr(), zip.as_ptr()) }, -1);
        assert_eq!(doc_ffi::last_error(), "INVALID_ARGUMENT: there is nothing to put in the archive");
        assert!(!unsafe { CStr::from_ptr(archive_core_version()) }.to_str().unwrap().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
