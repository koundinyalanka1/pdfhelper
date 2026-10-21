//! 20,000 mutations of drawing records: walking them, reading their
//! properties and importing their pictures may find nothing, but never
//! panic, take long or hold much memory. The seed is fixed, so a failure
//! repeats.

mod support;

use std::io::Write;
use std::time::{Duration, Instant};

use doc_art::*;
use doc_testkit::{mutate, run_limited, Limits, Rng};
use support::bounded;

fn rec(ver: u16, inst: u16, ty: u16, body: &[u8]) -> Vec<u8> {
    let mut v = (ver | inst << 4).to_le_bytes().to_vec();
    v.extend_from_slice(&ty.to_le_bytes());
    v.extend_from_slice(&(body.len() as u32).to_le_bytes());
    v.extend_from_slice(body);
    v
}

fn zlib(raw: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(raw).unwrap();
    z.finish().unwrap()
}

/// A metafile picture record: EMF (0xF01A) or WMF (0xF01B), compressed
/// or not.
fn metafile(ty: u16, data: &[u8], compressed: bool) -> Vec<u8> {
    let stored = if compressed { zlib(data) } else { data.to_vec() };
    let mut h = vec![0u8; 34];
    for (k, v) in [0i32, 0, 1000, 800, 1000].iter().enumerate() {
        h[4 + 4 * k..8 + 4 * k].copy_from_slice(&v.to_le_bytes());
    }
    h[28..32].copy_from_slice(&(stored.len() as u32).to_le_bytes());
    h[32] = if compressed { 0 } else { 0xFE };
    h[33] = 0xFE;
    let inst = if ty == 0xF01A { 0x3D4 } else { 0x216 };
    rec(0, inst, ty, &[vec![0u8; 16], h, stored].concat())
}

fn fbse(blip: &[u8], fo: u32, size: u32) -> Vec<u8> {
    let mut body = vec![0u8; 36];
    body[20..24].copy_from_slice(&size.to_le_bytes());
    body[28..32].copy_from_slice(&fo.to_le_bytes());
    body.extend_from_slice(blip);
    rec(2, 2, FBSE, &body)
}

/// Drawing records and a delay stream.
fn seeds() -> Vec<(Vec<u8>, Vec<u8>)> {
    let png = rec(0, 0x6E0, 0xF01E, &[vec![0u8; 17], b"\x89PNG\r\n\x1a\nrest".to_vec()].concat());
    let jpeg = rec(0, 0x46A, 0xF01D, &[vec![0u8; 17], vec![0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]].concat());
    let mut dib = vec![0u8; 40];
    dib[0] = 40;
    dib[14] = 8;
    dib.extend((0..1024u32).map(|i| i as u8));
    let dib = rec(0, 0x7A8, 0xF01F, &[vec![0u8; 17], dib].concat());
    let emf: Vec<u8> = (0..4000u32).map(|i| (i % 13) as u8).collect();
    let store = rec(
        0xF,
        0,
        BSTORE_CONTAINER,
        &[
            fbse(&png, 0, 0),
            fbse(&metafile(0xF01A, &emf, true), 0, 0),
            fbse(&metafile(0xF01B, &emf[..300], false), 0, 0),
            fbse(&metafile(0xF01B, &emf, true), 0, 0),
            fbse(&dib, 0, 0),
            fbse(&[], 4, jpeg.len() as u32),
        ]
        .concat(),
    );
    let dgg = rec(0xF, 0, DGG_CONTAINER, &store);
    let delay = [vec![0u8; 4], jpeg.clone()].concat();
    // Shapes: a group with a picture shape (properties, anchors, text).
    let mut opt = Vec::new();
    for (id, v) in [(0x0104u16, 1u32), (0x0181, 0xFF), (0x01BF, 0x0010_0010)] {
        opt.extend_from_slice(&id.to_le_bytes());
        opt.extend_from_slice(&v.to_le_bytes());
    }
    opt.extend_from_slice(&(0x8000u16 | 0x0145).to_le_bytes());
    opt.extend_from_slice(&3u32.to_le_bytes());
    opt.extend_from_slice(&[7, 8, 9]);
    let sp = rec(
        0xF,
        0,
        SP_CONTAINER,
        &[
            rec(2, 75, FSP, &[5, 4, 0, 0, 0, 0xA, 0, 0]),
            rec(3, 4, OPT, &opt),
            rec(0, 0, CLIENT_ANCHOR, &[0; 16]),
            rec(0, 0, CHILD_ANCHOR, &[0; 16]),
            rec(0xF, 0, CLIENT_TEXTBOX, &rec(0, 0, 0x0FA0, b"text")),
        ]
        .concat(),
    );
    let group = rec(0xF, 0, SPGR_CONTAINER, &[rec(0xF, 0, SP_CONTAINER, &rec(1, 0, FSPGR, &[0; 16])), sp.clone()].concat());
    let dg = rec(0xF, 0, DG_CONTAINER, &group);
    vec![(dgg, delay.clone()), (dg, Vec::new()), ([store.clone(), png, sp].concat(), delay)]
}

