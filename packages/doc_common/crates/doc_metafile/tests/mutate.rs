//! 20,000 mutations of metafiles that use every record the player knows:
//! none may panic, take long or hold much memory. The seed is fixed, so a
//! failure repeats.

mod support;

use std::time::{Duration, Instant};

use doc_testkit::{mutate, run_limited, Limits, Rng};
use support::bounded;

fn put16(b: &mut Vec<u8>, v: i32) {
    b.extend_from_slice(&(v as i16).to_le_bytes());
}

fn put32(b: &mut Vec<u8>, v: i32) {
    b.extend_from_slice(&v.to_le_bytes());
}

fn wrec(f: u16, params: &[i32]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, 3 + params.len() as i32);
    r.extend_from_slice(&f.to_le_bytes());
    for p in params {
        put16(&mut r, *p);
    }
    r
}

/// A WMF record with raw bytes after its function.
fn wrec_bytes(f: u16, body: &[u8]) -> Vec<u8> {
    let mut r = Vec::new();
    let words = 3 + body.len().div_ceil(2);
    put32(&mut r, words as i32);
    r.extend_from_slice(&f.to_le_bytes());
    r.extend_from_slice(body);
    r.resize(words * 2, 0);
    r
}

/// 16-bit words.
fn words(v: &[i32]) -> Vec<u8> {
    let mut b = Vec::new();
    for x in v {
        put16(&mut b, *x);
    }
    b
}

fn wmf(records: &[Vec<u8>]) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&0x9AC6_CDD7u32.to_le_bytes());
    put16(&mut b, 0);
    for v in [0, 0, 1000, 1000, 1000] {
        put16(&mut b, v);
    }
    put32(&mut b, 0);
    let sum = (0..10).fold(0u16, |s, k| s ^ u16::from_le_bytes([b[2 * k], b[2 * k + 1]]));
    b.extend_from_slice(&sum.to_le_bytes());
    let body: Vec<u8> = records.concat();
    for v in [1, 9, 0x0300] {
        put16(&mut b, v);
    }
    put32(&mut b, (9 + body.len() / 2 + 3) as i32);
    put16(&mut b, 4);
    put32(&mut b, 10);
    put16(&mut b, 0);
    b.extend_from_slice(&body);
    b.extend(wrec(0, &[]));
    b
}

fn erec(ty: u32, body: &[i32]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, ty as i32);
    put32(&mut r, 8 + 4 * body.len() as i32);
    for v in body {
        put32(&mut r, *v);
    }
    r
}

fn erec_bytes(ty: u32, body: &[u8]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, ty as i32);
    let len = 8 + body.len().div_ceil(4) * 4;
    put32(&mut r, len as i32);
    r.extend_from_slice(body);
    r.resize(len, 0);
    r
}

fn emf(records: &[Vec<u8>]) -> Vec<u8> {
    let mut h = Vec::new();
    put32(&mut h, 1);
    put32(&mut h, 88);
    for v in [0, 0, 99, 99, 0, 0, 2540, 2540] {
        put32(&mut h, v);
    }
    h.extend_from_slice(b" EMF");
    for v in [0x10000, 0, 0, 0, 0, 0, 0] {
        put32(&mut h, v);
    }
    for v in [1000, 1000, 254, 254] {
        put32(&mut h, v);
    }
    let mut b = h;
    for r in records {
        b.extend_from_slice(r);
    }
    b.extend(erec(14, &[0, 0, 0]));
    b
}

/// A 2x2 DIB of `bpp` bits (header, colours, bits).
fn dib(bpp: i32, compression: i32) -> (Vec<u8>, Vec<u8>) {
    let mut bmi = Vec::new();
    for v in [40, 2, -2] {
        put32(&mut bmi, v);
    }
    put16(&mut bmi, 1);
    put16(&mut bmi, bpp);
    put32(&mut bmi, compression);
    for _ in 0..5 {
        put32(&mut bmi, 0);
    }
    if compression == 3 {
        for m in [0xF800, 0x07E0, 0x001F] {
            put32(&mut bmi, m);
        }
    }
    if bpp <= 8 {
        for k in 0..(1 << bpp) {
            bmi.extend_from_slice(&[(k * 40) as u8, 255 - k as u8, 128, 0]);
        }
    }
    let stride = ((2 * bpp as usize).div_ceil(32)) * 4;
    let bits: Vec<u8> = (0..stride * 2).map(|i| (i * 37) as u8).collect();
    (bmi, bits)
}

