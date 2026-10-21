//! Text encodings, written from scratch: detection, decoding and encoding.
//!
//! Covers the Unicode encodings (UTF-8, UTF-16 and UTF-32 in both byte
//! orders) and the common single-byte code pages: Windows-125x and 874,
//! ISO-8859-x, KOI8, the DOS code pages and Mac Roman. Text files, CSV,
//! RTF, legacy Office binaries and XML declarations all name encodings from
//! this set. Multi-byte East Asian code pages are not supported yet.
//!
//! Decoding never fails: undecodable input becomes U+FFFD and is counted.
//! Every byte of a Windows code page decodes to some character, so text in
//! one survives a decode and re-encode unchanged.

mod tables;

use std::sync::OnceLock;

use tables::PAGES;

/// A text encoding.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Encoding {
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
    /// A single-byte code page; see [`Encoding::single_byte`].
    SingleByte(SingleByte),
}

/// One of the supported single-byte code pages.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SingleByte(u8);

/// The result of decoding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoded {
    pub text: String,
    /// How many characters were replaced by U+FFFD because the input was
    /// not valid in the encoding.
    pub errors: usize,
}

/// The result of encoding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Encoded {
    pub bytes: Vec<u8>,
    /// How many characters the encoding cannot represent; each was written
    /// as `?`.
    pub unmappable: usize,
}

impl Encoding {
    pub const WINDOWS_1252: Encoding = Encoding::SingleByte(SingleByte(0));

    /// Every supported encoding, Unicode ones first.
    pub fn all() -> Vec<Encoding> {
        let mut all = vec![
            Encoding::Utf8,
            Encoding::Utf16Le,
            Encoding::Utf16Be,
            Encoding::Utf32Le,
            Encoding::Utf32Be,
        ];
        all.extend((0..PAGES.len()).map(|i| Encoding::SingleByte(SingleByte(i as u8))));
        all
    }

