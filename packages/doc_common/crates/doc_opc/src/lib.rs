//! Document packages: the ZIP containers of Office Open XML (`.docx`,
//! `.xlsx`, `.pptx`) and OpenDocument (`.odt`, `.ods`, `.odp`) files.
//!
//! A [`Package`] reads parts, follows relationships ([`Rels`]) and content
//! types, and records changes: parts replaced, added or removed. Saving
//! writes the entries in their original order, copying every untouched part
//! byte for byte (still compressed), so editing one cell or paragraph never
//! disturbs the rest of the file. OpenDocument's `mimetype` entry stays
//! first and uncompressed.
//!
//! Reading is bounded for a phone ([`PackageLimits`]): an XML part may expand
//! to 64 MB, and the package as a whole only so far past its own size, so a
//! small hostile file is refused as too large instead of filling memory.

use std::collections::{BTreeMap, HashMap, HashSet};

use doc_xml::{ns, Document, Element, Node};
use doc_zip::{Compression, DosDateTime, ExpansionLimits, ReadLimits, ZipArchive, ZipError, ZipWriter};

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
    /// Where each id's relationship sits among the root's children, so a
    /// lookup is not a walk of every relationship (a deck of thousands of
    /// slides looks each one up). A lookup checks the position it finds and
    /// walks the tree when it is stale, so changes made to `doc` directly
    /// cannot make it wrong, only slower.
    index: HashMap<String, usize>,
}

fn is_relationship(node: &Node) -> Option<&Element> {
    node.as_element().filter(|e| e.local() == "Relationship")
}

fn rel_of(e: &Element) -> Rel {
    Rel {
        id: e.attr(ns::NONE, "Id").unwrap_or_default().to_owned(),
        rel_type: e.attr(ns::NONE, "Type").unwrap_or_default().to_owned(),
        target: e.attr(ns::NONE, "Target").unwrap_or_default().to_owned(),
        external: e.attr(ns::NONE, "TargetMode") == Some("External"),
    }
}

impl Rels {
    fn from_doc(source: &str, doc: Document) -> Rels {
        let mut rels = Rels {
            source: source.to_owned(),
            doc,
            index: HashMap::new(),
        };
        rels.reindex();
        rels
    }

    /// Rebuild the index; the first relationship with an id wins, as in
    /// [`Rels::list`].
    fn reindex(&mut self) {
        self.index.clear();
        for (at, node) in self.doc.root.children.iter().enumerate() {
            if let Some(id) = is_relationship(node).and_then(|e| e.attr(ns::NONE, "Id")) {
                self.index.entry(id.to_owned()).or_insert(at);
            }
        }
    }

    pub fn empty(source: &str) -> Rels {
        let root = Element::new("Relationships", ns::PKG_REL).with_attr(
            "xmlns",
            ns::XMLNS,
            "http://schemas.openxmlformats.org/package/2006/relationships",
        );
        Rels::from_doc(source, Document::new(root))
    }

    pub fn parse(source: &str, bytes: &[u8]) -> Result<Rels, OpcError> {
        let doc = Document::parse(bytes).map_err(|e| OpcError::Xml {
            part: rels_path(source),
            message: e.to_string(),
        })?;
        Ok(Rels::from_doc(source, doc))
    }

    fn relationships(&self) -> impl Iterator<Item = &Element> {
        self.doc.root.children.iter().filter_map(is_relationship)
    }

    pub fn list(&self) -> Vec<Rel> {
        self.relationships().map(rel_of).collect()
    }

    pub fn by_id(&self, id: &str) -> Option<Rel> {
        let indexed = self
            .index
            .get(id)
            .and_then(|&at| self.doc.root.children.get(at))
            .and_then(is_relationship)
            .filter(|e| e.attr(ns::NONE, "Id") == Some(id));
        match indexed {
            Some(e) => Some(rel_of(e)),
            None => self.relationships().find(|e| e.attr(ns::NONE, "Id") == Some(id)).map(rel_of),
        }
    }

    pub fn of_kind(&self, kind: &str) -> Vec<Rel> {
        self.relationships()
            .filter(|e| rel::is(e.attr(ns::NONE, "Type").unwrap_or_default(), kind))
            .map(rel_of)
            .collect()
    }

