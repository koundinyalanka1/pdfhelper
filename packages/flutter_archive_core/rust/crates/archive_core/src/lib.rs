//! Archives, read and written from scratch: browse, extract and create ZIP
//! files, and browse and extract TAR, gzip and gzipped TAR files.
//!
//! [`Archive`] opens an archive from a path or from memory and lists its
//! entries. It reads one entry into memory, extracts one to a path, or
//! extracts everything into a folder. [`create_zip`] packs files and folders
//! into a new ZIP.
//!
//! Archives come from anywhere, so nothing in one is trusted:
//!
//! * Names are reduced to safe relative paths ([`paths`]). Nothing is written
//!   outside the target folder, links are not extracted, and a file already
//!   there is never replaced: the new one is numbered instead.
//! * [`Limits`] bound the number of entries, the total size and how many
//!   times an archive expands, which stops zip bombs before anything is
//!   written.
//! * Every file is written atomically, and checked against its CRC-32 where
//!   the format has one.
//!
//! ZIP files are read through `doc_zip`, which holds the archive in memory;
//! each entry is inflated as a stream, so it never has to fit in memory
//! itself. TAR and gzip files are read front to back and never loaded whole.

mod create;
mod extract;
mod gzip;
pub mod paths;
mod source;
mod tar;
pub mod time;
mod zip;

pub use create::{create_zip, CreateOptions, Created, Source};

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use doc_zip::{Crc32, ZipArchive};

use extract::{write_atomically, Durability, Target};
use gzip::GzReader;
use paths::{display_name, safe_components, safe_path, BadName};
use source::{is_bomb, Data, Input, Limited};
use tar::{looks_like_tar, TarHeader, TarReader, BLOCK};
use time::unix_to_iso;

pub(crate) const NOT_AN_ARCHIVE: &str = "this is not a ZIP, TAR or GZ archive";

/// Kinds of archive this engine reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Zip,
    Tar,
    /// A single gzipped file.
    Gzip,
    /// A gzipped TAR (`.tar.gz`, `.tgz`).
    TarGzip,
}

impl Format {
    /// `zip`, `tar`, `gzip` or `tar.gz`.
    pub fn name(self) -> &'static str {
        match self {
            Format::Zip => "zip",
            Format::Tar => "tar",
            Format::Gzip => "gzip",
            Format::TarGzip => "tar.gz",
        }
    }
}

/// What an entry is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Directory,
    /// Listed, never extracted: a link could point anywhere.
    Symlink,
    HardLink,
    /// A device, pipe or socket.
    Special,
}

impl EntryKind {
    /// `file`, `dir`, `symlink`, `hardlink` or `special`.
    pub fn name(self) -> &'static str {
        match self {
            EntryKind::File => "file",
            EntryKind::Directory => "dir",
            EntryKind::Symlink => "symlink",
            EntryKind::HardLink => "hardlink",
            EntryKind::Special => "special",
        }
    }
}

/// How an entry's data is stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Method {
    Stored,
    Deflated,
    /// A method this engine cannot unpack: `bzip2`, `lzma`, `aes`,
    /// `sparse`, ...
    Unsupported(String),
}

impl Method {
    pub fn name(&self) -> &str {
        match self {
            Method::Stored => "stored",
            Method::Deflated => "deflated",
            Method::Unsupported(name) => name,
        }
    }

    fn describe(&self) -> String {
        match self.name() {
            "sparse" => "GNU sparse storage".to_owned(),
            "multi-volume" => "a multi-volume continuation".to_owned(),
            "aes" => "AES encryption".to_owned(),
            name => format!("{name} compression"),
        }
    }
}

