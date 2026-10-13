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
