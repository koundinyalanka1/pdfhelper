use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use doc_zip::{Compression, ZipWriter};

use super::*;
use crate::paths::{display_name, numbered, safe_components, safe_path};
use crate::time::{dos_from_system, dos_to_iso, unix_to_iso};

/// A scratch folder, removed when dropped.
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "archive_core_{tag}_{}_{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// An entry for [`raw_zip`], which writes headers exactly as told.
struct Raw<'a> {
    name: &'a [u8],
    data: &'a [u8],
    method: u16,
    flags: u16,
    made_by: u16,
    attributes: u32,
    /// The uncompressed size to declare, when not `data.len()`.
    size: Option<u32>,
}

impl<'a> Raw<'a> {
    fn file(name: &'a str, data: &'a [u8]) -> Self {
        Self { name: name.as_bytes(), data, method: 0, flags: 0, made_by: 20, attributes: 0, size: None }
    }
}

/// A ZIP whose every field the test chooses: links, encryption flags and
/// hostile names that the real writer would never produce.
fn raw_zip(entries: &[Raw]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for e in entries {
        let offset = out.len() as u32;
        let crc = doc_zip::crc32(e.data);
        let size = e.size.unwrap_or(e.data.len() as u32);
        let mut common = Vec::new();
        common.extend_from_slice(&20u16.to_le_bytes());
        common.extend_from_slice(&e.flags.to_le_bytes());
        common.extend_from_slice(&e.method.to_le_bytes());
        common.extend_from_slice(&0x7000u16.to_le_bytes()); // 14:00
        common.extend_from_slice(&0x5865u16.to_le_bytes()); // 2024-03-05
        common.extend_from_slice(&crc.to_le_bytes());
        common.extend_from_slice(&(e.data.len() as u32).to_le_bytes());
        common.extend_from_slice(&size.to_le_bytes());
        common.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
        common.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&common);
        out.extend_from_slice(e.name);
        out.extend_from_slice(e.data);
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&e.made_by.to_le_bytes());
        central.extend_from_slice(&common);
        central.extend_from_slice(&[0; 6]); // comment length, disk, internal attributes
        central.extend_from_slice(&e.attributes.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(e.name);
    }
    let directory = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&directory.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// Every file under `dir`, relative and `/`-separated, with its contents.
