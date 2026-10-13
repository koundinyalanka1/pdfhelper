//! Word paragraphs (`w:p`): what they show, and writing an edited one back.
//!
//! A paragraph is read into atoms (each piece of text or other content of
//! a run, each paragraph-level element), atoms become the view's inlines,
//! and an edit's inlines become new runs that reuse the original run
//! properties, objects and invisible markers.

use std::collections::HashMap;

use doc_xml::{ns, Element, Node as XmlNode};

use super::styles::{put_ordered, remove_child, wel, write_rpr, wval, StyleSheet, PPR_ORDER};
use crate::projected::{
    pieces, push_text, utf16_len, Objects, Piece, Projected, RebuildInput, StoredObject,
};
use crate::view::{
    Align, InlineEdit, LineSpacing, ObjectKind, ObjectView, ParaPatch, ParaView, RunStyle,
};

/// What reading a paragraph needs from its document.
pub struct ReadCtx<'a> {
    pub styles: &'a StyleSheet,
    /// Hyperlink relationship ids and their targets.
    pub links: &'a HashMap<String, String>,
}

enum AtomKind {
    /// Text of a run (`w:t`, a tab, a line break...).
    Text(String),
    /// Anything else inside a run: drawings, breaks, field characters.
    RunChild,
    /// A paragraph-level element shown as one object.
    Block(ObjectKind, String),
    /// A paragraph-level element that does not show.
    Marker,
}

struct Atom {
    kind: AtomKind,
    /// The run child, or the paragraph-level element.
    el: XmlNode,
    rpr: Option<Element>,
    link: Option<usize>,
}

struct Walk<'a> {
    atoms: Vec<Atom>,
    links: Vec<(String, Element)>,
    lock: Option<String>,
    ctx: &'a ReadCtx<'a>,
}

fn is_w(e: &Element, local: &str) -> bool {
    e.ns == ns::W && e.local() == local
}

fn head(e: &Element) -> Element {
    let mut h = e.clone();
    h.children.clear();
    h
}

/// Text of an element as Word shows it (`w:t`, tabs and breaks; not
/// deleted text or field instructions).
pub fn shown_text(e: &Element) -> String {
    let mut s = String::new();
    fn walk(e: &Element, s: &mut String) {
        for c in &e.children {
            match c {
                XmlNode::Element(c) if c.ns == ns::W => match c.local() {
                    "t" => s.push_str(&c.text()),
                    "tab" | "ptab" => s.push('\t'),
                    "br" | "cr" => s.push('\n'),
                    "noBreakHyphen" => s.push('\u{2011}'),
                    "delText" | "instrText" | "rPr" | "pPr" | "sdtPr" | "del" | "moveFrom" => {}
                    "p" => {
                        if !s.is_empty() && !s.ends_with('\n') {
                            s.push('\n');
                        }
                        walk(c, s);
                    }
                    _ => walk(c, s),
                },
                XmlNode::Element(c) if c.ns == ns::M && c.local() == "t" => s.push_str(&c.text()),
                XmlNode::Element(c) => walk(c, s),
                _ => {}
            }
        }
    }
    walk(e, &mut s);
    s
}

impl<'a> Walk<'a> {
    fn lock(&mut self, why: &str) {
        if self.lock.is_none() {
            self.lock = Some(why.to_owned());
        }
    }

