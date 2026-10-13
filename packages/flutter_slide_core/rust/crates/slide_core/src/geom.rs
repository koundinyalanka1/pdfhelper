//! Shape outlines: DrawingML preset shapes (the common ones, drawn here)
//! and custom geometry with its guide formulas.

use std::collections::HashMap;
use std::f64::consts::PI;

use doc_xml::{ns, Element};

use crate::scene::{Cmd, Path};

/// Builds paths in shape coordinates.
struct Pen {
    cmds: Vec<Cmd>,
    x: f64,
    y: f64,
}

impl Pen {
    fn new() -> Pen {
        Pen { cmds: Vec::new(), x: 0.0, y: 0.0 }
    }
    fn m(&mut self, x: f64, y: f64) -> &mut Self {
        self.cmds.push(Cmd::Move(x as f32, y as f32));
        self.x = x;
        self.y = y;
        self
    }
    fn l(&mut self, x: f64, y: f64) -> &mut Self {
        self.cmds.push(Cmd::Line(x as f32, y as f32));
        self.x = x;
        self.y = y;
        self
    }
    fn c(&mut self, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) -> &mut Self {
        self.cmds.push(Cmd::Cubic(x1 as f32, y1 as f32, x2 as f32, y2 as f32, x as f32, y as f32));
        self.x = x;
        self.y = y;
        self
    }
    fn q(&mut self, x1: f64, y1: f64, x: f64, y: f64) -> &mut Self {
        let (x0, y0) = (self.x, self.y);
        self.c(x0 + 2.0 / 3.0 * (x1 - x0), y0 + 2.0 / 3.0 * (y1 - y0), x + 2.0 / 3.0 * (x1 - x), y + 2.0 / 3.0 * (y1 - y), x, y)
    }
    fn z(&mut self) -> &mut Self {
        self.cmds.push(Cmd::Close);
        self
    }
    fn poly(&mut self, pts: &[(f64, f64)]) -> &mut Self {
        if let Some((&(x, y), rest)) = pts.split_first() {
            self.m(x, y);
            for &(x, y) in rest {
                self.l(x, y);
            }
            self.z();
        }
        self
    }
    /// An elliptical arc from the current point, DrawingML style: radii,
    /// start angle and sweep in degrees (clockwise, y down).
    fn arc(&mut self, wr: f64, hr: f64, st: f64, sw: f64) -> &mut Self {
        if wr <= 0.0 || hr <= 0.0 {
            return self;
        }
        let param = |deg: f64| {
            let a = deg.to_radians();
            (wr * a.sin()).atan2(hr * a.cos())
        };
        let t0 = param(st);
        let cx = self.x - wr * t0.cos();
        let cy = self.y - hr * t0.sin();
        let mut dt = if sw.abs() >= 360.0 {
            2.0 * PI * sw.signum()
        } else {
            let mut d = param(st + sw) - t0;
            if sw > 0.0 && d < 0.0 {
                d += 2.0 * PI;
            }
            if sw < 0.0 && d > 0.0 {
                d -= 2.0 * PI;
            }
            d
        };
        if dt.abs() < 1e-9 {
            return self;
        }
        let n = (dt.abs() / (PI / 2.0)).ceil().max(1.0) as usize;
        dt /= n as f64;
        let k = 4.0 / 3.0 * (dt / 4.0).tan();
        let mut t = t0;
        for _ in 0..n {
            let (s1, c1) = t.sin_cos();
            let (s2, c2) = (t + dt).sin_cos();
            self.c(
                cx + wr * (c1 - k * s1),
                cy + hr * (s1 + k * c1),
                cx + wr * (c2 + k * s2),
                cy + hr * (s2 - k * c2),
                cx + wr * c2,
                cy + hr * s2,
            );
            t += dt;
        }
        self
    }
    fn ellipse(&mut self, x: f64, y: f64, w: f64, h: f64) -> &mut Self {
        self.m(x + w, y + h / 2.0);
        self.arc(w / 2.0, h / 2.0, 0.0, 360.0);
        self.z()
    }
    fn round_rect(&mut self, x: f64, y: f64, w: f64, h: f64, r: [f64; 4]) -> &mut Self {
        // Radii: top-left, top-right, bottom-right, bottom-left.
        self.m(x + r[0], y);
        self.l(x + w - r[1], y);
        if r[1] > 0.0 {
            self.arc(r[1], r[1], 270.0, 90.0);
        }
        self.l(x + w, y + h - r[2]);
        if r[2] > 0.0 {
            self.arc(r[2], r[2], 0.0, 90.0);
        }
        self.l(x + r[3], y + h);
        if r[3] > 0.0 {
            self.arc(r[3], r[3], 90.0, 90.0);
        }
        self.l(x, y + r[0]);
        if r[0] > 0.0 {
            self.arc(r[0], r[0], 180.0, 90.0);
        }
        self.z()
    }
    fn take(&mut self) -> Path {
        Path {
            cmds: std::mem::take(&mut self.cmds),
            fill: true,
            stroke: true,
            shade: None,
        }
    }
}

