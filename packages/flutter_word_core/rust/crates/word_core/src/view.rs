//! What the screen sees of a document, whatever its file format:
//! paragraphs of styled text and objects, tables, and the edits that come
//! back.

/// Effective character formatting.
#[derive(Clone, Debug, PartialEq)]
pub struct RunStyle {
    pub bold: bool,
    pub italic: bool,
    /// `none`, `single`, `double`, `thick`, `dotted`, `dash`, `wave`, `words`...
    pub underline: String,
    pub strike: bool,
    /// Points.
    pub size: f32,
    /// `0xRRGGBB`; None for automatic.
    pub color: Option<u32>,
    /// Highlight or shading behind the text.
    pub highlight: Option<u32>,
    pub font: String,
    /// `super` or `sub`.
    pub vert: Option<String>,
    pub caps: bool,
    pub small_caps: bool,
    pub hidden: bool,
}

impl Default for RunStyle {
    fn default() -> Self {
        RunStyle {
            bold: false,
            italic: false,
            underline: "none".into(),
            strike: false,
            size: 11.0,
            color: None,
            highlight: None,
            font: "Calibri".into(),
            vert: None,
            caps: false,
            small_caps: false,
            hidden: false,
        }
    }
}

/// Paragraph alignment.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Align {
    #[default]
    Left,
    Center,
    Right,
    Justify,
}

impl Align {
    pub fn name(self) -> &'static str {
        match self {
            Align::Left => "left",
            Align::Center => "center",
            Align::Right => "right",
            Align::Justify => "justify",
        }
    }

    pub fn parse(s: &str) -> Align {
        match s {
            "center" => Align::Center,
            "right" | "end" => Align::Right,
            "justify" | "both" | "distribute" => Align::Justify,
            _ => Align::Left,
        }
    }
}

/// Line spacing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LineSpacing {
    /// A multiple of single spacing.
    Multiple(f32),
    Exactly(f32),
    AtLeast(f32),
}

/// Effective paragraph formatting. Lengths in points.
#[derive(Clone, Debug, PartialEq)]
pub struct ParaStyle {
    pub style_id: String,
    pub style_name: String,
    pub align: Align,
    pub indent_left: f32,
    pub indent_right: f32,
    /// First-line indent; negative for a hanging indent.
    pub first_line: f32,
    pub space_before: f32,
    pub space_after: f32,
    pub line: LineSpacing,
    pub keep_next: bool,
    pub page_break_before: bool,
    /// 0 for Heading 1 ... 8; None for body text.
    pub outline_level: Option<u8>,
    pub shading: Option<u32>,
    /// The paragraph mark's character formatting (for empty paragraphs).
    pub mark: RunStyle,
    /// Right-to-left.
    pub bidi: bool,
    /// The style a new paragraph typed after this one gets, when another.
    pub next_style: Option<String>,
}

impl Default for ParaStyle {
    fn default() -> Self {
        ParaStyle {
            style_id: String::new(),
            style_name: "Normal".into(),
            align: Align::Left,
            indent_left: 0.0,
            indent_right: 0.0,
            first_line: 0.0,
            space_before: 0.0,
            space_after: 0.0,
            line: LineSpacing::Multiple(1.0),
            keep_next: false,
            page_break_before: false,
            outline_level: None,
            shading: None,
            mark: RunStyle::default(),
            bidi: false,
            next_style: None,
        }
    }
}

/// A list paragraph's label.
#[derive(Clone, Debug, PartialEq)]
pub struct ListLabel {
    pub level: u8,
    pub text: String,
    pub bullet: bool,
    /// The label's own font (bullets often use Symbol).
    pub style: RunStyle,
}

/// Kinds of non-text content inside a paragraph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObjectKind {
    Image,
    PageBreak,
    ColumnBreak,
    Field,
    Note,
    Equation,
    Shape,
    Control,
    Other,
}

impl ObjectKind {
    pub fn name(self) -> &'static str {
        match self {
            ObjectKind::Image => "image",
            ObjectKind::PageBreak => "pageBreak",
            ObjectKind::ColumnBreak => "columnBreak",
            ObjectKind::Field => "field",
            ObjectKind::Note => "note",
            ObjectKind::Equation => "equation",
            ObjectKind::Shape => "shape",
            ObjectKind::Control => "control",
            ObjectKind::Other => "other",
        }
    }
}

