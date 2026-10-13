//! DrawingML text: the cascade of list styles down to each run, bullets and
//! automatic numbers, and writing edited text back with each character's
//! original formatting.

use doc_xml::{ns, Element, Node};

use crate::color::Palette;
use crate::scene::{Argb, Bullet, Para, Run, TextBox};
use crate::theme::Theme;

/// A line break inside a paragraph, as the screen sees it.
pub const LINE_BREAK: char = '\u{2028}';

#[derive(Clone, Debug)]
struct RProps {
    size: f32,
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
    color: Argb,
    font: String,
    baseline: i32,
    highlight: Option<Argb>,
}

#[derive(Clone, Debug)]
enum BulletKind {
    None,
    Char(String),
    Auto(String, i32),
}

#[derive(Clone, Debug)]
struct PProps {
    align: String,
    mar_l: f32,
    indent: f32,
    spc_bef: (f32, bool),
    spc_aft: (f32, bool),
    /// Multiple (`false`) or points (`true`).
    line: (f32, bool),
    bullet: BulletKind,
    bu_font: Option<String>,
    bu_color: Option<Argb>,
    bu_size: Option<f32>,
    run: RProps,
}

fn num(e: &Element, a: &str) -> Option<f32> {
    e.attr(ns::NONE, a).and_then(|v| v.parse::<f32>().ok())
}

/// What resolving text needs.
pub struct TextCtx<'a> {
    pub pal: &'a Palette,
    pub theme: &'a Theme,
    /// List styles, least specific first.
    pub lists: Vec<&'a Element>,
    /// The shape style's font colour and font (`major`/`minor`).
    pub font_color: Option<Argb>,
    pub font_ref: Option<String>,
    pub slide_number: usize,
    /// A hyperlink relationship's target.
    pub link: &'a dyn Fn(&str) -> Option<String>,
}

impl<'a> TextCtx<'a> {
    fn apply_rpr(&self, r: &mut RProps, e: &Element) {
        if let Some(v) = num(e, "sz") {
            r.size = v / 100.0;
        }
        if let Some(v) = e.attr(ns::NONE, "b") {
            r.bold = v == "1" || v == "true";
        }
        if let Some(v) = e.attr(ns::NONE, "i") {
            r.italic = v == "1" || v == "true";
        }
        if let Some(v) = e.attr(ns::NONE, "u") {
            r.underline = v != "none";
        }
        if let Some(v) = e.attr(ns::NONE, "strike") {
            r.strike = v != "noStrike";
        }
        if let Some(v) = num(e, "baseline") {
            r.baseline = (v / 1000.0) as i32;
        }
        for c in e.elements() {
            match c.local() {
                "solidFill" => {
                    if let Some(col) = self.pal.child_color(c, None) {
                        r.color = col;
                    }
                }
                "noFill" => r.color &= 0x00FF_FFFF,
                "gradFill" => {
                    if let Some(col) = c.descendants().find_map(|g| self.pal.color(g, None)) {
                        r.color = col;
                    }
                }
                "latin" => {
                    if let Some(f) = c.attr(ns::NONE, "typeface").filter(|f| !f.is_empty()) {
                        r.font = self.theme.font(f);
                    }
                }
                "highlight" => r.highlight = self.pal.child_color(c, None),
                _ => {}
            }
        }
    }

