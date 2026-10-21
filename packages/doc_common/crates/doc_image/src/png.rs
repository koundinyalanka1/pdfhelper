//! PNG decoding: every colour type and bit depth, interlaced or not.

use std::io::Read;

use crate::{be32, buffer, check_size, ImageError, Raster};

fn corrupt(m: &str) -> ImageError {
    ImageError::Corrupt(m.into())
}

pub fn decode(b: &[u8]) -> Result<Raster, ImageError> {
    if !b.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(corrupt("not a PNG"));
    }
    let mut i = 8;
    let (mut w, mut h, mut depth, mut ctype, mut interlace) = (0u32, 0u32, 0u8, 0u8, 0u8);
    let mut palette: Vec<[u8; 3]> = Vec::new();
    let mut trns: Vec<u8> = Vec::new();
    let mut idat = Vec::new();
    while i + 8 <= b.len() {
        let len = be32(b, i).ok_or_else(|| corrupt("chunk"))? as usize;
        let ty = &b[i + 4..i + 8];
        let data = (i + 8).checked_add(len).and_then(|end| b.get(i + 8..end)).ok_or_else(|| corrupt("truncated chunk"))?;
        match ty {
            b"IHDR" => {
                if data.len() < 13 {
                    return Err(corrupt("header"));
                }
                w = be32(data, 0).unwrap_or(0);
                h = be32(data, 4).unwrap_or(0);
                depth = data[8];
                ctype = data[9];
                interlace = data[12];
            }
            b"PLTE" => palette = data.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
            b"tRNS" => trns = data.to_vec(),
            b"IDAT" => idat.extend_from_slice(data),
            b"IEND" => break,
            _ => {}
        }
        i += 12 + len;
    }
    check_size(w, h)?;
    let channels: usize = match ctype {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        _ => return Err(ImageError::Unsupported(format!("PNG colour type {ctype}"))),
    };
    if !matches!(depth, 1 | 2 | 4 | 8 | 16) || (ctype != 0 && ctype != 3 && depth < 8) || (ctype == 3 && depth == 16) {
        return Err(corrupt("bit depth"));
    }
    let bits = channels * depth as usize;
    let bpp = bits.div_ceil(8).max(1);
    let row_bytes = |width: u32| (width as usize * bits).div_ceil(8);
    let passes: Vec<(u32, u32, u32, u32)> = if interlace == 1 {
        vec![(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    } else {
        vec![(0, 0, 1, 1)]
    };
    // Each pass's size and its filtered rows' length.
    let passes: Vec<(u32, u32, u32, u32, u32, u32)> = passes
        .into_iter()
        .filter(|&(x0, y0, _, _)| x0 < w && y0 < h)
        .map(|(x0, y0, dx, dy)| (x0, y0, dx, dy, (w - x0).div_ceil(dx), (h - y0).div_ceil(dy)))
        .collect();
    // Deflate packs at most 1,032 bytes into one: data much shorter than
    // the rows it claims cannot hold them, and no memory is set aside.
    let raw_len: u64 = passes.iter().map(|p| (row_bytes(p.4) as u64 + 1) * p.5 as u64).sum();
    if raw_len > (idat.len() as u64).saturating_mul(1100) + 1024 {
        return Err(corrupt("short data"));
    }

    // Each row is inflated, unfiltered and turned into 8-bit gray or RGB
    // and alpha straight away, into the picture.
    let gray = ctype == 0 || ctype == 4 || (ctype == 3 && palette.iter().all(|c| c[0] == c[1] && c[1] == c[2]));
    let out_channels = if gray { 1 } else { 3 };
    let n = w as usize * h as usize;
    let mut pixels = buffer(n * out_channels, 0)?;
    let mut alpha = buffer(n, 255)?;
    let sample = |row: &[u8], idx: usize| -> u16 {
        match depth {
            16 => u16::from_be_bytes([row[idx * 2], row[idx * 2 + 1]]),
            8 => row[idx] as u16,
            d => {
                let per = 8 / d as usize;
                let byte = row[idx / per];
                let shift = 8 - d as usize * (idx % per + 1);
                ((byte >> shift) & ((1u16 << d) - 1) as u8) as u16
            }
        }
    };
    let to8 = |v: u16| -> u8 {
        match depth {
            16 => (v >> 8) as u8,
            8 => v as u8,
            d => ((v as u32 * 255) / ((1u32 << d) - 1)) as u8,
        }
    };
    let gray_key = (trns.len() >= 2).then(|| u16::from_be_bytes([trns[0], trns[1]]));
    let rgb_key = (trns.len() >= 6).then(|| (u16::from_be_bytes([trns[0], trns[1]]), u16::from_be_bytes([trns[2], trns[3]]), u16::from_be_bytes([trns[4], trns[5]])));
    // Pixel `k` of an unfiltered row into pixel `o` of the picture.
    let mut put = |row: &[u8], k: usize, o: usize| {
        let (c, a) = match ctype {
            0 => {
                let v = sample(row, k);
                let g = to8(v);
                ([g, g, g], if gray_key == Some(v) { 0 } else { 255 })
            }
            2 => {
                let (r, g, bb) = (sample(row, k * 3), sample(row, k * 3 + 1), sample(row, k * 3 + 2));
                ([to8(r), to8(g), to8(bb)], if rgb_key == Some((r, g, bb)) { 0 } else { 255 })
            }
            3 => {
                let idx = sample(row, k) as usize;
                (palette.get(idx).copied().unwrap_or([0, 0, 0]), trns.get(idx).copied().unwrap_or(255))
            }
            4 => {
                let g = to8(sample(row, k * 2));
                ([g, g, g], to8(sample(row, k * 2 + 1)))
            }
            _ => ([to8(sample(row, k * 4)), to8(sample(row, k * 4 + 1)), to8(sample(row, k * 4 + 2))], to8(sample(row, k * 4 + 3))),
        };
        if gray {
            pixels[o] = c[0];
        } else {
            pixels[o * 3..o * 3 + 3].copy_from_slice(&c);
        }
        alpha[o] = a;
    };
    let mut z = flate2::read::ZlibDecoder::new(&idat[..]);
    let short = |e: std::io::Error| if e.kind() == std::io::ErrorKind::UnexpectedEof { corrupt("short data") } else { corrupt("compressed data") };
    let mut cur = Vec::new();
    let mut prev = Vec::new();
    for &(x0, y0, dx, dy, pw, ph) in &passes {
        let rb = row_bytes(pw);
        cur.clear();
        cur.resize(1 + rb, 0);
        prev.clear();
        prev.resize(1 + rb, 0);
        for r in 0..ph {
            z.read_exact(&mut cur).map_err(short)?;
            unfilter(cur[0], &mut cur[1..], &prev[1..], bpp)?;
            let y = (y0 + r * dy) as usize;
            for k in 0..pw as usize {
                put(&cur[1..], k, y * w as usize + x0 as usize + k * dx as usize);
            }
            std::mem::swap(&mut cur, &mut prev);
        }
    }
    // The rest of the stream must still inflate cleanly, as far as the
    // rows' length again.
    std::io::copy(&mut z.take(raw_len + 1024), &mut std::io::sink()).map_err(short)?;
    Ok(crate::raster(w, h, out_channels as u8, pixels, alpha))
}

fn unfilter(filter: u8, cur: &mut [u8], prev: &[u8], bpp: usize) -> Result<(), ImageError> {
    match filter {
        0 => {}
        1 => {
            for i in bpp..cur.len() {
                cur[i] = cur[i].wrapping_add(cur[i - bpp]);
            }
        }
        2 => {
            for i in 0..cur.len() {
                cur[i] = cur[i].wrapping_add(prev[i]);
            }
        }
        3 => {
            for i in 0..cur.len() {
                let left = if i >= bpp { cur[i - bpp] as u16 } else { 0 };
                cur[i] = cur[i].wrapping_add(((left + prev[i] as u16) / 2) as u8);
            }
        }
        4 => {
            for i in 0..cur.len() {
                let a = if i >= bpp { cur[i - bpp] as i16 } else { 0 };
                let b = prev[i] as i16;
                let c = if i >= bpp { prev[i - bpp] as i16 } else { 0 };
                let p = a + b - c;
                let (pa, pb, pc) = ((p - a).abs(), (p - b).abs(), (p - c).abs());
                let pred = if pa <= pb && pa <= pc {
                    a
                } else if pb <= pc {
                    b
                } else {
                    c
                };
                cur[i] = cur[i].wrapping_add(pred as u8);
            }
        }
        _ => return Err(corrupt("filter")),
    }
    Ok(())
}
