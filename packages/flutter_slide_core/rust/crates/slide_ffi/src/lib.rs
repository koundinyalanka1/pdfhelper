//! The FFI layer of the presentation engine, in Rust, for `dart:ffi`.
//!
//! Conventions are those of `doc_ffi`: UTF-8 strings, caller-owned results
//! freed with [`slide_free_string`], negative or NULL results on failure with
//! the reason in [`slide_last_error`]. Scenes and edits cross as JSON;
//! lengths are points.

use std::ffi::c_char;

use doc_ffi::{call_i64, call_str, codes, last_error_ptr, opt_str_arg, read_file, str_arg, write_file_atomically, FfiError, Registry};
use serde::Deserialize;
use serde_json::{json, Value as Json};
use slide_core::scene::{Cmd, Fill, Item, Line, Para, Scene, Table, TextBox};
use slide_core::{Deck, Edit, SlideError, TextPatch};

pub use slide_core;

const MAX_FILE_BYTES: u64 = 512 << 20;
const MAX_IMAGE_BYTES: u64 = 64 << 20;

static DECKS: Registry<Deck> = Registry::new();

fn slide_error(e: SlideError) -> FfiError {
    match e {
        SlideError::Encrypted => FfiError::new(codes::ENCRYPTED, e.to_string()),
        SlideError::Corrupt(m) => FfiError::corrupt(m),
        SlideError::Unsupported(m) => FfiError::unsupported(m),
        SlideError::TooLarge(m) => FfiError::new(codes::TOO_LARGE, m),
        SlideError::Invalid(m) => FfiError::invalid(m),
    }
}

fn to_json(v: &Json) -> Result<String, FfiError> {
    serde_json::to_string(v).map_err(|e| FfiError::new(codes::ERROR, e.to_string()))
}

// --- Scenes as JSON

fn fill_json(f: &Fill) -> Json {
    match f {
        Fill::None => Json::Null,
        Fill::Solid(c) => json!({"type": "solid", "color": c}),
        Fill::Gradient { stops, angle, radial } => json!({
            "type": "gradient",
            "stops": stops.iter().map(|(p, c)| json!([p, c])).collect::<Vec<_>>(),
            "angle": angle,
            "radial": radial,
        }),
        Fill::Image { part } => json!({"type": "image", "part": part}),
    }
}

fn line_json(l: &Option<Line>) -> Json {
    match l {
        None => Json::Null,
        Some(l) => json!({"width": l.width, "color": l.color, "dash": l.dash, "head": l.head, "tail": l.tail}),
    }
}

/// Path commands as compact text: `M x y L x y C x1 y1 x2 y2 x y Z`.
fn path_text(cmds: &[Cmd]) -> String {
    let mut s = String::new();
    let n = |v: f32| format!("{}", (v * 100.0).round() / 100.0);
    for c in cmds {
        match *c {
            Cmd::Move(x, y) => s.push_str(&format!("M {} {} ", n(x), n(y))),
            Cmd::Line(x, y) => s.push_str(&format!("L {} {} ", n(x), n(y))),
            Cmd::Cubic(a, b, c2, d, e, f) => s.push_str(&format!("C {} {} {} {} {} {} ", n(a), n(b), n(c2), n(d), n(e), n(f))),
            Cmd::Close => s.push_str("Z "),
        }
    }
    s.trim_end().to_owned()
}

fn para_json(p: &Para) -> Json {
    json!({
        "align": p.align,
        "level": p.level,
        "marginLeft": p.margin_left,
        "indent": p.indent,
        "spaceBefore": p.space_before,
        "spaceAfter": p.space_after,
        "line": p.line,
        "linePoints": p.line_points,
        "endSize": p.end_size,
        "bullet": p.bullet.as_ref().map(|b| json!({"text": b.text, "color": b.color, "font": b.font, "size": b.size})),
        "runs": p.runs.iter().map(|r| json!({
            "t": r.text,
            "size": r.size,
            "b": r.bold,
            "i": r.italic,
            "u": r.underline,
            "s": r.strike,
            "color": r.color,
            "font": r.font,
            "baseline": r.baseline,
            "hl": r.highlight,
            "link": r.link,
        })).collect::<Vec<_>>(),
    })
}