    fn apply_ppr(&self, p: &mut PProps, e: &Element) {
        if let Some(v) = e.attr(ns::NONE, "algn") {
            p.align = v.to_owned();
        }
        if let Some(v) = num(e, "marL") {
            p.mar_l = v / 12700.0;
        }
        if let Some(v) = num(e, "indent") {
            p.indent = v / 12700.0;
        }
        let spacing = |c: &Element| -> Option<(f32, bool)> {
            let x = c.elements().next()?;
            match x.local() {
                "spcPct" => num(x, "val").map(|v| (v / 100000.0, false)),
                "spcPts" => num(x, "val").map(|v| (v / 100.0, true)),
                _ => None,
            }
        };
        for c in e.elements() {
            match c.local() {
                "lnSpc" => {
                    if let Some(v) = spacing(c) {
                        p.line = v;
                    }
                }
                "spcBef" => {
                    if let Some(v) = spacing(c) {
                        p.spc_bef = v;
                    }
                }
                "spcAft" => {
                    if let Some(v) = spacing(c) {
                        p.spc_aft = v;
                    }
                }
                "buNone" => p.bullet = BulletKind::None,
                "buChar" => p.bullet = BulletKind::Char(c.attr(ns::NONE, "char").unwrap_or("\u{2022}").to_owned()),
                "buAutoNum" => {
                    p.bullet = BulletKind::Auto(
                        c.attr(ns::NONE, "type").unwrap_or("arabicPeriod").to_owned(),
                        c.attr(ns::NONE, "startAt").and_then(|v| v.parse().ok()).unwrap_or(1),
                    )
                }
                "buFont" => p.bu_font = c.attr(ns::NONE, "typeface").map(|f| self.theme.font(f)),
                "buFontTx" => p.bu_font = None,
                "buClr" => p.bu_color = self.pal.child_color(c, None),
                "buClrTx" => p.bu_color = None,
                "buSzPct" => p.bu_size = num(c, "val").map(|v| v / 100000.0),
                "buSzTx" => p.bu_size = None,
                "defRPr" => self.apply_rpr(&mut p.run, c),
                _ => {}
            }
        }
    }

    /// Paragraph formatting at a level (1-based) before the paragraph's own
    /// properties.
    fn level(&self, lvl: usize) -> PProps {
        let mut p = PProps {
            align: "l".into(),
            mar_l: 0.0,
            indent: 0.0,
            spc_bef: (0.0, true),
            spc_aft: (0.0, true),
            line: (1.0, false),
            bullet: BulletKind::None,
            bu_font: None,
            bu_color: None,
            bu_size: None,
            run: RProps {
                size: 18.0,
                bold: false,
                italic: false,
                underline: false,
                strike: false,
                color: 0xFF00_0000 | self.pal.scheme("tx1"),
                font: self.theme.minor.clone(),
                baseline: 0,
                highlight: None,
            },
        };
        let name = format!("lvl{lvl}pPr");
        for list in &self.lists {
            if let Some(d) = list.elements().find(|e| e.local() == "defPPr") {
                self.apply_ppr(&mut p, d);
            }
            if let Some(l) = list.elements().find(|e| e.local() == name) {
                self.apply_ppr(&mut p, l);
            }
        }
        if let Some(c) = self.font_color {
            p.run.color = c;
        }
        if let Some(f) = &self.font_ref {
            p.run.font = if f == "major" { self.theme.major.clone() } else { self.theme.minor.clone() };
        }
        p
    }

