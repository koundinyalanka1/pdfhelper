//! Paragraph layout for exports and page views.
//!
//! [`layout`] sets a paragraph of styled spans into lines of a width: each
//! character gets a face (the requested family, its substitute, or a
//! fallback that has the character), lines break at spaces, hyphens and
//! between ideographs (or inside a word too long for a line), tabs go to
//! their stops, a list label hangs before the text, and lines are aligned
//! and spaced. [`draw`] paints the result into a PDF page.
//!
//! Simple text is set a character at a time with kerning. Runs of complex
//! scripts (Indic, Arabic, Thai, combining marks) are shaped with the
//! font's OpenType tables into clusters that lines never split; right-to-
//! left text is put in display order line by line (a simplified Unicode
//! bidirectional algorithm: no explicit embeddings).

use std::sync::Arc;

use doc_font::{FaceId, Font, FontBook};
use doc_pdf::{Glyph, Page, Pdf, Stroke};

/// How a run of text looks.
#[derive(Clone, Debug, PartialEq)]
pub struct Style {
    pub family: String,
    /// Points.
    pub size: f32,
    pub bold: bool,
    pub italic: bool,
    /// `0xAARRGGBB`.
    pub color: u32,
    pub underline: bool,
    pub strike: bool,
    /// Percent of the size up (superscript) or down (negative).
    pub baseline: i32,
    pub highlight: Option<u32>,
    pub link: Option<String>,
    /// Extra space after each character, points.
    pub spacing: f32,
    /// Raised (positive) or lowered text, points, at its own size.
    pub rise: f32,
}

