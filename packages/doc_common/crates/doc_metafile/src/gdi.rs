//! What WMF and EMF records drive: a device context (pen, brush, font,
//! colours, mapping, current position, saved states), an object table,
//! paths, and the drawing itself onto a [`Canvas`].

use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

use doc_font::{Font, FontBook, Seg};

use crate::raster::{bezier, dash, Canvas, ImageOp, Pt, Rgba, MAX_DASHES};

/// Points a path may hold; past this, more figures and points are left out.
pub const MAX_PATH: usize = 1 << 20;

/// What looking up a face this picture has not used before costs, in
/// budget items. Each lookup searches the fonts (tens of microseconds on
/// a desktop), so a picture naming a new face for every space it draws
/// could otherwise spend seconds on them; at this price a render looks up
/// at most about a thousand.
pub const FACE_COST: usize = 4096;

#[derive(Clone, Debug, PartialEq)]
pub struct Pen {
    /// 0 solid, 1 dash, 2 dot, 3 dash-dot, 4 dash-dot-dot, 5 none.
    pub style: u32,
    /// Logical units; 0 is one pixel.
    pub width: f64,
    pub color: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Brush {
    /// 0 solid, 1 none, 2 hatched, 3 and more patterns.
    pub style: u32,
    pub color: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FontSpec {
    /// Logical units: negative for the em, positive for the cell.
    pub height: f64,
    pub weight: i32,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    /// Tenths of a degree, anticlockwise.
    pub escapement: f64,
    pub face: String,
    pub charset: u8,
}

#[derive(Clone, Debug)]
pub enum Obj {
    Pen(Pen),
    Brush(Brush),
    Font(FontSpec),
    Other,
}

/// The device context.
#[derive(Clone, Debug)]
pub struct Dc {
    pub pen: Pen,
    pub brush: Brush,
    pub font: FontSpec,
    pub text_color: u32,
    pub bk_color: u32,
    pub bk_opaque: bool,
    pub even_odd: bool,
    pub text_align: u32,
    pub pos: (f64, f64),
    pub map_mode: u32,
    pub win_org: (f64, f64),
    pub win_ext: (f64, f64),
    pub vp_org: (f64, f64),
    pub vp_ext: (f64, f64),
    /// World transform: x' = a x + c y + e, y' = b x + d y + f.
    pub xform: [f64; 6],
    pub clip: Option<(f32, f32, f32, f32)>,
}

impl Default for Dc {
    fn default() -> Self {
        Dc {
            pen: Pen { style: 0, width: 0.0, color: 0 },
            brush: Brush { style: 0, color: 0xFFFFFF },
            font: FontSpec { height: -12.0, weight: 400, italic: false, underline: false, strike: false, escapement: 0.0, face: "Arial".into(), charset: 0 },
            text_color: 0,
            bk_color: 0xFFFFFF,
            bk_opaque: true,
            even_odd: true,
            text_align: 0,
            pos: (0.0, 0.0),
            map_mode: 1,
            win_org: (0.0, 0.0),
            win_ext: (1.0, 1.0),
            vp_org: (0.0, 0.0),
            vp_ext: (1.0, 1.0),
            xform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            clip: None,
        }
    }
}

/// How logical coordinates reach the canvas.
pub enum Mapping {
    /// WMF: the window is the whole picture.
    Window { w: f64, h: f64 },
    /// EMF: logical to device through the world transform and the map
    /// mode, then device to canvas: (device - origin) * scale.
    Device { origin: (f64, f64), scale: (f64, f64), px_per_mm: (f64, f64) },
}

pub struct Gdi<'b> {
    pub canvas: Canvas,
    pub dc: Dc,
    stack: Vec<Dc>,
    pub objects: Vec<Option<Obj>>,
    /// The empty slots below the table's end, lowest first: a table kept
    /// full would otherwise be looked through on every new object.
    free: BTreeSet<usize>,
    pub mapping: Mapping,
    /// A path being recorded (canvas coordinates): figures and whether closed.
    path: Option<Vec<(Vec<Pt>, bool)>>,
    /// How many points (and figures) the path holds.
    path_size: usize,
    book: Option<&'b mut FontBook>,
    /// The faces this picture's fonts came to: by name, bold and italic.
    faces: HashMap<(String, bool, bool), Option<Arc<Font>>>,
    pub drawn: bool,
}

fn rgba(c: u32) -> Rgba {
    Rgba::colorref(c & 0xFF_FFFF)
}

/// Windows-1252's characters 0x80-0x9F.
const CP1252_HIGH: [u16; 32] = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC,
    0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

/// Text of an 8-bit string: Windows-1252, or the private-use characters
/// symbol fonts map their bytes to.
pub fn ansi(bytes: &[u8], symbol: bool) -> Vec<char> {
    bytes
        .iter()
        .map(|&b| {
            let u = if symbol && b >= 0x20 {
                0xF000 + b as u32
            } else if (0x80..0xA0).contains(&b) {
                CP1252_HIGH[(b - 0x80) as usize] as u32
            } else {
                b as u32
            };
            char::from_u32(u).unwrap_or('?')
        })
        .collect()
}

pub fn is_symbol_face(face: &str, charset: u8) -> bool {
    let f = face.to_ascii_lowercase();
    charset == 2 || f.contains("symbol") || f.contains("wingdings") || f.contains("webdings")
}

impl<'b> Gdi<'b> {
    pub fn new(w: usize, h: usize, mapping: Mapping, book: Option<&'b mut FontBook>) -> Gdi<'b> {
        Gdi { canvas: Canvas::new(w, h), dc: Dc::default(), stack: Vec::new(), objects: Vec::new(), free: BTreeSet::new(), mapping, path: None, path_size: 0, book, faces: HashMap::new(), drawn: false }
    }

    // ----- coordinates

    /// Page coordinates to device ones under the map mode.
    fn page_to_device(&self, x: f64, y: f64) -> (f64, f64) {
        let dc = &self.dc;
        let (px, py) = match &self.mapping {
            Mapping::Device { px_per_mm, .. } => *px_per_mm,
            Mapping::Window { .. } => (1.0, 1.0),
        };
        let fixed = |mm: f64| -> (f64, f64) { ((x - dc.win_org.0) * mm * px + dc.vp_org.0, -(y - dc.win_org.1) * mm * py + dc.vp_org.1) };
        match dc.map_mode {
            2 => fixed(0.1),
            3 => fixed(0.01),
            4 => fixed(0.254),
            5 => fixed(0.0254),
            6 => fixed(25.4 / 1440.0),
            7 | 8 => {
                let sx = if dc.win_ext.0 != 0.0 { dc.vp_ext.0 / dc.win_ext.0 } else { 1.0 };
                let mut sy = if dc.win_ext.1 != 0.0 { dc.vp_ext.1 / dc.win_ext.1 } else { 1.0 };
                let mut sx = sx;
                if dc.map_mode == 7 {
                    // Isotropic: the same scale both ways, the smaller.
                    let s = sx.abs().min(sy.abs());
                    sx = s * sx.signum();
                    sy = s * sy.signum();
                }
                ((x - dc.win_org.0) * sx + dc.vp_org.0, (y - dc.win_org.1) * sy + dc.vp_org.1)
            }
            _ => (x - dc.win_org.0 + dc.vp_org.0, y - dc.win_org.1 + dc.vp_org.1),
        }
    }

    /// A logical point on the canvas.
    pub fn map(&self, x: f64, y: f64) -> Pt {
        match &self.mapping {
            Mapping::Window { w, h } => {
                let dc = &self.dc;
                let (ex, ey) = (if dc.win_ext.0 != 0.0 { dc.win_ext.0 } else { 1.0 }, if dc.win_ext.1 != 0.0 { dc.win_ext.1 } else { 1.0 });
                (((x - dc.win_org.0) * w / ex) as f32, ((y - dc.win_org.1) * h / ey) as f32)
            }
            Mapping::Device { origin, scale, .. } => {
                let m = &self.dc.xform;
                let (wx, wy) = (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]);
                let (dx, dy) = self.page_to_device(wx, wy);
                (((dx - origin.0) * scale.0) as f32, ((dy - origin.1) * scale.1) as f32)
            }
        }
    }