    /// A text body's paragraphs (with `a:bodyPr` handled by the caller).
    pub fn paras(&self, body: &Element, scale: f32, line_reduction: f32) -> Vec<Para> {
        let mut out = Vec::new();
        // Automatic numbers count per level.
        let mut counters: Vec<(usize, String, i32)> = Vec::new();
        for p in body.elements().filter(|e| e.local() == "p") {
            let ppr = p.elements().find(|e| e.local() == "pPr");
            let lvl = ppr.and_then(|e| num(e, "lvl")).map_or(1, |v| v as usize + 1).clamp(1, 9);
            let mut props = self.level(lvl);
            if let Some(e) = ppr {
                self.apply_ppr(&mut props, e);
            }
            let mut runs = Vec::new();
            for c in p.elements() {
                let (text, rpr) = match c.local() {
                    "r" => (
                        c.elements().find(|e| e.local() == "t").map(|t| t.text()).unwrap_or_default(),
                        c.elements().find(|e| e.local() == "rPr"),
                    ),
                    "br" => (LINE_BREAK.to_string(), c.elements().find(|e| e.local() == "rPr")),
                    "fld" => {
                        let t = if c.attr(ns::NONE, "type") == Some("slidenum") {
                            self.slide_number.to_string()
                        } else {
                            c.elements().find(|e| e.local() == "t").map(|t| t.text()).unwrap_or_default()
                        };
                        (t, c.elements().find(|e| e.local() == "rPr"))
                    }
                    _ => continue,
                };
                let mut r = props.run.clone();
                let mut link = None;
                if let Some(rp) = rpr {
                    self.apply_rpr(&mut r, rp);
                    if let Some(h) = rp.elements().find(|e| e.local() == "hlinkClick") {
                        link = h.attr(ns::R, "id").and_then(|id| (self.link)(id));
                        if link.is_some() && !rp.elements().any(|e| e.local() == "solidFill") {
                            r.color = 0xFF00_0000 | self.pal.scheme("hlink");
                            r.underline = true;
                        }
                    }
                }
                runs.push(Run {
                    text,
                    size: r.size * scale,
                    bold: r.bold,
                    italic: r.italic,
                    underline: r.underline,
                    strike: r.strike,
                    color: r.color,
                    font: r.font,
                    baseline: r.baseline,
                    highlight: r.highlight,
                    link,
                });
            }
            let end_size = {
                let mut r = props.run.clone();
                if let Some(e) = p.elements().find(|e| e.local() == "endParaRPr") {
                    self.apply_rpr(&mut r, e);
                }
                r.size * scale
            };
            let first_size = runs.first().map_or(end_size, |r| r.size);
            let empty = runs.iter().all(|r| r.text.is_empty());
            let bullet = match (&props.bullet, empty) {
                (_, true) | (BulletKind::None, _) => {
                    counters.retain(|(l, _, _)| *l < lvl);
                    None
                }
                (BulletKind::Char(ch), _) => {
                    counters.retain(|(l, _, _)| *l < lvl);
                    let font = props.bu_font.clone().unwrap_or_else(|| props.run.font.clone());
                    let (text, font) = match unsymbol(ch, &font) {
                        Some(t) => (t, String::new()),
                        None => (ch.clone(), font),
                    };
                    Some(Bullet {
                        text,
                        color: props.bu_color.unwrap_or(runs.first().map_or(props.run.color, |r| r.color)),
                        font,
                        size: first_size * props.bu_size.unwrap_or(1.0),
                    })
                }
                (BulletKind::Auto(ty, start), _) => {
                    counters.retain(|(l, _, _)| *l <= lvl);
                    let n = match counters.iter_mut().find(|(l, t, _)| *l == lvl && t == ty) {
                        Some(c) => {
                            c.2 += 1;
                            c.2
                        }
                        None => {
                            counters.retain(|(l, _, _)| *l != lvl);
                            counters.push((lvl, ty.clone(), *start));
                            *start
                        }
                    };
                    Some(Bullet {
                        text: auto_number(ty, n),
                        color: props.bu_color.unwrap_or(runs.first().map_or(props.run.color, |r| r.color)),
                        font: runs.first().map_or(props.run.font.clone(), |r| r.font.clone()),
                        size: first_size * props.bu_size.unwrap_or(1.0),
                    })
                }
            };
            let spacing = |(v, pts): (f32, bool)| if pts { v } else { v * first_size };
            let (line, line_points) = match props.line {
                (v, true) => (v * scale, true),
                (v, false) => ((v - line_reduction).max(0.5), false),
            };
            out.push(Para {
                align: props.align.clone(),
                level: (lvl - 1) as u8,
                margin_left: props.mar_l,
                indent: props.indent,
                space_before: spacing(props.spc_bef),
                space_after: spacing(props.spc_aft),
                line,
                line_points,
                bullet,
                runs,
                end_size,
            });
        }
        out
    }
}

