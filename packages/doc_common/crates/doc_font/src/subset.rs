//! TrueType subsetting for embedding: the glyphs used (and composite
//! glyphs' parts) keep their outlines and ids; every other glyph is empty.

use std::collections::BTreeSet;

use crate::{u16_at, Font};

/// Tables a PDF's embedded TrueType font needs.
const KEEP: [&[u8; 4]; 9] = [b"head", b"hhea", b"maxp", b"hmtx", b"cvt ", b"fpgm", b"prep", b"OS/2", b"post"];

fn glyph_range(loca: &[u8], long: bool, g: usize) -> Option<(usize, usize)> {
    if long {
        let s = crate::u32_at(loca, g * 4)? as usize;
        let e = crate::u32_at(loca, g * 4 + 4)? as usize;
        Some((s, e))
    } else {
        let s = u16_at(loca, g * 2)? as usize * 2;
        let e = u16_at(loca, g * 2 + 2)? as usize * 2;
        Some((s, e))
    }
}

pub fn subset(font: &Font, used: &BTreeSet<u16>) -> Option<Vec<u8>> {
    if font.is_cff {
        return None;
    }
    let head = font.table(b"head")?;
    let loca = font.table(b"loca")?;
    let glyf = font.table(b"glyf")?;
    let long = u16_at(head, 50)? == 1;
    let n = font.num_glyphs as usize;
    // Glyph 0 (.notdef) always, then composites' parts.
    let mut keep: BTreeSet<u16> = used.iter().copied().filter(|g| (*g as usize) < n).collect();
    keep.insert(0);
    let mut stack: Vec<u16> = keep.iter().copied().collect();
    while let Some(g) = stack.pop() {
        let Some((s, e)) = glyph_range(loca, long, g as usize) else { continue };
        if e <= s || e > glyf.len() {
            continue;
        }
        let data = &glyf[s..e];
        if data.len() < 10 || i16::from_be_bytes([data[0], data[1]]) >= 0 {
            continue;
        }
        // Composite: walk its components.
        let mut at = 10;
        loop {
            let (Some(flags), Some(comp)) = (u16_at(data, at), u16_at(data, at + 2)) else { break };
            if keep.insert(comp) {
                stack.push(comp);
            }
            at += 4;
            at += if flags & 0x0001 != 0 { 4 } else { 2 };
            if flags & 0x0008 != 0 {
                at += 2;
            } else if flags & 0x0040 != 0 {
                at += 4;
            } else if flags & 0x0080 != 0 {
                at += 8;
            }
            if flags & 0x0020 == 0 {
                break;
            }
        }
    }
    let mut new_glyf = Vec::new();
    let mut new_loca = Vec::with_capacity((n + 1) * 4);
    for g in 0..n {
        new_loca.extend_from_slice(&(new_glyf.len() as u32).to_be_bytes());
        if keep.contains(&(g as u16)) {
            if let Some((s, e)) = glyph_range(loca, long, g) {
                if e > s && e <= glyf.len() {
                    new_glyf.extend_from_slice(&glyf[s..e]);
                    while new_glyf.len() % 4 != 0 {
                        new_glyf.push(0);
                    }
                }
            }
        }
    }
    new_loca.extend_from_slice(&(new_glyf.len() as u32).to_be_bytes());
    let mut tables: Vec<([u8; 4], Vec<u8>)> = Vec::new();
    for tag in KEEP {
        if let Some(t) = font.table(tag) {
            let mut t = t.to_vec();
            if tag == b"head" && t.len() >= 54 {
                // Long offsets; the checksum adjustment is recomputed below.
                t[50] = 0;
                t[51] = 1;
                t[8..12].copy_from_slice(&[0, 0, 0, 0]);
            }
            tables.push((*tag, t));
        }
    }
    tables.push((*b"loca", new_loca));
    tables.push((*b"glyf", new_glyf));
    Some(rebuild(font, &tables))
}

fn checksum(data: &[u8]) -> u32 {
    let mut sum = 0u32;
    for chunk in data.chunks(4) {
        let mut b = [0u8; 4];
        b[..chunk.len()].copy_from_slice(chunk);
        sum = sum.wrapping_add(u32::from_be_bytes(b));
    }
    sum
}

/// An sfnt file from tables.
pub fn rebuild(font: &Font, tables: &[([u8; 4], Vec<u8>)]) -> Vec<u8> {
    let mut tables: Vec<&([u8; 4], Vec<u8>)> = tables.iter().collect();
    tables.sort_by_key(|t| t.0);
    let n = tables.len() as u16;
    let mut entry = 1u16;
    let mut pow = 0u16;
    while entry * 2 <= n {
        entry *= 2;
        pow += 1;
    }
    let mut out = Vec::new();
    let version: u32 = if font.is_cff { 0x4F54_544F } else { 0x0001_0000 };
    out.extend_from_slice(&version.to_be_bytes());
    out.extend_from_slice(&n.to_be_bytes());
    out.extend_from_slice(&(entry * 16).to_be_bytes());
    out.extend_from_slice(&pow.to_be_bytes());
    out.extend_from_slice(&(n * 16 - entry * 16).to_be_bytes());
    let mut offset = 12 + 16 * tables.len();
    let mut body = Vec::new();
    let mut head_at = None;
    for (tag, data) in &tables {
        out.extend_from_slice(tag);
        out.extend_from_slice(&checksum(data).to_be_bytes());
        out.extend_from_slice(&(offset as u32).to_be_bytes());
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        if tag == b"head" {
            head_at = Some(offset);
        }
        body.extend_from_slice(data);
        while body.len() % 4 != 0 {
            body.push(0);
        }
        offset = 12 + 16 * tables.len() + body.len();
    }
    out.extend_from_slice(&body);
    if let Some(h) = head_at {
        if out.len() >= h + 12 {
            out[h + 8..h + 12].copy_from_slice(&[0, 0, 0, 0]);
            let adj = 0xB1B0_AFBAu32.wrapping_sub(checksum(&out));
            out[h + 8..h + 12].copy_from_slice(&adj.to_be_bytes());
        }
    }
    out
}