/// Everything a reader does with drawing records: bytes of pictures
/// made, plus records and properties seen.
fn read_all(b: &[u8], delay: &[u8]) -> usize {
    let mut seen = 0;
    walk(b, 0, b.len(), &mut |r| {
        seen += 1;
        if r.ty == OPT || r.ty == TERTIARY_OPT {
            let p = props(b, r);
            seen += p.len() + prop(&p, 0x0104).is_some() as usize;
            let _ = flag(&p, 0x01BF, 4);
            let _ = prop(&p, 0x0181).map(color);
        }
    });
    for r in records(b) {
        seen += r.children(b).count();
        let _ = record_at(b, r.start);
    }
    let mut budget = Budget::import();
    for (s, e) in store_entries(b) {
        seen += fbse_blip_within(&b[s..e], delay, &mut budget).map_or(0, |p| p.0.len());
    }
    seen + find_blip_within(b, delay, &mut budget).map_or(0, |p| p.0.len())
}

#[test]
fn every_seed_has_pictures() {
    for (b, delay) in seeds() {
        assert!(read_all(&b, &delay) > 0);
    }
    let (dgg, delay) = &seeds()[0];
    let store = records(dgg).next().unwrap();
    let entries = store_entries(store.body(dgg));
    let kinds: Vec<_> = entries.iter().map(|&(s, e)| fbse_blip(&store.body(dgg)[s..e], delay).map(|p| p.1)).collect();
    assert_eq!(kinds, [Some("png"), Some("emf"), Some("wmf"), Some("wmf"), Some("bmp"), Some("jpeg")]);
}

#[test]
fn mutated_drawings_never_panic_hang_or_hog_memory() {
    run_limited("mutated_drawings_never_panic_hang_or_hog_memory", Limits::mutation(Duration::from_secs(125)), mutations).unwrap();
}

fn mutations() {
    let seeds = seeds();
    let run = bounded("drawing mutations", 256 << 20, Duration::from_secs(120), move || {
        let mut rng = Rng(0x1234_5678_9ABC_DEF1);
        let mut slowest = (Duration::ZERO, 0);
        let mut found = 0;
        for i in 0..20_000 {
            let (seed, delay) = &seeds[i % seeds.len()];
            let other = &seeds[(i + 1) % seeds.len()].0;
            let b = mutate(&mut rng, seed, other);
            // Now and then the delay stream is the damaged one.
            let d = if i % 5 == 0 { mutate(&mut rng, delay, other) } else { delay.clone() };
            let t = Instant::now();
            if read_all(&b, &d) > 0 {
                found += 1;
            }
            if t.elapsed() > slowest.0 {
                slowest = (t.elapsed(), i);
            }
        }
        (slowest, found)
    });
    let ((slowest, at), found) = run.value;
    eprintln!("20,000 mutations in {:?}: {found} read, slowest {slowest:?} (#{at}), peak {} KB", run.time, run.peak / 1024);
    assert!(slowest < Duration::from_secs(2), "mutation #{at} took {slowest:?}");
}
