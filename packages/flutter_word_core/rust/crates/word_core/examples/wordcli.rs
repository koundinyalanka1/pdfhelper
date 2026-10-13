//! Try the engine on real files.
//!
//! ```text
//! cargo run --example wordcli -- dump FILE
//! cargo run --example wordcli -- text FILE
//! cargo run --example wordcli -- demo FILE OUT    (a few edits, then save)
//! ```

use word_core::view::{BlockView, Inline, InlineEdit, ParaPatch};
use word_core::{Edit, FindOptions, NewPara, TableOp};

fn dump(blocks: &[BlockView], indent: usize) {
    let pad = " ".repeat(indent);
    for b in blocks {
        match b {
            BlockView::Para(p) => {
                let label = p
                    .list
                    .as_ref()
                    .map(|l| format!("[{} L{}] ", l.text, l.level))
                    .unwrap_or_default();
                let lock = if p.editable { "" } else { " LOCKED" };
                println!(
                    "{pad}#{} {} ({:?}){lock}: {label}{:?}",
                    p.id,
                    p.style.style_name,
                    p.style.align,
                    p.text()
                );
                for i in &p.inlines {
                    match i {
                        Inline::Text { text, style, link } => println!(
                            "{pad}    text {:?} b={} i={} u={} {}pt {} color={:?}{}",
                            text,
                            style.bold,
                            style.italic,
                            style.underline,
                            style.size,
                            style.font,
                            style.color,
                            link.as_ref()
                                .map(|l| format!(" link={l}"))
                                .unwrap_or_default()
                        ),
                        Inline::Object(o) => println!(
                            "{pad}    object #{} {:?} {:?} {}x{}",
                            o.id, o.kind, o.text, o.width, o.height
                        ),
                    }
                }
            }
            BlockView::Table(t) => {
                println!(
                    "{pad}table #{} cols {:?} borders {}",
                    t.id, t.col_widths, t.borders
                );
                for (r, row) in t.rows.iter().enumerate() {
                    for (c, cell) in row.cells.iter().enumerate() {
                        println!(
                            "{pad}  cell {r},{c} span {}x{} merged_up {} fill {:?}",
                            cell.col_span, cell.row_span, cell.merged_up, cell.fill
                        );
                        dump(&cell.blocks, indent + 4);
                    }
                }
            }
            BlockView::Other { id, text } => println!("{pad}other #{id}: {text:?}"),
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("");
    let path = args.get(1).expect("a file");
    let bytes = std::fs::read(path).expect("readable file");
    let mut d = word_core::open(bytes, path).expect("opens");
    match cmd {
        "dump" => {
            let n = d.block_count();
            println!("{n} blocks, page {:?}", d.page_setup());
            let blocks = d.blocks(0, n);
            dump(&blocks, 0);
            println!(
                "styles: {:?}",
                d.styles()
                    .iter()
                    .map(|s| (&s.id, &s.name, s.defined))
                    .collect::<Vec<_>>()
            );
            println!("outline: {:?}", d.outline());
            println!("counts: {:?}", d.counts());
        }
        "text" => print!("{}", d.plain_text()),
        "demo" => {
            let out = args.get(2).expect("an output file");
            let n = d.block_count();
            let blocks = d.blocks(0, n);
            let paras: Vec<_> = blocks
                .iter()
                .filter_map(|b| match b {
                    BlockView::Para(p) if p.editable && !p.text().is_empty() => Some(p.clone()),
                    _ => None,
                })
                .collect();
            // Type at the end of the first paragraph, in bold.
            let p = &paras[0];
            let mut inlines: Vec<InlineEdit> = p
                .inlines
                .iter()
                .map(|i| match i {
                    Inline::Text { text, style, link } => InlineEdit::Text {
                        text: text.clone(),
                        style: style.clone(),
                        link: link.clone(),
                    },
                    Inline::Object(o) => InlineEdit::Object(o.id),
                })
                .collect();
            let mut bold = p.style.mark.clone();
            bold.bold = true;
            inlines.push(InlineEdit::Text {
                text: " (edited)".into(),
                style: bold,
                link: None,
            });
            d.apply(Edit::SetParas {
                first: p.id,
                last: p.id,
                paras: vec![NewPara {
                    inlines,
                    style: None,
                }],
            })
            .unwrap();
            // Split the second paragraph in two.
            if let Some(p) = paras.get(1) {
                let text = p.text();
                let half = text
                    .char_indices()
                    .nth(text.chars().count() / 2)
                    .map_or(0, |(i, _)| i);
                let style = match &p.inlines[0] {
                    Inline::Text { style, .. } => style.clone(),
                    _ => p.style.mark.clone(),
                };
                d.apply(Edit::SetParas {
                    first: p.id,
                    last: p.id,
                    paras: vec![
                        NewPara {
                            inlines: vec![InlineEdit::Text {
                                text: text[..half].into(),
                                style: style.clone(),
                                link: None,
                            }],
                            style: None,
                        },
                        NewPara {
                            inlines: vec![InlineEdit::Text {
                                text: text[half..].into(),
                                style,
                                link: Some("https://example.com/".into()),
                            }],
                            style: None,
                        },
                    ],
                })
                .unwrap();
            }
            // Make the third a heading, centre the fourth, bullet the last two.
            if let Some(p) = paras.get(2) {
                d.apply(Edit::Patch {
                    ids: vec![p.id],
                    patch: ParaPatch {
                        style_id: Some("Heading2".into()),
                        ..ParaPatch::default()
                    },
                })
                .unwrap();
            }
            if let Some(p) = paras.get(3) {
                d.apply(Edit::Patch {
                    ids: vec![p.id],
                    patch: ParaPatch {
                        align: Some(word_core::view::Align::Center),
                        ..ParaPatch::default()
                    },
                })
                .unwrap();
            }
            let tail: Vec<u32> = paras.iter().rev().take(2).map(|p| p.id).collect();
            d.apply(Edit::Patch {
                ids: tail,
                patch: ParaPatch {
                    list: Some("number".into()),
                    ..ParaPatch::default()
                },
            })
            .unwrap();
            // A table after the first paragraph, with a row and a column added.
            d.apply(Edit::InsertTable {
                after: paras[0].id,
                rows: 2,
                cols: 2,
            })
            .unwrap();
            let n = d.block_count();
            let table = d.blocks(0, n).into_iter().find_map(|b| match b {
                BlockView::Table(t) => Some(t.id),
                _ => None,
            });
            if let Some(t) = table {
                d.apply(Edit::Table {
                    id: t,
                    op: TableOp::InsertRow { at: 0, below: true },
                })
                .unwrap();
                d.apply(Edit::Table {
                    id: t,
                    op: TableOp::InsertCol { at: 0, right: true },
                })
                .unwrap();
            }
            let r = d
                .apply(Edit::ReplaceAll {
                    find: "the".into(),
                    replace: "THE".into(),
                    options: FindOptions::default(),
                })
                .unwrap();
            println!("replaced {}", r.count);
            d.apply(Edit::InsertPageBreak { after: paras[0].id })
                .unwrap();
            let (bytes, format) = d.save().unwrap();
            std::fs::write(out, bytes).unwrap();
            println!("saved as {format:?}");
            // Undo everything and check nothing is left over.
            while d.undo().unwrap() {}
            let again = d.plain_text();
            let orig = word_core::open(std::fs::read(path).unwrap(), path)
                .unwrap()
                .plain_text();
            println!("undo restores text: {}", again == orig);
        }
        _ => eprintln!("commands: dump, text, demo"),
    }
}