    /// The encoding's canonical (WHATWG-style) name.
    pub fn name(self) -> &'static str {
        match self {
            Encoding::Utf8 => "UTF-8",
            Encoding::Utf16Le => "UTF-16LE",
            Encoding::Utf16Be => "UTF-16BE",
            Encoding::Utf32Le => "UTF-32LE",
            Encoding::Utf32Be => "UTF-32BE",
            Encoding::SingleByte(page) => PAGES[page.0 as usize].name,
        }
    }

    /// Look an encoding up by any common label, case-insensitively, as found
    /// in XML declarations, HTML meta tags and MIME charsets.
    pub fn from_label(label: &str) -> Option<Encoding> {
        let label = label.trim().to_ascii_lowercase();
        let label = label.as_str();
        let unicode = match label {
            "utf-8" | "utf8" | "unicode-1-1-utf-8" | "x-unicode20utf8" => Some(Encoding::Utf8),
            "utf-16" | "utf-16le" | "utf16" | "utf16le" | "ucs-2" | "unicode" | "csunicode"
            | "iso-10646-ucs-2" | "unicodefeff" => Some(Encoding::Utf16Le),
            "utf-16be" | "utf16be" | "unicodefffe" => Some(Encoding::Utf16Be),
            "utf-32" | "utf-32le" | "utf32" | "utf32le" => Some(Encoding::Utf32Le),
            "utf-32be" | "utf32be" => Some(Encoding::Utf32Be),
            // ASCII is a subset; files labelled with it routinely contain
            // Windows-1252 bytes, which is how browsers read them too.
            "ascii" | "us-ascii" | "iso646-us" | "ansi_x3.4-1968" => Some(Encoding::WINDOWS_1252),
            _ => None,
        };
        if unicode.is_some() {
            return unicode;
        }
        PAGES
            .iter()
            .position(|page| page.name == label || page.labels.contains(&label))
            .map(|i| Encoding::SingleByte(SingleByte(i as u8)))
    }

    /// The encoding a Windows code page number names: from the `CodePage`
    /// fields of legacy Office files and RTF's `\ansicpg`.
    pub fn from_code_page(code_page: u32) -> Option<Encoding> {
        match code_page {
            65001 => Some(Encoding::Utf8),
            1200 => Some(Encoding::Utf16Le),
            1201 => Some(Encoding::Utf16Be),
            12000 => Some(Encoding::Utf32Le),
            12001 => Some(Encoding::Utf32Be),
            // US-ASCII.
            20127 => Some(Encoding::WINDOWS_1252),
            _ => PAGES
                .iter()
                .position(|page| page.code_page == code_page && code_page != 0)
                .map(|i| Encoding::SingleByte(SingleByte(i as u8))),
        }
    }

    /// The Windows code page number, where one exists.
    pub fn code_page(self) -> Option<u32> {
        match self {
            Encoding::Utf8 => Some(65001),
            Encoding::Utf16Le => Some(1200),
            Encoding::Utf16Be => Some(1201),
            Encoding::Utf32Le => Some(12000),
            Encoding::Utf32Be => Some(12001),
            Encoding::SingleByte(page) => Some(PAGES[page.0 as usize].code_page).filter(|&cp| cp != 0),
        }
    }

    /// Whether this is one of the Unicode encodings (which can encode any text).
    pub fn is_unicode(self) -> bool {
        !matches!(self, Encoding::SingleByte(_))
    }

    /// The byte-order mark for this encoding (empty for code pages).
    pub fn bom(self) -> &'static [u8] {
        match self {
            Encoding::Utf8 => &[0xEF, 0xBB, 0xBF],
            Encoding::Utf16Le => &[0xFF, 0xFE],
            Encoding::Utf16Be => &[0xFE, 0xFF],
            Encoding::Utf32Le => &[0xFF, 0xFE, 0x00, 0x00],
            Encoding::Utf32Be => &[0x00, 0x00, 0xFE, 0xFF],
            Encoding::SingleByte(_) => &[],
        }
    }

    /// Decode bytes (without a byte-order mark) to text.
    pub fn decode(self, bytes: &[u8]) -> Decoded {
        match self {
            Encoding::Utf8 => decode_utf8(bytes),
            Encoding::Utf16Le => decode_utf16(bytes, u16::from_le_bytes),
            Encoding::Utf16Be => decode_utf16(bytes, u16::from_be_bytes),
            Encoding::Utf32Le => decode_utf32(bytes, u32::from_le_bytes),
            Encoding::Utf32Be => decode_utf32(bytes, u32::from_be_bytes),
            Encoding::SingleByte(page) => {
                let high = &PAGES[page.0 as usize].high;
                let mut text = String::with_capacity(bytes.len() + bytes.len() / 4);
                let mut errors = 0;
                for &b in bytes {
                    if b < 0x80 {
                        text.push(b as char);
                    } else {
                        let code = high[(b - 0x80) as usize];
                        if code == 0xFFFD {
                            errors += 1;
                        }
                        text.push(char::from_u32(code as u32).unwrap_or('\u{FFFD}'));
                    }
                }
                Decoded { text, errors }
            }
        }
    }

    /// Encode text (without a byte-order mark).
    pub fn encode(self, text: &str) -> Encoded {
        match self {
            Encoding::Utf8 => Encoded {
                bytes: text.as_bytes().to_vec(),
                unmappable: 0,
            },
            Encoding::Utf16Le | Encoding::Utf16Be => {
                let mut bytes = Vec::with_capacity(text.len() * 2);
                for unit in text.encode_utf16() {
                    bytes.extend_from_slice(&if self == Encoding::Utf16Le {
                        unit.to_le_bytes()
                    } else {
                        unit.to_be_bytes()
                    });
                }
                Encoded { bytes, unmappable: 0 }
            }
            Encoding::Utf32Le | Encoding::Utf32Be => {
                let mut bytes = Vec::with_capacity(text.len() * 4);
                for c in text.chars() {
                    let code = c as u32;
                    bytes.extend_from_slice(&if self == Encoding::Utf32Le {
                        code.to_le_bytes()
                    } else {
                        code.to_be_bytes()
                    });
                }
                Encoded { bytes, unmappable: 0 }
            }
            Encoding::SingleByte(page) => {
                let reverse = reverse_table(page.0 as usize);
                let mut bytes = Vec::with_capacity(text.len());
                let mut unmappable = 0;
                for c in text.chars() {
                    let code = c as u32;
                    if code < 0x80 {
                        bytes.push(code as u8);
                        continue;
                    }
                    match u16::try_from(code)
                        .ok()
                        .and_then(|code| reverse.binary_search_by_key(&code, |&(c, _)| c).ok())
                    {
                        Some(found) => bytes.push(reverse[found].1),
                        None => {
                            unmappable += 1;
                            bytes.push(b'?');
                        }
                    }
                }
                Encoded { bytes, unmappable }
            }
        }
    }

    /// Whether every character of `text` can be written in this encoding.
    pub fn can_encode(self, text: &str) -> bool {
        self.is_unicode() || self.encode(text).unmappable == 0
    }

    pub fn decode_lossless(self, bytes: &[u8]) -> Decoded {
        self.decode_lossless_limited(bytes, usize::MAX).expect("text fits in memory")
    }

    pub fn decode_lossless_limited(self, bytes: &[u8], max_bytes: usize) -> Result<Decoded, &'static str> {
        let mut out = LosslessDecoder { text: String::new(), errors: 0, max_bytes };
        match self {
            Self::Utf8 => {
                let mut rest = bytes;
                while !rest.is_empty() {
                    match std::str::from_utf8(rest) {
                        Ok(text) => {
                            out.text(text)?;
                            break;
                        }
                        Err(error) => {
                            let valid = error.valid_up_to();
                            out.text(std::str::from_utf8(&rest[..valid]).unwrap_or_default())?;
                            let count = error.error_len().unwrap_or(rest.len() - valid);
                            out.raw(&rest[valid..valid + count])?;
                            rest = &rest[valid + count..];
                        }
                    }
                }
            }
            Self::Utf16Le | Self::Utf16Be => {
                let read = if self == Self::Utf16Le { u16::from_le_bytes } else { u16::from_be_bytes };
                let (pairs, tail) = bytes.as_chunks::<2>();
                let mut i = 0;
                while i < pairs.len() {
                    let unit = read(pairs[i]);
                    if (0xD800..=0xDBFF).contains(&unit) {
                        if let Some(&next) = pairs.get(i + 1) {
                            let low = read(next);
                            if (0xDC00..=0xDFFF).contains(&low) {
                                let code = 0x10000 + ((unit as u32 - 0xD800) << 10) + low as u32 - 0xDC00;
                                out.character(char::from_u32(code).unwrap_or(char::REPLACEMENT_CHARACTER))?;
                                i += 2;
                                continue;
                            }
                        }
                        out.raw(&pairs[i])?;
                    } else if (0xDC00..=0xDFFF).contains(&unit) {
                        out.raw(&pairs[i])?;
                    } else {
                        out.character(char::from_u32(unit as u32).unwrap_or(char::REPLACEMENT_CHARACTER))?;
                    }
                    i += 1;
                }
                if !tail.is_empty() { out.raw(tail)?; }
            }
            Self::Utf32Le | Self::Utf32Be => {
                let read = if self == Self::Utf32Le { u32::from_le_bytes } else { u32::from_be_bytes };
                let (quads, tail) = bytes.as_chunks::<4>();
                for &quad in quads {
                    match char::from_u32(read(quad)) {
                        Some(c) => out.character(c)?,
                        None => out.raw(&quad)?,
                    }
                }
                if !tail.is_empty() { out.raw(tail)?; }
            }
            Self::SingleByte(page) => {
                let high = &PAGES[page.index()].high;
                for &byte in bytes {
                    let code = if byte < 0x80 { byte as u16 } else { high[(byte - 0x80) as usize] };
                    let c = char::from_u32(code as u32).unwrap_or(char::REPLACEMENT_CHARACTER);
                    if code == 0xFFFD || single_byte_code(page, c) != Some(byte) {
                        out.raw(&[byte])?;
                    } else {
                        out.character(c)?;
                    }
                }
            }
        }
        Ok(Decoded { text: out.text, errors: out.errors })
    }

    pub fn encode_lossless(self, text: &str, source: Self) -> Encoded {
        let mut bytes = Vec::with_capacity(text.len());
        let mut unmappable = 0;
        // A file cut off mid-character (an odd byte at the end of UTF-16)
        // keeps that byte; text typed after it must still start on a whole
        // code unit, or everything after reads back as garbage.
        let unit = match self {
            Self::Utf16Le | Self::Utf16Be => 2,
            Self::Utf32Le | Self::Utf32Be => 4,
            _ => 1,
        };
        let align = |bytes: &mut Vec<u8>| {
            let partial = bytes.len() % unit;
            if partial != 0 { bytes.resize(bytes.len() + unit - partial, 0); }
        };
        for unit in LosslessUnits(text.chars().peekable()) {
            match unit {
                LosslessUnit::Byte(byte) if self == source => bytes.push(byte),
                LosslessUnit::Byte(_) => {
                    unmappable += 1;
                    align(&mut bytes);
                    encode_character(self, '?', &mut bytes);
                }
                LosslessUnit::Character(c) => {
                    align(&mut bytes);
                    unmappable += encode_character(self, c, &mut bytes) as usize;
                }
            }
        }
        Encoded { bytes, unmappable }
    }

    pub fn unmappable_lossless(self, text: &str, source: Self) -> usize {
        LosslessUnits(text.chars().peekable()).filter(|unit| match *unit {
            LosslessUnit::Byte(_) => self != source,
            LosslessUnit::Character(c) => match self {
                Self::SingleByte(page) => single_byte_code(page, c).is_none(),
                _ => false,
            },
        }).count()
    }
}

