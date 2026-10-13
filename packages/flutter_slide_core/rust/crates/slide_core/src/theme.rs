//! A theme's fonts and style lists, and resolving fills and lines from
//! shape properties and style references.

use doc_xml::{ns, Document, Element};

use crate::color::Palette;
use crate::scene::{Argb, Fill, Line};

/// What a theme part holds.
#[derive(Clone, Debug, Default)]
pub struct Theme {
    pub major: String,
    pub minor: String,
    /// `a:fillStyleLst`, `a:lnStyleLst`, `a:bgFillStyleLst` entries.
    pub fills: Vec<Element>,
    pub lines: Vec<Element>,
    pub bg_fills: Vec<Element>,
    /// The colour scheme element, applied to palettes.
    pub scheme: Option<Element>,
}

impl Theme {
    pub fn read(doc: &Document) -> Theme {
        let mut t = Theme {
            major: "Calibri Light".into(),
            minor: "Calibri".into(),
            ..Theme::default()
        };
        for e in doc.root.descendants() {
            match e.local() {
                "clrScheme" if t.scheme.is_none() => t.scheme = Some(e.clone()),
                "majorFont" | "minorFont" => {
                    if let Some(face) = e.elements().find(|c| c.local() == "latin").and_then(|l| l.attr(ns::NONE, "typeface")) {
                        if !face.is_empty() {
                            if e.local() == "majorFont" {
                                t.major = face.to_owned();
                            } else {
                                t.minor = face.to_owned();
                            }
                        }
                    }
                }
                "fillStyleLst" => t.fills = e.elements().cloned().collect(),
                "lnStyleLst" => t.lines = e.elements().cloned().collect(),
                "bgFillStyleLst" => t.bg_fills = e.elements().cloned().collect(),
                _ => {}
            }
        }
        t
    }

    /// A font name, with theme references (`+mj-lt`, `+mn-lt`) resolved.
    pub fn font(&self, face: &str) -> String {
        match face {
            f if f.starts_with("+mj") => self.major.clone(),
            f if f.starts_with("+mn") => self.minor.clone(),
            f => f.to_owned(),
        }
    }
}

fn is_fill(e: &Element) -> bool {
    matches!(e.local(), "noFill" | "solidFill" | "gradFill" | "blipFill" | "pattFill" | "grpFill")
}

/// The fill a fill element (`a:solidFill`...) gives. `ph` replaces
/// `phClr`; `image` resolves a picture fill's relationship id.
pub fn fill(e: &Element, pal: &Palette, ph: Option<Argb>, image: &dyn Fn(&str) -> Option<String>) -> Option<Fill> {
    Some(match e.local() {
        "noFill" => Fill::None,
        "solidFill" => Fill::Solid(pal.child_color(e, ph).unwrap_or(0xFF00_0000)),
        "gradFill" => {
            let mut stops: Vec<(f32, Argb)> = e
                .elements()
                .find(|c| c.local() == "gsLst")
                .map(|l| {
                    l.elements()
                        .filter(|g| g.local() == "gs")
                        .filter_map(|g| {
                            let pos = g.attr(ns::NONE, "pos").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
                            pal.child_color(g, ph).map(|c| (pos, c))
                        })
                        .collect()
                })
                .unwrap_or_default();
            stops.sort_by(|a, b| a.0.total_cmp(&b.0));
            if stops.is_empty() {
                return None;
            }
            let lin = e.elements().find(|c| c.local() == "lin");
            let angle = lin.and_then(|l| l.attr(ns::NONE, "ang")).and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 60000.0;
            let radial = e.elements().any(|c| c.local() == "path");
            Fill::Gradient { stops, angle, radial }
        }
        "blipFill" => {
            let id = e.descendants().find(|c| c.local() == "blip").and_then(|b| b.attr(ns::R, "embed"))?;
            Fill::Image { part: image(id)? }
        }
        "pattFill" => {
            // A pattern shows as its foreground, lightened towards the
            // background.
            let fg = e.elements().find(|c| c.local() == "fgClr").and_then(|c| pal.child_color(c, ph)).unwrap_or(0xFF00_0000);
            Fill::Solid(fg)
        }
        _ => return None,
    })
}

/// The fill among an element's children (`p:spPr`, `p:bgPr`, `a:tcPr`).
pub fn fill_in(parent: &Element, pal: &Palette, ph: Option<Argb>, image: &dyn Fn(&str) -> Option<String>) -> Option<Fill> {
    parent.elements().find(|c| is_fill(c)).and_then(|f| fill(f, pal, ph, image))
}

/// The fill a style reference (`a:fillRef`, `p:bgRef`) names.
pub fn fill_ref(r: &Element, theme: &Theme, pal: &Palette, image: &dyn Fn(&str) -> Option<String>) -> Option<Fill> {
    let idx = r.attr(ns::NONE, "idx").and_then(|v| v.parse::<usize>().ok())?;
    let ph = pal.child_color(r, None);
    let style = match idx {
        0 => return Some(Fill::None),
        1..=999 => theme.fills.get(idx - 1)?,
        _ => theme.bg_fills.get(idx - 1001)?,
    };
    fill(style, pal, ph, image)
}

/// A line from `a:ln`, on top of `base` (a style's line).
pub fn line(ln: &Element, pal: &Palette, ph: Option<Argb>, base: Option<Line>) -> Option<Line> {
    let mut l = base.unwrap_or(Line {
        width: 0.75,
        color: 0xFF00_0000,
        dash: "solid".into(),
        head: None,
        tail: None,
    });
    let mut visible = true;
    if let Some(w) = ln.attr(ns::NONE, "w").and_then(|v| v.parse::<f32>().ok()) {
        l.width = w / 12700.0;
    }
    for c in ln.elements() {
        match c.local() {
            "noFill" => visible = false,
            "solidFill" => {
                visible = true;
                l.color = pal.child_color(c, ph).unwrap_or(l.color);
            }
            "gradFill" => {
                if let Some(Fill::Gradient { stops, .. }) = fill(c, pal, ph, &|_| None) {
                    l.color = stops[0].1;
                }
            }
            "prstDash" => l.dash = c.attr(ns::NONE, "val").unwrap_or("solid").to_owned(),
            "headEnd" | "tailEnd" => {
                let ty = c.attr(ns::NONE, "type").filter(|t| *t != "none").map(str::to_owned);
                if c.local() == "headEnd" {
                    l.head = ty;
                } else {
                    l.tail = ty;
                }
            }
            _ => {}
        }
    }
    visible.then_some(l)
}

/// The line a style reference (`a:lnRef`) names.
pub fn line_ref(r: &Element, theme: &Theme, pal: &Palette) -> Option<Line> {
    let idx = r.attr(ns::NONE, "idx").and_then(|v| v.parse::<usize>().ok())?;
    if idx == 0 {
        return None;
    }
    let ph = pal.child_color(r, None);
    let style = theme.lines.get(idx - 1)?;
    line(style, pal, ph, None)
}