    /// Canvas pixels per logical unit, across and down.
    pub fn unit(&self) -> (f32, f32) {
        let (a, b, c) = (self.map(0.0, 0.0), self.map(1000.0, 0.0), self.map(0.0, 1000.0));
        (((b.0 - a.0).hypot(b.1 - a.1) / 1000.0), ((c.0 - a.0).hypot(c.1 - a.1) / 1000.0))
    }

    fn clip_now(&mut self) {
        let full = (0.0, 0.0, self.canvas.w as f32, self.canvas.h as f32);
        self.canvas.clip = match self.dc.clip {
            Some((a, b, c, d)) => (a.max(full.0), b.max(full.1), c.min(full.2), d.min(full.3)),
            None => full,
        };
    }

    // ----- state

    pub fn save(&mut self) {
        if self.stack.len() < 1024 {
            self.stack.push(self.dc.clone());
        }
    }

    pub fn restore(&mut self, n: i64) {
        // Negative: that many back; positive: an absolute level.
        let target = if n < 0 { self.stack.len() as i64 + n } else { n - 1 };
        if target < 0 || target as usize >= self.stack.len() {
            if let Some(dc) = self.stack.pop() {
                self.dc = dc;
            }
            return;
        }
        self.stack.truncate(target as usize + 1);
        if let Some(dc) = self.stack.pop() {
            self.dc = dc;
        }
    }

