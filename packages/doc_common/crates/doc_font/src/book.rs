//! A book of the fonts in some folders: indexed from their headers only,
//! loaded when used, and searched by family (with metric-compatible
//! substitutes for Office's fonts) or by a character a face lacks.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use crate::{read_name, u16_at, u32_at, Font};

pub type FaceId = usize;

/// A face found while indexing.
#[derive(Clone, Debug)]
pub struct FaceInfo {
    /// Where it is: a file, or in memory.
    pub path: Option<PathBuf>,
    pub index: u32,
    pub family: String,
    pub weight: u16,
    pub italic: bool,
    pub monospace: bool,
    /// The file name, lower case, for script hints.
    pub file: String,
}

#[derive(Default)]
pub struct FontBook {
    faces: Vec<FaceInfo>,
    memory: Vec<Arc<Vec<u8>>>,
    files: HashMap<PathBuf, Arc<Vec<u8>>>,
    loaded: HashMap<FaceId, Option<Arc<Font>>>,
    resolved: HashMap<(String, bool, bool), Option<FaceId>>,
    fallback: HashMap<(u32, bool), Option<FaceId>>,
    dirs: Vec<PathBuf>,
}

fn norm(name: &str) -> String {
    name.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Families to try for a requested one, in order.
fn substitutes(family: &str) -> Vec<&'static str> {
    const SANS: [&str; 10] = ["roboto", "notosans", "liberationsans", "arimo", "dejavusans", "droidsans", "opensans", "freesans", "carlito", "sourcesanspro"];
    const SERIF: [&str; 7] = ["notoserif", "liberationserif", "tinos", "dejavuserif", "droidserif", "caladea", "freeserif"];
    const MONO: [&str; 7] = ["liberationmono", "cousine", "droidsansmono", "dejavusansmono", "notosansmono", "cutivemono", "freemono"];
    let f = norm(family);
    let mut out: Vec<&'static str> = match f.as_str() {
        "calibri" | "calibrilight" => vec!["carlito"],
        "cambria" | "cambriamath" => vec!["caladea"],
        "arial" | "arialmt" | "helvetica" | "helveticaneue" => vec!["liberationsans", "arimo"],
        "arialnarrow" => vec!["liberationsansnarrow"],
        "timesnewroman" | "times" | "timesnewromanpsmt" => vec!["liberationserif", "tinos"],
        "couriernew" | "courier" => vec!["liberationmono", "cousine"],
        "segoeui" | "verdana" | "tahoma" | "trebuchetms" | "candara" | "corbel" | "gillsans" | "century gothic" | "aptos" => vec![],
        _ => vec![],
    };
    let mono = ["mono", "courier", "consol", "lucidaconsole", "code"].iter().any(|k| f.contains(k));
    let serif = !mono
        && ["serif", "times", "cambria", "georgia", "garamond", "bookantiqua", "palatino", "century", "constantia", "bookman", "caladea", "baskerville", "minion"]
            .iter()
            .any(|k| f.contains(k))
        && !f.contains("sans");
    if mono {
        out.extend(MONO);
    } else if serif {
        out.extend(SERIF);
    } else {
        out.extend(SANS);
    }
    out
}

/// File-name hints for the script a character belongs to.
fn script_hints(c: u32) -> &'static [&'static str] {
    match c {
        0x0900..=0x097F | 0xA8E0..=0xA8FF => &["devanagari"],
        0x0980..=0x09FF => &["bengali"],
        0x0A00..=0x0A7F => &["gurmukhi"],
        0x0A80..=0x0AFF => &["gujarati"],
        0x0B00..=0x0B7F => &["oriya"],
        0x0B80..=0x0BFF => &["tamil"],
        0x0C00..=0x0C7F => &["telugu"],
        0x0C80..=0x0CFF => &["kannada"],
        0x0D00..=0x0D7F => &["malayalam"],
        0x0D80..=0x0DFF => &["sinhala"],
        0x0E00..=0x0E7F => &["thai"],
        0x0E80..=0x0EFF => &["lao"],
        0x0590..=0x05FF => &["hebrew"],
        0x0600..=0x06FF | 0x0750..=0x077F | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF => &["arabic", "naskh"],
        0x0530..=0x058F => &["armenian"],
        0x10A0..=0x10FF => &["georgian"],
        0x1200..=0x139F => &["ethiopic"],
        0x1780..=0x17FF => &["khmer"],
        0x1000..=0x109F => &["myanmar"],
        0x3040..=0x30FF | 0x31F0..=0x31FF => &["cjk", "jp", "japanese", "fallback", "gothic", "wqy"],
        0xAC00..=0xD7AF | 0x1100..=0x11FF | 0x3130..=0x318F => &["cjk", "kr", "korean", "fallback", "wqy"],
        0x2E80..=0x2FDF | 0x3000..=0x303F | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0xFF00..=0xFFEF | 0x20000..=0x2FFFF => {
            &["cjk", "sc", "fallback", "wqy", "gothic"]
        }
        0x2190..=0x23FF | 0x2460..=0x27BF | 0x2900..=0x2BFF | 0x1F000..=0x1FAFF => &["symbols", "dejavusans", "freesans", "emoji"],
        _ => &["notosans", "dejavusans", "freesans", "roboto", "symbols"],
    }
}

