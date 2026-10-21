//! Hostile metafiles: each must draw (or refuse) within 2 s, 256 MB and a
//! 512 KiB stack. Before the budgets these aborted asking for gigabytes or
//! never finished.

mod support;

use support::hostile;

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

/// A WMF with a placeable header framing `frame` (left, top, right,
/// bottom) at 1000 units an inch.
fn wmf(frame: [i32; 4], records: &[Vec<u8>]) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&0x9AC6_CDD7u32.to_le_bytes());
    put16(&mut b, 0);
    for v in frame {
        put16(&mut b, v);
    }
    put16(&mut b, 1000);
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

/// An EMF record from 32-bit values.
fn erec(ty: u32, body: &[i32]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, ty as i32);
    put32(&mut r, 8 + 4 * body.len() as i32);
    for v in body {
        put32(&mut r, *v);
    }
    r
}

/// An EMF record from raw bytes (padded to whole words).
fn erec_bytes(ty: u32, body: &[u8]) -> Vec<u8> {
    let mut r = Vec::new();
    put32(&mut r, ty as i32);
    let len = 8 + body.len().div_ceil(4) * 4;
    put32(&mut r, len as i32);
    r.extend_from_slice(body);
    r.resize(len, 0);
    r
}

/// An EMF framing 0..100 px of a 100 px = 25.4 mm device.
fn emf(records: &[Vec<u8>]) -> Vec<u8> {
    let mut h = Vec::new();
    put32(&mut h, 1);
    put32(&mut h, 88);
    for v in [0, 0, 99, 99, 0, 0, 2540, 2540] {
        put32(&mut h, v);
    }
    h.extend_from_slice(b" EMF");
    for v in [0x10000, 0, 0, 0, 0, 0, 0] {
        put32(&mut h, v);
    }
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

/// Pixels with any ink.
fn inked(img: &(u32, u32, Vec<u8>)) -> usize {
    img.2.chunks_exact(4).filter(|p| p[3] > 0).count()
}

#[test]
fn a_dotted_line_across_a_huge_window_draws_its_dots() {
    // 86 bytes: a one-unit frame, a dotted pen, and one line from corner
    // to corner of the 16-bit plane: 111 million pixels long at 1200 px.
    // Dashing it in f32 never ended (the length stopped shrinking) and
    // asked for 1.6 GB of dashes.
    let b = wmf(
        [0, 0, 1, 1],
        &[wrec(0x02FA, &[2, 0, 0, 0, 0]), wrec(0x012D, &[0]), wrec(0x0325, &[2, -32768, -32768, 32767, 32767])],
    );
    assert_eq!(b.len(), 86);
    let run = hostile("dotted WMF", move || doc_metafile::render(&b, 1200, None));
    let img = run.value.expect("the dots are drawn");
    assert_eq!((img.0, img.1), (1200, 1200));
    // The line crosses the canvas from corner to corner, dotted: along the
    // diagonal, inked pixels alternate with faint ones from end to end.
    let alpha = |i: usize| img.2[(i * 1200 + i) * 4 + 3];
    for part in [0..100, 550..650, 1100..1200] {
        let dark = part.clone().filter(|&i| alpha(i) > 200).count();
        let faint = part.clone().filter(|&i| alpha(i) < 100).count();
        assert!(dark >= 10 && faint >= 25, "{part:?}: {dark} dark, {faint} faint");
    }
}

#[test]
fn emf_point_counts_stop_at_the_end_of_their_record() {
    // 196 bytes: a wide pen and a PolyPolygon16 whose four counts each
    // claim a million points the record does not have. Every point
    // became a disc of the pen's width: gigabytes.
    let mut poly = Vec::new();
    for v in [0, 0, 99, 99, 4, -1] {
        put32(&mut poly, v);
    }
    for _ in 0..4 {
        put32(&mut poly, -1);
    }
    let b = emf(&[erec(38, &[1, 0, 4, 0, 0xFF]), erec(37, &[1]), erec_bytes(91, &poly)]);
    assert_eq!(b.len(), 196);
    let run = hostile("196-byte EMF", move || doc_metafile::render(&b, 1200, None));
    assert!(run.peak < 64 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn emf_polypolygon16_with_more_polygons_than_bytes() {
    // nPolys 0xFFFFFFFF with counts that run past the record; and the
    // single-polyline records with counts of 0xFFFFFFFF.
    let mut poly = Vec::new();
    for v in [0, 0, 99, 99, -1, -1] {
        put32(&mut poly, v);
    }
    for _ in 0..4 {
        put32(&mut poly, 0x00FF_FFFF);
    }
    let mut records = vec![erec_bytes(91, &poly), erec_bytes(90, &poly)];
    for ty in [85, 86, 87, 88, 89] {
        records.push(erec(ty, &[0, 0, 99, 99, -1, 10, 10, 90, 90]));
    }
    let b = emf(&records);
    let run = hostile("EMF PolyPolygon16", move || doc_metafile::render(&b, 1200, None));
    assert!(run.peak < 64 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn wmf_polypolygon_counts_stop_at_the_end_of_their_record() {
    // 4,096 polygons of 65,535 points claimed by an 8 KB record that has
    // none of them: 4.3 GB.
    let mut params = vec![4096];
    params.extend(std::iter::repeat_n(-1, 4096));
    let b = wmf([0, 0, 1000, 1000], &[wrec(0x0538, &params)]);
    let run = hostile("WMF PolyPolygon", move || doc_metafile::render(&b, 1200, None));
    assert!(run.peak < 64 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn too_many_dashes_stroke_the_line_solid() {
    // 4,000 points zigzagging across the picture with a dotted pen: three
    // million dots, as many polygons. Past the cap the line is solid.
    let mut body = Vec::new();
    for v in [0, 0, 99, 99, 4000] {
        put32(&mut body, v);
    }
    for k in 0..4000 {
        put16(&mut body, if k % 2 == 0 { 0 } else { 99 });
        put16(&mut body, (k % 97) + 1);
    }
    let dotted = emf(&[erec(38, &[1, 2, 0, 0, 0]), erec(37, &[1]), erec_bytes(87, &body)]);
    let solid = emf(&[erec(38, &[1, 0, 0, 0, 0]), erec(37, &[1]), erec_bytes(87, &body)]);
    let run = hostile("dotted zigzag", move || (doc_metafile::render(&dotted, 600, None), doc_metafile::render(&solid, 600, None)));
    let (dotted, solid) = run.value;
    let dotted = dotted.expect("drawn");
    assert!(inked(&dotted) > 100_000, "{} pixels inked", inked(&dotted));
    assert!(dotted == solid.unwrap(), "drawn as the solid pen draws it");
}

#[test]
fn curves_in_an_open_path_stop_at_the_budget() {
    // A path that is never drawn, fed long Bézier curves: each 12-byte
    // curve made 200 points, so the path grew a hundred times faster than
    // the file.
    let mut records = vec![erec(59, &[])];
    let mut curve = Vec::new();
    for v in [0, 0, 99, 99, 3 * 2000] {
        put32(&mut curve, v);
    }
    for k in 0..2000 {
        for (x, y) in [(-30000, -30000), (30000, 30000), (-30000 + k, 30000)] {
            put16(&mut curve, x);
            put16(&mut curve, y);
        }
    }
    let rec = erec_bytes(88, &curve);
    for _ in 0..40 {
        records.push(rec.clone());
    }
    let b = emf(&records);
    let run = hostile("open path", move || doc_metafile::render(&b, 100, None));
    assert!(run.peak < 128 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn painting_stops_at_the_budget_and_keeps_what_was_drawn() {
    // 100,000 rectangles over the whole picture: past the paint budget the
    // rest are skipped and the picture so far comes back.
    let mut records = vec![erec(39, &[1, 0, 0x0000FF, 0]), erec(37, &[1]), erec(37, &[0x8000_0008u32 as i32])];
    let rect = erec(43, &[0, 0, 100, 100]);
    for _ in 0..100_000 {
        records.push(rect.clone());
    }
    let b = emf(&records);
    let run = hostile("100,000 rectangles", move || doc_metafile::render(&b, 200, None));
    let img = run.value.expect("drawn");
    assert_eq!(&img.2[..4], &[255, 0, 0, 255]);
}

#[test]
fn bit_field_masks_of_all_ones() {
    // A 32-bit BI_BITFIELDS picture whose masks are 0xFFFFFFFF: scaling
    // the field to 0..255 overflowed 32 bits.
    let mut bmi = Vec::new();
    for v in [40, 1, 1] {
        put32(&mut bmi, v);
    }
    put16(&mut bmi, 1);
    put16(&mut bmi, 32);
    put32(&mut bmi, 3);
    for _ in 0..5 {
        put32(&mut bmi, 0);
    }
    for _ in 0..3 {
        put32(&mut bmi, -1);
    }
    let bits = vec![0xFFu8; 4];
    let mut r = Vec::new();
    for v in [0, 0, 99, 99, 0, 0, 0, 0, 1, 1, 80, bmi.len() as i32, 80 + bmi.len() as i32, 4, 0, 0x00CC_0020, 100, 100] {
        put32(&mut r, v);
    }
    r.extend_from_slice(&bmi);
    r.extend_from_slice(&bits);
    let b = emf(&[erec_bytes(81, &r)]);
    let run = hostile("bit fields", move || doc_metafile::render(&b, 100, None));
    let img = run.value.expect("drawn");
    assert_eq!(&img.2[..4], &[255, 255, 255, 255]);
}

#[test]
fn creating_objects_into_a_full_table_stays_quick() {
    // 65,536 pens fill the object table; then, 80,000 times, one is
    // deleted and two are created. Each create looked through every slot
    // for the lowest free one, so a few megabytes of these records took
    // minutes, and 16 MB took hours.
    let blue = 0xFF0000;
    let pen = wrec(0x02FA, &[0, 1, 0, 0, 0]);
    let mut records = vec![pen.clone(); 65_536];
    for _ in 0..80_000 {
        records.push(wrec(0x01F0, &[0]));
        records.push(wrec(0x02FA, &[0, 30, 0, blue & 0xFFFF, blue >> 16]));
        records.push(pen.clone());
    }
    // The last blue pen sits in the freed slot 0: draw with it.
    records.push(wrec(0x012D, &[0]));
    records.push(wrec(0x0325, &[2, 0, 500, 1000, 500]));
    let b = wmf([0, 0, 1000, 1000], &records);
    let run = hostile("full object table", move || doc_metafile::render(&b, 100, None));
    let img = run.value.expect("drawn");
    assert_eq!(&img.2[(50 * 100 + 50) * 4..(50 * 100 + 50) * 4 + 4], &[0, 0, 255, 255]);
}

#[test]
fn long_strings_of_text_stay_linear() {
    // One ExtTextOutW of 65,535 characters in a 12-pixel font. Each glyph
    // counted the outline points of every glyph before it, against the
    // budget: billions of additions for one record. Skipped where the
    // font is not installed.
    let dir = std::path::Path::new("/usr/share/fonts/truetype/liberation");
    if !dir.join("LiberationSans-Regular.ttf").exists() {
        return;
    }
    let text = |n: usize| {
        let mut font = Vec::new();
        for v in [1, -1, 0, 0, 0, 400, 0, 0] {
            put32(&mut font, v);
        }
        let face: Vec<u16> = "Liberation Sans".encode_utf16().collect();
        for k in 0..32 {
            put16(&mut font, face.get(k).copied().unwrap_or(0) as i32);
        }
        let mut t = Vec::new();
        // Bounds, graphics mode and scales; then the reference point, the
        // count, the string's offset, options, rectangle and no advances.
        for v in [0, 0, 99, 99, 1, 0, 0, 0, 50, n as i32, 76, 0, 0, 0, 0, 0, 0] {
            put32(&mut t, v);
        }
        for k in 0..n {
            put16(&mut t, b"Wg@&%"[k % 5] as i32);
        }
        emf(&[erec_bytes(82, &font), erec(37, &[1]), erec_bytes(84, &t)])
    };
    let (short, long) = (text(400), text(65_535));
    let run = hostile("long text", move || {
        let mut book = doc_font::FontBook::new();
        book.add_dir(dir);
        (doc_metafile::render(&short, 1200, Some(&mut book)), doc_metafile::render(&long, 1200, Some(&mut book)))
    });
    let (short, long) = run.value;
    let short = short.expect("drawn");
    assert!(inked(&short) > 2_000, "the short text is drawn: {} pixels", inked(&short));
    assert!(long.is_some());
}

#[test]
fn part_of_a_large_picture_is_cut_out_in_place() {
    // A 2,000 x 2,000 one-bit picture (500 KB in the file), of which all
    // but the last column is drawn. The part drawn was copied out of the
    // decoded picture, holding its 16 MB twice.
    let (w, h) = (2000i32, 2000i32);
    let mut bmi = Vec::new();
    for v in [40, w, h] {
        put32(&mut bmi, v);
    }
    put16(&mut bmi, 1);
    put16(&mut bmi, 1);
    for _ in 0..6 {
        put32(&mut bmi, 0);
    }
    // Black, then white.
    put32(&mut bmi, 0);
    put32(&mut bmi, 0xFF_FFFF);
    let stride = (w as usize).div_ceil(32) * 4;
    // White, with the left half of each row black.
    let mut row = vec![0xFFu8; stride];
    row[..w as usize / 16].fill(0);
    let bits = row.repeat(h as usize);
    let mut r = Vec::new();
    for v in [0, 0, 99, 99, 0, 0, 0, 0, w - 1, h, 80, bmi.len() as i32, 80 + bmi.len() as i32, bits.len() as i32, 0, 0x00CC_0020, 100, 100] {
        put32(&mut r, v);
    }
    r.extend_from_slice(&bmi);
    r.extend_from_slice(&bits);
    let b = emf(&[erec_bytes(81, &r)]);
    let run = hostile("part of a large picture", move || doc_metafile::render(&b, 100, None));
    let img = run.value.expect("drawn");
    let at = |x: usize, y: usize| &img.2[(y * 100 + x) * 4..(y * 100 + x) * 4 + 4];
    assert_eq!((at(10, 50), at(90, 50)), (&[0, 0, 0, 255][..], &[255, 255, 255, 255][..]));
    assert!(run.peak < 24 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn slanted_lines_cost_the_pixels_they_cover() {
    // 400 thin lines, each slanting across the picture, and then a red
    // one. Each row of a line was charged the width of the line's whole
    // box, so the paint budget ran out after about 180 of them and the
    // rest of an ordinary hatched drawing was left out.
    let mut records = vec![wrec(0x02FA, &[0, 0, 0, 0, 0]), wrec(0x012D, &[0])];
    for k in 0..400 {
        records.push(wrec(0x0214, &[0, k * 2]));
        records.push(wrec(0x0213, &[10000, k * 2 + 9000]));
    }
    let red = 0x0000FF;
    records.extend([wrec(0x01F0, &[0]), wrec(0x02FA, &[0, 0, 0, red & 0xFFFF, red >> 16]), wrec(0x012D, &[0])]);
    records.extend([wrec(0x0214, &[0, 9550]), wrec(0x0213, &[10000, 9550])]);
    let b = wmf([0, 0, 10000, 10000], &records);
    let run = hostile("slanted lines", move || {
        let mut budget = doc_metafile::Budget::for_canvas(100, 100);
        (doc_metafile::render_within(&b, 100, None, &mut budget), budget)
    });
    let (img, budget) = run.value;
    let img = img.expect("drawn");
    assert!(!budget.spent(), "{budget:?}");
    assert_eq!(&img.2[(50 * 100 + 95) * 4..(50 * 100 + 95) * 4 + 4], &[255, 0, 0, 255]);
}

#[test]
fn a_new_face_for_every_space_comes_out_of_the_budget() {
    // 20,000 fonts, each of a name never seen before, each drawing one
    // space. A space has no outline, so nothing was charged, while each
    // name was looked for among the fonts: a 16 MB file of these took
    // 4.5 s in a release build, and every name stayed in the shared font
    // book. Skipped where the fonts are not installed.
    let dir = std::path::Path::new("/usr/share/fonts/truetype/liberation");
    if !dir.join("LiberationSans-Regular.ttf").exists() {
        return;
    }
    let mut records = Vec::new();
    for k in 0..20_000 {
        let mut font = Vec::new();
        for v in [1, -12, 0, 0, 0, 400, 0, 0] {
            put32(&mut font, v);
        }
        let face: Vec<u16> = format!("Face {k}").encode_utf16().collect();
        for n in 0..32 {
            put16(&mut font, face.get(n).copied().unwrap_or(0) as i32);
        }
        let mut t = Vec::new();
        for v in [0, 0, 99, 99, 1, 0, 0, 0, 50, 1, 76, 0, 0, 0, 0, 0, 0] {
            put32(&mut t, v);
        }
        put16(&mut t, b' ' as i32);
        records.extend([erec_bytes(82, &font), erec(37, &[1]), erec_bytes(84, &t)]);
    }
    let b = emf(&records);
    let run = hostile("20,000 faces", move || {
        let mut book = doc_font::FontBook::new();
        book.add_dir(dir);
        let mut budget = doc_metafile::Budget::for_canvas(1200, 1200);
        doc_metafile::render_within(&b, 1200, Some(&mut book), &mut budget);
        budget
    });
    assert!(run.value.spent(), "{:?}", run.value);
}
