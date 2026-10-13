//! OfficeArt ("Escher") drawing records: the shapes and pictures inside
//! Word 97 (`.doc`), Excel 97 (`.xls`) and PowerPoint 97 (`.ppt`) files.
//!
//! Records are an 8-byte header (version, instance, type, length) and a
//! body; containers (version 0xF) hold more records. This crate walks
//! them, reads shape properties, and turns stored pictures (BLIPs) back
//! into ordinary image files: PNG, JPEG, BMP, TIFF, EMF and WMF.
//!
//! Every length is checked against the bytes there are, so damaged
//! records end a walk instead of reading past it.

use std::io::Read;

fn u16_at(b: &[u8], i: usize) -> u16 {
    b.get(i..i.saturating_add(2)).map_or(0, |s| u16::from_le_bytes([s[0], s[1]]))
}

fn u32_at(b: &[u8], i: usize) -> u32 {
    b.get(i..i.saturating_add(4)).map_or(0, |s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn i32_at(b: &[u8], i: usize) -> i32 {
    u32_at(b, i) as i32
}

pub const DGG_CONTAINER: u16 = 0xF000;
pub const BSTORE_CONTAINER: u16 = 0xF001;
pub const DG_CONTAINER: u16 = 0xF002;
pub const SPGR_CONTAINER: u16 = 0xF003;
pub const SP_CONTAINER: u16 = 0xF004;
pub const FBSE: u16 = 0xF007;
pub const FSPGR: u16 = 0xF009;
pub const FSP: u16 = 0xF00A;
pub const OPT: u16 = 0xF00B;
pub const CLIENT_TEXTBOX: u16 = 0xF00D;
pub const CHILD_ANCHOR: u16 = 0xF00F;
pub const CLIENT_ANCHOR: u16 = 0xF010;
pub const CLIENT_DATA: u16 = 0xF011;
pub const TERTIARY_OPT: u16 = 0xF122;

/// A record: header fields and where its body is in the buffer walked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record {
    pub ver: u8,
    pub inst: u16,
    pub ty: u16,
    /// The body: `start..end` in the buffer (clipped to it).
    pub start: usize,
    pub end: usize,
}

impl Record {
    pub fn is_container(&self) -> bool {
        self.ver == 0xF
    }

    pub fn body<'a>(&self, b: &'a [u8]) -> &'a [u8] {
        &b[self.start..self.end]
    }

    /// The records inside a container.
    pub fn children<'a>(&self, b: &'a [u8]) -> Records<'a> {
        Records { b, at: self.start, end: self.end }
    }
}

/// Sibling records in `b[at..end]`.
pub struct Records<'a> {
    b: &'a [u8],
    at: usize,
    end: usize,
}

/// The records at the top level of `b`.
pub fn records(b: &[u8]) -> Records<'_> {
    Records { b, at: 0, end: b.len() }
}

/// The records in `b[at..end]`.
pub fn records_in(b: &[u8], at: usize, end: usize) -> Records<'_> {
    Records { b, at, end: end.min(b.len()) }
}

/// The record whose header is at `at`, if one fits.
pub fn record_at(b: &[u8], at: usize) -> Option<Record> {
    records_in(b, at, b.len()).next()
}

impl Iterator for Records<'_> {
    type Item = Record;

    fn next(&mut self) -> Option<Record> {
        if self.at.checked_add(8)? > self.end {
            return None;
        }
        let vi = u16_at(self.b, self.at);
        let start = self.at + 8;
        let end = start.saturating_add(u32_at(self.b, self.at + 4) as usize).min(self.end);
        let r = Record { ver: (vi & 0xF) as u8, inst: vi >> 4, ty: u16_at(self.b, self.at + 2), start, end };
        self.at = end;
        Some(r)
    }
}

/// Visit every atom (non-container record) under `b[at..end]`, depth
/// first, with the containers above it.
pub fn walk(b: &[u8], at: usize, end: usize, f: &mut dyn FnMut(&Record)) {
    fn go(b: &[u8], at: usize, end: usize, depth: usize, f: &mut dyn FnMut(&Record)) {
        for r in records_in(b, at, end) {
            if r.is_container() && depth < 32 {
                go(b, r.start, r.end, depth + 1, f);
            } else {
                f(&r);
            }
        }
    }
    go(b, at, end, 0, f)
}

/// A shape property: id, value, and its complex data when it has some.
#[derive(Clone, Debug, PartialEq)]
pub struct Prop<'a> {
    pub id: u16,
    pub blip: bool,
    pub value: u32,
    pub complex: Option<&'a [u8]>,
}

/// The properties of an OPT record (its instance counts them).
pub fn props<'a>(b: &'a [u8], r: &Record) -> Vec<Prop<'a>> {
    let body = r.body(b);
    let count = r.inst as usize;
    let mut out = Vec::with_capacity(count.min(512));
    let mut data = 6 * count;
    for k in 0..count {
        let at = 6 * k;
        if at + 6 > body.len() {
            break;
        }
        let opid = u16_at(body, at);
        let value = u32_at(body, at + 2);
        let complex = if opid & 0x8000 != 0 {
            let s = data.min(body.len());
            let e = s.saturating_add(value as usize).min(body.len());
            data = s.saturating_add(value as usize);
            Some(&body[s..e])
        } else {
            None
        };
        out.push(Prop { id: opid & 0x3FFF, blip: opid & 0x4000 != 0, value, complex });
    }
    out
}

