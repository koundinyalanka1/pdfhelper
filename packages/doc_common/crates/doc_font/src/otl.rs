//! OpenType layout: the GSUB and GPOS lookups of a script's features,
//! applied to a buffer of glyphs.
//!
//! Substitution covers single, multiple, alternate (the first), ligature,
//! contextual, chained contextual, extension and reverse chained lookups.
//! Positioning covers single and pair adjustments, mark-to-base,
//! mark-to-ligature and mark-to-mark attachment, and the contextual kinds;
//! cursive attachment is left out. Lookup flags, mark attachment classes
//! and mark filtering sets are honoured.

use crate::gpos::{class as class_of, coverage};
use crate::{i16_at, u16_at, u32_at};

pub(crate) type Tag = [u8; 4];

/// The mask bit every glyph carries: features that apply everywhere.
pub(crate) const GLOBAL: u32 = 1;

/// How deep contextual lookups may call each other.
const MAX_DEPTH: u8 = 6;

/// A glyph being shaped.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct G {
    pub gid: u16,
    /// The character it came from (the first, for ligatures).
    pub ch: char,
    /// Features that may change it.
    pub mask: u32,
    /// GDEF class: 1 base, 2 ligature, 3 mark, 4 component (0 unknown).
    pub class: u8,
    /// The first character of its cluster.
    pub cluster: u32,
    /// The characters it stands for, `[start, end)` (empty for the later
    /// glyphs of a multiple substitution).
    pub src: (u32, u32),
    /// Shaper data: a category and a position (Indic).
    pub cat: u8,
    pub pos: u8,
    /// Which syllable it belongs to, and whether that syllable reorders.
    pub syl: u32,
    pub syl_ok: bool,
    pub ligated: bool,
    pub substituted: bool,
    /// A default-ignorable character the font cannot show.
    pub hidden: bool,
}

/// Where a glyph goes, font units.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct P {
    pub xa: i32,
    pub xo: i32,
    pub yo: i32,
    /// The glyph a mark hangs on; its offsets are then from that glyph.
    pub attach: Option<usize>,
}

/// The glyph definition table.
#[derive(Clone, Copy, Default)]
pub(crate) struct Gdef<'a> {
    t: &'a [u8],
    classes: usize,
    attach: usize,
    sets: usize,
}

impl<'a> Gdef<'a> {
    pub fn new(t: Option<&'a [u8]>) -> Gdef<'a> {
        let Some(t) = t else { return Gdef::default() };
        let classes = u16_at(t, 4).unwrap_or(0) as usize;
        let attach = u16_at(t, 10).unwrap_or(0) as usize;
        let minor = u16_at(t, 2).unwrap_or(0);
        let sets = if minor >= 2 { u16_at(t, 12).unwrap_or(0) as usize } else { 0 };
        Gdef { t, classes, attach, sets }
    }

    pub fn has_classes(&self) -> bool {
        self.classes != 0
    }

    pub fn class(&self, g: u16) -> u8 {
        if self.classes == 0 {
            0
        } else {
            class_of(self.t, self.classes, g) as u8
        }
    }

    fn mark_attach(&self, g: u16) -> u16 {
        if self.attach == 0 {
            0
        } else {
            class_of(self.t, self.attach, g)
        }
    }

    fn in_set(&self, set: u16, g: u16) -> bool {
        if self.sets == 0 {
            return false;
        }
        let n = u16_at(self.t, self.sets + 2).unwrap_or(0);
        if set >= n {
            return false;
        }
        let Some(off) = u32_at(self.t, self.sets + 4 + set as usize * 4) else { return false };
        coverage(self.t, self.sets + off as usize, g).is_some()
    }
}

/// A lookup: its type, flags and subtables (extensions resolved).
#[derive(Clone, Debug)]
pub(crate) struct Lookup {
    flag: u16,
    filter: u16,
    subs: Vec<(u16, usize)>,
}

/// A GSUB or GPOS table, with the language system of a script chosen.
#[derive(Clone, Copy)]
pub(crate) struct Table<'a> {
    t: &'a [u8],
    gsub: bool,
    lang: usize,
    features: usize,
    lookups: usize,
}

