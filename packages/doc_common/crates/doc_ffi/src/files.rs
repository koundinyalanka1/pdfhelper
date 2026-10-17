//! Reading and saving documents, so that a save never damages the file it
//! replaces.
//!
//! A save writes a new temporary file next to the document, flushes it to
//! storage and renames it over the document, so a crash, a full disk or a
//! failing card leaves either the old file or the new one, never half of
//! one. [`save_verified`] also reads the new file back and has the engine
//! check it before the rename, and keeps the version it replaces in a
//! backup folder the app chooses ([`set_backup_dir`]).

use std::ffi::{c_char, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::{call_i64, codes, opt_str_arg, str_arg, FfiError};

/// Most the backup folder holds, all backups together; the oldest are
/// removed first.
pub const BACKUP_CAP_BYTES: u64 = 500 << 20;

/// The folder backups go to, if the app chose one.
static BACKUP_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Counts temporary files made by this process, so their names differ.
static TEMP_FILES: AtomicU64 = AtomicU64::new(0);

/// Read a whole file, with a size cap and a readable error. The cap holds
/// even when the size the system reports is wrong (as it is for some
/// special files) or the file grows while it is read.
pub fn read_file(path: &str, max_bytes: u64) -> Result<Vec<u8>, FfiError> {
    let file = File::open(path).map_err(|e| FfiError::io(path, &e))?;
    let stated = file.metadata().map_err(|e| FfiError::io(path, &e))?.len();
    let too_large = || {
        FfiError::new(
            codes::TOO_LARGE,
            format!("the file is {} MB; the limit is {} MB", stated.max(max_bytes + 1) >> 20, max_bytes >> 20),
        )
    };
    if stated > max_bytes {
        return Err(too_large());
    }
    let no_memory = || {
        FfiError::new(
            codes::TOO_LARGE,
            format!("there is not enough memory to open a file of {} MB", stated >> 20),
        )
    };
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(usize::try_from(stated).unwrap_or(usize::MAX))
        .map_err(|_| no_memory())?;
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| match e.kind() {
            io::ErrorKind::OutOfMemory => no_memory(),
            _ => FfiError::io(path, &e),
        })?;
    if bytes.len() as u64 > max_bytes {
        return Err(too_large());
    }
    Ok(bytes)
}

/// Choose the folder that [`save_verified`] keeps the previous version of
/// each saved file in: one per file name, the newest replacing the one
/// before. An empty `dir` turns backups off (the default). The folder is
/// made when the first backup is.
pub fn set_backup_dir(dir: &str) {
    let dir = (!dir.is_empty()).then(|| PathBuf::from(dir));
    *BACKUP_DIR.lock().unwrap_or_else(PoisonError::into_inner) = dir;
}

/// The folder chosen with [`set_backup_dir`], if any.
pub fn backup_dir() -> Option<PathBuf> {
    BACKUP_DIR.lock().unwrap_or_else(PoisonError::into_inner).clone()
}

/// The body of a library's `<kind>_set_backup_dir(dir)` export, which the
/// app calls with a folder in its private storage: [`set_backup_dir`], with
/// NULL or `""` turning backups off. Each engine library holds its own
/// setting, so the app sets it in every one. Returns 0, or -1 and a last
/// error.
///
/// # Safety
/// `dir` must be NULL or a valid NUL-terminated string.
pub unsafe fn set_backup_dir_c(dir: *const c_char) -> i64 {
    call_i64(|| {
        set_backup_dir(opt_str_arg(dir, "backup folder")?.unwrap_or(""));
        Ok(0)
    })
}

/// Write `bytes` to `path` so that a crash or full disk never leaves a
/// half-written file in its place: write a sibling temporary file, flush it
/// to storage, then rename it over `path`.
pub fn write_file_atomically(path: &str, bytes: &[u8]) -> Result<(), FfiError> {
    replace_file(path, bytes, None::<fn(&[u8]) -> Result<(), FfiError>>, None)
}

