//! Files imported into a new Word document: RTF, plain text and Markdown.
//!
//! RTF cannot be edited in place the way a package can (every byte is
//! formatting), so it is imported: paragraphs, character and paragraph
//! formatting, styles with heading names, lists, tables, pictures and links
//! become a new `.docx`, which is what saving writes. Headers, footers,
//! notes and fields other than links are left out. Plain text becomes one
//! paragraph per line; Markdown's headings, lists, emphasis, code and links
//! become their Word equivalents.

use std::collections::HashMap;

use doc_encoding::Encoding;

use crate::docx::builtin;
use crate::error::WordError;

const MAX_DEPTH: usize = 512;

#[derive(Clone, Debug, PartialEq)]
struct Chars {
    bold: bool,
    italic: bool,
    underline: Option<&'static str>,
    strike: bool,
    /// Half-points.
    size: Option<i32>,
    color: Option<u32>,
    highlight: Option<u32>,
    font: Option<i32>,
    vert: Option<&'static str>,
    caps: bool,
    small_caps: bool,
    hidden: bool,
}

impl Default for Chars {
    fn default() -> Self {
        Chars {
            bold: false,
            italic: false,
            underline: None,
            strike: false,
            size: None,
            color: None,
            highlight: None,
            font: None,
            vert: None,
            caps: false,
            small_caps: false,
            hidden: false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
struct ParaProps {
    align: Option<&'static str>,
    left: i32,
    right: i32,
    first: i32,
    before: Option<i32>,
    after: Option<i32>,
    /// `\sl` and `\slmult`.
    line: Option<(i32, bool)>,
    keep_next: bool,
    page_before: bool,
    style: Option<i32>,
    list: Option<i32>,
    level: i32,
    in_table: bool,
    outline: Option<i32>,
}

#[derive(Clone, Debug)]
enum Run {
    Text(String, Chars, Option<String>),
    Image { bytes: Vec<u8>, ext: &'static str, width: i32, height: i32 },
    PageBreak,
}

#[derive(Clone, Debug, Default)]
struct Para {
    props: ParaProps,
    runs: Vec<Run>,
}

#[derive(Clone, Debug, Default)]
struct CellDef {
    right: i32,
    vmerge: Option<bool>,
    hmerge: Option<bool>,
    shading: Option<u32>,
    border: bool,
}

#[derive(Clone, Debug, Default)]
struct Row {
    cells: Vec<Vec<Para>>,
    defs: Vec<CellDef>,
    header: bool,
}

#[derive(Clone, Debug)]
enum Block {
    Para(Para),
    Table(Vec<Row>),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Dest {
    Text,
    Skip,
    FontTable,
    ColorTable,
    StyleSheet,
    Pict,
    FieldInst,
    FieldResult,
    ListTable,
    ListOverride,
    ListText,
}

#[derive(Clone, Debug)]
struct State {
    chars: Chars,
    dest: Dest,
    uc: usize,
    link: Option<String>,
}

struct Pict {
    kind: Option<&'static str>,
    width: i32,
    height: i32,
    goal_w: i32,
    goal_h: i32,
    scale_x: i32,
    scale_y: i32,
    hex: Vec<u8>,
}

/// What an RTF file holds, read.
struct Reader<'a> {
    src: &'a [u8],
    at: usize,
    stack: Vec<State>,
    state: State,
    para: ParaProps,
    encoding: Encoding,
    fonts: HashMap<i32, (String, Encoding)>,
    colors: Vec<Option<u32>>,
    color_parts: (Option<u8>, Option<u8>, Option<u8>),
    styles: HashMap<i32, String>,
    style_name: String,
    style_index: Option<i32>,
    /// List override index -> whether bullets.
    list_bullets: HashMap<i32, bool>,
    /// List id -> whether its first level is a bullet.
    list_defs: HashMap<i32, bool>,
    list_id: Option<i32>,
    list_level_nfc: Option<i32>,
    list_level_count: i32,
    override_list: Option<i32>,
    override_ls: Option<i32>,
    skip: usize,
    field_inst: String,
    pict: Option<Pict>,
    blocks: Vec<Block>,
    current: Para,
    row: Row,
    cell: Vec<Para>,
    pending_defs: Vec<CellDef>,
    cell_def: CellDef,
    table: Vec<Row>,
    row_header: bool,
    /// Bytes of text waiting to be decoded together.
    bytes: Vec<u8>,
}

fn utf16_char(n: i32) -> Option<char> {
    let n = if n < 0 { n + 65536 } else { n } as u32;
    char::from_u32(n)
}

fn charset_code_page(charset: i32) -> Option<u32> {
    Some(match charset {
        0 => 1252,
        161 => 1253,
        162 => 1254,
        177 => 1255,
        178 => 1256,
        186 => 1257,
        204 => 1251,
        222 => 874,
        238 => 1250,
        163 => 1258,
        _ => return None,
    })
}

impl<'a> Reader<'a> {
    fn new(src: &'a [u8]) -> Reader<'a> {
        Reader {
            src,
            at: 0,
            stack: Vec::new(),
            state: State {
                chars: Chars::default(),
                dest: Dest::Text,
                uc: 1,
                link: None,
            },
            para: ParaProps::default(),
            encoding: Encoding::WINDOWS_1252,
            fonts: HashMap::new(),
            colors: Vec::new(),
            color_parts: (None, None, None),
            styles: HashMap::new(),
            style_name: String::new(),
            style_index: None,
            list_bullets: HashMap::new(),
            list_defs: HashMap::new(),
            list_id: None,
            list_level_nfc: None,
            list_level_count: 0,
            override_list: None,
            override_ls: None,
            skip: 0,
            field_inst: String::new(),
            pict: None,
            blocks: Vec::new(),
            current: Para::default(),
            row: Row::default(),
            cell: Vec::new(),
            pending_defs: Vec::new(),
            cell_def: CellDef::default(),
            table: Vec::new(),
            row_header: false,
            bytes: Vec::new(),
        }
    }

    fn text_encoding(&self) -> Encoding {
        self.state
            .chars
            .font
            .and_then(|f| self.fonts.get(&f))
            .map(|(_, e)| *e)
            .unwrap_or(self.encoding)
    }

    /// Decode pending bytes into the current destination.
    fn flush_bytes(&mut self) {
        if self.bytes.is_empty() {
            return;
        }
        let bytes = std::mem::take(&mut self.bytes);
        let text = self.text_encoding().decode(&bytes).text;
        self.put_text(&text);
    }

    fn put_byte(&mut self, b: u8) {
        if self.skip > 0 {
            self.skip -= 1;
            return;
        }
        self.bytes.push(b);
    }

    fn put_char(&mut self, c: char) {
        self.flush_bytes();
        let mut buf = [0u8; 4];
        self.put_text(c.encode_utf8(&mut buf));
    }

    fn put_text(&mut self, text: &str) {
        match self.state.dest {
            Dest::Text | Dest::FieldResult => {
                if self.state.chars.hidden && self.state.dest == Dest::Text && text.trim().is_empty() {
                    // Hidden spacing only.
                }
                let chars = self.state.chars.clone();
                let link = self.state.link.clone();
                let target = if self.para.in_table { self.cell_last_para() } else { &mut self.current };
                if let Some(Run::Text(t, c, l)) = target.runs.last_mut() {
                    if *c == chars && *l == link {
                        t.push_str(text);
                        return;
                    }
                }
                target.runs.push(Run::Text(text.to_owned(), chars, link));
            }
            Dest::FontTable | Dest::StyleSheet | Dest::ListTable => self.style_name.push_str(text),
            Dest::FieldInst => self.field_inst.push_str(text),
            Dest::Pict => {
                if let Some(p) = &mut self.pict {
                    p.hex.extend(text.bytes().filter(|b| b.is_ascii_hexdigit()));
                }
            }
            _ => {}
        }
    }

    /// The paragraph being written in the current table cell.
    fn cell_last_para(&mut self) -> &mut Para {
        &mut self.current
    }

    fn end_para(&mut self) {
        self.flush_bytes();
        let mut p = std::mem::take(&mut self.current);
        p.props = self.para.clone();
        if self.para.in_table {
            self.cell.push(p);
        } else {
            self.close_table();
            self.blocks.push(Block::Para(p));
        }
    }

    fn end_cell(&mut self) {
        self.flush_bytes();
        if !self.current.runs.is_empty() || self.cell.is_empty() {
            let mut p = std::mem::take(&mut self.current);
            p.props = self.para.clone();
            self.cell.push(p);
        }
        let cell = std::mem::take(&mut self.cell);
        self.row.cells.push(cell);
    }

    fn end_row(&mut self) {
        self.flush_bytes();
        if !self.cell.is_empty() || !self.current.runs.is_empty() {
            self.end_cell();
        }
        let mut row = std::mem::take(&mut self.row);
        row.defs = self.pending_defs.clone();
        row.header = self.row_header;
        if !row.cells.is_empty() {
            self.table.push(row);
        }
    }

    fn close_table(&mut self) {
        if !self.table.is_empty() {
            let t = std::mem::take(&mut self.table);
            self.blocks.push(Block::Table(t));
        }
    }

    fn color(&self, i: i32) -> Option<u32> {
        self.colors.get(i as usize).copied().flatten()
    }

    fn word(&mut self, name: &str, param: Option<i32>) {
        let p = param.unwrap_or(1);
        let on = param != Some(0);
        // Destinations first.
        match name {
            "fonttbl" => {
                self.state.dest = Dest::FontTable;
                return;
            }
            "colortbl" => {
                self.state.dest = Dest::ColorTable;
                self.colors.clear();
                return;
            }
            "stylesheet" => {
                self.state.dest = Dest::StyleSheet;
                return;
            }
            "listtable" => {
                self.state.dest = Dest::ListTable;
                return;
            }
            "listoverridetable" => {
                self.state.dest = Dest::ListOverride;
                return;
            }
            "info" | "header" | "headerl" | "headerr" | "headerf" | "footer" | "footerl" | "footerr" | "footerf" | "footnote" | "annotation" | "xe" | "tc"
            | "txe" | "rxe" | "bkmkstart" | "bkmkend" | "themedata" | "colorschememapping" | "latentstyles" | "datastore" | "xmlnstbl" | "rsidtbl"
            | "generator" | "pgdsctbl" | "objdata" | "nonshppict" | "listpicture" | "filetbl" | "revtbl" | "mmathPr" | "userprops" | "docvar" => {
                self.state.dest = Dest::Skip;
                return;
            }
            "pntext" | "listtext" => {
                self.state.dest = Dest::ListText;
                return;
            }
            "pict" => {
                self.state.dest = Dest::Pict;
                self.pict = Some(Pict {
                    kind: None,
                    width: 0,
                    height: 0,
                    goal_w: 0,
                    goal_h: 0,
                    scale_x: 100,
                    scale_y: 100,
                    hex: Vec::new(),
                });
                return;
            }
            "fldinst" => {
                self.state.dest = Dest::FieldInst;
                self.field_inst.clear();
                return;
            }
            "fldrslt" => {
                let inst = self.field_inst.trim().to_owned();
                self.state.dest = Dest::FieldResult;
                if let Some(rest) = inst.strip_prefix("HYPERLINK") {
                    let url = rest.trim().trim_start_matches("\\l").trim().trim_matches('"').to_owned();
                    let url = url.split('"').next().unwrap_or("").to_owned();
                    if !url.is_empty() {
                        self.state.link = Some(url);
                    }
                }
                return;
            }
            _ => {}
        }
        match self.state.dest {
            Dest::FontTable => {
                match name {
                    "f" => {
                        self.style_index = Some(p);
                        self.style_name.clear();
                    }
                    "fcharset" => {
                        if let (Some(i), Some(cp)) = (self.style_index, charset_code_page(p)) {
                            let enc = Encoding::from_code_page(cp).unwrap_or(Encoding::WINDOWS_1252);
                            self.fonts.entry(i).or_insert_with(|| (String::new(), enc)).1 = enc;
                        }
                    }
                    "cpg" => {
                        if let (Some(i), Some(enc)) = (self.style_index, Encoding::from_code_page(p as u32)) {
                            self.fonts.entry(i).or_insert_with(|| (String::new(), enc)).1 = enc;
                        }
                    }
                    _ => {}
                }
                return;
            }
            Dest::ColorTable => {
                match name {
                    "red" => self.color_parts.0 = Some(p as u8),
                    "green" => self.color_parts.1 = Some(p as u8),
                    "blue" => self.color_parts.2 = Some(p as u8),
                    _ => {}
                }
                return;
            }
            Dest::StyleSheet => {
                if matches!(name, "s" | "cs" | "ds" | "ts") {
                    self.style_index = if name == "s" { Some(p) } else { None };
                    self.style_name.clear();
                }
                return;
            }
            Dest::ListTable => {
                match name {
                    "list" => {
                        self.list_id = None;
                        self.list_level_count = 0;
                        self.list_level_nfc = None;
                    }
                    "listlevel" => self.list_level_count += 1,
                    "levelnfc" | "levelnfcn" if self.list_level_count == 1 => self.list_level_nfc = Some(p),
                    "listid" => {
                        self.list_id = Some(p);
                        if let Some(nfc) = self.list_level_nfc {
                            self.list_defs.insert(p, nfc == 23 || nfc == 255);
                        }
                    }
                    _ => {}
                }
                return;
            }
            Dest::ListOverride => {
                match name {
                    "listoverride" => {
                        self.override_list = None;
                        self.override_ls = None;
                    }
                    "listid" => self.override_list = Some(p),
                    "ls" => self.override_ls = Some(p),
                    _ => {}
                }
                if let (Some(l), Some(ls)) = (self.override_list, self.override_ls) {
                    let bullet = self.list_defs.get(&l).copied().unwrap_or(true);
                    self.list_bullets.insert(ls, bullet);
                }
                return;
            }
            Dest::Pict => {
                if let Some(pict) = &mut self.pict {
                    match name {
                        "pngblip" => pict.kind = Some("png"),
                        "jpegblip" => pict.kind = Some("jpeg"),
                        "emfblip" => pict.kind = Some("emf"),
                        "wmetafile" => pict.kind = Some("wmf"),
                        "picw" => pict.width = p,
                        "pich" => pict.height = p,
                        "picwgoal" => pict.goal_w = p,
                        "pichgoal" => pict.goal_h = p,
                        "picscalex" => pict.scale_x = p,
                        "picscaley" => pict.scale_y = p,
                        "bin" => {
                            // Raw bytes follow; take them as they are.
                            let n = (p.max(0) as usize).min(self.src.len() - self.at);
                            let raw = &self.src[self.at..self.at + n];
                            for b in raw {
                                pict.hex.extend(format!("{b:02x}").bytes());
                            }
                            self.at += n;
                        }
                        _ => {}
                    }
                }
                return;
            }
            Dest::Skip | Dest::ListText | Dest::FieldInst => return,
            Dest::Text | Dest::FieldResult => {}
        }
        let c = &mut self.state.chars;
        match name {
            "ansicpg" => {
                if let Some(e) = Encoding::from_code_page(p as u32) {
                    self.encoding = e;
                }
            }
            "uc" => self.state.uc = p.max(0) as usize,
            "u" => {
                self.flush_bytes();
                if let Some(ch) = param.and_then(utf16_char) {
                    self.put_char(ch);
                }
                self.skip = self.state.uc;
            }
            "par" | "sect" => self.end_para(),
            "line" => self.put_char('\n'),
            "tab" => self.put_char('\t'),
            "page" => {
                self.flush_bytes();
                self.current.runs.push(Run::PageBreak);
            }
            "pard" => {
                let in_table = false;
                self.para = ParaProps { in_table, ..ParaProps::default() };
            }
            "plain" => *c = Chars::default(),
            "b" => c.bold = on,
            "i" => c.italic = on,
            "ul" => c.underline = if on { Some("single") } else { None },
            "uld" => c.underline = Some("dotted"),
            "uldash" => c.underline = Some("dash"),
            "uldb" => c.underline = Some("double"),
            "ulw" => c.underline = Some("words"),
            "ulwave" => c.underline = Some("wave"),
            "ulth" => c.underline = Some("thick"),
            "ulnone" => c.underline = None,
            "strike" | "striked" => c.strike = on,
            "fs" => c.size = Some(p),
            "cf" => c.color = if p == 0 { None } else { self.colors.get(p as usize).copied().flatten() },
            "highlight" | "cb" | "chcbpat" => c.highlight = if p == 0 { None } else { self.colors.get(p as usize).copied().flatten() },
            "f" => {
                self.flush_bytes();
                self.state.chars.font = Some(p);
            }
            "super" => c.vert = Some("superscript"),
            "sub" => c.vert = Some("subscript"),
            "nosupersub" => c.vert = None,
            "caps" => c.caps = on,
            "scaps" => c.small_caps = on,
            "v" => c.hidden = on,
            "ql" => self.para.align = Some("left"),
            "qc" => self.para.align = Some("center"),
            "qr" => self.para.align = Some("right"),
            "qj" | "qd" => self.para.align = Some("both"),
            "li" | "lin" => self.para.left = p,
            "ri" | "rin" => self.para.right = p,
            "fi" => self.para.first = p,
            "sb" => self.para.before = Some(p),
            "sa" => self.para.after = Some(p),
            "sl" => self.para.line = Some((p, false)),
            "slmult" => {
                if let Some((v, _)) = self.para.line {
                    self.para.line = Some((v, p == 1));
                }
            }
            "keepn" => self.para.keep_next = on,
            "pagebb" => self.para.page_before = on,
            "s" => self.para.style = Some(p),
            "outlinelevel" => self.para.outline = Some(p),
            "ls" => self.para.list = Some(p),
            "ilvl" => self.para.level = p,
            "intbl" => self.para.in_table = true,
            "cell" | "nestcell" => self.end_cell(),
            "row" | "nestrow" => self.end_row(),
            "trowd" => {
                self.pending_defs.clear();
                self.cell_def = CellDef::default();
                self.row_header = false;
            }
            "trhdr" => self.row_header = true,
            "cellx" => {
                let mut d = std::mem::take(&mut self.cell_def);
                d.right = p;
                self.pending_defs.push(d);
            }
            "clvmgf" => self.cell_def.vmerge = Some(true),
            "clvmrg" => self.cell_def.vmerge = Some(false),
            "clmgf" => self.cell_def.hmerge = Some(true),
            "clmrg" => self.cell_def.hmerge = Some(false),
            "clcbpat" => self.cell_def.shading = self.color(p),
            "clbrdrt" | "clbrdrb" | "clbrdrl" | "clbrdrr" => self.cell_def.border = true,
            "bullet" => self.put_char('\u{2022}'),
            "endash" => self.put_char('\u{2013}'),
            "emdash" => self.put_char('\u{2014}'),
            "lquote" => self.put_char('\u{2018}'),
            "rquote" => self.put_char('\u{2019}'),
            "ldblquote" => self.put_char('\u{201C}'),
            "rdblquote" => self.put_char('\u{201D}'),
            "enspace" | "emspace" | "qmspace" => self.put_char(' '),
            "zwj" => self.put_char('\u{200D}'),
            "zwnj" => self.put_char('\u{200C}'),
            _ => {}
        }
    }

    fn symbol(&mut self, c: u8) {
        match c {
            b'\\' | b'{' | b'}' => self.put_byte(c),
            b'~' => self.put_char('\u{A0}'),
            b'_' => self.put_char('\u{2011}'),
            b'-' => self.put_char('\u{AD}'),
            b'\n' | b'\r' => {
                if self.state.dest == Dest::Text {
                    self.end_para();
                }
            }
            b'\t' => self.put_char('\t'),
            b'*' => {
                // An optional destination: skipped unless known.
                self.state.dest = match self.state.dest {
                    Dest::Text | Dest::FieldResult => Dest::Skip,
                    d => d,
                };
                self.peek_known_destination();
            }
            _ => {}
        }
    }

    /// After `\*`, a few optional destinations are worth reading.
    fn peek_known_destination(&mut self) {
        let rest = &self.src[self.at..];
        let rest = rest.strip_prefix(b" ").unwrap_or(rest);
        for (name, dest) in [
            (&b"\\fldinst"[..], Dest::FieldInst),
            (b"\\listtable", Dest::ListTable),
            (b"\\listoverridetable", Dest::ListOverride),
        ] {
            if rest.starts_with(name) {
                self.state.dest = dest;
            }
        }
    }

    fn end_group(&mut self) {
        self.flush_bytes();
        let ending = self.state.dest;
        match ending {
            Dest::FontTable => {
                if let Some(i) = self.style_index.take() {
                    let name = self.style_name.trim().trim_end_matches(';').trim().to_owned();
                    if !name.is_empty() {
                        let enc = self.fonts.get(&i).map(|(_, e)| *e).unwrap_or(self.encoding);
                        self.fonts.insert(i, (name, enc));
                    }
                    self.style_name.clear();
                }
            }
            Dest::StyleSheet => {
                if let Some(i) = self.style_index.take() {
                    let name = self.style_name.trim().trim_end_matches(';').trim().to_owned();
                    self.styles.insert(i, name);
                    self.style_name.clear();
                }
            }
            Dest::Pict => {
                let parent = self.stack.last().map(|s| s.dest);
                if parent != Some(Dest::Pict) {
                    if let Some(p) = self.pict.take() {
                        self.finish_pict(p);
                    }
                }
            }
            _ => {}
        }
        if let Some(s) = self.stack.pop() {
            // Inside the font table each font is its own group.
            if s.dest == Dest::FontTable && ending == Dest::FontTable {
                if let Some(i) = self.style_index.take() {
                    let name = self.style_name.trim().trim_end_matches(';').trim().to_owned();
                    let enc = self.fonts.get(&i).map(|(_, e)| *e).unwrap_or(self.encoding);
                    if !name.is_empty() {
                        self.fonts.insert(i, (name, enc));
                    }
                    self.style_name.clear();
                }
            }
            self.state = s;
        }
    }

    fn finish_pict(&mut self, p: Pict) {
        let Some(ext) = p.kind else { return };
        if ext != "png" && ext != "jpeg" {
            return;
        }
        let bytes: Vec<u8> = p
            .hex
            .chunks(2)
            .filter(|c| c.len() == 2)
            .filter_map(|c| u8::from_str_radix(std::str::from_utf8(c).ok()?, 16).ok())
            .collect();
        if bytes.is_empty() {
            return;
        }
        // Twips; picw/pich are pixels (or hundredths of a millimetre).
        let mut w = if p.goal_w > 0 { p.goal_w } else { p.width * 15 };
        let mut h = if p.goal_h > 0 { p.goal_h } else { p.height * 15 };
        w = w * p.scale_x.max(1) / 100;
        h = h * p.scale_y.max(1) / 100;
        let run = Run::Image {
            bytes,
            ext,
            width: w.max(20),
            height: h.max(20),
        };
        self.current.runs.push(run);
    }

    fn read(&mut self) -> Result<(), WordError> {
        while self.at < self.src.len() {
            let b = self.src[self.at];
            self.at += 1;
            match b {
                b'{' => {
                    self.flush_bytes();
                    if self.stack.len() >= MAX_DEPTH {
                        return Err(WordError::Corrupt("This RTF file nests too deeply.".into()));
                    }
                    self.stack.push(self.state.clone());
                    if self.state.dest == Dest::ColorTable {
                        // Unusual, but stay in the table.
                    }
                }
                b'}' => self.end_group(),
                b'\\' => {
                    let Some(&c) = self.src.get(self.at) else { break };
                    if c.is_ascii_alphabetic() {
                        let start = self.at;
                        while self.at < self.src.len() && self.src[self.at].is_ascii_alphabetic() && self.at - start < 32 {
                            self.at += 1;
                        }
                        let name = std::str::from_utf8(&self.src[start..self.at]).unwrap_or("").to_owned();
                        let mut param = None;
                        let neg = self.src.get(self.at) == Some(&b'-');
                        let num_start = if neg { self.at + 1 } else { self.at };
                        let mut end = num_start;
                        while end < self.src.len() && self.src[end].is_ascii_digit() && end - num_start < 10 {
                            end += 1;
                        }
                        if end > num_start {
                            let v: i64 = std::str::from_utf8(&self.src[num_start..end]).unwrap().parse().unwrap_or(0);
                            let v = v.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                            param = Some(if neg { -v } else { v });
                            self.at = end;
                        }
                        if self.src.get(self.at) == Some(&b' ') {
                            self.at += 1;
                        }
                        if name != "u" && name != "bin" {
                            self.flush_bytes();
                        }
                        self.word(&name, param);
                    } else if c == b'\'' {
                        let hex = self.src.get(self.at + 1..self.at + 3).and_then(|h| std::str::from_utf8(h).ok()).and_then(|h| u8::from_str_radix(h, 16).ok());
                        self.at += 3;
                        if let Some(v) = hex {
                            if self.state.dest == Dest::Pict {
                                continue;
                            }
                            self.put_byte(v);
                        }
                    } else {
                        self.at += 1;
                        self.flush_bytes();
                        self.symbol(c);
                    }
                }
                b'\r' | b'\n' => {}
                b';' if self.state.dest == Dest::ColorTable => {
                    let (r, g, bl) = self.color_parts;
                    let c = match (r, g, bl) {
                        (None, None, None) => None,
                        _ => Some(((r.unwrap_or(0) as u32) << 16) | ((g.unwrap_or(0) as u32) << 8) | bl.unwrap_or(0) as u32),
                    };
                    self.colors.push(c);
                    self.color_parts = (None, None, None);
                }
                _ => self.put_byte(b),
            }
        }
        self.flush_bytes();
        if !self.current.runs.is_empty() {
            self.end_para();
        }
        if !self.row.cells.is_empty() {
            self.end_row();
        }
        self.close_table();
        Ok(())
    }
}

// --- Writing the Word document

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

/// Word's built-in style id for an RTF style name, if one.
fn style_id(name: &str) -> Option<&'static str> {
    let l = name.to_ascii_lowercase();
    Some(match l.as_str() {
        "heading 1" => "Heading1",
        "heading 2" => "Heading2",
        "heading 3" => "Heading3",
        "title" => "Title",
        "subtitle" => "Subtitle",
        "quote" => "Quote",
        "list paragraph" => "ListParagraph",
        _ => return None,
    })
}

struct Writer {
    xml: String,
    rels: Vec<(String, String, String)>,
    media: Vec<(String, Vec<u8>)>,
    styles_used: Vec<&'static str>,
    lists: HashMap<i32, String>,
    list_kinds: Vec<(String, bool)>,
    fonts: HashMap<i32, (String, Encoding)>,
    style_names: HashMap<i32, String>,
    list_bullets: HashMap<i32, bool>,
    links: HashMap<String, String>,
    pic: u32,
}

impl Writer {
    fn rel(&mut self, kind: &str, target: &str, external: bool) -> String {
        let id = format!("rIdR{}", self.rels.len() + 1);
        let mode = if external { r#" TargetMode="External""# } else { "" };
        self.rels.push((id.clone(), kind.to_owned(), format!("{}\"{}", esc_attr(target), mode)));
        id
    }

    fn rpr(&self, c: &Chars) -> String {
        let mut s = String::new();
        if let Some(f) = c.font.and_then(|f| self.fonts.get(&f)).map(|(n, _)| n.clone()).filter(|n| !n.is_empty()) {
            let f = esc_attr(&f);
            s.push_str(&format!(r#"<w:rFonts w:ascii="{f}" w:hAnsi="{f}" w:cs="{f}"/>"#));
        }
        if c.bold {
            s.push_str("<w:b/><w:bCs/>");
        }
        if c.italic {
            s.push_str("<w:i/><w:iCs/>");
        }
        if c.caps {
            s.push_str("<w:caps/>");
        }
        if c.small_caps {
            s.push_str("<w:smallCaps/>");
        }
        if c.strike {
            s.push_str("<w:strike/>");
        }
        if c.hidden {
            s.push_str("<w:vanish/>");
        }
        if let Some(col) = c.color {
            s.push_str(&format!(r#"<w:color w:val="{col:06X}"/>"#));
        }
        if let Some(sz) = c.size {
            s.push_str(&format!(r#"<w:sz w:val="{sz}"/><w:szCs w:val="{sz}"/>"#));
        }
        if let Some(h) = c.highlight {
            s.push_str(&format!(r#"<w:shd w:val="clear" w:color="auto" w:fill="{h:06X}"/>"#));
        }
        if let Some(u) = c.underline {
            s.push_str(&format!(r#"<w:u w:val="{u}"/>"#));
        }
        if let Some(v) = c.vert {
            s.push_str(&format!(r#"<w:vertAlign w:val="{v}"/>"#));
        }
        if s.is_empty() {
            s
        } else {
            format!("<w:rPr>{s}</w:rPr>")
        }
    }

    fn text_runs(&self, text: &str, rpr: &str) -> String {
        let mut out = String::new();
        let mut buf = String::new();
        let flush = |buf: &mut String, out: &mut String| {
            if !buf.is_empty() {
                out.push_str(&format!(r#"<w:t xml:space="preserve">{}</w:t>"#, esc(buf)));
                buf.clear();
            }
        };
        for c in text.chars() {
            match c {
                '\t' => {
                    flush(&mut buf, &mut out);
                    out.push_str("<w:tab/>");
                }
                '\n' => {
                    flush(&mut buf, &mut out);
                    out.push_str("<w:br/>");
                }
                '\u{AD}' => {
                    flush(&mut buf, &mut out);
                    out.push_str("<w:softHyphen/>");
                }
                '\u{2011}' => {
                    flush(&mut buf, &mut out);
                    out.push_str("<w:noBreakHyphen/>");
                }
                c if (c as u32) < 0x20 => {}
                c => buf.push(c),
            }
        }
        flush(&mut buf, &mut out);
        format!("<w:r>{rpr}{out}</w:r>")
    }

    fn para(&mut self, p: &Para) {
        let pp = &p.props;
        let mut ppr = String::new();
        let style = pp.style.and_then(|s| self.style_names.get(&s)).and_then(|n| style_id(n)).or_else(|| match pp.outline {
            Some(0) => Some("Heading1"),
            Some(1) => Some("Heading2"),
            Some(2) => Some("Heading3"),
            _ => None,
        });
        if let Some(s) = style {
            if !self.styles_used.contains(&s) {
                self.styles_used.push(s);
            }
            ppr.push_str(&format!(r#"<w:pStyle w:val="{s}"/>"#));
        }
        if pp.keep_next {
            ppr.push_str("<w:keepNext/>");
        }
        if pp.page_before {
            ppr.push_str("<w:pageBreakBefore/>");
        }
        if let Some(ls) = pp.list {
            let num = match self.lists.get(&ls) {
                Some(n) => n.clone(),
                None => {
                    let n = (self.lists.len() + 1).to_string();
                    let bullet = self.list_bullets.get(&ls).copied().unwrap_or(true);
                    self.lists.insert(ls, n.clone());
                    self.list_kinds.push((n.clone(), bullet));
                    n
                }
            };
            ppr.push_str(&format!(r#"<w:numPr><w:ilvl w:val="{}"/><w:numId w:val="{num}"/></w:numPr>"#, pp.level.clamp(0, 8)));
        }
        let mut spacing = String::new();
        if let Some(b) = pp.before {
            spacing.push_str(&format!(r#" w:before="{b}""#));
        }
        if let Some(a) = pp.after {
            spacing.push_str(&format!(r#" w:after="{a}""#));
        }
        if let Some((v, mult)) = pp.line {
            if v != 0 {
                if mult {
                    spacing.push_str(&format!(r#" w:line="{}" w:lineRule="auto""#, v.abs()));
                } else if v < 0 {
                    spacing.push_str(&format!(r#" w:line="{}" w:lineRule="exact""#, -v));
                } else {
                    spacing.push_str(&format!(r#" w:line="{v}" w:lineRule="atLeast""#));
                }
            }
        }
        if !spacing.is_empty() {
            ppr.push_str(&format!("<w:spacing{spacing}/>"));
        }
        if pp.left != 0 || pp.right != 0 || pp.first != 0 {
            let first = if pp.first < 0 { format!(r#" w:hanging="{}""#, -pp.first) } else { format!(r#" w:firstLine="{}""#, pp.first) };
            ppr.push_str(&format!(r#"<w:ind w:left="{}" w:right="{}"{first}/>"#, pp.left, pp.right));
        }
        if let Some(a) = pp.align {
            ppr.push_str(&format!(r#"<w:jc w:val="{a}"/>"#));
        }
        self.xml.push_str("<w:p>");
        if !ppr.is_empty() {
            self.xml.push_str(&format!("<w:pPr>{ppr}</w:pPr>"));
        }
        let mut open_link: Option<String> = None;
        for run in &p.runs {
            let link = match run {
                Run::Text(_, _, l) => l.clone(),
                _ => None,
            };
            if open_link != link {
                if open_link.is_some() {
                    self.xml.push_str("</w:hyperlink>");
                }
                if let Some(url) = &link {
                    let id = match self.links.get(url) {
                        Some(i) => i.clone(),
                        None => {
                            let i = self.rel("hyperlink", url, true);
                            self.links.insert(url.clone(), i.clone());
                            i
                        }
                    };
                    self.xml.push_str(&format!(r#"<w:hyperlink r:id="{id}" w:history="1">"#));
                }
                open_link = link;
            }
            match run {
                Run::Text(t, c, _) => {
                    let rpr = self.rpr(c);
                    let r = self.text_runs(t, &rpr);
                    self.xml.push_str(&r);
                }
                Run::PageBreak => self.xml.push_str(r#"<w:r><w:br w:type="page"/></w:r>"#),
                Run::Image { bytes, ext, width, height } => {
                    self.pic += 1;
                    let n = self.pic;
                    let name = format!("media/rtf_image{n}.{ext}");
                    self.media.push((format!("word/{name}"), bytes.clone()));
                    let rid = self.rel("image", &name, false);
                    let cx = *width as i64 * 635;
                    let cy = *height as i64 * 635;
                    self.xml.push_str(&format!(
                        r#"<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/><wp:docPr id="{n}" name="Picture {n}"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="{n}" name="image{n}.{ext}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"#
                    ));
                }
            }
        }
        if open_link.is_some() {
            self.xml.push_str("</w:hyperlink>");
        }
        self.xml.push_str("</w:p>");
    }

    fn table(&mut self, rows: &[Row]) {
        // The grid: every distinct right edge.
        let mut edges: Vec<i32> = rows.iter().flat_map(|r| r.defs.iter().map(|d| d.right)).filter(|e| *e > 0).collect();
        edges.sort_unstable();
        edges.dedup();
        let borders = rows.iter().any(|r| r.defs.iter().any(|d| d.border));
        self.xml.push_str("<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>");
        if borders {
            self.xml.push_str(r#"<w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders>"#);
        }
        self.xml.push_str("<w:tblLook w:val=\"04A0\"/></w:tblPr><w:tblGrid>");
        let mut prev = 0;
        let min_left = rows.iter().filter_map(|r| r.defs.first()).map(|d| d.right).min().unwrap_or(0);
        let _ = min_left;
        for e in &edges {
            self.xml.push_str(&format!(r#"<w:gridCol w:w="{}"/>"#, (e - prev).max(1)));
            prev = *e;
        }
        if edges.is_empty() {
            let cols = rows.iter().map(|r| r.cells.len()).max().unwrap_or(1);
            for _ in 0..cols {
                self.xml.push_str(r#"<w:gridCol w:w="2000"/>"#);
            }
        }
        self.xml.push_str("</w:tblGrid>");
        for row in rows {
            self.xml.push_str("<w:tr>");
            if row.header {
                self.xml.push_str("<w:trPr><w:tblHeader/></w:trPr>");
            }
            let mut left = 0;
            let mut k = 0;
            while k < row.cells.len() {
                let def = row.defs.get(k).cloned().unwrap_or_default();
                // Horizontally merged cells widen the first.
                let mut last = k;
                while def.hmerge == Some(true) && row.defs.get(last + 1).is_some_and(|d| d.hmerge == Some(false)) {
                    last += 1;
                }
                let right = row.defs.get(last).map_or(left + 2000, |d| d.right);
                let span = edges.iter().filter(|e| **e > left && **e <= right).count().max(1);
                self.xml.push_str("<w:tc><w:tcPr>");
                self.xml.push_str(&format!(r#"<w:tcW w:w="{}" w:type="dxa"/>"#, (right - left).max(1)));
                if span > 1 {
                    self.xml.push_str(&format!(r#"<w:gridSpan w:val="{span}"/>"#));
                }
                match def.vmerge {
                    Some(true) => self.xml.push_str(r#"<w:vMerge w:val="restart"/>"#),
                    Some(false) => self.xml.push_str("<w:vMerge/>"),
                    None => {}
                }
                if let Some(s) = def.shading {
                    self.xml.push_str(&format!(r#"<w:shd w:val="clear" w:color="auto" w:fill="{s:06X}"/>"#));
                }
                self.xml.push_str("</w:tcPr>");
                let paras = &row.cells[k];
                if paras.is_empty() {
                    self.xml.push_str("<w:p/>");
                }
                for p in paras {
                    let mut p = p.clone();
                    p.props.in_table = false;
                    self.para(&p);
                }
                self.xml.push_str("</w:tc>");
                left = right;
                k = last + 1;
            }
            self.xml.push_str("</w:tr>");
        }
        self.xml.push_str("</w:tbl>");
    }
}

fn writer(fonts: HashMap<i32, (String, Encoding)>, styles: HashMap<i32, String>, list_bullets: HashMap<i32, bool>) -> Writer {
    Writer {
        xml: String::new(),
        rels: Vec::new(),
        media: Vec::new(),
        styles_used: Vec::new(),
        lists: HashMap::new(),
        list_kinds: Vec::new(),
        fonts,
        style_names: styles,
        list_bullets,
        links: HashMap::new(),
        pic: 0,
    }
}

fn write_blocks(mut w: Writer, blocks: &[Block]) -> Result<Vec<u8>, WordError> {
    for b in blocks {
        match b {
            Block::Para(p) => w.para(p),
            Block::Table(rows) => w.table(rows),
        }
    }
    if blocks.is_empty() || matches!(blocks.last(), Some(Block::Table(_))) {
        w.xml.push_str("<w:p/>");
    }
    build_package(w)
}

/// Read an RTF file into the bytes of an equivalent Word document.
pub fn rtf_to_docx(bytes: &[u8]) -> Result<Vec<u8>, WordError> {
    if !bytes.starts_with(b"{\\rtf") && !bytes.get(3..).is_some_and(|b| b.starts_with(b"{\\rtf")) {
        return Err(WordError::Corrupt("This is not an RTF document.".into()));
    }
    let src = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF][..]).unwrap_or(bytes);
    let mut r = Reader::new(src);
    r.read()?;
    let Reader {
        blocks,
        fonts,
        styles,
        list_bullets,
        ..
    } = r;
    write_blocks(writer(fonts, styles, list_bullets), &blocks)
}

/// Plain text or Markdown as the bytes of a Word document.
pub fn text_to_docx(text: &str, markdown: bool) -> Result<Vec<u8>, WordError> {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut fonts = HashMap::new();
    fonts.insert(1, ("Courier New".to_owned(), Encoding::WINDOWS_1252));
    let mut styles = HashMap::new();
    styles.insert(100, "Quote".to_owned());
    let mut bullets = HashMap::new();
    bullets.insert(1, true);
    bullets.insert(2, false);
    let blocks = if markdown { markdown_blocks(&text) } else { plain_blocks(&text) };
    write_blocks(writer(fonts, styles, bullets), &blocks)
}

fn text_para(text: &str, chars: &Chars) -> Para {
    Para {
        props: ParaProps::default(),
        runs: if text.is_empty() { Vec::new() } else { vec![Run::Text(text.to_owned(), chars.clone(), None)] },
    }
}

fn plain_blocks(text: &str) -> Vec<Block> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines.iter().map(|l| Block::Para(text_para(l, &Chars::default()))).collect()
}

/// Markdown's inline marks: emphasis, strong, strike, code and links.
fn inline_runs(text: &str, base: &Chars) -> Vec<Run> {
    let chars: Vec<char> = text.chars().collect();
    let mut runs: Vec<Run> = Vec::new();
    let mut cur = base.clone();
    let mut buf = String::new();
    let push = |runs: &mut Vec<Run>, buf: &mut String, c: &Chars, link: Option<String>| {
        if buf.is_empty() {
            return;
        }
        if let Some(Run::Text(t, rc, l)) = runs.last_mut() {
            if rc == c && *l == link {
                t.push_str(buf);
                buf.clear();
                return;
            }
        }
        runs.push(Run::Text(std::mem::take(buf), c.clone(), link));
    };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        match c {
            '\\' if next.is_some_and(|n| n.is_ascii_punctuation()) => {
                buf.push(next.unwrap());
                i += 2;
                continue;
            }
            '*' | '_' if next == Some(c) => {
                push(&mut runs, &mut buf, &cur, None);
                cur.bold = !cur.bold;
                i += 2;
                continue;
            }
            '*' | '_' => {
                // An underscore inside a word is just a letter.
                let in_word = c == '_' && i > 0 && chars[i - 1].is_alphanumeric() && next.is_some_and(|n| n.is_alphanumeric());
                if !in_word {
                    push(&mut runs, &mut buf, &cur, None);
                    cur.italic = !cur.italic;
                    i += 1;
                    continue;
                }
            }
            '~' if next == Some('~') => {
                push(&mut runs, &mut buf, &cur, None);
                cur.strike = !cur.strike;
                i += 2;
                continue;
            }
            '`' => {
                if let Some(end) = chars[i + 1..].iter().position(|x| *x == '`') {
                    push(&mut runs, &mut buf, &cur, None);
                    let code: String = chars[i + 1..i + 1 + end].iter().collect();
                    let mut mono = cur.clone();
                    mono.font = Some(1);
                    buf.push_str(&code);
                    push(&mut runs, &mut buf, &mono, None);
                    i += end + 2;
                    continue;
                }
            }
            '[' => {
                let rest: String = chars[i..].iter().collect();
                if let Some(close) = rest.find("](") {
                    if let Some(end) = rest[close..].find(')') {
                        let label = &rest[1..close];
                        let url = &rest[close + 2..close + end];
                        if !label.contains(']') && !url.contains(' ') {
                            push(&mut runs, &mut buf, &cur, None);
                            let mut l = cur.clone();
                            l.color = Some(0x0563C1);
                            l.underline = Some("single");
                            buf.push_str(label);
                            push(&mut runs, &mut buf, &l, Some(url.to_owned()));
                            i += label.chars().count() + url.chars().count() + 4;
                            continue;
                        }
                    }
                }
            }
            _ => {}
        }
        buf.push(c);
        i += 1;
    }
    push(&mut runs, &mut buf, &cur, None);
    runs
}

fn markdown_blocks(text: &str) -> Vec<Block> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut blocks = Vec::new();
    let mut para: Option<(String, ParaProps)> = None;
    let flush = |para: &mut Option<(String, ParaProps)>, blocks: &mut Vec<Block>| {
        if let Some((t, props)) = para.take() {
            blocks.push(Block::Para(Para {
                runs: inline_runs(&t, &Chars::default()),
                props,
            }));
        }
    };
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();
        let indent = line.len() - trimmed.len();
        // Fenced code: lines as they are, in a fixed-width font.
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            flush(&mut para, &mut blocks);
            let fence = &trimmed[..3];
            i += 1;
            let mono = Chars {
                font: Some(1),
                ..Chars::default()
            };
            while i < lines.len() && !lines[i].trim_start().starts_with(fence) {
                let mut p = text_para(lines[i], &mono);
                p.props.after = Some(0);
                blocks.push(Block::Para(p));
                i += 1;
            }
            i += 1;
            continue;
        }
        if trimmed.is_empty() {
            flush(&mut para, &mut blocks);
            i += 1;
            continue;
        }
        let hashes = trimmed.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&hashes) && trimmed[hashes..].starts_with(' ') {
            flush(&mut para, &mut blocks);
            let props = ParaProps {
                outline: Some((hashes as i32 - 1).min(2)),
                ..ParaProps::default()
            };
            blocks.push(Block::Para(Para {
                runs: inline_runs(trimmed[hashes..].trim().trim_end_matches('#').trim(), &Chars::default()),
                props,
            }));
            i += 1;
            continue;
        }
        if matches!(trimmed, "---" | "***" | "___") {
            flush(&mut para, &mut blocks);
            i += 1;
            continue;
        }
        // Tables: a header row, a separator row, then rows.
        if trimmed.starts_with('|') && lines.get(i + 1).is_some_and(|l| l.trim_start().starts_with('|') && l.contains("--")) {
            flush(&mut para, &mut blocks);
            let cells = |l: &str| -> Vec<String> {
                l.trim().trim_matches('|').split('|').map(|c| c.trim().to_owned()).collect()
            };
            let mut rows = Vec::new();
            let header = cells(trimmed);
            let width = header.len().max(1);
            let mut add_row = |cs: Vec<String>, header: bool| {
                let bold = Chars {
                    bold: header,
                    ..Chars::default()
                };
                let mut row = Row {
                    header,
                    ..Row::default()
                };
                for k in 0..width {
                    let t = cs.get(k).cloned().unwrap_or_default();
                    row.cells.push(vec![Para {
                        runs: inline_runs(&t, &bold),
                        props: ParaProps::default(),
                    }]);
                    row.defs.push(CellDef {
                        right: ((k + 1) * 9000 / width) as i32,
                        border: true,
                        ..CellDef::default()
                    });
                }
                rows.push(row);
            };
            add_row(header, true);
            i += 2;
            while i < lines.len() && lines[i].trim_start().starts_with('|') {
                add_row(cells(lines[i]), false);
                i += 1;
            }
            blocks.push(Block::Table(rows));
            continue;
        }
        let bullet = ["- ", "* ", "+ "].iter().any(|b| trimmed.starts_with(b));
        let number = {
            let digits = trimmed.chars().take_while(|c| c.is_ascii_digit()).count();
            digits > 0 && (trimmed[digits..].starts_with(". ") || trimmed[digits..].starts_with(") "))
        };
        if bullet || number {
            flush(&mut para, &mut blocks);
            let body = if bullet {
                &trimmed[2..]
            } else {
                let digits = trimmed.chars().take_while(|c| c.is_ascii_digit()).count();
                &trimmed[digits + 2..]
            };
            let props = ParaProps {
                list: Some(if bullet { 1 } else { 2 }),
                level: (indent / 2).min(8) as i32,
                ..ParaProps::default()
            };
            para = Some((body.trim().to_owned(), props));
            flush(&mut para, &mut blocks);
            i += 1;
            continue;
        }
        if let Some(q) = trimmed.strip_prefix('>') {
            flush(&mut para, &mut blocks);
            let props = ParaProps {
                style: Some(100),
                ..ParaProps::default()
            };
            para = Some((q.trim().to_owned(), props));
            flush(&mut para, &mut blocks);
            i += 1;
            continue;
        }
        // Ordinary text: lines join into one paragraph; two trailing spaces
        // break the line.
        let hard = line.ends_with("  ");
        let piece = trimmed.trim_end();
        match &mut para {
            Some((t, _)) => {
                if !t.ends_with('\n') {
                    t.push(' ');
                }
                t.push_str(piece);
            }
            None => para = Some((piece.to_owned(), ParaProps::default())),
        }
        if hard {
            if let Some((t, _)) = &mut para {
                t.push('\n');
            }
        }
        i += 1;
    }
    flush(&mut para, &mut blocks);
    blocks
}

fn build_package(mut w: Writer) -> Result<Vec<u8>, WordError> {
    use doc_zip::{Compression, ZipWriter};
    let mut doc = String::from(builtin::DOCUMENT);
    let body_start = doc.find("<w:body>").unwrap() + "<w:body>".len();
    let p_end = doc[body_start..].find("<w:sectPr").unwrap() + body_start;
    doc.replace_range(body_start..p_end, &w.xml);

    // Styles: the template's, plus built-in ones used.
    let mut styles = String::from(builtin::STYLES);
    let extra: String = w.styles_used.iter().filter_map(|s| builtin::style_xml(s)).collect();
    let at = styles.rfind("</w:styles>").unwrap();
    styles.insert_str(at, &extra);

    let mut numbering = None;
    if !w.list_kinds.is_empty() {
        let mut n = crate::docx::numbering::Numbering::default();
        let mut ids = Vec::new();
        for (_, bullet) in &w.list_kinds {
            ids.push(n.add_list(*bullet, "w"));
        }
        if let Some(d) = &n.doc {
            numbering = Some(d.to_xml());
        }
        let _ = ids;
    }

    let mut rels = String::from(builtin::DOCUMENT_RELS);
    let close = rels.rfind("</Relationships>").unwrap();
    let mut extra_rels = String::new();
    if numbering.is_some() {
        extra_rels.push_str(r#"<Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>"#);
    }
    for (id, kind, target) in &w.rels {
        extra_rels.push_str(&format!(
            r#"<Relationship Id="{id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/{kind}" Target="{target}/>"#
        ));
    }
    rels.insert_str(close, &extra_rels);

    let mut types = String::from(builtin::CONTENT_TYPES);
    let mut extra_types = String::new();
    let mut exts: Vec<&str> = w.media.iter().map(|(n, _)| n.rsplit('.').next().unwrap_or("png")).collect();
    exts.sort_unstable();
    exts.dedup();
    for e in exts {
        let ct = if e == "png" { "image/png" } else { "image/jpeg" };
        extra_types.push_str(&format!(r#"<Default Extension="{e}" ContentType="{ct}"/>"#));
    }
    if numbering.is_some() {
        extra_types.push_str(r#"<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>"#);
    }
    // Defaults before overrides.
    let at = types.find("<Override").unwrap();
    let (defaults, overrides): (String, String) = (
        extra_types.split("<Override").next().unwrap_or("").to_owned(),
        extra_types.find("<Override").map(|i| extra_types[i..].to_owned()).unwrap_or_default(),
    );
    types.insert_str(at, &defaults);
    let close = types.rfind("</Types>").unwrap();
    types.insert_str(close, &overrides);

    let mut z = ZipWriter::new();
    let core = builtin::core("2026-01-01T00:00:00Z");
    let parts: Vec<(&str, &[u8])> = vec![
        ("[Content_Types].xml", types.as_bytes()),
        ("_rels/.rels", builtin::ROOT_RELS.as_bytes()),
        ("docProps/core.xml", core.as_bytes()),
        ("docProps/app.xml", builtin::APP.as_bytes()),
        ("word/document.xml", doc.as_bytes()),
        ("word/_rels/document.xml.rels", rels.as_bytes()),
        ("word/styles.xml", styles.as_bytes()),
        ("word/settings.xml", builtin::SETTINGS.as_bytes()),
    ];
    for (name, data) in parts {
        z.add(name, data, Compression::DEFAULT).map_err(|e| WordError::Corrupt(e.to_string()))?;
    }
    if let Some(n) = &numbering {
        z.add("word/numbering.xml", n.as_bytes(), Compression::DEFAULT).map_err(|e| WordError::Corrupt(e.to_string()))?;
    }
    for (name, data) in std::mem::take(&mut w.media) {
        z.add(&name, &data, Compression::Stored).map_err(|e| WordError::Corrupt(e.to_string()))?;
    }
    Ok(z.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::view::{BlockView, Inline};

    fn read(rtf: &str) -> crate::Document {
        // A backslash-u escape, spelled out so editors leave it alone.
        let rtf = rtf.replace("{U}", concat!("\\", "u"));
        let bytes = rtf_to_docx(rtf.as_bytes()).unwrap();
        crate::open(bytes, "x.docx").unwrap()
    }

    #[test]
    fn markdown_becomes_word() {
        let md = "# Notes\n\nSome **bold** and *italic* with `code` and a [link](https://x.org).\nSame paragraph.\n\n- one\n- two\n\n1. first\n2. second\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n> quoted\n";
        let bytes = text_to_docx(md, true).unwrap();
        let mut d = crate::open(bytes, "x.docx").unwrap();
        let n = d.block_count();
        let blocks = d.blocks(0, n);
        let texts: Vec<String> = blocks
            .iter()
            .map(|b| match b {
                BlockView::Para(p) => p.text(),
                BlockView::Table(t) => format!("table {}x{}", t.rows.len(), t.rows[0].cells.len()),
                _ => String::new(),
            })
            .collect();
        assert_eq!(
            texts,
            ["Notes", "Some bold and italic with code and a link. Same paragraph.", "one", "two", "first", "second", "table 2x2", "quoted"]
        );
        let BlockView::Para(h) = &blocks[0] else { panic!() };
        assert_eq!(h.style.outline_level, Some(0));
        let BlockView::Para(p) = &blocks[1] else { panic!() };
        assert!(p.inlines.iter().any(|i| matches!(i, Inline::Text { text, style, .. } if text == "bold" && style.bold)));
        assert!(p.inlines.iter().any(|i| matches!(i, Inline::Text { text, link: Some(l), .. } if text == "link" && l == "https://x.org")));
        let BlockView::Para(n1) = &blocks[4] else { panic!() };
        assert_eq!(n1.list.as_ref().unwrap().text, "1.");
        let BlockView::Para(b1) = &blocks[2] else { panic!() };
        assert!(b1.list.as_ref().unwrap().bullet);
    }

    #[test]
    fn plain_text_is_a_paragraph_per_line() {
        let bytes = text_to_docx("one\n\ntwo\n", false).unwrap();
        let mut d = crate::open(bytes, "x.docx").unwrap();
        assert_eq!(d.plain_text(), "one\n\ntwo\n");
    }

    #[test]
    fn formatting_lists_and_tables() {
        let rtf = r#"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}{\f1\fswiss Arial;}}{\colortbl;\red255\green0\blue0;}
{\stylesheet{\s0 Normal;}{\s1 heading 1;}}
{\*\listtable{\list\listtemplateid1{\listlevel\levelnfc23\levelstartat1{\leveltext\'01{U}8226 ?;}}\listid42}}
{\*\listoverridetable{\listoverride\listid42\listoverridecount0\ls1}}
\pard\s1\qc Report\par
\pard Plain {\b bold} and {\i\cf1 red italic} caf\'e9 {U}8212? done.\par
\pard\ls1\ilvl0 {\listtext\'95\tab}First\par
\pard\ls1\ilvl0 Second\par
\trowd\cellx2000\cellx4000\pard\intbl A1\cell B1\cell\row
\trowd\cellx2000\cellx4000\pard\intbl A2\cell B2\cell\row
\pard {\field{\*\fldinst HYPERLINK "https://example.com"}{\fldrslt link}}\par
}"#;
        let mut d = read(rtf);
        let n = d.block_count();
        let blocks = d.blocks(0, n);
        let BlockView::Para(p) = &blocks[0] else { panic!() };
        assert_eq!(p.text(), "Report");
        assert_eq!(p.style.outline_level, Some(0));
        let BlockView::Para(p) = &blocks[1] else { panic!() };
        assert_eq!(p.text(), "Plain bold and red italic caf\u{e9} \u{2014} done.");
        let bold = p.inlines.iter().any(|i| matches!(i, Inline::Text { text, style, .. } if text == "bold" && style.bold));
        assert!(bold);
        let red = p.inlines.iter().any(|i| matches!(i, Inline::Text { text, style, .. } if text == "red italic" && style.color == Some(0xFF0000) && style.italic));
        assert!(red);
        let BlockView::Para(p) = &blocks[2] else { panic!() };
        assert_eq!(p.text(), "First");
        assert!(p.list.as_ref().is_some_and(|l| l.bullet));
        let BlockView::Table(t) = &blocks[4] else { panic!("{:?}", blocks[4]) };
        assert_eq!(t.rows.len(), 2);
        assert_eq!(t.rows[1].cells.len(), 2);
        let BlockView::Para(p) = &blocks[5] else { panic!() };
        assert!(matches!(&p.inlines[0], Inline::Text { link: Some(l), .. } if l == "https://example.com"));
    }
}