/// Bullets drawn with a symbol font (Wingdings, Symbol) as the Unicode
/// characters they show, so they draw without that font.
pub fn unsymbol(text: &str, font: &str) -> Option<String> {
    let f = font.to_ascii_lowercase();
    let wing = f.starts_with("wingdings");
    if !wing && f != "symbol" {
        return None;
    }
    let mut out = String::new();
    for c in text.chars() {
        let mut u = c as u32;
        if (0xF020..=0xF0FF).contains(&u) {
            u -= 0xF000;
        }
        let m = if wing {
            match u {
                0x6C => '\u{25CF}',
                0x6E => '\u{25A0}',
                0x6F => '\u{25A1}',
                0x71 => '\u{2751}',
                0x75 | 0x77 => '\u{25C6}',
                0x76 => '\u{2756}',
                0xA7 => '\u{25AA}',
                0xA8 => '\u{25FB}',
                0xD8 => '\u{27A2}',
                0xE0 | 0xE8 => '\u{2794}',
                0xF0 => '\u{21E8}',
                0xFC => '\u{2714}',
                0xFE => '\u{2611}',
                0xFD => '\u{2612}',
                _ => '\u{2022}',
            }
        } else {
            match u {
                0xB7 => '\u{2022}',
                0xAE => '\u{2192}',
                0xDE => '\u{21D2}',
                0x2D => '\u{2212}',
                0xA8 => '\u{2666}',
                _ => char::from_u32(u).unwrap_or('\u{2022}'),
            }
        };
        out.push(m);
    }
    Some(out)
}

fn roman(mut n: i32) -> String {
    let table = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")];
    let mut s = String::new();
    for (v, r) in table {
        while n >= v {
            s.push_str(r);
            n -= v;
        }
    }
    s
}

fn letters(n: i32) -> String {
    let n = n.max(1) - 1;
    let c = (b'a' + (n % 26) as u8) as char;
    std::iter::repeat_n(c, (n / 26 + 1) as usize).collect()
}

/// An automatic number in one of DrawingML's schemes.
pub fn auto_number(scheme: &str, n: i32) -> String {
    let (body, upper) = if scheme.starts_with("roman") {
        (roman(n), scheme.starts_with("romanUc"))
    } else if scheme.starts_with("alpha") {
        (letters(n), scheme.starts_with("alphaUc"))
    } else {
        (n.to_string(), false)
    };
    let body = if upper { body.to_uppercase() } else { body };
    if scheme.ends_with("ParenBoth") {
        format!("({body})")
    } else if scheme.ends_with("ParenR") {
        format!("{body})")
    } else if scheme.ends_with("Period") {
        format!("{body}.")
    } else if scheme.ends_with("Minus") {
        format!("- {body} -")
    } else {
        body
    }
}

/// Insets, anchor and wrapping from `a:bodyPr` elements, least specific
/// first.
pub fn body_props(chain: &[&Element]) -> ([f32; 4], String, bool, Option<String>, f32, f32) {
    let mut insets = [7.2, 3.6, 7.2, 3.6];
    let mut anchor = "t".to_owned();
    let mut wrap = true;
    let mut vertical = None;
    let mut scale = 1.0;
    let mut reduction = 0.0;
    for b in chain {
        for (i, a) in ["lIns", "tIns", "rIns", "bIns"].iter().enumerate() {
            if let Some(v) = num(b, a) {
                insets[i] = v / 12700.0;
            }
        }
        if let Some(v) = b.attr(ns::NONE, "anchor") {
            anchor = v.to_owned();
        }
        if let Some(v) = b.attr(ns::NONE, "wrap") {
            wrap = v != "none";
        }
        if let Some(v) = b.attr(ns::NONE, "vert") {
            vertical = (v != "horz").then(|| v.to_owned());
        }
        if let Some(fit) = b.elements().find(|e| e.local() == "normAutofit") {
            scale = num(fit, "fontScale").map_or(1.0, |v| v / 100000.0);
            reduction = num(fit, "lnSpcReduction").map_or(0.0, |v| v / 100000.0);
        } else if b.elements().any(|e| e.local() == "noAutofit" || e.local() == "spAutoFit") {
            scale = 1.0;
            reduction = 0.0;
        }
    }
    (insets, anchor, wrap, vertical, scale, reduction)
}