impl<'a> Table<'a> {
    /// The table with the first of `scripts` it has (then `DFLT`, `latn`).
    pub fn new(t: &'a [u8], gsub: bool, scripts: &[Tag]) -> Option<Table<'a>> {
        let sl = u16_at(t, 4)? as usize;
        let features = u16_at(t, 6)? as usize;
        let lookups = u16_at(t, 8)? as usize;
        let n = u16_at(t, sl)? as usize;
        let mut cands: Vec<Tag> = scripts.to_vec();
        cands.extend([*b"DFLT", *b"dflt", *b"latn"]);
        let mut script = None;
        'outer: for want in &cands {
            for k in 0..n {
                let r = sl + 2 + k * 6;
                if t.get(r..r + 4)? == want {
                    script = Some(sl + u16_at(t, r + 4)? as usize);
                    break 'outer;
                }
            }
        }
        let mut lang = 0;
        if let Some(s) = script {
            let default = u16_at(t, s)? as usize;
            if default != 0 {
                lang = s + default;
            } else if u16_at(t, s + 2)? > 0 {
                lang = s + u16_at(t, s + 8)? as usize;
            }
        }
        Some(Table { t, gsub, lang, features, lookups })
    }

    /// The lookups of a feature, in order.
    pub fn lookups(&self, tag: &Tag) -> Vec<u16> {
        let mut out = Vec::new();
        if self.lang == 0 {
            return out;
        }
        let t = self.t;
        let (Some(req), Some(n), Some(fcount)) = (u16_at(t, self.lang + 2), u16_at(t, self.lang + 4), u16_at(t, self.features)) else {
            return out;
        };
        let mut idx: Vec<u16> = (0..n as usize).filter_map(|k| u16_at(t, self.lang + 6 + k * 2)).collect();
        if req != 0xFFFF {
            idx.push(req);
        }
        for fi in idx {
            if fi >= fcount {
                continue;
            }
            let r = self.features + 2 + fi as usize * 6;
            if t.get(r..r + 4) != Some(&tag[..]) {
                continue;
            }
            let Some(off) = u16_at(t, r + 4) else { continue };
            let f = self.features + off as usize;
            let count = u16_at(t, f + 2).unwrap_or(0) as usize;
            out.extend((0..count).filter_map(|i| u16_at(t, f + 4 + i * 2)));
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    pub fn has(&self, tag: &Tag) -> bool {
        !self.lookups(tag).is_empty()
    }

    fn lookup(&self, index: u16) -> Option<Lookup> {
        let t = self.t;
        let n = u16_at(t, self.lookups)?;
        if index >= n {
            return None;
        }
        let l = self.lookups + u16_at(t, self.lookups + 2 + index as usize * 2)? as usize;
        let ty = u16_at(t, l)?;
        let flag = u16_at(t, l + 2)?;
        let count = u16_at(t, l + 4)? as usize;
        let ext = if self.gsub { 7 } else { 9 };
        let mut subs = Vec::with_capacity(count);
        for s in 0..count {
            let Some(off) = u16_at(t, l + 6 + s * 2) else { break };
            let mut st = l + off as usize;
            let mut sty = ty;
            if ty == ext {
                let (Some(real), Some(far)) = (u16_at(t, st + 2), u32_at(t, st + 4)) else { continue };
                sty = real;
                st += far as usize;
            }
            if st < t.len() {
                subs.push((sty, st));
            }
        }
        let filter = if flag & 0x10 != 0 { u16_at(t, l + 6 + count * 2).unwrap_or(0) } else { 0 };
        Some(Lookup { flag, filter, subs })
    }
}

/// A contextual match: the input glyphs and the lookups to apply there.
struct Match {
    at: Vec<usize>,
    records: usize,
    count: usize,
}

/// A table and the glyph definitions, applying lookups.
pub(crate) struct Engine<'a> {
    pub tab: Table<'a>,
    pub gdef: Gdef<'a>,
}

fn value_size(format: u16) -> usize {
    (format & 0xFF).count_ones() as usize * 2
}

impl Engine<'_> {
    fn u(&self, at: usize) -> Option<usize> {
        u16_at(self.tab.t, at).map(|v| v as usize)
    }

    fn ignored(&self, g: &G, flag: u16, filter: u16) -> bool {
        match g.class {
            1 => flag & 2 != 0,
            2 => flag & 4 != 0,
            3 => {
                if flag & 8 != 0 {
                    return true;
                }
                if flag & 0x10 != 0 && !self.gdef.in_set(filter, g.gid) {
                    return true;
                }
                let kind = flag >> 8;
                kind != 0 && self.gdef.mark_attach(g.gid) != kind
            }
            _ => false,
        }
    }