    /// Put an object in a slot (WMF: the lowest free one).
    pub fn add_object(&mut self, obj: Obj, slot: Option<usize>) {
        let i = match slot {
            Some(i) => i,
            None => self.lowest_free(),
        };
        if i > 65535 {
            return;
        }
        if self.objects.len() <= i {
            self.free.extend(self.objects.len()..i);
            self.objects.resize(i + 1, None);
        }
        self.free.remove(&i);
        self.objects[i] = Some(obj);
    }

    /// The lowest empty slot, or the table's end when it has none.
    fn lowest_free(&mut self) -> usize {
        while let Some(&i) = self.free.first() {
            // The table is public: a slot filled behind our back is not free.
            if self.objects.get(i).is_some_and(Option::is_none) {
                return i;
            }
            self.free.remove(&i);
        }
        self.objects.len()
    }

    pub fn select(&mut self, i: usize) {
        match self.objects.get(i).cloned().flatten() {
            Some(Obj::Pen(p)) => self.dc.pen = p,
            Some(Obj::Brush(b)) => self.dc.brush = b,
            Some(Obj::Font(f)) => self.dc.font = f,
            _ => {}
        }
    }

    pub fn delete(&mut self, i: usize) {
        if let Some(o) = self.objects.get_mut(i) {
            *o = None;
            self.free.insert(i);
        }
    }

    /// EMF stock objects.
    pub fn select_stock(&mut self, k: u32) {
        match k {
            0 => self.dc.brush = Brush { style: 0, color: 0xFFFFFF },
            1 => self.dc.brush = Brush { style: 0, color: 0xC0C0C0 },
            2 => self.dc.brush = Brush { style: 0, color: 0x808080 },
            3 => self.dc.brush = Brush { style: 0, color: 0x404040 },
            4 => self.dc.brush = Brush { style: 0, color: 0 },
            5 => self.dc.brush = Brush { style: 1, color: 0 },
            6 => self.dc.pen = Pen { style: 0, width: 0.0, color: 0xFFFFFF },
            7 => self.dc.pen = Pen { style: 0, width: 0.0, color: 0 },
            8 => self.dc.pen = Pen { style: 5, width: 0.0, color: 0 },
            10..=17 => self.dc.font = Dc::default().font,
            _ => {}
        }
    }

    pub fn intersect_clip(&mut self, l: f64, t: f64, r: f64, b: f64) {
        let (p, q) = (self.map(l, t), self.map(r, b));
        let rect = (p.0.min(q.0), p.1.min(q.1), p.0.max(q.0), p.1.max(q.1));
        self.dc.clip = Some(match self.dc.clip {
            Some(c) => (c.0.max(rect.0), c.1.max(rect.1), c.2.min(rect.2), c.3.min(rect.3)),
            None => rect,
        });
    }

    // ----- paths

    pub fn begin_path(&mut self) {
        self.path = Some(Vec::new());
        self.path_size = 0;
    }

    pub fn abort_path(&mut self) {
        self.path = None;
    }

    pub fn close_figure(&mut self) {
        if let Some(p) = &mut self.path {
            if let Some(last) = p.last_mut() {
                last.1 = true;
            }
        }
    }

    /// Finish the path: fill, stroke, or both.
    pub fn draw_path(&mut self, fill: bool, stroke: bool) {
        let Some(path) = self.path.take() else { return };
        let figures: Vec<Vec<Pt>> = path.iter().map(|f| f.0.clone()).collect();
        if fill {
            self.fill_canvas(&figures);
        }
        if stroke {
            for (f, closed) in &path {
                self.stroke_canvas(std::slice::from_ref(f), *closed);
            }
        }
    }

    fn recording(&self) -> bool {
        self.path.is_some()
    }

    /// Whether the path has room for `n` more points (and a figure).
    fn path_room(&mut self, n: usize) -> bool {
        match self.path_size.checked_add(n + 1) {
            Some(size) if size <= MAX_PATH => {
                self.path_size = size;
                true
            }
            _ => false,
        }
    }

    /// Add points to the path's current figure (starting one if needed).
    fn path_add(&mut self, pts: &[Pt], new_figure: bool, closed: bool) {
        if !self.path_room(pts.len()) {
            return;
        }
        let cur = self.map(self.dc.pos.0, self.dc.pos.1);
        if let Some(p) = &mut self.path {
            if new_figure || p.last().is_none_or(|f| f.1) {
                p.push((if new_figure { Vec::new() } else { vec![cur] }, false));
            }
            let last = p.last_mut().unwrap();
            last.0.extend_from_slice(pts);
            if closed {
                last.1 = true;
            }
        }
    }

