//! Word styles (`word/styles.xml`): the style chain, document defaults and
//! direct formatting, resolved to effective formatting; and writing direct
//! formatting back in the element order Word requires.

use std::cell::RefCell;
use std::collections::HashMap;

use doc_xml::{ns, Document, Element, Node};

use crate::view::{Align, LineSpacing, ParaStyle, RunStyle};

/// The order of a run's properties (CT_RPr). Word rejects files where they
/// come in another order.
pub const RPR_ORDER: &[&str] = &[
    "rStyle",
    "rFonts",
    "b",
    "bCs",
    "i",
    "iCs",
    "caps",
    "smallCaps",
    "strike",
    "dstrike",
    "outline",
    "shadow",
    "emboss",
    "imprint",
    "noProof",
    "snapToGrid",
    "vanish",
    "webHidden",
    "color",
    "spacing",
    "w",
    "kern",
    "position",
    "sz",
    "szCs",
    "highlight",
    "u",
    "effect",
    "bdr",
    "shd",
    "fitText",
    "vertAlign",
    "rtl",
    "cs",
    "em",
    "lang",
    "eastAsianLayout",
    "specVanish",
    "oMath",
    "rPrChange",
];

/// The order of a paragraph's properties (CT_PPr).
pub const PPR_ORDER: &[&str] = &[
    "pStyle",
    "keepNext",
    "keepLines",
    "pageBreakBefore",
    "framePr",
    "widowControl",
    "numPr",
    "suppressLineNumbers",
    "pBdr",
    "shd",
    "tabs",
    "suppressAutoHyphens",
    "kinsoku",
    "wordWrap",
    "overflowPunct",
    "topLinePunct",
    "autoSpaceDE",
    "autoSpaceDN",
    "bidi",
    "adjustRightInd",
    "snapToGrid",
    "spacing",
    "ind",
    "contextualSpacing",
    "mirrorIndents",
    "suppressOverlap",
    "jc",
    "textDirection",
    "textAlignment",
    "textboxTightWrap",
    "outlineLvl",
    "divId",
    "cnfStyle",
    "rPr",
    "sectPr",
    "pPrChange",
];

pub fn wval(e: &Element) -> Option<&str> {
    e.attr(ns::W, "val")
}

fn child<'e>(e: &'e Element, local: &str) -> Option<&'e Element> {
    e.elements().find(|c| c.ns == ns::W && c.local() == local)
}

/// A toggle property's value: present means on unless `val` says off.
fn toggle(e: &Element) -> bool {
    !matches!(wval(e), Some("0") | Some("false") | Some("off"))
}

fn twips(e: &Element, attr: &str) -> Option<f32> {
    e.attr(ns::W, attr)
        .and_then(|v| v.parse::<f32>().ok())
        .map(|v| v / 20.0)
}

/// The colours of `w:highlight`.
pub fn highlight_color(name: &str) -> Option<u32> {
    Some(match name {
        "yellow" => 0xFFFF00,
        "green" => 0x00FF00,
        "cyan" => 0x00FFFF,
        "magenta" => 0xFF00FF,
        "blue" => 0x0000FF,
        "red" => 0xFF0000,
        "darkBlue" => 0x000080,
        "darkCyan" => 0x008080,
        "darkGreen" => 0x008000,
        "darkMagenta" => 0x800080,
        "darkRed" => 0x800000,
        "darkYellow" => 0x808000,
        "darkGray" => 0x808080,
        "lightGray" => 0xC0C0C0,
        "black" => 0x000000,
        "white" => 0xFFFFFF,
        _ => return None,
    })
}

fn highlight_name(color: u32) -> Option<&'static str> {
    [
        "yellow",
        "green",
        "cyan",
        "magenta",
        "blue",
        "red",
        "darkBlue",
        "darkCyan",
        "darkGreen",
        "darkMagenta",
        "darkRed",
        "darkYellow",
        "darkGray",
        "lightGray",
        "black",
        "white",
    ]
    .into_iter()
    .find(|n| highlight_color(n) == Some(color))
}

fn hex_color(v: &str) -> Option<u32> {
    if v.eq_ignore_ascii_case("auto") || v.len() != 6 {
        return None;
    }
    u32::from_str_radix(v, 16).ok()
}

