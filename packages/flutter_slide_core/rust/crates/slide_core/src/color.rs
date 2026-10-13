//! DrawingML colours: RGB, theme (scheme) colours through the colour map,
//! system and preset colours, and their modifiers (luminance, tint, shade,
//! alpha...).

use std::collections::HashMap;

use doc_xml::{ns, Element};

use crate::scene::Argb;

/// A theme's colour scheme with the master's colour map.
#[derive(Clone, Debug)]
pub struct Palette {
    /// `dk1`, `lt1`, `dk2`, `lt2`, `accent1`..`accent6`, `hlink`, `folHlink`.
    pub scheme: HashMap<String, u32>,
    /// `bg1` -> `lt1`, `tx1` -> `dk1`...
    pub map: HashMap<String, String>,
}

impl Default for Palette {
    fn default() -> Self {
        let scheme = [
            ("dk1", 0x000000),
            ("lt1", 0xFFFFFF),
            ("dk2", 0x44546A),
            ("lt2", 0xE7E6E6),
            ("accent1", 0x4472C4),
            ("accent2", 0xED7D31),
            ("accent3", 0xA5A5A5),
            ("accent4", 0xFFC000),
            ("accent5", 0x5B9BD5),
            ("accent6", 0x70AD47),
            ("hlink", 0x0563C1),
            ("folHlink", 0x954F72),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect();
        let map = [("bg1", "lt1"), ("tx1", "dk1"), ("bg2", "lt2"), ("tx2", "dk2")]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
        Palette { scheme, map }
    }
}

fn hex(v: &str) -> Option<u32> {
    if v.len() == 6 {
        u32::from_str_radix(v, 16).ok()
    } else {
        None
    }
}

impl Palette {
    /// Read a theme's `a:clrScheme`.
    pub fn read_scheme(&mut self, scheme: &Element) {
        for c in scheme.elements() {
            let v = c
                .elements()
                .find_map(|x| match x.local() {
                    "srgbClr" => x.attr(ns::NONE, "val").and_then(hex),
                    "sysClr" => x.attr(ns::NONE, "lastClr").and_then(hex).or_else(|| match x.attr(ns::NONE, "val") {
                        Some("window") => Some(0xFFFFFF),
                        Some("windowText") => Some(0x000000),
                        _ => None,
                    }),
                    _ => None,
                });
            if let Some(v) = v {
                self.scheme.insert(c.local().to_owned(), v);
            }
        }
    }

    /// Apply a `p:clrMap` (or a slide's override).
    pub fn read_map(&mut self, map: &Element) {
        for a in &map.attrs {
            if a.ns == ns::NONE {
                self.map.insert(a.local().to_owned(), a.value.clone());
            }
        }
    }

    pub fn scheme(&self, name: &str) -> u32 {
        let key = self.map.get(name).map(String::as_str).unwrap_or(name);
        self.scheme
            .get(key)
            .or_else(|| self.scheme.get(name))
            .copied()
            .unwrap_or(0)
    }

    /// The colour a colour element (`a:srgbClr`, `a:schemeClr`...) gives;
    /// `ph` is what `phClr` stands for.
    pub fn color(&self, e: &Element, ph: Option<Argb>) -> Option<Argb> {
        let base: Argb = match e.local() {
            "srgbClr" => 0xFF00_0000 | e.attr(ns::NONE, "val").and_then(hex)?,
            "schemeClr" => match e.attr(ns::NONE, "val")? {
                "phClr" => ph.unwrap_or(0xFF00_0000),
                v => 0xFF00_0000 | self.scheme(v),
            },
            "sysClr" => 0xFF00_0000 | e.attr(ns::NONE, "lastClr").and_then(hex).unwrap_or(0),
            "prstClr" => 0xFF00_0000 | preset(e.attr(ns::NONE, "val")?)?,
            "scrgbClr" => {
                let get = |a: &str| e.attr(ns::NONE, a).and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
                let to = |v: f32| (linear_to_srgb(v) * 255.0).round().clamp(0.0, 255.0) as u32;
                0xFF00_0000 | (to(get("r")) << 16) | (to(get("g")) << 8) | to(get("b"))
            }
            "hslClr" => {
                let h = e.attr(ns::NONE, "hue").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 60000.0;
                let s = e.attr(ns::NONE, "sat").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
                let l = e.attr(ns::NONE, "lum").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
                0xFF00_0000 | hsl_to_rgb(h, s, l)
            }
            _ => return None,
        };
        Some(apply_mods(base, e))
    }

    /// The colour of the first colour child of `parent` (a fill element).
    pub fn child_color(&self, parent: &Element, ph: Option<Argb>) -> Option<Argb> {
        parent.elements().find_map(|c| self.color(c, ph))
    }
}

fn linear_to_srgb(v: f32) -> f32 {
    if v <= 0.0031308 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }
}

fn rgb_to_hsl(c: u32) -> (f32, f32, f32) {
    let r = ((c >> 16) & 0xFF) as f32 / 255.0;
    let g = ((c >> 8) & 0xFF) as f32 / 255.0;
    let b = (c & 0xFF) as f32 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;
    if (max - min).abs() < 1e-6 {
        return (0.0, 0.0, l);
    }
    let d = max - min;
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == r {
        (g - b) / d + if g < b { 6.0 } else { 0.0 }
    } else if max == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    (h * 60.0, s, l)
}

