//! PowerPoint decks (`.pptx`, `.pptm`, `.potx`): slides read into scenes
//! through their layouts, masters and themes, edited in place and written
//! back. Every part an edit does not touch is copied as it was.

pub mod edit;
pub mod template;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use doc_opc::{rel, Package, Rels};
use doc_xml::{ns, Document, Element};

use crate::color::Palette;
use crate::error::SlideError;
use crate::geom;
use crate::scene::{Cell, Fill, Item, Kind, Line, Path, Scene, Table, TableRow};
use crate::text::{text_box, TextCtx};
use crate::theme::{self, Theme};

pub const EMU_PER_PT: f32 = 12700.0;

/// A slide in the deck's order.
#[derive(Clone, Debug, PartialEq)]
pub struct SlideRef {
    pub part: String,
    pub rel_id: String,
    pub sld_id: u32,
}

/// A placeholder of a layout or master.
#[derive(Clone, Debug)]
pub struct Ph {
    pub ty: String,
    pub idx: Option<u32>,
    pub sp: Element,
}

pub fn ph_of(sp: &Element) -> Option<(String, Option<u32>)> {
    let nv = sp.elements().find(|e| e.local().starts_with("nv"))?;
    let nvpr = nv.elements().find(|e| e.local() == "nvPr")?;
    let ph = nvpr.elements().find(|e| e.local() == "ph")?;
    Some((
        ph.attr(ns::NONE, "type").unwrap_or("body").to_owned(),
        ph.attr(ns::NONE, "idx").and_then(|v| v.parse().ok()),
    ))
}

fn placeholders(tree: Option<&Element>) -> Vec<Ph> {
    let Some(tree) = tree else { return Vec::new() };
    tree.elements()
        .filter_map(|sp| {
            let (ty, idx) = ph_of(sp)?;
            Some(Ph { ty, idx, sp: sp.clone() })
        })
        .collect()
}

/// The placeholder of `list` a placeholder inherits from.
pub fn find_ph<'a>(list: &'a [Ph], ty: &str, idx: Option<u32>, master: bool) -> Option<&'a Ph> {
    fn norm(t: &str) -> &str {
        match t {
            "ctrTitle" | "title" => "title",
            "subTitle" | "body" | "obj" | "tbl" | "chart" | "dgm" | "media" | "clipArt" | "pic" => "body",
            other => other,
        }
    }
    if !master {
        if let Some(i) = idx {
            if let Some(p) = list.iter().find(|p| p.idx == Some(i)) {
                return Some(p);
            }
        }
        if let Some(p) = list.iter().find(|p| p.ty == ty && (idx.is_none() || p.idx.is_none())) {
            return Some(p);
        }
    }
    list.iter().find(|p| norm(&p.ty) == norm(ty))
}

/// A slide master, read.
#[derive(Debug)]
pub struct Master {
    pub part: String,
    pub doc: Document,
    pub rels: Rels,
    pub theme: Theme,
    pub palette: Palette,
    pub title_style: Option<Element>,
    pub body_style: Option<Element>,
    pub other_style: Option<Element>,
    pub phs: Vec<Ph>,
}

/// A slide layout, read.
#[derive(Debug)]
pub struct Layout {
    pub part: String,
    pub name: String,
    pub doc: Document,
    pub rels: Rels,
    pub master: String,
    pub phs: Vec<Ph>,
    pub show_master_sp: bool,
}

pub fn c_sld(doc: &Document) -> Option<&Element> {
    doc.root.elements().find(|e| e.local() == "cSld")
}

pub fn sp_tree(doc: &Document) -> Option<&Element> {
    c_sld(doc)?.elements().find(|e| e.local() == "spTree")
}

/// The cNvPr id of a shape element.
pub fn shape_id(sp: &Element) -> Option<u32> {
    let nv = sp.elements().find(|e| e.local().starts_with("nv"))?;
    nv.elements().find(|e| e.local() == "cNvPr")?.attr(ns::NONE, "id")?.parse().ok()
}

fn shape_name(sp: &Element) -> String {
    sp.elements()
        .find(|e| e.local().starts_with("nv"))
        .and_then(|nv| nv.elements().find(|e| e.local() == "cNvPr"))
        .and_then(|c| c.attr(ns::NONE, "name"))
        .unwrap_or("")
        .to_owned()
}

/// Mutable state, shared cheaply between undo steps.
#[derive(Clone, Debug)]
pub struct State {
    pub pres: Arc<Document>,
    pub pres_rels: Arc<Rels>,
    pub slides: Vec<SlideRef>,
    /// Slides and notes read or edited.
    pub docs: HashMap<String, Arc<Document>>,
    pub rels: HashMap<String, Arc<Rels>>,
    pub dirty: HashSet<String>,
    pub dirty_rels: HashSet<String>,
    pub pres_dirty: bool,
    /// Parts added: content type.
    pub new_parts: HashMap<String, String>,
    pub removed: HashSet<String>,
    pub media: HashMap<String, Arc<Vec<u8>>>,
}

/// A PowerPoint deck being edited.
pub struct Pptx {
    pub pkg: Package,
    pub pres_part: String,
    pub state: State,
    pub width: f32,
    pub height: f32,
    /// What the main part's content type says the file is.
    pub format: crate::deck::Format,
    default_text: Option<Element>,
    masters: HashMap<String, Arc<Master>>,
    layouts: HashMap<String, Arc<Layout>>,
    table_styles: Option<Document>,
}