/// A text box from its body and context.
pub fn text_box(ctx: &TextCtx, body: &Element, body_chain: &[&Element], prompt: Option<String>) -> TextBox {
    let (insets, anchor, wrap, vertical, scale, reduction) = body_props(body_chain);
    let paras = ctx.paras(body, scale, reduction);
    let empty = paras.iter().all(|p| p.runs.iter().all(|r| r.text.is_empty()));
    TextBox {
        insets,
        anchor,
        wrap,
        vertical,
        paras,
        prompt: if empty { prompt } else { None },
    }
}

// --- Writing edited text back

#[derive(Clone)]
enum Unit {
    Char(Option<Element>),
    Break(Option<Element>),
    /// A whole field, kept when its text is.
    Field(Element, usize),
}

/// The characters of a paragraph with their run properties.
fn units(p: &Element) -> (Vec<Unit>, String) {
    let mut units = Vec::new();
    let mut text = String::new();
    for c in p.elements() {
        let rpr = c.elements().find(|e| e.local() == "rPr").cloned();
        match c.local() {
            "r" => {
                let t = c.elements().find(|e| e.local() == "t").map(|t| t.text()).unwrap_or_default();
                for ch in t.chars() {
                    units.push(Unit::Char(rpr.clone()));
                    text.push(ch);
                }
            }
            "br" => {
                units.push(Unit::Break(rpr));
                text.push(LINE_BREAK);
            }
            "fld" => {
                let t = c.elements().find(|e| e.local() == "t").map(|t| t.text()).unwrap_or_default();
                let n = t.chars().count();
                for (i, ch) in t.chars().enumerate() {
                    if i == 0 {
                        units.push(Unit::Field(c.clone(), n));
                    } else {
                        units.push(Unit::Char(rpr.clone()));
                    }
                    text.push(ch);
                }
            }
            _ => {}
        }
    }
    (units, text)
}

/// The paragraph's plain text as the screen edits it.
pub fn para_text(p: &Element) -> String {
    units(p).1
}

/// Pairs of equal items (index in `a`, index in `b`), in order.
pub fn lcs<T: PartialEq>(a: &[T], b: &[T]) -> Vec<(usize, usize)> {
    let mut start = 0;
    while start < a.len() && start < b.len() && a[start] == b[start] {
        start += 1;
    }
    let mut end = 0;
    while end < a.len() - start && end < b.len() - start && a[a.len() - 1 - end] == b[b.len() - 1 - end] {
        end += 1;
    }
    let mut pairs: Vec<(usize, usize)> = (0..start).map(|i| (i, i)).collect();
    let am = &a[start..a.len() - end];
    let bm = &b[start..b.len() - end];
    let (n, m) = (am.len(), bm.len());
    if n > 0 && m > 0 && n * m <= 4_000_000 {
        let mut next = vec![0u32; m + 1];
        let mut cur = vec![0u32; m + 1];
        let mut take = vec![0u8; n * m];
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                if am[i] == bm[j] {
                    cur[j] = next[j + 1] + 1;
                    take[i * m + j] = 1;
                } else if next[j] >= cur[j + 1] {
                    cur[j] = next[j];
                    take[i * m + j] = 2;
                } else {
                    cur[j] = cur[j + 1];
                    take[i * m + j] = 3;
                }
            }
            std::mem::swap(&mut next, &mut cur);
        }
        let (mut i, mut j) = (0, 0);
        while i < n && j < m {
            match take[i * m + j] {
                1 => {
                    pairs.push((start + i, start + j));
                    i += 1;
                    j += 1;
                }
                2 => i += 1,
                _ => j += 1,
            }
        }
    }
    for k in 0..end {
        pairs.push((a.len() - end + k, b.len() - end + k));
    }
    pairs
}

