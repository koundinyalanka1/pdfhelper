//! Document packages: the ZIP containers of Office Open XML (`.docx`,
//! `.xlsx`, `.pptx`) and OpenDocument (`.odt`, `.ods`, `.odp`) files.
//!
//! A [`Package`] reads parts, follows relationships ([`Rels`]) and content
//! types, and records changes: parts replaced, added or removed. Saving
//! writes the entries in their original order, copying every untouched part
//! byte for byte (still compressed), so editing one cell or paragraph never
//! disturbs the rest of the file. OpenDocument's `mimetype` entry stays
//! first and uncompressed.

use std::collections::BTreeMap;

use doc_xml::{ns, Document, Element, Node};
use doc_zip::{Compression, DosDateTime, ZipArchive, ZipError, ZipWriter};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum OpcError {
    #[error("{0}")]
    Zip(#[from] ZipError),
    #[error("part '{part}' is not valid XML: {message}")]
    Xml { part: String, message: String },
    #[error("the package has no part '{0}'")]
    Missing(String),
    #[error("{0}")]
    Invalid(String),
}

/// Relationship types, matched by their last path segment so that the
/// Strict and Transitional forms agree.
pub mod rel {
    pub const OFFICE_DOCUMENT: &str = "officeDocument";
    pub const WORKSHEET: &str = "worksheet";
    pub const CHARTSHEET: &str = "chartsheet";
    pub const SHARED_STRINGS: &str = "sharedStrings";
    pub const STYLES: &str = "styles";
    pub const THEME: &str = "theme";
    pub const CALC_CHAIN: &str = "calcChain";
    pub const VBA_PROJECT: &str = "vbaProject";
    pub const TABLE: &str = "table";
    pub const IMAGE: &str = "image";
    pub const HYPERLINK: &str = "hyperlink";
    pub const SLIDE: &str = "slide";
    pub const SLIDE_LAYOUT: &str = "slideLayout";
    pub const SLIDE_MASTER: &str = "slideMaster";
    pub const NOTES_SLIDE: &str = "notesSlide";
    pub const NOTES_MASTER: &str = "notesMaster";
    pub const NUMBERING: &str = "numbering";
    pub const HEADER: &str = "header";
    pub const FOOTER: &str = "footer";
    pub const FOOTNOTES: &str = "footnotes";
    pub const ENDNOTES: &str = "endnotes";
    pub const COMMENTS: &str = "comments";
    pub const SETTINGS: &str = "settings";
    pub const FONT_TABLE: &str = "fontTable";
    pub const CHART: &str = "chart";

    /// The full Transitional URI of a relationship type.
    pub fn uri(kind: &str) -> String {
        match kind {
            VBA_PROJECT => "http://schemas.microsoft.com/office/2006/relationships/vbaProject".into(),
            _ => format!("http://schemas.openxmlformats.org/officeDocument/2006/relationships/{kind}"),
        }
    }

    /// Whether a relationship's type URI is of this kind.
    pub fn is(type_uri: &str, kind: &str) -> bool {
        type_uri.rsplit('/').next() == Some(kind)
    }
}

/// One relationship.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rel {
    pub id: String,
    pub rel_type: String,
    pub target: String,
    pub external: bool,
}

/// A part's relationships (`_rels/<part>.rels`), kept as a tree so that
/// saving them changes only what was edited.
#[derive(Clone, Debug)]
pub struct Rels {
    /// The part these relationships belong to ("" for the package).
    pub source: String,
    pub doc: Document,
}

impl Rels {
    pub fn empty(source: &str) -> Rels {
        let root = Element::new("Relationships", ns::PKG_REL).with_attr(
            "xmlns",
            ns::XMLNS,
            "http://schemas.openxmlformats.org/package/2006/relationships",
        );
        Rels {
            source: source.to_owned(),
            doc: Document::new(root),
        }
    }

    pub fn parse(source: &str, bytes: &[u8]) -> Result<Rels, OpcError> {
        let doc = Document::parse(bytes).map_err(|e| OpcError::Xml {
            part: rels_path(source),
            message: e.to_string(),
        })?;
        Ok(Rels {
            source: source.to_owned(),
            doc,
        })
    }

    pub fn list(&self) -> Vec<Rel> {
        self.doc
            .root
            .elements()
            .filter(|e| e.local() == "Relationship")
            .map(|e| Rel {
                id: e.attr(ns::NONE, "Id").unwrap_or_default().to_owned(),
                rel_type: e.attr(ns::NONE, "Type").unwrap_or_default().to_owned(),
                target: e.attr(ns::NONE, "Target").unwrap_or_default().to_owned(),
                external: e.attr(ns::NONE, "TargetMode") == Some("External"),
            })
            .collect()
    }