fn text_json(t: &TextBox) -> Json {
    json!({
        "insets": t.insets,
        "anchor": t.anchor,
        "wrap": t.wrap,
        "vertical": t.vertical,
        "prompt": t.prompt,
        "paras": t.paras.iter().map(para_json).collect::<Vec<_>>(),
    })
}

fn table_json(t: &Table) -> Json {
    json!({
        "cols": t.cols,
        "rows": t.rows.iter().map(|r| json!({
            "height": r.height,
            "cells": r.cells.iter().map(|c| json!({
                "text": text_json(&c.text),
                "fill": fill_json(&c.fill),
                "borders": c.borders.iter().map(line_json).collect::<Vec<_>>(),
                "colSpan": c.col_span,
                "rowSpan": c.row_span,
                "merged": c.merged,
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

fn item_json(it: &Item) -> Json {
    json!({
        "id": it.id,
        "kind": it.kind.name(),
        "name": it.name,
        "x": it.x,
        "y": it.y,
        "w": it.w,
        "h": it.h,
        "rot": it.rot,
        "flipH": it.flip_h,
        "flipV": it.flip_v,
        "paths": it.paths.iter().map(|p| json!({"d": path_text(&p.cmds), "fill": p.fill, "stroke": p.stroke, "shade": p.shade})).collect::<Vec<_>>(),
        "fill": fill_json(&it.fill),
        "line": line_json(&it.line),
        "text": it.text.as_ref().map(text_json),
        "image": it.image.as_ref().map(|(p, c)| json!({"part": p, "crop": c})),
        "table": it.table.as_ref().map(table_json),
        "placeholder": it.placeholder,
        "editable": it.editable,
        "grouped": it.grouped,
    })
}

fn scene_json(s: &Scene) -> Json {
    json!({
        "width": s.width,
        "height": s.height,
        "hidden": s.hidden,
        "background": fill_json(&s.background),
        "items": s.items.iter().map(item_json).collect::<Vec<_>>(),
    })
}

fn info(d: &mut Deck) -> Json {
    let (w, h) = d.size();
    let layouts: Vec<Json> = d.layouts().into_iter().map(|(id, name)| json!({"id": id, "name": name})).collect();
    json!({
        "format": d.format().name(),
        "slideCount": d.slide_count(),
        "width": w,
        "height": h,
        "layouts": layouts,
        "modified": d.is_dirty(),
        "canUndo": d.can_undo(),
        "canRedo": d.can_redo(),
        "warnings": d.warnings,
    })
}

// --- Edits from JSON

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum OpJson {
    #[serde(rename_all = "camelCase")]
    SetText {
        slide: usize,
        shape: u32,
        #[serde(default)]
        cell: Option<(usize, usize)>,
        paras: Vec<String>,
    },
    #[serde(rename_all = "camelCase")]
    FormatText {
        slide: usize,
        shape: u32,
        #[serde(default)]
        cell: Option<(usize, usize)>,
        #[serde(default)]
        bold: Option<bool>,
        #[serde(default)]
        italic: Option<bool>,
        #[serde(default)]
        underline: Option<bool>,
        #[serde(default)]
        size: Option<f32>,
        #[serde(default)]
        color: Option<u32>,
        #[serde(default)]
        align: Option<String>,
    },
    AddTextBox {
        slide: usize,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        #[serde(default)]
        text: String,
    },
    AddShape {
        slide: usize,
        preset: String,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    AddImage {
        slide: usize,
        path: String,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    DeleteShape {
        slide: usize,
        shape: u32,
    },
    MoveShape {
        slide: usize,
        shape: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    AddSlide {
        #[serde(default)]
        after: Option<usize>,
        #[serde(default)]
        layout: Option<String>,
    },
    DuplicateSlide {
        slide: usize,
    },
    DeleteSlide {
        slide: usize,
    },
    MoveSlide {
        from: usize,
        to: usize,
    },
    HideSlide {
        slide: usize,
        hidden: bool,
    },
    SetNotes {
        slide: usize,
        text: String,
    },
}

fn sniff_image(b: &[u8]) -> &'static str {
    if b.starts_with(&[0xFF, 0xD8]) {
        "jpeg"
    } else if b.starts_with(b"GIF8") {
        "gif"
    } else if b.starts_with(b"BM") {
        "bmp"
    } else {
        "png"
    }
}

fn edit_of(op: OpJson) -> Result<Edit, FfiError> {
    Ok(match op {
        OpJson::SetText { slide, shape, cell, paras } => Edit::SetText { slide, shape, cell, paras },
        OpJson::FormatText {
            slide,
            shape,
            cell,
            bold,
            italic,
            underline,
            size,
            color,
            align,
        } => Edit::FormatText {
            slide,
            shape,
            cell,
            patch: TextPatch {
                bold,
                italic,
                underline,
                size,
                color,
                align,
            },
        },
        OpJson::AddTextBox { slide, x, y, w, h, text } => Edit::AddTextBox { slide, x, y, w, h, text },
        OpJson::AddShape { slide, preset, x, y, w, h } => Edit::AddShape { slide, preset, x, y, w, h },
        OpJson::AddImage { slide, path, x, y, w, h } => {
            let bytes = read_file(&path, MAX_IMAGE_BYTES)?;
            let ext = sniff_image(&bytes).to_owned();
            Edit::AddImage { slide, bytes, ext, x, y, w, h }
        }
        OpJson::DeleteShape { slide, shape } => Edit::DeleteShape { slide, shape },
        OpJson::MoveShape { slide, shape, x, y, w, h } => Edit::MoveShape { slide, shape, x, y, w, h },
        OpJson::AddSlide { after, layout } => Edit::AddSlide { after, layout },
        OpJson::DuplicateSlide { slide } => Edit::DuplicateSlide { slide },
        OpJson::DeleteSlide { slide } => Edit::DeleteSlide { slide },
        OpJson::MoveSlide { from, to } => Edit::MoveSlide { from, to },
        OpJson::HideSlide { slide, hidden } => Edit::HideSlide { slide, hidden },
        OpJson::SetNotes { slide, text } => Edit::SetNotes { slide, text },
    })
}

// --- Exports

/// Library version (static; do not free).
#[no_mangle]
pub extern "C" fn slide_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// This thread's last error, `"CODE: message"` (borrowed; do not free).
#[no_mangle]
pub extern "C" fn slide_last_error() -> *const c_char {
    last_error_ptr()
}

/// Free a string returned by this library.
///
/// # Safety
/// `ptr` must be NULL or a string from this library, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn slide_free_string(ptr: *mut c_char) {
    doc_ffi::free_c_string(ptr)
}

/// Open a deck (PPTX, PPTM, POTX, PPSX, ODP). `name` gives the file name;
/// NULL uses `path`. Returns a handle, or -1.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn slide_open(path: *const c_char, name: *const c_char) -> i64 {
    call_i64(|| {
        let path = str_arg(path, "path")?;
        let name = opt_str_arg(name, "name")?.unwrap_or(path);
        let bytes = read_file(path, MAX_FILE_BYTES)?;
        let d = slide_core::open(bytes, name).map_err(slide_error)?;
        Ok(DECKS.insert(d))
    })
}

/// A new deck with one title slide (16:9). Returns a handle.
#[no_mangle]
pub extern "C" fn slide_new() -> i64 {
    call_i64(|| Ok(DECKS.insert(slide_core::blank().map_err(slide_error)?)))
}

/// Close a deck. Returns 0, or -1 for an unknown handle.
#[no_mangle]
pub extern "C" fn slide_close(handle: i64) -> i64 {
    call_i64(|| {
        if DECKS.remove(handle) {
            Ok(0)
        } else {
            Err(FfiError::new(codes::BAD_HANDLE, format!("no open deck has handle {handle}")))
        }
    })
}

/// `{"format", "slideCount", "width", "height", "layouts": [{"id", "name"}],
/// "modified", "canUndo", "canRedo", "warnings"}`.
#[no_mangle]
pub extern "C" fn slide_info_json(handle: i64) -> *mut c_char {
    call_str(|| DECKS.with(handle, |d| to_json(&info(d))))
}

/// Slide `index` as a scene to draw.
#[no_mangle]
pub extern "C" fn slide_scene_json(handle: i64, index: i64) -> *mut c_char {
    call_str(|| {
        DECKS.with(handle, |d| {
            let s = d.scene(index.max(0) as usize).map_err(slide_error)?;
            to_json(&scene_json(&s))
        })
    })
}

/// Speaker notes of slide `index`.
#[no_mangle]
pub extern "C" fn slide_notes(handle: i64, index: i64) -> *mut c_char {
    call_str(|| DECKS.with(handle, |d| d.notes(index.max(0) as usize).map_err(slide_error)))
}

/// Apply an edit: `setText {slide, shape, cell, paras}`, `formatText {slide,
/// shape, cell, bold, italic, underline, size, color, align}`, `addTextBox
/// {slide, x, y, w, h, text}`, `addShape {slide, preset, x, y, w, h}`,
/// `addImage {slide, path, x, y, w, h}`, `deleteShape {slide, shape}`,
/// `moveShape {slide, shape, x, y, w, h}`, `addSlide {after, layout}`,
/// `duplicateSlide {slide}`, `deleteSlide {slide}`, `moveSlide {from, to}`,
/// `hideSlide {slide, hidden}`, `setNotes {slide, text}`. Returns `{"slide",
/// "shape"}`.
///
/// # Safety
/// `op_json` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn slide_apply(handle: i64, op_json: *const c_char) -> *mut c_char {
    call_str(|| {
        let op: OpJson = serde_json::from_str(str_arg(op_json, "op")?).map_err(|e| FfiError::invalid(format!("bad request: {e}")))?;
        let edit = edit_of(op)?;
        DECKS.with(handle, |d| {
            let r = d.apply(&edit).map_err(slide_error)?;
            to_json(&json!({"slide": r.slide, "shape": r.shape}))
        })
    })
}

/// Undo. Returns 1, or 0 when there is nothing to undo.
#[no_mangle]
pub extern "C" fn slide_undo(handle: i64) -> i64 {
    call_i64(|| DECKS.with(handle, |d| Ok(i64::from(d.undo()))))
}

/// Redo. Returns 1, or 0 when there is nothing to redo.
#[no_mangle]
pub extern "C" fn slide_redo(handle: i64) -> i64 {
    call_i64(|| DECKS.with(handle, |d| Ok(i64::from(d.redo()))))
}

/// Write a part of the deck (a picture) to `path`. Returns its length.
///
/// # Safety
/// String arguments must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn slide_part_save(handle: i64, part: *const c_char, path: *const c_char) -> i64 {
    call_i64(|| {
        let part = str_arg(part, "part")?;
        let path = str_arg(path, "path")?;
        DECKS.with(handle, |d| {
            let bytes = d.part(part).ok_or_else(|| FfiError::new(codes::NOT_FOUND, "that picture is not in the deck"))?;
            write_file_atomically(path, &bytes)?;
            Ok(bytes.len() as i64)
        })
    })
}

/// Every slide's text and notes, for sharing as text.
#[no_mangle]
pub extern "C" fn slide_text(handle: i64) -> *mut c_char {
    call_str(|| DECKS.with(handle, |d| Ok(d.plain_text())))
}

/// Save to `path` (atomically). Returns `{"format"}`.
///
/// # Safety
/// `path` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn slide_save(handle: i64, path: *const c_char) -> *mut c_char {
    call_str(|| {
        let path = str_arg(path, "path")?;
        DECKS.with(handle, |d| {
            let bytes = d.save().map_err(slide_error)?;
            write_file_atomically(path, &bytes)?;
            d.saved();
            to_json(&json!({"format": d.format().name()}))
        })
    })
}

/// Write a copy to `path` without marking the deck saved; `format` `txt`
/// writes the slides' text. Returns `{"format"}`.
///
/// # Safety
/// String arguments must be NULL or valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn slide_write_copy(handle: i64, path: *const c_char, format: *const c_char) -> *mut c_char {
    call_str(|| {
        let path = str_arg(path, "path")?;
        let format = opt_str_arg(format, "format")?;
        DECKS.with(handle, |d| {
            if format == Some("txt") {
                write_file_atomically(path, d.plain_text().as_bytes())?;
                return to_json(&json!({"format": "txt"}));
            }
            let bytes = d.save().map_err(slide_error)?;
            write_file_atomically(path, &bytes)?;
            to_json(&json!({"format": d.format().name()}))
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
        unsafe { slide_free_string(p) };
        s
    }

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn new_deck_edit_save_reopen() {
        let h = slide_new();
        assert!(h > 0, "{}", doc_ffi::last_error());
        let info: Json = serde_json::from_str(&take(slide_info_json(h))).unwrap();
        assert_eq!(info["slideCount"], json!(1));
        assert!(info["layouts"].as_array().unwrap().len() >= 4);
        let scene: Json = serde_json::from_str(&take(slide_scene_json(h, 0))).unwrap();
        let title = scene["items"].as_array().unwrap().iter().find(|i| i["placeholder"] == json!("ctrTitle")).unwrap().clone();
        assert_eq!(title["text"]["prompt"], json!("Tap to add a title"));
        let id = title["id"].as_u64().unwrap();
        let op = json!({"op": "setText", "slide": 0, "shape": id, "paras": ["Family budget"]});
        take(unsafe { slide_apply(h, c(&op.to_string()).as_ptr()) });
        let op = json!({"op": "addSlide", "after": 0});
        let r: Json = serde_json::from_str(&take(unsafe { slide_apply(h, c(&op.to_string()).as_ptr()) })).unwrap();
        assert_eq!(r["slide"], json!(1));
        let op = json!({"op": "addShape", "slide": 1, "preset": "rightArrow", "x": 100, "y": 100, "w": 200, "h": 80});
        take(unsafe { slide_apply(h, c(&op.to_string()).as_ptr()) });

        let dir = std::env::temp_dir().join(format!("slide_ffi_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("budget.pptx");
        let p = c(path.to_str().unwrap());
        let saved: Json = serde_json::from_str(&take(unsafe { slide_save(h, p.as_ptr()) })).unwrap();
        assert_eq!(saved["format"], json!("pptx"));
        assert_eq!(slide_close(h), 0);

        let h2 = unsafe { slide_open(p.as_ptr(), std::ptr::null()) };
        assert!(h2 > 0, "{}", doc_ffi::last_error());
        let info: Json = serde_json::from_str(&take(slide_info_json(h2))).unwrap();
        assert_eq!(info["slideCount"], json!(2));
        let text = take(slide_text(h2));
        assert!(text.contains("Family budget"), "{text}");
        let scene: Json = serde_json::from_str(&take(slide_scene_json(h2, 1))).unwrap();
        assert!(scene["items"].as_array().unwrap().iter().any(|i| i["paths"][0]["d"].as_str().is_some_and(|d| d.starts_with("M 0 "))));
        assert_eq!(slide_close(h2), 0);
        std::fs::remove_dir_all(&dir).ok();
    }
}