fn seeds() -> Vec<Vec<u8>> {
    let mut seeds = Vec::new();
    let mut font = vec![0u8; 18];
    font[..2].copy_from_slice(&(-40i16).to_le_bytes());
    font.extend_from_slice(b"Arial\0\0\0");
    let (bmi, bits) = dib(8, 0);
    let mut wdib = Vec::new();
    for v in [0x00CC, 0x0020, 2, 2, 0, 0, 500, 500, 100, 100] {
        put16(&mut wdib, v);
    }
    wdib.extend_from_slice(&bmi);
    wdib.extend_from_slice(&bits);
    seeds.push(wmf(&[
        wrec(0x020B, &[0, 0]),
        wrec(0x020C, &[1000, 1000]),
        wrec(0x0103, &[8]),
        wrec(0x0102, &[2]),
        wrec(0x0106, &[1]),
        wrec(0x012E, &[0]),
        wrec(0x0209, &[0x00FF, 0]),
        wrec(0x0201, &[0xFFFF, 0x00FF]),
        wrec(0x02FC, &[0, 0x00FF, 0, 0]),
        wrec(0x012D, &[0]),
        wrec(0x02FA, &[1, 5, 0, 0xFF00, 0]),
        wrec(0x012D, &[1]),
        wrec(0x001E, &[]),
        wrec(0x0214, &[100, 100]),
        wrec(0x0213, &[900, 900]),
        wrec(0x041B, &[400, 400, 100, 100]),
        wrec(0x0418, &[900, 900, 500, 500]),
        wrec(0x061C, &[50, 50, 700, 300, 450, 50]),
        wrec(0x0817, &[100, 900, 600, 600, 950, 950, 500, 500]),
        wrec(0x0830, &[300, 100, 900, 600, 950, 950, 500, 500]),
        wrec(0x081A, &[700, 200, 100, 600, 900, 900, 300, 300]),
        wrec(0x0324, &[3, 600, 100, 900, 100, 750, 400]),
        wrec(0x0325, &[4, 10, 10, 990, 30, 500, 500, 20, 980]),
        wrec(0x0538, &[2, 3, 3, 10, 600, 300, 650, 150, 700, 700, 800, 750, 900, 820, 650]),
        wrec(0x0127, &[-1]),
        wrec(0x02FA, &[2, 0, 0, 0, 0]),
        wrec(0x012D, &[2]),
        wrec(0x0325, &[3, 0, 999, 999, 0, 500, 999]),
        wrec(0x01F0, &[2]),
        wrec_bytes(0x02FB, &font),
        wrec(0x012D, &[2]),
        wrec_bytes(0x0521, &[5, 0, b'H', b'e', b'l', b'l', b'o', 0, 100, 0, 100, 0]),
        wrec_bytes(0x0A32, &[200, 0, 100, 0, 3, 0, 6, 0, 0, 0, 0, 0, 200, 0, 200, 0, b'W', b'o', b'r', b'l', b'd', 0, 20, 0, 20, 0, 20, 0]),
        wrec(0x00F7, &[0x300, 1, 0, 0]),
        wrec(0x01F9, &[0, 0]),
        wrec(0x0416, &[950, 950, 50, 50]),
        wrec(0x061D, &[0x0021, 0x00F0, 100, 100, 800, 800]),
        wrec_bytes(0x0F43, &[words(&[0x20, 0xCC, 0, 2, 2, 0, 0, 200, 200, 700, 700]), bmi.clone(), bits.clone()].concat()),
        wrec_bytes(0x0B41, &[words(&[0x20, 0xCC, 2, 2, 0, 0, 100, 100, 50, 50]), bmi.clone(), bits.clone()].concat()),
        wrec_bytes(0x0940, &[words(&[0x20, 0xCC, 0, 0, 2, 2, 10, 10]), bmi.clone(), bits.clone()].concat()),
        wrec_bytes(0x0D33, &[words(&[0, 2, 0, 0, 0, 2, 2, 30, 30]), bmi.clone(), bits.clone()].concat()),
    ]));
    // EMF: every record the player draws.
    let mut ellipse_path = vec![erec(59, &[]), erec(27, &[10, 10]), erec(54, &[90, 20]), erec(54, &[50, 90]), erec(61, &[]), erec(60, &[]), erec(63, &[])];
    let mut records = vec![
        erec(17, &[8]),
        erec(9, &[100, 100]),
        erec(10, &[0, 0]),
        erec(11, &[100, 100]),
        erec(12, &[0, 0]),
        erec(18, &[1]),
        erec(19, &[2]),
        erec(22, &[24]),
        erec(24, &[0xFF]),
        erec(25, &[0xFFFFFF]),
        erec(33, &[]),
        erec(35, &[1f32.to_bits() as i32, 0, 0, 1f32.to_bits() as i32, 2f32.to_bits() as i32, 0]),
        erec(36, &[1f32.to_bits() as i32, 0, 0, 1f32.to_bits() as i32, 0, 3f32.to_bits() as i32, 2]),
        erec(38, &[1, 1, 3, 0, 0x00FF00]),
        erec(37, &[1]),
        erec(95, &[2, 0, 0, 0, 0, 0x0001_0003, 4, 0, 0xFF0000, 0, 0]),
        erec(37, &[2]),
        erec(39, &[3, 0, 0x808080, 0]),
        erec(37, &[3]),
        erec(93, &[4, 0, 0, 0, 0]),
        erec(37, &[0x8000_0001u32 as i32]),
        erec(42, &[10, 10, 60, 50]),
        erec(43, &[20, 20, 80, 70]),
        erec(44, &[5, 5, 95, 95, 20, 20]),
        erec(45, &[10, 10, 90, 90, 90, 50, 50, 10]),
        erec(46, &[10, 10, 90, 90, 90, 50, 50, 10]),
        erec(47, &[10, 10, 90, 90, 90, 50, 50, 10]),
        erec(55, &[10, 10, 90, 90, 90, 50, 50, 10]),
        erec(2, &[0, 0, 99, 99, 4, 5, 5, 30, 90, 70, 0, 95, 95]),
        erec(5, &[0, 0, 99, 99, 3, 30, 90, 70, 0, 95, 95]),
        erec(3, &[0, 0, 99, 99, 3, 10, 10, 90, 10, 50, 90]),
        erec(4, &[0, 0, 99, 99, 3, 10, 90, 90, 90, 50, 10]),
        erec(6, &[0, 0, 99, 99, 2, 20, 30, 70, 80]),
        erec(7, &[0, 0, 99, 99, 2, 5, 3, 2, 1, 1, 50, 1, 99, 50, 10, 80, 90, 80]),
        erec(8, &[0, 0, 99, 99, 2, 6, 3, 3, 1, 1, 50, 1, 99, 50, 10, 80, 90, 80, 50, 99]),
        erec(30, &[5, 5, 95, 95]),
        erec(75, &[0, 0]),
        erec(34, &[-1]),
        erec(40, &[2]),
    ];
    let mut p16 = Vec::new();
    for v in [0, 0, 99, 99, 4] {
        put32(&mut p16, v);
    }
    for v in [5, 5, 95, 5, 95, 95, 5, 95] {
        put16(&mut p16, v);
    }
    for ty in [85, 86, 87, 88, 89] {
        records.push(erec_bytes(ty, &p16));
    }
    let mut pp16 = Vec::new();
    for v in [0, 0, 99, 99, 2, 6, 3, 3] {
        put32(&mut pp16, v);
    }
    for v in [1, 1, 50, 1, 99, 50, 10, 80, 90, 80, 50, 99] {
        put16(&mut pp16, v);
    }
    records.push(erec_bytes(90, &pp16));
    records.push(erec_bytes(91, &pp16));
    // FillRgn and PaintRgn: a region of two rectangles.
    let region = [0, 0, 99, 99, 32, 1, 2, 32, 0, 0, 99, 99, 0, 0, 50, 50, 50, 50, 99, 99];
    records.push(erec(71, &[&[0, 0, 99, 99, 0, 3][..], &region[4..]].concat()));
    records.push(erec(74, &[&[0, 0, 99, 99, 0][..], &region[4..]].concat()));
    // Font and text.
    let mut lf = Vec::new();
    for v in [5, -12, 0, 0, 0, 400] {
        put32(&mut lf, v);
    }
    lf.extend_from_slice(&[1, 1, 0, 0, 0, 0, 0, 0]);
    for c in "Arial".encode_utf16() {
        lf.extend_from_slice(&c.to_le_bytes());
    }
    lf.resize(4 + 92, 0);
    records.push(erec_bytes(82, &lf));
    records.push(erec(37, &[5]));
    for (ty, text) in [(84u32, "Héllo".encode_utf16().flat_map(|u| u.to_le_bytes()).collect::<Vec<u8>>()), (83, b"World".to_vec())] {
        let n = if ty == 84 { text.len() / 2 } else { text.len() };
        let mut t = Vec::new();
        for v in [0, 0, 99, 99, 1, 0, 0, 10, 50, n as i32, 76, 0x2 | 0x2000, 0, 0, 99, 99, (76 + text.len().div_ceil(4) * 4) as i32] {
            put32(&mut t, v);
        }
        t.extend_from_slice(&text);
        t.resize(t.len().div_ceil(4) * 4, 0);
        for k in 0..2 * n {
            put32(&mut t, 5 + k as i32);
        }
        records.push(erec_bytes(ty, &t));
    }
    // Pictures: StretchDIBits, BitBlt, StretchBlt, SetDIBitsToDevice and
    // AlphaBlend, at several depths.
    for (bpp, comp) in [(1, 0), (4, 0), (8, 0), (16, 3), (24, 0), (32, 0), (32, 3)] {
        let (bmi, bits) = dib(bpp, comp);
        let mut s = Vec::new();
        for v in [0, 0, 99, 99, 0, 0, 0, 0, 2, 2, 80, bmi.len() as i32, 80 + bmi.len() as i32, bits.len() as i32, 0, 0x00CC_0020, 40, 40] {
            put32(&mut s, v);
        }
        s.extend_from_slice(&bmi);
        s.extend_from_slice(&bits);
        records.push(erec_bytes(81, &s));
        let mut blt = Vec::new();
        for v in [0, 0, 99, 99, 50, 50, 40, 40, 0x00CC_0020, 0, 0, 1 << 16, 0, 0, 1 << 16, 0, 0, 0, 0, 108, bmi.len() as i32, 108 + bmi.len() as i32, bits.len() as i32, 2, 2] {
            put32(&mut blt, v);
        }
        blt.resize(100, 0);
        blt.extend_from_slice(&bmi);
        blt.extend_from_slice(&bits);
        for ty in [76, 77, 114] {
            records.push(erec_bytes(ty, &blt));
        }
        let mut set = Vec::new();
        for v in [0, 0, 99, 99, 60, 60, 0, 0, 2, 2, 76, bmi.len() as i32, 76 + bmi.len() as i32, bits.len() as i32, 0, 0, 2] {
            put32(&mut set, v);
        }
        set.extend_from_slice(&bmi);
        set.extend_from_slice(&bits);
        records.push(erec_bytes(80, &set));
    }
    records.append(&mut ellipse_path);
    records.push(erec(59, &[]));
    records.push(erec_bytes(88, &p16));
    records.push(erec(62, &[]));
    records.push(erec(59, &[]));
    records.push(erec(54, &[3, 4]));
    records.push(erec(64, &[]));
    records.push(erec(59, &[]));
    records.push(erec(67, &[]));
    seeds.push(emf(&records));
    seeds
}

