//! An anti-aliased rasterizer: polygons filled by the non-zero or even-odd
//! rule (exact coverage across each pixel row, four samples down it),
//! strokes made into polygons, pictures drawn scaled, all composited onto
//! RGBA with a rectangular clip.

/// A colour with straight alpha, each channel 0..1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    /// From a Windows COLORREF (0x00BBGGRR).
    pub fn colorref(c: u32) -> Rgba {
        Rgba { r: (c & 0xFF) as f32 / 255.0, g: ((c >> 8) & 0xFF) as f32 / 255.0, b: ((c >> 16) & 0xFF) as f32 / 255.0, a: 1.0 }
    }
}

pub type Pt = (f32, f32);

/// Vertical samples per pixel row.
const SAMPLES: usize = 4;

/// Points, edges and dashes one render may make.
pub const MAX_ITEMS: u64 = 4 << 20;

/// How many times over one render may paint its canvas.
pub const PAINT_LAYERS: u64 = 256;

/// Dashes one stroke may be cut into; past this the line is drawn solid.
pub const MAX_DASHES: usize = 1 << 18;

/// Polylines with more points than this get no round joins: at that
/// density the joins cannot be seen, and each would be a polygon.
pub const MAX_JOINED: usize = 4096;

/// What one render may still spend. A metafile's counts come from its
/// bytes, so a few hundred bytes can ask for gigabytes of points or hours
/// of painting; once either part runs out, the render stops and keeps what
/// it has drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    /// Points, edges and dashes: the corners of every polygon filled
    /// (strokes and glyphs included), curve points and dashes; and the
    /// characters of text, and the faces looked up for it.
    pub items: u64,
    /// Painting, in about the time of copying one pixel: each pixel a
    /// filled row's spans touch or a picture covers (eight more for one
    /// blended with what is under it), and each sample row and each edge
    /// met on it.
    pub paint: u64,
}

impl Budget {
    /// The budget for a canvas of `w` x `h` pixels.
    pub fn for_canvas(w: usize, h: usize) -> Budget {
        let px = (w as u64).saturating_mul(h as u64);
        Budget { items: MAX_ITEMS, paint: PAINT_LAYERS.saturating_mul(px).max(1 << 20) }
    }

    /// Whether the budget has run out.
    pub fn spent(&self) -> bool {
        self.items == 0 || self.paint == 0
    }

    /// How many of `n` items may still be made, spending none.
    pub fn room(&self, n: usize) -> usize {
        (n as u64).min(self.items) as usize
    }

    /// Spend `n` items if that many are left; otherwise spend the rest,
    /// which ends the render, and say no.
    pub fn take(&mut self, n: usize) -> bool {
        match self.items.checked_sub(n as u64) {
            Some(left) => {
                self.items = left;
                true
            }
            None => {
                self.items = 0;
                false
            }
        }
    }

    /// The same for painting.
    pub fn paint(&mut self, n: u64) -> bool {
        match self.paint.checked_sub(n) {
            Some(left) => {
                self.paint = left;
                true
            }
            None => {
                self.paint = 0;
                false
            }
        }
    }
}

pub struct Canvas {
    pub w: usize,
    pub h: usize,
    /// Premultiplied RGBA, 0..65535.
    px: Vec<[u16; 4]>,
    /// Drawing is limited to this rectangle (x0, y0, x1, y1).
    pub clip: (f32, f32, f32, f32),
    /// What drawing may still spend.
    pub budget: Budget,
}

struct Edge {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    dir: i32,
}

impl Canvas {
    pub fn new(w: usize, h: usize) -> Canvas {
        Canvas { w, h, px: vec![[0; 4]; w * h], clip: (0.0, 0.0, w as f32, h as f32), budget: Budget::for_canvas(w, h) }
    }

