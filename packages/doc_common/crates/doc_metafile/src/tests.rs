use super::*;

fn put16(b: &mut Vec<u8>, v: i32) {
    b.extend_from_slice(&(v as i16).to_le_bytes());
}

fn put32(b: &mut Vec<u8>, v: i32) {
    b.extend_from_slice(&v.to_le_bytes());
}

/// A WMF record: function and 16-bit parameters (already reversed).
fn wrec(f: u16, params: &[i32]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, 3 + params.len() as i32);
    r.extend_from_slice(&f.to_le_bytes());
    for p in params {
        put16(&mut r, *p);
    }
    r
}

fn wmf(records: &[Vec<u8>]) -> Vec<u8> {
    let mut b = Vec::new();
    // Placeable header: 0..1000 square, 1000 units an inch.
    b.extend_from_slice(&0x9AC6_CDD7u32.to_le_bytes());
    put16(&mut b, 0);
    for v in [0, 0, 1000, 1000, 1000] {
        put16(&mut b, v);
    }
    put32(&mut b, 0);
    let sum = (0..10).fold(0u16, |s, k| s ^ u16::from_le_bytes([b[2 * k], b[2 * k + 1]]));
    b.extend_from_slice(&sum.to_le_bytes());
    let body: Vec<u8> = records.concat();
    for v in [1, 9, 0x0300] {
        put16(&mut b, v);
    }
    put32(&mut b, (9 + body.len() / 2 + 3) as i32);
    put16(&mut b, 4);
    put32(&mut b, 10);
    put16(&mut b, 0);
    b.extend_from_slice(&body);
    b.extend(wrec(0, &[]));
    b
}

fn at(img: &(u32, u32, Vec<u8>), x: u32, y: u32) -> [u8; 4] {
    let i = ((y * img.0 + x) * 4) as usize;
    [img.2[i], img.2[i + 1], img.2[i + 2], img.2[i + 3]]
}

#[test]
fn draws_wmf_shapes() {
    let red = 0x0000FF;
    let blue = 0xFF0000;
    let b = wmf(&[
        wrec(0x020B, &[0, 0]),
        wrec(0x020C, &[1000, 1000]),
        // A red brush and a null pen, selected; a rectangle over the left
        // half.
        wrec(0x02FC, &[0, red & 0xFFFF, red >> 16, 0]),
        wrec(0x012D, &[0]),
        wrec(0x02FA, &[5, 0, 0, 0, 0]),
        wrec(0x012D, &[1]),
        wrec(0x041B, &[1000, 500, 0, 0]),
        // A blue triangle on the right.
        wrec(0x02FC, &[0, blue & 0xFFFF, blue >> 16, 0]),
        wrec(0x012D, &[2]),
        wrec(0x0324, &[3, 600, 100, 900, 100, 750, 400]),
    ]);
    assert_eq!(kind(&b), Some(Kind::Wmf));
    assert_eq!(size(&b), Some((72.0, 72.0)));
    let img = render(&b, 100, None).unwrap();
    assert_eq!((img.0, img.1), (100, 100));
    assert_eq!(at(&img, 20, 50), [255, 0, 0, 255]);
    assert_eq!(at(&img, 75, 15), [0, 0, 255, 255]);
    // Outside both: transparent.
    assert_eq!(at(&img, 75, 80)[3], 0);
    let png = to_png(&b, 100, None).unwrap();
    assert!(png.starts_with(b"\x89PNG"));
}

/// An EMF record.
fn erec(ty: u32, body: &[i32]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, ty as i32);
    put32(&mut r, 8 + 4 * body.len() as i32);
    for v in body {
        put32(&mut r, *v);
    }
    r
}

fn emf(records: &[Vec<u8>]) -> Vec<u8> {
    // Header: bounds 0..99 px, frame 0..2540 (25.4 mm), a 100 px = 25.4 mm
    // device.
    let mut h = Vec::new();
    put32(&mut h, 1);
    put32(&mut h, 88);
    for v in [0, 0, 99, 99, 0, 0, 2540, 2540] {
        put32(&mut h, v);
    }
    h.extend_from_slice(b" EMF");
    put32(&mut h, 0x10000);
    put32(&mut h, 0);
    put32(&mut h, 0);
    put32(&mut h, 0);
    put32(&mut h, 0);
    put32(&mut h, 0);
    put32(&mut h, 0);
    // The reference device: 1000 px over 254 mm, so the frame is 100 px.
    for v in [1000, 1000, 254, 254] {
        put32(&mut h, v);
    }
    let mut b = h;
    for r in records {
        b.extend_from_slice(r);
    }
    b.extend(erec(14, &[0, 0, 0]));
    b
}

