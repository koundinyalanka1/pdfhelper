//! PNG decoding: every colour type and bit depth, interlaced or not.

use std::io::Read;

use crate::{be32, check_size, ImageError, Raster, MAX_PIXELS};

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
        let data = b.get(i + 8..i + 8 + len).ok_or_else(|| corrupt("truncated chunk"))?;
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
    // Decompressed size: rows with their filter bytes (more for Adam7).
    let row_bytes = |width: u32| (width as usize * bits).div_ceil(8);
    let limit = (row_bytes(w) + 1) * h as usize * 2 + 1024;
    if limit as u64 > MAX_PIXELS * 8 {
        return Err(ImageError::TooLarge);
    }
    let mut raw = Vec::new();
    flate2::read::ZlibDecoder::new(&idat[..]).take(limit as u64).read_to_end(&mut raw).map_err(|_| corrupt("compressed data"))?;

    // Unfiltered samples for the whole picture, row by row.
    let stride = row_bytes(w);
    let mut img = vec![0u8; stride * h as usize];
    let passes: Vec<(u32, u32, u32, u32)> = if interlace == 1 {
        vec![(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    } else {
        vec![(0, 0, 1, 1)]
    };
    let mut pos = 0;
    for (x0, y0, dx, dy) in passes {
        if x0 >= w || y0 >= h {
            continue;
        }
        let pw = (w - x0).div_ceil(dx);
        let ph = (h - y0).div_ceil(dy);
        let rb = row_bytes(pw);
        let mut prev = vec![0u8; rb];
        for r in 0..ph {
            let filter = *raw.get(pos).ok_or_else(|| corrupt("short data"))?;
            let line = raw.get(pos + 1..pos + 1 + rb).ok_or_else(|| corrupt("short data"))?;
            pos += 1 + rb;
            let mut cur = line.to_vec();
            unfilter(filter, &mut cur, &prev, bpp)?;
            // Scatter the pass's pixels into the picture.
            let y = (y0 + r * dy) as usize;
            if dx == 1 {
                img[y * stride..y * stride + rb].copy_from_slice(&cur);
            } else {
                for k in 0..pw as usize {
                    let x = x0 as usize + k * dx as usize;
                    copy_pixel(&cur, k, &mut img[y * stride..(y + 1) * stride], x, bits);
                }
            }
            prev = cur;
        }
    }

    // Samples to 8-bit gray/RGB and alpha.
    let n = (w * h) as usize;
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
    let mut rgba = Vec::with_capacity(n * 4);
    let mut gray_out = ctype == 0 || ctype == 4;
    for y in 0..h as usize {
        let row = &img[y * stride..(y + 1) * stride];
        for x in 0..w as usize {
            match ctype {
                0 => {
                    let v = sample(row, x);
                    let key = (trns.len() >= 2).then(|| u16::from_be_bytes([trns[0], trns[1]]));
                    let g = to8(v);
                    rgba.extend_from_slice(&[g, g, g, if key == Some(v) { 0 } else { 255 }]);
                }
                2 => {
                    let (r, g, bb) = (sample(row, x * 3), sample(row, x * 3 + 1), sample(row, x * 3 + 2));
                    let key = (trns.len() >= 6).then(|| (u16::from_be_bytes([trns[0], trns[1]]), u16::from_be_bytes([trns[2], trns[3]]), u16::from_be_bytes([trns[4], trns[5]])));
                    let a = if key == Some((r, g, bb)) { 0 } else { 255 };
                    rgba.extend_from_slice(&[to8(r), to8(g), to8(bb), a]);
                }
                3 => {
                    let idx = sample(row, x) as usize;
                    let c = palette.get(idx).copied().unwrap_or([0, 0, 0]);
                    let a = trns.get(idx).copied().unwrap_or(255);
                    rgba.extend_from_slice(&[c[0], c[1], c[2], a]);
                }
                4 => {
                    let g = to8(sample(row, x * 2));
                    rgba.extend_from_slice(&[g, g, g, to8(sample(row, x * 2 + 1))]);
                }
                _ => {
                    rgba.extend_from_slice(&[to8(sample(row, x * 4)), to8(sample(row, x * 4 + 1)), to8(sample(row, x * 4 + 2)), to8(sample(row, x * 4 + 3))]);
                }
            }
        }
    }
    if ctype == 3 && palette.iter().all(|c| c[0] == c[1] && c[1] == c[2]) {
        gray_out = true;
    }
    let mut r = crate::split_alpha(w, h, rgba);
    if gray_out {
        r.pixels = r.pixels.chunks_exact(3).map(|c| c[0]).collect();
        r.channels = 1;
    }
    Ok(r)
}

fn copy_pixel(src: &[u8], si: usize, dst: &mut [u8], di: usize, bits: usize) {
    if bits >= 8 {
        let n = bits / 8;
        dst[di * n..di * n + n].copy_from_slice(&src[si * n..si * n + n]);
        return;
    }
    let per = 8 / bits;
    let mask = ((1u16 << bits) - 1) as u8;
    let v = (src[si / per] >> (8 - bits * (si % per + 1))) & mask;
    let shift = 8 - bits * (di % per + 1);
    dst[di / per] = (dst[di / per] & !(mask << shift)) | (v << shift);
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
