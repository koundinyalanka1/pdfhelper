//! OpenDocument paragraphs (`text:p`, `text:h`): what they show, and
//! writing an edited one back with spans of automatic text styles.

use doc_xml::{ns, Element, Node as XmlNode};

use super::styles::{length_pt, OdfStyles};
use crate::projected::{pieces, push_text, utf16_len, Objects, Piece, Projected, RebuildInput, StoredObject};
use crate::view::{Inline, InlineEdit, ObjectKind, ObjectView, ParaView, RunStyle};

/// Prefixes of the namespaces paragraphs are written with.
#[derive(Clone, Debug)]
pub struct Prefixes {
    pub text: String,
    pub style: String,
    pub fo: String,
    pub xlink: String,
    pub draw: String,
    pub svg: String,
    pub table: String,
    pub office: String,
}

impl Default for Prefixes {
    fn default() -> Self {
        Prefixes {
            text: "text".into(),
            style: "style".into(),
            fo: "fo".into(),
            xlink: "xlink".into(),
            draw: "draw".into(),
            svg: "svg".into(),
            table: "table".into(),
            office: "office".into(),
        }
    }
}

pub fn q(prefix: &str, local: &str) -> String {
    if prefix.is_empty() {
        local.to_owned()
    } else {
        format!("{prefix}:{local}")
    }
}

fn is(e: &Element, n: doc_xml::ns::Ns, local: &str) -> bool {
    e.ns == n && e.local() == local
}

enum AtomKind {
    Text(String),
    Object(ObjectKind, String),
    Marker,
}

struct Atom {
    kind: AtomKind,
    el: XmlNode,
    /// The span styles around it, outermost first.
    spans: Vec<String>,
    /// The span elements around it (no children), for reusing them.
    span_head: Option<Element>,
    link: Option<usize>,
}

struct Walk {
    atoms: Vec<Atom>,
    links: Vec<(String, Element)>,
    lock: Option<String>,
    /// Whether the last character was white space (ODF collapses runs of
    /// it), or nothing has been seen yet.
    last_space: bool,
}

/// Elements that show a computed value: their current text is what shows.
const FIELDS: &[&str] = &[
    "page-number",
    "page-count",
    "page-continuation",
    "date",
    "time",
    "title",
    "subject",
    "description",
    "keywords",
    "initial-creator",
    "creator",
    "creation-date",
    "creation-time",
    "author-name",
    "author-initials",
    "file-name",
    "template-name",
    "chapter",
    "sequence",
    "sequence-ref",
    "bookmark-ref",
    "reference-ref",
    "note-ref",
    "variable-get",
    "variable-set",
    "variable-input",
    "user-field-get",
    "user-field-input",
    "user-defined",
    "expression",
    "text-input",
    "database-display",
    "conditional-text",
    "hidden-text",
    "word-count",
    "character-count",
    "paragraph-count",
    "sender-firstname",
    "sender-lastname",
    "sender-company",
    "printed-by",
    "print-date",
    "editing-duration",
    "editing-cycles",
    "modification-date",
    "modification-time",
    "dde-connection",
    "placeholder",
    "drop-down",
];

impl Walk {
    fn lock(&mut self, why: &str) {
        if self.lock.is_none() {
            self.lock = Some(why.to_owned());
        }
    }

    fn push_text(&mut self, s: &str, spans: &[String], head: &Option<Element>, link: Option<usize>) {
        if s.is_empty() {
            return;
        }
        if let Some(Atom {
            kind: AtomKind::Text(t),
            spans: sp,
            link: l,
            ..
        }) = self.atoms.last_mut()
        {
            if sp == spans && *l == link {
                t.push_str(s);
                return;
            }
        }
        self.atoms.push(Atom {
            kind: AtomKind::Text(s.to_owned()),
            el: XmlNode::Text(String::new()),
            spans: spans.to_vec(),
            span_head: head.clone(),
            link,
        });
    }

