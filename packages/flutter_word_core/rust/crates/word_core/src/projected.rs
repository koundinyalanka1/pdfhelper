//! What every format's paragraphs share once read: the view, the objects
//! they hold, the invisible markers between their characters, and how to
//! put those markers back after an edit.

use std::collections::HashMap;

use doc_xml::{Element, Node as XmlNode};

use crate::view::{Inline, InlineEdit, ObjectView, ParaView, RunStyle};

/// An object of a paragraph: the XML that makes it and how it shows.
#[derive(Clone, Debug)]
pub struct StoredObject {
    /// Paragraph-level nodes, written back as they were.
    pub nodes: Vec<XmlNode>,
    /// The link it sat in: its target and the link element (no children).
    pub link: Option<(String, Element)>,
    pub view: ObjectView,
}

/// Every object handed to the screen, by id. Ids are never reused within
/// a session, so an edit can name objects from any paragraph.
#[derive(Debug, Default)]
pub struct Objects {
    next: u32,
    map: HashMap<u32, StoredObject>,
}

impl Objects {
    pub fn add(&mut self, mut obj: StoredObject) -> u32 {
        self.next += 1;
        obj.view.id = self.next;
        self.map.insert(self.next, obj);
        self.next
    }

    pub fn get(&self, id: u32) -> Option<&StoredObject> {
        self.map.get(&id)
    }

    pub fn forget(&mut self, ids: &[u32]) {
        for id in ids {
            self.map.remove(id);
        }
    }
}

/// A paragraph as read: its view plus what an edit needs to write it back.
#[derive(Clone, Debug, Default)]
pub struct Projected {
    pub view: Option<ParaView>,
    /// Invisible nodes (bookmarks, comment anchors) and the UTF-16 offset
    /// in the paragraph's text they sat at.
    pub markers: Vec<(usize, XmlNode)>,
    /// Run properties seen, with the formatting they give: new text reuses
    /// the closest.
    pub templates: Vec<(RunStyle, Option<Element>)>,
    /// Links seen: target and link element (no children).
    pub links: Vec<(String, Element)>,
    /// Objects created for this view.
    pub object_ids: Vec<u32>,
}

impl Projected {
    pub fn view(&self) -> &ParaView {
        self.view
            .as_ref()
            .expect("projected paragraphs have a view")
    }
}

/// What writing an edited paragraph reuses from the paragraphs it
/// replaces.
#[derive(Clone, Debug, Default)]
pub struct RebuildInput {
    /// Run properties and the formatting they give, best first.
    pub templates: Vec<(RunStyle, Option<Element>)>,
    pub links: Vec<(String, Element)>,
    /// Markers and their UTF-16 offsets in the new paragraph's text.
    pub markers: Vec<(usize, XmlNode)>,
}

impl RebuildInput {
    /// Everything of one paragraph, its markers kept where they were.
    pub fn of(p: &Projected) -> RebuildInput {
        RebuildInput {
            templates: p.templates.clone(),
            links: p.links.clone(),
            markers: p.markers.clone(),
        }
    }

    /// The template run properties closest to `want`.
    pub fn template_for(&self, want: &RunStyle) -> Option<&(RunStyle, Option<Element>)> {
        if let Some(t) = self.templates.iter().find(|(s, _)| s == want) {
            return Some(t);
        }
        let score = |s: &RunStyle| {
            (s.bold == want.bold) as u32
                + (s.italic == want.italic) as u32
                + (s.underline == want.underline) as u32
                + (s.strike == want.strike) as u32
                + ((s.size - want.size).abs() < 0.01) as u32 * 2
                + (s.color == want.color) as u32
                + (s.highlight == want.highlight) as u32
                + (s.font == want.font) as u32 * 3
                + (s.vert == want.vert) as u32
        };
        // The first of the best, so earlier paragraphs win ties.
        let mut best: Option<(&(RunStyle, Option<Element>), u32)> = None;
        for t in &self.templates {
            let sc = score(&t.0);
            if best.is_none_or(|(_, b)| sc > b) {
                best = Some((t, sc));
            }
        }
        best.map(|(t, _)| t)
    }

    pub fn link_head(&self, target: &str) -> Option<&Element> {
        self.links.iter().find(|(t, _)| t == target).map(|(_, e)| e)
    }
}

pub fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// The text an edit's inlines make (objects as their text), as the view
/// would show it.
pub fn edit_text(inlines: &[InlineEdit], objects: &Objects) -> String {
    let mut s = String::new();
    for i in inlines {
        match i {
            InlineEdit::Text { text, .. } => s.push_str(text),
            InlineEdit::Object(id) => {
                if let Some(o) = objects.get(*id) {
                    s.push_str(&o.view.text);
                }
            }
        }
    }
    s
}

/// Maps offsets in a paragraph's old text to its new text: positions in
/// text that stayed move with it; positions in text that went go to where
/// the change is. Unchanged text is found by a longest common subsequence
/// of the changed middle (after the common start and end), so several
/// separate changes (replace all) each keep the markers around them.
pub struct OffsetMap {
    /// Runs of unchanged text: old start, new start, length (UTF-16).
    runs: Vec<(usize, usize, usize)>,
}

/// Above this many cells the middle is not compared character by
/// character.
const LCS_LIMIT: usize = 4_000_000;