/// Maps child coordinates (EMU) of groups to the slide.
#[derive(Clone, Copy, Debug)]
struct Xf {
    dx: f64,
    dy: f64,
    sx: f64,
    sy: f64,
}

impl Xf {
    const ID: Xf = Xf { dx: 0.0, dy: 0.0, sx: 1.0, sy: 1.0 };

    fn apply(&self, x: f64, y: f64, w: f64, h: f64) -> (f32, f32, f32, f32) {
        let pt = EMU_PER_PT as f64;
        (
            ((x * self.sx + self.dx) / pt) as f32,
            ((y * self.sy + self.dy) / pt) as f32,
            ((w * self.sx) / pt) as f32,
            ((h * self.sy) / pt) as f32,
        )
    }
}

/// Position from an `a:xfrm` / `p:xfrm`: off, ext, rotation, flips.
fn xfrm_of(x: &Element) -> Option<(f64, f64, f64, f64, f32, bool, bool)> {
    let off = x.elements().find(|e| e.local() == "off");
    let ext = x.elements().find(|e| e.local() == "ext");
    let get = |e: Option<&Element>, a: &str| e.and_then(|e| e.attr(ns::NONE, a)).and_then(|v| v.parse::<f64>().ok());
    let (cx, cy) = (get(ext, "cx")?, get(ext, "cy")?);
    Some((
        get(off, "x").unwrap_or(0.0),
        get(off, "y").unwrap_or(0.0),
        cx,
        cy,
        x.attr(ns::NONE, "rot").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 60000.0,
        x.attr(ns::NONE, "flipH").is_some_and(|v| v == "1" || v == "true"),
        x.attr(ns::NONE, "flipV").is_some_and(|v| v == "1" || v == "true"),
    ))
}

fn child<'a>(e: &'a Element, local: &str) -> Option<&'a Element> {
    e.elements().find(|c| c.local() == local)
}

/// Where a shape is drawn from: its own part, layout or master.
struct Ctx<'a> {
    pal: &'a Palette,
    theme: &'a Theme,
    master: &'a Master,
    layout: &'a Layout,
    rels: &'a Rels,
    slide_number: usize,
    /// Shapes of this part can be edited.
    editable: bool,
    /// Placeholders here inherit from the layout (slides) or the master
    /// (layouts).
    level: u8,
}

const SLIDE_TYPE: &str = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml";

impl Pptx {
    pub fn open(bytes: Vec<u8>) -> Result<Pptx, SlideError> {
        let pkg = Package::open(bytes)?;
        let pres_part = pkg.main_part()?;
        let pres = pkg.read_xml(&pres_part)?;
        if pres.root.local() != "presentation" {
            return Err(SlideError::Unsupported("This package is not a PowerPoint presentation.".into()));
        }
        let pres_rels = pkg.rels(&pres_part)?;
        let mut slides = Vec::new();
        if let Some(list) = child(&pres.root, "sldIdLst") {
            for s in list.elements() {
                let Some(rid) = s.attr(ns::R, "id") else { continue };
                let Some(r) = pres_rels.by_id(rid) else { continue };
                let Some(part) = pres_rels.part_of(&r) else { continue };
                if !pkg.exists(&part) {
                    continue;
                }
                slides.push(SlideRef {
                    part,
                    rel_id: rid.to_owned(),
                    sld_id: s.attr(ns::NONE, "id").and_then(|v| v.parse().ok()).unwrap_or(256),
                });
            }
        }
        let (width, height) = child(&pres.root, "sldSz")
            .map(|s| {
                let get = |a: &str, d: f32| s.attr(ns::NONE, a).and_then(|v| v.parse::<f32>().ok()).unwrap_or(d);
                (get("cx", 9144000.0) / EMU_PER_PT, get("cy", 6858000.0) / EMU_PER_PT)
            })
            .unwrap_or((720.0, 540.0));
        let default_text = child(&pres.root, "defaultTextStyle").cloned();
        let table_styles = pres_rels.first_part("tableStyles").and_then(|p| pkg.read_xml(&p).ok());
        let format = match pkg.content_type(&pres_part).unwrap_or_default() {
            t if t.contains("macroEnabled") => crate::deck::Format::Pptm,
            t if t.contains("template") || t.contains("slideshow") => crate::deck::Format::Potx,
            _ => crate::deck::Format::Pptx,
        };
        Ok(Pptx {
            format,
            pkg,
            pres_part,
            state: State {
                pres: Arc::new(pres),
                pres_rels: Arc::new(pres_rels),
                slides,
                docs: HashMap::new(),
                rels: HashMap::new(),
                dirty: HashSet::new(),
                dirty_rels: HashSet::new(),
                pres_dirty: false,
                new_parts: HashMap::new(),
                removed: HashSet::new(),
                media: HashMap::new(),
            },
            width,
            height,
            default_text,
            masters: HashMap::new(),
            layouts: HashMap::new(),
            table_styles,
        })
    }

