//! Edits to a PowerPoint deck. Each one changes the parsed parts it
//! touches (copied on write, so undo keeps the old ones) and records what
//! saving must write.

use std::sync::Arc;

use doc_opc::{rel, Rels};
use doc_xml::{ns, Document, Element, Node};

use super::{child, ph_of, shape_id, sp_tree, Pptx, SlideRef, EMU_PER_PT};
use crate::deck::{Edit, EditResult, TextPatch};
use crate::error::SlideError;
use crate::text;

const NS_DECLS: &str = r#"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#;
const NOTES_TYPE: &str = "application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml";

/// Parse a fragment written with the `p:`, `a:` and `r:` prefixes.
fn fragment(xml: &str) -> Element {
    let doc = Document::parse_str(&format!("<x {NS_DECLS}>{xml}</x>")).expect("built-in XML parses");
    let e = doc.root.elements().next().expect("a fragment has an element").clone();
    e
}

fn esc(s: &str) -> String {
    let mut out = String::new();
    doc_xml::escape_text(s, &mut out);
    out
}

fn esc_attr(s: &str) -> String {
    let mut out = String::new();
    doc_xml::escape_attr(s, &mut out);
    out
}

fn emu(pt: f32) -> i64 {
    (pt * EMU_PER_PT).round() as i64
}

/// Child indexes from the shape tree down to the shape with this id.
fn find_shape(tree: &Element, id: u32) -> Option<Vec<usize>> {
    for (i, n) in tree.children.iter().enumerate() {
        let Some(e) = n.as_element() else { continue };
        if matches!(e.local(), "sp" | "pic" | "graphicFrame" | "grpSp" | "cxnSp") && shape_id(e) == Some(id) {
            return Some(vec![i]);
        }
        if matches!(e.local(), "grpSp" | "AlternateContent" | "Choice" | "Fallback") {
            if let Some(mut sub) = find_shape(e, id) {
                sub.insert(0, i);
                return Some(sub);
            }
        }
    }
    None
}

fn at_path<'a>(e: &'a mut Element, path: &[usize]) -> Option<&'a mut Element> {
    let mut cur = e;
    for &i in path {
        cur = cur.children.get_mut(i)?.as_element_mut()?;
    }
    Some(cur)
}

fn tree_mut(doc: &mut Document) -> Option<&mut Element> {
    let c = doc.root.elements_mut().find(|e| e.local() == "cSld")?;
    c.elements_mut().find(|e| e.local() == "spTree")
}

fn max_id(tree: &Element) -> u32 {
    tree.descendants()
        .filter(|e| e.local() == "cNvPr")
        .filter_map(|e| e.attr(ns::NONE, "id")?.parse::<u32>().ok())
        .max()
        .unwrap_or(1)
}

/// The run properties elements of a text body, made where missing.
fn each_rpr(body: &mut Element, f: &mut dyn FnMut(&mut Element)) {
    for p in body.elements_mut().filter(|e| e.local() == "p") {
        for r in p.elements_mut().filter(|e| matches!(e.local(), "r" | "br" | "fld")) {
            if !r.elements().any(|c| c.local() == "rPr") {
                r.children.insert(0, Node::Element(Element::new("a:rPr", ns::A)));
            }
            if let Some(rpr) = r.elements_mut().find(|c| c.local() == "rPr") {
                f(rpr);
            }
        }
        if !p.elements().any(|c| c.local() == "endParaRPr") {
            p.push(Element::new("a:endParaRPr", ns::A));
        }
        if let Some(end) = p.elements_mut().find(|c| c.local() == "endParaRPr") {
            f(end);
        }
    }
}

fn set_fill(rpr: &mut Element, color: u32) {
    rpr.children.retain(|n| !n.as_element().is_some_and(|e| matches!(e.local(), "noFill" | "solidFill" | "gradFill" | "blipFill" | "pattFill" | "grpFill")));
    let mut fill = Element::new("a:solidFill", ns::A);
    fill.push(Element::new("a:srgbClr", ns::A).with_attr("val", ns::NONE, format!("{:06X}", color & 0xFF_FFFF)));
    // The fill comes after an outline and before everything else.
    let at = rpr.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() != "ln")).unwrap_or(rpr.children.len());
    rpr.children.insert(at, Node::Element(fill));
}