/// The theme's body and heading fonts.
#[derive(Clone, Debug, PartialEq)]
pub struct ThemeFonts {
    pub minor: String,
    pub major: String,
}

impl Default for ThemeFonts {
    fn default() -> Self {
        ThemeFonts {
            minor: "Calibri".into(),
            major: "Calibri Light".into(),
        }
    }
}

impl ThemeFonts {
    pub fn read(doc: &Document) -> ThemeFonts {
        let mut t = ThemeFonts::default();
        let face = |which: &str| {
            doc.root
                .descendants()
                .find(|e| e.local() == which)
                .and_then(|f| f.elements().find(|e| e.local() == "latin"))
                .and_then(|l| l.attr(ns::NONE, "typeface"))
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        if let Some(f) = face("minorFont") {
            t.minor = f;
        }
        if let Some(f) = face("majorFont") {
            t.major = f;
        }
        t
    }
}

/// Apply a run-properties element on top of a style.
pub fn apply_rpr(s: &mut RunStyle, rpr: &Element, theme: &ThemeFonts) {
    for c in rpr.elements() {
        if c.ns != ns::W {
            continue;
        }
        match c.local() {
            "b" => s.bold = toggle(c),
            "i" => s.italic = toggle(c),
            "strike" | "dstrike" => s.strike = toggle(c),
            "caps" => s.caps = toggle(c),
            "smallCaps" => s.small_caps = toggle(c),
            "vanish" => s.hidden = toggle(c),
            "u" => s.underline = wval(c).unwrap_or("single").to_owned(),
            "sz" => {
                if let Some(v) = wval(c).and_then(|v| v.parse::<f32>().ok()) {
                    s.size = v / 2.0;
                }
            }
            "color" => {
                if let Some(v) = wval(c) {
                    s.color = hex_color(v);
                }
            }
            "highlight" => {
                if let Some(v) = wval(c) {
                    s.highlight = highlight_color(v);
                }
            }
            "shd" => {
                if let Some(fill) = c.attr(ns::W, "fill").and_then(hex_color) {
                    s.highlight = Some(fill);
                }
            }
            "rFonts" => {
                if let Some(f) = c.attr(ns::W, "ascii").or_else(|| c.attr(ns::W, "hAnsi")) {
                    s.font = f.to_owned();
                } else if let Some(t) = c
                    .attr(ns::W, "asciiTheme")
                    .or_else(|| c.attr(ns::W, "hAnsiTheme"))
                {
                    s.font = if t.starts_with("major") {
                        theme.major.clone()
                    } else {
                        theme.minor.clone()
                    };
                }
            }
            "vertAlign" => {
                s.vert = match wval(c) {
                    Some("superscript") => Some("super".into()),
                    Some("subscript") => Some("sub".into()),
                    _ => None,
                }
            }
            _ => {}
        }
    }
}

/// Apply a paragraph-properties element on top of a style (not its run
/// properties or numbering, which are resolved separately).
pub fn apply_ppr(s: &mut ParaStyle, ppr: &Element) {
    for c in ppr.elements() {
        if c.ns != ns::W {
            continue;
        }
        match c.local() {
            "jc" => s.align = Align::parse(wval(c).unwrap_or("left")),
            "ind" => {
                if let Some(v) = twips(c, "left").or_else(|| twips(c, "start")) {
                    s.indent_left = v;
                }
                if let Some(v) = twips(c, "right").or_else(|| twips(c, "end")) {
                    s.indent_right = v;
                }
                if let Some(v) = twips(c, "firstLine") {
                    s.first_line = v;
                }
                if let Some(v) = twips(c, "hanging") {
                    s.first_line = -v;
                }
            }
            "spacing" => {
                if let Some(v) = twips(c, "before") {
                    s.space_before = v;
                }
                if let Some(v) = twips(c, "after") {
                    s.space_after = v;
                }
                if c.attr(ns::W, "beforeAutospacing")
                    .is_some_and(|v| v == "1" || v == "true")
                {
                    s.space_before = 14.0;
                }
                if c.attr(ns::W, "afterAutospacing")
                    .is_some_and(|v| v == "1" || v == "true")
                {
                    s.space_after = 14.0;
                }
                if let Some(line) = c.attr(ns::W, "line").and_then(|v| v.parse::<f32>().ok()) {
                    s.line = match c.attr(ns::W, "lineRule") {
                        Some("exact") => LineSpacing::Exactly(line / 20.0),
                        Some("atLeast") => LineSpacing::AtLeast(line / 20.0),
                        _ => LineSpacing::Multiple(line / 240.0),
                    };
                }
            }
            "keepNext" => s.keep_next = toggle(c),
            "pageBreakBefore" => s.page_break_before = toggle(c),
            "outlineLvl" => {
                s.outline_level = wval(c)
                    .and_then(|v| v.parse::<u8>().ok())
                    .filter(|l| *l < 9);
            }
            "shd" => s.shading = c.attr(ns::W, "fill").and_then(hex_color),
            "bidi" => s.bidi = toggle(c),
            _ => {}
        }
    }
}

/// One style definition.
#[derive(Clone, Debug, PartialEq)]
pub struct StyleDef {
    pub id: String,
    pub name: String,
    /// `paragraph`, `character`, `table` or `numbering`.
    pub kind: String,
    pub based_on: Option<String>,
    pub next: Option<String>,
    pub ppr: Option<Element>,
    pub rpr: Option<Element>,
    /// Hidden from style lists (`semiHidden`, `hidden`).
    pub hidden: bool,
    /// A table style that draws borders.
    pub borders: bool,
}

/// The styles part, read.
#[derive(Debug, Default)]
pub struct StyleSheet {
    pub styles: HashMap<String, StyleDef>,
    pub default_para: Option<String>,
    pub default_char: Option<String>,
    pub doc_rpr: Option<Element>,
    pub doc_ppr: Option<Element>,
    pub theme: ThemeFonts,
    cache: RefCell<HashMap<(String, String), RunStyle>>,
}

impl Clone for StyleSheet {
    fn clone(&self) -> Self {
        StyleSheet {
            styles: self.styles.clone(),
            default_para: self.default_para.clone(),
            default_char: self.default_char.clone(),
            doc_rpr: self.doc_rpr.clone(),
            doc_ppr: self.doc_ppr.clone(),
            theme: self.theme.clone(),
            cache: RefCell::new(HashMap::new()),
        }
    }
}

impl StyleSheet {
    pub fn read(doc: &Document, theme: ThemeFonts) -> StyleSheet {
        let mut sheet = StyleSheet {
            theme,
            ..StyleSheet::default()
        };
        for e in doc.root.elements() {
            if e.ns != ns::W {
                continue;
            }
            match e.local() {
                "docDefaults" => {
                    sheet.doc_rpr = e
                        .elements()
                        .find(|c| c.local() == "rPrDefault")
                        .and_then(|d| child(d, "rPr"))
                        .cloned();
                    sheet.doc_ppr = e
                        .elements()
                        .find(|c| c.local() == "pPrDefault")
                        .and_then(|d| child(d, "pPr"))
                        .cloned();
                }
                "style" => {
                    let Some(id) = e.attr(ns::W, "styleId") else {
                        continue;
                    };
                    let kind = e.attr(ns::W, "type").unwrap_or("paragraph").to_owned();
                    let def = StyleDef {
                        id: id.to_owned(),
                        name: child(e, "name").and_then(wval).unwrap_or(id).to_owned(),
                        kind: kind.clone(),
                        based_on: child(e, "basedOn").and_then(wval).map(str::to_owned),
                        next: child(e, "next").and_then(wval).map(str::to_owned),
                        ppr: child(e, "pPr").cloned(),
                        rpr: child(e, "rPr").cloned(),
                        hidden: child(e, "semiHidden")
                            .or_else(|| child(e, "hidden"))
                            .is_some_and(toggle),
                        borders: e
                            .descendants()
                            .find(|d| d.ns == ns::W && d.local() == "tblBorders")
                            .is_some_and(|b| {
                                b.elements()
                                    .any(|x| !matches!(wval(x), Some("none") | Some("nil")))
                            }),
                    };
                    if e.attr(ns::W, "default")
                        .is_some_and(|v| v == "1" || v == "true")
                    {
                        match kind.as_str() {
                            "paragraph" => sheet.default_para = Some(id.to_owned()),
                            "character" => sheet.default_char = Some(id.to_owned()),
                            _ => {}
                        }
                    }
                    sheet.styles.insert(id.to_owned(), def);
                }
                _ => {}
            }
        }
        sheet
    }

