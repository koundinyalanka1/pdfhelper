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
