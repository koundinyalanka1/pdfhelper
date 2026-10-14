//! Where an archive's bytes come from, read as a stream (TAR and gzip are
//! read front to back rather than loaded whole).

use std::fs::File;
use std::io::{self, BufRead, BufReader, Cursor, Read, Seek, SeekFrom};
use std::path::PathBuf;

use crate::gzip::GzReader;

/// An archive on disk or in memory.
pub(crate) enum Data {
    File(PathBuf),
    Memory(Vec<u8>),
}

impl Data {
    /// A fresh reader positioned at the start.
    pub fn open(&self) -> io::Result<Raw<'_>> {
        Ok(match self {
            Data::File(path) => {
                let file = File::open(path)?;
                let len = file.metadata()?.len();
                Raw::File(FileInput { reader: BufReader::with_capacity(256 << 10, file), pos: 0, len })
            }
            Data::Memory(bytes) => Raw::Memory(Cursor::new(bytes)),
        })
    }

    /// The last `n` bytes (fewer when the archive is shorter).
    pub fn tail(&self, n: u64) -> io::Result<Vec<u8>> {
        match self {
            Data::File(path) => {
                let mut file = File::open(path)?;
                let len = file.metadata()?.len();
                file.seek(SeekFrom::Start(len.saturating_sub(n)))?;
                let mut tail = Vec::new();
                file.take(n).read_to_end(&mut tail)?;
                Ok(tail)
            }
            Data::Memory(bytes) => Ok(bytes[bytes.len().saturating_sub(n as usize)..].to_vec()),
        }
    }
}

/// Input the TAR reader can jump through: files and memory skip entries
/// they do not need, decompressing streams read through them.
pub(crate) trait Input: Read {
    /// Move `n` bytes ahead; `UnexpectedEof` when fewer remain.
    fn skip(&mut self, n: u64) -> io::Result<()> {
        let skipped = io::copy(&mut Read::take(&mut *self, n), &mut io::sink())?;
        if skipped < n {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated"));
        }
        Ok(())
    }
}

impl<T: Input + ?Sized> Input for Box<T> {
    fn skip(&mut self, n: u64) -> io::Result<()> {
        (**self).skip(n)
    }
}

/// A buffered file that knows its length, so a skip past the end is noticed
/// rather than silently seeking beyond it.
pub(crate) struct FileInput {
    reader: BufReader<File>,
    pos: u64,
    len: u64,
}

impl Read for FileInput {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.reader.read(buf)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl BufRead for FileInput {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        self.reader.fill_buf()
    }

    fn consume(&mut self, amt: usize) {
        self.pos += amt as u64;
        self.reader.consume(amt);
    }
}

impl Input for FileInput {
    fn skip(&mut self, n: u64) -> io::Result<()> {
        let left = self.len.saturating_sub(self.pos);
        if n > left {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated"));
        }
        self.reader.seek_relative(n as i64)?;
        self.pos += n;
        Ok(())
    }
}

/// An archive's bytes, unprocessed.
pub(crate) enum Raw<'a> {
    File(FileInput),
    Memory(Cursor<&'a Vec<u8>>),
}

impl Read for Raw<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Raw::File(f) => f.read(buf),
            Raw::Memory(m) => m.read(buf),
        }
    }
}

impl BufRead for Raw<'_> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        match self {
            Raw::File(f) => f.fill_buf(),
            Raw::Memory(m) => m.fill_buf(),
        }
    }

    fn consume(&mut self, amt: usize) {
        match self {
            Raw::File(f) => f.consume(amt),
            Raw::Memory(m) => m.consume(amt),
        }
    }
}

impl Input for Raw<'_> {
    fn skip(&mut self, n: u64) -> io::Result<()> {
        match self {
            Raw::File(f) => f.skip(n),
            Raw::Memory(m) => {
                let len = m.get_ref().len() as u64;
                let pos = m.position();
                if n > len.saturating_sub(pos) {
                    m.set_position(len);
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the archive is truncated"));
                }
                m.set_position(pos + n);
                Ok(())
            }
        }
    }
}

impl<R: BufRead> Input for GzReader<R> {}

/// The error a [`Limited`] stream stops with.
#[derive(Debug)]
pub(crate) struct Bomb;

impl std::fmt::Display for Bomb {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the archive expands to far more than its size")
    }
}

impl std::error::Error for Bomb {}

/// Whether `error` came from a [`Limited`] stream.
pub(crate) fn is_bomb(error: &io::Error) -> bool {
    error.get_ref().is_some_and(|inner| inner.is::<Bomb>())
}

/// Stops a decompressing stream that grows past what is believable for the
/// size of the file it comes from.
pub(crate) struct Limited<R> {
    inner: R,
    read: u64,
    limit: u64,
}

impl<R> Limited<R> {
    pub fn new(inner: R, limit: u64) -> Self {
        Self { inner, read: 0, limit }
    }
}

impl<R: Read> Read for Limited<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.read += n as u64;
        if self.read > self.limit {
            return Err(io::Error::other(Bomb));
        }
        Ok(n)
    }
}

impl<R: Read> Input for Limited<R> {}