    pub fn by_id(&self, id: &str) -> Option<Rel> {
        self.list().into_iter().find(|r| r.id == id)
    }

    pub fn of_kind(&self, kind: &str) -> Vec<Rel> {
        self.list().into_iter().filter(|r| rel::is(&r.rel_type, kind)).collect()
    }

    /// The part a relationship points at (None for external targets).
    pub fn part_of(&self, r: &Rel) -> Option<String> {
        (!r.external).then(|| resolve(&self.source, &r.target))
    }

    /// The part of the first relationship of a kind.
    pub fn first_part(&self, kind: &str) -> Option<String> {
        self.of_kind(kind).first().and_then(|r| self.part_of(r))
    }

    fn unused_id(&self) -> String {
        let ids: Vec<String> = self.list().into_iter().map(|r| r.id).collect();
        (1..)
            .map(|i| format!("rId{i}"))
            .find(|id| !ids.contains(id))
            .unwrap_or_else(|| "rId1".into())
    }

    /// Add a relationship to `target_part` (a package path); returns its id.
    pub fn add(&mut self, kind_uri: &str, target_part: &str) -> String {
        let id = self.unused_id();
        let target = relative(&self.source, target_part);
        let prefix = self.doc.prefix_for(ns::PKG_REL).unwrap_or_default();
        let name = if prefix.is_empty() { "Relationship".to_owned() } else { format!("{prefix}:Relationship") };
        let e = Element::new(name, ns::PKG_REL)
            .with_attr("Id", ns::NONE, id.clone())
            .with_attr("Type", ns::NONE, kind_uri)
            .with_attr("Target", ns::NONE, target);
        self.doc.root.push(e);
        id
    }

    /// Add an external relationship (a hyperlink); returns its id.
    pub fn add_external(&mut self, kind_uri: &str, url: &str) -> String {
        let id = self.unused_id();
        let prefix = self.doc.prefix_for(ns::PKG_REL).unwrap_or_default();
        let name = if prefix.is_empty() { "Relationship".to_owned() } else { format!("{prefix}:Relationship") };
        let e = Element::new(name, ns::PKG_REL)
            .with_attr("Id", ns::NONE, id.clone())
            .with_attr("Type", ns::NONE, kind_uri)
            .with_attr("Target", ns::NONE, url)
            .with_attr("TargetMode", ns::NONE, "External");
        self.doc.root.push(e);
        id
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.doc.root.children.len();
        self.doc
            .root
            .children
            .retain(|n| !n.as_element().is_some_and(|e| e.local() == "Relationship" && e.attr(ns::NONE, "Id") == Some(id)));
        self.doc.root.children.len() != before
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        self.doc.to_bytes()
    }
}

/// The relationships part of a part: `xl/workbook.xml` →
/// `xl/_rels/workbook.xml.rels`; the package's own is `_rels/.rels`.
pub fn rels_path(part: &str) -> String {
    match part.rsplit_once('/') {
        Some((dir, name)) => format!("{dir}/_rels/{name}.rels"),
        None if part.is_empty() => "_rels/.rels".into(),
        None => format!("_rels/{part}.rels"),
    }
}

/// The folder of a part (`xl/worksheets/sheet1.xml` → `xl/worksheets`).
pub fn dir_of(part: &str) -> &str {
    part.rsplit_once('/').map_or("", |(d, _)| d)
}

/// Resolve a relationship target against its source part.
pub fn resolve(source: &str, target: &str) -> String {
    let target = target.split('#').next().unwrap_or(target);
    let mut parts: Vec<&str> = if let Some(abs) = target.strip_prefix('/') {
        return normalize(abs.split('/').collect());
    } else {
        dir_of(source).split('/').filter(|s| !s.is_empty()).collect()
    };
    parts.extend(target.split('/'));
    normalize(parts)
}

