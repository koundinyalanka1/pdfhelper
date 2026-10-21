//! Hostile drawing stores: importing their pictures must stay within the
//! import's budget, 2 s and a 512 KiB stack.

mod support;

use std::time::Duration;

use doc_art::{fbse_blip_within, store_entries, Budget, MAX_IMPORT, MAX_PICTURE};
use support::bounded;

fn rec(ver: u16, inst: u16, ty: u16, body: &[u8]) -> Vec<u8> {
    let mut v = (ver | inst << 4).to_le_bytes().to_vec();
    v.extend_from_slice(&ty.to_le_bytes());
    v.extend_from_slice(&(body.len() as u32).to_le_bytes());
    v.extend_from_slice(body);
    v
}

/// Deflate bits, least significant first.
struct Bits {
    out: Vec<u8>,
    acc: u64,
    n: u32,
}

impl Bits {
    fn put(&mut self, v: u32, n: u32) {
        self.acc |= (v as u64) << self.n;
        self.n += n;
        while self.n >= 8 {
            self.out.push(self.acc as u8);
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code: its bits go most significant first.
    fn code(&mut self, c: u32, n: u32) {
        self.put(c.reverse_bits() >> (32 - n), n);
    }

    fn finish(mut self) -> Vec<u8> {
        if self.n > 0 {
            self.out.push(self.acc as u8);
        }
        self.out
    }
}

/// A zlib stream of 1 + 258 x `matches` zero bytes, written by hand (a
/// zero, then that many copies of the 258 bytes before): compressing
/// 64 MB takes seconds in a debug build. With `broken`, a block of a
/// type that does not exist follows, so inflating fails at the end.
fn zeros(matches: usize, broken: bool) -> Vec<u8> {
    let mut b = Bits { out: vec![0x78, 0x01], acc: 0, n: 0 };
    // A block of the fixed codes: the last one unless one follows.
    b.put(if broken { 0 } else { 1 }, 1);
    b.put(1, 2);
    b.code(0x30, 8);
    for _ in 0..matches {
        // Length 258 (code 285), distance 1 (code 0).
        b.code(0xC5, 8);
        b.code(0, 5);
    }
    b.code(0, 7);
    if broken {
        b.put(1, 1);
        b.put(3, 2);
    }
    let mut out = b.finish();
    let n = 1 + 258 * matches as u64;
    out.extend_from_slice(&((((n % 65521) << 16) | 1) as u32).to_be_bytes());
    out
}

/// A compressed EMF picture record holding `data`.
fn emf_blip(data: &[u8]) -> Vec<u8> {
    let mut body = vec![0u8; 16];
    let mut h = vec![0u8; 34];
    h[28..32].copy_from_slice(&(data.len() as u32).to_le_bytes());
    h[33] = 0xFE;
    body.extend_from_slice(&h);
    body.extend_from_slice(data);
    rec(0, 0x3D4, 0xF01A, &body)
}

/// A store entry: embedding `blip`, or pointing `size` bytes at `fo` in
/// the delay stream.
fn fbse(blip: &[u8], fo: u32, size: u32) -> Vec<u8> {
    let mut body = vec![0u8; 36];
    body[20..24].copy_from_slice(&size.to_le_bytes());
    body[28..32].copy_from_slice(&fo.to_le_bytes());
    body.extend_from_slice(blip);
    rec(2, 2, doc_art::FBSE, &body)
}

/// Import every picture of a drawing group's store, keeping them as an
/// importer does: what each gave, in bytes.
fn import(store: &[u8], delay: &[u8], budget: &mut Budget) -> Vec<Option<usize>> {
    store_entries(store)
        .into_iter()
        .map(|(s, e)| fbse_blip_within(&store[s..e], delay, budget))
        .collect::<Vec<_>>()
        .into_iter()
        .map(|p| p.map(|(bytes, _)| bytes.len()))
        .collect()
}

#[test]
fn the_default_budget() {
    assert_eq!(Budget::import(), Budget { left: MAX_IMPORT });
    assert_eq!(Budget::default(), Budget::import());
    assert_eq!(MAX_IMPORT, 256 << 20);
}

#[test]
fn compressed_pictures_stop_at_the_import_budget() {
    // Sixteen pictures of 7 MB, each inflating past 64 MB: a gigabyte
    // kept from a 7 MB file, where each picture alone was within bounds.
    let bomb = emf_blip(&zeros(260_200, false));
    let store = rec(0xF, 0, doc_art::BSTORE_CONTAINER, &vec![fbse(&bomb, 0, 0); 16].concat());
    // 80 MB: the first picture, cut at 64 MB as it always was, and then
    // the budget ends in the second.
    let run = bounded("compressed pictures", 512 << 20, Duration::from_secs(2), move || {
        let mut budget = Budget { left: 80 << 20 };
        let got = import(&store, &[], &mut budget);
        (got, budget)
    });
    eprintln!("compressed pictures: {:?}, peak {} MB", run.time, run.peak >> 20);
    let (got, budget) = run.value;
    assert_eq!(got[0], Some(MAX_PICTURE as usize));
    assert!(got[1..].iter().all(Option::is_none), "{got:?}");
    assert!(budget.spent());
    assert!(run.peak < 96 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn broken_compressed_pictures_still_cost_what_they_inflated() {
    // 64 pictures inflating 8 MB each and then breaking off: none is kept,
    // but each took the time of inflating it.
    let bomb = emf_blip(&zeros(32_600, true));
    let store = rec(0xF, 0, doc_art::BSTORE_CONTAINER, &vec![fbse(&bomb, 0, 0); 64].concat());
    let run = bounded("broken pictures", 512 << 20, Duration::from_secs(2), move || {
        let mut budget = Budget { left: 32 << 20 };
        let got = import(&store, &[], &mut budget);
        (got, budget)
    });
    eprintln!("broken pictures: {:?}, peak {} MB", run.time, run.peak >> 20);
    let (got, budget) = run.value;
    assert!(got.iter().all(Option::is_none));
    assert!(budget.spent());
}

#[test]
fn store_entries_pointing_at_one_large_picture() {
    // 2,000 store entries of 44 bytes, all pointing at one 1 MB JPEG in
    // the delay stream: 2 GB of copies from 1 MB of file.
    let jpeg = rec(0, 0x46A, 0xF01D, &[vec![0u8; 17], vec![0xAB; 1 << 20]].concat());
    let store = rec(0xF, 0, doc_art::BSTORE_CONTAINER, &vec![fbse(&[], 0, jpeg.len() as u32); 2000].concat());
    let run = bounded("one picture, 2,000 entries", 512 << 20, Duration::from_secs(2), move || {
        let mut budget = Budget::import();
        import(&store, &jpeg, &mut budget)
    });
    eprintln!("one picture, 2,000 entries: {:?}, peak {} MB", run.time, run.peak >> 20);
    let got = run.value;
    // The default budget holds 256 of them; the rest are left out.
    assert_eq!(got.iter().filter(|p| p.is_some()).count(), 256);
    assert!(got[..256].iter().all(|p| *p == Some(1 << 20)));
    assert!(run.peak < 300 << 20, "held {} MB", run.peak >> 20);
}

#[test]
fn hand_made_streams_inflate() {
    use std::io::Read;
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(&zeros(10, false)[..]).read_to_end(&mut out).unwrap();
    assert_eq!(out, vec![0; 2581]);
    // The broken one fails where its second block starts.
    let mut out = Vec::new();
    assert!(flate2::read::ZlibDecoder::new(&zeros(10, true)[..]).read_to_end(&mut out).is_err());
}
