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
//! depth is bounded, and so is the number of nodes a tree may hold. Trees
//! are dropped, cloned, compared and written without recursion, so one
//! nested as deeply as code can build it cannot overflow a thread's stack.

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

/// How the message of an error for input over a budget starts.
const TOO_LARGE: &str = "too large: ";

impl XmlError {
    pub(crate) fn new(offset: usize, message: impl Into<String>) -> Self {
        Self {
            offset,
            message: message.into(),
        }
    }

    /// An error for input that is over one of the budgets below, rather
    /// than malformed.
    pub(crate) fn too_large(offset: usize, message: impl std::fmt::Display) -> Self {
        Self::new(offset, format!("{TOO_LARGE}{message}"))
    }

    /// Whether reading stopped because the input is over a budget (more
    /// than [`MAX_NODES`] nodes), not because it is malformed, so that the
    /// FFI layers can report it as `TOO_LARGE` rather than `CORRUPT`.
    pub fn is_too_large(&self) -> bool {
        self.message.starts_with(TOO_LARGE)
    }
}

/// How deep elements may nest before parsing stops. The deepest part found
/// in real documents nests 23 elements (a letter LibreOffice saved as
/// DOCX); calls through the FFI layers also run on a large stack.
pub const MAX_DEPTH: usize = 512;

/// How many nodes [`Document::parse`] builds before it stops: elements,
/// attributes, and the text, comments and other nodes between them. A tree
/// takes about 80 bytes per node, so a part stops at about 160 MB; the
/// largest parts in real documents hold well under a tenth of this.
pub const MAX_NODES: usize = 2_000_000;

#[cfg(test)]
mod tests;