fn normalize(parts: Vec<&str>) -> String {
    let mut out: Vec<&str> = Vec::new();
    for p in parts {
        match p {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    let joined = out.join("/");
    percent_decode(&joined)
}

fn percent_decode(s: &str) -> String {
    if !s.contains('%') {
        return s.to_owned();
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_owned())
}

/// A target for `target_part` relative to `source`'s folder.
pub fn relative(source: &str, target_part: &str) -> String {
    let from: Vec<&str> = dir_of(source).split('/').filter(|s| !s.is_empty()).collect();
    let to: Vec<&str> = target_part.split('/').collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut out: Vec<String> = Vec::new();
    for _ in common..from.len() {
        out.push("..".into());
    }
    out.extend(to[common..].iter().map(|s| s.to_string()));
    out.join("/")
}

/// A ZIP-based document package being read and edited.
pub struct Package {
    pub archive: ZipArchive,
    /// Changes since reading: new bytes for a part, or None when removed.
    changes: BTreeMap<String, Option<Vec<u8>>>,
    /// Parts added that were not in the archive, in the order added.
    added: Vec<String>,
}

impl std::fmt::Debug for Package {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Package")
            .field("entries", &self.archive.len())
            .field("changes", &self.changes.keys().collect::<Vec<_>>())
            .finish()
    }
}

const CONTENT_TYPES: &str = "[Content_Types].xml";

impl Package {
    pub fn open(bytes: Vec<u8>) -> Result<Package, OpcError> {
        Ok(Package {
            archive: ZipArchive::new(bytes)?,
            changes: BTreeMap::new(),
            added: Vec::new(),
        })
    }

    /// An empty package to build from scratch.
    pub fn empty() -> Package {
        let bytes = ZipWriter::new().finish();
        Package::open(bytes).expect("an empty archive reads back")
    }

    pub fn exists(&self, part: &str) -> bool {
        match self.changes.get(part) {
            Some(Some(_)) => true,
            Some(None) => false,
            None => self.archive.contains(part),
        }
    }

    /// Every part name, in saving order.
    pub fn part_names(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .archive
            .entries()
            .iter()
            .filter(|e| !e.is_dir())
            .map(|e| e.name.clone())
            .filter(|n| !matches!(self.changes.get(n), Some(None)))
            .collect();
        out.extend(self.added.iter().filter(|n| matches!(self.changes.get(*n), Some(Some(_)))).cloned());
        out
    }

    pub fn read(&self, part: &str) -> Result<Vec<u8>, OpcError> {
        match self.changes.get(part) {
            Some(Some(bytes)) => Ok(bytes.clone()),
            Some(None) => Err(OpcError::Missing(part.to_owned())),
            None => {
                let index = self.archive.find(part).ok_or_else(|| OpcError::Missing(part.to_owned()))?;
                Ok(self.archive.read(index)?)
            }
        }
    }

    pub fn read_xml(&self, part: &str) -> Result<Document, OpcError> {
        let bytes = self.read(part)?;
        Document::parse(&bytes).map_err(|e| OpcError::Xml {
            part: part.to_owned(),
            message: e.to_string(),
        })
    }

    /// A part's text (decoded from its declared encoding).
    pub fn read_text(&self, part: &str) -> Result<String, OpcError> {
        let bytes = self.read(part)?;
        Ok(doc_xml::decode_bytes(&bytes).0.into_owned())
    }

    /// Whether a part was replaced, added or removed.
    pub fn is_changed(&self, part: &str) -> bool {
        self.changes.contains_key(part)
    }

    /// Replace or add a part.
    pub fn set(&mut self, part: &str, bytes: Vec<u8>) {
        if !self.archive.contains(part) && !self.added.iter().any(|a| a == part) {
            self.added.push(part.to_owned());
        }
        self.changes.insert(part.to_owned(), Some(bytes));
    }

    pub fn set_xml(&mut self, part: &str, doc: &Document) {
        self.set(part, doc.to_bytes());
    }

    pub fn remove(&mut self, part: &str) {
        if self.archive.contains(part) {
            self.changes.insert(part.to_owned(), None);
        } else {
            self.changes.remove(part);
            self.added.retain(|a| a != part);
        }
    }

    /// The relationships of a part (empty if it has none).
    pub fn rels(&self, part: &str) -> Result<Rels, OpcError> {
        let path = rels_path(part);
        if !self.exists(&path) {
            return Ok(Rels::empty(part));
        }
        Rels::parse(part, &self.read(&path)?)
    }

    pub fn set_rels(&mut self, rels: &Rels) {
        self.set(&rels_path(&rels.source), rels.to_bytes());
    }

    /// The main document part (`word/document.xml`, `xl/workbook.xml`...).
    pub fn main_part(&self) -> Result<String, OpcError> {
        self.rels("")?
            .first_part(rel::OFFICE_DOCUMENT)
            .ok_or_else(|| OpcError::Invalid("the package does not name its main document".into()))
    }

    /// A part name like `xl/worksheets/sheet{}.xml` with the first unused
    /// number.
    pub fn unused_name(&self, pattern: &str) -> String {
        (1..)
            .map(|i| pattern.replace("{}", &i.to_string()))
            .find(|n| !self.exists(n))
            .unwrap_or_else(|| pattern.replace("{}", "x"))
    }

    fn content_types(&self) -> Result<Document, OpcError> {
        if self.exists(CONTENT_TYPES) {
            self.read_xml(CONTENT_TYPES)
        } else {
            let root = Element::new("Types", ns::CONTENT_TYPES).with_attr(
                "xmlns",
                ns::XMLNS,
                "http://schemas.openxmlformats.org/package/2006/content-types",
            );
            Ok(Document::new(root))
        }
    }

    /// A part's content type, from its override or its extension's default.
    pub fn content_type(&self, part: &str) -> Option<String> {
        let doc = self.content_types().ok()?;
        let name = format!("/{part}");
        for e in doc.root.elements() {
            if e.local() == "Override" && e.attr(ns::NONE, "PartName").is_some_and(|p| p.eq_ignore_ascii_case(&name)) {
                return e.attr(ns::NONE, "ContentType").map(str::to_owned);
            }
        }
        let ext = part.rsplit('.').next()?.to_ascii_lowercase();
        let found = doc
            .root
            .elements()
            .find(|e| e.local() == "Default" && e.attr(ns::NONE, "Extension").is_some_and(|x| x.eq_ignore_ascii_case(&ext)))
            .and_then(|e| e.attr(ns::NONE, "ContentType").map(str::to_owned));
        found
    }

    /// Give a part an explicit content type.
    pub fn set_override(&mut self, part: &str, content_type: &str) -> Result<(), OpcError> {
        let mut doc = self.content_types()?;
        let name = format!("/{part}");
        let existing = doc.root.elements_mut().find(|e| {
            e.local() == "Override" && e.attr(ns::NONE, "PartName").is_some_and(|p| p.eq_ignore_ascii_case(&name))
        });
        match existing {
            Some(e) => {
                if e.attr(ns::NONE, "ContentType") == Some(content_type) {
                    return Ok(());
                }
                e.set_attr("ContentType", ns::NONE, content_type);
            }
            None => {
                let prefix = doc.prefix_for(ns::CONTENT_TYPES).unwrap_or_default();
                let tag = if prefix.is_empty() { "Override".to_owned() } else { format!("{prefix}:Override") };
                doc.root.push(
                    Element::new(tag, ns::CONTENT_TYPES)
                        .with_attr("PartName", ns::NONE, name)
                        .with_attr("ContentType", ns::NONE, content_type),
                );
            }
        }
        self.set_xml(CONTENT_TYPES, &doc);
        Ok(())
    }

    /// Make sure files with an extension have a default content type (for
    /// images added to a package).
    pub fn ensure_default(&mut self, extension: &str, content_type: &str) -> Result<(), OpcError> {
        let mut doc = self.content_types()?;
        let has = doc
            .root
            .elements()
            .any(|e| e.local() == "Default" && e.attr(ns::NONE, "Extension").is_some_and(|x| x.eq_ignore_ascii_case(extension)));
        if has {
            return Ok(());
        }
        let prefix = doc.prefix_for(ns::CONTENT_TYPES).unwrap_or_default();
        let tag = if prefix.is_empty() { "Default".to_owned() } else { format!("{prefix}:Default") };
        let e = Element::new(tag, ns::CONTENT_TYPES)
            .with_attr("Extension", ns::NONE, extension)
            .with_attr("ContentType", ns::NONE, content_type);
        // Defaults go before overrides.
        let at = doc.root.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() == "Override"));
        match at {
            Some(i) => doc.root.children.insert(i, Node::Element(e)),
            None => doc.root.push(e),
        }
        self.set_xml(CONTENT_TYPES, &doc);
        Ok(())
    }

    pub fn remove_override(&mut self, part: &str) -> Result<(), OpcError> {
        if !self.exists(CONTENT_TYPES) {
            return Ok(());
        }
        let mut doc = self.content_types()?;
        let name = format!("/{part}");
        let before = doc.root.children.len();
        doc.root.children.retain(|n| {
            !n.as_element().is_some_and(|e| {
                e.local() == "Override" && e.attr(ns::NONE, "PartName").is_some_and(|p| p.eq_ignore_ascii_case(&name))
            })
        });
        if doc.root.children.len() != before {
            self.set_xml(CONTENT_TYPES, &doc);
        }
        Ok(())
    }

    /// Remove a part together with its relationships part and content-type
    /// override.
    pub fn remove_part(&mut self, part: &str) -> Result<(), OpcError> {
        self.remove(part);
        let rp = rels_path(part);
        if self.exists(&rp) {
            self.remove(&rp);
        }
        self.remove_override(part)
    }

    /// Write the package. Unchanged entries are copied without
    /// recompressing; `mimetype` (OpenDocument) stays first and stored.
    pub fn save(&self) -> Result<Vec<u8>, OpcError> {
        let mut w = ZipWriter::new();
        w.set_timestamp(DosDateTime::now_utc());
        let compression = |name: &str| {
            if name == "mimetype" {
                Compression::Stored
            } else {
                Compression::DEFAULT
            }
        };
        // A new mimetype entry must come first.
        if self.added.iter().any(|a| a == "mimetype") {
            if let Some(Some(bytes)) = self.changes.get("mimetype") {
                w.add("mimetype", bytes, Compression::Stored)?;
            }
        }
        for (index, entry) in self.archive.entries().iter().enumerate() {
            match self.changes.get(&entry.name) {
                Some(None) => {}
                Some(Some(bytes)) => w.add(&entry.name, bytes, compression(&entry.name))?,
                None => w.copy_from(&self.archive, index)?,
            }
        }
        for name in &self.added {
            if name == "mimetype" {
                continue;
            }
            if let Some(Some(bytes)) = self.changes.get(name) {
                w.add(name, bytes, compression(name))?;
            }
        }
        Ok(w.finish())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths() {
        assert_eq!(rels_path("xl/workbook.xml"), "xl/_rels/workbook.xml.rels");
        assert_eq!(rels_path(""), "_rels/.rels");
        assert_eq!(resolve("xl/workbook.xml", "worksheets/sheet1.xml"), "xl/worksheets/sheet1.xml");
        assert_eq!(resolve("xl/worksheets/sheet1.xml", "../drawings/drawing1.xml"), "xl/drawings/drawing1.xml");
        assert_eq!(resolve("xl/workbook.xml", "/xl/styles.xml"), "xl/styles.xml");
        assert_eq!(resolve("", "xl/workbook.xml"), "xl/workbook.xml");
        assert_eq!(resolve("word/document.xml", "media/image%201.png"), "word/media/image 1.png");
        assert_eq!(relative("xl/workbook.xml", "xl/worksheets/sheet2.xml"), "worksheets/sheet2.xml");
        assert_eq!(relative("xl/worksheets/sheet1.xml", "xl/drawings/d.xml"), "../drawings/d.xml");
        assert_eq!(relative("", "xl/workbook.xml"), "xl/workbook.xml");
    }

    fn sample() -> Vec<u8> {
        let mut w = ZipWriter::new();
        w.add(
            "[Content_Types].xml",
            br#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/a/main.xml" ContentType="test/main"/></Types>"#,
            Compression::DEFAULT,
        )
        .unwrap();
        w.add(
            "_rels/.rels",
            br#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="a/main.xml"/></Relationships>"#,
            Compression::DEFAULT,
        )
        .unwrap();
        w.add("a/main.xml", b"<main/>", Compression::DEFAULT).unwrap();
        w.add("a/other.bin", &[1, 2, 3], Compression::Stored).unwrap();
        w.finish()
    }

    #[test]
    fn edits_and_saves() {
        let mut p = Package::open(sample()).unwrap();
        assert_eq!(p.main_part().unwrap(), "a/main.xml");
        assert_eq!(p.content_type("a/main.xml").as_deref(), Some("test/main"));
        assert_eq!(p.content_type("a/x.xml").as_deref(), Some("application/xml"));
        p.set("a/main.xml", b"<main changed=\"1\"/>".to_vec());
        p.set("a/new.xml", b"<new/>".to_vec());
        p.set_override("a/new.xml", "test/new").unwrap();
        let mut rels = p.rels("a/main.xml").unwrap();
        let id = rels.add(&rel::uri(rel::STYLES), "a/new.xml");
        assert_eq!(id, "rId1");
        p.set_rels(&rels);
        p.remove_part("a/other.bin").unwrap();
        let saved = p.save().unwrap();
        let q = Package::open(saved).unwrap();
        assert_eq!(q.read("a/main.xml").unwrap(), b"<main changed=\"1\"/>");
        assert!(!q.exists("a/other.bin"));
        assert_eq!(q.content_type("a/new.xml").as_deref(), Some("test/new"));
        let r = q.rels("a/main.xml").unwrap();
        assert_eq!(r.first_part(rel::STYLES).as_deref(), Some("a/new.xml"));
        assert_eq!(
            q.part_names(),
            vec!["[Content_Types].xml", "_rels/.rels", "a/main.xml", "a/new.xml", "a/_rels/main.xml.rels"]
        );
    }
}
