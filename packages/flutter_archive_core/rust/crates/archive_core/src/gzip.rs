//! gzip files (RFC 1952): the member header, and members inflated one after
//! another with their checksums verified.
//!
//! A `.gz` file is one or more members, each a header, a raw deflate stream
//! and a trailer with the CRC-32 and length of what it holds. Tools such as
//! `pigz` and `bgzip` write several members; padding after the last member
//! is ignored, as `gzip` itself does.

use std::io::{self, BufRead, Read};

use doc_zip::Crc32;
use flate2::bufread::DeflateDecoder;

pub(crate) const MAGIC: [u8; 2] = [0x1F, 0x8B];

const FLAG_HEADER_CRC: u8 = 1 << 1;
const FLAG_EXTRA: u8 = 1 << 2;
const FLAG_NAME: u8 = 1 << 3;
const FLAG_COMMENT: u8 = 1 << 4;
const FLAG_RESERVED: u8 = 0xE0;

/// The longest file name or comment read from a header.
const MAX_HEADER_TEXT: usize = 64 << 10;

/// What the first member's header says about the file it holds.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GzHeader {
    /// The original file name, if the compressor recorded it.
    pub name: Option<String>,
    /// Modification time, seconds since 1970 (`None` when not recorded).
    pub mtime: Option<i64>,
    pub comment: Option<String>,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

/// Text in a header: ISO 8859-1 by the specification, UTF-8 in practice.
fn header_text(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap_or_else(|e| e.into_bytes().iter().map(|&b| b as char).collect())
}

fn read_zero_terminated<R: BufRead>(r: &mut R) -> io::Result<Vec<u8>> {
    let mut text = Vec::new();
    r.take(MAX_HEADER_TEXT as u64 + 1).read_until(0, &mut text)?;
    if text.last() != Some(&0) {
        return Err(invalid(if text.len() > MAX_HEADER_TEXT {
            "the gzip header is damaged"
        } else {
            "the gzip data is truncated"
        }));
    }
    text.pop();
    Ok(text)
}

/// Read a member header whose two magic bytes have already been read.
fn read_header_after_magic<R: BufRead>(r: &mut R) -> io::Result<GzHeader> {
    let mut fixed = [0u8; 8];
    r.read_exact(&mut fixed).map_err(|e| match e.kind() {
        io::ErrorKind::UnexpectedEof => invalid("the gzip data is truncated"),
        _ => e,
    })?;
    let [method, flags, t0, t1, t2, t3, _, _] = fixed;
    if method != 8 {
        return Err(invalid("the gzip file uses an unknown compression method"));
    }
    if flags & FLAG_RESERVED != 0 {
        return Err(invalid("the gzip header is damaged"));
    }
    let mtime = u32::from_le_bytes([t0, t1, t2, t3]);
    if flags & FLAG_EXTRA != 0 {
        let mut len = [0u8; 2];
        r.read_exact(&mut len)?;
        let len = u16::from_le_bytes(len) as u64;
        if io::copy(&mut r.take(len), &mut io::sink())? != len {
            return Err(invalid("the gzip data is truncated"));
        }
    }
    let name = if flags & FLAG_NAME != 0 { Some(header_text(read_zero_terminated(r)?)) } else { None };
    let comment = if flags & FLAG_COMMENT != 0 { Some(header_text(read_zero_terminated(r)?)) } else { None };
    if flags & FLAG_HEADER_CRC != 0 {
        r.read_exact(&mut [0u8; 2])?;
    }
    Ok(GzHeader {
        name: name.filter(|n| !n.is_empty()),
        mtime: (mtime != 0).then_some(mtime as i64),
        comment: comment.filter(|c| !c.is_empty()),
    })
}

/// Read two bytes if there are two; `None` at the end of the input.
fn read_magic<R: Read>(r: &mut R) -> io::Result<Option<[u8; 2]>> {
    let mut magic = [0u8; 2];
    let mut filled = 0;
    while filled < 2 {
        match r.read(&mut magic[filled..]) {
            Ok(0) => return Ok(None),
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(Some(magic))
}

enum State<R: BufRead> {
    Member { inflate: DeflateDecoder<R>, crc: Crc32, size: u64 },
    Done,
}

/// The decompressed contents of a gzip file, every member in turn.
pub(crate) struct GzReader<R: BufRead> {
    state: State<R>,
}

impl<R: BufRead> GzReader<R> {
    /// Start reading a gzip stream; fails unless it starts with a valid header.
    pub fn new(mut inner: R) -> io::Result<(Self, GzHeader)> {
        if read_magic(&mut inner)? != Some(MAGIC) {
            return Err(invalid("this is not a gzip file"));
        }
        let header = read_header_after_magic(&mut inner)?;
        let reader = Self { state: State::Member { inflate: DeflateDecoder::new(inner), crc: Crc32::new(), size: 0 } };
        Ok((reader, header))
    }

    /// Check the finished member's trailer and start the next member, if any.
    fn next_member(&mut self) -> io::Result<()> {
        let State::Member { inflate, crc, size } = std::mem::replace(&mut self.state, State::Done) else {
            return Ok(());
        };
        let mut inner = inflate.into_inner();
        let mut trailer = [0u8; 8];
        inner.read_exact(&mut trailer).map_err(|e| match e.kind() {
            io::ErrorKind::UnexpectedEof => invalid("the gzip data is truncated"),
            _ => e,
        })?;
        let stored_crc = u32::from_le_bytes([trailer[0], trailer[1], trailer[2], trailer[3]]);
        let stored_size = u32::from_le_bytes([trailer[4], trailer[5], trailer[6], trailer[7]]);
        if stored_crc != crc.finish() || stored_size != size as u32 {
            return Err(invalid("the gzip data is damaged (its checksum does not match)"));
        }
        if read_magic(&mut inner)? == Some(MAGIC) {
            read_header_after_magic(&mut inner)?;
            self.state = State::Member { inflate: DeflateDecoder::new(inner), crc: Crc32::new(), size: 0 };
        }
        Ok(())
    }
}

impl<R: BufRead> Read for GzReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            let State::Member { inflate, crc, size } = &mut self.state else {
                return Ok(0);
            };
            // flate2 reports a broken deflate stream as invalid input; other
            // errors are the file's own and pass through.
            let n = inflate.read(buf).map_err(|e| match e.kind() {
                io::ErrorKind::InvalidInput => invalid("the gzip data is damaged"),
                _ => e,
            })?;
            if n > 0 {
                crc.update(&buf[..n]);
                *size += n as u64;
                return Ok(n);
            }
            self.next_member()?;
        }
    }
}