    // ----- drawing

    fn fill_canvas(&mut self, contours: &[Vec<Pt>]) {
        let b = &self.dc.brush;
        if b.style == 1 {
            return;
        }
        let mut color = rgba(b.color);
        if b.style >= 2 {
            // Hatches and patterns: a lighter tint of their colour.
            color.a = 0.5;
        }
        self.clip_now();
        let even_odd = self.dc.even_odd;
        self.canvas.fill(contours, even_odd, color);
        self.drawn = true;
    }

    fn stroke_canvas(&mut self, lines: &[Vec<Pt>], closed: bool) {
        let p = self.dc.pen.clone();
        if p.style == 5 {
            return;
        }
        let (ux, uy) = self.unit();
        let w = (p.width * ((ux + uy) / 2.0) as f64) as f32;
        let w = if p.width <= 0.0 { 1.0 } else { w.max(1.0) };
        let unit = w.max(1.0);
        let pattern: Vec<f32> = match p.style {
            1 => vec![6.0 * unit, 2.0 * unit],
            2 => vec![unit, unit],
            3 => vec![6.0 * unit, 2.0 * unit, unit, 2.0 * unit],
            4 => vec![6.0 * unit, 2.0 * unit, unit, 2.0 * unit, unit, 2.0 * unit],
            _ => Vec::new(),
        };
        self.clip_now();
        let color = rgba(p.color);
        // Dashes only where they can be seen: the picture, and the pen's
        // width around it. Too many, and the line is drawn solid.
        let c = self.canvas.clip;
        let bounds = (c.0 - w, c.1 - w, c.2 + w, c.3 + w);
        let max = self.canvas.budget.room(MAX_DASHES);
        match (!pattern.is_empty()).then(|| dash(lines, closed, &pattern, bounds, max)).flatten() {
            Some(dashes) => {
                if self.canvas.budget.take(dashes.len()) {
                    self.canvas.stroke(&dashes, false, w, color);
                }
            }
            None => self.canvas.stroke(lines, closed, w, color),
        }
        self.drawn = true;
    }

    /// A polygon or polyline in logical coordinates.
    pub fn poly(&mut self, pts: &[(f64, f64)], closed: bool) {
        self.polys(&[pts.to_vec()], closed);
    }

    pub fn polys(&mut self, polys: &[Vec<(f64, f64)>], closed: bool) {
        let mapped: Vec<Vec<Pt>> = polys.iter().map(|p| p.iter().map(|q| self.map(q.0, q.1)).collect()).collect();
        if self.recording() {
            for m in &mapped {
                self.path_add(m, true, closed);
            }
            return;
        }
        if closed {
            self.fill_canvas(&mapped);
        }
        self.stroke_canvas(&mapped, closed);
    }

    /// Lines from the current position (`LineTo`, `PolylineTo`).
    pub fn lines_to(&mut self, pts: &[(f64, f64)]) {
        let Some(&last) = pts.last() else { return };
        let mapped: Vec<Pt> = pts.iter().map(|q| self.map(q.0, q.1)).collect();
        if self.recording() {
            self.path_add(&mapped, false, false);
        } else {
            let mut line = vec![self.map(self.dc.pos.0, self.dc.pos.1)];
            line.extend(mapped);
            self.stroke_canvas(&[line], false);
        }
        self.dc.pos = last;
    }

    pub fn move_to(&mut self, x: f64, y: f64) {
        self.dc.pos = (x, y);
        let mapped = self.map(x, y);
        if self.recording() && self.path_room(1) {
            if let Some(p) = &mut self.path {
                p.push((vec![mapped], false));
            }
        }
    }

    /// Bézier curves: `pts` in threes after a start point. Their points
    /// come out of the budget; curves past it are left out.
    pub fn beziers(&mut self, start: (f64, f64), pts: &[(f64, f64)], from_current: bool) {
        let s = self.map(start.0, start.1);
        let mut out = vec![s];
        let mut prev = s;
        for c in pts.chunks_exact(3) {
            let (p1, p2, p3) = (self.map(c[0].0, c[0].1), self.map(c[1].0, c[1].1), self.map(c[2].0, c[2].1));
            let before = out.len();
            bezier(prev, p1, p2, p3, &mut out);
            if !self.canvas.budget.take(out.len() - before) {
                out.truncate(before);
                break;
            }
            prev = p3;
        }
        if let Some(last) = pts.chunks_exact(3).last() {
            if from_current {
                self.dc.pos = last[2];
            }
        }
        if self.recording() {
            let before = self.path_size;
            self.path_add(&out[1..], !from_current, false);
            if !from_current && self.path_size != before {
                if let Some(f) = self.path.as_mut().and_then(|p| p.last_mut()) {
                    f.0.insert(0, s);
                }
            }
        } else {
            self.stroke_canvas(&[out], false);
        }
    }

