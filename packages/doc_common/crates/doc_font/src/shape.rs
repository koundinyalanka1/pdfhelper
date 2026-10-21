//! Shaping: characters to positioned glyphs with a font's OpenType tables,
//! for scripts where one glyph per character is not enough.
//!
//! [`Font::shape`] splits text into runs of one script and shapes each:
//!
//! - Indic scripts (Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil,
//!   Telugu, Kannada, Malayalam) are cut into syllables; each finds its
//!   base consonant, moves pre-base matras and reph, and goes through the
//!   basic and presentation features in the order the OpenType Indic
//!   specification gives.
//! - Arabic gets joining forms (isolated, initial, medial, final) and its
//!   required ligatures.
//! - Other scripts get the common features (composition, contextual
//!   alternates) and mark positioning.
//!
//! Glyphs come back in clusters (the characters a group of glyphs stands
//! for) in logical order, positioned within the cluster in font units.
//! Lines may break only between clusters; right-to-left order between
//! clusters is the caller's business.

use std::collections::HashMap;
use std::ops::Range;

use crate::otl::{Engine, Gdef, Table, Tag, G, P, GLOBAL};
use crate::Font;

/// A glyph of a cluster, font units from the cluster's origin (y up).
#[derive(Clone, Debug, PartialEq)]
pub struct ShapedGlyph {
    pub gid: u16,
    pub x: i32,
    pub y: i32,
    /// The characters it stands for (empty when another glyph has them).
    pub text: Range<usize>,
}