    /// The chain of a style from its root ancestor down to itself.
    pub fn chain(&self, id: &str) -> Vec<&StyleDef> {
        let mut out = Vec::new();
        let mut cur = self.styles.get(id);
        while let Some(s) = cur {
            if out.len() > 16 || out.iter().any(|x: &&StyleDef| x.id == s.id) {
                break;
            }
            out.push(s);
            cur = s.based_on.as_deref().and_then(|b| self.styles.get(b));
        }
        out.reverse();
        out
    }

    /// The paragraph style a paragraph uses (its own or the default).
    pub fn para_style_id<'a>(&'a self, ppr: Option<&'a Element>) -> Option<&'a str> {
        ppr.and_then(|p| child(p, "pStyle"))
            .and_then(wval)
            .filter(|id| self.styles.contains_key(*id))
            .or(self.default_para.as_deref())
    }

    /// Effective run formatting from the document defaults, a paragraph
    /// style and a character style (no direct formatting).
    pub fn base_run(&self, para_style: Option<&str>, char_style: Option<&str>) -> RunStyle {
        let key = (
            para_style.unwrap_or("").to_owned(),
            char_style.unwrap_or("").to_owned(),
        );
        if let Some(found) = self.cache.borrow().get(&key) {
            return found.clone();
        }
        let mut s = RunStyle {
            font: self.theme.minor.clone(),
            size: 10.0,
            ..RunStyle::default()
        };
        if let Some(d) = &self.doc_rpr {
            apply_rpr(&mut s, d, &self.theme);
        }
        if let Some(p) = para_style {
            for def in self.chain(p) {
                if let Some(r) = &def.rpr {
                    apply_rpr(&mut s, r, &self.theme);
                }
            }
        }
        if let Some(c) = char_style.or(self.default_char.as_deref()) {
            for def in self.chain(c) {
                if let Some(r) = &def.rpr {
                    apply_rpr(&mut s, r, &self.theme);
                }
            }
        }
        self.cache.borrow_mut().insert(key, s.clone());
        s
    }

