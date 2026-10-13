//! A round-tripping element tree.

use crate::escape::{escape_attr, escape_text};
use crate::ns::{self, Ns};
use crate::reader::{decode_bytes, Event, Reader};
use crate::XmlError;

/// An attribute, with its namespace resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attr {
    /// The qualified name as written (`w:val`, `xmlns:w`, `Id`).
    pub name: String,
    /// [`ns::NONE`] for unprefixed attributes; [`ns::XMLNS`] for namespace
    /// declarations.
    pub ns: Ns,
    pub value: String,
}

impl Attr {
    pub fn local(&self) -> &str {
        local_part(&self.name)
    }
}

/// A node in the tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    Element(Element),
    Text(String),
    CData(String),
    Comment(String),
    /// The inside of a processing instruction.
    Pi(String),
    /// The inside of a DOCTYPE (kept verbatim, never interpreted).
    DocType(String),
}

impl Node {
    pub fn as_element(&self) -> Option<&Element> {
        match self {
            Node::Element(e) => Some(e),
            _ => None,
        }
    }

    pub fn as_element_mut(&mut self) -> Option<&mut Element> {
        match self {
            Node::Element(e) => Some(e),
            _ => None,
        }
    }

    fn write(&self, out: &mut String) {
        match self {
            Node::Element(e) => e.write(out),
            Node::Text(t) => escape_text(t, out),
            Node::CData(t) => {
                // A "]]>" inside would end the section early; split it.
                out.push_str("<![CDATA[");
                out.push_str(&t.replace("]]>", "]]]]><![CDATA[>"));
                out.push_str("]]>");
            }
            Node::Comment(t) => {
                out.push_str("<!--");
                out.push_str(&t.replace("--", "- -"));
                out.push_str("-->");
            }
            Node::Pi(t) => {
                out.push_str("<?");
                out.push_str(&t.replace("?>", "? >"));
                out.push_str("?>");
            }
            Node::DocType(t) => {
                out.push_str("<!DOCTYPE ");
                out.push_str(t);
                out.push('>');
            }
        }
    }
}

fn local_part(name: &str) -> &str {
    name.rsplit_once(':').map_or(name, |(_, local)| local)
}

/// An element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Element {
    /// The qualified name as written (`w:p`).
    pub name: String,
    pub ns: Ns,
    pub attrs: Vec<Attr>,
    pub children: Vec<Node>,
}

impl Element {
    /// A new element. `name` is the qualified name to write; `ns` the
    /// namespace its prefix is bound to in the document it will join.
    pub fn new(name: impl Into<String>, ns: Ns) -> Self {
        Self {
            name: name.into(),
            ns,
            attrs: Vec::new(),
            children: Vec::new(),
        }
    }

    pub fn local(&self) -> &str {
        local_part(&self.name)
    }

    /// The prefix as written, or `""` for none.
    pub fn prefix(&self) -> &str {
        self.name.rsplit_once(':').map_or("", |(prefix, _)| prefix)
    }

    /// Whether this element is `{ns}local`.
    pub fn is(&self, ns: Ns, local: &str) -> bool {
        self.ns == ns && self.local() == local
    }

