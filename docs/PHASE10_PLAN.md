# Phase 10 plan: hardening and release

Written on 2026-10-15 from six surveys of the engines and the app (one per engine, the shared crates with the text and archive engines, and the app's release and accessibility). Paths are relative to the repository root.

## Overview

The six surveys reported about 95 findings. After merging duplicates and dropping what lacks evidence, about 70 work items remain.

**What the findings have in common.** Panics are already caught at every FFI boundary. The crashes that remain are ones `catch_unwind` cannot catch:
- allocation aborts driven by counts read from the file;
- stack overflows from recursion on Dart's 1 MB isolate stacks (512 KB expected on armv7);
- out-of-memory kills.

There are also hangs with no time budget, either on the UI isolate or inside `Isolate.run` with no way to cancel.

**Most fixes are small.** The large pieces of work are:
- the PDF render work budget and cancellation;
- moving editor calls off the UI isolate;
- phone-sized memory budgets;
- verified saves;
- corpus sweeps and fuzzers.

**What I checked.** I spot-checked the main claims and they hold:
- `pdf_core/src/document.rs:561` reserves `Vec::with_capacity(n)` without the guard its sibling has at :492.
- `doc_xml` `MAX_DEPTH` is 1024.
- `doc_ffi::write_file_atomically` does not verify, keeps no backup, and uses a temp name made only from the pid.
- `Registry::with` ignores a poisoned lock.
- ODT `number-columns-spanned` and PPTX `startAt` are not clamped.
- The `doc_metafile` dash loop uses f32.
- The version is `3.0.0+3`.
- The four editors have 51 catch blocks and 0 `logError` calls.
- `textTertiary` is black38/white38 and is used 106 times.

**Merged duplicates:**
- Verified saves and backups (5 surveys) become one shared `doc_ffi` helper plus a verify check per engine.
- A panic leaving a half-edited session (3 surveys) becomes one shared `Registry` fix.
- The ZIP ratio limit and per-part budgets (3 surveys) become one shared item.
- The CFB mini-stream reservation (2 surveys) and duplicate ZIP names (2 surveys) become one item each.
- Stack depth (5 surveys) becomes one shared fix plus one cap per engine.
- Synchronous calls on the UI isolate are handled once per engine.
- Corpus and fuzzing are split into one fetch step plus work per engine.

**Changed:**
- `cargo-fuzz`/libFuzzer vendors C++, and `proptest` is not an allowed crate. Fuzzing therefore uses in-tree xorshift mutators.

**Dropped or deferred:**
- The PDF engine's generic count of index expressions: no reachable panic was found. The specific `preserve.rs` unwraps are kept.
- Making `setMetadata` incremental: nothing is damaged today.
- `doc_font` kern fuzzing: only system fonts are read.
- Archive handle reuse and cancel.
- The Word/Sheet "normalized XML" findings, which are moved to the owner's decisions.

**Facts that affect the work:**
- All six engines are now submodules (`.gitmodules`); `doc_common` is still in the app's tree.
- Each batch is committed when it passes: the engine commits on `main` inside its submodule, then the app commits the gitlink.

**Tooling on this machine:**
- cargo 1.97.
- Flutter is at `/opt/flutter/bin`, which is not on `PATH`.
- LibreOffice runs headless (`/usr/bin/soffice`).
- `GITHUB_TOKEN` is set; `GH_TOKEN` is invalid.
- There is no KVM, so no emulator.
- Hostile tests run as follows:
  - stack checks on `std::thread::Builder::stack_size(512 KiB)` and 1 MiB;
  - hang checks under `timeout`;
  - memory checks under `prlimit --as=…` or by reading `VmHWM` from `/proc/self/status`.

## Order at a glance

| Wave | Batches (parallel, disjoint files) | Agents |
| --- | --- | --- |
| 0 | B0 corpus fetch | 1 |
| 1 | B1 shared core · B2 shared pictures and legacy · B3 PDF engine · B4 app reporting, release config, first accessibility pass | 2 + 1 + 2 + 1 |
| 2 | B5 Word · B6 Sheet · B7 Slide · B8 Text and archive. Fixes inside one engine can start during wave 1; wiring in B1's APIs waits for B1 | 2 + 4 + 2 + 1 |
| 3 | B9 sweeps and mutation fuzzers per engine · B10 work across all editors (draft autosave, accessibility) | 1 per engine + 1 |
| 4 | Device rounds, release (owner) | — |

**Shared crates.** B1, B2 and part of B8 (`doc_encoding`) change `packages/doc_common`. That code is linked into the text, sheet, word, slide and archive engines, but not PDF. After each of these batches:
- run `bash scripts/build_engines.sh test` and `host`;
- run `eval "$(bash scripts/build_engines.sh env)"`, then `flutter test`.

Only the orchestrator edits PLAN.md and CLAUDE.md. That avoids conflicts.

---

## B0. Corpus fetch (wave 0, size S)

- Run `scripts/download_office_corpus.py` with `GITHUB_TOKEN`; `test_corpus/office` has 0 files.
- Run `download_huge_and_photo_corpus.py` and `download_test_corpus.py` again; `huge/` has 0 files and `scans/` and `epics/` are nearly empty.
- Add the LibreOffice, Apache POI and python-pptx test documents, plus WMF/EMF clip art.
- The corpus stays git-ignored. Hostile inputs are built inside the Rust tests, not committed as binaries.
- **Verify:** count files per folder. `test/pvs_pdf_test.dart` should now see non-empty categories.

## B1. Shared core: `doc_xml`, `doc_zip`, `doc_opc`, `doc_odf`, `doc_ffi` (wave 1, size L, 2 agents: XML/ODF and ZIP/OPC/FFI)

All of `doc_common` except PDF depends on this batch. Blockers come first.

1. **Blocker: zip-bomb and part-size limits** (merges the shared, Word and slide findings).
   - Add `max_ratio`, `ratio_floor` and `max_total_bytes` to `doc_zip::ReadLimits`, as `archive_core::Limits` already has.
   - Inflate at most min(limit, declared size) + 1 bytes, and use `try_reserve` so a failure becomes `TOO_LARGE`.
   - Give `doc_opc` phone-sized defaults: 64 MB per XML part and a total per package.
   - Add a node budget to `doc_xml::Document::parse` (for example 2M) that returns `TOO_LARGE`.
   - Evidence: a 16 KB entry built a 466 MB tree; a 31 KB DOCX used 738 MB.
2. **Blocker: stack safety.**
   - Lower `doc_xml` `MAX_DEPTH`: 512 with the backstop below, 256 without it. Confirm against the deepest file in the corpus.
   - Write iterative `Drop`, `Clone`, `PartialEq` and `collect_text` for `Element`. Today, clone and equality abort at 300 KB of stack.
   - **Backstop:** `call_str`, `call_i64` and the bytes wrapper run the call on a scoped thread with a 16 MB stack and pass the `Result` back.
     - `LAST_ERROR` is the only `thread_local!` in the five engines, so the error is set on the caller's thread after the join.
     - The captured raw pointers need a `Send` wrapper.
     - Measure the overhead on hot calls (sheet window, word blocks). Above about 50 µs, use one long-lived worker per calling thread instead.
3. **Major: verified saves** (merges five findings). Add `doc_ffi::save_verified(path, bytes, verify)`:
   - make a unique temporary file (`create_new` plus a counter, as `archive_core/src/extract.rs:69` does);
   - write it and fsync it;
   - read it back and run the engine's check;
   - copy the original into a backup folder set by the app;
   - rename, then fsync the folder.

   Also export a cleanup for stale `.*.tmp` files, and make `read_file` read through `take(max+1)`. The engines supply their checks in B5–B8.
4. **Major: poisoned sessions** (merges the Word, sheet and slide findings). When a session's lock is poisoned, `Registry::with` refuses further edits and saves with `PANIC: … reopen the document`. Close still works.
5. **Major: relationship lookups** (from the slide survey; Word benefits too). Index `doc_opc::Rels` by id in a `HashMap` and collect ids into a `HashSet` in `unused_id`. Opening a 6,000-slide deck takes 12.4 s today.
6. **Major: quadratic XML.**
   - `escape.rs:31` should search for `;` only within the next 33 bytes. Today 400K bare `&` take 6.6 s.
   - Namespace resolution in `doc_xml/src/dom.rs` and `doc_odf/src/unflatten.rs` should use a `HashMap` with an undo list per element. Today 949 KB takes 1.6 s.
   - **Minor:** make `ns.rs` a `HashMap`, give unknown URIs ids per document, and stop interning undeclared prefixes.
7. **Minor: panics.** In `reader.rs:232` and `:256`, compare bytes instead of `str` slices. 1,821 of 60,000 mutated XML files panicked, and `doc_odf::flat_mimetype` runs on every opened file.
8. **Minor: round trip.**
   - Keep unknown entity references instead of turning them into `&amp;co;`.
   - Keep comments containing `--`.
   - Make `copy_from` carry extra fields across.
   - When a package has duplicate entry names, save the first one (the one the reader used) and warn, instead of failing. Today such a file can be edited but never saved.
   - Use checked arithmetic at `read.rs:311`.

**Verify:**
- `cargo test` in `packages/doc_common`, with new tests:
  - small bomb files return `TOO_LARGE` in under 1 s and under 100 MB RSS;
  - a tree at maximum depth parses, clones, compares and drops on a 128 KB thread;
  - 1M `&` take under 0.5 s and 40K namespaces under 0.2 s;
  - `save_verified` refuses corrupted bytes and leaves the original intact with no temporary file;
  - a package with duplicate names saves.
- Then the engine and app runs listed above.

## B2. Shared pictures and legacy files: `doc_metafile`, `doc_image`, `doc_cfb`, `doc_art` (wave 1, size M, 1 agent)

1. **Blocker: dashed metafile lines** (`raster.rs` `dash`).
   - Clip each polyline to the canvas plus the pen width before dashing.
   - Compute in f64 and stop when an iteration makes no progress.
   - Cap the dashes; past the cap, stroke the line solid.
   - Evidence: an 88-byte WMF aborts asking for 1.6 GB.
2. **Blocker: metafile point counts** (`emf.rs:42-87`, `wmf.rs:81` and `:115`).
   - Clamp each count to (record length − offset) / point size.
   - Give each render a budget for points, edges and dashes (about 4M) and return what was drawn.
   - Cap path size, and skip join discs on huge polylines.
   - Use `checked_add` and `saturating_mul` (armv7 wraps in release).
   - Evidence: a 196-byte EMF reached 2.5 GB.
3. **Major: `doc_image`.**
   - Check every GIF frame with `check_size` and clip it to the screen; fix the out-of-bounds index at `gif.rs:30`.
   - Lower `MAX_PIXELS` from 64M to the owner's budget (about 16–24M).
   - Unfilter PNG rows straight into the output, use `try_reserve`, and fix the overflow in `bmp.rs:48`.
4. **Major: `doc_art`.** Add a decompression budget for each import to `blip()`. B7 wires it into `ppt.rs`.
5. **Minor: `doc_cfb`** (merges the Word and shared findings).
   - Clamp the mini-stream cutoff to 4096.
   - Reserve at most min(size, minifat × 64).
   - Allocate one visited-bitset per file.
   - Use checked `(s+1)*sector`.

**Verify:** add unit tests with each hostile input: the 88-byte WMF, the 196-byte EMF, an EMF PolyPolygon16, the 28-byte GIF, the truncated GIF, and a CFB with cutoff 0xFFFFFFFF. Each must finish in under 2 s under `prlimit --as=1G`. Also run a 20,000-mutation loop per decoder with a time limit.

## B3. PDF engine: `packages/flutter_pdf_core` (wave 1, size L, 2 agents; does not use `doc_common`)

**Agent A: `pdf_core`**

1. **Blocker, S: object-stream `/N` abort.** Give `extract_from_object_stream` the guard `extract_all_from_object_stream` has (`n > first/4`, `first ≤ len`), and let the vector grow instead of reserving. A crafted file aborts with a 32 GB allocation request.
2. **Major, M: object-stream expansion is quadratic.** Parse the N-pair header once into a table, share it between both helpers, and cache it per container. N=32,000 (a 145 KB file) runs for more than 120 s today.
3. **Major, M: recovery is quadratic.** Remember parsed xref sections by offset, and bound the total work by file size. A 1 MB file takes 17 s today.
4. **Minor, S:** in `pdf_ops/src/preserve.rs`, replace the `resolve().unwrap()` chain with `?`/`ok_or`.

**Agent B: `pdf_render`, `pdf_text`, `pdf_ffi` and the Dart side**

5. **Blocker, L: work budget, deadline and cancel.**
   - Pass a budget through `run_operations`, `draw_form`, `draw_type3` and tiling, and cap the total number of form XObject calls.
   - When the budget runs out, return a "page too complex" warning, like the existing clip-limit path.
   - Export a cancel call keyed by render id.
   - `pdf_core_api.dart` cancels when its timeout passes, and `lib/services/pdf_raster.dart` shows a placeholder instead of an endless spinner.
   - Evidence: a k=3 self-referencing form ran for more than 60 s; 60M operators took 31.6 s and 3.3 GB.
6. **Blocker, M: text extractor memory.** Port `pdf_text` to the compact `Content` type, or cap the operators and return a partial result. The same page peaks at 5.6 GB today.
7. **Minor, M:** a budget for decoded image bytes per page, checked while decoding.

**Verify:**
- `cd packages/flutter_pdf_core/rust && cargo test --workspace --release`.
- Hostile inputs, ported into Rust test builders from the surveyor's `gen.py`, `mk_forms.py`, `mk_numbers.py` and `gen_xref.py`:
  - the huge-`/N` file gives `CORRUPT`, not an abort;
  - k=3 and k=4 form bombs return within the deadline, with the warning;
  - text extraction of the 60M-operator page stays under 500 MB;
  - N=32,000 opens in under 1 s;
  - M=1000 recovers in under 1 s.
- The package's and the app's PDF viewer tests.
- Rebuild the committed Android binaries here (NDK r27c). macOS and iOS need the Mac.

## B4. App: reporting, release configuration, data safety, first accessibility pass (wave 1, size M, 1 agent; none of these files belong to engine batches)

1. **Major, S: engine error kinds.** In `lib/utils/error_logger.dart`, `describeErrorKind` should name the five engine exception types with their code, for example `WordCoreException(PANIC)`. Add a helper that logs the file kind and a size bucket, never names or paths. The `logError` calls themselves go into each engine batch's screen.
2. **Major, M: native crash reporting** (needs the owner's go-ahead; it is a pending item).
   - Add `firebase-crashlytics-ndk` with `nativeSymbolUploadEnabled`, an `unstrippedNativeLibsDir` covering all six engines, and `ndk.debugSymbolLevel = "SYMBOL_TABLE"`.
   - At the next launch, record `ApplicationExitInfo` low-memory kills as non-fatal events (`MainActivity.kt`, `lib/services/firebase_service.dart`).
3. **Major, S: public copy is truncated, then rewritten.** In `PublicPdfExporter.kt:64-73`, write a new `IS_PENDING` row, then swap it with the old one, instead of opening the existing copy with `"wt"`.
4. **Blocker part, S: storage disclosure.** In `lib/widgets/storage_access_dialog.dart`, list ZIP and say that edits are saved back into the files.
5. **Major, M: first accessibility pass** .
   - Raise `textTertiary` (`lib/providers/theme_provider.dart:364`) to at least 4.5:1; it measures 2.65:1 today.
   - Fix the overflows at `settings_screen.dart:159` and `:501` (200% text) and `merge_pdf_screen.dart:713` (320 dp).
   - Label Settings' two 40 dp buttons and three switches.
   - Make the Files filter chips (34 dp) at least 48 dp tall.
   - Change the visible label `app storage (PDFHelper/…)` (`theme_provider.dart:44`) to plain "app storage". The private folder name stays.
   - Port the probe into `test/accessibility/`: the tap-target, label and contrast guidelines, at 1.0, 1.5 and 2.0 text scale, at 320 and 360 dp, in light and dark.
   - Contrast ratios of 1.1–1.5 in the probe output look like measurement artefacts; confirm them against screenshots.
6. **Major, S:** in `lib/screens/convert_screen.dart:831`, decode scan thumbnails with `ResizeImage`.
7. **Blocker, S: version bump** to `4.0.0+N` in `pubspec.yaml`, once the owner gives N.

**Verify:**
- `/opt/flutter/bin/flutter analyze` and `flutter test`, including the new accessibility tests.
- `flutter build apk --debug`, then `python3 scripts/check_android_native.py <apk>` to confirm the Gradle changes.

## B5. Word: `flutter_word_core` plus `lib/screens/document_editor_screen.dart` and `lib/widgets/word/` (wave 2, size L, 2 agents)

**Agent A: reading safety**

1. **Blocker, S: clamp counts read from files.**
   - Column spans 1..=64 with a checked `g + span` (`odt/mod.rs:893-905`); row spans at most the row count.
   - List starts 0..=32767 (`numbering.rs:88` and `:147`, `odt/lists.rs:115`).
   - `letters()` and `roman()` refuse huge values; `pdf.rs:401` sums columns safely.
   - Mirror the clamp in `doc_blocks.dart:293`.
   - Evidence: aborts asking for 80 GB and 38 TB.
2. **Blocker, S: NaN and infinite lengths.** One helper for every length read from a file: finite and clamped. `place_lines` always makes progress, and an export stops at 20,000 pages with `TOO_LARGE`. Today a `pgMar` of NaN loops forever.
3. **Blocker, M: recursion** (confirm on device). Cap depth or make iterative: `Walk::walk`, `shown_text`, `tree::build`, `blocks_of` and the ODT walks. Cap the display depth of nested tables. Test at the cap on a 512 KB thread.
4. **Blocker, M: Word 97 import amplification** (`doc.rs`).
   - Check that note ranges increase, stay inside the note story, and are each used once.
   - Bound the characters by the stream length.
   - Count unresolved fields instead of scanning the stack per character.
   - Index sections by character position.
   - Add a global import budget.
   - Evidence: a 266 KB file took 30 s and 2.4 GB; a 4.6 KB file took 507 MB.
5. **Blocker:** apply B1's per-part and node budgets with Word's own limits (main and styles parts 64 MB).
6. **Major, S: RTF.** Cap `\cellx` and cells per row at 63, move definitions instead of cloning them per row, and find grid spans by binary search. A 231 KB RTF reaches 805 MB today.

**Agent B: speed, UI isolate, saving**

7. **Major, M: lookups by id.**
   - Keep an id → path index for `projected`, `locate`, `patch` and `items_mut`.
   - Make patch and replace-all linear.
   - Cap find results at 10,000.
   - Evidence: counts on 60k paragraphs take 7.1 s; replace-all takes 15–17 s.
8. **Major, M** (confirm on device): find, replace-all, counts, outline, plainText and large `blocks` go through `Isolate.run`, with a busy state on the screen.
9. **Major, M: tables.**
   - Window table rows: a summary first, then a call for a range of rows.
   - Find vertical merges in one pass.
   - Serialize with `serde` structs instead of cloned `json!` trees.
   - Build `DocTableView` rows lazily.
   - Evidence: a 20k-row table produced 162 MB of JSON and took 77 s.
10. **Major, S: saving.**
    - Word's check for `save_verified`: the ZIP opens, the main part parses, and the paragraph count matches.
    - Unknown object ids in edits return `INVALID_ARGUMENT` instead of panicking.
    - Turn on the clippy `unwrap_used` lint outside tests.
11. **Major, S:** decode pictures at display size (`doc_blocks.dart:191` `cacheWidth`; inserting a picture). Add `logError` in every catch block of this screen.
12. **Major, M:** PDF export splits a row taller than a page across pages (`pdf.rs:466-479`). This was found by reading the code; add a test with 200 paragraphs in one cell.

**Verify:**
- `cargo test` in `word_core` and `word_ffi`. Every hostile file must run on a 512 KB thread, under a timeout and an RSS limit.
- Timing tests: counts on 60k paragraphs under 0.5 s, replace-all under 2 s, the first window of a 20k-row table under 0.5 s.
- Run `wordcli` over the corpus.
- Open the saved DOCX and ODT files in headless LibreOffice.
- `flutter test test/screens/document_editor_screen_test.dart`.

## B6. Sheet: `flutter_sheet_core` plus `lib/screens/sheet_editor_screen.dart` and `lib/widgets/sheet/` (wave 2, size L, 4 agents)

**Agent A: formula parsing, evaluation and recalculation** (`parser.rs`, `unparse.rs`, `ast.rs`, `eval.rs`, `calc.rs`, `functions/mod.rs`)

1. **Blocker, S: operator chains** (this also fixes the major `#CALC!` item).
   - Fold chains into an n-ary node, or evaluate the left spine in a loop.
   - Count depth for every node, and cap formulas at 8,192 characters.
   - Make `Drop`, `unparse` and `walk` on `Expr` iterative.
   - Evidence: an 8,000-term formula in a 1.6 KB file aborts at open; `=A1+…+A65` gives `#CALC!`.
2. **Blocker, M: nested evaluation.** Replace the recursion through `Grid::value` with an explicit work stack. A 300-cell cycle wrapped in SUMs aborts on 1 MiB today.
3. **Blocker, S: range broadcasting.** Use `checked_mul` and a 4M-element budget in `lift2` and `lift`; the same for `IF` is done by agent B. Today one formula asks for 393 GB.
4. **Major, M: reference chains and cycles.**
   - When the nesting limit is hit, defer the cell and run more passes.
   - Report cells left in Kahn's `rest` list as circular.
   - Evidence: chains deeper than 48 give wrong values; cycles of 49 or more are not reported.
5. **Major, S:**
   - `&` checks its length (32,767 characters) before allocating (`eval.rs:653`).
   - Add a calculation deadline and cancel flag that leaves the remaining cells dirty.
   - Check `pending` only for formula cells, and use a faster hasher.

**Agent B: function library and comparisons** (`functions/*`, `value.rs`, `criteria.rs`, `lookup.rs`)

6. **Major, S: loops sized by user numbers.** Add magnitude guards to FACTDOUBLE, PERMUT, COMBIN, COMBINA, DDB, CUMIPMT and CUMPRINC, and sweep the library for other `for _ in 0..user_value` loops. Add the `IF` budget in `logic.rs`.
7. **Major, S:** SUBSTITUTE and the other text builders check length before allocating.
8. **Major, M: comparison speed.** `compare()` compares exactly first, without `format!` and parse, and lookups reuse their key columns. 5,000 VLOOKUPs take 18 s today.

**Agent C: readers, writers, memory and round trip** (`xlsx/*`, `ods/*`, `csv.rs`, `xls/*`, `sheet_ffi`)

9. **Blocker, S: array formulas.** Member cells count toward the cell budget, or membership is stored as ranges. A 1.8 KB file makes 20M cells today.
10. **Major, L** (confirm on device): a phone budget for cells and memory, passed from Dart according to device RAM.
    - Cap shared strings by count and bytes.
    - Check ODS repeats before expanding them.
    - Stream CSV records into cells.
    - Store `<col>` information as ranges (`cols20k`: 3.7 KB, 20 s).
11. **Major, M:** shared formulas whose anchor does not parse are kept as raw XML (`xlsx/read.rs:579`).
12. **Major, S:**
    - Keep `cm`, `vm` and `ca` and the `_xlws.` and `SINGLE`/`ANCHORARRAY` prefixes.
    - Keep the original ODS `table:formula` text while a cell is unchanged, with namespaced function names.
13. **Major, S: saving.**
    - Re-open the bytes in memory and compare sheet, cell and formula counts through `save_verified`.
    - Report a failure only if the file was not written (today `saved()` can report a failure after the original was already replaced).
14. **Minor, S:**
    - CSV export walks only the stored cells.
    - Index ODS merges before writing.
    - Clamp coordinates and spans from XLS and ODS, with checked arithmetic.

**Agent D: editing and the screen** (`edit.rs`, the Dart `SheetBook` API, `sheet_editor_screen.dart`, `sheet_grid_data.dart`)

15. **Major, L: structural edits.**
    - Snapshot only the sheets an operation touches.
    - Record insert and delete as inverse operations.
    - Rename, hide, move and define-name copy no cells.
    - Budget undo by bytes.
    - Recalculate only what changed, using agent A's API.
16. **Major, M** (confirm on device):
    - Every apply, undo, redo and recalculate goes through `applyAsync`, with a busy overlay.
    - Restore a structural snapshot after a panic.
    - Evict grid blocks far from the viewport.
    - Add `logError` calls.

**Verify:**
- `cargo test --release` in `packages/flutter_sheet_core/rust`.
- A hostile suite on 1 MiB and 512 KiB threads. Each case must finish in under 2 s and under 300 MB: `chain8000`, `outer_nov`, `arrays20`, the 814-byte ODS, the shared-string bomb, `cols20k` and each hanging function.
- Timing: 5,000 VLOOKUPs recalculate in under 1 s on the desktop.
- `sheetcli` over the corpus.
- Round-trip `sharedext`, `dyn` and `odsf` through headless LibreOffice.
- Screen tests guarded so that any synchronous call over 16 ms on a large fixture fails.

## B7. Slide: `flutter_slide_core` plus `slide_editor_screen.dart`, `slide_show_screen.dart` and `lib/widgets/slide/` (wave 2, size M, 2 agents)

**Agent A: engine**

1. **Blocker, S: numbering.** Clamp `startAt` and `start-value` to 1..=32767 (`text.rs:152`, `odp/text.rs:294` and `:474`), use saturating counters, and cap the bullet label. Today a 15 KB file aborts.
2. **Blocker, S: nesting.**
   - Stop `Pptx::items` (`pptx/mod.rs:522`) and the other group walkers past 32–64 levels. Today 800 nested groups overflow 1 MB.
   - **Major:** cap ODP list depth at 10 (`odp/text.rs:207`).
3. **Major, M: PPT import** (`ppt.rs`).
   - Cap slides, shapes and the size of the generated XML.
   - Walk runs with a cursor instead of calling `run_at` per character.
   - Use B2's picture budget.
4. **Major, M: undo.** Bound undo by bytes, or record changes per shape. Today 40 edits on a 30,000-shape slide reach 4.18 GB.
5. **Major, S: saving and panics.** `Deck::apply` catches a panic and restores its snapshot. Slide's check for `save_verified`: re-open, check the slide count, parse the edited parts.
6. **Minor, S:** treat non-finite sizes as missing and clamp them. Remove the out-of-date WMF/EMF warning at `ppt.rs:514`.

**Agent B: app**

7. **Major, M** (confirm on device): `savePart` and the metafile drawing in it run in `Isolate.run`. Thumbnails and refreshes after edits use `sceneAsync`, and an edit invalidates only the slides it touched.
8. **Major, S** (confirm on device): `SlideImageCache` (`slide_images.dart:37-49`) refuses pictures above about 50 MP and decodes at display size. It keeps an LRU of about 64 MB and decodes thumbnails separately.
9. **Accessibility, S:** fix the strip overflow at 150% and 200% text (`slide_editor_screen.dart:1511`). Add `logError` calls.

**Verify:**
- `cargo test` for the slide engine, with these hostile inputs:
  - the `startAt` = 2e9 deck;
  - 800-deep groups on a 512 KB thread;
  - a 1000-deep ODP list;
  - 40 edits on a 30k-shape slide staying under 500 MB.
- `slidecli` over the corpus.
- Open the saved PPTX and ODP files in headless LibreOffice.
- `flutter test test/screens/slide_editor_screen_test.dart`.

## B8. Text and archive: `flutter_text_core`, `flutter_archive_core`, shared `doc_encoding`, `text_editor_screen.dart`, `archive_screen.dart` (wave 2, size M, 1–2 agents)

1. **Major, M: lossless round trip.**
   - Map bytes that cannot be decoded to private-use code points that encode back to the same bytes.
   - Fix the nine code pages that fail a 256-byte round trip (windows-1253, 1255, 1257, 874; ISO-8859-3, -6, -7, -8, -11).
   - Until then, warn before saving with a count, and offer Save a copy.
   - Offer a line-ending choice when the file had mixed endings; `mixedLineEndings` is computed but never used.
2. **Major, S: UI isolate.**
   - `info(withStats)` runs in `Isolate.run`, with stats computed lazily.
   - `lines()` borrows the line index instead of copying it.
   - Find and replace move to an isolate for large files.
   - Today a 64 MB file takes 1.3 s and each page of a large file 79 ms.
3. **Major, S: Format JSON.** Cap the output (8 times the input or 32 MB), stop indenting past 64 levels, and run it in `Isolate.run`. Today 50 KB formats to 250 MB.
4. **Major, S: Extract all.** Remember the next free suffix per (folder, name), and cap the total name-clash checks. Today 6,000 entries with one name take 30 s.
5. **Major, S:** the text engine's check for `save_verified`; `logError` in the text editor.
6. **Minor, S:** a lower text-file limit on 32-bit; keep no `original` copy for valid UTF-8.

**Verify:**
- `cargo test` for text and archive.
- Every code page round-trips all 256 bytes.
- An unedited UTF-16 file with a lone surrogate saves byte-identical.
- Extracting 6,000 same-name entries takes under 1 s.
- Depth-10,000 JSON returns a clear error.
- `flutter test` for the text and archive screens and both packages.

## B9. Sweeps and mutation fuzzers (wave 3, size L; one agent per engine, each in its own test folders, plus one owner of the shared script)

- Add a small dev-only crate, `packages/doc_common/crates/doc_testkit`, with no dependencies. It provides:
  - a xorshift mutator (byte flips, truncation, inflated counts);
  - `run_limited(f, stack, deadline)`, which reads RSS from `/proc/self/status`.

  The PDF engine keeps its own copy of this, because it does not depend on `doc_common`.
- **A sweep per engine** (an ignored test or an example):
  - open the file and view everything; edit one thing; save; reopen; export a PDF;
  - limit time and memory per file;
  - fail on a panic or timeout, or when an untouched ZIP entry changes (compare raw CRC and compressed bytes);
  - for sheets, compare recomputed values with the cached ones.

  Saved files are checked in headless LibreOffice.
- **Mutation fuzzing per engine and shared crate** with fixed seeds and a fixed iteration count:
  - PDF: xref and recovery, filter chains, fonts, codecs;
  - XLSX, ODS and XLS; DOCX, ODT, RTF and DOC; PPTX, ODP and PPT; WMF and EMF; text and archives.

  Run them through a new `fuzz` mode in `scripts/build_engines.sh`.
- `test/pvs_pdf_test.dart` gets a deadline and RSS limit per operation, and fails on an empty category instead of passing silently.
- All hostile suites run again with `RUST_MIN_STACK=524288`.
- Add byte-identity tests: an unedited save is identical, and an edited save copies untouched entries raw.

**Verify:** each sweep finishes over the corpus with 0 panics and 0 timeouts. Every crash found becomes a regression test.

## B10. Work across all editors (wave 3, after B5–B8, size M, 1 agent; touches every editor screen)

1. **Major, M: draft autosave and recovery** (PLAN §4.7).
   - Add a `DraftService` under `lib/services/`.
   - On `AppLifecycleState` hidden or paused, and a few seconds after the last edit, the engine saves a copy to app storage under `Drafts/` with a JSON note naming the source.
   - When the document opens again, offer to restore it. Delete the draft on Save or Discard.
   - Covers word, sheet, slide, text and `pdf_edit` (its pending items as JSON).
   - Add widget tests that simulate the lifecycle.
2. **Major, M: accessibility in the editors.**
   - Label the unlabeled tappables.
   - Make the Word style and size pickers (32 dp) at least 48 dp tall.
   - Fix the PdfEdit tool-label contrast and add PdfViewer page semantics.
   - Extend B4's guideline tests to all 13 screens.

**Verify:** `flutter test`, including the new accessibility and draft tests.

---

## Needs the owner's Mac, an emulator or a phone

The code for every item marked "confirm on device" can be written here. Only confirming it needs hardware.

**The owner's Mac**
- A signed release app bundle after the version bump (`key.properties` is on the Mac). Run `check_android_native.py` on it and the R8 release smoke test.
- Rebuild the PDF engine's macOS dylib and iOS XCFramework after B3, plus the per-format macOS binaries.
- Check saved files in real Excel, Word and PowerPoint:
  - Excel 365 dynamic arrays (`cm`/`vm`/`ca`, `_xlws.`);
  - shared formulas with external links;
  - edited DOCX and ODT open without a repair prompt.

**Emulator `pdfhelper_api36_16kb` (2.5 GB)**
- Open one file of each kind: docx/doc/odt/rtf/wps, xlsx/xls/ods/csv/et, pptx/ppt/odp/dps, txt/md/html/json, zip/tar.gz, fodt/fods/fodp, and a PDF form.
- "Open with" from Files by Google and from a `content://` share; check that "Always" choices survive.
- Save in place in `Download/`, with All files access and without it.
- Export PDF; check that legacy files save as modern formats with the notice.
- Process death ("Don't keep activities", `am kill`) with unsaved edits, after B10.
- `dumpsys meminfo` with a 100-photo deck, a DOCX holding 20 phone photos, a 50 MB XLSX and a 300 MB PDF.
- ANR checks: whole-column format and replace-all on a 100k-row sheet.
- Largest font and display size, TalkBack and Accessibility Scanner in both themes; predictive back; edge-to-edge.
- Measure the `Isolate.run` stack size, the real out-of-memory thresholds that set the sheet cell budget, and how the PDF render deadline feels.
- Work through the phase 9 Next-steps list.

**Other emulator images**
- API 28: `WRITE_EXTERNAL_STORAGE` public saves, in-place saves, Extract all.
- API 29: the legacy-storage Files sweep and saves.
- API 24 (minSdk): all six engines load, and one file of each kind opens and saves.
- API 30–33 without All files access: the temporary file of `save_verified` renamed through FUSE.

**The owner's arm64 phone**
- A Play internal-testing build, registered as an AdMob test device.
- The R8 smoke test for every kind, the consent form, and the interstitial after 4 operations.
- A Crashlytics test crash, both Dart and native (after the NDK setup).
- Camera scan legibility.

**A 2–3 GB 32-bit (armeabi-v7a) phone**
- Measure the isolate stack (512 KB expected).
- Run the hostile corpus and the large files.

**His father's phone**
- The eight jobs in PLAN §1, with his own font and display settings and his real WhatsApp and email files.

## Owner decisions

Each comes with a proposed default.

1. **Untouched XML after an edit** (PLAN §3.3). Today an edited part is rewritten in Office-normalized form, which means the same but is not byte-identical.
   - Default for Word: keep each top-level body element's original bytes and write untouched ones from them (M).
   - Default for sheets: reword §3.3 to "equivalent XML", and keep the attributes we don't model.
2. **Backups.** Default: the previous version of each saved file, kept in app-private storage until the next clean open, with a 500 MB cap overall. No restore screen yet.
3. **Phone budgets.** Defaults:
   - 2–4M cells, chosen by device RAM;
   - 64 MB per XML part;
   - a 200 MB open limit for decks (512 MB today);
   - a lower text-file limit on 32-bit;
   - 16–24M pixels per picture (64M today; this lowers export quality for huge scans);
   - about 20 s of PDF rendering per page before "page too complex".
4. **Keep shipping armeabi-v7a?** Keeping it means 512 KB isolate stacks, lower budgets and a 32-bit test phone. Default: keep it, protected by B1's 16 MB-stack backstop.
5. **Fuzzing tools.** `cargo-fuzz`/libFuzzer (C++) and `proptest` fall outside the allowed dependencies, so the plan uses in-tree mutators. Allowing `cargo-fuzz` as a tool that never ships is the owner's call.
6. **Crashlytics NDK and native symbol upload** (already pending), and whether to add `debug = "line-tables-only"` to the engines' release profiles. The privacy policy would then need to mention native crash data.
7. **Play policy.**
   - Rewrite the hosted privacy policy (`yourmateapps.github.io/pdfhelper/privacy-policy.html`, which still covers "PDFHelper" and PDFs only).
   - Submit the All-files-access declaration as "document management", with a screen recording.
   - Recheck the Data safety form. If the declaration is refused, remove the permission.
8. **Version:** `versionName` 4.0.0 and a `versionCode` N above the highest code already uploaded to the Play Console.
9. **Git-ignored engine binaries** (pending). This affects whether a release can be rebuilt reproducibly.
10. **`doc_common`'s own repository.** Only the owner can create it. Default: move it after waves 1–2 land, so the phase 10 churn stays in one tree.
11. **Commits.** Batches stay uncommitted until the owner asks. Then each submodule commits on `main` and pushes, and the app commits the gitlinks.