    /// Straight-alpha RGBA bytes.
    pub fn rgba(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.w * self.h * 4);
        for p in &self.px {
            let a = p[3] as f32 / 65535.0;
            let un = |c: u16| if a > 0.0 { ((c as f32 / 65535.0 / a).clamp(0.0, 1.0) * 255.0).round() as u8 } else { 0 };
            out.extend_from_slice(&[un(p[0]), un(p[1]), un(p[2]), (a * 255.0).round() as u8]);
        }
        out
    }

    fn blend(&mut self, x: usize, y: usize, c: Rgba, cover: f32) {
        let a = (c.a * cover).clamp(0.0, 1.0);
        if a <= 0.0 {
            return;
        }
        let p = &mut self.px[y * self.w + x];
        let k = 1.0 - a;
        let mix = |src: f32, dst: u16| ((src * a + dst as f32 / 65535.0 * k).clamp(0.0, 1.0) * 65535.0).round() as u16;
        *p = [mix(c.r, p[0]), mix(c.g, p[1]), mix(c.b, p[2]), mix(1.0, p[3])];
    }

    /// Fill contours (each closed) with a colour. Nothing is filled once
    /// the budget runs out.
    pub fn fill(&mut self, contours: &[Vec<Pt>], even_odd: bool, color: Rgba) {
        let corners = contours.iter().fold(0usize, |n, c| n.saturating_add(c.len()));
        if !self.budget.take(corners) {
            return;
        }
        let mut edges: Vec<Edge> = Vec::new();
        let (mut ymin, mut ymax) = (f32::MAX, f32::MIN);
        let (mut xmin, mut xmax) = (f32::MAX, f32::MIN);
        for c in contours {
            if c.len() < 2 {
                continue;
            }
            for i in 0..c.len() {
                let (a, b) = (c[i], c[(i + 1) % c.len()]);
                if !(a.0.is_finite() && a.1.is_finite() && b.0.is_finite() && b.1.is_finite()) {
                    continue;
                }
                xmin = xmin.min(a.0);
                xmax = xmax.max(a.0);
                if a.1 == b.1 {
                    continue;
                }
                let (dir, (p, q)) = if a.1 < b.1 { (1, (a, b)) } else { (-1, (b, a)) };
                ymin = ymin.min(p.1);
                ymax = ymax.max(q.1);
                edges.push(Edge { x0: p.0, y0: p.1, x1: q.0, y1: q.1, dir });
            }
        }
        if edges.is_empty() {
            return;
        }
        let (cx0, cy0, cx1, cy1) = self.clip;
        let y_start = ymin.max(cy0).max(0.0).floor() as i64;
        let y_end = ymax.min(cy1).min(self.h as f32).ceil() as i64;
        let x_lo = xmin.max(cx0).max(0.0).floor() as i64;
        let x_hi = xmax.min(cx1).min(self.w as f32).ceil() as i64;
        if y_start >= y_end || x_lo >= x_hi {
            return;
        }
        edges.sort_by(|a, b| a.y0.total_cmp(&b.y0));
        let width = (x_hi - x_lo) as usize;
        let to16 = |v: f32| (v.clamp(0.0, 1.0) * 65535.0).round() as u16;
        let solid = [to16(color.r), to16(color.g), to16(color.b), 65535];
        // Coverage along the row, kept at zero outside the part a row
        // touches: a thin slanted line across the picture costs its width
        // on each row, not the picture's.
        let mut cover = vec![0f32; width + 1];
        let mut active: Vec<usize> = Vec::new();
        let mut next = 0;
        let mut xs: Vec<(f32, i32)> = Vec::new();
        for y in y_start..y_end {
            // A row costs its samples, each edge it meets on them, and the
            // pixels its spans touch.
            if !self.budget.paint(SAMPLES as u64) {
                return;
            }
            // The entries of `cover` this row touched: lo..hi.
            let (mut lo, mut hi) = (cover.len(), 0);
            for s in 0..SAMPLES {
                let sy = y as f32 + (s as f32 + 0.5) / SAMPLES as f32;
                while next < edges.len() && edges[next].y0 <= sy {
                    active.push(next);
                    next += 1;
                }
                active.retain(|&i| edges[i].y1 > sy);
                // Each edge met, and sorting where they cross.
                let n = active.len() as u64;
                if !self.budget.paint(n * (1 + n.max(1).ilog2() as u64)) {
                    return;
                }
                xs.clear();
                for &i in &active {
                    let e = &edges[i];
                    if e.y0 <= sy && sy < e.y1 {
                        let t = (sy - e.y0) / (e.y1 - e.y0);
                        xs.push((e.x0 + t * (e.x1 - e.x0), e.dir));
                    }
                }
                if xs.len() < 2 {
                    continue;
                }
                xs.sort_by(|a, b| a.0.total_cmp(&b.0));
                let mut wind = 0;
                for k in 0..xs.len() - 1 {
                    wind += xs[k].1;
                    let inside = if even_odd { (k + 1) % 2 == 1 } else { wind != 0 };
                    if inside {
                        let a = (xs[k].0.max(cx0) - x_lo as f32).max(0.0);
                        let b = (xs[k + 1].0.min(cx1) - x_lo as f32).min(width as f32);
                        if b > a {
                            span(&mut cover, a, b, 1.0 / SAMPLES as f32);
                            // What span() wrote: from a's pixel to b's.
                            lo = lo.min(a as usize);
                            hi = hi.max((b as usize + 1).min(cover.len()));
                        }
                    }
                }
            }
            if lo >= hi {
                continue;
            }
            if !self.budget.paint((hi - lo) as u64) {
                return;
            }
            let row = y as usize * self.w + x_lo as usize;
            let mut blended = 0u64;
            for (i, &c) in cover.iter().enumerate().take(hi.min(width)).skip(lo) {
                if c >= 1.0 && color.a >= 1.0 {
                    // Covered by an opaque colour: what [`Canvas::blend`]
                    // would give, without its arithmetic.
                    self.px[row + i] = solid;
                } else if c > 0.0 {
                    self.blend(x_lo as usize + i, y as usize, color, c.min(1.0));
                    blended += 1;
                }
            }
            cover[lo..hi].fill(0.0);
            // A blended pixel takes about as long as eight copied ones.
            if !self.budget.paint(8 * blended) {
                return;
            }
        }
    }

    /// Stroke polylines `width` wide (at least a pixel), with round joins
    /// and ends; `closed` joins each back to its start. A stroke that
    /// would make more corners than the budget has left ends the render.
    pub fn stroke(&mut self, lines: &[Vec<Pt>], closed: bool, width: f32, color: Rgba) {
        match stroke_polygons(lines, closed, width.max(1.0), self.budget.items) {
            Some(polys) => self.fill(&polys, false, color),
            None => self.budget.items = 0,
        }
    }

    /// Draw a picture (straight RGBA, `iw` x `ih`) into a rectangle given
    /// by its corners, which may be flipped.
    pub fn image(&mut self, rgba: &[u8], iw: usize, ih: usize, dst: (f32, f32, f32, f32), op: ImageOp) {
        if iw == 0 || ih == 0 || rgba.len() < iw * ih * 4 {
            return;
        }
        let (x0, y0, x1, y1) = dst;
        let (lx, hx) = (x0.min(x1), x0.max(x1));
        let (ly, hy) = (y0.min(y1), y0.max(y1));
        let (cx0, cy0, cx1, cy1) = self.clip;
        let px0 = lx.max(cx0).max(0.0).floor() as i64;
        let px1 = hx.min(cx1).min(self.w as f32).ceil() as i64;
        let py0 = ly.max(cy0).max(0.0).floor() as i64;
        let py1 = hy.min(cy1).min(self.h as f32).ceil() as i64;
        if hx - lx < 0.01 || hy - ly < 0.01 {
            return;
        }
        // Every pixel is blended.
        let area = (py1 - py0).max(0) as u64 * (px1 - px0).max(0) as u64;
        if !self.budget.paint(9 * area) {
            return;
        }
        for y in py0..py1 {
            for x in px0..px1 {
                let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
                if fx < lx || fx >= hx || fy < ly || fy >= hy {
                    continue;
                }
                let mut u = (fx - x0) / (x1 - x0);
                let mut v = (fy - y0) / (y1 - y0);
                u = u.clamp(0.0, 0.9999);
                v = v.clamp(0.0, 0.9999);
                let (sx, sy) = ((u * iw as f32) as usize, (v * ih as f32) as usize);
                let p = &rgba[(sy * iw + sx) * 4..(sy * iw + sx) * 4 + 4];
                let c = Rgba { r: p[0] as f32 / 255.0, g: p[1] as f32 / 255.0, b: p[2] as f32 / 255.0, a: p[3] as f32 / 255.0 };
                match op {
                    ImageOp::Copy => self.blend(x as usize, y as usize, c, 1.0),
                    ImageOp::And => {
                        // Multiply: white leaves the page, black marks it.
                        let d = &mut self.px[y as usize * self.w + x as usize];
                        let f = |v: u16| v as f32 / 65535.0;
                        let a = f(d[3]);
                        let to = |v: f32| (v.clamp(0.0, 1.0) * 65535.0).round() as u16;
                        d[0] = to(f(d[0]) * c.r + (1.0 - a) * c.r);
                        d[1] = to(f(d[1]) * c.g + (1.0 - a) * c.g);
                        d[2] = to(f(d[2]) * c.b + (1.0 - a) * c.b);
                        if c.r + c.g + c.b < 2.99 {
                            d[3] = 65535;
                        }
                    }
                    ImageOp::Paint => {
                        // OR: only what is not black shows.
                        if c.r + c.g + c.b > 0.01 {
                            self.blend(x as usize, y as usize, c, 1.0);
                        }
                    }
                }
            }
        }
    }
}