    fn skip(&self, g: &G, lk: &Lookup) -> bool {
        self.ignored(g, lk.flag, lk.filter)
    }

    fn next(&self, buf: &[G], i: usize, lk: &Lookup) -> Option<usize> {
        (i + 1..buf.len()).find(|&j| !self.skip(&buf[j], lk))
    }

    fn prev(&self, buf: &[G], i: usize, lk: &Lookup) -> Option<usize> {
        (0..i).rev().find(|&j| !self.skip(&buf[j], lk))
    }

    fn set_glyph(&self, g: &mut G, gid: u16) {
        g.gid = gid;
        if self.gdef.has_classes() {
            g.class = self.gdef.class(gid);
        }
    }

    /// Lookups of features, merged in lookup order with their masks.
    fn plan(&self, feats: &[(Tag, u32)]) -> Vec<(u16, u32)> {
        let mut plan: Vec<(u16, u32)> = Vec::new();
        for (tag, mask) in feats {
            for l in self.tab.lookups(tag) {
                match plan.iter_mut().find(|p| p.0 == l) {
                    Some(p) => p.1 |= mask,
                    None => plan.push((l, *mask)),
                }
            }
        }
        plan.sort_by_key(|p| p.0);
        plan
    }

    // ---- Matching shared by contextual lookups ----

    fn input(&self, buf: &[G], i: usize, count: usize, lk: &Lookup, f: impl Fn(usize, u16) -> bool) -> Option<Vec<usize>> {
        let mut at = Vec::with_capacity(count);
        at.push(i);
        let mut j = i;
        for k in 1..count {
            j = self.next(buf, j, lk)?;
            if !f(k, buf[j].gid) {
                return None;
            }
            at.push(j);
        }
        Some(at)
    }

    fn back(&self, buf: &[G], i: usize, count: usize, lk: &Lookup, f: impl Fn(usize, u16) -> bool) -> bool {
        let mut j = i;
        for k in 0..count {
            match self.prev(buf, j, lk) {
                Some(p) if f(k, buf[p].gid) => j = p,
                _ => return false,
            }
        }
        true
    }

    fn ahead(&self, buf: &[G], last: usize, count: usize, lk: &Lookup, f: impl Fn(usize, u16) -> bool) -> bool {
        let mut j = last;
        for k in 0..count {
            match self.next(buf, j, lk) {
                Some(n) if f(k, buf[n].gid) => j = n,
                _ => return false,
            }
        }
        true
    }

    fn cov(&self, base: usize, off_at: usize, g: u16) -> bool {
        match self.u(off_at) {
            Some(off) => coverage(self.tab.t, base + off, g).is_some(),
            None => false,
        }
    }

    fn cls(&self, base: usize, raw: usize, g: u16) -> u16 {
        if raw == 0 {
            0
        } else {
            class_of(self.tab.t, base + raw, g)
        }
    }