    /// The part a relationship points at (None for external targets).
    pub fn part_of(&self, r: &Rel) -> Option<String> {
        (!r.external).then(|| resolve(&self.source, &r.target))
    }

    /// The part of the first relationship of a kind.
    pub fn first_part(&self, kind: &str) -> Option<String> {
        self.of_kind(kind).first().and_then(|r| self.part_of(r))
    }

    /// The first `rId<n>` no relationship has. The ids in use are gathered
    /// into a set once, so a part with thousands of relationships (a large
    /// deck's) does not make each number tried a search through them all.
    fn unused_id(&self) -> String {
        let ids: HashSet<&str> = self.relationships().filter_map(|e| e.attr(ns::NONE, "Id")).collect();
        (1..)
            .map(|i| format!("rId{i}"))
            .find(|id| !ids.contains(id.as_str()))
            .unwrap_or_else(|| "rId1".into())
    }

    /// Append a relationship element and index it.
    fn push(&mut self, e: Element, id: &str) {
        self.doc.root.push(e);
        self.index.entry(id.to_owned()).or_insert(self.doc.root.children.len() - 1);
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
        self.push(e, &id);
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
        self.push(e, &id);
        id
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.doc.root.children.len();
        self.doc
            .root
            .children
            .retain(|n| !is_relationship(n).is_some_and(|e| e.attr(ns::NONE, "Id") == Some(id)));
        let removed = self.doc.root.children.len() != before;
        if removed {
            self.reindex();
        }
        removed
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

/// Bounds on what a package may expand to as its parts are read, so that a
/// small hostile file cannot use up a phone's memory. Going past one is a
/// [`ZipError::TooLarge`] error. The defaults are sized for phones.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PackageLimits {
    /// Largest XML part, uncompressed, that [`Package::read_xml`] and
    /// [`Package::read_text`] read: 64 MB.
    pub max_xml_part: u64,
    /// Largest part of any kind (a picture, a video), uncompressed: 512 MB,
    /// 256 MB on 32-bit phones.
    pub max_part: u64,
    /// Most all the parts read may expand to together, each counted once:
    /// 1 GB, 512 MB on 32-bit phones.
    pub max_total: u64,
    /// A package that expands more than this many times its size (or a part
    /// more than this many times its compressed size) is treated as a zip
    /// bomb...
    pub max_ratio: u64,
    /// ...once it expands past this many bytes: 64 MB.
    pub ratio_floor: u64,
}

impl Default for PackageLimits {
    fn default() -> Self {
        let small = cfg!(target_pointer_width = "32");
        Self {
            max_xml_part: 64 << 20,
            max_part: if small { 256 << 20 } else { 512 << 20 },
            max_total: if small { 512 << 20 } else { 1 << 30 },
            max_ratio: 100,
            ratio_floor: 64 << 20,
        }
    }
}

/// A ZIP-based document package being read and edited.
pub struct Package {
    pub archive: ZipArchive,
    /// Changes since reading: new bytes for a part, or None when removed.
    changes: BTreeMap<String, Option<Vec<u8>>>,
    /// Parts added that were not in the archive, in the order added.
    added: Vec<String>,
    limits: PackageLimits,
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
    /// Open a package with the default (phone-sized) [`PackageLimits`].
    pub fn open(bytes: Vec<u8>) -> Result<Package, OpcError> {
        Package::open_with_limits(bytes, PackageLimits::default())
    }

    pub fn open_with_limits(bytes: Vec<u8>, limits: PackageLimits) -> Result<Package, OpcError> {
        let read = ReadLimits {
            max_entry_size: limits.max_part,
            ..ReadLimits::default()
        };
        let expansion = ExpansionLimits {
            max_total_bytes: limits.max_total,
            max_ratio: limits.max_ratio,
            ratio_floor: limits.ratio_floor,
        };
        Ok(Package {
            archive: ZipArchive::with_all_limits(bytes, read, expansion)?,
            changes: BTreeMap::new(),
            added: Vec::new(),
            limits,
        })
    }

    pub fn limits(&self) -> PackageLimits {
        self.limits
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
            .enumerate()
            // A name listed twice is one part, as reads and saves treat it.
            .filter(|&(index, e)| !e.is_dir() && !self.archive.is_duplicate(index))
            .map(|(_, e)| e.name.clone())
            .filter(|n| !matches!(self.changes.get(n), Some(None)))
            .collect();
        out.extend(self.added.iter().filter(|n| matches!(self.changes.get(*n), Some(Some(_)))).cloned());
        out
    }