/// One file, folder or link in an archive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Position in the listing, which [`Archive::extract`] takes.
    pub index: usize,
    /// The name exactly as stored: `/`-separated, though some Windows tools
    /// wrote `\`.
    pub path: String,
    /// The last part of the path, for showing in a list.
    pub name: String,
    /// Where [`Archive::extract_all`] puts it, relative to the target folder
    /// and before any " (2)" for a clash; `None` when nothing of the name is
    /// usable (or it names the archive's root folder).
    pub safe_path: Option<String>,
    pub kind: EntryKind,
    /// Uncompressed size in bytes; 0 for folders. A gzip file's is what its
    /// trailer records, which is the size modulo 4 GB.
    pub size: u64,
    /// Bytes the entry takes in the archive, when known (not for the entries
    /// of a gzipped TAR, which is compressed as a whole).
    pub compressed_size: Option<u64>,
    /// Modification time, ISO 8601: local time for ZIP (`2024-03-05T14:30:22`),
    /// UTC for TAR and gzip (`2024-03-05T14:30:22Z`).
    pub modified: Option<String>,
    /// Protected with a password; listed, but cannot be extracted.
    pub encrypted: bool,
    pub method: Method,
}

impl Entry {
    pub fn is_dir(&self) -> bool {
        self.kind == EntryKind::Directory
    }
}

/// Bounds that keep a hostile or broken archive from exhausting memory or
/// storage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Largest ZIP read into memory, largest entry [`Archive::read`]
    /// returns, and most file data [`create_zip`] packs (it builds the
    /// archive in memory).
    pub max_memory_bytes: u64,
    /// Most entries an archive may list.
    pub max_entries: usize,
    /// Largest entry extracted.
    pub max_entry_bytes: u64,
    /// Most an archive may expand to, all entries together.
    pub max_total_bytes: u64,
    /// An archive, or an entry, that expands more than this many times its
    /// compressed size is treated as a zip bomb...
    pub max_ratio: u64,
    /// ...once it expands past this many bytes.
    pub ratio_floor: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_memory_bytes: 512 << 20,
            max_entries: 100_000,
            max_entry_bytes: 4 << 30,
            max_total_bytes: 16 << 30,
            max_ratio: 100,
            ratio_floor: 256 << 20,
        }
    }
}

/// Why an archive could not be read or written, worded for people.
#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("{}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("{0}")]
    Unsupported(String),
    #[error("{0}")]
    Corrupt(String),
    /// The entry's name.
    #[error("'{0}' is protected with a password")]
    Encrypted(String),
    #[error("{0}")]
    TooLarge(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
}

impl ArchiveError {
    pub(crate) fn io(path: &Path, source: io::Error) -> Self {
        ArchiveError::Io { path: path.to_owned(), source }
    }

    /// Whether extracting everything has to stop here, because every later
    /// entry would fail the same way (a full disk, a folder that cannot be
    /// written). Anything else costs only the entry it happened to.
    fn stops_extraction(&self) -> bool {
        matches!(self, ArchiveError::Io { source, .. } if !entry_specific(source))
    }
}

/// I/O errors caused by one entry's name rather than by the storage.
fn entry_specific(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::InvalidInput | io::ErrorKind::InvalidFilename | io::ErrorKind::AlreadyExists)
}

/// What [`Archive::extract_all`] did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Extraction {
    /// Every file written, in archive order. Folders are not listed.
    pub written: Vec<PathBuf>,
    pub skipped: Vec<Skipped>,
}

/// An entry [`Archive::extract_all`] did not write, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Skipped {
    pub index: usize,
    /// The entry's name as stored.
    pub path: String,
    pub reason: String,
}

impl Extraction {
    fn skip(&mut self, entry: &Entry, reason: impl Into<String>) {
        self.skipped.push(Skipped { index: entry.index, path: entry.path.clone(), reason: reason.into() });
    }
}

pub(crate) fn megabytes(bytes: u64) -> u64 {
    bytes >> 20
}

