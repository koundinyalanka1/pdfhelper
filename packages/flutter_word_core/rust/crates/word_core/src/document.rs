//! A document being edited, whatever its format: views for the screen,
//! edits with undo, find and replace, and saving.

use std::collections::HashMap;

use doc_xml::{Element, Node as XmlNode};

use crate::backend::{Backend, Format, StyleInfo, TableOp};
use crate::error::WordError;
use crate::projected::{edit_text, utf16_len, Objects, OffsetMap, Projected, RebuildInput};
use crate::tree::{self, BoxKind, Node, Para, Path};
use crate::view::{
    BlockView, Counts, Inline, InlineEdit, ListLabel, PageSetup, ParaPatch, ParaView,
};

/// A paragraph an edit writes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NewPara {
    pub inlines: Vec<InlineEdit>,
    /// Another paragraph style for it (style id).
    pub style: Option<String>,
}

/// Search options.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FindOptions {
    pub match_case: bool,
    pub whole_word: bool,
}

/// A match: a paragraph and a UTF-16 range of its text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    pub para: u32,
    pub start: usize,
    pub len: usize,
}

/// An edit.
#[derive(Clone, Debug, PartialEq)]
pub enum Edit {
    /// Replace the paragraphs from `first` to `last` (siblings, with
    /// whatever lies between them) by new ones. The first keeps `first`'s
    /// id and properties; later ones are made like it. One paragraph
    /// replacing itself is ordinary typing; one replacing two is joining
    /// them; two replacing one is splitting.
    SetParas {
        first: u32,
        last: u32,
        paras: Vec<NewPara>,
    },
    /// Change paragraph properties.
    Patch {
        ids: Vec<u32>,
        patch: ParaPatch,
    },
    InsertTable {
        after: u32,
        rows: usize,
        cols: usize,
    },
    InsertPageBreak {
        after: u32,
    },
    /// Put a picture in a paragraph of its own after `after` (or into it,
    /// when it is empty). Size in points.
    InsertImage {
        after: u32,
        bytes: Vec<u8>,
        ext: String,
        width: f32,
        height: f32,
    },
    /// Delete a block (a table, a paragraph, content shown as text).
    DeleteBlock {
        id: u32,
    },
    Table {
        id: u32,
        op: TableOp,
    },
    ReplaceAll {
        find: String,
        replace: String,
        options: FindOptions,
    },
}

/// What an edit did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EditResult {
    /// The paragraphs written, in order (for a split, both halves).
    pub ids: Vec<u32>,
    /// Replacements made.
    pub count: usize,
}

/// One reversible change: children of a container replaced.
#[derive(Clone, Debug)]
struct Step {
    /// The container's id, or 0 for the body.
    parent: u32,
    index: usize,
    before: Vec<Node>,
    after: Vec<Node>,
}

const UNDO_LIMIT: usize = 200;

/// A heading, for the outline.
#[derive(Clone, Debug, PartialEq)]
pub struct Heading {
    pub id: u32,
    pub level: u8,
    pub text: String,
}

/// A document being edited.
pub struct Document {
    backend: Box<dyn Backend>,
    /// The format it was read from.
    source: Format,
    objects: Objects,
    cache: HashMap<u32, Projected>,
    labels: Option<HashMap<u32, ListLabel>>,
    /// The blocks the screen lists (paragraphs, tables, other content), in
    /// order, with where they are.
    top: Option<Vec<(u32, Path)>>,
    undo: Vec<Vec<Step>>,
    redo: Vec<Vec<Step>>,
    dirty: bool,
    /// Things worth telling the reader about the file.
    pub warnings: Vec<String>,
}

fn para_ids_in(nodes: &[Node], out: &mut Vec<u32>) {
    for n in nodes {
        match n {
            Node::Para(p) => out.push(p.id),
            Node::Box(b) => para_ids_in(&b.items, out),
            _ => {}
        }
    }
}

