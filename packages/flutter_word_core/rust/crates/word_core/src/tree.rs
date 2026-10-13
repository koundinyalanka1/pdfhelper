//! The body of a document as a tree of paragraphs and containers, each
//! paragraph still the XML element it was read as.
//!
//! Paragraphs get ids that stay put while the document is edited.
//! Containers (tables, rows, cells, content controls, lists, sections)
//! keep their own element and hold their children as nodes. Everything
//! this engine does not model is kept as it was, in its place.

use doc_xml::{Element, Node as XmlNode};

/// What kind of container a node is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BoxKind {
    Table,
    /// A group of rows (ODF header rows and row groups).
    RowGroup,
    Row,
    Cell,
    /// A cell hidden under a merged one (ODF).
    CoveredCell,
    /// A content control (Word `w:sdt`) or custom XML.
    Control,
    /// The content of a control.
    ControlContent,
    List,
    ListItem,
    Section,
}

/// One node of the body.
#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Para(Para),
    Box(BoxNode),
    /// Kept and written back, never shown: properties, bookmarks, the
    /// final section properties, whitespace.
    Hidden(XmlNode),
    /// A block this engine does not model, shown as its text.
    Raw {
        id: u32,
        el: Element,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Para {
    pub id: u32,
    pub el: Element,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BoxNode {
    pub id: u32,
    pub kind: BoxKind,
    /// The container's own element, without children.
    pub head: Element,
    pub items: Vec<Node>,
}

/// How a node of a particular format is classified.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Para,
    Box(BoxKind),
    Hidden,
    Raw,
}

/// Hands out ids.
#[derive(Clone, Debug, Default)]
pub struct Ids {
    next: u32,
}

impl Ids {
    pub fn next(&mut self) -> u32 {
        self.next += 1;
        self.next
    }
}

/// Build nodes from an element's children, classifying each with
/// `classify(child, parent kind)`.
pub fn build(
    children: Vec<XmlNode>,
    parent: Option<BoxKind>,
    ids: &mut Ids,
    classify: &dyn Fn(&Element, Option<BoxKind>) -> Class,
) -> Vec<Node> {
    let mut out = Vec::with_capacity(children.len());
    for child in children {
        match child {
            XmlNode::Element(e) => match classify(&e, parent) {
                Class::Para => out.push(Node::Para(Para {
                    id: ids.next(),
                    el: e,
                })),
                Class::Box(kind) => {
                    let mut head = e;
                    let kids = std::mem::take(&mut head.children);
                    let id = ids.next();
                    let items = build(kids, Some(kind), ids, classify);
                    out.push(Node::Box(BoxNode {
                        id,
                        kind,
                        head,
                        items,
                    }));
                }
                Class::Hidden => out.push(Node::Hidden(XmlNode::Element(e))),
                Class::Raw => out.push(Node::Raw {
                    id: ids.next(),
                    el: e,
                }),
            },
            other => out.push(Node::Hidden(other)),
        }
    }
    out
}

/// Turn nodes back into XML children.
pub fn flatten(items: &[Node]) -> Vec<XmlNode> {
    items
        .iter()
        .map(|n| match n {
            Node::Para(p) => XmlNode::Element(p.el.clone()),
            Node::Box(b) => {
                let mut e = b.head.clone();
                e.children = flatten(&b.items);
                XmlNode::Element(e)
            }
            Node::Hidden(x) => x.clone(),
            Node::Raw { el, .. } => XmlNode::Element(el.clone()),
        })
        .collect()
}

/// Where a node is: the indexes from the body down.
pub type Path = Vec<usize>;

/// Find a paragraph (or any node with an id) by id.
pub fn find_path(items: &[Node], id: u32) -> Option<Path> {
    for (i, n) in items.iter().enumerate() {
        match n {
            Node::Para(p) if p.id == id => return Some(vec![i]),
            Node::Raw { id: rid, .. } if *rid == id => return Some(vec![i]),
            Node::Box(b) => {
                if b.id == id {
                    return Some(vec![i]);
                }
                if let Some(mut sub) = find_path(&b.items, id) {
                    sub.insert(0, i);
                    return Some(sub);
                }
            }
            _ => {}
        }
    }
    None
}

pub fn node_at<'a>(items: &'a [Node], path: &[usize]) -> Option<&'a Node> {
    let (first, rest) = path.split_first()?;
    let n = items.get(*first)?;
    if rest.is_empty() {
        return Some(n);
    }
    match n {
        Node::Box(b) => node_at(&b.items, rest),
        _ => None,
    }
}

pub fn node_at_mut<'a>(items: &'a mut [Node], path: &[usize]) -> Option<&'a mut Node> {
    let (first, rest) = path.split_first()?;
    let n = items.get_mut(*first)?;
    if rest.is_empty() {
        return Some(n);
    }
    match n {
        Node::Box(b) => node_at_mut(&mut b.items, rest),
        _ => None,
    }
}

/// The list of items a path's last index points into.
pub fn parent_items_mut<'a>(items: &'a mut Vec<Node>, path: &[usize]) -> Option<&'a mut Vec<Node>> {
    if path.len() <= 1 {
        return Some(items);
    }
    let mut cur = items;
    for &i in &path[..path.len() - 1] {
        match cur.get_mut(i)? {
            Node::Box(b) => cur = &mut b.items,
            _ => return None,
        }
    }
    Some(cur)
}

pub fn para_mut<'a>(items: &'a mut [Node], id: u32) -> Option<&'a mut Para> {
    let path = find_path(items, id)?;
    match node_at_mut(items, &path)? {
        Node::Para(p) => Some(p),
        _ => None,
    }
}

pub fn para<'a>(items: &'a [Node], id: u32) -> Option<&'a Para> {
    let path = find_path(items, id)?;
    match node_at(items, &path)? {
        Node::Para(p) => Some(p),
        _ => None,
    }
}

/// Every paragraph in document order.
pub fn paragraphs(items: &[Node]) -> Vec<&Para> {
    let mut out = Vec::new();
    fn walk<'a>(items: &'a [Node], out: &mut Vec<&'a Para>) {
        for n in items {
            match n {
                Node::Para(p) => out.push(p),
                Node::Box(b) => walk(&b.items, out),
                _ => {}
            }
        }
    }
    walk(items, &mut out);
    out
}

/// Ids of every paragraph in document order.
pub fn paragraph_ids(items: &[Node]) -> Vec<u32> {
    paragraphs(items).iter().map(|p| p.id).collect()
}
