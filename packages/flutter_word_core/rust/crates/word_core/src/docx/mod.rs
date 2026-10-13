//! Word documents (`.docx`, `.docm`, `.dotx`): read into a body tree,
//! edited paragraph by paragraph, and written back in place. Parts this
//! engine does not edit (headers, footers, comments, media, macros) are
//! copied as they were.

pub mod builtin;
pub mod numbering;
pub mod para;
pub mod styles;

use std::cell::RefCell;
use std::collections::HashMap;

use doc_opc::{dir_of, rel, Package, Rels};
use doc_xml::{ns, Document, Element, Node as XmlNode};
use doc_zip::{Compression, ZipWriter};

use crate::backend::{Backend, Format, StyleInfo, TableOp};
use crate::error::WordError;
use crate::projected::{Objects, Projected, RebuildInput, StoredObject};
use crate::tree::{self, BoxKind, BoxNode, Class, Ids, Node, Para};
use crate::view::{
    BlockView, CellView, InlineEdit, ListLabel, PageSetup, ParaPatch, RowView, TableView,
};
use numbering::{Counters, Numbering};
use para::{PatchCtx, ReadCtx, WriteCtx};
use styles::{StyleSheet, ThemeFonts};

const NUMBERING_TYPE: &str =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml";
const STYLES_TYPE: &str =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml";

/// A Word document being edited.
pub struct Docx {
    pkg: Package,
    format: Format,
    main: String,
    /// `document.xml` with the body's children taken out (they live in
    /// `body`).
    doc: Document,
    body_at: usize,
    body: Vec<Node>,
    body_changed: bool,
    ids: Ids,
    /// The prefix bound to the main namespace (`w`).
    w: String,
    rels: Rels,
    rels_changed: bool,
    /// Hyperlink relationship ids and their URLs.
    links: HashMap<String, String>,
    sheet: StyleSheet,
    styles_doc: Option<Document>,
    styles_part: Option<String>,
    styles_changed: bool,
    numbering: Numbering,
    numbering_part: Option<String>,
    numbering_changed: bool,
}

fn is_w(e: &Element, local: &str) -> bool {
    e.ns == ns::W && e.local() == local
}

fn q(w: &str, local: &str) -> String {
    if w.is_empty() {
        local.to_owned()
    } else {
        format!("{w}:{local}")
    }
}

/// How body-level elements become nodes.
fn classify(e: &Element, _parent: Option<BoxKind>) -> Class {
    if e.ns != ns::W {
        return if e.text().trim().is_empty() {
            Class::Hidden
        } else {
            Class::Raw
        };
    }
    match e.local() {
        "p" => Class::Para,
        "tbl" => Class::Box(BoxKind::Table),
        "tr" => Class::Box(BoxKind::Row),
        "tc" => Class::Box(BoxKind::Cell),
        "sdt" | "customXml" => Class::Box(BoxKind::Control),
        "sdtContent" => Class::Box(BoxKind::ControlContent),
        "altChunk" => Class::Raw,
        _ => {
            if e.text().trim().is_empty() {
                Class::Hidden
            } else {
                Class::Raw
            }
        }
    }
}

/// Parse a fragment written with the `w:` prefix, renaming it to `w`.
fn fragment(xml: &str, w: &str) -> Element {
    let wrapped = format!(
        r#"<x xmlns:w="{}" xmlns:r="{}">{xml}</x>"#,
        builtin::W_URI,
        builtin::R_URI
    );
    let doc = Document::parse_str(&wrapped).expect("built-in XML parses");
    let mut e = doc
        .root
        .elements()
        .next()
        .expect("a fragment has an element")
        .clone();
    if w != "w" {
        reprefix(&mut e, w);
    }
    e
}

fn reprefix(e: &mut Element, to: &str) {
    let rename = |name: &str| -> Option<String> {
        let local = name.strip_prefix("w:")?;
        Some(q(to, local))
    };
    if let Some(n) = rename(&e.name) {
        e.name = n;
    }
    for a in &mut e.attrs {
        if let Some(n) = rename(&a.name) {
            a.name = n;
        }
    }
    for c in e.elements_mut() {
        reprefix(c, to);
    }
}