/// Something in a paragraph that is not plain text: kept as written and
/// moved as one piece.
#[derive(Clone, Debug, PartialEq)]
pub struct ObjectView {
    pub id: u32,
    pub kind: ObjectKind,
    /// What it shows as text (a field's result, a note's number).
    pub text: String,
    /// Size in points, for images and shapes.
    pub width: f32,
    pub height: f32,
    /// Text describing an image.
    pub alt: String,
    /// Formatting of its text.
    pub style: RunStyle,
}

/// Content of a paragraph.
#[derive(Clone, Debug, PartialEq)]
pub enum Inline {
    Text {
        text: String,
        style: RunStyle,
        link: Option<String>,
    },
    Object(ObjectView),
}

/// A paragraph as the screen shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct ParaView {
    pub id: u32,
    pub style: ParaStyle,
    pub list: Option<ListLabel>,
    pub inlines: Vec<Inline>,
    /// False when editing it here could lose something (tracked changes,
    /// a field spanning paragraphs).
    pub editable: bool,
    pub locked_reason: Option<String>,
}

impl ParaView {
    /// The paragraph's text (objects as their text).
    pub fn text(&self) -> String {
        let mut s = String::new();
        for i in &self.inlines {
            match i {
                Inline::Text { text, .. } => s.push_str(text),
                Inline::Object(o) => s.push_str(&o.text),
            }
        }
        s
    }
}

/// A table cell.
#[derive(Clone, Debug, PartialEq)]
pub struct CellView {
    pub blocks: Vec<BlockView>,
    pub col_span: u32,
    /// Continues the cell above (vertically merged).
    pub merged_up: bool,
    pub row_span: u32,
    pub fill: Option<u32>,
    /// Points.
    pub width: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RowView {
    pub cells: Vec<CellView>,
    pub header: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TableView {
    pub id: u32,
    pub rows: Vec<RowView>,
    /// Points.
    pub col_widths: Vec<f32>,
    pub borders: bool,
}

/// A block of the document body.
#[derive(Clone, Debug, PartialEq)]
pub enum BlockView {
    Para(ParaView),
    Table(TableView),
    /// Content this engine does not show; its text, if any.
    Other {
        id: u32,
        text: String,
    },
}

/// Content for a paragraph coming back from an edit.
#[derive(Clone, Debug, PartialEq)]
pub enum InlineEdit {
    Text {
        text: String,
        style: RunStyle,
        link: Option<String>,
    },
    /// An object of the document, by id.
    Object(u32),
}

/// What to change about paragraphs; only the set fields apply.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParaPatch {
    pub align: Option<Align>,
    /// A style id (`Heading1`, `Normal`, `Title`...).
    pub style_id: Option<String>,
    /// `none`, `bullet` or `number`.
    pub list: Option<String>,
    /// Change the list level (or indent) by this many steps.
    pub indent_steps: Option<i32>,
    pub space_before: Option<f32>,
    pub space_after: Option<f32>,
    pub line: Option<LineSpacing>,
    pub page_break_before: Option<bool>,
    pub keep_next: Option<bool>,
}

/// A document's page setup (the first section's).
#[derive(Clone, Debug, PartialEq)]
pub struct PageSetup {
    /// Points.
    pub width: f32,
    pub height: f32,
    pub margin_top: f32,
    pub margin_bottom: f32,
    pub margin_left: f32,
    pub margin_right: f32,
}

impl Default for PageSetup {
    /// A4 with 1-inch margins.
    fn default() -> Self {
        PageSetup {
            width: 595.3,
            height: 841.9,
            margin_top: 72.0,
            margin_bottom: 72.0,
            margin_left: 72.0,
            margin_right: 72.0,
        }
    }
}

/// Counts for the "word count" dialog.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub words: usize,
    pub characters: usize,
    pub characters_no_spaces: usize,
    pub paragraphs: usize,
}
