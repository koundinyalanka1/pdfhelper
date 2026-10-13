//! OpenDocument styles: named styles (`styles.xml`), automatic styles
//! (`content.xml`), their inheritance, and writing new automatic styles for
//! edited text.

use std::collections::HashMap;

use doc_xml::{ns, Element};

use crate::view::{Align, LineSpacing, ParaStyle, RunStyle};

/// A length in points (`0.5in`, `1.27cm`, `12pt`, `10mm`, `1pc`, `16px`).
pub fn length_pt(v: &str) -> Option<f32> {
    let v = v.trim();
    let split = v.find(|c: char| c.is_ascii_alphabetic() || c == '%').unwrap_or(v.len());
    let n: f32 = v[..split].trim().parse().ok()?;
    Some(match &v[split..] {
        "in" => n * 72.0,
        "cm" => n * 72.0 / 2.54,
        "mm" => n * 72.0 / 25.4,
        "pt" | "" => n,
        "pc" => n * 12.0,
        "px" => n * 0.75,
        _ => return None,
    })
}

/// A length for writing, in inches as LibreOffice writes them.
pub fn inches(pt: f32) -> String {
    let v = (pt / 72.0 * 10000.0).round() / 10000.0;
    format!("{v}in")
}

fn color(v: &str) -> Option<u32> {
    let h = v.strip_prefix('#')?;
    (h.len() == 6).then(|| u32::from_str_radix(h, 16).ok()).flatten()
}

/// One style.
#[derive(Clone, Debug)]
pub struct OdfStyle {
    pub name: String,
    pub display: String,
    pub family: String,
    pub parent: Option<String>,
    pub next: Option<String>,
    pub list_style: Option<String>,
    /// `style:default-outline-level` (1-based).
    pub outline: Option<u8>,
    pub ppr: Option<Element>,
    pub tpr: Option<Element>,
    /// Other properties (table, cell, column, graphic).
    pub other: Option<Element>,
    pub automatic: bool,
}

impl OdfStyle {
    pub fn read(e: &Element, automatic: bool) -> Option<OdfStyle> {
        let name = e.attr(ns::STYLE, "name")?.to_owned();
        let prop = |local: &str| e.elements().find(|c| c.ns == ns::STYLE && c.local() == local).cloned();
        Some(OdfStyle {
            display: e.attr(ns::STYLE, "display-name").map(str::to_owned).unwrap_or_else(|| name.replace("_20_", " ")),
            family: e.attr(ns::STYLE, "family").unwrap_or("paragraph").to_owned(),
            parent: e.attr(ns::STYLE, "parent-style-name").map(str::to_owned),
            next: e.attr(ns::STYLE, "next-style-name").map(str::to_owned),
            list_style: e.attr(ns::STYLE, "list-style-name").map(str::to_owned),
            outline: e.attr(ns::STYLE, "default-outline-level").and_then(|v| v.parse().ok()),
            ppr: prop("paragraph-properties"),
            tpr: prop("text-properties"),
            other: e
                .elements()
                .find(|c| c.ns == ns::STYLE && matches!(c.local(), "table-properties" | "table-cell-properties" | "table-column-properties" | "graphic-properties"))
                .cloned(),
            name,
            automatic,
        })
    }
}

/// One level of a list style.
#[derive(Clone, Debug, Default)]
pub struct ListLevel {
    pub bullet: bool,
    pub bullet_char: String,
    /// `1`, `a`, `A`, `i`, `I` or empty.
    pub format: String,
    pub prefix: String,
    pub suffix: String,
    pub start: i64,
    pub display_levels: u8,
}

#[derive(Clone, Debug, Default)]
pub struct ListStyle {
    pub levels: Vec<ListLevel>,
}

impl ListStyle {
    pub fn read(e: &Element) -> ListStyle {
        let mut levels = vec![ListLevel::default(); 10];
        for l in e.elements() {
            let Some(level) = l.attr(ns::TEXT, "level").and_then(|v| v.parse::<usize>().ok()) else { continue };
            if level == 0 || level > 10 {
                continue;
            }
            let bullet = l.local() == "list-level-style-bullet";
            let image = l.local() == "list-level-style-image";
            levels[level - 1] = ListLevel {
                bullet: bullet || image,
                bullet_char: if image { "\u{2022}".into() } else { l.attr(ns::TEXT, "bullet-char").unwrap_or("\u{2022}").to_owned() },
                format: l.attr(ns::STYLE, "num-format").unwrap_or("").to_owned(),
                prefix: l.attr(ns::STYLE, "num-prefix").unwrap_or("").to_owned(),
                suffix: l.attr(ns::STYLE, "num-suffix").unwrap_or("").to_owned(),
                start: l.attr(ns::TEXT, "start-value").and_then(|v| v.parse().ok()).unwrap_or(1),
                display_levels: l.attr(ns::TEXT, "display-levels").and_then(|v| v.parse().ok()).unwrap_or(1),
            };
        }
        ListStyle { levels }
    }