    fn walk(&mut self, children: &[XmlNode], link: Option<usize>) {
        for n in children {
            let e = match n {
                XmlNode::Element(e) => e,
                XmlNode::Comment(_) | XmlNode::Pi(_) => {
                    self.atoms.push(Atom {
                        kind: AtomKind::Marker,
                        el: n.clone(),
                        rpr: None,
                        link,
                    });
                    continue;
                }
                _ => continue,
            };
            let marker = |w: &mut Walk| {
                w.atoms.push(Atom {
                    kind: AtomKind::Marker,
                    el: n.clone(),
                    rpr: None,
                    link,
                })
            };
            let block = |w: &mut Walk, kind: ObjectKind, text: String| {
                w.atoms.push(Atom {
                    kind: AtomKind::Block(kind, text),
                    el: n.clone(),
                    rpr: None,
                    link,
                })
            };
            if e.ns == ns::M {
                block(self, ObjectKind::Equation, math_text(e));
                continue;
            }
            if e.ns != ns::W {
                let text = shown_text(e);
                if text.is_empty() {
                    marker(self);
                } else {
                    block(self, ObjectKind::Other, text);
                }
                continue;
            }
            match e.local() {
                "pPr" | "proofErr" | "smartTagPr" | "customXmlPr" => {}
                "r" => self.run(e, link),
                "hyperlink" => {
                    let target = if let Some(id) = e.attr(ns::R, "id") {
                        let url = self.ctx.links.get(id).cloned().unwrap_or_default();
                        match e.attr(ns::W, "anchor") {
                            Some(a) if url.is_empty() => format!("#{a}"),
                            _ => url,
                        }
                    } else if let Some(a) = e.attr(ns::W, "anchor") {
                        format!("#{a}")
                    } else {
                        String::new()
                    };
                    self.links.push((target, head(e)));
                    let idx = self.links.len() - 1;
                    self.walk(&e.children, Some(idx));
                }
                "smartTag" | "customXml" | "dir" | "bdo" => self.walk(&e.children, link),
                "ins" | "moveTo" => {
                    self.lock("This paragraph has tracked changes.");
                    self.walk(&e.children, link);
                }
                "del" | "moveFrom" => self.lock("This paragraph has tracked changes."),
                "fldSimple" => block(self, ObjectKind::Field, shown_text(e)),
                "sdt" => {
                    let text = e
                        .elements()
                        .find(|c| is_w(c, "sdtContent"))
                        .map(shown_text)
                        .unwrap_or_default();
                    block(self, ObjectKind::Control, text);
                }
                "subDoc" | "ruby" => block(self, ObjectKind::Other, shown_text(e)),
                _ => {
                    let text = shown_text(e);
                    if text.is_empty() {
                        marker(self);
                    } else {
                        block(self, ObjectKind::Other, text);
                    }
                }
            }
        }
    }

    fn run(&mut self, r: &Element, link: Option<usize>) {
        let rpr = r.elements().find(|c| is_w(c, "rPr")).cloned();
        if rpr
            .as_ref()
            .is_some_and(|p| p.elements().any(|c| is_w(c, "rPrChange")))
        {
            self.lock("This paragraph has tracked formatting changes.");
        }
        for c in &r.children {
            let XmlNode::Element(e) = c else { continue };
            let text = |s: &str| AtomKind::Text(s.to_owned());
            let kind = if e.ns == ns::W {
                match e.local() {
                    "rPr" | "lastRenderedPageBreak" => continue,
                    "t" => AtomKind::Text(e.text()),
                    "tab" => text("\t"),
                    "cr" => text("\n"),
                    "br" => match e.attr(ns::W, "type") {
                        Some("page") | Some("column") => AtomKind::RunChild,
                        _ => text("\n"),
                    },
                    "noBreakHyphen" => text("\u{2011}"),
                    "softHyphen" => text("\u{AD}"),
                    "delText" | "delInstrText" => {
                        self.lock("This paragraph has tracked changes.");
                        continue;
                    }
                    _ => AtomKind::RunChild,
                }
            } else {
                AtomKind::RunChild
            };
            self.atoms.push(Atom {
                kind,
                el: c.clone(),
                rpr: rpr.clone(),
                link,
            });
        }
    }
}

fn math_text(e: &Element) -> String {
    e.descendants()
        .filter(|c| c.ns == ns::M && c.local() == "t")
        .map(|c| c.text())
        .collect()
}

/// A run holding one child (or several), with properties.
fn make_run(w: &str, rpr: Option<&Element>, children: Vec<XmlNode>) -> Element {
    let mut r = Element::new(q(w, "r"), ns::W);
    if let Some(p) = rpr.filter(|p| !p.children.is_empty()) {
        r.push(p.clone());
    }
    r.children.extend(children);
    r
}

fn q(w: &str, local: &str) -> String {
    if w.is_empty() {
        local.to_owned()
    } else {
        format!("{w}:{local}")
    }
}

const EMU_PER_PT: f32 = 12700.0;

