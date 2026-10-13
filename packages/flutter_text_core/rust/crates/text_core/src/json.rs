//! JSON validation and re-indentation.
//!
//! Works token by token instead of building a value, so a formatted file
//! keeps its key order, number spelling and string escapes exactly: only
//! the whitespace between tokens changes.

/// Where and why a document is not valid JSON.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonError {
    /// 1-based.
    pub line: usize,
    /// 1-based, in characters.
    pub column: usize,
    pub message: String,
}

impl std::fmt::Display for JsonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}, column {}: {}", self.line, self.column, self.message)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Expect {
    Value,
    /// After `[`: a value or `]`.
    ValueOrEnd,
    /// After `{` or `,` in an object: a key (or `}` right after `{`).
    Key { allow_end: bool },
    Colon,
    CommaOrEnd,
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Container {
    Object,
    Array,
}

struct Formatter<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
    out: String,
    indent: usize,
    stack: Vec<Container>,
}

/// Maximum nesting, to keep pathological input from exhausting memory.
const MAX_DEPTH: usize = 10_000;

impl<'a> Formatter<'a> {
    fn error(&self, at: usize, message: impl Into<String>) -> JsonError {
        let before = &self.src[..at.min(self.src.len())];
        let line = before.matches('\n').count() + 1;
        let column = before.rsplit('\n').next().map_or(0, |l| l.chars().count()) + 1;
        JsonError {
            line,
            column,
            message: message.into(),
        }
    }

    fn newline(&mut self) {
        if self.indent > 0 {
            self.out.push('\n');
            for _ in 0..self.stack.len() * self.indent {
                self.out.push(' ');
            }
        }
    }

    fn skip_whitespace(&mut self) {
        while self.pos < self.bytes.len() && matches!(self.bytes[self.pos], b' ' | b'\t' | b'\n' | b'\r') {
            self.pos += 1;
        }
    }

    fn string(&mut self) -> Result<(), JsonError> {
        let start = self.pos;
        self.pos += 1;
        loop {
            match self.bytes.get(self.pos) {
                None => return Err(self.error(start, "this string never ends")),
                Some(b'"') => {
                    self.pos += 1;
                    break;
                }
                Some(b'\\') => {
                    match self.bytes.get(self.pos + 1) {
                        Some(b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't') => self.pos += 2,
                        Some(b'u') => {
                            let hex = self.bytes.get(self.pos + 2..self.pos + 6);
                            if !hex.is_some_and(|h| h.iter().all(u8::is_ascii_hexdigit)) {
                                return Err(self.error(self.pos, "\\u must be followed by four hex digits"));
                            }
                            self.pos += 6;
                        }
                        _ => return Err(self.error(self.pos, "unknown escape in a string")),
                    }
                }
                Some(&b) if b < 0x20 => {
                    return Err(self.error(self.pos, "control characters must be escaped in strings"))
                }
                Some(_) => self.pos += 1,
            }
        }
        self.out.push_str(&self.src[start..self.pos]);
        Ok(())
    }

    fn number(&mut self) -> Result<(), JsonError> {
        let start = self.pos;
        let digits = |f: &mut Self| {
            let from = f.pos;
            while f.bytes.get(f.pos).is_some_and(u8::is_ascii_digit) {
                f.pos += 1;
            }
            f.pos - from
        };
        if self.bytes[self.pos] == b'-' {
            self.pos += 1;
        }
        let int_start = self.pos;
        if digits(self) == 0 {
            return Err(self.error(start, "a number needs digits"));
        }
        if self.bytes[int_start] == b'0' && self.pos - int_start > 1 {
            return Err(self.error(start, "numbers cannot have leading zeros"));
        }
        if self.bytes.get(self.pos) == Some(&b'.') {
            self.pos += 1;
            if digits(self) == 0 {
                return Err(self.error(start, "a decimal point needs digits after it"));
            }
        }
        if matches!(self.bytes.get(self.pos), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.bytes.get(self.pos), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if digits(self) == 0 {
                return Err(self.error(start, "an exponent needs digits"));
            }
        }
        self.out.push_str(&self.src[start..self.pos]);
        Ok(())
    }

    fn literal(&mut self) -> Result<(), JsonError> {
        for word in ["true", "false", "null"] {
            if self.src[self.pos..].starts_with(word) {
                self.pos += word.len();
                self.out.push_str(word);
                return Ok(());
            }
        }
        Err(self.error(self.pos, "expected a value"))
    }

    fn after_value(&self) -> Expect {
        if self.stack.is_empty() {
            Expect::Done
        } else {
            Expect::CommaOrEnd
        }
    }