    pub fn rect(&mut self, l: f64, t: f64, r: f64, b: f64) {
        self.poly(&[(l, t), (r, t), (r, b), (l, b)], true);
    }

    pub fn ellipse(&mut self, l: f64, t: f64, r: f64, b: f64) {
        let (cx, cy, rx, ry) = ((l + r) / 2.0, (t + b) / 2.0, (r - l).abs() / 2.0, (b - t).abs() / 2.0);
        let n = 64;
        let pts: Vec<(f64, f64)> = (0..n).map(|i| {
            let a = i as f64 / n as f64 * std::f64::consts::TAU;
            (cx + rx * a.cos(), cy + ry * a.sin())
        }).collect();
        self.poly(&pts, true);
    }

    pub fn round_rect(&mut self, l: f64, t: f64, r: f64, b: f64, w: f64, h: f64) {
        let (l, r) = (l.min(r), l.max(r));
        let (t, b) = (t.min(b), t.max(b));
        let rx = (w.abs() / 2.0).min((r - l) / 2.0);
        let ry = (h.abs() / 2.0).min((b - t) / 2.0);
        let mut pts = Vec::new();
        let corner = |pts: &mut Vec<(f64, f64)>, cx: f64, cy: f64, a0: f64| {
            for i in 0..=8 {
                let a = (a0 + i as f64 * 90.0 / 8.0).to_radians();
                pts.push((cx + rx * a.cos(), cy + ry * a.sin()));
            }
        };
        corner(&mut pts, r - rx, t + ry, 270.0);
        corner(&mut pts, r - rx, b - ry, 0.0);
        corner(&mut pts, l + rx, b - ry, 90.0);
        corner(&mut pts, l + rx, t + ry, 180.0);
        self.poly(&pts, true);
    }

    /// An arc of the ellipse in a box, anticlockwise (as seen) from the
    /// start radial to the end radial; 0 arc, 1 chord, 2 pie.
    pub fn arc(&mut self, bx: (f64, f64, f64, f64), start: (f64, f64), end: (f64, f64), kind: u8, line_to: bool) {
        let (l, t, r, b) = bx;
        let (cx, cy, rx, ry) = ((l + r) / 2.0, (t + b) / 2.0, ((r - l) / 2.0).abs().max(1e-9), ((b - t) / 2.0).abs().max(1e-9));
        let ang = |p: (f64, f64)| ((p.1 - cy) / ry).atan2((p.0 - cx) / rx);
        let a0 = ang(start);
        let mut a1 = ang(end);
        // Anticlockwise on screen: angles decrease (y grows downwards).
        while a1 >= a0 {
            a1 -= std::f64::consts::TAU;
        }
        if (a0 - a1 - std::f64::consts::TAU).abs() < 1e-9 {
            a1 = a0 - std::f64::consts::TAU;
        }
        let n = (((a0 - a1) / std::f64::consts::TAU * 64.0).ceil() as usize).max(2);
        let mut pts: Vec<(f64, f64)> = (0..=n).map(|i| {
            let a = a0 + (a1 - a0) * i as f64 / n as f64;
            (cx + rx * a.cos(), cy + ry * a.sin())
        }).collect();
        if line_to {
            let mut all = vec![self.dc.pos];
            all.extend(pts.iter().copied());
            let last = *pts.last().unwrap();
            self.lines_to(&all[1..]);
            self.dc.pos = last;
            return;
        }
        match kind {
            1 => self.poly(&pts, true),
            2 => {
                pts.push((cx, cy));
                self.poly(&pts, true)
            }
            _ => {
                let mapped: Vec<Pt> = pts.iter().map(|q| self.map(q.0, q.1)).collect();
                if self.recording() {
                    self.path_add(&mapped, true, false);
                } else {
                    self.stroke_canvas(&[mapped], false);
                }
            }
        }
    }

    /// A blit without a picture: the brush (PATCOPY), black or white;
    /// other raster operations leave the picture as it is.
    pub fn pattern_blit(&mut self, l: f64, t: f64, r: f64, b: f64, rop: u32) {
        match rop {
            0x00F0_0021 => self.fill_rect(l, t, r, b, None),
            0x0000_0042 => self.fill_rect(l, t, r, b, Some(0)),
            0x00FF_0062 => self.fill_rect(l, t, r, b, Some(0xFFFFFF)),
            _ => {}
        }
    }