/// Size of a drawing (`wp:extent`), in points.
fn drawing_size(e: &Element) -> (f32, f32) {
    if let Some(ext) = e
        .descendants()
        .find(|d| d.ns == ns::WP && d.local() == "extent")
    {
        let get = |a: &str| {
            ext.attr(ns::NONE, a)
                .and_then(|v| v.parse::<f32>().ok())
                .unwrap_or(0.0)
                / EMU_PER_PT
        };
        return (get("cx"), get("cy"));
    }
    // VML: style="width:120pt;height:40pt".
    if let Some(shape) = e
        .descendants()
        .find(|d| d.ns == ns::V && d.attr(ns::NONE, "style").is_some())
    {
        let style = shape.attr(ns::NONE, "style").unwrap_or_default();
        let mut w = 0.0;
        let mut h = 0.0;
        for part in style.split(';') {
            let Some((k, v)) = part.split_once(':') else {
                continue;
            };
            let v = css_length(v.trim());
            match k.trim() {
                "width" => w = v,
                "height" => h = v,
                _ => {}
            }
        }
        return (w, h);
    }
    (0.0, 0.0)
}

/// A CSS length in points.
pub fn css_length(v: &str) -> f32 {
    let num: String = v
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    let n = num.parse::<f32>().unwrap_or(0.0);
    match v[num.len()..].trim() {
        "in" => n * 72.0,
        "cm" => n * 72.0 / 2.54,
        "mm" => n * 72.0 / 25.4,
        "px" => n * 0.75,
        "pc" => n * 12.0,
        "emu" => n / EMU_PER_PT,
        _ => n,
    }
}

/// The kind of a drawing, and its description.
fn drawing_kind(e: &Element) -> (ObjectKind, String) {
    let mut kind = ObjectKind::Shape;
    let mut alt = String::new();
    for d in e.descendants() {
        match (d.ns, d.local()) {
            (n, "docPr") if n == ns::WP => {
                alt = d
                    .attr(ns::NONE, "descr")
                    .or_else(|| d.attr(ns::NONE, "title"))
                    .unwrap_or_default()
                    .to_owned();
            }
            (n, "pic") if n == ns::PIC => kind = ObjectKind::Image,
            (n, "imagedata") if n == ns::V => kind = ObjectKind::Image,
            (n, "blip") if n == ns::A && kind == ObjectKind::Shape => kind = ObjectKind::Image,
            _ => {}
        }
    }
    (kind, alt)
}

/// The image part relationship id of an image object, if it is one.
pub fn image_rel_id(nodes: &[XmlNode]) -> Option<String> {
    for n in nodes {
        let XmlNode::Element(e) = n else { continue };
        for d in std::iter::once(e).chain(e.descendants()) {
            if d.ns == ns::A && d.local() == "blip" {
                if let Some(id) = d.attr(ns::R, "embed") {
                    return Some(id.to_owned());
                }
            }
            if d.ns == ns::V && d.local() == "imagedata" {
                if let Some(id) = d.attr(ns::R, "id") {
                    return Some(id.to_owned());
                }
            }
        }
    }
    None
}

