//! Writing entries out: atomic files, and a target folder that is never
//! written outside of and whose existing files are never replaced.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::paths::numbered;
use crate::ArchiveError;

/// Most " (n)" suffixes tried before giving up on a name.
const MAX_SUFFIX: usize = 10_000;

static TEMP_FILES: AtomicU64 = AtomicU64::new(0);

/// How hard [`write_atomically`] works to survive a power cut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Durability {
    /// Flush the file to storage before renaming it into place, so that even
    /// a power cut leaves either the old file or the new one. For a file that
    /// may replace another.
    Synced,
    /// Rename without flushing first. A crash still never shows a
    /// half-written file, but a power cut may leave the new one empty. For
    /// files that replace nothing: extracting everything, where flushing
    /// each of thousands of files would make it many times slower.
    Renamed,
}

/// Write a file through `fill` atomically: into a hidden temporary file in
/// the same folder, then renamed over `path`. A crash, a full disk or
/// damaged archive data never leaves a half-written file under the real
/// name. (`doc_ffi::write_file_atomically` does the same for bytes already
/// in memory; entries are streamed, since they can be larger than memory.)
/// `fill` reports write failures itself, naming `path`.
pub(crate) fn write_atomically(
    path: &Path,
    durability: Durability,
    fill: impl FnOnce(&mut dyn Write) -> Result<u64, ArchiveError>,
) -> Result<u64, ArchiveError> {
    let dir = path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    if path.file_name().is_none() {
        return Err(ArchiveError::Invalid(format!("'{}' is not a file path", path.display())));
    }
    let temp = dir.join(format!(".{}-{}.archive.tmp", std::process::id(), TEMP_FILES.fetch_add(1, Ordering::Relaxed)));
    let file = File::create(&temp).map_err(|e| ArchiveError::io(path, e))?;
    let mut out = BufWriter::with_capacity(256 << 10, file);
    let result = fill(&mut out).and_then(|written| {
        let file = out.into_inner().map_err(|e| ArchiveError::io(path, e.into_error()))?;
        if durability == Durability::Synced {
            file.sync_all().map_err(|e| ArchiveError::io(path, e))?;
        }
        drop(file);
        fs::rename(&temp, path).map_err(|e| ArchiveError::io(path, e))?;
        Ok(written)
    });
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// The folder an archive is extracted into. Folders from the archive are
/// created inside it (or merged into folders already there); a file never
/// replaces anything, but takes the next free name: `photo (2).jpg`.
pub(crate) struct Target {
    root: PathBuf,
    /// Each folder path from the archive, `/`-separated, and where it went.
    folders: HashMap<String, PathBuf>,
}

impl Target {
    pub fn new(root: &Path) -> Result<Self, ArchiveError> {
        fs::create_dir_all(root).map_err(|e| ArchiveError::io(root, e))?;
        if !fs::metadata(root).map_err(|e| ArchiveError::io(root, e))?.is_dir() {
            return Err(ArchiveError::Invalid(format!("'{}' is not a folder", root.display())));
        }
        Ok(Self { root: root.to_owned(), folders: HashMap::new() })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The real folder for `components` (outermost first), created as needed.
    /// A name taken by a file or a link gets a numbered folder instead, so a
    /// link already in the target is never followed.
    pub fn folder(&mut self, components: &[String]) -> io::Result<PathBuf> {
        let mut current = self.root.clone();
        let mut key = String::new();
        for component in components {
            if !key.is_empty() {
                key.push('/');
            }
            key.push_str(component);
            if let Some(found) = self.folders.get(&key) {
                current = found.clone();
                continue;
            }
            let mut n = 1;
            let actual = loop {
                let name = if n == 1 { component.clone() } else { numbered(component, n, true) };
                let candidate = current.join(name);
                match fs::symlink_metadata(&candidate) {
                    Ok(meta) if meta.is_dir() => break candidate,
                    Ok(_) => {}
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {
                        fs::create_dir(&candidate)?;
                        break candidate;
                    }
                    Err(e) => return Err(e),
                }
                n += 1;
                if n > MAX_SUFFIX {
                    return Err(io::Error::new(io::ErrorKind::AlreadyExists, "too many files have this name"));
                }
            };
            self.folders.insert(key.clone(), actual.clone());
            current = actual;
        }
        debug_assert!(current.starts_with(&self.root));
        Ok(current)
    }

    /// A free path for the file `components`, in its folder.
    pub fn file(&mut self, components: &[String]) -> io::Result<PathBuf> {
        let (name, parents) =
            components.split_last().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "the name is empty"))?;
        let folder = self.folder(parents)?;
        for n in 1..=MAX_SUFFIX {
            let candidate = folder.join(if n == 1 { name.clone() } else { numbered(name, n, false) });
            match fs::symlink_metadata(&candidate) {
                Ok(_) => continue,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(candidate),
                Err(e) => return Err(e),
            }
        }
        Err(io::Error::new(io::ErrorKind::AlreadyExists, "too many files have this name"))
    }
}
