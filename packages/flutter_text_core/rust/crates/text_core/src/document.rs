//! A text file in memory.

use doc_encoding::{detect, looks_binary, Encoding};

/// How a file breaks its lines.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineEnding {
    /// `\n`: Linux, Android, macOS.
    Lf,
    /// `\r\n`: Windows.
    CrLf,
    /// `\r`: classic Mac OS.
    Cr,
}

impl LineEnding {
    pub fn as_str(self) -> &'static str {
        match self {
            LineEnding::Lf => "\n",
            LineEnding::CrLf => "\r\n",
            LineEnding::Cr => "\r",
        }
    }

    /// `LF`, `CRLF` or `CR`.
    pub fn name(self) -> &'static str {
        match self {
            LineEnding::Lf => "LF",
            LineEnding::CrLf => "CRLF",
            LineEnding::Cr => "CR",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        match name.to_ascii_uppercase().as_str() {
            "LF" => Some(LineEnding::Lf),
            "CRLF" => Some(LineEnding::CrLf),
            "CR" => Some(LineEnding::Cr),
            _ => None,
        }
    }
}

/// Counts for a status line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stats {
    pub lines: usize,
    pub words: usize,
    /// Unicode scalar values.
    pub characters: usize,
    /// UTF-16 code units, the length a Dart string has.
    pub utf16_len: usize,
}

/// A text file: its content as Unicode with `\n` line breaks, and what it
/// takes to write it back the way it was.
#[derive(Clone, Debug)]
pub struct TextDocument {
    text: String,
    /// The file's bytes, kept until the first edit so that the user can
    /// reopen it in another encoding without losing anything.
    original: Option<Vec<u8>>,
    pub encoding: Encoding,
    /// Whether to write a byte-order mark.
    pub bom: bool,
    pub line_ending: LineEnding,
    /// The file mixed line-ending styles; saving makes them all
    /// [`TextDocument::line_ending`].
    pub mixed_line_endings: bool,
    /// Characters that could not be decoded and became U+FFFD.
    pub decode_errors: usize,
    /// False when the encoding is a guess between code pages.
    pub confident: bool,
    /// The bytes looked like a binary file, not text.
    pub binary: bool,
    modified: bool,
    line_starts: Option<Vec<usize>>,
}

/// Normalize line breaks to `\n`, reporting the dominant style and whether
/// styles were mixed.
fn normalize_line_endings(text: String) -> (String, LineEnding, bool) {
    let bytes = text.as_bytes();
    let (mut crlf, mut cr, mut lf) = (0usize, 0usize, 0usize);
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' if bytes.get(i + 1) == Some(&b'\n') => {
                crlf += 1;
                i += 2;
                continue;
            }
            b'\r' => cr += 1,
            b'\n' => lf += 1,
            _ => {}
        }
        i += 1;
    }
    let kinds = (crlf > 0) as u8 + (cr > 0) as u8 + (lf > 0) as u8;
    let ending = if crlf > lf && crlf >= cr {
        LineEnding::CrLf
    } else if cr > lf && cr > crlf {
        LineEnding::Cr
    } else {
        LineEnding::Lf
    };
    if crlf == 0 && cr == 0 {
        return (text, ending, false);
    }
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            out.push('\n');
        } else {
            out.push(c);
        }
    }
    (out, ending, kinds > 1)
}

impl Default for TextDocument {
    fn default() -> Self {
        Self::new()
    }
}

impl TextDocument {
    /// A new, empty UTF-8 document with `\n` line breaks.
    pub fn new() -> Self {
        Self {
            text: String::new(),
            original: None,
            encoding: Encoding::Utf8,
            bom: false,
            line_ending: LineEnding::Lf,
            mixed_line_endings: false,
            decode_errors: 0,
            confident: true,
            binary: false,
            modified: false,
            line_starts: None,
        }
    }

    /// Read a file's bytes, detecting its encoding (using `fallback` when
    /// the bytes could be any single-byte code page).
    pub fn from_bytes(bytes: Vec<u8>, fallback: Encoding) -> Self {
        let detection = detect(&bytes, fallback);
        let mut doc = Self::new();
        doc.binary = looks_binary(&bytes);
        doc.confident = detection.confident;
        doc.load(&bytes, detection.encoding, detection.bom_len);
        doc.original = Some(bytes);
        doc
    }

