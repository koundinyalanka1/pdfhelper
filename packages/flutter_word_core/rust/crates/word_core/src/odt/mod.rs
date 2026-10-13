//! OpenDocument text (`.odt`, `.ott`): read into a body tree, edited
//! paragraph by paragraph, and written back in place. Formatting of edited
//! text goes into new automatic styles; everything else in the package is
//! copied as it was.

pub mod lists;
pub mod para;
pub mod styles;

use std::collections::HashMap;

use doc_opc::Package;
use doc_xml::{ns, Document, Element, Node as XmlNode};

use crate::backend::{Backend, Format, Splice, StyleInfo, TableOp};
use crate::error::WordError;
use crate::projected::{Objects, Projected, RebuildInput, StoredObject};
use crate::tree::{self, BoxKind, BoxNode, Class, Ids, Node, Para};
use crate::view::{BlockView, CellView, InlineEdit, LineSpacing, ListLabel, PageSetup, ParaPatch, RowView, TableView};
use para::{q, Prefixes, WriteCtx};
use styles::{inches, length_pt, OdfStyles};

const CONTENT: &str = "content.xml";
const STYLES: &str = "styles.xml";
const MANIFEST: &str = "META-INF/manifest.xml";

/// Named styles added when a document first uses them, as LibreOffice
/// defines them.
fn builtin_style(name: &str) -> Option<&'static str> {
    Some(match name {
        "Standard" => r#"<style:style style:name="Standard" style:family="paragraph" style:class="text"/>"#,
        "Heading" => {
            r#"<style:style style:name="Heading" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Text_20_body" style:class="text"><style:paragraph-properties fo:margin-top="0.1665in" fo:margin-bottom="0.0835in" fo:keep-with-next="always"/><style:text-properties fo:font-size="14pt"/></style:style>"#
        }
        "Heading_20_1" => {
            r#"<style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:default-outline-level="1" style:class="text"><style:paragraph-properties fo:margin-top="0.1665in" fo:margin-bottom="0.0835in"/><style:text-properties fo:font-size="130%" fo:font-weight="bold" style:font-size-asian="130%" style:font-weight-asian="bold" style:font-size-complex="130%" style:font-weight-complex="bold"/></style:style>"#
        }
        "Heading_20_2" => {
            r#"<style:style style:name="Heading_20_2" style:display-name="Heading 2" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:default-outline-level="2" style:class="text"><style:paragraph-properties fo:margin-top="0.139in" fo:margin-bottom="0.0835in"/><style:text-properties fo:font-size="115%" fo:font-weight="bold" style:font-size-asian="115%" style:font-weight-asian="bold" style:font-size-complex="115%" style:font-weight-complex="bold"/></style:style>"#
        }
        "Heading_20_3" => {
            r#"<style:style style:name="Heading_20_3" style:display-name="Heading 3" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:default-outline-level="3" style:class="text"><style:paragraph-properties fo:margin-top="0.0972in" fo:margin-bottom="0.0835in"/><style:text-properties fo:font-size="101%" fo:font-weight="bold" style:font-size-asian="101%" style:font-weight-asian="bold" style:font-size-complex="101%" style:font-weight-complex="bold"/></style:style>"#
        }
        "Title" => {
            r#"<style:style style:name="Title" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:class="chapter"><style:paragraph-properties fo:text-align="center"/><style:text-properties fo:font-size="28pt" fo:font-weight="bold" style:font-size-asian="28pt" style:font-weight-asian="bold" style:font-size-complex="28pt" style:font-weight-complex="bold"/></style:style>"#
        }
        "Subtitle" => {
            r#"<style:style style:name="Subtitle" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:class="chapter"><style:paragraph-properties fo:margin-top="0.0417in" fo:margin-bottom="0.0835in" fo:text-align="center"/><style:text-properties fo:font-size="18pt" style:font-size-asian="18pt" style:font-size-complex="18pt"/></style:style>"#
        }
        "Quotations" => {
            r#"<style:style style:name="Quotations" style:family="paragraph" style:parent-style-name="Standard" style:class="html"><style:paragraph-properties fo:margin-left="0.3937in" fo:margin-right="0.3937in" fo:margin-top="0in" fo:margin-bottom="0.1965in"/></style:style>"#
        }
        "Text_20_body" => {
            r#"<style:style style:name="Text_20_body" style:display-name="Text body" style:family="paragraph" style:parent-style-name="Standard" style:class="text"><style:paragraph-properties fo:margin-top="0in" fo:margin-bottom="0.0972in" fo:line-height="115%"/></style:style>"#
        }
        _ => return None,
    })
}

const OFFERED: &[(&str, &str, Option<u8>)] = &[
    ("Standard", "Default Paragraph Style", None),
    ("Text_20_body", "Text body", None),
    ("Title", "Title", None),
    ("Subtitle", "Subtitle", None),
    ("Heading_20_1", "Heading 1", Some(0)),
    ("Heading_20_2", "Heading 2", Some(1)),
    ("Heading_20_3", "Heading 3", Some(2)),
    ("Quotations", "Quotations", None),
];

/// Word's style ids, for edits that name them.
fn odf_name_for(id: &str) -> &str {
    match id {
        "Normal" => "Standard",
        "Heading1" => "Heading_20_1",
        "Heading2" => "Heading_20_2",
        "Heading3" => "Heading_20_3",
        "Quote" => "Quotations",
        other => other,
    }
}

const NS_DECLS: &str = r#"xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0""#;

/// Parse a fragment written with the standard prefixes.
fn fragment(xml: &str) -> Element {
    let doc = Document::parse_str(&format!("<x {NS_DECLS}>{xml}</x>")).expect("built-in XML parses");
    let e = doc.root.elements().next().expect("a fragment has an element").clone();
    e
}

fn classify(e: &Element, _parent: Option<BoxKind>) -> Class {
    let empty = || if e.text().trim().is_empty() { Class::Hidden } else { Class::Raw };
    if e.ns == ns::TEXT {
        return match e.local() {
            "p" | "h" => Class::Para,
            "list" => Class::Box(BoxKind::List),
            "list-item" | "list-header" => Class::Box(BoxKind::ListItem),
            "section" | "index-title" => Class::Box(BoxKind::Section),
            "table-of-content" | "illustration-index" | "table-index" | "object-index" | "user-index" | "alphabetical-index" | "bibliography" => {
                Class::Box(BoxKind::Control)
            }
            "index-body" => Class::Box(BoxKind::ControlContent),
            local if local.ends_with("-source") || local.ends_with("-decls") => Class::Hidden,
            _ => empty(),
        };
    }
    if e.ns == ns::TABLE {
        return match e.local() {
            "table" => Class::Box(BoxKind::Table),
            "table-header-rows" | "table-rows" | "table-row-group" => Class::Box(BoxKind::RowGroup),
            "table-row" => Class::Box(BoxKind::Row),
            "table-cell" => Class::Box(BoxKind::Cell),
            "covered-table-cell" => Class::Box(BoxKind::CoveredCell),
            _ => Class::Hidden,
        };
    }
    empty()
}