/// How a picture combines with what is drawn (raster operations).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ImageOp {
    Copy,
    And,
    Paint,
}

fn span(cover: &mut [f32], a: f32, b: f32, w: f32) {
    let ia = a.floor() as usize;
    let ib = b.floor() as usize;
    if ia >= cover.len() {
        return;
    }
    if ia == ib {
        cover[ia] += (b - a) * w;
        return;
    }
    cover[ia] += (ia as f32 + 1.0 - a) * w;
    let end = ib.min(cover.len());
    for c in cover.iter_mut().take(end).skip(ia + 1) {
        *c += w;
    }
    if ib < cover.len() {
        cover[ib] += (b - ib as f32) * w;
    }
}

fn area(p: &[Pt]) -> f32 {
    let mut s = 0.0;
    for i in 0..p.len() {
        let (a, b) = (p[i], p[(i + 1) % p.len()]);
        s += a.0 * b.1 - b.0 * a.1;
    }
    s / 2.0
}

/// Make a polygon wind one way, so overlapping pieces add up under the
/// non-zero rule.
fn orient(mut p: Vec<Pt>) -> Vec<Pt> {
    if area(&p) < 0.0 {
        p.reverse();
    }
    p
}

/// How many points [`circle`] makes for radius `r`.
fn circle_points(r: f32) -> usize {
    ((r * 2.0).ceil() as usize).clamp(8, 64)
}

