//! Writing ZIP archives to memory.

use std::collections::HashSet;
use std::io::Write;

use crate::read::{SIG_CENTRAL, SIG_EOCD, SIG_EOCD64, SIG_EOCD64_LOCATOR, SIG_LOCAL};
use crate::{crc32, ZipArchive, ZipError, METHOD_DEFLATED, METHOD_STORED};

/// How to store a new entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compression {
    Stored,
    /// Deflate at a level from 1 (fastest) to 9 (smallest).
    Deflated(u32),
}

impl Compression {
    /// The level Office and LibreOffice use for their packages.
    pub const DEFAULT: Compression = Compression::Deflated(6);
}

/// An MS-DOS timestamp, the only kind the basic ZIP headers hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DosDateTime {
    pub date: u16,
    pub time: u16,
}

impl DosDateTime {
    /// 1980-01-01 00:00:00, the earliest DOS time. Microsoft Office stamps
    /// every entry of its packages with it, which keeps saves reproducible.
    pub const EPOCH: DosDateTime = DosDateTime {
        date: (1 << 5) | 1,
        time: 0,
    };

    /// A civil date and time. Years outside 1980..=2107 are clamped.
    pub fn from_civil(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Self {
        let year = year.clamp(1980, 2107) as u16;
        DosDateTime {
            date: ((year - 1980) << 9) | ((month.clamp(1, 12) as u16) << 5) | day.clamp(1, 31) as u16,
            time: ((hour.min(23) as u16) << 11) | ((minute.min(59) as u16) << 5) | (second.min(59) / 2) as u16,
        }
    }

    /// The current time in UTC (ZIP stores local time, but has no zone).
    pub fn now_utc() -> Self {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let days = secs.div_euclid(86_400);
        let rem = secs.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        Self::from_civil(
            year,
            month,
            day,
            (rem / 3600) as u32,
            ((rem % 3600) / 60) as u32,
            (rem % 60) as u32,
        )
    }
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
/// algorithm).
fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

struct CentralRecord {
    raw_name: Vec<u8>,
    flags: u16,
    method: u16,
    time: DosDateTime,
    crc: u32,
    compressed_size: u64,
    size: u64,
    offset: u64,
    external_attributes: u32,
    version_made_by: u16,
    /// Extra fields carried over from a copied entry, without the ZIP64
    /// field, which is written afresh.
    local_extra: Vec<u8>,
    central_extra: Vec<u8>,
}

/// The extra fields in `extra` other than the ZIP64 one (whose sizes and
/// offset no longer hold once an entry is copied). A field that runs past
/// the end is dropped with whatever follows it.
fn without_zip64(extra: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut at = 0;
    while at + 4 <= extra.len() {
        let id = u16::from_le_bytes([extra[at], extra[at + 1]]);
        let len = u16::from_le_bytes([extra[at + 2], extra[at + 3]]) as usize;
        let end = at + 4 + len;
        if end > extra.len() {
            break;
        }
        if id != 0x0001 {
            out.extend_from_slice(&extra[at..end]);
        }
        at = end;
    }
    out
}

/// Builds an archive in memory. Entries are written in the order added.
pub struct ZipWriter {
    out: Vec<u8>,
    central: Vec<CentralRecord>,
    names: HashSet<String>,
    timestamp: DosDateTime,
    force_zip64: bool,
}

impl Default for ZipWriter {
    fn default() -> Self {
        Self::new()
    }
}

const FLAG_UTF8: u16 = 1 << 11;
const FLAG_DESCRIPTOR: u16 = 1 << 3;
const MADE_BY_DOS: u16 = 20;
const ZIP64_VERSION: u16 = 45;
const MAX32: u64 = u32::MAX as u64;

impl ZipWriter {
    pub fn new() -> Self {
        Self {
            out: Vec::new(),
            central: Vec::new(),
            names: HashSet::new(),
            timestamp: DosDateTime::EPOCH,
            force_zip64: false,
        }
    }

    /// The timestamp given to entries added from now on.
    pub fn set_timestamp(&mut self, timestamp: DosDateTime) {
        self.timestamp = timestamp;
    }

    /// Write ZIP64 records even for small archives (for tests).
    #[doc(hidden)]
    pub fn force_zip64(&mut self) {
        self.force_zip64 = true;
    }

    fn claim(&mut self, name: &str) -> Result<(), ZipError> {
        if !self.names.insert(name.to_owned()) {
            return Err(ZipError::Duplicate(name.to_owned()));
        }
        Ok(())
    }

    /// Add a file.
    pub fn add(&mut self, name: &str, data: &[u8], compression: Compression) -> Result<(), ZipError> {
        self.claim(name)?;
        let crc = crc32(data);
        let (method, body): (u16, std::borrow::Cow<'_, [u8]>) = match compression {
            Compression::Stored => (METHOD_STORED, data.into()),
            Compression::Deflated(level) => {
                let mut encoder = flate2::write::DeflateEncoder::new(
                    Vec::with_capacity(data.len() / 3 + 64),
                    flate2::Compression::new(level.clamp(1, 9)),
                );
                encoder
                    .write_all(data)
                    .and_then(|_| encoder.finish())
                    .map(|compressed| (METHOD_DEFLATED, compressed.into()))
                    .map_err(|e| ZipError::Corrupt(format!("could not compress '{name}': {e}")))?
            }
        };
        let flags = if name.is_ascii() { 0 } else { FLAG_UTF8 };
        self.write_entry(CentralRecord {
            raw_name: name.as_bytes().to_vec(),
            flags,
            method,
            time: self.timestamp,
            crc,
            compressed_size: body.len() as u64,
            size: data.len() as u64,
            offset: 0,
            external_attributes: 0,
            version_made_by: MADE_BY_DOS,
            local_extra: Vec::new(),
            central_extra: Vec::new(),
        }, &body);
        Ok(())
    }

    /// Add a directory entry (`name` gets a trailing `/` if it lacks one).
    pub fn add_directory(&mut self, name: &str) -> Result<(), ZipError> {
        let name = if name.ends_with('/') { name.to_owned() } else { format!("{name}/") };
        self.claim(&name)?;
        let flags = if name.is_ascii() { 0 } else { FLAG_UTF8 };
        self.write_entry(CentralRecord {
            raw_name: name.into_bytes(),
            flags,
            method: METHOD_STORED,
            time: self.timestamp,
            crc: 0,
            compressed_size: 0,
            size: 0,
            offset: 0,
            // MS-DOS directory attribute.
            external_attributes: 0x10,
            version_made_by: MADE_BY_DOS,
            local_extra: Vec::new(),
            central_extra: Vec::new(),
        }, &[]);
        Ok(())
    }

    /// Copy an entry from another archive without recompressing it. Its name,
    /// timestamp, method, checksum and extra fields (such as Unix times and
    /// permissions) are kept.
    pub fn copy_from(&mut self, archive: &ZipArchive, index: usize) -> Result<(), ZipError> {
        let entry = &archive.entries()[index];
        if entry.is_encrypted() {
            return Err(ZipError::Encrypted(entry.name.clone()));
        }
        self.claim(&entry.name)?;
        let (local_extra, central_extra) = archive.extra_fields(index);
        self.write_entry(CentralRecord {
            raw_name: entry.raw_name.clone(),
            // Sizes go in the local header, so no data descriptor follows.
            flags: entry.flags & !FLAG_DESCRIPTOR,
            method: entry.method,
            time: DosDateTime {
                date: entry.dos_date,
                time: entry.dos_time,
            },
            crc: entry.crc32,
            compressed_size: entry.compressed_size,
            size: entry.size,
            offset: 0,
            external_attributes: entry.external_attributes,
            version_made_by: entry.version_made_by,
            local_extra: without_zip64(local_extra),
            central_extra: without_zip64(central_extra),
        }, archive.raw_data(index));
        Ok(())
    }

    fn write_entry(&mut self, mut record: CentralRecord, body: &[u8]) {
        record.offset = self.out.len() as u64;
        let wide = self.force_zip64 || record.size >= MAX32 || record.compressed_size >= MAX32;
        let zip64_len = if wide { 20 } else { 0 };
        // The extra fields share a 16-bit length with the ZIP64 field; ones
        // that no longer fit are dropped rather than the entry.
        if zip64_len + record.local_extra.len() > u16::MAX as usize {
            record.local_extra.clear();
        }
        let out = &mut self.out;
        out.extend_from_slice(&SIG_LOCAL.to_le_bytes());
        out.extend_from_slice(&(if wide { ZIP64_VERSION } else { 20 }).to_le_bytes());
        out.extend_from_slice(&record.flags.to_le_bytes());
        out.extend_from_slice(&record.method.to_le_bytes());
        out.extend_from_slice(&record.time.time.to_le_bytes());
        out.extend_from_slice(&record.time.date.to_le_bytes());
        out.extend_from_slice(&record.crc.to_le_bytes());
        if wide {
            out.extend_from_slice(&u32::MAX.to_le_bytes());
            out.extend_from_slice(&u32::MAX.to_le_bytes());
        } else {
            out.extend_from_slice(&(record.compressed_size as u32).to_le_bytes());
            out.extend_from_slice(&(record.size as u32).to_le_bytes());
        }
        out.extend_from_slice(&(record.raw_name.len() as u16).to_le_bytes());
        out.extend_from_slice(&((zip64_len + record.local_extra.len()) as u16).to_le_bytes());
        out.extend_from_slice(&record.raw_name);
        if wide {
            out.extend_from_slice(&1u16.to_le_bytes());
            out.extend_from_slice(&16u16.to_le_bytes());
            out.extend_from_slice(&record.size.to_le_bytes());
            out.extend_from_slice(&record.compressed_size.to_le_bytes());
        }
        out.extend_from_slice(&record.local_extra);
        out.extend_from_slice(body);
        self.central.push(record);
    }

    /// Finish the archive and return its bytes.
    pub fn finish(mut self) -> Vec<u8> {
        let directory_start = self.out.len() as u64;
        let out = &mut self.out;
        for record in &self.central {
            let mut extra = Vec::new();
            let size_wide = self.force_zip64 || record.size >= MAX32;
            let compressed_wide = self.force_zip64 || record.compressed_size >= MAX32;
            let offset_wide = self.force_zip64 || record.offset >= MAX32;
            if size_wide {
                extra.extend_from_slice(&record.size.to_le_bytes());
            }
            if compressed_wide {
                extra.extend_from_slice(&record.compressed_size.to_le_bytes());
            }
            if offset_wide {
                extra.extend_from_slice(&record.offset.to_le_bytes());
            }
            let wide = !extra.is_empty();
            let zip64_len = if wide { extra.len() + 4 } else { 0 };
            let carried: &[u8] = if zip64_len + record.central_extra.len() > u16::MAX as usize {
                &[]
            } else {
                &record.central_extra
            };
            out.extend_from_slice(&SIG_CENTRAL.to_le_bytes());
            out.extend_from_slice(&record.version_made_by.max(if wide { ZIP64_VERSION } else { 0 }).to_le_bytes());
            out.extend_from_slice(&(if wide { ZIP64_VERSION } else { 20 }).to_le_bytes());
            out.extend_from_slice(&record.flags.to_le_bytes());
            out.extend_from_slice(&record.method.to_le_bytes());
            out.extend_from_slice(&record.time.time.to_le_bytes());
            out.extend_from_slice(&record.time.date.to_le_bytes());
            out.extend_from_slice(&record.crc.to_le_bytes());
            let narrow = |value: u64, is_wide: bool| if is_wide { u32::MAX } else { value as u32 };
            out.extend_from_slice(&narrow(record.compressed_size, compressed_wide).to_le_bytes());
            out.extend_from_slice(&narrow(record.size, size_wide).to_le_bytes());
            out.extend_from_slice(&(record.raw_name.len() as u16).to_le_bytes());
            out.extend_from_slice(&((zip64_len + carried.len()) as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes()); // comment
            out.extend_from_slice(&0u16.to_le_bytes()); // disk
            out.extend_from_slice(&0u16.to_le_bytes()); // internal attributes
            out.extend_from_slice(&record.external_attributes.to_le_bytes());
            out.extend_from_slice(&narrow(record.offset, offset_wide).to_le_bytes());
            out.extend_from_slice(&record.raw_name);
            if wide {
                out.extend_from_slice(&1u16.to_le_bytes());
                out.extend_from_slice(&(extra.len() as u16).to_le_bytes());
                out.extend_from_slice(&extra);
            }
            out.extend_from_slice(carried);
        }
        let directory_size = out.len() as u64 - directory_start;
        let count = self.central.len() as u64;
        let wide = self.force_zip64 || count >= u16::MAX as u64 || directory_start >= MAX32 || directory_size >= MAX32;
        if wide {
            let record_at = out.len() as u64;
            out.extend_from_slice(&SIG_EOCD64.to_le_bytes());
            out.extend_from_slice(&44u64.to_le_bytes());
            out.extend_from_slice(&ZIP64_VERSION.to_le_bytes());
            out.extend_from_slice(&ZIP64_VERSION.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&count.to_le_bytes());
            out.extend_from_slice(&count.to_le_bytes());
            out.extend_from_slice(&directory_size.to_le_bytes());
            out.extend_from_slice(&directory_start.to_le_bytes());
            out.extend_from_slice(&SIG_EOCD64_LOCATOR.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&record_at.to_le_bytes());
            out.extend_from_slice(&1u32.to_le_bytes());
        }
        out.extend_from_slice(&SIG_EOCD.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        let short_count = if wide { u16::MAX } else { count as u16 };
        out.extend_from_slice(&short_count.to_le_bytes());
        out.extend_from_slice(&short_count.to_le_bytes());
        out.extend_from_slice(&(if wide { u32::MAX } else { directory_size as u32 }).to_le_bytes());
        out.extend_from_slice(&(if wide { u32::MAX } else { directory_start as u32 }).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        self.out
    }
}

#[cfg(test)]
pub(crate) fn civil_for_test(days: i64) -> (i32, u32, u32) {
    civil_from_days(days)
}
