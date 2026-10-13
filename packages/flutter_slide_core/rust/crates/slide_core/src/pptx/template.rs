//! A new, blank 16:9 deck: an Office-style theme, one master with six
//! layouts, a notes master, and a title slide.

use doc_zip::{Compression, ZipWriter};

const NS: &str = r#"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#;
const DECL: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#;
const REL: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

const THEME: &str = r#"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:lumMod val="110000"/><a:satMod val="105000"/><a:tint val="67000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="105000"/><a:satMod val="109000"/><a:tint val="81000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:satMod val="103000"/><a:lumMod val="102000"/><a:tint val="94000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="99000"/><a:satMod val="120000"/><a:shade val="78000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:shade val="98000"/></a:schemeClr></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"#;

const CLR_MAP: &str = r#"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#;

fn tree(shapes: &str) -> String {
    format!(
        r#"<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>{shapes}</p:spTree>"#
    )
}

/// A placeholder; `xfrm` and `body` may be empty to inherit.
fn ph(id: u32, name: &str, ph: &str, xfrm: Option<(i64, i64, i64, i64)>, body_pr: &str, lst: &str, text: &str) -> String {
    let xf = xfrm.map_or(String::new(), |(x, y, w, h)| format!(r#"<a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>"#));
    let geom = if xfrm.is_some() { r#"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>"# } else { "" };
    let para = if text.is_empty() {
        r#"<a:p><a:endParaRPr lang="en-US"/></a:p>"#.to_owned()
    } else {
        format!(r#"<a:p><a:r><a:rPr lang="en-US"/><a:t>{text}</a:t></a:r></a:p>"#)
    };
    format!(
        r#"<p:sp><p:nvSpPr><p:cNvPr id="{id}" name="{name}"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph {ph}/></p:nvPr></p:nvSpPr><p:spPr>{xf}{geom}</p:spPr><p:txBody><a:bodyPr{body_pr}/><a:lstStyle>{lst}</a:lstStyle>{para}</p:txBody></p:sp>"#
    )
}

fn footers(first_id: u32) -> String {
    let small = r#"<a:lvl1pPr algn="l"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"><a:tint val="75000"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr>"#;
    [
        ph(first_id, "Date Placeholder", r#"type="dt" sz="half" idx="10""#, None, "", "", ""),
        ph(first_id + 1, "Footer Placeholder", r#"type="ftr" sz="quarter" idx="11""#, None, "", "", ""),
        ph(first_id + 2, "Slide Number Placeholder", r#"type="sldNum" sz="quarter" idx="12""#, None, "", small, ""),
    ]
    .concat()
}

const MASTER_TX: &str = r#"<p:txStyles><p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/><a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="228600" indent="-228600" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPts val="1000"/></a:spcBef><a:buFont typeface="Arial" panose="020B0604020202020204" pitchFamily="34" charset="0"/><a:buChar char="&#8226;"/><a:defRPr sz="2800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr><a:lvl2pPr marL="685800" indent="-228600" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPts val="500"/></a:spcBef><a:buFont typeface="Arial" panose="020B0604020202020204" pitchFamily="34" charset="0"/><a:buChar char="&#8226;"/><a:defRPr sz="2400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl2pPr><a:lvl3pPr marL="1143000" indent="-228600" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPts val="500"/></a:spcBef><a:buFont typeface="Arial" panose="020B0604020202020204" pitchFamily="34" charset="0"/><a:buChar char="&#8226;"/><a:defRPr sz="2000" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl3pPr></p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles>"#;

fn master() -> String {
    let shapes = [
        ph(2, "Title Placeholder 1", r#"type="title""#, Some((838200, 365125, 10515600, 1325563)), r#" vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr""#, "", "Click to edit Master title style"),
        ph(3, "Text Placeholder 2", r#"type="body" idx="1""#, Some((838200, 1825625, 10515600, 4351338)), r#" vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0""#, "", "Click to edit Master text styles"),
        ph(4, "Date Placeholder 3", r#"type="dt" sz="half" idx="2""#, Some((838200, 6356350, 2743200, 365125)), r#" anchor="ctr""#, r#"<a:lvl1pPr algn="l"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"><a:tint val="75000"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr>"#, ""),
        ph(5, "Footer Placeholder 4", r#"type="ftr" sz="quarter" idx="3""#, Some((4038600, 6356350, 4114800, 365125)), r#" anchor="ctr""#, r#"<a:lvl1pPr algn="ctr"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"><a:tint val="75000"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr>"#, ""),
        ph(6, "Slide Number Placeholder 5", r#"type="sldNum" sz="quarter" idx="4""#, Some((8610600, 6356350, 2743200, 365125)), r#" anchor="ctr""#, r#"<a:lvl1pPr algn="r"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"><a:tint val="75000"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr>"#, ""),
    ]
    .concat();
    let ids: String = (0..LAYOUTS.len()).map(|i| format!(r#"<p:sldLayoutId id="{}" r:id="rId{}"/>"#, 2147483649u64 + i as u64, i + 1)).collect();
    format!(
        r#"{DECL}<p:sldMaster {NS}><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>{}</p:cSld>{CLR_MAP}<p:sldLayoutIdLst>{ids}</p:sldLayoutIdLst>{MASTER_TX}</p:sldMaster>"#,
        tree(&shapes)
    )
}

/// Layouts: (name, type, shapes).
const LAYOUTS: &[(&str, &str)] = &[
    ("Title Slide", "title"),
    ("Title and Content", "obj"),
    ("Section Header", "secHead"),
    ("Two Content", "twoObj"),
    ("Title Only", "titleOnly"),
    ("Blank", "blank"),
];

fn layout(i: usize) -> String {
    let (name, ty) = LAYOUTS[i];
    let shapes = match ty {
        "title" => [
            ph(2, "Title 1", r#"type="ctrTitle""#, Some((1524000, 1122363, 9144000, 2387600)), r#" anchor="b""#, r#"<a:lvl1pPr algn="ctr"><a:defRPr sz="6000"/></a:lvl1pPr>"#, "Click to edit Master title style"),
            ph(3, "Subtitle 2", r#"type="subTitle" idx="1""#, Some((1524000, 3602038, 9144000, 1655762)), "", r#"<a:lvl1pPr marL="0" indent="0" algn="ctr"><a:buNone/><a:defRPr sz="2400"/></a:lvl1pPr>"#, "Click to edit Master subtitle style"),
            footers(4),
        ]
        .concat(),
        "obj" => [
            ph(2, "Title 1", r#"type="title""#, None, "", "", "Click to edit Master title style"),
            ph(3, "Content Placeholder 2", r#"idx="1""#, None, "", "", "Click to edit Master text styles"),
            footers(4),
        ]
        .concat(),
        "secHead" => [
            ph(2, "Title 1", r#"type="title""#, Some((831850, 1709738, 10515600, 2852737)), r#" anchor="b""#, r#"<a:lvl1pPr><a:defRPr sz="6000"/></a:lvl1pPr>"#, "Click to edit Master title style"),
            ph(3, "Text Placeholder 2", r#"type="body" idx="1""#, Some((831850, 4589463, 10515600, 1500187)), "", r#"<a:lvl1pPr marL="0" indent="0"><a:buNone/><a:defRPr sz="2400"><a:solidFill><a:schemeClr val="tx1"><a:tint val="75000"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr>"#, "Click to edit Master text styles"),
            footers(4),
        ]
        .concat(),
        "twoObj" => [
            ph(2, "Title 1", r#"type="title""#, None, "", "", "Click to edit Master title style"),
            ph(3, "Content Placeholder 2", r#"sz="half" idx="1""#, Some((838200, 1825625, 5181600, 4351338)), "", "", "Click to edit Master text styles"),
            ph(4, "Content Placeholder 3", r#"sz="half" idx="2""#, Some((6172200, 1825625, 5181600, 4351338)), "", "", "Click to edit Master text styles"),
            footers(5),
        ]
        .concat(),
        "titleOnly" => [ph(2, "Title 1", r#"type="title""#, None, "", "", "Click to edit Master title style"), footers(3)].concat(),
        _ => footers(2),
    };
    format!(r#"{DECL}<p:sldLayout {NS} type="{ty}" preserve="1"><p:cSld name="{name}">{}</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#, tree(&shapes))
}

fn rels(list: &[(&str, &str)]) -> String {
    let body: String = list
        .iter()
        .enumerate()
        .map(|(i, (kind, target))| format!(r#"<Relationship Id="rId{}" Type="{REL}/{kind}" Target="{target}"/>"#, i + 1))
        .collect();
    format!(r#"{DECL}<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{body}</Relationships>"#)
}

/// The bytes of a new deck.
pub fn bytes() -> Vec<u8> {
    let mut types = String::from(r#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/><Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/><Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#);
    for i in 0..LAYOUTS.len() {
        types.push_str(&format!(
            r#"<Override PartName="/ppt/slideLayouts/slideLayout{}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>"#,
            i + 1
        ));
    }
    types.push_str("</Types>");

    let pres = format!(
        r#"{DECL}<p:presentation {NS} saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId3"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:defaultTextStyle></p:presentation>"#
    );
    let pres_rels = rels(&[
        ("slideMaster", "slideMasters/slideMaster1.xml"),
        ("notesMaster", "notesMasters/notesMaster1.xml"),
        ("slide", "slides/slide1.xml"),
        ("theme", "theme/theme1.xml"),
        ("presProps", "presProps.xml"),
        ("viewProps", "viewProps.xml"),
        ("tableStyles", "tableStyles.xml"),
    ]);
    let layout_targets: Vec<String> = (1..=LAYOUTS.len()).map(|i| format!("../slideLayouts/slideLayout{i}.xml")).collect();
    let mut master_rel_list: Vec<(&str, &str)> = layout_targets.iter().map(|t| ("slideLayout", t.as_str())).collect();
    master_rel_list.push(("theme", "../theme/theme1.xml"));
    let notes_master = format!(
        r#"{DECL}<p:notesMaster {NS}><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>{}</p:cSld>{CLR_MAP}</p:notesMaster>"#,
        tree(&[
            r#"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="3086100"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="12700"><a:solidFill><a:prstClr val="black"/></a:solidFill></a:ln></p:spPr></p:sp>"#,
            &ph(3, "Notes Placeholder 2", r#"type="body" sz="quarter" idx="3""#, Some((685800, 4400550, 5486400, 3600450)), "", "", "Click to edit Master text styles"),
        ]
        .concat())
    );
    let slide = format!(
        r#"{DECL}<p:sld {NS}><p:cSld>{}</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#,
        tree(&[
            r#"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>"#,
            r#"<p:sp><p:nvSpPr><p:cNvPr id="3" name="Subtitle 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="subTitle" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>"#,
        ]
        .concat())
    );
    let mut files: Vec<(String, String)> = vec![
        ("[Content_Types].xml".into(), format!("{DECL}{types}")),
        ("_rels/.rels".into(), rels(&[("officeDocument", "ppt/presentation.xml")]).replace(
            "</Relationships>",
            r#"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>"#,
        )),
        ("docProps/app.xml".into(), format!(r#"{DECL}<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>DocHelper</Application></Properties>"#)),
        ("ppt/presentation.xml".into(), pres),
        ("ppt/_rels/presentation.xml.rels".into(), pres_rels),
        ("ppt/slideMasters/slideMaster1.xml".into(), master()),
        ("ppt/slideMasters/_rels/slideMaster1.xml.rels".into(), rels(&master_rel_list)),
        ("ppt/notesMasters/notesMaster1.xml".into(), notes_master),
        ("ppt/notesMasters/_rels/notesMaster1.xml.rels".into(), rels(&[("theme", "../theme/theme2.xml")])),
        ("ppt/theme/theme1.xml".into(), format!("{DECL}{THEME}")),
        ("ppt/theme/theme2.xml".into(), format!("{DECL}{THEME}")),
        ("ppt/presProps.xml".into(), format!(r#"{DECL}<p:presentationPr {NS}/>"#)),
        ("ppt/viewProps.xml".into(), format!(r#"{DECL}<p:viewPr {NS}><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr><p:gridSpacing cx="76200" cy="76200"/></p:viewPr>"#)),
        ("ppt/tableStyles.xml".into(), format!(r#"{DECL}<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}}"/>"#)),
        ("ppt/slides/slide1.xml".into(), slide),
        ("ppt/slides/_rels/slide1.xml.rels".into(), rels(&[("slideLayout", "../slideLayouts/slideLayout1.xml")])),
    ];
    for i in 0..LAYOUTS.len() {
        files.push((format!("ppt/slideLayouts/slideLayout{}.xml", i + 1), layout(i)));
        files.push((format!("ppt/slideLayouts/_rels/slideLayout{}.xml.rels", i + 1), rels(&[("slideMaster", "../slideMasters/slideMaster1.xml")])));
    }
    let mut z = ZipWriter::new();
    for (name, data) in files {
        z.add(&name, data.as_bytes(), Compression::DEFAULT).expect("names are unique");
    }
    z.finish()
}