/// Characters `start..end` of the text and the glyphs showing them.
#[derive(Clone, Debug, PartialEq)]
pub struct Cluster {
    pub start: usize,
    pub end: usize,
    /// Font units.
    pub advance: i32,
    pub glyphs: Vec<ShapedGlyph>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Script {
    Common,
    Inherited,
    Deva,
    Beng,
    Guru,
    Gujr,
    Orya,
    Taml,
    Telu,
    Knda,
    Mlym,
    Arab,
    Hebr,
    Thai,
    Latn,
    Cyrl,
    Grek,
    Other(Tag),
}

fn script(c: char) -> Script {
    use Script::*;
    match c as u32 {
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE00..=0xFE0F | 0xFE20..=0xFE2F | 0x200C | 0x200D => Inherited,
        0x0964 | 0x0965 => Common,
        0x0900..=0x097F | 0xA8E0..=0xA8FF => Deva,
        0x0980..=0x09FF => Beng,
        0x0A00..=0x0A7F => Guru,
        0x0A80..=0x0AFF => Gujr,
        0x0B00..=0x0B7F => Orya,
        0x0B80..=0x0BFF => Taml,
        0x0C00..=0x0C7F => Telu,
        0x0C80..=0x0CFF => Knda,
        0x0D00..=0x0D7F => Mlym,
        0x0600..=0x06FF | 0x0750..=0x077F | 0x0870..=0x08FF | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF => Arab,
        0x0590..=0x05FF | 0xFB1D..=0xFB4F => Hebr,
        0x0E00..=0x0E7F => Thai,
        0x0041..=0x005A | 0x0061..=0x007A | 0x00AA | 0x00BA | 0x00C0..=0x00D6 | 0x00D8..=0x00F6 | 0x00F8..=0x024F | 0x1E00..=0x1EFF | 0x2C60..=0x2C7F | 0xA720..=0xA7FF => Latn,
        0x0370..=0x03FF | 0x1F00..=0x1FFF => Grek,
        0x0400..=0x052F | 0x2DE0..=0x2DFF | 0xA640..=0xA69F => Cyrl,
        0x0000..=0x02FF | 0x2000..=0x2BFF | 0x3000..=0x303F | 0xFF01..=0xFF20 => Common,
        0x0700..=0x074F => Other(*b"syrc"),
        0x0780..=0x07BF => Other(*b"thaa"),
        0x0D80..=0x0DFF => Other(*b"sinh"),
        0x0E80..=0x0EFF => Other(*b"lao "),
        0x0F00..=0x0FFF => Other(*b"tibt"),
        0x1000..=0x109F => Other(*b"mym2"),
        0x1780..=0x17FF => Other(*b"khmr"),
        _ => Other(*b"DFLT"),
    }
}

fn is_complex_other(c: char) -> bool {
    matches!(c as u32, 0x0700..=0x07BF | 0x0D80..=0x0DFF | 0x0E80..=0x0EFF | 0x0F00..=0x0FFF | 0x1000..=0x109F | 0x1780..=0x17FF)
}

/// Whether a character needs shaping (more than its own glyph): complex
/// scripts and combining marks.
pub fn needs_shaping(c: char) -> bool {
    match script(c) {
        Script::Inherited => !matches!(c, '\u{200C}' | '\u{200D}' | '\u{FE00}'..='\u{FE0F}'),
        Script::Deva | Script::Beng | Script::Guru | Script::Gujr | Script::Orya | Script::Taml | Script::Telu | Script::Knda | Script::Mlym => true,
        Script::Arab | Script::Hebr | Script::Thai => true,
        _ => is_complex_other(c) || is_mark(c),
    }
}

/// Whether a character is strongly right-to-left (Hebrew, Arabic and
/// their neighbours).
pub fn is_rtl(c: char) -> bool {
    match c as u32 {
        0x0660..=0x0669 | 0x06F0..=0x06F9 => false,
        0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF | 0x10800..=0x10FFF | 0x1E800..=0x1EFFF => !is_mark(c),
        _ => false,
    }
}

/// Whether a character belongs with the one before it (a combining mark,
/// a dependent vowel sign, a virama, a joiner), so it should keep that
/// character's font.
pub fn joins_previous(c: char) -> bool {
    matches!(c, '\u{200C}' | '\u{200D}') || is_mark(c) || is_indic_sign(c)
}

/// Dependent signs of the Indic blocks: matras, nukta, virama, modifiers.
fn is_indic_sign(c: char) -> bool {
    let u = c as u32;
    if !(0x0900..=0x0D7F).contains(&u) {
        return false;
    }
    let off = u & 0x7F;
    matches!(off, 0x00..=0x03 | 0x3A..=0x3C | 0x3E..=0x4D | 0x51..=0x57 | 0x62 | 0x63) || (u == 0x094E || u == 0x094F)
}

/// Non-spacing marks, roughly (for fonts without glyph classes).
fn is_mark(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x05BF | 0x05C1 | 0x05C2 | 0x05C4 | 0x05C5 | 0x05C7
        | 0x0610..=0x061A | 0x064B..=0x065F | 0x0670 | 0x06D6..=0x06DC | 0x06DF..=0x06E4 | 0x06E7 | 0x06E8 | 0x06EA..=0x06ED
        | 0x0711 | 0x0730..=0x074A | 0x07A6..=0x07B0 | 0x08D3..=0x08E1 | 0x08E3..=0x08FF
        | 0x0E31 | 0x0E34..=0x0E3A | 0x0E47..=0x0E4E | 0x0EB1 | 0x0EB4..=0x0EBC | 0x0EC8..=0x0ECD
        | 0x0D81..=0x0D83 | 0x0DCA..=0x0DDF | 0x0DF2 | 0x0DF3 | 0x0F18 | 0x0F19 | 0x0F35 | 0x0F37 | 0x0F39 | 0x0F71..=0x0F84 | 0x0F86 | 0x0F87 | 0x0F8D..=0x0FBC
        | 0x102B..=0x103E | 0x1056..=0x1059 | 0x105E..=0x1060 | 0x1062..=0x1064 | 0x1067..=0x106D | 0x1071..=0x1074 | 0x1082..=0x108D | 0x108F | 0x109A..=0x109D
        | 0x17B4..=0x17D3 | 0x17DD
        | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

fn is_ignorable(c: char) -> bool {
    matches!(c as u32, 0x00AD | 0x034F | 0x061C | 0x180B..=0x180F | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x206F | 0xFE00..=0xFE0F | 0xFEFF)
}

fn tags(sc: Script) -> Vec<Tag> {
    use Script::*;
    match sc {
        Deva => vec![*b"dev2", *b"deva"],
        Beng => vec![*b"bng2", *b"beng"],
        Guru => vec![*b"gur2", *b"guru"],
        Gujr => vec![*b"gjr2", *b"gujr"],
        Orya => vec![*b"ory2", *b"orya"],
        Taml => vec![*b"tml2", *b"taml"],
        Telu => vec![*b"tel2", *b"telu"],
        Knda => vec![*b"knd2", *b"knda"],
        Mlym => vec![*b"mlm2", *b"mlym"],
        Arab => vec![*b"arab"],
        Hebr => vec![*b"hebr"],
        Thai => vec![*b"thai"],
        Latn => vec![*b"latn"],
        Cyrl => vec![*b"cyrl"],
        Grek => vec![*b"grek"],
        Other(t) if &t == b"mym2" => vec![t, *b"mymr"],
        Other(t) => vec![t],
        Common | Inherited => vec![],
    }
}

fn is_indic(sc: Script) -> bool {
    use Script::*;
    matches!(sc, Deva | Beng | Guru | Gujr | Orya | Taml | Telu | Knda | Mlym)
}

const GPOS_FEATURES: [(Tag, u32); 6] = [(*b"kern", GLOBAL), (*b"dist", GLOBAL), (*b"abvm", GLOBAL), (*b"blwm", GLOBAL), (*b"mark", GLOBAL), (*b"mkmk", GLOBAL)];

impl Font {
    /// Shape text with this face: clusters in logical order.
    pub fn shape(&self, text: &[char]) -> Vec<Cluster> {
        let mut runs: Vec<(usize, usize, Script)> = Vec::new();
        let mut start = 0;
        let mut cur = Script::Common;
        for (k, &c) in text.iter().enumerate() {
            let s = script(c);
            if matches!(s, Script::Common | Script::Inherited) {
                continue;
            }
            if cur == Script::Common {
                cur = s;
                continue;
            }
            if s != cur {
                runs.push((start, k, cur));
                start = k;
                cur = s;
            }
        }
        if start < text.len() {
            runs.push((start, text.len(), cur));
        }
        let mut out = Vec::new();
        for (a, b, sc) in runs {
            for mut c in self.shape_run(&text[a..b], sc) {
                c.start += a;
                c.end += a;
                for g in &mut c.glyphs {
                    if !g.text.is_empty() {
                        g.text = g.text.start + a..g.text.end + a;
                    } else {
                        g.text = a..a;
                    }
                }
                out.push(c);
            }
        }
        out
    }

    fn shape_run(&self, text: &[char], sc: Script) -> Vec<Cluster> {
        let gdef = Gdef::new(self.table(b"GDEF"));
        let tg = tags(sc);
        let sub = self.table(b"GSUB").and_then(|t| Table::new(t, true, &tg)).map(|tab| Engine { tab, gdef });
        let pos = self.table(b"GPOS").and_then(|t| Table::new(t, false, &tg)).map(|tab| Engine { tab, gdef });
        let indic = is_indic(sc);

        let mut buf: Vec<G> = Vec::with_capacity(text.len());
        for (k, &c) in text.iter().enumerate() {
            let parts = if indic { decompose(self, c) } else { None };
            let one = [c];
            let parts: &[char] = match &parts {
                Some(p) => p,
                None => &one,
            };
            for (pi, &p) in parts.iter().enumerate() {
                let gid = self.glyph(p);
                let (cat, ipos) = if indic { indic::cat_pos(p, sc) } else { (0, 0) };
                let g = gid.unwrap_or(0);
                buf.push(G {
                    gid: g,
                    ch: p,
                    mask: GLOBAL,
                    class: if gdef.has_classes() {
                        gdef.class(g)
                    } else if is_mark(p) {
                        3
                    } else {
                        1
                    },
                    cluster: k as u32,
                    src: if pi == 0 { (k as u32, k as u32 + 1) } else { (k as u32 + 1, k as u32 + 1) },
                    cat,
                    pos: ipos,
                    hidden: gid.is_none() && is_ignorable(p),
                    ..G::default()
                });
            }
        }

        if indic {
            indic::shape(self, sub.as_ref(), &mut buf, sc);
        } else if sc == Script::Arab {
            arabic(sub.as_ref(), &mut buf);
        } else if let Some(e) = &sub {
            e.substitute(&mut buf, &[(*b"ccmp", GLOBAL), (*b"locl", GLOBAL)]);
            if matches!(sc, Script::Other(_)) {
                for tag in [b"nukt", b"akhn", b"blwf", b"abvf", b"half", b"pstf", b"vatu", b"cjct"] {
                    e.substitute(&mut buf, &[(*tag, GLOBAL)]);
                }
                e.substitute(&mut buf, &[(*b"pres", GLOBAL), (*b"abvs", GLOBAL), (*b"blws", GLOBAL), (*b"psts", GLOBAL)]);
            }
            let mut f = vec![(*b"rlig", GLOBAL), (*b"rclt", GLOBAL), (*b"calt", GLOBAL)];
            if !matches!(sc, Script::Latn | Script::Cyrl | Script::Grek | Script::Common) {
                f.extend([(*b"liga", GLOBAL), (*b"clig", GLOBAL)]);
            }
            e.substitute(&mut buf, &f);
        }

        let mut ps: Vec<P> = buf.iter().map(|g| P { xa: if g.hidden { 0 } else { self.advance(g.gid) as i32 }, ..P::default() }).collect();
        let gpos_kern = pos.as_ref().is_some_and(|e| e.tab.has(b"kern"));
        if let Some(e) = &pos {
            e.position(&buf, &mut ps, &GPOS_FEATURES);
        }
        if !gpos_kern {
            let mut prev: Option<usize> = None;
            for i in 0..buf.len() {
                if buf[i].class == 3 || buf[i].hidden {
                    continue;
                }
                if let Some(p) = prev {
                    ps[p].xa += self.kern(buf[p].gid, buf[i].gid) as i32;
                }
                prev = Some(i);
            }
        }
        for (g, p) in buf.iter().zip(ps.iter_mut()) {
            if g.hidden || (p.attach.is_some() && g.class == 3) {
                p.xa = 0;
            }
        }
        clusters(&buf, &ps, text.len(), matches!(sc, Script::Arab | Script::Hebr))
    }
}

/// Group glyphs into clusters and place them within each.
fn clusters(buf: &[G], ps: &[P], len: usize, rtl: bool) -> Vec<Cluster> {
    let n = buf.len();
    let mut cl: Vec<u32> = buf.iter().map(|g| g.cluster).collect();
    for i in 0..n {
        if let Some(b) = ps[i].attach {
            if b < i {
                let m = cl[b..=i].iter().copied().min().unwrap_or(0);
                for c in &mut cl[b..=i] {
                    *c = m;
                }
            }
        }
    }
    // (first character, first glyph, end glyph)
    let mut groups: Vec<(u32, usize, usize)> = Vec::new();
    for (i, &c) in cl.iter().enumerate() {
        match groups.last_mut() {
            Some(g) if c <= g.0 => {
                g.2 = i + 1;
                g.0 = g.0.min(c);
                while groups.len() >= 2 && groups[groups.len() - 2].0 >= groups[groups.len() - 1].0 {
                    let last = groups.pop().expect("two groups");
                    let prev = groups.last_mut().expect("one group");
                    prev.2 = last.2;
                    prev.0 = prev.0.min(last.0);
                }
            }
            _ => groups.push((c, i, i + 1)),
        }
    }
    if let Some(first) = groups.first_mut() {
        first.0 = 0;
    }
    let mut abs = vec![(0i32, 0i32); n];
    let mut out = Vec::with_capacity(groups.len());
    for (k, &(start, a, b)) in groups.iter().enumerate() {
        let end = groups.get(k + 1).map_or(len, |g| g.0 as usize);
        let mut pen = 0i32;
        let order: Vec<usize> = if rtl { (a..b).rev().collect() } else { (a..b).collect() };
        for &i in &order {
            if ps[i].attach.is_none() {
                abs[i] = (pen + ps[i].xo, ps[i].yo);
                pen += ps[i].xa;
            }
        }
        for i in a..b {
            if let Some(on) = ps[i].attach {
                let (bx, by) = if on < n { abs[on] } else { (0, 0) };
                abs[i] = (bx + ps[i].xo, by + ps[i].yo);
                pen += ps[i].xa;
            }
        }
        let glyphs = (a..b)
            .filter(|&i| !buf[i].hidden)
            .map(|i| {
                let (s, e) = buf[i].src;
                ShapedGlyph {
                    gid: buf[i].gid,
                    x: abs[i].0,
                    y: abs[i].1,
                    text: (s as usize).min(len)..(e as usize).min(len).max((s as usize).min(len)),
                }
            })
            .collect();
        out.push(Cluster { start: start as usize, end: end.max(start as usize), advance: pen, glyphs });
    }
    out
}

/// Split matras and nukta forms the font has no glyph for, decomposed.
fn decompose(font: &Font, c: char) -> Option<Vec<char>> {
    let pair = |a: u32, b: u32| Some(vec![char::from_u32(a)?, char::from_u32(b)?]);
    let parts = match c as u32 {
        // Two-part vowel signs: always split, so the left part can move.
        0x09CB => pair(0x09C7, 0x09BE),
        0x09CC => pair(0x09C7, 0x09D7),
        0x0B48 => pair(0x0B47, 0x0B56),
        0x0B4B => pair(0x0B47, 0x0B3E),
        0x0B4C => pair(0x0B47, 0x0B57),
        0x0BCA => pair(0x0BC6, 0x0BBE),
        0x0BCB => pair(0x0BC7, 0x0BBE),
        0x0BCC => pair(0x0BC6, 0x0BD7),
        0x0D4A => pair(0x0D46, 0x0D3E),
        0x0D4B => pair(0x0D47, 0x0D3E),
        0x0D4C => pair(0x0D46, 0x0D57),
        // Nukta forms only when the font lacks them.
        _ if font.has(c) => None,
        0x0929 => pair(0x0928, 0x093C),
        0x0931 => pair(0x0930, 0x093C),
        0x0934 => pair(0x0933, 0x093C),
        u @ 0x0958..=0x095F => pair([0x0915, 0x0916, 0x0917, 0x091C, 0x0921, 0x0922, 0x092B, 0x092F][(u - 0x0958) as usize], 0x093C),
        0x09DC => pair(0x09A1, 0x09BC),
        0x09DD => pair(0x09A2, 0x09BC),
        0x09DF => pair(0x09AF, 0x09BC),
        0x0A33 => pair(0x0A32, 0x0A3C),
        0x0A36 => pair(0x0A38, 0x0A3C),
        0x0A59 => pair(0x0A16, 0x0A3C),
        0x0A5A => pair(0x0A17, 0x0A3C),
        0x0A5B => pair(0x0A1C, 0x0A3C),
        0x0A5E => pair(0x0A2B, 0x0A3C),
        0x0B5C => pair(0x0B21, 0x0B3C),
        0x0B5D => pair(0x0B22, 0x0B3C),
        _ => None,
    }?;
    parts.iter().all(|p| font.has(*p)).then_some(parts)
}

// ---- Arabic ----

const J_U: u8 = 0;
const J_R: u8 = 1;
const J_D: u8 = 2;
const J_C: u8 = 3;
const J_T: u8 = 4;

/// Arabic joining type.
fn joining(c: char) -> u8 {
    let u = c as u32;
    if is_mark(c) || u == 0x061C {
        return J_T;
    }
    match u {
        0x200D | 0x0640 => J_C,
        0x0620 | 0x0626 | 0x0628 | 0x062A..=0x062E | 0x0633..=0x063F | 0x0641..=0x0647 | 0x0649 | 0x064A | 0x066E | 0x066F => J_D,
        0x0622..=0x0625 | 0x0627 | 0x0629 | 0x062F..=0x0632 | 0x0648 | 0x0671..=0x0673 | 0x0675..=0x0677 => J_R,
        0x0678..=0x0687 | 0x069A..=0x06BF | 0x06C1 | 0x06C2 | 0x06CC | 0x06CE | 0x06D0 | 0x06D1 | 0x06FA..=0x06FC | 0x06FF => J_D,
        0x0688..=0x0699 | 0x06C0 | 0x06C3..=0x06CB | 0x06CD | 0x06CF | 0x06D2 | 0x06D3 | 0x06D5 | 0x06EE | 0x06EF => J_R,
        0x0759..=0x075B | 0x076B | 0x076C | 0x0771 | 0x0773 | 0x0774 | 0x0778 | 0x0779 => J_R,
        0x0750..=0x077F => J_D,
        0x08AA..=0x08AC | 0x08AE | 0x08B1 | 0x08B2 | 0x08B9 => J_R,
        0x08A0..=0x08C9 => J_D,
        _ => J_U,
    }
}

const ISOL: u32 = 2;
const FINA: u32 = 4;
const MEDI: u32 = 8;
const INIT: u32 = 16;

fn arabic(e: Option<&Engine>, buf: &mut Vec<G>) {
    let n = buf.len();
    let mut form = vec![0u32; n];
    let mut prev: Option<(usize, u8)> = None;
    for i in 0..n {
        let t = joining(buf[i].ch);
        if t == J_T {
            continue;
        }
        let joins = matches!(prev, Some((_, pt)) if pt == J_D || pt == J_C) && matches!(t, J_R | J_D | J_C);
        if joins {
            let (p, _) = prev.expect("checked");
            form[p] = match form[p] {
                ISOL => INIT,
                FINA => MEDI,
                f => f,
            };
            form[i] = FINA;
        } else {
            form[i] = ISOL;
        }
        prev = Some((i, t));
    }
    for (g, f) in buf.iter_mut().zip(&form) {
        if joining(g.ch) != J_C {
            g.mask |= f;
        }
    }
    let Some(e) = e else { return };
    e.substitute(buf, &[(*b"ccmp", GLOBAL), (*b"locl", GLOBAL)]);
    for (tag, m) in [(b"isol", ISOL), (b"fina", FINA), (b"medi", MEDI), (b"init", INIT)] {
        e.substitute(buf, &[(*tag, m)]);
    }
    e.substitute(buf, &[(*b"rlig", GLOBAL)]);
    e.substitute(buf, &[(*b"rclt", GLOBAL), (*b"calt", GLOBAL)]);
    e.substitute(buf, &[(*b"liga", GLOBAL), (*b"clig", GLOBAL), (*b"mset", GLOBAL)]);
}

// ---- Indic ----

mod indic {
    use super::*;

    // Categories.
    pub const X: u8 = 0;
    pub const C: u8 = 1;
    pub const V: u8 = 2;
    pub const N: u8 = 3;
    pub const H: u8 = 4;
    pub const ZWNJ: u8 = 5;
    pub const ZWJ: u8 = 6;
    pub const M: u8 = 7;
    pub const SM: u8 = 8;
    pub const PH: u8 = 9;
    pub const RA: u8 = 10;
    pub const REPHA: u8 = 11;

    // Positions, in the order a syllable is sorted into.
    pub const START: u8 = 0;
    pub const RA_TO_BECOME_REPH: u8 = 1;
    pub const PRE_M: u8 = 2;
    pub const PRE_C: u8 = 3;
    pub const BASE_C: u8 = 4;
    pub const AFTER_MAIN: u8 = 5;
    pub const BEFORE_SUB: u8 = 7;
    pub const BELOW_C: u8 = 8;
    pub const AFTER_SUB: u8 = 9;
    pub const POST_C: u8 = 11;
    pub const AFTER_POST: u8 = 12;
    pub const SMVD: u8 = 13;
    pub const END: u8 = 14;

    // Feature masks.
    const RPHF: u32 = 2;
    const HALF: u32 = 4;
    const BLWF: u32 = 8;
    const ABVF: u32 = 16;
    const PSTF: u32 = 32;
    const PREF: u32 = 64;

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Reph {
        AfterMain,
        AfterSub,
        BeforeSub,
        BeforePost,
        AfterPost,
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Mode {
        Implicit,
        Explicit,
        Encoded,
    }

    fn config(sc: Script) -> (u32, Reph, Mode, bool) {
        match sc {
            Script::Deva => (0x0900, Reph::BeforePost, Mode::Implicit, true),
            Script::Beng => (0x0980, Reph::AfterSub, Mode::Implicit, true),
            Script::Guru => (0x0A00, Reph::BeforeSub, Mode::Implicit, true),
            Script::Gujr => (0x0A80, Reph::BeforePost, Mode::Implicit, true),
            Script::Orya => (0x0B00, Reph::AfterMain, Mode::Implicit, true),
            Script::Taml => (0x0B80, Reph::AfterPost, Mode::Implicit, true),
            Script::Telu => (0x0C00, Reph::AfterPost, Mode::Explicit, false),
            Script::Knda => (0x0C80, Reph::AfterPost, Mode::Implicit, false),
            _ => (0x0D00, Reph::AfterMain, Mode::Encoded, true),
        }
    }

    #[derive(Clone, Copy)]
    enum Side {
        Left,
        Right,
        Top,
        Bottom,
    }

    fn side(u: u32) -> Side {
        match u {
            0x093F | 0x094E | 0x09BF | 0x09C7 | 0x09C8 | 0x0A3F | 0x0ABF | 0x0B47 | 0x0BC6..=0x0BC8 | 0x0D46..=0x0D48 => Side::Left,
            0x093A | 0x0945..=0x0948 | 0x0955 | 0x0A47 | 0x0A48 | 0x0A4B | 0x0A4C | 0x0AC5 | 0x0AC7 | 0x0AC8 | 0x0B3F | 0x0B55 | 0x0B56 | 0x0BC0 | 0x0C3E..=0x0C40 | 0x0C46..=0x0C48
            | 0x0C4A..=0x0C4C | 0x0C55 | 0x0CBF | 0x0CC6 | 0x0CCC => Side::Top,
            0x0941..=0x0944 | 0x0956 | 0x0957 | 0x0962 | 0x0963 | 0x09C1..=0x09C4 | 0x09E2 | 0x09E3 | 0x0A41 | 0x0A42 | 0x0A75 | 0x0AC1..=0x0AC4 | 0x0AE2 | 0x0AE3 | 0x0B41..=0x0B44
            | 0x0B62 | 0x0B63 | 0x0C56 | 0x0C62 | 0x0C63 | 0x0CE2 | 0x0CE3 | 0x0D41..=0x0D44 | 0x0D62 | 0x0D63 => Side::Bottom,
            _ => Side::Right,
        }
    }

    fn matra_pos(u: u32, sc: Script) -> u8 {
        use Script::*;
        match side(u) {
            Side::Left => PRE_M,
            Side::Right => match sc {
                Deva => AFTER_SUB,
                Beng | Guru | Gujr | Orya | Taml | Mlym => AFTER_POST,
                Telu => {
                    if u <= 0x0C42 {
                        BEFORE_SUB
                    } else {
                        AFTER_SUB
                    }
                }
                Knda => {
                    if !(0x0CC3..=0x0CD6).contains(&u) {
                        BEFORE_SUB
                    } else {
                        AFTER_SUB
                    }
                }
                _ => AFTER_SUB,
            },
            Side::Top => match sc {
                Guru => AFTER_POST,
                Orya => AFTER_MAIN,
                Telu | Knda => BEFORE_SUB,
                _ => AFTER_SUB,
            },
            Side::Bottom => match sc {
                Guru | Gujr | Taml => AFTER_POST,
                Telu | Knda => BEFORE_SUB,
                _ => AFTER_SUB,
            },
        }
    }

    /// A character's category and starting position.
    pub fn cat_pos(c: char, sc: Script) -> (u8, u8) {
        let u = c as u32;
        let cat = match u {
            0x200C => ZWNJ,
            0x200D => ZWJ,
            0x00A0 | 0x25CC => PH,
            0x0C04 | 0x0D04 => SM,
            0x0C84 => X,
            0x0900..=0x0D7F => {
                let off = u & 0x7F;
                let blk = u & !0x7F;
                match off {
                    0x00..=0x03 => SM,
                    0x04..=0x14 => V,
                    0x30 => RA,
                    0x15..=0x39 => C,
                    0x3A | 0x3B | 0x3C if blk == 0x0D00 => H,
                    0x3A | 0x3B => M,
                    0x3C => N,
                    0x3D => X,
                    0x3E..=0x4C => M,
                    0x4D => H,
                    0x4E => match blk {
                        0x0900 => M,
                        0x0980 => C,
                        0x0D00 => REPHA,
                        _ => X,
                    },
                    0x4F if blk == 0x0900 => M,
                    0x51..=0x57 => match (blk, off) {
                        (0x0D00, 0x54..=0x56) => C,
                        (_, 0x55..=0x57) => M,
                        _ => SM,
                    },
                    0x58..=0x5F if blk == 0x0D00 => X,
                    0x58..=0x5F => C,
                    0x60 | 0x61 => V,
                    0x62 | 0x63 => M,
                    0x70..=0x7F => match (blk, off) {
                        (0x0900, 0x72..=0x77) => V,
                        (0x0900, 0x78..=0x7F) => C,
                        (0x0980, 0x70) => RA,
                        (0x0980, 0x71) => C,
                        (0x0A00, 0x70 | 0x71) => SM,
                        (0x0A00, 0x72 | 0x73) => C,
                        (0x0A00, 0x75) => M,
                        (0x0D00, 0x7A..=0x7F) => C,
                        _ => X,
                    },
                    _ => X,
                }
            }
            _ => X,
        };
        let pos = match cat {
            M => matra_pos(u, sc),
            SM => SMVD,
            C | RA | V | PH => BASE_C,
            _ => END,
        };
        (cat, pos)
    }

    fn is_cons(cat: u8) -> bool {
        matches!(cat, C | RA | V | PH)
    }

    fn is_joiner(cat: u8) -> bool {
        cat == ZWJ || cat == ZWNJ
    }

    /// Mark syllables; each takes the cluster of its first character.
    fn syllables(buf: &mut [G]) {
        let n = buf.len();
        let mut i = 0;
        let mut id = 0u32;
        while i < n {
            let s = i;
            let ok;
            if is_cons(buf[i].cat) || buf[i].cat == REPHA {
                ok = buf[i].cat != REPHA;
                i += 1;
                while i < n && buf[i].cat == N {
                    i += 1;
                }
                while i < n && buf[i].cat == H {
                    let mut j = i + 1;
                    while j < n && is_joiner(buf[j].cat) {
                        j += 1;
                    }
                    if j < n && matches!(buf[j].cat, C | RA) {
                        i = j + 1;
                        while i < n && buf[i].cat == N {
                            i += 1;
                        }
                        continue;
                    }
                    i = j;
                    break;
                }
                while i < n && matches!(buf[i].cat, M | N | H | ZWJ | ZWNJ) {
                    i += 1;
                }
                while i < n && buf[i].cat == SM {
                    i += 1;
                }
            } else if matches!(buf[i].cat, M | N | H | SM | ZWJ | ZWNJ) {
                ok = false;
                i += 1;
                while i < n && matches!(buf[i].cat, M | N | H | SM) {
                    i += 1;
                }
            } else {
                ok = false;
                i += 1;
            }
            let cluster = buf[s].cluster;
            for g in &mut buf[s..i] {
                g.syl = id;
                g.syl_ok = ok;
                g.cluster = cluster;
            }
            id += 1;
        }
    }

    fn ranges(buf: &[G]) -> Vec<(usize, usize)> {
        let mut out = Vec::new();
        let mut s = 0;
        for i in 1..=buf.len() {
            if i == buf.len() || buf[i].syl != buf[s].syl {
                out.push((s, i));
                s = i;
            }
        }
        out
    }

    struct Ctx<'a, 'b> {
        e: Option<&'a Engine<'b>>,
        sc: Script,
        reph: Reph,
        mode: Mode,
        blwf_pre: bool,
        virama: u16,
        has_rphf: bool,
        has_pref: bool,
        cache: HashMap<u16, u8>,
    }

    impl Ctx<'_, '_> {
        fn would(&self, tag: &Tag, glyphs: &[u16]) -> bool {
            self.e.is_some_and(|e| e.would(tag, glyphs))
        }

        /// Whether a consonant has a below-base or post-base form.
        fn consonant_pos(&mut self, gid: u16) -> u8 {
            if let Some(p) = self.cache.get(&gid) {
                return *p;
            }
            let v = self.virama;
            let pairs = [[v, gid], [gid, v]];
            let p = if v == 0 || self.e.is_none() {
                BASE_C
            } else if pairs.iter().any(|p| self.would(b"blwf", p) || self.would(b"vatu", p)) {
                BELOW_C
            } else if pairs.iter().any(|p| self.would(b"pstf", p) || self.would(b"pref", p)) {
                POST_C
            } else {
                BASE_C
            };
            self.cache.insert(gid, p);
            p
        }

        fn initial(&mut self, buf: &mut [G], s: usize, end: usize) {
            if !buf[s].syl_ok || end - s < 2 {
                return;
            }
            for i in s..end {
                if matches!(buf[i].cat, C | RA) {
                    buf[i].pos = self.consonant_pos(buf[i].gid);
                }
            }
            let mut base = end;
            let mut has_reph = false;
            let mut limit = s;
            if self.has_rphf
                && s + 3 <= end
                && buf[s].cat == RA
                && buf[s + 1].cat == H
                && ((self.mode == Mode::Implicit && !is_joiner(buf[s + 2].cat)) || (self.mode == Mode::Explicit && buf[s + 2].cat == ZWJ))
            {
                let two = [buf[s].gid, buf[s + 1].gid];
                let three = [buf[s].gid, buf[s + 1].gid, buf[s + 2].gid];
                if self.would(b"rphf", &two) || (self.mode == Mode::Explicit && self.would(b"rphf", &three)) {
                    limit += 2;
                    while limit < end && is_joiner(buf[limit].cat) {
                        limit += 1;
                    }
                    base = s;
                    has_reph = true;
                }
            }
            let mut i = end;
            let mut seen_below = false;
            while i > limit {
                i -= 1;
                let g = buf[i];
                if is_cons(g.cat) {
                    if g.pos != BELOW_C && (g.pos != POST_C || seen_below) {
                        base = i;
                        break;
                    }
                    if g.pos == BELOW_C {
                        seen_below = true;
                    }
                    base = i;
                } else if s < i && g.cat == ZWJ && buf[i - 1].cat == H {
                    break;
                }
            }
            if has_reph && base == s && limit - base <= 2 {
                has_reph = false;
            }
            if base >= end {
                return;
            }
            for g in &mut buf[s..base] {
                g.pos = g.pos.min(PRE_C);
            }
            buf[base].pos = BASE_C;
            if has_reph {
                buf[s].pos = RA_TO_BECOME_REPH;
            }
            // Marks and joiners move with what they follow.
            let mut last_pos = START;
            for i in s..end {
                if matches!(buf[i].cat, ZWJ | ZWNJ | N | H) {
                    buf[i].pos = last_pos;
                    if buf[i].cat == H && buf[i].pos == PRE_M {
                        for j in (s + 1..=i).rev() {
                            if buf[j - 1].pos != PRE_M {
                                buf[i].pos = buf[j - 1].pos;
                                break;
                            }
                        }
                    }
                } else if buf[i].pos != SMVD {
                    last_pos = buf[i].pos;
                }
            }
            // Post-base consonants take what comes before them.
            let mut last = base;
            for i in base + 1..end {
                if is_cons(buf[i].cat) {
                    for j in last + 1..i {
                        if buf[j].pos < SMVD {
                            buf[j].pos = buf[i].pos;
                        }
                    }
                    last = i;
                } else if buf[i].cat == M {
                    last = i;
                }
            }
            buf[s..end].sort_by_key(|g| g.pos);
            let base = (s..end).find(|&i| buf[i].pos == BASE_C).unwrap_or(end);
            for g in &mut buf[s..end] {
                if g.pos != RA_TO_BECOME_REPH {
                    break;
                }
                g.mask |= RPHF;
            }
            let pre = HALF | if self.blwf_pre { BLWF } else { 0 };
            for g in &mut buf[s..base.min(end)] {
                g.mask |= pre;
            }
            if base < end {
                for g in &mut buf[base + 1..end] {
                    g.mask |= BLWF | ABVF | PSTF;
                }
            }
            if self.has_pref && base + 2 < end {
                for i in base + 1..end - 1 {
                    if self.would(b"pref", &[buf[i].gid, buf[i + 1].gid]) {
                        buf[i].mask |= PREF;
                        buf[i + 1].mask |= PREF;
                        break;
                    }
                }
            }
            for i in s + 1..end {
                if is_joiner(buf[i].cat) {
                    let non_joiner = buf[i].cat == ZWNJ;
                    let mut j = i;
                    loop {
                        j -= 1;
                        if non_joiner {
                            buf[j].mask &= !HALF;
                        }
                        if !(j > s && !is_cons(buf[j].cat)) {
                            break;
                        }
                    }
                }
            }
        }

        fn final_(&self, buf: &mut [G], s: usize, end: usize) {
            if !buf[s].syl_ok || end - s < 2 {
                return;
            }
            let mut base = end;
            for i in s..end {
                if buf[i].pos >= BASE_C {
                    base = i;
                    if s < base && buf[base].pos > BASE_C {
                        base -= 1;
                    }
                    break;
                }
            }
            if base == end && s < base && buf[base - 1].cat == ZWJ {
                base -= 1;
            }
            if base < end {
                while s < base && matches!(buf[base].cat, N | H) {
                    base -= 1;
                }
            }

            // A pre-base matra goes after the last halant left standing.
            if s + 1 < end && s < base {
                let mut new_pos = if base == end { base.saturating_sub(2).max(s) } else { base - 1 };
                if !matches!(self.sc, Script::Mlym | Script::Taml) {
                    while new_pos > s && !matches!(buf[new_pos].cat, M | H) {
                        new_pos -= 1;
                    }
                    if !(buf[new_pos].cat == H && buf[new_pos].pos != PRE_M) {
                        new_pos = s;
                    }
                }
                if s < new_pos && buf[new_pos].pos != PRE_M {
                    let mut i = new_pos;
                    while i > s {
                        if buf[i - 1].pos == PRE_M {
                            let old = i - 1;
                            if old < base && base <= new_pos {
                                base -= 1;
                            }
                            buf[old..=new_pos].rotate_left(1);
                            new_pos -= 1;
                        }
                        i -= 1;
                    }
                }
            }

            // Reph moves to its place.
            if s + 1 < end && buf[s].pos == RA_TO_BECOME_REPH && ((buf[s].cat == REPHA) != buf[s].ligated) {
                let mut new_reph = s + 1;
                while new_reph < base && buf[new_reph].cat != H {
                    new_reph += 1;
                }
                if new_reph < base && buf[new_reph].cat == H {
                    if new_reph + 1 < base && is_joiner(buf[new_reph + 1].cat) {
                        new_reph += 1;
                    }
                } else {
                    match self.reph {
                        Reph::AfterMain if base < end => {
                            new_reph = base;
                            while new_reph + 1 < end && buf[new_reph + 1].pos <= AFTER_MAIN {
                                new_reph += 1;
                            }
                        }
                        Reph::AfterSub if base < end => {
                            new_reph = base;
                            while new_reph + 1 < end && !matches!(buf[new_reph + 1].pos, POST_C | AFTER_POST | SMVD) {
                                new_reph += 1;
                            }
                        }
                        _ => {
                            new_reph = end - 1;
                            while new_reph > s && buf[new_reph].pos == SMVD {
                                new_reph -= 1;
                            }
                            if buf[new_reph].cat == H {
                                for i in base + 1..new_reph {
                                    if buf[i].cat == M && new_reph > s + 1 {
                                        new_reph -= 1;
                                    }
                                }
                            }
                        }
                    }
                }
                if new_reph > s {
                    buf[s..=new_reph].rotate_left(1);
                    if s < base && base <= new_reph {
                        base -= 1;
                    }
                }
            }

            // A pre-base-reordering consonant form moves before the base.
            if base + 1 < end {
                for i in base + 1..end {
                    if buf[i].mask & PREF != 0 {
                        if buf[i].ligated {
                            let mut new_pos = base;
                            if !matches!(self.sc, Script::Mlym | Script::Taml) {
                                while new_pos > s && !matches!(buf[new_pos - 1].cat, M | H) {
                                    new_pos -= 1;
                                }
                            }
                            if new_pos > s && buf[new_pos - 1].cat == H && new_pos < end && is_joiner(buf[new_pos].cat) {
                                new_pos += 1;
                            }
                            if new_pos <= i {
                                buf[new_pos..=i].rotate_right(1);
                            }
                        }
                        break;
                    }
                }
            }
        }
    }

    pub fn shape(font: &Font, e: Option<&Engine>, buf: &mut Vec<G>, sc: Script) {
        let (block, reph, mode, blwf_pre) = config(sc);
        let virama = char::from_u32(block + 0x4D).and_then(|c| font.glyph(c)).unwrap_or(0);
        let mut ctx = Ctx {
            e,
            sc,
            reph,
            mode,
            blwf_pre,
            virama,
            has_rphf: e.is_some_and(|e| e.tab.has(b"rphf")),
            has_pref: e.is_some_and(|e| e.tab.has(b"pref")),
            cache: HashMap::new(),
        };
        syllables(buf);
        if let Some(e) = e {
            e.substitute(buf, &[(*b"locl", GLOBAL), (*b"ccmp", GLOBAL)]);
        }
        for (s, end) in ranges(buf) {
            ctx.initial(buf, s, end);
        }
        if let Some(e) = e {
            let basic: [(&Tag, u32); 11] = [
                (b"nukt", GLOBAL),
                (b"akhn", GLOBAL),
                (b"rphf", RPHF),
                (b"rkrf", GLOBAL),
                (b"pref", PREF),
                (b"blwf", BLWF),
                (b"abvf", ABVF),
                (b"half", HALF),
                (b"pstf", PSTF),
                (b"vatu", GLOBAL),
                (b"cjct", GLOBAL),
            ];
            for (tag, m) in basic {
                e.substitute(buf, &[(*tag, m)]);
            }
        }
        for (s, end) in ranges(buf) {
            ctx.final_(buf, s, end);
        }
        if let Some(e) = e {
            let f: Vec<(Tag, u32)> = [b"pres", b"abvs", b"blws", b"psts", b"haln", b"rlig", b"calt", b"clig", b"liga"].iter().map(|t| (**t, GLOBAL)).collect();
            e.substitute(buf, &f);
        }
    }
}
