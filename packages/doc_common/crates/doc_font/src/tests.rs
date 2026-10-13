//! Tests on fonts installed on the machine; they skip when one is missing.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Arc;

use super::*;

fn load(path: &str) -> Option<Font> {
    let data = std::fs::read(path).ok()?;
    Font::parse(Arc::new(data), 0).ok()
}

const CARLITO: &str = "/usr/share/fonts/truetype/crosextra/Carlito-Regular.ttf";
const LIB_SERIF_BOLD: &str = "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf";

#[test]
fn reads_metrics_cmap_widths_and_kerning() {
    let Some(f) = load(CARLITO) else { return };
    assert_eq!(f.family, "Carlito");
    assert!(!f.is_cff);
    assert!(f.units_per_em >= 1000);
    let a = f.glyph('A').unwrap();
    let v = f.glyph('V').unwrap();
    assert!(f.advance(a) > 0);
    assert!(f.glyph('\u{E000}').is_none());
    // Carlito kerns "AV" (Calibri does too).
    assert!(f.kern(a, v) < 0, "AV kerning {}", f.kern(a, v));
    // Calibri's metrics: 11pt "Hello" is about 23.4pt wide.
    let w = f.text_width("Hello", 11.0);
    assert!((w - 23.4).abs() < 1.0, "{w}");
    // Office's single line for Calibri is 1.22 em.
    let line = (f.ascent - f.descent + f.line_gap) as f32 / f.units_per_em as f32;
    assert!((line - 1.22).abs() < 0.02, "{line}");
}

#[test]
fn subsets_keep_used_glyphs() {
    let Some(f) = load(LIB_SERIF_BOLD) else { return };
    let used: BTreeSet<u16> = "Hello".chars().filter_map(|c| f.glyph(c)).collect();
    let sub = f.subset(&used).unwrap();
    assert!(sub.len() < f.data().len() / 4, "{} of {}", sub.len(), f.data().len());
    let back = Font::parse(Arc::new(sub), 0).unwrap();
    assert_eq!(back.num_glyphs, f.num_glyphs);
    let h = f.glyph('H').unwrap();
    assert_eq!(back.advance(h), f.advance(h));
    let glyf = back.table(b"glyf").unwrap();
    assert!(!glyf.is_empty());
}

#[test]
fn book_resolves_office_fonts_and_falls_back() {
    if !Path::new(CARLITO).exists() {
        return;
    }
    let mut book = FontBook::new();
    book.add_dir(Path::new("/usr/share/fonts/truetype"));
    let calibri = book.resolve("Calibri", false, false).unwrap();
    assert_eq!(book.faces()[calibri].family, "Carlito");
    let times = book.resolve("Times New Roman", true, false).unwrap();
    assert_eq!(book.faces()[times].family, "Liberation Serif");
    assert!(book.faces()[times].weight >= 700);
    let courier = book.resolve("Courier New", false, true).unwrap();
    assert!(book.faces()[courier].italic);
    // Something for a face to fall back to: Greek, then CJK when a CJK
    // font is installed.
    let greek = book.fallback('\u{03A9}', false).unwrap();
    assert!(book.font(greek).unwrap().has('\u{03A9}'));
    if let Some(cjk) = book.fallback('\u{4E2D}', false) {
        assert!(book.font(cjk).unwrap().has('\u{4E2D}'));
    }
}
