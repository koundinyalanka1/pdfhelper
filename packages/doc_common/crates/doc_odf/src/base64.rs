//! Base64 (RFC 4648), the encoding of `office:binary-data`.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// The value of a base64 digit, or None for anything else.
fn digit(c: u8) -> Option<u32> {
    Some(match c {
        b'A'..=b'Z' => c - b'A',
        b'a'..=b'z' => c - b'a' + 26,
        b'0'..=b'9' => c - b'0' + 52,
        b'+' => 62,
        b'/' => 63,
        _ => return None,
    } as u32)
}

/// Decode base64 text. Whitespace anywhere is ignored (producers wrap the
/// text in lines), and missing `=` padding is tolerated. Returns None for
/// other characters, for data after the padding, or for a lone digit at
/// the end, which cannot hold a whole byte.
pub fn decode(text: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3 + 3);
    let mut acc = 0u32;
    let mut digits = 0u32;
    let mut padded = false;
    for &c in text {
        if c.is_ascii_whitespace() {
            continue;
        }
        if c == b'=' {
            padded = true;
            continue;
        }
        if padded {
            return None;
        }
        acc = (acc << 6) | digit(c)?;
        digits += 1;
        if digits == 4 {
            out.extend_from_slice(&[(acc >> 16) as u8, (acc >> 8) as u8, acc as u8]);
            acc = 0;
            digits = 0;
        }
    }
    match digits {
        0 => {}
        2 => out.push((acc >> 4) as u8),
        3 => out.extend_from_slice(&[(acc >> 10) as u8, (acc >> 2) as u8]),
        _ => return None,
    }
    Some(out)
}

/// Encode bytes as base64 with padding, in lines of `line` characters
/// separated by line feeds (0 for one line).
pub fn encode(bytes: &[u8], line: usize) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4 + bytes.len() / 48 + 1);
    let mut column = 0;
    let mut push = |c: u8, out: &mut String| {
        if line > 0 && column == line {
            out.push('\n');
            column = 0;
        }
        out.push(c as char);
        column += 1;
    };
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize], &mut out);
            } else {
                push(b'=', &mut out);
            }
        }
    }
    out
}