    /// A contextual (`chain` false) or chained contextual subtable at `i`.
    fn context(&self, buf: &[G], i: usize, chain: bool, st: usize, lk: &Lookup) -> Option<Match> {
        let t = self.tab.t;
        let fmt = u16_at(t, st)?;
        let g = buf[i].gid;
        match (chain, fmt) {
            (false, 1) | (false, 2) => {
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                let (set_index, cd, base_at) = if fmt == 1 { (idx, 0, st + 4) } else { (self.cls(st, self.u(st + 4)?, g) as usize, self.u(st + 4)?, st + 6) };
                let n = self.u(base_at)?;
                if set_index >= n {
                    return None;
                }
                let off = self.u(base_at + 2 + set_index * 2)?;
                if off == 0 {
                    return None;
                }
                let set = st + off;
                for r in 0..self.u(set)? {
                    let rule = set + self.u(set + 2 + r * 2)?;
                    let gc = self.u(rule)?;
                    let sc = self.u(rule + 2)?;
                    if gc == 0 {
                        continue;
                    }
                    let want = |k: usize| u16_at(t, rule + 4 + (k - 1) * 2);
                    let m = self.input(buf, i, gc, lk, |k, gid| match want(k) {
                        Some(w) if fmt == 1 => w == gid,
                        Some(w) => self.cls(st, cd, gid) == w,
                        None => false,
                    });
                    if let Some(at) = m {
                        return Some(Match { at, records: rule + 4 + (gc - 1) * 2, count: sc });
                    }
                }
                None
            }
            (false, 3) => {
                let gc = self.u(st + 2)?;
                let sc = self.u(st + 4)?;
                if gc == 0 || !self.cov(st, st + 6, g) {
                    return None;
                }
                let at = self.input(buf, i, gc, lk, |k, gid| self.cov(st, st + 6 + k * 2, gid))?;
                Some(Match { at, records: st + 6 + gc * 2, count: sc })
            }
            (true, 1) | (true, 2) => {
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                let (set_index, cds, base_at) = if fmt == 1 {
                    (idx, [0, 0, 0], st + 4)
                } else {
                    let cds = [self.u(st + 4)?, self.u(st + 6)?, self.u(st + 8)?];
                    (self.cls(st, cds[1], g) as usize, cds, st + 10)
                };
                let n = self.u(base_at)?;
                if set_index >= n {
                    return None;
                }
                let off = self.u(base_at + 2 + set_index * 2)?;
                if off == 0 {
                    return None;
                }
                let set = st + off;
                let same = |which: usize, w: Option<u16>, gid: u16| match w {
                    Some(w) if fmt == 1 => w == gid,
                    Some(w) => self.cls(st, cds[which], gid) == w,
                    None => false,
                };
                for r in 0..self.u(set)? {
                    let rule = set + self.u(set + 2 + r * 2)?;
                    let bc = self.u(rule)?;
                    let b0 = rule + 2;
                    let ic_at = b0 + bc * 2;
                    let ic = self.u(ic_at)?;
                    if ic == 0 {
                        continue;
                    }
                    let i0 = ic_at + 2;
                    let lc_at = i0 + (ic - 1) * 2;
                    let lc = self.u(lc_at)?;
                    let l0 = lc_at + 2;
                    let sc_at = l0 + lc * 2;
                    let sc = self.u(sc_at)?;
                    let Some(at) = self.input(buf, i, ic, lk, |k, gid| same(1, u16_at(t, i0 + (k - 1) * 2), gid)) else { continue };
                    if !self.back(buf, i, bc, lk, |k, gid| same(0, u16_at(t, b0 + k * 2), gid)) {
                        continue;
                    }
                    if !self.ahead(buf, *at.last()?, lc, lk, |k, gid| same(2, u16_at(t, l0 + k * 2), gid)) {
                        continue;
                    }
                    return Some(Match { at, records: sc_at + 2, count: sc });
                }
                None
            }
            (true, 3) => {
                let bc = self.u(st + 2)?;
                let b0 = st + 4;
                let ic_at = b0 + bc * 2;
                let ic = self.u(ic_at)?;
                let i0 = ic_at + 2;
                let lc_at = i0 + ic * 2;
                let lc = self.u(lc_at)?;
                let l0 = lc_at + 2;
                let sc_at = l0 + lc * 2;
                let sc = self.u(sc_at)?;
                if ic == 0 || !self.cov(st, i0, g) {
                    return None;
                }
                let at = self.input(buf, i, ic, lk, |k, gid| self.cov(st, i0 + k * 2, gid))?;
                if !self.back(buf, i, bc, lk, |k, gid| self.cov(st, b0 + k * 2, gid)) {
                    return None;
                }
                if !self.ahead(buf, *at.last()?, lc, lk, |k, gid| self.cov(st, l0 + k * 2, gid)) {
                    return None;
                }
                Some(Match { at, records: sc_at + 2, count: sc })
            }
            _ => None,
        }
    }

    // ---- Substitution ----

