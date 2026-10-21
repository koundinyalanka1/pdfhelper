//! Windows Metafiles (`.wmf`): 16-bit records with their parameters in
//! reverse order, objects in the lowest free slot.

use crate::gdi::{ansi, is_symbol_face, Brush, FontSpec, Gdi, Obj, Pen};
use crate::raster::Budget;

fn u16_at(b: &[u8], i: usize) -> u16 {
    b.get(i..i.saturating_add(2)).map_or(0, |s| u16::from_le_bytes([s[0], s[1]]))
}

fn i16_at(b: &[u8], i: usize) -> f64 {
    u16_at(b, i) as i16 as f64
}

fn u32_at(b: &[u8], i: usize) -> u32 {
    b.get(i..i.saturating_add(4)).map_or(0, |s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

/// A record's length in bytes (its size is in 16-bit words).
fn record_len(b: &[u8], at: usize) -> usize {
    (u32_at(b, at) as usize).saturating_mul(2)
}

/// The picture's frame from its placeable header (logical units, and
/// units per inch), or None.
pub fn placeable(b: &[u8]) -> Option<((f64, f64, f64, f64), f64)> {
    if u32_at(b, 0) != 0x9AC6_CDD7 {
        return None;
    }
    let r = (i16_at(b, 6), i16_at(b, 8), i16_at(b, 10), i16_at(b, 12));
    let inch = u16_at(b, 14).max(1) as f64;
    Some((r, inch))
}

/// The window set by the records, when the header gives none.
pub fn window(b: &[u8]) -> Option<(f64, f64, f64, f64)> {
    let start = if placeable(b).is_some() { 22 } else { 0 };
    let header = u16_at(b, start + 2) as usize * 2;
    let mut at = start + header;
    let (mut org, mut ext) = ((0.0, 0.0), None);
    let mut n = 0;
    while b.len().saturating_sub(at) >= 6 && n < 100_000 {
        let size = record_len(b, at);
        let f = u16_at(b, at + 4);
        if size < 6 {
            break;
        }
        match f {
            0x020B => org = (i16_at(b, at + 8), i16_at(b, at + 6)),
            0x020C => ext = Some((i16_at(b, at + 8), i16_at(b, at + 6))),
            0x0000 => break,
            _ => {}
        }
        at = at.saturating_add(size);
        n += 1;
    }
    ext.map(|e: (f64, f64)| (org.0, org.1, org.0 + e.0, org.1 + e.1))
}

/// Play a WMF's records, until the end or the render's budget.
pub fn play(b: &[u8], gdi: &mut Gdi) {
    let start = if placeable(b).is_some() { 22 } else { 0 };
    if let Some(((l, t, r, bt), _)) = placeable(b) {
        gdi.dc.win_org = (l, t);
        gdi.dc.win_ext = (r - l, bt - t);
    }
    let header = (u16_at(b, start + 2) as usize * 2).max(18);
    let mut at = start + header;
    let mut n = 0;
    while b.len().saturating_sub(at) >= 6 && n < 1_000_000 && !gdi.canvas.budget.spent() {
        let size = record_len(b, at);
        if size < 6 {
            break;
        }
        let end = at.saturating_add(size).min(b.len());
        let r = &b[at..end];
        let f = u16_at(r, 4);
        if f == 0 {
            break;
        }
        record(r, f, gdi);
        at = at.saturating_add(size);
        n += 1;
    }
}

/// Points from `at`: as many of `n` as the record holds and the budget
/// could still draw.
fn points(r: &[u8], at: usize, n: usize, budget: &Budget) -> Vec<(f64, f64)> {
    let n = budget.room(n.min(r.len().saturating_sub(at) / 4));
    (0..n).map(|k| (i16_at(r, at + 4 * k), i16_at(r, at + 4 * k + 2))).collect()
}

fn record(r: &[u8], f: u16, g: &mut Gdi) {
    let p = |k: usize| i16_at(r, 6 + 2 * k);
    let budget = g.canvas.budget;
    match f {
        0x020B => g.dc.win_org = (p(1), p(0)),
        0x020C => g.dc.win_ext = (p(1), p(0)),
        0x0211 => {}
        0x0103 => g.dc.map_mode = u16_at(r, 6) as u32,
        0x0102 => g.dc.bk_opaque = u16_at(r, 6) == 2,
        0x0106 => g.dc.even_odd = u16_at(r, 6) == 1,
        0x012E => g.dc.text_align = u16_at(r, 6) as u32,
        0x0209 => g.dc.text_color = u32_at(r, 6),
        0x0201 => g.dc.bk_color = u32_at(r, 6),
        0x0214 => g.move_to(p(1), p(0)),
        0x0213 => g.lines_to(&[(p(1), p(0))]),
        0x041B => g.rect(p(3), p(2), p(1), p(0)),
        0x0418 => g.ellipse(p(3), p(2), p(1), p(0)),
        0x061C => g.round_rect(p(5), p(4), p(3), p(2), p(1), p(0)),
        0x0817 | 0x0830 | 0x081A => {
            let kind = match f {
                0x0830 => 1,
                0x081A => 2,
                _ => 0,
            };
            g.arc((p(7), p(6), p(5), p(4)), (p(3), p(2)), (p(1), p(0)), kind, false);
        }
        0x0324 | 0x0325 => {
            let n = u16_at(r, 6) as usize;
            let pts = points(r, 8, n, &budget);
            g.poly(&pts, f == 0x0324);
        }
        0x0538 => {
            // The counts, then every polygon's points; a count is cut to
            // what the record still holds.
            let polys = u16_at(r, 6) as usize;
            let mut at = 8 + 2 * polys;
            let mut left = budget;
            let mut all = Vec::new();
            for k in 0..polys.min(4096) {
                let pts = points(r, at, u16_at(r, 8 + 2 * k) as usize, &left);
                left.items -= pts.len() as u64;
                at += 4 * pts.len();
                all.push(pts);
            }
            g.polys(&all, true);
        }
        0x001E => g.save(),
        0x0127 => g.restore(p(0) as i64),
        0x012D => g.select(u16_at(r, 6) as usize),
        0x01F0 => g.delete(u16_at(r, 6) as usize),
        0x02FA => g.add_object(Obj::Pen(Pen { style: (u16_at(r, 6) & 0xF) as u32, width: p(1).abs(), color: u32_at(r, 12) }), None),
        0x02FC => g.add_object(Obj::Brush(Brush { style: u16_at(r, 6) as u32, color: u32_at(r, 8) }), None),
        0x02FB => {
            let face: Vec<u8> = r.get(24..).unwrap_or(&[]).iter().take(32).copied().take_while(|c| *c != 0).collect();
            let face = ansi(&face, false).into_iter().collect::<String>();
            g.add_object(
                Obj::Font(FontSpec {
                    height: p(0),
                    weight: p(4) as i32,
                    italic: r.get(16).is_some_and(|v| *v != 0),
                    underline: r.get(17).is_some_and(|v| *v != 0),
                    strike: r.get(18).is_some_and(|v| *v != 0),
                    escapement: p(2),
                    charset: *r.get(19).unwrap_or(&0),
                    face,
                }),
                None,
            );
        }
        // Palettes, pattern brushes, regions: they take a slot.
        0x00F7 | 0x06FF => g.add_object(Obj::Other, None),
        0x01F9 | 0x0142 => g.add_object(Obj::Brush(Brush { style: 3, color: 0x808080 }), None),
        0x0416 => g.intersect_clip(p(3), p(2), p(1), p(0)),
        0x061D => {
            // PatBlt: a rectangle of the brush (or black/white).
            let rop = u32_at(r, 6);
            let (h, w, y, x) = (p(2), p(3), p(4), p(5));
            g.pattern_blit(x, y, x + w, y + h, rop);
        }
        0x0521 => {
            let n = u16_at(r, 6) as usize;
            let text = r.get(8..8 + n).unwrap_or(&[]);
            let off = 8 + n.div_ceil(2) * 2;
            let (y, x) = (i16_at(r, off), i16_at(r, off + 2));
            let sym = is_symbol_face(&g.dc.font.face, g.dc.font.charset);
            g.text(x, y, &ansi(text, sym), None, None);
        }
        0x0A32 => {
            let (y, x) = (p(0), p(1));
            let n = u16_at(r, 10) as usize;
            let opts = u16_at(r, 12);
            let mut at = 14;
            let mut rect = None;
            if opts & 0x6 != 0 {
                rect = Some((i16_at(r, at), i16_at(r, at + 2), i16_at(r, at + 4), i16_at(r, at + 6)));
                at += 8;
            }
            let text = r.get(at..at + n).unwrap_or(&[]);
            at += n.div_ceil(2) * 2;
            let dx: Vec<f64> = if r.len() >= at + 2 * n { (0..n).map(|k| i16_at(r, at + 2 * k)).collect() } else { Vec::new() };
            let opaque = rect.filter(|_| opts & 0x2 != 0);
            let sym = is_symbol_face(&g.dc.font.face, g.dc.font.charset);
            g.text(x, y, &ansi(text, sym), if dx.len() == n { Some(&dx) } else { None }, opaque);
        }
        0x0B41 => {
            // DIBStretchBlt (with a bitmap when the record is long enough).
            let rop = u32_at(r, 6);
            let (sh, sw, sy, sx) = (p(2), p(3), p(4), p(5));
            let (dh, dw, dy, dx) = (p(6), p(7), p(8), p(9));
            dib_at(g, r, 26, (dx, dy, dw, dh), Some((sx as i64, sy as i64, sw as i64, sh as i64)), rop);
        }
        0x0F43 => {
            let rop = u32_at(r, 6);
            let (sh, sw, sy, sx) = (p(3), p(4), p(5), p(6));
            let (dh, dw, dy, dx) = (p(7), p(8), p(9), p(10));
            dib_at(g, r, 28, (dx, dy, dw, dh), Some((sx as i64, sy as i64, sw as i64, sh as i64)), rop);
        }
        0x0940 => {
            let rop = u32_at(r, 6);
            let (sy, sx, h, w, dy, dx) = (p(2), p(3), p(4), p(5), p(6), p(7));
            dib_at(g, r, 22, (dx, dy, w, h), Some((sx as i64, sy as i64, w as i64, h as i64)), rop);
        }
        0x0D33 => {
            let (sy, sx, h, w, dy, dx) = (p(3), p(4), p(5), p(6), p(7), p(8));
            dib_at(g, r, 24, (dx, dy, w, h), Some((sx as i64, sy as i64, w as i64, h as i64)), 0x00CC_0020);
        }
        _ => {}
    }
}

/// A DIB (header, colours, bits together) at `at` in a record.
fn dib_at(g: &mut Gdi, r: &[u8], at: usize, dest: (f64, f64, f64, f64), src: Option<(i64, i64, i64, i64)>, rop: u32) {
    let Some(d) = r.get(at..) else { return };
    if d.len() < 12 {
        // No bitmap: a pattern blit.
        g.pattern_blit(dest.0, dest.1, dest.0 + dest.2, dest.1 + dest.3, rop);
        return;
    }
    let size = u32_at(d, 0) as usize;
    if size != 12 && size < 40 {
        return;
    }
    let (bpp, used, compression) = if size == 12 { (u16_at(d, 10) as usize, 0, 0) } else { (u16_at(d, 14) as usize, u32_at(d, 32) as usize, u32_at(d, 16)) };
    let colors = if bpp <= 8 { if used > 0 { used.min(256) } else { 1 << bpp } } else { 0 };
    let masks = if compression == 3 && size == 40 { 12 } else { 0 };
    let Some(bits_at) = size.checked_add(colors * if size == 12 { 3 } else { 4 } + masks) else { return };
    let Some(bits) = d.get(bits_at..) else { return };
    g.dib(&d[..bits_at.min(d.len())], bits, dest, src, rop, false);
}