    fn load(&mut self, bytes: &[u8], encoding: Encoding, bom_len: usize) {
        let decoded = encoding.decode(&bytes[bom_len..]);
        let (text, ending, mixed) = normalize_line_endings(decoded.text);
        self.text = text;
        self.encoding = encoding;
        self.bom = bom_len > 0;
        self.line_ending = ending;
        self.mixed_line_endings = mixed;
        self.decode_errors = decoded.errors;
        self.modified = false;
        self.line_starts = None;
    }

    /// Re-read the original bytes as `encoding` ("the text looks wrong, try
    /// Cyrillic"). Only possible before the first edit.
    pub fn reinterpret(&mut self, encoding: Encoding) -> Result<(), &'static str> {
        let Some(bytes) = self.original.take() else {
            return Err("the text has been edited, so it can no longer be read in another encoding");
        };
        let bom_len = doc_encoding::sniff_bom(&bytes)
            .filter(|(found, _)| *found == encoding)
            .map_or(0, |(_, len)| len);
        self.load(&bytes, encoding, bom_len);
        self.confident = true;
        self.original = Some(bytes);
        Ok(())
    }

    pub fn can_reinterpret(&self) -> bool {
        self.original.is_some()
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_modified(&self) -> bool {
        self.modified
    }

    /// Replace the whole text. Any `\r\n` or `\r` becomes `\n`.
    pub fn set_text(&mut self, text: String) {
        let (text, _, _) = normalize_line_endings(text);
        if text != self.text {
            self.text = text;
            self.modified = true;
            self.original = None;
            self.line_starts = None;
        }
    }

    /// Mark the current state as saved.
    pub fn mark_saved(&mut self) {
        self.modified = false;
    }

    /// The bytes to write: the text with the chosen line breaks, encoding
    /// and byte-order mark. Also returns how many characters the encoding
    /// could not represent (each written as `?`).
    pub fn encode(&self) -> (Vec<u8>, usize) {
        let text = if self.line_ending == LineEnding::Lf {
            std::borrow::Cow::Borrowed(self.text.as_str())
        } else {
            std::borrow::Cow::Owned(self.text.replace('\n', self.line_ending.as_str()))
        };
        let encoded = self.encoding.encode(&text);
        let mut bytes = Vec::with_capacity(encoded.bytes.len() + 4);
        if self.bom {
            bytes.extend_from_slice(self.encoding.bom());
        }
        bytes.extend_from_slice(&encoded.bytes);
        (bytes, encoded.unmappable)
    }

    /// Characters the current encoding cannot represent.
    pub fn unmappable(&self) -> usize {
        if self.encoding.is_unicode() {
            0
        } else {
            self.encoding.encode(&self.text).unmappable
        }
    }

    fn starts(&mut self) -> &[usize] {
        if self.line_starts.is_none() {
            let mut starts = vec![0];
            starts.extend(self.text.match_indices('\n').map(|(i, _)| i + 1));
            self.line_starts = Some(starts);
        }
        self.line_starts.as_deref().unwrap_or(&[])
    }

    /// Number of lines (a final line break starts an empty last line).
    pub fn line_count(&mut self) -> usize {
        self.starts().len()
    }

    /// Lines `first..first + count`, without their line breaks.
    pub fn lines(&mut self, first: usize, count: usize) -> Vec<String> {
        let starts = self.starts().to_vec();
        let text = &self.text;
        (first..first.saturating_add(count).min(starts.len()))
            .map(|i| {
                let start = starts[i];
                let end = starts.get(i + 1).map_or(text.len(), |&next| next - 1);
                text[start..end].to_owned()
            })
            .collect()
    }

    /// The line containing byte offset `at` (0-based).
    pub fn line_of(&mut self, at: usize) -> usize {
        let starts = self.starts();
        match starts.binary_search(&at) {
            Ok(i) => i,
            Err(i) => i.saturating_sub(1),
        }
    }

    pub fn stats(&mut self) -> Stats {
        let lines = self.line_count();
        let text = &self.text;
        Stats {
            lines,
            words: text.split_whitespace().count(),
            characters: text.chars().count(),
            utf16_len: text.chars().map(char::len_utf16).sum(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(bytes: &[u8]) -> TextDocument {
        TextDocument::from_bytes(bytes.to_vec(), Encoding::WINDOWS_1252)
    }

    #[test]
    fn keeps_windows_files_as_they_were() {
        let bytes = b"first line\r\nsecond line\r\n";
        let doc = open(bytes);
        assert_eq!(doc.text(), "first line\nsecond line\n");
        assert_eq!(doc.line_ending, LineEnding::CrLf);
        assert!(!doc.mixed_line_endings);
        assert_eq!(doc.encode(), (bytes.to_vec(), 0));
    }

    #[test]
    fn keeps_bom_and_utf16() {
        let mut bytes = vec![0xFF, 0xFE];
        bytes.extend("తెలుగు\r\nline".encode_utf16().flat_map(u16::to_le_bytes));
        let doc = open(&bytes);
        assert_eq!(doc.encoding, Encoding::Utf16Le);
        assert!(doc.bom);
        assert_eq!(doc.text(), "తెలుగు\nline");
        assert_eq!(doc.encode().0, bytes);
    }

    #[test]
    fn mixed_line_endings_use_the_most_common() {
        let mut doc = open(b"a\r\nb\r\nc\nd\re");
        assert!(doc.mixed_line_endings);
        assert_eq!(doc.line_ending, LineEnding::CrLf);
        assert_eq!(doc.line_count(), 5);
        assert_eq!(doc.encode().0, b"a\r\nb\r\nc\r\nd\r\ne");
    }

    #[test]
    fn single_byte_text_survives_and_reinterprets() {
        let bytes = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, b' ', b'm', b'i', b'r'];
        let mut doc = TextDocument::from_bytes(bytes.to_vec(), Encoding::WINDOWS_1252);
        assert!(!doc.confident);
        assert_eq!(doc.encode().0, bytes);
        doc.reinterpret(Encoding::from_label("windows-1251").unwrap()).unwrap();
        assert_eq!(doc.text(), "Привет mir");
        assert_eq!(doc.encode().0, bytes);
        doc.set_text("edited".into());
        assert!(doc.reinterpret(Encoding::Utf8).is_err());
    }

    #[test]
    fn editing_and_unmappable_characters() {
        let mut doc = open(b"caf\xE9");
        assert_eq!(doc.text(), "café");
        assert!(!doc.is_modified());
        doc.set_text("café ₹ 100\r\nnext".into());
        assert!(doc.is_modified());
        assert_eq!(doc.text(), "café ₹ 100\nnext");
        assert_eq!(doc.unmappable(), 1);
        let (bytes, unmappable) = doc.encode();
        assert_eq!(unmappable, 1);
        assert_eq!(bytes, b"caf\xE9 ? 100\nnext");
        doc.encoding = Encoding::Utf8;
        assert_eq!(doc.unmappable(), 0);
    }

    #[test]
    fn paging_by_line() {
        let mut doc = open(b"zero\none\ntwo\n");
        assert_eq!(doc.line_count(), 4);
        assert_eq!(doc.lines(1, 2), ["one", "two"]);
        assert_eq!(doc.lines(3, 10), [""]);
        assert!(doc.lines(9, 1).is_empty());
        assert_eq!(doc.line_of(0), 0);
        assert_eq!(doc.line_of(5), 1);
        assert_eq!(doc.line_of(7), 1);
        let stats = doc.stats();
        assert_eq!((stats.lines, stats.words, stats.characters), (4, 3, 13));
    }

    #[test]
    fn empty_and_binary_files() {
        let mut doc = open(b"");
        assert_eq!(doc.line_count(), 1);
        assert_eq!(doc.encoding, Encoding::Utf8);
        assert!(!doc.binary);
        let doc = open(&[0x89, b'P', b'N', b'G', 0, 0, 0, 13, 0x49, 0x48]);
        assert!(doc.binary);
    }
}