fn hidden_el<'a>(items: &'a [Node], local: &str) -> Option<&'a Element> {
    items.iter().find_map(|n| match n {
        Node::Hidden(XmlNode::Element(e)) if is_w(e, local) => Some(e),
        _ => None,
    })
}

fn hidden_el_mut<'a>(items: &'a mut [Node], local: &str) -> Option<&'a mut Element> {
    items.iter_mut().find_map(|n| match n {
        Node::Hidden(XmlNode::Element(e)) if is_w(e, local) => Some(e),
        _ => None,
    })
}

/// Boxes of a kind, looking through content controls.
fn boxes_of(items: &[Node], kind: BoxKind) -> Vec<&BoxNode> {
    let mut out = Vec::new();
    for n in items {
        if let Node::Box(b) = n {
            if b.kind == kind {
                out.push(b);
            } else if matches!(b.kind, BoxKind::Control | BoxKind::ControlContent) {
                out.extend(boxes_of(&b.items, kind));
            }
        }
    }
    out
}

fn hex(v: &str) -> Option<u32> {
    if v.len() == 6 {
        u32::from_str_radix(v, 16).ok()
    } else {
        None
    }
}

fn twips_attr(e: &Element, local: &str) -> Option<f32> {
    e.attr(ns::W, local)
        .and_then(|v| v.parse::<f32>().ok())
        .map(|v| v / 20.0)
}

/// Give a copied node new ids throughout.
fn renew_ids(n: &mut Node, ids: &mut Ids) {
    match n {
        Node::Para(p) => p.id = ids.next(),
        Node::Raw { id, .. } => *id = ids.next(),
        Node::Box(b) => {
            b.id = ids.next();
            for c in &mut b.items {
                renew_ids(c, ids);
            }
        }
        Node::Hidden(_) => {}
    }
}

/// Today as the W3C date-time Office writes.
fn now_w3c() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs()) as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem / 60 % 60,
        rem % 60
    )
}

/// The bytes of a new, empty Word document.
pub fn blank_bytes() -> Vec<u8> {
    let mut z = ZipWriter::new();
    let parts: [(&str, String); 7] = [
        ("[Content_Types].xml", builtin::CONTENT_TYPES.into()),
        ("_rels/.rels", builtin::ROOT_RELS.into()),
        ("docProps/core.xml", builtin::core(&now_w3c())),
        ("docProps/app.xml", builtin::APP.into()),
        ("word/document.xml", builtin::DOCUMENT.into()),
        (
            "word/_rels/document.xml.rels",
            builtin::DOCUMENT_RELS.into(),
        ),
        ("word/styles.xml", builtin::STYLES.into()),
    ];
    for (name, text) in parts {
        z.add(name, text.as_bytes(), Compression::DEFAULT)
            .expect("names are unique");
    }
    z.add(
        "word/settings.xml",
        builtin::SETTINGS.as_bytes(),
        Compression::DEFAULT,
    )
    .expect("names are unique");
    z.finish()
}

