//! Entity and character-reference handling.

use std::borrow::Cow;

use crate::XmlError;

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
                let Some(semi) = raw[i..].find(';').filter(|&n| n <= 32) else {
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
