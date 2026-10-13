//! OLE2 compound files ("Compound File Binary"): the container of Word 97
//! `.doc`, Excel `.xls`, PowerPoint `.ppt`, WPS Office binaries and
//! password-protected OOXML. A file of fixed-size sectors holding a little
//! file system: a FAT of sector chains, a directory tree of storages and
//! streams, and a mini stream for small streams.
//!
//! Reading only, with every chain and size checked, so damaged or hostile
//! files fail cleanly.

use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CfbError {
    #[error("this is not a compound file")]
    NotCfb,
    #[error("this compound file is damaged: {0}")]
    Corrupt(String),
    #[error("a stream of this file is larger than this app allows")]
    TooLarge,
}

fn corrupt(m: &str) -> CfbError {
    CfbError::Corrupt(m.into())
}

const SIGNATURE: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
const END_OF_CHAIN: u32 = 0xFFFF_FFFE;
const FREE: u32 = 0xFFFF_FFFF;
const NO_STREAM: u32 = 0xFFFF_FFFF;
/// Streams larger than this are refused.
pub const MAX_STREAM: u64 = 512 * 1024 * 1024;

/// Whether bytes start like a compound file.
pub fn is_cfb(data: &[u8]) -> bool {
    data.starts_with(&SIGNATURE)
}

fn u16_at(b: &[u8], i: usize) -> u16 {
    b.get(i..i + 2).map_or(0, |s| u16::from_le_bytes([s[0], s[1]]))
}

fn u32_at(b: &[u8], i: usize) -> u32 {
    b.get(i..i + 4).map_or(0, |s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

/// A directory entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    /// 1 storage, 2 stream, 5 root.
    pub kind: u8,
    left: u32,
    right: u32,
    child: u32,
    start: u32,
    pub size: u64,
}

impl Entry {
    pub fn is_stream(&self) -> bool {
        self.kind == 2
    }

    pub fn is_storage(&self) -> bool {
        self.kind == 1 || self.kind == 5
    }
}

pub struct Cfb {
    data: Vec<u8>,
    sector: usize,
    mini: usize,
    cutoff: u64,
    fat: Vec<u32>,
    minifat: Vec<u32>,
    entries: Vec<Entry>,
    mini_stream: Vec<u8>,
}

impl std::fmt::Debug for Cfb {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Cfb({} entries)", self.entries.len())
    }
}