fn adj(a: &HashMap<String, f64>, name: &str, default: f64) -> f64 {
    a.get(name).copied().unwrap_or(default)
}

/// A regular star or polygon's points.
fn star(w: f64, h: f64, n: usize, inner: Option<f64>) -> Vec<(f64, f64)> {
    let (cx, cy) = (w / 2.0, h / 2.0);
    let mut pts = Vec::new();
    let steps = if inner.is_some() { n * 2 } else { n };
    for i in 0..steps {
        let a = -PI / 2.0 + i as f64 * 2.0 * PI / steps as f64;
        let r = match inner {
            Some(f) if i % 2 == 1 => f,
            _ => 1.0,
        };
        pts.push((cx + cx * r * a.cos(), cy + cy * r * a.sin()));
    }
    pts
}

/// The outline of preset shape `name` in a `w` x `h` box, with adjust
/// values (in the preset's own units, mostly 1/100000).
pub fn preset(name: &str, w: f64, h: f64, a: &HashMap<String, f64>) -> Vec<Path> {
    let ss = w.min(h);
    let mut p = Pen::new();
    let mut extra: Vec<Path> = Vec::new();
    match name {
        "rect" | "flowChartProcess" | "textBox" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
        }
        "roundRect" | "flowChartAlternateProcess" => {
            let r = ss * adj(a, "adj", 16667.0) / 100000.0;
            p.round_rect(0.0, 0.0, w, h, [r; 4]);
        }
        "flowChartTerminator" => {
            p.round_rect(0.0, 0.0, w, h, [ss / 2.0; 4]);
        }
        "round1Rect" => {
            let r = ss * adj(a, "adj", 16667.0) / 100000.0;
            p.round_rect(0.0, 0.0, w, h, [0.0, r, 0.0, 0.0]);
        }
        "round2SameRect" => {
            let r = ss * adj(a, "adj1", 16667.0) / 100000.0;
            p.round_rect(0.0, 0.0, w, h, [r, r, 0.0, 0.0]);
        }
        "round2DiagRect" => {
            let r = ss * adj(a, "adj1", 16667.0) / 100000.0;
            p.round_rect(0.0, 0.0, w, h, [r, 0.0, r, 0.0]);
        }
        "snip1Rect" => {
            let s = ss * adj(a, "adj", 16667.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w - s, 0.0), (w, s), (w, h), (0.0, h)]);
        }
        "snip2SameRect" => {
            let s = ss * adj(a, "adj1", 16667.0) / 100000.0;
            p.poly(&[(s, 0.0), (w - s, 0.0), (w, s), (w, h), (0.0, h), (0.0, s)]);
        }
        "snip2DiagRect" => {
            let s = ss * adj(a, "adj2", 16667.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w - s, 0.0), (w, s), (w, h), (s, h), (0.0, h - s)]);
        }
        "ellipse" | "flowChartConnector" => {
            p.ellipse(0.0, 0.0, w, h);
        }
        "triangle" | "flowChartExtract" => {
            let x = w * adj(a, "adj", 50000.0) / 100000.0;
            p.poly(&[(x, 0.0), (w, h), (0.0, h)]);
        }
        "flowChartMerge" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w / 2.0, h)]);
        }
        "rtTriangle" => {
            p.poly(&[(0.0, 0.0), (w, h), (0.0, h)]);
        }
        "diamond" | "flowChartDecision" => {
            p.poly(&[(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]);
        }
        "parallelogram" | "flowChartInputOutput" => {
            let d = if name == "parallelogram" { ss * adj(a, "adj", 25000.0) / 100000.0 } else { w / 5.0 };
            p.poly(&[(d, 0.0), (w, 0.0), (w - d, h), (0.0, h)]);
        }
        "trapezoid" | "flowChartManualOperation" => {
            let d = if name == "trapezoid" { ss * adj(a, "adj", 25000.0) / 100000.0 } else { w / 5.0 };
            if name == "trapezoid" {
                p.poly(&[(d, 0.0), (w - d, 0.0), (w, h), (0.0, h)]);
            } else {
                p.poly(&[(0.0, 0.0), (w, 0.0), (w - d, h), (d, h)]);
            }
        }
        "pentagon" => {
            p.poly(&star(w, h, 5, None));
        }
        "hexagon" | "flowChartPreparation" => {
            let d = if name == "hexagon" { ss * adj(a, "adj", 25000.0) / 100000.0 } else { w / 5.0 };
            p.poly(&[(d, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (d, h), (0.0, h / 2.0)]);
        }
        "heptagon" => {
            p.poly(&star(w, h, 7, None));
        }
        "octagon" => {
            let d = ss * adj(a, "adj", 29289.0) / 100000.0;
            p.poly(&[(d, 0.0), (w - d, 0.0), (w, d), (w, h - d), (w - d, h), (d, h), (0.0, h - d), (0.0, d)]);
        }
        "decagon" => {
            p.poly(&star(w, h, 10, None));
        }
        "dodecagon" => {
            p.poly(&star(w, h, 12, None));
        }
        "star4" => {
            p.poly(&star(w, h, 4, Some(adj(a, "adj", 12500.0) / 50000.0)));
        }
        "star5" => {
            p.poly(&star(w, h, 5, Some(adj(a, "adj", 19098.0) / 50000.0)));
        }
        "star6" => {
            p.poly(&star(w, h, 6, Some(adj(a, "adj", 28868.0) / 50000.0)));
        }
        "star7" | "star8" | "star10" | "star12" | "star16" | "star24" | "star32" => {
            let n: usize = name[4..].parse().unwrap_or(8);
            p.poly(&star(w, h, n, Some(adj(a, "adj", 37500.0) / 50000.0)));
        }
        "irregularSeal1" | "irregularSeal2" => {
            p.poly(&star(w, h, 12, Some(0.6)));
        }
        "plus" => {
            let d = ss * adj(a, "adj", 25000.0) / 100000.0;
            p.poly(&[
                (d, 0.0),
                (w - d, 0.0),
                (w - d, d),
                (w, d),
                (w, h - d),
                (w - d, h - d),
                (w - d, h),
                (d, h),
                (d, h - d),
                (0.0, h - d),
                (0.0, d),
                (d, d),
            ]);
        }
        "rightArrow" | "leftArrow" | "upArrow" | "downArrow" => {
            let horizontal = name == "rightArrow" || name == "leftArrow";
            let (len, thick) = if horizontal { (w, h) } else { (h, w) };
            let shaft = thick * adj(a, "adj1", 50000.0) / 100000.0;
            let head = (ss * adj(a, "adj2", 50000.0) / 100000.0).min(len);
            let s0 = (thick - shaft) / 2.0;
            // Pointing right along x, then mapped.
            let pts = [
                (0.0, s0),
                (len - head, s0),
                (len - head, 0.0),
                (len, thick / 2.0),
                (len - head, thick),
                (len - head, s0 + shaft),
                (0.0, s0 + shaft),
            ];
            let mapped: Vec<(f64, f64)> = pts
                .iter()
                .map(|&(u, v)| match name {
                    "rightArrow" => (u, v),
                    "leftArrow" => (w - u, v),
                    "downArrow" => (v, u),
                    _ => (v, h - u),
                })
                .collect();
            p.poly(&mapped);
        }
        "leftRightArrow" | "upDownArrow" => {
            let horizontal = name == "leftRightArrow";
            let (len, thick) = if horizontal { (w, h) } else { (h, w) };
            let shaft = thick * adj(a, "adj1", 50000.0) / 100000.0;
            let head = (ss * adj(a, "adj2", 50000.0) / 100000.0).min(len / 2.0);
            let s0 = (thick - shaft) / 2.0;
            let pts = [
                (0.0, thick / 2.0),
                (head, 0.0),
                (head, s0),
                (len - head, s0),
                (len - head, 0.0),
                (len, thick / 2.0),
                (len - head, thick),
                (len - head, s0 + shaft),
                (head, s0 + shaft),
                (head, thick),
            ];
            let mapped: Vec<(f64, f64)> = pts.iter().map(|&(u, v)| if horizontal { (u, v) } else { (v, u) }).collect();
            p.poly(&mapped);
        }
        "chevron" => {
            let d = (ss * adj(a, "adj", 50000.0) / 100000.0).min(w);
            p.poly(&[(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h), (d, h / 2.0)]);
        }
        "homePlate" => {
            let d = (ss * adj(a, "adj", 50000.0) / 100000.0).min(w);
            p.poly(&[(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h)]);
        }
        "flowChartOffpageConnector" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h * 0.8), (w / 2.0, h), (0.0, h * 0.8)]);
        }
        "donut" => {
            let d = ss * adj(a, "adj", 25000.0) / 100000.0;
            p.ellipse(0.0, 0.0, w, h);
            // The hole, the other way round.
            p.m(w - d, h / 2.0);
            p.arc(w / 2.0 - d, h / 2.0 - d, 0.0, -360.0);
            p.z();
        }
        "noSmoking" => {
            p.ellipse(0.0, 0.0, w, h);
        }
        "frame" => {
            let d = ss * adj(a, "adj1", 12500.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
            p.poly(&[(d, d), (d, h - d), (w - d, h - d), (w - d, d)]);
        }
        "can" | "flowChartMagneticDisk" => {
            let e = (ss * adj(a, "adj", 25000.0) / 100000.0).min(h / 2.0);
            p.m(0.0, e / 2.0);
            p.arc(w / 2.0, e / 2.0, 180.0, 180.0);
            p.l(w, h - e / 2.0);
            p.arc(w / 2.0, e / 2.0, 0.0, 180.0);
            p.z();
            let mut top = Pen::new();
            top.ellipse(0.0, 0.0, w, e);
            let mut t = top.take();
            t.shade = Some("lighten".into());
            extra.push(t);
        }
        "cube" => {
            let d = ss * adj(a, "adj", 25000.0) / 100000.0;
            p.poly(&[(0.0, d), (w - d, d), (w - d, h), (0.0, h)]);
            let mut top = Pen::new();
            top.poly(&[(0.0, d), (d, 0.0), (w, 0.0), (w - d, d)]);
            let mut t = top.take();
            t.shade = Some("lighten".into());
            extra.push(t);
            let mut side = Pen::new();
            side.poly(&[(w - d, d), (w, 0.0), (w, h - d), (w - d, h)]);
            let mut s = side.take();
            s.shade = Some("darken".into());
            extra.push(s);
        }
        "heart" => {
            p.m(w / 2.0, h / 4.0);
            p.c(w * 0.6, -h / 12.0, w * 1.15, h / 6.0, w / 2.0, h);
            p.c(-w * 0.15, h / 6.0, w * 0.4, -h / 12.0, w / 2.0, h / 4.0);
            p.z();
        }
        "lightningBolt" => {
            let pts: Vec<(f64, f64)> = [
                (0.39, 0.0),
                (0.6, 0.27),
                (0.52, 0.31),
                (0.81, 0.58),
                (0.73, 0.62),
                (1.0, 1.0),
                (0.47, 0.68),
                (0.56, 0.64),
                (0.18, 0.44),
                (0.29, 0.39),
                (0.0, 0.18),
            ]
            .iter()
            .map(|&(u, v)| (u * w, v * h))
            .collect();
            p.poly(&pts);
        }
        "moon" => {
            let d = w * adj(a, "adj", 50000.0) / 100000.0;
            p.m(w, 0.0);
            p.arc(w, h / 2.0, 270.0, -180.0);
            p.arc(w - d, h / 2.0, 90.0, 180.0);
            p.z();
        }
        "cloud" | "cloudCallout" => {
            // Puffs around an ellipse.
            let (cx, cy) = (w / 2.0, h / 2.0);
            let n = 9;
            let mut pts = Vec::new();
            for i in 0..n {
                let t = 2.0 * PI * i as f64 / n as f64;
                pts.push((cx + cx * 0.8 * t.cos(), cy + cy * 0.75 * t.sin()));
            }
            p.ellipse(w * 0.15, h * 0.15, w * 0.7, h * 0.7);
            for (x, y) in pts {
                let (rw, rh) = (w * 0.18, h * 0.2);
                p.ellipse(x - rw, y - rh, rw * 2.0, rh * 2.0);
            }
        }
        "sun" => {
            p.ellipse(w * 0.25, h * 0.25, w * 0.5, h * 0.5);
            for i in 0..8 {
                let t = 2.0 * PI * i as f64 / 8.0;
                let (c, s) = (t.cos(), t.sin());
                let tip = (w / 2.0 + w / 2.0 * c, h / 2.0 + h / 2.0 * s);
                let side = 0.09;
                let b1 = (w / 2.0 + w * 0.33 * (t - side).cos(), h / 2.0 + h * 0.33 * (t - side).sin());
                let b2 = (w / 2.0 + w * 0.33 * (t + side).cos(), h / 2.0 + h * 0.33 * (t + side).sin());
                p.poly(&[b1, tip, b2]);
            }
        }
        "smileyFace" => {
            p.ellipse(0.0, 0.0, w, h);
            let mut eyes = Pen::new();
            eyes.ellipse(w * 0.3, h * 0.3, w * 0.1, h * 0.1);
            eyes.ellipse(w * 0.6, h * 0.3, w * 0.1, h * 0.1);
            let mut e = eyes.take();
            e.shade = Some("darken".into());
            extra.push(e);
            let mut mouth = Pen::new();
            mouth.m(w * 0.25, h * 0.65);
            mouth.q(w / 2.0, h * 0.85, w * 0.75, h * 0.65);
            let mut m = mouth.take();
            m.fill = false;
            extra.push(m);
        }
        "arc" => {
            let st = adj(a, "adj1", 16200000.0) / 60000.0;
            let en = adj(a, "adj2", 0.0) / 60000.0;
            let sw = (en - st).rem_euclid(360.0);
            let t = st.to_radians();
            let param = (w / 2.0 * t.sin()).atan2(h / 2.0 * t.cos());
            p.m(w / 2.0 + w / 2.0 * param.cos(), h / 2.0 + h / 2.0 * param.sin());
            p.arc(w / 2.0, h / 2.0, st, sw);
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "blockArc" | "chord" | "pie" | "pieWedge" => {
            p.m(w / 2.0, h / 2.0);
            let st = adj(a, "adj1", 10800000.0) / 60000.0;
            let en = adj(a, "adj2", 0.0) / 60000.0;
            let sw = (en - st).rem_euclid(360.0);
            let t = st.to_radians();
            let param = (w / 2.0 * t.sin()).atan2(h / 2.0 * t.cos());
            p.l(w / 2.0 + w / 2.0 * param.cos(), h / 2.0 + h / 2.0 * param.sin());
            p.arc(w / 2.0, h / 2.0, st, sw);
            p.z();
        }
        "flowChartDocument" => {
            p.m(0.0, 0.0);
            p.l(w, 0.0);
            p.l(w, h * 0.83);
            p.c(w * 0.75, h * 0.68, w * 0.25, h * 1.08, 0.0, h * 0.9);
            p.z();
        }
        "flowChartMultidocument" => {
            p.poly(&[(w * 0.1, 0.0), (w, 0.0), (w, h * 0.7), (w * 0.1, h * 0.7)]);
            p.m(0.0, h * 0.2);
            p.l(w * 0.9, h * 0.2);
            p.l(w * 0.9, h * 0.83);
            p.c(w * 0.7, h * 0.7, w * 0.2, h * 1.05, 0.0, h * 0.9);
            p.z();
        }
        "flowChartPredefinedProcess" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
            let mut lines = Pen::new();
            lines.m(w / 8.0, 0.0).l(w / 8.0, h).m(w * 7.0 / 8.0, 0.0).l(w * 7.0 / 8.0, h);
            let mut l = lines.take();
            l.fill = false;
            extra.push(l);
        }
        "flowChartInternalStorage" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
            let mut lines = Pen::new();
            lines.m(w / 8.0, 0.0).l(w / 8.0, h).m(0.0, h / 8.0).l(w, h / 8.0);
            let mut l = lines.take();
            l.fill = false;
            extra.push(l);
        }
        "flowChartDelay" => {
            p.m(0.0, 0.0);
            p.l(w / 2.0, 0.0);
            p.arc(w / 2.0, h / 2.0, 270.0, 180.0);
            p.l(0.0, h);
            p.z();
        }
        "flowChartPunchedCard" => {
            p.poly(&[(w * 0.2, 0.0), (w, 0.0), (w, h), (0.0, h), (0.0, h * 0.2)]);
        }
        "flowChartSort" | "flowChartCollate" => {
            p.poly(&[(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]);
        }
        "flowChartSummingJunction" | "flowChartOr" => {
            p.ellipse(0.0, 0.0, w, h);
        }
        "plaque" => {
            let d = ss * adj(a, "adj", 16667.0) / 100000.0;
            p.m(0.0, d);
            p.arc(d, d, 90.0, -90.0);
            p.l(w - d, 0.0);
            p.arc(d, d, 180.0, -90.0);
            p.l(w, h - d);
            p.arc(d, d, 270.0, -90.0);
            p.l(d, h);
            p.arc(d, d, 0.0, -90.0);
            p.z();
        }
        "teardrop" => {
            p.m(0.0, h / 2.0);
            p.arc(w / 2.0, h / 2.0, 180.0, 90.0);
            p.l(w, 0.0);
            p.l(w, h / 2.0);
            p.arc(w / 2.0, h / 2.0, 0.0, 180.0);
            p.z();
        }
        "halfFrame" => {
            let d = ss * adj(a, "adj1", 33333.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w, 0.0), (w - d, d), (d, d), (d, h - d), (0.0, h)]);
        }
        "corner" => {
            let d = ss * adj(a, "adj1", 50000.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (d, 0.0), (d, h - d), (w, h - d), (w, h), (0.0, h)]);
        }
        "diagStripe" => {
            let d = ss * adj(a, "adj", 50000.0) / 100000.0;
            p.poly(&[(0.0, d), (d, 0.0), (w, 0.0), (0.0, h)]);
        }
        "wedgeRectCallout" | "wedgeRoundRectCallout" | "wedgeEllipseCallout" | "borderCallout1" | "callout1" | "accentCallout1" => {
            let tx = w / 2.0 + w * adj(a, "adj1", -20833.0) / 100000.0;
            let ty = h / 2.0 + h * adj(a, "adj2", 62500.0) / 100000.0;
            match name {
                "wedgeEllipseCallout" => {
                    p.ellipse(0.0, 0.0, w, h);
                }
                "wedgeRoundRectCallout" => {
                    p.round_rect(0.0, 0.0, w, h, [ss * 0.16667; 4]);
                }
                _ => {
                    p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
                }
            }
            if name.starts_with("wedge") {
                // The pointer, from the side nearest to its tip.
                let (bx, by, ex, ey) = if ty > h {
                    (w * 0.35, h * 0.9, w * 0.55, h * 0.9)
                } else if ty < 0.0 {
                    (w * 0.35, h * 0.1, w * 0.55, h * 0.1)
                } else if tx < 0.0 {
                    (w * 0.1, h * 0.35, w * 0.1, h * 0.6)
                } else {
                    (w * 0.9, h * 0.35, w * 0.9, h * 0.6)
                };
                let mut tail = Pen::new();
                tail.poly(&[(bx, by), (tx, ty), (ex, ey)]);
                extra.push(tail.take());
            }
        }
        "line" | "straightConnector1" => {
            p.m(0.0, 0.0).l(w, h);
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "bentConnector2" => {
            p.m(0.0, 0.0).l(w, 0.0).l(w, h);
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "bentConnector3" | "bentConnector4" | "bentConnector5" => {
            let x = w * adj(a, "adj1", 50000.0) / 100000.0;
            p.m(0.0, 0.0).l(x, 0.0).l(x, h).l(w, h);
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "curvedConnector2" | "curvedConnector3" | "curvedConnector4" | "curvedConnector5" => {
            p.m(0.0, 0.0).c(w / 2.0, 0.0, w / 2.0, h, w, h);
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "leftBracket" | "rightBracket" | "leftBrace" | "rightBrace" | "bracketPair" | "bracePair" => {
            let left = name.starts_with("left") || name.ends_with("Pair");
            let right = name.starts_with("right") || name.ends_with("Pair");
            let d = w.min(h * 0.1);
            if left {
                p.m(d, 0.0).q(0.0, 0.0, 0.0, d).l(0.0, h - d).q(0.0, h, d, h);
            }
            if right {
                p.m(w - d, 0.0).q(w, 0.0, w, d).l(w, h - d).q(w, h, w - d, h);
            }
            let mut path = p.take();
            path.fill = false;
            return vec![path];
        }
        "upArrowCallout" | "downArrowCallout" | "leftArrowCallout" | "rightArrowCallout" => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
        }
        "notchedRightArrow" | "stripedRightArrow" => {
            let shaft = h * 0.5;
            let head = (ss * 0.5).min(w);
            let s0 = (h - shaft) / 2.0;
            let notch = if name == "notchedRightArrow" { h * 0.25 } else { 0.0 };
            p.poly(&[(0.0, s0), (w - head, s0), (w - head, 0.0), (w, h / 2.0), (w - head, h), (w - head, s0 + shaft), (0.0, s0 + shaft), (notch, h / 2.0)]);
        }
        "curvedRightArrow" | "curvedLeftArrow" | "curvedUpArrow" | "curvedDownArrow" | "uturnArrow" | "circularArrow" | "bentArrow" | "bentUpArrow" => {
            // Drawn as their plain arrow.
            return preset("rightArrow", w, h, &HashMap::new());
        }
        "quadArrow" | "leftRightUpArrow" => {
            let t = ss * 0.11;
            let hd = ss * 0.22;
            let (cx, cy) = (w / 2.0, h / 2.0);
            p.poly(&[
                (cx, 0.0),
                (cx + hd, hd),
                (cx + t, hd),
                (cx + t, cy - t),
                (w - hd, cy - t),
                (w - hd, cy - hd),
                (w, cy),
                (w - hd, cy + hd),
                (w - hd, cy + t),
                (cx + t, cy + t),
                (cx + t, h - hd),
                (cx + hd, h - hd),
                (cx, h),
                (cx - hd, h - hd),
                (cx - t, h - hd),
                (cx - t, cy + t),
                (hd, cy + t),
                (hd, cy + hd),
                (0.0, cy),
                (hd, cy - hd),
                (hd, cy - t),
                (cx - t, cy - t),
                (cx - t, hd),
                (cx - hd, hd),
            ]);
        }
        "ribbon" | "ribbon2" | "ellipseRibbon" | "ellipseRibbon2" | "verticalScroll" | "horizontalScroll" | "wave" | "doubleWave" => {
            if name.contains("ave") {
                let d = h * 0.1;
                p.m(0.0, d);
                p.c(w / 3.0, -d, w * 2.0 / 3.0, d * 3.0, w, d);
                p.l(w, h - d);
                p.c(w * 2.0 / 3.0, h + d, w / 3.0, h - d * 3.0, 0.0, h - d);
                p.z();
            } else {
                p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
            }
        }
        "foldedCorner" => {
            let d = ss * adj(a, "adj", 16667.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h - d), (w - d, h), (0.0, h)]);
            let mut fold = Pen::new();
            fold.poly(&[(w - d, h), (w - d * 0.8, h - d * 0.8), (w, h - d)]);
            let mut f = fold.take();
            f.shade = Some("darken".into());
            extra.push(f);
        }
        "bevel" => {
            let d = ss * adj(a, "adj", 12500.0) / 100000.0;
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
            let mut inner = Pen::new();
            inner.poly(&[(d, d), (w - d, d), (w - d, h - d), (d, h - d)]);
            let mut i = inner.take();
            i.shade = Some("lighten".into());
            extra.push(i);
        }
        _ => {
            p.poly(&[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]);
        }
    }
    let mut out = vec![p.take()];
    out.extend(extra);
    out
}

