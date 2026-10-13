//! A PDF writer for exports: pages drawn with paths, solid and gradient
//! fills, pictures and text, in points with the origin at the top left
//! (y down), like the scenes and layouts the engines produce.
//!
//! Text is set in Type 0 fonts (Identity-H) embedding a subset of each
//! TrueType face (or a CFF face whole), with a ToUnicode map so the text can
//! be searched and copied. JPEG pictures are passed through; PNG, GIF and
//! BMP are decoded and stored with Flate (alpha as a soft mask).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;
use std::io::Write as _;
use std::sync::Arc;

use doc_font::Font;

/// A colour, `0xAARRGGBB`.
pub type Argb = u32;

fn deflate(data: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    let _ = z.write_all(data);
    z.finish().unwrap_or_default()
}

/// A number as PDF writes it: short, no exponent.
fn num(v: f32) -> String {
    if !v.is_finite() {
        return "0".into();
    }
    let r = (v * 1000.0).round() / 1000.0;
    if r == r.trunc() {
        format!("{}", r as i64)
    } else {
        let s = format!("{r:.3}");
        s.trim_end_matches('0').trim_end_matches('.').to_owned()
    }
}

fn rgb(c: Argb) -> String {
    let f = |s: u32| num(((c >> s) & 0xFF) as f32 / 255.0);
    format!("{} {} {}", f(16), f(8), f(0))
}

fn alpha(c: Argb) -> u8 {
    (c >> 24) as u8
}

