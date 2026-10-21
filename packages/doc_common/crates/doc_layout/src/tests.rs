use std::path::Path;

use super::*;

fn book() -> Option<FontBook> {
    if !Path::new("/usr/share/fonts/truetype/crosextra/Carlito-Regular.ttf").exists() {
        return None;
    }
    let mut b = FontBook::new();
    b.add_dir(Path::new("/usr/share/fonts/truetype"));
    Some(b)
}

fn style(size: f32) -> Style {
    Style { family: "Calibri".into(), size, ..Style::default() }
}

fn text_of(line: &Line) -> String {
    line.runs.iter().flat_map(|r| r.glyphs.iter().map(|g| g.text.clone())).collect()
}

#[test]
fn breaks_lines_at_spaces_and_aligns() {
    let Some(mut b) = book() else { return };
    let p = Paragraph {
        spans: vec![Span { text: "The quick brown fox jumps over the lazy dog".into(), style: style(11.0) }],
        ..Paragraph::default()
    };
    let l = layout(&mut b, &p, 100.0);
    assert!(l.lines.len() >= 2, "{}", l.lines.len());
    for line in &l.lines {
        assert!(line.right - line.left <= 100.0 + 0.01);
    }
    let all: Vec<String> = l.lines.iter().map(text_of).collect();
    assert_eq!(all.join(""), "The quick brown fox jumps over the lazy dog");
    assert!(all[0].ends_with(' '), "{all:?}");
    // Calibri at 11pt: lines 1.22 em apart.
    assert!((l.lines[0].height - 13.4).abs() < 0.3, "{}", l.lines[0].height);

    let centred = layout(&mut b, &Paragraph { align: Align::Center, ..p.clone() }, 400.0);
    assert_eq!(centred.lines.len(), 1);
    let line = &centred.lines[0];
    assert!((line.left - (400.0 - line.right)).abs() < 0.5, "{} {}", line.left, line.right);

    let just = layout(&mut b, &Paragraph { align: Align::Justify, ..p.clone() }, 100.0);
    let first = &just.lines[0];
    assert!((first.right - 100.0).abs() < 0.5, "{}", first.right);
}

#[test]
fn labels_tabs_breaks_and_spacing() {
    let Some(mut b) = book() else { return };
    let p = Paragraph {
        spans: vec![Span { text: "Item\tone\u{2028}two".into(), style: style(12.0) }],
        left: 36.0,
        first: -18.0,
        label: Some(Span { text: "\u{2022}".into(), style: style(12.0) }),
        spacing: LineSpacing::Exact(20.0),
        ..Paragraph::default()
    };
    let l = layout(&mut b, &p, 300.0);
    assert_eq!(l.lines.len(), 2);
    assert_eq!(l.height, 40.0);
    // The label sits at 18pt, the text at 36pt, the tab goes to 72pt.
    let runs = &l.lines[0].runs;
    assert!((runs[0].x - 18.0).abs() < 0.01);
    assert!((runs[1].x - 36.0).abs() < 0.01, "{}", runs[1].x);
    let one = runs.iter().find(|r| r.glyphs.iter().any(|g| g.text == "o")).unwrap();
    let o = one.glyphs.iter().find(|g| g.text == "o").unwrap();
    assert!((one.x + o.x - 72.0).abs() < 0.01, "{}", one.x + o.x);
    assert_eq!(text_of(&l.lines[1]), "two");

    // An empty paragraph still has a line's height.
    let empty = layout(&mut b, &Paragraph { mark: style(20.0), ..Paragraph::default() }, 100.0);
    assert_eq!(empty.lines.len(), 1);
    assert!(empty.height > 20.0);
}

#[test]
fn falls_back_for_missing_characters_and_draws() {
    let Some(mut b) = book() else { return };
    let p = Paragraph {
        spans: vec![
            Span { text: "Price \u{20B9}100 \u{2192} ".into(), style: style(14.0) },
            Span { text: "bold".into(), style: Style { bold: true, underline: true, ..style(14.0) } },
        ],
        ..Paragraph::default()
    };
    let l = layout(&mut b, &p, 400.0);
    let faces: std::collections::HashSet<_> = l.lines[0].runs.iter().map(|r| r.face).collect();
    assert!(!faces.is_empty());
    for r in &l.lines[0].runs {
        for g in &r.glyphs {
            if g.text != " " {
                assert!(g.gid != 0 || !r.font.has(g.text.chars().next().unwrap()), "{} missing", g.text);
            }
        }
    }
    let mut pdf = Pdf::new();
    let mut page = pdf.page(500.0, 200.0);
    draw(&mut page, &mut pdf, &l, 20.0, 20.0);
    pdf.add_page(page);
    let bytes = pdf.finish();
    assert!(bytes.len() > 1000);
}