fn tree(dir: &Path) -> Vec<(String, Vec<u8>)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>) {
        for child in fs::read_dir(dir).unwrap() {
            let path = child.unwrap().path();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                walk(root, &path, out);
            } else {
                let rel = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
                out.push((rel, fs::read(&path).unwrap_or_default()));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

fn names(archive: &Archive) -> Vec<&str> {
    archive.entries().iter().map(|e| e.path.as_str()).collect()
}

/// Run `python3 -I -c script args...`; `false` when Python is missing.
fn python(script: &str, args: &[&Path]) -> bool {
    let mut command = Command::new("python3");
    command.arg("-I").arg("-c").arg(script).args(args);
    match command.output() {
        Ok(out) if out.status.success() => true,
        Ok(out) => panic!("python failed: {}", String::from_utf8_lossy(&out.stderr)),
        Err(_) => {
            eprintln!("python3 is not installed; skipping");
            false
        }
    }
}

/// Run a command in `dir`; `false` when the tool is missing.
fn tool(dir: &Path, program: &str, args: &[&str]) -> bool {
    match Command::new(program).current_dir(dir).args(args).output() {
        Ok(out) if out.status.success() => true,
        Ok(out) => panic!("{program} failed: {}", String::from_utf8_lossy(&out.stderr)),
        Err(_) => {
            eprintln!("{program} is not installed; skipping");
            false
        }
    }
}

fn small_limits() -> Limits {
    Limits { max_ratio: 100, ratio_floor: 1 << 20, ..Limits::default() }
}

#[test]
fn names_become_safe_relative_paths() {
    let ok = |name: &str| safe_components(name).unwrap().join("/");
    assert_eq!(ok("docs/a.txt"), "docs/a.txt");
    assert_eq!(ok("../x"), "x");
    assert_eq!(ok("/etc/x"), "etc/x");
    assert_eq!(ok("C:\\x"), "x");
    assert_eq!(ok("c:x"), "x");
    assert_eq!(ok("a\\..\\..\\b"), "a/b");
    assert_eq!(ok("//server/share/./f"), "server/share/f");
    assert_eq!(ok("./"), "");
    assert_eq!(ok("a/ b. /c"), "a/ b/c");
    assert_eq!(ok("what?.txt"), "what_.txt");
    assert_eq!(ok("ab:y|z<1>\"*"), "ab_y_z_1___");
    assert_eq!(ok("tab\there"), "tab_here");
    assert_eq!(ok("..."), "_");
    assert_eq!(ok("रिपोर्ट/日本語.txt"), "रिपोर्ट/日本語.txt");
    assert_eq!(safe_components("bad\0name"), Err(BadName::Nul));
    assert_eq!(safe_path("../"), None);

    let long = format!("{}.pdf", "न".repeat(200));
    let short = ok(&long);
    assert!(short.len() <= 240 && short.ends_with(".pdf"), "{short}");
    assert!(short.starts_with('न'));

    assert_eq!(numbered("photo.jpg", 2, false), "photo (2).jpg");
    assert_eq!(numbered(".profile", 3, false), ".profile (3)");
    assert_eq!(numbered("v1.2", 2, true), "v1.2 (2)");
    assert_eq!(display_name("docs/a.txt"), "a.txt");
    assert_eq!(display_name("docs/"), "docs");
    assert_eq!(display_name("win\\dir\\b.txt"), "b.txt");
    assert_eq!(display_name("/"), "/");
}

#[test]
fn dates_read_as_iso_8601() {
    assert_eq!(dos_to_iso(0x5865, 0x7000).as_deref(), Some("2024-03-05T14:00:00"));
    assert_eq!(dos_to_iso(0, 0), None);
    // 2023-02-29 does not exist.
    assert_eq!(dos_to_iso((43 << 9) | (2 << 5) | 29, 0), None);
    assert_eq!(unix_to_iso(0).as_deref(), Some("1970-01-01T00:00:00Z"));
    assert_eq!(unix_to_iso(1_700_000_000).as_deref(), Some("2023-11-14T22:13:20Z"));
    let time = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
    let dos = dos_from_system(time, 330);
    assert_eq!(dos_to_iso(dos.date, dos.time).as_deref(), Some("2023-11-15T03:43:20"));
    let old = dos_from_system(std::time::UNIX_EPOCH, 0);
    assert_eq!(dos_to_iso(old.date, old.time).as_deref(), Some("1980-01-01T00:00:00"));
}

#[test]
fn create_list_extract_round_trip() {
    let dir = TempDir::new("round");
    let src = dir.join("src");
    fs::create_dir_all(src.join("Photos/Empty")).unwrap();
    fs::create_dir_all(src.join("दस्तावेज़")).unwrap();
    fs::write(src.join("notes.txt"), "Total: ₹500\n".repeat(200)).unwrap();
    fs::write(src.join("Photos/beach.jpg"), [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]).unwrap();
    fs::write(src.join("दस्तावेज़/रिपोर्ट.txt"), "नमस्ते").unwrap();
    fs::write(src.join("दस्तावेज़/日本語 😀.md"), "# hi").unwrap();
    let single = dir.join("loose.csv");
    fs::write(&single, "a,b\n1,2\n").unwrap();

    let out = dir.join("bundle.zip");
    let sources = [
        Source::new(src.join("notes.txt")),
        Source::named(src.join("Photos"), "Pictures"),
        Source::new(src.join("दस्तावेज़")),
        Source::named(&single, "data/table.csv"),
        // Clashes with the first source, so it is numbered.
        Source::new(src.join("notes.txt")),
    ];
    let options = CreateOptions { utc_offset_minutes: 330, ..CreateOptions::default() };
    let created = create_zip(&sources, &out, &options).unwrap();
    assert_eq!(created.files, 6);
    assert_eq!(created.folders, 4);
    assert_eq!(created.bytes, fs::metadata(&out).unwrap().len());

    let archive = Archive::open(&out).unwrap();
    assert_eq!(archive.format(), Format::Zip);
    assert_eq!(
        names(&archive),
        [
            "notes.txt",
            "Pictures/",
            "Pictures/Empty/",
            "Pictures/beach.jpg",
            "दस्तावेज़/",
            "दस्तावेज़/रिपोर्ट.txt",
            "दस्तावेज़/日本語 😀.md",
            "data/",
            "data/table.csv",
            "notes (2).txt",
        ]
    );
    let notes = &archive.entries()[0];
    assert_eq!(notes.kind, EntryKind::File);
    assert_eq!(notes.size, 200 * "Total: ₹500\n".len() as u64);
    assert!(notes.compressed_size.unwrap() < notes.size / 10);
    assert_eq!(notes.method, Method::Deflated);
    assert!(notes.modified.is_some());
    let photo = &archive.entries()[3];
    assert_eq!(photo.method, Method::Stored, "photos are stored as they are");
    assert_eq!(photo.name, "beach.jpg");
    let folder = &archive.entries()[1];
    assert!(folder.is_dir());
    assert_eq!(folder.name, "Pictures");
    assert_eq!(folder.size, 0);

    assert_eq!(archive.read(5).unwrap(), "नमस्ते".as_bytes());
    let one = dir.join("one.md");
    assert_eq!(archive.extract(6, &one).unwrap(), 4);
    assert_eq!(fs::read(&one).unwrap(), b"# hi");
    assert!(matches!(archive.extract(1, &one), Err(ArchiveError::Invalid(_))));
    assert!(matches!(archive.extract(99, &one), Err(ArchiveError::NotFound(_))));

    let target = dir.join("out");
    let report = archive.extract_all(&target).unwrap();
    assert!(report.skipped.is_empty(), "{:?}", report.skipped);
    assert_eq!(report.written.len(), 6);
    assert!(target.join("Pictures/Empty").is_dir());
    let files = tree(&target);
    assert_eq!(
        files.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
        [
            "Pictures/beach.jpg",
            "data/table.csv",
            "notes (2).txt",
            "notes.txt",
            "दस्तावेज़/रिपोर्ट.txt",
            "दस्तावेज़/日本語 😀.md",
        ]
    );
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), fs::read(src.join("notes.txt")).unwrap());

    // A second extraction into the same folder keeps the first one's files.
    let again = archive.extract_all(&target).unwrap();
    assert_eq!(again.written.len(), 6);
    assert!(target.join("notes (3).txt").is_file());
    assert!(target.join("Pictures/beach (2).jpg").is_file());
    let leftovers: Vec<_> = fs::read_dir(&target)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

#[test]
fn create_checks_its_input() {
    let dir = TempDir::new("create_errors");
    let options = CreateOptions::default();
    let out = dir.join("out.zip");
    assert!(matches!(create_zip(&[], &out, &options), Err(ArchiveError::Invalid(_))));
    let missing = create_zip(&[Source::new(dir.join("missing.txt"))], &out, &options).unwrap_err();
    assert!(matches!(missing, ArchiveError::Io { .. }), "{missing}");
    assert!(!out.exists(), "nothing is written when a source is missing");

    // Zipping a folder into itself leaves the old archive out.
    let folder = dir.join("folder");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("a.txt"), "a").unwrap();
    let inside = folder.join("folder.zip");
    create_zip(&[Source::new(&folder)], &inside, &options).unwrap();
    create_zip(&[Source::new(&folder)], &inside, &options).unwrap();
    assert_eq!(names(&Archive::open(&inside).unwrap()), ["folder/", "folder/a.txt"]);
    let itself = create_zip(&[Source::new(&inside)], &inside, &options).unwrap_err();
    assert!(matches!(itself, ArchiveError::Invalid(_)), "{itself}");

    let limits = Limits { max_memory_bytes: 10, ..Limits::default() };
    fs::write(folder.join("big.txt"), "more than ten bytes").unwrap();
    let too_big = create_zip(&[Source::new(&folder)], &out, &CreateOptions { limits, ..options }).unwrap_err();
    assert!(matches!(too_big, ArchiveError::TooLarge(_)), "{too_big}");
}

