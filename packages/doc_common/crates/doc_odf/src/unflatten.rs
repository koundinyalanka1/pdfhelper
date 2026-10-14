//! A flat file turned into a package.

use std::collections::HashMap;

use doc_xml::{decode_bytes, escape_attr, ns, Event, Ns, Reader, StartTag};
use doc_zip::{crc32, Compression, ZipWriter};

use crate::{base64, declarations, picture_kind, root_mimetype, OdfError};

/// The parts a package's sections are written to.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Part {
    Content,
    Styles,
    Meta,
    Settings,
}

/// Where a section of the flat file goes. Font declarations and automatic
/// styles serve both the body and the master pages, so both parts get
/// them; anything unknown stays with the body.
fn parts_of(ns: Ns, local: &str) -> &'static [Part] {
    if ns != ns::OFFICE {
        return &[Part::Content];
    }
    match local {
        "meta" => &[Part::Meta],
        "settings" => &[Part::Settings],
        "font-face-decls" | "automatic-styles" => &[Part::Content, Part::Styles],
        "styles" | "master-styles" => &[Part::Styles],
        _ => &[Part::Content],
    }
}

/// Namespace bindings in scope, the innermost element's last.
#[derive(Default)]
struct Scopes {
    stack: Vec<Vec<(String, Ns)>>,
}

impl Scopes {
    fn push(&mut self, tag: &StartTag) {
        self.stack.push(declarations(tag));
    }

    fn pop(&mut self) {
        self.stack.pop();
    }

    fn resolve(&self, prefix: &str) -> Ns {
        match prefix {
            "xml" => return ns::XML,
            "xmlns" => return ns::XMLNS,
            _ => {}
        }
        self.stack
            .iter()
            .rev()
            .find_map(|scope| scope.iter().rev().find(|(p, _)| p == prefix).map(|(_, n)| *n))
            .unwrap_or(ns::NONE)
    }

    /// The namespace of an element named `name` here.
    fn element_ns(&self, name: &str) -> Ns {
        self.resolve(name.rsplit_once(':').map_or("", |(p, _)| p))
    }
}

/// The flat file's root: what every part's root copies.
#[derive(Clone)]
struct Root {
    /// The prefix of its name with the colon (`office:`), or empty.
    prefix: String,
    /// Its attributes as written, except `office:mimetype`.
    attrs: Vec<(String, String)>,
    mimetype: String,
    version: Option<String>,
    /// The prefix bound to XLink on the root, or the one to declare there
    /// when a picture needs it.
    xlink: String,
    declare_xlink: bool,
}

fn read_root(tag: &StartTag, scopes: &mut Scopes) -> Result<Root, OdfError> {
    let mimetype = root_mimetype(tag).ok_or(OdfError::NotFlat)?;
    let mut attrs = Vec::new();
    let mut version = None;
    for (name, value) in tag.attrs().filter_map(Result::ok) {
        if let Some((p, local)) = name.rsplit_once(':') {
            if p != "xmlns" && scopes.resolve(p) == ns::OFFICE {
                match local {
                    "mimetype" => continue,
                    "version" => version = Some(value.to_string()),
                    _ => {}
                }
            }
        }
        attrs.push((name.to_owned(), value.into_owned()));
    }
    let bound = |prefix: &str| attrs.iter().find(|(n, _)| n.strip_prefix("xmlns:") == Some(prefix)).map(|(_, v)| v.as_str());
    let (xlink, declare_xlink) = match attrs.iter().find_map(|(n, v)| {
        let prefix = n.strip_prefix("xmlns:")?;
        (Ns::from_uri(v) == ns::XLINK).then(|| prefix.to_owned())
    }) {
        Some(prefix) => (prefix, false),
        None => {
            // `xlink`, unless the root uses that prefix for something else.
            let prefix = std::iter::once("xlink".to_owned())
                .chain((1..).map(|n| format!("xlink{n}")))
                .find(|p| bound(p).is_none())
                .expect("an unused prefix");
            if let Some(root) = scopes.stack.last_mut() {
                root.push((prefix.clone(), ns::XLINK));
            }
            (prefix, true)
        }
    };
    Ok(Root {
        prefix: tag.name.rsplit_once(':').map_or(String::new(), |(p, _)| format!("{p}:")),
        attrs,
        mimetype,
        version,
        xlink,
        declare_xlink,
    })
}

/// An element open below the root.
struct Open {
    /// Where its start tag is in the source.
    start: usize,
    end: usize,
    /// Its picture became a file (one per element).
    linked: bool,
}

/// One of the root's children, and the parts it goes to.
struct Section {
    start: usize,
    end: usize,
    parts: &'static [Part],
}

/// A change to the source: the text at `start..end` replaced.
struct Edit {
    start: usize,
    end: usize,
    text: String,
}

