//! A package turned into a flat file, for tests and tools.

use doc_xml::{ns, Document, Element, Node};
use doc_zip::ZipArchive;

use crate::{base64, OdfError};

/// Elements whose linked file a flat file holds inline.
const INLINE: [&str; 5] = ["image", "fill-image", "object-ole", "background-image", "list-level-style-image"];

/// A section of `doc`'s root, copied.
fn section(doc: Option<&Document>, local: &str) -> Option<Element> {
    doc?.root.child(ns::OFFICE, local).cloned()
}

/// A section that `content.xml` and `styles.xml` both have, merged: the
/// content's children, then those of the styles' that it lacks (by element
/// and `style:name`). Automatic styles of the same name in the two parts
/// are not renamed, so only the content's is kept.
fn merged(content: &Document, styles: Option<&Document>, local: &str) -> Option<Element> {
    let key = |e: &Element| (e.local().to_owned(), e.attr(ns::STYLE, "name").map(str::to_owned));
    match (section(Some(content), local), section(styles, local)) {
        (Some(mut first), Some(mut second)) => {
            let seen: Vec<_> = first.elements().map(key).collect();
            for child in std::mem::take(&mut second.children) {
                if let Node::Element(e) = &child {
                    if seen.contains(&key(e)) {
                        continue;
                    }
                }
                first.children.push(child);
            }
            Some(first)
        }
        (first, second) => first.or(second),
    }
}

/// Put the pictures and other files that elements link to inside them, as
/// base64 `office:binary-data`.
fn inline_files(root: &mut Element, zip: &ZipArchive, office: &str) -> Result<(), OdfError> {
    // Iterative, so deep trees cannot overflow the stack.
    let mut stack = vec![root];
    while let Some(e) = stack.pop() {
        let target = e
            .attr(ns::XLINK, "href")
            .filter(|_| INLINE.contains(&e.local()))
            .map(|href| href.strip_prefix("./").unwrap_or(href).to_owned())
            .and_then(|path| zip.find(&path).filter(|&i| !zip.entries()[i].is_dir()));
        if let Some(index) = target {
            let bytes = zip.read(index)?;
            for local in ["href", "type", "show", "actuate"] {
                e.remove_attr(ns::XLINK, local);
            }
            let mut data = Element::new(format!("{office}binary-data"), ns::OFFICE);
            data.set_text(base64::encode(&bytes, 76));
            e.push(data);
        }
        stack.extend(e.elements_mut());
    }
    Ok(())
}

/// Turn an OpenDocument package into a flat file: the sections of its
/// `meta.xml`, `settings.xml`, `styles.xml` and `content.xml` under one
/// `office:document` root with the package's mimetype, and linked
/// pictures inline. The root takes every part's namespace declarations,
/// and its other attributes (`office:version`) from `content.xml`.
///
/// Embedded objects (`Object 1/`) are left as links, so a package with
/// them does not flatten completely.
pub fn flatten(package: &[u8]) -> Result<Vec<u8>, OdfError> {
    let zip = ZipArchive::new(package.to_vec())?;
    let mimetype = String::from_utf8_lossy(&zip.read_named("mimetype")?).trim().to_owned();
    let part = |name: &str| -> Result<Option<Document>, OdfError> {
        match zip.find(name) {
            Some(i) => Ok(Some(Document::parse(&zip.read(i)?)?)),
            None => Ok(None),
        }
    };
    let content = part("content.xml")?.ok_or_else(|| OdfError::Missing("content.xml".into()))?;
    let styles = part("styles.xml")?;
    let meta = part("meta.xml")?;
    let settings = part("settings.xml")?;

    let office = match content.root.prefix() {
        "" => String::new(),
        p => format!("{p}:"),
    };
    let mut root = Element::new(format!("{office}document"), ns::OFFICE);
    root.attrs = content.root.attrs.clone();
    for doc in [&styles, &meta, &settings].into_iter().flatten() {
        for a in &doc.root.attrs {
            if a.ns == ns::XMLNS && !root.attrs.iter().any(|b| b.name == a.name) {
                root.attrs.push(a.clone());
            }
        }
    }
    root.set_attr(&format!("{office}mimetype"), ns::OFFICE, mimetype);

    let sections = [
        section(meta.as_ref(), "meta"),
        section(settings.as_ref(), "settings"),
        section(Some(&content), "scripts"),
        merged(&content, styles.as_ref(), "font-face-decls"),
        section(styles.as_ref(), "styles"),
        merged(&content, styles.as_ref(), "automatic-styles"),
        section(styles.as_ref(), "master-styles"),
        section(Some(&content), "body"),
    ];
    for s in sections.into_iter().flatten() {
        root.push(s);
    }
    inline_files(&mut root, &zip, &office)?;
    let flat = Document {
        declaration: Some(r#"xml version="1.0" encoding="UTF-8""#.to_owned()),
        prolog: vec![Node::Text("\n".to_owned())],
        root,
        epilog: Vec::new(),
        namespaces: Default::default(),
    };
    Ok(flat.to_bytes())
}