    fn walk(&mut self, children: &[XmlNode], spans: &[String], head: &Option<Element>, link: Option<usize>) {
        for n in children {
            match n {
                XmlNode::Text(t) | XmlNode::CData(t) => {
                    let mut out = String::new();
                    for c in t.chars() {
                        if matches!(c, ' ' | '\t' | '\n' | '\r') {
                            if !self.last_space {
                                out.push(' ');
                                self.last_space = true;
                            }
                        } else {
                            out.push(c);
                            self.last_space = false;
                        }
                    }
                    self.push_text(&out, spans, head, link);
                }
                XmlNode::Element(e) => self.element(n, e, spans, head, link),
                _ => self.atoms.push(Atom {
                    kind: AtomKind::Marker,
                    el: n.clone(),
                    spans: spans.to_vec(),
                    span_head: head.clone(),
                    link,
                }),
            }
        }
    }

    fn element(&mut self, n: &XmlNode, e: &Element, spans: &[String], head: &Option<Element>, link: Option<usize>) {
        let object = |w: &mut Walk, kind: ObjectKind, text: String| {
            w.last_space = false;
            w.atoms.push(Atom {
                kind: AtomKind::Object(kind, text),
                el: n.clone(),
                spans: spans.to_vec(),
                span_head: head.clone(),
                link,
            })
        };
        let marker = |w: &mut Walk| {
            w.atoms.push(Atom {
                kind: AtomKind::Marker,
                el: n.clone(),
                spans: spans.to_vec(),
                span_head: head.clone(),
                link,
            })
        };
        if e.ns == ns::TEXT {
            match e.local() {
                "span" => {
                    let mut inner = spans.to_vec();
                    if let Some(s) = e.attr(ns::TEXT, "style-name") {
                        inner.push(s.to_owned());
                    }
                    let mut h = e.clone();
                    h.children.clear();
                    // Moved content keeps the outermost span.
                    let h = if spans.is_empty() { Some(h) } else { head.clone() };
                    self.walk(&e.children, &inner, &h, link);
                }
                "a" => {
                    let target = e.attr(ns::XLINK, "href").unwrap_or_default().to_owned();
                    let mut h = e.clone();
                    h.children.clear();
                    self.links.push((target, h));
                    let idx = self.links.len() - 1;
                    self.walk(&e.children, spans, head, Some(idx));
                }
                "s" => {
                    let c = e.attr(ns::TEXT, "c").and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).min(10_000);
                    self.push_text(&" ".repeat(c), spans, head, link);
                    self.last_space = true;
                }
                "tab" => {
                    self.push_text("\t", spans, head, link);
                    self.last_space = true;
                }
                "line-break" => {
                    self.push_text("\n", spans, head, link);
                    self.last_space = true;
                }
                "meta" | "meta-field" => self.walk(&e.children, spans, head, link),
                "change" | "change-start" | "change-end" => {
                    self.lock("This paragraph has tracked changes.");
                    marker(self);
                }
                "note" => {
                    let citation = e
                        .elements()
                        .find(|c| is(c, ns::TEXT, "note-citation"))
                        .map(|c| c.text())
                        .unwrap_or_else(|| "*".into());
                    object(self, ObjectKind::Note, citation);
                }
                "ruby" => object(self, ObjectKind::Other, e.text()),
                local if FIELDS.contains(&local) => object(self, ObjectKind::Field, e.text()),
                _ => {
                    let t = e.text();
                    if t.is_empty() {
                        marker(self)
                    } else {
                        object(self, ObjectKind::Other, t)
                    }
                }
            }
            return;
        }
        if e.ns == ns::DRAW {
            let kind = if e.local() == "frame" && e.elements().any(|c| is(c, ns::DRAW, "image")) {
                ObjectKind::Image
            } else {
                ObjectKind::Shape
            };
            object(self, kind, String::new());
            return;
        }
        if e.ns == ns::OFFICE && matches!(e.local(), "annotation" | "annotation-end") {
            marker(self);
            return;
        }
        if e.ns == ns::MATHML {
            object(self, ObjectKind::Equation, e.text());
            return;
        }
        let t = e.text();
        if t.is_empty() {
            marker(self)
        } else {
            object(self, ObjectKind::Other, t)
        }
    }
}

