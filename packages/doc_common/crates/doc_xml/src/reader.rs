//! A pull parser over UTF-8 text.

use std::borrow::Cow;

use doc_encoding::Encoding;

use crate::escape::unescape;
use crate::XmlError;

/// One piece of an XML document.
#[derive(Debug, Clone, PartialEq)]
pub enum Event<'a> {
    /// The inside of `<?xml ... ?>`.
    Declaration(&'a str),
    Start(StartTag<'a>),
    /// An end tag, or the implicit end of an empty-element tag.
    End(&'a str),
    /// Character data with references expanded and line ends normalized.
    Text(Cow<'a, str>),
    CData(&'a str),
    Comment(&'a str),
    /// The inside of a processing instruction `<? ... ?>`.
    Pi(&'a str),
    /// The inside of `<!DOCTYPE ... >`, skipped and never interpreted.
    DocType(&'a str),
    Eof,
}

/// A start tag (or an empty-element tag, with `empty` set).
#[derive(Debug, Clone, PartialEq)]
pub struct StartTag<'a> {
    /// The qualified name as written, e.g. `w:p`.
    pub name: &'a str,
    pub empty: bool,
    raw_attrs: &'a str,
    /// Byte offset of the attributes, for error positions.
    attrs_at: usize,
}

impl<'a> StartTag<'a> {
    /// The local part of the name (after any prefix).
    pub fn local(&self) -> &'a str {
        self.name.rsplit_once(':').map_or(self.name, |(_, local)| local)
    }

    /// The tag's attributes, in document order.
    pub fn attrs(&self) -> Attrs<'a> {
        Attrs {
            src: self.raw_attrs,
            pos: 0,
            base: self.attrs_at,
        }
    }

    /// The value of the attribute with this qualified name, if present and
    /// well-formed.
    pub fn attr(&self, name: &str) -> Option<Cow<'a, str>> {
        self.attrs()
            .filter_map(Result::ok)
            .find(|(n, _)| *n == name)
            .map(|(_, v)| v)
    }
}

/// Iterator over a start tag's attributes: `(qualified name, value)`.
pub struct Attrs<'a> {
    src: &'a str,
    pos: usize,
    base: usize,
}

impl<'a> Iterator for Attrs<'a> {
    type Item = Result<(&'a str, Cow<'a, str>), XmlError>;

    fn next(&mut self) -> Option<Self::Item> {
        let bytes = self.src.as_bytes();
        while self.pos < bytes.len() && bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
        if self.pos >= bytes.len() {
            return None;
        }
        let name_start = self.pos;
        while self.pos < bytes.len() && !bytes[self.pos].is_ascii_whitespace() && bytes[self.pos] != b'=' {
            self.pos += 1;
        }
        let name = &self.src[name_start..self.pos];
        while self.pos < bytes.len() && bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
        let fail = |pos: usize, message: &str| {
            Some(Err(XmlError::new(pos, message.to_owned())))
        };
        if bytes.get(self.pos) != Some(&b'=') {
            self.pos = bytes.len();
            return fail(self.base + name_start, "attribute without a value");
        }
        self.pos += 1;
        while self.pos < bytes.len() && bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
        let quote = match bytes.get(self.pos) {
            Some(&q @ (b'"' | b'\'')) => q,
            _ => {
                self.pos = bytes.len();
                return fail(self.base + name_start, "attribute value is not quoted");
            }
        };
        let value_start = self.pos + 1;
        let Some(len) = bytes[value_start..].iter().position(|&b| b == quote) else {
            self.pos = bytes.len();
            return fail(self.base + name_start, "unterminated attribute value");
        };
        self.pos = value_start + len + 1;
        let raw = &self.src[value_start..value_start + len];
        Some(normalize_attr(raw, self.base + value_start).map(|value| (name, value)))
    }
}

/// Attribute-value normalization: references expanded, and literal tabs and
/// line ends become spaces (a referenced `&#10;` stays a line feed).
fn normalize_attr(raw: &str, base: usize) -> Result<Cow<'_, str>, XmlError> {
    let needs_space = raw.as_bytes().iter().any(|&b| matches!(b, b'\t' | b'\n' | b'\r'));
    if !needs_space {
        return unescape(raw, base);
    }
    // Normalize the literal whitespace first, then expand references, so
    // that references to whitespace survive.
    let mut spaced = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                spaced.push(' ');
            }
            '\t' | '\n' => spaced.push(' '),
            c => spaced.push(c),
        }
    }
    Ok(Cow::Owned(unescape(&spaced, base)?.into_owned()))
}

/// A pull parser. Call [`Reader::next`] until it returns [`Event::Eof`].
///
/// Well-formedness is checked only as far as the document formats need:
/// tags must nest and close, but names are not validated character by
/// character.
pub struct Reader<'a> {
    src: &'a str,
    pos: usize,
    pending_end: Option<&'a str>,
    stack: Vec<&'a str>,
    seen_root: bool,
}