/// A literal string with the characters PDF needs escaped.
fn pdf_string(s: &str) -> String {
    if s.is_ascii() {
        let mut out = String::from("(");
        for ch in s.chars() {
            match ch {
                '(' | ')' | '\\' => {
                    out.push('\\');
                    out.push(ch);
                }
                '\r' => out.push_str("\\r"),
                '\n' => out.push_str("\\n"),
                c if (c as u32) < 32 => {
                    let _ = write!(out, "\\{:03o}", c as u32);
                }
                c => out.push(c),
            }
        }
        out.push(')');
        out
    } else {
        let mut out = String::from("<FEFF");
        for u in s.encode_utf16() {
            let _ = write!(out, "{u:04X}");
        }
        out.push('>');
        out
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FontRef(usize);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageRef {
    id: usize,
    pub width: u32,
    pub height: u32,
}

struct FontEntry {
    font: Arc<Font>,
    /// Glyphs used and the text each stands for.
    used: BTreeMap<u16, String>,
    obj: usize,
}

/// A gradient fill.
#[derive(Clone, Debug, PartialEq)]
pub enum Gradient {
    /// From (x0, y0) to (x1, y1).
    Linear { from: (f32, f32), to: (f32, f32), stops: Vec<(f32, Argb)> },
    /// Circles around a centre, out to a radius.
    Radial { center: (f32, f32), radius: f32, stops: Vec<(f32, Argb)> },
}

/// Line caps and joins as PDF numbers them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Cap {
    #[default]
    Butt = 0,
    Round = 1,
    Square = 2,
}

/// How a stroke looks.
#[derive(Clone, Debug, PartialEq)]
pub struct Stroke {
    pub width: f32,
    pub color: Argb,
    /// Dash lengths (on, off, ...), points; empty for solid.
    pub dash: Vec<f32>,
    pub cap: Cap,
    pub round_join: bool,
}

/// One glyph to set: its id, where it starts (points from the run's x) and
/// the text it stands for (empty for the later glyphs of a cluster).
#[derive(Clone, Debug, PartialEq)]
pub struct Glyph {
    pub gid: u16,
    pub x: f32,
    pub text: String,
}

/// A page being drawn; give it to [`Pdf::add_page`] when done.
pub struct Page {
    pub width: f32,
    pub height: f32,
    ops: String,
    fonts: BTreeSet<usize>,
    images: BTreeSet<usize>,
    states: BTreeSet<(u8, u8)>,
    shadings: Vec<(usize, Gradient)>,
    links: Vec<([f32; 4], String)>,
    path_open: bool,
}

impl Page {
    fn op(&mut self, s: &str) {
        self.ops.push_str(s);
        self.ops.push('\n');
    }

    pub fn save(&mut self) {
        self.op("q");
    }

    pub fn restore(&mut self) {
        self.op("Q");
    }

    /// Concatenate a matrix `[a b c d e f]`.
    pub fn transform(&mut self, m: [f32; 6]) {
        let s = format!("{} {} {} {} {} {} cm", num(m[0]), num(m[1]), num(m[2]), num(m[3]), num(m[4]), num(m[5]));
        self.op(&s);
    }

    pub fn translate(&mut self, x: f32, y: f32) {
        self.transform([1.0, 0.0, 0.0, 1.0, x, y]);
    }

    /// Rotate clockwise (as seen, y down) by degrees.
    pub fn rotate(&mut self, deg: f32) {
        let (s, c) = deg.to_radians().sin_cos();
        self.transform([c, s, -s, c, 0.0, 0.0]);
    }

    pub fn scale(&mut self, sx: f32, sy: f32) {
        self.transform([sx, 0.0, 0.0, sy, 0.0, 0.0]);
    }

    pub fn move_to(&mut self, x: f32, y: f32) {
        let s = format!("{} {} m", num(x), num(y));
        self.op(&s);
        self.path_open = true;
    }

    pub fn line_to(&mut self, x: f32, y: f32) {
        let s = format!("{} {} l", num(x), num(y));
        self.op(&s);
    }

    pub fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        let s = format!("{} {} {} {} {} {} c", num(x1), num(y1), num(x2), num(y2), num(x), num(y));
        self.op(&s);
    }

    pub fn close(&mut self) {
        self.op("h");
    }

    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32) {
        let s = format!("{} {} {} {} re", num(x), num(y), num(w), num(h));
        self.op(&s);
        self.path_open = true;
    }

    fn alpha_state(&mut self, fill: u8, stroke: u8) {
        if fill == 255 && stroke == 255 {
            return;
        }
        self.states.insert((fill, stroke));
        let s = format!("/GS{fill}_{stroke} gs");
        self.op(&s);
    }

    /// Fill the current path.
    pub fn fill(&mut self, color: Argb, even_odd: bool) {
        if alpha(color) == 0 {
            self.op("n");
            return;
        }
        self.op("q");
        self.alpha_state(alpha(color), 255);
        let s = format!("{} rg {}", rgb(color), if even_odd { "f*" } else { "f" });
        self.op(&s);
        self.op("Q");
        self.path_open = false;
    }

    fn stroke_style(&mut self, s: &Stroke) {
        let st = format!(
            "{} w {} J {} j [{}] 0 d {} RG",
            num(s.width.max(0.0)),
            s.cap as u8,
            if s.round_join { 1 } else { 0 },
            s.dash.iter().map(|d| num(*d)).collect::<Vec<_>>().join(" "),
            rgb(s.color)
        );
        self.op(&st);
    }

    /// Stroke the current path.
    pub fn stroke(&mut self, s: &Stroke) {
        if alpha(s.color) == 0 {
            self.op("n");
            return;
        }
        self.op("q");
        self.alpha_state(255, alpha(s.color));
        self.stroke_style(s);
        self.op("S");
        self.op("Q");
        self.path_open = false;
    }

    /// Keep later drawing inside the current path (until `restore`).
    pub fn clip(&mut self, even_odd: bool) {
        self.op(if even_odd { "W* n" } else { "W n" });
        self.path_open = false;
    }

    /// Paint a gradient over the clip (set one first).
    pub fn gradient(&mut self, g: Gradient) {
        let id = self.shadings.len();
        let a = match &g {
            Gradient::Linear { stops, .. } | Gradient::Radial { stops, .. } => stops.iter().map(|s| alpha(s.1) as u32).sum::<u32>() / stops.len().max(1) as u32,
        };
        self.shadings.push((id, g));
        self.op("q");
        self.alpha_state(a as u8, 255);
        let s = format!("/Sh{id} sh");
        self.op(&s);
        self.op("Q");
    }

    /// Draw a picture into a box.
    pub fn image(&mut self, img: &ImageRef, x: f32, y: f32, w: f32, h: f32) {
        self.images.insert(img.id);
        let s = format!("q {} 0 0 {} {} {} cm /Im{} Do Q", num(w), num(-h), num(x), num(y + h), img.id);
        self.op(&s);
    }

    /// Set glyphs of a font on a baseline; `x` is where the run starts.
    #[allow(clippy::too_many_arguments)]
    pub fn text(&mut self, pdf: &mut Pdf, font: FontRef, size: f32, color: Argb, x: f32, baseline: f32, glyphs: &[Glyph], bold: bool, italic: bool) {
        if glyphs.is_empty() || size <= 0.0 || alpha(color) == 0 {
            return;
        }
        let entry = &mut pdf.fonts[font.0];
        let upm = entry.font.units_per_em as f32;
        for g in glyphs {
            let slot = entry.used.entry(g.gid).or_default();
            if slot.is_empty() && !g.text.is_empty() {
                *slot = g.text.clone();
            }
        }
        self.fonts.insert(font.0);
        let mut s = String::new();
        s.push_str("q\n");
        self.ops.push_str(&s);
        self.alpha_state(alpha(color), alpha(color));
        let mut t = String::new();
        let _ = write!(t, "BT /F{} 1 Tf {} rg ", font.0, rgb(color));
        if bold {
            let _ = write!(t, "2 Tr {} w {} RG ", num(size * 0.03), rgb(color));
        }
        let skew = if italic { size * 0.2 } else { 0.0 };
        let _ = write!(t, "{} 0 {} {} {} {} Tm [", num(size), num(skew), num(-size), num(x + glyphs[0].x), num(baseline));
        // Each glyph advances by its width; adjust to where layout put it.
        let mut pen = glyphs[0].x;
        for (k, g) in glyphs.iter().enumerate() {
            if k > 0 {
                let gap = g.x - pen;
                if gap.abs() > 0.001 {
                    let adj = -gap / size * 1000.0;
                    let _ = write!(t, "{}", num(adj));
                }
            }
            let _ = write!(t, "<{:04X}>", g.gid);
            pen = g.x + entry.font.advance(g.gid) as f32 / upm * size;
        }
        t.push_str("] TJ ET\nQ");
        self.op(&t);
    }

    /// A link over a box to a web address.
    pub fn link(&mut self, x: f32, y: f32, w: f32, h: f32, uri: &str) {
        self.links.push(([x, y, x + w, y + h], uri.to_owned()));
    }
}