/// Guide values: built-ins for the box, then the shape's own guides.
struct Guides {
    vals: HashMap<String, f64>,
}

impl Guides {
    fn new(w: f64, h: f64) -> Guides {
        let mut v = HashMap::new();
        let ss = w.min(h);
        let ls = w.max(h);
        for (k, x) in [
            ("w", w),
            ("h", h),
            ("l", 0.0),
            ("t", 0.0),
            ("r", w),
            ("b", h),
            ("hc", w / 2.0),
            ("vc", h / 2.0),
            ("ss", ss),
            ("ls", ls),
            ("cd2", 10800000.0),
            ("cd4", 5400000.0),
            ("cd8", 2700000.0),
            ("3cd4", 16200000.0),
            ("3cd8", 8100000.0),
            ("5cd8", 13500000.0),
            ("7cd8", 18900000.0),
        ] {
            v.insert(k.to_owned(), x);
        }
        for n in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 16.0, 32.0] {
            v.insert(format!("wd{n}"), w / n);
            v.insert(format!("hd{n}"), h / n);
            v.insert(format!("ssd{n}"), ss / n);
        }
        Guides { vals: v }
    }

    fn get(&self, token: &str) -> f64 {
        token.parse::<f64>().unwrap_or_else(|_| self.vals.get(token).copied().unwrap_or(0.0))
    }

    fn eval(&mut self, name: &str, fmla: &str) {
        let parts: Vec<&str> = fmla.split_whitespace().collect();
        let arg = |i: usize| parts.get(i).map_or(0.0, |t| self.get(t));
        let rad = |v: f64| (v / 60000.0).to_radians();
        let (x, y, z) = (arg(1), arg(2), arg(3));
        let v = match parts.first().copied().unwrap_or("val") {
            "val" => x,
            "*/" => {
                if z == 0.0 {
                    0.0
                } else {
                    x * y / z
                }
            }
            "+-" => x + y - z,
            "+/" => {
                if z == 0.0 {
                    0.0
                } else {
                    (x + y) / z
                }
            }
            "?:" => {
                if x > 0.0 {
                    y
                } else {
                    z
                }
            }
            "abs" => x.abs(),
            "at2" => y.atan2(x).to_degrees() * 60000.0,
            "cat2" => x * z.atan2(y).cos(),
            "sat2" => x * z.atan2(y).sin(),
            "cos" => x * rad(y).cos(),
            "sin" => x * rad(y).sin(),
            "tan" => x * rad(y).tan(),
            "max" => x.max(y),
            "min" => x.min(y),
            "mod" => (x * x + y * y + z * z).sqrt(),
            "pin" => {
                if y < x {
                    x
                } else if y > z {
                    z
                } else {
                    y
                }
            }
            "sqrt" => x.max(0.0).sqrt(),
            _ => 0.0,
        };
        self.vals.insert(name.to_owned(), v);
    }
}