fn is(e: &Element, n: doc_xml::ns::Ns, local: &str) -> bool {
    e.ns == n && e.local() == local
}

/// Boxes of a kind, looking through row groups.
fn boxes_of(items: &[Node], kind: BoxKind) -> Vec<&BoxNode> {
    let mut out = Vec::new();
    for n in items {
        if let Node::Box(b) = n {
            if b.kind == kind {
                out.push(b);
            } else if b.kind == BoxKind::RowGroup {
                out.extend(boxes_of(&b.items, kind));
            }
        }
    }
    out
}

/// An OpenDocument text being edited.
pub struct Odt {
    pkg: Package,
    format: Format,
    /// `content.xml` with `office:text` emptied (its children live in
    /// `body`).
    content: Document,
    /// Child indexes from the root to `office:text`.
    text_path: Vec<usize>,
    body: Vec<Node>,
    body_changed: bool,
    ids: Ids,
    p: Prefixes,
    styles: OdfStyles,
    styles_doc: Option<Document>,
    styles_changed: bool,
    /// Automatic styles added, by their properties, for reuse.
    made: HashMap<String, String>,
    manifest: Option<Document>,
    manifest_changed: bool,
    page: PageSetup,
}

impl Odt {
    pub fn open(bytes: Vec<u8>, format: Format) -> Result<Odt, WordError> {
        let pkg = Package::open(bytes)?;
        if !pkg.exists(CONTENT) {
            return Err(WordError::Corrupt("This document has no content.".into()));
        }
        if let Ok(m) = pkg.read_text(MANIFEST) {
            if m.contains("encryption-data") {
                return Err(WordError::Encrypted);
            }
        }
        let mut content = pkg.read_xml(CONTENT)?;
        let p = {
            let r = &content;
            let get = |n: doc_xml::ns::Ns, d: &str| r.prefix_for(n).unwrap_or_else(|| d.to_owned());
            Prefixes {
                text: get(ns::TEXT, "text"),
                style: get(ns::STYLE, "style"),
                fo: get(ns::FO, "fo"),
                xlink: get(ns::XLINK, "xlink"),
                draw: get(ns::DRAW, "draw"),
                svg: get(ns::SVG, "svg"),
                table: get(ns::TABLE, "table"),
                office: get(ns::OFFICE, "office"),
            }
        };
        // Namespaces new content uses must be declared.
        for (prefix, n) in [
            ("style", ns::STYLE),
            ("fo", ns::FO),
            ("xlink", ns::XLINK),
            ("draw", ns::DRAW),
            ("svg", ns::SVG),
            ("table", ns::TABLE),
            ("text", ns::TEXT),
        ] {
            if content.prefix_for(n).is_none() && content.root.attr_named(&format!("xmlns:{prefix}")).is_none() {
                content.root.set_attr(&format!("xmlns:{prefix}"), ns::XMLNS, n.uri());
            }
        }
        let body_at = content
            .root
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "body")))
            .ok_or_else(|| WordError::Corrupt("This document has no body.".into()))?;
        let text_at = content.root.children[body_at]
            .as_element()
            .unwrap()
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "text")))
            .ok_or_else(|| WordError::Unsupported("This OpenDocument file is not a text document.".into()))?;
        let text_path = vec![body_at, text_at];
        let kids = {
            let body = content.root.children[body_at].as_element_mut().unwrap();
            let text = body.children[text_at].as_element_mut().unwrap();
            std::mem::take(&mut text.children)
        };
        let mut ids = Ids::default();
        let body = tree::build(kids, None, &mut ids, &classify);

        let styles_doc = pkg.read_xml(STYLES).ok();
        let mut styles = OdfStyles::default();
        if let Some(d) = &styles_doc {
            styles.add_part(&d.root, false);
        }
        styles.add_part(&content.root, true);
        let page = styles_doc.as_ref().map(page_setup).unwrap_or_default();
        let manifest = pkg.read_xml(MANIFEST).ok();
        Ok(Odt {
            pkg,
            format,
            content,
            text_path,
            body,
            body_changed: false,
            ids,
            p,
            styles,
            styles_doc,
            styles_changed: false,
            made: HashMap::new(),
            manifest,
            manifest_changed: false,
            page,
        })
    }

    /// `office:automatic-styles` of the content, made if missing.
    fn auto_styles(&mut self) -> &mut Element {
        let root = &mut self.content.root;
        let at = match root.children.iter().position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "automatic-styles"))) {
            Some(i) => i,
            None => {
                let body = root
                    .children
                    .iter()
                    .position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "body")))
                    .unwrap_or(root.children.len());
                root.children.insert(body, XmlNode::Element(Element::new(q(&self.p.office, "automatic-styles"), ns::OFFICE)));
                if self.text_path[0] >= body {
                    self.text_path[0] += 1;
                }
                body
            }
        };
        root.children[at].as_element_mut().unwrap()
    }

    fn unused_auto_name(&self, prefix: &str) -> String {
        (1..)
            .map(|i| format!("{prefix}{i}"))
            .find(|n| !self.styles.auto.keys().any(|(_, x)| x == n) && !self.styles.lists.contains_key(n))
            .unwrap()
    }

    /// Add an automatic style element and register it.
    fn add_auto(&mut self, e: Element) {
        if is(&e, ns::TEXT, "list-style") {
            if let Some(name) = e.attr(ns::STYLE, "name") {
                self.styles.lists.insert(name.to_owned(), styles::ListStyle::read(&e));
            }
        } else if let Some(st) = styles::OdfStyle::read(&e, true) {
            self.styles.auto.insert((st.family.clone(), st.name.clone()), st);
        }
        self.auto_styles().push(e);
    }

    /// The font face declared for a family, declaring it when missing.
    fn font_face(&mut self, family: &str) -> String {
        if let Some(f) = self.styles.font_face_for(family) {
            return f.to_owned();
        }
        let root = &mut self.content.root;
        let at = match root.children.iter().position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "font-face-decls"))) {
            Some(i) => i,
            None => {
                let first = root
                    .children
                    .iter()
                    .position(|n| n.as_element().is_some_and(|e| is(e, ns::OFFICE, "automatic-styles") || is(e, ns::OFFICE, "body")))
                    .unwrap_or(0);
                root.children.insert(first, XmlNode::Element(Element::new(q(&self.p.office, "font-face-decls"), ns::OFFICE)));
                if self.text_path[0] >= first {
                    self.text_path[0] += 1;
                }
                first
            }
        };
        let mut f = Element::new(q(&self.p.style, "font-face"), ns::STYLE);
        f.set_attr(&q(&self.p.style, "name"), ns::STYLE, family);
        let quoted = if family.contains(' ') { format!("'{family}'") } else { family.to_owned() };
        f.set_attr(&q(&self.p.svg, "font-family"), ns::SVG, quoted);
        root.children[at].as_element_mut().unwrap().push(f);
        self.styles.fonts.insert(family.to_owned(), family.to_owned());
        family.to_owned()
    }

    /// The list style for bullets or numbers, made when there is none.
    fn list_style(&mut self, bullet: bool) -> String {
        let mut found: Vec<&String> = self
            .styles
            .lists
            .iter()
            .filter(|(_, l)| l.is_bullet() == bullet && (bullet || l.levels.first().is_some_and(|x| x.format == "1")))
            .map(|(n, _)| n)
            .collect();
        found.sort();
        if let Some(n) = found.first() {
            return (*n).clone();
        }
        let name = self.unused_auto_name("L");
        let mut xml = format!(r#"<text:list-style style:name="{name}">"#);
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"];
        let formats = ["1", "a", "i"];
        for level in 1..=10u32 {
            let indent = 0.25 * level as f32 + 0.25;
            let props = format!(
                r#"<style:list-level-properties text:list-level-position-and-space-mode="label-alignment"><style:list-level-label-alignment text:label-followed-by="listtab" text:list-tab-stop-position="{indent}in" fo:text-indent="-0.25in" fo:margin-left="{indent}in"/></style:list-level-properties>"#
            );
            if bullet {
                let b = bullets[(level as usize - 1) % 3];
                xml.push_str(&format!(r#"<text:list-level-style-bullet text:level="{level}" text:bullet-char="{b}">{props}</text:list-level-style-bullet>"#));
            } else {
                let f = formats[(level as usize - 1) % 3];
                xml.push_str(&format!(r#"<text:list-level-style-number text:level="{level}" style:num-suffix="." style:num-format="{f}">{props}</text:list-level-style-number>"#));
            }
        }
        xml.push_str("</text:list-style>");
        self.add_auto(fragment(&xml));
        name
    }

    /// Make sure a named paragraph style exists (built-in ones are added).
    fn ensure_named(&mut self, name: &str) {
        let key = ("paragraph".to_owned(), name.to_owned());
        if self.styles.named.contains_key(&key) {
            return;
        }
        let Some(xml) = builtin_style(name) else { return };
        let e = fragment(xml);
        if let Some(parent) = e.attr(ns::STYLE, "parent-style-name").map(str::to_owned) {
            self.ensure_named(&parent);
        }
        let Some(doc) = &mut self.styles_doc else { return };
        let Some(section) = doc.root.elements_mut().find(|c| is(c, ns::OFFICE, "styles")) else { return };
        section.push(e.clone());
        if let Some(st) = styles::OdfStyle::read(&e, false) {
            self.styles.named.insert(key, st);
        }
        self.styles_changed = true;
    }

    /// Change a paragraph's direct properties through a new automatic
    /// style based on its current one.
    fn restyle(&mut self, el: &mut Element, change: &dyn Fn(&mut Element, &Prefixes), parent: Option<&str>) {
        let current = el.attr(ns::TEXT, "style-name").map(str::to_owned);
        let mut st = match current.as_deref().and_then(|n| self.styles.auto.get(&("paragraph".to_owned(), n.to_owned()))) {
            Some(_) => {
                let name = current.clone().unwrap();
                self.auto_element("paragraph", &name).unwrap_or_else(|| Element::new(q(&self.p.style, "style"), ns::STYLE))
            }
            None => {
                let mut e = Element::new(q(&self.p.style, "style"), ns::STYLE);
                e.set_attr(&q(&self.p.style, "family"), ns::STYLE, "paragraph");
                if let Some(c) = &current {
                    e.set_attr(&q(&self.p.style, "parent-style-name"), ns::STYLE, c.clone());
                }
                e
            }
        };
        st.set_attr(&q(&self.p.style, "family"), ns::STYLE, "paragraph");
        if let Some(parent) = parent {
            st.set_attr(&q(&self.p.style, "parent-style-name"), ns::STYLE, parent);
        }
        change(&mut st, &self.p);
        st.remove_attr(ns::STYLE, "name");
        let key = format!("para|{}", st.to_xml());
        let name = match self.made.get(&key) {
            Some(n) => n.clone(),
            None => {
                let name = self.unused_auto_name("P");
                let mut e = st.clone();
                e.attrs.insert(
                    0,
                    doc_xml::Attr {
                        name: q(&self.p.style, "name"),
                        ns: ns::STYLE,
                        value: name.clone(),
                    },
                );
                self.add_auto(e);
                self.made.insert(key, name.clone());
                name
            }
        };
        el.set_attr(&q(&self.p.text, "style-name"), ns::TEXT, name);
    }

    fn auto_element(&self, family: &str, name: &str) -> Option<Element> {
        let root = &self.content.root;
        let section = root.elements().find(|e| is(e, ns::OFFICE, "automatic-styles"))?;
        section
            .elements()
            .find(|e| is(e, ns::STYLE, "style") && e.attr(ns::STYLE, "family") == Some(family) && e.attr(ns::STYLE, "name") == Some(name))
            .cloned()
    }

    fn style_width(&self, family: &str, name: Option<&str>, local: &str) -> Option<f32> {
        let st = self.styles.get(family, name?)?;
        st.other.as_ref()?.attr(ns::STYLE, local).and_then(length_pt)
    }

    fn blank_cell(&mut self, cell: &mut BoxNode) {
        let like = tree::paragraphs(&cell.items).first().map(|p| p.el.clone());
        cell.items.retain(|n| matches!(n, Node::Hidden(_)));
        cell.head.attrs.retain(|a| !(a.ns == ns::OFFICE && a.local().starts_with("value") || a.ns == ns::OFFICE && a.local().ends_with("-value")));
        let p = self.new_para(like.as_ref(), None);
        let id = self.ids.next();
        cell.items.push(Node::Para(Para { id, el: p }));
    }

    fn parent_of(&self, path: &[usize]) -> (u32, Option<&BoxNode>) {
        if path.len() <= 1 {
            return (0, None);
        }
        match tree::node_at(&self.body, &path[..path.len() - 1]) {
            Some(Node::Box(b)) => (b.id, Some(b)),
            _ => (0, None),
        }
    }
}

/// The page setup of the first master page.
fn page_setup(styles_doc: &Document) -> PageSetup {
    let mut p = PageSetup::default();
    let root = &styles_doc.root;
    let layout_name = root
        .elements()
        .find(|e| is(e, ns::OFFICE, "master-styles"))
        .and_then(|m| {
            m.elements()
                .find(|e| is(e, ns::STYLE, "master-page") && e.attr(ns::STYLE, "name") == Some("Standard"))
                .or_else(|| m.elements().find(|e| is(e, ns::STYLE, "master-page")))
        })
        .and_then(|m| m.attr(ns::STYLE, "page-layout-name"))
        .map(str::to_owned);
    let Some(name) = layout_name else { return p };
    let props = root
        .elements()
        .filter(|e| is(e, ns::OFFICE, "automatic-styles") || is(e, ns::OFFICE, "styles"))
        .flat_map(|s| s.elements())
        .find(|e| is(e, ns::STYLE, "page-layout") && e.attr(ns::STYLE, "name") == Some(name.as_str()))
        .and_then(|l| l.elements().find(|e| is(e, ns::STYLE, "page-layout-properties")));
    if let Some(pp) = props {
        let get = |a: &str| pp.attr(ns::FO, a).and_then(length_pt);
        p.width = get("page-width").unwrap_or(p.width);
        p.height = get("page-height").unwrap_or(p.height);
        p.margin_top = get("margin-top").unwrap_or(p.margin_top);
        p.margin_bottom = get("margin-bottom").unwrap_or(p.margin_bottom);
        p.margin_left = get("margin-left").unwrap_or(p.margin_left);
        p.margin_right = get("margin-right").unwrap_or(p.margin_right);
    }
    p
}

fn set_prop(st: &mut Element, p: &Prefixes, local: &str, attr: (&str, doc_xml::ns::Ns, &str), value: &str) {
    let at = match st.children.iter().position(|n| n.as_element().is_some_and(|e| is(e, ns::STYLE, local))) {
        Some(i) => i,
        None => {
            // Paragraph properties come before text properties.
            let pos = if local == "paragraph-properties" { 0 } else { st.children.len() };
            st.children.insert(pos, XmlNode::Element(Element::new(q(&p.style, local), ns::STYLE)));
            pos
        }
    };
    let e = st.children[at].as_element_mut().unwrap();
    let prefix = if attr.1 == ns::FO { &p.fo } else { &p.style };
    e.set_attr(&q(prefix, attr.0), attr.1, value);
    let _ = attr.2;
}

impl Backend for Odt {
    fn format(&self) -> Format {
        self.format
    }

    fn body(&self) -> &Vec<Node> {
        &self.body
    }

    fn body_mut(&mut self) -> &mut Vec<Node> {
        self.body_changed = true;
        &mut self.body
    }

    fn ids(&mut self) -> &mut Ids {
        &mut self.ids
    }

    fn project(&self, p: &Para, objects: &mut Objects) -> Projected {
        para::project(&p.el, p.id, &self.styles, objects)
    }

    fn list_labels(&self) -> HashMap<u32, ListLabel> {
        let styles = &self.styles;
        let base = |e: &Element| para::base_run(styles, e);
        let mut l = lists::Labeler::new(styles, &base);
        l.walk(&self.body);
        l.out
    }

    fn rebuild(&mut self, base: &Element, input: &RebuildInput, inlines: &[InlineEdit], objects: &Objects) -> Element {
        // New styles are collected first, then added: the context borrows
        // the style registry.
        let styles = self.styles.clone();
        let p = self.p.clone();
        let made_before = self.made.clone();
        let mut new_text: Vec<(Vec<(&'static str, String)>, String)> = Vec::new();
        let mut new_fonts: Vec<String> = Vec::new();
        let mut counter = 0usize;
        let taken: Vec<String> = styles.auto.keys().map(|(_, n)| n.clone()).collect();
        let el = {
            let mut text_style = |props: &[(&'static str, String)]| -> String {
                let key = format!("text|{props:?}");
                if let Some(n) = made_before.get(&key) {
                    return n.clone();
                }
                if let Some((_, n)) = new_text.iter().find(|(p, _)| p.as_slice() == props) {
                    return n.clone();
                }
                let name = loop {
                    counter += 1;
                    let n = format!("T{counter}");
                    if !taken.contains(&n) && !made_before.values().any(|v| *v == n) {
                        break n;
                    }
                };
                new_text.push((props.to_vec(), name.clone()));
                name
            };
            let mut font_face = |family: &str| -> String {
                if let Some(f) = styles.font_face_for(family) {
                    return f.to_owned();
                }
                new_fonts.push(family.to_owned());
                family.to_owned()
            };
            let mut ctx = WriteCtx {
                styles: &styles,
                p: &p,
                text_style: &mut text_style,
                font_face: &mut font_face,
            };
            para::rebuild(base, input, inlines, objects, &mut ctx)
        };
        for f in new_fonts {
            self.font_face(&f);
        }
        for (props, name) in new_text {
            let mut st = Element::new(q(&self.p.style, "style"), ns::STYLE);
            st.set_attr(&q(&self.p.style, "name"), ns::STYLE, name.clone());
            st.set_attr(&q(&self.p.style, "family"), ns::STYLE, "text");
            let mut tp = Element::new(q(&self.p.style, "text-properties"), ns::STYLE);
            for (attr, v) in &props {
                let (prefix, local) = attr.split_once(':').unwrap();
                let (n, real) = match prefix {
                    "fo" => (ns::FO, self.p.fo.clone()),
                    "text" => (ns::TEXT, self.p.text.clone()),
                    _ => (ns::STYLE, self.p.style.clone()),
                };
                tp.set_attr(&q(&real, local), n, v.clone());
            }
            st.push(tp);
            self.add_auto(st);
            self.made.insert(format!("text|{props:?}"), name);
        }
        el
    }

    fn patch(&mut self, paras: &mut [Element], _prev: Option<&Element>, patch: &ParaPatch) {
        let parent = patch.style_id.as_deref().map(|s| odf_name_for(s).to_owned());
        if let Some(name) = &parent {
            self.ensure_named(name);
        }
        let outline = parent.as_deref().and_then(|n| self.styles.named.get(&("paragraph".to_owned(), n.to_owned()))).and_then(|s| s.outline);
        for el in paras.iter_mut() {
            let current = self.styles.para_style(el.attr(ns::TEXT, "style-name"), None);
            let patch = patch.clone();
            let change = move |st: &mut Element, p: &Prefixes| {
                if let Some(a) = patch.align {
                    let v = match a {
                        crate::view::Align::Left => "start",
                        crate::view::Align::Center => "center",
                        crate::view::Align::Right => "end",
                        crate::view::Align::Justify => "justify",
                    };
                    set_prop(st, p, "paragraph-properties", ("text-align", ns::FO, ""), v);
                }
                if let Some(steps) = patch.indent_steps {
                    let left = ((current.indent_left + steps as f32 * 36.0) / 36.0).round().max(0.0) * 36.0;
                    set_prop(st, p, "paragraph-properties", ("margin-left", ns::FO, ""), &inches(left));
                }
                if let Some(v) = patch.space_before {
                    set_prop(st, p, "paragraph-properties", ("margin-top", ns::FO, ""), &inches(v));
                }
                if let Some(v) = patch.space_after {
                    set_prop(st, p, "paragraph-properties", ("margin-bottom", ns::FO, ""), &inches(v));
                }
                if let Some(line) = patch.line {
                    match line {
                        LineSpacing::Multiple(m) => set_prop(st, p, "paragraph-properties", ("line-height", ns::FO, ""), &format!("{}%", (m * 100.0).round())),
                        LineSpacing::Exactly(pt) => set_prop(st, p, "paragraph-properties", ("line-height", ns::FO, ""), &format!("{pt}pt")),
                        LineSpacing::AtLeast(pt) => set_prop(st, p, "paragraph-properties", ("line-height-at-least", ns::STYLE, ""), &format!("{pt}pt")),
                    }
                }
                if let Some(on) = patch.page_break_before {
                    set_prop(st, p, "paragraph-properties", ("break-before", ns::FO, ""), if on { "page" } else { "auto" });
                }
                if let Some(on) = patch.keep_next {
                    set_prop(st, p, "paragraph-properties", ("keep-with-next", ns::FO, ""), if on { "always" } else { "auto" });
                }
            };
            let only_style = patch.align.is_none()
                && patch.indent_steps.is_none()
                && patch.space_before.is_none()
                && patch.space_after.is_none()
                && patch.line.is_none()
                && patch.page_break_before.is_none()
                && patch.keep_next.is_none();
            if only_style {
                if let Some(name) = &parent {
                    // A new style replaces the paragraph's direct look only
                    // where it had none.
                    let auto = el
                        .attr(ns::TEXT, "style-name")
                        .is_some_and(|n| self.styles.auto.contains_key(&("paragraph".to_owned(), n.to_owned())));
                    if auto {
                        self.restyle(el, &|_, _| {}, Some(name));
                    } else {
                        el.set_attr(&q(&self.p.text, "style-name"), ns::TEXT, name.clone());
                    }
                }
            } else {
                self.restyle(el, &change, parent.as_deref());
            }
            // Headings are `text:h` with their level.
            if parent.is_some() {
                match outline {
                    Some(level) => {
                        el.name = q(&self.p.text, "h");
                        el.set_attr(&q(&self.p.text, "outline-level"), ns::TEXT, level.to_string());
                    }
                    None if el.local() == "h" => {
                        el.name = q(&self.p.text, "p");
                        el.remove_attr(ns::TEXT, "outline-level");
                        el.remove_attr(ns::TEXT, "is-list-header");
                    }
                    None => {}
                }
            }
        }
    }

    fn structural_lists(&self) -> bool {
        true
    }

    fn list_splice(&mut self, id: u32, kind: &str) -> Option<Splice> {
        let path = tree::find_path(&self.body, id)?;
        let n = path.len();
        let in_list = n >= 3
            && matches!(tree::node_at(&self.body, &path[..n - 1]), Some(Node::Box(b)) if b.kind == BoxKind::ListItem)
            && matches!(tree::node_at(&self.body, &path[..n - 2]), Some(Node::Box(b)) if b.kind == BoxKind::List);
        let text = self.p.text.clone();
        match kind {
            "bullet" | "number" => {
                let style = self.list_style(kind == "bullet");
                if in_list {
                    let Some(Node::Box(list)) = tree::node_at(&self.body, &path[..n - 2]).cloned() else { return None };
                    let current = list.head.attr(ns::TEXT, "style-name").and_then(|s| self.styles.lists.get(s));
                    if current.is_some_and(|l| l.is_bullet() == (kind == "bullet")) {
                        return None;
                    }
                    let (parent, _) = self.parent_of(&path[..n - 1]);
                    let mut new = list.clone();
                    new.head.set_attr(&q(&text, "style-name"), ns::TEXT, style);
                    return Some(Splice {
                        parent,
                        index: path[n - 3],
                        remove: 1,
                        insert: vec![Node::Box(new)],
                    });
                }
                let (parent, parent_box) = self.parent_of(&path);
                let siblings: Vec<Node> = match parent_box {
                    Some(b) => b.items.clone(),
                    None => self.body.clone(),
                };
                let idx = path[n - 1];
                let para = siblings[idx].clone();
                let mut item = BoxNode {
                    id: self.ids.next(),
                    kind: BoxKind::ListItem,
                    head: Element::new(q(&text, "list-item"), ns::TEXT),
                    items: vec![para],
                };
                let same = |n: Option<&Node>| matches!(n, Some(Node::Box(b)) if b.kind == BoxKind::List && b.head.attr(ns::TEXT, "style-name") == Some(style.as_str()));
                if idx > 0 && same(siblings.get(idx - 1)) {
                    let Node::Box(mut list) = siblings[idx - 1].clone() else { unreachable!() };
                    list.items.push(Node::Box(item));
                    return Some(Splice {
                        parent,
                        index: idx - 1,
                        remove: 2,
                        insert: vec![Node::Box(list)],
                    });
                }
                if same(siblings.get(idx + 1)) {
                    let Node::Box(mut list) = siblings[idx + 1].clone() else { unreachable!() };
                    let first_item = list.items.iter().position(|n| matches!(n, Node::Box(_))).unwrap_or(0);
                    list.items.insert(first_item, Node::Box(item));
                    return Some(Splice {
                        parent,
                        index: idx,
                        remove: 2,
                        insert: vec![Node::Box(list)],
                    });
                }
                let mut head = Element::new(q(&text, "list"), ns::TEXT);
                head.set_attr(&q(&text, "style-name"), ns::TEXT, style);
                item.items.shrink_to_fit();
                let list = BoxNode {
                    id: self.ids.next(),
                    kind: BoxKind::List,
                    head,
                    items: vec![Node::Box(item)],
                };
                Some(Splice {
                    parent,
                    index: idx,
                    remove: 1,
                    insert: vec![Node::Box(list)],
                })
            }
            _ => {
                if !in_list {
                    return None;
                }
                let Some(Node::Box(list)) = tree::node_at(&self.body, &path[..n - 2]).cloned() else { return None };
                let (container, _) = self.parent_of(&path[..n - 2]);
                let item_at = path[n - 2];
                let para_at = path[n - 1];
                let Node::Box(item) = &list.items[item_at] else { return None };
                let para = item.items[para_at].clone();
                let mut before = list.clone();
                before.items.truncate(item_at);
                let before_rest: Vec<Node> = item.items[..para_at].to_vec();
                let after_rest: Vec<Node> = item.items[para_at + 1..].to_vec();
                if before_rest.iter().any(|n| !matches!(n, Node::Hidden(_))) {
                    let mut it = item.clone();
                    it.items = before_rest;
                    before.items.push(Node::Box(it));
                }
                let mut after = list.clone();
                after.items = Vec::new();
                if after_rest.iter().any(|n| !matches!(n, Node::Hidden(_))) {
                    let mut it = item.clone();
                    it.items = after_rest;
                    after.items.push(Node::Box(it));
                }
                after.items.extend(list.items[item_at + 1..].iter().cloned());
                let mut insert = Vec::new();
                let has_items = |l: &BoxNode| l.items.iter().any(|n| matches!(n, Node::Box(_)));
                if has_items(&before) {
                    insert.push(Node::Box(before));
                }
                insert.push(para);
                if has_items(&after) {
                    renew_box_ids(&mut after, &mut self.ids);
                    after.head.remove_attr(ns::XML, "id");
                    after.head.set_attr(&q(&text, "continue-numbering"), ns::TEXT, "true");
                    insert.push(Node::Box(after));
                }
                Some(Splice {
                    parent: container,
                    index: path[n - 3],
                    remove: 1,
                    insert,
                })
            }
        }
    }

    fn new_para(&self, like: Option<&Element>, style: Option<&str>) -> Element {
        let mut p = match like {
            Some(l) => {
                let mut e = l.clone();
                e.children.clear();
                e.attrs.retain(|a| !(a.ns == ns::XML && a.local() == "id") && !(a.ns == ns::TEXT && matches!(a.local(), "id" | "restart-numbering" | "start-value")));
                e
            }
            None => Element::new(q(&self.p.text, "p"), ns::TEXT),
        };
        if let Some(s) = style {
            let name = odf_name_for(s);
            p.set_attr(&q(&self.p.text, "style-name"), ns::TEXT, name);
            match self.styles.named.get(&("paragraph".to_owned(), name.to_owned())).and_then(|s| s.outline) {
                Some(level) => {
                    p.name = q(&self.p.text, "h");
                    p.set_attr(&q(&self.p.text, "outline-level"), ns::TEXT, level.to_string());
                }
                None => {
                    p.name = q(&self.p.text, "p");
                    p.remove_attr(ns::TEXT, "outline-level");
                }
            }
        }
        p
    }

    fn table_view(&self, table: &BoxNode, cells: &mut dyn FnMut(&[Node]) -> Vec<BlockView>) -> TableView {
        // Columns, with their repeat counts expanded.
        let mut col_widths = Vec::new();
        fn columns<'a>(items: impl Iterator<Item = &'a XmlNode>, out: &mut Vec<&'a Element>) {
            for n in items {
                let XmlNode::Element(e) = n else { continue };
                if is(e, ns::TABLE, "table-column") {
                    out.push(e);
                } else if e.ns == ns::TABLE && matches!(e.local(), "table-columns" | "table-header-columns" | "table-column-group") {
                    columns(e.children.iter(), out);
                }
            }
        }
        let mut cols = Vec::new();
        let hidden: Vec<&XmlNode> = table
            .items
            .iter()
            .filter_map(|n| match n {
                Node::Hidden(x) => Some(x),
                _ => None,
            })
            .collect();
        columns(hidden.into_iter(), &mut cols);
        for c in cols {
            let repeat = c.attr(ns::TABLE, "number-columns-repeated").and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).min(1024);
            let w = self.style_width("table-column", c.attr(ns::TABLE, "style-name"), "column-width").unwrap_or(0.0);
            col_widths.extend(std::iter::repeat_n(w, repeat));
        }
        let mut borders = false;
        let mut rows = Vec::new();
        let mut below: Vec<usize> = vec![0; col_widths.len().max(1)];
        let header_rows: Vec<u32> = table
            .items
            .iter()
            .filter_map(|n| match n {
                Node::Box(b) if b.kind == BoxKind::RowGroup && b.head.local() == "table-header-rows" => Some(b),
                _ => None,
            })
            .flat_map(|b| boxes_of(&b.items, BoxKind::Row).into_iter().map(|r| r.id))
            .collect();
        for row in boxes_of(&table.items, BoxKind::Row) {
            let mut out_cells = Vec::new();
            let mut g = 0usize;
            let mut skip = 0usize;
            for n in &row.items {
                let Node::Box(cell) = n else { continue };
                match cell.kind {
                    BoxKind::Cell => {
                        let span = cell.head.attr(ns::TABLE, "number-columns-spanned").and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).max(1);
                        let rspan = cell.head.attr(ns::TABLE, "number-rows-spanned").and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).max(1);
                        let style = cell.head.attr(ns::TABLE, "style-name").and_then(|s| self.styles.get("table-cell", s));
                        let props = style.and_then(|s| s.other.as_ref());
                        let fill = props.and_then(|p| p.attr(ns::FO, "background-color")).and_then(|v| v.strip_prefix('#')).and_then(|h| u32::from_str_radix(h, 16).ok());
                        if props.is_some_and(|p| p.attrs.iter().any(|a| a.ns == ns::FO && a.local().starts_with("border") && a.value != "none")) {
                            borders = true;
                        }
                        if below.len() < g + span {
                            below.resize(g + span, 0);
                        }
                        for b in &mut below[g..g + span] {
                            *b = rspan - 1;
                        }
                        out_cells.push(CellView {
                            blocks: cells(&cell.items),
                            col_span: span as u32,
                            merged_up: false,
                            row_span: rspan as u32,
                            fill,
                            width: col_widths.iter().skip(g).take(span).sum(),
                        });
                        g += span;
                        skip = span - 1;
                    }
                    BoxKind::CoveredCell => {
                        if skip > 0 {
                            skip -= 1;
                            continue;
                        }
                        if below.get(g).copied().unwrap_or(0) > 0 {
                            below[g] -= 1;
                            out_cells.push(CellView {
                                blocks: Vec::new(),
                                col_span: 1,
                                merged_up: true,
                                row_span: 1,
                                fill: None,
                                width: col_widths.get(g).copied().unwrap_or(0.0),
                            });
                        }
                        g += 1;
                    }
                    _ => {}
                }
            }
            rows.push(RowView {
                cells: out_cells,
                header: header_rows.contains(&row.id),
            });
        }
        TableView {
            id: table.id,
            rows,
            col_widths,
            borders,
        }
    }

    fn new_table(&mut self, rows: usize, cols: usize) -> Node {
        let rows = rows.clamp(1, 500);
        let cols = cols.clamp(1, 63);
        let mut taken = Vec::new();
        for p in boxes_in(&self.body) {
            if let Some(n) = p.head.attr(ns::TABLE, "name") {
                taken.push(n.to_owned());
            }
        }
        let name = (1..)
            .map(|i| format!("Table{i}"))
            .find(|n| !taken.contains(n) && !self.styles.auto.keys().any(|(_, x)| x == n))
            .unwrap();
        let width = (self.page.width - self.page.margin_left - self.page.margin_right).max(72.0);
        let col = width / cols as f32;
        self.add_auto(fragment(&format!(
            r#"<style:style style:name="{name}" style:family="table"><style:table-properties style:width="{}" table:align="margins"/></style:style>"#,
            inches(width)
        )));
        self.add_auto(fragment(&format!(
            r#"<style:style style:name="{name}.A" style:family="table-column"><style:table-column-properties style:column-width="{}"/></style:style>"#,
            inches(col)
        )));
        self.add_auto(fragment(&format!(
            r#"<style:style style:name="{name}.A1" style:family="table-cell"><style:table-cell-properties fo:padding="0.0382in" fo:border="0.5pt solid #000000"/></style:style>"#
        )));
        let mut xml = format!(r#"<table:table table:name="{name}" table:style-name="{name}"><table:table-column table:style-name="{name}.A" table:number-columns-repeated="{cols}"/>"#);
        for _ in 0..rows {
            xml.push_str("<table:table-row>");
            for _ in 0..cols {
                xml.push_str(&format!(r#"<table:table-cell table:style-name="{name}.A1" office:value-type="string"><text:p/></table:table-cell>"#));
            }
            xml.push_str("</table:table-row>");
        }
        xml.push_str("</table:table>");
        let mut tbl = fragment(&xml);
        if self.p.table != "table" || self.p.text != "text" || self.p.office != "office" {
            reprefix(&mut tbl, &self.p);
        }
        tree::build(vec![XmlNode::Element(tbl)], None, &mut self.ids, &classify).pop().expect("a table builds one node")
    }

    fn table_edit(&mut self, table: &BoxNode, op: TableOp) -> Result<BoxNode, WordError> {
        let mut t = table.clone();
        let row_at: Vec<usize> = t
            .items
            .iter()
            .enumerate()
            .filter(|(_, n)| matches!(n, Node::Box(b) if b.kind == BoxKind::Row))
            .map(|(i, _)| i)
            .collect();
        if row_at.len() != boxes_of(&t.items, BoxKind::Row).len() {
            return Err(WordError::Unsupported("This table has header rows or row groups and can't be changed here.".into()));
        }
        let merged = boxes_of(&table.items, BoxKind::Row).iter().any(|r| {
            r.items.iter().any(|c| match c {
                Node::Box(b) if b.kind == BoxKind::CoveredCell => true,
                Node::Box(b) => {
                    b.head.attr(ns::TABLE, "number-columns-spanned").is_some_and(|v| v != "1") || b.head.attr(ns::TABLE, "number-rows-spanned").is_some_and(|v| v != "1")
                }
                _ => false,
            })
        });
        if merged {
            return Err(WordError::Unsupported("This table has merged cells, so its rows and columns can't be changed here.".into()));
        }
        let cells_of = |row: &BoxNode| -> Vec<usize> {
            row.items
                .iter()
                .enumerate()
                .filter(|(_, n)| matches!(n, Node::Box(b) if b.kind == BoxKind::Cell))
                .map(|(i, _)| i)
                .collect()
        };
        match op {
            TableOp::InsertRow { at, below } => {
                let src = *row_at.get(at).ok_or_else(|| WordError::Invalid("There is no such row.".into()))?;
                let Node::Box(mut row) = t.items[src].clone() else { unreachable!() };
                row.id = self.ids.next();
                for n in &mut row.items {
                    if let Node::Box(cell) = n {
                        cell.id = self.ids.next();
                        self.blank_cell(cell);
                    }
                }
                t.items.insert(if below { src + 1 } else { src }, Node::Box(row));
            }
            TableOp::DeleteRow { at } => {
                if row_at.len() <= 1 {
                    return Err(WordError::Invalid("A table needs a row. Delete the table instead.".into()));
                }
                let src = *row_at.get(at).ok_or_else(|| WordError::Invalid("There is no such row.".into()))?;
                t.items.remove(src);
            }
            TableOp::InsertCol { at, right } => {
                expand_columns(&mut t, &self.p);
                let col_at: Vec<usize> = t
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| matches!(n, Node::Hidden(XmlNode::Element(e)) if is(e, ns::TABLE, "table-column")))
                    .map(|(i, _)| i)
                    .collect();
                if let Some(&ci) = col_at.get(at).or(col_at.last()) {
                    let copy = t.items[ci].clone();
                    t.items.insert(if right { ci + 1 } else { ci }, copy);
                }
                let row_at = rows_in(&t);
                for &ri in &row_at {
                    let Node::Box(row) = &mut t.items[ri] else { continue };
                    let cells = cells_of(row);
                    let Some(&ci) = cells.get(at).or(cells.last()) else { continue };
                    let Node::Box(mut copy) = row.items[ci].clone() else { continue };
                    copy.id = self.ids.next();
                    self.blank_cell(&mut copy);
                    row.items.insert(if right { ci + 1 } else { ci }, Node::Box(copy));
                }
            }
            TableOp::DeleteCol { at } => {
                expand_columns(&mut t, &self.p);
                let row_at = rows_in(&t);
                for &ri in &row_at {
                    let Node::Box(row) = &mut t.items[ri] else { continue };
                    let cells = cells_of(row);
                    if cells.len() <= 1 {
                        return Err(WordError::Invalid("A table needs a column. Delete the table instead.".into()));
                    }
                    if let Some(&ci) = cells.get(at) {
                        row.items.remove(ci);
                    }
                }
                let col_at: Vec<usize> = t
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| matches!(n, Node::Hidden(XmlNode::Element(e)) if is(e, ns::TABLE, "table-column")))
                    .map(|(i, _)| i)
                    .collect();
                if let Some(&ci) = col_at.get(at) {
                    t.items.remove(ci);
                }
            }
        }
        Ok(t)
    }

    fn page_break_para(&mut self) -> Element {
        // ODF breaks pages through a paragraph style.
        if !self.styles.auto.contains_key(&("paragraph".to_owned(), "DocHelperPageBreak".to_owned())) {
            self.add_auto(fragment(
                r#"<style:style style:name="DocHelperPageBreak" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:break-before="page"/></style:style>"#,
            ));
        }
        let mut p = Element::new(q(&self.p.text, "p"), ns::TEXT);
        p.set_attr(&q(&self.p.text, "style-name"), ns::TEXT, "DocHelperPageBreak");
        p
    }

    fn page_setup(&self) -> PageSetup {
        self.page.clone()
    }

    fn styles(&self) -> Vec<StyleInfo> {
        let mut out: Vec<StyleInfo> = Vec::new();
        for ((family, name), st) in &self.styles.named {
            if family != "paragraph" {
                continue;
            }
            let offered = OFFERED.iter().any(|(n, _, _)| n == name);
            let common = matches!(name.as_str(), "Standard" | "Text_20_body" | "Title" | "Subtitle" | "Quotations" | "List" | "Table_20_Contents");
            if !offered && !common && st.outline.is_none() {
                continue;
            }
            out.push(StyleInfo {
                id: name.clone(),
                name: if name == "Standard" { "Default Paragraph Style".into() } else { st.display.clone() },
                outline: st.outline.map(|o| o.saturating_sub(1)),
                defined: true,
            });
        }
        for (id, name, outline) in OFFERED {
            if !out.iter().any(|s| s.id == *id) {
                out.push(StyleInfo {
                    id: (*id).to_owned(),
                    name: (*name).to_owned(),
                    outline: *outline,
                    defined: false,
                });
            }
        }
        let rank = |s: &StyleInfo| -> (u8, u8, String) {
            let r = match s.id.as_str() {
                "Standard" => 0,
                "Text_20_body" => 1,
                "Title" => 2,
                "Subtitle" => 3,
                _ if s.outline.is_some() => 4,
                _ => 5,
            };
            (r, s.outline.unwrap_or(9), s.name.to_lowercase())
        };
        out.sort_by_key(rank);
        out
    }

    fn ensure_style(&mut self, id: &str) {
        let name = odf_name_for(id).to_owned();
        self.ensure_named(&name);
    }

    fn image(&self, obj: &StoredObject) -> Option<(Vec<u8>, String)> {
        let href = para::image_href(&obj.nodes)?;
        let bytes = self.pkg.read(&href).ok()?;
        let ext = href.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
        Some((bytes, ext))
    }

    fn image_nodes(&mut self, bytes: &[u8], ext: &str, width: f32, height: f32) -> Result<Vec<XmlNode>, WordError> {
        let ext = ext.trim_start_matches('.').to_ascii_lowercase();
        let media = match ext.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            _ => return Err(WordError::Unsupported("Pictures must be PNG, JPEG, GIF or BMP.".into())),
        };
        let part = self.pkg.unused_name(&format!("Pictures/image{{}}.{ext}"));
        self.pkg.set(&part, bytes.to_vec());
        if let Some(m) = &mut self.manifest {
            let prefix = m.prefix_for(ns::MANIFEST).unwrap_or_else(|| "manifest".into());
            let mut e = Element::new(q(&prefix, "file-entry"), ns::MANIFEST);
            e.set_attr(&q(&prefix, "full-path"), ns::MANIFEST, part.clone());
            e.set_attr(&q(&prefix, "media-type"), ns::MANIFEST, media);
            m.root.push(e);
            self.manifest_changed = true;
        }
        let n = self.ids.next();
        let xml = format!(
            r#"<draw:frame draw:name="Picture{n}" text:anchor-type="as-char" svg:width="{}" svg:height="{}" draw:z-index="0"><draw:image xlink:href="{part}" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad" draw:mime-type="{media}"/></draw:frame>"#,
            inches(width.max(1.0)),
            inches(height.max(1.0))
        );
        let mut frame = fragment(&xml);
        frame.attrs.retain(|a| a.ns != ns::XMLNS);
        Ok(vec![XmlNode::Element(frame)])
    }

    fn save(&mut self) -> Result<Vec<u8>, WordError> {
        if self.body_changed || !self.made.is_empty() {
            let mut doc = self.content.clone();
            let [b, t] = [self.text_path[0], self.text_path[1]];
            let body = doc.root.children[b].as_element_mut().unwrap();
            body.children[t].as_element_mut().unwrap().children = tree::flatten(&self.body);
            self.pkg.set_xml(CONTENT, &doc);
        }
        if self.styles_changed {
            if let Some(d) = &self.styles_doc {
                self.pkg.set_xml(STYLES, d);
            }
        }
        if self.manifest_changed {
            if let Some(m) = &self.manifest {
                self.pkg.set_xml(MANIFEST, m);
            }
        }
        Ok(self.pkg.save()?)
    }
}

/// Every box in the body, depth first.
fn boxes_in(items: &[Node]) -> Vec<&BoxNode> {
    let mut out = Vec::new();
    for n in items {
        if let Node::Box(b) = n {
            out.push(b);
            out.extend(boxes_in(&b.items));
        }
    }
    out
}

/// New ids for the containers in a copied box; paragraphs keep theirs
/// (they move rather than repeat).
fn renew_box_ids(b: &mut BoxNode, ids: &mut Ids) {
    b.id = ids.next();
    for n in &mut b.items {
        if let Node::Box(c) = n {
            renew_box_ids(c, ids);
        }
    }
}

/// Where a table's rows are among its children.
fn rows_in(t: &BoxNode) -> Vec<usize> {
    t.items
        .iter()
        .enumerate()
        .filter(|(_, n)| matches!(n, Node::Box(b) if b.kind == BoxKind::Row))
        .map(|(i, _)| i)
        .collect()
}

/// Spell out repeated column elements, one per column.
fn expand_columns(t: &mut BoxNode, p: &Prefixes) {
    let mut out = Vec::new();
    for n in std::mem::take(&mut t.items) {
        match n {
            Node::Hidden(XmlNode::Element(e)) if is(&e, ns::TABLE, "table-column") => {
                let repeat = e.attr(ns::TABLE, "number-columns-repeated").and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).min(1024);
                let mut one = e.clone();
                one.remove_attr(ns::TABLE, "number-columns-repeated");
                for _ in 0..repeat {
                    out.push(Node::Hidden(XmlNode::Element(one.clone())));
                }
            }
            other => out.push(other),
        }
    }
    let _ = p;
    t.items = out;
}

fn reprefix(e: &mut Element, p: &Prefixes) {
    let map = |name: &str| -> Option<String> {
        let (prefix, local) = name.split_once(':')?;
        let to = match prefix {
            "table" => &p.table,
            "text" => &p.text,
            "office" => &p.office,
            "style" => &p.style,
            "fo" => &p.fo,
            _ => return None,
        };
        Some(q(to, local))
    };
    if let Some(n) = map(&e.name) {
        e.name = n;
    }
    for a in &mut e.attrs {
        if let Some(n) = map(&a.name) {
            a.name = n;
        }
    }
    for c in e.elements_mut() {
        reprefix(c, p);
    }
}

/// A small OpenDocument text with the given body XML, for tests and new
/// documents.
pub fn bytes_with_body(body: &str) -> Vec<u8> {
    use doc_zip::{Compression, ZipWriter};
    let content = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><office:document-content {NS_DECLS} office:version="1.3"><office:font-face-decls/><office:automatic-styles/><office:body><office:text>{body}</office:text></office:body></office:document-content>"#
    );
    let styles = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><office:document-styles {NS_DECLS} office:version="1.3"><office:styles><style:default-style style:family="paragraph"><style:text-properties fo:font-size="12pt"/></style:default-style>{}</office:styles><office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="8.2681in" fo:page-height="11.6929in" fo:margin-top="0.7874in" fo:margin-bottom="0.7874in" fo:margin-left="0.7874in" fo:margin-right="0.7874in"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"/></office:master-styles></office:document-styles>"#,
        builtin_style("Standard").unwrap()
    );
    let manifest = r#"<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/></manifest:manifest>"#;
    let mut z = ZipWriter::new();
    z.add("mimetype", b"application/vnd.oasis.opendocument.text", Compression::Stored).unwrap();
    z.add(CONTENT, content.as_bytes(), Compression::DEFAULT).unwrap();
    z.add(STYLES, styles.as_bytes(), Compression::DEFAULT).unwrap();
    z.add(MANIFEST, manifest.as_bytes(), Compression::DEFAULT).unwrap();
    z.finish()
}