/// A PDF being written.
pub struct Pdf {
    objects: Vec<Option<Vec<u8>>>,
    pages: Vec<usize>,
    fonts: Vec<FontEntry>,
    images: Vec<(usize, u32, u32)>,
    image_cache: HashMap<u64, ImageRef>,
    title: Option<String>,
    author: Option<String>,
}

const CATALOG: usize = 1;
const PAGES: usize = 2;

impl Default for Pdf {
    fn default() -> Self {
        Self::new()
    }
}

impl Pdf {
    pub fn new() -> Pdf {
        Pdf {
            objects: vec![None, None],
            pages: Vec::new(),
            fonts: Vec::new(),
            images: Vec::new(),
            image_cache: HashMap::new(),
            title: None,
            author: None,
        }
    }

    pub fn set_title(&mut self, title: &str) {
        self.title = Some(title.to_owned());
    }

    pub fn set_author(&mut self, author: &str) {
        self.author = Some(author.to_owned());
    }

    fn alloc(&mut self) -> usize {
        self.objects.push(None);
        self.objects.len()
    }

    fn set(&mut self, id: usize, body: Vec<u8>) {
        self.objects[id - 1] = Some(body);
    }

    fn stream(&mut self, id: usize, dict: &str, data: &[u8], compress: bool) {
        let (data, filter) = if compress { (deflate(data), " /Filter /FlateDecode") } else { (data.to_vec(), "") };
        let mut body = format!("<< {dict}{filter} /Length {} >>\nstream\n", data.len()).into_bytes();
        body.extend_from_slice(&data);
        body.extend_from_slice(b"\nendstream");
        self.set(id, body);
    }

    /// Use a font; the same face twice gives the same reference.
    pub fn font(&mut self, font: Arc<Font>) -> FontRef {
        if let Some(i) = self.fonts.iter().position(|f| Arc::ptr_eq(&f.font, &font)) {
            return FontRef(i);
        }
        let obj = self.alloc();
        self.fonts.push(FontEntry { font, used: BTreeMap::new(), obj });
        FontRef(self.fonts.len() - 1)
    }

    /// The face of a font reference.
    pub fn face(&self, f: FontRef) -> &Arc<Font> {
        &self.fonts[f.0].font
    }