    /// A part's document (slides and notes are kept for editing).
    pub fn doc(&mut self, part: &str) -> Result<Arc<Document>, SlideError> {
        if let Some(d) = self.state.docs.get(part) {
            return Ok(d.clone());
        }
        let d = Arc::new(self.pkg.read_xml(part)?);
        self.state.docs.insert(part.to_owned(), d.clone());
        Ok(d)
    }

    pub fn rels(&mut self, part: &str) -> Result<Arc<Rels>, SlideError> {
        if let Some(r) = self.state.rels.get(part) {
            return Ok(r.clone());
        }
        let r = Arc::new(self.pkg.rels(part)?);
        self.state.rels.insert(part.to_owned(), r.clone());
        Ok(r)
    }

    /// A part's bytes, including pictures added since opening.
    pub fn part_bytes(&self, part: &str) -> Option<Vec<u8>> {
        if let Some(m) = self.state.media.get(part) {
            return Some(m.as_ref().clone());
        }
        self.pkg.read(part).ok()
    }

    fn master(&mut self, part: &str) -> Result<Arc<Master>, SlideError> {
        if let Some(m) = self.masters.get(part) {
            return Ok(m.clone());
        }
        let doc = self.pkg.read_xml(part)?;
        let rels = self.pkg.rels(part)?;
        let theme = rels
            .first_part(rel::THEME)
            .and_then(|p| self.pkg.read_xml(&p).ok())
            .map(|d| Theme::read(&d))
            .unwrap_or_default();
        let mut palette = Palette::default();
        if let Some(s) = &theme.scheme {
            palette.read_scheme(s);
        }
        if let Some(m) = child(&doc.root, "clrMap") {
            palette.read_map(m);
        }
        let styles = child(&doc.root, "txStyles");
        let pick = |n: &str| styles.and_then(|s| child(s, n)).cloned();
        let m = Arc::new(Master {
            part: part.to_owned(),
            title_style: pick("titleStyle"),
            body_style: pick("bodyStyle"),
            other_style: pick("otherStyle"),
            phs: placeholders(sp_tree(&doc)),
            doc,
            rels,
            theme,
            palette,
        });
        self.masters.insert(part.to_owned(), m.clone());
        Ok(m)
    }

    pub fn layout(&mut self, part: &str) -> Result<Arc<Layout>, SlideError> {
        if let Some(l) = self.layouts.get(part) {
            return Ok(l.clone());
        }
        let doc = self.pkg.read_xml(part)?;
        let rels = self.pkg.rels(part)?;
        let master = rels
            .first_part(rel::SLIDE_MASTER)
            .ok_or_else(|| SlideError::Corrupt("A slide layout has no master.".into()))?;
        let l = Arc::new(Layout {
            part: part.to_owned(),
            name: c_sld(&doc).and_then(|c| c.attr(ns::NONE, "name")).unwrap_or("").to_owned(),
            phs: placeholders(sp_tree(&doc)),
            show_master_sp: doc.root.attr(ns::NONE, "showMasterSp") != Some("0"),
            doc,
            rels,
            master,
        });
        self.layouts.insert(part.to_owned(), l.clone());
        Ok(l)
    }

    /// The layout of slide `i`.
    pub fn slide_layout(&mut self, i: usize) -> Result<Arc<Layout>, SlideError> {
        let part = self.slide_part(i)?;
        let rels = self.rels(&part)?;
        let lp = rels
            .first_part(rel::SLIDE_LAYOUT)
            .ok_or_else(|| SlideError::Corrupt("A slide has no layout.".into()))?;
        self.layout(&lp)
    }

    pub fn slide_part(&self, i: usize) -> Result<String, SlideError> {
        self.state
            .slides
            .get(i)
            .map(|s| s.part.clone())
            .ok_or_else(|| SlideError::Invalid("There is no such slide.".into()))
    }

    /// Every layout of the deck's first master, for new slides.
    pub fn layouts(&mut self) -> Vec<(String, String)> {
        let Some(mp) = self.state.pres_rels.first_part(rel::SLIDE_MASTER) else { return Vec::new() };
        let Ok(m) = self.master(&mp) else { return Vec::new() };
        let ids: Vec<String> = child(&m.doc.root, "sldLayoutIdLst")
            .map(|l| l.elements().filter_map(|e| e.attr(ns::R, "id").map(str::to_owned)).collect())
            .unwrap_or_default();
        let mut out = Vec::new();
        for id in ids {
            let Some(r) = m.rels.by_id(&id) else { continue };
            let Some(part) = m.rels.part_of(&r) else { continue };
            if let Ok(l) = self.layout(&part) {
                out.push((part, if l.name.is_empty() { "Layout".into() } else { l.name.clone() }));
            }
        }
        out
    }

