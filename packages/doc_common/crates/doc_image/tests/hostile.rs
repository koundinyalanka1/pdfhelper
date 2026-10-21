//! Hostile pictures: each must decode or fail cleanly within 2 s, 256 MB
//! and a 512 KiB stack.

mod support;

use std::io::Write;

use doc_image::{decode, ImageError};
use support::hostile;

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

fn png(w: u32, h: u32, depth: u8, ctype: u8, interlace: u8, idat: &[u8]) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[depth, ctype, 0, 0, interlace]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", idat);
    chunk(&mut out, b"IEND", &[]);
    out
}

fn zlib(raw: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
    z.write_all(raw).unwrap();
    z.finish().unwrap()
}

#[test]
fn a_28_byte_gif_whose_frame_claims_four_billion_pixels() {
    // A 1x1 screen with a 65,535 x 65,535 frame: the decoder reserved
    // 4.3 GB for the frame's colour indexes before reading any.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[1, 0, 1, 0, 0, 0, 0]);
    g.extend_from_slice(&[0x2C, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0]);
    g.extend_from_slice(&[2, 1, 0x44, 0, 0x3B]);
    assert_eq!(g.len(), 28);
    let run = hostile("28-byte GIF", move || decode(&g));
    assert_eq!(run.value, Err(ImageError::TooLarge));
    assert!(run.peak < 1 << 20, "held {} KB", run.peak >> 10);
}

#[test]
fn a_gif_cut_off_inside_its_graphic_control_block() {
    // The file ends right after a graphic control extension's size byte:
    // its flags were read past the end.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[2, 0, 2, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 255]);
    g.extend_from_slice(&[0x21, 0xF9, 4]);
    let run = hostile("truncated GIF", move || decode(&g));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
}