    pub fn read(&self, part: &str) -> Result<Vec<u8>, OpcError> {
        self.read_at_most(part, self.limits.max_part)
    }

    /// A part's bytes, refused as too large past `max_size` bytes.
    fn read_at_most(&self, part: &str, max_size: u64) -> Result<Vec<u8>, OpcError> {
        match self.changes.get(part) {
            Some(Some(bytes)) => Ok(bytes.clone()),
            Some(None) => Err(OpcError::Missing(part.to_owned())),
            None => {
                let index = self.archive.find(part).ok_or_else(|| OpcError::Missing(part.to_owned()))?;
                Ok(self.archive.read_at_most(index, max_size)?)
            }
        }
    }

    pub fn read_xml(&self, part: &str) -> Result<Document, OpcError> {
        let bytes = self.read_at_most(part, self.limits.max_xml_part)?;
        Document::parse(&bytes).map_err(|e| OpcError::Xml {
            part: part.to_owned(),
            message: e.to_string(),
        })
    }

    /// A part's text (decoded from its declared encoding).
    pub fn read_text(&self, part: &str) -> Result<String, OpcError> {
        let bytes = self.read_at_most(part, self.limits.max_xml_part)?;
        Ok(doc_xml::decode_bytes(&bytes).0.into_owned())
    }

