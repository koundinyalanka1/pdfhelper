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

pub struct Canvas {
    pub w: usize,
    pub h: usize,
    /// Premultiplied RGBA, 0..65535.
    px: Vec<[u16; 4]>,
    /// Drawing is limited to this rectangle (x0, y0, x1, y1).
    pub clip: (f32, f32, f32, f32),
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
        Canvas { w, h, px: vec![[0; 4]; w * h], clip: (0.0, 0.0, w as f32, h as f32) }
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

    /// Fill contours (each closed) with a colour.
    pub fn fill(&mut self, contours: &[Vec<Pt>], even_odd: bool, color: Rgba) {
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
        let mut cover = vec![0f32; width + 1];
        let mut active: Vec<usize> = Vec::new();
        let mut next = 0;
        let mut xs: Vec<(f32, i32)> = Vec::new();
        for y in y_start..y_end {
            cover.iter_mut().for_each(|c| *c = 0.0);
            let mut any = false;
            for s in 0..SAMPLES {
                let sy = y as f32 + (s as f32 + 0.5) / SAMPLES as f32;
                while next < edges.len() && edges[next].y0 <= sy {
                    active.push(next);
                    next += 1;
                }
                active.retain(|&i| edges[i].y1 > sy);
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
                            any = true;
                        }
                    }
                }
            }
            if !any {
                continue;
            }
            for (i, c) in cover.iter().take(width).enumerate() {
                if *c > 0.0 {
                    self.blend(x_lo as usize + i, y as usize, color, c.min(1.0));
                }
            }
        }
    }

    /// Stroke polylines `width` wide (at least a pixel), with round joins
    /// and ends; `closed` joins each back to its start.
    pub fn stroke(&mut self, lines: &[Vec<Pt>], closed: bool, width: f32, color: Rgba) {
        let polys = stroke_polygons(lines, closed, width.max(1.0));
        self.fill(&polys, false, color);
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

pub fn circle(c: Pt, r: f32) -> Vec<Pt> {
    let n = ((r * 2.0).ceil() as usize).clamp(8, 64);
    (0..n).map(|i| {
        let t = i as f32 / n as f32 * std::f32::consts::TAU;
        (c.0 + r * t.cos(), c.1 + r * t.sin())
    }).collect()
}

/// The polygons covering a stroke: a quad per segment and a disc at
/// each joint and end.
fn stroke_polygons(lines: &[Vec<Pt>], closed: bool, width: f32) -> Vec<Vec<Pt>> {
    let r = width / 2.0;
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
        if r > 0.75 {
            for p in line {
                out.push(orient(circle(*p, r)));
            }
        } else if n == 1 {
            out.push(orient(circle(line[0], r)));
        }
    }
    out
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

/// Split polylines into dashes: `pattern` alternates on and off lengths.
pub fn dash(lines: &[Vec<Pt>], closed: bool, pattern: &[f32]) -> Vec<Vec<Pt>> {
    if pattern.is_empty() || pattern.iter().sum::<f32>() <= 0.0 {
        return lines.to_vec();
    }
    let mut out = Vec::new();
    for line in lines {
        let mut pts = line.clone();
        if closed && pts.len() > 2 {
            pts.push(pts[0]);
        }
        let (mut k, mut left, mut on) = (0usize, pattern[0], true);
        let mut cur: Vec<Pt> = Vec::new();
        if let Some(p) = pts.first() {
            cur.push(*p);
        }
        for w in pts.windows(2) {
            let (mut a, b) = (w[0], w[1]);
            let mut seg = (b.0 - a.0).hypot(b.1 - a.1);
            while seg > 0.0 {
                if seg < left {
                    left -= seg;
                    if on {
                        cur.push(b);
                    }
                    break;
                }
                let t = left / seg;
                let m = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
                if on {
                    cur.push(m);
                    out.push(std::mem::take(&mut cur));
                } else {
                    cur = vec![m];
                }
                seg -= left;
                a = m;
                on = !on;
                k = (k + 1) % pattern.len();
                left = pattern[k];
            }
        }
        if on && cur.len() > 1 {
            out.push(cur);
        }
    }
    out
}