/// The outline of a custom geometry (`a:custGeom`) in a `w` x `h` box.
pub fn custom(geom: &Element, w: f64, h: f64) -> Vec<Path> {
    let mut g = Guides::new(w, h);
    for list in ["avLst", "gdLst"] {
        if let Some(l) = geom.elements().find(|e| e.local() == list) {
            for gd in l.elements().filter(|e| e.local() == "gd") {
                if let (Some(n), Some(f)) = (gd.attr(ns::NONE, "name"), gd.attr(ns::NONE, "fmla")) {
                    g.eval(n, f);
                }
            }
        }
    }
    let mut out = Vec::new();
    let Some(list) = geom.elements().find(|e| e.local() == "pathLst") else { return out };
    for path in list.elements().filter(|e| e.local() == "path") {
        let pw = path.attr(ns::NONE, "w").and_then(|v| v.parse::<f64>().ok()).filter(|v| *v > 0.0);
        let ph = path.attr(ns::NONE, "h").and_then(|v| v.parse::<f64>().ok()).filter(|v| *v > 0.0);
        let sx = pw.map_or(1.0, |pw| w / pw);
        let sy = ph.map_or(1.0, |ph| h / ph);
        let pt = |e: &Element, g: &Guides| -> (f64, f64) {
            let p = e.elements().find(|c| c.local() == "pt").unwrap_or(e);
            (g.get(p.attr(ns::NONE, "x").unwrap_or("0")) * sx, g.get(p.attr(ns::NONE, "y").unwrap_or("0")) * sy)
        };
        let mut pen = Pen::new();
        for c in path.elements() {
            match c.local() {
                "moveTo" => {
                    let (x, y) = pt(c, &g);
                    pen.m(x, y);
                }
                "lnTo" => {
                    let (x, y) = pt(c, &g);
                    pen.l(x, y);
                }
                "cubicBezTo" => {
                    let pts: Vec<(f64, f64)> = c.elements().filter(|e| e.local() == "pt").map(|p| pt(p, &g)).collect();
                    if pts.len() == 3 {
                        pen.c(pts[0].0, pts[0].1, pts[1].0, pts[1].1, pts[2].0, pts[2].1);
                    }
                }
                "quadBezTo" => {
                    let pts: Vec<(f64, f64)> = c.elements().filter(|e| e.local() == "pt").map(|p| pt(p, &g)).collect();
                    if pts.len() == 2 {
                        pen.q(pts[0].0, pts[0].1, pts[1].0, pts[1].1);
                    }
                }
                "arcTo" => {
                    let get = |a: &str| g.get(c.attr(ns::NONE, a).unwrap_or("0"));
                    pen.arc(get("wR") * sx, get("hR") * sy, get("stAng") / 60000.0, get("swAng") / 60000.0);
                }
                "close" => {
                    pen.z();
                }
                _ => {}
            }
        }
        let mut p = pen.take();
        let fill = path.attr(ns::NONE, "fill").unwrap_or("norm");
        p.fill = fill != "none";
        if matches!(fill, "darken" | "darkenLess" | "lighten" | "lightenLess") {
            p.shade = Some(fill.to_owned());
        }
        p.stroke = path.attr(ns::NONE, "stroke").is_none_or(|v| v != "0" && v != "false");
        out.push(p);
    }
    out
}

