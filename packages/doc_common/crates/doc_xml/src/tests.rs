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
    // URIs that are not well-known get identities from the document.
    let one = doc.namespaces.get("urn:one").unwrap();
    let two = doc.namespaces.get("urn:two").unwrap();
    let three = doc.namespaces.get("urn:three").unwrap();
    assert_ne!(one, two);
    assert_eq!(doc.namespaces.uri(three), Some("urn:three"));
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

// --- Hostile input
//
// Each of these failed or aborted before the fix it guards: stack overflow
// on deep trees, quadratic time on many ampersands or namespaces, a tree
// without a size limit, and panics on characters beyond ASCII.

use std::time::{Duration, Instant};

/// The allocator for these tests: the system's, counting the bytes each
/// thread holds, so a test can bound what a parse allocates.
mod memory {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    pub struct Counting;

    thread_local! {
        static HELD: Cell<isize> = const { Cell::new(0) };
        static PEAK: Cell<isize> = const { Cell::new(0) };
    }

    fn add(n: isize) {
        let _ = HELD.try_with(|held| {
            let now = held.get() + n;
            held.set(now);
            let _ = PEAK.try_with(|peak| peak.set(peak.get().max(now)));
        });
    }

    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }

        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc_zeroed(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }

        unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
            unsafe { System.dealloc(p, layout) };
            add(-(layout.size() as isize));
        }

        unsafe fn realloc(&self, p: *mut u8, layout: Layout, size: usize) -> *mut u8 {
            let q = unsafe { System.realloc(p, layout, size) };
            if !q.is_null() {
                add(size as isize - layout.size() as isize);
            }
            q
        }
    }

    /// What `f` returns, and the most bytes this thread held at once while
    /// it ran beyond what it held before.
    pub fn peak<T>(f: impl FnOnce() -> T) -> (T, usize) {
        let start = HELD.with(Cell::get);
        PEAK.with(|peak| peak.set(start));
        let out = f();
        (out, (PEAK.with(Cell::get) - start).max(0) as usize)
    }
}

#[global_allocator]
static ALLOCATOR: memory::Counting = memory::Counting;

const KIB: usize = 1024;
const MIB: usize = 1024 * 1024;

/// Run `f` on a thread with a small stack (Dart's isolates have 1 MiB, and
/// 32-bit phones half that), failing if it runs longer than `limit`.
fn hostile<T: Send + 'static>(stack: usize, limit: Duration, f: impl FnOnce() -> T + Send + 'static) -> T {
    let (done, result) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .stack_size(stack)
        .spawn(move || {
            let _ = done.send(f());
        })
        .unwrap();
    match result.recv_timeout(limit) {
        Ok(out) => out,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => panic!("took longer than {limit:?}"),
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => panic!("the thread panicked"),
    }
}

/// Check a time measured in an optimized build (`cargo test --release`)
/// against `release`; debug builds are held only to the bound [`hostile`]
/// sets.
fn within(elapsed: Duration, release: Duration) {
    if !cfg!(debug_assertions) {
        assert!(elapsed < release, "took {elapsed:?}, more than {release:?}");
    }
}

/// An element nested `depth` deep, built by code (deeper than a parse
/// allows), with text at the bottom.
fn nested(depth: usize) -> Element {
    let mut e = Element::new("a", ns::NONE);
    e.set_text("deep");
    for _ in 0..depth {
        let mut parent = Element::new("a", ns::NONE).with_attr("k", ns::NONE, "v");
        parent.push(e);
        e = parent;
    }
    e
}

#[test]
fn deep_trees_are_dropped_cloned_and_compared_without_recursion() {
    // Before, each of these overflowed a 512 KiB stack and aborted.
    hostile(512 * KIB, Duration::from_secs(60), || {
        let tree = nested(100_000);
        let copy = tree.clone();
        assert!(copy == tree);
        assert_eq!(tree.text(), "deep");
        assert_eq!(tree.descendants().count(), 100_000);
        let xml = tree.to_xml();
        assert!(xml.starts_with("<a k=\"v\"><a k=\"v\">") && xml.contains("<a>deep</a></a>"));
        assert_eq!(xml.matches("</a>").count(), 100_001);
        // A difference at the bottom is found.
        let mut other = copy.clone();
        let mut bottom = &mut other;
        while bottom.children.first().is_some_and(|n| n.as_element().is_some()) {
            bottom = bottom.children[0].as_element_mut().unwrap();
        }
        bottom.set_text("changed");
        assert!(other != tree);
        drop(copy);
        drop(other);
        drop(tree);
    });
}

