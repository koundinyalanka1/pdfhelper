//! XML, written from scratch for document formats.
//!
//! * [`Reader`]: a fast pull parser that borrows from its input, for large
//!   parts such as spreadsheet cell data.
//! * [`Document`] / [`Element`]: a tree that keeps everything it read
//!   (element and attribute order, namespace prefixes, comments, processing
//!   instructions, whitespace), so a part edited in one place serializes
//!   unchanged everywhere else.
//! * [`XmlWriter`]: an escaping writer for generating parts.
//! * [`ns`]: namespace identities resolved by URI, so code matches
//!   `{wordprocessingml}p` whatever prefix a producer chose. Strict and
//!   transitional OOXML namespaces resolve to the same identity.
//!
//! Safety: only the five predefined entities and character references are
//! expanded. Document type declarations are skipped, never processed, so
//! external entities (XXE) and entity expansion bombs cannot occur. Nesting
//! depth is bounded.

mod dom;
mod escape;
pub mod ns;
pub mod ooxml;
mod reader;
mod writer;

pub use dom::{Attr, Document, Element, Node};
pub use escape::{escape_attr, escape_text, unescape};
pub use ns::Ns;
pub use reader::{decode_bytes, Attrs, Event, Reader, StartTag};
pub use writer::XmlWriter;

/// A parse error, with the byte offset where it was found.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("XML error at byte {offset}: {message}")]
pub struct XmlError {
    pub offset: usize,
    pub message: String,
}

impl XmlError {
    pub(crate) fn new(offset: usize, message: impl Into<String>) -> Self {
        Self {
            offset,
            message: message.into(),
        }
    }
}

/// How deep elements may nest before parsing stops.
pub const MAX_DEPTH: usize = 1024;

#[cfg(test)]
mod tests;