impl Docx {
    pub fn open(bytes: Vec<u8>, format: Format) -> Result<Docx, WordError> {
        let pkg = Package::open(bytes)?;
        let main = pkg.main_part()?;
        let mut doc = pkg.read_xml(&main)?;
        if !doc.root.is(ns::W, "document") {
            return Err(WordError::Unsupported(
                "This package is not a Word document.".into(),
            ));
        }
        let w = doc.prefix_for(ns::W).unwrap_or_else(|| "w".into());
        // New links and images name relationships with `r:`.
        if doc.prefix_for(ns::R).as_deref() != Some("r") && doc.root.attr_named("xmlns:r").is_none()
        {
            doc.root.set_attr("xmlns:r", ns::XMLNS, builtin::R_URI);
        }
        let body_at = doc
            .root
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| is_w(e, "body")))
            .ok_or_else(|| WordError::Corrupt("This document has no body.".into()))?;
        let kids = std::mem::take(
            &mut doc.root.children[body_at]
                .as_element_mut()
                .unwrap()
                .children,
        );
        let mut ids = Ids::default();
        let body = tree::build(kids, None, &mut ids, &classify);

        let rels = pkg.rels(&main)?;
        let links = rels
            .of_kind(rel::HYPERLINK)
            .into_iter()
            .map(|r| (r.id, r.target))
            .collect();
        let theme = rels
            .first_part(rel::THEME)
            .and_then(|p| pkg.read_xml(&p).ok())
            .map(|d| ThemeFonts::read(&d))
            .unwrap_or_default();
        let styles_part = rels.first_part(rel::STYLES).filter(|p| pkg.exists(p));
        let styles_doc = styles_part.as_ref().and_then(|p| pkg.read_xml(p).ok());
        let sheet = match &styles_doc {
            Some(d) => StyleSheet::read(d, theme),
            None => {
                let mut s = StyleSheet::default();
                s.theme = theme;
                s
            }
        };
        let numbering_part = rels.first_part(rel::NUMBERING).filter(|p| pkg.exists(p));
        let numbering = numbering_part
            .as_ref()
            .and_then(|p| pkg.read_xml(p).ok())
            .map(Numbering::read)
            .unwrap_or_default();
        Ok(Docx {
            pkg,
            format,
            main,
            doc,
            body_at,
            body,
            body_changed: false,
            ids,
            w,
            rels,
            rels_changed: false,
            links,
            sheet,
            styles_doc,
            styles_part,
            styles_changed: false,
            numbering,
            numbering_part,
            numbering_changed: false,
        })
    }

    pub fn blank() -> Docx {
        Docx::open(blank_bytes(), Format::Docx).expect("the blank document reads")
    }

    pub fn styles_sheet(&self) -> &StyleSheet {
        &self.sheet
    }

    /// The last section's properties (the document's page setup).
    fn section(&self) -> Option<&Element> {
        self.body.iter().rev().find_map(|n| match n {
            Node::Hidden(XmlNode::Element(e)) if is_w(e, "sectPr") => Some(e),
            _ => None,
        })
    }

    fn style_outline(&self, id: &str) -> Option<u8> {
        let mut ppr = Element::new(q(&self.w, "pPr"), ns::W);
        ppr.push(styles::wel(&self.w, "pStyle", Some(id)));
        self.sheet.para_style(Some(&ppr)).outline_level
    }

    fn part_in_main_dir(&self, name: &str) -> String {
        let dir = dir_of(&self.main);
        if dir.is_empty() {
            name.to_owned()
        } else {
            format!("{dir}/{name}")
        }
    }

    /// Clear a copied cell: its properties stay, its content becomes one
    /// empty paragraph like its first.
    fn blank_cell(&mut self, cell: &mut BoxNode) {
        let like = tree::paragraphs(&cell.items).first().map(|p| p.el.clone());
        cell.items.retain(|n| matches!(n, Node::Hidden(_)));
        if let Some(tc_pr) = hidden_el_mut(&mut cell.items, "tcPr") {
            styles::remove_child(tc_pr, "vMerge");
        }
        let p = self.new_para(like.as_ref(), None);
        let id = self.ids.next();
        cell.items.push(Node::Para(Para { id, el: p }));
    }
}

impl Backend for Docx {
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

    fn project(&self, para: &Para, objects: &mut Objects) -> Projected {
        let ctx = ReadCtx {
            styles: &self.sheet,
            links: &self.links,
        };
        para::project(&para.el, para.id, &ctx, objects, &self.w)
    }

    fn list_labels(&self) -> HashMap<u32, ListLabel> {
        let mut out = HashMap::new();
        if self.numbering.nums.is_empty() {
            return out;
        }
        let mut counters = Counters::default();
        for p in tree::paragraphs(&self.body) {
            let ppr = p.el.elements().find(|c| is_w(c, "pPr"));
            let Some((num, level)) = self.sheet.numbering(ppr) else {
                continue;
            };
            let mark = self.sheet.para_style(ppr).mark;
            if let Some(label) =
                counters.next(&self.numbering, &num, level, &mark, &self.sheet.theme)
            {
                out.insert(p.id, label);
            }
        }
        out
    }

