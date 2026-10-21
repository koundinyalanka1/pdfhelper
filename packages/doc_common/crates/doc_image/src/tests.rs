use std::io::Write;

use super::*;

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

/// A PNG from raw (already filtered) rows.
fn png(w: u32, h: u32, depth: u8, ctype: u8, rows: &[u8], extra: &[(&[u8], Vec<u8>)]) -> Vec<u8> {
    png_i(w, h, depth, ctype, 0, rows, extra)
}

fn png_i(w: u32, h: u32, depth: u8, ctype: u8, interlace: u8, rows: &[u8], extra: &[(&[u8], Vec<u8>)]) -> Vec<u8> {
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

#[test]
fn png_rgb_with_filters() {
    // 2x2 RGB: row 0 unfiltered, row 1 "up".
    let rows = [0, 255, 0, 0, 0, 255, 0, /**/ 2, 0, 0, 255, 255, 0, 0];
    let p = png(2, 2, 8, 2, &rows, &[]);
    assert_eq!(kind(&p), Kind::Png);
    assert_eq!(size(&p), Some((2, 2)));
    let r = decode(&p).unwrap();
    assert_eq!(r.channels, 3);
    assert_eq!(r.pixels, vec![255, 0, 0, 0, 255, 0, 255, 0, 255, 255, 255, 0]);
    assert!(r.alpha.is_none());
}

#[test]
fn png_palette_with_transparency_and_low_depth() {
    // 4x1, 2 bits a pixel: indexes 0 1 2 3.
    let rows = [0, 0b0001_1011];
    let plte = vec![255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9];
    let p = png(4, 1, 2, 3, &rows, &[(b"PLTE", plte), (b"tRNS", vec![255, 0])]);
    let r = decode(&p).unwrap();
    assert_eq!(r.pixels, vec![255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]);
    assert_eq!(r.alpha, Some(vec![255, 0, 255, 255]));
}

#[test]
fn png_gray_alpha_sixteen_bit_and_paeth() {
    // 2x1 gray+alpha at 16 bits, Paeth filter on the first row (acts like Sub).
    let rows = [4, 0x80, 0, 0xFF, 0xFF, 0x10, 0, 0x01, 0];
    let p = png(2, 1, 16, 4, &rows, &[]);
    let r = decode(&p).unwrap();
    assert_eq!(r.channels, 1);
    assert_eq!(r.pixels, vec![0x80, 0x90]);
    assert_eq!(r.alpha, Some(vec![0xFF, 0x00]));
}

#[test]
fn png_interlaced() {
    // 2x2 RGBA, Adam7: pass 1 has (0,0), pass 6 has (1,0), pass 7 row 1.
    let mut rows = Vec::new();
    rows.extend_from_slice(&[0, 1, 2, 3, 255]);
    rows.extend_from_slice(&[0, 4, 5, 6, 255]);
    rows.extend_from_slice(&[0, 7, 8, 9, 255, 10, 11, 12, 255]);
    let p = png_i(2, 2, 8, 6, 1, &rows, &[]);
    let r = decode(&p).unwrap();
    assert_eq!(r.pixels, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
}

#[test]
fn gif_first_frame() {
    // A 2x2 GIF: palette red/blue, pixels 0 1 / 1 0, colour 1 transparent.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[2, 0, 2, 0, 0x80, 0, 0]);
    g.extend_from_slice(&[255, 0, 0, 0, 0, 255]);
    g.extend_from_slice(&[0x21, 0xF9, 4, 1, 0, 0, 1, 0]);
    g.extend_from_slice(&[0x2C, 0, 0, 0, 0, 2, 0, 2, 0, 0]);
    // LZW, min code 2: clear(4) 0 1 1 0 end(5); codes widen to 4 bits
    // once the table reaches 8 entries.
    let codes = [(4u32, 3), (0, 3), (1, 3), (1, 3), (0, 4), (5, 4)];
    let (mut acc, mut n, mut bytes) = (0u32, 0, Vec::new());
    for (c, width) in codes {
        acc |= c << n;
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
    g.push(2);
    g.push(bytes.len() as u8);
    g.extend_from_slice(&bytes);
    g.push(0);
    g.push(0x3B);
    assert_eq!(kind(&g), Kind::Gif);
    assert_eq!(size(&g), Some((2, 2)));
    let r = decode(&g).unwrap();
    assert_eq!(&r.pixels[..3], &[255, 0, 0]);
    assert_eq!(r.alpha, Some(vec![255, 0, 0, 255]));
}

#[test]
fn bmp_24_bit_bottom_up() {
    let (w, h) = (2u32, 2u32);
    let stride = 8u32;
    let mut b = b"BM".to_vec();
    b.extend_from_slice(&(54 + stride * 2).to_le_bytes());
    b.extend_from_slice(&[0, 0, 0, 0]);
    b.extend_from_slice(&54u32.to_le_bytes());
    b.extend_from_slice(&40u32.to_le_bytes());
    b.extend_from_slice(&(w as i32).to_le_bytes());
    b.extend_from_slice(&(h as i32).to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&24u16.to_le_bytes());
    b.extend_from_slice(&[0; 24]);
    // Bottom row first: blue, green; then red, white.
    b.extend_from_slice(&[255, 0, 0, 0, 255, 0, 0, 0]);
    b.extend_from_slice(&[0, 0, 255, 255, 255, 255, 0, 0]);
    let r = decode(&b).unwrap();
    assert_eq!(r.pixels, vec![255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0]);
}

#[test]
fn jpeg_headers() {
    let j = [0xFF, 0xD8, 0xFF, 0xEE, 0, 14, b'A', b'd', b'o', b'b', b'e', 0, 100, 0, 0, 0, 0, 2, 0xFF, 0xC0, 0, 17, 8, 0, 20, 0, 30, 4];
    let info = jpeg_info(&j).unwrap();
    assert_eq!((info.width, info.height, info.components, info.adobe), (30, 20, 4, true));
    assert_eq!(kind(&j), Kind::Jpeg);
}

#[test]
fn writes_pngs_it_can_read_back() {
    // A 3x2 picture, one pixel half transparent.
    let mut rgba = Vec::new();
    for i in 0..6u8 {
        rgba.extend_from_slice(&[i * 40, 255 - i * 40, 7, if i == 4 { 128 } else { 255 }]);
    }
    let png = encode_png(3, 2, &rgba);
    let r = decode(&png).unwrap();
    assert_eq!((r.width, r.height, r.channels), (3, 2, 3));
    assert_eq!(&r.pixels[..3], &[0, 255, 7]);
    assert_eq!(r.alpha.as_ref().unwrap()[4], 128);
    // All opaque: RGB.
    let opaque: Vec<u8> = rgba.chunks(4).flat_map(|p| [p[0], p[1], p[2], 255]).collect();
    let r = decode(&encode_png(3, 2, &opaque)).unwrap();
    assert!(r.alpha.is_none());
    assert_eq!(&r.pixels[15..18], &[200, 55, 7]);
}