    /// The value of attribute `{ns}local`; use [`ns::NONE`] for unprefixed
    /// attributes.
    pub fn attr(&self, ns: Ns, local: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|a| a.ns == ns && a.local() == local)
            .map(|a| a.value.as_str())
    }

    /// The value of an attribute by its qualified name as written.
    pub fn attr_named(&self, name: &str) -> Option<&str> {
        self.attrs.iter().find(|a| a.name == name).map(|a| a.value.as_str())
    }

    /// Set attribute `{ns}local`, keeping its position if it exists, or
    /// append it as `name`.
    pub fn set_attr(&mut self, name: &str, ns: Ns, value: impl Into<String>) {
        let value = value.into();
        let local = local_part(name);
        if let Some(attr) = self.attrs.iter_mut().find(|a| a.ns == ns && a.local() == local) {
            attr.value = value;
        } else {
            self.attrs.push(Attr {
                name: name.to_owned(),
                ns,
                value,
            });
        }
    }

    /// Builder form of [`Element::set_attr`].
    pub fn with_attr(mut self, name: &str, ns: Ns, value: impl Into<String>) -> Self {
        self.set_attr(name, ns, value);
        self
    }

    /// Remove attribute `{ns}local`, returning its value.
    pub fn remove_attr(&mut self, ns: Ns, local: &str) -> Option<String> {
        let at = self.attrs.iter().position(|a| a.ns == ns && a.local() == local)?;
        Some(self.attrs.remove(at).value)
    }

    /// Child elements, skipping text and other nodes.
    pub fn elements(&self) -> impl Iterator<Item = &Element> {
        self.children.iter().filter_map(Node::as_element)
    }

    pub fn elements_mut(&mut self) -> impl Iterator<Item = &mut Element> {
        self.children.iter_mut().filter_map(Node::as_element_mut)
    }

    /// The first child element `{ns}local`.
    pub fn child(&self, ns: Ns, local: &str) -> Option<&Element> {
        self.elements().find(|e| e.is(ns, local))
    }

    pub fn child_mut(&mut self, ns: Ns, local: &str) -> Option<&mut Element> {
        self.elements_mut().find(|e| e.is(ns, local))
    }

    /// All child elements `{ns}local`.
    pub fn children_named<'s>(&'s self, ns: Ns, local: &'s str) -> impl Iterator<Item = &'s Element> + 's {
        self.elements().filter(move |e| e.is(ns, local))
    }

    /// Index in `children` of the first child element `{ns}local`.
    pub fn child_index(&self, ns: Ns, local: &str) -> Option<usize> {
        self.children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| e.is(ns, local)))
    }

    /// Descendant elements in document order (not including `self`).
    pub fn descendants(&self) -> Descendants<'_> {
        Descendants {
            stack: vec![self.children.iter()],
        }
    }

    /// All character data inside, concatenated.
    pub fn text(&self) -> String {
        let mut out = String::new();
        self.collect_text(&mut out);
        out
    }

    fn collect_text(&self, out: &mut String) {
        for child in &self.children {
            match child {
                Node::Text(t) | Node::CData(t) => out.push_str(t),
                Node::Element(e) => e.collect_text(out),
                _ => {}
            }
        }
    }

    /// Replace all children with one text node.
    pub fn set_text(&mut self, text: impl Into<String>) {
        self.children.clear();
        let text = text.into();
        if !text.is_empty() {
            self.children.push(Node::Text(text));
        }
    }

    pub fn push(&mut self, element: Element) {
        self.children.push(Node::Element(element));
    }

    /// Serialize this element and its content.
    pub fn to_xml(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    pub(crate) fn write(&self, out: &mut String) {
        // Iterative, so deep trees cannot overflow the stack.
        enum Step<'e> {
            Open(&'e Element),
            Close(&'e Element),
            Other(&'e Node),
        }
        let mut steps = vec![Step::Open(self)];
        while let Some(step) = steps.pop() {
            match step {
                Step::Open(e) => {
                    out.push('<');
                    out.push_str(&e.name);
                    for attr in &e.attrs {
                        out.push(' ');
                        out.push_str(&attr.name);
                        out.push_str("=\"");
                        escape_attr(&attr.value, out);
                        out.push('"');
                    }
                    if e.children.is_empty() {
                        out.push_str("/>");
                        continue;
                    }
                    out.push('>');
                    steps.push(Step::Close(e));
                    for child in e.children.iter().rev() {
                        steps.push(match child {
                            Node::Element(c) => Step::Open(c),
                            other => Step::Other(other),
                        });
                    }
                }
                Step::Close(e) => {
                    out.push_str("</");
                    out.push_str(&e.name);
                    out.push('>');
                }
                Step::Other(node) => node.write(out),
            }
        }
    }
}

/// Iterator returned by [`Element::descendants`].
pub struct Descendants<'a> {
    stack: Vec<std::slice::Iter<'a, Node>>,
}

impl<'a> Iterator for Descendants<'a> {
    type Item = &'a Element;

    fn next(&mut self) -> Option<&'a Element> {
        loop {
            let iter = self.stack.last_mut()?;
            match iter.next() {
                Some(Node::Element(e)) => {
                    self.stack.push(e.children.iter());
                    return Some(e);
                }
                Some(_) => {}
                None => {
                    self.stack.pop();
                }
            }
        }
    }
}

/// A whole document: the declaration, anything around the root, and the
/// root element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    /// The inside of `<?xml ... ?>`, if the document had one.
    pub declaration: Option<String>,
    /// Comments, processing instructions, DOCTYPE and whitespace before the root.
    pub prolog: Vec<Node>,
    pub root: Element,
    /// Anything after the root.
    pub epilog: Vec<Node>,
}

/// The declaration Office writes on every part.
pub const OFFICE_DECLARATION: &str = r#"xml version="1.0" encoding="UTF-8" standalone="yes""#;

impl Document {
    /// A document with the standard declaration followed by a line break, as
    /// Office writes it.
    pub fn new(root: Element) -> Self {
        Self {
            declaration: Some(OFFICE_DECLARATION.to_owned()),
            prolog: vec![Node::Text("\r\n".to_owned())],
            root,
            epilog: Vec::new(),
        }
    }

    /// Parse a part's bytes, honouring a byte-order mark or declared encoding.
    pub fn parse(bytes: &[u8]) -> Result<Self, XmlError> {
        let (text, _) = decode_bytes(bytes);
        Self::parse_str(&text)
    }

