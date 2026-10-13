//! Reading ZIP archives from memory.

use std::collections::HashMap;
use std::io::Read;

use crate::{cp437, crc32, ZipError, METHOD_DEFLATED, METHOD_STORED};

pub(crate) const SIG_LOCAL: u32 = 0x0403_4b50;
pub(crate) const SIG_CENTRAL: u32 = 0x0201_4b50;
pub(crate) const SIG_EOCD: u32 = 0x0605_4b50;
pub(crate) const SIG_EOCD64: u32 = 0x0606_4b50;
pub(crate) const SIG_EOCD64_LOCATOR: u32 = 0x0706_4b50;

const EOCD_LEN: usize = 22;
const CENTRAL_LEN: usize = 46;
const LOCAL_LEN: usize = 30;

/// Bounds that keep a hostile or broken archive from exhausting memory.
#[derive(Clone, Copy, Debug)]
pub struct ReadLimits {
    /// Largest single entry, uncompressed, in bytes.
    pub max_entry_size: u64,
    /// Most entries an archive may list.
    pub max_entries: usize,
}

impl Default for ReadLimits {
    fn default() -> Self {
        Self {
            max_entry_size: 512 << 20,
            max_entries: 200_000,
        }
    }
}

/// One file or directory in an archive, as its central directory describes it.
#[derive(Clone, Debug)]
pub struct ZipEntry {
    /// The entry's path inside the archive, `/`-separated.
    pub name: String,
    pub method: u16,
    pub flags: u16,
    pub crc32: u32,
    pub compressed_size: u64,
    /// Uncompressed size.
    pub size: u64,
    pub dos_time: u16,
    pub dos_date: u16,
    pub external_attributes: u32,
    pub version_made_by: u16,
    /// Where the entry's compressed bytes start.
    pub(crate) data_offset: u64,
    /// The name exactly as stored, so a copied entry keeps it.
    pub(crate) raw_name: Vec<u8>,
}

impl ZipEntry {
    pub fn is_dir(&self) -> bool {
        self.name.ends_with('/')
    }

    pub fn is_encrypted(&self) -> bool {
        self.flags & 1 != 0
    }
}

/// A ZIP archive held in memory.
pub struct ZipArchive {
    data: Vec<u8>,
    entries: Vec<ZipEntry>,
    exact: HashMap<String, usize>,
    folded: HashMap<String, usize>,
    limits: ReadLimits,
    comment: Vec<u8>,
}