#[test]
fn a_gif_screen_without_its_frame() {
    // A 5,000 x 4,800 screen whose frame is cut off: 96 MB was set aside
    // for the screen before the frame was read.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[0x88, 0x13, 0xC0, 0x12, 0x80, 0, 0, 255, 0, 0, 0, 0, 255]);
    g.extend_from_slice(&[0x2C, 0, 0, 0, 0, 0x88, 0x13, 0xC0, 0x12, 0, 2, 200, 1, 2]);
    let run = hostile("GIF without its frame", move || decode(&g));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
    assert!(run.peak < 1 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn decoders_refuse_other_kinds() {
    // Bytes of another kind handed to a decoder were read as its own.
    let png = png(2, 2, 8, 0, 0, &zlib(&[0; 6]));
    let mut gif = b"XIF89a".to_vec();
    gif.extend_from_slice(&[0xFF, 0xFF, 0x80, 0x01, 0, 0, 0, 0x3B]);
    for b in [png.clone(), gif] {
        let run = hostile("not a GIF", move || doc_image::decode_gif(&b));
        assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
        assert!(run.peak < 1 << 20, "held {} MB", run.peak >> 20);
    }
    let run = hostile("not a BMP", move || doc_image::decode_bmp(&png));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
}

#[test]
fn gif_frames_off_the_screen_are_clipped() {
    // A 4x4 frame at (2, 2) on a 3x3 screen: only its corner shows.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[3, 0, 3, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 255]);
    g.extend_from_slice(&[0x2C, 2, 0, 2, 0, 4, 0, 4, 0, 0]);
    // LZW, minimum code 2: clear, then sixteen 1s as single codes (the
    // table fills as it goes), end.
    let mut codes = vec![(4u32, 3u32)];
    let mut size = 3;
    let mut next = 6;
    for _ in 0..16 {
        codes.push((1, size));
        next += 1;
        if next == 1 << size && size < 12 {
            size += 1;
        }
    }
    codes.push((5, size));
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
    g.extend_from_slice(&[0, 0x3B]);
    let run = hostile("clipped GIF frame", move || decode(&g));
    let r = run.value.unwrap();
    assert_eq!((r.width, r.height), (3, 3));
    assert_eq!(&r.pixels[24..27], &[0, 0, 255]);
    assert_eq!(r.alpha.unwrap(), vec![0, 0, 0, 0, 0, 0, 0, 0, 255]);
}

/// LZW codes packed as a GIF frame's data sub-blocks: `codes` are
/// (code, width) pairs, least significant bit first.
fn gif_blocks(codes: &[(u32, u32)]) -> Vec<u8> {
    let (mut acc, mut n, mut bytes) = (0u64, 0, Vec::new());
    for &(c, width) in codes {
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
    let mut out = Vec::new();
    for b in bytes.chunks(255) {
        out.push(b.len() as u8);
        out.extend_from_slice(b);
    }
    out.push(0);
    out
}

#[test]
fn a_gif_frame_whose_codes_run_past_it() {
    // A 2,000 x 2,000 frame of one colour whose codes go on past its four
    // million pixels. The string of the last code crossed the end of the
    // indexes, and growing them for it doubled them to 8 MB.
    let mut g = b"GIF89a".to_vec();
    g.extend_from_slice(&[0xD0, 0x07, 0xD0, 0x07, 0x80, 0, 0, 255, 0, 0, 0, 0, 255]);
    g.extend_from_slice(&[0x2C, 0, 0, 0, 0, 0xD0, 0x07, 0xD0, 0x07, 0, 2]);
    // Minimum code size 2: clear, 0, then each new code (the run so far
    // and one more), until the table is full; then its longest run.
    let mut codes = vec![(4u32, 3u32), (0, 3)];
    let (mut size, mut next, mut made) = (3u32, 6u32, 1u64);
    while made < 2000 * 2000 + 4096 {
        let code = next.min(4095);
        codes.push((code, size));
        made += (code - 4) as u64;
        if next < 4096 {
            next += 1;
            if next == 1 << size && size < 12 {
                size += 1;
            }
        }
    }
    g.extend(gif_blocks(&codes));
    g.push(0x3B);
    let run = hostile("GIF codes past the frame", move || decode(&g).map(|r| (r.width, r.pixels.len(), r.alpha.is_none())));
    assert_eq!(run.value, Ok((2000, 12_000_000, true)));
    // The screen's colours and alpha (16 MB), and 4 MB of indexes.
    assert!(run.peak < 21 << 20, "held {} KB", run.peak >> 10);
}

#[test]
fn pictures_past_24_million_pixels_are_refused() {
    // 5,200 x 5,000 is 26 million pixels: too large for a phone.
    let p = png(5200, 5000, 8, 0, 0, &zlib(&[0]));
    let run = hostile("26 MP PNG", move || decode(&p));
    assert_eq!(run.value, Err(ImageError::TooLarge));
    // 4,800 x 4,800 (23 million) is not refused for its size.
    let p = png(4800, 4800, 1, 0, 0, &zlib(&[0]));
    let run = hostile("23 MP PNG", move || decode(&p));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
}

#[test]
fn a_png_without_the_data_its_header_claims() {
    // A 4,000 x 4,000 RGBA header over a few bytes of data: the decoder
    // inflated, unfiltered and converted into three full-size buffers.
    let p = png(4000, 4000, 8, 6, 0, &zlib(&[0; 100]));
    let run = hostile("hollow PNG", move || decode(&p));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
    assert!(run.peak < 4 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn a_large_png_decodes_in_one_pass() {
    // 2,000 x 1,500 RGBA, every row filtered: the decoder held the
    // inflated data, the unfiltered picture, RGBA and the result at once,
    // four times what it returns.
    let (w, h) = (2000usize, 1500usize);
    let mut raw = Vec::with_capacity((w * 4 + 1) * h);
    for y in 0..h {
        raw.push((y % 5) as u8);
        raw.extend((0..w * 4).map(|i| ((i * 7 + y) % 251) as u8));
    }
    let p = png(w as u32, h as u32, 8, 6, 0, &zlib(&raw));
    drop(raw);
    let run = hostile("large PNG", move || decode(&p).map(|r| (r.width, r.pixels.len(), r.alpha.map(|a| a.len()))));
    assert_eq!(run.value, Ok((2000, w * h * 3, Some(w * h))));
    // The result is 12 MB; the decoder needs little more.
    assert!(run.peak < 16 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn bmp_bit_field_masks_of_all_ones() {
    // A 32-bit BI_BITFIELDS BMP whose masks are 0xFFFFFFFF: scaling the
    // field to 0..255 overflowed 32 bits.
    let mut b = b"BM".to_vec();
    b.extend_from_slice(&(66u32 + 4).to_le_bytes());
    b.extend_from_slice(&[0; 4]);
    b.extend_from_slice(&66u32.to_le_bytes());
    b.extend_from_slice(&40u32.to_le_bytes());
    b.extend_from_slice(&1i32.to_le_bytes());
    b.extend_from_slice(&1i32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&32u16.to_le_bytes());
    b.extend_from_slice(&3u32.to_le_bytes());
    b.extend_from_slice(&[0; 20]);
    b.extend_from_slice(&[0xFF; 12]);
    b.extend_from_slice(&[0xFF; 4]);
    let run = hostile("BMP bit fields", move || decode(&b));
    let r = run.value.unwrap();
    assert_eq!(r.pixels, vec![255, 255, 255]);
}

#[test]
fn a_bmp_header_without_its_pixels() {
    // A 4,800 x 4,800 BMP of 54 bytes: 92 MB was reserved before the
    // first missing row was noticed.
    let mut b = b"BM".to_vec();
    b.extend_from_slice(&54u32.to_le_bytes());
    b.extend_from_slice(&[0; 4]);
    b.extend_from_slice(&54u32.to_le_bytes());
    b.extend_from_slice(&40u32.to_le_bytes());
    b.extend_from_slice(&4800i32.to_le_bytes());
    b.extend_from_slice(&4800i32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&24u16.to_le_bytes());
    b.extend_from_slice(&[0; 24]);
    let run = hostile("hollow BMP", move || decode(&b));
    assert!(matches!(run.value, Err(ImageError::Corrupt(_))), "{:?}", run.value);
    assert!(run.peak < 1 << 20, "held {} KB", run.peak >> 10);
}