/// Read some bytes of a file at an offset.
fn read_at(f: &mut File, at: u64, len: usize) -> Option<Vec<u8>> {
    if len > 16 * 1024 * 1024 {
        return None;
    }
    f.seek(SeekFrom::Start(at)).ok()?;
    let mut buf = vec![0u8; len];
    f.read_exact(&mut buf).ok()?;
    Some(buf)
}

/// Faces of a font file from its headers, without reading the outlines.
fn scan_file(path: &Path) -> Vec<FaceInfo> {
    let mut out = Vec::new();
    let Ok(mut f) = File::open(path) else { return out };
    let Some(head) = read_at(&mut f, 0, 12) else { return out };
    let offsets: Vec<u32> = if head.starts_with(b"ttcf") {
        let n = u32_at(&head, 8).unwrap_or(0).min(64) as usize;
        let Some(list) = read_at(&mut f, 12, n * 4) else { return out };
        (0..n).filter_map(|k| u32_at(&list, k * 4)).collect()
    } else {
        vec![0]
    };
    let file = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    for (index, off) in offsets.into_iter().enumerate() {
        let Some(dir) = read_at(&mut f, off as u64, 12) else { continue };
        let n = u16_at(&dir, 4).unwrap_or(0).min(64) as usize;
        let Some(recs) = read_at(&mut f, off as u64 + 12, n * 16) else { continue };
        let table = |f: &mut File, tag: &[u8; 4]| -> Option<Vec<u8>> {
            for k in 0..n {
                let r = k * 16;
                if &recs[r..r + 4] == tag {
                    let at = u32_at(&recs, r + 8)? as u64;
                    let len = u32_at(&recs, r + 12)? as usize;
                    return read_at(f, at, len.min(256 * 1024));
                }
            }
            None
        };
        let Some(name) = table(&mut f, b"name") else { continue };
        let family = read_name(&name, 16).or_else(|| read_name(&name, 1)).unwrap_or_default();
        let sub = read_name(&name, 17).or_else(|| read_name(&name, 2)).unwrap_or_default().to_lowercase();
        let (mut weight, mut italic) = (400u16, sub.contains("italic") || sub.contains("oblique"));
        if let Some(os2) = table(&mut f, b"OS/2") {
            weight = u16_at(&os2, 4).unwrap_or(400);
            italic |= u16_at(&os2, 62).unwrap_or(0) & 1 != 0;
        } else if sub.contains("bold") {
            weight = 700;
        }
        let monospace = table(&mut f, b"post").and_then(|p| u32_at(&p, 12)).is_some_and(|v| v != 0);
        out.push(FaceInfo {
            path: Some(path.to_path_buf()),
            index: index as u32,
            family,
            weight,
            italic,
            monospace,
            file: file.clone(),
        });
    }
    out
}

impl FontBook {
    pub fn new() -> FontBook {
        FontBook::default()
    }

