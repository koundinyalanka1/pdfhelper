# DocHelper plan

PDF Helper becomes **DocHelper**: one phone app for reading, editing, creating,
converting and sharing documents of every common kind. It is built for someone
who does real office work on a phone instead of a laptop.

This file is the plan and the progress record. It is updated as work lands.
See the [progress log](#progress-log) at the end.

Last updated: 2026-10-13 (phases 0-3 done; phase 4 started).

## 1. What "done" looks like

The app is finished when these everyday jobs work on the phone, offline, without
damaging the files:

1. **A Word letter arrives on WhatsApp.** Open it from WhatsApp, read it
   comfortably, correct a few lines, and send it back as `.docx` or PDF.
   Formatting he did not touch stays exactly as it was.
2. **An Excel sheet with formulas** (accounts, lists, bills). Change numbers and
   watch totals recalculate. Add a row, save as `.xlsx`, and the next person
   opens it in Excel without a repair warning.
3. **A PowerPoint deck.** View the slides, fix a typo, reorder slides, and
   export a PDF.
4. **A PDF form.** Fill it in, sign it, save it and share it.
5. **A text or CSV file.** Open, edit, and save it in its original encoding and
   line endings.
6. **Something new:** a letter, a sheet, a presentation or a note, started from
   blank.
7. **WPS Office and LibreOffice files** (`.wps/.et/.dps`, `.odt/.ods/.odp`)
   open too. ODF saves back as ODF. Old binary formats (`.doc/.xls/.ppt` and
   WPS's binary files) save as their modern equivalents, and the app says so.
8. **Anything else** (images, ZIP archives, unknown files) can at least be
   viewed, unpacked, shared or handed to another app.

## 2. Ground rules

- **Everything is written in Rust from scratch**: every engine and its FFI
  layer. No C or C++ code is written or vendored. `extern "C"` on the exported
  Rust functions is only the calling convention `dart:ffi` needs. No third-party
  document libraries: no ZIP, XML, OLE2, Office, ODF, spreadsheet or font
  crates. The only crates allowed are the small, audited primitives the PDF
  engine already uses: `flate2` (deflate), RustCrypto (`aes`, `cbc`, `sha2`,
  `md-5`) for encrypted files, `serde`/`serde_json` at the FFI boundary, and
  `thiserror`. Fonts we bundle are data (open-licensed font files), not
  engines.
- **One library per kind of file** (the user's instruction, 2026-10-13). Each
  is a self-contained Flutter FFI plugin with its own Dart API, Rust
  workspace and native library, as `flutter_pdf_core` already is for PDF.
  Code that every format needs (ZIP, XML, OLE2 containers, text encodings,
  and later fonts, layout and PDF output) is a shared Rust-only library that
  each one links in.
- **Never damage a file.**
  - Unknown content is carried through untouched.
  - A save writes a temporary file, reopens it to verify, keeps a backup of
    the original, and only then replaces it.
  - "Save a copy" is always offered.
  - A format we can read but not write (legacy binaries) saves as its modern
    equivalent, and the app says so plainly.
- **Phone-first, plain-spoken UI.** Large touch targets, a reading view that
  reflows to the screen, autosaved drafts, and undo everywhere.
- **Private.** Everything runs on the device; nothing is uploaded.
- **Android first** (the current release scope); iOS follows later.

## 3. Architecture

### 3.1 Libraries

| Library | Path | Native library | Formats | Dart API |
| --- | --- | --- | --- | --- |
| PDF | `packages/flutter_pdf_core` (submodule, existing) | `libpdf_ffi` | PDF | `PdfCore` |
| Spreadsheets | `packages/flutter_sheet_core` | `libsheet_ffi` | `.xlsx .xlsm .xltx`, `.ods .fods`, `.csv .tsv`, `.xls`, WPS `.et` | `SheetCore` |
| Word processing | `packages/flutter_word_core` | `libword_ffi` | `.docx .docm .dotx`, `.odt .fodt`, `.rtf`, `.doc`, WPS `.wps` | `WordCore` |
| Presentations | `packages/flutter_slide_core` | `libslide_ffi` | `.pptx .ppsx .potx`, `.odp .fodp`, `.ppt`, WPS `.dps` | `SlideCore` |
| Plain text | `packages/flutter_text_core` | `libtext_ffi` | `.txt .log .md .json .xml .html .ini .yaml`, source code, any text | `TextCore` |
| Archives (later) | `packages/flutter_archive_core` | `libarchive_ffi` | `.zip` (browse, extract, create) | `ArchiveCore` |
| Shared (Rust only) | `packages/doc_common` | linked into each | ZIP, XML, OLE2/CFB, text encodings; later fonts, layout, PDF writer, images | — |

Crates inside each library follow one pattern:

- `<kind>_core`: the model, readers, writers and editing.
- `<kind>_ffi`: the FFI layer, written in Rust. Its functions are exported
  with `extern "C"`, the calling convention `dart:ffi` uses. There is no C
  code.
- `<kind>_cli`: a developer tool for trying real files.

The shared crates are:

- `doc_zip`, `doc_xml`, `doc_cfb` and `doc_encoding` (phase 1).
- `doc_font`, `doc_layout`, `doc_pdf` and `doc_image` (phase 6).

### 3.2 How the app talks to an engine

- **Sessions.** Editing needs the document to stay in memory, so these
  libraries use handles, not one file per call. Each library follows the
  same call pattern:
  1. `open(path, password)` returns a handle and a summary.
  2. Queries return what the screen needs: a window of cells, a block of
     paragraphs, the shapes on a slide.
  3. Edits are sent as small JSON operations. Each one returns what changed
     and is recorded for undo and redo.
  4. `save(handle, path, format)` writes the file.
  5. `close(handle)` frees the session.
- **Conventions copied from the PDF engine.**
  - Strings are UTF-8.
  - `*_last_error` reports failures with stable codes.
  - Panics are caught at the boundary.
  - Every input is bounded: decompressed sizes, cell counts and nesting
    depth all have limits.
- **Threads.** Sessions are process-global and locked per session. Small
  queries run on the UI isolate (they take under a millisecond). Opening,
  saving, recalculating and rendering run on a background isolate.
- **Page views.** A Word document's print layout, a slide, and a sheet's
  print preview are all produced as PDF by the shared layout and PDF writer.
  The existing PDF viewer then displays them. One path covers the page view,
  "Export PDF", printing and "Share as PDF", and it reuses the mature PDF
  rasterizer.

### 3.3 Keeping files intact (round-trip)

OOXML and ODF documents are ZIP packages of XML parts. Fidelity comes from
editing in place, not from rebuilding the file:

- **Parts we don't edit** are copied byte for byte, still compressed.
- **XML parts we edit** are parsed into a tree that keeps every element,
  attribute, namespace prefix, comment and whitespace run. Only the nodes
  that change are rewritten.
- **Unedited paragraphs** in a Word file serialize identically. Charts,
  pivot tables, macros (`.xlsm`/`.docm`, kept and never run), comments and
  anything else we don't model survive a save.
- **Spreadsheet cells.**
  - Cells are regenerated from the model with fresh cached values.
  - Every other worksheet element stays untouched.
  - `calcChain.xml` is dropped, so Excel rebuilds it.

## 4. The libraries in detail

### 4.1 Shared: `doc_common`

- **`doc_zip`.**
  - Reader: central directory, ZIP64, stored and deflate, data
    descriptors, CRC-32 checks, and limits on size and compression ratio
    (zip bombs).
  - Writer: keeps the original entry order and copies untouched entries
    raw. ODF's `mimetype` entry stays first and uncompressed.
- **`doc_xml`.**
  - A pull tokenizer, plus a tree that round-trips exactly.
  - Namespaces are resolved by URI, not by prefix.
  - Only the predefined entities and character references are expanded.
    The DTD is skipped, so XXE and "billion laughs" attacks don't apply.
- **`doc_cfb`.** OLE2 compound files (FAT, DIFAT, mini stream, directory
  tree), for `.doc/.xls/.ppt`, WPS binaries and password-protected OOXML.
- **`doc_encoding`.**
  - UTF-8 and UTF-16LE/BE, with or without a BOM.
  - Windows-125x, ISO-8859-x, CP437/850 and Mac Roman.
  - Detection heuristics.
  - CJK multi-byte encodings come later.
- **Later (phase 6).**
  - `doc_font`: sfnt tables, metrics, cmap, kerning and subsetting, with
    TrueType and CFF outlines.
  - `doc_layout`: line breaking, font fallback, paragraphs, tables and
    pagination.
  - `doc_pdf`: a PDF writer with subset Type0 fonts, ToUnicode maps,
    JPEG passthrough and PNG to Flate.
  - `doc_image`: PNG decoding and image headers.

### 4.2 Spreadsheets: `flutter_sheet_core`

- **Model.**
  - A workbook holds sheets, interned strings, a style table, defined
    names and the date system (1900 or 1904).
  - A sheet holds sparse cells, column widths, row heights, hidden rows and
    columns, merges and frozen panes. It also carries conditional formats,
    validations, hyperlinks and comments, which are kept as is.
- **Readers and writers.**
  - XLSX: read and write.
  - ODS: read and write; OpenFormula is translated to and from Excel syntax.
  - CSV/TSV: read and write, with delimiter and encoding detection.
  - XLS (BIFF8) and WPS `.et`: read only (phase 7), saved as `.xlsx`.
- **Formulas.**
  - The parser covers the full A1 grammar: sheet references, absolute
    references, whole rows and columns, names, arrays, `_xlfn.` prefixes,
    and the union and intersection operators.
  - The evaluator follows Excel's coercion and error rules, and implicit
    intersection.
  - A dependency graph drives recalculation and catches circular
    references.
  - About 150 functions in the first set: maths and statistics, logic,
    lookup (`VLOOKUP`, `XLOOKUP`, `INDEX/MATCH`), text, date and time,
    information, and finance (`PMT`, `NPV`, `IRR`).
  - A function we don't know keeps its formula and last cached value
    rather than breaking the cell.
- **Number formats.**
  - The complete Excel format-code language: sections, conditions, colours,
    dates and times, elapsed time, fractions, scientific notation, text and
    literals.
  - Excel's "General" rendering rules.
  - Built-in format ids.
  - Indian lakh/crore grouping offered as a ready-made format.
- **Editing.**
  - Typed input is parsed as Excel does (formulas, numbers, percentages,
    dates and booleans).
  - Insert and delete rows and columns, with references adjusted
    everywhere.
  - Fill down and right, copy and paste with relative references, clear,
    and sort.
  - Formatting: bold, italic, underline, size, colours, fill, borders,
    alignment, wrap, number format, merge, column width and row height.
  - Freeze panes.
  - Sheets: add, rename, delete, move and duplicate.
  - Find and replace.
  - Undo and redo.
- **Screen.**
  - A virtualized grid with column and row headers, pinch zoom, and cell
    and range selection.
  - A formula bar with a function picker, AutoSum, sheet tabs and a
    formatting toolbar.
  - Save, Share and Export PDF.

### 4.3 Word processing: `flutter_word_core`

- **Model.**
  - Body blocks: paragraphs and tables.
  - Sections: page size, margins, headers and footers.
  - Styles with inheritance: document defaults, then the style chain, then
    direct formatting.
  - Numbering, images, hyperlinks, fields (shown with their cached result),
    and bookmarks.
  - Footnotes, comments and tracked changes are kept intact, and shown
    later.
- **Readers and writers.**
  - DOCX: in-place editing of `document.xml`.
  - ODT: the same approach.
  - RTF: read and write.
  - TXT and Markdown: import.
  - DOC (Word 97–2003) and WPS `.wps`: read only (phase 7), saved as
    `.docx`.
- **Editing.**
  - Paragraph text and inline formatting: bold, italic, underline, strike,
    size, colour and highlight.
  - Paragraph format: alignment, headings, bullet and numbered lists,
    indent, line spacing and page breaks.
  - Insert and delete paragraphs, tables and images.
  - Find and replace, word count, undo and redo.
  - New paragraphs inherit the formatting of the paragraph they come from.
- **Screen.**
  - A reflowing reading view, with headings, lists, tables and images
    fitted to the phone's width.
  - Tap a paragraph to edit it with a formatting toolbar.
  - "Page view" shows the true print layout (phase 6).
  - Save, Share as `.docx` or PDF.

### 4.4 Presentations: `flutter_slide_core`

- **Model.**
  - Slide size; slides in their order; layouts, masters and the theme
    (colours, fonts, effects).
  - The shape tree: shapes, pictures, groups, connectors, tables and
    graphic frames.
  - Speaker notes.
  - Charts are kept, and drawn from their cached image or as a placeholder
    until charts are supported.
- **Readers and writers.**
  - PPTX: in-place editing.
  - ODP: read, then write.
  - PPT and WPS `.dps`: read only (phase 7), saved as `.pptx`.
- **Rendering.** Each slide becomes a scene:
  - Placeholder inheritance across slide, layout and master is resolved.
  - Theme colours and their modifiers are applied.
  - The common preset shapes are drawn, along with custom geometry.
  - Fills and lines are drawn: solid, gradient and picture fills, dashes and
    arrowheads.
  - Text autofit and bullets are handled.

  The scene is written as PDF and shown by the PDF renderer. Tapping a shape
  uses the scene's geometry to find it.
- **Editing.** Text in shapes and placeholders; add, duplicate, delete, hide
  and reorder slides; a new slide from a layout; speaker notes; undo and
  redo.
- **Screen.** A slide strip and a large slide view, with a full-screen
  presenter mode. Save, Share and Export PDF.

### 4.5 Plain text: `flutter_text_core`

- **Encodings.** Detection and conversion, and saving back in the original
  encoding, BOM and line endings.
- **Large files.** Files up to tens of MB are edited through a piece table.
  Anything bigger opens in a read-only paged view.
- **Search.**
  - Find and replace: plain, case-insensitive and whole-word.
  - Our own regex engine comes later.
- **Formats.** JSON validation and pretty-printing. Syntax highlighting for
  common formats comes later. Markdown preview comes later.
- **Screen.** Editor with word wrap, font size, line numbers, go-to-line,
  find and replace, and an encoding and line-ending picker; save and share.

### 4.6 PDF additions (in `flutter_pdf_core`)

- **Annotate.** Highlight, underline and strike out from a selection;
  freehand ink; text boxes; sticky notes; shapes. Each is written with an
  appearance stream.
- **Forms.** Fill text, checkbox, radio and choice fields, and generate their
  appearances.
- **Sign.** Draw or pick a signature and place it as a stamp. This is a
  visible signature, not a cryptographic one.
- **Stamp onto pages.** Add text and images, page numbers, a watermark, and
  headers and footers.
- **Compress.** Re-encode images with our own JPEG encoder.
- **Convert.** Turn pages into images. PDF to Word comes later, built on the
  text layout.

### 4.7 The app

- **Rename to DocHelper.** Launcher label, titles, splash, dialogs,
  notifications and the public save folder (`Download/DocHelper`,
  `Documents/DocHelper`) all change.
- **What stays the same, deliberately.**
  - Android `applicationId` `com.yourmateapps.pdfhelper` stays. The Play
    listing, Firebase and AdMob are keyed to it, and installed copies keep
    updating.
  - The Dart package name, internal channel names and private working
    folders stay too.
  - Old `PDFHelper` public folders keep working.
- **File kinds.**
  - A `DocKind` (pdf, word, sheet, slides, text, image, archive, other) is
    detected from content first, then the extension, then the MIME type.
  - Each kind has its own icon, colour and screen.
- **Files tab.**
  - Discovers every supported kind, with filter chips (All, PDF, Word,
    Excel, PowerPoint, Text, Other).
  - The scan cache gets a schema version, so older caches are rebuilt.
- **Open with.**
  - Intent filters cover every supported MIME type and extension.
  - The Kotlin resolver accepts each kind after checking its signature, and
    keeps the original extension.
  - `ACTION_EDIT` writes back to the source when the sender grants that.
- **New.** Blank document, spreadsheet, presentation and text note.
- **Saving.**
  - Save back to the original when it is a writable local file (with a
    verified backup); otherwise save to `Documents/DocHelper`.
  - Save as another format, Share, and Export PDF.
  - Drafts are autosaved, and recovered after a crash.
- **Tools tab.**
  - A Convert section: Word, Excel, PowerPoint or text to PDF; Excel to
    and from CSV; ODF to and from OOXML; PDF to images or text.
  - A New section.
  - The existing PDF tools.

## 5. Phases

Status: `[ ]` not started · `[~]` in progress · `[x]` done.

| # | Phase | Status |
| --- | --- | --- |
| 0 | Plan, rename to DocHelper | [x] |
| 1 | Shared foundation (`doc_zip`, `doc_xml`, `doc_encoding`); scaffolding for the four libraries; build script and Android preflight | [x] |
| 2 | Text library and text editor; app-wide file kinds, discovery, "Open with" and routing | [x] |
| 3 | Spreadsheet library v1 (XLSX/CSV/ODS, formulas, number formats) and spreadsheet screen | [x] |
| 4 | Word library v1 (DOCX/ODT/RTF, in-place editing) and document screen | [~] |
| 5 | Presentation library v1 (PPTX/ODP, scene, text edits, slide operations) and slides screen | [ ] |
| 6 | Fonts, layout and PDF writer: Word page view and export; sheet and slide export | [ ] |
| 7 | Legacy binaries through `doc_cfb`: XLS, DOC, PPT and WPS `.et/.wps/.dps` | [ ] |
| 8 | PDF editing: annotate, sign, fill forms, stamp, compress, convert pages to images | [ ] |
| 9 | Other files: images, ZIP archives, Markdown, HTML and JSON viewers, unknown files | [ ] |
| 10 | Hardening: a real-world corpus per format, fuzzing, memory and time limits, device runs, accessibility, release | [ ] |

### How each phase is verified

- Rust unit tests for every reader, writer and function.
- Round-trip tests: open, save, reopen and compare. Unedited parts must be
  byte-identical.
- The app's widget tests, with every native library loaded through
  `*_CORE_LIB_PATH` on macOS.
- Real-world files collected into `test_corpus/<kind>/`, as already done for
  PDF, with a sweep that must never hang or panic.
- Checks on the emulator (`pdfhelper_api36_16kb`) before the phones.
- Files saved by DocHelper are checked in a reference application
  (LibreOffice headless, where installed) to confirm they open without
  repair.

## 6. Decisions for the owner

Item 1 is settled. The others are defaults in effect, and each is easy to
change.

1. **Settled by the owner (2026-10-13): never change the package name.**
   `com.yourmateapps.pdfhelper` stays everywhere: the Android
   `applicationId`, the namespace and Kotlin package, and the iOS bundle ID.
   AdMob and Google Play are linked to it. The Dart package name `pdfhelper`
   stays as well. Only the app's name and other visible text change.
2. **New public saves go to `…/DocHelper`.** Existing `PDFHelper` copies stay
   where they are.
3. **The new native binaries are built locally and git-ignored for now.**
   Committing them as `flutter_pdf_core` does would add about 30 MB to the
   history on every rebuild. Git LFS is the alternative.
4. **Bundle metric-compatible open fonts** (Carlito for Calibri, Caladea for
   Cambria, Liberation for Arial, Times and Courier; about 5 MB), so that
   Office documents break lines where Word does. This is proposed for
   phase 6.
5. **The new libraries live in this repository for now.** Each can move to
   its own repository and submodule later, as `flutter_pdf_core` did.
6. **Legacy binary formats** (`.doc/.xls/.ppt`, WPS binaries) are read, and
   saved as `.docx/.xlsx/.pptx`. Writing the old binaries is out of scope.
7. **Commit the PDF engine's open viewer-speed work before phase 8.** Phase 8
   changes that repository.

## 7. Risks

- **Scope.** This is the size of an office suite. Work goes in the order the
   everyday jobs in section 1 need it. Sample files from the real user should
   steer priorities.
- **Complex scripts in our own layout.** Telugu, Devanagari and Arabic need a
   shaping engine for page view and PDF export. The reflowing reading view
   uses Flutter's text engine, which already shapes them correctly. Our own
   shaper is planned after phase 6.
- **Visual fidelity** against Microsoft Office: fonts, theme effects and
   charts. This is measured on the corpus, not assumed.
- **Data safety:** handled by verified saves, backups and round-trip tests.
- **App size.** Four more native libraries and the bundled fonts. Size is
   tracked per library.
- **iOS.** Several Rust static libraries cannot be linked into one iOS
   binary, because their standard-library symbols clash. iOS needs an
   umbrella static library that combines the FFI crates. The libraries stay
   separate in source and on Android.

## 8. Phase 3 design notes (spreadsheet engine)

Written at the 2026-10-13 checkpoint so that the next session (a cloud
session) can continue without anything outside this repository.

### 8.1 Files and their state

All paths are under `packages/flutter_sheet_core/rust/crates/sheet_core/src/`.

| File | State |
| --- | --- |
| `refs.rs` | Done. `CellRef`/`Range` (0-based), A1 parsing, column letters, `quote_sheet_name` |
| `value.rs` | Done. `Value` (`Empty`/`Number`/`Text(Arc<str>)`/`Bool`/`Error`), `CellError`, coercions, `compare` (numbers before text before booleans, case-insensitive text, 15 digits), `parse_number`, `number_to_text`, `round15` |
| `datetime.rs` | Done. Serials for the 1900 system (with the phantom 1900-02-29) and the 1904 system, DATE overflow rules, weekdays, time of day |
| `numfmt/` | Done. Format-code parser (`parse.rs`) and formatter (`mod.rs`); `FormatOptions` (`DateOrder`, `date1904`); `builtin_format(id)`; `INDIAN_NUMBER_FORMAT`/`INDIAN_RUPEE_FORMAT`; `round_half_away` |
| `input.rs` | Done. `parse_input` for typed text, giving a formula, a number with a suggested format, text, a boolean or an error; `parse_date_time`/`parse_date`/`parse_time` |
| `formula/ast.rs`, `parser.rs`, `unparse.rs`, `adjust.rs` | Done. `parse`, `unparse`, `unparse_ooxml` (adds `_xlfn.`), `shift_references`, `offset_references`, `move_block`, `rename_sheet`, `invalidate_sheet` |
| `formula/eval.rs` | Written, not in the build yet (see `formula/mod.rs`) |
| `formula/functions/mod.rs` | Written (dispatch, `KNOWN` names, `arity`, `tri!`, helpers), not in the build. Missing: `criteria.rs`, `logic.rs`, `math.rs`, `stats.rs`, `lookup.rs`, `text.rs`, `date.rs`, `info.rs`, `finance.rs`, `tests.rs` |

### 8.2 The evaluator (`eval.rs`, as written)

- **The `Grid` trait** is what the calculation engine provides:
  - `value(sheet, cell)` computes a dirty formula cell on demand.
  - `cells_in(sheet, range)` returns only the non-empty cells.
  - `used_range`, `sheet_index`, `defined_name`, `format_options`, `now`,
    `random` and `formula_text`.
- **`Eval`** is a `Value`, a `Ref(Vec<SheetArea>)` (a union is several
  areas) or an `Array`.
- **`Evaluator::evaluate`** returns what the cell shows:
  - An empty result shows as 0.
  - A reference or array result gives its top-left value. Spilling is not
    supported yet.
  - A range used where one value is expected takes Excel's implicit
    intersection with the formula's own row or column (`scalar`).
- **Operators.** Binary operators go through `lift2`. When either side is a
  multi-cell range or array they work element by element with broadcasting
  (out-of-shape elements give `#N/A`), so `SUMPRODUCT((A1:A9>5)*B1:B9)`
  works. `:`, `,` and space are reference operators.
- **Helpers for functions:**
  - `numbers(args)`: SUM rules. Typed text and booleans are converted;
    inside references they are skipped; the first error wins.
  - `numbers_a(args)`: the *A rules.
  - `flatten`.
  - `to_array`, which clips whole rows and columns to the used range.
  - `reference_arg`, `number_or` and `bool_or`.
- **Flags.** `unsupported` is set by unknown functions and structured
  references (tables). `volatile` should be set by NOW, TODAY, RAND,
  RANDBETWEEN, OFFSET and INDIRECT.

### 8.3 The function library (to write)

The about 180 names in `functions::KNOWN`, one module per category, each
exposing `pub fn call(ev, name, args) -> Option<Eval>`. Excel details to
match:

- **Rounding.**
  - ROUND, ROUNDUP and ROUNDDOWN use the 15-digit decimal value:
    `numfmt::round_half_away`, so ROUND(2.675, 2) = 2.68. Apply `round15`
    before ROUNDUP and ROUNDDOWN.
  - MOD takes the sign of the divisor: n − d·INT(n/d).
  - The CEILING/FLOOR variants each have their own sign rules.
- **Criteria** (COUNTIF, SUMIF, AVERAGEIF, the *IFS functions, MAXIFS,
  MINIFS):
  - An operator prefix: `<= >= <> < > =`.
  - A numeric operand compares numbers, and also text that reads as the
    same number.
  - Dates written in criteria (`">=1/1/2026"`) go through
    `input::parse_date` in the locale's order.
  - TRUE/FALSE and error operands match those values.
  - Text operands are case-insensitive, with `*`, `?` and `~` wildcards for
    `=` and `<>`.
  - `""` matches blanks; `"<>"` matches non-blanks.
- **The *IFS functions** align every range to the first range's clipped
  shape.
- **Lookups.**
  - VLOOKUP and HLOOKUP: TRUE means approximate (the largest value <= the
    lookup value, data assumed sorted); FALSE means exact, case-insensitive,
    with wildcards.
  - MATCH types 1, 0 and −1.
  - XMATCH and XLOOKUP match modes 0, −1, 1 and 2, and search modes ±1 and
    ±2.
  - INDEX returns a reference (`Eval::Ref`), so `A1:INDEX(...)` works.
  - OFFSET and INDIRECT return references and are volatile.
- **Text.**
  - Positions (LEN, LEFT, MID, FIND...) count characters. Excel counts
    UTF-16 units, which differs only for emoji.
  - FIND is case-sensitive; SEARCH is case-insensitive and supports
    wildcards.
  - TEXT uses `numfmt` with the grid's `FormatOptions`.
  - VALUE, DATEVALUE and TIMEVALUE use `value::parse_number` and `input`.
- **Dates.** DATE uses `datetime::date_to_serial` (overflow rules).
  EDATE/EOMONTH, DATEDIF ("Y", "M", "D", "MD", "YM", "YD"), NETWORKDAYS
  and WORKDAY (and their .INTL forms, with weekend codes or masks),
  YEARFRAC bases 0–4, WEEKNUM types and ISOWEEKNUM.
- **Finance.** PMT, IPMT, PPMT, FV, PV and NPER in closed form; RATE, IRR
  and XIRR by Newton's method with a bisection fallback. Return `#NUM!`
  when they do not converge.
- **Tests** pin each function to values Excel gives. That includes the
  quirks above, empty and error inputs, and `0.1+0.2-0.3` staying
  5.55E-17, as Excel shows it.

### 8.4 The workbook model and calculation (to write)

- **The model.**
  - `Workbook { sheets, styles, defined_names, date1904, active, source }`.
  - `Sheet { name, cells: BTreeMap<u32, BTreeMap<u32, Cell>>, col widths,
    row heights/hidden/styles (keep unknown row attributes), merges,
    freeze, state }`.
  - `Cell { value, formula: Option<{ text, expr, array range? }>, style:
    u32 }`, where `style` is the xf index.
- **Never recalculate on open.** Show the values the file was saved with,
  which are Excel's own.
- **After an edit**, recompute only the transitive dependents of the
  changed cells, in topological order, plus volatile cells:
  - Build the reverse dependency index lazily from `eval::static_areas`.
  - Keep ranges as a list per sheet and test containment; an interval tree
    can come later.
  - Read dynamic references (INDIRECT, OFFSET) on demand through
    `Grid::value`, with a depth limit.
  - Find cycles with Kahn's algorithm; the cells involved keep their values
    and are reported.
  - A formula that comes back `unsupported` keeps its previous (file)
    value.
- **On save, after any recalculation**, set
  `<calcPr fullCalcOnLoad="1"/>` so that Excel recomputes everything.
- **Undo and redo.**
  - `CellsChange { sheet, before, after }` covers cell edits, formatting,
    paste, fill and sort.
  - Structural edits (insert or delete rows and columns, sheet operations)
    take a whole-model snapshot.
  - The memory used for undo is capped.
- **Inserting or deleting rows and columns** moves the cells, then runs
  `adjust::shift_references` over every formula in every sheet and over
  defined names. Merges, column widths and row heights move too.

### 8.5 XLSX (to write)

- **Reading.**
  1. `_rels/.rels` gives the workbook part, `xl/workbook.xml` the sheets
     (name, `r:id`, state), `workbookPr date1904`, `definedNames` and
     `bookViews activeTab`, and the workbook's rels give the sheet,
     sharedStrings and styles parts.
  2. Read `sharedStrings.xml` with the pull `Reader`. Keep the raw XML of
     any `<si>` that has rich runs, and decode `_xHHHH_` with
     `doc_xml::ooxml`.
  3. Parse `styles.xml` as a `doc_xml::Document`: number formats
     (`numFmt` plus the built-in ids), fonts, fills, borders and `cellXfs`.
     The DOM is kept for writing.
  4. In each worksheet, find `<sheetData>` by offsets with the pull reader.
     Everything before and after it is kept as a DOM, so `cols`,
     `sheetViews/pane`, `mergeCells` and `dimension` can be edited and
     everything else survives.
  5. Read the cells (`t` = `s`/`str`/`inlineStr`/`b`/`e`/`n`/`d`; `<f>` with
     `t="shared"` is expanded per cell with `offset_references`;
     `t="array"`).
- **Writing.**
  - Copy every unchanged part raw (`ZipWriter::copy_from`).
  - Regenerate `sheetData` (rows in order, cells with `r`, `s`, `t`, `<f>`
    from `unparse_ooxml`, and `<v>`).
  - Rebuild `sharedStrings`, re-emitting the raw XML of untouched rich
    strings.
  - Add new styles to the end of `styles.xml`; never renumber existing
    ones.
  - Update `dimension`, `workbook.xml` (sheet list, renamed names) and the
    relationships and content types of added or removed sheets.
  - Delete `calcChain.xml`, with its relationship and Override.
  - Write `xml:space="preserve"` on strings with leading or trailing
    spaces.
  - ZIP entries keep the original order.
- **Not handled yet**, but kept intact:
  - Charts, pivots and drawings are kept as raw parts.
  - `.xlsm` macros are kept, never run.
  - Tables (`xl/tables/*.xml`) are needed before structured references can
    be evaluated.
  - Encrypted OOXML (a CFB container) arrives with `doc_cfb` in phase 7.

### 8.6 CSV and ODS (to write)

- **CSV.**
  - The encoding comes from `doc_encoding::detect`.
  - The delimiter (`,` `;` tab `|`) is the one that splits the first lines
    into the most consistent field counts.
  - RFC 4180 quoting.
  - Keep each field's text exactly unless it was edited; numbers are read
    for display and formulas.
  - Save with the same delimiter, encoding and line endings. Warn that
    formulas and formatting are saved as values only.
- **ODS.**
  - Read `content.xml` tables, expanding `table:number-rows-repeated` and
    `number-columns-repeated`.
  - Values come from `office:value-type` with `office:value`,
    `date-value`, `time-value`, `boolean-value` and `string-value`.
  - Merges come from `number-columns-spanned`/`number-rows-spanned`.
  - Styles come from automatic styles and data styles.
  - Translate OpenFormula `of:=SUM([.A1:.B3];[Sheet2.C1])` to and from
    Excel syntax.
  - Writing regenerates the table bodies in `content.xml` and keeps the
    other parts. `mimetype` stays first and uncompressed.

### 8.7 The Rust FFI layer, the Dart API and the screen (to write)

- **`sheet_ffi`, on the pattern of `text_ffi`:**
  - `sheet_open(path, password)` and `sheet_new()` return a handle.
  - `sheet_info_json`: format, sheets (name, used range, frozen panes,
    hidden), warnings, `modified`, `canUndo`/`canRedo`.
  - `sheet_cells_json(handle, sheet, r0, c0, r1, c1)`: shown text, kind,
    style id and colour per non-empty cell, plus merges, column widths and
    row heights for the window.
  - `sheet_styles_json(ids)`: the resolved formats.
  - `sheet_cell_json` for the formula bar: what to edit (the formula, or
    the value as typed).
  - `sheet_set_cell(handle, sheet, r, c, input)`, which returns the
    changed cells.
  - `sheet_apply(handle, ops_json)` for structural and formatting
    operations.
  - `sheet_undo` and `sheet_redo`.
  - `sheet_save(handle, path, format)`.
  - `sheet_find_json`.
  - `sheet_format_preview(number, code)`.
- **The Dart API.** `SheetCore.open/create` returns a `SheetBook`, mirroring
  `TextCore`/`TextDocument`. It takes `SHEET_CORE_LIB_PATH` and runs heavy
  calls in `Isolate.run`.
- **The screen.**
  - A custom-painted, virtualized grid. It has frozen column and row
    headers, pinch zoom, and cell and range selection with handles. Fetch
    and cache windows of cells.
  - A formula bar with function hints. Enter commits and moves down.
  - A bottom toolbar: AutoSum, bold, italic, fill and text colour,
    alignment, number formats (General, Number, ₹ Indian, %, Date, Text),
    merge and wrap.
  - Row and column menus: insert, delete, hide, width and height. Sheet
    tabs: add, rename, delete, duplicate and move.
  - Find, then Save, Share and Export (CSV now, PDF in phase 6).
- **Wiring into the app:**
  - Add the screen to `DocumentRouter`.
  - Set `DocKind.sheet` to `canOpen`.
  - Add `.xlsx`, `.xls`, `.ods` and `.csv` to the manifest's "Open with"
    filters and to `OPENABLE_EXTENSIONS` in `MainActivity.kt`.
  - Add "New spreadsheet" to the Files tab's add sheet.
  - Add `sheet` to the preflight and `check_android_native.py`.

### 8.8 Checking the work

- Unit tests per module.
- XLSX round trips: open, save, reopen. Unchanged parts must be
  byte-identical, and values and formulas preserved.
- A sweep of `test_corpus/office` that must never panic or hang.
- When working on the owner's Mac, open saved files in the installed
  Microsoft Excel to confirm they open without a repair prompt.

## Progress log

- **2026-10-13.**
  - Plan written.
  - The user asked for a separate library per kind of file. The
    architecture above follows that.
  - Phase 0 done:
    - The app shows "DocHelper" everywhere a user sees its name: launcher,
      title, splash, settings, dialogs, notifications, iOS strings and the
      web, Linux and Windows window titles.
    - Public saves go to `Download/DocHelper` and `Documents/DocHelper`.
    - New launcher icons replace "PDF" with a generic page, on the same red,
      for Android (adaptive, monochrome and legacy) and iOS.
    - IDs, the Dart package name and private folders are unchanged.
    - 518 app tests pass.
  - The user confirmed: never change `com.yourmateapps.pdfhelper` (see
    §6, item 1). They also allowed renaming internal file names freely.
  - Phase 1 done: `packages/doc_common`.
    - `doc_zip` is a ZIP reader and writer. It handles ZIP64, data
      descriptors, CP437 and Unicode names, prepended bytes, size and
      entry limits, and raw copying of unchanged entries. It was
      cross-checked both ways against Info-ZIP `unzip` and Python's
      `zipfile`.
    - `doc_xml` has a pull reader, a round-tripping tree and a writer. It
      handles namespaces by URI, with Strict and Transitional OOXML
      matched, and OOXML `_xHHHH_` escaping. It is safe against XXE and
      "billion laughs".
    - `doc_encoding` covers UTF-8/16/32 and 32 single-byte code pages, with
      detection.
    - `doc_ffi` holds the shared FFI plumbing, in Rust: error codes, panic guards,
      a session registry and atomic writes.
    - 47 Rust tests.
  - `scripts/build_engines.sh` builds every per-type library for Android
    (16 KB-aligned) and macOS, runs their tests, and prints the
    `*_CORE_LIB_PATH` exports for `flutter test`.
  - The Android build preflight and `check_android_native.py` now check
    every engine.
  - Phase 2 so far:
    - `flutter_text_core` (Rust `text_core` and `text_ffi`, Dart
      `TextCore`/`TextDocument`):
      - Saves in the original encoding, BOM and line endings.
      - Warns about characters an encoding cannot hold.
      - Re-reads an unedited file in another encoding.
      - Pages through large files by line.
      - Find and replace with line numbers.
      - Re-indents JSON while keeping key order.
      - 17 Rust tests and 5 Dart tests.
    - In the app:
      - A `DocKind` model.
      - The Files tab lists PDF, Word, Excel, PowerPoint and text files,
        with kind chips, kind icons, PDF-only actions only on PDFs, and
        rename/import that keep extensions.
      - The add button offers "New text file".
      - `DocumentRouter` opens each kind on its screen, and offers "Open
        with another app" for kinds without one.
      - `TextEditorScreen` has undo/redo, find and replace, encoding and
        line-ending choices, text size, JSON formatting, file info, a
        read-only line view for big files, and an unsaved-changes prompt.
      - `DocumentSaveService` saves in place when it can. Otherwise it
        publishes a public copy and updates the same copy on later saves.
        The exporter now takes a MIME type.
      - "Open with" accepts text, Markdown and JSON as well as PDF.
    - Internal renames: `PdfLibraryService` became `LibraryService`,
      `PdfFileEntry` became `LibraryEntry`, and `PdfIntentListener` became
      `DocumentIntentListener`.
    - 538 app tests pass.
  - Checked on the emulator (`pdfhelper_api36_16kb`):
    - A Windows-1252 file with CRLF line endings, opened through "Open
      with", shows its accents correctly.
    - Edits save back in the same encoding and line endings.
    - A public copy is created in `Download/DocHelper` and updated on the
      next save, with no duplicate.
    - A new note opens with the keyboard ready, and saving publishes it.
  - Device testing found and fixed:
    - A stale native library: the Android preflight now refuses an engine
      binary older than its Rust source.
    - The new-file dialog showed `.pdf`.
    - A crowded title bar: Undo, Redo and Find moved to a bottom toolbar.
    - Raw folder names for app files: they now read "DocHelper".
    - Empty notes that were never typed in are no longer kept.
  - The storage-permission dialog now names every kind of document it
    lists.
  - Phase 2 done. Syntax highlighting, Markdown preview and a regex engine
    move to phase 9.
  - Phase 3 started in `packages/flutter_sheet_core` (Rust `sheet_core`),
    with 37 tests passing. Done and tested:
    - `refs`: A1 references, ranges and sheet-name quoting.
    - `value`: Excel's coercion and comparison rules, 15-digit precision,
      and number-to-text conversion.
    - `datetime`: 1900 and 1904 serials, including Lotus's phantom
      1900-02-29, and DATE's overflow rules.
    - `numfmt`: the full format-code language, with Excel's rounding
      (2.675 shows as 2.68), Excel's General display, locale short dates,
      and Indian lakh/crore formats (`INDIAN_NUMBER_FORMAT`).
    - `input`: typed numbers, percentages, currency, dates (in the locale's
      order) and times, each with the number format it suggests.
    - `formula`: the parser, the printer (with OOXML's `_xlfn.` prefixes),
      and reference adjustment for inserted and deleted rows and columns,
      copy/fill offsets, and sheet renames and deletions.
  - In progress, written but not yet in the build:
    - `formula/eval.rs`: the evaluator, with implicit intersection,
      element-wise arrays, reference operators, and keeping the saved value
      for unsupported formulas.
    - `formula/functions/mod.rs`: dispatch for about 180 functions. Its
      per-category modules (`criteria`, `logic`, `math`, `stats`, `lookup`,
      `text`, `date`, `info`, `finance`) are next.
  - `scripts/download_office_corpus.py` collects real-world office files
    from public test suites (Apache POI, XlsxWriter, calamine,
    python-docx/pptx, LibreOffice) into `test_corpus/office/`. It has not
    finished listing yet: the GitHub API allows 60 requests an hour, so set
    `GITHUB_TOKEN` to finish it.
  - Microsoft Excel, Word and PowerPoint are installed on the development
    Mac. They can confirm that files DocHelper writes open without a repair
    prompt.

- **2026-10-13 (cloud session).** Phase 3 done.
  - `doc_common` gained `doc_opc`: OOXML and ODF packages (parts,
    relationships, content types), saving every untouched part raw.
  - `sheet_core`:
    - The function library: about 280 functions in nine modules
      (criteria, logic, maths, statistics, lookup, text, dates,
      information, finance), pinned to Excel's results.
    - The workbook model, styles that are only appended, and
      recalculation of just what an edit affects (reverse dependency
      index, Kahn's order, volatile functions, circular references kept
      and reported).
    - Every edit as an `Op` with undo and redo: typing, formatting,
      rows and columns, sheets, fill, paste, sort, replace, names.
    - XLSX/XLSM in place: unchanged parts byte for byte, only changed
      sheets regenerated, new styles and shared strings appended,
      `calcChain.xml` dropped, tables and ranges follow inserted rows.
    - ODS in place: unchanged tables verbatim, OpenFormula both ways,
      comments, validations and conditional formats kept.
    - CSV/TSV with encoding and delimiter detection, each field's text
      kept until edited.
    - 68 Rust tests. Files written were checked in LibreOffice and
      openpyxl: values, formulas, styles, merges, comments, validations,
      conditional formats, hyperlinks, names and hidden sheets survive.
  - `sheet_ffi` and the Dart API (`SheetCore`, `SheetBook`), 4 Dart tests.
  - The app: `SheetEditorScreen` (custom-painted grid with frozen panes,
    pinch zoom, selection handles, formula bar with function hints,
    formatting toolbar, number formats including lakh/crore, sheet tabs,
    find and replace, copy and paste, sort, AutoSum, status-bar sums),
    "New spreadsheet", "Open with" for XLSX/XLSM/ODS/CSV/TSV, and the
    sheet engine in the Android preflight. 3 widget tests; 482 app tests
    pass.
  - Flutter 3.47.7 and LibreOffice run in the cloud machine, so app tests
    and reference-application checks work there too.

## Next steps (for the next session)

1. Phase 4 (Word): `packages/flutter_word_core` (DOCX in place, then ODT
   and RTF), its FFI and Dart API, and the document screen.
2. Phase 5 (slides), then phase 6 (layout and PDF export).
3. Run the office corpus sweep (`download_office_corpus.py` needs
   `GITHUB_TOKEN`), and check saved files in real Excel on the Mac.
