use super::*;

fn sample() -> Vec<u8> {
    let mut zip = ZipWriter::new();
    zip.add("[Content_Types].xml", b"<Types/>", Compression::DEFAULT).unwrap();
    zip.add_directory("word").unwrap();
    zip.add("word/document.xml", "<w:document>héllo</w:document>".repeat(50).as_bytes(), Compression::DEFAULT)
        .unwrap();
    zip.add("mimetype", b"application/vnd.oasis.opendocument.text", Compression::Stored)
        .unwrap();
    zip.finish()
}

#[test]
fn crc32_matches_known_values() {
    assert_eq!(crc32(b""), 0);
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    assert_eq!(crc32(b"The quick brown fox jumps over the lazy dog"), 0x414F_A339);
    let mut incremental = Crc32::new();
    for part in [&b"The quick "[..], b"brown fox jumps", b" over the lazy dog"] {
        incremental.update(part);
    }
    assert_eq!(incremental.finish(), 0x414F_A339);
}

#[test]
fn round_trips_entries_in_order() {
    let archive = ZipArchive::new(sample()).unwrap();
    let names: Vec<_> = archive.entries().iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["[Content_Types].xml", "word/", "word/document.xml", "mimetype"]);
    assert!(archive.entries()[1].is_dir());
    assert_eq!(archive.read_named("[Content_Types].xml").unwrap(), b"<Types/>");
    let doc = archive.read_named("word/document.xml").unwrap();
    assert_eq!(doc, "<w:document>héllo</w:document>".repeat(50).as_bytes());
    // Deflate actually happened for the repetitive part.
    let index = archive.find("word/document.xml").unwrap();
    assert!(archive.entries()[index].compressed_size < archive.entries()[index].size / 4);
    let mime = archive.find("mimetype").unwrap();
    assert_eq!(archive.entries()[mime].method, METHOD_STORED);
}

#[test]
fn finds_names_with_leading_slash_and_other_case() {
    let archive = ZipArchive::new(sample()).unwrap();
    assert_eq!(archive.find("/word/document.xml"), archive.find("word/document.xml"));
    assert_eq!(archive.find("WORD/Document.XML"), archive.find("word/document.xml"));
    assert!(archive.find("word/missing.xml").is_none());
    assert_eq!(
        archive.read_named("nope"),
        Err(ZipError::Missing("nope".into()))
    );
}

#[test]
fn copying_entries_keeps_their_bytes() {
    let source = ZipArchive::new(sample()).unwrap();
    let mut zip = ZipWriter::new();
    for index in 0..source.len() {
        zip.copy_from(&source, index).unwrap();
    }
    let copy = ZipArchive::new(zip.finish()).unwrap();
    assert_eq!(copy.len(), source.len());
    for index in 0..source.len() {
        assert_eq!(copy.raw_data(index), source.raw_data(index));
        assert_eq!(copy.read(index).unwrap(), source.read(index).unwrap());
        assert_eq!(copy.entries()[index].crc32, source.entries()[index].crc32);
    }
}

#[test]
fn rejects_duplicate_names() {
    let mut zip = ZipWriter::new();
    zip.add("a.txt", b"1", Compression::Stored).unwrap();
    assert_eq!(
        zip.add("a.txt", b"2", Compression::Stored),
        Err(ZipError::Duplicate("a.txt".into()))
    );
}

#[test]
fn reads_forced_zip64_archives() {
    let mut zip = ZipWriter::new();
    zip.force_zip64();
    zip.add("big.bin", &vec![7u8; 10_000], Compression::DEFAULT).unwrap();
    zip.add("small.txt", b"hi", Compression::Stored).unwrap();
    let archive = ZipArchive::new(zip.finish()).unwrap();
    assert_eq!(archive.read_named("big.bin").unwrap(), vec![7u8; 10_000]);
    assert_eq!(archive.read_named("small.txt").unwrap(), b"hi");
}

#[test]
fn reads_archives_with_prepended_bytes() {
    let mut data = b"#!/bin/sh\necho self-extractor\nexit 0\n".to_vec();
    data.extend_from_slice(&sample());
    let archive = ZipArchive::new(data).unwrap();
    assert_eq!(archive.read_named("[Content_Types].xml").unwrap(), b"<Types/>");
}