    pub fn is_bullet(&self) -> bool {
        self.levels.first().is_some_and(|l| l.bullet)
    }
}

/// Every style a document's content can refer to.
#[derive(Clone, Debug, Default)]
pub struct OdfStyles {
    pub named: HashMap<(String, String), OdfStyle>,
    pub auto: HashMap<(String, String), OdfStyle>,
    /// `style:default-style` per family.
    pub defaults: HashMap<String, OdfStyle>,
    /// Font face names and their font families.
    pub fonts: HashMap<String, String>,
    pub lists: HashMap<String, ListStyle>,
}

impl OdfStyles {
    /// Read styles from a part's `office:styles`, `office:automatic-styles`
    /// and `office:font-face-decls`.
    pub fn add_part(&mut self, root: &Element, content: bool) {
        for section in root.elements() {
            if section.ns != ns::OFFICE {
                continue;
            }
            let automatic = section.local() == "automatic-styles";
            match section.local() {
                "font-face-decls" => {
                    for f in section.elements() {
                        if let Some(name) = f.attr(ns::STYLE, "name") {
                            let family = f.attr(ns::SVG, "font-family").unwrap_or(name).trim_matches(['\'', '"']).to_owned();
                            self.fonts.insert(name.to_owned(), family);
                        }
                    }
                }
                "styles" | "automatic-styles" => {
                    // Automatic styles of styles.xml serve headers and
                    // footers, not the body.
                    if automatic && !content {
                        continue;
                    }
                    for s in section.elements() {
                        match (s.ns, s.local()) {
                            (n, "style") if n == ns::STYLE => {
                                if let Some(st) = OdfStyle::read(s, automatic) {
                                    let key = (st.family.clone(), st.name.clone());
                                    if automatic {
                                        self.auto.insert(key, st);
                                    } else {
                                        self.named.insert(key, st);
                                    }
                                }
                            }
                            (n, "default-style") if n == ns::STYLE => {
                                let mut e = s.clone();
                                e.set_attr("style:name", ns::STYLE, "");
                                if let Some(st) = OdfStyle::read(&e, false) {
                                    self.defaults.insert(st.family.clone(), st);
                                }
                            }
                            (n, "list-style") if n == ns::TEXT => {
                                if let Some(name) = s.attr(ns::STYLE, "name") {
                                    self.lists.insert(name.to_owned(), ListStyle::read(s));
                                }
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    }

    pub fn get(&self, family: &str, name: &str) -> Option<&OdfStyle> {
        let key = (family.to_owned(), name.to_owned());
        self.auto.get(&key).or_else(|| self.named.get(&key))
    }

    /// The chain from the root ancestor down to `name`.
    pub fn chain(&self, family: &str, name: &str) -> Vec<&OdfStyle> {
        let mut out = Vec::new();
        let mut cur = self.get(family, name);
        while let Some(s) = cur {
            if out.len() > 16 || out.iter().any(|x: &&OdfStyle| x.name == s.name && x.automatic == s.automatic) {
                break;
            }
            out.push(s);
            cur = s.parent.as_deref().and_then(|p| self.named.get(&(family.to_owned(), p.to_owned())));
        }
        out.reverse();
        out
    }

    /// The named style a paragraph's style comes from (itself when named).
    pub fn named_of(&self, name: &str) -> Option<&OdfStyle> {
        let s = self.get("paragraph", name)?;
        if !s.automatic {
            return Some(s);
        }
        s.parent.as_deref().and_then(|p| self.named.get(&("paragraph".to_owned(), p.to_owned())))
    }

    pub fn apply_text(&self, s: &mut RunStyle, tpr: &Element) {
        for a in &tpr.attrs {
            let local = a.local();
            let v = a.value.as_str();
            match (a.ns, local) {
                (n, "font-weight") if n == ns::FO => s.bold = matches!(v, "bold" | "600" | "700" | "800" | "900"),
                (n, "font-style") if n == ns::FO => s.italic = matches!(v, "italic" | "oblique"),
                (n, "font-size") if n == ns::FO => {
                    if let Some(p) = v.strip_suffix('%') {
                        if let Ok(p) = p.parse::<f32>() {
                            s.size *= p / 100.0;
                        }
                    } else if let Some(pt) = length_pt(v) {
                        s.size = pt;
                    }
                }
                (n, "color") if n == ns::FO => s.color = color(v),
                (n, "use-window-font-color") if n == ns::STYLE && v == "true" => s.color = None,
                (n, "background-color") if n == ns::FO => s.highlight = color(v),
                (n, "text-underline-style") if n == ns::STYLE => {
                    s.underline = match v {
                        "none" => "none",
                        "dotted" => "dotted",
                        "dash" | "long-dash" | "dot-dash" | "dot-dot-dash" => "dash",
                        "wave" => "wave",
                        _ => "single",
                    }
                    .into();
                }
                (n, "text-underline-type") if n == ns::STYLE && v == "double" && s.underline != "none" => s.underline = "double".into(),
                (n, "text-line-through-style") if n == ns::STYLE => s.strike = v != "none",
                (n, "font-name") if n == ns::STYLE => {
                    s.font = self.fonts.get(v).cloned().unwrap_or_else(|| v.to_owned());
                }
                (n, "font-family") if n == ns::FO => s.font = v.trim_matches(['\'', '"']).to_owned(),
                (n, "text-position") if n == ns::STYLE => {
                    let first = v.split_whitespace().next().unwrap_or("0%");
                    s.vert = match first {
                        "super" => Some("super".into()),
                        "sub" => Some("sub".into()),
                        p => match p.trim_end_matches('%').parse::<f32>() {
                            Ok(x) if x > 0.0 => Some("super".into()),
                            Ok(x) if x < 0.0 => Some("sub".into()),
                            _ => None,
                        },
                    };
                }
                (n, "text-transform") if n == ns::FO => s.caps = v == "uppercase",
                (n, "font-variant") if n == ns::FO => s.small_caps = v == "small-caps",
                (n, "display") if n == ns::TEXT => s.hidden = v == "none",
                _ => {}
            }
        }
    }

    pub fn apply_para(&self, s: &mut ParaStyle, ppr: &Element) {
        for a in &ppr.attrs {
            let v = a.value.as_str();
            match (a.ns, a.local()) {
                (n, "text-align") if n == ns::FO => {
                    s.align = match v {
                        "center" => Align::Center,
                        "end" | "right" => Align::Right,
                        "justify" => Align::Justify,
                        _ => Align::Left,
                    }
                }
                (n, "margin-left") if n == ns::FO => s.indent_left = length_pt(v).unwrap_or(s.indent_left),
                (n, "margin-right") if n == ns::FO => s.indent_right = length_pt(v).unwrap_or(s.indent_right),
                (n, "text-indent") if n == ns::FO => s.first_line = length_pt(v).unwrap_or(s.first_line),
                (n, "margin-top") if n == ns::FO => s.space_before = length_pt(v).unwrap_or(s.space_before),
                (n, "margin-bottom") if n == ns::FO => s.space_after = length_pt(v).unwrap_or(s.space_after),
                (n, "line-height") if n == ns::FO => {
                    if let Some(p) = v.strip_suffix('%') {
                        if let Ok(p) = p.parse::<f32>() {
                            s.line = LineSpacing::Multiple(p / 100.0);
                        }
                    } else if let Some(pt) = length_pt(v) {
                        s.line = LineSpacing::Exactly(pt);
                    }
                }
                (n, "line-height-at-least") if n == ns::STYLE => {
                    if let Some(pt) = length_pt(v) {
                        s.line = LineSpacing::AtLeast(pt);
                    }
                }
                (n, "keep-with-next") if n == ns::FO => s.keep_next = v == "always",
                (n, "break-before") if n == ns::FO => s.page_break_before = v == "page",
                (n, "background-color") if n == ns::FO => s.shading = color(v),
                (n, "writing-mode") if n == ns::STYLE => s.bidi = v.starts_with("rl"),
                _ => {}
            }
        }
    }

    /// Formatting from the paragraph default and a paragraph style chain.
    pub fn para_style(&self, style_name: Option<&str>, outline: Option<u8>) -> ParaStyle {
        let mut s = ParaStyle::default();
        let mut run = RunStyle {
            font: "Liberation Serif".into(),
            size: 12.0,
            ..RunStyle::default()
        };
        if let Some(d) = self.defaults.get("paragraph") {
            if let Some(p) = &d.ppr {
                self.apply_para(&mut s, p);
            }
            if let Some(t) = &d.tpr {
                self.apply_text(&mut run, t);
            }
        }
        if let Some(name) = style_name {
            for st in self.chain("paragraph", name) {
                if let Some(p) = &st.ppr {
                    self.apply_para(&mut s, p);
                }
                if let Some(t) = &st.tpr {
                    self.apply_text(&mut run, t);
                }
            }
            if let Some(named) = self.named_of(name) {
                s.style_id = named.name.clone();
                s.style_name = named.display.clone();
                s.next_style = named.next.clone().filter(|n| *n != named.name && self.named.contains_key(&("paragraph".to_owned(), n.clone())));
                s.outline_level = named.outline.map(|o| o.saturating_sub(1)).or_else(|| {
                    // Headings named so, without an outline level.
                    let n = named.display.to_ascii_lowercase();
                    n.strip_prefix("heading ").and_then(|l| l.trim().parse::<u8>().ok()).filter(|l| (1..=10).contains(l)).map(|l| l - 1)
                });
            }
        }
        if let Some(o) = outline {
            s.outline_level = Some(o.saturating_sub(1).min(8));
        }
        s.mark = run;
        s
    }

    /// Effective formatting of text in a span of style `span` (and its
    /// ancestors' spans) inside a paragraph.
    pub fn run_style(&self, base: &RunStyle, spans: &[String]) -> RunStyle {
        let mut s = base.clone();
        for span in spans {
            for st in self.chain("text", span) {
                if let Some(t) = &st.tpr {
                    self.apply_text(&mut s, t);
                }
            }
        }
        s
    }

    /// The font face name for a font family, if declared.
    pub fn font_face_for(&self, family: &str) -> Option<&str> {
        self.fonts.iter().find(|(_, f)| f.eq_ignore_ascii_case(family)).map(|(n, _)| n.as_str())
    }
}

/// Text properties that make text look like `want` on top of `base`.
pub fn text_props(base: &RunStyle, want: &RunStyle, font_face: Option<&str>) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    if want.bold != base.bold {
        let v = if want.bold { "bold" } else { "normal" };
        out.push(("fo:font-weight", v.to_owned()));
        out.push(("style:font-weight-asian", v.to_owned()));
        out.push(("style:font-weight-complex", v.to_owned()));
    }
    if want.italic != base.italic {
        let v = if want.italic { "italic" } else { "normal" };
        out.push(("fo:font-style", v.to_owned()));
        out.push(("style:font-style-asian", v.to_owned()));
        out.push(("style:font-style-complex", v.to_owned()));
    }
    if (want.size - base.size).abs() > 0.01 {
        let v = format!("{}pt", (want.size * 10.0).round() / 10.0);
        out.push(("fo:font-size", v.clone()));
        out.push(("style:font-size-asian", v.clone()));
        out.push(("style:font-size-complex", v));
    }
    if want.underline != base.underline {
        let (style, ty) = match want.underline.as_str() {
            "none" => ("none", None),
            "double" => ("solid", Some("double")),
            "dotted" => ("dotted", None),
            "dash" => ("dash", None),
            "wave" => ("wave", None),
            _ => ("solid", None),
        };
        out.push(("style:text-underline-style", style.to_owned()));
        if style != "none" {
            out.push(("style:text-underline-width", "auto".to_owned()));
            out.push(("style:text-underline-color", "font-color".to_owned()));
        }
        if let Some(t) = ty {
            out.push(("style:text-underline-type", t.to_owned()));
        }
    }
    if want.strike != base.strike {
        out.push(("style:text-line-through-style", if want.strike { "solid" } else { "none" }.to_owned()));
        if want.strike {
            out.push(("style:text-line-through-type", "single".to_owned()));
        }
    }
    if want.color != base.color {
        match want.color {
            Some(c) => out.push(("fo:color", format!("#{c:06x}"))),
            None => out.push(("style:use-window-font-color", "true".to_owned())),
        }
    }
    if want.highlight != base.highlight {
        out.push(("fo:background-color", want.highlight.map_or("transparent".to_owned(), |c| format!("#{c:06x}"))));
    }
    if want.font != base.font && !want.font.is_empty() {
        match font_face {
            Some(face) => {
                out.push(("style:font-name", face.to_owned()));
                out.push(("style:font-name-complex", face.to_owned()));
            }
            None => out.push(("fo:font-family", want.font.clone())),
        }
    }
    if want.vert != base.vert {
        let v = match want.vert.as_deref() {
            Some("super") => "super 58%",
            Some("sub") => "sub 58%",
            _ => "0% 100%",
        };
        out.push(("style:text-position", v.to_owned()));
    }
    if want.caps != base.caps {
        out.push(("fo:text-transform", if want.caps { "uppercase" } else { "none" }.to_owned()));
    }
    if want.small_caps != base.small_caps {
        out.push(("fo:font-variant", if want.small_caps { "small-caps" } else { "normal" }.to_owned()));
    }
    if want.hidden != base.hidden {
        out.push(("text:display", if want.hidden { "none" } else { "true" }.to_owned()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths() {
        assert_eq!(length_pt("1in"), Some(72.0));
        assert!((length_pt("2.54cm").unwrap() - 72.0).abs() < 0.01);
        assert_eq!(length_pt("12pt"), Some(12.0));
        assert_eq!(length_pt("-0.5in"), Some(-36.0));
        assert_eq!(inches(36.0), "0.5in");
    }
}