    fn rebuild(
        &mut self,
        base: &Element,
        input: &RebuildInput,
        inlines: &[InlineEdit],
        objects: &Objects,
    ) -> Element {
        let mut added = false;
        let el = {
            let rels = &mut self.rels;
            let links = &mut self.links;
            let mut add_link = |url: &str| {
                let id = rels.add_external(&rel::uri(rel::HYPERLINK), url);
                links.insert(id.clone(), url.to_owned());
                added = true;
                id
            };
            let mut ctx = WriteCtx {
                styles: &self.sheet,
                w: &self.w,
                add_link: &mut add_link,
            };
            para::rebuild(base, input, inlines, objects, &mut ctx)
        };
        if added {
            self.rels_changed = true;
        }
        el
    }

    fn patch(&mut self, paras: &mut [Element], prev: Option<&Element>, patch: &ParaPatch) {
        if let Some(s) = &patch.style_id {
            self.ensure_style(s);
        }
        let prev_list =
            prev.and_then(|p| self.sheet.numbering(p.elements().find(|c| is_w(c, "pPr"))));
        let numbering = RefCell::new(std::mem::take(&mut self.numbering));
        let before = numbering.borrow().nums.len();
        let chosen: RefCell<Option<String>> = RefCell::new(None);
        let w = self.w.clone();
        {
            let mut list_for = |bullet: bool| -> String {
                if let Some(c) = chosen.borrow().clone() {
                    return c;
                }
                let mut n = numbering.borrow_mut();
                let id = match &prev_list {
                    Some((id, _)) if n.is_bullet(id) == bullet => id.clone(),
                    _ if bullet => n.list_for(true, &w),
                    // A new numbered list starts at 1.
                    _ => n.add_list(false, &w),
                };
                *chosen.borrow_mut() = Some(id.clone());
                id
            };
            let is_bullet = |id: &str| numbering.borrow().is_bullet(id);
            let mut ctx = PatchCtx {
                styles: &self.sheet,
                w: &self.w,
                list_for: &mut list_for,
                is_bullet: &is_bullet,
            };
            for p in paras.iter_mut() {
                para::patch(p, patch, &mut ctx);
            }
        }
        self.numbering = numbering.into_inner();
        if self.numbering.nums.len() != before {
            self.numbering_changed = true;
        }
    }

    fn new_para(&self, like: Option<&Element>, style: Option<&str>) -> Element {
        para::new_para(like, style, &self.sheet, &self.w)
    }