const RAW_BYTE_BASE: u32 = 0xF0000;
const LOSSLESS_ESCAPE: char = '\u{F0100}';

struct LosslessDecoder {
    text: String,
    errors: usize,
    max_bytes: usize,
}

impl LosslessDecoder {
    fn push(&mut self, c: char) -> Result<(), &'static str> {
        if c.len_utf8() > self.max_bytes.saturating_sub(self.text.len()) {
            return Err("the decoded text is too large");
        }
        self.text.try_reserve(c.len_utf8()).map_err(|_| "not enough memory for the decoded text")?;
        self.text.push(c);
        Ok(())
    }

    fn character(&mut self, c: char) -> Result<(), &'static str> {
        if c == LOSSLESS_ESCAPE || (RAW_BYTE_BASE..RAW_BYTE_BASE + 256).contains(&(c as u32)) {
            self.push(LOSSLESS_ESCAPE)?;
        }
        self.push(c)
    }

    fn text(&mut self, text: &str) -> Result<(), &'static str> {
        for c in text.chars() { self.character(c)?; }
        Ok(())
    }

    fn raw(&mut self, bytes: &[u8]) -> Result<(), &'static str> {
        self.errors += 1;
        for &byte in bytes {
            self.push(char::from_u32(RAW_BYTE_BASE + byte as u32).unwrap_or(char::REPLACEMENT_CHARACTER))?;
        }
        Ok(())
    }
}