/// Read a paragraph into its view.
pub fn project(p: &Element, id: u32, ctx: &ReadCtx, objects: &mut Objects, w: &str) -> Projected {
    let ppr = p.elements().find(|c| is_w(c, "pPr"));
    let style = ctx.styles.para_style(ppr);
    let style_id = (!style.style_id.is_empty()).then(|| style.style_id.clone());
    let mut walk = Walk {
        atoms: Vec::new(),
        links: Vec::new(),
        lock: None,
        ctx,
    };
    walk.walk(&p.children, None);
    let Walk {
        atoms,
        links,
        mut lock,
        ..
    } = walk;

    let run_style = |rpr: Option<&Element>| ctx.styles.run_style(style_id.as_deref(), rpr);
    let link_target = |l: Option<usize>| l.map(|i| links[i].0.clone());
    let mut out = Projected {
        links: links.clone(),
        ..Projected::default()
    };
    let mut inlines = Vec::new();
    let mut pos = 0usize;
    let mut i = 0;
    while i < atoms.len() {
        let a = &atoms[i];
        match &a.kind {
            AtomKind::Text(t) => {
                let s = run_style(a.rpr.as_ref());
                if !out.templates.iter().any(|(x, r)| *x == s && *r == a.rpr) {
                    out.templates.push((s.clone(), a.rpr.clone()));
                }
                push_text(&mut inlines, t, &s, link_target(a.link).as_deref());
                pos += utf16_len(t);
                i += 1;
            }
            AtomKind::Marker => {
                out.markers.push((pos, a.el.clone()));
                i += 1;
            }
            AtomKind::Block(kind, text) => {
                let (width, height) = a.el.as_element().map_or((0.0, 0.0), drawing_size);
                let view = ObjectView {
                    id: 0,
                    kind: *kind,
                    text: text.clone(),
                    width,
                    height,
                    alt: String::new(),
                    style: style.mark.clone(),
                };
                let oid = objects.add(StoredObject {
                    nodes: vec![a.el.clone()],
                    link: a.link.map(|l| links[l].clone()),
                    view: view.clone(),
                });
                out.object_ids.push(oid);
                pos += utf16_len(text);
                inlines.push(crate::view::Inline::Object(
                    objects.get(oid).unwrap().view.clone(),
                ));
                i += 1;
            }
            AtomKind::RunChild => {
                let el = a.el.as_element().unwrap();
                let s = run_style(a.rpr.as_ref());
                // A complex field: everything from its begin to its end is
                // one object showing its result.
                if is_w(el, "fldChar") && el.attr(ns::W, "fldCharType") == Some("begin") {
                    let mut depth = 0;
                    let mut end = None;
                    for (k, b) in atoms.iter().enumerate().skip(i) {
                        if let (AtomKind::RunChild, Some(x)) = (&b.kind, b.el.as_element()) {
                            if is_w(x, "fldChar") {
                                match x.attr(ns::W, "fldCharType") {
                                    Some("begin") => depth += 1,
                                    Some("end") => {
                                        depth -= 1;
                                        if depth == 0 {
                                            end = Some(k);
                                            break;
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    if let Some(end) = end {
                        let group = &atoms[i..=end];
                        let mut result = String::new();
                        let mut in_result = false;
                        let mut d = 0;
                        let mut result_style = None;
                        for b in group {
                            match (&b.kind, b.el.as_element()) {
                                (AtomKind::RunChild, Some(x)) if is_w(x, "fldChar") => {
                                    match x.attr(ns::W, "fldCharType") {
                                        Some("begin") => d += 1,
                                        Some("separate") if d == 1 => in_result = true,
                                        Some("end") => {
                                            d -= 1;
                                        }
                                        _ => {}
                                    }
                                }
                                (AtomKind::Text(t), _) if in_result => {
                                    result.push_str(t);
                                    if result_style.is_none() {
                                        result_style = Some(run_style(b.rpr.as_ref()));
                                    }
                                }
                                (AtomKind::Block(_, t), _) if in_result => result.push_str(t),
                                _ => {}
                            }
                        }
                        let nodes = atoms_to_nodes(group, w);
                        let view = ObjectView {
                            id: 0,
                            kind: ObjectKind::Field,
                            text: result.clone(),
                            width: 0.0,
                            height: 0.0,
                            alt: String::new(),
                            style: result_style.unwrap_or(s),
                        };
                        let oid = objects.add(StoredObject {
                            nodes,
                            link: a.link.map(|l| links[l].clone()),
                            view,
                        });
                        out.object_ids.push(oid);
                        pos += utf16_len(&result);
                        inlines.push(crate::view::Inline::Object(
                            objects.get(oid).unwrap().view.clone(),
                        ));
                        i = end + 1;
                        continue;
                    }
                    if lock.is_none() {
                        lock =
                            Some("A field in this paragraph continues into the next one.".into());
                    }
                }
                let run = make_run(w, a.rpr.as_ref(), vec![a.el.clone()]);
                let (kind, text, alt) = match (el.ns, el.local()) {
                    (n, "br") if n == ns::W => {
                        if el.attr(ns::W, "type") == Some("page") {
                            (ObjectKind::PageBreak, String::new(), String::new())
                        } else {
                            (ObjectKind::ColumnBreak, String::new(), String::new())
                        }
                    }
                    (n, "drawing") if n == ns::W => {
                        let (k, alt) = drawing_kind(el);
                        (k, String::new(), alt)
                    }
                    (n, "pict") | (n, "object") if n == ns::W => {
                        let (k, alt) = drawing_kind(el);
                        let k = if el.local() == "object" {
                            ObjectKind::Other
                        } else {
                            k
                        };
                        (k, String::new(), alt)
                    }
                    (n, "AlternateContent") if n == ns::MC => {
                        let (k, alt) = drawing_kind(el);
                        (k, String::new(), alt)
                    }
                    (n, "footnoteReference") | (n, "endnoteReference") if n == ns::W => (
                        ObjectKind::Note,
                        el.attr(ns::W, "id").unwrap_or("*").to_owned(),
                        String::new(),
                    ),
                    (n, "sym") if n == ns::W => {
                        let c = el
                            .attr(ns::W, "char")
                            .and_then(|v| u32::from_str_radix(v, 16).ok())
                            .and_then(char::from_u32)
                            .map(super::numbering::map_symbol)
                            .unwrap_or('\u{25A1}');
                        (ObjectKind::Other, c.to_string(), String::new())
                    }
                    (n, "ptab") if n == ns::W => (ObjectKind::Other, "\t".into(), String::new()),
                    (n, "commentReference")
                    | (n, "annotationRef")
                    | (n, "fldChar")
                    | (n, "instrText")
                        if n == ns::W =>
                    {
                        // Invisible: kept where it was.
                        out.markers.push((pos, XmlNode::Element(run)));
                        i += 1;
                        continue;
                    }
                    (n, "footnoteRef") | (n, "endnoteRef") if n == ns::W => {
                        (ObjectKind::Note, "*".into(), String::new())
                    }
                    _ => {
                        let t = shown_text(el);
                        (ObjectKind::Other, t, String::new())
                    }
                };
                let (width, height) = drawing_size(el);
                let view = ObjectView {
                    id: 0,
                    kind,
                    text: text.clone(),
                    width,
                    height,
                    alt,
                    style: s,
                };
                let oid = objects.add(StoredObject {
                    nodes: vec![XmlNode::Element(run)],
                    link: a.link.map(|l| links[l].clone()),
                    view,
                });
                out.object_ids.push(oid);
                pos += utf16_len(&text);
                inlines.push(crate::view::Inline::Object(
                    objects.get(oid).unwrap().view.clone(),
                ));
                i += 1;
            }
        }
    }
    let editable = lock.is_none();
    out.view = Some(ParaView {
        id,
        style,
        list: None,
        inlines,
        editable,
        locked_reason: lock,
    });
    out
}

/// Runs for a sequence of atoms, merging neighbours with the same
/// properties; paragraph-level atoms go as they are.
fn atoms_to_nodes(atoms: &[Atom], w: &str) -> Vec<XmlNode> {
    let mut out: Vec<XmlNode> = Vec::new();
    let mut current: Option<(Option<Element>, Vec<XmlNode>)> = None;
    let flush = |current: &mut Option<(Option<Element>, Vec<XmlNode>)>, out: &mut Vec<XmlNode>| {
        if let Some((rpr, kids)) = current.take() {
            out.push(XmlNode::Element(make_run(w, rpr.as_ref(), kids)));
        }
    };
    for a in atoms {
        match a.kind {
            AtomKind::Text(_) | AtomKind::RunChild => match &mut current {
                Some((rpr, kids)) if *rpr == a.rpr => kids.push(a.el.clone()),
                _ => {
                    flush(&mut current, &mut out);
                    current = Some((a.rpr.clone(), vec![a.el.clone()]));
                }
            },
            _ => {
                flush(&mut current, &mut out);
                out.push(a.el.clone());
            }
        }
    }
    flush(&mut current, &mut out);
    out
}

/// What writing an edited paragraph needs from its document.
pub struct WriteCtx<'a> {
    pub styles: &'a StyleSheet,
    pub w: &'a str,
    /// Adds a hyperlink relationship for a URL; returns its id.
    pub add_link: &'a mut dyn FnMut(&str) -> String,
}

/// Run content for text: `w:t` pieces, tabs and breaks.
fn text_nodes(text: &str, w: &str) -> Vec<XmlNode> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let flush = |buf: &mut String, out: &mut Vec<XmlNode>| {
        if buf.is_empty() {
            return;
        }
        let mut t = Element::new(q(w, "t"), ns::W);
        if buf.starts_with([' ', '\u{A0}']) || buf.ends_with([' ', '\u{A0}']) || buf.contains("  ")
        {
            t.set_attr("xml:space", ns::XML, "preserve");
        }
        t.set_text(std::mem::take(buf));
        out.push(XmlNode::Element(t));
    };
    for c in text.chars() {
        let special = match c {
            '\t' => Some("tab"),
            '\n' | '\u{2028}' | '\r' => Some("br"),
            '\u{2011}' => Some("noBreakHyphen"),
            '\u{AD}' => Some("softHyphen"),
            _ => None,
        };
        match special {
            Some(name) => {
                flush(&mut buf, &mut out);
                out.push(XmlNode::Element(Element::new(q(w, name), ns::W)));
            }
            None => buf.push(c),
        }
    }
    flush(&mut buf, &mut out);
    out
}

/// Run properties for text that should look like `want`.
fn rpr_for(
    want: &RunStyle,
    input: &RebuildInput,
    mark: Option<&Element>,
    para_style: Option<&str>,
    ctx: &WriteCtx,
) -> Option<Element> {
    if let Some((_, rpr)) = input.templates.iter().find(|(s, _)| s == want) {
        return rpr.clone();
    }
    let template = match input.template_for(want) {
        Some((_, rpr)) => rpr.clone(),
        None => mark.map(|m| {
            let mut r = m.clone();
            r.name = q(ctx.w, "rPr");
            // A paragraph mark's own revision marks do not belong on runs.
            r.children.retain(|n| {
                !n.as_element().is_some_and(|e| {
                    e.ns == ns::W
                        && matches!(
                            e.local(),
                            "ins" | "del" | "moveFrom" | "moveTo" | "rPrChange"
                        )
                })
            });
            r
        }),
    };
    let current = ctx.styles.run_style(para_style, template.as_ref());
    let mut rpr = template.unwrap_or_else(|| Element::new(q(ctx.w, "rPr"), ns::W));
    write_rpr(&mut rpr, ctx.w, &current, want);
    (!rpr.children.is_empty()).then_some(rpr)
}

/// Write an edited paragraph: the original element with new content.
pub fn rebuild(
    p: &Element,
    input: &RebuildInput,
    inlines: &[InlineEdit],
    objects: &Objects,
    ctx: &mut WriteCtx,
) -> Element {
    let ppr = p.elements().find(|c| is_w(c, "pPr")).cloned();
    let mark = ppr
        .as_ref()
        .and_then(|pp| pp.elements().find(|c| is_w(c, "rPr")));
    let para_style = ctx.styles.para_style_id(ppr.as_ref()).map(str::to_owned);
    let mut out = head(p);
    if let Some(pp) = &ppr {
        out.push(pp.clone());
    }

    // Each piece as nodes, with the link it belongs to.
    let mut seq: Vec<(Option<String>, Option<Element>, Vec<XmlNode>)> = Vec::new();
    for piece in pieces(inlines, &input.markers, objects) {
        match piece {
            Piece::Text { text, style, link } => {
                let rpr = rpr_for(&style, input, mark, para_style.as_deref(), ctx);
                let run = make_run(ctx.w, rpr.as_ref(), text_nodes(&text, ctx.w));
                seq.push((
                    link.filter(|l| !l.is_empty()),
                    None,
                    vec![XmlNode::Element(run)],
                ));
            }
            Piece::Object { id } => {
                let o = objects.get(id).expect("pieces only lists known objects");
                let (target, head) = match &o.link {
                    Some((t, h)) => (Some(t.clone()), Some(h.clone())),
                    None => (None, None),
                };
                seq.push((target, head, o.nodes.clone()));
            }
            Piece::Marker(n) => {
                // Markers join the link around them.
                let link = seq.last().and_then(|(l, _, _)| l.clone());
                seq.push((link, None, vec![n]));
            }
        }
    }
    // Wrap runs of the same link in one link element.
    let mut i = 0;
    while i < seq.len() {
        let Some(target) = seq[i].0.clone() else {
            out.children.extend(std::mem::take(&mut seq[i].2));
            i += 1;
            continue;
        };
        let mut j = i;
        let mut known_head = None;
        let mut kids = Vec::new();
        while j < seq.len() && seq[j].0.as_deref() == Some(target.as_str()) {
            if known_head.is_none() {
                known_head = seq[j].1.clone();
            }
            kids.extend(std::mem::take(&mut seq[j].2));
            j += 1;
        }
        let mut link = match input.link_head(&target).cloned().or(known_head) {
            Some(h) => h,
            None => {
                let mut h = Element::new(q(ctx.w, "hyperlink"), ns::W);
                if let Some(anchor) = target.strip_prefix('#') {
                    h.set_attr(&q(ctx.w, "anchor"), ns::W, anchor);
                } else {
                    let id = (ctx.add_link)(&target);
                    h.set_attr("r:id", ns::R, id);
                }
                h.set_attr(&q(ctx.w, "history"), ns::W, "1");
                h
            }
        };
        link.children = kids;
        out.push(link);
        i = j;
    }
    out
}

fn ppr_mut<'e>(p: &'e mut Element, w: &str) -> &'e mut Element {
    let at = match p
        .children
        .iter()
        .position(|n| n.as_element().is_some_and(|e| is_w(e, "pPr")))
    {
        Some(i) => i,
        None => {
            p.children
                .insert(0, XmlNode::Element(Element::new(q(w, "pPr"), ns::W)));
            0
        }
    };
    p.children[at].as_element_mut().unwrap()
}

fn get_or_add<'e>(parent: &'e mut Element, local: &str, w: &str) -> &'e mut Element {
    if !parent.elements().any(|e| is_w(e, local)) {
        put_ordered(parent, Element::new(q(w, local), ns::W), PPR_ORDER);
    }
    parent.elements_mut().find(|e| is_w(e, local)).unwrap()
}