    fn take_section(&self, para: &mut Element) -> Option<XmlNode> {
        let ppr = para.elements_mut().find(|c| is_w(c, "pPr"))?;
        let at = ppr
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| is_w(e, "sectPr")))?;
        Some(ppr.children.remove(at))
    }

    fn put_section(&self, para: &mut Element, section: XmlNode) {
        let at = match para
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| is_w(e, "pPr")))
        {
            Some(i) => i,
            None => {
                para.children
                    .insert(0, XmlNode::Element(Element::new(q(&self.w, "pPr"), ns::W)));
                0
            }
        };
        if let (Some(ppr), XmlNode::Element(s)) = (para.children[at].as_element_mut(), section) {
            styles::put_ordered(ppr, s, styles::PPR_ORDER);
        }
    }

    fn table_view(
        &self,
        table: &BoxNode,
        cells: &mut dyn FnMut(&[Node]) -> Vec<BlockView>,
    ) -> TableView {
        let tbl_pr = hidden_el(&table.items, "tblPr");
        let col_widths: Vec<f32> = hidden_el(&table.items, "tblGrid")
            .map(|g| {
                g.elements()
                    .filter(|c| is_w(c, "gridCol"))
                    .map(|c| twips_attr(c, "w").unwrap_or(0.0))
                    .collect()
            })
            .unwrap_or_default();
        let draws = |b: &Element| {
            b.elements()
                .any(|x| !matches!(x.attr(ns::W, "val"), Some("none") | Some("nil")))
        };
        let mut borders = tbl_pr
            .and_then(|p| p.elements().find(|c| is_w(c, "tblBorders")))
            .is_some_and(draws);
        if !borders {
            if let Some(style) = tbl_pr
                .and_then(|p| p.elements().find(|c| is_w(c, "tblStyle")))
                .and_then(styles::wval)
            {
                borders = self.sheet.chain(style).iter().any(|s| s.borders);
            }
        }
        let mut rows = Vec::new();
        // (row, cell index, grid column, merged up)
        let mut grid: Vec<Vec<(usize, bool)>> = Vec::new();
        for row in boxes_of(&table.items, BoxKind::Row) {
            let tr_pr = hidden_el(&row.items, "trPr");
            let header = tr_pr.is_some_and(|p| {
                p.elements()
                    .any(|c| is_w(c, "tblHeader") && styles::wval(c) != Some("0"))
            });
            let mut g = tr_pr
                .and_then(|p| p.elements().find(|c| is_w(c, "gridBefore")))
                .and_then(styles::wval)
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(0);
            let mut out_cells = Vec::new();
            let mut row_grid = Vec::new();
            for cell in boxes_of(&row.items, BoxKind::Cell) {
                let tc_pr = hidden_el(&cell.items, "tcPr");
                let get = |local: &str| tc_pr.and_then(|p| p.elements().find(|c| is_w(c, local)));
                let span = get("gridSpan")
                    .and_then(styles::wval)
                    .and_then(|v| v.parse::<u32>().ok())
                    .unwrap_or(1)
                    .max(1);
                let merged_up = get("vMerge").is_some_and(|m| styles::wval(m) != Some("restart"));
                let fill = get("shd").and_then(|s| s.attr(ns::W, "fill")).and_then(hex);
                let width = match get("tcW") {
                    Some(t) if t.attr(ns::W, "type").is_none_or(|ty| ty == "dxa") => {
                        twips_attr(t, "w").unwrap_or(0.0)
                    }
                    _ => col_widths.iter().skip(g).take(span as usize).sum(),
                };
                if get("tcBorders").is_some_and(draws) {
                    borders = true;
                }
                out_cells.push(CellView {
                    blocks: cells(&cell.items),
                    col_span: span,
                    merged_up,
                    row_span: 1,
                    fill,
                    width,
                });
                row_grid.push((g, merged_up));
                g += span as usize;
            }
            grid.push(row_grid);
            rows.push(RowView {
                cells: out_cells,
                header,
            });
        }
        // Vertical merges: a starting cell spans the continuing cells below.
        for r in 0..rows.len() {
            for c in 0..rows[r].cells.len() {
                let (g, merged) = grid[r][c];
                if merged {
                    continue;
                }
                let mut span = 1;
                for below in grid.iter().skip(r + 1) {
                    if below.iter().any(|(bg, m)| *bg == g && *m) {
                        span += 1;
                    } else {
                        break;
                    }
                }
                rows[r].cells[c].row_span = span;
            }
        }
        TableView {
            id: table.id,
            rows,
            col_widths,
            borders,
        }
    }

    fn new_table(&mut self, rows: usize, cols: usize) -> Node {
        self.ensure_style("TableGrid");
        let page = self.page_setup();
        let rows = rows.clamp(1, 500);
        let cols = cols.clamp(1, 63);
        let text_width =
            ((page.width - page.margin_left - page.margin_right).max(72.0) * 20.0) as i64;
        let col = text_width / cols as i64;
        let mut xml = String::from(
            r#"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr><w:tblGrid>"#,
        );
        for _ in 0..cols {
            xml.push_str(&format!(r#"<w:gridCol w:w="{col}"/>"#));
        }
        xml.push_str("</w:tblGrid>");
        for _ in 0..rows {
            xml.push_str("<w:tr>");
            for _ in 0..cols {
                xml.push_str(&format!(
                    r#"<w:tc><w:tcPr><w:tcW w:w="{col}" w:type="dxa"/></w:tcPr><w:p><w:pPr><w:spacing w:after="0"/></w:pPr></w:p></w:tc>"#
                ));
            }
            xml.push_str("</w:tr>");
        }
        xml.push_str("</w:tbl>");
        let tbl = fragment(&xml, &self.w);
        tree::build(vec![XmlNode::Element(tbl)], None, &mut self.ids, &classify)
            .pop()
            .expect("a table builds one node")
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
            return Err(WordError::Unsupported(
                "This table has rows inside content controls and can't be changed here.".into(),
            ));
        }
        let merged = || {
            boxes_of(&table.items, BoxKind::Row).iter().any(|r| {
                boxes_of(&r.items, BoxKind::Cell).iter().any(|c| {
                    hidden_el(&c.items, "tcPr").is_some_and(|p| {
                        p.elements().any(|e| {
                            (is_w(e, "gridSpan") && styles::wval(e).is_some_and(|v| v != "1"))
                                || is_w(e, "vMerge")
                                || is_w(e, "hMerge")
                        })
                    })
                }) || hidden_el(&r.items, "trPr").is_some_and(|p| {
                    p.elements()
                        .any(|e| is_w(e, "gridBefore") || is_w(e, "gridAfter"))
                })
            })
        };
        match op {
            TableOp::InsertRow { at, below } => {
                let src = *row_at
                    .get(at)
                    .ok_or_else(|| WordError::Invalid("There is no such row.".into()))?;
                let Node::Box(mut row) = t.items[src].clone() else {
                    unreachable!()
                };
                row.id = self.ids.next();
                let mut kids = std::mem::take(&mut row.items);
                for n in &mut kids {
                    if let Node::Box(cell) = n {
                        if cell.kind == BoxKind::Cell {
                            cell.id = self.ids.next();
                            self.blank_cell(cell);
                        } else {
                            renew_ids(n, &mut self.ids);
                        }
                    }
                }
                row.items = kids;
                t.items
                    .insert(if below { src + 1 } else { src }, Node::Box(row));
            }
            TableOp::DeleteRow { at } => {
                if row_at.len() <= 1 {
                    return Err(WordError::Invalid(
                        "A table needs a row. Delete the table instead.".into(),
                    ));
                }
                let src = *row_at
                    .get(at)
                    .ok_or_else(|| WordError::Invalid("There is no such row.".into()))?;
                t.items.remove(src);
            }
            TableOp::InsertCol { at, right } => {
                if merged() {
                    return Err(WordError::Unsupported(
                        "This table has merged cells, so columns can't be added here.".into(),
                    ));
                }
                if let Some(grid) = hidden_el_mut(&mut t.items, "tblGrid") {
                    let cols: Vec<usize> = grid
                        .children
                        .iter()
                        .enumerate()
                        .filter(|(_, n)| n.as_element().is_some_and(|e| is_w(e, "gridCol")))
                        .map(|(i, _)| i)
                        .collect();
                    if let Some(&ci) = cols.get(at).or(cols.last()) {
                        let col = grid.children[ci].as_element_mut().unwrap();
                        let half = (twips_attr(col, "w").unwrap_or(72.0) * 10.0).round() as i64;
                        col.set_attr(&q(&self.w, "w"), ns::W, half.to_string());
                        let copy = col.clone();
                        grid.children
                            .insert(if right { ci + 1 } else { ci }, XmlNode::Element(copy));
                    }
                }
                for &ri in &row_at {
                    let Node::Box(row) = &mut t.items[ri] else {
                        continue;
                    };
                    let cell_at: Vec<usize> = row
                        .items
                        .iter()
                        .enumerate()
                        .filter(|(_, n)| matches!(n, Node::Box(b) if b.kind == BoxKind::Cell))
                        .map(|(i, _)| i)
                        .collect();
                    let Some(&ci) = cell_at.get(at).or(cell_at.last()) else {
                        continue;
                    };
                    if let Node::Box(cell) = &mut row.items[ci] {
                        if let Some(tc_w) = hidden_el_mut(&mut cell.items, "tcPr")
                            .and_then(|p| p.child_mut(ns::W, "tcW"))
                        {
                            if tc_w.attr(ns::W, "type").is_none_or(|t| t == "dxa") {
                                let half =
                                    (twips_attr(tc_w, "w").unwrap_or(72.0) * 10.0).round() as i64;
                                tc_w.set_attr(&q(&self.w, "w"), ns::W, half.to_string());
                            }
                        }
                    }
                    let Node::Box(mut copy) = row.items[ci].clone() else {
                        continue;
                    };
                    copy.id = self.ids.next();
                    self.blank_cell(&mut copy);
                    row.items
                        .insert(if right { ci + 1 } else { ci }, Node::Box(copy));
                }
            }
            TableOp::DeleteCol { at } => {
                if merged() {
                    return Err(WordError::Unsupported(
                        "This table has merged cells, so columns can't be removed here.".into(),
                    ));
                }
                let mut removed_any = false;
                for &ri in &row_at {
                    let Node::Box(row) = &mut t.items[ri] else {
                        continue;
                    };
                    let cell_at: Vec<usize> = row
                        .items
                        .iter()
                        .enumerate()
                        .filter(|(_, n)| matches!(n, Node::Box(b) if b.kind == BoxKind::Cell))
                        .map(|(i, _)| i)
                        .collect();
                    if cell_at.len() <= 1 {
                        return Err(WordError::Invalid(
                            "A table needs a column. Delete the table instead.".into(),
                        ));
                    }
                    if let Some(&ci) = cell_at.get(at) {
                        row.items.remove(ci);
                        removed_any = true;
                    }
                }
                if !removed_any {
                    return Err(WordError::Invalid("There is no such column.".into()));
                }
                if let Some(grid) = hidden_el_mut(&mut t.items, "tblGrid") {
                    let cols: Vec<usize> = grid
                        .children
                        .iter()
                        .enumerate()
                        .filter(|(_, n)| n.as_element().is_some_and(|e| is_w(e, "gridCol")))
                        .map(|(i, _)| i)
                        .collect();
                    if let Some(&ci) = cols.get(at) {
                        grid.children.remove(ci);
                    }
                }
            }
        }
        Ok(t)
    }

    fn page_break_para(&mut self) -> Element {
        fragment(r#"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#, &self.w)
    }

    fn page_setup(&self) -> PageSetup {
        let mut p = PageSetup::default();
        let Some(s) = self.section() else { return p };
        if let Some(sz) = s.elements().find(|c| is_w(c, "pgSz")) {
            p.width = twips_attr(sz, "w").unwrap_or(p.width);
            p.height = twips_attr(sz, "h").unwrap_or(p.height);
        }
        if let Some(m) = s.elements().find(|c| is_w(c, "pgMar")) {
            p.margin_top = twips_attr(m, "top").unwrap_or(p.margin_top).abs();
            p.margin_bottom = twips_attr(m, "bottom").unwrap_or(p.margin_bottom).abs();
            p.margin_left = twips_attr(m, "left").unwrap_or(p.margin_left);
            p.margin_right = twips_attr(m, "right").unwrap_or(p.margin_right);
        }
        p
    }

    fn styles(&self) -> Vec<StyleInfo> {
        let mut out: Vec<StyleInfo> = Vec::new();
        for (id, name) in self.sheet.paragraph_styles() {
            let def = &self.sheet.styles[id];
            let offered = builtin::OFFERED.iter().any(|(o, _, _)| *o == id);
            if def.hidden && !offered {
                continue;
            }
            out.push(StyleInfo {
                id: id.to_owned(),
                name: styles::display_name(name),
                outline: self.style_outline(id),
                defined: true,
            });
        }
        for (id, name, outline) in builtin::OFFERED {
            if !out
                .iter()
                .any(|s| s.id == *id || s.name.eq_ignore_ascii_case(name))
            {
                out.push(StyleInfo {
                    id: (*id).to_owned(),
                    name: (*name).to_owned(),
                    outline: *outline,
                    defined: false,
                });
            }
        }
        let rank = |s: &StyleInfo| -> (u8, u8, String) {
            let l = s.name.to_ascii_lowercase();
            let r = if l == "normal" {
                0
            } else if l == "title" {
                1
            } else if l == "subtitle" {
                2
            } else if s.outline.is_some() {
                3
            } else if l.contains("quote") {
                4
            } else if l.contains("list") {
                5
            } else {
                6
            };
            (r, s.outline.unwrap_or(9), l)
        };
        out.sort_by_key(rank);
        out
    }

    fn ensure_style(&mut self, id: &str) {
        if id.is_empty() || self.sheet.styles.contains_key(id) {
            return;
        }
        let Some(xml) = builtin::style_xml(id) else {
            return;
        };
        if self.styles_doc.is_none() {
            let part = self.part_in_main_dir("styles.xml");
            if self.pkg.set_override(&part, STYLES_TYPE).is_err() {
                return;
            }
            self.rels.add(&rel::uri(rel::STYLES), &part);
            self.rels_changed = true;
            self.styles_doc = Document::parse_str(builtin::STYLES).ok();
            self.styles_part = Some(part);
        }
        let Some(doc) = &mut self.styles_doc else {
            return;
        };
        let w = doc.prefix_for(ns::W).unwrap_or_else(|| "w".into());
        doc.root.push(fragment(xml, &w));
        let theme = self.sheet.theme.clone();
        self.sheet = StyleSheet::read(doc, theme);
        self.styles_changed = true;
    }

    fn image(&self, obj: &StoredObject) -> Option<(Vec<u8>, String)> {
        let id = para::image_rel_id(&obj.nodes)?;
        let r = self.rels.by_id(&id)?;
        let part = self.rels.part_of(&r)?;
        let bytes = self.pkg.read(&part).ok()?;
        let ext = part.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
        Some((bytes, ext))
    }

    fn image_nodes(
        &mut self,
        bytes: &[u8],
        ext: &str,
        width: f32,
        height: f32,
    ) -> Result<Vec<XmlNode>, WordError> {
        let ext = ext.trim_start_matches('.').to_ascii_lowercase();
        let content_type = match ext.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            "tif" | "tiff" => "image/tiff",
            _ => {
                return Err(WordError::Unsupported(
                    "Pictures must be PNG, JPEG, GIF or BMP.".into(),
                ))
            }
        };
        let part = self
            .pkg
            .unused_name(&self.part_in_main_dir(&format!("media/image{{}}.{ext}")));
        self.pkg.set(&part, bytes.to_vec());
        self.pkg.ensure_default(&ext, content_type)?;
        let rid = self.rels.add(&rel::uri(rel::IMAGE), &part);
        self.rels_changed = true;
        // Drawing ids are unique in the document.
        let mut max_id = 0u32;
        for p in tree::paragraphs(&self.body) {
            for d in p.el.descendants() {
                if d.ns == ns::WP && d.local() == "docPr" {
                    if let Some(v) = d.attr(ns::NONE, "id").and_then(|v| v.parse::<u32>().ok()) {
                        max_id = max_id.max(v);
                    }
                }
            }
        }
        let n = max_id + 1;
        let cx = (width.max(1.0) * 12700.0).round() as i64;
        let cy = (height.max(1.0) * 12700.0).round() as i64;
        let name = part.rsplit('/').next().unwrap_or("image");
        let xml = format!(
            r#"<w:r><w:drawing><wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="{n}" name="Picture {n}"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="{n}" name="{name}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"#
        );
        Ok(vec![XmlNode::Element(fragment(&xml, &self.w))])
    }

    fn save(&mut self) -> Result<Vec<u8>, WordError> {
        if self.body_changed {
            let mut doc = self.doc.clone();
            doc.root.children[self.body_at]
                .as_element_mut()
                .unwrap()
                .children = tree::flatten(&self.body);
            self.pkg.set_xml(&self.main, &doc);
        }
        if self.numbering_changed {
            if let Some(ndoc) = &self.numbering.doc {
                let part = match &self.numbering_part {
                    Some(p) => p.clone(),
                    None => {
                        let p = self.part_in_main_dir("numbering.xml");
                        self.pkg.set_override(&p, NUMBERING_TYPE)?;
                        self.rels.add(&rel::uri(rel::NUMBERING), &p);
                        self.rels_changed = true;
                        self.numbering_part = Some(p.clone());
                        p
                    }
                };
                self.pkg.set_xml(&part, ndoc);
            }
        }
        if self.styles_changed {
            if let (Some(doc), Some(part)) = (&self.styles_doc, &self.styles_part) {
                self.pkg.set_xml(part, doc);
            }
        }
        if self.rels_changed {
            self.pkg.set_rels(&self.rels);
        }
        Ok(self.pkg.save()?)
    }
}