    /// The process's book, shared by every export.
    pub fn shared() -> &'static Mutex<FontBook> {
        static BOOK: OnceLock<Mutex<FontBook>> = OnceLock::new();
        BOOK.get_or_init(|| Mutex::new(FontBook::new()))
    }

    /// Index the fonts of a folder and its subfolders (once per folder).
    pub fn add_dir(&mut self, dir: &Path) {
        if self.dirs.iter().any(|d| d == dir) {
            return;
        }
        self.dirs.push(dir.to_path_buf());
        let mut stack = vec![(dir.to_path_buf(), 0)];
        let mut files = Vec::new();
        while let Some((d, depth)) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    if depth < 4 {
                        stack.push((p, depth + 1));
                    }
                    continue;
                }
                let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                if matches!(ext.as_str(), "ttf" | "otf" | "ttc" | "otc") {
                    files.push(p);
                }
            }
        }
        files.sort();
        for f in files {
            self.add_file(&f);
        }
        self.resolved.clear();
        self.fallback.clear();
    }

    pub fn add_file(&mut self, path: &Path) {
        self.faces.extend(scan_file(path));
    }

    /// Add a font held in memory (bundled fonts, tests).
    pub fn add_bytes(&mut self, data: Vec<u8>) -> Vec<FaceId> {
        let data = Arc::new(data);
        let mut ids = Vec::new();
        for index in 0..crate::face_count(&data) {
            let Ok(f) = Font::parse(data.clone(), index) else { continue };
            let id = self.faces.len();
            self.faces.push(FaceInfo {
                path: None,
                index,
                family: f.family.clone(),
                weight: f.weight,
                italic: f.italic,
                monospace: f.monospace,
                file: f.family.to_lowercase(),
            });
            self.loaded.insert(id, Some(Arc::new(f)));
            ids.push(id);
        }
        self.memory.push(data);
        self.resolved.clear();
        self.fallback.clear();
        ids
    }

    pub fn faces(&self) -> &[FaceInfo] {
        &self.faces
    }

    pub fn is_empty(&self) -> bool {
        self.faces.is_empty()
    }

    /// A face, loaded on first use.
    pub fn font(&mut self, id: FaceId) -> Option<Arc<Font>> {
        if let Some(f) = self.loaded.get(&id) {
            return f.clone();
        }
        let info = self.faces.get(id)?.clone();
        let font = info.path.as_ref().and_then(|p| {
            let data = match self.files.get(p) {
                Some(d) => d.clone(),
                None => {
                    let d = Arc::new(std::fs::read(p).ok()?);
                    self.files.insert(p.clone(), d.clone());
                    d
                }
            };
            Font::parse(data, info.index).ok().map(Arc::new)
        });
        self.loaded.insert(id, font.clone());
        font
    }

    fn best_of(&self, family_norm: &str, bold: bool, italic: bool) -> Option<FaceId> {
        let want = if bold { 700 } else { 400 };
        self.faces
            .iter()
            .enumerate()
            .filter(|(_, f)| norm(&f.family) == family_norm)
            .min_by_key(|(_, f)| (f.weight as i32 - want).abs() + if f.italic != italic { 1000 } else { 0 })
            .map(|(i, _)| i)
    }

    /// The face for a family, weight and style: the family itself, its
    /// substitutes, then a face of the same kind (sans, serif, mono).
    pub fn resolve(&mut self, family: &str, bold: bool, italic: bool) -> Option<FaceId> {
        let key = (norm(family), bold, italic);
        if let Some(r) = self.resolved.get(&key) {
            return *r;
        }
        let mut found = self.best_of(&key.0, bold, italic);
        if found.is_none() {
            for s in substitutes(family) {
                if let Some(f) = self.best_of(s, bold, italic) {
                    found = Some(f);
                    break;
                }
            }
        }
        if found.is_none() {
            found = (0..self.faces.len()).find(|i| !self.faces[*i].monospace && !self.faces[*i].italic).or(if self.faces.is_empty() { None } else { Some(0) });
        }
        self.resolved.insert(key, found);
        found
    }

    /// A face that has `ch`, for text the chosen face cannot show.
    pub fn fallback(&mut self, ch: char, bold: bool) -> Option<FaceId> {
        let key = (ch as u32 >> 7, bold);
        match self.fallback.get(&key).copied() {
            Some(Some(id)) => {
                if self.font(id).is_some_and(|f| f.has(ch)) {
                    return Some(id);
                }
            }
            Some(None) => return None,
            None => {}
        }
        let hints = script_hints(ch as u32);
        let want = if bold { 700 } else { 400 };
        let mut order: Vec<FaceId> = (0..self.faces.len()).collect();
        order.sort_by_key(|i| {
            let f = &self.faces[*i];
            let hinted = hints.iter().position(|h| f.file.contains(h) || norm(&f.family).contains(h)).unwrap_or(99);
            // UI variants and regular upright faces first.
            (hinted, f.italic as i32, (f.weight as i32 - want).abs(), f.file.contains("ui") as i32)
        });
        let mut found = None;
        for (tried, id) in order.into_iter().enumerate() {
            // Without a hint, only look so far before giving up.
            let hinted = {
                let f = &self.faces[id];
                hints.iter().any(|h| f.file.contains(h) || norm(&f.family).contains(h))
            };
            if !hinted && tried > 80 {
                break;
            }
            if self.font(id).is_some_and(|f| f.has(ch)) {
                found = Some(id);
                break;
            }
        }
        self.fallback.insert(key, found);
        found
    }
}