/// A size for messages: `300 MB`, `1.5 GB`.
pub(crate) fn size_text(bytes: u64) -> String {
    const GB: u64 = 1 << 30;
    if bytes >= GB {
        let tenths = (bytes * 10 + GB / 2) / GB;
        if tenths.is_multiple_of(10) {
            format!("{} GB", tenths / 10)
        } else {
            format!("{}.{} GB", tenths / 10, tenths % 10)
        }
    } else {
        format!("{} MB", (bytes + (1 << 20) - 1) >> 20)
    }
}

/// Why copying an entry's data stopped.
pub(crate) enum CopyError {
    Read(io::Error),
    Write(io::Error),
    /// More data than allowed.
    TooLong,
    /// The data does not match what the archive says about it.
    Damaged(String),
}

/// Copy at most `max` bytes from `from` to `to`, returning the count and
/// their CRC-32.
pub(crate) fn copy_limited(from: &mut dyn Read, to: &mut dyn Write, max: u64) -> Result<(u64, u32), CopyError> {
    let mut buf = vec![0u8; 64 << 10];
    let mut total: u64 = 0;
    let mut crc = Crc32::new();
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(CopyError::Read(e)),
        };
        total += n as u64;
        if total > max {
            return Err(CopyError::TooLong);
        }
        crc.update(&buf[..n]);
        to.write_all(&buf[..n]).map_err(CopyError::Write)?;
    }
    Ok((total, crc.finish()))
}

/// Recognise formats this engine does not read, to say which they are.
fn unsupported_kind(head: &[u8]) -> Option<&'static str> {
    let kinds: [(&[u8], &str); 5] = [
        (b"7z\xBC\xAF\x27\x1C", "7-Zip archives (.7z) are not supported yet"),
        (b"Rar!\x1A\x07", "RAR archives are not supported"),
        (b"\xFD7zXZ\x00", "xz files (.xz) are not supported yet"),
        (b"\x28\xB5\x2F\xFD", "Zstandard files (.zst) are not supported yet"),
        (b"MSCF\0\0\0\0", "Windows cabinet files (.cab) are not supported"),
    ];
    if let Some((_, message)) = kinds.iter().find(|(magic, _)| head.starts_with(magic)) {
        return Some(message);
    }
    if head.len() >= 4 && head.starts_with(b"BZh") && (b'1'..=b'9').contains(&head[3]) {
        return Some("bzip2 files (.bz2) are not supported yet");
    }
    None
}

/// Work out the format from the first block of the file (and, for gzip,
/// the first block it inflates to).
fn detect(head: &[u8], data: &Data, name: &str, label: &Path) -> Result<Format, ArchiveError> {
    let lower = name.to_ascii_lowercase();
    if head.starts_with(&gzip::MAGIC) {
        let raw = data.open().map_err(|e| ArchiveError::io(label, e))?;
        let (gz, _) =
            GzReader::new(raw).map_err(|e| ArchiveError::Corrupt(format!("the gzip file is damaged ({e})")))?;
        let mut block = Vec::with_capacity(BLOCK);
        // Damage further in shows up when the file is listed or unpacked.
        let _ = gz.take(BLOCK as u64).read_to_end(&mut block);
        let named_tar = [".tar.gz", ".tgz", ".taz"].iter().any(|s| lower.ends_with(s));
        let empty_tar = named_tar && block.len() == BLOCK && block.iter().all(|&b| b == 0);
        return Ok(if looks_like_tar(&block) || empty_tar { Format::TarGzip } else { Format::Gzip });
    }
    if looks_like_tar(head) || (lower.ends_with(".tar") && head.len() == BLOCK && head.iter().all(|&b| b == 0)) {
        return Ok(Format::Tar);
    }
    if [b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"].iter().any(|magic| head.starts_with(*magic)) {
        return Ok(Format::Zip);
    }
    if let Some(message) = unsupported_kind(head) {
        return Err(ArchiveError::Unsupported(message.to_owned()));
    }
    // A self-extracting archive starts with a program; its ZIP directory
    // still ends within the last 64 KB.
    let tail = data.tail(22 + u16::MAX as u64).map_err(|e| ArchiveError::io(label, e))?;
    if tail.windows(4).any(|w| w == b"PK\x05\x06") {
        return Ok(Format::Zip);
    }
    Err(ArchiveError::Unsupported(NOT_AN_ARCHIVE.to_owned()))
}