#[test]
fn reads_archives_with_a_comment() {
    let mut data = sample();
    let n = data.len();
    // Rewrite the (empty) comment length and append a comment.
    data[n - 2..].copy_from_slice(&5u16.to_le_bytes());
    data.extend_from_slice(b"hello");
    let archive = ZipArchive::new(data).unwrap();
    assert_eq!(archive.comment(), b"hello");
    assert_eq!(archive.len(), 4);
}

#[test]
fn decodes_cp437_and_unicode_path_names() {
    // Build a stored entry by hand with a CP437 name (0x84 = 'ä').
    let mut zip = ZipWriter::new();
    zip.add("placeholder", b"x", Compression::Stored).unwrap();
    let mut data = zip.finish();
    let raw_name = b"placeholder";
    let position = |data: &[u8], needle: &[u8]| {
        data.windows(needle.len()).position(|w| w == needle).unwrap()
    };
    let local = position(&data, raw_name);
    data[local] = 0x84;
    let central = local + 1 + position(&data[local + 1..], raw_name);
    data[central] = 0x84;
    let archive = ZipArchive::new(data).unwrap();
    assert_eq!(archive.entries()[0].name, "älaceholder");
    assert_eq!(archive.read(0).unwrap(), b"x");
}

#[test]
fn detects_damage() {
    assert_eq!(ZipArchive::new(b"not a zip".to_vec()).unwrap_err(), ZipError::NotZip);
    assert_eq!(ZipArchive::new(Vec::new()).unwrap_err(), ZipError::NotZip);

    // Flip a byte inside the compressed data of the stored mimetype entry.
    let mut data = sample();
    let at = data
        .windows(b"application/vnd".len())
        .position(|w| w == b"application/vnd")
        .unwrap();
    data[at] = b'A';
    let archive = ZipArchive::new(data).unwrap();
    let index = archive.find("mimetype").unwrap();
    assert_eq!(archive.read(index), Err(ZipError::Checksum("mimetype".into())));
    // Salvage is still possible.
    assert!(archive.read_unchecked(index).unwrap().starts_with(b"Application"));

    // A truncated archive loses its directory.
    let data = sample();
    assert!(ZipArchive::new(data[..data.len() / 2].to_vec()).is_err());
}

#[test]
fn enforces_size_limits() {
    let mut zip = ZipWriter::new();
    zip.add("zeros", &vec![0u8; 1 << 20], Compression::DEFAULT).unwrap();
    let data = zip.finish();
    let limits = ReadLimits {
        max_entry_size: 1000,
        max_entries: 10,
    };
    let archive = ZipArchive::with_limits(data.clone(), limits).unwrap();
    assert_eq!(archive.read(0), Err(ZipError::TooLarge("zeros".into())));
    // A lying size field cannot get around the limit either.
    assert_eq!(archive.read_unchecked(0), Err(ZipError::TooLarge("zeros".into())));
    let few = ReadLimits {
        max_entry_size: 1 << 30,
        max_entries: 0,
    };
    assert!(matches!(ZipArchive::with_limits(data, few), Err(ZipError::TooLarge(_))));
}

#[test]
fn reports_encrypted_and_unsupported_entries() {
    let mut data = sample();
    // Set the encryption flag on the first entry, in both headers.
    let central = data
        .windows(4)
        .position(|w| w == read_sig_central())
        .unwrap();
    data[central + 8] |= 1;
    let archive = ZipArchive::new(data).unwrap();
    assert_eq!(archive.read(0), Err(ZipError::Encrypted("[Content_Types].xml".into())));

    let mut data = sample();
    let central = data
        .windows(4)
        .position(|w| w == read_sig_central())
        .unwrap();
    data[central + 10] = 14; // LZMA
    let archive = ZipArchive::new(data).unwrap();
    assert!(matches!(archive.read(0), Err(ZipError::UnsupportedMethod { method: 14, .. })));
}

fn read_sig_central() -> [u8; 4] {
    0x0201_4b50u32.to_le_bytes()
}

