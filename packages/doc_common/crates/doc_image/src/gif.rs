//! GIF decoding: the first frame, with its transparency, clipped to the
//! screen.

use crate::{buffer, check_size, le16, raster, ImageError, Raster};

fn corrupt(m: &str) -> ImageError {
    ImageError::Corrupt(m.into())
}

/// The first frame: where it sits on the screen, its colours and its
/// compressed indexes.
struct Frame {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    interlaced: bool,
    palette: Vec<[u8; 3]>,
    min_code: u8,
    data: Vec<u8>,
}

pub fn decode(b: &[u8]) -> Result<Raster, ImageError> {
    if !b.starts_with(b"GIF87a") && !b.starts_with(b"GIF89a") {
        return Err(corrupt("not a GIF"));
    }
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
    // The first frame is read before memory is set aside for the screen,
    // so a damaged file costs nothing.
    let mut transparent: Option<u8> = None;
    let frame = loop {
        match *b.get(i).ok_or_else(|| corrupt("end"))? {
            0x21 => {
                let label = *b.get(i + 1).ok_or_else(|| corrupt("extension"))?;
                i += 2;
                if label == 0xF9 && b.get(i) == Some(&4) && b.get(i + 1).is_some_and(|f| f & 1 != 0) {
                    transparent = b.get(i + 4).copied();
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
                let x = le16(b, i + 1).ok_or_else(|| corrupt("frame"))?;
                let y = le16(b, i + 3).ok_or_else(|| corrupt("frame"))?;
                let fw = le16(b, i + 5).ok_or_else(|| corrupt("frame"))?;
                let fh = le16(b, i + 7).ok_or_else(|| corrupt("frame"))?;
                let fflags = *b.get(i + 9).ok_or_else(|| corrupt("frame"))?;
                i += 10;
                // A frame is a picture too: one past the budget is refused
                // even on a small screen.
                if fw > 0 && fh > 0 {
                    check_size(fw, fh)?;
                }
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
                // Only the first frame of an animation.
                break Some(Frame { x, y, w: fw, h: fh, interlaced: fflags & 0x40 != 0, palette, min_code, data });
            }
            _ => break None,
        }
    };
    let n = w as usize * h as usize;
    let mut rgb = buffer(n * 3, 0)?;
    let mut alpha = buffer(n, 0)?;
    if let Some(f) = frame {
        let rows: Vec<u32> = if f.interlaced {
            let mut r = Vec::new();
            for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
                let mut y = start;
                while y < f.h {
                    r.push(y);
                    y += step;
                }
            }
            r
        } else {
            (0..f.h).collect()
        };
        // Indexes up to the last row on the screen; the rest are never
        // drawn.
        let shown = rows.iter().rposition(|&r| f.y + r < h).map_or(0, |k| k + 1);
        let idx = lzw(&f.data, f.min_code, shown * f.w as usize)?;
        // Only the part of the frame on the screen is drawn.
        let across = f.w.min(w.saturating_sub(f.x));
        for (k, &row) in rows.iter().enumerate() {
            let py = f.y + row;
            if py >= h {
                continue;
            }
            for x in 0..across {
                let Some(&c) = idx.get(k * f.w as usize + x as usize) else { continue };
                if Some(c) == transparent {
                    continue;
                }
                let o = py as usize * w as usize + (f.x + x) as usize;
                let col = f.palette.get(c as usize).copied().unwrap_or([0, 0, 0]);
                rgb[o * 3..o * 3 + 3].copy_from_slice(&col);
                alpha[o] = 255;
            }
        }
    }
    Ok(raster(w, h, 3, rgb, alpha))
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
    let mut out = Vec::new();
    out.try_reserve_exact(max).map_err(|_| ImageError::TooLarge)?;
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
        // No further than `max`: a string crossing it would grow the
        // indexes to twice their size.
        out.extend(stack.iter().rev().take(max - out.len()));
        if first.is_some() && out.len() < max {
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
