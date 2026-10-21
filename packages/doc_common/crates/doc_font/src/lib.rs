//! Fonts for laying out and embedding text: TrueType and OpenType (`.ttf`,
//! `.otf`, `.ttc`) read from scratch.
//!
//! [`Font`] gives metrics, the character map, advance widths and kerning
//! (the `kern` table and GPOS pair adjustments), and subsets TrueType
//! outlines for embedding. [`FontBook`] indexes the fonts of a few folders
//! (Android's `/system/fonts`, a desktop's font folders) and finds the face
//! for a family, weight and style, with metric-compatible substitutes for
//! Office fonts and fallbacks for characters a face lacks. [`Font::shape`]
//! shapes complex scripts (Indic, Arabic, marks) with the GSUB and GPOS
//! tables.

mod book;
mod gpos;
mod otl;
mod outline;
pub use outline::Seg;
mod shape;
pub use shape::{is_rtl, joins_previous, needs_shaping, Cluster, ShapedGlyph};
mod subset;

use std::collections::HashMap;
use std::sync::Arc;

pub use book::{FaceId, FaceInfo, FontBook};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FontError {
    #[error("this font is damaged: {0}")]
    Corrupt(String),
    #[error("this font is not supported: {0}")]
    Unsupported(String),
}

fn corrupt(m: &str) -> FontError {
    FontError::Corrupt(m.into())
}

pub(crate) fn u16_at(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*b.get(i)?, *b.get(i + 1)?]))
}

pub(crate) fn i16_at(b: &[u8], i: usize) -> Option<i16> {
    u16_at(b, i).map(|v| v as i16)
}

pub(crate) fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_be_bytes([*b.get(i)?, *b.get(i + 1)?, *b.get(i + 2)?, *b.get(i + 3)?]))
}

/// The character map subtable in use.
#[derive(Debug, Clone)]
enum Cmap {
    None,
    /// Format 4 at this offset; `symbol` fonts map U+F0xx.
    Format4 { at: usize, symbol: bool },
    Format12 { at: usize },
}

/// One face of a font file.
#[derive(Clone)]
pub struct Font {
    data: Arc<Vec<u8>>,
    tables: Vec<([u8; 4], usize, usize)>,
    pub units_per_em: u16,
    pub ascent: i16,
    pub descent: i16,
    pub line_gap: i16,
    pub cap_height: i16,
    pub x_height: i16,
    pub bbox: [i16; 4],
    pub italic_angle: f32,
    pub family: String,
    pub subfamily: String,
    pub postscript_name: String,
    pub weight: u16,
    pub italic: bool,
    pub monospace: bool,
    pub num_glyphs: u16,
    /// CFF outlines (`.otf`) rather than TrueType ones.
    pub is_cff: bool,
    /// Embedding is not allowed (OS/2 fsType restricted).
    pub restricted: bool,
    cmap: Cmap,
    advances: Vec<u16>,
    kern: HashMap<u32, i16>,
    gpos: Option<gpos::PairKerning>,
}

impl std::fmt::Debug for Font {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Font({} {} w{} {} glyphs)", self.family, self.subfamily, self.weight, self.num_glyphs)
    }
}

/// How many faces a font file holds (more than one for collections).
pub fn face_count(data: &[u8]) -> u32 {
    if data.starts_with(b"ttcf") {
        u32_at(data, 8).unwrap_or(0)
    } else {
        1
    }
}

/// Offsets of a face's table directory.
fn face_offset(data: &[u8], index: u32) -> Result<usize, FontError> {
    if data.starts_with(b"ttcf") {
        let n = u32_at(data, 8).ok_or_else(|| corrupt("collection"))?;
        if index >= n {
            return Err(corrupt("no such face"));
        }
        Ok(u32_at(data, 12 + 4 * index as usize).ok_or_else(|| corrupt("collection"))? as usize)
    } else {
        Ok(0)
    }
}

/// The table directory of a face: (tag, offset, length).
pub(crate) fn table_directory(data: &[u8], base: usize) -> Result<Vec<([u8; 4], usize, usize)>, FontError> {
    let version = u32_at(data, base).ok_or_else(|| corrupt("header"))?;
    if !matches!(version, 0x0001_0000 | 0x4F54_544F | 0x7472_7565) {
        return Err(FontError::Unsupported("not a TrueType or OpenType font".into()));
    }
    let n = u16_at(data, base + 4).ok_or_else(|| corrupt("header"))? as usize;
    let mut out = Vec::with_capacity(n);
    for k in 0..n {
        let r = base + 12 + 16 * k;
        let tag = data.get(r..r + 4).ok_or_else(|| corrupt("directory"))?;
        let off = u32_at(data, r + 8).ok_or_else(|| corrupt("directory"))? as usize;
        let len = u32_at(data, r + 12).ok_or_else(|| corrupt("directory"))? as usize;
        if off.checked_add(len).is_none_or(|end| end > data.len()) {
            continue;
        }
        out.push(([tag[0], tag[1], tag[2], tag[3]], off, len));
    }
    Ok(out)
}

