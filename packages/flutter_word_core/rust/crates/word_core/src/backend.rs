//! What each file format provides to the format-neutral [`crate::Document`].

use std::collections::HashMap;

use doc_xml::{Element, Node as XmlNode};

use crate::error::WordError;
use crate::projected::{Objects, Projected, RebuildInput, StoredObject};
use crate::tree::{BoxNode, Ids, Node, Para};
use crate::view::{BlockView, InlineEdit, ListLabel, PageSetup, ParaPatch, TableView};

/// File formats a document is read from or written to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Docx,
    /// Word with macros (`.docm`): saved as it is, macros untouched.
    Docm,
    /// A Word template (`.dotx`, `.dotm`).
    Dotx,
    Odt,
    /// An OpenDocument template (`.ott`).
    Ott,
    Rtf,
    Txt,
    Markdown,
}

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::Docx => "docx",
            Format::Docm => "docm",
            Format::Dotx => "dotx",
            Format::Odt => "odt",
            Format::Ott => "ott",
            Format::Rtf => "rtf",
            Format::Txt => "txt",
            Format::Markdown => "md",
        }
    }

    pub fn parse(s: &str) -> Option<Format> {
        Some(match s.to_ascii_lowercase().trim_start_matches('.') {
            "docx" => Format::Docx,
            "docm" => Format::Docm,
            "dotx" | "dotm" => Format::Dotx,
            "odt" => Format::Odt,
            "ott" => Format::Ott,
            "rtf" => Format::Rtf,
            "txt" | "text" => Format::Txt,
            "md" | "markdown" => Format::Markdown,
            _ => return None,
        })
    }

    /// Whether documents of this format are saved back in it. The others
    /// are imported and saved as Word documents.
    pub fn writes_back(self) -> bool {
        matches!(
            self,
            Format::Docx | Format::Docm | Format::Dotx | Format::Odt | Format::Ott
        )
    }
}

/// A change to a table's shape.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TableOp {
    /// Insert a row next to row `at` (below it when `below`).
    InsertRow {
        at: usize,
        below: bool,
    },
    DeleteRow {
        at: usize,
    },
    /// Insert a column next to column `at` (to its right when `right`).
    InsertCol {
        at: usize,
        right: bool,
    },
    DeleteCol {
        at: usize,
    },
}

/// A paragraph style the screen can offer.
#[derive(Clone, Debug, PartialEq)]
pub struct StyleInfo {
    pub id: String,
    pub name: String,
    /// Heading level (0 for Heading 1) of heading styles.
    pub outline: Option<u8>,
    /// Defined by the document (others are added when first used).
    pub defined: bool,
}

/// A structural change: `remove` children of container `parent` (0 for
/// the body) at `index` replaced by `insert`.
#[derive(Clone, Debug)]
pub struct Splice {
    pub parent: u32,
    pub index: usize,
    pub remove: usize,
    pub insert: Vec<Node>,
}

/// One file format's reading and writing of paragraphs, tables and the
/// package around them.
pub trait Backend: Send {
    fn format(&self) -> Format;
    fn body(&self) -> &Vec<Node>;
    fn body_mut(&mut self) -> &mut Vec<Node>;
    fn ids(&mut self) -> &mut Ids;

    /// Read a paragraph into its view (no list label).
    fn project(&self, para: &Para, objects: &mut Objects) -> Projected;
    /// The label of every list paragraph, by paragraph id.
    fn list_labels(&self) -> HashMap<u32, ListLabel>;
    /// Write a paragraph with new content, keeping `base`'s properties.
    fn rebuild(
        &mut self,
        base: &Element,
        input: &RebuildInput,
        inlines: &[InlineEdit],
        objects: &Objects,
    ) -> Element;
    /// Change paragraph properties; `prev` is the paragraph before the
    /// first one, for continuing its list.
    fn patch(&mut self, paras: &mut [Element], prev: Option<&Element>, patch: &ParaPatch);
    /// Whether lists are containers around paragraphs (OpenDocument)
    /// rather than paragraph properties (Word).
    fn structural_lists(&self) -> bool {
        false
    }
    /// For structural lists: the change that puts paragraph `id` into a
    /// list of `kind` (`bullet`, `number`) or takes it out (`none`).
    fn list_splice(&mut self, _id: u32, _kind: &str) -> Option<Splice> {
        None
    }
    /// A new empty paragraph like `like`, optionally in another style.
    fn new_para(&self, like: Option<&Element>, style: Option<&str>) -> Element;
    /// Section properties a paragraph carries (Word keeps a section break
    /// in the paragraph that ends the section): taken out, to be put back
    /// on whichever paragraph ends up last.
    fn take_section(&self, _para: &mut Element) -> Option<XmlNode> {
        None
    }
    fn put_section(&self, _para: &mut Element, _section: XmlNode) {}

    fn table_view(
        &self,
        table: &BoxNode,
        cells: &mut dyn FnMut(&[Node]) -> Vec<BlockView>,
    ) -> TableView;
    fn new_table(&mut self, rows: usize, cols: usize) -> Node;
    fn table_edit(&mut self, table: &BoxNode, op: TableOp) -> Result<BoxNode, WordError>;
    /// A paragraph holding only a page break.
    fn page_break_para(&mut self) -> Element;

    fn page_setup(&self) -> PageSetup;
    fn styles(&self) -> Vec<StyleInfo>;
    /// Make sure a style exists, adding a built-in definition if needed.
    fn ensure_style(&mut self, id: &str);

    /// An image object's bytes and file extension.
    fn image(&self, obj: &StoredObject) -> Option<(Vec<u8>, String)>;
    /// Add an image to the package; returns the paragraph content that
    /// shows it at `width` x `height` points.
    fn image_nodes(
        &mut self,
        bytes: &[u8],
        ext: &str,
        width: f32,
        height: f32,
    ) -> Result<Vec<XmlNode>, WordError>;

    /// The document in its format.
    fn save(&mut self) -> Result<Vec<u8>, WordError>;
}