    /// Slide `i`, ready to draw.
    pub fn scene(&mut self, i: usize) -> Result<Scene, SlideError> {
        let part = self.slide_part(i)?;
        let doc = self.doc(&part)?;
        let rels = self.rels(&part)?;
        let layout = self.slide_layout(i)?;
        let master = self.master(&layout.master)?;
        let mut pal = master.palette.clone();
        // A slide or layout can override the colour map.
        for d in [&layout.doc, doc.as_ref()] {
            if let Some(m) = child(&d.root, "clrMapOvr").and_then(|o| child(o, "overrideClrMapping")) {
                pal.read_map(m);
            }
        }
        let hidden = doc.root.attr(ns::NONE, "show") == Some("0");
        let background = self.background(&doc, &rels, &layout, &master, &pal);
        let mut items = Vec::new();
        let show_master = layout.show_master_sp && doc.root.attr(ns::NONE, "showMasterSp") != Some("0");
        if show_master {
            let ctx = Ctx {
                pal: &pal,
                theme: &master.theme,
                master: &master,
                layout: &layout,
                rels: &master.rels,
                slide_number: i + 1,
                editable: false,
                level: 2,
            };
            if let Some(t) = sp_tree(&master.doc) {
                self.items(&ctx, t, Xf::ID, &mut items, false, true);
            }
        }
        if doc.root.attr(ns::NONE, "showMasterSp") != Some("0") {
            let ctx = Ctx {
                pal: &pal,
                theme: &master.theme,
                master: &master,
                layout: &layout,
                rels: &layout.rels,
                slide_number: i + 1,
                editable: false,
                level: 1,
            };
            if let Some(t) = sp_tree(&layout.doc) {
                self.items(&ctx, t, Xf::ID, &mut items, false, true);
            }
        }
        let ctx = Ctx {
            pal: &pal,
            theme: &master.theme,
            master: &master,
            layout: &layout,
            rels: &rels,
            slide_number: i + 1,
            editable: true,
            level: 0,
        };
        if let Some(t) = sp_tree(&doc) {
            self.items(&ctx, t, Xf::ID, &mut items, false, false);
        }
        Ok(Scene {
            width: self.width,
            height: self.height,
            background,
            items,
            hidden,
        })
    }

    fn background(&self, slide: &Document, rels: &Rels, layout: &Layout, master: &Master, pal: &Palette) -> Fill {
        for (doc, rels) in [(slide, rels), (&layout.doc, &layout.rels), (&master.doc, &master.rels)] {
            let Some(bg) = c_sld(doc).and_then(|c| child(c, "bg")) else { continue };
            let image = |id: &str| rels.by_id(id).and_then(|r| rels.part_of(&r));
            if let Some(pr) = child(bg, "bgPr") {
                if let Some(f) = theme::fill_in(pr, pal, None, &image) {
                    return f;
                }
            }
            if let Some(r) = child(bg, "bgRef") {
                if let Some(f) = theme::fill_ref(r, &master.theme, pal, &image) {
                    return f;
                }
            }
        }
        Fill::Solid(0xFF00_0000 | pal.scheme("bg1"))
    }