#[test]
fn documents_at_the_depth_limit_work_on_a_small_stack() {
    hostile(128 * KIB, Duration::from_secs(60), || {
        let xml = "<a x='1'>".repeat(MAX_DEPTH) + "text" + &"</a>".repeat(MAX_DEPTH);
        let doc = Document::parse_str(&xml).unwrap();
        let copy = doc.clone();
        assert!(copy == doc);
        assert_eq!(doc.root.text(), "text");
        assert_eq!(doc.to_xml(), xml.replace('\'', "\""));
        drop(copy);
        drop(doc);
    });
}

#[test]
fn equality_and_clones_see_every_difference() {
    let doc = Document::parse_str(DOCX_BODY).unwrap();
    let copy = doc.clone();
    assert_eq!(copy, doc);
    assert_eq!(copy.to_xml(), DOCX_BODY);
    let base = doc.root.clone();
    let change = |f: &dyn Fn(&mut Element)| {
        let mut e = base.clone();
        f(&mut e);
        e
    };
    fn body(e: &mut Element) -> &mut Element {
        e.child_mut(ns::W, "body").unwrap()
    }
    for (what, changed) in [
        ("name", change(&|e| body(e).name = "w:bodx".into())),
        ("namespace", change(&|e| body(e).ns = ns::S)),
        ("attribute", change(&|e| body(e).set_attr("w:x", ns::W, "1"))),
        ("child count", change(&|e| body(e).push(Element::new("w:p", ns::W)))),
        ("text", change(&|e| body(e).child_mut(ns::W, "p").unwrap().set_text("x"))),
        ("kind", change(&|e| body(e).children[1] = Node::Text("<!-- a comment -->".into()))),
    ] {
        assert_ne!(changed, base, "{what}");
        assert_ne!(base, changed, "{what}");
    }
}

#[test]
fn the_node_budget_stops_huge_trees() {
    // Exactly the budget parses; one node more does not. The root, its
    // attribute, two children, a text node and a comment are six nodes.
    let xml = "<a k='v'><b/><c>text</c><!--c--></a>";
    assert!(Document::parse_limited(xml, 6).is_ok());
    let err = Document::parse_limited(xml, 5).unwrap_err();
    assert!(err.is_too_large(), "{err}");
    assert!(!Document::parse_str("<a><b></a>").unwrap_err().is_too_large());

    // A part of four million empty elements (what a few kilobytes of
    // deflate become) stops at the budget, quickly and with bounded memory.
    // Before, it built the whole tree, twice the memory measured here.
    let (err, held) = hostile(512 * KIB, Duration::from_secs(60), || {
        let xml = format!("<a>{}</a>", "<b/>".repeat(4_000_000));
        memory::peak(|| Document::parse_str(&xml).unwrap_err())
    });
    assert!(err.is_too_large(), "{err}");
    assert!(err.to_string().contains("more than 2000000"), "{err}");
    assert!(held < 300 * MIB, "a stopped parse held {} MiB", held / MIB);

    // Attributes count too.
    let err = hostile(512 * KIB, Duration::from_secs(60), || {
        let xml = format!("<a{}/>", " b=''".repeat(MAX_NODES));
        Document::parse_str(&xml).unwrap_err()
    });
    assert!(err.is_too_large(), "{err}");
}

#[test]
fn many_ampersands_take_linear_time() {
    // Before, each bare ampersand searched the rest of the text for a ';'.
    // A hundred thousand took 0.8 s in a release build, a million 83 s.
    let text = hostile(512 * KIB, Duration::from_secs(10), || {
        let xml = format!("<a t='{}'>{}</a>", "&".repeat(1_000_000), "&".repeat(1_000_000));
        let started = Instant::now();
        let doc = Document::parse_str(&xml).unwrap();
        (doc.root.text().len(), doc.root.attr(ns::NONE, "t").map(str::len), started.elapsed())
    });
    assert_eq!((text.0, text.1), (1_000_000, Some(1_000_000)));
    within(text.2, Duration::from_millis(500));
    // References are still found up to 32 bytes after the ampersand.
    let name = "n".repeat(31);
    let xml = format!("<a>&{name};|&{name}x;|&#x{};</a>", "0".repeat(27) + "41");
    let doc = Document::parse_str(&xml).unwrap();
    assert_eq!(doc.root.text(), format!("&{name};|&{name}x;|A"));
    assert_eq!(doc.to_xml(), format!("<a>&{name};|&amp;{name}x;|A</a>"));
}

