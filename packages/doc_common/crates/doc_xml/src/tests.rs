use super::*;

const DOCX_BODY: &str = concat!(
    r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
    "\r\n",
    r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" "#,
    r#"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" "#,
    r#"xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="w14">"#,
    "<w:body>",
    r#"<w:p w:rsidR="00A1"><w:pPr><w:jc w:val="center"/></w:pPr>"#,
    r#"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Hello &amp; welcome  </w:t></w:r></w:p>"#,
    "<!-- a comment --><?pi data?>",
    r#"<w:p><w:r><w:t>5 &lt; 6 &gt; 4 "quoted" 'single'</w:t></w:r></w:p>"#,
    r#"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>"#,
    "</w:body></w:document>",
);

#[test]
fn canonical_documents_round_trip_exactly() {
    let doc = Document::parse(DOCX_BODY.as_bytes()).unwrap();
    assert_eq!(doc.to_xml(), DOCX_BODY);
}

#[test]
fn resolves_namespaces_by_uri() {
    let doc = Document::parse_str(DOCX_BODY).unwrap();
    assert!(doc.root.is(ns::W, "document"));
    let body = doc.root.child(ns::W, "body").unwrap();
    let paragraphs: Vec<_> = body.children_named(ns::W, "p").collect();
    assert_eq!(paragraphs.len(), 2);
    let jc = paragraphs[0]
        .child(ns::W, "pPr")
        .and_then(|p| p.child(ns::W, "jc"))
        .unwrap();
    assert_eq!(jc.attr(ns::W, "val"), Some("center"));
    assert_eq!(jc.attr(ns::NONE, "val"), None);
    let t = paragraphs[0].descendants().find(|e| e.is(ns::W, "t")).unwrap();
    assert_eq!(t.attr(ns::XML, "space"), Some("preserve"));
    assert_eq!(t.text(), "Hello & welcome  ");
    assert_eq!(doc.prefix_for(ns::W).as_deref(), Some("w"));
    assert_eq!(doc.prefix_for(ns::R).as_deref(), Some("r"));
    assert_eq!(doc.prefix_for(ns::S), None);
}

#[test]
fn strict_and_transitional_namespaces_match() {
    let strict = r#"<x:worksheet xmlns:x="http://purl.oclc.org/ooxml/spreadsheetml/main"><x:sheetData/></x:worksheet>"#;
    let default_ns = r#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>"#;
    for xml in [strict, default_ns] {
        let doc = Document::parse_str(xml).unwrap();
        assert!(doc.root.is(ns::S, "worksheet"), "{xml}");
        assert!(doc.root.child(ns::S, "sheetData").is_some());
        assert_eq!(doc.to_xml(), xml);
    }
    let doc = Document::parse_str(default_ns).unwrap();
    assert_eq!(doc.prefix_for(ns::S).as_deref(), Some(""));
    assert_eq!(ns::S.uri(), "http://schemas.openxmlformats.org/spreadsheetml/2006/main");
}

#[test]
fn nested_redeclarations_and_unknown_namespaces() {
    let xml = r#"<a xmlns="urn:one" xmlns:p="urn:two"><b><p:c/><d xmlns="urn:three"><e/></d></b><q:f/></a>"#;
    let doc = Document::parse_str(xml).unwrap();
    let one = Ns::from_uri("urn:one");
    let two = Ns::from_uri("urn:two");
    let three = Ns::from_uri("urn:three");
    assert_ne!(one, two);
    assert_eq!(doc.root.ns, one);
    let b = doc.root.child(one, "b").unwrap();
    assert!(b.child(two, "c").is_some());
    let d = b.child(three, "d").unwrap();
    assert!(d.child(three, "e").is_some());
    // An undeclared prefix gets its own identity rather than an error.
    let f = doc.root.elements().last().unwrap();
    assert_eq!(f.local(), "f");
    assert_ne!(f.ns, ns::NONE);
    assert_eq!(Ns::from_uri("urn:one").uri(), "urn:one");
}