#[cfg(unix)]
#[test]
fn create_skips_links_inside_folders() {
    let dir = TempDir::new("create_links");
    let folder = dir.join("folder");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("real.txt"), "real").unwrap();
    std::os::unix::fs::symlink("/etc/passwd", folder.join("passwd")).unwrap();
    std::os::unix::fs::symlink(&folder, folder.join("loop")).unwrap();
    let out = dir.join("out.zip");
    create_zip(&[Source::new(&folder)], &out, &CreateOptions::default()).unwrap();
    assert_eq!(names(&Archive::open(&out).unwrap()), ["folder/", "folder/real.txt"]);
}

#[test]
fn hostile_names_never_escape() {
    let dir = TempDir::new("slip");
    let bytes = raw_zip(&[
        Raw::file("../x", b"1"),
        Raw::file("/etc/x", b"2"),
        Raw::file("C:\\x", b"3"),
        Raw::file("a\\..\\..\\b", b"4"),
        Raw::file("..\\..\\..\\evil.txt", b"5"),
        Raw::file("dir/../../up.txt", b"6"),
        Raw::file("./ok.txt", b"7"),
        Raw::file("../", b""),
        Raw::file("win\\folder\\file.txt", b"8"),
        Raw::file("bad\0name.txt", b"9"),
        Raw::file("..", b"10"),
    ]);
    let archive = Archive::from_bytes(bytes, Some("slip.zip")).unwrap();
    let safe: Vec<_> = archive.entries().iter().map(|e| e.safe_path.as_deref()).collect();
    assert_eq!(
        safe,
        [
            Some("x"),
            Some("etc/x"),
            Some("x"),
            Some("a/b"),
            Some("evil.txt"),
            Some("dir/up.txt"),
            Some("ok.txt"),
            None,
            Some("win/folder/file.txt"),
            None,
            None,
        ]
    );
    assert!(archive.entries()[7].is_dir());
    assert!(archive.entries()[8].kind == EntryKind::File);

    let target = dir.join("deep/target");
    let report = archive.extract_all(&target).unwrap();
    for path in &report.written {
        assert!(path.starts_with(&target), "{} escaped", path.display());
    }
    // Only the target was created under the scratch folder.
    assert_eq!(fs::read_dir(dir.join("deep")).unwrap().count(), 1);
    assert!(!dir.join("x").exists() && !dir.join("evil.txt").exists() && !dir.join("deep/up.txt").exists());
    let expected: Vec<(String, Vec<u8>)> = [
        ("a/b", "4"),
        ("dir/up.txt", "6"),
        ("etc/x", "2"),
        ("evil.txt", "5"),
        ("ok.txt", "7"),
        ("win/folder/file.txt", "8"),
        ("x", "1"),
        ("x (2)", "3"),
    ]
    .iter()
    .map(|(name, data)| (name.to_string(), data.as_bytes().to_vec()))
    .collect();
    assert_eq!(tree(&target), expected);
    let reasons: Vec<_> = report.skipped.iter().map(|s| (s.index, s.reason.as_str())).collect();
    assert_eq!(reasons, [(9, "its name contains a NUL character"), (10, "its name has no usable characters")]);
}

