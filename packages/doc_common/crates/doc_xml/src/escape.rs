//! Entity and character-reference handling.

use std::borrow::Cow;

use crate::XmlError;

/// The longest reference looked for: `&`, a name or number of up to 31
/// bytes, and `;`.
const MAX_REFERENCE: usize = 33;

/// The entities XML predefines.
const PREDEFINED: [&str; 5] = ["lt", "gt", "amp", "apos", "quot"];

/// The length of the reference that starts with the `&` at `bytes[0]`, up
/// to and including its `;`; None for a bare ampersand. Only the next
/// [`MAX_REFERENCE`] bytes are looked at, so text full of ampersands is
/// read in linear time.
fn reference_len(bytes: &[u8]) -> Option<usize> {
    bytes.iter().take(MAX_REFERENCE).position(|&b| b == b';').map(|n| n + 1)
}

/// Whether `name` can name an entity: letters, digits and `_ : . -` (or
/// any character beyond ASCII), not starting with a digit, `.` or `-`.
fn is_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let start = |b: u8| b.is_ascii_alphabetic() || matches!(b, b'_' | b':') || b >= 0x80;
    bytes.first().is_some_and(|&b| start(b))
        && bytes.iter().all(|&b| start(b) || b.is_ascii_digit() || matches!(b, b'.' | b'-'))
}

/// The name of the entity reference at the start of `raw` when XML does not
/// predefine it (`&nbsp;` gives `nbsp`), so that a tree can keep it as
/// written.
pub(crate) fn unknown_entity(raw: &str) -> Option<&str> {
    let len = reference_len(raw.as_bytes())?;
    let name = &raw[1..len - 1];
    (is_name(name) && !PREDEFINED.contains(&name)).then_some(name)
}

/// Expand entity and character references, and normalize line ends as an
/// XML processor must (`\r\n` and lone `\r` become `\n`). `base` is the
/// input's offset, for error positions.
///
/// Unknown named entities (`&nbsp;` in HTML-ish content) are kept literally
/// rather than failing the whole document.
pub fn unescape(raw: &str, base: usize) -> Result<Cow<'_, str>, XmlError> {
    if !raw.as_bytes().iter().any(|&b| b == b'&' || b == b'\r') {
        return Ok(Cow::Borrowed(raw));
    }
    let mut out = String::with_capacity(raw.len());
    let bytes = raw.as_bytes();
    let mut i = 0;
    let mut run_start = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' => {
                out.push_str(&raw[run_start..i]);
                out.push('\n');
                i += if bytes.get(i + 1) == Some(&b'\n') { 2 } else { 1 };
                run_start = i;
            }
            b'&' => {
                out.push_str(&raw[run_start..i]);
                let Some(semi) = reference_len(&bytes[i..]).map(|len| len - 1) else {
                    // A bare ampersand: malformed, but common in hand-made
                    // files. Keep it.
                    out.push('&');
                    i += 1;
                    run_start = i;
                    continue;
                };
                let entity = &raw[i + 1..i + semi];
                match entity {
                    "lt" => out.push('<'),
                    "gt" => out.push('>'),
                    "amp" => out.push('&'),
                    "apos" => out.push('\''),
                    "quot" => out.push('"'),
                    _ if entity.starts_with('#') => {
                        let code = if let Some(hex) = entity.strip_prefix("#x").or_else(|| entity.strip_prefix("#X")) {
                            u32::from_str_radix(hex, 16).ok()
                        } else {
                            entity[1..].parse::<u32>().ok()
                        };
                        match code.and_then(char::from_u32) {
                            Some(c) => out.push(c),
                            None => {
                                return Err(XmlError::new(base + i, format!("bad character reference &{entity};")))
                            }
                        }
                    }
                    _ => out.push_str(&raw[i..i + semi + 1]),
                }
                i += semi + 1;
                run_start = i;
            }
            _ => i += 1,
        }
    }
    out.push_str(&raw[run_start..]);
    Ok(Cow::Owned(out))
}

/// Whether XML 1.0 allows `c` in a document.
fn allowed(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\r' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..='\u{10FFFF}')
}

/// Escape character data. `\r` is written as a reference so that it
/// survives a reader's line-end normalization; characters XML cannot carry
/// become U+FFFD.
pub fn escape_text(text: &str, out: &mut String) {
    let mut run_start = 0;
    for (i, c) in text.char_indices() {
        let replacement = match c {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\r' => "&#13;",
            c if !allowed(c) => "\u{FFFD}",
            _ => continue,
        };
        out.push_str(&text[run_start..i]);
        out.push_str(replacement);
        run_start = i + c.len_utf8();
    }
    out.push_str(&text[run_start..]);
}

/// Escape an attribute value for double quotes. Tabs and line ends are
/// written as references so attribute-value normalization keeps them.
pub fn escape_attr(value: &str, out: &mut String) {
    let mut run_start = 0;
    for (i, c) in value.char_indices() {
        let replacement = match c {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\t' => "&#9;",
            '\n' => "&#10;",
            '\r' => "&#13;",
            c if !allowed(c) => "\u{FFFD}",
            _ => continue,
        };
        out.push_str(&value[run_start..i]);
        out.push_str(replacement);
        run_start = i + c.len_utf8();
    }
    out.push_str(&value[run_start..]);
}