    pub fn parse_str(text: &str) -> Result<Self, XmlError> {
        let mut reader = Reader::new(text);
        let mut declaration = None;
        let mut prolog = Vec::new();
        let mut epilog = Vec::new();
        let mut root: Option<Element> = None;
        // Open elements, and the namespace bindings each one introduced.
        let mut open: Vec<Element> = Vec::new();
        let mut scopes: Vec<Vec<(String, Ns)>> = Vec::new();

        loop {
            let before = reader.offset();
            let event = reader.next()?;
            let node = match event {
                Event::Eof => break,
                Event::Declaration(d) => {
                    declaration = Some(d.trim_end().to_owned());
                    continue;
                }
                Event::Start(tag) => {
                    let mut bindings = Vec::new();
                    let mut raw = Vec::new();
                    for attr in tag.attrs() {
                        let (name, value) = attr?;
                        if name == "xmlns" {
                            bindings.push((String::new(), Ns::from_uri(&value)));
                        } else if let Some(prefix) = name.strip_prefix("xmlns:") {
                            bindings.push((prefix.to_owned(), Ns::from_uri(&value)));
                        }
                        raw.push((name, value.into_owned()));
                    }
                    scopes.push(bindings);
                    let resolve = |prefix: &str| -> Ns {
                        match prefix {
                            "xml" => return ns::XML,
                            "xmlns" => return ns::XMLNS,
                            _ => {}
                        }
                        for scope in scopes.iter().rev() {
                            if let Some((_, ns)) = scope.iter().rev().find(|(p, _)| p == prefix) {
                                return *ns;
                            }
                        }
                        if prefix.is_empty() {
                            ns::NONE
                        } else {
                            Ns::from_uri(&format!("urn:undeclared-prefix:{prefix}"))
                        }
                    };
                    let element_ns = resolve(tag.name.rsplit_once(':').map_or("", |(p, _)| p));
                    let attrs = raw
                        .into_iter()
                        .map(|(name, value)| {
                            let ns = if name == "xmlns" {
                                ns::XMLNS
                            } else {
                                match name.rsplit_once(':') {
                                    Some((prefix, _)) => resolve(prefix),
                                    None => ns::NONE,
                                }
                            };
                            Attr {
                                name: name.to_owned(),
                                ns,
                                value,
                            }
                        })
                        .collect();
                    open.push(Element {
                        name: tag.name.to_owned(),
                        ns: element_ns,
                        attrs,
                        children: Vec::new(),
                    });
                    continue;
                }
                Event::End(_) => {
                    scopes.pop();
                    let element = open.pop().expect("reader checks nesting");
                    match open.last_mut() {
                        Some(parent) => parent.children.push(Node::Element(element)),
                        None => root = Some(element),
                    }
                    continue;
                }
                // Whitespace around the root is kept byte for byte: line
                // ends there are not character data, and cannot be escaped.
                Event::Text(_) if open.is_empty() => Node::Text(reader.source()[before..reader.offset()].to_owned()),
                Event::Text(t) => Node::Text(t.into_owned()),
                Event::CData(t) => Node::CData(t.to_owned()),
                Event::Comment(t) => Node::Comment(t.to_owned()),
                Event::Pi(t) => Node::Pi(t.to_owned()),
                Event::DocType(t) => Node::DocType(t.to_owned()),
            };
            match open.last_mut() {
                Some(parent) => parent.children.push(node),
                None if root.is_none() => prolog.push(node),
                None => epilog.push(node),
            }
        }
        let root = root.ok_or_else(|| XmlError::new(text.len(), "no root element"))?;
        Ok(Self {
            declaration,
            prolog,
            root,
            epilog,
        })
    }

    /// The prefix the root element binds to `ns` (`Some("")` for a default
    /// namespace). Use it to name elements added to this document.
    pub fn prefix_for(&self, ns: Ns) -> Option<String> {
        if self.root.ns == ns && !self.root.name.contains(':') {
            return Some(String::new());
        }
        self.root.attrs.iter().find_map(|a| {
            if a.ns != ns::XMLNS || Ns::from_uri(&a.value) != ns {
                return None;
            }
            Some(a.name.strip_prefix("xmlns:").unwrap_or("").to_owned())
        })
    }

    /// Serialize as UTF-8 text.
    pub fn to_xml(&self) -> String {
        let mut out = String::new();
        if let Some(declaration) = &self.declaration {
            out.push_str("<?");
            out.push_str(&utf8_declaration(declaration));
            out.push_str("?>");
        }
        let outside = |node: &Node, out: &mut String| match node {
            Node::Text(t) if t.trim().is_empty() => out.push_str(t),
            other => other.write(out),
        };
        for node in &self.prolog {
            outside(node, &mut out);
        }
        self.root.write(&mut out);
        for node in &self.epilog {
            outside(node, &mut out);
        }
        out
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        self.to_xml().into_bytes()
    }
}

/// The declaration with its `encoding` changed to UTF-8, which is what the
/// serializer writes.
fn utf8_declaration(declaration: &str) -> String {
    let Some(at) = declaration.find("encoding") else {
        return declaration.to_owned();
    };
    let rest = &declaration[at + 8..];
    let Some(eq) = rest.find('=') else {
        return declaration.to_owned();
    };
    let value = rest[eq + 1..].trim_start();
    let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') else {
        return declaration.to_owned();
    };
    let Some(len) = value[1..].find(quote) else {
        return declaration.to_owned();
    };
    let current = &value[1..1 + len];
    if current.eq_ignore_ascii_case("utf-8") {
        return declaration.to_owned();
    }
    let value_at = declaration.len() - value.len();
    format!(
        "{}{quote}UTF-8{quote}{}",
        &declaration[..value_at],
        &declaration[value_at + len + 2..]
    )
}