fn hsl_to_rgb(h: f32, s: f32, l: f32) -> u32 {
    let h = h.rem_euclid(360.0) / 360.0;
    let s = s.clamp(0.0, 1.0);
    let l = l.clamp(0.0, 1.0);
    let to = |v: f32| (v * 255.0).round().clamp(0.0, 255.0) as u32;
    if s == 0.0 {
        let v = to(l);
        return (v << 16) | (v << 8) | v;
    }
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    let hue = |mut t: f32| {
        if t < 0.0 {
            t += 1.0;
        }
        if t > 1.0 {
            t -= 1.0;
        }
        if t < 1.0 / 6.0 {
            p + (q - p) * 6.0 * t
        } else if t < 0.5 {
            q
        } else if t < 2.0 / 3.0 {
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        } else {
            p
        }
    };
    (to(hue(h + 1.0 / 3.0)) << 16) | (to(hue(h)) << 8) | to(hue(h - 1.0 / 3.0))
}

/// Apply a colour element's modifiers.
fn apply_mods(c: Argb, e: &Element) -> Argb {
    let mut alpha = (c >> 24) & 0xFF;
    let mut rgb = c & 0xFF_FFFF;
    for m in e.elements() {
        let v = m.attr(ns::NONE, "val").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0) / 100000.0;
        match m.local() {
            "lumMod" | "lumOff" | "satMod" | "satOff" | "hueMod" | "hueOff" => {
                let (mut h, mut s, mut l) = rgb_to_hsl(rgb);
                match m.local() {
                    "lumMod" => l *= v,
                    "lumOff" => l += v,
                    "satMod" => s *= v,
                    "satOff" => s += v,
                    "hueMod" => h *= v,
                    _ => h += v * 100000.0 / 60000.0,
                }
                rgb = hsl_to_rgb(h, s, l);
            }
            "tint" => {
                let f = |ch: u32| (255.0 - (255.0 - ch as f32) * v).round().clamp(0.0, 255.0) as u32;
                rgb = (f((rgb >> 16) & 0xFF) << 16) | (f((rgb >> 8) & 0xFF) << 8) | f(rgb & 0xFF);
            }
            "shade" => {
                let f = |ch: u32| (ch as f32 * v).round().clamp(0.0, 255.0) as u32;
                rgb = (f((rgb >> 16) & 0xFF) << 16) | (f((rgb >> 8) & 0xFF) << 8) | f(rgb & 0xFF);
            }
            "alpha" => alpha = (v * 255.0).round().clamp(0.0, 255.0) as u32,
            "alphaMod" => alpha = (alpha as f32 * v).round().clamp(0.0, 255.0) as u32,
            "comp" => {
                let (h, s, l) = rgb_to_hsl(rgb);
                rgb = hsl_to_rgb(h + 180.0, s, l);
            }
            "inv" => rgb ^= 0xFF_FFFF,
            "gray" => {
                let g = (((rgb >> 16) & 0xFF) * 30 + ((rgb >> 8) & 0xFF) * 59 + (rgb & 0xFF) * 11) / 100;
                rgb = (g << 16) | (g << 8) | g;
            }
            _ => {}
        }
    }
    (alpha << 24) | rgb
}

fn preset(name: &str) -> Option<u32> {
    Some(match name {
        "black" => 0x000000,
        "white" => 0xFFFFFF,
        "red" => 0xFF0000,
        "green" => 0x008000,
        "lime" => 0x00FF00,
        "blue" => 0x0000FF,
        "yellow" => 0xFFFF00,
        "cyan" | "aqua" => 0x00FFFF,
        "magenta" | "fuchsia" => 0xFF00FF,
        "gray" | "grey" => 0x808080,
        "silver" => 0xC0C0C0,
        "darkGray" | "dkGray" => 0xA9A9A9,
        "lightGray" | "ltGray" => 0xD3D3D3,
        "orange" => 0xFFA500,
        "purple" => 0x800080,
        "brown" => 0xA52A2A,
        "navy" => 0x000080,
        "maroon" => 0x800000,
        "olive" => 0x808000,
        "teal" => 0x008080,
        "pink" => 0xFFC0CB,
        "gold" => 0xFFD700,
        "darkBlue" | "dkBlue" => 0x00008B,
        "darkRed" | "dkRed" => 0x8B0000,
        "darkGreen" | "dkGreen" => 0x006400,
        "lightBlue" | "ltBlue" => 0xADD8E6,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use doc_xml::Document;

    fn el(xml: &str) -> Element {
        let d = Document::parse_str(&format!(r#"<r xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">{xml}</r>"#)).unwrap();
        let e = d.root.elements().next().unwrap().clone();
        e
    }

    #[test]
    fn scheme_colors_and_modifiers() {
        let p = Palette::default();
        assert_eq!(p.color(&el(r#"<a:schemeClr val="tx1"/>"#), None), Some(0xFF000000));
        assert_eq!(p.color(&el(r#"<a:srgbClr val="FF0000"><a:alpha val="50000"/></a:srgbClr>"#), None), Some(0x80FF0000));
        // accent1 lightened 40%: Office's "Lighter 40%".
        let c = p.color(&el(r#"<a:schemeClr val="accent1"><a:lumMod val="60000"/><a:lumOff val="40000"/></a:schemeClr>"#), None).unwrap();
        let near = |a: u32, b: u32| (a as i32 - b as i32).abs() <= 2;
        assert!(near((c >> 16) & 0xFF, 0x8F) && near((c >> 8) & 0xFF, 0xAA) && near(c & 0xFF, 0xDC), "{c:08X}");
    }
}