impl OffsetMap {
    pub fn new(old: &str, new: &str) -> OffsetMap {
        let a: Vec<u16> = old.encode_utf16().collect();
        let b: Vec<u16> = new.encode_utf16().collect();
        let prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
        let max_suffix = a.len().min(b.len()) - prefix;
        let suffix = a
            .iter()
            .rev()
            .zip(b.iter().rev())
            .take(max_suffix)
            .take_while(|(x, y)| x == y)
            .count();
        let mut runs = vec![(0, 0, prefix)];
        let am = &a[prefix..a.len() - suffix];
        let bm = &b[prefix..b.len() - suffix];
        if !am.is_empty() && !bm.is_empty() && am.len() * bm.len() <= LCS_LIMIT {
            for (i, j, len) in lcs_runs(am, bm) {
                runs.push((prefix + i, prefix + j, len));
            }
        }
        runs.push((a.len() - suffix, b.len() - suffix, suffix));
        OffsetMap { runs }
    }

    pub fn map(&self, off: usize) -> usize {
        for &(o, n, len) in &self.runs {
            if off >= o && off <= o + len {
                return n + (off - o);
            }
        }
        // In text that went: where the change is.
        self.runs
            .iter()
            .filter(|(o, _, len)| o + len <= off)
            .map(|(_, n, len)| n + len)
            .max()
            .unwrap_or(0)
    }
}

/// Runs common to `a` and `b` (start in a, start in b, length), in order.
fn lcs_runs(a: &[u16], b: &[u16]) -> Vec<(usize, usize, usize)> {
    let (n, m) = (a.len(), b.len());
    // Lengths of common subsequences of suffixes, one row at a time; the
    // choices are kept to walk back.
    let mut next = vec![0u32; m + 1];
    let mut cur = vec![0u32; m + 1];
    let mut take = vec![0u8; n * m];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            if a[i] == b[j] {
                cur[j] = next[j + 1] + 1;
                take[i * m + j] = 1;
            } else if next[j] >= cur[j + 1] {
                cur[j] = next[j];
                take[i * m + j] = 2;
            } else {
                cur[j] = cur[j + 1];
                take[i * m + j] = 3;
            }
        }
        std::mem::swap(&mut next, &mut cur);
    }
    let mut runs: Vec<(usize, usize, usize)> = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        match take[i * m + j] {
            1 => {
                match runs.last_mut() {
                    Some((ri, rj, len)) if *ri + *len == i && *rj + *len == j => *len += 1,
                    _ => runs.push((i, j, 1)),
                }
                i += 1;
                j += 1;
            }
            2 => i += 1,
            _ => j += 1,
        }
    }
    runs
}

/// Merge text with the previous inline when it looks the same.
pub fn push_text(inlines: &mut Vec<Inline>, text: &str, style: &RunStyle, link: Option<&str>) {
    if text.is_empty() {
        return;
    }
    if let Some(Inline::Text {
        text: t,
        style: s,
        link: l,
    }) = inlines.last_mut()
    {
        if s == style && l.as_deref() == link {
            t.push_str(text);
            return;
        }
    }
    inlines.push(Inline::Text {
        text: text.to_owned(),
        style: style.clone(),
        link: link.map(str::to_owned),
    });
}

/// One piece of a rebuilt paragraph, before links are wrapped around.
pub enum Piece {
    /// Text with its formatting and link.
    Text {
        text: String,
        style: RunStyle,
        link: Option<String>,
    },
    /// An object's nodes, with the link it should sit in.
    Object {
        id: u32,
    },
    Marker(XmlNode),
}

/// Lay out an edit's inlines with markers put at their offsets.
pub fn pieces(
    inlines: &[InlineEdit],
    markers: &[(usize, XmlNode)],
    objects: &Objects,
) -> Vec<Piece> {
    let mut markers: Vec<(usize, &XmlNode)> = markers.iter().map(|(o, n)| (*o, n)).collect();
    markers.sort_by_key(|(o, _)| *o);
    let mut markers = markers.into_iter().peekable();
    let mut out = Vec::new();
    let mut pos = 0usize;
    for inline in inlines {
        match inline {
            InlineEdit::Text { text, style, link } => {
                let mut start = 0usize;
                let mut at = pos;
                for (i, c) in text.char_indices() {
                    while markers.peek().is_some_and(|(o, _)| *o <= at) {
                        if i > start {
                            out.push(Piece::Text {
                                text: text[start..i].to_owned(),
                                style: style.clone(),
                                link: link.clone(),
                            });
                            start = i;
                        }
                        out.push(Piece::Marker(markers.next().unwrap().1.clone()));
                    }
                    at += c.len_utf16();
                }
                if text.len() > start {
                    out.push(Piece::Text {
                        text: text[start..].to_owned(),
                        style: style.clone(),
                        link: link.clone(),
                    });
                }
                pos = at;
            }
            InlineEdit::Object(id) => {
                while markers.peek().is_some_and(|(o, _)| *o <= pos) {
                    out.push(Piece::Marker(markers.next().unwrap().1.clone()));
                }
                if let Some(o) = objects.get(*id) {
                    pos += utf16_len(&o.view.text);
                    out.push(Piece::Object { id: *id });
                }
            }
        }
    }
    for (_, n) in markers {
        out.push(Piece::Marker(n.clone()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_follow_their_characters() {
        let m = OffsetMap::new("Hello world", "Hello big world");
        assert_eq!(m.map(0), 0);
        assert_eq!(m.map(5), 5);
        assert_eq!(m.map(6), 6);
        assert_eq!(m.map(7), 11);
        assert_eq!(m.map(11), 15);
        let m = OffsetMap::new("abcdef", "abef");
        assert_eq!(m.map(3), 2);
        assert_eq!(m.map(4), 2);
        assert_eq!(m.map(6), 4);
        // Two separate changes: text between them keeps its markers.
        let m = OffsetMap::new("Plain bold and spaced end", "Plain! bold and spaced end BOLD");
        assert_eq!(m.map(21), 22);
        assert_eq!(m.map(25), 26);
    }
}