enum LosslessUnit {
    Character(char),
    Byte(u8),
}

struct LosslessUnits<'a>(std::iter::Peekable<std::str::Chars<'a>>);

impl Iterator for LosslessUnits<'_> {
    type Item = LosslessUnit;

    fn next(&mut self) -> Option<Self::Item> {
        let c = self.0.next()?;
        if c == LOSSLESS_ESCAPE {
            if let Some(&next) = self.0.peek() {
                if next == LOSSLESS_ESCAPE || (RAW_BYTE_BASE..RAW_BYTE_BASE + 256).contains(&(next as u32)) {
                    self.0.next();
                    return Some(LosslessUnit::Character(next));
                }
            }
        }
        Some(if (RAW_BYTE_BASE..RAW_BYTE_BASE + 256).contains(&(c as u32)) {
            LosslessUnit::Byte((c as u32 - RAW_BYTE_BASE) as u8)
        } else {
            LosslessUnit::Character(c)
        })
    }
}

fn single_byte_code(page: SingleByte, c: char) -> Option<u8> {
    if (c as u32) < 0x80 { return Some(c as u8); }
    let reverse = reverse_table(page.index());
    let code = u16::try_from(c as u32).ok()?;
    reverse.binary_search_by_key(&code, |&(c, _)| c).ok().map(|index| reverse[index].1)
}

fn encode_character(encoding: Encoding, c: char, bytes: &mut Vec<u8>) -> bool {
    match encoding {
        Encoding::Utf8 => bytes.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes()),
        Encoding::Utf16Le | Encoding::Utf16Be => {
            for unit in c.encode_utf16(&mut [0; 2]) {
                bytes.extend_from_slice(&if encoding == Encoding::Utf16Le { unit.to_le_bytes() } else { unit.to_be_bytes() });
            }
        }
        Encoding::Utf32Le => bytes.extend_from_slice(&(c as u32).to_le_bytes()),
        Encoding::Utf32Be => bytes.extend_from_slice(&(c as u32).to_be_bytes()),
        Encoding::SingleByte(page) => match single_byte_code(page, c) {
            Some(byte) => bytes.push(byte),
            None => { bytes.push(b'?'); return true; }
        },
    }
    false
}