impl Default for Style {
    fn default() -> Self {
        Style {
            family: String::new(),
            size: 11.0,
            bold: false,
            italic: false,
            color: 0xFF00_0000,
            underline: false,
            strike: false,
            baseline: 0,
            highlight: None,
            link: None,
            spacing: 0.0,
            rise: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    pub text: String,
    pub style: Style,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Align {
    Left,
    Center,
    Right,
    Justify,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LineSpacing {
    /// A multiple of the natural line height.
    Multiple(f32),
    /// Exactly this many points.
    Exact(f32),
    /// At least this many points.
    AtLeast(f32),
}

/// What a single line's height is measured from.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LineMetric {
    /// The fonts' ascent, descent and line gap (Word, Writer).
    Font,
    /// This multiple of the largest size (PowerPoint's 1.2).
    Em(f32),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Paragraph {
    pub spans: Vec<Span>,
    pub align: Align,
    /// Indents of the text from the box's edges, points.
    pub left: f32,
    pub right: f32,
    /// The first line's offset from `left` (negative to hang).
    pub first: f32,
    pub spacing: LineSpacing,
    pub metric: LineMetric,
    /// A list label set at `left + first`; text follows at `left` (or after
    /// the label when it is wider).
    pub label: Option<Span>,
    /// Tab stops from the box's left edge, points.
    pub tabs: Vec<f32>,
    pub default_tab: f32,
    /// The style of an empty paragraph's mark (its height).
    pub mark: Style,
    /// Right-to-left: the base direction for ordering mixed text.
    pub rtl: bool,
}

impl Default for Paragraph {
    fn default() -> Self {
        Paragraph {
            spans: Vec::new(),
            align: Align::Left,
            left: 0.0,
            right: 0.0,
            first: 0.0,
            spacing: LineSpacing::Multiple(1.0),
            metric: LineMetric::Font,
            label: None,
            tabs: Vec::new(),
            default_tab: 36.0,
            mark: Style::default(),
            rtl: false,
        }
    }
}

/// A glyph placed in a run.
#[derive(Clone, Debug, PartialEq)]
pub struct PlacedGlyph {
    pub gid: u16,
    /// From the run's start, points.
    pub x: f32,
    /// Below the baseline (negative above), points: marks set by the font.
    pub y: f32,
    pub text: String,
}

/// Glyphs of one face and style on a line.
#[derive(Clone, Debug)]
pub struct GlyphRun {
    pub face: FaceId,
    pub font: Arc<Font>,
    pub size: f32,
    pub style: Style,
    /// From the line's left edge (the box's), points.
    pub x: f32,
    pub width: f32,
    pub glyphs: Vec<PlacedGlyph>,
    pub synthetic_bold: bool,
    pub synthetic_italic: bool,
    /// Up is negative, points.
    pub shift: f32,
}

#[derive(Clone, Debug)]
pub struct Line {
    /// Top of the line from the paragraph's top, points.
    pub y: f32,
    pub height: f32,
    /// Baseline from the line's top.
    pub baseline: f32,
    pub runs: Vec<GlyphRun>,
    /// Where the text starts and ends.
    pub left: f32,
    pub right: f32,
}

#[derive(Clone, Debug, Default)]
pub struct Laid {
    pub lines: Vec<Line>,
    pub height: f32,
}

/// The tallest faces on a line.
#[derive(Default, Clone, Copy)]
struct Metrics {
    asc: f32,
    desc: f32,
    gap: f32,
    max_size: f32,
}

impl Metrics {
    fn add(&mut self, f: &Font, size: f32) {
        let u = f.units_per_em as f32;
        self.asc = self.asc.max(f.ascent as f32 / u * size);
        self.desc = self.desc.max(-(f.descent as f32) / u * size);
        self.gap = self.gap.max(f.line_gap as f32 / u * size);
        self.max_size = self.max_size.max(size);
    }
}

/// Bidirectional classes, simplified.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Bidi {
    L,
    R,
    /// Digits.
    En,
    /// Spaces, punctuation and symbols.
    N,
}

fn bidi_class(c: char) -> Bidi {
    if doc_font::is_rtl(c) {
        Bidi::R
    } else if c.is_ascii_digit() || matches!(c, '\u{0660}'..='\u{0669}' | '\u{06F0}'..='\u{06F9}') {
        Bidi::En
    } else if c.is_alphabetic() {
        Bidi::L
    } else {
        Bidi::N
    }
}

/// A character's mirror image, for brackets in right-to-left text.
fn mirror(c: char) -> Option<char> {
    Some(match c {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        '\u{00AB}' => '\u{00BB}',
        '\u{00BB}' => '\u{00AB}',
        '\u{2039}' => '\u{203A}',
        '\u{203A}' => '\u{2039}',
        _ => return None,
    })
}

/// A cluster: characters drawn as a unit, with its face and width.
#[derive(Clone, Debug)]
struct Item {
    /// The first character.
    ch: char,
    span: usize,
    face: Option<FaceId>,
    /// Glyph, offset (x right, y down, points) and the text it stands for.
    glyphs: Vec<(u16, f32, f32, String)>,
    advance: f32,
    /// A line may break after this cluster.
    break_after: bool,
    space: bool,
    tab: bool,
    newline: bool,
    bidi: Bidi,
}

fn is_ideograph(c: char) -> bool {
    matches!(c as u32, 0x2E80..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0xFF00..=0xFFEF | 0x20000..=0x2FFFF)
}

struct Faces<'a> {
    book: &'a mut FontBook,
}

impl Faces<'_> {
    fn face_for(&mut self, style: &Style, ch: char) -> Option<(FaceId, Arc<Font>)> {
        let primary = self.book.resolve(&style.family, style.bold, style.italic);
        if let Some(id) = primary {
            if let Some(f) = self.book.font(id) {
                if f.has(ch) || ch.is_whitespace() || ch.is_control() {
                    return Some((id, f));
                }
            }
        }
        if let Some(id) = self.book.fallback(ch, style.bold) {
            if let Some(f) = self.book.font(id) {
                return Some((id, f));
            }
        }
        let id = primary?;
        self.book.font(id).map(|f| (id, f))
    }
}

fn effective_size(s: &Style) -> f32 {
    if s.baseline != 0 {
        s.size * 0.66
    } else {
        s.size
    }
}

/// Per-character items of the spans, with faces and advances; complex
/// scripts shaped into clusters.
fn items(faces: &mut Faces, spans: &[Span]) -> Vec<Item> {
    let mut out: Vec<Item> = Vec::new();
    let is_newline = |c: char| matches!(c, '\n' | '\u{2028}' | '\u{000B}' | '\r');
    let is_space = |c: char| c == ' ' || c == '\u{00A0}' || c == '\u{3000}';
    let breaks = |ch: char, next: Option<char>| {
        (is_space(ch) && ch != '\u{00A0}')
            || ch == '\t'
            || (ch == '-' && next.is_some_and(|n| n.is_alphanumeric()))
            || ch == '\u{200B}'
            || is_ideograph(ch)
            || next.is_some_and(is_ideograph)
    };
    for (si, span) in spans.iter().enumerate() {
        let size = effective_size(&span.style);
        let chars: Vec<char> = span.text.chars().collect();
        let after = spans.get(si + 1).and_then(|s| s.text.chars().next());
        // Each character's face; marks and signs stay with the character
        // they belong to.
        let mut fc: Vec<Option<(FaceId, Arc<Font>)>> = Vec::with_capacity(chars.len());
        for (k, &ch) in chars.iter().enumerate() {
            let special = is_newline(ch) || ch == '\t';
            let keep = if k > 0 && !special && doc_font::joins_previous(ch) {
                fc[k - 1].as_ref().filter(|(_, f)| f.has(ch) || matches!(ch, '\u{200C}' | '\u{200D}')).cloned()
            } else {
                None
            };
            let f = keep.or_else(|| faces.face_for(&span.style, if special { ' ' } else { ch }));
            fc.push(f);
        }
        let mut prev: Option<(FaceId, u16)> = None;
        let mut k = 0;
        while k < chars.len() {
            // A segment: characters of one face, or one tab or line break.
            let id = fc[k].as_ref().map(|f| f.0);
            let mut e = k + 1;
            if !(is_newline(chars[k]) || chars[k] == '\t') && id.is_some() {
                while e < chars.len() && !(is_newline(chars[e]) || chars[e] == '\t') && fc[e].as_ref().map(|f| f.0) == id {
                    e += 1;
                }
            }
            if let (Some((fid, font)), true) = (fc[k].clone(), chars[k..e].iter().any(|c| doc_font::needs_shaping(*c))) {
                let scale = size / font.units_per_em as f32;
                for c in font.shape(&chars[k..e]) {
                    let (a, b) = (k + c.start, k + c.end);
                    if a >= b {
                        continue;
                    }
                    let glyphs = c
                        .glyphs
                        .iter()
                        .map(|g| (g.gid, g.x as f32 * scale, -(g.y as f32) * scale, chars[k + g.text.start..k + g.text.end].iter().collect::<String>()))
                        .collect();
                    let ch = chars[a];
                    let space = b - a == 1 && is_space(ch);
                    let advance = c.advance as f32 * scale + span.style.spacing;
                    out.push(Item {
                        ch,
                        span: si,
                        face: Some(fid),
                        glyphs,
                        advance: if ch == '\u{00A0}' { advance } else { advance.max(0.0) },
                        break_after: breaks(chars[b - 1], chars.get(b).copied().or(after)),
                        space,
                        tab: false,
                        newline: false,
                        bidi: bidi_class(ch),
                    });
                }
                prev = None;
                k = e;
                continue;
            }
            for kk in k..e {
                let ch = chars[kk];
                let newline = is_newline(ch);
                let tab = ch == '\t';
                let space = is_space(ch);
                let (face, gid, mut advance) = match fc[kk].clone() {
                    Some((id, f)) => {
                        let g = f.glyph(if newline || tab { ' ' } else { ch }).unwrap_or(0);
                        let mut a = f.advance(g) as f32 / f.units_per_em as f32 * size;
                        if let Some((pid, pg)) = prev {
                            if pid == id {
                                let kern = f.kern(pg, g) as f32 / f.units_per_em as f32 * size;
                                if let Some(last) = out.last_mut() {
                                    last.advance += kern;
                                }
                            }
                        }
                        prev = Some((id, g));
                        if newline || tab {
                            a = 0.0;
                        }
                        (Some(id), g, a)
                    }
                    None => (None, 0, size * 0.5),
                };
                advance += span.style.spacing;
                let next = chars.get(kk + 1).copied().or(after);
                let glyphs = if newline || tab || ch.is_control() { Vec::new() } else { vec![(gid, 0.0, 0.0, ch.to_string())] };
                out.push(Item {
                    ch,
                    span: si,
                    face,
                    glyphs,
                    advance: if ch == '\u{00A0}' { advance } else { advance.max(0.0) },
                    break_after: breaks(ch, next),
                    space,
                    tab,
                    newline,
                    bidi: bidi_class(ch),
                });
            }
            k = e;
        }
    }
    out
}

/// The display order of a line's items (indices into `all`) and each
/// one's embedding level, odd for right-to-left.
fn reorder(all: &[Item], idx: &[usize], rtl: bool) -> (Vec<usize>, Vec<u8>) {
    let base: u8 = rtl as u8;
    let n = idx.len();
    if !rtl && idx.iter().all(|&i| all[i].bidi != Bidi::R) {
        return (idx.to_vec(), vec![0; n]);
    }
    // Digits after left-to-right text are left-to-right.
    let mut t: Vec<Bidi> = idx.iter().map(|&i| all[i].bidi).collect();
    let mut strong = if rtl { Bidi::R } else { Bidi::L };
    for c in t.iter_mut() {
        match *c {
            Bidi::L | Bidi::R => strong = *c,
            Bidi::En if strong == Bidi::L => *c = Bidi::L,
            _ => {}
        }
    }
    // Neutrals between text of one direction take it; else the base's.
    let dir = |b: Bidi| if b == Bidi::L { Bidi::L } else { Bidi::R };
    let base_dir = if rtl { Bidi::R } else { Bidi::L };
    let mut k = 0;
    while k < n {
        if t[k] != Bidi::N {
            k += 1;
            continue;
        }
        let mut e = k;
        while e < n && t[e] == Bidi::N {
            e += 1;
        }
        let before = if k == 0 { base_dir } else { dir(t[k - 1]) };
        let after = if e == n { base_dir } else { dir(t[e]) };
        let r = if before == after { before } else { base_dir };
        for c in &mut t[k..e] {
            *c = r;
        }
        k = e;
    }
    let levels: Vec<u8> = t
        .iter()
        .map(|c| match (c, base) {
            (Bidi::L, 0) => 0,
            (Bidi::L, _) => 2,
            (Bidi::R, _) => 1,
            _ => 2,
        })
        .collect();
    let mut order: Vec<usize> = (0..n).collect();
    let max = levels.iter().copied().max().unwrap_or(0);
    for lvl in (1..=max).rev() {
        let mut k = 0;
        while k < n {
            if levels[order[k]] < lvl {
                k += 1;
                continue;
            }
            let mut e = k;
            while e < n && levels[order[e]] >= lvl {
                e += 1;
            }
            order[k..e].reverse();
            k = e;
        }
    }
    (order.iter().map(|&k| idx[k]).collect(), order.iter().map(|&k| levels[k]).collect())
}

/// Set a paragraph into lines `width` points wide.
pub fn layout(book: &mut FontBook, p: &Paragraph, width: f32) -> Laid {
    let mut faces = Faces { book };
    let all = items(&mut faces, &p.spans);
    // The label: its own items, set before the first line.
    let label_items = p.label.as_ref().map(|l| items(&mut faces, std::slice::from_ref(l)));
    let label_width: f32 = label_items.as_ref().map_or(0.0, |l| l.iter().map(|i| i.advance).sum());

    // Split into lines: (start, end) item ranges.
    let mut lines: Vec<(usize, usize, bool)> = Vec::new();
    let mut start = 0;
    let mut first = true;
    let first_text_x = |lw: f32| -> f32 {
        if p.label.is_some() {
            let label_x = p.left + p.first;
            let end = label_x + lw;
            if end + 0.5 <= p.left {
                p.left
            } else {
                // The next tab stop after the label.
                let mut x = end + 1.0;
                let dt = p.default_tab.max(1.0);
                x = (x / dt).ceil() * dt;
                x.max(end + 2.0)
            }
        } else {
            p.left + p.first
        }
    };
    let text_x0 = first_text_x(label_width);
    while start < all.len() || (start == 0 && all.is_empty()) {
        if all.is_empty() {
            lines.push((0, 0, true));
            break;
        }
        let x0 = if first { text_x0 } else { p.left };
        let avail = (width - p.right - x0).max(1.0);
        let mut x = 0.0f32;
        let mut last_break: Option<usize> = None;
        let mut end = start;
        let mut forced = false;
        while end < all.len() {
            let it = &all[end];
            if it.newline {
                end += 1;
                forced = true;
                break;
            }
            let w = if it.tab {
                let abs = x0 + x;
                let stop = p.tabs.iter().copied().find(|t| *t > abs + 0.5).unwrap_or_else(|| {
                    let dt = p.default_tab.max(1.0);
                    ((abs + 0.5) / dt).ceil() * dt
                });
                (stop - abs).max(0.0)
            } else {
                it.advance
            };
            if x + w > avail && !it.space && end > start {
                // Break at the last opportunity, else inside the word.
                match last_break {
                    Some(b) => end = b + 1,
                    None => {}
                }
                break;
            }
            x += w;
            if it.break_after {
                last_break = Some(end);
            }
            end += 1;
        }
        if end == start {
            end = start + 1;
        }
        lines.push((start, end, forced || end >= all.len()));
        start = end;
        first = false;
        // A paragraph ending in a line break gets an empty last line.
        if forced && start >= all.len() {
            lines.push((start, start, true));
            break;
        }
    }

    let mut out = Laid::default();
    let mut y = 0.0f32;
    for (li, &(s, e, last)) in lines.iter().enumerate() {
        let x0 = if li == 0 { text_x0 } else { p.left };
        let mut runs: Vec<GlyphRun> = Vec::new();
        // Metrics of the faces on the line (or of the paragraph mark).
        let mut m = Metrics::default();
        let mut x = x0;
        let place = |runs: &mut Vec<GlyphRun>, faces: &mut Faces, it: &Item, style: &Style, x: f32, w: f32, mirrored: bool| {
            let Some(face) = it.face else { return };
            let Some(font) = faces.book.font(face) else { return };
            let size = effective_size(style);
            let shift = -(style.baseline as f32 / 100.0) * style.size - style.rise;
            let continues = runs.last().is_some_and(|r| r.face == face && r.style == *style && (r.x + r.width - x).abs() < 0.01);
            // Brackets in right-to-left text face the other way.
            let swapped = if mirrored && it.glyphs.len() == 1 { mirror(it.ch).and_then(|m| font.glyph(m)) } else { None };
            if !continues {
                runs.push(GlyphRun {
                    face,
                    synthetic_bold: style.bold && !font.bold(),
                    synthetic_italic: style.italic && !font.italic,
                    font,
                    size,
                    style: style.clone(),
                    x,
                    width: 0.0,
                    glyphs: Vec::new(),
                    shift,
                });
            }
            let r = runs.last_mut().unwrap();
            for (gid, dx, dy, text) in &it.glyphs {
                r.glyphs.push(PlacedGlyph { gid: swapped.unwrap_or(*gid), x: x - r.x + dx, y: *dy, text: text.clone() });
            }
            r.width = x + w - r.x;
        };
        if li == 0 {
            if let (Some(l), Some(label)) = (&label_items, &p.label) {
                let mut lx = p.left + p.first;
                for it in l {
                    if let Some(f) = it.face.and_then(|id| faces.book.font(id)) {
                        m.add(&f, effective_size(&label.style));
                    }
                    place(&mut runs, &mut faces, it, &label.style, lx, it.advance, false);
                    lx += it.advance;
                }
            }
        }
        // Trailing spaces hang past the edge.
        let mut content_end = e;
        while content_end > s && (all[content_end - 1].space || all[content_end - 1].newline) {
            content_end -= 1;
        }
        // Display order: right-to-left text reversed; trailing spaces
        // hang after the text whatever its direction.
        let content: Vec<usize> = (s..content_end).collect();
        let (mut order, mut levels) = reorder(&all, &content, p.rtl);
        order.extend(content_end..e);
        levels.resize(order.len(), 0);
        let mut positions = vec![(0.0f32, 0.0f32); e - s];
        let mut used_end = x0;
        for &i in &order {
            let it = &all[i];
            let w = if it.tab {
                let stop = p.tabs.iter().copied().find(|t| *t > x + 0.5).unwrap_or_else(|| {
                    let dt = p.default_tab.max(1.0);
                    ((x + 0.5) / dt).ceil() * dt
                });
                (stop - x).max(0.0)
            } else {
                it.advance
            };
            positions[i - s] = (x, w);
            x += w;
            if i < content_end {
                used_end = x;
            }
        }
        let used = used_end - x0;
        let avail = width - p.right - x0;
        let extra = (avail - used).max(0.0);
        let (shift, per_space) = match p.align {
            Align::Center => (extra / 2.0, 0.0),
            Align::Right => (extra, 0.0),
            Align::Justify if !last => {
                let spaces = all[s..content_end].iter().filter(|i| i.space).count();
                if spaces > 0 {
                    (0.0, extra / spaces as f32)
                } else {
                    (0.0, 0.0)
                }
            }
            _ => (0.0, 0.0),
        };
        let mut added = 0.0;
        for (&i, &level) in order.iter().zip(&levels) {
            let it = &all[i];
            let style = &p.spans[it.span].style;
            if let Some(f) = it.face.and_then(|id| faces.book.font(id)) {
                m.add(&f, effective_size(style));
            }
            let (px, w) = positions[i - s];
            let inner = it.space && i < content_end;
            let w = if inner { w + per_space } else { w };
            place(&mut runs, &mut faces, it, style, px + shift + added, w, level % 2 == 1);
            if inner {
                added += per_space;
            }
        }
        if m.max_size == 0.0 {
            // An empty line: the paragraph mark's font.
            let mut probe = Faces { book: faces.book };
            if let Some((_, f)) = probe.face_for(&p.mark, 'x') {
                m.add(&f, effective_size(&p.mark));
            }
            if m.max_size == 0.0 {
                let s = p.mark.size;
                m.asc = s * 0.8;
                m.desc = s * 0.2;
                m.max_size = s;
            }
        }
        let Metrics { asc, desc, gap, max_size } = m;
        let natural = match p.metric {
            LineMetric::Font => asc + desc + gap,
            LineMetric::Em(k) => k * max_size,
        };
        let height = match p.spacing {
            LineSpacing::Multiple(m) => natural * m,
            LineSpacing::Exact(h) => h,
            LineSpacing::AtLeast(h) => natural.max(h),
        };
        let text_h = match p.metric {
            LineMetric::Font => asc + desc + gap,
            LineMetric::Em(k) => k * max_size,
        };
        // Word sets extra height above the text; PowerPoint shares the line
        // between ascent and descent.
        let baseline = match p.metric {
            LineMetric::Font if height >= text_h => height - desc - gap,
            LineMetric::Font => asc * height / text_h.max(0.01),
            LineMetric::Em(_) => height * asc / (asc + desc).max(0.01),
        };
        out.lines.push(Line {
            y,
            height,
            baseline: baseline.max(0.0),
            runs,
            left: x0 + shift,
            right: x0 + shift + used + added,
        });
        y += height;
    }
    out.height = y;
    out
}

/// Width of the widest line's text, points (for shrinking boxes).
pub fn max_line_width(l: &Laid) -> f32 {
    l.lines.iter().map(|ln| ln.right - ln.left).fold(0.0, f32::max)
}

/// Paint laid-out lines with the paragraph's top-left at (x, y).
pub fn draw(page: &mut Page, pdf: &mut Pdf, laid: &Laid, x: f32, y: f32) {
    for line in &laid.lines {
        let base = y + line.y + line.baseline;
        for run in &line.runs {
            let rx = x + run.x;
            if let Some(h) = run.style.highlight {
                let u = run.font.units_per_em as f32;
                let top = base + run.shift - run.font.ascent as f32 / u * run.size;
                let bottom = base + run.shift - run.font.descent as f32 / u * run.size;
                page.rect(rx, top, run.width, bottom - top);
                page.fill(h, false);
            }
        }
        for run in &line.runs {
            let rx = x + run.x;
            let fr = pdf.font(run.font.clone());
            let glyphs: Vec<Glyph> = run.glyphs.iter().map(|g| Glyph { gid: g.gid, x: g.x, y: g.y, text: g.text.clone() }).collect();
            page.text(pdf, fr, run.size, run.style.color, rx, base + run.shift, &glyphs, run.synthetic_bold, run.synthetic_italic);
            let thick = (run.size / 18.0).max(0.5);
            if run.style.underline {
                let uy = base + run.shift + run.size * 0.12;
                page.move_to(rx, uy);
                page.line_to(rx + run.width, uy);
                page.stroke(&Stroke { width: thick, color: run.style.color, dash: Vec::new(), cap: doc_pdf::Cap::Butt, round_join: false });
            }
            if run.style.strike {
                let sy = base + run.shift - run.size * 0.28;
                page.move_to(rx, sy);
                page.line_to(rx + run.width, sy);
                page.stroke(&Stroke { width: thick, color: run.style.color, dash: Vec::new(), cap: doc_pdf::Cap::Butt, round_join: false });
            }
            if let Some(uri) = &run.style.link {
                page.link(rx, y + line.y, run.width, line.height, uri);
            }
        }
    }
}

#[cfg(test)]
mod tests;