impl Cfb {
    pub fn open(data: Vec<u8>) -> Result<Cfb, CfbError> {
        if !is_cfb(&data) || data.len() < 512 {
            return Err(CfbError::NotCfb);
        }
        let shift = u16_at(&data, 30);
        let sector = match shift {
            9 => 512,
            12 => 4096,
            _ => return Err(corrupt("sector size")),
        };
        let mini_shift = u16_at(&data, 32);
        if mini_shift != 6 {
            return Err(corrupt("mini sector size"));
        }
        let fat_sectors = u32_at(&data, 44) as usize;
        let first_dir = u32_at(&data, 48);
        let cutoff = u32_at(&data, 56) as u64;
        let first_minifat = u32_at(&data, 60);
        let minifat_sectors = u32_at(&data, 64) as usize;
        let mut difat_next = u32_at(&data, 68);
        let difat_sectors = u32_at(&data, 72) as usize;
        let count = (data.len().saturating_sub(sector)).div_ceil(sector);
        if fat_sectors > count + 1 || difat_sectors > count + 1 {
            return Err(corrupt("header counts"));
        }
        // The FAT's own sectors: 109 in the header, the rest in DIFAT
        // sectors.
        let mut fat_list: Vec<u32> = (0..109).map(|k| u32_at(&data, 76 + k * 4)).filter(|s| *s != FREE).collect();
        let per = sector / 4 - 1;
        let mut seen = HashSet::new();
        for _ in 0..difat_sectors {
            if difat_next >= END_OF_CHAIN || !seen.insert(difat_next) {
                break;
            }
            let at = (difat_next as usize + 1) * sector;
            if at + sector > data.len() {
                return Err(corrupt("DIFAT"));
            }
            for k in 0..per {
                let s = u32_at(&data, at + k * 4);
                if s != FREE {
                    fat_list.push(s);
                }
            }
            difat_next = u32_at(&data, at + per * 4);
        }
        fat_list.truncate(fat_sectors.max(1));
        let mut fat = Vec::with_capacity(fat_list.len() * sector / 4);
        for s in &fat_list {
            let at = (*s as usize + 1) * sector;
            let chunk = data.get(at..at + sector).ok_or_else(|| corrupt("FAT"))?;
            fat.extend(chunk.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])));
        }
        let mut cfb = Cfb {
            data,
            sector,
            mini: 64,
            cutoff: if cutoff == 0 { 4096 } else { cutoff },
            fat,
            minifat: Vec::new(),
            entries: Vec::new(),
            mini_stream: Vec::new(),
        };
        // The directory.
        let dir = cfb.chain_bytes(first_dir, None)?;
        for e in dir.chunks_exact(128) {
            let name_len = (u16_at(e, 64) as usize).min(64);
            let units: Vec<u16> = (0..name_len / 2).map(|k| u16_at(e, k * 2)).take_while(|u| *u != 0).collect();
            let size = if cfb.sector == 512 { u32_at(e, 120) as u64 } else { u32_at(e, 120) as u64 | (u32_at(e, 124) as u64) << 32 };
            cfb.entries.push(Entry {
                name: String::from_utf16_lossy(&units),
                kind: e[66],
                left: u32_at(e, 68),
                right: u32_at(e, 72),
                child: u32_at(e, 76),
                start: u32_at(e, 116),
                size,
            });
        }
        if cfb.entries.first().is_none_or(|r| r.kind != 5) {
            return Err(corrupt("no root entry"));
        }
        // The mini FAT and the mini stream (held by the root entry).
        if minifat_sectors > 0 && first_minifat < END_OF_CHAIN {
            let m = cfb.chain_bytes(first_minifat, None)?;
            cfb.minifat = m.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
        }
        let root = cfb.entries[0].clone();
        if root.start < END_OF_CHAIN && root.size > 0 {
            if root.size > MAX_STREAM {
                return Err(CfbError::TooLarge);
            }
            cfb.mini_stream = cfb.chain_bytes(root.start, Some(root.size))?;
        }
        Ok(cfb)
    }

    /// The bytes of a chain of regular sectors, cut to `size`.
    fn chain_bytes(&self, start: u32, size: Option<u64>) -> Result<Vec<u8>, CfbError> {
        let mut out = Vec::new();
        let mut s = start;
        let mut seen = vec![false; self.fat.len()];
        while s != END_OF_CHAIN {
            if s >= END_OF_CHAIN - 3 || s as usize >= self.fat.len() {
                return Err(corrupt("sector chain"));
            }
            if std::mem::replace(&mut seen[s as usize], true) {
                return Err(corrupt("a sector chain loops"));
            }
            let at = (s as usize + 1) * self.sector;
            let end = (at + self.sector).min(self.data.len());
            if at >= self.data.len() {
                return Err(corrupt("sector past the end"));
            }
            out.extend_from_slice(&self.data[at..end]);
            if let Some(n) = size {
                if out.len() as u64 >= n {
                    break;
                }
            }
            if out.len() as u64 > MAX_STREAM {
                return Err(CfbError::TooLarge);
            }
            s = self.fat[s as usize];
        }
        if let Some(n) = size {
            if (out.len() as u64) < n {
                return Err(corrupt("stream shorter than its size"));
            }
            out.truncate(n as usize);
        }
        Ok(out)
    }

    fn mini_bytes(&self, start: u32, size: u64) -> Result<Vec<u8>, CfbError> {
        let mut out = Vec::with_capacity(size as usize);
        let mut s = start;
        let mut seen = vec![false; self.minifat.len()];
        while (out.len() as u64) < size {
            if s >= END_OF_CHAIN - 3 || s as usize >= self.minifat.len() {
                return Err(corrupt("mini sector chain"));
            }
            if std::mem::replace(&mut seen[s as usize], true) {
                return Err(corrupt("a mini chain loops"));
            }
            let at = s as usize * self.mini;
            let chunk = self.mini_stream.get(at..at + self.mini).ok_or_else(|| corrupt("mini sector past the end"))?;
            out.extend_from_slice(chunk);
            s = self.minifat[s as usize];
        }
        out.truncate(size as usize);
        Ok(out)
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Children of a storage entry, in no particular order.
    fn children(&self, storage: usize) -> Vec<usize> {
        let mut out = Vec::new();
        let Some(e) = self.entries.get(storage) else { return out };
        let mut stack = vec![e.child];
        let mut seen = HashSet::new();
        while let Some(i) = stack.pop() {
            if i == NO_STREAM || i as usize >= self.entries.len() || !seen.insert(i) {
                continue;
            }
            out.push(i as usize);
            let c = &self.entries[i as usize];
            stack.push(c.left);
            stack.push(c.right);
        }
        out
    }

    /// The entry at a path like `Workbook` or `ObjectPool/_123/Ole`
    /// (names compare without case).
    pub fn find(&self, path: &str) -> Option<usize> {
        let mut cur = 0usize;
        for part in path.split('/').filter(|p| !p.is_empty()) {
            cur = self.children(cur).into_iter().find(|i| self.entries[*i].name.eq_ignore_ascii_case(part))?;
        }
        Some(cur)
    }

    pub fn exists(&self, path: &str) -> bool {
        self.find(path).is_some()
    }

    /// A stream's bytes.
    pub fn stream(&self, path: &str) -> Result<Vec<u8>, CfbError> {
        let i = self.find(path).ok_or_else(|| corrupt(&format!("no stream {path}")))?;
        self.stream_at(i)
    }

    pub fn stream_at(&self, i: usize) -> Result<Vec<u8>, CfbError> {
        let e = self.entries.get(i).ok_or_else(|| corrupt("no such entry"))?;
        if !e.is_stream() {
            return Err(corrupt("not a stream"));
        }
        if e.size > MAX_STREAM {
            return Err(CfbError::TooLarge);
        }
        if e.size == 0 {
            return Ok(Vec::new());
        }
        if e.size < self.cutoff {
            self.mini_bytes(e.start, e.size)
        } else {
            self.chain_bytes(e.start, Some(e.size))
        }
    }

    /// Every stream's path.
    pub fn list(&self) -> Vec<String> {
        let mut out = Vec::new();
        let mut stack = vec![(0usize, String::new())];
        let mut seen = HashSet::new();
        while let Some((i, prefix)) = stack.pop() {
            if !seen.insert(i) {
                continue;
            }
            for c in self.children(i) {
                let e = &self.entries[c];
                let path = if prefix.is_empty() { e.name.clone() } else { format!("{prefix}/{}", e.name) };
                if e.is_stream() {
                    out.push(path);
                } else if e.is_storage() {
                    stack.push((c, path));
                }
            }
        }
        out.sort();
        out
    }
}

