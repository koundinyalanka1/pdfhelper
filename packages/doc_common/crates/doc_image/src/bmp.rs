//! BMP decoding: uncompressed 1, 4, 8, 24 and 32-bit pictures, and
//! bit-field 16/32-bit ones.

use crate::{check_size, le16, le32, ImageError, Raster};

fn corrupt(m: &str) -> ImageError {
    ImageError::Corrupt(m.into())
}

pub fn decode(b: &[u8]) -> Result<Raster, ImageError> {
    let data_at = le32(b, 10).ok_or_else(|| corrupt("header"))? as usize;
    let header = le32(b, 14).ok_or_else(|| corrupt("header"))? as usize;
    let w = le32(b, 18).ok_or_else(|| corrupt("header"))? as i32;
    let h = le32(b, 22).ok_or_else(|| corrupt("header"))? as i32;
    let bpp = le16(b, 28).ok_or_else(|| corrupt("header"))?;
    let compression = if header >= 40 { le32(b, 30).unwrap_or(0) } else { 0 };
    let top_down = h < 0;
    let (w, h) = (w.unsigned_abs(), h.unsigned_abs());
    check_size(w, h)?;
    if !matches!(compression, 0 | 3) {
        return Err(ImageError::Unsupported("compressed BMP".into()));
    }
    let colors_used = if header >= 40 { le32(b, 46).unwrap_or(0) } else { 0 };
    let mut palette = Vec::new();
    if bpp <= 8 {
        let n = if colors_used == 0 { 1usize << bpp } else { colors_used as usize };
        let at = 14 + header;
        for k in 0..n {
            let o = at + k * 4;
            let c = b.get(o..o + 3).ok_or_else(|| corrupt("palette"))?;
            palette.push([c[2], c[1], c[0]]);
        }
    }
    let masks = if compression == 3 {
        let at = if header >= 52 { 54 } else { 14 + header };
        [le32(b, at).unwrap_or(0), le32(b, at + 4).unwrap_or(0), le32(b, at + 8).unwrap_or(0), if header >= 56 { le32(b, 66).unwrap_or(0) } else { 0 }]
    } else if bpp == 16 {
        [0x7C00, 0x03E0, 0x001F, 0]
    } else {
        [0x00FF_0000, 0x0000_FF00, 0x0000_00FF, if bpp == 32 { 0xFF00_0000 } else { 0 }]
    };
    let channel = |v: u32, m: u32| -> u8 {
        if m == 0 {
            return 255;
        }
        let shift = m.trailing_zeros();
        let max = m >> shift;
        (((v & m) >> shift) * 255 / max.max(1)) as u8
    };
    let stride = ((w as usize * bpp as usize).div_ceil(32)) * 4;
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    let mut any_alpha = false;
    for y in 0..h as usize {
        let src_row = if top_down { y } else { h as usize - 1 - y };
        let row = b.get(data_at + src_row * stride..data_at + (src_row + 1) * stride).ok_or_else(|| corrupt("pixels"))?;
        for x in 0..w as usize {
            let o = (y * w as usize + x) * 4;
            let px = match bpp {
                1 | 4 | 8 => {
                    let per = 8 / bpp as usize;
                    let byte = row[x / per];
                    let shift = 8 - bpp as usize * (x % per + 1);
                    let idx = (byte >> shift) & ((1u16 << bpp) - 1) as u8;
                    let c = palette.get(idx as usize).copied().unwrap_or([0, 0, 0]);
                    [c[0], c[1], c[2], 255]
                }
                24 => [row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255],
                16 => {
                    let v = u16::from_le_bytes([row[x * 2], row[x * 2 + 1]]) as u32;
                    [channel(v, masks[0]), channel(v, masks[1]), channel(v, masks[2]), 255]
                }
                32 => {
                    let v = u32::from_le_bytes([row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]]);
                    let a = if masks[3] != 0 { channel(v, masks[3]) } else { 255 };
                    if a != 0 {
                        any_alpha = true;
                    }
                    [channel(v, masks[0]), channel(v, masks[1]), channel(v, masks[2]), a]
                }
                _ => return Err(ImageError::Unsupported(format!("{bpp}-bit BMP"))),
            };
            rgba[o..o + 4].copy_from_slice(&px);
        }
    }
    // Many 32-bit BMPs leave alpha at zero meaning "unused".
    if bpp == 32 && !any_alpha {
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
    }
    Ok(crate::split_alpha(w, h, rgba))
}
