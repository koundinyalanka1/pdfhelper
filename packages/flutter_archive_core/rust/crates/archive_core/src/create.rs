//! Making a ZIP from files and folders on disk.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use doc_zip::{Compression, ZipError, ZipWriter};

use crate::extract::{write_atomically, Durability};
use crate::paths::{numbered, safe_components};
use crate::time::dos_from_system;
use crate::{megabytes, ArchiveError, Limits};

/// Deepest folder nesting followed when adding a folder.
const MAX_DEPTH: usize = 128;

/// Extensions of files that are already compressed, which are stored as
/// they are: deflating them again costs time and saves almost nothing.
const COMPRESSED: &[&str] = &[
    "7z", "aac", "apk", "avi", "bz2", "docx", "epub", "flac", "gif", "gz", "heic", "heif", "jar", "jpeg", "jpg", "m4a",
    "m4v", "mkv", "mov", "mp3", "mp4", "odp", "ods", "odt", "ogg", "opus", "png", "pptx", "rar", "tgz", "webm", "webp",
    "xlsx", "xz", "zip", "zst",
];

/// A file or folder to put in a new archive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub path: PathBuf,
    /// Its name inside the archive, `/`-separated; `None` uses the file or
    /// folder's own name.
    pub name: Option<String>,
}

impl Source {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into(), name: None }
    }

    pub fn named(path: impl Into<PathBuf>, name: impl Into<String>) -> Self {
        Self { path: path.into(), name: Some(name.into()) }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct CreateOptions {
    /// Minutes east of UTC of the phone's time zone: ZIP stores local times.
    pub utc_offset_minutes: i32,
    pub limits: Limits,
}

/// What [`create_zip`] wrote.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Created {
    pub files: usize,
    pub folders: usize,
    /// The archive's size in bytes.
    pub bytes: u64,
}

struct Planned {
    /// The entry's name; folders end with `/`.
    name: String,
    /// The file to read, or `None` for a folder.
    file: Option<PathBuf>,
    modified: SystemTime,
}

#[derive(Default)]
struct Plan {
    entries: Vec<Planned>,
    /// Names taken so far, lower-cased: two names differing only in case
    /// would collide when extracted on Windows or a memory card.
    taken: HashSet<String>,
    bytes: u64,
    /// The archive being written, if it already exists, so a folder that
    /// contains it does not pack its old copy.
    output: Option<PathBuf>,
}

impl Plan {
    /// `name` inside folder `prefix` (empty or ending in `/`), numbered if
    /// it is taken.
    fn claim(&mut self, prefix: &str, name: &str, is_dir: bool) -> String {
        let mut n = 1;
        loop {
            let candidate = if n == 1 { name.to_owned() } else { numbered(name, n, is_dir) };
            let (full, other) = if is_dir {
                (format!("{prefix}{candidate}/"), format!("{prefix}{candidate}"))
            } else {
                (format!("{prefix}{candidate}"), format!("{prefix}{candidate}/"))
            };
            // A file and a folder of the same name cannot both be extracted.
            if !self.taken.contains(&other.to_lowercase()) && self.taken.insert(full.to_lowercase()) {
                return full;
            }
            n += 1;
        }
    }

    fn add_file(
        &mut self,
        path: &Path,
        name: String,
        meta: &fs::Metadata,
        limits: &Limits,
    ) -> Result<(), ArchiveError> {
        self.bytes += meta.len();
        if self.bytes > limits.max_memory_bytes {
            return Err(ArchiveError::TooLarge(format!(
                "the files add up to more than {} MB, the most one archive can hold here",
                megabytes(limits.max_memory_bytes)
            )));
        }
        self.push(
            Planned { name, file: Some(path.to_owned()), modified: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH) },
            limits,
        )
    }

    fn push(&mut self, entry: Planned, limits: &Limits) -> Result<(), ArchiveError> {
        if self.entries.len() >= limits.max_entries {
            return Err(ArchiveError::TooLarge(format!(
                "there are more than {} files and folders to add",
                limits.max_entries
            )));
        }
        self.entries.push(entry);
        Ok(())
    }

    /// Add folder `path` as `name` (ending in `/`) and everything in it, in
    /// name order. Links inside are skipped: they could point outside the
    /// folder or back into it.
    fn add_folder(&mut self, path: &Path, name: String, depth: usize, limits: &Limits) -> Result<(), ArchiveError> {
        if depth > MAX_DEPTH {
            return Err(ArchiveError::TooLarge(format!(
                "'{}' has folders nested more than {MAX_DEPTH} deep",
                path.display()
            )));
        }
        let modified = fs::metadata(path).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
        self.push(Planned { name: name.clone(), file: None, modified }, limits)?;
        let mut children: Vec<_> = fs::read_dir(path)
            .map_err(|e| ArchiveError::io(path, e))?
            .collect::<Result<_, _>>()
            .map_err(|e| ArchiveError::io(path, e))?;
        children.sort_by_key(|c| c.file_name());
        for child in children {
            let child_path = child.path();
            let meta = fs::symlink_metadata(&child_path).map_err(|e| ArchiveError::io(&child_path, e))?;
            let child_name = child.file_name().to_string_lossy().into_owned();
            if meta.is_dir() {
                let full = self.claim(&name, &child_name, true);
                self.add_folder(&child_path, full, depth + 1, limits)?;
            } else if meta.is_file() {
                if self.output.as_deref().is_some_and(|out| same_file(out, &child_path)) {
                    continue;
                }
                let full = self.claim(&name, &child_name, false);
                self.add_file(&child_path, full, &meta, limits)?;
            }
        }
        Ok(())
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

fn is_compressed(name: &str) -> bool {
    let extension = name.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase());
    extension.is_some_and(|ext| COMPRESSED.contains(&ext.as_str()))
}