    fn run(mut self) -> Result<String, JsonError> {
        if self.src.starts_with('\u{FEFF}') {
            self.pos = 3;
        }
        let mut expect = Expect::Value;
        loop {
            self.skip_whitespace();
            let Some(&b) = self.bytes.get(self.pos) else {
                return match expect {
                    Expect::Done => Ok(self.out),
                    _ if self.out.is_empty() => Err(self.error(self.pos, "the document is empty")),
                    _ => Err(self.error(self.pos, "the document ends too early")),
                };
            };
            match (expect, b) {
                (Expect::Done, _) => return Err(self.error(self.pos, "unexpected text after the end")),
                (Expect::Key { .. }, b'"') => {
                    self.newline();
                    self.string()?;
                    expect = Expect::Colon;
                }
                (Expect::Key { allow_end: true }, b'}') | (Expect::ValueOrEnd, b']') => {
                    self.stack.pop();
                    self.pos += 1;
                    self.out.push(b as char);
                    expect = self.after_value();
                }
                (Expect::Key { .. }, _) => return Err(self.error(self.pos, "expected a key in double quotes")),
                (Expect::Colon, b':') => {
                    self.pos += 1;
                    self.out.push(':');
                    if self.indent > 0 {
                        self.out.push(' ');
                    }
                    expect = Expect::Value;
                }
                (Expect::Colon, _) => return Err(self.error(self.pos, "expected ':' after the key")),
                (Expect::CommaOrEnd, b',') => {
                    self.pos += 1;
                    self.out.push(',');
                    expect = match self.stack.last() {
                        Some(Container::Object) => Expect::Key { allow_end: false },
                        _ => Expect::Value,
                    };
                }
                (Expect::CommaOrEnd, b'}' | b']') => {
                    let wanted = if b == b'}' { Container::Object } else { Container::Array };
                    if self.stack.last() != Some(&wanted) {
                        return Err(self.error(self.pos, format!("'{}' does not close what is open", b as char)));
                    }
                    self.stack.pop();
                    self.newline();
                    self.pos += 1;
                    self.out.push(b as char);
                    expect = self.after_value();
                }
                (Expect::CommaOrEnd, _) => {
                    let closer = if self.stack.last() == Some(&Container::Object) { '}' } else { ']' };
                    return Err(self.error(self.pos, format!("expected ',' or '{closer}'")));
                }
                (Expect::Value | Expect::ValueOrEnd, _) => {
                    if !self.stack.is_empty() && self.stack.last() == Some(&Container::Array) {
                        self.newline();
                    }
                    match b {
                        b'{' | b'[' => {
                            if self.stack.len() >= MAX_DEPTH {
                                return Err(self.error(self.pos, "nested too deeply"));
                            }
                            self.pos += 1;
                            self.out.push(b as char);
                            if b == b'{' {
                                self.stack.push(Container::Object);
                                expect = Expect::Key { allow_end: true };
                            } else {
                                self.stack.push(Container::Array);
                                expect = Expect::ValueOrEnd;
                            }
                            continue;
                        }
                        b'"' => self.string()?,
                        b'-' | b'0'..=b'9' => self.number()?,
                        _ => self.literal()?,
                    }
                    expect = self.after_value();
                }
            }
        }
    }
}

/// Re-indent JSON with `indent` spaces per level, or compact it when
/// `indent` is 0. Empty objects and arrays stay `{}` and `[]`.
pub fn format(text: &str, indent: usize) -> Result<String, JsonError> {
    Formatter {
        src: text,
        bytes: text.as_bytes(),
        pos: 0,
        out: String::with_capacity(text.len() + text.len() / 4),
        indent: indent.min(8),
        stack: Vec::new(),
    }
    .run()
}

/// Whether `text` is valid JSON (the error says where it is not).
pub fn validate(text: &str) -> Result<(), JsonError> {
    format(text, 0).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pretty_prints_keeping_tokens() {
        let src = concat!(r#"{"b":1.50,"a":[1,2,{}],"e":[],"s":"x"#, "\\u0041", r#"\n","n":null,"t":true}"#);
        let pretty = format(src, 2).unwrap();
        assert_eq!(
            pretty,
            "{\n  \"b\": 1.50,\n  \"a\": [\n    1,\n    2,\n    {}\n  ],\n  \"e\": [],\n  \"s\": \"x\\u0041\\n\",\n  \"n\": null,\n  \"t\": true\n}"
        );
        assert_eq!(format(&pretty, 0).unwrap(), src);
    }

    #[test]
    fn top_level_scalars_and_nesting() {
        assert_eq!(format(" 42 ", 2).unwrap(), "42");
        assert_eq!(format("\"x\"", 2).unwrap(), "\"x\"");
        assert_eq!(format("[[[]]]", 1).unwrap(), "[\n [\n  []\n ]\n]");
        assert_eq!(format("\u{FEFF}{}", 2).unwrap(), "{}");
    }

    #[test]
    fn reports_where_it_breaks() {
        let cases = [
            ("{\"a\": 1,}", 1, 9, "expected a key in double quotes"),
            ("[1 2]", 1, 4, "expected ',' or ']'"),
            ("{\n  \"a\" 1\n}", 2, 7, "expected ':' after the key"),
            ("[01]", 1, 2, "numbers cannot have leading zeros"),
            ("{\"a\": tru}", 1, 7, "expected a value"),
            ("[1]]", 1, 4, "unexpected text after the end"),
            ("", 1, 1, "the document is empty"),
            ("{\"a\": [1, 2}", 1, 12, "'}' does not close what is open"),
            ("\"tab\there\"", 1, 5, "control characters must be escaped in strings"),
        ];
        for (src, line, column, message) in cases {
            let err = format(src, 2).unwrap_err();
            assert_eq!((err.line, err.column, err.message.as_str()), (line, column, message), "{src:?}");
        }
        assert!(validate("{\"ok\": [1, -2.5e3, \"\\\"\"]}").is_ok());
    }
}