/// Size of a frame, in points.
fn frame_size(e: &Element) -> (f32, f32) {
    let get = |a: &str| e.attr(ns::SVG, a).and_then(length_pt).unwrap_or(0.0);
    (get("width"), get("height"))
}

/// The package path of an image object's picture.
pub fn image_href(nodes: &[XmlNode]) -> Option<String> {
    for n in nodes {
        let XmlNode::Element(e) = n else { continue };
        for d in std::iter::once(e).chain(e.descendants()) {
            if is(d, ns::DRAW, "image") {
                if let Some(h) = d.attr(ns::XLINK, "href") {
                    return Some(h.trim_start_matches("./").to_owned());
                }
            }
        }
    }
    None
}

/// The run formatting of a paragraph's text outside spans.
pub fn base_run(styles: &OdfStyles, p: &Element) -> RunStyle {
    styles.para_style(p.attr(ns::TEXT, "style-name"), None).mark
}

/// Read a paragraph into its view.
pub fn project(p: &Element, id: u32, styles: &OdfStyles, objects: &mut Objects) -> Projected {
    let outline = if p.local() == "h" {
        Some(p.attr(ns::TEXT, "outline-level").and_then(|v| v.parse::<u8>().ok()).unwrap_or(1))
    } else {
        None
    };
    let style = styles.para_style(p.attr(ns::TEXT, "style-name"), outline);
    let mut walk = Walk {
        atoms: Vec::new(),
        links: Vec::new(),
        lock: None,
        last_space: true,
    };
    walk.walk(&p.children, &[], &None, None);
    let Walk { atoms, links, lock, .. } = walk;

    let mut out = Projected {
        links: links.clone(),
        ..Projected::default()
    };
    let mut inlines = Vec::new();
    let mut pos = 0usize;
    for a in &atoms {
        let run = styles.run_style(&style.mark, &a.spans);
        let target = a.link.map(|l| links[l].0.clone());
        match &a.kind {
            AtomKind::Text(t) => {
                // A template: the span element that gives this look (one
                // span deep), or none for plain paragraph text.
                if a.spans.len() <= 1 {
                    let head = if a.spans.is_empty() { None } else { a.span_head.clone() };
                    if !out.templates.iter().any(|(s, h)| *s == run && *h == head) {
                        out.templates.push((run.clone(), head));
                    }
                }
                push_text(&mut inlines, t, &run, target.as_deref());
                pos += utf16_len(t);
            }
            AtomKind::Marker => out.markers.push((pos, wrap_spans(&a.el, a.span_head.as_ref(), &a.spans))),
            AtomKind::Object(kind, text) => {
                let (width, height) = a.el.as_element().map_or((0.0, 0.0), frame_size);
                let alt = a
                    .el
                    .as_element()
                    .and_then(|e| e.descendants().find(|d| is(d, ns::SVG, "title") || is(d, ns::SVG, "desc")))
                    .map(|d| d.text())
                    .unwrap_or_default();
                let view = ObjectView {
                    id: 0,
                    kind: *kind,
                    text: text.clone(),
                    width,
                    height,
                    alt,
                    style: run.clone(),
                };
                let oid = objects.add(StoredObject {
                    nodes: vec![wrap_spans(&a.el, a.span_head.as_ref(), &a.spans)],
                    link: a.link.map(|l| links[l].clone()),
                    view,
                });
                out.object_ids.push(oid);
                pos += utf16_len(text);
                inlines.push(Inline::Object(objects.get(oid).unwrap().view.clone()));
            }
        }
    }
    out.view = Some(ParaView {
        id,
        style,
        list: None,
        inlines,
        editable: lock.is_none(),
        locked_reason: lock,
    });
    out
}

