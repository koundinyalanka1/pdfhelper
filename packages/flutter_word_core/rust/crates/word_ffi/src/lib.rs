//! The FFI layer of the word-processing engine, in Rust, for `dart:ffi`.
//!
//! Conventions are those of `doc_ffi`: UTF-8 strings, caller-owned results
//! freed with [`word_free_string`], negative or NULL results on failure with
//! the reason in [`word_last_error`]. Structured data crosses as JSON; edits
//! are JSON operations (see [`word_apply`]). Text offsets are UTF-16.

use std::ffi::c_char;

use doc_ffi::{
    call_i64, call_str, codes, last_error_ptr, opt_str_arg, read_file, str_arg,
    write_file_atomically, FfiError, Registry,
};
use serde::Deserialize;
use serde_json::{json, Value as Json};
use word_core::view::{
    Align, BlockView, Inline, InlineEdit, LineSpacing, ListLabel, ObjectView, ParaPatch, ParaStyle,
    ParaView, RunStyle, TableView,
};
use word_core::{Document, Edit, FindOptions, Format, NewPara, TableOp, WordError};

pub use word_core;

/// Files larger than this are refused rather than read into memory.
const MAX_FILE_BYTES: u64 = 256 << 20;
/// Pictures larger than this are refused.
const MAX_IMAGE_BYTES: u64 = 64 << 20;

static DOCS: Registry<Document> = Registry::new();

fn word_error(e: WordError) -> FfiError {
    match e {
        WordError::Encrypted => FfiError::new(codes::ENCRYPTED, e.to_string()),
        WordError::Corrupt(m) => FfiError::corrupt(m),
        WordError::Unsupported(m) => FfiError::unsupported(m),
        WordError::TooLarge(m) => FfiError::new(codes::TOO_LARGE, m),
        WordError::Invalid(m) => FfiError::invalid(m),
    }
}

fn json_err(e: serde_json::Error) -> FfiError {
    FfiError::invalid(format!("bad request: {e}"))
}

fn to_json(v: &Json) -> Result<String, FfiError> {
    serde_json::to_string(v).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
}

// --- Views as JSON

fn run_json(s: &RunStyle) -> Json {
    json!({
        "b": s.bold,
        "i": s.italic,
        "u": s.underline,
        "s": s.strike,
        "size": s.size,
        "color": s.color,
        "hl": s.highlight,
        "font": s.font,
        "vert": s.vert,
        "caps": s.caps,
        "smallCaps": s.small_caps,
        "hidden": s.hidden,
    })
}

fn line_json(l: LineSpacing) -> Json {
    match l {
        LineSpacing::Multiple(v) => json!({"rule": "multiple", "value": v}),
        LineSpacing::Exactly(v) => json!({"rule": "exactly", "value": v}),
        LineSpacing::AtLeast(v) => json!({"rule": "atLeast", "value": v}),
    }
}

fn para_style_json(s: &ParaStyle) -> Json {
    json!({
        "styleId": s.style_id,
        "styleName": s.style_name,
        "align": s.align.name(),
        "indentLeft": s.indent_left,
        "indentRight": s.indent_right,
        "firstLine": s.first_line,
        "spaceBefore": s.space_before,
        "spaceAfter": s.space_after,
        "line": line_json(s.line),
        "keepNext": s.keep_next,
        "pageBreakBefore": s.page_break_before,
        "outline": s.outline_level,
        "shading": s.shading,
        "mark": run_json(&s.mark),
        "bidi": s.bidi,
        "nextStyle": s.next_style,
    })
}

fn label_json(l: &ListLabel) -> Json {
    json!({"level": l.level, "text": l.text, "bullet": l.bullet, "style": run_json(&l.style)})
}

fn object_json(o: &ObjectView) -> Json {
    json!({
        "id": o.id,
        "kind": o.kind.name(),
        "text": o.text,
        "width": o.width,
        "height": o.height,
        "alt": o.alt,
        "style": run_json(&o.style),
    })
}