#[cfg(unix)]
#[test]
fn links_already_in_the_target_are_not_followed() {
    let dir = TempDir::new("target_link");
    let outside = dir.join("outside");
    let target = dir.join("target");
    fs::create_dir_all(&outside).unwrap();
    fs::create_dir_all(&target).unwrap();
    std::os::unix::fs::symlink(&outside, target.join("sub")).unwrap();
    let archive = Archive::from_bytes(raw_zip(&[Raw::file("sub/x.txt", b"x")]), None).unwrap();
    let report = archive.extract_all(&target).unwrap();
    assert_eq!(report.written, [target.join("sub (2)/x.txt")]);
    assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
}

#[test]
fn links_devices_and_locked_entries_are_listed_but_skipped() {
    let dir = TempDir::new("skips");
    let unix = 3 << 8;
    let bytes = raw_zip(&[
        Raw { made_by: unix, attributes: 0o120_777 << 16, ..Raw::file("link", b"/etc/passwd") },
        Raw { made_by: unix, attributes: 0o010_644 << 16, ..Raw::file("fifo", b"") },
        Raw { flags: 1, ..Raw::file("secret.txt", b"scrambled") },
        Raw { method: 12, ..Raw::file("old.bz", b"BZh9") },
        Raw { made_by: unix, attributes: 0o100_644 << 16, ..Raw::file("plain.txt", b"plain") },
        Raw { attributes: 0x10, ..Raw::file("dos folder", b"") },
    ]);
    let archive = Archive::from_bytes(bytes, None).unwrap();
    let kinds: Vec<_> = archive.entries().iter().map(|e| e.kind).collect();
    assert_eq!(
        kinds,
        [
            EntryKind::Symlink,
            EntryKind::Special,
            EntryKind::File,
            EntryKind::File,
            EntryKind::File,
            EntryKind::Directory,
        ]
    );
    let secret = &archive.entries()[2];
    assert!(secret.encrypted);
    assert!(!archive.entries()[4].encrypted);
    assert_eq!(archive.entries()[3].method.name(), "bzip2");
    assert!(matches!(archive.extract(2, &dir.join("s")), Err(ArchiveError::Encrypted(name)) if name == "secret.txt"));
    assert!(matches!(archive.read(0), Err(ArchiveError::Unsupported(_))));
    assert!(matches!(archive.read(3), Err(ArchiveError::Unsupported(_))));
    assert!(!dir.join("s").exists());

    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written, [dir.join("out/plain.txt")]);
    assert!(dir.join("out/dos folder").is_dir());
    let reasons: Vec<_> = report.skipped.iter().map(|s| s.reason.as_str()).collect();
    assert_eq!(
        reasons,
        [
            "'link' is a symbolic link, which is not extracted",
            "'fifo' is a device or other special file, which is not extracted",
            "'secret.txt' is protected with a password",
            "'old.bz' uses bzip2 compression, which is not supported",
        ]
    );
}

#[test]
fn zip_bombs_are_refused_before_writing() {
    let zeros = vec![0u8; 5 << 20];
    let mut writer = ZipWriter::new();
    writer.add("zeros.bin", &zeros, Compression::Deflated(9)).unwrap();
    let bomb = writer.finish();
    assert!(bomb.len() < 64 << 10);
    let error = Archive::from_bytes_with_limits(bomb.clone(), None, small_limits()).unwrap_err();
    assert!(matches!(&error, ArchiveError::TooLarge(m) if m.contains("zip bomb")), "{error}");
    // Under the default limits 5 MB is too little to worry about.
    assert!(Archive::from_bytes(bomb, None).is_ok());

    // Many entries that each claim far more than they hold (as overlapping
    // bombs do) are caught by the archive's own size.
    let piece = vec![7u8; 4096];
    let mut entries: Vec<Raw> = Vec::new();
    let names: Vec<String> = (0..300).map(|i| format!("copy{i}.bin")).collect();
    for name in &names {
        entries.push(Raw { size: Some(16 << 20), ..Raw::file(name, &piece) });
    }
    let overlapping = raw_zip(&entries);
    let error = Archive::from_bytes(overlapping, None).unwrap_err();
    assert!(matches!(error, ArchiveError::TooLarge(_)), "{error}");

    let limits = Limits { max_entries: 3, ..Limits::default() };
    let many = raw_zip(&[Raw::file("a", b""), Raw::file("b", b""), Raw::file("c", b""), Raw::file("d", b"")]);
    let error = Archive::from_bytes_with_limits(many, None, limits).unwrap_err();
    assert!(matches!(&error, ArchiveError::TooLarge(m) if m.contains("more than 3 entries")), "{error}");

    let limits = Limits { max_total_bytes: 100, ..Limits::default() };
    let error = Archive::from_bytes_with_limits(raw_zip(&[Raw::file("a", &[1; 101])]), None, limits).unwrap_err();
    assert!(matches!(error, ArchiveError::TooLarge(_)), "{error}");
}