    /// Fill a rectangle with the current brush (pattern blits).
    pub fn fill_rect(&mut self, l: f64, t: f64, r: f64, b: f64, color: Option<u32>) {
        let pts = [self.map(l, t), self.map(r, t), self.map(r, b), self.map(l, b)];
        self.clip_now();
        let c = match color {
            Some(c) => rgba(c),
            None if self.dc.brush.style == 1 => return,
            None => rgba(self.dc.brush.color),
        };
        self.canvas.fill(&[pts.to_vec()], false, c);
        self.drawn = true;
    }

    /// A picture (a DIB: header, colours, bits) into a logical rectangle.
    #[allow(clippy::too_many_arguments)]
    pub fn dib(&mut self, bmi: &[u8], bits: &[u8], dest: (f64, f64, f64, f64), src: Option<(i64, i64, i64, i64)>, rop: u32, alpha: bool) {
        let Some((w, h, mut px)) = decode_dib(bmi, bits, alpha) else { return };
        let (mut sx, mut sy, mut sw, mut sh) = src.unwrap_or((0, 0, w as i64, h as i64));
        if sw <= 0 || sh <= 0 {
            sx = 0;
            sy = 0;
            sw = w as i64;
            sh = h as i64;
        }
        let sx = sx.clamp(0, w as i64) as usize;
        let sy = sy.clamp(0, h as i64) as usize;
        let sw = (sw as usize).min(w - sx);
        let sh = (sh as usize).min(h - sy);
        if sw == 0 || sh == 0 {
            return;
        }
        if (sx, sy, sw, sh) != (0, 0, w, h) {
            // The part shown, moved to the front of the picture's own
            // buffer: a copy would hold a large picture twice. Each row
            // moves to where it is or earlier, so none is overwritten
            // before it moves.
            for (k, y) in (sy..sy + sh).enumerate() {
                let from = (y * w + sx) * 4;
                px.copy_within(from..from + sw * 4, k * sw * 4);
            }
            px.truncate(sw * sh * 4);
        }
        let op = match rop {
            0x0088_00C6 => ImageOp::And,
            0x00EE_0086 | 0x0066_0046 => ImageOp::Paint,
            0x0033_0008 => {
                for p in px.chunks_exact_mut(4) {
                    p[0] = 255 - p[0];
                    p[1] = 255 - p[1];
                    p[2] = 255 - p[2];
                }
                ImageOp::Copy
            }
            _ => ImageOp::Copy,
        };
        let (x, y, dw, dh) = dest;
        let a = self.map(x, y);
        let b = self.map(x + dw, y + dh);
        self.clip_now();
        self.canvas.image(&px, sw, sh, (a.0, a.1, b.0, b.1), op);
        self.drawn = true;
    }

    // ----- text

    /// The face for a font: from those this picture already used, or
    /// looked up in the font book for [`FACE_COST`] of the budget.
    fn face(&mut self, spec: &FontSpec) -> Option<Arc<Font>> {
        let key = (spec.face.clone(), spec.weight >= 600, spec.italic);
        if let Some(face) = self.faces.get(&key) {
            return face.clone();
        }
        let book = self.book.as_deref_mut()?;
        if !self.canvas.budget.take(FACE_COST) {
            return None;
        }
        let face = book.resolve(&key.0, key.1, key.2).and_then(|id| book.font(id));
        self.faces.insert(key, face.clone());
        face
    }