fn twips(pt: f32) -> String {
    ((pt * 20.0).round() as i64).to_string()
}

/// What a paragraph patch needs from the document.
pub struct PatchCtx<'a> {
    pub styles: &'a StyleSheet,
    pub w: &'a str,
    /// The list (num id) to use for `bullet` or `number`.
    pub list_for: &'a mut dyn FnMut(bool) -> String,
    /// Whether a list (num id) is a bullet list.
    pub is_bullet: &'a dyn Fn(&str) -> bool,
}

/// Apply a patch to a paragraph's properties.
pub fn patch(p: &mut Element, patch: &ParaPatch, ctx: &mut PatchCtx) {
    let w = ctx.w;
    if let Some(style) = &patch.style_id {
        let pp = ppr_mut(p, w);
        if style.is_empty() || ctx.styles.default_para.as_deref() == Some(style.as_str()) {
            remove_child(pp, "pStyle");
        } else {
            put_ordered(pp, wel(w, "pStyle", Some(style)), PPR_ORDER);
        }
    }
    if let Some(align) = patch.align {
        let v = match align {
            Align::Left => "left",
            Align::Center => "center",
            Align::Right => "right",
            Align::Justify => "both",
        };
        put_ordered(ppr_mut(p, w), wel(w, "jc", Some(v)), PPR_ORDER);
    }
    let current_list = {
        let ppr = p.elements().find(|c| is_w(c, "pPr"));
        ctx.styles.numbering(ppr)
    };
    if let Some(list) = &patch.list {
        let pp = ppr_mut(p, w);
        match list.as_str() {
            "bullet" | "number" => {
                let bullet = list == "bullet";
                let keep = current_list
                    .as_ref()
                    .filter(|(id, _)| (ctx.is_bullet)(id) == bullet);
                if keep.is_some() {
                    // Already that kind of list.
                    return finish(p, patch, ctx);
                }
                let (num_id, level) = (
                    (ctx.list_for)(bullet),
                    current_list.as_ref().map_or(0, |(_, l)| *l),
                );
                let mut num_pr = Element::new(q(w, "numPr"), ns::W);
                num_pr.push(wel(w, "ilvl", Some(&level.to_string())));
                num_pr.push(wel(w, "numId", Some(&num_id)));
                put_ordered(pp, num_pr, PPR_ORDER);
            }
            _ => {
                remove_child(pp, "numPr");
                // A list style still numbers it; switch that off.
                let ppr = p.elements().find(|c| is_w(c, "pPr"));
                if ctx.styles.numbering(ppr).is_some() {
                    let mut num_pr = Element::new(q(w, "numPr"), ns::W);
                    num_pr.push(wel(w, "numId", Some("0")));
                    put_ordered(ppr_mut(p, w), num_pr, PPR_ORDER);
                }
            }
        }
    }
    finish(p, patch, ctx);
}