fn para_json(p: &ParaView) -> Json {
    let inlines: Vec<Json> = p
        .inlines
        .iter()
        .map(|i| match i {
            Inline::Text { text, style, link } => {
                json!({"t": text, "style": run_json(style), "link": link})
            }
            Inline::Object(o) => json!({"o": object_json(o)}),
        })
        .collect();
    json!({
        "type": "para",
        "id": p.id,
        "style": para_style_json(&p.style),
        "list": p.list.as_ref().map(label_json),
        "inlines": inlines,
        "editable": p.editable,
        "locked": p.locked_reason,
    })
}

fn table_json(t: &TableView) -> Json {
    let rows: Vec<Json> = t
        .rows
        .iter()
        .map(|r| {
            let cells: Vec<Json> = r
                .cells
                .iter()
                .map(|c| {
                    json!({
                        "colSpan": c.col_span,
                        "rowSpan": c.row_span,
                        "mergedUp": c.merged_up,
                        "fill": c.fill,
                        "width": c.width,
                        "blocks": c.blocks.iter().map(block_json).collect::<Vec<_>>(),
                    })
                })
                .collect();
            json!({"header": r.header, "cells": cells})
        })
        .collect();
    json!({"type": "table", "id": t.id, "colWidths": t.col_widths, "borders": t.borders, "rows": rows})
}

fn block_json(b: &BlockView) -> Json {
    match b {
        BlockView::Para(p) => para_json(p),
        BlockView::Table(t) => table_json(t),
        BlockView::Other { id, text } => json!({"type": "other", "id": id, "text": text}),
    }
}

fn info(d: &mut Document) -> Json {
    let page = d.page_setup();
    let styles: Vec<Json> = d
        .styles()
        .iter()
        .map(|s| json!({"id": s.id, "name": s.name, "outline": s.outline, "defined": s.defined}))
        .collect();
    json!({
        "format": d.source_format().name(),
        "saveFormat": d.save_format().name(),
        "writesBack": d.source_format().writes_back(),
        "blockCount": d.block_count(),
        "page": {
            "width": page.width,
            "height": page.height,
            "marginTop": page.margin_top,
            "marginBottom": page.margin_bottom,
            "marginLeft": page.margin_left,
            "marginRight": page.margin_right,
        },
        "styles": styles,
        "modified": d.is_dirty(),
        "canUndo": d.can_undo(),
        "canRedo": d.can_redo(),
        "warnings": d.warnings,
    })
}

// --- Edits from JSON

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunJson {
    #[serde(default)]
    b: bool,
    #[serde(default)]
    i: bool,
    #[serde(default = "none")]
    u: String,
    #[serde(default)]
    s: bool,
    size: f32,
    #[serde(default)]
    color: Option<u32>,
    #[serde(default)]
    hl: Option<u32>,
    #[serde(default)]
    font: String,
    #[serde(default)]
    vert: Option<String>,
    #[serde(default)]
    caps: bool,
    #[serde(default)]
    small_caps: bool,
    #[serde(default)]
    hidden: bool,
}

fn none() -> String {
    "none".into()
}