#[test]
fn draws_emf_paths_transforms_and_pens() {
    let green = 0x00FF00;
    let b = emf(&[
        // A green brush, the null pen; an ellipse filling the frame.
        erec(39, &[1, 0, green, 0]),
        erec(37, &[1]),
        erec(37, &[0x8000_0008u32 as i32]),
        erec(42, &[0, 0, 100, 100]),
        // A thick black line across the top, through a world transform
        // that moves it 10 px down.
        erec(38, &[2, 0, 6, 0, 0]),
        erec(37, &[2]),
        erec(35, &[1f32.to_bits() as i32, 0, 0, 1f32.to_bits() as i32, 0, 10f32.to_bits() as i32]),
        erec(27, &[0, 0]),
        erec(54, &[100, 0]),
    ]);
    assert_eq!(kind(&b), Some(Kind::Emf));
    let img = render(&b, 100, None).unwrap();
    // The ellipse's middle is green, its corner empty.
    assert_eq!(at(&img, 50, 50), [0, 255, 0, 255]);
    assert_eq!(at(&img, 2, 98)[3], 0);
    // The line, 6 px thick at y = 10.
    assert_eq!(&at(&img, 50, 10)[..3], &[0, 0, 0]);
    assert_eq!(at(&img, 50, 10)[3], 255);
    assert_eq!(&at(&img, 50, 20)[..3], &[0, 255, 0]);
}

#[test]
fn draws_dib_pictures_and_refuses_other_bytes() {
    // A 2x1 24-bit DIB (blue, red) stretched over the frame.
    let mut bmi = Vec::new();
    for v in [40, 2, 1] {
        put32(&mut bmi, v);
    }
    put16(&mut bmi, 1);
    put16(&mut bmi, 24);
    for _ in 0..6 {
        put32(&mut bmi, 0);
    }
    let bits = vec![255u8, 0, 0, 0, 0, 255, 0, 0];
    let mut r = Vec::new();
    put32(&mut r, 81);
    let size = 80 + bmi.len() + bits.len();
    put32(&mut r, size as i32);
    for v in [0, 0, 99, 99] {
        put32(&mut r, v);
    }
    for v in [0, 0, 0, 0, 2, 1, 80, bmi.len() as i32, 80 + bmi.len() as i32, bits.len() as i32, 0, 0x00CC_0020, 100, 100] {
        put32(&mut r, v);
    }
    r.extend_from_slice(&bmi);
    r.extend_from_slice(&bits);
    let b = emf(&[r]);
    let img = render(&b, 100, None).unwrap();
    assert_eq!(at(&img, 25, 50), [0, 0, 255, 255]);
    assert_eq!(at(&img, 75, 50), [255, 0, 0, 255]);
    assert_eq!(kind(b"PNG not a metafile"), None);
    assert!(render(b"\x89PNG", 100, None).is_none());
}

#[test]
fn draws_the_part_of_a_picture_asked_for() {
    // A 3x3 24-bit DIB, of which the 2x2 from (1, 1) is drawn over the
    // frame: its rows are moved up inside the decoded picture.
    let mut bmi = Vec::new();
    for v in [40, 3, 3] {
        put32(&mut bmi, v);
    }
    put16(&mut bmi, 1);
    put16(&mut bmi, 24);
    for _ in 0..6 {
        put32(&mut bmi, 0);
    }
    // Top to bottom: red green blue, cyan magenta yellow, black white
    // gray; stored bottom row first, in BGR, each row padded to 12 bytes.
    let rows = [[[0, 0, 255], [0, 255, 0], [255, 0, 0]], [[255, 255, 0], [255, 0, 255], [0, 255, 255]], [[0, 0, 0], [255, 255, 255], [128, 128, 128]]];
    let mut bits = Vec::new();
    for row in rows.iter().rev() {
        bits.extend(row.concat());
        bits.extend([0, 0, 0]);
    }
    let mut r = Vec::new();
    put32(&mut r, 81);
    put32(&mut r, (80 + bmi.len() + bits.len()) as i32);
    for v in [0, 0, 99, 99] {
        put32(&mut r, v);
    }
    for v in [0, 0, 1, 1, 2, 2, 80, bmi.len() as i32, 80 + bmi.len() as i32, bits.len() as i32, 0, 0x00CC_0020, 100, 100] {
        put32(&mut r, v);
    }
    r.extend_from_slice(&bmi);
    r.extend_from_slice(&bits);
    let img = render(&emf(&[r]), 100, None).unwrap();
    assert_eq!(at(&img, 25, 25), [255, 0, 255, 255]);
    assert_eq!(at(&img, 75, 25), [255, 255, 0, 255]);
    assert_eq!(at(&img, 25, 75), [255, 255, 255, 255]);
    assert_eq!(at(&img, 75, 75), [128, 128, 128, 255]);
}

/// The dashes' ends, rounded, for comparing.
fn ends(d: &[Vec<raster::Pt>]) -> Vec<((i64, i64), (i64, i64))> {
    let r = |p: raster::Pt| ((p.0 * 100.0).round() as i64, (p.1 * 100.0).round() as i64);
    d.iter().map(|s| (r(s[0]), r(*s.last().unwrap()))).collect()
}