/// The rest of a patch, after its list change.
fn finish(p: &mut Element, patch: &ParaPatch, ctx: &mut PatchCtx) {
    let w = ctx.w;
    if let Some(steps) = patch.indent_steps {
        let ppr = p.elements().find(|c| is_w(c, "pPr"));
        let list = ctx.styles.numbering(ppr);
        let style = ctx.styles.para_style(ppr);
        let pp = ppr_mut(p, w);
        match list {
            Some((num_id, level)) => {
                let level = (level as i32 + steps).clamp(0, 8);
                let mut num_pr = Element::new(q(w, "numPr"), ns::W);
                num_pr.push(wel(w, "ilvl", Some(&level.to_string())));
                num_pr.push(wel(w, "numId", Some(&num_id)));
                put_ordered(pp, num_pr, PPR_ORDER);
            }
            None => {
                let left = (style.indent_left + steps as f32 * 36.0).max(0.0);
                let left = (left / 36.0).round() * 36.0;
                let ind = get_or_add(pp, "ind", w);
                ind.remove_attr(ns::W, "start");
                ind.set_attr(&q(w, "left"), ns::W, twips(left));
            }
        }
    }
    if patch.space_before.is_some() || patch.space_after.is_some() || patch.line.is_some() {
        let pp = ppr_mut(p, w);
        let sp = get_or_add(pp, "spacing", w);
        if let Some(v) = patch.space_before {
            sp.remove_attr(ns::W, "beforeAutospacing");
            sp.remove_attr(ns::W, "beforeLines");
            sp.set_attr(&q(w, "before"), ns::W, twips(v));
        }
        if let Some(v) = patch.space_after {
            sp.remove_attr(ns::W, "afterAutospacing");
            sp.remove_attr(ns::W, "afterLines");
            sp.set_attr(&q(w, "after"), ns::W, twips(v));
        }
        if let Some(line) = patch.line {
            let (v, rule) = match line {
                LineSpacing::Multiple(m) => (((m * 240.0).round() as i64).to_string(), "auto"),
                LineSpacing::Exactly(pt) => (twips(pt), "exact"),
                LineSpacing::AtLeast(pt) => (twips(pt), "atLeast"),
            };
            sp.set_attr(&q(w, "line"), ns::W, v);
            sp.set_attr(&q(w, "lineRule"), ns::W, rule);
        }
    }
    if let Some(on) = patch.page_break_before {
        let pp = ppr_mut(p, w);
        put_ordered(
            pp,
            wel(w, "pageBreakBefore", if on { None } else { Some("0") }),
            PPR_ORDER,
        );
    }
    if let Some(on) = patch.keep_next {
        let pp = ppr_mut(p, w);
        put_ordered(
            pp,
            wel(w, "keepNext", if on { None } else { Some("0") }),
            PPR_ORDER,
        );
    }
    // An empty pPr says nothing.
    if let Some(i) = p.children.iter().position(|n| {
        n.as_element()
            .is_some_and(|e| is_w(e, "pPr") && e.children.is_empty() && e.attrs.is_empty())
    }) {
        p.children.remove(i);
    }
}