/// Save `bytes` as `path` only once they are known to be good:
///
/// 1. write them to a new temporary file beside `path` and flush it to
///    storage;
/// 2. read the file back and compare it with `bytes`, then run the engine's
///    `verify` on them (typically: open them as a document);
/// 3. copy the file being replaced into the backup folder, if one is set
///    ([`set_backup_dir`]);
/// 4. rename the new file over `path` and flush the folder.
///
/// When a step before the rename fails, the temporary file is removed and
/// the file at `path` is left exactly as it was. A backup that cannot be
/// made does not stop the save.
pub fn save_verified(
    path: &str,
    bytes: &[u8],
    verify: impl FnOnce(&[u8]) -> Result<(), FfiError>,
) -> Result<(), FfiError> {
    let dir = backup_dir();
    let backups = dir.as_deref().map(|dir| Backups {
        dir,
        cap: BACKUP_CAP_BYTES,
    });
    replace_file(path, bytes, Some(verify), backups)
}

/// Where backups go, and the most they may take up together.
pub(crate) struct Backups<'a> {
    pub dir: &'a Path,
    pub cap: u64,
}

/// A temporary file, removed when dropped unless kept.
struct TempFile {
    path: PathBuf,
    keep: bool,
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// The steps of [`save_verified`]; `verify` and `backups` are optional so
/// that [`write_file_atomically`] can share them.
pub(crate) fn replace_file<V>(path: &str, bytes: &[u8], verify: Option<V>, backups: Option<Backups>) -> Result<(), FfiError>
where
    V: FnOnce(&[u8]) -> Result<(), FfiError>,
{
    let given = Path::new(path);
    let name = given
        .file_name()
        .ok_or_else(|| FfiError::invalid(format!("'{path}' is not a file path")))?;
    // Saving through a link replaces the file it points to, not the link.
    let target = match fs::symlink_metadata(given) {
        Ok(meta) if meta.file_type().is_symlink() => fs::canonicalize(given).unwrap_or_else(|_| given.to_owned()),
        _ => given.to_owned(),
    };
    let dir = target.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let io_error = |e: io::Error| FfiError::io(path, &e);

    let (temp_path, mut file) = create_temp(dir, name).map_err(io_error)?;
    let mut temp = TempFile {
        path: temp_path,
        keep: false,
    };
    // The new file keeps the old one's permissions.
    if let Ok(meta) = fs::metadata(&target) {
        let _ = file.set_permissions(meta.permissions());
    }
    file.write_all(bytes).and_then(|_| file.sync_all()).map_err(io_error)?;
    drop(file);

    if let Some(verify) = verify {
        if !reads_back_as(&temp.path, bytes).map_err(io_error)? {
            return Err(FfiError::new(
                codes::IO,
                "the new version did not read back from storage as it was written, so it was not saved; the file is unchanged",
            ));
        }
        let checked = catch_unwind(AssertUnwindSafe(|| verify(bytes)))
            .unwrap_or_else(|_| Err(FfiError::new(codes::PANIC, "the check of the new version failed")));
        if let Err(e) = checked {
            return Err(FfiError::new(
                codes::ERROR,
                format!(
                    "the new version did not open correctly ({}), so it was not saved; the file is unchanged",
                    e.message
                ),
            ));
        }
    }

    if let Some(backups) = backups {
        let _ = back_up(&target, name, &backups);
    }
    fs::rename(&temp.path, &target).map_err(io_error)?;
    temp.keep = true;
    sync_dir(dir);
    Ok(())
}

/// Whether the file at `path` holds exactly `bytes`, read back in pieces
/// so that a large document is not held in memory twice.
fn reads_back_as(path: &Path, bytes: &[u8]) -> io::Result<bool> {
    let mut file = File::open(path)?;
    if file.metadata()?.len() != bytes.len() as u64 {
        return Ok(false);
    }
    let mut chunk = vec![0u8; 256 << 10];
    let mut at = 0;
    loop {
        let n = match file.read(&mut chunk) {
            Ok(0) => return Ok(at == bytes.len()),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if bytes.get(at..at + n) != Some(&chunk[..n]) {
            return Ok(false);
        }
        at += n;
    }
}

/// Copy `original` into the backup folder as `name`, replacing the backup
/// of the same name, then trim the folder to its cap.
fn back_up(original: &Path, name: &OsStr, backups: &Backups) -> io::Result<()> {
    let meta = fs::metadata(original)?;
    if !meta.is_file() || meta.len() > backups.cap {
        return Ok(());
    }
    fs::create_dir_all(backups.dir)?;
    let dest = backups.dir.join(name);
    // A backup folder that holds the document itself would replace it.
    if fs::canonicalize(&dest).ok() == fs::canonicalize(original).ok() {
        return Ok(());
    }
    let (temp_path, mut file) = create_temp(backups.dir, name)?;
    let mut temp = TempFile {
        path: temp_path,
        keep: false,
    };
    io::copy(&mut File::open(original)?, &mut file)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temp.path, &dest)?;
    temp.keep = true;
    sync_dir(backups.dir);
    trim_backups(backups.dir, &dest, backups.cap);
    Ok(())
}

/// Remove the oldest backups until the folder holds at most `cap` bytes,
/// never `keep`, the one just made.
fn trim_backups(dir: &Path, keep: &Path, cap: u64) {
    let Ok(listing) = fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(SystemTime, u64, PathBuf)> = listing
        .flatten()
        .filter_map(|entry| {
            let meta = entry.metadata().ok().filter(|m| m.is_file())?;
            Some((meta.modified().unwrap_or(UNIX_EPOCH), meta.len(), entry.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|(_, len, _)| len).sum();
    files.sort();
    for (_, len, path) in files {
        if total <= cap {
            break;
        }
        if path != keep && fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

/// Flush a folder's entries (a rename) to storage. Some file systems
/// cannot, which is no reason to fail a save.
fn sync_dir(dir: &Path) {
    if let Ok(dir) = File::open(dir) {
        let _ = dir.sync_all();
    }
}

/// A new hidden temporary file in `dir` for a file named `name`:
/// `.<name>.<process>-<time>-<count>.tmp`. It is made only if nothing has
/// that name, so an existing file is never truncated and a link there is
/// never followed.
fn create_temp(dir: &Path, name: &OsStr) -> io::Result<(PathBuf, File)> {
    let name = name.to_string_lossy();
    // Keep the temporary name within the 255 bytes file systems allow.
    let mut end = name.len().min(180);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let mut tries = 0;
    loop {
        let n = TEMP_FILES.fetch_add(1, Ordering::Relaxed);
        let temp = dir.join(format!(".{}.{}-{nanos:08x}-{n}.tmp", &name[..end], std::process::id()));
        match OpenOptions::new().write(true).create_new(true).open(&temp) {
            Ok(file) => return Ok((temp, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists && tries < 100 => tries += 1,
            Err(e) => return Err(e),
        }
    }
}

/// Whether `name` is one of the temporary names a save makes: the current
/// `.<name>.<process>-<time>-<count>.tmp` (the time as 8 hex digits), or
/// the `.<name>.<process>.tmp` of earlier versions, whose `<name>` always
/// had an extension. Nothing else matches, so a cleanup never removes a
/// file of the user's that merely looks similar.
fn is_temp_name(name: &str) -> bool {
    let Some(inner) = name.strip_prefix('.').and_then(|n| n.strip_suffix(".tmp")) else {
        return false;
    };
    let Some((stem, tag)) = inner.rsplit_once('.') else {
        return false;
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let parts: Vec<&str> = tag.split('-').collect();
    match parts[..] {
        [process, time, count] => {
            !stem.is_empty()
                && digits(process)
                && time.len() == 8
                && time.bytes().all(|b| b.is_ascii_hexdigit())
                && digits(count)
        }
        [process] => {
            digits(process) && stem.rsplit_once('.').is_some_and(|(base, ext)| !base.is_empty() && !ext.is_empty())
        }
        _ => false,
    }
}

/// Remove the temporary files that saves left in `dir` (when the app was
/// killed mid-save, say) and that are older than `older_than`, so a save in
/// progress is left alone. Returns how many were removed.
pub fn remove_stale_temp_files(dir: &str, older_than: Duration) -> Result<usize, FfiError> {
    let listing = fs::read_dir(dir).map_err(|e| FfiError::io(dir, &e))?;
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in listing.flatten() {
        if !entry.file_name().to_str().is_some_and(is_temp_name) {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        let age = meta.modified().ok().and_then(|m| now.duration_since(m).ok());
        if meta.is_file() && age.is_some_and(|age| age >= older_than) && fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

/// The body of a library's `<kind>_remove_stale_temp_files(dir, seconds)`
/// export: [`remove_stale_temp_files`] for temporary files at least
/// `min_age_seconds` old. Returns how many were removed, or -1 and a last
/// error.
///
/// # Safety
/// `dir` must be NULL or a valid NUL-terminated string.
pub unsafe fn remove_stale_temp_files_c(dir: *const c_char, min_age_seconds: i64) -> i64 {
    call_i64(|| {
        let dir = str_arg(dir, "folder")?;
        let age = u64::try_from(min_age_seconds).map_err(|_| FfiError::invalid("the age must not be negative"))?;
        let removed = remove_stale_temp_files(dir, Duration::from_secs(age))?;
        Ok(removed as i64)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh folder for one test.
    fn folder(test: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("doc_ffi_{test}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn accept(_: &[u8]) -> Result<(), FfiError> {
        Ok(())
    }

    /// Taken by the tests that call [`save_verified`], which reads the
    /// backup folder every test shares, and by the one that sets it.
    static BACKUP_SETTING: Mutex<()> = Mutex::new(());

    fn backup_setting() -> std::sync::MutexGuard<'static, ()> {
        BACKUP_SETTING.lock().unwrap_or_else(PoisonError::into_inner)
    }

    #[test]
    fn a_verified_save_replaces_the_file() {
        let _setting = backup_setting();
        let dir = folder("verified");
        let path = dir.join("doc.docx");
        let path = path.to_str().unwrap();
        fs::write(path, b"old").unwrap();
        save_verified(path, b"new", |bytes| {
            assert_eq!(bytes, b"new");
            Ok(())
        })
        .unwrap();
        assert_eq!(fs::read(path).unwrap(), b"new");
        assert_eq!(names_in(&dir), ["doc.docx"]);
        // A file that did not exist yet is made.
        let fresh = dir.join("fresh.docx");
        save_verified(fresh.to_str().unwrap(), b"made", accept).unwrap();
        assert_eq!(fs::read(&fresh).unwrap(), b"made");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_save_that_does_not_verify_leaves_the_file_alone() {
        let _setting = backup_setting();
        let dir = folder("refused");
        let path = dir.join("doc.xlsx");
        let path = path.to_str().unwrap();
        fs::write(path, b"the original").unwrap();
        let error = save_verified(path, b"corrupted bytes", |_| Err(FfiError::corrupt("not a ZIP archive"))).unwrap_err();
        assert_eq!(error.code, codes::ERROR);
        assert!(error.message.contains("not a ZIP archive") && error.message.contains("unchanged"), "{error}");
        assert_eq!(fs::read(path).unwrap(), b"the original");
        assert_eq!(names_in(&dir), ["doc.xlsx"], "no temporary file left");

        // A check that panics is a refusal too.
        let error = save_verified(path, b"x", |_| panic!("bad check")).unwrap_err();
        assert!(error.message.contains("unchanged"), "{error}");
        assert_eq!(fs::read(path).unwrap(), b"the original");
        assert_eq!(names_in(&dir), ["doc.xlsx"]);

        // So is a folder that cannot be written.
        let missing = dir.join("no such folder/doc.xlsx");
        assert_eq!(save_verified(missing.to_str().unwrap(), b"x", accept).unwrap_err().code, codes::IO);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn saves_keep_the_previous_version_as_a_backup() {
        let dir = folder("backups");
        let backups = dir.join("backups");
        let path = dir.join("letter.docx");
        let path = path.to_str().unwrap();
        let save = |bytes: &[u8], cap: u64| {
            let backups = Backups { dir: &backups, cap };
            replace_file(path, bytes, Some(accept), Some(backups))
        };
        // The first save of a new file has nothing to back up.
        save(b"version 1", 1 << 20).unwrap();
        assert!(!backups.join("letter.docx").exists());
        save(b"version 2", 1 << 20).unwrap();
        assert_eq!(fs::read(backups.join("letter.docx")).unwrap(), b"version 1");
        // One backup per name: the newer replaces the older.
        save(b"version 3", 1 << 20).unwrap();
        assert_eq!(fs::read(backups.join("letter.docx")).unwrap(), b"version 2");
        assert_eq!(names_in(&backups), ["letter.docx"]);
        assert_eq!(fs::read(path).unwrap(), b"version 3");

        // Over the cap, the oldest backups go first.
        for (i, name) in ["a.txt", "b.txt"].iter().enumerate() {
            let other = dir.join(name);
            fs::write(&other, vec![b'x'; 600]).unwrap();
            std::thread::sleep(Duration::from_millis(20));
            let backups = Backups { dir: &backups, cap: 1000 + i as u64 };
            replace_file(other.to_str().unwrap(), b"new", Some(accept), Some(backups)).unwrap();
        }
        assert_eq!(names_in(&backups), ["b.txt"]);

        // A failed save makes no backup.
        let backups_before = fs::read(backups.join("b.txt")).unwrap();
        let refused = replace_file(
            dir.join("b.txt").to_str().unwrap(),
            b"bad",
            Some(|_: &[u8]| Err(FfiError::corrupt("no"))),
            Some(Backups { dir: &backups, cap: 1 << 20 }),
        );
        assert!(refused.is_err());
        assert_eq!(fs::read(backups.join("b.txt")).unwrap(), backups_before);

        // A backup folder that is the document's own folder is not used.
        let own = Backups { dir: &dir, cap: 1 << 20 };
        replace_file(path, b"version 4", Some(accept), Some(own)).unwrap();
        assert_eq!(fs::read(path).unwrap(), b"version 4");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_backup_folder_is_set_by_the_app() {
        let _setting = backup_setting();
        let dir = folder("setter");
        let backups = dir.join("backups");
        assert_eq!(backup_dir(), None);
        let given = std::ffi::CString::new(backups.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { set_backup_dir_c(given.as_ptr()) }, 0);
        assert_eq!(backup_dir(), Some(backups.clone()));
        let path = dir.join("memo.txt");
        fs::write(&path, b"before").unwrap();
        save_verified(path.to_str().unwrap(), b"after", accept).unwrap();
        assert_eq!(fs::read(backups.join("memo.txt")).unwrap(), b"before");
        // NULL and "" both turn backups off.
        assert_eq!(unsafe { set_backup_dir_c(std::ptr::null()) }, 0);
        assert_eq!(backup_dir(), None);
        set_backup_dir(backups.to_str().unwrap());
        let empty = std::ffi::CString::new("").unwrap();
        assert_eq!(unsafe { set_backup_dir_c(empty.as_ptr()) }, 0);
        assert_eq!(backup_dir(), None);
        save_verified(path.to_str().unwrap(), b"again", accept).unwrap();
        assert_eq!(fs::read(backups.join("memo.txt")).unwrap(), b"before", "no backup once turned off");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn temporary_names_are_unique_and_recognised() {
        let dir = folder("temps");
        let (a, _) = create_temp(&dir, OsStr::new("doc.docx")).unwrap();
        let (b, _) = create_temp(&dir, OsStr::new("doc.docx")).unwrap();
        assert_ne!(a, b);
        for path in [&a, &b] {
            let name = path.file_name().unwrap().to_str().unwrap();
            assert!(name.starts_with(".doc.docx.") && is_temp_name(name), "{name}");
        }
        assert!(is_temp_name(".doc.docx.1234.tmp"), "the older form");
        for other in [
            "doc.docx",
            ".hidden.tmp",
            ".doc.docx.tmp",
            ".doc.docx.abc.tmp",
            "..1.tmp",
            ".x.12.tmp.bak",
            // A user's hidden file with a number in its name.
            ".config.2.tmp",
            ".notes.1-2.tmp",
            ".doc.docx.12-0badf00d.tmp",
            ".doc.docx.12-badf00d-3.tmp",
            ".doc.docx.12-0badf00d-x.tmp",
        ] {
            assert!(!is_temp_name(other), "{other}");
        }
        // A very long name still makes a temporary file.
        let long = "ü".repeat(120) + ".docx";
        assert!(create_temp(&dir, OsStr::new(&long)).is_ok());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stale_temporary_files_are_cleaned_up() {
        let dir = folder("stale");
        let old = dir.join(".report.docx.4242-0badf00d-3.tmp");
        let older_form = dir.join(".report.docx.4242.tmp");
        let fresh = dir.join(".report.docx.4243-00c0ffee-0.tmp");
        let unrelated = dir.join(".cache.tmp");
        let document = dir.join("report.docx");
        for path in [&old, &older_form, &fresh, &unrelated, &document] {
            fs::write(path, b"x").unwrap();
        }
        let hour_ago = SystemTime::now() - Duration::from_secs(3600);
        for path in [&old, &older_form, &unrelated, &document] {
            File::options().write(true).open(path).unwrap().set_modified(hour_ago).unwrap();
        }
        let removed = remove_stale_temp_files(dir.to_str().unwrap(), Duration::from_secs(600)).unwrap();
        assert_eq!(removed, 2);
        assert_eq!(
            names_in(&dir),
            [".cache.tmp", ".report.docx.4243-00c0ffee-0.tmp", "report.docx"]
        );
        assert_eq!(remove_stale_temp_files(dir.join("nope").to_str().unwrap(), Duration::ZERO).unwrap_err().code, codes::IO);

        // Through the export: an age of 0 takes the fresh one too.
        let given = std::ffi::CString::new(dir.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { remove_stale_temp_files_c(given.as_ptr(), 0) }, 1);
        assert_eq!(names_in(&dir), [".cache.tmp", "report.docx"]);
        assert_eq!(unsafe { remove_stale_temp_files_c(given.as_ptr(), -1) }, -1);
        assert_eq!(crate::last_error(), "INVALID_ARGUMENT: the age must not be negative");
        assert_eq!(unsafe { remove_stale_temp_files_c(std::ptr::null(), 60) }, -1);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn saving_through_a_link_replaces_its_file() {
        let _setting = backup_setting();
        let dir = folder("link");
        let real = dir.join("real.odt");
        let link = dir.join("link.odt");
        fs::write(&real, b"old").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        save_verified(link.to_str().unwrap(), b"new", accept).unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(fs::read(&real).unwrap(), b"new");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn saves_keep_the_file_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = folder("modes");
        let path = dir.join("private.docx");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        write_file_atomically(path.to_str().unwrap(), b"new").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn reading_stops_at_the_cap_whatever_size_the_file_reports() {
        // Files under /proc report a size of 0 and hold more.
        let error = read_file("/proc/self/maps", 10).unwrap_err();
        assert_eq!(error.code, codes::TOO_LARGE);
        assert!(read_file("/proc/self/maps", 64 << 20).unwrap().len() > 10);
    }
}