    /// Placeholder elements a slide or layout placeholder inherits from,
    /// most general first (master, layout).
    fn ph_chain<'a>(&self, ctx: &'a Ctx, sp: &Element) -> (Option<(String, Option<u32>)>, Vec<&'a Element>) {
        let Some((ty, idx)) = ph_of(sp) else { return (None, Vec::new()) };
        let mut chain = Vec::new();
        match ctx.level {
            0 => {
                let lp = find_ph(&ctx.layout.phs, &ty, idx, false);
                let mty = lp.map_or(ty.as_str(), |p| p.ty.as_str());
                if let Some(m) = find_ph(&ctx.master.phs, mty, None, true) {
                    chain.push(&m.sp);
                }
                if let Some(l) = lp {
                    chain.push(&l.sp);
                }
            }
            1 => {
                if let Some(m) = find_ph(&ctx.master.phs, &ty, None, true) {
                    chain.push(&m.sp);
                }
            }
            _ => {}
        }
        (Some((ty, idx)), chain)
    }

    fn items(&self, ctx: &Ctx, tree: &Element, xf: Xf, out: &mut Vec<Item>, grouped: bool, decor_only: bool) {
        for e in tree.elements() {
            match e.local() {
                "sp" | "cxnSp" => {
                    // A layout's or master's placeholders show only through
                    // the slide's own.
                    if decor_only && ph_of(e).is_some() {
                        continue;
                    }
                    if let Some(it) = self.shape(ctx, e, xf, grouped) {
                        out.push(it);
                    }
                }
                "pic" => {
                    if decor_only && ph_of(e).is_some() {
                        continue;
                    }
                    if let Some(it) = self.picture(ctx, e, xf, grouped) {
                        out.push(it);
                    }
                }
                "graphicFrame" => {
                    if let Some(it) = self.frame(ctx, e, xf, grouped, out) {
                        out.push(it);
                    }
                }
                "grpSp" => {
                    let gp = child(e, "grpSpPr").and_then(|p| child(p, "xfrm"));
                    let inner = match gp {
                        Some(x) => {
                            let get = |n: &str, a: &str| child(x, n).and_then(|c| c.attr(ns::NONE, a)).and_then(|v| v.parse::<f64>().ok());
                            let (ox, oy) = (get("off", "x").unwrap_or(0.0), get("off", "y").unwrap_or(0.0));
                            let (cx, cy) = (get("ext", "cx").unwrap_or(0.0), get("ext", "cy").unwrap_or(0.0));
                            let (chx, chy) = (get("chOff", "x").unwrap_or(ox), get("chOff", "y").unwrap_or(oy));
                            let (chcx, chcy) = (get("chExt", "cx").unwrap_or(cx), get("chExt", "cy").unwrap_or(cy));
                            let sx = if chcx > 0.0 { cx / chcx } else { 1.0 };
                            let sy = if chcy > 0.0 { cy / chcy } else { 1.0 };
                            // child -> group: off + (c - chOff) * s; then the
                            // outer transform.
                            Xf {
                                sx: xf.sx * sx,
                                sy: xf.sy * sy,
                                dx: xf.dx + xf.sx * (ox - chx * sx),
                                dy: xf.dy + xf.sy * (oy - chy * sy),
                            }
                        }
                        None => xf,
                    };
                    self.items(ctx, e, inner, out, true, decor_only);
                }
                "AlternateContent" => {
                    let pick = child(e, "Fallback").or_else(|| child(e, "Choice"));
                    if let Some(p) = pick {
                        self.items(ctx, p, xf, out, grouped, decor_only);
                    }
                }
                _ => {}
            }
        }
    }

    fn shape(&self, ctx: &Ctx, sp: &Element, xf: Xf, grouped: bool) -> Option<Item> {
        let id = shape_id(sp).unwrap_or(0);
        let (ph, chain) = self.ph_chain(ctx, sp);
        let sppr = child(sp, "spPr");
        let inherit = |local: &str| -> Option<&Element> {
            sppr.and_then(|p| child(p, local)).or_else(|| chain.iter().rev().find_map(|c| child(c, "spPr").and_then(|p| child(p, local))))
        };
        let (x, y, w, h, rot, fh, fv) = xfrm_of(inherit("xfrm")?)?;
        let (px, py, pw, ph_) = xf.apply(x, y, w, h);
        let paths = if let Some(g) = inherit("custGeom") {
            geom::custom(g, pw as f64, ph_ as f64)
        } else if let Some(g) = inherit("prstGeom") {
            geom::preset(g.attr(ns::NONE, "prst").unwrap_or("rect"), pw as f64, ph_ as f64, &geom::adjusts(g))
        } else {
            geom::preset("rect", pw as f64, ph_ as f64, &Default::default())
        };
        let style = child(sp, "style");
        let image = |rid: &str| ctx.rels.by_id(rid).and_then(|r| ctx.rels.part_of(&r));
        let mut fill = None;
        for p in std::iter::once(sppr).chain(chain.iter().rev().map(|c| child(c, "spPr"))).flatten() {
            if let Some(f) = theme::fill_in(p, ctx.pal, None, &image) {
                fill = Some(f);
                break;
            }
        }
        let fill = fill
            .or_else(|| style.and_then(|s| child(s, "fillRef")).and_then(|r| theme::fill_ref(r, ctx.theme, ctx.pal, &image)))
            .unwrap_or(Fill::None);
        let base_line = style.and_then(|s| child(s, "lnRef")).and_then(|r| theme::line_ref(r, ctx.theme, ctx.pal));
        let line = match inherit("ln") {
            Some(ln) => theme::line(ln, ctx.pal, None, base_line),
            None => base_line,
        };
        // Text.
        let text = child(sp, "txBody").map(|body| {
            let font_ref = style.and_then(|s| child(s, "fontRef"));
            let mut lists: Vec<&Element> = Vec::new();
            if let Some(d) = &self.default_text {
                lists.push(d);
            }
            let ty = ph.as_ref().map(|(t, _)| t.as_str());
            match ty {
                Some("title") | Some("ctrTitle") => lists.extend(ctx.master.title_style.as_ref()),
                Some("dt") | Some("ftr") | Some("sldNum") | Some("hdr") => lists.extend(ctx.master.other_style.as_ref()),
                Some(_) => lists.extend(ctx.master.body_style.as_ref()),
                None => lists.extend(ctx.master.other_style.as_ref()),
            }
            let mut body_chain: Vec<&Element> = Vec::new();
            for c in &chain {
                if let Some(b) = child(c, "txBody") {
                    lists.extend(child(b, "lstStyle"));
                    body_chain.extend(child(b, "bodyPr"));
                }
            }
            lists.extend(child(body, "lstStyle"));
            body_chain.extend(child(body, "bodyPr"));
            let tctx = TextCtx {
                pal: ctx.pal,
                theme: ctx.theme,
                lists,
                font_color: font_ref.and_then(|f| ctx.pal.child_color(f, None)),
                font_ref: font_ref.and_then(|f| f.attr(ns::NONE, "idx")).filter(|v| *v != "none").map(str::to_owned),
                slide_number: ctx.slide_number,
                link: &|rid| ctx.rels.by_id(rid).filter(|r| r.external).map(|r| r.target),
            };
            let prompt = match ty {
                Some("title") | Some("ctrTitle") => Some("Tap to add a title".to_owned()),
                Some("subTitle") => Some("Tap to add a subtitle".to_owned()),
                Some("body") | Some("obj") => Some("Tap to add text".to_owned()),
                _ => None,
            };
            text_box(&tctx, body, &body_chain, prompt)
        });
        Some(Item {
            id: if ctx.editable { id } else { 0 },
            kind: Kind::Shape,
            name: shape_name(sp),
            x: px,
            y: py,
            w: pw,
            h: ph_,
            rot,
            flip_h: fh,
            flip_v: fv,
            paths,
            fill,
            line,
            text,
            image: None,
            table: None,
            placeholder: ph.map(|(t, _)| t),
            editable: ctx.editable,
            grouped,
        })
    }

    fn picture(&self, ctx: &Ctx, pic: &Element, xf: Xf, grouped: bool) -> Option<Item> {
        let (_, chain) = self.ph_chain(ctx, pic);
        let sppr = child(pic, "spPr");
        let xfrm = sppr
            .and_then(|p| child(p, "xfrm"))
            .or_else(|| chain.iter().rev().find_map(|c| child(c, "spPr").and_then(|p| child(p, "xfrm"))))?;
        let (x, y, w, h, rot, fh, fv) = xfrm_of(xfrm)?;
        let (px, py, pw, ph) = xf.apply(x, y, w, h);
        let blip_fill = child(pic, "blipFill")?;
        let rid = child(blip_fill, "blip").and_then(|b| b.attr(ns::R, "embed"))?;
        let part = ctx.rels.by_id(rid).and_then(|r| ctx.rels.part_of(&r))?;
        let crop = child(blip_fill, "srcRect").map_or([0.0; 4], |s| {
            let g = |a: &str| s.attr(ns::NONE, a).and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
            [g("l"), g("t"), g("r"), g("b")]
        });
        let paths = match sppr.and_then(|p| child(p, "prstGeom")) {
            Some(g) => geom::preset(g.attr(ns::NONE, "prst").unwrap_or("rect"), pw as f64, ph as f64, &geom::adjusts(g)),
            None => geom::preset("rect", pw as f64, ph as f64, &Default::default()),
        };
        let line = sppr.and_then(|p| child(p, "ln")).and_then(|ln| theme::line(ln, ctx.pal, None, None));
        Some(Item {
            id: if ctx.editable { shape_id(pic).unwrap_or(0) } else { 0 },
            kind: Kind::Picture,
            name: shape_name(pic),
            x: px,
            y: py,
            w: pw,
            h: ph,
            rot,
            flip_h: fh,
            flip_v: fv,
            paths,
            fill: Fill::None,
            line,
            text: None,
            image: Some((part, crop)),
            table: None,
            placeholder: None,
            editable: ctx.editable,
            grouped,
        })
    }

    fn frame(&self, ctx: &Ctx, gf: &Element, xf: Xf, grouped: bool, out: &mut Vec<Item>) -> Option<Item> {
        let (x, y, w, h, rot, fh, fv) = xfrm_of(child(gf, "xfrm")?)?;
        let (px, py, pw, ph) = xf.apply(x, y, w, h);
        let data = child(gf, "graphic").and_then(|g| child(g, "graphicData"))?;
        let uri = data.attr(ns::NONE, "uri").unwrap_or("");
        let mut item = Item {
            id: if ctx.editable { shape_id(gf).unwrap_or(0) } else { 0 },
            kind: Kind::Other,
            name: shape_name(gf),
            x: px,
            y: py,
            w: pw,
            h: ph,
            rot,
            flip_h: fh,
            flip_v: fv,
            paths: geom::preset("rect", pw as f64, ph as f64, &Default::default()),
            fill: Fill::None,
            line: None,
            text: None,
            image: None,
            table: None,
            placeholder: None,
            editable: ctx.editable,
            grouped,
        };
        if uri.ends_with("/table") {
            if let Some(tbl) = child(data, "tbl") {
                item.kind = Kind::Table;
                item.table = Some(self.table(ctx, tbl));
            }
        } else if uri.ends_with("/chart") {
            item.kind = Kind::Chart;
        } else if uri.ends_with("/diagram") {
            item.kind = Kind::Diagram;
            // SmartArt is drawn from its saved drawing, when there is one.
            if let Some(shapes) = self.diagram_drawing(ctx, data) {
                let dxf = Xf {
                    dx: xf.dx + xf.sx * x,
                    dy: xf.dy + xf.sy * y,
                    sx: xf.sx,
                    sy: xf.sy,
                };
                let dctx = Ctx {
                    editable: false,
                    level: 3,
                    ..*ctx
                };
                if let Some(tree) = shapes.root.descendants().find(|e| e.local() == "spTree") {
                    self.items(&dctx, tree, dxf, out, true, false);
                }
                return None;
            }
        } else {
            // An OLE object or another kind: its saved picture, if any.
            if let Some(pic) = data.descendants().find(|e| e.local() == "pic") {
                if let Some(mut p) = self.picture(ctx, pic, xf, grouped) {
                    p.x = px;
                    p.y = py;
                    p.w = pw;
                    p.h = ph;
                    p.id = item.id;
                    return Some(p);
                }
            }
        }
        Some(item)
    }

    fn diagram_drawing(&self, ctx: &Ctx, data: &Element) -> Option<Document> {
        let rel_ids = child(data, "relIds")?;
        let dm = rel_ids.attr(ns::R, "dm")?;
        let dm_part = ctx.rels.by_id(dm).and_then(|r| ctx.rels.part_of(&r))?;
        let dm_doc = self.pkg.read_xml(&dm_part).ok()?;
        let drawing_rid = dm_doc.root.descendants().find(|e| e.local() == "dataModelExt").and_then(|e| e.attr(ns::NONE, "relId"))?;
        let part = ctx.rels.by_id(drawing_rid).and_then(|r| ctx.rels.part_of(&r))?;
        self.pkg.read_xml(&part).ok()
    }

    fn table(&self, ctx: &Ctx, tbl: &Element) -> Table {
        let cols: Vec<f32> = child(tbl, "tblGrid")
            .map(|g| g.elements().filter_map(|c| c.attr(ns::NONE, "w")?.parse::<f32>().ok()).map(|w| w / EMU_PER_PT).collect())
            .unwrap_or_default();
        let tbl_pr = child(tbl, "tblPr");
        let flag = |a: &str| tbl_pr.and_then(|p| p.attr(ns::NONE, a)).is_some_and(|v| v == "1" || v == "true");
        let (first_row, band_row) = (flag("firstRow"), flag("bandRow"));
        let style_id = tbl_pr.and_then(|p| child(p, "tableStyleId")).map(|e| e.text());
        let style = TableStyle::find(self.table_styles.as_ref(), style_id.as_deref(), ctx.pal);
        let mut lists: Vec<&Element> = Vec::new();
        if let Some(d) = &self.default_text {
            lists.push(d);
        }
        lists.extend(ctx.master.other_style.as_ref());
        let rows: Vec<&Element> = tbl.elements().filter(|e| e.local() == "tr").collect();
        let mut out_rows = Vec::new();
        for (r, tr) in rows.iter().enumerate() {
            let header = first_row && r == 0;
            let band = band_row && !header && (r - first_row as usize) % 2 == 0;
            let height = tr.attr(ns::NONE, "h").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / EMU_PER_PT;
            let mut cells = Vec::new();
            for tc in tr.elements().filter(|e| e.local() == "tc") {
                let tcpr = child(tc, "tcPr");
                let image = |rid: &str| ctx.rels.by_id(rid).and_then(|r| ctx.rels.part_of(&r));
                let fill = tcpr
                    .and_then(|p| theme::fill_in(p, ctx.pal, None, &image))
                    .unwrap_or_else(|| style.fill(header, band));
                let line_of = |n: &str| tcpr.and_then(|p| child(p, n)).and_then(|ln| theme::line(ln, ctx.pal, None, None));
                let mut borders = [line_of("lnL"), line_of("lnT"), line_of("lnR"), line_of("lnB")];
                for b in &mut borders {
                    if b.is_none() {
                        *b = style.border.clone();
                    }
                }
                let tctx = TextCtx {
                    pal: ctx.pal,
                    theme: ctx.theme,
                    lists: lists.clone(),
                    font_color: if header { style.header_text } else { style.text },
                    font_ref: None,
                    slide_number: ctx.slide_number,
                    link: &|rid| ctx.rels.by_id(rid).filter(|r| r.external).map(|r| r.target),
                };
                let mut text = match child(tc, "txBody") {
                    Some(b) => {
                        let mut bp = Element::new("a:bodyPr", ns::A);
                        if let Some(p) = tcpr {
                            for (from, to) in [("marL", "lIns"), ("marT", "tIns"), ("marR", "rIns"), ("marB", "bIns")] {
                                if let Some(v) = p.attr(ns::NONE, from) {
                                    bp.set_attr(to, ns::NONE, v);
                                }
                            }
                            if let Some(a) = p.attr(ns::NONE, "anchor") {
                                bp.set_attr("anchor", ns::NONE, a);
                            }
                        }
                        let mut chain: Vec<&Element> = child(b, "bodyPr").into_iter().collect();
                        chain.push(&bp);
                        text_box(&tctx, b, &chain, None)
                    }
                    None => text_box(&tctx, &Element::new("a:txBody", ns::A), &[], None),
                };
                if header && style.header_bold {
                    for p in &mut text.paras {
                        for run in &mut p.runs {
                            run.bold = true;
                        }
                    }
                }
                let span = |a: &str| tc.attr(ns::NONE, a).and_then(|v| v.parse::<u32>().ok()).unwrap_or(1).max(1);
                let merged = tc.attr(ns::NONE, "hMerge").is_some_and(|v| v == "1" || v == "true")
                    || tc.attr(ns::NONE, "vMerge").is_some_and(|v| v == "1" || v == "true");
                cells.push(Cell {
                    text,
                    fill,
                    borders,
                    col_span: span("gridSpan"),
                    row_span: span("rowSpan"),
                    merged,
                });
            }
            out_rows.push(TableRow { height, cells });
        }
        Table { cols, rows: out_rows }
    }

    /// Notes of slide `i`.
    pub fn notes(&mut self, i: usize) -> Result<String, SlideError> {
        let part = self.slide_part(i)?;
        let rels = self.rels(&part)?;
        let Some(np) = rels.first_part(rel::NOTES_SLIDE).filter(|p| !self.state.removed.contains(p)) else {
            return Ok(String::new());
        };
        let doc = self.doc(&np)?;
        let Some(tree) = sp_tree(&doc) else { return Ok(String::new()) };
        for sp in tree.elements() {
            if ph_of(sp).is_some_and(|(t, _)| t == "body") {
                if let Some(body) = child(sp, "txBody") {
                    let paras: Vec<String> = body.elements().filter(|e| e.local() == "p").map(crate::text::para_text).collect();
                    return Ok(paras.join("\n"));
                }
            }
        }
        Ok(String::new())
    }

    /// The deck in its format.
    pub fn save(&self) -> Result<Vec<u8>, SlideError> {
        // Changes apply to the package as read, so saving twice (or after
        // an undo) writes exactly the current state.
        let mut pkg = Package::open(self.pkg.archive.bytes().to_vec())?;
        let s = &self.state;
        for (part, bytes) in &s.media {
            pkg.set(part, bytes.as_ref().clone());
            let ext = part.rsplit('.').next().unwrap_or("png").to_ascii_lowercase();
            let ct = match ext.as_str() {
                "jpg" | "jpeg" => "image/jpeg",
                "gif" => "image/gif",
                "bmp" => "image/bmp",
                _ => "image/png",
            };
            pkg.ensure_default(&ext, ct)?;
        }
        for part in &s.dirty {
            if let Some(d) = s.docs.get(part) {
                pkg.set_xml(part, d);
            }
        }
        for part in &s.dirty_rels {
            if let Some(r) = s.rels.get(part) {
                pkg.set_rels(r);
            }
        }
        if s.pres_dirty {
            pkg.set_xml(&self.pres_part, &s.pres);
            pkg.set_rels(&s.pres_rels);
        }
        for (part, ct) in &s.new_parts {
            if !s.removed.contains(part) {
                pkg.set_override(part, ct)?;
            }
        }
        for part in &s.removed {
            if pkg.exists(part) {
                pkg.remove_part(part)?;
            }
        }
        Ok(pkg.save()?)
    }

    pub fn slide_type() -> &'static str {
        SLIDE_TYPE
    }
}