#[test]
fn non_ascii_names_are_flagged_utf8() {
    let mut zip = ZipWriter::new();
    zip.add("ఫైల్.txt", b"telugu", Compression::Stored).unwrap();
    let archive = ZipArchive::new(zip.finish()).unwrap();
    assert_eq!(archive.entries()[0].name, "ఫైల్.txt");
    assert_ne!(archive.entries()[0].flags & (1 << 11), 0);
}

#[test]
fn dos_dates() {
    assert_eq!(write::civil_for_test(0), (1970, 1, 1));
    assert_eq!(write::civil_for_test(19_000), (2022, 1, 8));
    let t = DosDateTime::from_civil(2026, 10, 13, 14, 30, 59);
    assert_eq!(t.date >> 9, 46);
    assert_eq!((t.date >> 5) & 0xF, 10);
    assert_eq!(t.date & 0x1F, 13);
    assert_eq!(t.time >> 11, 14);
    assert_eq!((t.time >> 5) & 0x3F, 30);
    assert_eq!(t.time & 0x1F, 29);
    let now = DosDateTime::now_utc();
    assert!(now.date >> 9 >= 46);
}

#[test]
fn empty_archive() {
    let data = ZipWriter::new().finish();
    assert_eq!(data.len(), 22);
    let archive = ZipArchive::new(data).unwrap();
    assert!(archive.is_empty());
}

// Hostile archives. Each is built here rather than committed as a file:
// `bomb` makes a deflate stream of zeros at about 1000:1, and `hand_built`
// writes headers that say whatever a test needs, true or not.

/// A raw deflate stream that inflates to `megabytes` MB of zeros: one
/// compressed megabyte, repeated (each copy refers only to itself), then an
/// empty final block.
fn bomb(megabytes: usize) -> Vec<u8> {
    let mut compress = flate2::Compress::new(flate2::Compression::best(), false);
    let mut chunk = Vec::with_capacity(4096);
    compress
        .compress_vec(&vec![0u8; 1 << 20], &mut chunk, flate2::FlushCompress::Sync)
        .unwrap();
    let mut out = Vec::with_capacity(chunk.len() * megabytes + 5);
    for _ in 0..megabytes {
        out.extend_from_slice(&chunk);
    }
    out.extend_from_slice(&[0x01, 0x00, 0x00, 0xFF, 0xFF]);
    out
}

/// The CRC-32 of `megabytes` MB of zeros.
fn zeros_crc(megabytes: usize) -> u32 {
    let mut crc = Crc32::new();
    let zeros = vec![0u8; 1 << 20];
    for _ in 0..megabytes {
        crc.update(&zeros);
    }
    crc.finish()
}

/// One local entry of a hand-built archive: its stored bytes and what its
/// headers claim.
struct Raw {
    name: String,
    method: u16,
    data: Vec<u8>,
    size: u32,
    crc: u32,
    local_extra: Vec<u8>,
    central_extra: Vec<u8>,
    /// Written into the central record's offset field instead of the real one.
    offset_field: Option<u32>,
}

impl Raw {
    fn deflated(name: &str, data: Vec<u8>, size: u32, crc: u32) -> Raw {
        Raw {
            name: name.into(),
            method: METHOD_DEFLATED,
            data,
            size,
            crc,
            local_extra: Vec::new(),
            central_extra: Vec::new(),
            offset_field: None,
        }
    }
}