impl From<RunJson> for RunStyle {
    fn from(r: RunJson) -> RunStyle {
        RunStyle {
            bold: r.b,
            italic: r.i,
            underline: r.u,
            strike: r.s,
            size: r.size,
            color: r.color,
            highlight: r.hl,
            font: r.font,
            vert: r.vert,
            caps: r.caps,
            small_caps: r.small_caps,
            hidden: r.hidden,
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum InlineJson {
    Text {
        text: String,
        style: RunJson,
        #[serde(default)]
        link: Option<String>,
    },
    Object {
        object: u32,
    },
}

#[derive(Deserialize)]
struct NewParaJson {
    #[serde(default)]
    inlines: Vec<InlineJson>,
    #[serde(default)]
    style: Option<String>,
}

#[derive(Deserialize)]
struct LineJson {
    rule: String,
    value: f32,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum OpJson {
    SetParas {
        first: u32,
        last: u32,
        paras: Vec<NewParaJson>,
    },
    #[serde(rename_all = "camelCase")]
    Patch {
        ids: Vec<u32>,
        #[serde(default)]
        align: Option<String>,
        #[serde(default)]
        style_id: Option<String>,
        #[serde(default)]
        list: Option<String>,
        #[serde(default)]
        indent_steps: Option<i32>,
        #[serde(default)]
        space_before: Option<f32>,
        #[serde(default)]
        space_after: Option<f32>,
        #[serde(default)]
        line: Option<LineJson>,
        #[serde(default)]
        page_break_before: Option<bool>,
        #[serde(default)]
        keep_next: Option<bool>,
    },
    InsertTable {
        after: u32,
        rows: usize,
        cols: usize,
    },
    InsertPageBreak {
        after: u32,
    },
    InsertImage {
        after: u32,
        path: String,
        width: f32,
        height: f32,
        #[serde(default)]
        ext: Option<String>,
    },
    DeleteBlock {
        id: u32,
    },
    Table {
        id: u32,
        action: String,
        at: usize,
        #[serde(default)]
        after: bool,
    },
    #[serde(rename_all = "camelCase")]
    ReplaceAll {
        find: String,
        replace: String,
        #[serde(default)]
        match_case: bool,
        #[serde(default)]
        whole_word: bool,
    },
}

fn inline_edit(i: InlineJson) -> InlineEdit {
    match i {
        InlineJson::Text { text, style, link } => InlineEdit::Text {
            text,
            style: style.into(),
            link: link.filter(|l| !l.is_empty()),
        },
        InlineJson::Object { object } => InlineEdit::Object(object),
    }
}

fn edit_of(op: OpJson) -> Result<Edit, FfiError> {
    Ok(match op {
        OpJson::SetParas { first, last, paras } => Edit::SetParas {
            first,
            last,
            paras: paras
                .into_iter()
                .map(|p| NewPara {
                    inlines: p.inlines.into_iter().map(inline_edit).collect(),
                    style: p.style,
                })
                .collect(),
        },
        OpJson::Patch {
            ids,
            align,
            style_id,
            list,
            indent_steps,
            space_before,
            space_after,
            line,
            page_break_before,
            keep_next,
        } => Edit::Patch {
            ids,
            patch: ParaPatch {
                align: align.as_deref().map(Align::parse),
                style_id,
                list,
                indent_steps,
                space_before,
                space_after,
                line: line.map(|l| match l.rule.as_str() {
                    "exactly" => LineSpacing::Exactly(l.value),
                    "atLeast" => LineSpacing::AtLeast(l.value),
                    _ => LineSpacing::Multiple(l.value),
                }),
                page_break_before,
                keep_next,
            },
        },
        OpJson::InsertTable { after, rows, cols } => Edit::InsertTable { after, rows, cols },
        OpJson::InsertPageBreak { after } => Edit::InsertPageBreak { after },
        OpJson::InsertImage {
            after,
            path,
            width,
            height,
            ext,
        } => {
            let bytes = read_file(&path, MAX_IMAGE_BYTES)?;
            let ext = ext
                .or_else(|| path.rsplit_once('.').map(|(_, e)| e.to_owned()))
                .or_else(|| sniff_image(&bytes).map(str::to_owned))
                .unwrap_or_default();
            Edit::InsertImage {
                after,
                bytes,
                ext,
                width,
                height,
            }
        }
        OpJson::DeleteBlock { id } => Edit::DeleteBlock { id },
        OpJson::Table {
            id,
            action,
            at,
            after,
        } => Edit::Table {
            id,
            op: match action.as_str() {
                "insertRow" => TableOp::InsertRow { at, below: after },
                "deleteRow" => TableOp::DeleteRow { at },
                "insertCol" => TableOp::InsertCol { at, right: after },
                "deleteCol" => TableOp::DeleteCol { at },
                other => return Err(FfiError::invalid(format!("unknown table action '{other}'"))),
            },
        },
        OpJson::ReplaceAll {
            find,
            replace,
            match_case,
            whole_word,
        } => Edit::ReplaceAll {
            find,
            replace,
            options: FindOptions {
                match_case,
                whole_word,
            },
        },
    })
}

fn sniff_image(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("png")
    } else if b.starts_with(&[0xFF, 0xD8]) {
        Some("jpeg")
    } else if b.starts_with(b"GIF8") {
        Some("gif")
    } else if b.starts_with(b"BM") {
        Some("bmp")
    } else {
        None
    }
}

// --- Exports

/// Library version (static; do not free).
#[no_mangle]
pub extern "C" fn word_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// This thread's last error, `"CODE: message"` (borrowed; do not free).
#[no_mangle]
pub extern "C" fn word_last_error() -> *const c_char {
    last_error_ptr()
}

/// Free a string returned by this library.
///
/// # Safety
/// `ptr` must be NULL or a string from this library, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn word_free_string(ptr: *mut c_char) {
    doc_ffi::free_c_string(ptr)
}

/// Open a document (DOCX, DOCM, DOTX). `name` gives the file name for its
/// extension; NULL uses `path`. Returns a handle, or -1.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_open(path: *const c_char, name: *const c_char) -> i64 {
    call_i64(|| {
        let path = str_arg(path, "path")?;
        let name = opt_str_arg(name, "name")?.unwrap_or(path);
        let bytes = read_file(path, MAX_FILE_BYTES)?;
        let d = word_core::open(bytes, name).map_err(word_error)?;
        Ok(DOCS.insert(d))
    })
}

/// A new, empty Word document. Returns a handle.
#[no_mangle]
pub extern "C" fn word_new() -> i64 {
    call_i64(|| Ok(DOCS.insert(word_core::blank())))
}

/// Close a document. Returns 0, or -1 for an unknown handle.
#[no_mangle]
pub extern "C" fn word_close(handle: i64) -> i64 {
    call_i64(|| {
        if DOCS.remove(handle) {
            Ok(0)
        } else {
            Err(FfiError::new(
                codes::BAD_HANDLE,
                format!("no open document has handle {handle}"),
            ))
        }
    })
}

/// The document: `{"format", "saveFormat", "writesBack", "blockCount",
/// "page", "styles", "modified", "canUndo", "canRedo", "warnings"}`.
#[no_mangle]
pub extern "C" fn word_info_json(handle: i64) -> *mut c_char {
    call_str(|| DOCS.with(handle, |d| to_json(&info(d))))
}

/// Blocks `from..from + count` of the body: paragraphs (`type` `para`),
/// tables (`table`, with their cells' blocks) and content shown as text
/// (`other`).
#[no_mangle]
pub extern "C" fn word_blocks_json(handle: i64, from: i64, count: i64) -> *mut c_char {
    call_str(|| {
        DOCS.with(handle, |d| {
            let blocks = d.blocks(from.max(0) as usize, count.clamp(0, 10_000) as usize);
            to_json(&Json::Array(blocks.iter().map(block_json).collect()))
        })
    })
}

/// One paragraph (anywhere, including table cells), or null when gone.
#[no_mangle]
pub extern "C" fn word_paragraph_json(handle: i64, id: i64) -> *mut c_char {
    call_str(|| {
        DOCS.with(handle, |d| {
            to_json(&d.paragraph(id as u32).map_or(Json::Null, |p| para_json(&p)))
        })
    })
}

/// Where a block (or the block holding a paragraph) is in the body's list,
/// or -1.
#[no_mangle]
pub extern "C" fn word_block_index(handle: i64, id: i64) -> i64 {
    call_i64(|| {
        DOCS.with(handle, |d| {
            Ok(d.block_index(id as u32).map_or(-1, |i| i as i64))
        })
    })
}

/// Apply an edit. Returns `{"ids": [...], "count": n}`: the paragraphs
/// written (a split gives both halves) and, for replace-all, how many.
///
/// Edits (`op`):
/// - `setParas {first, last, paras: [{inlines: [{text, style, link} |
///   {object}], style}]}`: replace paragraphs `first..=last` (siblings);
/// - `patch {ids, align, styleId, list ("none"|"bullet"|"number"),
///   indentSteps, spaceBefore, spaceAfter, line: {rule, value},
///   pageBreakBefore, keepNext}`;
/// - `insertTable {after, rows, cols}`, `insertPageBreak {after}`,
///   `insertImage {after, path, width, height}`;
/// - `deleteBlock {id}`;
/// - `table {id, action ("insertRow"|"deleteRow"|"insertCol"|"deleteCol"),
///   at, after}`;
/// - `replaceAll {find, replace, matchCase, wholeWord}`.
///
/// # Safety
/// `op_json` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_apply(handle: i64, op_json: *const c_char) -> *mut c_char {
    call_str(|| {
        let op: OpJson = serde_json::from_str(str_arg(op_json, "op")?).map_err(json_err)?;
        let edit = edit_of(op)?;
        DOCS.with(handle, |d| {
            let r = d.apply(edit).map_err(word_error)?;
            to_json(&json!({"ids": r.ids, "count": r.count}))
        })
    })
}