/// A table style's fills, borders and text colours.
struct TableStyle {
    whole: Fill,
    band: Fill,
    header: Fill,
    header_text: Option<u32>,
    text: Option<u32>,
    header_bold: bool,
    border: Option<Line>,
}

impl TableStyle {
    fn find(styles: Option<&Document>, id: Option<&str>, pal: &Palette) -> TableStyle {
        let def = styles.and_then(|d| d.root.attr(ns::NONE, "def").map(str::to_owned));
        let id = id.map(str::to_owned).or(def);
        if let (Some(doc), Some(id)) = (styles, id.as_deref()) {
            if let Some(st) = doc.root.elements().find(|e| e.attr(ns::NONE, "styleId") == Some(id)) {
                return TableStyle::read(st, pal);
            }
        }
        // Office's default, "Medium Style 2 - Accent 1".
        let accent = 0xFF00_0000 | pal.scheme("accent1");
        let tint = |amount: f32| {
            let f = |c: u32| (255.0 - (255.0 - c as f32) * amount).round() as u32;
            0xFF00_0000 | (f((accent >> 16) & 0xFF) << 16) | (f((accent >> 8) & 0xFF) << 8) | f(accent & 0xFF)
        };
        TableStyle {
            whole: Fill::Solid(tint(0.2)),
            band: Fill::Solid(tint(0.4)),
            header: Fill::Solid(accent),
            header_text: Some(0xFF00_0000 | pal.scheme("lt1")),
            text: None,
            header_bold: true,
            border: Some(Line {
                width: 1.0,
                color: 0xFF00_0000 | pal.scheme("lt1"),
                dash: "solid".into(),
                head: None,
                tail: None,
            }),
        }
    }