    /// Add a picture (JPEG, PNG, GIF or BMP); the same bytes twice give the
    /// same reference.
    pub fn image(&mut self, bytes: &[u8]) -> Option<ImageRef> {
        let key = {
            // FNV-1a over the bytes.
            let mut h = 0xcbf2_9ce4_8422_2325u64;
            for b in bytes {
                h ^= *b as u64;
                h = h.wrapping_mul(0x100_0000_01b3);
            }
            h ^ bytes.len() as u64
        };
        if let Some(r) = self.image_cache.get(&key) {
            return Some(r.clone());
        }
        let obj = self.alloc();
        let (w, h) = match doc_image::kind(bytes) {
            doc_image::Kind::Jpeg => {
                let info = doc_image::jpeg_info(bytes)?;
                let (cs, decode) = match info.components {
                    1 => ("/DeviceGray", ""),
                    4 => ("/DeviceCMYK", if info.adobe { " /Decode [1 0 1 0 1 0 1 0]" } else { "" }),
                    _ => ("/DeviceRGB", ""),
                };
                let dict = format!("/Type /XObject /Subtype /Image /Width {} /Height {} /ColorSpace {cs} /BitsPerComponent 8{decode} /Filter /DCTDecode", info.width, info.height);
                let mut body = format!("<< {dict} /Length {} >>\nstream\n", bytes.len()).into_bytes();
                body.extend_from_slice(bytes);
                body.extend_from_slice(b"\nendstream");
                self.set(obj, body);
                (info.width, info.height)
            }
            _ => {
                let r = doc_image::decode(bytes).ok()?;
                let cs = if r.channels == 1 { "/DeviceGray" } else { "/DeviceRGB" };
                let mut smask = String::new();
                if let Some(a) = &r.alpha {
                    let m = self.alloc();
                    self.stream(m, &format!("/Type /XObject /Subtype /Image /Width {} /Height {} /ColorSpace /DeviceGray /BitsPerComponent 8", r.width, r.height), a, true);
                    smask = format!(" /SMask {m} 0 R");
                }
                self.stream(obj, &format!("/Type /XObject /Subtype /Image /Width {} /Height {} /ColorSpace {cs} /BitsPerComponent 8{smask}", r.width, r.height), &r.pixels, true);
                (r.width, r.height)
            }
        };
        self.images.push((obj, w, h));
        let r = ImageRef { id: self.images.len() - 1, width: w, height: h };
        self.image_cache.insert(key, r.clone());
        Some(r)
    }

    pub fn page(&self, width: f32, height: f32) -> Page {
        let mut p = Page {
            width,
            height,
            ops: String::new(),
            fonts: BTreeSet::new(),
            images: BTreeSet::new(),
            states: BTreeSet::new(),
            shadings: Vec::new(),
            links: Vec::new(),
            path_open: false,
        };
        // Points, origin at the top left, y down.
        let flip = format!("1 0 0 -1 0 {} cm", num(height));
        p.op(&flip);
        p
    }