/// An archive of `locals`, whose central directory lists, in order, the
/// local entry each `(index, name)` gives under that name, so several
/// records may share one entry's data.
fn hand_built(prefix: &[u8], locals: &[Raw], directory: &[(usize, String)]) -> Vec<u8> {
    let mut out = prefix.to_vec();
    let mut offsets = Vec::new();
    for raw in locals {
        offsets.push((out.len() - prefix.len()) as u32);
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&raw.method.to_le_bytes());
        out.extend_from_slice(&[0; 4]);
        out.extend_from_slice(&raw.crc.to_le_bytes());
        out.extend_from_slice(&(raw.data.len() as u32).to_le_bytes());
        out.extend_from_slice(&raw.size.to_le_bytes());
        out.extend_from_slice(&(raw.name.len() as u16).to_le_bytes());
        out.extend_from_slice(&(raw.local_extra.len() as u16).to_le_bytes());
        out.extend_from_slice(raw.name.as_bytes());
        out.extend_from_slice(&raw.local_extra);
        out.extend_from_slice(&raw.data);
    }
    let directory_start = (out.len() - prefix.len()) as u32;
    for (index, name) in directory {
        let raw = &locals[*index];
        out.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&raw.method.to_le_bytes());
        out.extend_from_slice(&[0; 4]);
        out.extend_from_slice(&raw.crc.to_le_bytes());
        out.extend_from_slice(&(raw.data.len() as u32).to_le_bytes());
        out.extend_from_slice(&raw.size.to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&(raw.central_extra.len() as u16).to_le_bytes());
        // Comment length, disk, internal and external attributes.
        out.extend_from_slice(&[0; 10]);
        out.extend_from_slice(&raw.offset_field.unwrap_or(offsets[*index]).to_le_bytes());
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(&raw.central_extra);
    }
    let directory_size = (out.len() - prefix.len()) as u32 - directory_start;
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&(directory.len() as u16).to_le_bytes());
    out.extend_from_slice(&(directory.len() as u16).to_le_bytes());
    out.extend_from_slice(&directory_size.to_le_bytes());
    out.extend_from_slice(&directory_start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// Tests that inflate a lot take this lock, so that the peak memory one
/// measures is its own.
static HEAVY: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The process's peak resident memory, in bytes, while `f` runs (Linux;
/// elsewhere 0). Writing 5 to `clear_refs` resets the peak first.
fn peak_memory<T>(f: impl FnOnce() -> T) -> (T, u64) {
    let _ = std::fs::write("/proc/self/clear_refs", "5");
    let value = f();
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let kb = status
        .lines()
        .find_map(|line| line.strip_prefix("VmHWM:"))
        .and_then(|rest| rest.trim().trim_end_matches("kB").trim().parse::<u64>().ok())
        .unwrap_or(0);
    (value, kb << 10)
}

const MB: u64 = 1 << 20;

#[test]
fn a_size_field_that_lies_cannot_inflate_a_bomb() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    // 1 GB of zeros in about a megabyte, whose headers claim 1000 bytes.
    let data = hand_built(b"", &[Raw::deflated("bomb.xml", bomb(1024), 1000, 0)], &[(0, "bomb.xml".into())]);
    let archive = ZipArchive::new(data).unwrap();
    let start = std::time::Instant::now();
    let (result, peak) = peak_memory(|| archive.read(0));
    assert_eq!(result, Err(ZipError::Corrupt("'bomb.xml' has the wrong size".into())));
    assert!(start.elapsed().as_secs_f64() < 1.0, "took {:?}", start.elapsed());
    assert!(peak < 100 * MB, "peak memory {} MB", peak / MB);
}

#[test]
fn an_entry_cannot_expand_past_the_ratio_limit() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    // 400 MB of zeros from 400 KB, its size stated honestly: under the
    // 512 MB entry limit, but a thousand times its compressed size, which no
    // real part reaches. (Its checksum is never reached.)
    let size = 400u32 << 20;
    let data = hand_built(b"", &[Raw::deflated("big.bin", bomb(400), size, 0)], &[(0, "big.bin".into())]);
    let archive = ZipArchive::new(data).unwrap();
    let start = std::time::Instant::now();
    let (checked, peak) = peak_memory(|| archive.read(0));
    assert_eq!(checked, Err(ZipError::TooLarge("big.bin".into())));
    assert!(start.elapsed().as_secs_f64() < 1.0, "took {:?}", start.elapsed());
    assert!(peak < 100 * MB, "peak memory {} MB", peak / MB);
    // The salvaging read, which ignores the stated size, inflates up to the
    // 256 MB floor before it stops: bounded by that, not by the 400 MB.
    let (unchecked, peak) = peak_memory(|| archive.read_unchecked(0));
    assert_eq!(unchecked, Err(ZipError::TooLarge("big.bin".into())));
    assert!(peak < 300 * MB, "peak memory {} MB", peak / MB);

    // A tighter floor stops it sooner.
    let limits = ExpansionLimits { ratio_floor: 16 << 20, ..ExpansionLimits::default() };
    let data = hand_built(b"", &[Raw::deflated("big.bin", bomb(400), size, 0)], &[(0, "big.bin".into())]);
    let archive = ZipArchive::with_all_limits(data, ReadLimits::default(), limits).unwrap();
    let start = std::time::Instant::now();
    let (unchecked, peak) = peak_memory(|| archive.read_unchecked(0));
    assert_eq!(unchecked, Err(ZipError::TooLarge("big.bin".into())));
    assert!(start.elapsed().as_secs_f64() < 1.0, "took {:?}", start.elapsed());
    assert!(peak < 100 * MB, "peak memory {} MB", peak / MB);
}