/// A node inside spans keeps its formatting when moved: wrap it in the
/// outermost span (a field's text style matters).
fn wrap_spans(n: &XmlNode, head: Option<&Element>, spans: &[String]) -> XmlNode {
    match (head, spans.len()) {
        (Some(h), 1) => {
            let mut s = h.clone();
            s.children = vec![n.clone()];
            XmlNode::Element(s)
        }
        _ => n.clone(),
    }
}

/// What writing an edited paragraph needs from the document.
pub struct WriteCtx<'a> {
    pub styles: &'a OdfStyles,
    pub p: &'a Prefixes,
    /// The automatic text style giving `props`; made when there is none.
    pub text_style: &'a mut dyn FnMut(&[(&'static str, String)]) -> String,
    /// The font face to name for a family (declared when missing).
    pub font_face: &'a mut dyn FnMut(&str) -> String,
}

/// Paragraph content for text: spaces as ODF wants them (runs of spaces
/// as `text:s`), tabs and line breaks.
fn text_nodes(text: &str, prev_space: &mut bool, p: &Prefixes) -> Vec<XmlNode> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut spaces = 0usize;
    let flush_spaces = |spaces: &mut usize, out: &mut Vec<XmlNode>| {
        if *spaces > 0 {
            let mut s = Element::new(q(&p.text, "s"), ns::TEXT);
            if *spaces > 1 {
                s.set_attr(&q(&p.text, "c"), ns::TEXT, spaces.to_string());
            }
            out.push(XmlNode::Element(s));
            *spaces = 0;
        }
    };
    let flush_text = |buf: &mut String, out: &mut Vec<XmlNode>| {
        if !buf.is_empty() {
            out.push(XmlNode::Text(std::mem::take(buf)));
        }
    };
    for c in text.chars() {
        match c {
            ' ' => {
                if *prev_space {
                    flush_text(&mut buf, &mut out);
                    spaces += 1;
                } else {
                    flush_spaces(&mut spaces, &mut out);
                    buf.push(' ');
                    *prev_space = true;
                }
            }
            '\t' | '\n' | '\u{2028}' | '\r' => {
                flush_text(&mut buf, &mut out);
                flush_spaces(&mut spaces, &mut out);
                let local = if c == '\t' { "tab" } else { "line-break" };
                out.push(XmlNode::Element(Element::new(q(&p.text, local), ns::TEXT)));
                *prev_space = true;
            }
            _ => {
                flush_spaces(&mut spaces, &mut out);
                buf.push(c);
                *prev_space = false;
            }
        }
    }
    flush_text(&mut buf, &mut out);
    flush_spaces(&mut spaces, &mut out);
    out
}

/// The span to put text that should look like `want` in (None for plain
/// paragraph text).
fn span_for(want: &RunStyle, base: &RunStyle, input: &RebuildInput, ctx: &mut WriteCtx) -> Option<Element> {
    if want == base {
        return None;
    }
    if let Some((_, head)) = input.templates.iter().find(|(s, h)| s == want && h.is_some()) {
        return head.clone();
    }
    let face = if want.font != base.font && !want.font.is_empty() {
        Some((ctx.font_face)(&want.font))
    } else {
        None
    };
    let props = super::styles::text_props(base, want, face.as_deref());
    if props.is_empty() {
        return None;
    }
    let name = (ctx.text_style)(&props);
    let mut span = Element::new(q(&ctx.p.text, "span"), ns::TEXT);
    span.set_attr(&q(&ctx.p.text, "style-name"), ns::TEXT, name);
    Some(span)
}