/// Undo the last edit. Returns 1, or 0 when there is nothing to undo.
#[no_mangle]
pub extern "C" fn word_undo(handle: i64) -> i64 {
    call_i64(|| DOCS.with(handle, |d| d.undo().map(i64::from).map_err(word_error)))
}

/// Redo. Returns 1, or 0 when there is nothing to redo.
#[no_mangle]
pub extern "C" fn word_redo(handle: i64) -> i64 {
    call_i64(|| DOCS.with(handle, |d| d.redo().map(i64::from).map_err(word_error)))
}

/// Matches of `query`: `[{"para", "start", "len"}]` (UTF-16 offsets in the
/// paragraph's text). `options_json`: `{"matchCase", "wholeWord"}`.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_find_json(
    handle: i64,
    query: *const c_char,
    options_json: *const c_char,
) -> *mut c_char {
    call_str(|| {
        let query = str_arg(query, "query")?;
        let opts: Json = match opt_str_arg(options_json, "options")? {
            Some(j) => serde_json::from_str(j).map_err(json_err)?,
            None => json!({}),
        };
        let options = FindOptions {
            match_case: opts["matchCase"].as_bool().unwrap_or(false),
            whole_word: opts["wholeWord"].as_bool().unwrap_or(false),
        };
        DOCS.with(handle, |d| {
            let found: Vec<Json> = d
                .find(query, options)
                .iter()
                .map(|m| json!({"para": m.para, "start": m.start, "len": m.len}))
                .collect();
            to_json(&Json::Array(found))
        })
    })
}

