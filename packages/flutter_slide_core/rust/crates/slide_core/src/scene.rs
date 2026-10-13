//! What a slide looks like, ready to draw: shapes with their outlines as
//! paths, fills, lines, laid-out-ready text, pictures and tables, all in
//! points on the slide. The app paints scenes; the PDF writer can draw the
//! same ones.

/// A colour, `0xAARRGGBB`.
pub type Argb = u32;

/// One drawing command, in the item's own box (0..w, 0..h), points.
#[derive(Clone, Debug, PartialEq)]
pub enum Cmd {
    Move(f32, f32),
    Line(f32, f32),
    Cubic(f32, f32, f32, f32, f32, f32),
    Close,
}

/// One path of a shape's outline.
#[derive(Clone, Debug, PartialEq)]
pub struct Path {
    pub cmds: Vec<Cmd>,
    /// Whether this path is filled (some paths of a preset are only
    /// stroked, some only filled).
    pub fill: bool,
    pub stroke: bool,
    /// Fill darkening of this path (`darken`, `lighten`...), for 3-D looking
    /// presets.
    pub shade: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Fill {
    None,
    Solid(Argb),
    /// Stops (position 0..1, colour); angle in degrees; radial for path
    /// gradients.
    Gradient { stops: Vec<(f32, Argb)>, angle: f32, radial: bool },
    /// A picture of the package (part name), stretched over the shape.
    Image { part: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    /// Points.
    pub width: f32,
    pub color: Argb,
    /// `solid`, `dash`, `dot`, `dashDot`, `lgDash`, `sysDash`, `sysDot`...
    pub dash: String,
    /// Arrowheads: `triangle`, `arrow`, `stealth`, `diamond`, `oval`.
    pub head: Option<String>,
    pub tail: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Run {
    pub text: String,
    /// Points.
    pub size: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub color: Argb,
    pub font: String,
    /// Percent up (superscript, positive) or down.
    pub baseline: i32,
    pub highlight: Option<Argb>,
    pub link: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Bullet {
    pub text: String,
    pub color: Argb,
    pub font: String,
    /// Points.
    pub size: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Para {
    /// `l`, `ctr`, `r`, `just`, `dist`.
    pub align: String,
    pub level: u8,
    /// Left margin and first-line indent, points.
    pub margin_left: f32,
    pub indent: f32,
    pub space_before: f32,
    pub space_after: f32,
    /// A multiple of single spacing, or exact points when `line_points`.
    pub line: f32,
    pub line_points: bool,
    pub bullet: Option<Bullet>,
    pub runs: Vec<Run>,
    /// Size of the paragraph mark, for the height of empty paragraphs.
    pub end_size: f32,
}

impl Para {
    pub fn text(&self) -> String {
        self.runs.iter().map(|r| r.text.as_str()).collect()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TextBox {
    /// Insets: left, top, right, bottom, points.
    pub insets: [f32; 4],
    /// `t`, `ctr`, `b`.
    pub anchor: String,
    pub wrap: bool,
    /// `vert`, `vert270`, `eaVert`... or None for horizontal.
    pub vertical: Option<String>,
    pub paras: Vec<Para>,
    /// What an empty placeholder shows while editing.
    pub prompt: Option<String>,
}

impl TextBox {
    pub fn text(&self) -> String {
        self.paras.iter().map(Para::text).collect::<Vec<_>>().join("\n")
    }

    pub fn is_empty(&self) -> bool {
        self.paras.iter().all(|p| p.runs.iter().all(|r| r.text.is_empty()))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cell {
    pub text: TextBox,
    pub fill: Fill,
    /// Borders: left, top, right, bottom.
    pub borders: [Option<Line>; 4],
    pub col_span: u32,
    pub row_span: u32,
    /// Covered by a merged cell.
    pub merged: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TableRow {
    /// Points.
    pub height: f32,
    pub cells: Vec<Cell>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Table {
    pub cols: Vec<f32>,
    pub rows: Vec<TableRow>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Shape,
    Picture,
    Table,
    Chart,
    Diagram,
    Other,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Shape => "shape",
            Kind::Picture => "picture",
            Kind::Table => "table",
            Kind::Chart => "chart",
            Kind::Diagram => "diagram",
            Kind::Other => "other",
        }
    }
}

/// One thing on a slide.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    /// The shape's id on its slide.
    pub id: u32,
    pub kind: Kind,
    pub name: String,
    /// The box on the slide, points, before rotation.
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// Degrees clockwise.
    pub rot: f32,
    pub flip_h: bool,
    pub flip_v: bool,
    pub paths: Vec<Path>,
    pub fill: Fill,
    pub line: Option<Line>,
    pub text: Option<TextBox>,
    /// A picture's part and crop (left, top, right, bottom fractions).
    pub image: Option<(String, [f32; 4])>,
    pub table: Option<Table>,
    /// `title`, `ctrTitle`, `subTitle`, `body`, `dt`, `ftr`, `sldNum`...
    pub placeholder: Option<String>,
    /// Whether its text can be edited here.
    pub editable: bool,
    /// Inside a group (moved and deleted with it).
    pub grouped: bool,
}

/// A slide, ready to draw.
#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    /// Points.
    pub width: f32,
    pub height: f32,
    pub background: Fill,
    pub items: Vec<Item>,
    pub hidden: bool,
}
