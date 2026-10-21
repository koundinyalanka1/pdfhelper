//! A streaming writer for generating XML parts.

use crate::escape::{escape_attr, escape_text};
use crate::dom::OFFICE_DECLARATION;

/// Writes well-formed XML: escapes text and attribute values, closes
/// elements in order, and writes childless elements as `<a/>`.
///
/// ```
/// let mut w = doc_xml::XmlWriter::with_declaration();
/// w.start("row").attr("r", "1");
/// w.start("c").attr("r", "A1").text("5 < 6").end();
/// w.end();
/// assert!(w.finish().ends_with(r#"<row r="1"><c r="A1">5 &lt; 6</c></row>"#));
/// ```
#[derive(Default)]
pub struct XmlWriter {
    out: String,
    open: Vec<String>,
    /// A start tag is open (`<a x="1"`) and not yet closed by `>` or `/>`.
    in_tag: bool,
}

impl XmlWriter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start with Office's standard declaration and a line break.
    pub fn with_declaration() -> Self {
        let mut w = Self::new();
        w.out.push_str("<?");
        w.out.push_str(OFFICE_DECLARATION);
        w.out.push_str("?>\r\n");
        w
    }

    /// A writer that appends to existing text.
    pub fn appending(out: String) -> Self {
        Self {
            out,
            open: Vec::new(),
            in_tag: false,
        }
    }

    fn close_tag(&mut self) {
        if self.in_tag {
            self.out.push('>');
            self.in_tag = false;
        }
    }

    /// Open an element.
    pub fn start(&mut self, name: &str) -> &mut Self {
        self.close_tag();
        self.out.push('<');
        self.out.push_str(name);
        self.open.push(name.to_owned());
        self.in_tag = true;
        self
    }

    /// Add an attribute to the element just opened.
    pub fn attr(&mut self, name: &str, value: &str) -> &mut Self {
        debug_assert!(self.in_tag, "attribute {name} written outside a start tag");
        self.out.push(' ');
        self.out.push_str(name);
        self.out.push_str("=\"");
        escape_attr(value, &mut self.out);
        self.out.push('"');
        self
    }

    /// Add an attribute only when there is a value.
    pub fn attr_opt(&mut self, name: &str, value: Option<&str>) -> &mut Self {
        if let Some(value) = value {
            self.attr(name, value);
        }
        self
    }

    /// Write escaped character data.
    pub fn text(&mut self, text: &str) -> &mut Self {
        self.close_tag();
        escape_text(text, &mut self.out);
        self
    }

    /// Write markup that is already serialized.
    pub fn raw(&mut self, xml: &str) -> &mut Self {
        self.close_tag();
        self.out.push_str(xml);
        self
    }

    /// Close the most recently opened element.
    pub fn end(&mut self) -> &mut Self {
        let name = self.open.pop().expect("end() without an open element");
        if self.in_tag {
            self.out.push_str("/>");
            self.in_tag = false;
        } else {
            self.out.push_str("</");
            self.out.push_str(&name);
            self.out.push('>');
        }
        self
    }

    /// `<name>text</name>`.
    pub fn element_text(&mut self, name: &str, text: &str) -> &mut Self {
        self.start(name).text(text).end()
    }

    /// Close any elements still open and return the text.
    pub fn finish(mut self) -> String {
        while !self.open.is_empty() {
            self.end();
        }
        self.out
    }

    /// Bytes written so far (including an unclosed start tag).
    pub fn len(&self) -> usize {
        self.out.len()
    }

    pub fn is_empty(&self) -> bool {
        self.out.is_empty()
    }
}
