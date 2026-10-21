//! 20,000 mutations of PNG, GIF and BMP pictures, each handed to every
//! decoder: they may refuse it, but never panic, take long or hold more
//! than a picture's budget. The seed is fixed, so a failure repeats.

mod support;

use std::io::Write;
use std::time::{Duration, Instant};

use doc_testkit::{mutate, run_limited, Limits, Rng};
use support::bounded;

fn crc32(data: &[u8]) -> u32 {
    let mut c = 0xFFFF_FFFFu32;
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
        }
    }
    !c
}

fn chunk(out: &mut Vec<u8>, ty: &[u8], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut body = ty.to_vec();
    body.extend_from_slice(data);
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc32(&body).to_be_bytes());
}

/// A PNG from its filtered rows and extra chunks before the data.
fn png(w: u32, h: u32, depth: u8, ctype: u8, interlace: u8, rows: &[u8], extra: &[(&[u8], Vec<u8>)]) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[depth, ctype, 0, 0, interlace]);
    chunk(&mut out, b"IHDR", &ihdr);
    for (ty, data) in extra {
        chunk(&mut out, ty, data);
    }
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(rows).unwrap();
    chunk(&mut out, b"IDAT", &z.finish().unwrap());
    chunk(&mut out, b"IEND", &[]);
    out
}

/// Rows of `row_bytes` each, the filters taking turns.
fn rows(h: usize, row_bytes: usize) -> Vec<u8> {
    let mut r = Vec::new();
    for y in 0..h {
        r.push((y % 5) as u8);
        r.extend((0..row_bytes).map(|i| ((i * 31 + y * 7) % 256) as u8));
    }
    r
}

/// GIF image data: each index as a code of its own, so the decoder's
/// table grows as it reads and is cleared before it fills.
fn lzw(indexes: &[u8], min_code: u32) -> Vec<u8> {
    let clear = 1u32 << min_code;
    let (mut size, mut next) = (min_code + 1, clear + 2);
    let mut codes = vec![(clear, size)];
    for (k, &i) in indexes.iter().enumerate() {
        codes.push((i as u32, size));
        if k > 0 {
            next += 1;
            if next == 1 << size && size < 12 {
                size += 1;
            }
        }
        if next >= 4000 {
            codes.push((clear, size));
            size = min_code + 1;
            next = clear + 2;
        }
    }
    codes.push((clear + 1, size));
    let (mut acc, mut n, mut bytes) = (0u64, 0, Vec::new());
    for (c, width) in codes {
        acc |= (c as u64) << n;
        n += width;
        while n >= 8 {
            bytes.push(acc as u8);
            acc >>= 8;
            n -= 8;
        }
    }
    if n > 0 {
        bytes.push(acc as u8);
    }
    let mut out = vec![min_code as u8];
    for block in bytes.chunks(255) {
        out.push(block.len() as u8);
        out.extend_from_slice(block);
    }
    out.push(0);
    out
}

/// A GIF of `w` x `h` with a four-colour palette, global or local, and
/// a transparent colour.
fn gif(w: u16, h: u16, local: bool, interlaced: bool) -> Vec<u8> {
    let palette = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255];
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&w.to_le_bytes());
    g.extend_from_slice(&h.to_le_bytes());
    g.extend_from_slice(&[if local { 0 } else { 0x81 }, 0, 0]);
    if !local {
        g.extend_from_slice(&palette);
    }
    g.extend_from_slice(&[0x21, 0xF9, 4, 1, 0, 0, 3, 0]);
    g.extend_from_slice(&[0x21, 0xFE, 3, b'h', b'i', b'!', 0]);
    g.push(0x2C);
    for v in [0u16, 0, w, h] {
        g.extend_from_slice(&v.to_le_bytes());
    }
    g.push(if local { 0x81 } else { 0 } | if interlaced { 0x40 } else { 0 });
    if local {
        g.extend_from_slice(&palette);
    }
    let indexes: Vec<u8> = (0..w as usize * h as usize).map(|i| ((i / 3 + i / 7) % 4) as u8).collect();
    g.extend_from_slice(&lzw(&indexes, 2));
    g.push(0x3B);
    g
}