#[test]
fn entries_sharing_one_bomb_run_out_of_the_archive_budget() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    // Twenty directory records point at the same 50 MB of zeros (about
    // 50 KB compressed): each looks fine alone, together they make 1 GB.
    let size = 50u32 << 20;
    let locals = [Raw::deflated("part0", bomb(50), size, zeros_crc(50))];
    let directory: Vec<_> = (0..20).map(|i| (0, format!("part{i}"))).collect();
    let archive = ZipArchive::new(hand_built(b"", &locals, &directory)).unwrap();
    let start = std::time::Instant::now();
    let (results, peak) = peak_memory(|| (0..20).map(|i| archive.read(i).map(|bytes| bytes.len())).collect::<Vec<_>>());
    // The budget for a small archive is the 256 MB floor: five parts fit.
    let read = results.iter().take_while(|r| r.is_ok()).count();
    assert_eq!(read, 5, "{results:?}");
    assert_eq!(results[5], Err(ZipError::TooLarge("part5".into())));
    assert!(start.elapsed().as_secs_f64() < 2.0, "took {:?}", start.elapsed());
    assert!(peak < 150 * MB, "peak memory {} MB", peak / MB);
    // Reading a part again does not count it twice.
    assert_eq!(archive.read(0).map(|b| b.len()), Ok(size as usize));
    assert_eq!(archive.inflated_bytes(), 5 * size as u64);
}

#[test]
fn read_at_most_refuses_larger_entries() {
    let archive = ZipArchive::new(sample()).unwrap();
    let index = archive.find("word/document.xml").unwrap();
    let size = archive.entries()[index].size;
    assert_eq!(archive.read_at_most(index, size).unwrap().len() as u64, size);
    assert_eq!(archive.read_at_most(index, size - 1), Err(ZipError::TooLarge("word/document.xml".into())));
}

/// Running out of memory while inflating is an error, not an abort. The
/// test runs itself again under an address-space limit (`prlimit`), where
/// the 200 MB an honest entry needs cannot be had.
#[test]
#[cfg(target_os = "linux")]
fn running_out_of_memory_is_too_large_not_an_abort() {
    const CHILD: &str = "DOC_ZIP_OUT_OF_MEMORY_CHILD";
    let size = 200u32 << 20;
    if std::env::var_os(CHILD).is_some() {
        let data = hand_built(b"", &[Raw::deflated("big.bin", bomb(200), size, zeros_crc(200))], &[(0, "big.bin".into())]);
        let archive = ZipArchive::new(data).unwrap();
        assert_eq!(archive.read(0).map(|b| b.len()), Err(ZipError::TooLarge("big.bin".into())));
        return;
    }
    let exe = std::env::current_exe().unwrap();
    let status = std::process::Command::new("prlimit")
        .arg(format!("--as={}", 192u64 << 20))
        .arg(&exe)
        .args(["--exact", "tests::running_out_of_memory_is_too_large_not_an_abort", "--test-threads=1"])
        .env(CHILD, "1")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    match status {
        // No prlimit on this machine: nothing to check.
        Err(_) => {}
        Ok(status) => assert!(status.success(), "the child failed: {status}"),
    }
}