#[test]
fn damaged_zips_are_reported() {
    let dir = TempDir::new("damaged");
    let mut writer = ZipWriter::new();
    writer.add("a.txt", &b"hello world, ".repeat(100), Compression::DEFAULT).unwrap();
    writer.add("b.txt", b"fine", Compression::Stored).unwrap();
    let good = writer.finish();

    let mut cut = good.clone();
    cut.truncate(cut.len() - 30);
    let error = Archive::from_bytes(cut, None).unwrap_err();
    assert!(matches!(error, ArchiveError::Corrupt(_)), "{error}");

    // Flip a byte inside a's compressed data: its checksum no longer matches.
    let mut flipped = good.clone();
    flipped[40] ^= 0x55;
    let archive = Archive::from_bytes(flipped, None).unwrap();
    assert!(matches!(archive.read(0), Err(ArchiveError::Corrupt(_))));
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written, [dir.join("out/b.txt")]);
    assert_eq!(report.skipped.len(), 1);
    assert!(report.skipped[0].reason.starts_with("'a.txt' is damaged"), "{:?}", report.skipped);
    assert!(!dir.join("out/a.txt").exists());
}

#[test]
fn self_extracting_and_zip64_archives_open() {
    let mut writer = ZipWriter::new();
    writer.force_zip64();
    writer.add("inside.txt", b"inside", Compression::DEFAULT).unwrap();
    let mut bytes = b"MZ\x90\x00 a program that unpacks what follows".repeat(40);
    bytes.extend_from_slice(&writer.finish());
    let archive = Archive::from_bytes(bytes, Some("setup.exe")).unwrap();
    assert_eq!(archive.format(), Format::Zip);
    assert_eq!(archive.read(0).unwrap(), b"inside");
}

#[test]
fn other_files_are_not_archives() {
    let unsupported = |bytes: &[u8]| match Archive::from_bytes(bytes.to_vec(), None) {
        Err(ArchiveError::Unsupported(m)) => m,
        other => panic!("{other:?}"),
    };
    assert_eq!(unsupported(b"just some text"), NOT_AN_ARCHIVE);
    assert_eq!(unsupported(b""), NOT_AN_ARCHIVE);
    assert!(unsupported(b"Rar!\x1A\x07\x01\x00rest").starts_with("RAR"));
    assert!(unsupported(b"7z\xBC\xAF\x27\x1C\x00\x04").starts_with("7-Zip"));
    assert!(unsupported(b"BZh91AY&SY").starts_with("bzip2"));
    assert!(unsupported(b"BZhello").starts_with("this is not"));
    let dir = TempDir::new("not_archives");
    let folder = Archive::open(&dir.0).unwrap_err();
    assert!(matches!(folder, ArchiveError::Invalid(_)), "{folder}");
    let missing = Archive::open(dir.join("missing.zip")).unwrap_err();
    assert!(matches!(missing, ArchiveError::Io { .. }), "{missing}");
}

