//! Engine tests on a deck made here.

use crate::scene::Kind;
use crate::{open, Edit, TextPatch};

/// A small deck: a title slide and a slide with a rectangle.
fn deck_bytes() -> Vec<u8> {
    use doc_zip::{Compression, ZipWriter};
    let ns = r#"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#;
    let types = r#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/></Types>"#;
    let root_rels = r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#;
    let pres = format!(r#"<?xml version="1.0" encoding="UTF-8"?><p:presentation {ns}><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#);
    let pres_rels = r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>"#;
    let master = format!(r#"<?xml version="1.0" encoding="UTF-8"?><p:sldMaster {ns}><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="457200" y="274638"/><a:ext cx="8229600" cy="1143000"/></a:xfrm></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p/></p:txBody></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:buChar char="&#8226;"/><a:defRPr sz="3200"/></a:lvl1pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>"#);
    let master_rels = r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>"#;
    let layout = format!(r#"<?xml version="1.0" encoding="UTF-8"?><p:sldLayout {ns}><p:cSld name="Title Only"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp></p:spTree></p:cSld></p:sldLayout>"#);
    let layout_rels = r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>"#;
    let slide = format!(r#"<?xml version="1.0" encoding="UTF-8"?><p:sld {ns}><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr b="1"/><a:t>Hello</a:t></a:r><a:r><a:t> deck</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="1270000" y="2540000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm><a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="2E75B6"/></a:solidFill></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:r><a:t>Box</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#);
    let slide_rels = r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>"#;
    let mut z = ZipWriter::new();
    for (n, d) in [
        ("[Content_Types].xml", types.to_owned()),
        ("_rels/.rels", root_rels.to_owned()),
        ("ppt/presentation.xml", pres),
        ("ppt/_rels/presentation.xml.rels", pres_rels.to_owned()),
        ("ppt/slideMasters/slideMaster1.xml", master),
        ("ppt/slideMasters/_rels/slideMaster1.xml.rels", master_rels.to_owned()),
        ("ppt/slideLayouts/slideLayout1.xml", layout),
        ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", layout_rels.to_owned()),
        ("ppt/slides/slide1.xml", slide),
        ("ppt/slides/_rels/slide1.xml.rels", slide_rels.to_owned()),
    ] {
        z.add(n, d.as_bytes(), Compression::DEFAULT).unwrap();
    }
    z.finish()
}

#[test]
fn scene_resolves_placeholders_and_styles() {
    let mut d = open(deck_bytes(), "a.pptx").unwrap();
    assert_eq!(d.slide_count(), 1);
    let s = d.scene(0).unwrap();
    assert_eq!((s.width, s.height), (720.0, 540.0));
    let title = s.items.iter().find(|i| i.id == 2).unwrap();
    // The position comes from the master; the size and centring from the
    // title style.
    assert!((title.x - 36.0).abs() < 0.1 && (title.w - 648.0).abs() < 0.1);
    let t = title.text.as_ref().unwrap();
    assert_eq!(t.anchor, "ctr");
    assert_eq!(t.paras[0].align, "ctr");
    assert_eq!(t.paras[0].runs[0].size, 44.0);
    assert!(t.paras[0].runs[0].bold && !t.paras[0].runs[1].bold);
    let bx = s.items.iter().find(|i| i.id == 3).unwrap();
    assert_eq!(bx.kind, Kind::Shape);
    assert_eq!((bx.x, bx.y, bx.w, bx.h), (100.0, 200.0, 200.0, 100.0));
    assert_eq!(bx.fill, crate::scene::Fill::Solid(0xFF2E75B6));
}

#[test]
fn edits_save_and_undo() {
    let mut d = open(deck_bytes(), "a.pptx").unwrap();
    d.apply(&Edit::SetText {
        slide: 0,
        shape: 2,
        cell: None,
        paras: vec!["Hello there deck".into()],
    })
    .unwrap();
    d.apply(&Edit::FormatText {
        slide: 0,
        shape: 3,
        cell: None,
        patch: TextPatch {
            italic: Some(true),
            color: Some(0xFF0000),
            ..TextPatch::default()
        },
    })
    .unwrap();
    let r = d.apply(&Edit::AddSlide { after: Some(0), layout: None }).unwrap();
    assert_eq!(r.slide, Some(1));
    let tb = d
        .apply(&Edit::AddTextBox {
            slide: 1,
            x: 50.0,
            y: 50.0,
            w: 300.0,
            h: 40.0,
            text: "New slide text".into(),
        })
        .unwrap();
    d.apply(&Edit::DuplicateSlide { slide: 0 }).unwrap();
    d.apply(&Edit::MoveSlide { from: 2, to: 0 }).unwrap();
    assert_eq!(d.slide_count(), 3);
    let bytes = d.save().unwrap();

    let mut again = open(bytes, "a.pptx").unwrap();
    assert_eq!(again.slide_count(), 3);
    // Order now: the new slide, the original, its copy.
    let s0 = again.scene(0).unwrap();
    let new_box = s0.items.iter().find(|i| Some(i.id) == tb.shape).unwrap();
    assert_eq!(new_box.text.as_ref().unwrap().text(), "New slide text");
    for i in [1, 2] {
        let s = again.scene(i).unwrap();
        let t = s.items.iter().find(|i| i.id == 2).unwrap().text.as_ref().unwrap();
        assert_eq!(t.text(), "Hello there deck");
        assert!(t.paras[0].runs[0].bold, "the first word kept its bold");
        let bx = s.items.iter().find(|i| i.id == 3).unwrap().text.as_ref().unwrap();
        assert!(bx.paras[0].runs[0].italic);
        assert_eq!(bx.paras[0].runs[0].color, 0xFFFF0000);
    }

    // Undo everything: the original text again.
    while d.undo() {}
    assert_eq!(d.slide_count(), 1);
    let s = d.scene(0).unwrap();
    assert_eq!(s.items.iter().find(|i| i.id == 2).unwrap().text.as_ref().unwrap().text(), "Hello deck");
}