#[test]
fn entities_and_character_references() {
    let doc = Document::parse_str("<a t='&#x41;&#66;&lt;&quot;&apos;'>&#x1F600; &nbsp; &amp;amp; caf&#233;</a>").unwrap();
    assert_eq!(doc.root.attr(ns::NONE, "t"), Some("AB<\"'"));
    assert_eq!(doc.root.text(), "😀 &nbsp; &amp; café");
    assert!(Document::parse_str("<a>&#xD800;</a>").is_err());
    assert!(Document::parse_str("<a>&#99999999;</a>").is_err());
    // A bare ampersand is kept rather than rejected.
    assert_eq!(Document::parse_str("<a>Tom & Jerry</a>").unwrap().root.text(), "Tom & Jerry");
}

#[test]
fn attribute_values_are_normalized() {
    let doc = Document::parse_str("<a v=\"one\ntwo\tthree&#10;four\"/>").unwrap();
    assert_eq!(doc.root.attr(ns::NONE, "v"), Some("one two three\nfour"));
    // ...and written so that they read back the same.
    let again = Document::parse_str(&doc.to_xml()).unwrap();
    assert_eq!(again.root.attr(ns::NONE, "v"), Some("one two three\nfour"));
}

#[test]
fn line_ends_are_normalized_but_escaped_returns_survive() {
    let doc = Document::parse_str("<a>one\r\ntwo\rthree&#13;</a>").unwrap();
    assert_eq!(doc.root.text(), "one\ntwo\nthree\r");
    let again = Document::parse_str(&doc.to_xml()).unwrap();
    assert_eq!(again.root.text(), "one\ntwo\nthree\r");
}

#[test]
fn doctype_entities_are_never_expanded() {
    let xxe = r#"<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd"><!ENTITY lol "lol">]><x>&e;&lol;</x>"#;
    let doc = Document::parse_str(xxe).unwrap();
    assert_eq!(doc.root.text(), "&e;&lol;");
    assert!(matches!(doc.prolog.first(), Some(Node::DocType(t)) if t.starts_with("x [")));
}

#[test]
fn malformed_documents_are_rejected() {
    for bad in [
        "<a><b></a></b>",
        "<a>",
        "<a></a><b/>",
        "</a>",
        "<a x=1/>",
        "<a x='1/>",
        "<a><!-- unterminated </a>",
        "",
        "just text",
    ] {
        assert!(Document::parse_str(bad).is_err(), "{bad:?} should fail");
    }
    let deep = "<a>".repeat(MAX_DEPTH + 1) + &"</a>".repeat(MAX_DEPTH + 1);
    let err = Document::parse_str(&deep).unwrap_err();
    assert!(err.message.contains("deeply"));
    let fine = "<a>".repeat(MAX_DEPTH) + &"</a>".repeat(MAX_DEPTH);
    assert!(Document::parse_str(&fine).is_ok());
}

#[test]
fn cdata_comments_and_pis_survive() {
    let xml = "<a><![CDATA[<raw> & ]]]]><![CDATA[> end]]><!--c--><?target x?>tail</a>";
    let doc = Document::parse_str(xml).unwrap();
    assert_eq!(doc.root.text(), "<raw> & ]]> endtail");
    let again = Document::parse_str(&doc.to_xml()).unwrap();
    assert_eq!(again, doc);
}

