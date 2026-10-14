use doc_xml::{ns, Document, Element, Node};
use doc_zip::{crc32, Compression, ZipArchive, ZipWriter, METHOD_STORED};

use super::*;

/// A 1x1 PNG.
const PNG_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

fn png() -> Vec<u8> {
    base64_decode(PNG_BASE64.as_bytes()).unwrap()
}

/// Not a whole JPEG, but it starts like one.
fn jpeg() -> Vec<u8> {
    let mut b = vec![0xFF, 0xD8, 0xFF, 0xE0, 0, 16];
    b.extend_from_slice(b"JFIF\0 and some made-up data");
    b
}

const NS: &str = concat!(
    r#"xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" "#,
    r#"xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" "#,
    r#"xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" "#,
    r#"xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" "#,
    r#"xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" "#,
    r#"xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" "#,
    r#"xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" "#,
    r#"xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" "#,
    r#"xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" "#,
    r#"xmlns:dc="http://purl.org/dc/elements/1.1/" "#,
    r#"xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0""#,
);

/// A flat letter as an office suite writes one: every section, line
/// breaks between them, and a picture inline in wrapped base64 (with no
/// XLink namespace declared, as it is not needed).
fn flat_letter() -> String {
    let (first, rest) = PNG_BASE64.split_at(40);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<office:document {NS} office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text">
 <office:meta><dc:title>Letter</dc:title><meta:generator>Hand</meta:generator></office:meta>
 <office:settings><config:config-item-set config:name="ooo:view-settings"><config:config-item config:name="ViewAreaTop" config:type="long">0</config:config-item></config:config-item-set></office:settings>
 <office:scripts/>
 <office:font-face-decls><style:font-face style:name="Liberation Serif" svg:font-family="'Liberation Serif'"/></office:font-face-decls>
 <office:styles><style:style style:name="Standard" style:family="paragraph"/></office:styles>
 <office:automatic-styles><style:style style:name="P1" style:family="paragraph"><style:text-properties fo:font-weight="bold"/></style:style><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm"/></style:page-layout></office:automatic-styles>
 <office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"/></office:master-styles>
 <office:body><office:text><text:p text:style-name="P1">Dear &amp; welcome</text:p><text:p><draw:frame draw:name="Logo" svg:width="1cm" svg:height="1cm"><draw:image draw:mime-type="image/png">
    <office:binary-data>{first}
{rest}</office:binary-data>
   </draw:image></draw:frame></text:p></office:text></office:body>
</office:document>
"#
    )
}

fn entry_names(zip: &ZipArchive) -> Vec<String> {
    zip.entries().iter().map(|e| e.name.clone()).collect()
}

fn part(zip: &ZipArchive, name: &str) -> Document {
    Document::parse(&zip.read_named(name).unwrap()).unwrap()
}

fn locals(e: &Element) -> Vec<String> {
    e.elements().map(|c| c.local().to_owned()).collect()
}

/// The manifest's entries: (path, media type).
fn manifest(zip: &ZipArchive) -> Vec<(String, String)> {
    part(zip, "META-INF/manifest.xml")
        .root
        .elements()
        .map(|e| {
            (
                e.attr(ns::MANIFEST, "full-path").unwrap().to_owned(),
                e.attr(ns::MANIFEST, "media-type").unwrap().to_owned(),
            )
        })
        .collect()
}

#[test]
fn base64_round_trips_and_tolerates_wrapping() {
    for len in 0..40 {
        let bytes: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
        let one_line = base64_encode(&bytes, 0);
        assert_eq!(base64_decode(one_line.as_bytes()).as_deref(), Some(bytes.as_slice()), "{len}");
        let wrapped = base64_encode(&bytes, 8);
        assert!(wrapped.lines().all(|l| l.len() <= 8));
        assert_eq!(base64_decode(wrapped.as_bytes()).as_deref(), Some(bytes.as_slice()));
        let unpadded = one_line.trim_end_matches('=');
        assert_eq!(base64_decode(unpadded.as_bytes()).as_deref(), Some(bytes.as_slice()));
    }
    assert_eq!(base64_encode(b"Man", 0), "TWFu");
    assert_eq!(base64_encode(b"Ma", 0), "TWE=");
    assert_eq!(base64_decode(b" T W\r\nE =\t= ").as_deref(), Some(&b"Ma"[..]));
    assert_eq!(base64_decode(b"TWE*"), None, "not a base64 digit");
    assert_eq!(base64_decode(b"TWE=TWE="), None, "data after the padding");
    assert_eq!(base64_decode(b"TWFuT"), None, "a lone digit at the end");
    assert_eq!(png()[..8], *b"\x89PNG\r\n\x1a\n");
}

