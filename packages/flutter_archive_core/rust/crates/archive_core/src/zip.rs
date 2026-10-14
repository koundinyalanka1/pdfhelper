//! ZIP archives, through `doc_zip`: the listing, and each entry unpacked as a
//! stream, so an entry larger than memory can still be extracted.

use std::io::{Read, Write};

use doc_zip::{ReadLimits, ZipArchive, ZipEntry, ZipError, METHOD_DEFLATED, METHOD_STORED};

use crate::paths::{display_name, safe_path};
use crate::time::dos_to_iso;
use crate::{copy_limited, ArchiveError, CopyError, Entry, EntryKind, Limits, Method, NOT_AN_ARCHIVE};

/// Unix file types, kept in the high half of the external attributes.
const S_IFMT: u32 = 0o170_000;
const S_IFREG: u32 = 0o100_000;
const S_IFDIR: u32 = 0o040_000;
const S_IFLNK: u32 = 0o120_000;

/// The MS-DOS directory attribute.
const DOS_DIRECTORY: u32 = 0x10;

pub(crate) fn open(bytes: Vec<u8>, limits: &Limits) -> Result<ZipArchive, ArchiveError> {
    let looks_like_zip = bytes.starts_with(b"PK\x03\x04");
    let read_limits = ReadLimits { max_entry_size: limits.max_entry_bytes, max_entries: limits.max_entries };
    ZipArchive::with_limits(bytes, read_limits).map_err(|e| match e {
        ZipError::NotZip if looks_like_zip => ArchiveError::Corrupt(
            "the ZIP archive is incomplete or damaged (its list of contents is missing)".to_owned(),
        ),
        ZipError::NotZip => ArchiveError::Unsupported(NOT_AN_ARCHIVE.to_owned()),
        ZipError::TooLarge(_) => {
            ArchiveError::TooLarge(format!("the archive lists more than {} entries", limits.max_entries))
        }
        ZipError::Corrupt(m) => ArchiveError::Corrupt(format!("the ZIP archive is damaged: {m}")),
        other => ArchiveError::Corrupt(other.to_string()),
    })
}

fn kind(entry: &ZipEntry) -> EntryKind {
    let host = entry.version_made_by >> 8;
    // Unix (3) and macOS (19) writers record the file's mode.
    if host == 3 || host == 19 {
        match (entry.external_attributes >> 16) & S_IFMT {
            0 | S_IFREG => {}
            S_IFDIR => return EntryKind::Directory,
            S_IFLNK => return EntryKind::Symlink,
            _ => return EntryKind::Special,
        }
    }
    if entry.name.ends_with('/') || entry.name.ends_with('\\') {
        return EntryKind::Directory;
    }
    if entry.external_attributes & DOS_DIRECTORY != 0 && entry.size == 0 && entry.compressed_size == 0 {
        return EntryKind::Directory;
    }
    EntryKind::File
}

fn method(code: u16) -> Method {
    let name = match code {
        METHOD_STORED => return Method::Stored,
        METHOD_DEFLATED => return Method::Deflated,
        1 => "shrink",
        2..=5 => "reduce",
        6 => "implode",
        9 => "deflate64",
        12 => "bzip2",
        14 => "lzma",
        93 => "zstd",
        95 => "xz",
        96 => "jpeg",
        97 => "wavpack",
        98 => "ppmd",
        99 => "aes",
        other => return Method::Unsupported(format!("method {other}")),
    };
    Method::Unsupported(name.to_owned())
}

pub(crate) fn entries(zip: &ZipArchive) -> Vec<Entry> {
    zip.entries()
        .iter()
        .enumerate()
        .map(|(index, e)| {
            let kind = kind(e);
            Entry {
                index,
                path: e.name.clone(),
                name: display_name(&e.name),
                safe_path: safe_path(&e.name),
                kind,
                size: if kind == EntryKind::Directory { 0 } else { e.size },
                compressed_size: Some(e.compressed_size),
                modified: dos_to_iso(e.dos_date, e.dos_time),
                encrypted: e.is_encrypted(),
                method: method(e.method),
            }
        })
        .collect()
}

pub(crate) fn comment(zip: &ZipArchive) -> String {
    String::from_utf8_lossy(zip.comment()).into_owned()
}

/// Unpack entry `index` into `out`, checking its length and checksum against
/// the directory. The caller has checked that it is a file this engine can
/// unpack.
pub(crate) fn copy(zip: &ZipArchive, index: usize, out: &mut dyn Write) -> Result<u64, CopyError> {
    let entry = &zip.entries()[index];
    let raw = zip.raw_data(index);
    let mut reader: Box<dyn Read + '_> = match entry.method {
        METHOD_DEFLATED => Box::new(flate2::read::DeflateDecoder::new(raw)),
        _ => Box::new(raw),
    };
    let (written, crc) = copy_limited(&mut reader, out, entry.size).map_err(|e| match e {
        CopyError::TooLong => CopyError::Damaged("it is longer than the archive says".to_owned()),
        e => e,
    })?;
    if written != entry.size {
        return Err(CopyError::Damaged("it is shorter than the archive says".to_owned()));
    }
    if crc != entry.crc32 {
        return Err(CopyError::Damaged("its checksum does not match".to_owned()));
    }
    Ok(written)
}