#[test]
fn many_namespaces_take_linear_time() {
    // Before, each prefix was looked for in every scope in turn, and each
    // URI in a process-wide list: 40,000 took 3.9 s in a release build.
    let count = 40_000;
    let (doc, elapsed) = hostile(512 * KIB, Duration::from_secs(10), move || {
        let mut xml = String::from("<a");
        for i in 0..count {
            xml.push_str(&format!(" xmlns:p{i}=\"urn:many:{i}\""));
        }
        xml.push('>');
        for i in 0..count {
            xml.push_str(&format!("<p{i}:b p{i}:c=\"1\"/>"));
        }
        xml.push_str("</a>");
        // The best of three, so that a busy machine does not fail the test.
        let mut best = Duration::MAX;
        let mut doc = None;
        for _ in 0..3 {
            let started = Instant::now();
            let parsed = Document::parse_str(&xml).unwrap();
            best = best.min(started.elapsed());
            doc = Some(parsed);
        }
        (doc.unwrap(), best)
    });
    within(elapsed, Duration::from_millis(200));
    let b: Vec<&Element> = doc.root.elements().collect();
    assert_eq!(b.len(), count);
    for i in [0, 1, 7_777, 32_765] {
        let uri = format!("urn:many:{i}");
        assert_eq!(doc.namespaces.uri(b[i].ns), Some(uri.as_str()));
        assert_eq!(b[i].attrs[0].ns, b[i].ns);
        // Parsing names nothing process-wide.
        assert_eq!(Ns::find(&uri), None);
    }
    // A document numbers at most 32,766 URIs; the rest share one identity.
    assert_eq!(b[32_766].ns, ns::OVERFLOW);
    assert_ne!(b[0].ns, b[1].ns);
    drop(doc);

    // Deep redeclarations are undone as their elements close.
    let depth = MAX_DEPTH - 1;
    let mut xml = String::from("<r xmlns:p='urn:outer'>");
    for i in 0..depth {
        xml.push_str(&format!("<p:e xmlns:p='urn:level:{i}'>"));
    }
    xml.push_str(&"</p:e>".repeat(depth));
    xml.push_str("<p:after/></r>");
    let doc = Document::parse_str(&xml).unwrap();
    let after = doc.root.elements().last().unwrap();
    assert_eq!(doc.namespaces.uri(after.ns), Some("urn:outer"));
    let deepest = doc.root.descendants().nth(depth - 1).unwrap();
    assert_eq!(doc.namespaces.uri(deepest.ns), Some(format!("urn:level:{}", depth - 1).as_str()));
}

#[test]
fn namespaces_belong_to_their_document() {
    let one = Document::parse_str("<x:a xmlns:x='urn:doc:one'><q:b/></x:a>").unwrap();
    let two = Document::parse_str("<x:a xmlns:x='urn:doc:two'/>").unwrap();
    // The same number, each document's own URI.
    assert_eq!(one.root.ns, two.root.ns);
    assert_eq!(one.namespaces.uri(one.root.ns), Some("urn:doc:one"));
    assert_eq!(two.namespaces.uri(two.root.ns), Some("urn:doc:two"));
    assert_eq!(Ns::find("urn:doc:one"), None);
    // An undeclared prefix gets the identity all of them share, interned
    // nowhere.
    let b = one.root.elements().next().unwrap();
    assert_eq!(b.ns, ns::UNDECLARED);
    assert_eq!(Ns::find("urn:undeclared-prefix:q"), None);
    assert_eq!(one.prefix_for(one.root.ns).as_deref(), Some("x"));
    // URIs code names are interned as before, and found by prefix.
    let code = Ns::from_uri("urn:named:by:code");
    assert_eq!(Ns::find("urn:named:by:code"), Some(code));
    assert_eq!(code.uri(), "urn:named:by:code");
    let mut doc = Document::new(Element::new("c:root", code).with_attr("xmlns:c", ns::XMLNS, code.uri()));
    assert_eq!(doc.prefix_for(code).as_deref(), Some("c"));
    doc.root.set_attr("xmlns:w", ns::XMLNS, ns::W.uri());
    assert_eq!(doc.prefix_for(ns::W).as_deref(), Some("w"));
    // OpenDocument settings are well-known, so code and documents agree.
    let settings = Document::parse_str("<c:s xmlns:c='urn:oasis:names:tc:opendocument:xmlns:config:1.0'/>").unwrap();
    assert_eq!(settings.root.ns, ns::CONFIG);
    assert_eq!(Ns::from_uri("urn:oasis:names:tc:opendocument:xmlns:config:1.0"), ns::CONFIG);
}