    /// Apply the lookups of some features (one stage) to the buffer.
    pub fn substitute(&self, buf: &mut Vec<G>, feats: &[(Tag, u32)]) {
        for (li, mask) in self.plan(feats) {
            let Some(lk) = self.tab.lookup(li) else { continue };
            if lk.subs.iter().all(|s| s.0 == 8) && !lk.subs.is_empty() {
                for i in (0..buf.len()).rev() {
                    if buf[i].mask & mask != 0 && !self.skip(&buf[i], &lk) {
                        for &(_, st) in &lk.subs {
                            if self.reverse(buf, i, st, &lk) {
                                break;
                            }
                        }
                    }
                }
                continue;
            }
            let mut i = 0;
            let mut guard = 0usize;
            // Each step moves on or shortens the buffer; the cap only stops
            // a font whose lookups would loop.
            let cap = buf.len() * 8 + 1024;
            while i < buf.len() {
                guard += 1;
                if guard > cap {
                    break;
                }
                if buf[i].mask & mask != 0 && !self.skip(&buf[i], &lk) {
                    if let Some(next) = self.sub_at(buf, i, &lk, mask, 0) {
                        i = next;
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    fn sub_at(&self, buf: &mut Vec<G>, i: usize, lk: &Lookup, mask: u32, depth: u8) -> Option<usize> {
        for &(ty, st) in &lk.subs {
            if let Some(n) = self.sub_one(buf, i, ty, st, lk, mask, depth) {
                return Some(n);
            }
        }
        None
    }

    #[allow(clippy::too_many_arguments)]
    fn sub_one(&self, buf: &mut Vec<G>, i: usize, ty: u16, st: usize, lk: &Lookup, mask: u32, depth: u8) -> Option<usize> {
        let t = self.tab.t;
        let g = buf[i].gid;
        match ty {
            1 => {
                let fmt = u16_at(t, st)?;
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                let new = match fmt {
                    1 => g.wrapping_add(u16_at(t, st + 4)?),
                    2 => {
                        if idx >= self.u(st + 4)? {
                            return None;
                        }
                        u16_at(t, st + 6 + idx * 2)?
                    }
                    _ => return None,
                };
                self.set_glyph(&mut buf[i], new);
                buf[i].substituted = true;
                Some(i + 1)
            }
            2 => {
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                if idx >= self.u(st + 4)? {
                    return None;
                }
                let seq = st + self.u(st + 6 + idx * 2)?;
                let count = self.u(seq)?;
                if count == 0 {
                    buf.remove(i);
                    return Some(i);
                }
                let first = buf[i];
                let mut new = Vec::with_capacity(count);
                for k in 0..count {
                    let mut gg = first;
                    self.set_glyph(&mut gg, u16_at(t, seq + 2 + k * 2)?);
                    gg.substituted = true;
                    if k > 0 {
                        gg.src = (first.src.1, first.src.1);
                    }
                    new.push(gg);
                }
                buf.splice(i..i + 1, new);
                Some(i + count)
            }
            3 => {
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                if idx >= self.u(st + 4)? {
                    return None;
                }
                let set = st + self.u(st + 6 + idx * 2)?;
                if self.u(set)? == 0 {
                    return None;
                }
                self.set_glyph(&mut buf[i], u16_at(t, set + 2)?);
                buf[i].substituted = true;
                Some(i + 1)
            }
            4 => {
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                if idx >= self.u(st + 4)? {
                    return None;
                }
                let set = st + self.u(st + 6 + idx * 2)?;
                'lig: for k in 0..self.u(set)? {
                    let lig = set + self.u(set + 2 + k * 2)?;
                    let glyph = u16_at(t, lig)?;
                    let comps = self.u(lig + 2)?;
                    if comps == 0 {
                        continue;
                    }
                    let mut matched = Vec::with_capacity(comps);
                    matched.push(i);
                    let mut j = i;
                    for c in 1..comps {
                        let Some(nj) = self.next(buf, j, lk) else { continue 'lig };
                        if buf[nj].mask & mask == 0 || Some(buf[nj].gid) != u16_at(t, lig + 4 + (c - 1) * 2) {
                            continue 'lig;
                        }
                        matched.push(nj);
                        j = nj;
                    }
                    let mut first = buf[i];
                    let last = *matched.last()?;
                    let (mut a, mut b) = first.src;
                    let mut cluster = first.cluster;
                    for &m in &matched[1..] {
                        if buf[m].src.0 < buf[m].src.1 {
                            a = a.min(buf[m].src.0);
                            b = b.max(buf[m].src.1);
                        }
                        cluster = cluster.min(buf[m].cluster);
                    }
                    first.src = (a, b);
                    first.cluster = cluster;
                    self.set_glyph(&mut first, glyph);
                    if !self.gdef.has_classes() {
                        first.class = 2;
                    }
                    first.ligated = true;
                    first.substituted = true;
                    buf[i] = first;
                    // Marks skipped over join the ligature's cluster.
                    for g in &mut buf[i + 1..=last] {
                        g.cluster = cluster;
                    }
                    for &m in matched[1..].iter().rev() {
                        buf.remove(m);
                    }
                    return Some(i + 1);
                }
                None
            }
            5 | 6 => {
                let m = self.context(buf, i, ty == 6, st, lk)?;
                Some(self.sub_records(buf, m, mask, depth))
            }
            _ => None,
        }
    }

    fn sub_records(&self, buf: &mut Vec<G>, m: Match, mask: u32, depth: u8) -> usize {
        let t = self.tab.t;
        let mut at = m.at;
        for r in 0..m.count {
            let (Some(seq), Some(li)) = (u16_at(t, m.records + r * 4), u16_at(t, m.records + r * 4 + 2)) else { break };
            let seq = seq as usize;
            if seq >= at.len() || depth >= MAX_DEPTH {
                continue;
            }
            let Some(nested) = self.tab.lookup(li) else { continue };
            let p = at[seq];
            if p >= buf.len() || self.skip(&buf[p], &nested) {
                continue;
            }
            let before = buf.len() as isize;
            if self.sub_at(buf, p, &nested, mask, depth + 1).is_none() {
                continue;
            }
            let delta = buf.len() as isize - before;
            if delta != 0 {
                for q in at.iter_mut() {
                    if *q > p {
                        let moved = *q as isize + delta;
                        *q = if moved <= p as isize { p } else { moved as usize };
                    }
                }
            }
        }
        at.last().map_or(0, |l| l + 1).min(buf.len())
    }

    fn reverse(&self, buf: &mut [G], i: usize, st: usize, lk: &Lookup) -> bool {
        let t = self.tab.t;
        let f = || -> Option<u16> {
            let idx = coverage(t, st + self.u(st + 2)?, buf[i].gid)?;
            let bc = self.u(st + 4)?;
            let b0 = st + 6;
            let lc_at = b0 + bc * 2;
            let lc = self.u(lc_at)?;
            let l0 = lc_at + 2;
            let gc_at = l0 + lc * 2;
            if idx >= self.u(gc_at)? {
                return None;
            }
            if !self.back(buf, i, bc, lk, |k, gid| self.cov(st, b0 + k * 2, gid)) {
                return None;
            }
            if !self.ahead(buf, i, lc, lk, |k, gid| self.cov(st, l0 + k * 2, gid)) {
                return None;
            }
            u16_at(t, gc_at + 2 + idx * 2)
        };
        match f() {
            Some(new) => {
                self.set_glyph(&mut buf[i], new);
                buf[i].substituted = true;
                true
            }
            None => false,
        }
    }

    /// Whether a feature would change exactly this glyph sequence.
    pub fn would(&self, tag: &Tag, glyphs: &[u16]) -> bool {
        let t = self.tab.t;
        let Some(&g0) = glyphs.first() else { return false };
        for li in self.tab.lookups(tag) {
            let Some(lk) = self.tab.lookup(li) else { continue };
            for &(ty, st) in &lk.subs {
                let hit = (|| -> Option<bool> {
                    match ty {
                        1..=3 => Some(glyphs.len() == 1 && coverage(t, st + self.u(st + 2)?, g0).is_some()),
                        4 => {
                            let idx = coverage(t, st + self.u(st + 2)?, g0)?;
                            if idx >= self.u(st + 4)? {
                                return Some(false);
                            }
                            let set = st + self.u(st + 6 + idx * 2)?;
                            for k in 0..self.u(set)? {
                                let lig = set + self.u(set + 2 + k * 2)?;
                                if self.u(lig + 2)? != glyphs.len() {
                                    continue;
                                }
                                if (1..glyphs.len()).all(|c| u16_at(t, lig + 4 + (c - 1) * 2) == Some(glyphs[c])) {
                                    return Some(true);
                                }
                            }
                            Some(false)
                        }
                        5 if u16_at(t, st)? == 3 => {
                            let gc = self.u(st + 2)?;
                            Some(gc == glyphs.len() && (0..gc).all(|k| self.cov(st, st + 6 + k * 2, glyphs[k])))
                        }
                        6 if u16_at(t, st)? == 3 => {
                            let bc = self.u(st + 2)?;
                            let ic_at = st + 4 + bc * 2;
                            let ic = self.u(ic_at)?;
                            let lc = self.u(ic_at + 2 + ic * 2)?;
                            Some(bc == 0 && lc == 0 && ic == glyphs.len() && (0..ic).all(|k| self.cov(st, ic_at + 2 + k * 2, glyphs[k])))
                        }
                        _ => Some(false),
                    }
                })();
                if hit == Some(true) {
                    return true;
                }
            }
        }
        false
    }

    // ---- Positioning ----

    /// Apply the lookups of some features to the positions.
    pub fn position(&self, buf: &[G], pos: &mut [P], feats: &[(Tag, u32)]) {
        for (li, mask) in self.plan(feats) {
            let Some(lk) = self.tab.lookup(li) else { continue };
            let mut i = 0;
            while i < buf.len() {
                if buf[i].mask & mask != 0 && !self.skip(&buf[i], &lk) {
                    if let Some(next) = self.pos_at(buf, pos, i, &lk, mask, 0) {
                        i = next.max(i + 1);
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    fn pos_at(&self, buf: &[G], pos: &mut [P], i: usize, lk: &Lookup, mask: u32, depth: u8) -> Option<usize> {
        for &(ty, st) in &lk.subs {
            if let Some(n) = self.pos_one(buf, pos, i, ty, st, lk, mask, depth) {
                return Some(n);
            }
        }
        None
    }

    fn value(&self, at: usize, vf: u16, p: &mut P) {
        let t = self.tab.t;
        let mut o = at;
        if vf & 1 != 0 {
            p.xo += i16_at(t, o).unwrap_or(0) as i32;
            o += 2;
        }
        if vf & 2 != 0 {
            p.yo += i16_at(t, o).unwrap_or(0) as i32;
            o += 2;
        }
        if vf & 4 != 0 {
            p.xa += i16_at(t, o).unwrap_or(0) as i32;
        }
    }

    fn anchor(&self, at: usize) -> Option<(i32, i32)> {
        let t = self.tab.t;
        Some((i16_at(t, at + 2)? as i32, i16_at(t, at + 4)? as i32))
    }

    /// Hang mark `i` on glyph `on`: mark record `mi` of the mark array at
    /// `ma`, anchor record `bi` of the array at `ba`.
    #[allow(clippy::too_many_arguments)]
    fn attach(&self, pos: &mut [P], i: usize, on: usize, ma: usize, mi: usize, ba: usize, bi: usize, classes: usize) -> Option<usize> {
        let rec = ma + 2 + mi * 4;
        let mclass = self.u(rec)?;
        let manchor = ma + self.u(rec + 2)?;
        if mclass >= classes {
            return None;
        }
        let off = self.u(ba + 2 + (bi * classes + mclass) * 2)?;
        if off == 0 {
            return None;
        }
        let (mx, my) = self.anchor(manchor)?;
        let (bx, by) = self.anchor(ba + off)?;
        pos[i].xo = bx - mx;
        pos[i].yo = by - my;
        pos[i].attach = Some(on);
        Some(i + 1)
    }

    #[allow(clippy::too_many_arguments)]
    fn pos_one(&self, buf: &[G], pos: &mut [P], i: usize, ty: u16, st: usize, lk: &Lookup, mask: u32, depth: u8) -> Option<usize> {
        let t = self.tab.t;
        let g = buf[i].gid;
        match ty {
            1 => {
                let fmt = u16_at(t, st)?;
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                let vf = u16_at(t, st + 4)?;
                let rec = match fmt {
                    1 => st + 6,
                    2 => {
                        if idx >= self.u(st + 6)? {
                            return None;
                        }
                        st + 8 + idx * value_size(vf)
                    }
                    _ => return None,
                };
                self.value(rec, vf, &mut pos[i]);
                Some(i + 1)
            }
            2 => {
                let fmt = u16_at(t, st)?;
                let idx = coverage(t, st + self.u(st + 2)?, g)?;
                let vf1 = u16_at(t, st + 4)?;
                let vf2 = u16_at(t, st + 6)?;
                let j = self.next(buf, i, lk)?;
                if buf[j].mask & mask == 0 {
                    return None;
                }
                let g2 = buf[j].gid;
                let (s1, s2) = (value_size(vf1), value_size(vf2));
                let (r1, r2) = match fmt {
                    1 => {
                        if idx >= self.u(st + 8)? {
                            return None;
                        }
                        let set = st + self.u(st + 10 + idx * 2)?;
                        let count = self.u(set)?;
                        let rec = 2 + s1 + s2;
                        let (mut lo, mut hi) = (0usize, count);
                        let mut found = None;
                        while lo < hi {
                            let mid = (lo + hi) / 2;
                            let r = set + 2 + mid * rec;
                            let second = u16_at(t, r)?;
                            if second == g2 {
                                found = Some(r);
                                break;
                            }
                            if second < g2 {
                                lo = mid + 1;
                            } else {
                                hi = mid;
                            }
                        }
                        let r = found?;
                        (r + 2, r + 2 + s1)
                    }
                    2 => {
                        let cd1 = self.u(st + 8)?;
                        let cd2 = self.u(st + 10)?;
                        let n1 = self.u(st + 12)?;
                        let n2 = self.u(st + 14)?;
                        let c1 = self.cls(st, cd1, g) as usize;
                        let c2 = self.cls(st, cd2, g2) as usize;
                        if c1 >= n1 || c2 >= n2 {
                            return None;
                        }
                        let r = st + 16 + (c1 * n2 + c2) * (s1 + s2);
                        (r, r + s1)
                    }
                    _ => return None,
                };
                self.value(r1, vf1, &mut pos[i]);
                self.value(r2, vf2, &mut pos[j]);
                Some(if vf2 != 0 { j + 1 } else { j })
            }
            4 => {
                let mi = coverage(t, st + self.u(st + 2)?, g)?;
                let base = (0..i).rev().find(|&j| buf[j].class != 3)?;
                let bi = coverage(t, st + self.u(st + 4)?, buf[base].gid)?;
                let classes = self.u(st + 6)?;
                let ma = st + self.u(st + 8)?;
                let ba = st + self.u(st + 10)?;
                self.attach(pos, i, base, ma, mi, ba, bi, classes)
            }
            5 => {
                let mi = coverage(t, st + self.u(st + 2)?, g)?;
                let lig = (0..i).rev().find(|&j| buf[j].class != 3)?;
                let li = coverage(t, st + self.u(st + 4)?, buf[lig].gid)?;
                let classes = self.u(st + 6)?;
                let ma = st + self.u(st + 8)?;
                let la = st + self.u(st + 10)?;
                if li >= self.u(la)? {
                    return None;
                }
                let la_at = la + self.u(la + 2 + li * 2)?;
                let comps = self.u(la_at)?;
                let rec = ma + 2 + mi * 4;
                let mclass = self.u(rec)?;
                if mclass >= classes {
                    return None;
                }
                // The last component with an anchor for this class.
                for comp in (0..comps).rev() {
                    let off = self.u(la_at + 2 + (comp * classes + mclass) * 2)?;
                    if off != 0 {
                        let (mx, my) = self.anchor(ma + self.u(rec + 2)?)?;
                        let (bx, by) = self.anchor(la_at + off)?;
                        pos[i].xo = bx - mx;
                        pos[i].yo = by - my;
                        pos[i].attach = Some(lig);
                        return Some(i + 1);
                    }
                }
                None
            }
            6 => {
                let mi = coverage(t, st + self.u(st + 2)?, g)?;
                let j = (0..i).rev().find(|&j| !self.ignored(&buf[j], lk.flag & !0x0E, lk.filter))?;
                if buf[j].class != 3 {
                    return None;
                }
                let m2 = coverage(t, st + self.u(st + 4)?, buf[j].gid)?;
                let classes = self.u(st + 6)?;
                let ma = st + self.u(st + 8)?;
                let m2a = st + self.u(st + 10)?;
                self.attach(pos, i, j, ma, mi, m2a, m2, classes)
            }
            7 | 8 => {
                let m = self.context(buf, i, ty == 8, st, lk)?;
                let end = m.at.last().map_or(i + 1, |l| l + 1);
                for r in 0..m.count {
                    let (Some(seq), Some(li)) = (u16_at(t, m.records + r * 4), u16_at(t, m.records + r * 4 + 2)) else { break };
                    let Some(&p) = m.at.get(seq as usize) else { continue };
                    if depth >= MAX_DEPTH {
                        continue;
                    }
                    let Some(nested) = self.tab.lookup(li) else { continue };
                    if !self.skip(&buf[p], &nested) {
                        self.pos_at(buf, pos, p, &nested, mask, depth + 1);
                    }
                }
                Some(end)
            }
            _ => None,
        }
    }
}
