//! Flat OpenDocument files (`.fodt`, `.fods`, `.fodp`): one XML document,
//! `<office:document office:mimetype="...">`, holding everything a packaged
//! file spreads over its parts: `office:meta`, `office:settings`,
//! `office:scripts`, `office:font-face-decls`, `office:styles`,
//! `office:automatic-styles`, `office:master-styles` and `office:body`,
//! with pictures inline as base64 `office:binary-data`.
//!
//! The engines read packages, so [`unflatten`] turns a flat file into one.
//! Each section is copied into its parts as written, byte for byte, so
//! nothing an engine does not understand is lost. Only inline pictures
//! change: they become files under `Pictures/` that the elements holding
//! them link to. [`flatten`] goes the other way, for tests and tools.
//!
//! [`flat_mimetype`] tells a flat file from other XML by its root alone,
//! cheaply enough to try on every file an engine opens.

mod base64;
mod flatten;
mod unflatten;

use doc_xml::ns::{self, Bindings, Namespaces};
use doc_xml::{Event, Reader, StartTag, XmlError};
use doc_zip::ZipError;

pub use base64::{decode as base64_decode, encode as base64_encode};
pub use flatten::flatten;
pub use unflatten::unflatten;

/// The mimetype of text documents (also the start of the template's,
/// `...text-template`, and the master document's, `...text-master`).
pub const TEXT: &str = "application/vnd.oasis.opendocument.text";
/// The mimetype of spreadsheets (and the start of the template's).
pub const SPREADSHEET: &str = "application/vnd.oasis.opendocument.spreadsheet";
/// The mimetype of presentations (and the start of the template's).
pub const PRESENTATION: &str = "application/vnd.oasis.opendocument.presentation";

/// Why a flat file could not be turned into a package, or a package into
/// a flat file.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum OdfError {
    #[error("this is not a flat OpenDocument file")]
    NotFlat,
    #[error("{0}")]
    Xml(#[from] XmlError),
    #[error("{0}")]
    Zip(#[from] ZipError),
    /// A package without a part every OpenDocument file has.
    #[error("the package has no '{0}'")]
    Missing(String),
}

/// How much of a file [`flat_mimetype`] reads. The root's start tag, with
/// all its namespace declarations, ends well within it.
const HEAD: usize = 64 * 1024;

/// The `office:mimetype` of a flat OpenDocument file, such as
/// `application/vnd.oasis.opendocument.text`; None when the bytes are not
/// one. Only the start of the file is read, up to the root's start tag.
pub fn flat_mimetype(bytes: &[u8]) -> Option<String> {
    let head = &bytes[..bytes.len().min(HEAD)];
    if !starts_like_xml(head) {
        return None;
    }
    let (text, _) = doc_xml::decode_bytes(head);
    let mut reader = Reader::new(text.trim_start_matches('\u{FEFF}').trim_start());
    loop {
        match reader.next().ok()? {
            Event::Start(tag) => {
                let mut bindings = Bindings::new();
                bindings.open();
                declare(&tag, &mut bindings, &mut Namespaces::new());
                return root_mimetype(&tag, &bindings);
            }
            Event::Eof => return None,
            _ => {}
        }
    }
}

/// Whether bytes can be XML: after a byte-order mark and whitespace, a
/// `<` (UTF-16 text has a zero byte beside it, or a mark of its own).
fn starts_like_xml(bytes: &[u8]) -> bool {
    if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        return true;
    }
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF][..]).unwrap_or(bytes);
    bytes.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'<')
}

/// Bind the namespaces a start tag declares, in the scope `bindings` has
/// just opened for it; `namespaces` numbers the URIs that are not
/// well-known.
fn declare(tag: &StartTag, bindings: &mut Bindings, namespaces: &mut Namespaces) {
    for (name, value) in tag.attrs().filter_map(Result::ok) {
        if name == "xmlns" {
            bindings.bind("", namespaces.id(&value));
        } else if let Some(prefix) = name.strip_prefix("xmlns:") {
            bindings.bind(prefix, namespaces.id(&value));
        }
    }
}

/// The mimetype of a root start tag that is `{office}document`, with
/// `bindings` holding its declarations.
fn root_mimetype(tag: &StartTag, bindings: &Bindings) -> Option<String> {
    let bound = |prefix: &str| bindings.resolve(prefix);
    let prefix = tag.name.rsplit_once(':').map_or("", |(p, _)| p);
    if tag.local() != "document" || bound(prefix) != Some(ns::OFFICE) {
        return None;
    }
    let mimetype = tag.attrs().filter_map(Result::ok).find_map(|(name, value)| {
        let (p, local) = name.rsplit_once(':')?;
        (local == "mimetype" && bound(p) == Some(ns::OFFICE)).then(|| value.trim().to_owned())
    })?;
    (!mimetype.is_empty()).then_some(mimetype)
}

/// Whether bytes are a flat OpenDocument file.
pub fn is_flat(bytes: &[u8]) -> bool {
    flat_mimetype(bytes).is_some()
}

/// The kinds of picture a package holds, told by their first bytes: the
/// file extension used for them, and the media type the manifest lists.
pub(crate) fn picture_kind(bytes: &[u8]) -> (&'static str, &'static str) {
    let u16_at = |i: usize| bytes.get(i..i + 2).map_or(0, |b| u16::from_le_bytes([b[0], b[1]]));
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        ("png", "image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        ("jpg", "image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        ("gif", "image/gif")
    } else if bytes.starts_with(&[0xD7, 0xCD, 0xC6, 0x9A])
        || (matches!(u16_at(0), 1 | 2) && u16_at(2) == 9 && matches!(u16_at(4), 0x0100 | 0x0300))
    {
        // A placeable metafile, or a plain one: its header is nine words.
        ("wmf", "image/x-wmf")
    } else if bytes.starts_with(&[1, 0, 0, 0]) && bytes.get(40..44) == Some(b" EMF") {
        ("emf", "image/x-emf")
    } else if bytes.starts_with(b"BM") {
        ("bmp", "image/bmp")
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        ("tif", "image/tiff")
    } else if is_svg(bytes) {
        ("svg", "image/svg+xml")
    } else {
        ("bin", "application/octet-stream")
    }
}

/// Whether bytes are an SVG drawing: XML whose root, near the start, is
/// `svg`.
fn is_svg(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(4096)];
    if !starts_like_xml(head) {
        return false;
    }
    let (text, _) = doc_xml::decode_bytes(head);
    let mut reader = Reader::new(text.trim_start_matches('\u{FEFF}').trim_start());
    loop {
        match reader.next() {
            Ok(Event::Start(tag)) => return tag.local() == "svg",
            Ok(Event::Eof) | Err(_) => return false,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests;
