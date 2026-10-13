# flutter_word_core

DocHelper's word-processing engine, written from scratch in Rust, with a
Dart API over `dart:ffi`.

`rust/crates/word_core`:

| Module | What it does |
| --- | --- |
| `tree` | The body as a tree of paragraphs and containers (tables, rows, cells, content controls, lists), each paragraph still the XML element it was read as |
| `view` | What the screen sees: paragraphs of styled text and objects, tables, lists, page setup |
| `projected` | Objects, invisible markers and run formats a paragraph had, and where markers go after an edit |
| `document` | The format-neutral document: block windows, edits (`Edit`) with undo and redo, find and replace, outline, word count |
| `docx` | Word documents: styles (defaults, chains, themes), numbering and list labels, paragraphs read and written back with their original run properties, tables, pictures, links; saved in place |

An edit replaces whole paragraphs with new content (`SetParas`): the
paragraph keeps its element and properties, text that looks like an
original run reuses that run's properties, objects (pictures, fields,
footnote marks) move as they are, and bookmarks and comment anchors go back
where their characters went. Everything else in the package is copied
byte for byte.

`rust/crates/word_ffi` exports the engine to Dart (`word_open`,
`word_blocks_json`, `word_apply`, `word_save`, ...). `lib/` holds the Dart
API: `WordCore.open/create` return a `WordDocument`.

```bash
(cd rust && cargo test)
cargo run --release --example wordcli -- dump letter.docx   # from rust/
```