impl std::fmt::Debug for ZipArchive {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZipArchive")
            .field("bytes", &self.data.len())
            .field("entries", &self.entries.len())
            .finish()
    }
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    let bytes = data.get(at..at.checked_add(2)?)?;
    Some(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    let bytes = data.get(at..at.checked_add(4)?)?;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn u64_at(data: &[u8], at: usize) -> Option<u64> {
    let bytes = data.get(at..at.checked_add(8)?)?;
    let mut buf = [0u8; 8];
    buf.copy_from_slice(bytes);
    Some(u64::from_le_bytes(buf))
}

fn corrupt(message: impl Into<String>) -> ZipError {
    ZipError::Corrupt(message.into())
}

/// Locate the end-of-central-directory record: the last signature whose
/// comment length fits inside the file.
fn find_eocd(data: &[u8]) -> Option<usize> {
    if data.len() < EOCD_LEN {
        return None;
    }
    let last = data.len() - EOCD_LEN;
    let first = last.saturating_sub(u16::MAX as usize);
    let mut pos = last;
    loop {
        if u32_at(data, pos) == Some(SIG_EOCD) {
            let comment = u16_at(data, pos + 20)? as usize;
            if pos + EOCD_LEN + comment <= data.len() {
                return Some(pos);
            }
        }
        if pos == first {
            return None;
        }
        pos -= 1;
    }
}

struct Directory {
    entries: u64,
    size: u64,
    offset: u64,
    /// Where the directory must end: the ZIP64 record if there is one,
    /// otherwise the end record.
    end: u64,
}

fn read_directory(data: &[u8], eocd: usize) -> Result<Directory, ZipError> {
    let entries = u16_at(data, eocd + 10).ok_or_else(|| corrupt("truncated end record"))?;
    let size = u32_at(data, eocd + 12).ok_or_else(|| corrupt("truncated end record"))?;
    let offset = u32_at(data, eocd + 16).ok_or_else(|| corrupt("truncated end record"))?;
    let mut dir = Directory {
        entries: entries as u64,
        size: size as u64,
        offset: offset as u64,
        end: eocd as u64,
    };
    let wants_zip64 = entries == u16::MAX || size == u32::MAX || offset == u32::MAX;
    let locator = eocd.checked_sub(20);
    let has_locator = locator.is_some_and(|at| u32_at(data, at) == Some(SIG_EOCD64_LOCATOR));
    if !(wants_zip64 || has_locator) {
        return Ok(dir);
    }
    let Some(locator) = locator.filter(|_| has_locator) else {
        return Err(corrupt("ZIP64 end record is missing"));
    };
    // The locator gives the record's absolute offset, which is wrong when
    // bytes were prepended to the archive; the record normally sits right
    // before the locator, so look there too.
    let stated = u64_at(data, locator + 8).ok_or_else(|| corrupt("truncated ZIP64 locator"))?;
    let candidates = [usize::try_from(stated).ok(), locator.checked_sub(56)];
    let record = candidates
        .into_iter()
        .flatten()
        .find(|&at| u32_at(data, at) == Some(SIG_EOCD64))
        .ok_or_else(|| corrupt("ZIP64 end record is missing"))?;
    dir.entries = u64_at(data, record + 32).ok_or_else(|| corrupt("truncated ZIP64 record"))?;
    dir.size = u64_at(data, record + 40).ok_or_else(|| corrupt("truncated ZIP64 record"))?;
    dir.offset = u64_at(data, record + 48).ok_or_else(|| corrupt("truncated ZIP64 record"))?;
    dir.end = record as u64;
    Ok(dir)
}

/// Decode an entry name: UTF-8 when flagged or when it is valid UTF-8,
/// otherwise CP437 as the specification says.
fn decode_name(raw: &[u8], flags: u16) -> String {
    if flags & (1 << 11) != 0 {
        return String::from_utf8_lossy(raw).into_owned();
    }
    match std::str::from_utf8(raw) {
        Ok(text) => text.to_owned(),
        Err(_) => cp437::decode(raw),
    }
}

/// Values the ZIP64 extra field replaces, in the order the field stores them.
struct Zip64Fields<'a> {
    size: &'a mut u64,
    compressed: &'a mut u64,
    offset: &'a mut u64,
}

fn apply_extra(extra: &[u8], raw_name: &[u8], name: &mut String, fields: Zip64Fields<'_>) {
    let mut at = 0;
    while at + 4 <= extra.len() {
        let id = u16::from_le_bytes([extra[at], extra[at + 1]]);
        let len = u16::from_le_bytes([extra[at + 2], extra[at + 3]]) as usize;
        let body_start = at + 4;
        let Some(body) = extra.get(body_start..body_start + len) else {
            break;
        };
        match id {
            0x0001 => {
                let mut pos = 0;
                for (value, sentinel) in [
                    (&mut *fields.size, u32::MAX as u64),
                    (&mut *fields.compressed, u32::MAX as u64),
                    (&mut *fields.offset, u32::MAX as u64),
                ] {
                    if *value == sentinel {
                        if let Some(wide) = u64_at(body, pos) {
                            *value = wide;
                            pos += 8;
                        }
                    }
                }
            }
            // Info-ZIP Unicode path: valid only if it was written for this name.
            0x7075 if body.len() > 5 && body[0] == 1 => {
                let expected = u32::from_le_bytes([body[1], body[2], body[3], body[4]]);
                if crc32(raw_name) == expected {
                    if let Ok(text) = std::str::from_utf8(&body[5..]) {
                        *name = text.to_owned();
                    }
                }
            }
            _ => {}
        }
        at = body_start + len;
    }
}

