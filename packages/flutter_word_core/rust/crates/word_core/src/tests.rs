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
