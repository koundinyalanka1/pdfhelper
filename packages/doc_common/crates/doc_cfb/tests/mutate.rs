//! 20,000 mutations of compound files: opening one and reading every
//! stream may fail, but never panic, take long or hold much memory. The
//! seed is fixed, so a failure repeats.

mod support;

use std::time::{Duration, Instant};

use doc_cfb::{build, Cfb};
use doc_testkit::{mutate, run_limited, Limits, Rng};
use support::bounded;

const END: u32 = 0xFFFF_FFFE;
const FREE: u32 = 0xFFFF_FFFF;

fn put32(b: &mut [u8], i: usize, v: u32) {
    b[i..i + 4].copy_from_slice(&v.to_le_bytes());
}

/// A directory entry: name, kind, siblings, child, start and size.
fn entry(name: &str, kind: u8, right: u32, child: u32, start: u32, size: u32) -> Vec<u8> {
    let mut e = vec![0u8; 128];
    let units: Vec<u16> = name.encode_utf16().collect();
    for (k, u) in units.iter().enumerate() {
        e[2 * k..2 * k + 2].copy_from_slice(&u.to_le_bytes());
    }
    e[64..66].copy_from_slice(&(((units.len() + 1) * 2) as u16).to_le_bytes());
    e[66] = kind;
    put32(&mut e, 68, FREE);
    put32(&mut e, 72, right);
    put32(&mut e, 76, child);
    put32(&mut e, 116, start);
    put32(&mut e, 120, size);
    e
}

/// A file with a regular stream and a mini stream: sectors 0-9 "Big",
/// 10 the mini stream (two mini sectors of "Small"), 11 the mini FAT,
/// 12 the directory and 13 the FAT.
fn with_mini_stream() -> Vec<u8> {
    let mut h = vec![0u8; 512];
    h[..8].copy_from_slice(&[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
    h[24..26].copy_from_slice(&0x3Eu16.to_le_bytes());
    h[26..28].copy_from_slice(&3u16.to_le_bytes());
    h[28..30].copy_from_slice(&0xFFFEu16.to_le_bytes());
    h[30..32].copy_from_slice(&9u16.to_le_bytes());
    h[32..34].copy_from_slice(&6u16.to_le_bytes());
    for (at, v) in [(44, 1), (48, 12), (56, 4096), (60, 11), (64, 1), (68, END), (72, 0), (76, 13)] {
        put32(&mut h, at, v);
    }
    for k in 1..109 {
        put32(&mut h, 76 + 4 * k, FREE);
    }
    let mut b = h;
    b.extend((0..5120u32).map(|i| (i % 251) as u8));
    let mut mini: Vec<u8> = (0..128u32).map(|i| (i * 3) as u8).collect();
    mini.resize(512, 0);
    b.extend_from_slice(&mini);
    let mut minifat = vec![0xFFu8; 512];
    put32(&mut minifat, 0, 1);
    put32(&mut minifat, 4, END);
    b.extend_from_slice(&minifat);
    let mut dir = Vec::new();
    dir.extend(entry("Root Entry", 5, FREE, 1, 10, 128));
    dir.extend(entry("Big", 2, 2, FREE, 0, 5000));
    dir.extend(entry("Small", 2, FREE, FREE, 0, 100));
    dir.extend(entry("", 0, FREE, FREE, 0, 0));
    b.extend_from_slice(&dir);
    let mut fat = vec![0xFFu8; 512];
    for s in 0..9 {
        put32(&mut fat, 4 * s, s as u32 + 1);
    }
    for s in 9..13 {
        put32(&mut fat, 4 * s, END);
    }
    put32(&mut fat, 52, 0xFFFF_FFFD);
    b.extend_from_slice(&fat);
    b
}

fn seeds() -> Vec<Vec<u8>> {
    let big: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
    vec![
        with_mini_stream(),
        build(&[("WordDocument", &big), ("1Table", b"hello"), ("\u{5}SummaryInformation", &[1, 2, 3])]),
        build(&[("Workbook", &[7u8; 2000])]),
        build(&[("PowerPoint Document", &big[..1500]), ("Current User", &[0; 20]), ("Pictures", &big[..700])]),
    ]
}

/// Open a file and read all it lists: the bytes read, or 0.
fn read_all(b: Vec<u8>) -> usize {
    let Ok(c) = Cfb::open(b) else { return 0 };
    let mut n = 0;
    for path in c.list().iter().take(64) {
        n += c.stream(path).map_or(0, |s| s.len());
    }
    for i in 0..c.entries().len().min(64) {
        n += c.stream_at(i).map_or(0, |s| s.len());
    }
    n
}

#[test]
fn every_seed_reads() {
    let c = Cfb::open(with_mini_stream()).unwrap();
    assert_eq!(c.stream("Small").unwrap(), (0..100u32).map(|i| (i * 3) as u8).collect::<Vec<_>>());
    assert_eq!(c.stream("Big").unwrap().len(), 5000);
    for s in seeds() {
        assert!(read_all(s) > 0);
    }
}

#[test]
fn mutated_compound_files_never_panic_hang_or_hog_memory() {
    run_limited("mutated_compound_files_never_panic_hang_or_hog_memory", Limits::mutation(Duration::from_secs(125)), mutations).unwrap();
}

fn mutations() {
    let seeds = seeds();
    let run = bounded("compound file mutations", 256 << 20, Duration::from_secs(120), move || {
        let mut rng = Rng(0x2545_F491_4F6C_DD1D);
        let mut slowest = (Duration::ZERO, 0);
        let mut opened = 0;
        for i in 0..20_000 {
            let b = mutate(&mut rng, &seeds[i % seeds.len()], &seeds[(i + 1) % seeds.len()]);
            let t = Instant::now();
            if read_all(b) > 0 {
                opened += 1;
            }
            if t.elapsed() > slowest.0 {
                slowest = (t.elapsed(), i);
            }
        }
        (slowest, opened)
    });
    let ((slowest, at), opened) = run.value;
    eprintln!("20,000 mutations in {:?}: {opened} read, slowest {slowest:?} (#{at}), peak {} KB", run.time, run.peak / 1024);
    assert!(slowest < Duration::from_secs(2), "mutation #{at} took {slowest:?}");
}
