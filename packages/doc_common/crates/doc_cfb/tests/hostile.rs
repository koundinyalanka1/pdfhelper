//! Hostile compound files: each must open and read (or fail) within 2 s,
//! 256 MB and a 512 KiB stack.

mod support;

use doc_cfb::{build, Cfb, CfbError};
use support::hostile;

fn u32_at(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

fn put32(b: &mut [u8], i: usize, v: u32) {
    b[i..i + 4].copy_from_slice(&v.to_le_bytes());
}

/// Where directory entry `k` of a file made by [`build`] starts.
fn entry_at(file: &[u8], k: usize) -> usize {
    (u32_at(file, 48) as usize + 1) * 512 + 128 * k
}

#[test]
fn a_mini_stream_cutoff_of_four_billion() {
    // The header says every stream under 4 GB lives in the mini stream,
    // and a stream claims 400 MB: that much was set aside before the
    // mini stream (there is none) was looked at.
    let data: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
    let mut file = build(&[("WordDocument", &data), ("Huge", &[7; 600])]);
    put32(&mut file, 56, 0xFFFF_FFFF);
    let huge = entry_at(&file, 2);
    put32(&mut file, huge + 120, 400 << 20);
    let run = hostile("cutoff 0xFFFFFFFF", move || {
        let c = Cfb::open(file).unwrap();
        (c.stream("WordDocument"), c.stream("Huge"))
    });
    let (word, huge) = run.value;
    // Streams are read where a cutoff of 4096 puts them.
    assert_eq!(word.unwrap(), data);
    assert_eq!(huge.unwrap_err(), CfbError::Corrupt("stream shorter than its size".into()));
    assert!(run.peak < 1 << 20, "held {} KB", run.peak >> 10);
}

/// A file whose FAT lists its one FAT sector `refs` times (through the
/// header and DIFAT sectors), padded so the header's counts hold: a FAT
/// of `refs` x 128 entries, every copy the same.
fn repeated_fat(refs: usize) -> Vec<u8> {
    // Sector 0: "Data"; 1: the directory; 2: the FAT.
    let mut file = build(&[("Data", &[1u8; 100])]);
    assert_eq!(file.len(), 4 * 512);
    for k in 0..109 {
        put32(&mut file, 76 + 4 * k, 2);
    }
    let difat = (refs - 109).div_ceil(127);
    for d in 0..difat {
        let mut s = vec![0u8; 512];
        for k in 0..127 {
            put32(&mut s, 4 * k, 2);
        }
        put32(&mut s, 508, if d + 1 == difat { 0xFFFF_FFFE } else { 3 + d as u32 + 1 });
        file.extend_from_slice(&s);
    }
    // Padding, so the file has as many sectors as the FAT claims.
    file.resize((refs + 1) * 512, 0);
    put32(&mut file, 44, refs as u32);
    put32(&mut file, 68, 3);
    put32(&mut file, 72, difat as u32);
    file
}

#[test]
fn a_huge_fat_is_marked_with_one_bit_per_entry() {
    // A 4 MB file with a FAT of a million entries. Every chain walked set
    // aside a byte for each entry (a megabyte), on top of the FAT itself;
    // now one bit each, set aside once for the file.
    let file = repeated_fat(8192);
    let run = hostile("repeated FAT", move || {
        let c = Cfb::open(file).unwrap();
        let mut read = 0;
        for _ in 0..100 {
            read += c.stream("Data").unwrap().len();
        }
        read
    });
    assert_eq!(run.value, 100 * 100);
    // The FAT is 4 MB; its marks 128 KB.
    assert!(run.peak < 4608 << 10, "held {} KB", run.peak >> 10);
}

#[test]
fn sector_numbers_near_the_top_fail_cleanly() {
    // FAT, DIFAT and chain links just below the special values: where
    // they start overflows a 32-bit address, so each is checked.
    for at in [76, 68] {
        let mut file = build(&[("Data", &[1u8; 100])]);
        put32(&mut file, at, 0xFFFF_FFFA);
        if at == 68 {
            // A second FAT sector, listed in one DIFAT sector.
            put32(&mut file, 44, 2);
            put32(&mut file, 72, 1);
        }
        let run = hostile("sector 0xFFFFFFFA", move || Cfb::open(file).map(|_| ()));
        assert!(matches!(run.value, Err(CfbError::Corrupt(_))), "{:?}", run.value);
    }
    let mut file = build(&[("Data", &[1u8; 100])]);
    let data = entry_at(&file, 1);
    put32(&mut file, data + 116, 0xFFFF_FFFA);
    let run = hostile("chain 0xFFFFFFFA", move || Cfb::open(file).unwrap().stream("Data"));
    assert!(matches!(run.value, Err(CfbError::Corrupt(_))), "{:?}", run.value);
}
