//! Glyph outlines from TrueType `glyf` tables (simple and composite
//! glyphs), for drawing text as shapes. CFF outlines are not read.

use crate::{i16_at, u16_at, u32_at, Font};

/// A step of a glyph's outline, in font units with y going up.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Seg {
    Move(f32, f32),
    Line(f32, f32),
    /// A quadratic curve: control point, then end point.
    Quad(f32, f32, f32, f32),
    Close,
}

fn glyph_data(font: &Font, gid: u16) -> Option<&[u8]> {
    let head = font.table(b"head")?;
    let loca = font.table(b"loca")?;
    let glyf = font.table(b"glyf")?;
    let g = gid as usize;
    let (s, e) = if u16_at(head, 50)? == 1 {
        (u32_at(loca, g * 4)? as usize, u32_at(loca, g * 4 + 4)? as usize)
    } else {
        (u16_at(loca, g * 2)? as usize * 2, u16_at(loca, g * 2 + 2)? as usize * 2)
    };
    if e < s || e > glyf.len() {
        return None;
    }
    Some(&glyf[s..e])
}

/// A 2-D transform for composite glyph parts: x' = a x + c y + e.
#[derive(Clone, Copy)]
struct M([f32; 6]);

impl M {
    const ID: M = M([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);

    fn apply(&self, x: f32, y: f32) -> (f32, f32) {
        let m = &self.0;
        (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])
    }

    fn then(&self, n: &M) -> M {
        // self after n.
        let (a, b) = (&self.0, &n.0);
        M([
            a[0] * b[0] + a[2] * b[1],
            a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3],
            a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4],
            a[1] * b[4] + a[3] * b[5] + a[5],
        ])
    }
}

impl Font {
    /// The outline of glyph `gid`, or None for CFF fonts and damaged
    /// glyphs. An empty outline (a space) is Some of nothing.
    pub fn outline(&self, gid: u16) -> Option<Vec<Seg>> {
        if self.is_cff {
            return None;
        }
        let mut out = Vec::new();
        self.add_outline(gid, M::ID, 0, &mut out)?;
        Some(out)
    }

    fn add_outline(&self, gid: u16, m: M, depth: usize, out: &mut Vec<Seg>) -> Option<()> {
        if depth > 8 {
            return None;
        }
        let d = glyph_data(self, gid)?;
        if d.is_empty() {
            return Some(());
        }
        let contours = i16_at(d, 0)?;
        if contours >= 0 {
            simple(d, contours as usize, &m, out)
        } else {
            // Composite: parts placed by offsets and scales.
            let mut at = 10;
            loop {
                let flags = u16_at(d, at)?;
                let part = u16_at(d, at + 2)?;
                at += 4;
                let (dx, dy) = if flags & 0x1 != 0 {
                    let v = (i16_at(d, at)? as f32, i16_at(d, at + 2)? as f32);
                    at += 4;
                    v
                } else {
                    let v = (*d.get(at)? as i8 as f32, *d.get(at + 1)? as i8 as f32);
                    at += 2;
                    v
                };
                let f2 = |i: usize| -> Option<f32> { Some(i16_at(d, i)? as f32 / 16384.0) };
                let (mut a, mut b, mut c, mut dd) = (1.0, 0.0, 0.0, 1.0);
                if flags & 0x8 != 0 {
                    a = f2(at)?;
                    dd = a;
                    at += 2;
                } else if flags & 0x40 != 0 {
                    a = f2(at)?;
                    dd = f2(at + 2)?;
                    at += 4;
                } else if flags & 0x80 != 0 {
                    a = f2(at)?;
                    b = f2(at + 2)?;
                    c = f2(at + 4)?;
                    dd = f2(at + 6)?;
                    at += 8;
                }
                // Point-matched parts (offsets not given as x/y) are placed
                // without an offset.
                let (ex, ey) = if flags & 0x2 != 0 { (dx, dy) } else { (0.0, 0.0) };
                let local = M([a, b, c, dd, ex, ey]);
                self.add_outline(part, m.then(&local), depth + 1, out)?;
                if flags & 0x20 == 0 {
                    break;
                }
            }
            Some(())
        }
    }
}

fn simple(d: &[u8], contours: usize, m: &M, out: &mut Vec<Seg>) -> Option<()> {
    let mut ends = Vec::with_capacity(contours);
    for k in 0..contours {
        ends.push(u16_at(d, 10 + 2 * k)? as usize);
    }
    let n = ends.last().map_or(0, |e| e + 1);
    if n > 65536 {
        return None;
    }
    let ins = u16_at(d, 10 + 2 * contours)? as usize;
    let mut at = 12 + 2 * contours + ins;
    let mut flags = Vec::with_capacity(n);
    while flags.len() < n {
        let f = *d.get(at)?;
        at += 1;
        flags.push(f);
        if f & 0x08 != 0 {
            let r = *d.get(at)?;
            at += 1;
            for _ in 0..r {
                if flags.len() < n {
                    flags.push(f);
                }
            }
        }
    }
    let coords = |short: u8, same: u8, at: &mut usize| -> Option<Vec<f32>> {
        let mut v = Vec::with_capacity(n);
        let mut cur = 0i32;
        for f in &flags {
            if f & short != 0 {
                let x = *d.get(*at)? as i32;
                *at += 1;
                cur += if f & same != 0 { x } else { -x };
            } else if f & same == 0 {
                cur += i16_at(d, *at)? as i32;
                *at += 2;
            }
            v.push(cur as f32);
        }
        Some(v)
    };
    let xs = coords(0x02, 0x10, &mut at)?;
    let ys = coords(0x04, 0x20, &mut at)?;
    let mut start = 0;
    for &end in &ends {
        if end < start || end >= n {
            return None;
        }
        let pts: Vec<(f32, f32, bool)> = (start..=end).map(|i| {
            let (x, y) = m.apply(xs[i], ys[i]);
            (x, y, flags[i] & 1 != 0)
        }).collect();
        contour(&pts, out);
        start = end + 1;
    }
    Some(())
}

/// One contour: on-curve points joined by lines, off-curve ones as
/// quadratic controls, with the implied points between two controls.
fn contour(pts: &[(f32, f32, bool)], out: &mut Vec<Seg>) {
    if pts.is_empty() {
        return;
    }
    let n = pts.len();
    // Start on an on-curve point (or the midpoint of the first two).
    let first_on = pts.iter().position(|p| p.2);
    let (sx, sy, offset) = match first_on {
        Some(i) => (pts[i].0, pts[i].1, i),
        None => ((pts[0].0 + pts[1 % n].0) / 2.0, (pts[0].1 + pts[1 % n].1) / 2.0, 0),
    };
    out.push(Seg::Move(sx, sy));
    let mut ctrl: Option<(f32, f32)> = None;
    for k in 1..=n {
        let p = pts[(offset + k) % n];
        if p.2 {
            match ctrl.take() {
                Some((cx, cy)) => out.push(Seg::Quad(cx, cy, p.0, p.1)),
                None => out.push(Seg::Line(p.0, p.1)),
            }
        } else {
            if let Some((cx, cy)) = ctrl {
                let (mx, my) = ((cx + p.0) / 2.0, (cy + p.1) / 2.0);
                out.push(Seg::Quad(cx, cy, mx, my));
            }
            ctrl = Some((p.0, p.1));
        }
    }
    if let Some((cx, cy)) = ctrl {
        out.push(Seg::Quad(cx, cy, sx, sy));
    }
    out.push(Seg::Close);
}