impl<'a> Reader<'a> {
    pub fn new(src: &'a str) -> Self {
        let src = src.strip_prefix('\u{FEFF}').unwrap_or(src);
        Self {
            src,
            pos: 0,
            pending_end: None,
            stack: Vec::new(),
            seen_root: false,
        }
    }

    /// Current byte offset in the input.
    pub fn offset(&self) -> usize {
        self.pos
    }

    /// The input being read (after any byte-order mark).
    pub fn source(&self) -> &'a str {
        self.src
    }

    /// Element nesting depth at this point.
    pub fn depth(&self) -> usize {
        self.stack.len()
    }

    fn err(&self, at: usize, message: impl Into<String>) -> XmlError {
        XmlError::new(at, message)
    }

    /// The next event.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Event<'a>, XmlError> {
        if let Some(name) = self.pending_end.take() {
            return Ok(Event::End(name));
        }
        let src = self.src;
        let bytes = src.as_bytes();
        if self.pos >= bytes.len() {
            if let Some(open) = self.stack.last() {
                return Err(self.err(self.pos, format!("<{open}> is never closed")));
            }
            return Ok(Event::Eof);
        }
        let start = self.pos;
        if bytes[start] != b'<' {
            let end = src[start..].find('<').map_or(bytes.len(), |n| start + n);
            self.pos = end;
            return Ok(Event::Text(unescape(&src[start..end], start)?));
        }
        match bytes.get(start + 1) {
            Some(b'/') => {
                let close = src[start..]
                    .find('>')
                    .map(|n| start + n)
                    .ok_or_else(|| self.err(start, "unterminated end tag"))?;
                let name = src[start + 2..close].trim();
                self.pos = close + 1;
                match self.stack.pop() {
                    Some(open) if open == name => Ok(Event::End(name)),
                    Some(open) => Err(self.err(start, format!("</{name}> closes <{open}>"))),
                    None => Err(self.err(start, format!("</{name}> has no start tag"))),
                }
            }
            Some(b'?') => {
                let close = src[start + 2..]
                    .find("?>")
                    .map(|n| start + 2 + n)
                    .ok_or_else(|| self.err(start, "unterminated processing instruction"))?;
                let inner = &src[start + 2..close];
                self.pos = close + 2;
                // Bytes, not text: the third byte may be inside a character.
                let is_decl = inner.as_bytes().get(..3).is_some_and(|b| b.eq_ignore_ascii_case(b"xml"))
                    && inner.as_bytes().get(3).is_some_and(u8::is_ascii_whitespace);
                if is_decl && start == 0 {
                    Ok(Event::Declaration(inner))
                } else {
                    Ok(Event::Pi(inner))
                }
            }
            Some(b'!') => {
                let rest = &src[start..];
                if rest.starts_with("<!--") {
                    let close = src[start + 4..]
                        .find("-->")
                        .map(|n| start + 4 + n)
                        .ok_or_else(|| self.err(start, "unterminated comment"))?;
                    self.pos = close + 3;
                    Ok(Event::Comment(&src[start + 4..close]))
                } else if rest.starts_with("<![CDATA[") {
                    let close = src[start + 9..]
                        .find("]]>")
                        .map(|n| start + 9 + n)
                        .ok_or_else(|| self.err(start, "unterminated CDATA section"))?;
                    self.pos = close + 3;
                    Ok(Event::CData(&src[start + 9..close]))
                } else if rest.as_bytes().get(..9).is_some_and(|b| b.eq_ignore_ascii_case(b"<!DOCTYPE")) {
                    let close = doctype_end(bytes, start + 9).ok_or_else(|| self.err(start, "unterminated DOCTYPE"))?;
                    self.pos = close + 1;
                    Ok(Event::DocType(src[start + 9..close].trim()))
                } else {
                    Err(self.err(start, "unknown markup declaration"))
                }
            }
            Some(_) => {
                let name_end = bytes[start + 1..]
                    .iter()
                    .position(|&b| b.is_ascii_whitespace() || b == b'>' || b == b'/')
                    .map(|n| start + 1 + n)
                    .ok_or_else(|| self.err(start, "unterminated start tag"))?;
                let name = &src[start + 1..name_end];
                if name.is_empty() {
                    return Err(self.err(start, "start tag without a name"));
                }
                let close = tag_end(bytes, name_end).ok_or_else(|| self.err(start, format!("unterminated <{name}>")))?;
                let empty = bytes[close - 1] == b'/' && close > name_end;
                let attrs_end = if empty { close - 1 } else { close };
                let raw_attrs = &src[name_end..attrs_end];
                self.pos = close + 1;
                if self.stack.is_empty() {
                    if self.seen_root {
                        return Err(self.err(start, "content after the root element"));
                    }
                    self.seen_root = true;
                }
                if empty {
                    self.pending_end = Some(name);
                } else {
                    if self.stack.len() >= crate::MAX_DEPTH {
                        return Err(self.err(start, "elements nest too deeply"));
                    }
                    self.stack.push(name);
                }
                Ok(Event::Start(StartTag {
                    name,
                    empty,
                    raw_attrs,
                    attrs_at: name_end,
                }))
            }
            None => Err(self.err(start, "document ends inside a tag")),
        }
    }

    /// Skip the rest of the element whose start tag was just read (its
    /// children and its end tag).
    pub fn skip_element(&mut self) -> Result<(), XmlError> {
        let target = self.stack.len();
        if self.pending_end.take().is_some() {
            return Ok(());
        }
        loop {
            match self.next()? {
                Event::End(_) if self.stack.len() < target => return Ok(()),
                Event::Eof => return Err(self.err(self.pos, "document ends inside an element")),
                _ => {}
            }
        }
    }

    /// Read the text content of the element whose start tag was just read,
    /// up to its end tag (child elements' text is included).
    pub fn read_text(&mut self) -> Result<String, XmlError> {
        let target = self.stack.len();
        let mut out = String::new();
        if self.pending_end.take().is_some() {
            return Ok(out);
        }
        loop {
            match self.next()? {
                Event::Text(text) => out.push_str(&text),
                Event::CData(text) => out.push_str(text),
                Event::End(_) if self.stack.len() < target => return Ok(out),
                Event::Eof => return Err(self.err(self.pos, "document ends inside an element")),
                _ => {}
            }
        }
    }
}