#[test]
fn mutated_metafiles_never_panic_hang_or_hog_memory() {
    run_limited("mutated_metafiles_never_panic_hang_or_hog_memory", Limits::mutation(Duration::from_secs(305)), mutations).unwrap();
}

fn mutations() {
    let seeds = seeds();
    for s in &seeds {
        assert!(doc_metafile::render(s, 64, None).is_some(), "every seed draws");
    }
    let run = bounded("metafile mutations", 256 << 20, Duration::from_secs(300), move || {
        let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
        let mut slowest = (Duration::ZERO, 0);
        let mut drawn = 0;
        for i in 0..20_000 {
            let seed = &seeds[i % seeds.len()];
            let other = &seeds[(i + 1) % seeds.len()];
            let b = mutate(&mut rng, seed, other);
            // Small canvases: the records are read the same, and painting
            // in a debug build is slow.
            let px = 16 + rng.below(25) as u32;
            let t = Instant::now();
            if doc_metafile::render(&b, px, None).is_some() {
                drawn += 1;
            }
            let _ = doc_metafile::size(&b);
            if t.elapsed() > slowest.0 {
                slowest = (t.elapsed(), i);
            }
        }
        (slowest, drawn)
    });
    let ((slowest, at), drawn) = run.value;
    eprintln!("20,000 mutations in {:?}: {drawn} drawn, slowest {slowest:?} (#{at}), peak {} KB", run.time, run.peak / 1024);
    assert!(slowest < Duration::from_secs(2), "mutation #{at} took {slowest:?}");
}