fn view_of(
    backend: &dyn Backend,
    cache: &mut HashMap<u32, Projected>,
    objects: &mut Objects,
    labels: &HashMap<u32, ListLabel>,
    p: &Para,
) -> ParaView {
    let pj = cache
        .entry(p.id)
        .or_insert_with(|| backend.project(p, objects));
    let mut v = pj.view().clone();
    v.list = labels.get(&p.id).cloned();
    v
}

fn blocks_of(
    backend: &dyn Backend,
    cache: &mut HashMap<u32, Projected>,
    objects: &mut Objects,
    labels: &HashMap<u32, ListLabel>,
    items: &[Node],
) -> Vec<BlockView> {
    let mut out = Vec::new();
    for n in items {
        match n {
            Node::Para(p) => out.push(BlockView::Para(view_of(backend, cache, objects, labels, p))),
            Node::Box(b) if b.kind == BoxKind::Table => {
                let t = backend.table_view(b, &mut |cell: &[Node]| {
                    blocks_of(backend, cache, objects, labels, cell)
                });
                out.push(BlockView::Table(t));
            }
            Node::Box(b) => out.extend(blocks_of(backend, cache, objects, labels, &b.items)),
            Node::Raw { id, el } => out.push(BlockView::Other {
                id: *id,
                text: el.text(),
            }),
            Node::Hidden(_) => {}
        }
    }
    out
}

fn top_of(items: &[Node], prefix: &mut Path, out: &mut Vec<(u32, Path)>) {
    for (i, n) in items.iter().enumerate() {
        prefix.push(i);
        match n {
            Node::Para(p) => out.push((p.id, prefix.clone())),
            Node::Raw { id, .. } => out.push((*id, prefix.clone())),
            Node::Box(b) if b.kind == BoxKind::Table => out.push((b.id, prefix.clone())),
            Node::Box(b) => top_of(&b.items, prefix, out),
            Node::Hidden(_) => {}
        }
        prefix.pop();
    }
}

/// Characters folded for searching, one per character so offsets map back.
fn fold(text: &str, match_case: bool) -> Vec<char> {
    text.chars()
        .map(|c| {
            if match_case {
                c
            } else {
                c.to_lowercase().next().unwrap_or(c)
            }
        })
        .collect()
}

/// Matches of `needle` in `hay` as char ranges.
fn find_in(hay: &[char], needle: &[char], whole_word: bool) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    if needle.is_empty() || needle.len() > hay.len() {
        return out;
    }
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let mut i = 0;
    while i + needle.len() <= hay.len() {
        if hay[i..i + needle.len()] == *needle {
            let ok = !whole_word
                || ((i == 0 || !word(hay[i - 1]))
                    && (i + needle.len() == hay.len() || !word(hay[i + needle.len()])));
            if ok {
                out.push((i, needle.len()));
                i += needle.len();
                continue;
            }
        }
        i += 1;
    }
    out
}

fn utf16_at(chars: &[char], i: usize) -> usize {
    chars[..i].iter().map(|c| c.len_utf16()).sum()
}

impl Document {
    pub fn new(backend: Box<dyn Backend>, source: Format) -> Document {
        Document {
            backend,
            source,
            objects: Objects::default(),
            cache: HashMap::new(),
            labels: None,
            top: None,
            undo: Vec::new(),
            redo: Vec::new(),
            dirty: false,
            warnings: Vec::new(),
        }
    }

    /// The format the document was read from.
    pub fn source_format(&self) -> Format {
        self.source
    }