/// The `>` that ends a start tag, skipping quoted attribute values.
fn tag_end(bytes: &[u8], from: usize) -> Option<usize> {
    let mut quote = 0u8;
    for (i, &b) in bytes.iter().enumerate().skip(from) {
        if quote != 0 {
            if b == quote {
                quote = 0;
            }
        } else if b == b'"' || b == b'\'' {
            quote = b;
        } else if b == b'>' {
            return Some(i);
        } else if b == b'<' {
            return None;
        }
    }
    None
}

/// The `>` that ends a DOCTYPE, skipping its internal subset and quotes.
fn doctype_end(bytes: &[u8], from: usize) -> Option<usize> {
    let mut quote = 0u8;
    let mut bracket = 0usize;
    for (i, &b) in bytes.iter().enumerate().skip(from) {
        if quote != 0 {
            if b == quote {
                quote = 0;
            }
            continue;
        }
        match b {
            b'"' | b'\'' => quote = b,
            b'[' => bracket += 1,
            b']' => bracket = bracket.saturating_sub(1),
            b'>' if bracket == 0 => return Some(i),
            _ => {}
        }
    }
    None
}

/// Turn the bytes of an XML part into text: a byte-order mark wins, then the
/// declaration's `encoding`, then UTF-8. Returns the text and whether any
/// bytes were undecodable.
pub fn decode_bytes(bytes: &[u8]) -> (Cow<'_, str>, bool) {
    if let Some((encoding, bom)) = doc_encoding::sniff_bom(bytes) {
        if encoding == Encoding::Utf8 {
            return utf8(&bytes[bom..]);
        }
        let decoded = encoding.decode(&bytes[bom..]);
        return (Cow::Owned(decoded.text), decoded.errors > 0);
    }
    // UTF-16 without a mark still starts with '<' and a zero byte.
    if bytes.starts_with(&[b'<', 0]) {
        let decoded = Encoding::Utf16Le.decode(bytes);
        return (Cow::Owned(decoded.text), decoded.errors > 0);
    }
    if bytes.starts_with(&[0, b'<']) {
        let decoded = Encoding::Utf16Be.decode(bytes);
        return (Cow::Owned(decoded.text), decoded.errors > 0);
    }
    if let Some(label) = declared_encoding(bytes) {
        if let Some(encoding) = Encoding::from_label(&label) {
            if !encoding.is_unicode() {
                let decoded = encoding.decode(bytes);
                return (Cow::Owned(decoded.text), decoded.errors > 0);
            }
        }
    }
    utf8(bytes)
}

fn utf8(bytes: &[u8]) -> (Cow<'_, str>, bool) {
    match std::str::from_utf8(bytes) {
        Ok(text) => (Cow::Borrowed(text), false),
        Err(_) => (Cow::Owned(String::from_utf8_lossy(bytes).into_owned()), true),
    }
}

fn declared_encoding(bytes: &[u8]) -> Option<String> {
    if !bytes.starts_with(b"<?xml") {
        return None;
    }
    let end = bytes.iter().position(|&b| b == b'>')?;
    let decl = std::str::from_utf8(&bytes[..end]).ok()?;
    let at = decl.find("encoding")?;
    let rest = decl[at + 8..].trim_start().strip_prefix('=')?.trim_start();
    let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'')?;
    let value = &rest[1..];
    Some(value[..value.find(quote)?].to_owned())
}
