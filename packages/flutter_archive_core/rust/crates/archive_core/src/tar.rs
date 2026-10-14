//! TAR archives: POSIX ustar and pax, GNU long names, and the old v7 layout.
//!
//! A TAR file is a run of 512-byte headers, each followed by its file's data
//! padded to a whole block, and ends with blocks of zeros. Extra headers
//! before an entry carry what the basic header cannot hold: GNU `L` records
//! a long name and pax `x` records a long name, a large size or an exact
//! time. Link targets are never followed, so `K` records are skipped.

use std::io::{self, Read};

use crate::source::Input;
use crate::{EntryKind, Method};

pub(crate) const BLOCK: usize = 512;

/// Largest long-name or pax record read.
const MAX_META_BYTES: u64 = 1 << 20;

/// One listed entry, read from its header (and any extra headers before it).
#[derive(Clone, Debug)]
pub(crate) struct TarHeader {
    pub path: String,
    pub kind: EntryKind,
    pub method: Method,
    /// The file's size; for a sparse file, the size it expands to.
    pub size: u64,
    pub mtime: Option<i64>,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

/// Names are bytes in the writer's locale: UTF-8 today, ISO 8859-1 before.
fn text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(t) => t.to_owned(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// A field up to its first NUL.
fn field(bytes: &[u8]) -> &[u8] {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    &bytes[..end]
}

/// A numeric field: octal digits, or GNU's base-256 for values too large for
/// them. Negative base-256 values are `None`.
fn number(bytes: &[u8]) -> Option<u64> {
    let first = *bytes.first()?;
    if first & 0x80 != 0 {
        if first & 0x40 != 0 {
            return None;
        }
        let mut value = (first & 0x3F) as u64;
        for &b in &bytes[1..] {
            value = value.checked_mul(256)?.checked_add(b as u64)?;
        }
        return Some(value);
    }
    let mut value: u64 = 0;
    let mut seen = false;
    for &b in bytes {
        match b {
            b'0'..=b'7' => {
                value = value.checked_mul(8)?.checked_add((b - b'0') as u64)?;
                seen = true;
            }
            b' ' if !seen => {}
            b' ' | 0 => break,
            _ => return None,
        }
    }
    Some(value)
}

/// Whether the header's checksum is right. Old writers summed signed bytes,
/// so either sum is accepted.
fn checksum_ok(block: &[u8]) -> bool {
    let Some(stored) = number(&block[148..156]) else {
        return false;
    };
    let mut unsigned: u64 = 0;
    let mut signed: i64 = 0;
    for (i, &b) in block[..BLOCK].iter().enumerate() {
        let b = if (148..156).contains(&i) { b' ' } else { b };
        unsigned += b as u64;
        signed += b as i8 as i64;
    }
    stored == unsigned || stored as i64 == signed
}

/// Whether `block` is a TAR header: a valid checksum, and the `ustar` magic
/// or (for v7 archives) a name.
pub(crate) fn looks_like_tar(block: &[u8]) -> bool {
    block.len() >= BLOCK
        && block[..BLOCK].iter().any(|&b| b != 0)
        && checksum_ok(block)
        && (block[257..262] == *b"ustar" || block[0] != 0)
}

fn decimal(bytes: &[u8]) -> Option<i64> {
    let text = std::str::from_utf8(bytes).ok()?;
    // pax times may have a fraction of a second.
    let whole = text.split('.').next()?;
    whole.parse().ok()
}

/// What pax records say about the next entry.
#[derive(Default)]
struct Pax {
    path: Option<String>,
    size: Option<u64>,
    mtime: Option<i64>,
    sparse: bool,
    sparse_name: Option<String>,
    sparse_size: Option<u64>,
}

/// Records are `<length> <key>=<value>\n`, the length counting the whole record.
fn parse_pax(data: &[u8], pax: &mut Pax) -> io::Result<()> {
    let mut rest = data;
    while !rest.is_empty() && rest.iter().any(|&b| b != 0) {
        let space = rest.iter().position(|&b| b == b' ').ok_or_else(|| invalid("a TAR pax record is damaged"))?;
        let len: usize = std::str::from_utf8(&rest[..space])
            .ok()
            .and_then(|t| t.parse().ok())
            .filter(|&len| len > space + 1 && len <= rest.len())
            .ok_or_else(|| invalid("a TAR pax record is damaged"))?;
        let record = &rest[space + 1..len];
        let record = record.strip_suffix(b"\n").unwrap_or(record);
        if let Some(eq) = record.iter().position(|&b| b == b'=') {
            let (key, value) = (&record[..eq], &record[eq + 1..]);
            // An empty value cancels a global setting; nothing to do here.
            if !value.is_empty() {
                match key {
                    b"path" => pax.path = Some(text(value)),
                    b"size" => pax.size = decimal(value).and_then(|v| u64::try_from(v).ok()),
                    b"mtime" => pax.mtime = decimal(value),
                    b"GNU.sparse.name" => {
                        pax.sparse = true;
                        pax.sparse_name = Some(text(value));
                    }
                    b"GNU.sparse.realsize" | b"GNU.sparse.size" => {
                        pax.sparse = true;
                        pax.sparse_size = decimal(value).and_then(|v| u64::try_from(v).ok());
                    }
                    k if k.starts_with(b"GNU.sparse.") => pax.sparse = true,
                    _ => {}
                }
            }
        }
        rest = &rest[len..];
    }
    Ok(())
}

fn padding(size: u64) -> u64 {
    (BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64
}

/// Reads entries one after another; between calls to [`TarReader::next`],
/// reading the reader itself gives the current entry's data.
pub(crate) struct TarReader<R> {
    inner: R,
    /// Data of the current entry not read yet, and the padding after it.
    remaining: u64,
    padding: u64,
    done: bool,
}

impl<R: Input> TarReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, remaining: 0, padding: 0, done: false }
    }