impl SingleByte {
    /// The code page's index in [`Encoding::all`] after the Unicode encodings.
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

fn reverse_table(page: usize) -> &'static [(u16, u8)] {
    static REVERSE: OnceLock<Vec<Vec<(u16, u8)>>> = OnceLock::new();
    &REVERSE.get_or_init(|| {
        PAGES
            .iter()
            .map(|page| {
                let mut pairs: Vec<(u16, u8)> = page
                    .high
                    .iter()
                    .enumerate()
                    .filter(|&(_, &code)| code != 0xFFFD)
                    .map(|(i, &code)| (code, 0x80 + i as u8))
                    .collect();
                pairs.sort_unstable();
                pairs.dedup_by_key(|pair| pair.0);
                pairs
            })
            .collect()
    })[page]
}

fn decode_utf8(bytes: &[u8]) -> Decoded {
    match std::str::from_utf8(bytes) {
        Ok(text) => Decoded {
            text: text.to_owned(),
            errors: 0,
        },
        Err(_) => {
            let text = String::from_utf8_lossy(bytes).into_owned();
            let errors = text.chars().filter(|&c| c == '\u{FFFD}').count()
                - count_replacement_chars_in_valid_input(bytes);
            Decoded { text, errors }
        }
    }
}

/// U+FFFD characters that were genuinely in the input (encoded as EF BF BD),
/// so they are not counted as decoding errors.
fn count_replacement_chars_in_valid_input(bytes: &[u8]) -> usize {
    bytes.windows(3).filter(|w| *w == [0xEF, 0xBF, 0xBD]).count()
}

fn decode_utf16(bytes: &[u8], read: fn([u8; 2]) -> u16) -> Decoded {
    let units = bytes.as_chunks::<2>().0.iter().map(|&pair| read(pair));
    let mut text = String::with_capacity(bytes.len() / 2 + 8);
    let mut errors = 0;
    for unit in char::decode_utf16(units) {
        match unit {
            Ok(c) => text.push(c),
            Err(_) => {
                errors += 1;
                text.push('\u{FFFD}');
            }
        }
    }
    if bytes.len() % 2 == 1 {
        errors += 1;
        text.push('\u{FFFD}');
    }
    Decoded { text, errors }
}

fn decode_utf32(bytes: &[u8], read: fn([u8; 4]) -> u32) -> Decoded {
    let mut text = String::with_capacity(bytes.len() / 4 + 8);
    let mut errors = 0;
    for &quad in bytes.as_chunks::<4>().0 {
        match char::from_u32(read(quad)) {
            Some(c) => text.push(c),
            None => {
                errors += 1;
                text.push('\u{FFFD}');
            }
        }
    }
    if !bytes.len().is_multiple_of(4) {
        errors += 1;
        text.push('\u{FFFD}');
    }
    Decoded { text, errors }
}

/// The byte-order mark at the start of `bytes`, if any.
pub fn sniff_bom(bytes: &[u8]) -> Option<(Encoding, usize)> {
    // UTF-32LE's mark begins with UTF-16LE's, so test it first.
    if bytes.starts_with(&[0xFF, 0xFE, 0x00, 0x00]) {
        Some((Encoding::Utf32Le, 4))
    } else if bytes.starts_with(&[0x00, 0x00, 0xFE, 0xFF]) {
        Some((Encoding::Utf32Be, 4))
    } else if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        Some((Encoding::Utf8, 3))
    } else if bytes.starts_with(&[0xFF, 0xFE]) {
        Some((Encoding::Utf16Le, 2))
    } else if bytes.starts_with(&[0xFE, 0xFF]) {
        Some((Encoding::Utf16Be, 2))
    } else {
        None
    }
}

/// What [`detect`] concluded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Detection {
    pub encoding: Encoding,
    /// Length of the byte-order mark to skip (0 when there is none).
    pub bom_len: usize,
    /// False when the choice is a guess between code pages, which the user
    /// may need to correct.
    pub confident: bool,
}

/// Guess the encoding of a complete file's `bytes`.
///
/// In order: a byte-order mark; the zero-byte pattern of BOM-less UTF-16;
/// valid UTF-8 (pure ASCII counts); and otherwise a single-byte code page,
/// choosing Cyrillic over `fallback` when the high bytes look like Cyrillic
/// letters. `fallback` is usually Windows-1252 or the code page of the
/// user's locale.
pub fn detect(bytes: &[u8], fallback: Encoding) -> Detection {
    detect_inner(bytes, fallback, false)
}