    /// The format saving writes: the source's when it can be written back,
    /// otherwise Word.
    pub fn save_format(&self) -> Format {
        if self.source.writes_back() {
            self.source
        } else {
            self.backend.format()
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn page_setup(&self) -> PageSetup {
        self.backend.page_setup()
    }

    pub fn styles(&self) -> Vec<StyleInfo> {
        self.backend.styles()
    }

    fn ensure_top(&mut self) -> &Vec<(u32, Path)> {
        if self.top.is_none() {
            let mut out = Vec::new();
            top_of(self.backend.body(), &mut Vec::new(), &mut out);
            self.top = Some(out);
        }
        self.top.as_ref().unwrap()
    }

    fn ensure_labels(&mut self) {
        if self.labels.is_none() {
            self.labels = Some(self.backend.list_labels());
        }
    }

    /// How many blocks the screen lists.
    pub fn block_count(&mut self) -> usize {
        self.ensure_top().len()
    }

    /// Where a block is in the list.
    pub fn block_index(&mut self, id: u32) -> Option<usize> {
        let path = tree::find_path(self.backend.body(), id)?;
        self.ensure_top()
            .iter()
            .position(|(_, p)| path.starts_with(p))
    }

    /// Blocks `from..from + count`.
    pub fn blocks(&mut self, from: usize, count: usize) -> Vec<BlockView> {
        self.ensure_labels();
        let top: Vec<Path> = self
            .ensure_top()
            .iter()
            .skip(from)
            .take(count)
            .map(|(_, p)| p.clone())
            .collect();
        let backend = &*self.backend;
        let labels = self.labels.as_ref().unwrap();
        let mut out = Vec::new();
        for path in top {
            let Some(node) = tree::node_at(backend.body(), &path) else {
                continue;
            };
            out.extend(blocks_of(
                backend,
                &mut self.cache,
                &mut self.objects,
                labels,
                std::slice::from_ref(node),
            ));
        }
        out
    }

    /// One paragraph's view.
    pub fn paragraph(&mut self, id: u32) -> Option<ParaView> {
        self.ensure_labels();
        let backend = &*self.backend;
        let p = tree::para(backend.body(), id)?;
        Some(view_of(
            backend,
            &mut self.cache,
            &mut self.objects,
            self.labels.as_ref().unwrap(),
            p,
        ))
    }

    fn projected(&mut self, id: u32) -> Result<&Projected, WordError> {
        if !self.cache.contains_key(&id) {
            let p = tree::para(self.backend.body(), id)
                .ok_or_else(|| WordError::Invalid("That paragraph is gone.".into()))?;
            let pj = self.backend.project(p, &mut self.objects);
            self.cache.insert(id, pj);
        }
        Ok(&self.cache[&id])
    }

    /// Headings, for moving around a long document.
    pub fn outline(&mut self) -> Vec<Heading> {
        let ids = tree::paragraph_ids(self.backend.body());
        let mut out = Vec::new();
        for id in ids {
            let Ok(pj) = self.projected(id) else { continue };
            let v = pj.view();
            if let Some(level) = v.style.outline_level {
                let text = v.text();
                if !text.trim().is_empty() {
                    out.push(Heading {
                        id,
                        level,
                        text: text.trim().to_owned(),
                    });
                }
            }
        }
        out
    }

    /// The bytes and file extension of an image object.
    pub fn image(&self, object: u32) -> Option<(Vec<u8>, String)> {
        let o = self.objects.get(object)?;
        self.backend.image(o)
    }

    /// The whole text: paragraphs on lines, table cells separated by tabs.
    pub fn plain_text(&mut self) -> String {
        let n = self.block_count();
        let blocks = self.blocks(0, n);
        let mut out = String::new();
        fn para_text(v: &ParaView) -> String {
            let mut s = String::new();
            if let Some(l) = &v.list {
                s.push_str(&l.text);
                s.push(' ');
            }
            s.push_str(&v.text());
            s
        }
        fn write(blocks: &[BlockView], out: &mut String) {
            for b in blocks {
                match b {
                    BlockView::Para(p) => {
                        out.push_str(&para_text(p));
                        out.push('\n');
                    }
                    BlockView::Table(t) => {
                        for r in &t.rows {
                            let cells: Vec<String> = r
                                .cells
                                .iter()
                                .map(|c| {
                                    let mut s = String::new();
                                    write(&c.blocks, &mut s);
                                    s.trim_end().replace('\n', " ")
                                })
                                .collect();
                            out.push_str(&cells.join("\t"));
                            out.push('\n');
                        }
                    }
                    BlockView::Other { text, .. } => {
                        out.push_str(text);
                        out.push('\n');
                    }
                }
            }
        }
        write(&blocks, &mut out);
        out
    }

    pub fn counts(&mut self) -> Counts {
        let ids = tree::paragraph_ids(self.backend.body());
        let mut c = Counts::default();
        for id in ids {
            let Ok(pj) = self.projected(id) else { continue };
            let text = pj.view().text();
            if text.trim().is_empty() {
                continue;
            }
            c.paragraphs += 1;
            c.words += text.split_whitespace().count();
            c.characters += text.chars().filter(|ch| *ch != '\n').count();
            c.characters_no_spaces += text.chars().filter(|ch| !ch.is_whitespace()).count();
        }
        c
    }

    /// Every match of `query`, in document order.
    pub fn find(&mut self, query: &str, options: FindOptions) -> Vec<Match> {
        let needle = fold(query, options.match_case);
        let ids = tree::paragraph_ids(self.backend.body());
        let mut out = Vec::new();
        for id in ids {
            let Ok(pj) = self.projected(id) else { continue };
            let text = pj.view().text();
            let hay = fold(&text, options.match_case);
            for (s, l) in find_in(&hay, &needle, options.whole_word) {
                let start = utf16_at(&hay, s);
                let len = utf16_at(&hay, s + l) - start;
                out.push(Match {
                    para: id,
                    start,
                    len,
                });
            }
        }
        out
    }

    // --- Editing

    fn items_mut(&mut self, parent: u32) -> Result<&mut Vec<Node>, WordError> {
        let body = self.backend.body_mut();
        if parent == 0 {
            return Ok(body);
        }
        let path = tree::find_path(body, parent)
            .ok_or_else(|| WordError::Invalid("That part of the document is gone.".into()))?;
        match tree::node_at_mut(body, &path) {
            Some(Node::Box(b)) => Ok(&mut b.items),
            _ => Err(WordError::Invalid(
                "That part of the document is gone.".into(),
            )),
        }
    }

    /// The container (0 for the body) and index of a node.
    fn locate(&self, id: u32) -> Result<(u32, usize, Path), WordError> {
        let body = self.backend.body();
        let path = tree::find_path(body, id)
            .ok_or_else(|| WordError::Invalid("That part of the document is gone.".into()))?;
        let index = *path.last().unwrap();
        let parent = if path.len() == 1 {
            0
        } else {
            match tree::node_at(body, &path[..path.len() - 1]) {
                Some(Node::Box(b)) => b.id,
                _ => 0,
            }
        };
        Ok((parent, index, path))
    }

    fn splice(
        &mut self,
        parent: u32,
        index: usize,
        remove: usize,
        insert: Vec<Node>,
    ) -> Result<Vec<Node>, WordError> {
        let mut touched = Vec::new();
        para_ids_in(&insert, &mut touched);
        let items = self.items_mut(parent)?;
        if index + remove > items.len() {
            return Err(WordError::Invalid(
                "That part of the document has changed.".into(),
            ));
        }
        let removed: Vec<Node> = items.splice(index..index + remove, insert).collect();
        para_ids_in(&removed, &mut touched);
        for id in touched {
            self.cache.remove(&id);
        }
        self.labels = None;
        self.top = None;
        Ok(removed)
    }

    fn run(&mut self, steps: Vec<Step>) -> Result<(), WordError> {
        let mut done: Vec<Step> = Vec::new();
        for s in steps {
            match self.splice(s.parent, s.index, s.before.len(), s.after.clone()) {
                Ok(_) => done.push(s),
                Err(e) => {
                    // Put back what was done.
                    for d in done.into_iter().rev() {
                        let _ = self.splice(d.parent, d.index, d.after.len(), d.before);
                    }
                    return Err(e);
                }
            }
        }
        if !done.is_empty() {
            self.undo.push(done);
            if self.undo.len() > UNDO_LIMIT {
                self.undo.remove(0);
            }
            self.redo.clear();
            self.dirty = true;
        }
        Ok(())
    }

    pub fn undo(&mut self) -> Result<bool, WordError> {
        let Some(group) = self.undo.pop() else {
            return Ok(false);
        };
        for s in group.iter().rev() {
            self.splice(s.parent, s.index, s.after.len(), s.before.clone())?;
        }
        self.redo.push(group);
        self.dirty = true;
        Ok(true)
    }

    pub fn redo(&mut self) -> Result<bool, WordError> {
        let Some(group) = self.redo.pop() else {
            return Ok(false);
        };
        for s in &group {
            self.splice(s.parent, s.index, s.before.len(), s.after.clone())?;
        }
        self.undo.push(group);
        self.dirty = true;
        Ok(true)
    }

    pub fn apply(&mut self, edit: Edit) -> Result<EditResult, WordError> {
        match edit {
            Edit::SetParas { first, last, paras } => {
                let (steps, ids) = self.plan_set_paras(first, last, paras)?;
                self.run(steps)?;
                Ok(EditResult { ids, count: 0 })
            }
            Edit::Patch { ids, patch } => self.patch(ids, patch),
            Edit::InsertTable { after, rows, cols } => {
                let (parent, index, _) = self.locate(after)?;
                let empty = self
                    .projected(after)
                    .map(|p| p.view().inlines.is_empty())
                    .unwrap_or(false);
                let table = self.backend.new_table(rows, cols);
                let mut first_para = Vec::new();
                tree::paragraphs(std::slice::from_ref(&table))
                    .first()
                    .inspect(|p| first_para.push(p.id));
                let step = if empty {
                    Step {
                        parent,
                        index,
                        before: vec![],
                        after: vec![table],
                    }
                } else {
                    let next_is_para = {
                        let items = self.items_mut(parent)?;
                        matches!(items.get(index + 1), Some(Node::Para(_)))
                    };
                    let mut after_nodes = vec![table];
                    if !next_is_para {
                        let id = self.backend.ids().next();
                        let el = self.backend.new_para(None, None);
                        after_nodes.push(Node::Para(Para { id, el }));
                    }
                    Step {
                        parent,
                        index: index + 1,
                        before: vec![],
                        after: after_nodes,
                    }
                };
                self.run(vec![step])?;
                Ok(EditResult {
                    ids: first_para,
                    count: 0,
                })
            }
            Edit::InsertPageBreak { after } => {
                let (parent, index, _) = self.locate(after)?;
                let id = self.backend.ids().next();
                let el = self.backend.page_break_para();
                self.run(vec![Step {
                    parent,
                    index: index + 1,
                    before: vec![],
                    after: vec![Node::Para(Para { id, el })],
                }])?;
                Ok(EditResult {
                    ids: vec![id],
                    count: 0,
                })
            }
            Edit::InsertImage {
                after,
                bytes,
                ext,
                width,
                height,
            } => {
                let (parent, index, path) = self.locate(after)?;
                let empty = self.projected(after)?.view().inlines.is_empty();
                let Some(Node::Para(old)) = tree::node_at(self.backend.body(), &path).cloned()
                else {
                    return Err(WordError::Invalid("Pictures go after a paragraph.".into()));
                };
                let nodes = self.backend.image_nodes(&bytes, &ext, width, height)?;
                let (step, id) = if empty {
                    let mut el = old.el.clone();
                    el.children.extend(nodes);
                    (
                        Step {
                            parent,
                            index,
                            before: vec![Node::Para(old.clone())],
                            after: vec![Node::Para(Para { id: old.id, el })],
                        },
                        old.id,
                    )
                } else {
                    let mut el = self.backend.new_para(Some(&old.el), None);
                    el.children.extend(nodes);
                    let id = self.backend.ids().next();
                    (
                        Step {
                            parent,
                            index: index + 1,
                            before: vec![],
                            after: vec![Node::Para(Para { id, el })],
                        },
                        id,
                    )
                };
                self.run(vec![step])?;
                Ok(EditResult {
                    ids: vec![id],
                    count: 0,
                })
            }
            Edit::DeleteBlock { id } => {
                let (parent, index, path) = self.locate(id)?;
                let node = tree::node_at(self.backend.body(), &path).cloned().unwrap();
                // Containers keep at least one paragraph.
                let left = {
                    let items = self.items_mut(parent)?;
                    items
                        .iter()
                        .enumerate()
                        .filter(|(i, n)| {
                            *i != index
                                && matches!(n, Node::Para(_) | Node::Box(_) | Node::Raw { .. })
                        })
                        .count()
                };
                let mut after = Vec::new();
                if left == 0 {
                    let id = self.backend.ids().next();
                    let el = self.backend.new_para(None, None);
                    after.push(Node::Para(Para { id, el }));
                }
                let ids = after
                    .iter()
                    .filter_map(|n| match n {
                        Node::Para(p) => Some(p.id),
                        _ => None,
                    })
                    .collect();
                self.run(vec![Step {
                    parent,
                    index,
                    before: vec![node],
                    after,
                }])?;
                Ok(EditResult { ids, count: 0 })
            }
            Edit::Table { id, op } => {
                let (parent, index, path) = self.locate(id)?;
                let Some(Node::Box(table)) = tree::node_at(self.backend.body(), &path).cloned()
                else {
                    return Err(WordError::Invalid("That is not a table.".into()));
                };
                let new = self.backend.table_edit(&table, op)?;
                self.run(vec![Step {
                    parent,
                    index,
                    before: vec![Node::Box(table)],
                    after: vec![Node::Box(new)],
                }])?;
                Ok(EditResult::default())
            }
            Edit::ReplaceAll {
                find,
                replace,
                options,
            } => self.replace_all(&find, &replace, options),
        }
    }

    fn patch(&mut self, ids: Vec<u32>, patch: ParaPatch) -> Result<EditResult, WordError> {
        let order = tree::paragraph_ids(self.backend.body());
        let mut ids: Vec<u32> = ids.into_iter().filter(|id| order.contains(id)).collect();
        ids.sort_by_key(|id| order.iter().position(|x| x == id));
        ids.dedup();
        let Some(&first) = ids.first() else {
            return Err(WordError::Invalid("No paragraph to change.".into()));
        };
        let prev = order
            .iter()
            .position(|x| *x == first)
            .filter(|i| *i > 0)
            .and_then(|i| tree::para(self.backend.body(), order[i - 1]))
            .map(|p| p.el.clone());
        // Lists that are containers change the tree, one paragraph at a
        // time from the last, so earlier positions stay put.
        let mut patch = patch;
        let mut list_steps = Vec::new();
        if self.backend.structural_lists() {
            if let Some(kind) = patch.list.take() {
                for id in ids.iter().rev() {
                    if let Some(sp) = self.backend.list_splice(*id, &kind) {
                        let before = self.splice(sp.parent, sp.index, sp.remove, sp.insert.clone())?;
                        list_steps.push(Step {
                            parent: sp.parent,
                            index: sp.index,
                            before,
                            after: sp.insert,
                        });
                    }
                }
            }
        }
        if patch == ParaPatch::default() {
            self.record(list_steps);
            return Ok(EditResult { ids, count: 0 });
        }
        let mut places = Vec::new();
        let mut els: Vec<Element> = Vec::new();
        for id in &ids {
            let (parent, index, _) = self.locate(*id)?;
            let p = tree::para(self.backend.body(), *id).unwrap();
            places.push((parent, index, p.clone()));
            els.push(p.el.clone());
        }
        self.backend.patch(&mut els, prev.as_ref(), &patch);
        let steps: Vec<Step> = places
            .into_iter()
            .zip(els)
            .map(|((parent, index, old), el)| Step {
                parent,
                index,
                after: vec![Node::Para(Para { id: old.id, el })],
                before: vec![Node::Para(old)],
            })
            .collect();
        if list_steps.is_empty() {
            self.run(steps)?;
        } else {
            for st in &steps {
                self.splice(st.parent, st.index, st.before.len(), st.after.clone())?;
            }
            list_steps.extend(steps);
            self.record(list_steps);
        }
        Ok(EditResult { ids, count: 0 })
    }

    /// Keep steps already applied as one undoable edit.
    fn record(&mut self, steps: Vec<Step>) {
        if steps.is_empty() {
            return;
        }
        self.undo.push(steps);
        if self.undo.len() > UNDO_LIMIT {
            self.undo.remove(0);
        }
        self.redo.clear();
        self.dirty = true;
    }

    fn plan_set_paras(
        &mut self,
        first: u32,
        last: u32,
        specs: Vec<NewPara>,
    ) -> Result<(Vec<Step>, Vec<u32>), WordError> {
        if specs.is_empty() {
            return Err(WordError::Invalid("An edit must leave a paragraph.".into()));
        }
        let (parent, i0, p1) = self.locate(first)?;
        let (_, i1, p2) = self.locate(last)?;
        if p1[..p1.len() - 1] != p2[..p2.len() - 1] || i1 < i0 {
            return Err(WordError::Invalid(
                "Those paragraphs are not next to each other.".into(),
            ));
        }
        let old: Vec<Node> = {
            let items = self.items_mut(parent)?;
            items[i0..=i1].to_vec()
        };
        let Node::Para(first_para) = &old[0] else {
            return Err(WordError::Invalid("That is not a paragraph.".into()));
        };
        let first_el = first_para.el.clone();
        let old_paras: Vec<Para> = old
            .iter()
            .filter_map(|n| match n {
                Node::Para(p) => Some(p.clone()),
                _ => None,
            })
            .collect();

        // What the old paragraphs had: text, markers, run formats, links.
        let mut old_text = String::new();
        let mut markers: Vec<(usize, XmlNode)> = Vec::new();
        let mut input = RebuildInput::default();
        for (k, p) in old_paras.iter().enumerate() {
            let pj = self.projected(p.id)?;
            let v = pj.view();
            if !v.editable {
                return Err(WordError::Invalid(
                    v.locked_reason
                        .clone()
                        .unwrap_or_else(|| "This paragraph can't be edited here.".into()),
                ));
            }
            if k > 0 {
                old_text.push('\n');
            }
            let base = utf16_len(&old_text);
            markers.extend(pj.markers.iter().map(|(o, n)| (base + o, n.clone())));
            old_text.push_str(&v.text());
            for t in &pj.templates {
                if !input.templates.contains(t) {
                    input.templates.push(t.clone());
                }
            }
            for l in &pj.links {
                if !input.links.iter().any(|x| x.0 == l.0) {
                    input.links.push(l.clone());
                }
            }
        }
        // Markers go where their characters went.
        let new_texts: Vec<String> = specs
            .iter()
            .map(|s| edit_text(&s.inlines, &self.objects))
            .collect();
        let map = OffsetMap::new(&old_text, &new_texts.join("\n"));
        let mut starts = Vec::new();
        let mut acc = 0;
        for t in &new_texts {
            starts.push(acc);
            acc += utf16_len(t) + 1;
        }
        let mut per_para: Vec<Vec<(usize, XmlNode)>> = vec![Vec::new(); specs.len()];
        for (o, n) in markers {
            let m = map.map(o);
            let k = starts.iter().rposition(|s| *s <= m).unwrap_or(0);
            let local = (m - starts[k]).min(utf16_len(&new_texts[k]));
            per_para[k].push((local, n));
        }
        // A section break stays at the end of the stretch.
        let mut section = None;
        for p in &old_paras {
            let mut el = p.el.clone();
            if let Some(s) = self.backend.take_section(&mut el) {
                section = Some(s);
            }
        }
        let mut new_nodes = Vec::new();
        let mut ids = Vec::new();
        let count = specs.len();
        for (k, spec) in specs.into_iter().enumerate() {
            if let Some(s) = &spec.style {
                self.backend.ensure_style(s);
            }
            let base = if k == 0 {
                let mut b = first_el.clone();
                self.backend.take_section(&mut b);
                if let Some(s) = &spec.style {
                    let mut arr = [b];
                    self.backend.patch(
                        &mut arr,
                        None,
                        &ParaPatch {
                            style_id: Some(s.clone()),
                            ..ParaPatch::default()
                        },
                    );
                    let [x] = arr;
                    b = x;
                }
                b
            } else {
                self.backend
                    .new_para(Some(&first_el), spec.style.as_deref())
            };
            let mut inp = input.clone();
            inp.markers = std::mem::take(&mut per_para[k]);
            let mut el = self
                .backend
                .rebuild(&base, &inp, &spec.inlines, &self.objects);
            if k + 1 == count {
                if let Some(s) = section.take() {
                    self.backend.put_section(&mut el, s);
                }
            }
            let id = if k == 0 {
                first
            } else {
                self.backend.ids().next()
            };
            ids.push(id);
            new_nodes.push(Node::Para(Para { id, el }));
        }
        // Invisible body-level content between the paragraphs stays.
        for n in old.iter().skip(1) {
            if let Node::Hidden(_) = n {
                new_nodes.push(n.clone());
            }
        }
        Ok((
            vec![Step {
                parent,
                index: i0,
                before: old,
                after: new_nodes,
            }],
            ids,
        ))
    }

    fn replace_all(
        &mut self,
        find: &str,
        replace: &str,
        options: FindOptions,
    ) -> Result<EditResult, WordError> {
        let needle = fold(find, options.match_case);
        if needle.is_empty() {
            return Ok(EditResult::default());
        }
        let ids = tree::paragraph_ids(self.backend.body());
        let mut steps = Vec::new();
        let mut changed = Vec::new();
        let mut count = 0;
        for id in ids {
            let pj = self.projected(id)?;
            let v = pj.view();
            if !v.editable {
                continue;
            }
            let mut hit = false;
            let mut inlines = Vec::new();
            for i in &v.inlines {
                match i {
                    Inline::Text { text, style, link } => {
                        let chars: Vec<char> = text.chars().collect();
                        let hay = fold(text, options.match_case);
                        let found = find_in(&hay, &needle, options.whole_word);
                        if found.is_empty() {
                            inlines.push(InlineEdit::Text {
                                text: text.clone(),
                                style: style.clone(),
                                link: link.clone(),
                            });
                            continue;
                        }
                        hit = true;
                        count += found.len();
                        let mut s = String::new();
                        let mut at = 0;
                        for (start, len) in found {
                            s.extend(&chars[at..start]);
                            s.push_str(replace);
                            at = start + len;
                        }
                        s.extend(&chars[at..]);
                        inlines.push(InlineEdit::Text {
                            text: s,
                            style: style.clone(),
                            link: link.clone(),
                        });
                    }
                    Inline::Object(o) => inlines.push(InlineEdit::Object(o.id)),
                }
            }
            if hit {
                let (mut s, _) = self.plan_set_paras(
                    id,
                    id,
                    vec![NewPara {
                        inlines,
                        style: None,
                    }],
                )?;
                steps.append(&mut s);
                changed.push(id);
            }
        }
        self.run(steps)?;
        Ok(EditResult {
            ids: changed,
            count,
        })
    }

    /// The document in the format it saves as.
    pub fn save(&mut self) -> Result<(Vec<u8>, Format), WordError> {
        let bytes = self.backend.save()?;
        Ok((bytes, self.save_format()))
    }

    /// Mark as saved.
    pub fn saved(&mut self) {
        self.dirty = false;
    }
}