/// A property's value by id.
pub fn prop(props: &[Prop], id: u16) -> Option<u32> {
    props.iter().find(|p| p.id == id).map(|p| p.value)
}

/// A boolean property: bit `bit` of the set whose id is `id`, if it is
/// in use (its use bit, 16 higher, set).
pub fn flag(props: &[Prop], id: u16, bit: u32) -> Option<bool> {
    let v = prop(props, id)?;
    (v & (1 << (bit + 16)) != 0).then_some(v & (1 << bit) != 0)
}

/// A colour in a shape property.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArtColor {
    Rgb(u32),
    /// An index into the slide's colour scheme.
    Scheme(u8),
    /// One of the shape's own colours or a system colour.
    System(u16),
}

pub fn color(v: u32) -> ArtColor {
    let flags = (v >> 24) as u8;
    if flags & 0x08 != 0 {
        ArtColor::Scheme((v & 0xFF) as u8)
    } else if flags & 0x10 != 0 {
        ArtColor::System((v & 0xFFFF) as u16)
    } else {
        ArtColor::Rgb((v & 0xFF) << 16 | (v & 0xFF00) | (v >> 16) & 0xFF)
    }
}

/// The first picture among records: a picture shape and its store entry,
/// or a picture record itself. `delay` holds pictures stored outside
/// (the Word document stream, PowerPoint's Pictures stream).
pub fn find_blip(b: &[u8], delay: &[u8]) -> Option<(Vec<u8>, &'static str)> {
    for r in records(b) {
        match r.ty {
            FBSE => {
                if let Some(x) = fbse_blip(r.body(b), delay) {
                    return Some(x);
                }
            }
            0xF018..=0xF117 => {
                if let Some(x) = blip(&b[r.start - 8..r.end]) {
                    return Some(x);
                }
            }
            _ => {}
        }
    }
    None
}

/// The store entries (FBSE bodies) of a drawing group: picture ids are
/// 1-based indexes into them.
pub fn store_entries(b: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    walk(b, 0, b.len(), &mut |r| {
        if r.ty == FBSE {
            out.push((r.start, r.end));
        }
    });
    out
}

/// A picture store entry's picture: embedded after it, or at its offset
/// in the delay stream.
pub fn fbse_blip(body: &[u8], delay: &[u8]) -> Option<(Vec<u8>, &'static str)> {
    let size = u32_at(body, 20) as usize;
    let fo = u32_at(body, 28) as usize;
    let name = *body.get(33).unwrap_or(&0) as usize;
    let inner = body.get(36 + name..).unwrap_or(&[]);
    if inner.len() >= 8 {
        return blip(inner);
    }
    if size > 0 {
        return blip(delay.get(fo..fo.checked_add(size)?.min(delay.len()))?);
    }
    None
}

