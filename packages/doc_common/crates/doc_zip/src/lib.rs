//! ZIP archives, read and written from scratch.
//!
//! Office Open XML (`.docx`, `.xlsx`, `.pptx`), OpenDocument (`.odt`, `.ods`,
//! `.odp`) and EPUB files are ZIP packages. [`ZipArchive`] reads one from
//! memory with bounded decompression and checksum verification. [`ZipWriter`]
//! writes one back, and can copy the still-compressed bytes of entries that
//! did not change, so saving a document only recompresses what was edited.
//!
//! Supported: stored and deflated entries, ZIP64, data descriptors, archives
//! with bytes prepended (self-extractors), UTF-8 and CP437 names, and the
//! Info-ZIP Unicode path field. Not supported: encryption and compression
//! methods other than store/deflate (reported as errors, never guessed at).

mod cp437;
mod crc32;
mod read;
mod write;

pub use crc32::{crc32, Crc32};
pub use read::{ReadLimits, ZipArchive, ZipEntry};
pub use write::{Compression, DosDateTime, ZipWriter};

/// Compression method numbers from the ZIP specification.
pub const METHOD_STORED: u16 = 0;
pub const METHOD_DEFLATED: u16 = 8;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ZipError {
    #[error("not a ZIP archive")]
    NotZip,
    #[error("damaged ZIP archive: {0}")]
    Corrupt(String),
    #[error("'{0}' is encrypted inside the ZIP archive")]
    Encrypted(String),
    #[error("'{name}' uses compression method {method}, which is not supported")]
    UnsupportedMethod { name: String, method: u16 },
    #[error("'{0}' is larger than this app allows")]
    TooLarge(String),
    #[error("'{0}' is damaged (its checksum does not match)")]
    Checksum(String),
    #[error("the archive has no entry named '{0}'")]
    Missing(String),
    #[error("the archive already has an entry named '{0}'")]
    Duplicate(String),
}

#[cfg(test)]
mod tests;