/// A book of one font file, when it is installed.
fn book_of(paths: &[&str]) -> Option<FontBook> {
    let p = paths.iter().find(|p| Path::new(p).exists())?;
    let mut b = FontBook::new();
    b.add_file(Path::new(p));
    Some(b)
}

const INDIC: &[&str] = &["C:/Windows/Fonts/Nirmala.ttc", "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf", "/system/fonts/NotoSansDevanagari-Regular.otf"];
const ARABIC: &[&str] = &["C:/Windows/Fonts/arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/system/fonts/NotoNaskhArabic-Regular.ttf"];

#[test]
fn shapes_indic_words_and_never_splits_a_syllable() {
    let Some(mut b) = book_of(INDIC) else { return };
    // "namaste" twice: syllables, a conjunct and a reordered matra.
    let text = "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} \u{0915}\u{093F}\u{0924}\u{093E}\u{092C} \u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}";
    let p = Paragraph { spans: vec![Span { text: text.into(), style: Style { family: String::new(), ..style(14.0) } }], ..Paragraph::default() };
    let wide = layout(&mut b, &p, 1000.0);
    assert_eq!(wide.lines.len(), 1);
    let glyphs: Vec<&PlacedGlyph> = wide.lines[0].runs.iter().flat_map(|r| r.glyphs.iter()).collect();
    // Fewer glyphs than characters: the conjunct is one glyph.
    assert!(glyphs.len() < text.chars().count(), "{}", glyphs.len());
    // The I matra is drawn before Ka.
    let font = b.font(wide.lines[0].runs[0].face).unwrap();
    let ka = font.glyph('\u{0915}').unwrap();
    let ka_at = glyphs.iter().position(|g| g.gid == ka).unwrap();
    assert_eq!(glyphs[ka_at - 1].text, "\u{093F}");
    // Every character is still there for copying.
    let mut all: Vec<char> = glyphs.iter().flat_map(|g| g.text.chars()).collect();
    let mut want: Vec<char> = text.chars().filter(|c| *c != ' ').collect();
    all.retain(|c| *c != ' ');
    all.sort_unstable();
    want.sort_unstable();
    assert_eq!(all, want);
    // A narrow box breaks between words, not inside them.
    let narrow = layout(&mut b, &p, 60.0);
    assert!(narrow.lines.len() >= 2);
    for line in &narrow.lines {
        let t: String = line.runs.iter().flat_map(|r| r.glyphs.iter().map(|g| g.text.clone())).collect();
        assert!(!t.trim().starts_with('\u{094D}') && !t.trim().starts_with('\u{0947}'), "{t:?}");
    }
    // It draws.
    let mut pdf = Pdf::new();
    let mut page = pdf.page(300.0, 100.0);
    draw(&mut page, &mut pdf, &wide, 10.0, 10.0);
    pdf.add_page(page);
    assert!(pdf.finish().len() > 1000);
}

#[test]
fn orders_right_to_left_text_for_display() {
    let Some(mut b) = book_of(ARABIC) else { return };
    // "Salam" then a number and Latin: Arabic reads right to left.
    let text = "\u{0633}\u{0644}\u{0627}\u{0645} 42 abc";
    let p = Paragraph { spans: vec![Span { text: text.into(), style: style(14.0) }], ..Paragraph::default() };
    let l = layout(&mut b, &p, 1000.0);
    let glyphs: Vec<(f32, String)> = l.lines[0].runs.iter().flat_map(|run| run.glyphs.iter().map(move |g| (run.x + g.x, g.text.clone()))).collect();
    let x_of = |s: &str| glyphs.iter().find(|g| g.1.contains(s)).map(|g| g.0).unwrap();
    // In a left-to-right paragraph the Arabic word and the number after it
    // read right to left as one piece (the number's digits left to right),
    // then the Latin follows.
    assert!(x_of("4") < x_of("2"));
    assert!(x_of("2") < x_of("\u{0645}"));
    assert!(x_of("\u{0645}") < x_of("\u{0633}"));
    assert!(x_of("\u{0633}") < x_of("a"));
    // Right-to-left: the Latin comes first (on the left), the Arabic last.
    let r = layout(&mut b, &Paragraph { rtl: true, ..p.clone() }, 1000.0);
    let rg: Vec<(f32, String)> = r.lines[0].runs.iter().flat_map(|run| run.glyphs.iter().map(move |g| (run.x + g.x, g.text.clone()))).collect();
    let rx = |s: &str| rg.iter().find(|g| g.1.contains(s)).map(|g| g.0).unwrap();
    assert!(rx("a") < rx("4"));
    assert!(rx("4") < rx("2"));
    assert!(rx("2") < rx("\u{0645}"));
    assert!(rx("\u{0645}") < rx("\u{0633}"));
}