#[test]
fn editing_keeps_everything_else() {
    let mut doc = Document::parse_str(DOCX_BODY).unwrap();
    let body = doc.root.child_mut(ns::W, "body").unwrap();
    let p = body.child_mut(ns::W, "p").unwrap();
    let jc = p
        .child_mut(ns::W, "pPr")
        .and_then(|p| p.child_mut(ns::W, "jc"))
        .unwrap();
    jc.set_attr("w:val", ns::W, "right");
    let xml = doc.to_xml();
    assert_eq!(xml, DOCX_BODY.replace(r#"w:val="center""#, r#"w:val="right""#));
}

#[test]
fn reader_skips_and_reads_text() {
    let xml = r#"<root><skip><deep><x/></deep></skip><t>one<b>two</b><![CDATA[three]]></t><e/></root>"#;
    let mut reader = Reader::new(xml);
    let mut seen = Vec::new();
    loop {
        match reader.next().unwrap() {
            Event::Start(tag) if tag.name == "skip" => reader.skip_element().unwrap(),
            Event::Start(tag) if tag.name == "t" => seen.push(reader.read_text().unwrap()),
            Event::Start(tag) if tag.name == "e" => {
                assert!(tag.empty);
                seen.push(reader.read_text().unwrap());
            }
            Event::Start(tag) => seen.push(format!("<{}>", tag.name)),
            Event::End(name) => seen.push(format!("</{name}>")),
            Event::Eof => break,
            _ => {}
        }
    }
    assert_eq!(seen, ["<root>", "onetwothree", "", "</root>"]);
}

#[test]
fn start_tag_attribute_access() {
    let mut reader = Reader::new(r#"<c r="B2" s = '3' t="s"/>"#);
    let Event::Start(tag) = reader.next().unwrap() else { panic!() };
    assert_eq!(tag.local(), "c");
    assert_eq!(tag.attr("s").as_deref(), Some("3"));
    let all: Vec<_> = tag.attrs().map(|a| a.unwrap().0).collect();
    assert_eq!(all, ["r", "s", "t"]);
    assert_eq!(reader.next().unwrap(), Event::End("c"));
    assert_eq!(reader.next().unwrap(), Event::Eof);
}

#[test]
fn decodes_declared_and_marked_encodings() {
    let utf16: Vec<u8> = [0xFF, 0xFE]
        .into_iter()
        .chain("<a>తెలుగు</a>".encode_utf16().flat_map(u16::to_le_bytes))
        .collect();
    assert_eq!(Document::parse(&utf16).unwrap().root.text(), "తెలుగు");
    let latin1 = b"<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf\xE9</a>";
    let doc = Document::parse(latin1).unwrap();
    assert_eq!(doc.root.text(), "café");
    // Written back as UTF-8, and the declaration says so.
    assert!(doc.to_xml().starts_with(r#"<?xml version="1.0" encoding="UTF-8"?>"#));
}

#[test]
fn writer_escapes_and_nests() {
    let mut w = XmlWriter::with_declaration();
    w.start("root").attr("note", "a \"quote\" & <tag>\n");
    w.element_text("t", "x < y & z");
    w.start("empty").end();
    w.start("ctl").text("bell\u{7}").end();
    let xml = w.finish();
    let doc = Document::parse_str(&xml).unwrap();
    assert_eq!(doc.root.attr(ns::NONE, "note"), Some("a \"quote\" & <tag>\n"));
    assert_eq!(doc.root.child(ns::NONE, "t").unwrap().text(), "x < y & z");
    assert!(xml.contains("<empty/>"));
    // Characters XML 1.0 cannot carry are replaced, never written raw.
    assert_eq!(doc.root.child(ns::NONE, "ctl").unwrap().text(), "bell\u{FFFD}");
}

#[test]
fn descendants_are_in_document_order() {
    let doc = Document::parse_str("<a><b><c/><d/></b><e><f/></e></a>").unwrap();
    let names: Vec<_> = doc.root.descendants().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["b", "c", "d", "e", "f"]);
}

#[test]
fn new_documents_carry_office_declaration() {
    let root = Element::new("Types", Ns::from_uri("http://schemas.openxmlformats.org/package/2006/content-types"))
        .with_attr("xmlns", ns::XMLNS, ns::CONTENT_TYPES.uri());
    let xml = Document::new(root).to_xml();
    assert_eq!(
        xml,
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"
    );
}