pub fn circle(c: Pt, r: f32) -> Vec<Pt> {
    let n = circle_points(r);
    (0..n).map(|i| {
        let t = i as f32 / n as f32 * std::f32::consts::TAU;
        (c.0 + r * t.cos(), c.1 + r * t.sin())
    }).collect()
}

/// Which points of a polyline of `n` points get a disc: every joint and
/// end, or on a huge polyline only its ends.
fn discs(n: usize, closed: bool, r: f32) -> std::ops::Range<usize> {
    if r > 0.75 && n <= MAX_JOINED {
        0..n
    } else if (r > 0.75 && !closed) || n == 1 {
        // Round ends on a line too long for joins; a dot for one point.
        0..n.min(2)
    } else {
        0..0
    }
}

/// The polygons covering a stroke: a quad per segment and a disc at
/// each joint and end. None when they would have more than `room`
/// corners.
fn stroke_polygons(lines: &[Vec<Pt>], closed: bool, width: f32, room: u64) -> Option<Vec<Vec<Pt>>> {
    let r = width / 2.0;
    let disc = circle_points(r) as u64;
    let mut corners = 0u64;
    for line in lines {
        let n = line.len();
        let segs = if closed && n > 2 { n } else { n.saturating_sub(1) };
        corners = corners.saturating_add(4 * segs as u64).saturating_add(disc * discs(n, closed, r).len() as u64);
    }
    if corners > room {
        return None;
    }
    let mut out = Vec::new();
    for line in lines {
        let n = line.len();
        if n == 0 {
            continue;
        }
        let segs = if closed && n > 2 { n } else { n.saturating_sub(1) };
        for i in 0..segs {
            let (a, b) = (line[i], line[(i + 1) % n]);
            let (dx, dy) = (b.0 - a.0, b.1 - a.1);
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-6 {
                continue;
            }
            let (nx, ny) = (-dy / len * r, dx / len * r);
            out.push(orient(vec![(a.0 + nx, a.1 + ny), (b.0 + nx, b.1 + ny), (b.0 - nx, b.1 - ny), (a.0 - nx, a.1 - ny)]));
        }
        let ends = discs(n, closed, r);
        if ends.len() == 2 && n > 2 {
            // The first and the last point.
            out.push(orient(circle(line[0], r)));
            out.push(orient(circle(line[n - 1], r)));
        } else {
            for p in &line[ends] {
                out.push(orient(circle(*p, r)));
            }
        }
    }
    Some(out)
}