    /// Text at a logical point; `dx` gives each character's advance.
    pub fn text(&mut self, x: f64, y: f64, chars: &[char], dx: Option<&[f64]>, opaque: Option<(f64, f64, f64, f64)>) {
        if let Some((l, t, r, b)) = opaque {
            let bk = self.dc.bk_color;
            self.fill_rect(l, t, r, b, Some(bk));
        }
        // Each character is looked up and placed, outline or not.
        if chars.is_empty() || !self.canvas.budget.take(chars.len()) {
            return;
        }
        let spec = self.dc.font.clone();
        let Some(face) = self.face(&spec) else { return };
        let upm = face.units_per_em.max(1) as f32;
        let (asc, desc) = (face.ascent as f32, -(face.descent as f32).abs());
        let (ux, uy) = self.unit();
        // The em in logical units: a negative height is the em itself; a
        // positive one is the cell (ascent plus descent).
        let em_logical = if spec.height < 0.0 {
            -spec.height as f32
        } else if spec.height > 0.0 {
            spec.height as f32 * upm / (asc - desc).max(1.0)
        } else {
            12.0
        };
        let em = em_logical * uy;
        if em < 0.3 || !em.is_finite() {
            return;
        }
        let k = em / upm;
        let update_cp = self.dc.text_align & 1 != 0;
        let start = if update_cp { self.dc.pos } else { (x, y) };
        let origin = self.map(start.0, start.1);
        let a = -(spec.escapement as f32 / 10.0).to_radians();
        let d = (a.cos(), a.sin());
        let up = (a.sin(), -a.cos());
        // Glyphs and advances.
        let mut glyphs: Vec<(Arc<Font>, u16, f32)> = Vec::with_capacity(chars.len());
        for (i, &c) in chars.iter().enumerate() {
            let (font, gid) = match face.glyph(c) {
                Some(g) => (face.clone(), g),
                None => {
                    let fb = self.book.as_deref_mut().and_then(|b| {
                        let id = b.fallback(c, spec.weight >= 600)?;
                        let f = b.font(id)?;
                        let g = f.glyph(c)?;
                        Some((f, g))
                    });
                    match fb {
                        Some(x) => x,
                        None => (face.clone(), 0),
                    }
                }
            };
            let fk = em / font.units_per_em.max(1) as f32;
            let adv = match dx.and_then(|d| d.get(i)) {
                Some(v) => *v as f32 * ux,
                None => font.advance(gid) as f32 * fk,
            };
            glyphs.push((font, gid, adv));
        }
        let total: f32 = glyphs.iter().map(|g| g.2).sum();
        let shift_x = match self.dc.text_align & 6 {
            2 => -total,
            6 => -total / 2.0,
            _ => 0.0,
        };
        let shift_y = match self.dc.text_align & 24 {
            24 => 0.0,
            8 => -desc * k,
            _ => -asc * k,
        };
        let base = (origin.0 + d.0 * shift_x - up.0 * shift_y, origin.1 + d.1 * shift_x - up.1 * shift_y);
        let mut contours: Vec<Vec<Pt>> = Vec::new();
        let mut pen = 0.0f32;
        let room = self.canvas.budget.room(usize::MAX);
        let mut made = 0usize;
        for (font, gid, adv) in &glyphs {
            if made > room {
                // More outline than can be filled: the fill below ends the render.
                break;
            }
            let fk = em / font.units_per_em.max(1) as f32;
            let before = contours.len();
            if let Some(segs) = font.outline(*gid) {
                let at = |gx: f32, gy: f32| -> Pt {
                    let (lx, ly) = (pen + gx * fk, gy * fk);
                    (base.0 + d.0 * lx + up.0 * ly, base.1 + d.1 * lx + up.1 * ly)
                };
                let mut cur: Vec<Pt> = Vec::new();
                let mut last = (0.0, 0.0);
                for s in segs {
                    match s {
                        Seg::Move(x, y) => {
                            if cur.len() > 2 {
                                contours.push(std::mem::take(&mut cur));
                            }
                            cur.clear();
                            cur.push(at(x, y));
                            last = (x, y);
                        }
                        Seg::Line(x, y) => {
                            cur.push(at(x, y));
                            last = (x, y);
                        }
                        Seg::Quad(cx, cy, x, y) => {
                            let steps = ((em / 4.0).ceil() as usize).clamp(2, 12);
                            for i in 1..=steps {
                                let t = i as f32 / steps as f32;
                                let u = 1.0 - t;
                                let qx = u * u * last.0 + 2.0 * u * t * cx + t * t * x;
                                let qy = u * u * last.1 + 2.0 * u * t * cy + t * t * y;
                                cur.push(at(qx, qy));
                            }
                            last = (x, y);
                        }
                        Seg::Close => {
                            if cur.len() > 2 {
                                contours.push(std::mem::take(&mut cur));
                            }
                        }
                    }
                }
                if cur.len() > 2 {
                    contours.push(cur);
                }
                // Only this glyph's contours: counting them all again for
                // every glyph made long strings quadratic.
                made = contours[before..].iter().fold(made, |n, c| n.saturating_add(c.len()));
            }
            pen += adv;
        }
        self.clip_now();
        let color = rgba(self.dc.text_color);
        self.canvas.fill(&contours, false, color);
        // Bold asked of a face that is not: thicken the outline.
        if spec.weight >= 600 && !face.bold() {
            self.canvas.stroke(&contours, true, (em * 0.04).max(0.5), color);
        }
        let line = |off: f32| -> Vec<Pt> {
            vec![(base.0 - up.0 * off, base.1 - up.1 * off), (base.0 + d.0 * total - up.0 * off, base.1 + d.1 * total - up.1 * off)]
        };
        let thick = (em * 0.06).max(1.0);
        if spec.underline {
            self.canvas.stroke(&[line(-em * 0.12)], false, thick, color);
        }
        if spec.strike {
            self.canvas.stroke(&[line(em * 0.3)], false, thick, color);
        }
        self.drawn = true;
        if update_cp {
            let (lx, ly) = (start.0 + (total / ux.max(1e-6)) as f64 * d.0 as f64, start.1);
            self.dc.pos = (lx, ly);
        }
    }
}

/// A device-independent bitmap's pixels as straight RGBA, top row first.
pub fn decode_dib(bmi: &[u8], bits: &[u8], alpha: bool) -> Option<(usize, usize, Vec<u8>)> {
    let u16_at = |i: usize| -> u32 { bmi.get(i..i.saturating_add(2)).map_or(0, |s| u16::from_le_bytes([s[0], s[1]]) as u32) };
    let u32_at = |b: &[u8], i: usize| -> u32 { b.get(i..i.saturating_add(4)).map_or(0, |s| u32::from_le_bytes([s[0], s[1], s[2], s[3]])) };
    let size = u32_at(bmi, 0) as usize;
    let (w, h, bpp, compression, used, table_at, rgbquad) = if size == 12 {
        (u16_at(4) as i64, u16_at(6) as i16 as i64, u16_at(10), 0, 0, 12, 3)
    } else {
        (u32_at(bmi, 4) as i32 as i64, u32_at(bmi, 8) as i32 as i64, u16_at(14), u32_at(bmi, 16), u32_at(bmi, 32) as usize, size, 4)
    };
    let (w, top_down, h) = (w.unsigned_abs(), h < 0, h.unsigned_abs());
    // Pixel counts in 64 bits: on 32-bit phones `w * h` would wrap.
    if w == 0 || h == 0 || w.saturating_mul(h) > doc_image::MAX_PIXELS || !matches!(bpp, 1 | 4 | 8 | 16 | 24 | 32) {
        return None;
    }
    let (w, h) = (w as usize, h as usize);
    let colors = if bpp <= 8 { if used > 0 { used.min(256) } else { 1 << bpp } } else { 0 };
    let palette: Vec<[u8; 3]> = (0..colors)
        .map(|i| {
            let at = table_at.saturating_add(i * rgbquad);
            [*bmi.get(at.saturating_add(2)).unwrap_or(&0), *bmi.get(at.saturating_add(1)).unwrap_or(&0), *bmi.get(at).unwrap_or(&0)]
        })
        .collect();
    // Bit fields: after the header (or inside a V4/V5 header).
    let masks = if compression == 3 {
        let at = if size >= 52 { 40 } else { size };
        Some([u32_at(bmi, at), u32_at(bmi, at.saturating_add(4)), u32_at(bmi, at.saturating_add(8))])
    } else {
        None
    };
    if compression != 0 && compression != 3 {
        return None;
    }
    let stride = (w * bpp as usize).div_ceil(32) * 4;
    if bits.len() < stride.checked_mul(h)? {
        return None;
    }
    let mut out = Vec::new();
    out.try_reserve_exact(w * h * 4).ok()?;
    out.resize(w * h * 4, 0);
    let field = |v: u32, m: u32| -> u8 {
        if m == 0 {
            return 0;
        }
        let shift = m.trailing_zeros();
        let max = (m >> shift) as u64;
        // In 64 bits: a mask of all ones times 255 overflows 32.
        (((v & m) >> shift) as u64 * 255 / max) as u8
    };
    for row in 0..h {
        let src = &bits[row * stride..row * stride + stride];
        let y = if top_down { row } else { h - 1 - row };
        for x in 0..w {
            let (rgb, a) = match bpp {
                1 | 4 | 8 => {
                    let bit = x * bpp as usize;
                    let byte = src[bit / 8];
                    let idx = ((byte >> (8 - bpp as usize - bit % 8)) & ((1u16 << bpp) - 1) as u8) as usize;
                    (palette.get(idx).copied().unwrap_or([0, 0, 0]), 255)
                }
                16 => {
                    let v = u16::from_le_bytes([src[x * 2], src[x * 2 + 1]]) as u32;
                    let m = masks.unwrap_or([0x7C00, 0x03E0, 0x001F]);
                    ([field(v, m[0]), field(v, m[1]), field(v, m[2])], 255)
                }
                24 => ([src[x * 3 + 2], src[x * 3 + 1], src[x * 3]], 255),
                32 => {
                    let v = u32::from_le_bytes([src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]]);
                    match masks {
                        Some(m) => ([field(v, m[0]), field(v, m[1]), field(v, m[2])], 255),
                        None => ([src[x * 4 + 2], src[x * 4 + 1], src[x * 4]], if alpha { src[x * 4 + 3] } else { 255 }),
                    }
                }
                _ => return None,
            };
            let o = (y * w + x) * 4;
            // Premultiplied alpha (AlphaBlend's) back to straight.
            let un = |c: u8| if alpha && a > 0 && a < 255 { ((c as u32 * 255) / a as u32).min(255) as u8 } else { c };
            out[o..o + 4].copy_from_slice(&[un(rgb[0]), un(rgb[1]), un(rgb[2]), a]);
        }
    }
    Some((w, h, out))
}