impl ZipArchive {
    /// Parse an archive with the default [`ReadLimits`].
    pub fn new(data: Vec<u8>) -> Result<Self, ZipError> {
        Self::with_limits(data, ReadLimits::default())
    }

    pub fn with_limits(data: Vec<u8>, limits: ReadLimits) -> Result<Self, ZipError> {
        let eocd = find_eocd(&data).ok_or(ZipError::NotZip)?;
        let comment_len = u16_at(&data, eocd + 20).unwrap_or(0) as usize;
        let comment = data[eocd + EOCD_LEN..eocd + EOCD_LEN + comment_len].to_vec();
        let dir = read_directory(&data, eocd)?;

        // Bytes prepended to an archive (a self-extractor stub, say) shift
        // every stored offset by the same amount.
        let stated_end = dir
            .offset
            .checked_add(dir.size)
            .ok_or_else(|| corrupt("directory size overflows"))?;
        if stated_end > dir.end {
            return Err(corrupt("central directory runs past the end record"));
        }
        let shift = dir.end - stated_end;
        let start = usize::try_from(dir.offset + shift).map_err(|_| corrupt("bad directory offset"))?;
        let end = usize::try_from(dir.end).map_err(|_| corrupt("bad directory end"))?;

        let mut entries = Vec::new();
        let mut at = start;
        while at + CENTRAL_LEN <= end && u32_at(&data, at) == Some(SIG_CENTRAL) {
            if entries.len() >= limits.max_entries {
                return Err(ZipError::TooLarge("archive directory".into()));
            }
            let header = &data[at..at + CENTRAL_LEN];
            let field16 = |offset: usize| u16::from_le_bytes([header[offset], header[offset + 1]]);
            let field32 = |offset: usize| {
                u32::from_le_bytes([
                    header[offset],
                    header[offset + 1],
                    header[offset + 2],
                    header[offset + 3],
                ])
            };
            let name_len = field16(28) as usize;
            let extra_len = field16(30) as usize;
            let comment_len = field16(32) as usize;
            let name_start = at + CENTRAL_LEN;
            let extra_start = name_start + name_len;
            let next = extra_start + extra_len + comment_len;
            if next > end {
                return Err(corrupt("central directory entry runs past its end"));
            }
            let raw_name = data[name_start..extra_start].to_vec();
            let flags = field16(8);
            let mut name = decode_name(&raw_name, flags);
            let mut size = field32(24) as u64;
            let mut compressed_size = field32(20) as u64;
            let mut header_offset = field32(42) as u64;
            apply_extra(
                &data[extra_start..extra_start + extra_len],
                &raw_name,
                &mut name,
                Zip64Fields {
                    size: &mut size,
                    compressed: &mut compressed_size,
                    offset: &mut header_offset,
                },
            );
            entries.push(ZipEntry {
                name,
                method: field16(10),
                flags,
                crc32: field32(16),
                compressed_size,
                size,
                dos_time: field16(12),
                dos_date: field16(14),
                external_attributes: field32(38),
                version_made_by: field16(4),
                data_offset: header_offset + shift,
                raw_name,
            });
            at = next;
        }
        if entries.is_empty() && dir.entries > 0 {
            return Err(corrupt("central directory is unreadable"));
        }

        // Resolve each entry's data through its local header.
        for entry in &mut entries {
            let local = usize::try_from(entry.data_offset).map_err(|_| corrupt("bad entry offset"))?;
            if u32_at(&data, local) != Some(SIG_LOCAL) {
                return Err(corrupt(format!("'{}' has no local header", entry.name)));
            }
            let name_len = u16_at(&data, local + 26).ok_or_else(|| corrupt("truncated local header"))? as u64;
            let extra_len = u16_at(&data, local + 28).ok_or_else(|| corrupt("truncated local header"))? as u64;
            entry.data_offset = local as u64 + LOCAL_LEN as u64 + name_len + extra_len;
            let data_end = entry
                .data_offset
                .checked_add(entry.compressed_size)
                .ok_or_else(|| corrupt("entry size overflows"))?;
            if data_end > data.len() as u64 {
                return Err(corrupt(format!("'{}' is truncated", entry.name)));
            }
        }

        let mut exact = HashMap::with_capacity(entries.len());
        let mut folded = HashMap::with_capacity(entries.len());
        for (index, entry) in entries.iter().enumerate() {
            exact.entry(entry.name.clone()).or_insert(index);
            folded.entry(entry.name.to_ascii_lowercase()).or_insert(index);
        }
        Ok(Self {
            data,
            entries,
            exact,
            folded,
            limits,
            comment,
        })
    }

