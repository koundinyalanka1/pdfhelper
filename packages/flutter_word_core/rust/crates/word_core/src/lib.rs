//! Word processing: Word (`.docx`), OpenDocument (`.odt`) and RTF documents,
//! read, edited in place and written back.
//!
//! A document's body is a tree of paragraphs and containers ([`tree`]),
//! each paragraph still the XML element it was read as. The screen sees
//! paragraphs as styled text and objects ([`view`]); edits come back as
//! new content for paragraphs ([`Edit`]), which the format's backend
//! writes into the original elements, keeping what it does not show.

pub mod backend;
pub mod document;
pub mod docx;
pub mod error;
pub mod import;
pub mod odt;
pub mod projected;
pub mod tree;
pub mod view;

#[cfg(test)]
mod tests;

pub use backend::{Format, StyleInfo, TableOp};
pub use document::{Document, Edit, EditResult, FindOptions, Heading, Match, NewPara};
pub use error::WordError;

/// What a file's bytes look like.
pub fn detect_format(bytes: &[u8], name: &str) -> Option<Format> {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    if bytes.starts_with(b"PK") {
        // OpenDocument names itself in its first entry.
        if bytes.len() > 38 && &bytes[30..38] == b"mimetype" {
            let rest = &bytes[38..bytes.len().min(38 + 64)];
            if rest.starts_with(b"application/vnd.oasis.opendocument.text-template") {
                return Some(Format::Ott);
            }
            if rest.starts_with(b"application/vnd.oasis.opendocument.text") {
                return Some(Format::Odt);
            }
        }
        return Some(match ext.as_str() {
            "odt" => Format::Odt,
            "ott" => Format::Ott,
            "docm" => Format::Docm,
            "dotx" | "dotm" => Format::Dotx,
            _ => Format::Docx,
        });
    }
    let head = &bytes[..bytes.len().min(16)];
    let trimmed: &[u8] = {
        let mut h = head;
        if h.starts_with(&[0xEF, 0xBB, 0xBF]) {
            h = &h[3..];
        }
        h
    };
    if trimmed.starts_with(b"{\\rtf") {
        return Some(Format::Rtf);
    }
    if bytes.starts_with(&[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
        return None;
    }
    match ext.as_str() {
        "md" | "markdown" => Some(Format::Markdown),
        "txt" | "text" | "" => Some(Format::Txt),
        _ => Format::parse(&ext),
    }
}

/// Whether bytes are an Office file protected with a password (an
/// encrypted package inside a compound file).
pub fn is_encrypted_package(bytes: &[u8]) -> bool {
    if !bytes.starts_with(&[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
        return false;
    }
    let needle: Vec<u8> = "EncryptedPackage"
        .encode_utf16()
        .flat_map(|u| u.to_le_bytes())
        .collect();
    bytes.windows(needle.len()).any(|w| w == needle.as_slice())
}

/// Open a document from its bytes; `name` (the file name) helps tell
/// formats apart.
pub fn open(bytes: Vec<u8>, name: &str) -> Result<Document, WordError> {
    if is_encrypted_package(&bytes) {
        return Err(WordError::Encrypted);
    }
    let Some(format) = detect_format(&bytes, name) else {
        return Err(WordError::Unsupported(
            "This is an older Word document (.doc). Opening those is coming; for now, open it in another app.".into(),
        ));
    };
    match format {
        Format::Docx | Format::Docm | Format::Dotx => {
            let d = docx::Docx::open(bytes, format)?;
            Ok(Document::new(Box::new(d), format))
        }
        Format::Odt | Format::Ott => {
            let d = odt::Odt::open(bytes, format)?;
            Ok(Document::new(Box::new(d), format))
        }
        Format::Rtf | Format::Txt | Format::Markdown => {
            let docx = match format {
                Format::Rtf => import::rtf_to_docx(&bytes)?,
                _ => import::text_to_docx(&decode_text(&bytes), format == Format::Markdown)?,
            };
            let d = docx::Docx::open(docx, Format::Docx)?;
            Ok(Document::new(Box::new(d), format))
        }
    }
}

/// A new, empty Word document.
pub fn blank() -> Document {
    Document::new(Box::new(docx::Docx::blank()), Format::Docx)
}

/// Text bytes as a string: UTF-8 (with or without a byte-order mark),
/// UTF-16 with a mark, or Windows-1252.
fn decode_text(bytes: &[u8]) -> String {
    use doc_encoding::Encoding;
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE][..]) {
        return Encoding::Utf16Le.decode(rest).text;
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF][..]) {
        return Encoding::Utf16Be.decode(rest).text;
    }
    let b = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF][..]).unwrap_or(bytes);
    match std::str::from_utf8(b) {
        Ok(s) => s.to_owned(),
        Err(_) => Encoding::WINDOWS_1252.decode(b).text,
    }
}