/// Headings: `[{"id", "level", "text"}]`.
#[no_mangle]
pub extern "C" fn word_outline_json(handle: i64) -> *mut c_char {
    call_str(|| {
        DOCS.with(handle, |d| {
            let h: Vec<Json> = d
                .outline()
                .iter()
                .map(|h| json!({"id": h.id, "level": h.level, "text": h.text}))
                .collect();
            to_json(&Json::Array(h))
        })
    })
}

/// `{"words", "characters", "charactersNoSpaces", "paragraphs"}`.
#[no_mangle]
pub extern "C" fn word_counts_json(handle: i64) -> *mut c_char {
    call_str(|| {
        DOCS.with(handle, |d| {
            let c = d.counts();
            to_json(&json!({
                "words": c.words,
                "characters": c.characters,
                "charactersNoSpaces": c.characters_no_spaces,
                "paragraphs": c.paragraphs,
            }))
        })
    })
}

/// The document as plain text.
#[no_mangle]
pub extern "C" fn word_text(handle: i64) -> *mut c_char {
    call_str(|| DOCS.with(handle, |d| Ok(d.plain_text())))
}

/// Write an image object's bytes to `path`. Returns its file extension
/// (`png`, `jpeg`, `emf`...).
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_image_save(
    handle: i64,
    object: i64,
    path: *const c_char,
) -> *mut c_char {
    call_str(|| {
        let path = str_arg(path, "path")?;
        DOCS.with(handle, |d| {
            let (bytes, ext) = d.image(object as u32).ok_or_else(|| {
                FfiError::new(codes::NOT_FOUND, "that picture is not in the document")
            })?;
            write_file_atomically(path, &bytes)?;
            Ok(ext)
        })
    })
}