/// A cubic Bézier as points (the start excluded).
pub fn bezier(p0: Pt, p1: Pt, p2: Pt, p3: Pt, out: &mut Vec<Pt>) {
    let len = ((p1.0 - p0.0).hypot(p1.1 - p0.1) + (p2.0 - p1.0).hypot(p2.1 - p1.1) + (p3.0 - p2.0).hypot(p3.1 - p2.1)).max(1.0);
    let n = ((len / 3.0).ceil() as usize).clamp(4, 200);
    for i in 1..=n {
        let t = i as f32 / n as f32;
        let u = 1.0 - t;
        let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
        out.push((a * p0.0 + b * p1.0 + c * p2.0 + d * p3.0, a * p0.1 + b * p1.1 + c * p2.1 + d * p3.1));
    }
}

/// The part of segment `a`-`b` inside `r` (x0, y0, x1, y1), as the
/// parameters 0 <= t0 <= t1 <= 1 of its ends, or None when it misses.
fn clip_segment(a: (f64, f64), b: (f64, f64), r: (f64, f64, f64, f64)) -> Option<(f64, f64)> {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, q) in [(-dx, a.0 - r.0), (dx, r.2 - a.0), (-dy, a.1 - r.1), (dy, r.3 - a.1)] {
        if p == 0.0 {
            if q < 0.0 {
                return None;
            }
        } else {
            let t = q / p;
            if p < 0.0 {
                t0 = t0.max(t);
            } else {
                t1 = t1.min(t);
            }
        }
    }
    (t0 <= t1).then_some((t0, t1))
}

/// Where a walk is in a dash pattern: which length, and how much of it
/// is left. Even lengths are drawn, odd ones skipped.
struct Phase<'p> {
    pattern: &'p [f64],
    period: f64,
    k: usize,
    left: f64,
}

impl Phase<'_> {
    fn on(&self) -> bool {
        self.k.is_multiple_of(2)
    }

    fn next(&mut self) {
        self.k = (self.k + 1) % self.pattern.len();
        self.left = self.pattern[self.k];
    }

    /// Move `d` along the pattern without drawing (a part of the line
    /// outside the picture), in whole periods first.
    fn skip(&mut self, d: f64) {
        if !d.is_finite() || d <= 0.0 {
            return;
        }
        let mut d = d % self.period;
        while d >= self.left {
            d -= self.left;
            self.next();
        }
        self.left -= d;
    }
}

