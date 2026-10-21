//! Pictures in documents: what kind a picture is, its size, and its pixels
//! for the formats a PDF cannot take as they are (PNG, GIF, BMP). JPEG
//! stays compressed: only its header is read, for passthrough.

mod bmp;
mod encode;
mod gif;
mod png;

pub use encode::encode_png;

pub use bmp::decode as decode_bmp;
pub use gif::decode as decode_gif;
pub use png::decode as decode_png;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ImageError {
    #[error("this picture is damaged: {0}")]
    Corrupt(String),
    #[error("this kind of picture is not supported: {0}")]
    Unsupported(String),
    #[error("this picture is too large")]
    TooLarge,
}

/// Pictures larger than this many pixels are refused: a phone's budget
/// for one picture (a 24-megapixel photo fits).
pub const MAX_PIXELS: u64 = 24 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Png,
    Jpeg,
    Gif,
    Bmp,
    Webp,
    Tiff,
    Emf,
    Wmf,
    Svg,
    Unknown,
}

/// What kind of picture `bytes` hold, by their signature.
pub fn kind(bytes: &[u8]) -> Kind {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Kind::Png
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Kind::Jpeg
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Kind::Gif
    } else if bytes.starts_with(b"BM") && bytes.len() > 26 {
        Kind::Bmp
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Kind::Webp
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Kind::Tiff
    } else if bytes.len() > 44 && bytes[..4] == [1, 0, 0, 0] && &bytes[40..44] == b" EMF" {
        Kind::Emf
    } else if bytes.starts_with(&[0xD7, 0xCD, 0xC6, 0x9A]) || bytes.starts_with(&[1, 0, 9, 0]) || bytes.starts_with(&[2, 0, 9, 0]) {
        Kind::Wmf
    } else {
        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).to_ascii_lowercase();
        if head.contains("<svg") {
            Kind::Svg
        } else {
            Kind::Unknown
        }
    }
}

fn be16(b: &[u8], i: usize) -> Option<u32> {
    Some(u16::from_be_bytes([*b.get(i)?, *b.get(i + 1)?]) as u32)
}

fn le16(b: &[u8], i: usize) -> Option<u32> {
    Some(u16::from_le_bytes([*b.get(i)?, *b.get(i + 1)?]) as u32)
}

fn le32(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes([*b.get(i)?, *b.get(i + 1)?, *b.get(i + 2)?, *b.get(i + 3)?]))
}

fn be32(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_be_bytes([*b.get(i)?, *b.get(i + 1)?, *b.get(i + 2)?, *b.get(i + 3)?]))
}

/// A JPEG's header: what a PDF `DCTDecode` image needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JpegInfo {
    pub width: u32,
    pub height: u32,
    /// 1 (gray), 3 (YCbCr/RGB) or 4 (CMYK/YCCK).
    pub components: u8,
    /// Adobe CMYK JPEGs store inverted values.
    pub adobe: bool,
}

pub fn jpeg_info(b: &[u8]) -> Option<JpegInfo> {
    if !b.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut i = 2;
    let mut adobe = false;
    while i + 4 <= b.len() {
        if b[i] != 0xFF {
            i += 1;
            continue;
        }
        let marker = b[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        if marker == 0xD8 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            i += 2;
            continue;
        }
        let len = be16(b, i + 2)? as usize;
        if marker == 0xEE && b.get(i + 4..i + 9) == Some(b"Adobe") {
            adobe = true;
        }
        // Start of frame (not DHT, JPG, DAC).
        if (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            let height = be16(b, i + 5)?;
            let width = be16(b, i + 7)?;
            let components = *b.get(i + 9)?;
            return Some(JpegInfo { width, height, components, adobe });
        }
        if marker == 0xD9 || marker == 0xDA {
            return None;
        }
        i += 2 + len;
    }
    None
}

/// A picture's size in pixels, from its header.
pub fn size(b: &[u8]) -> Option<(u32, u32)> {
    match kind(b) {
        Kind::Png => Some((be32(b, 16)?, be32(b, 20)?)),
        Kind::Jpeg => jpeg_info(b).map(|j| (j.width, j.height)),
        Kind::Gif => Some((le16(b, 6)?, le16(b, 8)?)),
        Kind::Bmp => {
            let w = le32(b, 18)? as i32;
            let h = le32(b, 22)? as i32;
            Some((w.unsigned_abs(), h.unsigned_abs()))
        }
        Kind::Webp => {
            let chunk = b.get(12..16)?;
            match chunk {
                b"VP8 " => Some((le16(b, 26)? & 0x3FFF, le16(b, 28)? & 0x3FFF)),
                b"VP8L" => {
                    let v = le32(b, 21)?;
                    Some(((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1))
                }
                b"VP8X" => {
                    let w = (*b.get(24)? as u32) | (*b.get(25)? as u32) << 8 | (*b.get(26)? as u32) << 16;
                    let h = (*b.get(27)? as u32) | (*b.get(28)? as u32) << 8 | (*b.get(29)? as u32) << 16;
                    Some((w + 1, h + 1))
                }
                _ => None,
            }
        }
        _ => None,
    }
}

/// Decoded pixels: gray or RGB, 8 bits a channel, with a separate alpha
/// plane when the picture has transparency.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Raster {
    pub width: u32,
    pub height: u32,
    /// 1 (gray) or 3 (RGB).
    pub channels: u8,
    pub pixels: Vec<u8>,
    pub alpha: Option<Vec<u8>>,
}

/// Decode a PNG, GIF or BMP.
pub fn decode(b: &[u8]) -> Result<Raster, ImageError> {
    match kind(b) {
        Kind::Png => png::decode(b),
        Kind::Gif => gif::decode(b),
        Kind::Bmp => bmp::decode(b),
        k => Err(ImageError::Unsupported(format!("{k:?}"))),
    }
}

fn check_size(w: u32, h: u32) -> Result<(), ImageError> {
    if w == 0 || h == 0 {
        return Err(ImageError::Corrupt("empty picture".into()));
    }
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err(ImageError::TooLarge);
    }
    Ok(())
}

/// `n` bytes of `fill`, or TooLarge when the memory is not there.
fn buffer(n: usize, fill: u8) -> Result<Vec<u8>, ImageError> {
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| ImageError::TooLarge)?;
    v.resize(n, fill);
    Ok(v)
}

/// A raster from its samples and an alpha plane, which is dropped when it
/// is all opaque.
fn raster(w: u32, h: u32, channels: u8, pixels: Vec<u8>, alpha: Vec<u8>) -> Raster {
    let opaque = alpha.iter().all(|v| *v == 255);
    Raster { width: w, height: h, channels, pixels, alpha: if opaque { None } else { Some(alpha) } }
}

#[cfg(test)]
mod tests;