/// Refuse an archive that expands beyond the limits, or by a ratio no real
/// archive reaches (a zip bomb), before anything is written.
fn check_expansion(entries: &[Entry], archive_len: u64, limits: &Limits) -> Result<(), ArchiveError> {
    let mut total: u64 = 0;
    for entry in entries {
        total = total.saturating_add(entry.size);
        if let Some(compressed) = entry.compressed_size {
            let ratio = entry.size / compressed.max(1);
            if entry.size > limits.ratio_floor && ratio > limits.max_ratio {
                return Err(ArchiveError::TooLarge(format!(
                    "'{}' would expand {ratio} times, to {}, which looks like a zip bomb",
                    entry.path,
                    size_text(entry.size)
                )));
            }
        }
    }
    if total > limits.max_total_bytes {
        return Err(ArchiveError::TooLarge(format!(
            "the archive would expand to {}; the limit is {}",
            size_text(total),
            size_text(limits.max_total_bytes)
        )));
    }
    let ratio = total / archive_len.max(1);
    if total > limits.ratio_floor && ratio > limits.max_ratio {
        return Err(ArchiveError::TooLarge(format!(
            "the archive would expand {ratio} times, to {}, which looks like a zip bomb",
            size_text(total)
        )));
    }
    Ok(())
}

/// The name of the file inside `archive.gz` when the header gives none.
fn inner_name(archive: &str) -> String {
    let lower = archive.to_ascii_lowercase();
    for suffix in [".gz", ".gzip", ".z"] {
        if lower.ends_with(suffix) && archive.len() > suffix.len() {
            return archive[..archive.len() - suffix.len()].to_owned();
        }
    }
    archive.to_owned()
}

enum Body {
    Zip(Box<ZipArchive>),
    /// TAR and gzip, read afresh for each operation.
    Stream(Data),
}

/// An archive opened for browsing and extracting.
pub struct Archive {
    format: Format,
    entries: Vec<Entry>,
    comment: String,
    limits: Limits,
    /// The archive's path, for messages.
    label: PathBuf,
    /// Its size in bytes.
    len: u64,
    body: Body,
}

impl std::fmt::Debug for Archive {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Archive")
            .field("format", &self.format)
            .field("entries", &self.entries.len())
            .field("bytes", &self.len)
            .finish()
    }
}

impl Archive {
    /// Open the archive at `path`, with the default [`Limits`].
    pub fn open(path: impl AsRef<Path>) -> Result<Self, ArchiveError> {
        Self::open_with_limits(path, Limits::default())
    }

    pub fn open_with_limits(path: impl AsRef<Path>, limits: Limits) -> Result<Self, ArchiveError> {
        let path = path.as_ref();
        let meta = fs::metadata(path).map_err(|e| ArchiveError::io(path, e))?;
        if meta.is_dir() {
            return Err(ArchiveError::Invalid(format!("'{}' is a folder, not an archive", path.display())));
        }
        let mut head = Vec::with_capacity(BLOCK);
        File::open(path)
            .and_then(|f| f.take(BLOCK as u64).read_to_end(&mut head))
            .map_err(|e| ArchiveError::io(path, e))?;
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let data = Data::File(path.to_owned());
        let format = detect(&head, &data, &name, path)?;
        if format != Format::Zip {
            return Self::from_stream(data, format, meta.len(), limits, path.to_owned(), &name);
        }
        if meta.len() > limits.max_memory_bytes {
            return Err(ArchiveError::TooLarge(format!(
                "the archive is {}; ZIP files up to {} can be opened",
                size_text(meta.len()),
                size_text(limits.max_memory_bytes)
            )));
        }
        let bytes = fs::read(path).map_err(|e| ArchiveError::io(path, e))?;
        Self::from_zip(bytes, limits, path.to_owned())
    }

