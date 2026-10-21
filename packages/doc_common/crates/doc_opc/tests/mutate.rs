use std::time::Duration;

use doc_opc::{Package, PackageLimits, Rels};
use doc_testkit::{mutate, run_limited, Limits, Rng};
use doc_zip::{Compression, ZipArchive, ZipWriter};

const SEED: u64 = 0x5048_4153_4531_3042;
const ITERATIONS: usize = 4096;
const MAIN: &str = "a/main.xml";
const XML: &[u8] = br#"<?xml version="1.0"?><main xmlns:a="urn:unknown"><a:item count="1">original &amp; preserved</a:item></main>"#;
const RELS: &[u8] = br#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="a/main.xml"/></Relationships>"#;
const FLAT: &[u8] = br#"<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:mimetype="application/vnd.oasis.opendocument.text"><office:body><office:text><text:p>original</text:p></office:text></office:body></office:document>"#;

fn package() -> Vec<u8> {
    let mut writer = ZipWriter::new();
    writer.add("_rels/.rels", RELS, Compression::DEFAULT).unwrap();
    writer.add(MAIN, XML, Compression::DEFAULT).unwrap();
    writer.add("opaque/unknown.bin", &(0..=255).collect::<Vec<u8>>(), Compression::Stored).unwrap();
    writer.add("opaque/compressed.bin", &b"untouched opaque bytes".repeat(40), Compression::DEFAULT).unwrap();
    writer.finish()
}

/// Text as it reads back after a save: characters XML cannot hold are written as U+FFFD.
fn xml_text(text: &str) -> String {
    text.chars().map(|c| match c {
        '\t' | '\n' | '\r' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..='\u{10FFFF}' => c,
        _ => '\u{FFFD}',
    }).collect()
}

fn raw_unchanged(before: &ZipArchive, after: &ZipArchive, edited: Option<&str>) {
    for (index, entry) in before.entries().iter().enumerate() {
        // Part names are case-insensitive, so an edit replaces an entry whose name differs only in case.
        if edited.is_some_and(|e| e.eq_ignore_ascii_case(&entry.name)) || before.is_duplicate(index) { continue; }
        let saved = after.find(&entry.name).expect("untouched entry missing");
        let saved_entry = &after.entries()[saved];
        assert_eq!((saved_entry.crc32, saved_entry.method, saved_entry.size), (entry.crc32, entry.method, entry.size), "{}", entry.name);
        assert_eq!(after.raw_data(saved), before.raw_data(index), "raw bytes changed: {}", entry.name);
    }
}

#[test]
fn unedited_save_is_identical_and_edit_preserves_opaque_entries() {
    run_limited("unedited_save_is_identical_and_edit_preserves_opaque_entries", Limits::mutation(Duration::from_secs(10)), || {
        let original = package();
        let mut doc = Package::open(original.clone()).unwrap();
        assert_eq!(doc.save().unwrap(), original);
        let replacement = b"<main>edited content survives reopen</main>";
        doc.set(MAIN, replacement.to_vec());
        let saved = doc.save().unwrap();
        let reopened = Package::open(saved).unwrap();
        raw_unchanged(&doc.archive, &reopened.archive, Some(MAIN));
        assert_eq!(reopened.read(MAIN).unwrap(), replacement);
        assert_eq!(reopened.read_xml(MAIN).unwrap().root.text(), "edited content survives reopen");
    }).unwrap();
}

#[test]
fn fuzz_zip_and_opc_fixed_seed() {
    run_limited("fuzz_zip_and_opc_fixed_seed", Limits::mutation(Duration::from_secs(90)), || {
        let seed = package();
        let mut rng = Rng::new(SEED);
        let mut opened = 0;
        for iteration in 0..ITERATIONS {
            let bytes = mutate(&mut rng, &seed, XML);
            let limits = PackageLimits { max_xml_part: 2 << 20, max_part: 4 << 20, max_total: 16 << 20, ..PackageLimits::default() };
            if let Ok(mut doc) = Package::open_with_limits(bytes, limits) {
                opened += 1;
                for part in doc.part_names() {
                    let _ = doc.read(&part);
                    if part.ends_with(".xml") || part.ends_with(".rels") { let _ = doc.read_xml(&part); }
                }
                let _ = doc.main_part();
                if let Ok(saved) = doc.save() {
                    let reopened = Package::open_with_limits(saved, limits).unwrap();
                    raw_unchanged(&doc.archive, &reopened.archive, None);
                }
                doc.set(MAIN, b"<main>changed</main>".to_vec());
                if let Ok(saved) = doc.save() {
                    let reopened = Package::open_with_limits(saved, limits).unwrap();
                    raw_unchanged(&doc.archive, &reopened.archive, Some(MAIN));
                    assert_eq!(reopened.read(MAIN).unwrap(), b"<main>changed</main>", "seed {SEED:x} iteration {iteration}");
                }
            }
        }
        assert!(opened > 0);
        eprintln!("ZIP/OPC seed={SEED:x} iterations={ITERATIONS} opened={opened}");
    }).unwrap();
}

#[test]
fn fuzz_xml_relationships_and_flat_odf_fixed_seed() {
    run_limited("fuzz_xml_relationships_and_flat_odf_fixed_seed", Limits::mutation(Duration::from_secs(90)), || {
        let mut rng = Rng::new(SEED ^ 1);
        let seeds = [XML, RELS, FLAT];
        let mut parsed = 0;
        for iteration in 0..ITERATIONS {
            let bytes = mutate(&mut rng, seeds[iteration % seeds.len()], seeds[(iteration + 1) % seeds.len()]);
            if let Ok(doc) = doc_xml::Document::parse(&bytes) {
                parsed += 1;
                let copy = doc.clone();
                assert_eq!(copy, doc);
                let saved = doc.to_bytes();
                if let Ok(reopened) = doc_xml::Document::parse(&saved) {
                    assert_eq!(reopened.root.text(), xml_text(&doc.root.text()), "iteration {iteration}: {:?} saved as {:?}",
                        String::from_utf8_lossy(&bytes), String::from_utf8_lossy(&saved));
                }
            }
            if let Ok(rels) = Rels::parse(MAIN, &bytes) {
                for rel in rels.list() { let _ = rels.by_id(&rel.id); let _ = rels.part_of(&rel); }
            }
            let _ = doc_odf::flat_mimetype(&bytes);
            if let Ok(package) = doc_odf::unflatten(&bytes) {
                let _ = doc_odf::flatten(&package);
                let _ = Package::open(package);
            }
        }
        assert!(parsed > 0);
        eprintln!("XML/relationships/ODF seed={:x} iterations={ITERATIONS} parsed={parsed}", SEED ^ 1);
    }).unwrap();
}