    fn read(st: &Element, pal: &Palette) -> TableStyle {
        let part = |n: &str| child(st, n);
        let fill_of = |p: Option<&Element>| -> Option<Fill> {
            let tc = child(p?, "tcStyle")?;
            let f = child(tc, "fill")?;
            theme::fill_in(f, pal, None, &|_| None)
        };
        let text_of = |p: Option<&Element>| -> (Option<u32>, bool) {
            let Some(tx) = p.and_then(|p| child(p, "tcTxStyle")) else { return (None, false) };
            let color = tx.elements().find_map(|c| pal.color(c, None)).or_else(|| child(tx, "fontRef").and_then(|f| pal.child_color(f, None)));
            (color, tx.attr(ns::NONE, "b") == Some("on"))
        };
        let border = part("wholeTbl")
            .and_then(|p| child(p, "tcStyle"))
            .and_then(|t| child(t, "tcBdr"))
            .and_then(|b| b.elements().find_map(|side| child(side, "ln")))
            .and_then(|ln| theme::line(ln, pal, None, None));
        let (header_text, header_bold) = text_of(part("firstRow"));
        let (text, _) = text_of(part("wholeTbl"));
        TableStyle {
            whole: fill_of(part("wholeTbl")).unwrap_or(Fill::None),
            band: fill_of(part("band1H")).or_else(|| fill_of(part("wholeTbl"))).unwrap_or(Fill::None),
            header: fill_of(part("firstRow")).or_else(|| fill_of(part("wholeTbl"))).unwrap_or(Fill::None),
            header_text,
            text,
            header_bold,
            border,
        }
    }

    fn fill(&self, header: bool, band: bool) -> Fill {
        if header {
            self.header.clone()
        } else if band {
            self.band.clone()
        } else {
            self.whole.clone()
        }
    }
}

/// Paths of an item, for code that only needs the outline.
pub fn outline(item: &Item) -> &[Path] {
    &item.paths
}