#[test]
fn dashes_outside_the_picture_are_skipped_but_keep_their_place() {
    use raster::dash;
    // A long line across a small picture: clipped, the dashes inside sit
    // exactly where dashing the whole line puts them.
    let line = vec![vec![(-1000.0, 5.0), (40.0, 5.0), (1000.0, 7.0)]];
    let everything = (-1e9, -1e9, 1e9, 1e9);
    let picture = (0.0, 0.0, 100.0, 10.0);
    let all = dash(&line, false, &[3.0, 2.0], everything, usize::MAX).unwrap();
    let inside = dash(&line, false, &[3.0, 2.0], picture, usize::MAX).unwrap();
    assert_eq!(all.len(), 401);
    let wanted: Vec<_> = all.iter().filter(|d| d.iter().any(|p| (0.0..=100.0).contains(&p.0))).cloned().collect();
    // Dashes crossing the edge are cut there; the rest are the same.
    assert_eq!(ends(&inside[1..inside.len() - 1]), ends(&wanted[1..wanted.len() - 1]));
    assert!(inside.len() <= wanted.len() && inside.len() >= wanted.len() - 2);
    // A dash around the corner keeps the corner.
    assert!(inside.iter().any(|d| d.len() == 3 && d[1] == (40.0, 5.0)) == all.iter().any(|d| d.len() == 3 && d[1] == (40.0, 5.0)));
    // Too many: None, so the line is stroked solid.
    assert!(dash(&line, false, &[3.0, 2.0], everything, 400).is_none());
    // A pattern that draws nothing sensible: solid too.
    assert!(dash(&line, false, &[0.0, f32::NAN], everything, usize::MAX).is_none());
    assert!(dash(&line, false, &[], everything, usize::MAX).is_none());
}

#[test]
fn odd_dash_patterns_swap_on_and_off_each_time_round() {
    use raster::dash;
    // On 2, off 1, on 1 | off 2, on 1, off 1: as before, the pattern's
    // second time round is its complement.
    let line = vec![vec![(0.0, 0.0), (12.0, 0.0)]];
    let d = dash(&line, false, &[2.0, 1.0, 1.0], (-1.0, -1.0, 20.0, 1.0), 100).unwrap();
    let xs: Vec<(f32, f32)> = d.iter().map(|s| (s[0].0, s.last().unwrap().0)).collect();
    assert_eq!(xs, vec![(0.0, 2.0), (3.0, 4.0), (6.0, 7.0), (8.0, 10.0), (11.0, 12.0)]);
}

#[test]
fn closed_dashed_shapes_and_huge_lengths() {
    use raster::dash;
    // A closed square, dashed all the way round, back to the start.
    let square = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
    let d = dash(&square, true, &[5.0, 5.0], (-1.0, -1.0, 11.0, 11.0), 100).unwrap();
    assert_eq!(d.len(), 4);
    assert_eq!(*d[3].last().unwrap(), (0.0, 5.0));
    // A line far longer than f32 can count along in steps of one: only
    // the part inside is dashed, a few hundred dots.
    let long = vec![vec![(-4.0e10, 50.0), (4.0e10, 50.0)]];
    let d = dash(&long, false, &[1.0, 1.0], (0.0, 0.0, 600.0, 100.0), 1 << 18).unwrap();
    assert!((295..=305).contains(&d.len()), "{} dots", d.len());
}

#[test]
fn budgets_run_out_once() {
    let mut b = Budget::for_canvas(10, 10);
    assert_eq!(b, Budget { items: raster::MAX_ITEMS, paint: 1 << 20 });
    assert_eq!(Budget::for_canvas(1200, 1200).paint, raster::PAINT_LAYERS * 1200 * 1200);
    assert!(b.take(10) && b.items == raster::MAX_ITEMS - 10);
    assert_eq!(b.room(usize::MAX), (raster::MAX_ITEMS - 10) as usize);
    assert!(!b.take(usize::MAX) && b.items == 0 && b.spent());
    let mut b = Budget { items: 5, paint: 5 };
    assert!(b.paint(5) && b.spent());
    // A render cut short says so, and keeps what it drew.
    let red = 0x0000FF;
    let mut records = vec![wrec(0x02FC, &[0, red & 0xFFFF, red >> 16, 0]), wrec(0x012D, &[0]), wrec(0x02FA, &[5, 0, 0, 0, 0]), wrec(0x012D, &[1])];
    for _ in 0..50 {
        records.push(wrec(0x041B, &[1000, 1000, 0, 0]));
    }
    let b = wmf(&records);
    let mut budget = Budget { items: 1000, paint: 64 * 64 * 3 };
    let img = render_within(&b, 64, None, &mut budget).unwrap();
    assert!(budget.spent());
    assert_eq!(at(&img, 10, 10), [255, 0, 0, 255]);
    let mut plenty = Budget::for_canvas(64, 64);
    assert_eq!(render_within(&b, 64, None, &mut plenty), Some(img));
    assert!(!plenty.spent());
}
