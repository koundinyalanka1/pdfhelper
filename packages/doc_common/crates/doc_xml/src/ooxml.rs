//! OOXML string escaping (ECMA-376 Part 1, §22.9.2.19 `ST_Xstring`).
//!
//! Office writes characters XML 1.0 cannot carry, and carriage returns
//! (which an XML reader would normalize away), as `_xHHHH_`, where `HHHH`
//! is a UTF-16 code unit in hex. A literal underscore that would otherwise
//! read as the start of such an escape is itself written `_x005F_`.

fn hex4(bytes: &[u8]) -> Option<u16> {
    if bytes.len() < 4 {
        return None;
    }
    let text = std::str::from_utf8(&bytes[..4]).ok()?;
    u16::from_str_radix(text, 16).ok()
}

/// Whether `text` starts with `_xHHHH_`.
fn escape_at(text: &[u8]) -> Option<u16> {
    if text.len() >= 7 && text[0] == b'_' && (text[1] == b'x' || text[1] == b'X') && text[6] == b'_' {
        hex4(&text[2..6])
    } else {
        None
    }
}

/// Decode `_xHHHH_` escapes.
pub fn decode_xstring(text: &str) -> String {
    if !text.contains("_x") && !text.contains("_X") {
        return text.to_owned();
    }
    let bytes = text.as_bytes();
    let mut units: Vec<u16> = Vec::with_capacity(text.len());
    let mut out = String::with_capacity(text.len());
    let flush = |units: &mut Vec<u16>, out: &mut String| {
        out.extend(char::decode_utf16(units.drain(..)).map(|r| r.unwrap_or('\u{FFFD}')));
    };
    let mut i = 0;
    let mut run_start = 0;
    while i < bytes.len() {
        if let Some(unit) = escape_at(&bytes[i..]) {
            if units.is_empty() {
                out.push_str(&text[run_start..i]);
            }
            units.push(unit);
            i += 7;
            run_start = i;
            // A surrogate pair is written as two escapes in a row.
            if escape_at(&bytes[i..]).is_none() {
                flush(&mut units, &mut out);
            }
            continue;
        }
        i += 1;
    }
    flush(&mut units, &mut out);
    out.push_str(&text[run_start..]);
    out
}

fn needs_escape(c: char) -> bool {
    matches!(c, '\u{0}'..='\u{8}' | '\u{B}' | '\u{C}' | '\u{E}'..='\u{1F}' | '\r' | '\u{FFFE}' | '\u{FFFF}')
}

/// Encode text for an OOXML string: escape what XML cannot hold, carriage
/// returns, and underscores that would read as escapes.
pub fn encode_xstring(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    for (i, c) in text.char_indices() {
        if needs_escape(c) {
            out.push_str(&format!("_x{:04X}_", c as u32));
        } else if c == '_' && escape_at(&bytes[i..]).is_some() {
            out.push_str("_x005F_");
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_escapes() {
        assert_eq!(decode_xstring("plain"), "plain");
        assert_eq!(decode_xstring("line one_x000D_\nline two"), "line one\r\nline two");
        assert_eq!(decode_xstring("tab_x0009_end"), "tab\tend");
        assert_eq!(decode_xstring("_x005F_x0041_"), "_x0041_");
        assert_eq!(decode_xstring("not_an_escape_x12"), "not_an_escape_x12");
        // A supplementary character as a surrogate pair.
        assert_eq!(decode_xstring("_xD83D__xDE00_!"), "😀!");
    }

    #[test]
    fn encodes_round_trip() {
        for text in ["a\r\nb", "bell\u{7}", "_x0041_ literal", "snake_case_name", "😀 fine", "under_"] {
            let encoded = encode_xstring(text);
            assert_eq!(decode_xstring(&encoded), text, "{encoded}");
        }
        assert_eq!(encode_xstring("a\rb"), "a_x000D_b");
        assert_eq!(encode_xstring("_x0041_"), "_x005F_x0041_");
        assert_eq!(encode_xstring("snake_case"), "snake_case");
    }
}
