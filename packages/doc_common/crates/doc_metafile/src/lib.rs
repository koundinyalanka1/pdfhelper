//! Windows metafiles (WMF and EMF), the vector pictures inside old (and
//! many new) Office documents, drawn into pixels: shapes, lines, curves,
//! paths, text (through the fonts' outlines) and bitmaps, with the
//! mapping modes, world transforms and saved states GDI has.
//!
//! The engines turn a metafile into a PNG when the app shows a picture
//! and when they save as PDF; the file itself keeps the metafile.
//!
//! Every count in a metafile comes from its bytes, so each is cut to the
//! record holding it, and each render has a [`Budget`] of points, edges,
//! dashes and painting: a hostile picture ends early with what it drew
//! instead of exhausting the phone.

pub mod emf;
pub mod gdi;
pub mod raster;
pub mod wmf;

use doc_font::FontBook;

use gdi::{Gdi, Mapping};

pub use raster::Budget;

/// What kind of metafile bytes are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Wmf,
    Emf,
}

pub fn kind(b: &[u8]) -> Option<Kind> {
    if emf::header(b).is_some() {
        return Some(Kind::Emf);
    }
    if wmf::placeable(b).is_some() {
        return Some(Kind::Wmf);
    }
    // A WMF without the placeable header: type 1 or 2, header of 9 words.
    let u16_at = |i: usize| b.get(i..i + 2).map_or(0, |s| u16::from_le_bytes([s[0], s[1]]));
    if matches!(u16_at(0), 1 | 2) && u16_at(2) == 9 && matches!(u16_at(4), 0x0100 | 0x0300) {
        return Some(Kind::Wmf);
    }
    None
}

/// The picture's frame: (left, top, width, height) in its own units, and
/// its size in points.
fn frame(b: &[u8]) -> Option<((f64, f64, f64, f64), (f64, f64))> {
    match kind(b)? {
        Kind::Emf => {
            let h = emf::header(b)?;
            let (l, t, r, bt) = h.frame;
            let (w, hh) = ((r - l).abs(), (bt - t).abs());
            if w < 1.0 || hh < 1.0 {
                return None;
            }
            Some(((l, t, w, hh), (w / 100.0 / 25.4 * 72.0, hh / 100.0 / 25.4 * 72.0)))
        }
        Kind::Wmf => {
            if let Some(((l, t, r, bt), inch)) = wmf::placeable(b) {
                let (w, h) = ((r - l).abs(), (bt - t).abs());
                if w >= 1.0 && h >= 1.0 {
                    return Some(((l, t, w, h), (w / inch * 72.0, h / inch * 72.0)));
                }
            }
            let (l, t, r, bt) = wmf::window(b)?;
            let (w, h) = ((r - l).abs(), (bt - t).abs());
            if w < 1.0 || h < 1.0 {
                return None;
            }
            // Without a header, take twips.
            Some(((l, t, w, h), (w / 20.0, h / 20.0)))
        }
    }
}

/// The picture's natural size in points.
pub fn size(b: &[u8]) -> Option<(f32, f32)> {
    frame(b).map(|(_, s)| (s.0 as f32, s.1 as f32))
}

/// The canvas for a frame of `fw` x `fh` drawn with its longer side
/// `max_px` (16 to 4096) pixels.
fn canvas(fw: f64, fh: f64, max_px: u32) -> (f64, f64) {
    let max = max_px.clamp(16, 4096) as f64;
    if fw >= fh {
        (max, (max * fh / fw).round().max(1.0))
    } else {
        ((max * fw / fh).round().max(1.0), max)
    }
}

/// Draw a metafile into RGBA pixels whose longer side is `max_px`;
/// `fonts` draws its text (none: text is left out). None when the bytes
/// are not a metafile or nothing could be drawn. Drawing stops at the
/// canvas's [`Budget::for_canvas`].
pub fn render(b: &[u8], max_px: u32, fonts: Option<&mut FontBook>) -> Option<(u32, u32, Vec<u8>)> {
    let ((_, _, fw, fh), _) = frame(b)?;
    let (w, h) = canvas(fw, fh, max_px);
    render_within(b, max_px, fonts, &mut Budget::for_canvas(w as usize, h as usize))
}

/// [`render`] within `budget`, leaving what is left of it there: a
/// spent budget means the picture was cut short.
pub fn render_within(b: &[u8], max_px: u32, fonts: Option<&mut FontBook>, budget: &mut Budget) -> Option<(u32, u32, Vec<u8>)> {
    let ((l, t, fw, fh), _) = frame(b)?;
    let (w, h) = canvas(fw, fh, max_px);
    let (wu, hu) = (w as usize, h as usize);
    let mut g = match kind(b)? {
        Kind::Wmf => Gdi::new(wu, hu, Mapping::Window { w, h }, fonts),
        Kind::Emf => {
            let hd = emf::header(b)?;
            let ppm = (hd.device.0 / hd.mm.0, hd.device.1 / hd.mm.1);
            // The frame in device pixels, onto the canvas.
            let origin = (l / 100.0 * ppm.0, t / 100.0 * ppm.1);
            let scale = (w / (fw / 100.0 * ppm.0), h / (fh / 100.0 * ppm.1));
            Gdi::new(wu, hu, Mapping::Device { origin, scale, px_per_mm: ppm }, fonts)
        }
    };
    g.canvas.budget = *budget;
    match kind(b)? {
        Kind::Wmf => {
            if wmf::placeable(b).is_none() {
                if let Some((l, t, r, bt)) = wmf::window(b) {
                    g.dc.win_org = (l, t);
                    g.dc.win_ext = (r - l, bt - t);
                }
            }
            wmf::play(b, &mut g)
        }
        Kind::Emf => emf::play(b, &mut g),
    }
    *budget = g.canvas.budget;
    if !g.drawn {
        return None;
    }
    Some((wu as u32, hu as u32, g.canvas.rgba()))
}

/// Where systems keep their fonts (Android, Linux, macOS).
const SYSTEM_FONTS: [&str; 4] = ["/system/fonts", "/usr/share/fonts", "/System/Library/Fonts", "/Library/Fonts"];

/// A picture as the app can show it: a metafile drawn as a PNG with the
/// system's fonts; None for anything else (shown as it is).
pub fn shown(bytes: &[u8]) -> Option<Vec<u8>> {
    kind(bytes)?;
    let mut book = FontBook::shared().lock().unwrap_or_else(|e| e.into_inner());
    for dir in SYSTEM_FONTS {
        book.add_dir(std::path::Path::new(dir));
    }
    to_png(bytes, 1200, Some(&mut book))
}

/// [`render`] as a PNG.
pub fn to_png(b: &[u8], max_px: u32, fonts: Option<&mut FontBook>) -> Option<Vec<u8>> {
    let (w, h, rgba) = render(b, max_px, fonts)?;
    Some(doc_image::encode_png(w, h, &rgba))
}

#[cfg(test)]
mod tests;
