# DocHelper plan

PDF Helper becomes **DocHelper**: one phone app for reading, editing, creating,
converting and sharing documents of every common kind. It is built for someone
who does real office work on a phone instead of a laptop.

This file is the plan and the progress record. It is updated as work lands.
See the [progress log](#progress-log) at the end.

Last updated: 2026-10-15 (phases 0-9 done; phase 9 still to be tried on the
emulator).

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
| Archives | `packages/flutter_archive_core` (submodule) | `libarchive_ffi` | `.zip`, `.tar`, `.tar.gz`/`.tgz`, `.gz` (browse, extract); `.zip` (create) | `ArchiveCore` |
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
- **`doc_art`.** OfficeArt drawing records inside those files: walking
  them, shape properties and colours, and stored pictures turned back
  into PNG, JPEG, BMP, TIFF, EMF and WMF files.
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
- **Formats.** JSON validation and pretty-printing. Markdown and HTML read
  as a page (the engine's own reader, `text_core::markup`) and JSON as a
  tree. Syntax highlighting for common formats comes later.
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
| 4 | Word library v1 (DOCX/ODT/RTF, in-place editing) and document screen | [x] |
| 5 | Presentation library v1 (PPTX/ODP, scene, text edits, slide operations) and slides screen | [x] |
| 6 | Fonts, layout and PDF writer: Word page view and export; sheet and slide export | [x] |
| 7 | Legacy binaries through `doc_cfb`: XLS, DOC, PPT and WPS `.et/.wps/.dps` | [x] |
| 8 | PDF editing: annotate, sign, fill forms, stamp, compress, convert pages to images | [x] |
| 9 | Other files: images, ZIP archives, Markdown, HTML and JSON viewers, unknown files | [x] |
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

- **2026-10-13 (cloud session, later).** Phase 4, Word documents (DOCX).
  - `word_core`, format-neutral where it can be:
    - The body is a tree of paragraphs and containers; each paragraph
      stays the XML element it was read as, and only paragraphs that are
      edited are written again.
    - Paragraphs reach the screen as styled text and objects: pictures,
      breaks, fields (with their shown result), notes, equations, content
      controls. Bookmarks and comment anchors are invisible markers that
      go back where their characters went after an edit (a common prefix
      and suffix of old and new text decide).
    - Edits: replace a run of sibling paragraphs (typing, splitting with
      Enter, joining with Backspace, pasting), paragraph properties
      (style, alignment, lists, indent, spacing, page break before),
      tables (insert, rows and columns), page breaks, pictures, delete a
      block, replace all. Undo and redo record container splices.
    - Paragraphs with tracked changes, or a field running into the next
      paragraph, are shown but locked, so editing them cannot lose
      anything.
  - DOCX: style chains with document defaults and theme fonts, numbering
    with Word's counters and level restarts, run properties reused from
    the original runs and only differences written (in schema order),
    links through relationships, built-in styles added on first use,
    pictures added as media parts, new lists in `numbering.xml`. Checked
    in LibreOffice and python-docx.
  - `word_ffi` (JSON blocks and edits) and the Dart API (`WordCore`,
    `WordDocument`), 3 Dart tests.
  - The app: `DocumentEditorScreen`, a reflowing view (tables fitted to
    the width, pictures, list labels, page breaks); tap a paragraph to edit
    it where you tapped, with a toolbar (styles, bold, italic, underline,
    strike, size, colours, alignment, bullets, numbering, indent, line
    spacing, links, insert table, picture and page break); Enter splits,
    Backspace at the start joins; find and replace, headings, word count,
    share, save a copy as text. "New document", "Open with" for
    DOCX/DOCM/DOTX, the word engine in the Android preflight. 4 widget
    tests.

- **2026-10-13 (cloud session, later still).** Phase 4 done: ODT, RTF,
  text and Markdown.
  - `odt` backend behind the same `Backend` trait: named and automatic
    styles with inheritance and percentages, ODF white space (collapsed
    on reading, `text:s` on writing), edited text in spans of new
    automatic styles (reused when they match), headings as `text:h`,
    lists as containers (a paragraph joining a list merges with a
    neighbouring one; leaving it splits the list, the rest continuing
    its numbering), tables with spans and covered cells, pictures added
    to `Pictures/` and the manifest, page breaks through a paragraph
    style.
  - Markers keep their places through several separate changes in one
    paragraph: offsets map through a longest common subsequence of the
    changed middle.
  - `import`: RTF (code pages and `\u`, fonts, colours, styles with
    heading names, list tables, tables with merges, PNG/JPEG pictures,
    hyperlink fields), plain text and Markdown (headings, lists,
    emphasis, code, links, tables, quotes) become a new `.docx`. The app
    opens them in the document screen, says so, and saves a new Word
    file next to the app's other edited files (with its public copy).
  - 12 Rust tests; files written were checked in LibreOffice.
  - "Open with" for ODT/OTT/RTF; 5 widget tests.

- **2026-10-13 (owner's direction).** All work now goes on `main` (the
  app and the engine repositories); the cloud session's feature branch was
  fast-forwarded into `main`. The word engine moved to its own repository,
  `koundinyalanka1/flutter_word_core` (private), with its history, and is a
  submodule at `packages/flutter_word_core`. The slide engine follows when
  phase 5 is done, `doc_common` when its phase 6 and 7 crates land.

- **2026-10-13 (phase 5, the engine).** `packages/flutter_slide_core`, now
  in its own repository, `koundinyalanka1/flutter_slide_core` (a submodule,
  moved early at the owner's request):
  - `slide_core` reads a PowerPoint deck (`.pptx`, `.pptm`, `.potx`,
    `.ppsx`, told apart by the main part's content type) into scenes:
    master and layout decoration behind the slide's own shapes,
    placeholder inheritance (slide, layout by index or type, master),
    theme colours with their modifiers, theme fill and line styles,
    about 80 preset shapes and custom geometry with its guide formulas,
    gradients, pictures with crops, groups, tables with the default
    table style, SmartArt from its saved drawing, and text with the whole
    list-style cascade (autofit scale, bullets and automatic numbering;
    Wingdings and Symbol bullets become Unicode).
  - Edits: shape text (unchanged paragraphs kept, changed ones rebuilt
    with each character's original run properties), whole-shape
    formatting, new text boxes, shapes and pictures, delete and move or
    resize, new slides from a layout, duplicate, delete, move and hide
    slides, speaker notes (a notes slide is made when missing). Undo and
    redo through copy-on-write state; saving writes the state into a fresh
    copy of the original package, other parts byte for byte.
  - A built-in 16:9 template for new decks (six layouts, a notes master),
    checked in python-pptx and LibreOffice.
  - `slide_ffi` (`slide_*`), the Dart API (`SlideCore`, `SlideDeck`,
    scene models); 8 Rust tests and 2 Dart tests.
  - Still to do in phase 5: the slides screen and app wiring, then ODP.
    Charts draw as a placeholder box until phase 6.

- **2026-10-13 (phase 5 done).** The slides screen and OpenDocument
  presentations:
  - `lib/screens/slide_editor_screen.dart`: the slide large, painted from
    its scene (`lib/widgets/slide/slide_painter.dart`: paths, solid,
    gradient and picture fills, dashes and arrowheads, text with bullets
    and line spacing, tables), a strip of slides (tap, long-press to
    reorder, a menu to add, duplicate, move, hide or delete), tap to select
    and tap again (or once on an empty placeholder) to type, drag to move,
    corner handles to resize (pictures keep their shape), bold, italic,
    underline, size, colour and alignment for the whole shape or a table
    cell, new text boxes, shapes (a picker drawing the engine's own
    outlines) and pictures, speaker notes, undo and redo, save, share,
    "save a copy as" and copy all text.
  - `lib/screens/slide_show_screen.dart`: full screen, landscape, tap or
    swipe; hidden slides skipped.
  - "New presentation" in Files; PowerPoint and OpenDocument presentations
    open from Files and from other apps ("Open with").
  - Undoing back to the state last saved leaves the deck unmodified.
  - `odp`: styles, master pages (their non-placeholder shapes behind each
    slide), lists with bullets and numbering, enhanced geometry evaluated
    (equations, modifiers, `T`/`U`/`A`/`B`/`W`/`V`/`X`/`Y`/`G` arcs), SVG
    path data, polygons, lines, connectors, pictures, tables with their
    cell styles, rotation (`draw:transform`), notes; every edit the PPTX
    side has, saved in place with new automatic styles. Checked against
    LibreOffice's own rendering of a converted deck.
  - 14 Rust tests, 3 Dart engine tests, 8 widget tests.

- **2026-10-13 (phase 6).** Saving as PDF, everywhere:
  - `doc_common` gained `doc_image`, `doc_font`, `doc_pdf` and
    `doc_layout` (see its README); fonts come from the system's folders
    (`exportFontDirs()` in `lib/services/export_fonts.dart`: Android's
    `/system/fonts`, macOS's, Linux's), indexed once per process.
  - Slides: each scene drawn as the screen draws it (geometry, gradients,
    pictures with crops, arrowheads, tables, text with bullets); hidden
    slides left out. Checked against LibreOffice's export of the same deck.
  - Sheets: pages down then across, a sheet a little too wide shrunk to
    fit (and turned to landscape), fills, borders, number colours,
    alignment, wrapping, merged cells, text running into empty
    neighbours, numbers too wide as `###`, light grid lines, and a footer
    with the sheet's name and page.
  - Word: paragraphs flowing across pages with their indents, spacing,
    line spacing, list labels and shading; pictures (shrunk to fit); page
    breaks; keep-with-next; tables with fills, borders and repeated header
    rows. "Page view" in the document screen shows these pages in the PDF
    viewer (not added to Recent). Raised text (`w:position`) is read and
    written back now.
  - Each screen has "Save a copy as… PDF" and "Share as PDF".
  - Known gaps: no complex-script shaping yet (Devanagari, Tamil and other
    Indic scripts show unjoined glyphs; Arabic is not joined); Word
    headers, footers, footnotes, columns and floating shapes are not laid
    out; CFF fonts (CJK on Android) are embedded whole; charts draw as a
    placeholder box.

- **2026-10-13 (phase 7).** Office 97-2003 and WPS binaries open:
  - `doc_cfb` reads OLE2 files (every chain checked for loops and bounds);
    `doc_art` reads their drawing records and pictures, shared by the
    readers below.
  - Excel (`.xls`, `.xlt`, WPS `.et`): BIFF8 values, shared strings,
    formulas decompiled to text (shared and array formulas, 3-D
    references, names, add-in functions), number formats, fonts, fills,
    borders, merges, sizes, frozen panes. The screen saves to a new
    `.xlsx` in `Edited/` and says so.
  - Word (`.doc`, `.dot`, WPS `.wps`): the piece table, formatting with
    styles applied (so text looks as it did), lists with their own
    numbering, tables (merged and shaded cells, header rows), links,
    inline and floating pictures, text boxes (as paragraphs after their
    anchor), footnotes and endnotes, page size and margins, headers and
    footers; imported into a new `.docx` the way RTF is.
  - PowerPoint (`.ppt`, `.pps`, `.pot`, WPS `.dps`): the persist directory
    and edit chain, masters (their shapes, text styles, colour schemes and
    the properties slide shapes inherit), preset shapes, freeforms,
    lines, groups with their turns, fills (solid, gradient, picture),
    pictures with crops, backgrounds, text with bullets and indents,
    notes; imported into a new `.pptx` built by
    `pptx::template::package`. The screen saves to a new `.pptx`.
  - Checked against LibreOffice's rendering of Apache POI's test files
    (23 `.ppt`, 24 `.doc`, 17 `.xls`) and of files LibreOffice converted.
    Password-protected files say so; Word 6/95 and PowerPoint 95 say they
    cannot be opened yet.
  - The sheet engine now computes a range that stands for one cell as
    Excel does (implicit intersection: `=$A:$A*2` is this row's A
    doubled), outside array formulas and aggregates; recalculating POI's
    formula torture test agrees with Excel's saved values except for
    last-digit rounding and a few edge cases.
  - Known gaps: WMF/EMF pictures (common clip art in old files) are kept
    but not drawn; Word drawing shapes and comments are left out;
    LibreOffice's custom shapes in `.ppt` (formula-driven geometry) draw
    as rectangles.

- **2026-10-13 (metafiles).** WMF and EMF pictures are drawn:
  - `doc_metafile` in `doc_common` plays both formats onto an anti-aliased
    canvas: GDI state and mapping modes, world transforms, pens with joins
    and dashes, brushes, paths, regions as clips, bitmaps (with raster
    operations), and text through the fonts' TrueType outlines
    (`doc_font::Font::outline`). `doc_image::encode_png` writes the result.
  - The word and slide engines show a metafile as a PNG
    (`doc_metafile::shown`, with the system's fonts) and draw it into
    their PDF exports; the file keeps the metafile. Clip art, diagrams and
    newspaper pages with photos from the POI and LibreOffice test files
    draw as Office shows them.
  - Known gaps: EMF+ records (GDI+) are skipped, so EMF+-only pictures
    are blank.

- **2026-10-13 (phase 8, part 1).** PDFs can be filled in, signed and
  marked up:
  - `pdf_edit` in `flutter_pdf_core`: form fields (text, comb, multi-line,
    password, check boxes, radio groups, drop-downs and lists) filled with
    appearances drawn for the new values; annotations (highlight,
    underline, strike-out, squiggly, ink, rectangle, ellipse, line, arrow,
    text box, typed text, note, picture, drawn signature), each with an
    appearance stream, listed and removable; marks drawn onto many pages
    (page numbers, headers, footers, watermarks), upright on rotated
    pages. Anything can be flattened into the page instead.
  - Saving appends an incremental update, so existing signatures stay
    valid; files that use cross-reference streams get one; encrypted files
    keep their password (the update is encrypted with the file's key); a
    file whose index was rebuilt is written whole. XFA is dropped from a
    filled form so readers show the AcroForm values.
  - Checked against the IRS W-9, W-4 and 1040 and pdf.js's form tests,
    read back with pypdf (strict) and rendered with poppler as well as
    our renderer.
  - The app: "Fill & sign", "Annotate" and "Page numbers & watermark" in
    the viewer's actions and in Tools. `PdfEditScreen` shows the pages
    with tools (fill, sign, text, highlight, underline, strike, pen, note,
    box, circle, arrow, picture), undo, colours and widths; highlights
    follow the text's lines; signatures are drawn once and kept
    (`SignatureStore`); existing annotations are removed with a long press.
    `PdfStampScreen` previews its marks on the first page. Both save in
    place when the file is writable, otherwise to a published copy, and
    the viewer reloads what was saved.
  - Known gaps: text is set in the standard fonts (WinAnsi), so Indic and
    other scripts in fields and text boxes come out as "?" (the app warns);
    the macOS and iOS PDF binaries need rebuilding on the Mac for these
    functions (the Android ones are rebuilt).

- **2026-10-13 (phase 8, part 2).** PDFs can be made smaller and their
  pages saved as pictures:
  - A baseline JPEG encoder of our own in `pdf_render` (4:2:0 colour,
    Annex K quantization scaled by quality, Huffman tables made for each
    image).
  - `pdf_compress`: pictures scaled to the chosen resolution and
    re-encoded when that is smaller (masks, bi-level scans and colour-keyed
    pictures keep their pixels), plain streams Flate-packed, unreferenced
    objects dropped, and the file written with object streams and a
    cross-reference stream. Photo-heavy arXiv papers came out at a third of
    their size and render as before. Encrypted files keep their password; a
    file that does not shrink is returned as it was.
  - Pages as PNG or JPEG at a chosen sharpness.
  - The app: "Compress" (Light, Recommended, Strong; a named copy, with the
    sizes before and after) and "Save pages as pictures" (format,
    sharpness, pages; shared or published to `Download/DocHelper`), in the
    viewer's actions and in Tools.

- **2026-10-14/15 (phase 9).** Other files: pictures, archives, Markdown,
  HTML and JSON, and flat OpenDocument:
  - Flat OpenDocument (`.fodt/.fods/.fodp`, one XML file) opens in the
    word, sheet and slide engines (`doc_odf`). It cannot be written back,
    so saving makes `Edited/<name>.odt/.ods/.odp` and says so.
  - `text_core::markup` reads Markdown (CommonMark with GitHub's tables,
    task lists, strikethrough and bare links) and real-world HTML into
    one reading model: headings, styled runs, quotes, lists, code, rules,
    tables and pictures. It is cut short at 100,000 parts (blocks, items,
    cells and runs) and its trees at 300,000 nodes, with `truncated` set:
    five megabytes of one-word list items took 2 GB and 20 s before.
  - `packages/flutter_archive_core` (its own repository, a submodule):
    ZIP (ZIP64, stored and deflate), TAR (ustar, GNU, pax), gzip and
    `.tar.gz` listed, read and extracted; ZIP files made. Names are made
    safe before anything is written (no `..`, absolute paths, devices or
    links), a target's existing files and links are never replaced or
    followed, and zip bombs and huge entries are refused before writing.
    Cross-checked against Python's `zipfile`/`tarfile`, Info-ZIP and GNU
    tar; fuzzed in review (100,000 mutated archives, nothing written
    outside the target).
  - The app: `ImageViewerScreen` (zoom, turn, details, share, make a
    PDF), `ArchiveScreen` (folders, open/share/save one file, Extract all
    into a folder, published to `Download/DocHelper/<folder>/...` in one
    batch), `MakeZipScreen`, and in the text editor a page view of
    Markdown and HTML (`MarkupView`, built lazily piece by piece, even
    inside long lists and tables) and a tree of JSON (`JsonTreeView`,
    numbers shown as the file writes them). Tools has a Files section:
    Open a file (any kind, pictures included), Make a ZIP, Open a ZIP.
    "Open with" covers archives, flat OpenDocument and HTML.
  - Checked: about 700 app tests (the only failures are the corpus sweep's,
    as `test_corpus/` was absent), the engines' Rust and Dart tests, and a
    debug APK built on Linux, whose six engines pass
    `check_android_native.py` (16 KB pages) and whose merged manifest has
    the new filters.
  - Known gaps: nothing was tried on a device or emulator yet; pictures are not listed in Files (Tools > Open a
    file opens one); HEIC/AVIF go through the phone's own codec, untried
    here; very large pictures are decoded downscaled; jumping far through
    a page of tens of thousands of pieces lays out every piece between;
    7-Zip and RAR are recognised but not opened; extracted files are kept
    both in the app and as public copies, each linked in the public-copy
    catalogue (about 360 bytes a file).

## Next steps (for the next session)

1. Try phase 9 on the emulator `pdfhelper_api36_16kb` (the debug APK builds;
   the Kotlin resolver and the manifest changed): "Open with" for `.zip`,
   `.tar.gz`, `.fodt` and `.html`; Tools > Open a file with a JPEG and a
   HEIC photo; Extract all of a ZIP with nested folders
   (public copies in `Download/DocHelper/<folder>/...`) on Android 10+ and
   on an Android 9 image; Make a ZIP.
2. Rebuild the PDF engine's macOS dylib and iOS XCFramework on the Mac
   (`bash scripts/build_pdf_core.sh ios macos`); the Android binaries are
   current.
3. `doc_common` becomes its own repository (`koundinyalanka1/doc_common`)
   and a submodule at the same path. Creating the repository needs the
   owner: the GitHub app cannot create repositories.
4. A complex-script shaper (GSUB/GPOS for Indic and Arabic) in
   `doc_layout`, so Hindi, Telugu and Tamil text exports correctly; then
   embedded fonts for PDF form text and text boxes.
5. Run the office corpus sweep (`download_office_corpus.py` needs
   `GITHUB_TOKEN`), and check saved files in real Office on the Mac.
