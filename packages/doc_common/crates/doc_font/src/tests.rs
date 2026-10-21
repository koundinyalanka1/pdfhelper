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

/// An upright regular face, from the first of `paths` that has `ch`.
fn face_with(paths: &[&str], ch: char) -> Option<Font> {
    for p in paths {
        let Ok(data) = std::fs::read(p) else { continue };
        let data = Arc::new(data);
        for i in 0..face_count(&data) {
            if let Ok(f) = Font::parse(data.clone(), i) {
                if f.has(ch) && !f.italic && f.weight < 600 {
                    return Some(f);
                }
            }
        }
    }
    None
}

const INDIC: &[&str] = &[
    "C:/Windows/Fonts/Nirmala.ttc",
    "C:/Windows/Fonts/Nirmala.ttf",
    "/system/fonts/NotoSansDevanagari-Regular.otf",
    "/system/fonts/NotoSansTelugu-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansTelugu-Regular.ttf",
    "/usr/share/fonts/truetype/lohit-devanagari/Lohit-Devanagari.ttf",
    "/usr/share/fonts/truetype/lohit-telugu/Lohit-Telugu.ttf",
];

const ARABIC: &[&str] = &[
    "C:/Windows/Fonts/arial.ttf",
    "/system/fonts/NotoNaskhArabic-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
];

fn chars(s: &str) -> Vec<char> {
    s.chars().collect()
}

#[test]
fn shapes_devanagari_syllables() {
    let Some(f) = face_with(INDIC, '\u{0915}') else { return };
    let ka = f.glyph('\u{0915}').unwrap();
    // Ka + vowel sign I: one cluster, the sign drawn before the consonant.
    let c = f.shape(&chars("\u{0915}\u{093F}"));
    assert_eq!(c.len(), 1, "{c:?}");
    let g = &c[0].glyphs;
    assert_eq!(g.len(), 2, "{g:?}");
    assert_eq!(g[0].text, 1..2, "{g:?}");
    assert_eq!(g[1].gid, ka);
    assert!(g[0].x < g[1].x, "{g:?}");
    // Ka + virama + Ssa: one conjunct glyph.
    let c = f.shape(&chars("\u{0915}\u{094D}\u{0937}"));
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].glyphs.len(), 1, "{c:?}");
    assert_eq!(c[0].glyphs[0].text, 0..3);
    // Ra + virama + Ka: the reph goes after the consonant.
    let c = f.shape(&chars("\u{0930}\u{094D}\u{0915}"));
    assert_eq!(c.len(), 1);
    let g = &c[0].glyphs;
    assert_eq!(g.len(), 2, "{g:?}");
    assert_eq!(g[0].gid, ka);
    assert_eq!(g[1].text, 0..2);
    // Two words: a cluster per syllable and the space.
    let c = f.shape(&chars("\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} \u{0915}"));
    assert_eq!(c.iter().map(|c| (c.start, c.end)).collect::<Vec<_>>(), vec![(0, 1), (1, 2), (2, 6), (6, 7), (7, 8)]);
}

#[test]
fn shapes_telugu_below_base_forms() {
    let Some(f) = face_with(INDIC, '\u{0C24}') else { return };
    let ta = f.glyph('\u{0C24}').unwrap();
    // Sa + virama + Ta: Sa with Ta's below-base form.
    let c = f.shape(&chars("\u{0C38}\u{0C4D}\u{0C24}"));
    assert_eq!(c.len(), 1, "{c:?}");
    let g = &c[0].glyphs;
    assert!(!g.is_empty() && g.len() <= 2, "{g:?}");
    assert!(g.iter().all(|g| g.gid != ta), "Ta kept its full form: {g:?}");
    assert!(g.iter().all(|g| g.gid != f.glyph('\u{0C4D}').unwrap_or(0)), "the virama is still shown: {g:?}");
    // Ka + vowel sign I + Ssa conjunct: two clusters.
    let c = f.shape(&chars("\u{0C15}\u{0C3F}\u{0C15}\u{0C4D}\u{0C37}"));
    assert_eq!(c.len(), 2, "{c:?}");
}

#[test]
fn shapes_arabic_joining_and_lam_alef() {
    let Some(f) = face_with(ARABIC, '\u{0633}') else { return };
    // Seen-Lam-Alef-Meem: seen takes its initial form, lam and alef join.
    let text = chars("\u{0633}\u{0644}\u{0627}\u{0645}");
    let c = f.shape(&text);
    let glyphs: Vec<u16> = c.iter().flat_map(|c| c.glyphs.iter().map(|g| g.gid)).collect();
    assert_ne!(glyphs[0], f.glyph('\u{0633}').unwrap(), "seen is not in its initial form");
    assert!(glyphs.len() <= 4, "{glyphs:?}");
    let isolated: Vec<u16> = text.iter().map(|c| f.glyph(*c).unwrap()).collect();
    assert_ne!(glyphs, isolated);
    // Every character is in a cluster, in order.
    assert_eq!(c.first().unwrap().start, 0);
    assert_eq!(c.last().unwrap().end, 4);
}

#[test]
fn keeps_marks_with_their_base() {
    let Some(f) = face_with(ARABIC, '\u{0301}') else { return };
    let c = f.shape(&chars("e\u{0301}x"));
    assert_eq!(c.len(), 2, "{c:?}");
    assert_eq!((c[0].start, c[0].end), (0, 2));
    assert_eq!(c[0].glyphs.len(), 2);
}
