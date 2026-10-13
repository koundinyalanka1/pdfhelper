use std::process::Command;
use std::sync::Arc;

use super::*;

fn carlito() -> Option<Arc<Font>> {
    let data = std::fs::read("/usr/share/fonts/truetype/crosextra/Carlito-Regular.ttf").ok()?;
    Some(Arc::new(Font::parse(Arc::new(data), 0).ok()?))
}

/// A tiny opaque 2x1 PNG.
fn png() -> Vec<u8> {
    use std::io::Write;
    fn crc(data: &[u8]) -> u32 {
        let mut c = 0xFFFF_FFFFu32;
        for &b in data {
            c ^= b as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut chunk = |ty: &[u8], data: &[u8]| {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        let mut body = ty.to_vec();
        body.extend_from_slice(data);
        out.extend_from_slice(&body);
        out.extend_from_slice(&crc(&body).to_be_bytes());
    };
    chunk(b"IHDR", &[0, 0, 0, 2, 0, 0, 0, 1, 8, 2, 0, 0, 0]);
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(&[0, 255, 0, 0, 0, 0, 255]).unwrap();
    chunk(b"IDAT", &z.finish().unwrap());
    chunk(b"IEND", &[]);
    out
}

#[test]
fn writes_a_valid_file_with_text_shapes_and_pictures() {
    let mut pdf = Pdf::new();
    pdf.set_title("Family budget");
    let mut page = pdf.page(595.0, 842.0);
    page.rect(50.0, 50.0, 200.0, 100.0);
    page.fill(0xFF33_6699, false);
    page.move_to(50.0, 200.0);
    page.line_to(300.0, 200.0);
    page.stroke(&Stroke { width: 2.0, color: 0x80FF_0000, dash: vec![6.0, 3.0], cap: Cap::Round, round_join: true });
    page.save();
    page.rect(300.0, 50.0, 200.0, 100.0);
    page.clip(false);
    page.gradient(Gradient::Linear { from: (300.0, 50.0), to: (500.0, 50.0), stops: vec![(0.0, 0xFFFF_FFFF), (0.5, 0xFFFF_0000), (1.0, 0xFF00_00FF)] });
    page.restore();
    let img = pdf.image(&png()).unwrap();
    assert_eq!((img.width, img.height), (2, 1));
    assert_eq!(pdf.image(&png()).unwrap(), img);
    page.image(&img, 50.0, 300.0, 100.0, 50.0);
    page.link(50.0, 300.0, 100.0, 50.0, "https://example.org/(x)");
    if let Some(f) = carlito() {
        let fr = pdf.font(f.clone());
        let mut x = 0.0;
        let glyphs: Vec<Glyph> = "Hello, world"
            .chars()
            .map(|c| {
                let gid = f.glyph(c).unwrap_or(0);
                let g = Glyph { gid, x, text: c.to_string() };
                x += f.advance(gid) as f32 / f.units_per_em as f32 * 24.0;
                g
            })
            .collect();
        page.text(&mut pdf, fr, 24.0, 0xFF00_0000, 60.0, 450.0, &glyphs, false, false);
        page.text(&mut pdf, fr, 24.0, 0xFFC0_0000, 60.0, 500.0, &glyphs[..5], true, true);
    }
    pdf.add_page(page);
    let second = pdf.page(842.0, 595.0);
    pdf.add_page(second);
    assert_eq!(pdf.page_count(), 2);
    let bytes = pdf.finish();
    assert!(bytes.starts_with(b"%PDF-1.7"));
    assert!(bytes.ends_with(b"%%EOF\n"));
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("/Count 2"));
    assert!(text.contains("/ShadingType 2"));

    // When poppler is installed, it reads the file back.
    let path = std::env::temp_dir().join(format!("doc_pdf_test_{}.pdf", std::process::id()));
    std::fs::write(&path, &bytes).unwrap();
    if let Ok(out) = Command::new("pdftotext").arg(&path).arg("-").output() {
        if out.status.success() && carlito().is_some() {
            let t = String::from_utf8_lossy(&out.stdout);
            assert!(t.contains("Hello, world"), "{t}");
        }
    }
    if let Ok(out) = Command::new("pdfinfo").arg(&path).output() {
        if out.status.success() {
            let t = String::from_utf8_lossy(&out.stdout);
            assert!(t.contains("Pages:") && t.contains("2"), "{t}");
            assert!(t.contains("Family budget"), "{t}");
        }
    }
    if std::env::var("KEEP_PDF").is_err() {
        let _ = std::fs::remove_file(&path);
    } else {
        eprintln!("kept {}", path.display());
    }
}