fn el(prefix: &str, local: &str) -> Element {
    let name = if prefix.is_empty() { local.to_owned() } else { format!("{prefix}:{local}") };
    Element::new(name, ns::A)
}

/// A paragraph with new text, formatted like `source` character by
/// character.
fn rebuild_para(source: &Element, new_text: &str, a: &str) -> Element {
    let (old_units, old_text) = units(source);
    let old_chars: Vec<char> = old_text.chars().collect();
    let new_chars: Vec<char> = new_text.chars().collect();
    let pairs = lcs(&old_chars, &new_chars);
    let mut map: Vec<Option<usize>> = vec![None; new_chars.len()];
    for (i, j) in &pairs {
        map[*j] = Some(*i);
    }
    let rpr_of = |u: &Unit| -> Option<Element> {
        match u {
            Unit::Char(r) | Unit::Break(r) => r.clone(),
            Unit::Field(f, _) => f.elements().find(|e| e.local() == "rPr").cloned(),
        }
    };
    let fallback = old_units
        .first()
        .map(rpr_of)
        .unwrap_or_else(|| source.elements().find(|e| e.local() == "endParaRPr").cloned().map(|mut e| {
            e.name = if a.is_empty() { "rPr".into() } else { format!("{a}:rPr") };
            e
        }));
    let mut out = source.clone();
    out.children.retain(|n| {
        n.as_element().is_some_and(|e| matches!(e.local(), "pPr" | "endParaRPr"))
    });
    let end = out.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() == "endParaRPr")).unwrap_or(out.children.len());
    let mut nodes: Vec<Node> = Vec::new();
    let mut current: Option<(Option<Element>, String)> = None;
    let flush = |current: &mut Option<(Option<Element>, String)>, nodes: &mut Vec<Node>| {
        if let Some((rpr, text)) = current.take() {
            if text.is_empty() {
                return;
            }
            let mut r = el(a, "r");
            if let Some(rp) = rpr {
                r.push(rp);
            }
            let mut t = el(a, "t");
            t.set_text(text);
            r.push(t);
            nodes.push(Node::Element(r));
        }
    };
    let mut prev_rpr = fallback.clone();
    let mut j = 0;
    while j < new_chars.len() {
        let ch = new_chars[j];
        // A field whose text stayed whole stays a field.
        if let Some(i) = map[j] {
            if let Unit::Field(f, n) = &old_units[i] {
                let whole = (0..*n).all(|k| j + k < new_chars.len() && map[j + k] == Some(i + k));
                if whole {
                    flush(&mut current, &mut nodes);
                    nodes.push(Node::Element(f.clone()));
                    prev_rpr = rpr_of(&old_units[i]);
                    j += n;
                    continue;
                }
            }
        }
        let rpr = match map[j] {
            Some(i) => rpr_of(&old_units[i]),
            None => prev_rpr.clone(),
        };
        prev_rpr = rpr.clone();
        if ch == LINE_BREAK || ch == '\u{B}' {
            flush(&mut current, &mut nodes);
            let mut br = el(a, "br");
            if let Some(rp) = rpr {
                br.push(rp);
            }
            nodes.push(Node::Element(br));
            j += 1;
            continue;
        }
        match &mut current {
            Some((r, text)) if *r == rpr => text.push(ch),
            _ => {
                flush(&mut current, &mut nodes);
                current = Some((rpr, ch.to_string()));
            }
        }
        j += 1;
    }
    flush(&mut current, &mut nodes);
    for (k, n) in nodes.into_iter().enumerate() {
        out.children.insert(end + k, n);
    }
    out
}