    /// Open an archive held in memory. `name` (a file name such as
    /// `backup.tar.gz`) names a gzipped file's contents when its header does
    /// not, and tells an empty TAR from random zeros.
    pub fn from_bytes(bytes: Vec<u8>, name: Option<&str>) -> Result<Self, ArchiveError> {
        Self::from_bytes_with_limits(bytes, name, Limits::default())
    }

    pub fn from_bytes_with_limits(bytes: Vec<u8>, name: Option<&str>, limits: Limits) -> Result<Self, ArchiveError> {
        let name = name.unwrap_or("archive");
        let label = PathBuf::from(name);
        let head = bytes[..bytes.len().min(BLOCK)].to_vec();
        let len = bytes.len() as u64;
        let data = Data::Memory(bytes);
        let format = detect(&head, &data, name, &label)?;
        match data {
            Data::Memory(bytes) if format == Format::Zip => Self::from_zip(bytes, limits, label),
            data => Self::from_stream(data, format, len, limits, label, name),
        }
    }

    fn from_zip(bytes: Vec<u8>, limits: Limits, label: PathBuf) -> Result<Self, ArchiveError> {
        let len = bytes.len() as u64;
        let zip = zip::open(bytes, &limits)?;
        let entries = zip::entries(&zip);
        check_expansion(&entries, len, &limits)?;
        Ok(Self {
            format: Format::Zip,
            comment: zip::comment(&zip),
            entries,
            limits,
            label,
            len,
            body: Body::Zip(Box::new(zip)),
        })
    }

    fn from_stream(
        data: Data,
        format: Format,
        len: u64,
        limits: Limits,
        label: PathBuf,
        name: &str,
    ) -> Result<Self, ArchiveError> {
        let mut archive =
            Self { format, entries: Vec::new(), comment: String::new(), limits, label, len, body: Body::Stream(data) };
        if format == Format::Gzip {
            archive.list_gzip(name)?;
        } else {
            archive.entries = archive.list_tar()?;
        }
        // A plain TAR holds its files as they are, so it cannot expand; one
        // whose sizes add up to more than the file is cut short, which
        // extracting reports entry by entry.
        if format != Format::Tar {
            check_expansion(&archive.entries, len, &limits)?;
        }
        Ok(archive)
    }