/// Adjust values of a preset (`a:avLst`).
pub fn adjusts(prst: &Element) -> HashMap<String, f64> {
    let mut out = HashMap::new();
    if let Some(av) = prst.elements().find(|e| e.local() == "avLst") {
        for gd in av.elements().filter(|e| e.local() == "gd") {
            let (Some(n), Some(f)) = (gd.attr(ns::NONE, "name"), gd.attr(ns::NONE, "fmla")) else { continue };
            if let Some(v) = f.strip_prefix("val ").and_then(|v| v.trim().parse::<f64>().ok()) {
                out.insert(n.to_owned(), v);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds(paths: &[Path]) -> (f32, f32, f32, f32) {
        let mut b = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for p in paths {
            for c in &p.cmds {
                let pts: Vec<(f32, f32)> = match *c {
                    Cmd::Move(x, y) | Cmd::Line(x, y) => vec![(x, y)],
                    Cmd::Cubic(a, b, c, d, e, f) => vec![(a, b), (c, d), (e, f)],
                    Cmd::Close => vec![],
                };
                for (x, y) in pts {
                    b = (b.0.min(x), b.1.min(y), b.2.max(x), b.3.max(y));
                }
            }
        }
        b
    }

    #[test]
    fn presets_fill_their_box() {
        for name in ["rect", "roundRect", "ellipse", "triangle", "diamond", "rightArrow", "star5", "hexagon", "chevron", "can"] {
            let (x0, y0, x1, y1) = bounds(&preset(name, 100.0, 50.0, &HashMap::new()));
            assert!(x0 >= -0.5 && y0 >= -0.5 && x1 <= 100.5 && y1 <= 50.5, "{name}: {x0} {y0} {x1} {y1}");
            assert!(x1 - x0 > 90.0 && y1 - y0 > 45.0, "{name}");
        }
    }

    #[test]
    fn custom_geometry_with_guides_and_arcs() {
        let xml = r#"<a:custGeom xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:gdLst><a:gd name="half" fmla="*/ w 1 2"/></a:gdLst><a:pathLst><a:path w="200" h="100"><a:moveTo><a:pt x="0" y="50"/></a:moveTo><a:arcTo wR="100" hR="50" stAng="10800000" swAng="10800000"/><a:lnTo><a:pt x="half" y="100"/></a:lnTo><a:close/></a:path></a:pathLst></a:custGeom>"#;
        let doc = doc_xml::Document::parse_str(xml).unwrap();
        let paths = custom(&doc.root, 400.0, 100.0);
        assert_eq!(paths.len(), 1);
        let (x0, y0, x1, y1) = bounds(&paths);
        assert!((x0 - 0.0).abs() < 0.5 && (x1 - 400.0).abs() < 0.5 && y0 > -0.5 && y1 <= 100.5, "{x0} {y0} {x1} {y1}");
    }
}