/// Save to `path` (atomically). The document is written in its own format
/// when that can be written back, otherwise as Word. Returns
/// `{"format": "docx"}`.
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_save(handle: i64, path: *const c_char) -> *mut c_char {
    call_str(|| {
        let path = str_arg(path, "path")?;
        DOCS.with(handle, |d| {
            let (bytes, format) = d.save().map_err(word_error)?;
            write_file_atomically(path, &bytes)?;
            d.saved();
            to_json(&json!({"format": format.name()}))
        })
    })
}

/// Write a copy to `path` without marking the document saved. `format`:
/// `txt` writes plain text; NULL or anything else, the save format.
/// Returns `{"format": ...}`.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn word_write_copy(
    handle: i64,
    path: *const c_char,
    format: *const c_char,
) -> *mut c_char {
    call_str(|| {
        let path = str_arg(path, "path")?;
        let format = opt_str_arg(format, "format")?.and_then(Format::parse);
        DOCS.with(handle, |d| {
            if format == Some(Format::Txt) {
                let text = d.plain_text();
                write_file_atomically(path, text.as_bytes())?;
                return to_json(&json!({"format": "txt"}));
            }
            let (bytes, f) = d.save().map_err(word_error)?;
            write_file_atomically(path, &bytes)?;
            to_json(&json!({"format": f.name()}))
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn take(p: *mut c_char) -> String {
        assert!(!p.is_null(), "{}", doc_ffi::last_error());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { word_free_string(p) };
        s
    }

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn edit_save_and_reopen() {
        let h = word_new();
        assert!(h > 0);
        let blocks: Json = serde_json::from_str(&take(word_blocks_json(h, 0, 10))).unwrap();
        let id = blocks[0]["id"].as_u64().unwrap();
        let mark = blocks[0]["style"]["mark"].clone();
        let mut bold = mark.clone();
        bold["b"] = json!(true);
        let op = json!({
            "op": "setParas", "first": id, "last": id,
            "paras": [
                {"inlines": [{"text": "Dear Sir,", "style": mark}]},
                {"inlines": [{"text": "Bold ", "style": bold}, {"text": "plain", "style": mark}]},
            ]
        });
        let r: Json =
            serde_json::from_str(&take(unsafe { word_apply(h, c(&op.to_string()).as_ptr()) }))
                .unwrap();
        assert_eq!(r["ids"].as_array().unwrap().len(), 2);
        let second = r["ids"][1].as_u64().unwrap();
        let op = json!({"op": "patch", "ids": [second], "list": "bullet", "align": "center"});
        take(unsafe { word_apply(h, c(&op.to_string()).as_ptr()) });
        let op = json!({"op": "insertTable", "after": second, "rows": 2, "cols": 3});
        take(unsafe { word_apply(h, c(&op.to_string()).as_ptr()) });

        let dir = std::env::temp_dir().join(format!("word_ffi_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("letter.docx");
        let p = c(path.to_str().unwrap());
        let saved: Json = serde_json::from_str(&take(unsafe { word_save(h, p.as_ptr()) })).unwrap();
        assert_eq!(saved["format"], json!("docx"));
        assert_eq!(word_close(h), 0);

        let h2 = unsafe { word_open(p.as_ptr(), std::ptr::null()) };
        assert!(h2 > 0, "{}", doc_ffi::last_error());
        let info: Json = serde_json::from_str(&take(word_info_json(h2))).unwrap();
        assert_eq!(info["blockCount"], json!(4));
        let blocks: Json = serde_json::from_str(&take(word_blocks_json(h2, 0, 10))).unwrap();
        assert_eq!(blocks[1]["list"]["bullet"], json!(true));
        assert_eq!(blocks[1]["style"]["align"], json!("center"));
        assert_eq!(blocks[1]["inlines"][0]["style"]["b"], json!(true));
        assert_eq!(blocks[2]["type"], json!("table"));
        assert_eq!(blocks[2]["rows"][0]["cells"].as_array().unwrap().len(), 3);
        let text = take(word_text(h2));
        assert!(
            text.starts_with("Dear Sir,\n\u{2022} Bold plain\n"),
            "{text:?}"
        );
        assert_eq!(word_close(h2), 0);
        std::fs::remove_dir_all(&dir).ok();
    }
}