/// A name from the `name` table (Windows Unicode first, then Mac Roman).
pub(crate) fn read_name(name: &[u8], id: u16) -> Option<String> {
    let count = u16_at(name, 2)? as usize;
    let strings = u16_at(name, 4)? as usize;
    let mut mac = None;
    let mut best: Option<(u8, String)> = None;
    for k in 0..count {
        let r = 6 + 12 * k;
        let platform = u16_at(name, r)?;
        let encoding = u16_at(name, r + 2)?;
        let lang = u16_at(name, r + 4)?;
        if u16_at(name, r + 6)? != id {
            continue;
        }
        let len = u16_at(name, r + 8)? as usize;
        let off = u16_at(name, r + 10)? as usize;
        let raw = name.get(strings + off..strings + off + len)?;
        match (platform, encoding) {
            (3, 0) | (3, 1) | (3, 10) | (0, _) => {
                let units: Vec<u16> = raw.chunks_exact(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
                let s = String::from_utf16_lossy(&units);
                // English (United States) wins.
                let rank = if lang == 0x0409 || platform == 0 { 0 } else { 1 };
                if best.as_ref().is_none_or(|(r, _)| rank < *r) {
                    best = Some((rank, s));
                }
            }
            (1, 0) => mac = Some(raw.iter().map(|&b| b as char).collect()),
            _ => {}
        }
    }
    best.map(|(_, s)| s).or(mac)
}

impl Font {
    /// Parse face `index` of a font file.
    pub fn parse(data: Arc<Vec<u8>>, index: u32) -> Result<Font, FontError> {
        let base = face_offset(&data, index)?;
        let tables = table_directory(&data, base)?;
        let get = |tag: &[u8; 4]| tables.iter().find(|t| &t.0 == tag).map(|t| &data[t.1..t.1 + t.2]);
        let head = get(b"head").ok_or_else(|| corrupt("no head table"))?;
        let hhea = get(b"hhea").ok_or_else(|| corrupt("no hhea table"))?;
        let maxp = get(b"maxp").ok_or_else(|| corrupt("no maxp table"))?;
        let units_per_em = u16_at(head, 18).filter(|u| *u > 0).unwrap_or(1000);
        let bbox = [i16_at(head, 36).unwrap_or(0), i16_at(head, 38).unwrap_or(0), i16_at(head, 40).unwrap_or(0), i16_at(head, 42).unwrap_or(0)];
        let num_glyphs = u16_at(maxp, 4).unwrap_or(0);
        let mut ascent = i16_at(hhea, 4).unwrap_or(800);
        let mut descent = i16_at(hhea, 6).unwrap_or(-200);
        let mut line_gap = i16_at(hhea, 8).unwrap_or(0);
        let metrics = u16_at(hhea, 34).unwrap_or(0) as usize;
        let (mut weight, mut italic, mut cap_height, mut x_height, mut restricted) = (400u16, false, 0i16, 0i16, false);
        if let Some(os2) = get(b"OS/2") {
            weight = u16_at(os2, 4).unwrap_or(400);
            let fs_type = u16_at(os2, 8).unwrap_or(0);
            restricted = fs_type & 0x000F == 0x0002;
            let selection = u16_at(os2, 62).unwrap_or(0);
            italic = selection & 1 != 0;
            // Typographic metrics when the font says to use them; else the
            // Windows ones Office lays out with.
            if os2.len() >= 78 {
                if selection & 0x80 != 0 {
                    ascent = i16_at(os2, 68).unwrap_or(ascent);
                    descent = i16_at(os2, 70).unwrap_or(descent);
                    line_gap = i16_at(os2, 72).unwrap_or(line_gap);
                } else {
                    let win_ascent = u16_at(os2, 74).unwrap_or(0) as i16;
                    let win_descent = u16_at(os2, 76).unwrap_or(0) as i16;
                    if win_ascent > 0 {
                        // Office's single line: winAscent + winDescent.
                        let gap = (ascent - descent + line_gap) - (win_ascent + win_descent);
                        ascent = win_ascent;
                        descent = -win_descent;
                        line_gap = gap.max(0);
                    }
                }
            }
            if os2.len() >= 90 {
                x_height = i16_at(os2, 86).unwrap_or(0);
                cap_height = i16_at(os2, 88).unwrap_or(0);
            }
        }
        if cap_height == 0 {
            cap_height = (ascent as f32 * 0.7) as i16;
        }
        if x_height == 0 {
            x_height = (ascent as f32 * 0.5) as i16;
        }
        let (mut italic_angle, mut monospace) = (0.0f32, false);
        if let Some(post) = get(b"post") {
            let fixed = u32_at(post, 4).unwrap_or(0) as i32;
            italic_angle = fixed as f32 / 65536.0;
            monospace = u32_at(post, 12).unwrap_or(0) != 0;
        }
        let name = get(b"name");
        let family = name
            .and_then(|n| read_name(n, 16).or_else(|| read_name(n, 1)))
            .unwrap_or_default();
        let subfamily = name.and_then(|n| read_name(n, 17).or_else(|| read_name(n, 2))).unwrap_or_default();
        let postscript_name = name
            .and_then(|n| read_name(n, 6))
            .unwrap_or_else(|| family.replace(' ', ""))
            .chars()
            .filter(|c| c.is_ascii_graphic() && !"[](){}<>/%".contains(*c))
            .collect();
        if subfamily.to_ascii_lowercase().contains("italic") || subfamily.to_ascii_lowercase().contains("oblique") {
            italic = true;
        }
        let mut advances = Vec::with_capacity(num_glyphs as usize);
        if let Some(hmtx) = get(b"hmtx") {
            let mut last = 0;
            for g in 0..num_glyphs as usize {
                if g < metrics {
                    last = u16_at(hmtx, g * 4).unwrap_or(last);
                }
                advances.push(last);
            }
        }
        let cmap = get(b"cmap").map(|c| (c.as_ptr() as usize - data.as_ptr() as usize, c)).map_or(Cmap::None, |(off, c)| pick_cmap(c, off));
        let mut kern = HashMap::new();
        if let Some(k) = get(b"kern") {
            read_kern(k, &mut kern);
        }
        let gpos = get(b"GPOS").and_then(|g| gpos::PairKerning::read(g, g.as_ptr() as usize - data.as_ptr() as usize));
        let is_cff = get(b"CFF ").is_some() || get(b"CFF2").is_some();
        Ok(Font {
            tables,
            units_per_em,
            ascent,
            descent,
            line_gap,
            cap_height,
            x_height,
            bbox,
            italic_angle,
            family,
            subfamily,
            postscript_name,
            weight,
            italic,
            monospace,
            num_glyphs,
            is_cff,
            restricted,
            cmap,
            advances,
            kern,
            gpos,
            data,
        })
    }

    pub fn table(&self, tag: &[u8; 4]) -> Option<&[u8]> {
        self.tables.iter().find(|t| &t.0 == tag).map(|t| &self.data[t.1..t.1 + t.2])
    }

    pub fn bold(&self) -> bool {
        self.weight >= 600
    }

    /// The glyph for a character, if the face has one.
    pub fn glyph(&self, ch: char) -> Option<u16> {
        let c = ch as u32;
        let d = &self.data[..];
        let g = match self.cmap {
            Cmap::None => None,
            Cmap::Format12 { at } => {
                let n = u32_at(d, at + 12)? as usize;
                let (mut lo, mut hi) = (0usize, n);
                let mut found = None;
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    let r = at + 16 + mid * 12;
                    let start = u32_at(d, r)?;
                    let end = u32_at(d, r + 4)?;
                    if c < start {
                        hi = mid;
                    } else if c > end {
                        lo = mid + 1;
                    } else {
                        found = Some((u32_at(d, r + 8)? + (c - start)) as u16);
                        break;
                    }
                }
                found
            }
            Cmap::Format4 { at, symbol } => {
                let look = |c: u32| -> Option<u16> {
                    if c > 0xFFFF {
                        return None;
                    }
                    let segs = u16_at(d, at + 6)? as usize / 2;
                    let ends = at + 14;
                    let starts = ends + segs * 2 + 2;
                    let deltas = starts + segs * 2;
                    let ranges = deltas + segs * 2;
                    let (mut lo, mut hi) = (0usize, segs);
                    while lo < hi {
                        let mid = (lo + hi) / 2;
                        let end = u16_at(d, ends + mid * 2)? as u32;
                        if end < c {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    if lo >= segs {
                        return None;
                    }
                    let start = u16_at(d, starts + lo * 2)? as u32;
                    if c < start {
                        return None;
                    }
                    let delta = u16_at(d, deltas + lo * 2)?;
                    let range = u16_at(d, ranges + lo * 2)? as usize;
                    if range == 0 {
                        return Some((c as u16).wrapping_add(delta));
                    }
                    let gi = ranges + lo * 2 + range + (c - start) as usize * 2;
                    let g = u16_at(d, gi)?;
                    if g == 0 {
                        return None;
                    }
                    Some(g.wrapping_add(delta))
                };
                let g = look(c);
                if g.is_none_or(|g| g == 0) && symbol && c < 0x100 {
                    look(0xF000 + c)
                } else {
                    g
                }
            }
        };
        g.filter(|g| *g != 0 && *g < self.num_glyphs)
    }

    pub fn has(&self, ch: char) -> bool {
        self.glyph(ch).is_some()
    }

    /// A glyph's advance in font units.
    pub fn advance(&self, gid: u16) -> u16 {
        self.advances.get(gid as usize).copied().unwrap_or(0)
    }

    /// Kerning between two glyphs, font units.
    pub fn kern(&self, left: u16, right: u16) -> i16 {
        if let Some(v) = self.kern.get(&((left as u32) << 16 | right as u32)) {
            return *v;
        }
        match &self.gpos {
            Some(g) => g.kern(&self.data, left, right),
            None => 0,
        }
    }

    /// Width of text at a size, points (no fallback; missing characters
    /// count as the `.notdef` glyph).
    pub fn text_width(&self, text: &str, size: f32) -> f32 {
        let mut w = 0i32;
        let mut prev: Option<u16> = None;
        for ch in text.chars() {
            let g = self.glyph(ch).unwrap_or(0);
            if let Some(p) = prev {
                w += self.kern(p, g) as i32;
            }
            w += self.advance(g) as i32;
            prev = Some(g);
        }
        w as f32 * size / self.units_per_em as f32
    }

    /// A TrueType font file holding only `glyphs` (and the composites'
    /// parts), with glyph ids unchanged, for embedding.
    pub fn subset(&self, glyphs: &std::collections::BTreeSet<u16>) -> Option<Vec<u8>> {
        subset::subset(self, glyphs)
    }

    /// The face as a standalone font file (a collection member taken out),
    /// for embedding CFF fonts whole.
    pub fn standalone(&self) -> Vec<u8> {
        subset::rebuild(self, &self.tables.iter().map(|t| (t.0, self.data[t.1..t.1 + t.2].to_vec())).collect::<Vec<_>>())
    }

    pub fn data(&self) -> &[u8] {
        &self.data
    }

    /// For a CID-keyed CFF face (the CJK fonts), each glyph's CID: PDF
    /// picks such a font's glyphs by CID rather than glyph id. `None` for
    /// every other face.
    pub fn cff_cids(&self) -> Option<Vec<u16>> {
        let cff = self.table(b"CFF ")?;
        let hdr = *cff.get(2)? as usize;
        let (_, names_end) = cff_index(cff, hdr)?;
        let (top, _) = cff_index(cff, names_end)?;
        let (a, b) = top?;
        let d = cff.get(a..b)?;
        let (mut ros, mut charset) = (false, 0usize);
        let mut operands: Vec<f64> = Vec::new();
        let mut i = 0;
        while i < d.len() {
            let b0 = d[i];
            match b0 {
                0..=21 => {
                    let op = if b0 == 12 {
                        i += 1;
                        1200 + *d.get(i)? as u32
                    } else {
                        b0 as u32
                    };
                    match op {
                        1230 => ros = true,
                        15 => charset = operands.last().copied().unwrap_or(0.0).max(0.0) as usize,
                        _ => {}
                    }
                    operands.clear();
                    i += 1;
                }
                28 => {
                    operands.push(i16_at(d, i + 1)? as f64);
                    i += 3;
                }
                29 => {
                    operands.push(u32_at(d, i + 1)? as i32 as f64);
                    i += 5;
                }
                30 => {
                    i += 1;
                    loop {
                        let b = *d.get(i)?;
                        i += 1;
                        if b >> 4 == 0xF || b & 0xF == 0xF {
                            break;
                        }
                    }
                    operands.push(0.0);
                }
                32..=246 => {
                    operands.push(b0 as f64 - 139.0);
                    i += 1;
                }
                247..=250 => {
                    operands.push((b0 as f64 - 247.0) * 256.0 + *d.get(i + 1)? as f64 + 108.0);
                    i += 2;
                }
                251..=254 => {
                    operands.push(-(b0 as f64 - 251.0) * 256.0 - *d.get(i + 1)? as f64 - 108.0);
                    i += 2;
                }
                _ => i += 1,
            }
        }
        if !ros || charset < 3 {
            return None;
        }
        let n = self.num_glyphs as usize;
        let mut out = vec![0u16; n];
        let fmt = *cff.get(charset)?;
        let (mut gid, mut p) = (1usize, charset + 1);
        match fmt {
            0 => {
                while gid < n {
                    out[gid] = u16_at(cff, p)?;
                    p += 2;
                    gid += 1;
                }
            }
            1 | 2 => {
                while gid < n {
                    let first = u16_at(cff, p)?;
                    let left = if fmt == 1 {
                        p += 3;
                        *cff.get(p - 1)? as usize
                    } else {
                        p += 4;
                        u16_at(cff, p - 2)? as usize
                    };
                    for k in 0..=left {
                        if gid >= n {
                            break;
                        }
                        out[gid] = first.wrapping_add(k as u16);
                        gid += 1;
                    }
                }
            }
            _ => return None,
        }
        Some(out)
    }
}

/// A CFF INDEX at `at`: its first item's span and where it ends.
fn cff_index(cff: &[u8], at: usize) -> Option<(Option<(usize, usize)>, usize)> {
    let count = u16_at(cff, at)? as usize;
    if count == 0 {
        return Some((None, at + 2));
    }
    let size = *cff.get(at + 2)? as usize;
    if !(1..=4).contains(&size) {
        return None;
    }
    let off = |k: usize| -> Option<usize> {
        let mut v = 0usize;
        for b in 0..size {
            v = v << 8 | *cff.get(at + 3 + k * size + b)? as usize;
        }
        Some(v)
    };
    let data = at + 3 + (count + 1) * size - 1;
    Some((Some((data + off(0)?, data + off(1)?)), data + off(count)?))
}

fn pick_cmap(c: &[u8], base: usize) -> Cmap {
    let n = u16_at(c, 2).unwrap_or(0) as usize;
    let mut best: Option<(u8, Cmap)> = None;
    for k in 0..n {
        let r = 4 + 8 * k;
        let (Some(p), Some(e), Some(off)) = (u16_at(c, r), u16_at(c, r + 2), u32_at(c, r + 4)) else { continue };
        let off = off as usize;
        let Some(format) = u16_at(c, off) else { continue };
        let rank = match (p, e, format) {
            (3, 10, 12) | (0, 4, 12) | (0, 6, 12) => 0,
            (3, 1, 4) | (0, 3, 4) | (0, 1, 4) | (0, 0, 4) => 1,
            (3, 0, 4) => 2,
            (0, _, 12) => 0,
            _ => continue,
        };
        let cm = match format {
            12 => Cmap::Format12 { at: base + off },
            _ => Cmap::Format4 { at: base + off, symbol: p == 3 && e == 0 },
        };
        if best.as_ref().is_none_or(|(r, _)| rank < *r) {
            best = Some((rank, cm));
        }
    }
    best.map_or(Cmap::None, |(_, c)| c)
}

fn read_kern(k: &[u8], out: &mut HashMap<u32, i16>) {
    let version = u16_at(k, 0).unwrap_or(0);
    if version != 0 {
        return;
    }
    let n = u16_at(k, 2).unwrap_or(0) as usize;
    let mut at = 4;
    for _ in 0..n {
        let Some(len) = u16_at(k, at + 2) else { return };
        let coverage = u16_at(k, at + 4).unwrap_or(0);
        // Format 0, horizontal, not cross-stream or minimum.
        if coverage >> 8 == 0 && coverage & 0x07 == 0x01 {
            let pairs = u16_at(k, at + 6).unwrap_or(0) as usize;
            for p in 0..pairs {
                let r = at + 14 + p * 6;
                let (Some(l), Some(rr), Some(v)) = (u16_at(k, r), u16_at(k, r + 2), i16_at(k, r + 4)) else { break };
                out.insert((l as u32) << 16 | rr as u32, v);
            }
        }
        at += len as usize;
    }
}

#[cfg(test)]
mod tests;
