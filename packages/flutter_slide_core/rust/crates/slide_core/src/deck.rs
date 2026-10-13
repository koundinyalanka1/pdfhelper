//! A presentation being edited, whatever its format: scenes, notes, edits
//! with undo and redo, and saving.

use std::any::Any;

use crate::error::SlideError;
use crate::scene::Scene;

/// File formats a deck is read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Pptx,
    /// PowerPoint with macros: saved as it is, macros untouched.
    Pptm,
    /// A PowerPoint template or show (`.potx`, `.ppsx`).
    Potx,
    Odp,
}

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::Pptx => "pptx",
            Format::Pptm => "pptm",
            Format::Potx => "potx",
            Format::Odp => "odp",
        }
    }
}

/// Text formatting applied to a whole shape's text.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TextPatch {
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<bool>,
    /// Points.
    pub size: Option<f32>,
    /// `0xRRGGBB`.
    pub color: Option<u32>,
    /// `l`, `ctr`, `r`, `just`.
    pub align: Option<String>,
}

/// An edit. Positions and sizes are in points.
#[derive(Clone, Debug, PartialEq)]
pub enum Edit {
    /// New text for a shape (or a table cell): one string per paragraph,
    /// U+2028 for line breaks inside one.
    SetText { slide: usize, shape: u32, cell: Option<(usize, usize)>, paras: Vec<String> },
    FormatText { slide: usize, shape: u32, cell: Option<(usize, usize)>, patch: TextPatch },
    AddTextBox { slide: usize, x: f32, y: f32, w: f32, h: f32, text: String },
    AddShape { slide: usize, preset: String, x: f32, y: f32, w: f32, h: f32 },
    AddImage { slide: usize, bytes: Vec<u8>, ext: String, x: f32, y: f32, w: f32, h: f32 },
    DeleteShape { slide: usize, shape: u32 },
    MoveShape { slide: usize, shape: u32, x: f32, y: f32, w: f32, h: f32 },
    /// A new slide after `after` (at the end when None) from a layout (its
    /// part; the slide before's when None).
    AddSlide { after: Option<usize>, layout: Option<String> },
    DuplicateSlide { slide: usize },
    DeleteSlide { slide: usize },
    MoveSlide { from: usize, to: usize },
    HideSlide { slide: usize, hidden: bool },
    SetNotes { slide: usize, text: String },
}

/// What an edit did: the slide to show and the shape it made or changed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EditResult {
    pub slide: Option<usize>,
    pub shape: Option<u32>,
}

impl EditResult {
    pub fn slide(i: usize) -> EditResult {
        EditResult { slide: Some(i), shape: None }
    }

    pub fn at(i: usize, shape: u32) -> EditResult {
        EditResult {
            slide: Some(i),
            shape: Some(shape),
        }
    }
}

/// One format's reading and writing.
pub trait Backend: Send {
    fn format(&self) -> Format;
    /// Slide size in points.
    fn size(&self) -> (f32, f32);
    fn slide_count(&self) -> usize;
    fn scene(&mut self, i: usize) -> Result<Scene, SlideError>;
    fn notes(&mut self, i: usize) -> Result<String, SlideError>;
    /// Layouts for new slides: (id, name).
    fn layouts(&mut self) -> Vec<(String, String)>;
    /// A part's bytes (pictures).
    fn part(&self, name: &str) -> Option<Vec<u8>>;
    fn apply(&mut self, edit: &Edit) -> Result<EditResult, SlideError>;
    /// The editable state, for undo.
    fn snapshot(&self) -> Box<dyn Any + Send>;
    fn restore(&mut self, state: Box<dyn Any + Send>);
    fn save(&self) -> Result<Vec<u8>, SlideError>;
}

const UNDO_LIMIT: usize = 100;

/// A presentation being edited.
pub struct Deck {
    backend: Box<dyn Backend>,
    undo: Vec<Box<dyn Any + Send>>,
    redo: Vec<Box<dyn Any + Send>>,
    dirty: bool,
    pub warnings: Vec<String>,
}

impl Deck {
    pub fn new(backend: Box<dyn Backend>) -> Deck {
        Deck {
            backend,
            undo: Vec::new(),
            redo: Vec::new(),
            dirty: false,
            warnings: Vec::new(),
        }
    }

    pub fn format(&self) -> Format {
        self.backend.format()
    }

    pub fn size(&self) -> (f32, f32) {
        self.backend.size()
    }

    pub fn slide_count(&self) -> usize {
        self.backend.slide_count()
    }

    pub fn scene(&mut self, i: usize) -> Result<Scene, SlideError> {
        self.backend.scene(i)
    }

    pub fn notes(&mut self, i: usize) -> Result<String, SlideError> {
        self.backend.notes(i)
    }

    pub fn layouts(&mut self) -> Vec<(String, String)> {
        self.backend.layouts()
    }

    pub fn part(&self, name: &str) -> Option<Vec<u8>> {
        self.backend.part(name)
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

    pub fn apply(&mut self, edit: &Edit) -> Result<EditResult, SlideError> {
        let before = self.backend.snapshot();
        match self.backend.apply(edit) {
            Ok(r) => {
                self.undo.push(before);
                if self.undo.len() > UNDO_LIMIT {
                    self.undo.remove(0);
                }
                self.redo.clear();
                self.dirty = true;
                Ok(r)
            }
            Err(e) => {
                // Nothing half-done stays.
                self.backend.restore(before);
                Err(e)
            }
        }
    }

    pub fn undo(&mut self) -> bool {
        let Some(s) = self.undo.pop() else { return false };
        self.redo.push(self.backend.snapshot());
        self.backend.restore(s);
        self.dirty = true;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(s) = self.redo.pop() else { return false };
        self.undo.push(self.backend.snapshot());
        self.backend.restore(s);
        self.dirty = true;
        true
    }

    /// Every slide's text, for find and sharing as text.
    pub fn plain_text(&mut self) -> String {
        let mut out = String::new();
        for i in 0..self.slide_count() {
            out.push_str(&format!("Slide {}\n", i + 1));
            if let Ok(s) = self.scene(i) {
                for it in &s.items {
                    if !it.editable {
                        continue;
                    }
                    if let Some(t) = &it.text {
                        if !t.is_empty() {
                            out.push_str(&t.text().replace('\u{2028}', "\n"));
                            out.push('\n');
                        }
                    }
                    if let Some(tbl) = &it.table {
                        for r in &tbl.rows {
                            let cells: Vec<String> = r.cells.iter().map(|c| c.text.text()).collect();
                            out.push_str(&cells.join("\t"));
                            out.push('\n');
                        }
                    }
                }
            }
            if let Ok(n) = self.notes(i) {
                if !n.trim().is_empty() {
                    out.push_str("Notes: ");
                    out.push_str(&n);
                    out.push('\n');
                }
            }
            out.push('\n');
        }
        out
    }

    pub fn save(&mut self) -> Result<Vec<u8>, SlideError> {
        self.backend.save()
    }

    pub fn saved(&mut self) {
        self.dirty = false;
    }
}