    pub fn format(&self) -> Format {
        self.format
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// The archive's comment (ZIP) or the gzip header's; often empty.
    pub fn comment(&self) -> &str {
        &self.comment
    }

    pub fn entry(&self, index: usize) -> Result<&Entry, ArchiveError> {
        self.entries.get(index).ok_or_else(|| ArchiveError::NotFound(format!("the archive has no entry {index}")))
    }

    /// Read a file entry into memory: at most [`Limits::max_memory_bytes`].
    pub fn read(&self, index: usize) -> Result<Vec<u8>, ArchiveError> {
        let entry = self.entry(index)?;
        let max = self.limits.max_memory_bytes;
        self.check_extractable(entry, max)?;
        let mut out = Vec::new();
        self.copy_entry(entry, &mut out, None, max)?;
        Ok(out)
    }

    /// Extract a file entry to `out`, replacing it atomically if it exists.
    /// Returns the number of bytes written.
    pub fn extract(&self, index: usize, out: &Path) -> Result<u64, ArchiveError> {
        let entry = self.entry(index)?;
        let max = self.limits.max_entry_bytes;
        self.check_extractable(entry, max)?;
        write_atomically(out, Durability::Synced, |w| self.copy_entry(entry, w, Some(out), max))
    }

    /// Extract everything into the folder `out_dir`, creating it if needed.
    ///
    /// Entries are written under their [`Entry::safe_path`], so nothing
    /// lands outside `out_dir`; files already there are kept, and a new file
    /// whose name is taken is numbered (`photo (2).jpg`). Links, encrypted
    /// entries, unsupported methods and damaged data are skipped and
    /// reported; only a failure that would stop every later entry too (a
    /// full disk, a folder that cannot be written) fails the whole call.
    pub fn extract_all(&self, out_dir: &Path) -> Result<Extraction, ArchiveError> {
        let mut target = Target::new(out_dir)?;
        let mut report = Extraction::default();
        let max = self.limits.max_entry_bytes;
        if matches!(self.format, Format::Zip | Format::Gzip) {
            for entry in &self.entries {
                self.unpack(&mut target, entry, &mut report, |w, path| self.copy_entry(entry, w, Some(path), max))?;
            }
            return Ok(report);
        }
        // TAR is read once, front to back, in step with the listing.
        let mut reader = TarReader::new(self.input()?);
        for entry in &self.entries {
            match reader.next() {
                Ok(Some(_)) => {}
                // The file itself could not be read: every later entry
                // would fail too.
                Err(e) if !damaged(&e) && !is_bomb(&e) => return Err(self.read_error(e, None)),
                Ok(None) | Err(_) => {
                    for rest in &self.entries[entry.index..] {
                        report.skip(rest, "the archive ends, or is damaged, before it");
                    }
                    break;
                }
            }
            self.unpack(&mut target, entry, &mut report, |w, path| self.copy_tar(&mut reader, entry, w, Some(path)))?;
        }
        Ok(report)
    }

    /// Why `entry` cannot be extracted, if it cannot.
    fn check_extractable(&self, entry: &Entry, max: u64) -> Result<(), ArchiveError> {
        let what = &entry.path;
        let not_extracted = match entry.kind {
            EntryKind::File => None,
            EntryKind::Directory => return Err(ArchiveError::Invalid(format!("'{what}' is a folder"))),
            EntryKind::Symlink => Some("a symbolic link"),
            EntryKind::HardLink => Some("a hard link"),
            EntryKind::Special => Some("a device or other special file"),
        };
        if let Some(kind) = not_extracted {
            return Err(ArchiveError::Unsupported(format!("'{what}' is {kind}, which is not extracted")));
        }
        if entry.encrypted {
            return Err(ArchiveError::Encrypted(what.clone()));
        }
        if let Method::Unsupported(_) = entry.method {
            return Err(ArchiveError::Unsupported(format!(
                "'{what}' uses {}, which is not supported",
                entry.method.describe()
            )));
        }
        if entry.size > max {
            return Err(ArchiveError::TooLarge(format!(
                "'{what}' is {}; the limit is {}",
                size_text(entry.size),
                size_text(max)
            )));
        }
        Ok(())
    }

    /// Extract one entry into `target` while extracting everything, and
    /// record what happened. `copy` writes the entry's data.
    fn unpack(
        &self,
        target: &mut Target,
        entry: &Entry,
        report: &mut Extraction,
        copy: impl FnOnce(&mut dyn Write, &Path) -> Result<u64, ArchiveError>,
    ) -> Result<(), ArchiveError> {
        let components = match &entry.safe_path {
            Some(path) => path.split('/').map(str::to_owned).collect(),
            None => match safe_components(&entry.path) {
                Err(BadName::Nul) => {
                    report.skip(entry, "its name contains a NUL character");
                    return Ok(());
                }
                Ok(_) => Vec::new(),
            },
        };
        if entry.kind == EntryKind::Directory {
            // A folder naming the archive's root (`./`) needs nothing done.
            if !components.is_empty() {
                if let Err(e) = target.folder(&components) {
                    return io_failure(e, entry, report, target.root());
                }
            }
            return Ok(());
        }
        if let Err(e) = self.check_extractable(entry, self.limits.max_entry_bytes) {
            report.skip(entry, e.to_string());
            return Ok(());
        }
        if components.is_empty() {
            report.skip(entry, "its name has no usable characters");
            return Ok(());
        }
        let path = match target.file(&components) {
            Ok(path) => path,
            Err(e) => return io_failure(e, entry, report, target.root()),
        };
        // The name was free, so nothing is replaced and the file need not be
        // flushed before it takes it.
        match write_atomically(&path, Durability::Renamed, |w| copy(w, &path)) {
            Ok(_) => report.written.push(path),
            Err(e) if e.stops_extraction() => return Err(e),
            Err(ArchiveError::Io { source, .. }) => {
                report.skip(entry, format!("it could not be saved here ({source})"))
            }
            Err(e) => report.skip(entry, e.to_string()),
        }
        Ok(())
    }

    /// A fresh stream of a TAR or gzip archive's contents, inflated when
    /// gzipped, and cut off if it expands like a zip bomb.
    fn input(&self) -> Result<Box<dyn Input + '_>, ArchiveError> {
        let Body::Stream(data) = &self.body else {
            return Err(ArchiveError::Invalid("a ZIP archive is not read as a stream".to_owned()));
        };
        let raw = data.open().map_err(|e| ArchiveError::io(&self.label, e))?;
        if self.format == Format::Tar {
            return Ok(Box::new(raw));
        }
        let (gz, _) = GzReader::new(raw).map_err(|e| self.read_error(e, None))?;
        Ok(Box::new(Limited::new(gz, self.inflate_limit())))
    }

