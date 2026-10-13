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

/// Maps offsets in a paragraph's old text to its new text: positions before
/// and after the changed stretch move with their characters; positions
/// inside it go to its start.
pub struct OffsetMap {
    prefix: usize,
    old_suffix_start: usize,
    delta: isize,
}

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
        OffsetMap {
            prefix,
            old_suffix_start: a.len() - suffix,
            delta: b.len() as isize - a.len() as isize,
        }
    }

    pub fn map(&self, off: usize) -> usize {
        if off <= self.prefix {
            off
        } else if off >= self.old_suffix_start {
            (off as isize + self.delta).max(0) as usize
        } else {
            self.prefix
        }
    }
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
    }
}
