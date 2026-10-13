//! Engine tests on generated documents.

use crate::view::{BlockView, Inline, InlineEdit, ParaPatch};
use crate::{blank, open, Edit, NewPara};

#[test]
fn blank_document_round_trips() {
    let mut d = blank();
    assert_eq!(d.block_count(), 1);
    let blocks = d.blocks(0, 10);
    let BlockView::Para(p) = &blocks[0] else {
        panic!()
    };
    assert!(p.inlines.is_empty());
    let style = p.style.mark.clone();
    d.apply(Edit::SetParas {
        first: p.id,
        last: p.id,
        paras: vec![NewPara {
            inlines: vec![InlineEdit::Text {
                text: "Hello world".into(),
                style,
                link: None,
            }],
            style: None,
        }],
    })
    .unwrap();
    let (bytes, _) = d.save().unwrap();
    let mut again = open(bytes, "x.docx").unwrap();
    let blocks = again.blocks(0, 10);
    let BlockView::Para(p) = &blocks[0] else {
        panic!()
    };
    assert_eq!(p.text(), "Hello world");
    let Inline::Text { style, .. } = &p.inlines[0] else {
        panic!()
    };
    assert_eq!(style.size, 11.0);
    assert_eq!(style.font, "Calibri");
    let _ = ParaPatch::default();
}

fn paras(d: &mut crate::Document) -> Vec<crate::view::ParaView> {
    let n = d.block_count();
    d.blocks(0, n)
        .into_iter()
        .filter_map(|b| match b {
            BlockView::Para(p) => Some(p),
            _ => None,
        })
        .collect()
}

fn same(p: &crate::view::ParaView) -> Vec<InlineEdit> {
    p.inlines
        .iter()
        .map(|i| match i {
            Inline::Text { text, style, link } => InlineEdit::Text {
                text: text.clone(),
                style: style.clone(),
                link: link.clone(),
            },
            Inline::Object(o) => InlineEdit::Object(o.id),
        })
        .collect()
}

#[test]
fn odt_text_edits_keep_spans_and_spaces() {
    let body = r#"<text:p>Plain <text:span text:style-name="B">bold</text:span>  and<text:s text:c="2"/>spaced<text:bookmark text:name="here"/> end</text:p><text:p>Second</text:p>"#;
    let mut bytes = crate::odt::bytes_with_body(body);
    // A bold text style for the span.
    let mut d = open(bytes.clone(), "a.odt").unwrap();
    let p = &paras(&mut d)[0];
    assert_eq!(p.text(), "Plain bold and  spaced end");
    // Bold through a new automatic style.
    let mut edits = same(p);
    if let InlineEdit::Text { text, .. } = &mut edits[0] {
        *text = text.replacen("Plain ", "Plain! ", 1);
    }
    let mut bold = p.style.mark.clone();
    bold.bold = true;
    edits.push(InlineEdit::Text {
        text: " BOLD".into(),
        style: bold,
        link: None,
    });
    d.apply(Edit::SetParas {
        first: p.id,
        last: p.id,
        paras: vec![NewPara { inlines: edits, style: None }],
    })
    .unwrap();
    bytes = d.save().unwrap().0;
    let mut again = open(bytes.clone(), "a.odt").unwrap();
    let p = &paras(&mut again)[0];
    assert_eq!(p.text(), "Plain! bold and  spaced end BOLD");
    let last = p.inlines.last().unwrap();
    let Inline::Text { style, .. } = last else { panic!() };
    assert!(style.bold);
    let pkg = doc_opc::Package::open(bytes).unwrap();
    let xml = pkg.read_text("content.xml").unwrap();
    assert!(xml.contains(r#"spaced<text:bookmark text:name="here"/> end"#), "{xml}");
    assert!(xml.contains(r#"fo:font-weight="bold""#), "{xml}");
}

#[test]
fn odt_lists_are_containers() {
    let body = "<text:p>One</text:p><text:p>Two</text:p><text:p>Three</text:p>";
    let mut d = open(crate::odt::bytes_with_body(body), "a.odt").unwrap();
    let ps = paras(&mut d);
    let ids: Vec<u32> = ps.iter().map(|p| p.id).collect();
    d.apply(Edit::Patch {
        ids: ids.clone(),
        patch: ParaPatch {
            list: Some("number".into()),
            ..ParaPatch::default()
        },
    })
    .unwrap();
    let labels: Vec<String> = paras(&mut d).iter().map(|p| p.list.as_ref().unwrap().text.clone()).collect();
    assert_eq!(labels, ["1.", "2.", "3."]);
    // Take the middle one out: the list continues after it.
    d.apply(Edit::Patch {
        ids: vec![ids[1]],
        patch: ParaPatch {
            list: Some("none".into()),
            ..ParaPatch::default()
        },
    })
    .unwrap();
    let ps = paras(&mut d);
    assert!(ps[1].list.is_none());
    assert_eq!(ps[2].list.as_ref().unwrap().text, "2.");
    let bytes = d.save().unwrap().0;
    let xml = doc_opc::Package::open(bytes).unwrap().read_text("content.xml").unwrap();
    assert!(xml.contains(r#"text:continue-numbering="true""#), "{xml}");
    assert_eq!(xml.matches("<text:list ").count(), 2, "{xml}");
    // Undo puts the single list back.
    d.undo().unwrap();
    let labels: Vec<Option<String>> = paras(&mut d).iter().map(|p| p.list.as_ref().map(|l| l.text.clone())).collect();
    assert_eq!(labels, [Some("1.".into()), Some("2.".into()), Some("3.".into())]);
}

#[test]
fn odt_heading_style_makes_a_heading() {
    let mut d = open(crate::odt::bytes_with_body("<text:p>Title here</text:p>"), "a.odt").unwrap();
    let id = paras(&mut d)[0].id;
    d.apply(Edit::Patch {
        ids: vec![id],
        patch: ParaPatch {
            style_id: Some("Heading1".into()),
            ..ParaPatch::default()
        },
    })
    .unwrap();
    let p = &paras(&mut d)[0];
    assert_eq!(p.style.outline_level, Some(0));
    assert!(p.inlines.iter().all(|i| matches!(i, Inline::Text { style, .. } if style.bold)));
    let bytes = d.save().unwrap().0;
    let pkg = doc_opc::Package::open(bytes).unwrap();
    assert!(pkg.read_text("content.xml").unwrap().contains(r#"<text:h text:style-name="Heading_20_1" text:outline-level="1">Title here</text:h>"#));
    assert!(pkg.read_text("styles.xml").unwrap().contains(r#"style:name="Heading_20_1""#));
}