/// Write a compound file (version 3, 512-byte sectors) holding streams at
/// the root. For tests and for building small files; the readers here
/// never write legacy formats.
pub fn build(streams: &[(&str, &[u8])]) -> Vec<u8> {
    let sector = 512usize;
    // Every stream in regular sectors (cutoff 0 forces that).
    let mut body: Vec<u8> = Vec::new();
    let mut starts = Vec::new();
    let mut fat: Vec<u32> = Vec::new();
    for (_, data) in streams {
        let n = data.len().div_ceil(sector).max(1);
        let first = fat.len() as u32;
        starts.push(first);
        for k in 0..n {
            fat.push(if k + 1 == n { END_OF_CHAIN } else { first + k as u32 + 1 });
        }
        let mut d = data.to_vec();
        d.resize(n * sector, 0);
        body.extend_from_slice(&d);
    }
    // Directory: root plus one entry per stream, as a right-leaning chain.
    let dir_entries = streams.len() + 1;
    let dir_sectors = (dir_entries * 128).div_ceil(sector);
    let dir_first = fat.len() as u32;
    for k in 0..dir_sectors {
        fat.push(if k + 1 == dir_sectors { END_OF_CHAIN } else { dir_first + k as u32 + 1 });
    }
    let mut dir = vec![0u8; dir_sectors * sector];
    let entry = |dir: &mut Vec<u8>, i: usize, name: &str, kind: u8, child: u32, right: u32, start: u32, size: u32| {
        let at = i * 128;
        let units: Vec<u16> = name.encode_utf16().collect();
        for (k, u) in units.iter().enumerate().take(31) {
            dir[at + k * 2..at + k * 2 + 2].copy_from_slice(&u.to_le_bytes());
        }
        dir[at + 64..at + 66].copy_from_slice(&(((units.len().min(31) + 1) * 2) as u16).to_le_bytes());
        dir[at + 66] = kind;
        dir[at + 67] = 1;
        dir[at + 68..at + 72].copy_from_slice(&NO_STREAM.to_le_bytes());
        dir[at + 72..at + 76].copy_from_slice(&right.to_le_bytes());
        dir[at + 76..at + 80].copy_from_slice(&child.to_le_bytes());
        dir[at + 116..at + 120].copy_from_slice(&start.to_le_bytes());
        dir[at + 120..at + 124].copy_from_slice(&size.to_le_bytes());
    };
    entry(&mut dir, 0, "Root Entry", 5, if streams.is_empty() { NO_STREAM } else { 1 }, NO_STREAM, END_OF_CHAIN, 0);
    for (k, (name, data)) in streams.iter().enumerate() {
        let right = if k + 1 < streams.len() { k as u32 + 2 } else { NO_STREAM };
        entry(&mut dir, k + 1, name, 2, NO_STREAM, right, starts[k], data.len() as u32);
    }
    for k in dir_entries..dir_sectors * sector / 128 {
        let at = k * 128;
        dir[at + 68..at + 80].copy_from_slice(&[0xFF; 12]);
    }
    body.extend_from_slice(&dir);
    // The FAT itself.
    let mut fat_sectors = 1;
    loop {
        let total = fat.len() + fat_sectors;
        if total.div_ceil(sector / 4) <= fat_sectors {
            break;
        }
        fat_sectors += 1;
    }
    let fat_first = fat.len() as u32;
    for _ in 0..fat_sectors {
        fat.push(0xFFFF_FFFD);
    }
    fat.resize(fat_sectors * sector / 4, FREE);
    let mut header = vec![0u8; 512];
    header[..8].copy_from_slice(&SIGNATURE);
    header[24..26].copy_from_slice(&0x3Eu16.to_le_bytes());
    header[26..28].copy_from_slice(&3u16.to_le_bytes());
    header[28..30].copy_from_slice(&0xFFFEu16.to_le_bytes());
    header[30..32].copy_from_slice(&9u16.to_le_bytes());
    header[32..34].copy_from_slice(&6u16.to_le_bytes());
    header[44..48].copy_from_slice(&(fat_sectors as u32).to_le_bytes());
    header[48..52].copy_from_slice(&dir_first.to_le_bytes());
    // A cutoff of 1: every stream sits in regular sectors.
    header[56..60].copy_from_slice(&1u32.to_le_bytes());
    header[60..64].copy_from_slice(&END_OF_CHAIN.to_le_bytes());
    header[68..72].copy_from_slice(&END_OF_CHAIN.to_le_bytes());
    for k in 0..109 {
        let v = if k < fat_sectors { fat_first + k as u32 } else { FREE };
        header[76 + k * 4..80 + k * 4].copy_from_slice(&v.to_le_bytes());
    }
    let mut out = header;
    out.extend_from_slice(&body);
    for v in fat {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_it_builds() {
        let big: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
        let file = build(&[("WordDocument", &big), ("1Table", b"hello"), ("\u{5}SummaryInformation", &[1, 2, 3])]);
        assert!(is_cfb(&file));
        let c = Cfb::open(file).unwrap();
        assert_eq!(c.stream("WordDocument").unwrap(), big);
        assert_eq!(c.stream("1table").unwrap(), b"hello");
        assert!(c.exists("\u{5}SummaryInformation"));
        assert_eq!(c.list().len(), 3);
        assert!(c.stream("Nope").is_err());
    }

    #[test]
    fn rejects_damage() {
        assert_eq!(Cfb::open(b"not a compound file".to_vec()).unwrap_err(), CfbError::NotCfb);
        let mut file = build(&[("Workbook", &[7u8; 2000])]);
        // Make the stream's chain loop on itself.
        let fat_at = file.len() - 512;
        file[fat_at..fat_at + 4].copy_from_slice(&0u32.to_le_bytes());
        let c = Cfb::open(file).unwrap();
        assert!(c.stream("Workbook").is_err());
    }
}