/// A new empty paragraph with the properties of `like` (minus a page break
/// before), optionally in another style.
pub fn new_para(
    like: Option<&Element>,
    style: Option<&str>,
    styles: &StyleSheet,
    w: &str,
) -> Element {
    let mut p = Element::new(q(w, "p"), ns::W);
    if let Some(pp) = like.and_then(|l| l.elements().find(|c| is_w(c, "pPr"))) {
        let mut pp = pp.clone();
        remove_child(&mut pp, "pageBreakBefore");
        remove_child(&mut pp, "sectPr");
        remove_child(&mut pp, "pPrChange");
        if let Some(mark) = pp.child_mut(ns::W, "rPr") {
            mark.children.retain(|n| {
                !n.as_element().is_some_and(|e| {
                    e.ns == ns::W
                        && matches!(
                            e.local(),
                            "ins" | "del" | "moveFrom" | "moveTo" | "rPrChange"
                        )
                })
            });
        }
        p.push(pp);
    }
    if let Some(style) = style {
        let mut pp = ppr_mut(&mut p, w).clone();
        if style.is_empty() || styles.default_para.as_deref() == Some(style) {
            remove_child(&mut pp, "pStyle");
        } else {
            put_ordered(&mut pp, wel(w, "pStyle", Some(style)), PPR_ORDER);
        }
        // A new paragraph in another style drops the list it came from.
        if styles.para_style_id(Some(&pp))
            != like.and_then(|l| styles.para_style_id(l.elements().find(|c| is_w(c, "pPr"))))
        {
            remove_child(&mut pp, "numPr");
        }
        *ppr_mut(&mut p, w) = pp;
    }
    if let Some(i) = p.children.iter().position(|n| {
        n.as_element()
            .is_some_and(|e| is_w(e, "pPr") && e.children.is_empty())
    }) {
        p.children.remove(i);
    }
    p
}

/// The value of the style a paragraph's `w:pStyle` names.
pub fn style_of(p: &Element) -> Option<&str> {
    p.elements()
        .find(|c| is_w(c, "pPr"))
        .and_then(|pp| pp.elements().find(|c| is_w(c, "pStyle")))
        .and_then(wval)
}