/// Write a ZIP of `sources` to `out`, atomically. Folders are added with
/// everything in them; files are deflated, except those already compressed
/// (photos, videos, other archives), which are stored. Names that clash
/// get a number: `photo (2).jpg`.
///
/// The archive is built in memory, so the files together may hold at most
/// [`Limits::max_memory_bytes`].
pub fn create_zip(sources: &[Source], out: &Path, options: &CreateOptions) -> Result<Created, ArchiveError> {
    let limits = &options.limits;
    if sources.is_empty() {
        return Err(ArchiveError::Invalid("there is nothing to put in the archive".to_owned()));
    }
    let mut plan = Plan { output: fs::metadata(out).is_ok().then(|| out.to_owned()), ..Plan::default() };
    for source in sources {
        let meta = fs::metadata(&source.path).map_err(|e| ArchiveError::io(&source.path, e))?;
        let own_name = source.path.file_name().map(|n| n.to_string_lossy().into_owned());
        let given = source.name.as_deref().map(safe_components).transpose().ok().flatten();
        let mut parts = given.filter(|p| !p.is_empty()).or_else(|| own_name.map(|n| vec![n])).unwrap_or_default();
        let Some(last) = parts.pop() else {
            return Err(ArchiveError::Invalid(format!(
                "'{}' has no name to use in the archive",
                source.path.display()
            )));
        };
        // Folders a given name implies ("docs/2024/a.pdf") come first.
        let mut prefix = String::new();
        for folder in parts {
            let full = format!("{prefix}{folder}/");
            if plan.taken.insert(full.to_lowercase()) {
                plan.push(
                    Planned {
                        name: full.clone(),
                        file: None,
                        modified: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                    },
                    limits,
                )?;
            }
            prefix = full;
        }
        if meta.is_dir() {
            let name = plan.claim(&prefix, &last, true);
            plan.add_folder(&source.path, name, 0, limits)?;
        } else if plan.output.as_deref().is_some_and(|o| same_file(o, &source.path)) {
            return Err(ArchiveError::Invalid("an archive cannot contain itself".to_owned()));
        } else {
            let name = plan.claim(&prefix, &last, false);
            plan.add_file(&source.path, name, &meta, limits)?;
        }
    }

    let mut writer = ZipWriter::new();
    let mut created = Created::default();
    for entry in &plan.entries {
        writer.set_timestamp(dos_from_system(entry.modified, options.utc_offset_minutes));
        let result = match &entry.file {
            None => {
                created.folders += 1;
                writer.add_directory(&entry.name)
            }
            Some(path) => {
                let data = fs::read(path).map_err(|e| ArchiveError::io(path, e))?;
                created.files += 1;
                let compression = if is_compressed(&entry.name) { Compression::Stored } else { Compression::DEFAULT };
                writer.add(&entry.name, &data, compression)
            }
        };
        result.map_err(|e| match e {
            ZipError::Duplicate(name) => ArchiveError::Invalid(format!("'{name}' would be in the archive twice")),
            other => ArchiveError::Corrupt(other.to_string()),
        })?;
    }
    let bytes = writer.finish();
    write_atomically(out, Durability::Synced, |w| {
        w.write_all(&bytes).map_err(|e| ArchiveError::io(out, e))?;
        Ok(bytes.len() as u64)
    })?;
    created.bytes = bytes.len() as u64;
    Ok(created)
}
