//! GIF decoding: the first frame, with its transparency.

use crate::{check_size, le16, ImageError, Raster};

fn corrupt(m: &str) -> ImageError {
    ImageError::Corrupt(m.into())
}

pub fn decode(b: &[u8]) -> Result<Raster, ImageError> {
    let w = le16(b, 6).ok_or_else(|| corrupt("header"))?;
    let h = le16(b, 8).ok_or_else(|| corrupt("header"))?;
    check_size(w, h)?;
    let flags = *b.get(10).ok_or_else(|| corrupt("header"))?;
    let mut i = 13;
    let mut global: Vec<[u8; 3]> = Vec::new();
    if flags & 0x80 != 0 {
        let n = 3 << ((flags & 7) + 1);
        let t = b.get(i..i + n).ok_or_else(|| corrupt("palette"))?;
        global = t.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();
        i += n;
    }
    let mut transparent: Option<u8> = None;
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    loop {
        match *b.get(i).ok_or_else(|| corrupt("end"))? {
            0x21 => {
                let label = *b.get(i + 1).ok_or_else(|| corrupt("extension"))?;
                i += 2;
                if label == 0xF9 && b.get(i) == Some(&4) {
                    if b[i + 1] & 1 != 0 {
                        transparent = b.get(i + 4).copied();
                    }
                }
                // Skip sub-blocks.
                loop {
                    let n = *b.get(i).ok_or_else(|| corrupt("extension"))? as usize;
                    i += 1 + n;
                    if n == 0 {
                        break;
                    }
                }
            }
            0x2C => {
                let fx = le16(b, i + 1).ok_or_else(|| corrupt("frame"))?;
                let fy = le16(b, i + 3).ok_or_else(|| corrupt("frame"))?;
                let fw = le16(b, i + 5).ok_or_else(|| corrupt("frame"))?;
                let fh = le16(b, i + 7).ok_or_else(|| corrupt("frame"))?;
                let fflags = *b.get(i + 9).ok_or_else(|| corrupt("frame"))?;
                i += 10;
                let mut palette = global.clone();
                if fflags & 0x80 != 0 {
                    let n = 3 << ((fflags & 7) + 1);
                    let t = b.get(i..i + n).ok_or_else(|| corrupt("palette"))?;
                    palette = t.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();
                    i += n;
                }
                let min_code = *b.get(i).ok_or_else(|| corrupt("frame"))?;
                i += 1;
                let mut data = Vec::new();
                loop {
                    let n = *b.get(i).ok_or_else(|| corrupt("frame"))? as usize;
                    i += 1;
                    if n == 0 {
                        break;
                    }
                    data.extend_from_slice(b.get(i..i + n).ok_or_else(|| corrupt("frame"))?);
                    i += n;
                }
                let idx = lzw(&data, min_code, (fw * fh) as usize)?;
                let interlaced = fflags & 0x40 != 0;
                let rows: Vec<u32> = if interlaced {
                    let mut r = Vec::new();
                    for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
                        let mut y = start;
                        while y < fh {
                            r.push(y);
                            y += step;
                        }
                    }
                    r
                } else {
                    (0..fh).collect()
                };
                for (k, &row) in rows.iter().enumerate() {
                    for x in 0..fw {
                        let Some(&c) = idx.get(k * fw as usize + x as usize) else { continue };
                        let (px, py) = (fx + x, fy + row);
                        if px >= w || py >= h {
                            continue;
                        }
                        let o = ((py * w + px) * 4) as usize;
                        if Some(c) == transparent {
                            continue;
                        }
                        let col = palette.get(c as usize).copied().unwrap_or([0, 0, 0]);
                        rgba[o..o + 4].copy_from_slice(&[col[0], col[1], col[2], 255]);
                    }
                }
                // Only the first frame of an animation.
                break;
            }
            _ => break,
        }
    }
    Ok(crate::split_alpha(w, h, rgba))
}

fn lzw(data: &[u8], min_code: u8, max: usize) -> Result<Vec<u8>, ImageError> {
    if !(2..=11).contains(&min_code) {
        return Err(corrupt("code size"));
    }
    let clear = 1u16 << min_code;
    let end = clear + 1;
    let mut size = min_code as u32 + 1;
    let mut prefix: Vec<u16> = vec![0; 4096];
    let mut suffix: Vec<u8> = vec![0; 4096];
    let mut length: Vec<u16> = vec![0; 4096];
    for c in 0..clear {
        suffix[c as usize] = c as u8;
        length[c as usize] = 1;
    }
    let mut next = end + 1;
    let mut prev: Option<u16> = None;
    let mut out = Vec::with_capacity(max);
    let (mut acc, mut nbits, mut pos) = (0u32, 0u32, 0usize);
    let mut stack = Vec::new();
    while out.len() < max {
        while nbits < size {
            let Some(&byte) = data.get(pos) else { return Ok(out) };
            acc |= (byte as u32) << nbits;
            nbits += 8;
            pos += 1;
        }
        let code = (acc & ((1 << size) - 1)) as u16;
        acc >>= size;
        nbits -= size;
        if code == clear {
            size = min_code as u32 + 1;
            next = end + 1;
            prev = None;
            continue;
        }
        if code == end {
            break;
        }
        let Some(p) = prev else {
            if code >= clear {
                return Err(corrupt("first code"));
            }
            out.push(code as u8);
            prev = Some(code);
            continue;
        };
        let (emit, first) = if code < next {
            (code, None)
        } else if code == next {
            (p, Some(()))
        } else {
            return Err(corrupt("code"));
        };
        stack.clear();
        let mut c = emit;
        loop {
            stack.push(suffix[c as usize]);
            if length[c as usize] <= 1 {
                break;
            }
            c = prefix[c as usize];
        }
        let head = *stack.last().unwrap_or(&0);
        out.extend(stack.iter().rev());
        if first.is_some() {
            out.push(head);
        }
        if next < 4096 {
            prefix[next as usize] = p;
            suffix[next as usize] = head;
            length[next as usize] = length[p as usize] + 1;
            next += 1;
            if next == (1 << size) && size < 12 {
                size += 1;
            }
        }
        prev = Some(code);
    }
    out.truncate(max);
    Ok(out)
}