    /// The most a gzip stream may inflate to: `max_ratio` times its size, but
    /// at least `ratio_floor` and at most `max_total_bytes`.
    fn inflate_limit(&self) -> u64 {
        self.limits.max_ratio.saturating_mul(self.len).max(self.limits.ratio_floor).min(self.limits.max_total_bytes)
    }

    fn read_error(&self, e: io::Error, entry: Option<&str>) -> ArchiveError {
        if is_bomb(&e) {
            return ArchiveError::TooLarge(format!(
                "the archive expands to more than {}, far more than its size, which looks like a zip bomb",
                size_text(self.inflate_limit())
            ));
        }
        match e.kind() {
            io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput | io::ErrorKind::UnexpectedEof => {
                ArchiveError::Corrupt(match entry {
                    Some(name) => format!("'{name}' is damaged ({e})"),
                    None => format!("the archive is damaged ({e})"),
                })
            }
            _ => ArchiveError::io(&self.label, e),
        }
    }

    fn copy_error(&self, e: CopyError, entry: &Entry, out: Option<&Path>, max: u64) -> ArchiveError {
        match e {
            CopyError::Read(e) => self.read_error(e, Some(&entry.path)),
            CopyError::Write(e) => ArchiveError::io(out.unwrap_or(&self.label), e),
            CopyError::TooLong => ArchiveError::TooLarge(format!("'{}' is larger than {}", entry.path, size_text(max))),
            CopyError::Damaged(why) => ArchiveError::Corrupt(format!("'{}' is damaged ({why})", entry.path)),
        }
    }

    /// Write a file entry's data to `out` (the file at `out_path`, if any);
    /// `max` caps entries whose size is not known in advance.
    fn copy_entry(
        &self,
        entry: &Entry,
        out: &mut dyn Write,
        out_path: Option<&Path>,
        max: u64,
    ) -> Result<u64, ArchiveError> {
        match &self.body {
            Body::Zip(zip) => zip::copy(zip, entry.index, out).map_err(|e| self.copy_error(e, entry, out_path, max)),
            Body::Stream(_) if self.format == Format::Gzip => {
                let mut input = self.input()?;
                copy_limited(&mut input, out, max)
                    .map(|(written, _)| written)
                    .map_err(|e| self.copy_error(e, entry, out_path, max))
            }
            Body::Stream(_) => {
                let mut reader = TarReader::new(self.input()?);
                for _ in 0..=entry.index {
                    if reader.next().map_err(|e| self.read_error(e, None))?.is_none() {
                        return Err(ArchiveError::Corrupt(format!(
                            "the archive ends before '{}'; it may have changed since it was opened",
                            entry.path
                        )));
                    }
                }
                self.copy_tar(&mut reader, entry, out, out_path)
            }
        }
    }