    pub fn entries(&self) -> &[ZipEntry] {
        &self.entries
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn comment(&self) -> &[u8] {
        &self.comment
    }

    /// The archive's bytes, as given to [`ZipArchive::new`].
    pub fn bytes(&self) -> &[u8] {
        &self.data
    }

    /// Find an entry by name. A leading `/` is ignored, and when no entry
    /// matches exactly, ASCII case is ignored too: OOXML part names are
    /// case-insensitive, and some writers disagree on case.
    pub fn find(&self, name: &str) -> Option<usize> {
        let name = name.strip_prefix('/').unwrap_or(name);
        self.exact
            .get(name)
            .or_else(|| self.folded.get(&name.to_ascii_lowercase()))
            .copied()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.find(name).is_some()
    }

    /// The entry's compressed bytes, exactly as stored.
    pub fn raw_data(&self, index: usize) -> &[u8] {
        let entry = &self.entries[index];
        let start = entry.data_offset as usize;
        &self.data[start..start + entry.compressed_size as usize]
    }

    /// Decompress an entry, verifying its size and checksum.
    pub fn read(&self, index: usize) -> Result<Vec<u8>, ZipError> {
        self.read_inner(index, true)
    }

    /// Decompress an entry without verifying its size or checksum, to salvage
    /// what a damaged archive still holds.
    pub fn read_unchecked(&self, index: usize) -> Result<Vec<u8>, ZipError> {
        self.read_inner(index, false)
    }

    /// Decompress an entry by name.
    pub fn read_named(&self, name: &str) -> Result<Vec<u8>, ZipError> {
        let index = self.find(name).ok_or_else(|| ZipError::Missing(name.to_owned()))?;
        self.read(index)
    }

    fn read_inner(&self, index: usize, verify: bool) -> Result<Vec<u8>, ZipError> {
        let entry = &self.entries[index];
        if entry.is_encrypted() {
            return Err(ZipError::Encrypted(entry.name.clone()));
        }
        let limit = self.limits.max_entry_size;
        if verify && entry.size > limit {
            return Err(ZipError::TooLarge(entry.name.clone()));
        }
        let raw = self.raw_data(index);
        let out = match entry.method {
            METHOD_STORED => {
                if raw.len() as u64 > limit {
                    return Err(ZipError::TooLarge(entry.name.clone()));
                }
                raw.to_vec()
            }
            METHOD_DEFLATED => {
                let capacity = entry.size.min(limit).min(64 << 20) as usize;
                let mut out = Vec::with_capacity(capacity);
                let decoder = flate2::read::DeflateDecoder::new(raw);
                match decoder.take(limit + 1).read_to_end(&mut out) {
                    Ok(_) => {}
                    Err(_) if !verify && !out.is_empty() => {}
                    Err(_) => return Err(corrupt(format!("'{}' has damaged compressed data", entry.name))),
                }
                if out.len() as u64 > limit {
                    return Err(ZipError::TooLarge(entry.name.clone()));
                }
                out
            }
            method => {
                return Err(ZipError::UnsupportedMethod {
                    name: entry.name.clone(),
                    method,
                })
            }
        };
        if verify {
            if out.len() as u64 != entry.size {
                return Err(corrupt(format!("'{}' has the wrong size", entry.name)));
            }
            if crc32(&out) != entry.crc32 {
                return Err(ZipError::Checksum(entry.name.clone()));
            }
        }
        Ok(out)
    }
}