    /// Part names the archive lists more than once. Only the first of each
    /// is read, and saving keeps only that one, so an app may want to say
    /// that the file had repeated parts which were dropped.
    pub fn duplicate_parts(&self) -> Vec<String> {
        self.archive.duplicate_names()
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
    /// recompressing; `mimetype` (OpenDocument) stays first and stored. A
    /// name the archive lists twice is saved once, from the first entry,
    /// the one every read used ([`Package::duplicate_parts`] names them).
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
            if self.archive.is_duplicate(index) {
                continue;
            }
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

    // Hostile packages, built here rather than committed as files.

    /// A raw deflate stream of `megabytes` MB of zeros, about 1000:1: one
    /// compressed megabyte repeated, each copy referring only to itself.
    fn bomb(megabytes: usize) -> Vec<u8> {
        let mut compress = flate2::Compress::new(flate2::Compression::best(), false);
        let mut chunk = Vec::with_capacity(4096);
        compress
            .compress_vec(&vec![0u8; 1 << 20], &mut chunk, flate2::FlushCompress::Sync)
            .unwrap();
        let mut out = chunk.repeat(megabytes);
        out.extend_from_slice(&[0x01, 0x00, 0x00, 0xFF, 0xFF]);
        out
    }

    /// An archive whose central directory lists every name in `names`, all
    /// pointing at one deflated entry holding `body` (inflating to `size`
    /// bytes with checksum `crc`).
    fn shared_entries(body: &[u8], size: u32, crc: u32, names: &[String]) -> Vec<u8> {
        let header = |out: &mut Vec<u8>, name: &str| {
            out.extend_from_slice(&8u16.to_le_bytes());
            out.extend_from_slice(&[0; 4]);
            out.extend_from_slice(&crc.to_le_bytes());
            out.extend_from_slice(&(body.len() as u32).to_le_bytes());
            out.extend_from_slice(&size.to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
        };
        let mut out = Vec::new();
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&[20, 0, 0, 0]);
        header(&mut out, &names[0]);
        out.extend_from_slice(names[0].as_bytes());
        out.extend_from_slice(body);
        let start = out.len() as u32;
        for name in names {
            out.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            out.extend_from_slice(&[20, 0, 20, 0, 0, 0]);
            header(&mut out, name);
            // Comment length, disk, attributes, then the offset (0).
            out.extend_from_slice(&[0; 14]);
            out.extend_from_slice(name.as_bytes());
        }
        let size_of_directory = out.len() as u32 - start;
        out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        out.extend_from_slice(&[0; 4]);
        out.extend_from_slice(&(names.len() as u16).to_le_bytes());
        out.extend_from_slice(&(names.len() as u16).to_le_bytes());
        out.extend_from_slice(&size_of_directory.to_le_bytes());
        out.extend_from_slice(&start.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    /// The process's peak resident memory while `f` runs (Linux; elsewhere
    /// 0), after resetting the peak through `clear_refs`.
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

    /// Tests that inflate a lot take turns, so each measures its own peak.
    static HEAVY: std::sync::Mutex<()> = std::sync::Mutex::new(());

    const MB: u64 = 1 << 20;

    fn too_large(part: &str) -> OpcError {
        OpcError::Zip(ZipError::TooLarge(part.into()))
    }

    #[test]
    fn a_small_bomb_is_too_large_at_once() {
        let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
        // 300 KB that inflate to a 300 MB "document.xml", its size stated
        // honestly: under the 512 MB any part may have, over the 64 MB an XML
        // part may.
        let names = ["word/document.xml".to_owned()];
        let p = Package::open(shared_entries(&bomb(300), 300 << 20, 0, &names)).unwrap();
        let start = std::time::Instant::now();
        let ((xml, text), peak) = peak_memory(|| (p.read_xml(&names[0]).map(|_| ()), p.read_text(&names[0]).map(|_| ())));
        assert_eq!(xml, Err(too_large("word/document.xml")));
        assert_eq!(text, Err(too_large("word/document.xml")));
        assert!(start.elapsed().as_secs_f64() < 1.0, "took {:?}", start.elapsed());
        assert!(peak < 100 * MB, "peak memory {} MB", peak / MB);
    }

    #[test]
    fn parts_sharing_one_bomb_run_out_of_the_package_budget() {
        let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
        // Thirty pictures that all point at the same 16 MB of zeros (16 KB
        // compressed): 480 MB from a 20 KB file.
        let zeros = vec![0u8; 16 << 20];
        let names: Vec<String> = (0..30).map(|i| format!("media/image{i:02}.png")).collect();
        let package = shared_entries(&bomb(16), 16 << 20, doc_zip::crc32(&zeros), &names);
        drop(zeros);
        let p = Package::open(package).unwrap();
        let start = std::time::Instant::now();
        let (results, peak) = peak_memory(|| names.iter().map(|n| p.read(n).map(|b| b.len())).collect::<Vec<_>>());
        // A small package may expand to the 64 MB floor: four pictures fit.
        assert_eq!(results.iter().take_while(|r| r.is_ok()).count(), 4, "{results:?}");
        assert_eq!(results[4], Err(too_large("media/image04.png")));
        assert!(start.elapsed().as_secs_f64() < 1.0, "took {:?}", start.elapsed());
        assert!(peak < 100 * MB, "peak memory {} MB", peak / MB);
    }

    #[test]
    fn default_limits_are_phone_sized() {
        let limits = PackageLimits::default();
        assert_eq!(limits.max_xml_part, 64 << 20);
        assert!(limits.max_total <= 1 << 30);
        assert_eq!(Package::open(sample()).unwrap().limits(), limits);
        // A caller may allow more, for a part it streams rather than parses.
        let roomy = PackageLimits { max_xml_part: 512 << 20, ..limits };
        assert_eq!(Package::open_with_limits(sample(), roomy).unwrap().limits(), roomy);
    }

    /// A package with "a.xml" twice ("first", then "again") and "c.xml".
    fn with_duplicate() -> Vec<u8> {
        let mut w = ZipWriter::new();
        w.add("a.xml", b"<first/>", Compression::Stored).unwrap();
        w.add("b.xml", b"<again/>", Compression::Stored).unwrap();
        w.add("c.xml", b"<c/>", Compression::Stored).unwrap();
        let mut bytes = w.finish();
        // Rename "b.xml" to "a.xml" in its local header and directory record.
        let mut at = 0;
        while let Some(found) = bytes[at..].windows(5).position(|w| w == b"b.xml") {
            bytes[at + found] = b'a';
            at += found + 5;
        }
        bytes
    }

    #[test]
    fn a_package_with_a_duplicate_name_saves_the_first() {
        let mut p = Package::open(with_duplicate()).unwrap();
        assert_eq!(p.duplicate_parts(), ["a.xml"]);
        assert_eq!(p.part_names(), ["a.xml", "c.xml"]);
        assert_eq!(p.read("a.xml").unwrap(), b"<first/>");
        p.set("c.xml", b"<c changed=\"1\"/>".to_vec());
        let q = Package::open(p.save().unwrap()).unwrap();
        assert_eq!(q.part_names(), ["a.xml", "c.xml"]);
        assert_eq!(q.read("a.xml").unwrap(), b"<first/>");
        assert_eq!(q.read("c.xml").unwrap(), b"<c changed=\"1\"/>");
        assert!(q.duplicate_parts().is_empty());

        // Editing the repeated part itself saves the edit, once.
        let mut p = Package::open(with_duplicate()).unwrap();
        p.set("a.xml", b"<edited/>".to_vec());
        let q = Package::open(p.save().unwrap()).unwrap();
        assert_eq!(q.part_names(), ["a.xml", "c.xml"]);
        assert_eq!(q.read("a.xml").unwrap(), b"<edited/>");
    }

    fn many_rels(count: usize) -> Rels {
        let mut xml = String::from(r#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#);
        for i in 1..=count {
            xml.push_str(&format!(
                r#"<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i}.xml"/>"#
            ));
        }
        xml.push_str("</Relationships>");
        Rels::parse("ppt/presentation.xml", xml.as_bytes()).unwrap()
    }

    #[test]
    fn looking_up_thousands_of_relationships_is_fast() {
        // A deck of 10,000 slides looks up each slide's relationship.
        let rels = many_rels(10_000);
        let start = std::time::Instant::now();
        for i in 1..=10_000 {
            let r = rels.by_id(&format!("rId{i}")).unwrap();
            assert_eq!(r.target, format!("slides/slide{i}.xml"));
        }
        assert!(start.elapsed().as_secs_f64() < 1.0, "lookups took {:?}", start.elapsed());
        // Adding slides to it gives each the next free id.
        let mut rels = rels;
        let start = std::time::Instant::now();
        for i in 1..=20 {
            assert_eq!(rels.add(&rel::uri(rel::SLIDE), "ppt/slides/new.xml"), format!("rId{}", 10_000 + i));
        }
        assert!(start.elapsed().as_secs_f64() < 1.0, "adding took {:?}", start.elapsed());
    }

    #[test]
    fn the_relationship_index_follows_edits() {
        let mut rels = many_rels(5);
        assert!(rels.remove("rId2"));
        assert!(!rels.remove("rId2"));
        assert_eq!(rels.by_id("rId2"), None);
        assert_eq!(rels.by_id("rId5").unwrap().target, "slides/slide5.xml");
        // The first free id is reused. Ids are compared as text, as they
        // always were: "rId01" is not "rId1".
        assert_eq!(rels.add(&rel::uri(rel::SLIDE), "ppt/slides/again.xml"), "rId2");
        let mut odd = Rels::empty("x.xml");
        let e = Element::new("Relationship", ns::PKG_REL).with_attr("Id", ns::NONE, "rId01");
        odd.doc.root.push(e);
        assert_eq!(odd.add(&rel::uri(rel::SLIDE), "s.xml"), "rId1");
        assert_eq!(odd.add(&rel::uri(rel::SLIDE), "t.xml"), "rId2");
        assert_eq!(odd.by_id("rId1").unwrap().target, "s.xml");
        assert_eq!(rels.by_id("rId2").unwrap().target, "slides/again.xml");
        assert_eq!(rels.add_external(&rel::uri(rel::HYPERLINK), "https://example.com"), "rId6");
        assert!(rels.by_id("rId6").unwrap().external);
        // Changes made to the tree directly are still found.
        rels.doc.root.children.remove(0);
        let e = Element::new("Relationship", ns::PKG_REL)
            .with_attr("Id", ns::NONE, "rIdX")
            .with_attr("Type", ns::NONE, rel::uri(rel::IMAGE))
            .with_attr("Target", ns::NONE, "media/x.png");
        rels.doc.root.push(e);
        assert_eq!(rels.by_id("rId1"), None);
        assert_eq!(rels.by_id("rIdX").unwrap().target, "media/x.png");
        for r in rels.list() {
            assert_eq!(rels.by_id(&r.id), Some(r.clone()));
        }
        assert_eq!(rels.of_kind(rel::IMAGE).len(), 1);
        // The tree reads back the same after saving.
        let again = Rels::parse(&rels.source, &rels.to_bytes()).unwrap();
        assert_eq!(again.list(), rels.list());
    }

}