    /// Effective run formatting of a run with properties `rpr` in a
    /// paragraph of style `para_style`.
    pub fn run_style(&self, para_style: Option<&str>, rpr: Option<&Element>) -> RunStyle {
        let char_style = rpr.and_then(|r| child(r, "rStyle")).and_then(wval);
        let mut s = self.base_run(para_style, char_style);
        if let Some(r) = rpr {
            apply_rpr(&mut s, r, &self.theme);
        }
        s
    }

    /// Effective paragraph formatting.
    pub fn para_style(&self, ppr: Option<&Element>) -> ParaStyle {
        let id = self.para_style_id(ppr).map(str::to_owned);
        let mut s = ParaStyle::default();
        if let Some(d) = &self.doc_ppr {
            apply_ppr(&mut s, d);
        }
        if let Some(id) = &id {
            for def in self.chain(id) {
                if let Some(p) = &def.ppr {
                    apply_ppr(&mut s, p);
                }
            }
            let def = &self.styles[id];
            s.style_id = id.clone();
            s.style_name = display_name(&def.name);
            s.next_style = def
                .next
                .clone()
                .filter(|n| n != id && self.styles.contains_key(n));
        }
        if let Some(p) = ppr {
            apply_ppr(&mut s, p);
        }
        let mark_rpr = ppr.and_then(|p| child(p, "rPr"));
        s.mark = self.run_style(id.as_deref(), mark_rpr);
        // Headings are outline levels even when the style says so only by
        // its name.
        if s.outline_level.is_none() {
            let lower = s.style_name.to_ascii_lowercase();
            if let Some(n) = lower
                .strip_prefix("heading ")
                .and_then(|n| n.trim().parse::<u8>().ok())
            {
                if (1..=9).contains(&n) {
                    s.outline_level = Some(n - 1);
                }
            }
        }
        s
    }