#[test]
fn reads_zips_made_by_python() {
    let dir = TempDir::new("python_zip");
    let path = dir.join("py.zip");
    let script = r#"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
    z.comment = 'Made by Python'.encode()
    z.writestr('docs/', '')
    z.writestr('docs/नमस्ते.txt', 'नमस्ते दुनिया\n' * 50)
    info = zipfile.ZipInfo('docs/report.csv', date_time=(2024, 3, 5, 14, 30, 22))
    z.writestr(info, 'a,b\n1,2\n', compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('stored.bin', bytes(range(256)), compress_type=zipfile.ZIP_STORED)
"#;
    if !python(script, &[&path]) {
        return;
    }
    let archive = Archive::open(&path).unwrap();
    assert_eq!(archive.comment(), "Made by Python");
    assert_eq!(names(&archive), ["docs/", "docs/नमस्ते.txt", "docs/report.csv", "stored.bin"]);
    let report = &archive.entries()[2];
    assert_eq!(report.modified.as_deref(), Some("2024-03-05T14:30:22"));
    assert_eq!(report.method, Method::Deflated);
    assert_eq!(archive.entries()[3].method, Method::Stored);
    let out = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(out.written.len(), 3);
    assert_eq!(fs::read_to_string(dir.join("out/docs/नमस्ते.txt")).unwrap(), "नमस्ते दुनिया\n".repeat(50));
    assert_eq!(fs::read(dir.join("out/stored.bin")).unwrap(), (0..=255).collect::<Vec<u8>>());

    // And Python reads what this engine writes.
    let ours = dir.join("ours.zip");
    create_zip(&[Source::new(dir.join("out/docs"))], &ours, &CreateOptions::default()).unwrap();
    let check = r#"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
    assert sorted(z.namelist()) == ['docs/', 'docs/report.csv', 'docs/नमस्ते.txt'], z.namelist()
    assert z.read('docs/report.csv') == b'a,b\n1,2\n'
"#;
    python(check, &[&ours]);
}

#[cfg(unix)]
#[test]
fn reads_zips_made_by_info_zip() {
    let dir = TempDir::new("info_zip");
    let src = dir.join("src");
    fs::create_dir_all(src.join("folder/inner")).unwrap();
    fs::write(src.join("folder/a.txt"), "aaaa".repeat(1000)).unwrap();
    fs::write(src.join("folder/inner/b.txt"), "b").unwrap();
    std::os::unix::fs::symlink("/etc/hosts", src.join("folder/hosts")).unwrap();
    if !tool(&src, "zip", &["-q", "-r", "-y", "../made.zip", "folder"]) {
        return;
    }
    let archive = Archive::open(dir.join("made.zip")).unwrap();
    let mut listed: Vec<_> = archive.entries().iter().map(|e| (e.path.as_str(), e.kind)).collect();
    listed.sort_by_key(|(path, _)| *path);
    assert_eq!(
        listed,
        [
            ("folder/", EntryKind::Directory),
            ("folder/a.txt", EntryKind::File),
            ("folder/hosts", EntryKind::Symlink),
            ("folder/inner/", EntryKind::Directory),
            ("folder/inner/b.txt", EntryKind::File),
        ]
    );
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written.len(), 2);
    assert_eq!(report.skipped.len(), 1);
    assert!(!dir.join("out/folder/hosts").exists());
    assert_eq!(fs::read_to_string(dir.join("out/folder/a.txt")).unwrap(), "aaaa".repeat(1000));

    // unzip accepts what this engine writes.
    let ours = dir.join("ours.zip");
    create_zip(&[Source::new(src.join("folder"))], &ours, &CreateOptions::default()).unwrap();
    tool(&dir.0, "unzip", &["-tq", "ours.zip"]);
}