    pub fn add_page(&mut self, page: Page) {
        let content = self.alloc();
        self.stream(content, "", page.ops.as_bytes(), true);
        let mut res = String::from("/ProcSet [/PDF /Text /ImageB /ImageC]");
        if !page.fonts.is_empty() {
            res.push_str(" /Font <<");
            for f in &page.fonts {
                let _ = write!(res, " /F{f} {} 0 R", self.fonts[*f].obj);
            }
            res.push_str(" >>");
        }
        if !page.images.is_empty() {
            res.push_str(" /XObject <<");
            for i in &page.images {
                let _ = write!(res, " /Im{i} {} 0 R", self.images[*i].0);
            }
            res.push_str(" >>");
        }
        if !page.states.is_empty() {
            res.push_str(" /ExtGState <<");
            for (f, s) in &page.states {
                let _ = write!(res, " /GS{f}_{s} << /Type /ExtGState /ca {} /CA {} >>", num(*f as f32 / 255.0), num(*s as f32 / 255.0));
            }
            res.push_str(" >>");
        }
        if !page.shadings.is_empty() {
            res.push_str(" /Shading <<");
            for (id, g) in &page.shadings {
                let sh = self.alloc();
                let body = shading(g);
                self.set(sh, body.into_bytes());
                let _ = write!(res, " /Sh{id} {sh} 0 R");
            }
            res.push_str(" >>");
        }
        let mut annots = String::new();
        if !page.links.is_empty() {
            annots.push_str(" /Annots [");
            for (r, uri) in &page.links {
                let a = self.alloc();
                let h = page.height;
                let body = format!(
                    "<< /Type /Annot /Subtype /Link /Rect [{} {} {} {}] /Border [0 0 0] /A << /S /URI /URI {} >> >>",
                    num(r[0]),
                    num(h - r[3]),
                    num(r[2]),
                    num(h - r[1]),
                    pdf_string(uri)
                );
                self.set(a, body.into_bytes());
                let _ = write!(annots, " {a} 0 R");
            }
            annots.push_str(" ]");
        }
        let id = self.alloc();
        let body = format!(
            "<< /Type /Page /Parent {PAGES} 0 R /MediaBox [0 0 {} {}] /Resources << {res} >> /Contents {content} 0 R{annots} >>",
            num(page.width),
            num(page.height)
        );
        self.set(id, body.into_bytes());
        self.pages.push(id);
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    fn write_fonts(&mut self) {
        let fonts = std::mem::take(&mut self.fonts);
        for (i, f) in fonts.iter().enumerate() {
            let font = &f.font;
            let upm = font.units_per_em as f32;
            let scale = |v: i32| (v as f32 * 1000.0 / upm).round() as i32;
            // A subset tag from the glyphs used.
            let mut h = 0x811c_9dc5u32 ^ i as u32;
            for g in f.used.keys() {
                h ^= *g as u32;
                h = h.wrapping_mul(0x0100_0193);
            }
            let tag: String = (0..6).map(|k| (b'A' + ((h >> (k * 5)) % 26) as u8) as char).collect();
            let base = format!("{tag}+{}", if font.postscript_name.is_empty() { "Font" } else { &font.postscript_name });
            let file_obj = self.alloc();
            let (file_key, ok) = if font.is_cff {
                let data = font.standalone();
                self.stream(file_obj, "/Subtype /OpenType", &data, true);
                ("FontFile3", true)
            } else {
                let used: BTreeSet<u16> = f.used.keys().copied().collect();
                match font.subset(&used) {
                    Some(data) => {
                        let len = data.len();
                        self.stream(file_obj, &format!("/Length1 {len}"), &data, true);
                        ("FontFile2", true)
                    }
                    None => ("FontFile2", false),
                }
            };
            let desc = self.alloc();
            let flags = 4 | if font.italic { 64 } else { 0 } | if font.monospace { 1 } else { 0 };
            let b = font.bbox;
            let mut d = format!(
                "<< /Type /FontDescriptor /FontName /{base} /Flags {flags} /FontBBox [{} {} {} {}] /ItalicAngle {} /Ascent {} /Descent {} /CapHeight {} /StemV {}",
                scale(b[0] as i32),
                scale(b[1] as i32),
                scale(b[2] as i32),
                scale(b[3] as i32),
                num(font.italic_angle),
                scale(font.ascent as i32),
                scale(font.descent as i32),
                scale(font.cap_height as i32),
                if font.bold() { 120 } else { 80 }
            );
            if ok {
                let _ = write!(d, " /{file_key} {file_obj} 0 R");
            }
            d.push_str(" >>");
            self.set(desc, d.into_bytes());
            // Widths of the glyphs used.
            let mut w = String::from("[");
            for g in f.used.keys() {
                let _ = write!(w, " {} [{}]", g, scale(font.advance(*g) as i32));
            }
            w.push_str(" ]");
            let cid = self.alloc();
            let subtype = if font.is_cff { "CIDFontType0" } else { "CIDFontType2" };
            let map = if font.is_cff { "" } else { " /CIDToGIDMap /Identity" };
            let body = format!(
                "<< /Type /Font /Subtype /{subtype} /BaseFont /{base} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {desc} 0 R /DW 1000 /W {w}{map} >>"
            );
            self.set(cid, body.into_bytes());
            // What each glyph stands for, for search and copying.
            let mut cmap = String::from(
                "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
            );
            let entries: Vec<(&u16, &String)> = f.used.iter().filter(|(_, t)| !t.is_empty()).collect();
            for chunk in entries.chunks(100) {
                let _ = writeln!(cmap, "{} beginbfchar", chunk.len());
                for (g, t) in chunk {
                    let hex: String = t.encode_utf16().map(|u| format!("{u:04X}")).collect();
                    let _ = writeln!(cmap, "<{:04X}> <{hex}>", g);
                }
                cmap.push_str("endbfchar\n");
            }
            cmap.push_str("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend");
            let tu = self.alloc();
            self.stream(tu, "", cmap.as_bytes(), true);
            let body = format!("<< /Type /Font /Subtype /Type0 /BaseFont /{base} /Encoding /Identity-H /DescendantFonts [{cid} 0 R] /ToUnicode {tu} 0 R >>");
            self.set(f.obj, body.into_bytes());
        }
        self.fonts = fonts;
    }

    /// The finished file.
    pub fn finish(mut self) -> Vec<u8> {
        self.write_fonts();
        let kids: Vec<String> = self.pages.iter().map(|p| format!("{p} 0 R")).collect();
        self.set(PAGES, format!("<< /Type /Pages /Kids [{}] /Count {} >>", kids.join(" "), self.pages.len()).into_bytes());
        self.set(CATALOG, format!("<< /Type /Catalog /Pages {PAGES} 0 R >>").into_bytes());
        let mut info = String::from("<< /Producer (DocHelper)");
        if let Some(t) = &self.title {
            let _ = write!(info, " /Title {}", pdf_string(t));
        }
        if let Some(a) = &self.author {
            let _ = write!(info, " /Author {}", pdf_string(a));
        }
        info.push_str(" >>");
        let info_id = self.alloc();
        self.set(info_id, info.into_bytes());

        let mut out = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n".to_vec();
        let mut offsets = Vec::with_capacity(self.objects.len());
        for (i, o) in self.objects.iter().enumerate() {
            offsets.push(out.len());
            let _ = write!(out, "{} 0 obj\n", i + 1);
            match o {
                Some(b) => out.extend_from_slice(b),
                None => out.extend_from_slice(b"null"),
            }
            out.extend_from_slice(b"\nendobj\n");
        }
        let xref = out.len();
        let _ = write!(out, "xref\n0 {}\n0000000000 65535 f \n", self.objects.len() + 1);
        for o in offsets {
            let _ = write!(out, "{o:010} 00000 n \n");
        }
        let _ = write!(out, "trailer\n<< /Size {} /Root {CATALOG} 0 R /Info {info_id} 0 R >>\nstartxref\n{xref}\n%%EOF\n", self.objects.len() + 1);
        out
    }
}

/// A shading dictionary with its colour function.
fn shading(g: &Gradient) -> String {
    let stops = match g {
        Gradient::Linear { stops, .. } | Gradient::Radial { stops, .. } => stops,
    };
    let mut stops: Vec<(f32, Argb)> = stops.clone();
    stops.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    if stops.is_empty() {
        stops.push((0.0, 0xFF00_0000));
    }
    if stops.len() == 1 {
        stops.push((1.0, stops[0].1));
    }
    let lin = |a: Argb, b: Argb| format!("<< /FunctionType 2 /Domain [0 1] /C0 [{}] /C1 [{}] /N 1 >>", rgb(a), rgb(b));
    let (t0, t1) = (stops[0].0.clamp(0.0, 1.0), stops[stops.len() - 1].0.clamp(0.0, 1.0));
    let func = if stops.len() == 2 {
        lin(stops[0].1, stops[1].1)
    } else {
        let fns: Vec<String> = stops.windows(2).map(|w| lin(w[0].1, w[1].1)).collect();
        let bounds: Vec<String> = stops[1..stops.len() - 1].iter().map(|s| num(s.0.clamp(t0, t1))).collect();
        let encode: Vec<String> = (0..fns.len()).map(|_| "0 1".to_owned()).collect();
        format!(
            "<< /FunctionType 3 /Domain [{} {}] /Functions [{}] /Bounds [{}] /Encode [{}] >>",
            num(t0),
            num(t1.max(t0 + 0.0001)),
            fns.join(" "),
            bounds.join(" "),
            encode.join(" ")
        )
    };
    match g {
        Gradient::Linear { from, to, .. } => {
            // Stops between t0 and t1 of the line.
            let (dx, dy) = (to.0 - from.0, to.1 - from.1);
            let a = (from.0 + dx * t0, from.1 + dy * t0);
            let b = (from.0 + dx * t1, from.1 + dy * t1);
            format!(
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{} {} {} {}] /Domain [{} {}] /Function {func} /Extend [true true] >>",
                num(a.0),
                num(a.1),
                num(b.0),
                num(b.1),
                num(t0),
                num(t1.max(t0 + 0.0001))
            )
        }
        Gradient::Radial { center, radius, .. } => format!(
            "<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [{} {} {} {} {} {}] /Domain [{} {}] /Function {func} /Extend [true true] >>",
            num(center.0),
            num(center.1),
            num(radius * t0),
            num(center.0),
            num(center.1),
            num(radius * t1),
            num(t0),
            num(t1.max(t0 + 0.0001))
        ),
    }
}

#[cfg(test)]
mod tests;
