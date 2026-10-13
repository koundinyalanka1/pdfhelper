//! Enhanced Metafiles (`.emf`): 32-bit records with explicit object
//! handles, world transforms and paths. EMF+ records (in comments) are
//! skipped; the EMF records a dual file carries are drawn.

use crate::gdi::{ansi, is_symbol_face, Brush, FontSpec, Gdi, Obj, Pen};

fn u32_at(b: &[u8], i: usize) -> u32 {
    b.get(i..i + 4).map_or(0, |s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn i32_at(b: &[u8], i: usize) -> f64 {
    u32_at(b, i) as i32 as f64
}

fn i16_at(b: &[u8], i: usize) -> f64 {
    b.get(i..i + 2).map_or(0, |s| i16::from_le_bytes([s[0], s[1]])) as f64
}

fn f32_at(b: &[u8], i: usize) -> f64 {
    f32::from_bits(u32_at(b, i)) as f64
}

/// What the header says: bounds (device pixels), frame (0.01 mm), the
/// reference device in pixels and in millimetres.
pub struct Header {
    pub frame: (f64, f64, f64, f64),
    pub device: (f64, f64),
    pub mm: (f64, f64),
}

pub fn header(b: &[u8]) -> Option<Header> {
    if u32_at(b, 0) != 1 || b.get(40..44) != Some(b" EMF") {
        return None;
    }
    Some(Header {
        frame: (i32_at(b, 24), i32_at(b, 28), i32_at(b, 32), i32_at(b, 36)),
        device: (i32_at(b, 72).max(1.0), i32_at(b, 76).max(1.0)),
        mm: (i32_at(b, 80).max(1.0), i32_at(b, 84).max(1.0)),
    })
}

fn points32(r: &[u8], at: usize, n: usize) -> Vec<(f64, f64)> {
    (0..n.min(1 << 20)).map(|k| (i32_at(r, at + 8 * k), i32_at(r, at + 8 * k + 4))).collect()
}

fn points16(r: &[u8], at: usize, n: usize) -> Vec<(f64, f64)> {
    (0..n.min(1 << 20)).map(|k| (i16_at(r, at + 4 * k), i16_at(r, at + 4 * k + 2))).collect()
}

fn xform(r: &[u8], at: usize) -> [f64; 6] {
    [f32_at(r, at), f32_at(r, at + 4), f32_at(r, at + 8), f32_at(r, at + 12), f32_at(r, at + 16), f32_at(r, at + 20)]
}

/// a after b: apply b, then a.
fn compose(a: &[f64; 6], b: &[f64; 6]) -> [f64; 6] {
    [
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    ]
}

/// Play an EMF's records.
pub fn play(b: &[u8], g: &mut Gdi) {
    let mut at = 0;
    let mut n = 0;
    while at + 8 <= b.len() && n < 2_000_000 {
        let ty = u32_at(b, at);
        let size = u32_at(b, at + 4) as usize;
        if size < 8 || size % 4 != 0 {
            break;
        }
        let end = (at + size).min(b.len());
        let r = &b[at..end];
        if ty == 14 {
            break;
        }
        record(r, ty, g);
        at += size;
        n += 1;
    }
}

fn polys(r: &[u8], wide: bool) -> Vec<Vec<(f64, f64)>> {
    let n = u32_at(r, 24) as usize;
    let mut at = 32 + 4 * n.min(1 << 16);
    let mut out = Vec::new();
    for k in 0..n.min(1 << 16) {
        let c = u32_at(r, 32 + 4 * k) as usize;
        out.push(if wide { points32(r, at, c) } else { points16(r, at, c) });
        at += c.min(1 << 20) * if wide { 8 } else { 4 };
    }
    out
}

fn record(r: &[u8], ty: u32, g: &mut Gdi) {
    let p = |off: usize| i32_at(r, off);
    match ty {
        9 => g.dc.win_ext = (p(8), p(12)),
        10 => g.dc.win_org = (p(8), p(12)),
        11 => g.dc.vp_ext = (p(8), p(12)),
        12 => g.dc.vp_org = (p(8), p(12)),
        17 => g.dc.map_mode = u32_at(r, 8),
        18 => g.dc.bk_opaque = u32_at(r, 8) == 2,
        19 => g.dc.even_odd = u32_at(r, 8) == 1,
        22 => g.dc.text_align = u32_at(r, 8),
        24 => g.dc.text_color = u32_at(r, 8),
        25 => g.dc.bk_color = u32_at(r, 8),
        27 => g.move_to(p(8), p(12)),
        54 => g.lines_to(&[(p(8), p(12))]),
        33 => g.save(),
        34 => g.restore(p(8) as i64),
        35 => g.dc.xform = xform(r, 8),
        36 => {
            let x = xform(r, 8);
            let cur = g.dc.xform;
            g.dc.xform = match u32_at(r, 32) {
                1 => [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                2 => compose(&cur, &x),
                3 => compose(&x, &cur),
                4 => x,
                _ => cur,
            };
        }
        37 => {
            let h = u32_at(r, 8);
            if h & 0x8000_0000 != 0 {
                g.select_stock(h & 0x7FFF_FFFF);
            } else {
                g.select(h as usize);
            }
        }
        40 => g.delete(u32_at(r, 8) as usize),
        38 => g.add_object(Obj::Pen(Pen { style: u32_at(r, 12) & 0xF, width: p(16).abs(), color: u32_at(r, 24) }), Some(u32_at(r, 8) as usize)),
        95 => {
            // ExtCreatePen: geometric pens have a width; brush colour.
            let style = u32_at(r, 28);
            let geometric = style & 0x0001_0000 != 0;
            let width = if geometric { u32_at(r, 32) as f64 } else { 0.0 };
            let s = style & 0xF;
            g.add_object(Obj::Pen(Pen { style: if s > 5 { 0 } else { s }, width, color: u32_at(r, 40) }), Some(u32_at(r, 8) as usize));
        }
        39 => g.add_object(Obj::Brush(Brush { style: u32_at(r, 12), color: u32_at(r, 16) }), Some(u32_at(r, 8) as usize)),
        93 | 94 => g.add_object(Obj::Brush(Brush { style: 3, color: 0x808080 }), Some(u32_at(r, 8) as usize)),
        82 => {
            let face: Vec<u16> = (0..32).map(|k| u16::from_le_bytes([*r.get(40 + 2 * k).unwrap_or(&0), *r.get(41 + 2 * k).unwrap_or(&0)])).take_while(|c| *c != 0).collect();
            g.add_object(
                Obj::Font(FontSpec {
                    height: p(12),
                    weight: p(28) as i32,
                    italic: r.get(32).is_some_and(|v| *v != 0),
                    underline: r.get(33).is_some_and(|v| *v != 0),
                    strike: r.get(34).is_some_and(|v| *v != 0),
                    escapement: p(20),
                    charset: *r.get(35).unwrap_or(&0),
                    face: String::from_utf16_lossy(&face),
                }),
                Some(u32_at(r, 8) as usize),
            );
        }
        30 => g.intersect_clip(p(8), p(12), p(16), p(20)),
        75 => {
            // A region selected with no data resets the clip.
            if u32_at(r, 8) == 0 {
                g.dc.clip = None;
            }
        }
        42 => g.ellipse(p(8), p(12), p(16), p(20)),
        43 => g.rect(p(8), p(12), p(16), p(20)),
        44 => g.round_rect(p(8), p(12), p(16), p(20), p(24), p(28)),
        45..=47 | 55 => {
            let kind = match ty {
                46 => 1,
                47 => 2,
                _ => 0,
            };
            g.arc((p(8), p(12), p(16), p(20)), (p(24), p(28)), (p(32), p(36)), kind, ty == 55);
        }
        2 | 85 => {
            let pts = if ty == 2 { points32(r, 28, u32_at(r, 24) as usize) } else { points16(r, 28, u32_at(r, 24) as usize) };
            if let Some((first, rest)) = pts.split_first() {
                g.beziers(*first, rest, false);
            }
        }
        5 | 88 => {
            let pts = if ty == 5 { points32(r, 28, u32_at(r, 24) as usize) } else { points16(r, 28, u32_at(r, 24) as usize) };
            let start = g.dc.pos;
            g.beziers(start, &pts, true);
        }
        3 | 86 => {
            let pts = if ty == 3 { points32(r, 28, u32_at(r, 24) as usize) } else { points16(r, 28, u32_at(r, 24) as usize) };
            g.poly(&pts, true);
        }
        4 | 87 => {
            let pts = if ty == 4 { points32(r, 28, u32_at(r, 24) as usize) } else { points16(r, 28, u32_at(r, 24) as usize) };
            g.poly(&pts, false);
        }
        6 | 89 => {
            let pts = if ty == 6 { points32(r, 28, u32_at(r, 24) as usize) } else { points16(r, 28, u32_at(r, 24) as usize) };
            g.lines_to(&pts);
        }
        7 | 90 => g.polys(&polys(r, ty == 7), false),
        8 | 91 => g.polys(&polys(r, ty == 8), true),
        59 => g.begin_path(),
        60 => {}
        61 => g.close_figure(),
        62 => g.draw_path(true, false),
        63 => g.draw_path(true, true),
        64 => g.draw_path(false, true),
        67 | 68 => g.abort_path(),
        71 | 74 => {
            // FillRgn (with a brush) and PaintRgn: the region's rectangles.
            let (data, brush) = if ty == 71 { (32, Some(u32_at(r, 28) as usize)) } else { (28, None) };
            let saved = g.dc.brush.clone();
            if let Some(h) = brush {
                g.select(h);
            }
            let count = u32_at(r, data + 8) as usize;
            for k in 0..count.min(1 << 16) {
                let at = data + 32 + 16 * k;
                g.fill_rect(p(at), p(at + 4), p(at + 8), p(at + 12), None);
            }
            g.dc.brush = saved;
        }
        76 | 77 => {
            // BitBlt / StretchBlt: a bitmap, or the brush when none.
            let (x, y, w, h) = (p(24), p(28), p(32), p(36));
            let rop = u32_at(r, 40);
            let (off_bmi, cb_bmi, off_bits, cb_bits) = (u32_at(r, 84) as usize, u32_at(r, 88) as usize, u32_at(r, 92) as usize, u32_at(r, 96) as usize);
            if cb_bmi == 0 || cb_bits == 0 {
                g.pattern_blit(x, y, x + w, y + h, rop);
                return;
            }
            let (sx, sy) = (p(44) as i64, p(48) as i64);
            let (sw, sh) = if ty == 77 { (p(100) as i64, p(104) as i64) } else { (w as i64, h as i64) };
            if let (Some(bmi), Some(bits)) = (r.get(off_bmi..off_bmi + cb_bmi), r.get(off_bits..off_bits + cb_bits)) {
                g.dib(bmi, bits, (x, y, w, h), Some((sx, sy, sw, sh)), rop, false);
            }
        }
        81 => {
            // StretchDIBits.
            let (x, y) = (p(24), p(28));
            let (sx, sy, sw, sh) = (p(32) as i64, p(36) as i64, p(40) as i64, p(44) as i64);
            let (off_bmi, cb_bmi, off_bits, cb_bits) = (u32_at(r, 48) as usize, u32_at(r, 52) as usize, u32_at(r, 56) as usize, u32_at(r, 60) as usize);
            let rop = u32_at(r, 68);
            let (w, h) = (p(72), p(76));
            if let (Some(bmi), Some(bits)) = (r.get(off_bmi..off_bmi + cb_bmi), r.get(off_bits..off_bits + cb_bits)) {
                g.dib(bmi, bits, (x, y, w, h), Some((sx, sy, sw, sh)), rop, false);
            }
        }
        80 => {
            // SetDIBitsToDevice: pixels one to one.
            let (x, y) = (p(24), p(28));
            let (sx, sy, sw, sh) = (p(32) as i64, p(36) as i64, p(40) as i64, p(44) as i64);
            let (off_bmi, cb_bmi, off_bits, cb_bits) = (u32_at(r, 48) as usize, u32_at(r, 52) as usize, u32_at(r, 56) as usize, u32_at(r, 60) as usize);
            if let (Some(bmi), Some(bits)) = (r.get(off_bmi..off_bmi + cb_bmi), r.get(off_bits..off_bits + cb_bits)) {
                g.dib(bmi, bits, (x, y, sw as f64, sh as f64), Some((sx, sy, sw, sh)), 0x00CC_0020, false);
            }
        }
        114 => {
            // AlphaBlend: per-pixel alpha when the blend function says so.
            let (x, y, w, h) = (p(24), p(28), p(32), p(36));
            let alpha = r.get(43).is_some_and(|f| *f & 1 != 0);
            let (sx, sy) = (p(44) as i64, p(48) as i64);
            let (off_bmi, cb_bmi, off_bits, cb_bits) = (u32_at(r, 84) as usize, u32_at(r, 88) as usize, u32_at(r, 92) as usize, u32_at(r, 96) as usize);
            let (sw, sh) = (p(100) as i64, p(104) as i64);
            if let (Some(bmi), Some(bits)) = (r.get(off_bmi..off_bmi + cb_bmi), r.get(off_bits..off_bits + cb_bits)) {
                g.dib(bmi, bits, (x, y, w, h), Some((sx, sy, sw, sh)), 0x00CC_0020, alpha);
            }
        }
        83 | 84 => {
            // ExtTextOutA/W.
            let (x, y) = (p(36), p(40));
            let n = u32_at(r, 44) as usize;
            let off = u32_at(r, 48) as usize;
            let opts = u32_at(r, 52);
            let rect = (p(56), p(60), p(64), p(68));
            let off_dx = u32_at(r, 72) as usize;
            let n = n.min(1 << 16);
            let chars: Vec<char> = if ty == 84 {
                let units: Vec<u16> = (0..n).map(|k| u16::from_le_bytes([*r.get(off + 2 * k).unwrap_or(&0), *r.get(off + 2 * k + 1).unwrap_or(&0)])).collect();
                let sym = is_symbol_face(&g.dc.font.face, g.dc.font.charset);
                String::from_utf16_lossy(&units)
                    .chars()
                    .map(|c| if sym && (0x20..0x100).contains(&(c as u32)) { char::from_u32(0xF000 + c as u32).unwrap_or(c) } else { c })
                    .collect()
            } else {
                let sym = is_symbol_face(&g.dc.font.face, g.dc.font.charset);
                ansi(r.get(off..off + n).unwrap_or(&[]), sym)
            };
            let dx: Vec<f64> = if off_dx > 0 && off_dx + 4 * n <= r.len() { (0..n).map(|k| i32_at(r, off_dx + 4 * k)).collect() } else { Vec::new() };
            // With ETO_PDY each character has an x and a y advance.
            let dx: Vec<f64> = if opts & 0x2000 != 0 && off_dx + 8 * n <= r.len() { (0..n).map(|k| i32_at(r, off_dx + 8 * k)).collect() } else { dx };
            let opaque = (opts & 0x2 != 0).then_some(rect);
            let glyph_indices = opts & 0x10 != 0;
            if !glyph_indices {
                g.text(x, y, &chars, if dx.len() == chars.len() { Some(&dx) } else { None }, opaque);
            }
        }
        _ => {}
    }
}