/// A BMP of `bpp` bits, bottom-up unless `top_down`, with a palette for
/// 8 bits and less, and bit fields for 16 and 32.
fn bmp(w: i32, h: i32, bpp: u16, top_down: bool) -> Vec<u8> {
    let colors = if bpp <= 8 { 1usize << bpp } else { 0 };
    let masks = if bpp == 16 || bpp == 32 { 12 } else { 0 };
    let data_at = 54 + 4 * colors + masks;
    let stride = (w as usize * bpp as usize).div_ceil(32) * 4;
    let mut b = b"BM".to_vec();
    b.extend_from_slice(&((data_at + stride * h as usize) as u32).to_le_bytes());
    b.extend_from_slice(&[0; 4]);
    b.extend_from_slice(&(data_at as u32).to_le_bytes());
    b.extend_from_slice(&40u32.to_le_bytes());
    b.extend_from_slice(&w.to_le_bytes());
    b.extend_from_slice(&(if top_down { -h } else { h }).to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&bpp.to_le_bytes());
    b.extend_from_slice(&(if masks > 0 { 3u32 } else { 0 }).to_le_bytes());
    b.extend_from_slice(&[0; 20]);
    if bpp == 16 {
        for m in [0xF800u32, 0x07E0, 0x001F] {
            b.extend_from_slice(&m.to_le_bytes());
        }
    } else if bpp == 32 {
        for m in [0x00FF_0000u32, 0x0000_FF00, 0x0000_00FF] {
            b.extend_from_slice(&m.to_le_bytes());
        }
    }
    for k in 0..colors {
        b.extend_from_slice(&[(k * 3) as u8, (k * 5) as u8, (k * 7) as u8, 0]);
    }
    b.extend((0..stride * h as usize).map(|i| (i * 13 % 256) as u8));
    b
}

fn seeds() -> Vec<Vec<u8>> {
    let rgba: Vec<u8> = (0..20 * 12 * 4).map(|i| (i * 3 % 256) as u8).collect();
    vec![
        png(16, 16, 8, 2, 0, &rows(16, 48), &[]),
        png(13, 5, 2, 3, 0, &rows(5, 4), &[(b"PLTE", vec![255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]), (b"tRNS", vec![255, 0, 128])]),
        png(7, 6, 16, 4, 0, &rows(6, 28), &[]),
        png(9, 9, 8, 6, 1, &[rows(2, 8), rows(2, 4), rows(1, 12), rows(3, 8), rows(2, 20), rows(5, 16), rows(4, 36)].concat(), &[]),
        png(11, 3, 1, 0, 1, &[rows(1, 1), rows(1, 1), rows(1, 1), rows(1, 1), rows(2, 1), rows(1, 2)].concat(), &[(b"tRNS", vec![0, 1])]),
        doc_image::encode_png(20, 12, &rgba),
        gif(8, 8, false, false),
        gif(10, 9, true, true),
        bmp(5, 3, 24, false),
        bmp(7, 2, 8, true),
        bmp(3, 3, 32, true),
        bmp(9, 2, 1, false),
        bmp(6, 4, 16, false),
        bmp(5, 5, 4, true),
    ]
}

/// Every decoder on the bytes: how many pictures came out.
fn decode_all(b: &[u8]) -> usize {
    let _ = (doc_image::kind(b), doc_image::size(b), doc_image::jpeg_info(b));
    [doc_image::decode(b), doc_image::decode_png(b), doc_image::decode_gif(b), doc_image::decode_bmp(b)].iter().filter(|r| r.is_ok()).count()
}

#[test]
fn every_seed_decodes() {
    for (k, s) in seeds().iter().enumerate() {
        let r = doc_image::decode(s).unwrap_or_else(|e| panic!("seed {k}: {e}"));
        assert!(r.width > 0 && r.pixels.len() == (r.width * r.height) as usize * r.channels as usize, "seed {k}");
    }
}

#[test]
fn mutated_pictures_never_panic_hang_or_hog_memory() {
    run_limited("mutated_pictures_never_panic_hang_or_hog_memory", Limits::mutation(Duration::from_secs(125)), mutations).unwrap();
}

fn mutations() {
    let seeds = seeds();
    // A picture may take its budget: 24M pixels of RGB and alpha.
    let run = bounded("picture mutations", 256 << 20, Duration::from_secs(120), move || {
        let mut rng = Rng(0x0DDB_1A5E_5BAD_5EED);
        let mut slowest = (Duration::ZERO, 0);
        let mut decoded = 0;
        for i in 0..20_000 {
            let b = mutate(&mut rng, &seeds[i % seeds.len()], &seeds[(i + 7) % seeds.len()]);
            let t = Instant::now();
            decoded += decode_all(&b);
            if t.elapsed() > slowest.0 {
                slowest = (t.elapsed(), i);
            }
        }
        (slowest, decoded)
    });
    let ((slowest, at), decoded) = run.value;
    eprintln!("20,000 mutations in {:?}: {decoded} decoded, slowest {slowest:?} (#{at}), peak {} KB", run.time, run.peak / 1024);
    assert!(slowest < Duration::from_secs(2), "mutation #{at} took {slowest:?}");
}