    /// Read one block; `false` at a clean end of input.
    fn read_block(&mut self, block: &mut [u8; BLOCK]) -> io::Result<bool> {
        let mut filled = 0;
        while filled < BLOCK {
            match self.inner.read(&mut block[filled..]) {
                Ok(0) if filled == 0 => return Ok(false),
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated")),
                Ok(n) => filled += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(true)
    }

    /// The data of an extra header, which must be small.
    fn read_meta(&mut self, size: u64) -> io::Result<Vec<u8>> {
        if size > MAX_META_BYTES {
            return Err(invalid("a TAR header is too large"));
        }
        let mut data = Vec::with_capacity(size as usize);
        Read::take(&mut self.inner, size).read_to_end(&mut data)?;
        if (data.len() as u64) < size {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated"));
        }
        self.inner.skip(padding(size))?;
        Ok(data)
    }

    /// The next listed entry, after skipping what is left of the current one.
    /// `None` at the end of the archive.
    pub fn next(&mut self) -> io::Result<Option<TarHeader>> {
        if self.done {
            return Ok(None);
        }
        self.inner.skip(self.remaining + self.padding)?;
        self.remaining = 0;
        self.padding = 0;
        let mut long_name: Option<String> = None;
        let mut pax = Pax::default();
        let mut block = [0u8; BLOCK];
        loop {
            if !self.read_block(&mut block)? || block.iter().all(|&b| b == 0) {
                self.done = true;
                return Ok(None);
            }
            if !checksum_ok(&block) {
                return Err(invalid("a TAR header is damaged"));
            }
            let size = number(&block[124..136]).ok_or_else(|| invalid("a TAR header is damaged"))?;
            let typeflag = block[156];
            match typeflag {
                b'L' => {
                    let data = self.read_meta(size)?;
                    long_name = Some(text(field(&data)));
                    continue;
                }
                b'x' => {
                    let data = self.read_meta(size)?;
                    parse_pax(&data, &mut pax)?;
                    continue;
                }
                // Link targets, global pax records and volume labels.
                b'K' | b'g' | b'V' => {
                    self.inner.skip(size + padding(size))?;
                    continue;
                }
                _ => {}
            }

            let path = pax.sparse_name.take().or(pax.path.take()).or(long_name.take()).unwrap_or_else(|| {
                let name = text(field(&block[0..100]));
                // Only POSIX ustar has a name prefix; GNU uses those bytes for
                // other things.
                let prefix = text(field(&block[345..500]));
                if block[257..263] == *b"ustar\0" && !prefix.is_empty() {
                    format!("{prefix}/{name}")
                } else {
                    name
                }
            });
            let stored_size = pax.size.unwrap_or(size);
            let (kind, has_data) = match typeflag {
                b'1' => (EntryKind::HardLink, false),
                b'2' => (EntryKind::Symlink, false),
                b'3' | b'4' | b'6' => (EntryKind::Special, false),
                b'5' => (EntryKind::Directory, false),
                // A GNU dump directory lists its contents as data.
                b'D' => (EntryKind::Directory, true),
                // Old archives mark a folder only by a trailing slash.
                0 if path.ends_with('/') => (EntryKind::Directory, false),
                // Regular files, and types this reader does not know, which
                // POSIX says to read as regular files.
                _ => (EntryKind::File, true),
            };
            let mut method = Method::Stored;
            let mut listed_size = stored_size;
            if typeflag == b'S' || pax.sparse {
                method = Method::Unsupported("sparse".to_owned());
                // Old GNU sparse headers give the real size at offset 483.
                let real = if typeflag == b'S' { number(&block[483..495]) } else { pax.sparse_size };
                listed_size = real.unwrap_or(stored_size);
            } else if typeflag == b'M' {
                method = Method::Unsupported("multi-volume".to_owned());
            }
            let mtime = pax.mtime.or_else(|| number(&block[136..148]).map(|t| t as i64));
            if has_data {
                self.remaining = stored_size;
                self.padding = padding(stored_size);
            }
            return Ok(Some(TarHeader {
                path,
                kind,
                method,
                size: if kind == EntryKind::File { listed_size } else { 0 },
                mtime,
            }));
        }
    }
}

impl<R: Input> Read for TarReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.remaining == 0 || buf.is_empty() {
            return Ok(0);
        }
        let max = buf.len().min(usize::try_from(self.remaining).unwrap_or(usize::MAX));
        let n = self.inner.read(&mut buf[..max])?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated"));
        }
        self.remaining -= n as u64;
        Ok(n)
    }
}