/// Give a text body (`p:txBody`, `a:txBody`) new paragraphs: unchanged
/// ones stay as they were, changed ones keep their formatting character
/// by character, new ones are formatted like their neighbours.
pub fn set_text(body: &mut Element, paras: &[String], a: &str) {
    let old: Vec<Element> = body.elements().filter(|e| e.local() == "p").cloned().collect();
    let old_texts: Vec<String> = old.iter().map(para_text).collect();
    let pairs = lcs(&old_texts, paras);
    let matched_old = |j: usize| pairs.iter().find(|(_, jj)| *jj == j).map(|(i, _)| *i);
    let mut new_ps: Vec<Element> = Vec::new();
    let mut prev_old: Option<usize> = None;
    let mut in_gap = 0usize;
    for (j, text) in paras.iter().enumerate() {
        if let Some(i) = matched_old(j) {
            new_ps.push(old[i].clone());
            prev_old = Some(i);
            in_gap = 0;
            continue;
        }
        // Unmatched: take the old paragraphs between the matches around it
        // in order, then the nearest one.
        let gap_start = prev_old.map_or(0, |p| p + 1);
        let next_old = pairs.iter().find(|(_, jj)| *jj > j).map_or(old.len(), |(i, _)| *i);
        let source = if gap_start + in_gap < next_old {
            Some(gap_start + in_gap)
        } else if gap_start < next_old {
            Some(next_old - 1)
        } else {
            prev_old.or_else(|| (next_old < old.len()).then_some(next_old))
        };
        in_gap += 1;
        let p = match source.and_then(|s| old.get(s)) {
            Some(src) => rebuild_para(src, text, a),
            None => {
                let mut p = el(a, "p");
                if !text.is_empty() {
                    let mut r = el(a, "r");
                    let mut t = el(a, "t");
                    t.set_text(text.clone());
                    r.push(t);
                    p.push(r);
                }
                p
            }
        };
        new_ps.push(p);
    }
    if new_ps.is_empty() {
        // A text body needs a paragraph.
        let mut p = old.first().cloned().unwrap_or_else(|| el(a, "p"));
        p.children.retain(|n| n.as_element().is_some_and(|e| matches!(e.local(), "pPr" | "endParaRPr")));
        new_ps.push(p);
    }
    // Put the paragraphs where the old ones were.
    let first = body.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() == "p"));
    body.children.retain(|n| !n.as_element().is_some_and(|e| e.local() == "p"));
    let at = first.unwrap_or(body.children.len()).min(body.children.len());
    for (k, p) in new_ps.into_iter().enumerate() {
        body.children.insert(at + k, Node::Element(p));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use doc_xml::Document;

    fn body(xml: &str) -> Element {
        let d = Document::parse_str(&format!(r#"<p:txBody xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:bodyPr/>{xml}</p:txBody>"#)).unwrap();
        d.root
    }

    #[test]
    fn edits_keep_formatting_per_character() {
        let mut b = body(r#"<a:p><a:r><a:rPr b="1"/><a:t>Bold </a:t></a:r><a:r><a:rPr i="1"/><a:t>italic</a:t></a:r></a:p><a:p><a:r><a:t>Second</a:t></a:r></a:p>"#);
        set_text(&mut b, &["Bold and italic!".into(), "Second".into(), "Third".into()], "a");
        let xml = b.to_xml();
        // Typing after a bold word continues bold, as in PowerPoint.
        assert!(xml.contains(r#"<a:r><a:rPr b="1"/><a:t>Bold and </a:t></a:r>"#), "{xml}");
        assert!(xml.contains(r#"<a:rPr i="1"/><a:t>italic!</a:t>"#), "{xml}");
        assert!(xml.contains("<a:t>Second</a:t>"), "{xml}");
        assert!(xml.contains("<a:t>Third</a:t>"), "{xml}");
        assert_eq!(b.elements().filter(|e| e.local() == "p").count(), 3);
    }

    #[test]
    fn numbers() {
        assert_eq!(auto_number("arabicPeriod", 3), "3.");
        assert_eq!(auto_number("romanUcPeriod", 4), "IV.");
        assert_eq!(auto_number("alphaLcParenR", 2), "b)");
    }
}