/// Write an edited paragraph: the original element with new content.
pub fn rebuild(p: &Element, input: &RebuildInput, inlines: &[InlineEdit], objects: &Objects, ctx: &mut WriteCtx) -> Element {
    let base = base_run(ctx.styles, p);
    let mut out = p.clone();
    out.children.clear();
    let mut prev_space = true;
    // (link target, link head, nodes)
    let mut seq: Vec<(Option<String>, Option<Element>, Vec<XmlNode>)> = Vec::new();
    for piece in pieces(inlines, &input.markers, objects) {
        match piece {
            Piece::Text { text, style, link } => {
                let nodes = text_nodes(&text, &mut prev_space, ctx.p);
                let nodes = match span_for(&style, &base, input, ctx) {
                    Some(mut span) => {
                        span.children = nodes;
                        vec![XmlNode::Element(span)]
                    }
                    None => nodes,
                };
                seq.push((link.filter(|l| !l.is_empty()), None, nodes));
            }
            Piece::Object { id } => {
                let o = objects.get(id).expect("pieces only lists known objects");
                prev_space = false;
                let (t, h) = match &o.link {
                    Some((t, h)) => (Some(t.clone()), Some(h.clone())),
                    None => (None, None),
                };
                seq.push((t, h, o.nodes.clone()));
            }
            Piece::Marker(n) => {
                let link = seq.last().and_then(|(l, _, _)| l.clone());
                seq.push((link, None, vec![n]));
            }
        }
    }
    let mut i = 0;
    while i < seq.len() {
        let Some(target) = seq[i].0.clone() else {
            out.children.extend(std::mem::take(&mut seq[i].2));
            i += 1;
            continue;
        };
        let mut j = i;
        let mut known = None;
        let mut kids = Vec::new();
        while j < seq.len() && seq[j].0.as_deref() == Some(target.as_str()) {
            if known.is_none() {
                known = seq[j].1.clone();
            }
            kids.extend(std::mem::take(&mut seq[j].2));
            j += 1;
        }
        let mut a = match input.link_head(&target).cloned().or(known) {
            Some(h) => h,
            None => {
                let mut a = Element::new(q(&ctx.p.text, "a"), ns::TEXT);
                a.set_attr(&q(&ctx.p.xlink, "type"), ns::XLINK, "simple");
                a.set_attr(&q(&ctx.p.xlink, "href"), ns::XLINK, target.clone());
                a
            }
        };
        a.children = kids;
        out.push(a);
        i = j;
    }
    out
}

/// The text of a paragraph element as ODF shows it (for tests and plain
/// text).
pub fn plain(p: &Element) -> String {
    let mut objects = Objects::default();
    let styles = OdfStyles::default();
    project(p, 0, &styles, &mut objects).view().text()
}

#[cfg(test)]
mod tests {
    use super::*;
    use doc_xml::Document;

    const NS: &str = r#"xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:xlink="http://www.w3.org/1999/xlink""#;

    fn para(xml: &str) -> Element {
        let doc = Document::parse_str(&format!("<r {NS}>{xml}</r>")).unwrap();
        let e = doc.root.elements().next().unwrap().clone();
        e
    }

    #[test]
    fn white_space_collapses_as_odf_says() {
        let p = para("<text:p>  Hello \n  world<text:s text:c=\"2\"/>x<text:tab/>y<text:line-break/>z</text:p>");
        assert_eq!(plain(&p), "Hello world  x\ty\nz");
    }

    #[test]
    fn spaces_are_written_back_as_odf_wants() {
        let mut prev = true;
        let nodes = text_nodes(" a  b\tc", &mut prev, &Prefixes::default());
        let mut e = Element::new("text:p", ns::TEXT);
        e.set_attr("xmlns:text", ns::XMLNS, ns::TEXT.uri());
        e.children = nodes;
        assert_eq!(e.to_xml(), r#"<text:p xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><text:s/>a <text:s/>b<text:tab/>c</text:p>"#);
        assert_eq!(plain(&e), " a  b\tc");
    }
}
