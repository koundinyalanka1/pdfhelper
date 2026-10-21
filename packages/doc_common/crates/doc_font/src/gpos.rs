//! Pair kerning from the GPOS table: the `kern` feature's pair adjustment
//! lookups (formats 1 and 2, also through extension lookups), read lazily.

use crate::{i16_at, u16_at, u32_at};

/// Where the kerning subtables are, as absolute offsets into the font data.
#[derive(Clone, Debug)]
pub struct PairKerning {
    subtables: Vec<usize>,
}

fn value_size(format: u16) -> usize {
    (format & 0xFF).count_ones() as usize * 2
}

/// Offset of XAdvance within a value record, if it has one.
fn x_advance_at(format: u16) -> Option<usize> {
    if format & 0x0004 == 0 {
        return None;
    }
    Some(((format & 0x0003).count_ones() as usize) * 2)
}

pub(crate) fn coverage(d: &[u8], at: usize, glyph: u16) -> Option<usize> {
    match u16_at(d, at)? {
        1 => {
            let n = u16_at(d, at + 2)? as usize;
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                let g = u16_at(d, at + 4 + mid * 2)?;
                if g == glyph {
                    return Some(mid);
                }
                if g < glyph {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            None
        }
        2 => {
            let n = u16_at(d, at + 2)? as usize;
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                let r = at + 4 + mid * 6;
                let start = u16_at(d, r)?;
                let end = u16_at(d, r + 2)?;
                if glyph < start {
                    hi = mid;
                } else if glyph > end {
                    lo = mid + 1;
                } else {
                    return Some(u16_at(d, r + 4)? as usize + (glyph - start) as usize);
                }
            }
            None
        }
        _ => None,
    }
}

pub(crate) fn class(d: &[u8], at: usize, glyph: u16) -> u16 {
    let f = || -> Option<u16> {
        match u16_at(d, at)? {
            1 => {
                let start = u16_at(d, at + 2)?;
                let n = u16_at(d, at + 4)?;
                if glyph >= start && (glyph as u32) < start as u32 + n as u32 {
                    u16_at(d, at + 6 + (glyph - start) as usize * 2)
                } else {
                    Some(0)
                }
            }
            2 => {
                let n = u16_at(d, at + 2)? as usize;
                let (mut lo, mut hi) = (0usize, n);
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    let r = at + 4 + mid * 6;
                    let start = u16_at(d, r)?;
                    let end = u16_at(d, r + 2)?;
                    if glyph < start {
                        hi = mid;
                    } else if glyph > end {
                        lo = mid + 1;
                    } else {
                        return u16_at(d, r + 4);
                    }
                }
                Some(0)
            }
            _ => Some(0),
        }
    };
    f().unwrap_or(0)
}

impl PairKerning {
    /// `table` is the GPOS table; `base` its offset in the font data.
    pub fn read(table: &[u8], base: usize) -> Option<PairKerning> {
        let features = u16_at(table, 6)? as usize;
        let lookups = u16_at(table, 8)? as usize;
        let mut lookup_ids = Vec::new();
        let n = u16_at(table, features)? as usize;
        for k in 0..n {
            let r = features + 2 + k * 6;
            if table.get(r..r + 4)? != b"kern" {
                continue;
            }
            let f = features + u16_at(table, r + 4)? as usize;
            let count = u16_at(table, f + 2)? as usize;
            for i in 0..count {
                let id = u16_at(table, f + 4 + i * 2)?;
                if !lookup_ids.contains(&id) {
                    lookup_ids.push(id);
                }
            }
        }
        let mut subtables = Vec::new();
        let count = u16_at(table, lookups)?;
        for id in lookup_ids {
            if id >= count {
                continue;
            }
            let l = lookups + u16_at(table, lookups + 2 + id as usize * 2)? as usize;
            let ty = u16_at(table, l)?;
            let n = u16_at(table, l + 4)? as usize;
            for s in 0..n {
                let mut st = l + u16_at(table, l + 6 + s * 2)? as usize;
                let mut sty = ty;
                if ty == 9 {
                    // Extension: the real lookup type and a 32-bit offset.
                    sty = u16_at(table, st + 2)?;
                    st += u32_at(table, st + 4)? as usize;
                }
                if sty == 2 && st < table.len() {
                    subtables.push(base + st);
                }
            }
        }
        (!subtables.is_empty()).then_some(PairKerning { subtables })
    }

    pub fn kern(&self, d: &[u8], left: u16, right: u16) -> i16 {
        for &st in &self.subtables {
            if let Some(v) = self.pair(d, st, left, right) {
                return v;
            }
        }
        0
    }

    fn pair(&self, d: &[u8], st: usize, left: u16, right: u16) -> Option<i16> {
        let format = u16_at(d, st)?;
        let cov = st + u16_at(d, st + 2)? as usize;
        let idx = coverage(d, cov, left)?;
        let vf1 = u16_at(d, st + 4)?;
        let vf2 = u16_at(d, st + 6)?;
        let x_at = x_advance_at(vf1);
        match format {
            1 => {
                let n = u16_at(d, st + 8)? as usize;
                if idx >= n {
                    return None;
                }
                let set = st + u16_at(d, st + 10 + idx * 2)? as usize;
                let count = u16_at(d, set)? as usize;
                let rec = 2 + value_size(vf1) + value_size(vf2);
                let (mut lo, mut hi) = (0usize, count);
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    let r = set + 2 + mid * rec;
                    let g = u16_at(d, r)?;
                    if g == right {
                        return Some(x_at.map_or(0, |x| i16_at(d, r + 2 + x).unwrap_or(0)));
                    }
                    if g < right {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                None
            }
            2 => {
                let cd1 = st + u16_at(d, st + 8)? as usize;
                let cd2 = st + u16_at(d, st + 10)? as usize;
                let n1 = u16_at(d, st + 12)? as usize;
                let n2 = u16_at(d, st + 14)? as usize;
                let c1 = class(d, cd1, left) as usize;
                let c2 = class(d, cd2, right) as usize;
                if c1 >= n1 || c2 >= n2 {
                    return None;
                }
                let rec = value_size(vf1) + value_size(vf2);
                let r = st + 16 + (c1 * n2 + c2) * rec;
                let v = x_at.map_or(0, |x| i16_at(d, r + x).unwrap_or(0));
                // Class pairs cover every glyph in the coverage; a zero
                // there still ends the search like a found pair.
                Some(v)
            }
            _ => None,
        }
    }
}