/// Like [`detect`], for the first part of a larger file: a UTF-8 sequence
/// cut off at the very end of `sample` does not count against UTF-8.
pub fn detect_sample(sample: &[u8], fallback: Encoding) -> Detection {
    detect_inner(sample, fallback, true)
}

fn detect_inner(bytes: &[u8], fallback: Encoding, truncated: bool) -> Detection {
    if let Some((encoding, bom_len)) = sniff_bom(bytes) {
        return Detection {
            encoding,
            bom_len,
            confident: true,
        };
    }
    if let Some(encoding) = sniff_utf16(bytes) {
        return Detection {
            encoding,
            bom_len: 0,
            confident: true,
        };
    }
    if utf8_is_valid(bytes, truncated) {
        return Detection {
            encoding: Encoding::Utf8,
            bom_len: 0,
            confident: true,
        };
    }
    Detection {
        encoding: guess_code_page(bytes).unwrap_or(fallback),
        bom_len: 0,
        confident: false,
    }
}

/// Valid UTF-8; with `truncated`, a multi-byte sequence cut off at the very
/// end is allowed too.
fn utf8_is_valid(bytes: &[u8], truncated: bool) -> bool {
    match std::str::from_utf8(bytes) {
        Ok(_) => true,
        Err(e) => truncated && e.error_len().is_none() && bytes.len() - e.valid_up_to() < 4,
    }
}

fn sniff_utf16(bytes: &[u8]) -> Option<Encoding> {
    let sample = &bytes[..bytes.len().min(64 * 1024) & !1];
    let pairs = sample.len() / 2;
    if pairs < 2 {
        return None;
    }
    let (mut even_zero, mut odd_zero) = (0usize, 0usize);
    for pair in sample.as_chunks::<2>().0 {
        even_zero += (pair[0] == 0) as usize;
        odd_zero += (pair[1] == 0) as usize;
    }
    // Mostly-Latin text in UTF-16 has a zero in one half of most pairs, and
    // almost never in the other.
    if odd_zero * 10 >= pairs * 4 && even_zero * 50 <= pairs {
        Some(Encoding::Utf16Le)
    } else if even_zero * 10 >= pairs * 4 && odd_zero * 50 <= pairs {
        Some(Encoding::Utf16Be)
    } else {
        None
    }
}

/// Recognize Cyrillic Windows-1251 text: most letters are high bytes, and
/// the lowercase block (0xE0-0xFF) dominates as it does in running text.
fn guess_code_page(bytes: &[u8]) -> Option<Encoding> {
    let (mut ascii_letters, mut high, mut lower_cyrillic, mut upper_cyrillic) = (0usize, 0usize, 0usize, 0usize);
    for &b in bytes.iter().take(256 * 1024) {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' => ascii_letters += 1,
            0xE0..=0xFF => {
                high += 1;
                lower_cyrillic += 1;
            }
            0xC0..=0xDF => {
                high += 1;
                upper_cyrillic += 1;
            }
            0x80..=0xBF => high += 1,
            _ => {}
        }
    }
    let letters = lower_cyrillic + upper_cyrillic;
    if letters >= 8 && letters * 2 > ascii_letters && lower_cyrillic > upper_cyrillic && letters * 10 >= high * 8 {
        Encoding::from_label("windows-1251")
    } else {
        None
    }
}

/// Whether `bytes` looks like binary data rather than text: zero bytes
/// outside UTF-16/32, or a high share of control characters.
pub fn looks_binary(bytes: &[u8]) -> bool {
    let sample = &bytes[..bytes.len().min(64 * 1024)];
    if sample.is_empty() {
        return false;
    }
    if let Some((encoding, _)) = sniff_bom(sample) {
        if encoding != Encoding::Utf8 {
            return false;
        }
    }
    if sniff_utf16(sample).is_some() {
        return false;
    }
    if sample.contains(&0) {
        return true;
    }
    let controls = sample
        .iter()
        .filter(|&&b| b < 0x20 && !matches!(b, b'\n' | b'\r' | b'\t' | 0x0C | 0x1B))
        .count();
    controls * 20 > sample.len()
}

/// Decode a whole file: strip and honour a byte-order mark, otherwise use
/// [`detect`] with `fallback`.
pub fn decode_detected(bytes: &[u8], fallback: Encoding) -> (Decoded, Detection) {
    let detection = detect(bytes, fallback);
    (detection.encoding.decode(&bytes[detection.bom_len..]), detection)
}

#[cfg(test)]
mod tests;