/// Split polylines into dashes: `pattern` alternates on and off lengths.
/// Only what lies inside `bounds` (the picture and the pen's width around
/// it) is dashed: the pattern runs on outside it, but nothing is made
/// there. None when the pattern draws nothing sensible, or when there
/// would be more than `max` dashes: the lines are then stroked solid.
pub fn dash(lines: &[Vec<Pt>], closed: bool, pattern: &[f32], bounds: (f32, f32, f32, f32), max: usize) -> Option<Vec<Vec<Pt>>> {
    let mut pattern: Vec<f64> = pattern.iter().map(|&v| if v.is_finite() && v > 0.0 { v as f64 } else { 0.0 }).collect();
    if pattern.len() % 2 == 1 {
        // An odd pattern repeats with on and off swapped.
        pattern.extend_from_within(..);
    }
    let period: f64 = pattern.iter().sum();
    if !(period > 0.0 && period.is_finite()) {
        return None;
    }
    let bounds = (bounds.0 as f64, bounds.1 as f64, bounds.2 as f64, bounds.3 as f64);
    let at = |p: Pt| (p.0 as f64, p.1 as f64);
    let pt = |p: (f64, f64)| (p.0 as f32, p.1 as f32);
    let mut out: Vec<Vec<Pt>> = Vec::new();
    for line in lines {
        let mut pts: Vec<Pt> = line.clone();
        if closed && pts.len() > 2 {
            pts.push(pts[0]);
        }
        let mut phase = Phase { pattern: &pattern, period, k: 0, left: pattern[0] };
        // The dash being drawn, from its start.
        let mut cur: Vec<Pt> = Vec::new();
        let finish = |cur: &mut Vec<Pt>, out: &mut Vec<Vec<Pt>>| {
            if cur.len() > 1 {
                out.push(std::mem::take(cur));
            } else {
                cur.clear();
            }
        };
        for w in pts.windows(2) {
            let (a, b) = (at(w[0]), at(w[1]));
            let len = (b.0 - a.0).hypot(b.1 - a.1);
            if !len.is_finite() {
                finish(&mut cur, &mut out);
                continue;
            }
            if len <= 0.0 {
                continue;
            }
            let Some((t0, t1)) = clip_segment(a, b, bounds) else {
                finish(&mut cur, &mut out);
                phase.skip(len);
                continue;
            };
            let lerp = |t: f64| {
                if t <= 0.0 {
                    a
                } else if t >= 1.0 {
                    b
                } else {
                    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
                }
            };
            if t0 > 0.0 {
                finish(&mut cur, &mut out);
                phase.skip(len * t0);
            }
            let (mut p, end) = (lerp(t0), lerp(t1));
            if phase.on() && cur.is_empty() {
                cur.push(pt(p));
            }
            let mut seg = len * (t1 - t0);
            while seg > 0.0 {
                if seg < phase.left {
                    phase.left -= seg;
                    if phase.on() {
                        cur.push(pt(end));
                    }
                    break;
                }
                let m = (p.0 + (end.0 - p.0) * phase.left / seg, p.1 + (end.1 - p.1) * phase.left / seg);
                if phase.on() {
                    cur.push(pt(m));
                    finish(&mut cur, &mut out);
                    if out.len() > max {
                        return None;
                    }
                } else {
                    cur = vec![pt(m)];
                }
                let rest = seg - phase.left;
                if phase.left > 0.0 && rest >= seg {
                    // Too long to make progress in: leave the rest undrawn.
                    break;
                }
                seg = rest;
                p = m;
                phase.next();
            }
            if t1 < 1.0 {
                finish(&mut cur, &mut out);
                phase.skip(len * (1.0 - t1));
            }
        }
        if phase.on() {
            finish(&mut cur, &mut out);
        }
    }
    (out.len() <= max).then_some(out)
}