/// A picture record (header included) as an image file and its extension.
pub fn blip(rec: &[u8]) -> Option<(Vec<u8>, &'static str)> {
    let inst = u16_at(rec, 0) >> 4;
    let ty = u16_at(rec, 2);
    let len = u32_at(rec, 4) as usize;
    let body = rec.get(8..8usize.checked_add(len)?.min(rec.len()))?;
    // One 16-byte id, or two for these instances.
    let uids = |two: &[u16]| if two.contains(&inst) { 32 } else { 16 };
    match ty {
        0xF01A | 0xF01B => {
            let h = body.get(uids(&[0x3D5, 0x217])..)?;
            let cb_save = u32_at(h, 28) as usize;
            let raw = h.get(34..34usize.saturating_add(cb_save).min(h.len()))?;
            let data = if h.get(32) == Some(&0) {
                let mut out = Vec::new();
                flate2::read::ZlibDecoder::new(raw).take(64 * 1024 * 1024).read_to_end(&mut out).ok()?;
                out
            } else {
                raw.to_vec()
            };
            if ty == 0xF01A {
                return Some((data, "emf"));
            }
            // A WMF needs its placeable header back.
            let (l, t, r, bm) = (i32_at(h, 4), i32_at(h, 8), i32_at(h, 12), i32_at(h, 16));
            let cx = i32_at(h, 20);
            let inch = if cx > 0 { ((r - l) as i64 * 914_400 / cx as i64).clamp(1, 32767) } else { 1440 } as u16;
            let mut out = Vec::with_capacity(22 + data.len());
            out.extend_from_slice(&0x9AC6_CDD7u32.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            for v in [l, t, r, bm] {
                out.extend_from_slice(&(v as i16).to_le_bytes());
            }
            out.extend_from_slice(&inch.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            let sum = (0..10).fold(0u16, |s, k| s ^ u16_at(&out, 2 * k));
            out.extend_from_slice(&sum.to_le_bytes());
            out.extend_from_slice(&data);
            Some((out, "wmf"))
        }
        0xF01D | 0xF02A => Some((body.get(uids(&[0x46B, 0x6E3]) + 1..)?.to_vec(), "jpeg")),
        0xF01E => Some((body.get(uids(&[0x6E1]) + 1..)?.to_vec(), "png")),
        0xF029 => Some((body.get(uids(&[0x6E5]) + 1..)?.to_vec(), "tiff")),
        0xF01F => {
            let dib = body.get(uids(&[0x7A9]) + 1..)?;
            let header = u32_at(dib, 0) as usize;
            let bits = u16_at(dib, 14);
            let used = u32_at(dib, 32) as usize;
            let colors = if used != 0 {
                used.min(256)
            } else if bits <= 8 {
                1 << bits
            } else {
                0
            };
            let masks = if u32_at(dib, 16) == 3 && header == 40 { 12 } else { 0 };
            let mut out = Vec::with_capacity(14 + dib.len());
            out.extend_from_slice(b"BM");
            out.extend_from_slice(&((14 + dib.len()) as u32).to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&((14 + header + 4 * colors + masks) as u32).to_le_bytes());
            out.extend_from_slice(dib);
            Some((out, "bmp"))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(ver: u16, inst: u16, ty: u16, body: &[u8]) -> Vec<u8> {
        let mut v = (ver | inst << 4).to_le_bytes().to_vec();
        v.extend_from_slice(&ty.to_le_bytes());
        v.extend_from_slice(&(body.len() as u32).to_le_bytes());
        v.extend_from_slice(body);
        v
    }

    #[test]
    fn walks_records_and_reads_properties() {
        // An OPT with a fill colour and a complex property, in a shape
        // container.
        let mut opt = Vec::new();
        opt.extend_from_slice(&0x0181u16.to_le_bytes());
        opt.extend_from_slice(&0x0000_00FFu32.to_le_bytes());
        opt.extend_from_slice(&(0x8000u16 | 0x0145).to_le_bytes());
        opt.extend_from_slice(&3u32.to_le_bytes());
        opt.extend_from_slice(&0x01BFu16.to_le_bytes());
        opt.extend_from_slice(&0x0010_0010u32.to_le_bytes());
        opt.extend_from_slice(&[7, 8, 9]);
        let sp = rec(0xF, 0, SP_CONTAINER, &[rec(2, 1, FSP, &[5, 0, 0, 0, 0, 0, 0, 0]), rec(3, 3, OPT, &opt)].concat());
        let mut seen = Vec::new();
        walk(&sp, 0, sp.len(), &mut |r| seen.push(r.ty));
        assert_eq!(seen, [FSP, OPT]);
        let shape = records(&sp).next().unwrap();
        let opt_rec = shape.children(&sp).nth(1).unwrap();
        let p = props(&sp, &opt_rec);
        assert_eq!(color(prop(&p, 0x0181).unwrap()), ArtColor::Rgb(0xFF0000));
        assert_eq!(p[1].complex, Some(&[7u8, 8, 9][..]));
        assert_eq!(flag(&p, 0x01BF, 4), Some(true));
        assert_eq!(flag(&p, 0x01BF, 3), None);
        assert_eq!(color(0x0800_0003), ArtColor::Scheme(3));
    }

    #[test]
    fn turns_pictures_into_files() {
        let png = b"\x89PNG\r\n\x1a\nrest".to_vec();
        let blip_rec = rec(0, 0x6E0, 0xF01E, &[vec![0u8; 17], png.clone()].concat());
        assert_eq!(blip(&blip_rec), Some((png.clone(), "png")));
        // In a store entry, embedded.
        let mut head = vec![6u8, 6];
        head.extend_from_slice(&[0; 34]);
        let fbse = rec(2, 6, FBSE, &[head.clone(), blip_rec.clone()].concat());
        assert_eq!(find_blip(&fbse, &[]), Some((png.clone(), "png")));
        // Stored in a delay stream.
        let mut head2 = head.clone();
        head2[20..24].copy_from_slice(&(blip_rec.len() as u32).to_le_bytes());
        head2[28..32].copy_from_slice(&4u32.to_le_bytes());
        let delay = [vec![0u8; 4], blip_rec].concat();
        assert_eq!(fbse_blip(&head2, &delay), Some((png, "png")));
        // A DIB becomes a BMP with its file header.
        let mut dib = vec![0u8; 40];
        dib[0] = 40;
        dib[14] = 24;
        dib.extend_from_slice(&[1, 2, 3, 0]);
        let (bmp, ext) = blip(&rec(0, 0x7A8, 0xF01F, &[vec![0u8; 17], dib].concat())).unwrap();
        assert_eq!(ext, "bmp");
        assert_eq!(&bmp[..2], b"BM");
        assert_eq!(u32_at(&bmp, 10), 54);
        // Damaged lengths end quietly.
        assert_eq!(blip(&[0xFF; 6]), None);
        assert_eq!(records(&[0, 0, 0, 0xF0, 0xFF, 0xFF, 0xFF, 0x7F, 1]).count(), 1);
    }
}