#[test]
fn copying_keeps_extra_fields() {
    // An extended timestamp (0x5455) and Unix owner (0x7875) in the local
    // header, the timestamp alone in the directory, as Info-ZIP writes them.
    let local_extra = [
        &[0x55, 0x54, 9, 0, 3][..],
        &0x6000_0000u32.to_le_bytes(),
        &0x6000_0001u32.to_le_bytes(),
        &[0x75, 0x78, 11, 0, 1, 4],
        &1000u32.to_le_bytes(),
        &[4],
        &1000u32.to_le_bytes(),
    ]
    .concat();
    let central_extra = [&[0x55, 0x54, 5, 0, 3][..], &0x6000_0000u32.to_le_bytes()].concat();
    let raw = Raw {
        name: "notes.txt".into(),
        method: METHOD_STORED,
        data: b"hello".to_vec(),
        size: 5,
        crc: crc32(b"hello"),
        local_extra: local_extra.clone(),
        central_extra: central_extra.clone(),
        offset_field: None,
    };
    let source = ZipArchive::new(hand_built(b"", &[raw], &[(0, "notes.txt".into())])).unwrap();
    let mut zip = ZipWriter::new();
    zip.copy_from(&source, 0).unwrap();
    let copied = zip.finish();
    let contains = |needle: &[u8]| copied.windows(needle.len()).any(|w| w == needle);
    let local_at = copied.windows(4).position(|w| w == 0x0403_4b50u32.to_le_bytes()).unwrap();
    assert_eq!(&copied[local_at + 28..local_at + 30], &(local_extra.len() as u16).to_le_bytes());
    assert!(contains(&[b"notes.txt".as_slice(), &local_extra].concat()), "local extra fields kept");
    assert!(contains(&[b"notes.txt".as_slice(), &central_extra].concat()), "central extra fields kept");
    let copy = ZipArchive::new(copied.clone()).unwrap();
    assert_eq!(copy.read(0).unwrap(), b"hello");

    // A ZIP64 entry's own field is written afresh, not carried twice.
    let mut zip = ZipWriter::new();
    zip.force_zip64();
    zip.add("wide.txt", b"wide", Compression::Stored).unwrap();
    let source = ZipArchive::new(zip.finish()).unwrap();
    let mut zip = ZipWriter::new();
    zip.copy_from(&source, 0).unwrap();
    let copied = zip.finish();
    assert_eq!(copied.windows(4).filter(|w| *w == [1, 0, 16, 0]).count(), 0, "no stale ZIP64 field");
    assert_eq!(ZipArchive::new(copied).unwrap().read(0).unwrap(), b"wide");
}

#[test]
fn an_offset_that_overflows_is_damage_not_a_panic() {
    // Bytes before the archive shift every offset; a ZIP64 offset near the
    // top of the range then overflows.
    let zip64 = [&[1, 0, 8, 0][..], &(u64::MAX - 4).to_le_bytes()].concat();
    let raw = Raw {
        name: "a.txt".into(),
        method: METHOD_STORED,
        data: b"a".to_vec(),
        size: 1,
        crc: crc32(b"a"),
        local_extra: Vec::new(),
        central_extra: zip64,
        offset_field: Some(u32::MAX),
    };
    let data = hand_built(b"prepended bytes", &[raw], &[(0, "a.txt".into())]);
    assert!(matches!(ZipArchive::new(data), Err(ZipError::Corrupt(_))));
}

#[test]
fn duplicate_names_are_reported() {
    let raws = [
        Raw { method: METHOD_STORED, ..Raw::deflated("a.xml", b"first".to_vec(), 5, crc32(b"first")) },
        Raw { method: METHOD_STORED, ..Raw::deflated("a.xml", b"again".to_vec(), 5, crc32(b"again")) },
        Raw { method: METHOD_STORED, ..Raw::deflated("b.xml", b"b".to_vec(), 1, crc32(b"b")) },
    ];
    let directory = [(0, "a.xml".into()), (1, "a.xml".into()), (2, "b.xml".into())];
    let archive = ZipArchive::new(hand_built(b"", &raws, &directory)).unwrap();
    assert_eq!(archive.read_named("a.xml").unwrap(), b"first");
    assert!(!archive.is_duplicate(0));
    assert!(archive.is_duplicate(1));
    assert!(!archive.is_duplicate(2));
    assert_eq!(archive.duplicate_names(), ["a.xml"]);
}