#[test]
fn later_documents_still_tell_their_namespaces_apart() {
    // Before, every URI a document named went into one process-wide table
    // for good, and past 4,096 of them all new URIs shared one identity, so
    // a later document could no longer tell its namespaces apart.
    for i in 0..5_000 {
        Document::parse_str(&format!("<a xmlns='urn:earlier:{i}'/>")).unwrap();
    }
    let doc = Document::parse_str("<a xmlns:x='urn:later:x' xmlns:y='urn:later:y'><x:b/><y:b/></a>").unwrap();
    let b: Vec<&Element> = doc.root.elements().collect();
    assert_ne!(b[0].ns, b[1].ns);
    assert_eq!(doc.namespaces.uri(b[1].ns), Some("urn:later:y"));
}

#[test]
fn markup_beyond_ascii_does_not_panic() {
    // Before, a character across byte 3 of a processing instruction or
    // byte 9 of a markup declaration panicked the reader.
    for xml in [
        "<a><?éé?></a>",
        "<?éé?><a/>",
        "<a><?x日本?></a>",
        "<a><!DOCTYPé x></a>",
        "<a><!DOCé></a>",
        "<!DOCTYPé><a/>",
        "<!DOCTYPEé><a/>",
        "<a><!é></a>",
    ] {
        let _ = Document::parse_str(xml);
        let mut reader = Reader::new(xml);
        while !matches!(reader.next(), Ok(Event::Eof) | Err(_)) {}
    }
    let doc = Document::parse_str("<a><?éé data?></a>").unwrap();
    assert_eq!(doc.root.children, [Node::Pi("éé data".into())]);
}

#[test]
fn unknown_entities_and_comments_are_kept_as_written() {
    // Before, `&nbsp;` was written back as `&amp;nbsp;` and `--` inside a
    // comment as `- -`.
    let xml = "<a t='x'>caf&eacute; &nbsp;x &amp;nbsp; R&amp;D &lt;<b>&co;</b><!-- a -- b --><!--x--->&e1.x-y;</a>";
    let doc = Document::parse_str(xml).unwrap();
    assert_eq!(doc.to_xml(), xml.replace("t='x'", "t=\"x\""));
    assert_eq!(doc.root.text(), "caf&eacute; &nbsp;x &nbsp; R&D <&co;&e1.x-y;");
    assert_eq!(doc.root.children[1], Node::EntityRef("eacute".into()));
    // Text that merely looks like a reference stays text, written escaped.
    let mut e = Element::new("t", ns::NONE);
    e.set_text("&nbsp; & &1x; & x;");
    assert_eq!(e.to_xml(), "<t>&amp;nbsp; &amp; &amp;1x; &amp; x;</t>");
    // A comment made by code that holds "-->" is still written safely.
    let mut e = Element::new("c", ns::NONE);
    e.children.push(Node::Comment("a --> b".into()));
    let again = Document::parse_str(&e.to_xml()).unwrap();
    assert_eq!(again.root.children, [Node::Comment("a - -> b".into())]);
}

#[test]
fn text_around_the_root_is_kept_as_read() {
    // Only a lenient reader accepts more than whitespace around the root.
    // Before, it was escaped on writing, and again on every later save:
    // `>` became `&gt;`, then `&amp;gt;`, `&amp;amp;gt;`...
    let xml = "junk & <?pi?>\r\n<a>&amp;</a>&gt; > &nbsp;\0\n";
    let doc = Document::parse_str(xml).unwrap();
    assert_eq!(doc.to_xml(), xml);
    assert_eq!(Document::parse_str(&doc.to_xml()).unwrap().to_xml(), xml);
}