fn apply_patch(body: &mut Element, patch: &TextPatch) {
    each_rpr(body, &mut |rpr| {
        if let Some(b) = patch.bold {
            rpr.set_attr("b", ns::NONE, if b { "1" } else { "0" });
        }
        if let Some(i) = patch.italic {
            rpr.set_attr("i", ns::NONE, if i { "1" } else { "0" });
        }
        if let Some(u) = patch.underline {
            rpr.set_attr("u", ns::NONE, if u { "sng" } else { "none" });
        }
        if let Some(s) = patch.size {
            rpr.set_attr("sz", ns::NONE, ((s * 100.0).round() as i64).to_string());
        }
        if let Some(c) = patch.color {
            set_fill(rpr, c);
        }
    });
    if let Some(a) = &patch.align {
        for p in body.elements_mut().filter(|e| e.local() == "p") {
            if !p.elements().any(|c| c.local() == "pPr") {
                p.children.insert(0, Node::Element(Element::new("a:pPr", ns::A)));
            }
            if let Some(ppr) = p.elements_mut().find(|c| c.local() == "pPr") {
                ppr.set_attr("algn", ns::NONE, a.clone());
            }
        }
    }
}

/// The text body of a shape (or of a table cell), made when missing.
fn body_of<'a>(shape: &'a mut Element, cell: Option<(usize, usize)>) -> Option<&'a mut Element> {
    if let Some((r, c)) = cell {
        let tbl = shape
            .elements_mut()
            .find(|e| e.local() == "graphic")?
            .elements_mut()
            .find(|e| e.local() == "graphicData")?
            .elements_mut()
            .find(|e| e.local() == "tbl")?;
        let tr = tbl.elements_mut().filter(|e| e.local() == "tr").nth(r)?;
        let tc = tr.elements_mut().filter(|e| e.local() == "tc").nth(c)?;
        if !tc.elements().any(|e| e.local() == "txBody") {
            tc.children.insert(0, Node::Element(fragment("<a:txBody><a:bodyPr/><a:lstStyle/><a:p/></a:txBody>")));
        }
        return tc.elements_mut().find(|e| e.local() == "txBody");
    }
    if shape.local() != "sp" {
        return None;
    }
    if !shape.elements().any(|e| e.local() == "txBody") {
        // After nvSpPr, spPr and style.
        let at = shape
            .children
            .iter()
            .position(|n| n.as_element().is_some_and(|e| e.local() == "extLst"))
            .unwrap_or(shape.children.len());
        shape.children.insert(
            at,
            Node::Element(fragment(r#"<p:txBody><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/></a:p></p:txBody>"#)),
        );
    }
    shape.elements_mut().find(|e| e.local() == "txBody")
}

impl Pptx {
    /// Change slide `i`'s document.
    fn slide_mut(&mut self, i: usize) -> Result<(String, &mut Document), SlideError> {
        let part = self.slide_part(i)?;
        self.doc(&part)?;
        self.state.dirty.insert(part.clone());
        let d = self.state.docs.get_mut(&part).unwrap();
        Ok((part, Arc::make_mut(d)))
    }

    fn rels_mut(&mut self, part: &str) -> Result<&mut Rels, SlideError> {
        self.rels(part)?;
        self.state.dirty_rels.insert(part.to_owned());
        Ok(Arc::make_mut(self.state.rels.get_mut(part).unwrap()))
    }

    fn with_shape<R>(&mut self, slide: usize, id: u32, f: impl FnOnce(&mut Element) -> Result<R, SlideError>) -> Result<R, SlideError> {
        let (_, doc) = self.slide_mut(slide)?;
        let tree = tree_mut(doc).ok_or_else(|| SlideError::Corrupt("This slide has no shapes.".into()))?;
        let path = find_shape(tree, id).ok_or_else(|| SlideError::Invalid("That shape is gone.".into()))?;
        let shape = at_path(tree, &path).unwrap();
        f(shape)
    }

    fn unused_part(&self, pattern: &str) -> String {
        (1..)
            .map(|i| pattern.replace("{}", &i.to_string()))
            .find(|n| (!self.pkg.exists(n) || self.state.removed.contains(n)) && !self.state.new_parts.contains_key(n) && !self.state.media.contains_key(n))
            .unwrap()
    }

    fn add_shape_xml(&mut self, slide: usize, make: impl FnOnce(u32) -> String) -> Result<u32, SlideError> {
        let (_, doc) = self.slide_mut(slide)?;
        let tree = tree_mut(doc).ok_or_else(|| SlideError::Corrupt("This slide has no shapes.".into()))?;
        let id = max_id(tree) + 1;
        let el = fragment(&make(id));
        let at = tree.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() == "extLst")).unwrap_or(tree.children.len());
        tree.children.insert(at, Node::Element(el));
        Ok(id)
    }

    fn insert_slide(&mut self, at: usize, part: String, doc: Document, rels: Rels) {
        let mut pres_rels = Arc::make_mut(&mut self.state.pres_rels).clone();
        let rid = pres_rels.add(&rel::uri(rel::SLIDE), &part);
        self.state.pres_rels = Arc::new(pres_rels);
        let next_id = self.state.slides.iter().map(|s| s.sld_id).max().unwrap_or(255).max(255) + 1;
        let pres = Arc::make_mut(&mut self.state.pres);
        let has_list = pres.root.elements().any(|e| e.local() == "sldIdLst");
        let list = match has_list {
            true => pres.root.elements_mut().find(|e| e.local() == "sldIdLst").unwrap(),
            false => {
                // After the master list (and notes/handout master lists).
                let after = pres
                    .root
                    .children
                    .iter()
                    .rposition(|n| n.as_element().is_some_and(|e| matches!(e.local(), "sldMasterIdLst" | "notesMasterIdLst" | "handoutMasterIdLst")))
                    .map_or(0, |i| i + 1);
                pres.root.children.insert(after, Node::Element(Element::new("p:sldIdLst", ns::P)));
                pres.root.elements_mut().find(|e| e.local() == "sldIdLst").unwrap()
            }
        };
        let entry = Element::new("p:sldId", ns::P).with_attr("id", ns::NONE, next_id.to_string()).with_attr("r:id", ns::R, rid.clone());
        let pos = list.children.iter().enumerate().filter(|(_, n)| n.as_element().is_some()).nth(at).map_or(list.children.len(), |(i, _)| i);
        list.children.insert(pos, Node::Element(entry));
        self.state.pres_dirty = true;
        self.state.slides.insert(at, SlideRef { part: part.clone(), rel_id: rid, sld_id: next_id });
        self.state.docs.insert(part.clone(), Arc::new(doc));
        self.state.rels.insert(part.clone(), Arc::new(rels));
        self.state.dirty.insert(part.clone());
        self.state.dirty_rels.insert(part.clone());
        self.state.new_parts.insert(part.clone(), Pptx::slide_type().to_owned());
        self.state.removed.remove(&part);
    }

    pub fn apply(&mut self, edit: &Edit) -> Result<EditResult, SlideError> {
        match edit {
            Edit::SetText { slide, shape, cell, paras } => {
                self.with_shape(*slide, *shape, |sp| {
                    let body = body_of(sp, *cell).ok_or_else(|| SlideError::Invalid("That shape has no text.".into()))?;
                    text::set_text(body, paras, "a");
                    Ok(())
                })?;
                Ok(EditResult::at(*slide, *shape))
            }
            Edit::FormatText { slide, shape, cell, patch } => {
                self.with_shape(*slide, *shape, |sp| {
                    let body = body_of(sp, *cell).ok_or_else(|| SlideError::Invalid("That shape has no text.".into()))?;
                    apply_patch(body, patch);
                    Ok(())
                })?;
                Ok(EditResult::at(*slide, *shape))
            }
            Edit::AddTextBox { slide, x, y, w, h, text } => {
                let paras: String = text
                    .split('\n')
                    .map(|line| {
                        if line.is_empty() {
                            r#"<a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p>"#.to_owned()
                        } else {
                            format!(r#"<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{}</a:t></a:r></a:p>"#, esc(line))
                        }
                    })
                    .collect();
                let (x, y, w, h) = (emu(*x), emu(*y), emu(*w), emu(*h));
                let id = self.add_shape_xml(*slide, |id| {
                    format!(
                        r#"<p:sp><p:nvSpPr><p:cNvPr id="{id}" name="TextBox {id}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>{paras}</p:txBody></p:sp>"#
                    )
                })?;
                Ok(EditResult::at(*slide, id))
            }
            Edit::AddShape { slide, preset, x, y, w, h } => {
                let (x, y, w, h) = (emu(*x), emu(*y), emu(*w), emu(*h));
                let prst = esc_attr(preset);
                let id = self.add_shape_xml(*slide, |id| {
                    format!(
                        r#"<p:sp><p:nvSpPr><p:cNvPr id="{id}" name="Shape {id}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm><a:prstGeom prst="{prst}"><a:avLst/></a:prstGeom></p:spPr><p:style><a:lnRef idx="2"><a:schemeClr val="accent1"><a:shade val="50000"/></a:schemeClr></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></p:style><p:txBody><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:endParaRPr lang="en-US" dirty="0"/></a:p></p:txBody></p:sp>"#
                    )
                })?;
                Ok(EditResult::at(*slide, id))
            }
            Edit::AddImage { slide, bytes, ext, x, y, w, h } => {
                let ext = ext.trim_start_matches('.').to_ascii_lowercase();
                if !matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "bmp") {
                    return Err(SlideError::Unsupported("Pictures must be PNG, JPEG, GIF or BMP.".into()));
                }
                let part = self.unused_part(&format!("ppt/media/image{{}}.{ext}"));
                self.state.media.insert(part.clone(), Arc::new(bytes.clone()));
                let slide_part = self.slide_part(*slide)?;
                let rid = self.rels_mut(&slide_part)?.add(&rel::uri(rel::IMAGE), &part);
                let (x, y, w, h) = (emu(*x), emu(*y), emu(*w), emu(*h));
                let id = self.add_shape_xml(*slide, |id| {
                    format!(
                        r#"<p:pic><p:nvPicPr><p:cNvPr id="{id}" name="Picture {id}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                    )
                })?;
                Ok(EditResult::at(*slide, id))
            }
            Edit::DeleteShape { slide, shape } => {
                let (_, doc) = self.slide_mut(*slide)?;
                let tree = tree_mut(doc).ok_or_else(|| SlideError::Corrupt("This slide has no shapes.".into()))?;
                let path = find_shape(tree, *shape).ok_or_else(|| SlideError::Invalid("That shape is gone.".into()))?;
                let (last, parent) = path.split_last().unwrap();
                let holder = at_path(tree, parent).unwrap();
                holder.children.remove(*last);
                Ok(EditResult::slide(*slide))
            }
            Edit::MoveShape { slide, shape, x, y, w, h } => {
                let (x, y, w, h) = (emu(*x), emu(*y), emu(*w), emu(*h));
                self.with_shape(*slide, *shape, |sp| {
                    let holder: &mut Element = match sp.local() {
                        "graphicFrame" => sp,
                        "grpSp" => sp.elements_mut().find(|e| e.local() == "grpSpPr").ok_or_else(|| SlideError::Invalid("That group can't be moved.".into()))?,
                        _ => {
                            if !sp.elements().any(|e| e.local() == "spPr") {
                                let at = sp.children.iter().position(|n| n.as_element().is_some_and(|e| e.local().starts_with("nv"))).map_or(0, |i| i + 1);
                                sp.children.insert(at, Node::Element(Element::new("p:spPr", ns::P)));
                            }
                            sp.elements_mut().find(|e| e.local() == "spPr").unwrap()
                        }
                    };
                    let name = if holder.local() == "graphicFrame" { "p:xfrm" } else { "a:xfrm" };
                    if !holder.elements().any(|e| e.local() == "xfrm") {
                        // Right after the frame's non-visual properties, or
                        // first in the shape properties.
                        let at = if holder.local() == "graphicFrame" {
                            holder.children.iter().position(|n| n.as_element().is_some_and(|e| e.local() == "nvGraphicFramePr")).map_or(0, |i| i + 1)
                        } else {
                            0
                        };
                        let nsx = if name.starts_with("p:") { ns::P } else { ns::A };
                        holder.children.insert(at, Node::Element(Element::new(name, nsx)));
                    }
                    let xfrm = holder.elements_mut().find(|e| e.local() == "xfrm").unwrap();
                    let mut off = Element::new("a:off", ns::A);
                    off.set_attr("x", ns::NONE, x.to_string());
                    off.set_attr("y", ns::NONE, y.to_string());
                    let mut ext = Element::new("a:ext", ns::A);
                    ext.set_attr("cx", ns::NONE, w.to_string());
                    ext.set_attr("cy", ns::NONE, h.to_string());
                    let rest: Vec<Node> = xfrm.children.drain(..).filter(|n| !n.as_element().is_some_and(|e| matches!(e.local(), "off" | "ext"))).collect();
                    xfrm.children = vec![Node::Element(off), Node::Element(ext)];
                    xfrm.children.extend(rest);
                    Ok(())
                })?;
                Ok(EditResult::at(*slide, *shape))
            }
            Edit::AddSlide { after, layout } => {
                let at = after.map_or(self.state.slides.len(), |a| (a + 1).min(self.state.slides.len()));
                let layout_part = match layout {
                    Some(l) => l.clone(),
                    None => {
                        // The layout of the slide before, or the master's second.
                        match after.and_then(|a| self.slide_layout(a).ok()) {
                            Some(l) => l.part.clone(),
                            None => {
                                let list = self.layouts();
                                list.get(1).or(list.first()).map(|(p, _)| p.clone()).ok_or_else(|| SlideError::Corrupt("This presentation has no slide layouts.".into()))?
                            }
                        }
                    }
                };
                let lay = self.layout(&layout_part)?;
                let mut shapes = String::new();
                let mut id = 2;
                for ph in &lay.phs {
                    if matches!(ph.ty.as_str(), "dt" | "ftr" | "sldNum" | "hdr") {
                        continue;
                    }
                    let ty = if ph.ty == "body" && ph.idx.is_some() { String::new() } else { format!(r#" type="{}""#, ph.ty) };
                    let idx = ph.idx.map(|i| format!(r#" idx="{i}""#)).unwrap_or_default();
                    let name = super::shape_name(&ph.sp);
                    let body = if matches!(ph.ty.as_str(), "pic" | "chart" | "tbl" | "dgm" | "media" | "clipArt") {
                        String::new()
                    } else {
                        r#"<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p></p:txBody>"#.to_owned()
                    };
                    shapes.push_str(&format!(
                        r#"<p:sp><p:nvSpPr><p:cNvPr id="{id}" name="{}"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph{ty}{idx}/></p:nvPr></p:nvSpPr><p:spPr/>{body}</p:sp>"#,
                        esc_attr(&name)
                    ));
                    id += 1;
                }
                let xml = format!(
                    r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld {NS_DECLS}><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>{shapes}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#
                );
                let doc = Document::parse_str(&xml).expect("built-in XML parses");
                let part = self.unused_part("ppt/slides/slide{}.xml");
                let mut rels = Rels::empty(&part);
                rels.add(&rel::uri(rel::SLIDE_LAYOUT), &layout_part);
                self.insert_slide(at, part, doc, rels);
                Ok(EditResult::slide(at))
            }
            Edit::DuplicateSlide { slide } => {
                let src = self.slide_part(*slide)?;
                let doc = self.doc(&src)?.as_ref().clone();
                let mut rels = self.rels(&src)?.as_ref().clone();
                let part = self.unused_part("ppt/slides/slide{}.xml");
                // The copy shares pictures and the layout, but not notes.
                let notes: Vec<String> = rels.of_kind(rel::NOTES_SLIDE).into_iter().map(|r| r.id).collect();
                for id in notes {
                    rels.remove(&id);
                }
                rels.source = part.clone();
                self.insert_slide(slide + 1, part, doc, rels);
                Ok(EditResult::slide(slide + 1))
            }
            Edit::DeleteSlide { slide } => {
                if self.state.slides.len() <= 1 {
                    return Err(SlideError::Invalid("A presentation needs a slide.".into()));
                }
                let s = self.state.slides.get(*slide).cloned().ok_or_else(|| SlideError::Invalid("There is no such slide.".into()))?;
                let rels = self.rels(&s.part)?;
                if let Some(np) = rels.first_part(rel::NOTES_SLIDE) {
                    self.state.removed.insert(np.clone());
                    self.state.dirty.remove(&np);
                    self.state.dirty_rels.remove(&np);
                }
                self.state.slides.remove(*slide);
                let pres = Arc::make_mut(&mut self.state.pres);
                if let Some(list) = pres.root.elements_mut().find(|e| e.local() == "sldIdLst") {
                    list.children.retain(|n| !n.as_element().is_some_and(|e| e.attr(ns::R, "id") == Some(s.rel_id.as_str())));
                }
                Arc::make_mut(&mut self.state.pres_rels).remove(&s.rel_id);
                self.state.pres_dirty = true;
                self.state.removed.insert(s.part.clone());
                self.state.dirty.remove(&s.part);
                self.state.dirty_rels.remove(&s.part);
                Ok(EditResult::slide(slide.saturating_sub(1).min(self.state.slides.len() - 1)))
            }
            Edit::MoveSlide { from, to } => {
                let n = self.state.slides.len();
                if *from >= n || *to >= n {
                    return Err(SlideError::Invalid("There is no such slide.".into()));
                }
                let s = self.state.slides.remove(*from);
                self.state.slides.insert(*to, s);
                let order: Vec<String> = self.state.slides.iter().map(|s| s.rel_id.clone()).collect();
                let pres = Arc::make_mut(&mut self.state.pres);
                if let Some(list) = pres.root.elements_mut().find(|e| e.local() == "sldIdLst") {
                    let mut entries: Vec<Element> = list.elements().cloned().collect();
                    entries.sort_by_key(|e| order.iter().position(|r| Some(r.as_str()) == e.attr(ns::R, "id")).unwrap_or(usize::MAX));
                    list.children = entries.into_iter().map(Node::Element).collect();
                }
                self.state.pres_dirty = true;
                Ok(EditResult::slide(*to))
            }
            Edit::HideSlide { slide, hidden } => {
                let (_, doc) = self.slide_mut(*slide)?;
                if *hidden {
                    doc.root.set_attr("show", ns::NONE, "0");
                } else {
                    doc.root.remove_attr(ns::NONE, "show");
                }
                Ok(EditResult::slide(*slide))
            }
            Edit::SetNotes { slide, text } => {
                let part = self.slide_part(*slide)?;
                let rels = self.rels(&part)?;
                let paras: Vec<String> = text.split('\n').map(str::to_owned).collect();
                match rels.first_part(rel::NOTES_SLIDE).filter(|p| !self.state.removed.contains(p)) {
                    Some(np) => {
                        self.doc(&np)?;
                        self.state.dirty.insert(np.clone());
                        let doc = Arc::make_mut(self.state.docs.get_mut(&np).unwrap());
                        let tree = tree_mut(doc).ok_or_else(|| SlideError::Corrupt("These notes have no shapes.".into()))?;
                        let body = tree
                            .elements_mut()
                            .find(|sp| ph_of(sp).is_some_and(|(t, _)| t == "body"))
                            .and_then(|sp| body_of(sp, None))
                            .ok_or_else(|| SlideError::Unsupported("These notes have no text area.".into()))?;
                        text::set_text(body, &paras, "a");
                    }
                    None => {
                        let master = self
                            .state
                            .pres_rels
                            .first_part(rel::NOTES_MASTER)
                            .ok_or_else(|| SlideError::Unsupported("This presentation has no notes pages to add notes to.".into()))?;
                        let body: String = paras
                            .iter()
                            .map(|l| {
                                if l.is_empty() {
                                    "<a:p/>".to_owned()
                                } else {
                                    format!(r#"<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{}</a:t></a:r></a:p>"#, esc(l))
                                }
                            })
                            .collect();
                        let xml = format!(
                            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:notes {NS_DECLS}><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>{body}</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"#
                        );
                        let np = self.unused_part("ppt/notesSlides/notesSlide{}.xml");
                        let mut nrels = Rels::empty(&np);
                        nrels.add(&rel::uri(rel::NOTES_MASTER), &master);
                        nrels.add(&rel::uri(rel::SLIDE), &part);
                        self.state.docs.insert(np.clone(), Arc::new(Document::parse_str(&xml).expect("built-in XML parses")));
                        self.state.rels.insert(np.clone(), Arc::new(nrels));
                        self.state.dirty.insert(np.clone());
                        self.state.dirty_rels.insert(np.clone());
                        self.state.new_parts.insert(np.clone(), NOTES_TYPE.to_owned());
                        self.state.removed.remove(&np);
                        self.rels_mut(&part)?.add(&rel::uri(rel::NOTES_SLIDE), &np);
                    }
                }
                Ok(EditResult::slide(*slide))
            }
        }
    }
}

/// Whether the slide's tree has a shape (for tests).
pub fn has_shape(doc: &Document, id: u32) -> bool {
    sp_tree(doc).is_some_and(|t| find_shape(t, id).is_some()) && child(&doc.root, "cSld").is_some()
}