    /// Write the current TAR entry's data, all `entry.size` bytes of it.
    fn copy_tar<R: Input>(
        &self,
        reader: &mut TarReader<R>,
        entry: &Entry,
        out: &mut dyn Write,
        out_path: Option<&Path>,
    ) -> Result<u64, ArchiveError> {
        copy_limited(reader, out, entry.size)
            .and_then(|(written, _)| {
                if written == entry.size {
                    Ok(written)
                } else {
                    Err(CopyError::Damaged("it is shorter than the archive says".to_owned()))
                }
            })
            .map_err(|e| self.copy_error(e, entry, out_path, entry.size))
    }

    fn list_gzip(&mut self, archive_name: &str) -> Result<(), ArchiveError> {
        let Body::Stream(data) = &self.body else {
            return Ok(());
        };
        let raw = data.open().map_err(|e| ArchiveError::io(&self.label, e))?;
        let (_, header) = GzReader::new(raw).map_err(|e| self.read_error(e, None))?;
        let path = header.name.clone().unwrap_or_else(|| inner_name(archive_name));
        // gzip keeps a bare file name; never let one choose a folder.
        let name = display_name(&path);
        let trailer = data.tail(4).map_err(|e| ArchiveError::io(&self.label, e))?;
        let size = match trailer[..] {
            [a, b, c, d] if self.len >= 18 => u32::from_le_bytes([a, b, c, d]) as u64,
            _ => 0,
        };
        self.entries = vec![Entry {
            index: 0,
            safe_path: safe_path(&name),
            name,
            path,
            kind: EntryKind::File,
            size,
            compressed_size: Some(self.len),
            modified: header.mtime.and_then(unix_to_iso),
            encrypted: false,
            method: Method::Deflated,
        }];
        self.comment = header.comment.unwrap_or_default();
        Ok(())
    }

    fn list_tar(&self) -> Result<Vec<Entry>, ArchiveError> {
        let gzipped = self.format == Format::TarGzip;
        let mut reader = TarReader::new(self.input()?);
        let mut entries = Vec::new();
        loop {
            let header: TarHeader = match reader.next() {
                Ok(Some(header)) => header,
                Ok(None) => break,
                // A truncated download lists what arrived; extracting the
                // entry cut short reports it.
                Err(e) if !entries.is_empty() && !is_bomb(&e) && damaged(&e) => break,
                Err(e) => return Err(self.read_error(e, None)),
            };
            if entries.len() >= self.limits.max_entries {
                return Err(ArchiveError::TooLarge(format!(
                    "the archive lists more than {} entries",
                    self.limits.max_entries
                )));
            }
            let method = match header.method {
                Method::Stored if gzipped => Method::Deflated,
                method => method,
            };
            entries.push(Entry {
                index: entries.len(),
                name: display_name(&header.path),
                safe_path: safe_path(&header.path),
                kind: header.kind,
                size: header.size,
                compressed_size: (!gzipped).then_some(header.size),
                modified: header.mtime.and_then(unix_to_iso),
                encrypted: false,
                method,
                path: header.path,
            });
        }
        Ok(entries)
    }
}

/// Errors that mean the archive's data is broken, rather than unreadable.
fn damaged(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput | io::ErrorKind::UnexpectedEof)
}

/// A file or folder of the target could not be made: skip the entry when
/// its name is to blame, stop when the storage is.
fn io_failure(e: io::Error, entry: &Entry, report: &mut Extraction, root: &Path) -> Result<(), ArchiveError> {
    if entry_specific(&e) {
        report.skip(entry, format!("it could not be saved here ({e})"));
        Ok(())
    } else {
        Err(ArchiveError::io(root, e))
    }
}

#[cfg(test)]
mod tests;