    /// The numbering (num id, level) a paragraph gets: its own or its
    /// style's.
    pub fn numbering(&self, ppr: Option<&Element>) -> Option<(String, u8)> {
        let own = ppr.and_then(|p| child(p, "numPr"));
        let from_style = || {
            let id = self.para_style_id(ppr)?;
            self.chain(id)
                .into_iter()
                .rev()
                .find_map(|d| d.ppr.as_ref().and_then(|p| child(p, "numPr")).cloned())
        };
        let num_pr = match own {
            Some(n) => Some(n.clone()),
            None => from_style(),
        }?;
        let num_id = child(&num_pr, "numId").and_then(wval)?.to_owned();
        let level = child(&num_pr, "ilvl")
            .and_then(wval)
            .and_then(|v| v.parse::<u8>().ok())
            .unwrap_or(0);
        if num_id == "0" {
            return None;
        }
        Some((num_id, level.min(8)))
    }

    /// The style id for a style name (`Heading 1` -> `Heading1`).
    pub fn id_for_name(&self, name: &str) -> Option<&str> {
        self.styles
            .values()
            .find(|s| s.name.eq_ignore_ascii_case(name))
            .map(|s| s.id.as_str())
    }

    /// Paragraph styles to offer, in a useful order.
    pub fn paragraph_styles(&self) -> Vec<(&str, &str)> {
        let mut list: Vec<(&str, &str)> = self
            .styles
            .values()
            .filter(|s| s.kind == "paragraph")
            .map(|s| (s.id.as_str(), s.name.as_str()))
            .collect();
        let rank = |name: &str| -> (u8, String) {
            let l = name.to_ascii_lowercase();
            let r = if l == "normal" {
                0
            } else if l == "title" {
                1
            } else if l == "subtitle" {
                2
            } else if l.starts_with("heading ") {
                3
            } else if l.contains("list") || l.contains("quote") {
                4
            } else {
                5
            };
            (r, l)
        };
        list.sort_by_key(|(_, name)| rank(name));
        list
    }
}

/// Insert or replace a property element among `parent`'s children in the
/// schema's order.
pub fn put_ordered(parent: &mut Element, child: Element, order: &[&str]) {
    let local = child.local().to_owned();
    if let Some(i) = parent.children.iter().position(|n| {
        n.as_element()
            .is_some_and(|e| e.ns == ns::W && e.local() == local)
    }) {
        parent.children[i] = Node::Element(child);
        return;
    }
    let rank = |name: &str| order.iter().position(|o| *o == name).unwrap_or(order.len());
    let mine = rank(&local);
    let at = parent
        .children
        .iter()
        .position(|n| n.as_element().is_some_and(|e| rank(e.local()) > mine))
        .unwrap_or(parent.children.len());
    parent.children.insert(at, Node::Element(child));
}

pub fn remove_child(parent: &mut Element, local: &str) {
    parent.children.retain(|n| {
        !n.as_element()
            .is_some_and(|e| e.ns == ns::W && e.local() == local)
    });
}

/// A `w:` element with a `w:val`.
pub fn wel(prefix: &str, local: &str, val: Option<&str>) -> Element {
    let name = if prefix.is_empty() {
        local.to_owned()
    } else {
        format!("{prefix}:{local}")
    };
    let mut e = Element::new(name, ns::W);
    if let Some(v) = val {
        let attr = if prefix.is_empty() {
            "val".to_owned()
        } else {
            format!("{prefix}:val")
        };
        e.set_attr(&attr, ns::W, v);
    }
    e
}

fn set_toggle(rpr: &mut Element, prefix: &str, local: &str, on: bool) {
    put_ordered(
        rpr,
        wel(prefix, local, if on { None } else { Some("0") }),
        RPR_ORDER,
    );
}

/// Change `rpr` so that, on top of `inherited` effective formatting, the
/// run looks like `want`. Only properties that differ are written.
pub fn write_rpr(rpr: &mut Element, prefix: &str, current: &RunStyle, want: &RunStyle) {
    if want.bold != current.bold {
        set_toggle(rpr, prefix, "b", want.bold);
        set_toggle(rpr, prefix, "bCs", want.bold);
    }
    if want.italic != current.italic {
        set_toggle(rpr, prefix, "i", want.italic);
        set_toggle(rpr, prefix, "iCs", want.italic);
    }
    if want.strike != current.strike {
        remove_child(rpr, "dstrike");
        set_toggle(rpr, prefix, "strike", want.strike);
    }
    if want.caps != current.caps {
        set_toggle(rpr, prefix, "caps", want.caps);
    }
    if want.small_caps != current.small_caps {
        set_toggle(rpr, prefix, "smallCaps", want.small_caps);
    }
    if want.hidden != current.hidden {
        set_toggle(rpr, prefix, "vanish", want.hidden);
    }
    if want.underline != current.underline {
        put_ordered(rpr, wel(prefix, "u", Some(&want.underline)), RPR_ORDER);
    }
    if (want.size - current.size).abs() > 0.01 {
        let half = format!("{}", (want.size * 2.0).round() as i64);
        put_ordered(rpr, wel(prefix, "sz", Some(&half)), RPR_ORDER);
        put_ordered(rpr, wel(prefix, "szCs", Some(&half)), RPR_ORDER);
    }
    if want.color != current.color {
        let v = want.color.map_or("auto".to_owned(), |c| format!("{c:06X}"));
        put_ordered(rpr, wel(prefix, "color", Some(&v)), RPR_ORDER);
    }
    if want.highlight != current.highlight {
        remove_child(rpr, "highlight");
        remove_child(rpr, "shd");
        if let Some(c) = want.highlight {
            match highlight_name(c) {
                Some(name) => put_ordered(rpr, wel(prefix, "highlight", Some(name)), RPR_ORDER),
                None => {
                    let mut shd = wel(prefix, "shd", Some("clear"));
                    let a = |n: &str| {
                        if prefix.is_empty() {
                            n.to_owned()
                        } else {
                            format!("{prefix}:{n}")
                        }
                    };
                    shd.set_attr(&a("color"), ns::W, "auto");
                    shd.set_attr(&a("fill"), ns::W, format!("{c:06X}"));
                    put_ordered(rpr, shd, RPR_ORDER);
                }
            }
        }
    }
    if want.font != current.font && !want.font.is_empty() {
        let a = |n: &str| {
            if prefix.is_empty() {
                n.to_owned()
            } else {
                format!("{prefix}:{n}")
            }
        };
        // Keep the East Asian font and anything else already there; theme
        // fonts would win over the named ones, so they go.
        let mut f = child(rpr, "rFonts")
            .cloned()
            .unwrap_or_else(|| wel(prefix, "rFonts", None));
        for theme in ["asciiTheme", "hAnsiTheme", "cstheme"] {
            f.remove_attr(ns::W, theme);
        }
        f.set_attr(&a("ascii"), ns::W, want.font.clone());
        f.set_attr(&a("hAnsi"), ns::W, want.font.clone());
        f.set_attr(&a("cs"), ns::W, want.font.clone());
        put_ordered(rpr, f, RPR_ORDER);
    }
    if want.vert != current.vert {
        let v = match want.vert.as_deref() {
            Some("super") => "superscript",
            Some("sub") => "subscript",
            _ => "baseline",
        };
        put_ordered(rpr, wel(prefix, "vertAlign", Some(v)), RPR_ORDER);
    }
}

/// Word names its built-in styles in lower case (`heading 1`); show them
/// as Word does.
pub fn display_name(name: &str) -> String {
    let lower_builtin = name.starts_with("heading ")
        || matches!(
            name,
            "caption"
                | "footer"
                | "header"
                | "toc 1"
                | "toc 2"
                | "toc 3"
                | "footnote text"
                | "endnote text"
                | "annotation text"
                | "macro"
        );
    let mut c = name.chars();
    match c.next() {
        Some(f) if lower_builtin => f.to_uppercase().chain(c).collect(),
        _ => name.to_owned(),
    }
}