/// The pictures taken out of the file, each stored once.
#[derive(Default)]
struct Pictures {
    /// Path in the package, media type and bytes.
    files: Vec<(String, &'static str, Vec<u8>)>,
    /// The files by checksum, to find a picture seen before.
    by_crc: HashMap<u32, Vec<usize>>,
}

impl Pictures {
    /// The path of a picture in the package, adding it unless the same
    /// bytes are there already.
    fn add(&mut self, bytes: Vec<u8>) -> String {
        let same = self.by_crc.entry(crc32(&bytes)).or_default();
        if let Some(&i) = same.iter().find(|&&i| self.files[i].2 == bytes) {
            return self.files[i].0.clone();
        }
        same.push(self.files.len());
        let (ext, media_type) = picture_kind(&bytes);
        let path = format!("Pictures/{}.{ext}", self.files.len() + 1);
        self.files.push((path.clone(), media_type, bytes));
        path
    }
}

fn push_attr(out: &mut String, name: &str, value: &str) {
    out.push(' ');
    out.push_str(name);
    out.push_str("=\"");
    escape_attr(value, out);
    out.push('"');
}

/// The start tag `tag` (as written in the source) linking to a picture at
/// `href` instead of holding it: any earlier link replaced, the XLink
/// prefix declared if it is not in scope.
fn linked_tag(tag: &str, href: &str, xlink: &str, scopes: &Scopes) -> Option<String> {
    let mut reader = Reader::new(tag);
    let Ok(Event::Start(tag)) = reader.next() else {
        return None;
    };
    let mut out = format!("<{}", tag.name);
    for (name, value) in tag.attrs().filter_map(Result::ok) {
        let replaced = name.rsplit_once(':').is_some_and(|(p, local)| {
            p != "xmlns" && scopes.resolve(p) == ns::XLINK && matches!(local, "href" | "type" | "show" | "actuate")
        });
        if !replaced {
            push_attr(&mut out, name, &value);
        }
    }
    if scopes.resolve(xlink) != ns::XLINK {
        push_attr(&mut out, &format!("xmlns:{xlink}"), ns::XLINK.uri());
    }
    for (local, value) in [("href", href), ("type", "simple"), ("show", "embed"), ("actuate", "onLoad")] {
        push_attr(&mut out, &format!("{xlink}:{local}"), value);
    }
    out.push('>');
    Some(out)
}

/// The start of the whitespace that ends `src[..at]`.
fn whitespace_before(src: &str, mut at: usize) -> usize {
    let bytes = src.as_bytes();
    while at > 0 && bytes[at - 1].is_ascii_whitespace() {
        at -= 1;
    }
    at
}

/// The end of the whitespace that starts `src[at..]`.
fn whitespace_after(src: &str, mut at: usize) -> usize {
    let bytes = src.as_bytes();
    while at < bytes.len() && bytes[at].is_ascii_whitespace() {
        at += 1;
    }
    at
}

/// Turn a flat OpenDocument file into a package: `mimetype` first and
/// stored, then `content.xml`, `styles.xml`, `meta.xml`, `settings.xml`,
/// the pictures, and `META-INF/manifest.xml` listing them all. Each part's
/// root keeps the flat root's attributes (namespace declarations,
/// `office:version`), except `office:mimetype`.
///
/// Every element holding `office:binary-data` links to a file under
/// `Pictures/` instead (`xlink:href`, `xlink:type`, `xlink:show`,
/// `xlink:actuate`). Data that is not valid base64 stays inline, as do
/// embedded objects written inline (an `office:document` inside a
/// `draw:object`), which are complete in themselves.
pub fn unflatten(bytes: &[u8]) -> Result<Vec<u8>, OdfError> {
    let (text, _) = decode_bytes(bytes);
    let mut reader = Reader::new(&text);
    let src = reader.source();
    let mut scopes = Scopes::default();
    let mut root: Option<Root> = None;
    let mut open: Vec<Open> = Vec::new();
    let mut sections: Vec<Section> = Vec::new();
    let mut edits: Vec<Edit> = Vec::new();
    let mut pictures = Pictures::default();

    loop {
        let before = reader.offset();
        match reader.next()? {
            Event::Eof => break,
            Event::Start(tag) => {
                scopes.push(&tag);
                let depth = open.len();
                if depth == 0 {
                    root = Some(read_root(&tag, &mut scopes)?);
                } else if depth == 1 {
                    sections.push(Section {
                        start: before,
                        end: before,
                        parts: parts_of(scopes.element_ns(tag.name), tag.local()),
                    });
                } else if scopes.element_ns(tag.name) == ns::OFFICE {
                    match tag.local() {
                        // An embedded object written inline (a chart, a
                        // formula) is complete in itself, pictures included.
                        "document" => {
                            reader.skip_element()?;
                            scopes.pop();
                            continue;
                        }
                        // Pictures belong to elements inside the sections
                        // (an image, a fill, a bullet); anywhere else the
                        // data stays as it is.
                        "binary-data" if depth >= 3 => {
                            let data = reader.read_text()?;
                            scopes.pop();
                            let end = reader.offset();
                            let parent = open.last_mut().expect("binary data inside a section");
                            if parent.linked {
                                continue;
                            }
                            let Some(bytes) = base64::decode(data.as_bytes()).filter(|b| !b.is_empty()) else {
                                continue;
                            };
                            let xlink = &root.as_ref().expect("the root is open").xlink;
                            let href = pictures.add(bytes);
                            let Some(tag) = linked_tag(&src[parent.start..parent.end], &href, xlink, &scopes) else {
                                continue;
                            };
                            parent.linked = true;
                            edits.push(Edit {
                                start: parent.start,
                                end: parent.end,
                                text: tag,
                            });
                            edits.push(Edit {
                                start: whitespace_before(src, before),
                                end: whitespace_after(src, end),
                                text: String::new(),
                            });
                            continue;
                        }
                        _ => {}
                    }
                }
                open.push(Open {
                    start: before,
                    end: reader.offset(),
                    linked: false,
                });
            }
            Event::End(_) => {
                scopes.pop();
                open.pop();
                if open.len() == 1 {
                    if let Some(section) = sections.last_mut() {
                        section.end = reader.offset();
                    }
                }
            }
            _ => {}
        }
    }
    let root = root.ok_or(OdfError::NotFlat)?;
    edits.sort_by_key(|e| e.start);
    write_package(src, &root, &sections, &edits, &pictures)
}

/// Append a section's text, with the edits inside it made.
fn push_section(out: &mut String, src: &str, section: &Section, edits: &[Edit]) {
    let mut at = section.start;
    let first = edits.partition_point(|e| e.start < section.start);
    for edit in edits[first..].iter().take_while(|e| e.end <= section.end) {
        // Edits never overlap; one that did would be skipped.
        if edit.start < at {
            continue;
        }
        out.push_str(&src[at..edit.start]);
        out.push_str(&edit.text);
        at = edit.end;
    }
    out.push_str(&src[at..section.end]);
}

/// A part: its declaration, and a root named `local` with the flat root's
/// attributes around the sections that go to `part`.
fn part_xml(src: &str, root: &Root, part: Part, local: &str, sections: &[Section], edits: &[Edit]) -> String {
    let mine: Vec<&Section> = sections.iter().filter(|s| s.parts.contains(&part)).collect();
    let mut out = String::with_capacity(mine.iter().map(|s| s.end - s.start).sum::<usize>() + 4096);
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push('<');
    out.push_str(&root.prefix);
    out.push_str(local);
    for (name, value) in &root.attrs {
        push_attr(&mut out, name, value);
    }
    if root.declare_xlink {
        push_attr(&mut out, &format!("xmlns:{}", root.xlink), ns::XLINK.uri());
    }
    if mine.is_empty() {
        out.push_str("/>");
        return out;
    }
    out.push('>');
    for section in mine {
        push_section(&mut out, src, section, edits);
    }
    out.push_str("</");
    out.push_str(&root.prefix);
    out.push_str(local);
    out.push('>');
    out
}

/// `META-INF/manifest.xml` listing `files` (path, media type).
fn manifest_xml(root: &Root, files: &[(&str, &str)]) -> String {
    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest");
    push_attr(&mut out, "xmlns:manifest", ns::MANIFEST.uri());
    if let Some(v) = &root.version {
        push_attr(&mut out, "manifest:version", v);
    }
    out.push('>');
    out.push_str("\n <manifest:file-entry");
    push_attr(&mut out, "manifest:full-path", "/");
    if let Some(v) = &root.version {
        push_attr(&mut out, "manifest:version", v);
    }
    push_attr(&mut out, "manifest:media-type", &root.mimetype);
    out.push_str("/>");
    for (path, media_type) in files {
        out.push_str("\n <manifest:file-entry");
        push_attr(&mut out, "manifest:full-path", path);
        push_attr(&mut out, "manifest:media-type", media_type);
        out.push_str("/>");
    }
    out.push_str("\n</manifest:manifest>\n");
    out
}

fn write_package(src: &str, root: &Root, sections: &[Section], edits: &[Edit], pictures: &Pictures) -> Result<Vec<u8>, OdfError> {
    let root = &Root {
        declare_xlink: root.declare_xlink && !pictures.files.is_empty(),
        ..root.clone()
    };
    let mut zip = ZipWriter::new();
    zip.add("mimetype", root.mimetype.as_bytes(), Compression::Stored)?;
    let mut files: Vec<(&str, &str)> = Vec::new();
    for (part, name, local) in [
        (Part::Content, "content.xml", "document-content"),
        (Part::Styles, "styles.xml", "document-styles"),
        (Part::Meta, "meta.xml", "document-meta"),
        (Part::Settings, "settings.xml", "document-settings"),
    ] {
        // One part at a time, so a large file is held once more at most.
        let xml = part_xml(src, root, part, local, sections, edits);
        zip.add(name, xml.as_bytes(), Compression::DEFAULT)?;
        files.push((name, "text/xml"));
    }
    for (path, media_type, bytes) in &pictures.files {
        // Compressed pictures gain nothing from deflating again.
        let compression = match *media_type {
            "image/png" | "image/jpeg" | "image/gif" => Compression::Stored,
            _ => Compression::DEFAULT,
        };
        zip.add(path, bytes, compression)?;
        files.push((path, media_type));
    }
    zip.add("META-INF/manifest.xml", manifest_xml(root, &files).as_bytes(), Compression::DEFAULT)?;
    Ok(zip.finish())
}