#[test]
fn tells_flat_files_from_other_xml() {
    let letter = flat_letter();
    assert_eq!(flat_mimetype(letter.as_bytes()).as_deref(), Some(TEXT));
    assert!(is_flat(letter.as_bytes()));

    // A byte-order mark, whitespace, a comment and a document type first.
    let decorated = format!("\u{FEFF}\n  <!-- made by hand --><!DOCTYPE office:document>{}", &letter[letter.find("<office:document").unwrap()..]);
    assert_eq!(flat_mimetype(decorated.as_bytes()).as_deref(), Some(TEXT));
    // UTF-16 with a byte-order mark.
    let mut utf16 = vec![0xFF, 0xFE];
    utf16.extend(letter.replace("UTF-8", "UTF-16").encode_utf16().flat_map(|u| u.to_le_bytes()));
    assert_eq!(flat_mimetype(&utf16).as_deref(), Some(TEXT));
    // Any prefix, or none, as long as the namespace is OpenDocument's.
    let other = r#"<o:document xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" o:mimetype=" application/vnd.oasis.opendocument.spreadsheet "/>"#;
    assert_eq!(flat_mimetype(other.as_bytes()).as_deref(), Some(SPREADSHEET));
    let default = r#"<document xmlns="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" o:mimetype="application/vnd.oasis.opendocument.presentation"/>"#;
    assert_eq!(flat_mimetype(default.as_bytes()).as_deref(), Some(PRESENTATION));

    let not_flat = [
        // A packaged file's part.
        format!(r#"<office:document-content {NS} office:version="1.3"/>"#),
        // No mimetype.
        format!(r#"<office:document {NS} office:version="1.3"/>"#),
        // The right names in another namespace.
        r#"<office:document xmlns:office="urn:example" office:mimetype="application/vnd.oasis.opendocument.text"/>"#.to_owned(),
        // A mimetype attribute outside the office namespace.
        format!(r#"<office:document {NS} mimetype="application/vnd.oasis.opendocument.text"/>"#),
        "Just some text that mentions <office:document>".to_owned(),
        String::new(),
        "<".to_owned(),
    ];
    for xml in &not_flat {
        assert_eq!(flat_mimetype(xml.as_bytes()), None, "{xml}");
        assert!(unflatten(xml.as_bytes()).is_err(), "{xml}");
    }
    assert_eq!(unflatten(not_flat[0].as_bytes()), Err(OdfError::NotFlat));
    assert_eq!(flat_mimetype(b"PK\x03\x04mimetypeapplication/vnd.oasis.opendocument.text"), None);
    // A root tag cut off by the end of the bytes read.
    let cut = &letter[..letter.find("office:version").unwrap()];
    assert_eq!(flat_mimetype(cut.as_bytes()), None);
}

#[test]
fn unflattens_a_flat_letter_with_a_picture() {
    let letter = flat_letter();
    let package = unflatten(letter.as_bytes()).unwrap();
    let zip = ZipArchive::new(package).unwrap();
    assert_eq!(
        entry_names(&zip),
        ["mimetype", "content.xml", "styles.xml", "meta.xml", "settings.xml", "Pictures/1.png", "META-INF/manifest.xml"]
    );
    // The mimetype comes first, stored, so it can be read at a fixed offset.
    assert_eq!(zip.entries()[0].method, METHOD_STORED);
    assert_eq!(zip.read_named("mimetype").unwrap(), TEXT.as_bytes());
    assert_eq!(&zip.bytes()[30..38], b"mimetype");
    assert_eq!(&zip.bytes()[38..38 + TEXT.len()], TEXT.as_bytes());

    let content = part(&zip, "content.xml");
    assert!(content.root.is(ns::OFFICE, "document-content"));
    assert_eq!(content.root.name, "office:document-content");
    assert_eq!(content.root.attr(ns::OFFICE, "version"), Some("1.3"));
    assert_eq!(content.root.attr(ns::OFFICE, "mimetype"), None);
    assert_eq!(content.prefix_for(ns::TEXT).as_deref(), Some("text"));
    assert_eq!(content.prefix_for(ns::XLINK).as_deref(), Some("xlink"), "declared for the picture");
    assert_eq!(locals(&content.root), ["scripts", "font-face-decls", "automatic-styles", "body"]);
    let image = content.root.descendants().find(|e| e.is(ns::DRAW, "image")).unwrap();
    assert_eq!(image.attr(ns::XLINK, "href"), Some("Pictures/1.png"));
    assert_eq!(image.attr(ns::XLINK, "type"), Some("simple"));
    assert_eq!(image.attr(ns::XLINK, "show"), Some("embed"));
    assert_eq!(image.attr(ns::XLINK, "actuate"), Some("onLoad"));
    assert_eq!(image.attr(ns::DRAW, "mime-type"), Some("image/png"));
    assert!(image.children.is_empty(), "the data and the space around it are gone: {image:?}");
    let body = content.root.child(ns::OFFICE, "body").unwrap();
    assert_eq!(body.text(), "Dear & welcome");
    // Sections are copied as written.
    let raw = String::from_utf8(zip.read_named("content.xml").unwrap()).unwrap();
    assert!(raw.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content "));
    assert!(raw.contains(r#"<text:p text:style-name="P1">Dear &amp; welcome</text:p>"#));
    assert!(!raw.contains("binary-data"));

    let styles = part(&zip, "styles.xml");
    assert!(styles.root.is(ns::OFFICE, "document-styles"));
    assert_eq!(locals(&styles.root), ["font-face-decls", "styles", "automatic-styles", "master-styles"]);
    assert_eq!(styles.root.attr(ns::OFFICE, "version"), Some("1.3"));
    let meta = part(&zip, "meta.xml");
    assert!(meta.root.is(ns::OFFICE, "document-meta"));
    assert_eq!(meta.root.child(ns::OFFICE, "meta").unwrap().child(ns::DC, "title").unwrap().text(), "Letter");
    let settings = part(&zip, "settings.xml");
    assert!(settings.root.is(ns::OFFICE, "document-settings"));
    assert_eq!(locals(&settings.root), ["settings"]);

    assert_eq!(zip.read_named("Pictures/1.png").unwrap(), png());
    assert_eq!(zip.entries()[5].method, METHOD_STORED, "pictures are stored");
    assert_eq!(
        manifest(&zip),
        [
            ("/", TEXT),
            ("content.xml", "text/xml"),
            ("styles.xml", "text/xml"),
            ("meta.xml", "text/xml"),
            ("settings.xml", "text/xml"),
            ("Pictures/1.png", "image/png"),
        ]
        .map(|(a, b)| (a.to_owned(), b.to_owned()))
    );
    let m = part(&zip, "META-INF/manifest.xml");
    assert_eq!(m.root.attr(ns::MANIFEST, "version"), Some("1.3"));
    assert_eq!(m.root.elements().next().unwrap().attr(ns::MANIFEST, "version"), Some("1.3"));
}

#[test]
fn pictures_anywhere_are_stored_once() {
    let png = PNG_BASE64;
    let jpg = base64_encode(&jpeg(), 0);
    // XLink bound to another prefix on the root; one picture already has
    // a stale link, which is replaced.
    let flat = format!(
        r#"<office:document {NS} xmlns:xl="http://www.w3.org/1999/xlink" office:mimetype="application/vnd.oasis.opendocument.presentation"><office:styles><style:style style:name="bg" style:family="drawing-page"><style:drawing-page-properties><style:background-image><office:binary-data>{png}</office:binary-data></style:background-image></style:drawing-page-properties></style:style><draw:fill-image draw:name="Photo"><office:binary-data>{jpg}</office:binary-data></draw:fill-image></office:styles><office:body><office:presentation><draw:page draw:name="p1"><draw:frame><draw:image xl:href="old.png"><office:binary-data>{png}</office:binary-data></draw:image></draw:frame><draw:frame><draw:image><office:binary-data>{png}</office:binary-data><text:p>caption</text:p></draw:image></draw:frame></draw:page></office:presentation></office:body></office:document>"#
    );
    let zip = ZipArchive::new(unflatten(flat.as_bytes()).unwrap()).unwrap();
    let names = entry_names(&zip);
    assert!(names.contains(&"Pictures/1.png".to_owned()) && names.contains(&"Pictures/2.jpg".to_owned()), "{names:?}");
    assert_eq!(names.iter().filter(|n| n.starts_with("Pictures/")).count(), 2);
    assert_eq!(zip.read_named("Pictures/2.jpg").unwrap(), jpeg());

    let styles = part(&zip, "styles.xml");
    let background = styles.root.descendants().find(|e| e.local() == "background-image").unwrap();
    assert_eq!(background.attr_named("xl:href"), Some("Pictures/1.png"));
    let fill = styles.root.descendants().find(|e| e.local() == "fill-image").unwrap();
    assert_eq!(fill.attr_named("xl:href"), Some("Pictures/2.jpg"));
    assert_eq!(fill.attr(ns::DRAW, "name"), Some("Photo"));
    assert_eq!(styles.root.attr_named("xmlns:xlink"), None, "the root's own prefix is used");

    let content = part(&zip, "content.xml");
    let images: Vec<&Element> = content.root.descendants().filter(|e| e.is(ns::DRAW, "image")).collect();
    assert_eq!(images.len(), 2);
    for image in &images {
        assert_eq!(image.attr(ns::XLINK, "href"), Some("Pictures/1.png"));
        assert_eq!(image.attrs.iter().filter(|a| a.local() == "href").count(), 1);
    }
    // Other content of a picture element is kept.
    assert_eq!(locals(images[1]), ["p"]);
    assert_eq!(images[1].text(), "caption");
    assert!(manifest(&zip).contains(&("Pictures/2.jpg".to_owned(), "image/jpeg".to_owned())));
}

#[test]
fn keeps_what_it_cannot_link() {
    let png = PNG_BASE64;
    // Data straight inside a section; data that is not base64; a second
    // picture in one element; an embedded chart written inline, with a
    // picture of its own; and an element that redeclares the XLink prefix
    // for something else.
    let flat = format!(
        r#"<office:document {NS} office:mimetype="application/vnd.oasis.opendocument.text"><office:styles><office:binary-data>{png}</office:binary-data></office:styles><office:body><office:text><draw:frame><draw:image><office:binary-data>not*base64</office:binary-data></draw:image></draw:frame><draw:frame><draw:image><office:binary-data>{png}</office:binary-data><office:binary-data>{png}</office:binary-data></draw:image></draw:frame><draw:frame><draw:object><office:document office:mimetype="application/vnd.oasis.opendocument.chart"><office:body><office:chart><draw:image><office:binary-data>{png}</office:binary-data></draw:image></office:chart></office:body></office:document></draw:object></draw:frame><text:p xmlns:xlink="urn:not-xlink"><draw:frame><draw:image><office:binary-data>{png}</office:binary-data></draw:image></draw:frame></text:p></office:text></office:body></office:document>"#
    );
    let zip = ZipArchive::new(unflatten(flat.as_bytes()).unwrap()).unwrap();
    let styles = part(&zip, "styles.xml");
    let section = styles.root.child(ns::OFFICE, "styles").unwrap();
    assert!(section.attrs.is_empty());
    assert_eq!(locals(section), ["binary-data"]);
    let content = part(&zip, "content.xml");
    let text = content.root.child(ns::OFFICE, "body").unwrap().child(ns::OFFICE, "text").unwrap();
    let frames: Vec<&Element> = text.descendants().filter(|e| e.is(ns::DRAW, "frame")).collect();
    // The undecodable data stays where it was.
    let bad = frames[0].child(ns::DRAW, "image").unwrap();
    assert_eq!(bad.attr(ns::XLINK, "href"), None);
    assert_eq!(bad.child(ns::OFFICE, "binary-data").unwrap().text(), "not*base64");
    // The first picture is linked, the second stays inline.
    let two = frames[1].child(ns::DRAW, "image").unwrap();
    assert_eq!(two.attr(ns::XLINK, "href"), Some("Pictures/1.png"));
    assert_eq!(two.children_named(ns::OFFICE, "binary-data").count(), 1);
    // The inline chart is untouched.
    let object = frames[2].child(ns::DRAW, "object").unwrap();
    assert_eq!(object.attr(ns::XLINK, "href"), None);
    let chart = object.child(ns::OFFICE, "document").unwrap();
    assert_eq!(chart.attr(ns::OFFICE, "mimetype"), Some("application/vnd.oasis.opendocument.chart"));
    assert!(chart.descendants().any(|e| e.is(ns::OFFICE, "binary-data")));
    // Where the prefix means something else, XLink is declared on the
    // element itself.
    let p = text.child(ns::TEXT, "p").unwrap();
    let image = p.descendants().find(|e| e.is(ns::DRAW, "image")).unwrap();
    assert_eq!(image.attr(ns::XLINK, "href"), Some("Pictures/1.png"));
    assert_eq!(image.attr_named("xmlns:xlink"), Some(ns::XLINK.uri()));
    assert_eq!(entry_names(&zip).iter().filter(|n| n.starts_with("Pictures/")).count(), 1);
}

#[test]
fn a_flat_file_without_pictures_or_sections() {
    let flat = r#"<document xmlns="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" o:mimetype="application/vnd.oasis.opendocument.spreadsheet"><body><spreadsheet/></body></document>"#;
    let zip = ZipArchive::new(unflatten(flat.as_bytes()).unwrap()).unwrap();
    assert_eq!(zip.read_named("mimetype").unwrap(), SPREADSHEET.as_bytes());
    let content = part(&zip, "content.xml");
    assert_eq!(content.root.name, "document-content");
    assert!(content.root.is(ns::OFFICE, "document-content"));
    assert_eq!(locals(&content.root), ["body"]);
    assert_eq!(content.root.attr_named("xmlns:xlink"), None, "no picture needed it");
    // Empty parts are still there, and still well formed.
    let meta = part(&zip, "meta.xml");
    assert!(meta.root.children.is_empty());
    assert!(meta.root.is(ns::OFFICE, "document-meta"));
    assert!(part(&zip, "styles.xml").root.children.is_empty());
    let m = part(&zip, "META-INF/manifest.xml");
    assert_eq!(m.root.attr(ns::MANIFEST, "version"), None, "the flat file has no version");
}

// --- Round trips through packages like the engines' fixtures

fn package(mimetype: &str, parts: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut z = ZipWriter::new();
    z.add("mimetype", mimetype.as_bytes(), Compression::Stored).unwrap();
    let mut entries = format!(r#"<manifest:file-entry manifest:full-path="/" manifest:media-type="{mimetype}"/>"#);
    for (name, bytes) in parts {
        z.add(name, bytes, Compression::DEFAULT).unwrap();
        entries.push_str(&format!(r#"<manifest:file-entry manifest:full-path="{name}" manifest:media-type="text/xml"/>"#));
    }
    let manifest = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">{entries}</manifest:manifest>"#
    );
    z.add("META-INF/manifest.xml", manifest.as_bytes(), Compression::DEFAULT).unwrap();
    z.finish()
}

fn xml_part(root: &str, inner: &str) -> Vec<u8> {
    format!(r#"<?xml version="1.0" encoding="UTF-8"?><office:{root} {NS} xmlns:xlink="http://www.w3.org/1999/xlink" office:version="1.3">{inner}</office:{root}>"#)
        .into_bytes()
}

const META: &str = r#"<office:meta><dc:title>Fixture</dc:title><meta:document-statistic meta:page-count="1"/></office:meta>"#;
const SETTINGS: &str = r#"<office:settings><config:config-item-set config:name="ooo:view-settings"><config:config-item config:name="VisibleAreaTop" config:type="int">0</config:config-item></config:config-item-set></office:settings>"#;
const LINK: &str = r#"xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad""#;

/// A letter like the word engine's: lists, a table, a link, a picture,
/// and a page background picture in the styles.
fn text_package() -> Vec<u8> {
    let content = xml_part(
        "document-content",
        &format!(
            r#"<office:scripts/><office:font-face-decls><style:font-face style:name="Liberation Sans" svg:font-family="'Liberation Sans'"/></office:font-face-decls><office:automatic-styles><style:style style:name="P1" style:family="paragraph"><style:paragraph-properties fo:text-align="center"/></style:style><style:style style:name="T1" style:family="text"><style:text-properties fo:font-style="italic"/></style:style></office:automatic-styles><office:body><office:text><text:h text:outline-level="1">Title</text:h><text:p text:style-name="P1">Hello <text:span text:style-name="T1">world</text:span> &lt;3</text:p><text:list><text:list-item><text:p>One</text:p></text:list-item></text:list><table:table table:name="T"><table:table-column/><table:table-row><table:table-cell office:value-type="string"><text:p>Cell</text:p></table:table-cell></table:table-row></table:table><text:p><text:a xlink:type="simple" xlink:href="http://example.com/">a link</text:a><draw:frame draw:name="Pic" svg:width="2cm" svg:height="2cm"><draw:image xlink:href="Pictures/image1.png" {LINK} draw:mime-type="image/png"/></draw:frame></text:p></office:text></office:body>"#
        ),
    );
    let styles = xml_part(
        "document-styles",
        &format!(
            r#"<office:font-face-decls><style:font-face style:name="Liberation Sans" svg:font-family="'Liberation Sans'"/><style:font-face style:name="Liberation Serif" svg:font-family="'Liberation Serif'"/></office:font-face-decls><office:styles><style:default-style style:family="paragraph"><style:text-properties fo:font-size="12pt"/></style:default-style><style:style style:name="Standard" style:family="paragraph"/></office:styles><office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm"><style:background-image xlink:href="Pictures/paper.jpg" {LINK}/></style:page-layout-properties></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"><style:header><text:p>Header</text:p></style:header></style:master-page></office:master-styles>"#
        ),
    );
    package(
        TEXT,
        &[
            ("content.xml", content),
            ("styles.xml", styles),
            ("meta.xml", xml_part("document-meta", META)),
            ("settings.xml", xml_part("document-settings", SETTINGS)),
            ("Pictures/image1.png", png()),
            ("Pictures/paper.jpg", jpeg()),
        ],
    )
}

/// A workbook like the sheet engine's: values, a formula, a repeated row
/// and a picture over the cells.
fn spreadsheet_package() -> Vec<u8> {
    let content = xml_part(
        "document-content",
        &format!(
            r#"<office:automatic-styles><style:style style:name="co1" style:family="table-column"><style:table-column-properties style:column-width="2.5cm"/></style:style><style:style style:name="ce1" style:family="table-cell"><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles><office:body><office:spreadsheet><table:table table:name="Bills"><table:shapes><draw:frame svg:width="1cm" svg:height="1cm"><draw:image xlink:href="Pictures/logo.png" {LINK}/></draw:frame></table:shapes><table:table-column table:style-name="co1" table:number-columns-repeated="2"/><table:table-row><table:table-cell table:style-name="ce1" office:value-type="string"><text:p>Rent</text:p></table:table-cell><table:table-cell office:value-type="float" office:value="1200.5"><text:p>1200.5</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated="2"><table:table-cell table:number-columns-repeated="2"/></table:table-row><table:table-row><table:table-cell office:value-type="string"><text:p>Total</text:p></table:table-cell><table:table-cell table:formula="of:=SUM([.B1:.B3])" office:value-type="float" office:value="1200.5"><text:p>1200.5</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body>"#
        ),
    );
    let styles = xml_part(
        "document-styles",
        r#"<office:styles><style:default-style style:family="table-cell"><style:text-properties fo:font-size="10pt"/></style:default-style><style:style style:name="Default" style:family="table-cell"/></office:styles><office:automatic-styles><style:page-layout style:name="pm1"/></office:automatic-styles><office:master-styles><style:master-page style:name="Default" style:page-layout-name="pm1"/></office:master-styles>"#,
    );
    package(
        SPREADSHEET,
        &[
            ("content.xml", content),
            ("styles.xml", styles),
            ("meta.xml", xml_part("document-meta", META)),
            ("settings.xml", xml_part("document-settings", SETTINGS)),
            ("Pictures/logo.png", png()),
        ],
    )
}

/// A deck like the slide engine's: a master page with a band, two slides,
/// a picture and notes. Its settings are missing, as some writers leave
/// them out.
fn presentation_package() -> Vec<u8> {
    let content = xml_part(
        "document-content",
        &format!(
            r##"<office:automatic-styles><style:style style:name="dp1" style:family="drawing-page"/><style:style style:name="gr1" style:family="graphic"><style:graphic-properties draw:fill-color="#336699"/></style:style></office:automatic-styles><office:body><office:presentation><draw:page draw:name="page1" draw:style-name="dp1" draw:master-page-name="Default"><draw:frame presentation:class="title" svg:x="1cm" svg:y="1cm" svg:width="20cm" svg:height="3cm"><draw:text-box><text:p>Family trip</text:p></draw:text-box></draw:frame><draw:frame svg:x="5cm" svg:y="5cm" svg:width="4cm" svg:height="4cm"><draw:image xlink:href="./Pictures/beach.png" {LINK}/></draw:frame></draw:page><draw:page draw:name="page2" draw:master-page-name="Default"><draw:custom-shape draw:style-name="gr1" svg:width="4cm" svg:height="2cm"><text:p>Go</text:p><draw:enhanced-geometry draw:type="ellipse"/></draw:custom-shape><presentation:notes><draw:frame presentation:class="notes"><draw:text-box><text:p>Leave at nine</text:p></draw:text-box></draw:frame></presentation:notes></draw:page></office:presentation></office:body>"##
        ),
    );
    let styles = xml_part(
        "document-styles",
        r##"<office:styles><style:default-style style:family="graphic"><style:graphic-properties draw:fill-color="#729fcf"/></style:default-style></office:styles><office:automatic-styles><style:page-layout style:name="PM1"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm"/></style:page-layout><style:style style:name="Mdp1" style:family="drawing-page"><style:drawing-page-properties draw:fill="solid" draw:fill-color="#ffffcc"/></style:style></office:automatic-styles><office:master-styles><style:master-page style:name="Default" style:page-layout-name="PM1" draw:style-name="Mdp1"><draw:rect svg:x="0cm" svg:y="15cm" svg:width="28cm" svg:height="0.75cm"/></style:master-page></office:master-styles>"##,
    );
    package(
        PRESENTATION,
        &[
            ("content.xml", content),
            ("styles.xml", styles),
            ("meta.xml", xml_part("document-meta", META)),
            ("Pictures/beach.png", png()),
        ],
    )
}

/// An element with its attributes in a fixed order, and every link to a
/// file in `zip` replaced by the checksum of that file, so that elements
/// from two packages that name their pictures differently compare equal.
fn normalized(e: &Element, zip: &ZipArchive) -> Element {
    let mut out = e.clone();
    out.attrs.sort_by(|a, b| a.name.cmp(&b.name));
    for a in &mut out.attrs {
        if a.ns == ns::XLINK && a.local() == "href" {
            let path = a.value.strip_prefix("./").unwrap_or(&a.value);
            if let Ok(bytes) = zip.read_named(path) {
                a.value = format!("crc:{:08x}", crc32(&bytes));
            }
        }
    }
    for child in &mut out.children {
        if let Node::Element(c) = child {
            *c = normalized(c, zip);
        }
    }
    out
}

fn section_of(zip: &ZipArchive, part_name: &str, local: &str) -> Option<Element> {
    if !zip.contains(part_name) {
        return None;
    }
    part(zip, part_name).root.child(ns::OFFICE, local).map(|e| normalized(e, zip))
}

/// Flatten a package, unflatten it again, and check every section came
/// back with its pictures.
fn round_trip(original: Vec<u8>, mimetype: &str, pictures: usize) {
    let flat = flatten(&original).unwrap();
    assert_eq!(flat_mimetype(&flat).as_deref(), Some(mimetype));
    let flat_text = String::from_utf8(flat.clone()).unwrap();
    assert_eq!(flat_text.matches("<office:binary-data>").count(), pictures, "{flat_text}");
    assert!(!flat_text.contains("Pictures/"), "pictures are inline: {flat_text}");
    assert!(flat_text.contains(r#"xlink:href="http://example.com/""#) || mimetype != TEXT, "links to elsewhere stay");

    let again = unflatten(&flat).unwrap();
    let before = ZipArchive::new(original).unwrap();
    let after = ZipArchive::new(again.clone()).unwrap();
    assert_eq!(after.read_named("mimetype").unwrap(), mimetype.as_bytes());
    for (part_name, local) in [
        ("content.xml", "body"),
        ("content.xml", "scripts"),
        ("styles.xml", "styles"),
        ("styles.xml", "master-styles"),
        ("meta.xml", "meta"),
        ("settings.xml", "settings"),
    ] {
        assert_eq!(section_of(&before, part_name, local), section_of(&after, part_name, local), "{part_name} {local}");
    }
    // Font declarations and automatic styles from both parts are in both.
    for local in ["font-face-decls", "automatic-styles"] {
        let mut wanted: Vec<Element> = Vec::new();
        for part_name in ["content.xml", "styles.xml"] {
            if let Some(s) = section_of(&before, part_name, local) {
                for e in s.elements() {
                    if !wanted.contains(e) {
                        wanted.push(e.clone());
                    }
                }
            }
        }
        for part_name in ["content.xml", "styles.xml"] {
            let got: Vec<Element> = section_of(&after, part_name, local).map(|s| s.elements().cloned().collect()).unwrap_or_default();
            assert_eq!(got, wanted, "{part_name} {local}");
        }
    }
    let content = part(&after, "content.xml");
    assert_eq!(content.root.attr(ns::OFFICE, "version"), Some("1.3"));
    assert_eq!(content.root.attr(ns::OFFICE, "mimetype"), None);
    let listed = manifest(&after);
    for name in entry_names(&after) {
        if name != "mimetype" && name != "META-INF/manifest.xml" {
            assert!(listed.iter().any(|(path, _)| *path == name), "{name} is in the manifest");
        }
    }
    assert_eq!(after.entries().iter().filter(|e| e.name.starts_with("Pictures/")).count(), pictures);

    // Flattening the result gives the same flat file.
    assert_eq!(String::from_utf8(flatten(&again).unwrap()).unwrap(), flat_text);
}

#[test]
fn packages_round_trip_through_flat_files() {
    round_trip(text_package(), TEXT, 2);
    round_trip(spreadsheet_package(), SPREADSHEET, 1);
    round_trip(presentation_package(), PRESENTATION, 1);
}

#[test]
fn flattening_needs_a_package_with_content() {
    assert!(matches!(flatten(b"not a zip"), Err(OdfError::Zip(_))));
    let mut z = ZipWriter::new();
    z.add("mimetype", TEXT.as_bytes(), Compression::Stored).unwrap();
    assert_eq!(flatten(&z.finish()), Err(OdfError::Missing("content.xml".into())));
}

#[test]
fn picture_kinds_by_their_first_bytes() {
    let mut emf = vec![1, 0, 0, 0];
    emf.resize(40, 0);
    emf.extend_from_slice(b" EMF");
    let cases: [(&[u8], &str); 10] = [
        (&png(), "png"),
        (&jpeg(), "jpg"),
        (b"GIF89a....", "gif"),
        (&[0xD7, 0xCD, 0xC6, 0x9A, 0, 0], "wmf"),
        (&[1, 0, 9, 0, 0, 3, 0, 0], "wmf"),
        (&emf, "emf"),
        (b"BM....", "bmp"),
        (b"II*\0....", "tif"),
        (b"\xEF\xBB\xBF<?xml version=\"1.0\"?>\n<!-- drawn --><svg xmlns=\"http://www.w3.org/2000/svg\"/>", "svg"),
        (b"\x00\x01\x02", "bin"),
    ];
    for (bytes, ext) in cases {
        assert_eq!(picture_kind(bytes).0, ext, "{bytes:?}");
    }
    assert_eq!(picture_kind(b"<html/>").0, "bin");
}