/// A xorshift generator, so mutation runs are the same every time.
struct XorShift(u64);

impl XorShift {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

/// Pieces of markup worth inserting, beyond random bytes.
const TOKENS: [&str; 26] = [
    "<", ">", "/>", "</", "&", ";", "\"", "'", "=", "?", "!", "-", "]", "\r", "é", "日", "😀", "<!--", "-->", "<?", "?>",
    "<![CDATA[", "]]>", "<!DOCTYPE", "&#x", "xmlns:",
];

/// `bytes` changed in one to four places.
fn mutate(bytes: &[u8], rng: &mut XorShift) -> Vec<u8> {
    let mut out = bytes.to_vec();
    for _ in 0..1 + rng.below(4) {
        let at = rng.below(out.len() + 1);
        match rng.below(6) {
            0 if at < out.len() => out[at] = rng.next() as u8,
            1 => {
                let token = TOKENS[rng.below(TOKENS.len())].as_bytes();
                out.splice(at..at, token.iter().copied());
            }
            2 if at < out.len() => {
                let end = (at + 1 + rng.below(16)).min(out.len());
                out.drain(at..end);
            }
            3 if at < out.len() => {
                let end = (at + 1 + rng.below(32)).min(out.len());
                let copy = out[at..end].to_vec();
                out.splice(at..at, copy);
            }
            4 => out.truncate(at),
            _ => out.insert(at.min(out.len()), rng.next() as u8),
        }
    }
    out
}

const XHTML: &str = concat!(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n",
    "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0//EN\" \"x.dtd\" [<!ENTITY é \"e\">]>\n",
    "<?xml-stylesheet href=\"é.css\"?>",
    "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"te\"><!-- తెలుగు -- note -->",
    "<body class='a&amp;b' title=\"tab\there\nline\"><p>caf&eacute; &nbsp; R&amp;D &#x1F600; &#233; Tom & Jerry</p>",
    "<![CDATA[ <raw> é ]]><br/><?php echo \"日本\"; ?></body></html>\r\n<!-- after -->",
);

const FLAT: &str = concat!(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<office:document xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" ",
    "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:x=\"urn:custom\" ",
    "office:version=\"1.3\" office:mimetype=\"application/vnd.oasis.opendocument.text\">",
    "<office:body><office:text><text:p text:style-name=\"P1\">Ünïcödé <text:span>span</text:span><text:s text:c=\"3\"/>",
    "<x:y xmlns:x=\"urn:inner\" x:z=\"1\"/><q:undeclared/></text:p></office:text></office:body></office:document>",
);

const SHEET: &str = concat!(
    "\u{FEFF}<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" ",
    "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\r\n",
    "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r='B1'><f>SUM(A1:A3)&lt;&gt;</f></c></row></sheetData>",
    "<inner xmlns=\"\"><plain/></inner></worksheet>",
);

#[test]
fn mutated_xml_never_panics() {
    // Before, 274 of these 60,000 files panicked the reader (1,821 of the
    // survey's 60,000).
    hostile(512 * KIB, Duration::from_secs(300), || {
        let samples = [DOCX_BODY, XHTML, FLAT, SHEET];
        let mut rng = XorShift(0x9E37_79B9_7F4A_7C15);
        for _ in 0..60_000 {
            let sample = samples[rng.below(samples.len())];
            let bytes = mutate(sample.as_bytes(), &mut rng);
            let (text, _) = decode_bytes(&bytes);
            let mut reader = Reader::new(&text);
            for _ in 0..=text.len() + 1 {
                match reader.next() {
                    Ok(Event::Eof) | Err(_) => break,
                    Ok(Event::Start(tag)) => tag.attrs().for_each(drop),
                    Ok(_) => {}
                }
            }
            if let Ok(doc) = Document::parse(&bytes) {
                let _ = doc.root.text();
                // What is written reads back, and is then written the same
                // way again: saving twice changes nothing more.
                let written = doc.to_xml();
                let again = Document::parse_str(&written).expect("a written document reads back");
                assert_eq!(again.to_xml(), written, "a second save changes nothing");
            }
        }
    });
}