const TAR_SCRIPT: &str = r#"
import io, sys, tarfile
long = 'deep/' + 'a' * 120 + '/file.txt'
def add(t, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mtime = 1700000000
    t.addfile(info, io.BytesIO(data))
def special(t, name, kind, link=''):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.linkname = link
    t.addfile(info)
for path, mode, fmt in [(sys.argv[1], 'w', tarfile.GNU_FORMAT),
                        (sys.argv[2], 'w:gz', tarfile.PAX_FORMAT),
                        (sys.argv[3], 'w', tarfile.USTAR_FORMAT)]:
    with tarfile.open(path, mode, format=fmt) as t:
        special(t, 'folder', tarfile.DIRTYPE)
        add(t, 'folder/hello.txt', b'hello\n')
        add(t, 'folder/日本語.txt', 'こんにちは'.encode())
        add(t, long, b'long name')
        special(t, 'folder/link', tarfile.SYMTYPE, '../../etc/passwd')
        special(t, 'folder/hard', tarfile.LNKTYPE, 'folder/hello.txt')
        special(t, 'folder/pipe', tarfile.FIFOTYPE)
        add(t, '../escape.txt', b'x' * 1000)
"#;

#[test]
fn reads_tars_made_by_python() {
    let dir = TempDir::new("python_tar");
    let (gnu, pax, ustar) = (dir.join("gnu.tar"), dir.join("pax.tar.gz"), dir.join("ustar.tar"));
    if !python(TAR_SCRIPT, &[&gnu, &pax, &ustar]) {
        return;
    }
    let long = format!("deep/{}/file.txt", "a".repeat(120));
    for (path, format) in [(&gnu, Format::Tar), (&pax, Format::TarGzip), (&ustar, Format::Tar)] {
        let archive = Archive::open(path).unwrap();
        assert_eq!(archive.format(), format, "{}", path.display());
        assert_eq!(
            names(&archive),
            [
                "folder/",
                "folder/hello.txt",
                "folder/日本語.txt",
                long.as_str(),
                "folder/link",
                "folder/hard",
                "folder/pipe",
                "../escape.txt",
            ],
            "{}",
            path.display()
        );
        let kinds: Vec<_> = archive.entries().iter().map(|e| e.kind).collect();
        assert_eq!(
            kinds,
            [
                EntryKind::Directory,
                EntryKind::File,
                EntryKind::File,
                EntryKind::File,
                EntryKind::Symlink,
                EntryKind::HardLink,
                EntryKind::Special,
                EntryKind::File,
            ]
        );
        assert_eq!(archive.entries()[0].name, "folder");
        let hello = &archive.entries()[1];
        assert_eq!(hello.size, 6);
        assert_eq!(hello.modified.as_deref(), Some("2023-11-14T22:13:20Z"));
        assert_eq!(hello.compressed_size, (format == Format::Tar).then_some(6));
        assert_eq!(archive.read(2).unwrap(), "こんにちは".as_bytes());
        assert_eq!(archive.read(3).unwrap(), b"long name");
        let one = dir.join("one.txt");
        assert_eq!(archive.extract(7, &one).unwrap(), 1000);

        let target = dir.join(&format!("out_{}", path.file_name().unwrap().to_string_lossy()));
        let report = archive.extract_all(&target).unwrap();
        let files = tree(&target);
        let listed: Vec<_> = files.iter().map(|(n, _)| n.as_str()).collect();
        let long_out = format!("deep/{}/file.txt", "a".repeat(120));
        let mut expected = vec![long_out.as_str(), "escape.txt", "folder/hello.txt", "folder/日本語.txt"];
        expected.sort();
        assert_eq!(listed, expected);
        assert_eq!(report.written.len(), 4);
        assert_eq!(report.skipped.len(), 3, "{:?}", report.skipped);
        assert_eq!(fs::read(target.join("escape.txt")).unwrap(), vec![b'x'; 1000]);
    }
}

#[test]
fn reads_gzip_files() {
    let dir = TempDir::new("gzip");
    let text = "line of text\n".repeat(5000);
    fs::write(dir.join("notes.txt"), &text).unwrap();
    if !tool(&dir.0, "gzip", &["-k", "-N", "notes.txt"]) {
        return;
    }
    let archive = Archive::open(dir.join("notes.txt.gz")).unwrap();
    assert_eq!(archive.format(), Format::Gzip);
    let entry = &archive.entries()[0];
    assert_eq!(entry.path, "notes.txt");
    assert_eq!(entry.size, text.len() as u64);
    assert_eq!(entry.method, Method::Deflated);
    assert!(entry.modified.as_deref().is_some_and(|m| m.ends_with('Z')));
    assert_eq!(archive.read(0).unwrap(), text.as_bytes());

    // Without a stored name, the archive's own name is used; several members
    // read as one file, and padding after them is ignored.
    let mut joined = fs::read(dir.join("notes.txt.gz")).unwrap();
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(b"second part").unwrap();
    joined.extend_from_slice(&encoder.finish().unwrap());
    joined.extend_from_slice(&[0; 300]);
    joined[3] &= !0x08; // drop the name flag...
    let name_end = joined[10..].iter().position(|&b| b == 0).unwrap() + 11;
    joined.drain(10..name_end); // ...and the name
    let archive = Archive::from_bytes(joined, Some("Report.TXT.GZ")).unwrap();
    assert_eq!(archive.entries()[0].path, "Report.TXT");
    let mut expected = text.clone().into_bytes();
    expected.extend_from_slice(b"second part");
    assert_eq!(archive.read(0).unwrap(), expected);
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written, [dir.join("out/Report.TXT")]);

    // A hostile stored name only ever names a file in the target folder.
    let mut encoder =
        flate2::GzBuilder::new().filename("../../evil.sh").write(Vec::new(), flate2::Compression::default());
    encoder.write_all(b"boo").unwrap();
    let archive = Archive::from_bytes(encoder.finish().unwrap(), None).unwrap();
    assert_eq!(archive.entries()[0].safe_path.as_deref(), Some("evil.sh"));
    let report = archive.extract_all(&dir.join("evil")).unwrap();
    assert_eq!(report.written, [dir.join("evil/evil.sh")]);

    // A damaged stream is reported, and nothing is left behind.
    let mut broken = fs::read(dir.join("notes.txt.gz")).unwrap();
    let len = broken.len();
    broken[len - 6] ^= 0xFF;
    let archive = Archive::from_bytes(broken, None).unwrap();
    assert!(matches!(archive.extract(0, &dir.join("broken.txt")), Err(ArchiveError::Corrupt(_))));
    assert!(!dir.join("broken.txt").exists());
}

#[test]
fn reads_tar_gz_made_by_gnu_tar() {
    let dir = TempDir::new("gnu_tar");
    let src = dir.join("src");
    let long = "b".repeat(150);
    fs::create_dir_all(src.join(&long)).unwrap();
    fs::write(src.join(&long).join("inner.txt"), "deep").unwrap();
    fs::write(src.join("top.txt"), "top").unwrap();
    if !tool(&src, "tar", &["-czf", "../made.tgz", "."]) {
        return;
    }
    let archive = Archive::open(dir.join("made.tgz")).unwrap();
    assert_eq!(archive.format(), Format::TarGzip);
    let mut listed = names(&archive);
    listed.sort();
    let inner = format!("./{long}/inner.txt");
    let folder = format!("./{long}/");
    assert_eq!(listed, ["./", folder.as_str(), inner.as_str(), "./top.txt"]);
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert!(report.skipped.is_empty(), "{:?}", report.skipped);
    assert_eq!(fs::read_to_string(dir.join("out").join(&long).join("inner.txt")).unwrap(), "deep");
}

#[test]
fn truncated_tar_gz_lists_what_arrived() {
    let dir = TempDir::new("cut_tgz");
    let (gnu, pax, ustar) = (dir.join("gnu.tar"), dir.join("pax.tar.gz"), dir.join("ustar.tar"));
    if !python(TAR_SCRIPT, &[&gnu, &pax, &ustar]) {
        return;
    }
    // Cut the plain TAR inside the last file's data.
    let mut tar = fs::read(&gnu).unwrap();
    let end = tar.windows(1000).rposition(|w| w.iter().all(|&b| b == b'x')).unwrap();
    tar.truncate(end + 500);
    let archive = Archive::from_bytes(tar, Some("cut.tar")).unwrap();
    assert_eq!(archive.entries().len(), 8);
    assert!(matches!(archive.read(7), Err(ArchiveError::Corrupt(_))));
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written.len(), 3);
    assert!(report.skipped.iter().any(|s| s.path == "../escape.txt" && s.reason.contains("damaged")));
    assert!(!dir.join("out/escape.txt").exists());

    let mut gz = fs::read(&pax).unwrap();
    gz.truncate(gz.len() / 2);
    let error = Archive::from_bytes(gz, Some("cut.tar.gz"));
    // Half a gzip stream either lists its first entries or, if the cut falls
    // in the first header, reports the damage.
    match error {
        Ok(archive) => assert!(!archive.entries().is_empty()),
        Err(e) => assert!(matches!(e, ArchiveError::Corrupt(_)), "{e}"),
    }
}

/// A ustar header for a regular file; sizes too large for octal digits use
/// GNU's base-256 form.
fn tar_header(name: &str, size: u64) -> [u8; BLOCK] {
    let mut header = [0u8; BLOCK];
    header[..name.len()].copy_from_slice(name.as_bytes());
    header[100..107].copy_from_slice(b"0000644");
    if size < 1 << 33 {
        header[124..135].copy_from_slice(format!("{size:011o}").as_bytes());
    } else {
        header[124] = 0x80;
        header[128..136].copy_from_slice(&size.to_be_bytes());
    }
    header[136..147].copy_from_slice(b"00000000000");
    header[156] = b'0';
    header[257..263].copy_from_slice(b"ustar\0");
    header[263..265].copy_from_slice(b"00");
    header[148..156].copy_from_slice(b"        ");
    let sum: u32 = header.iter().map(|&b| b as u32).sum();
    header[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
    header
}

#[test]
fn tar_gz_bombs_stop_while_listing() {
    let mut tar = tar_header("zeros.bin", 5 << 20).to_vec();
    tar.extend(std::iter::repeat_n(0u8, (5 << 20) + 1024));
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(&tar).unwrap();
    let gz = encoder.finish().unwrap();

    let ok = Archive::from_bytes(gz.clone(), Some("z.tar.gz")).unwrap();
    assert_eq!(ok.format(), Format::TarGzip);
    assert_eq!(ok.entries()[0].size, 5 << 20);
    let error = Archive::from_bytes_with_limits(gz, Some("z.tar.gz"), small_limits()).unwrap_err();
    assert!(matches!(&error, ArchiveError::TooLarge(m) if m.contains("zip bomb")), "{error}");
}

#[test]
fn truncated_tar_with_a_huge_size_is_listed_not_refused() {
    // A plain TAR cannot expand, so a header claiming 16 GB in a tiny file
    // only means the file was cut short.
    let dir = TempDir::new("big_tar");
    let mut tar = tar_header("small.txt", 5).to_vec();
    tar.extend_from_slice(b"hello");
    tar.extend(std::iter::repeat_n(0u8, BLOCK - 5));
    tar.extend_from_slice(&tar_header("huge.img", 16 << 30));
    tar.extend_from_slice(&[7; 1000]);
    let archive = Archive::from_bytes(tar, Some("cut.tar")).unwrap();
    assert_eq!(names(&archive), ["small.txt", "huge.img"]);
    assert_eq!(archive.entries()[1].size, 16 << 30);
    assert!(matches!(archive.read(1), Err(ArchiveError::TooLarge(_))));
    let report = archive.extract_all(&dir.join("out")).unwrap();
    assert_eq!(report.written, [dir.join("out/small.txt")]);
    assert!(report.skipped[0].reason.contains("16 GB"), "{:?}", report.skipped);
}

#[test]
fn extract_replaces_its_target_atomically() {
    let dir = TempDir::new("replace");
    let archive = Archive::from_bytes(raw_zip(&[Raw::file("a.txt", b"new")]), None).unwrap();
    let out = dir.join("a.txt");
    fs::write(&out, "old contents").unwrap();
    archive.extract(0, &out).unwrap();
    assert_eq!(fs::read(&out).unwrap(), b"new");
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1, "no temporary files left");
    let error = archive.extract(0, &dir.join("missing/a.txt")).unwrap_err();
    assert!(matches!(error, ArchiveError::Io { .. }), "{error}");
}
