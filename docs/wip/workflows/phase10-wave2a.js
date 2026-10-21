export const meta = {
  name: 'phase10-wave2a',
  description: 'Phase 10 wave 2a: Word engine (B5) and Sheet engine (B6) hardening, each batch adversarially verified',
  phases: [
    { title: 'Build', detail: 'B5a Word reading, B5b Word speed and saving; B6a formulas, B6b functions, B6c readers and FFI, then B6d editing and screen' },
    { title: 'Verify', detail: 'one adversarial verifier per batch' },
  ],
}

// Saved at hand-off (2026-10-18) from the session that ran it, with the corrections the hand-off review found.
// Apply docs/wip/phase10-wave2a-word-partial.patch in packages/flutter_word_core before launching B5.

const COMMON = `
You are working in the DocHelper repository at /home/user/pdfhelper: a Flutter app (Android first) whose document engines are written from scratch in Rust. The guides AGENTS.md (app) and packages/<engine>/AGENTS.md bind you; read them. This is phase 10 (hardening): the plan is docs/PHASE10_PLAN.md. Read its Overview, your batch's section and "Owner decisions" (where a number or policy is needed, use the default proposed there: 64 MB per XML part, 2-4M cells chosen by device RAM, backups of the previous version in app-private storage, keep armeabi-v7a, in-tree xorshift mutators instead of cargo-fuzz).
Wave 1 is done and committed (PLAN.md progress log, 2026-10-17/18). Shared APIs it added in packages/doc_common that your batch wires in:
- doc_ffi::save_verified(path, bytes, verify: impl FnOnce(&[u8]) -> Result<(), FfiError>): unique temp file, fsync, read back and run your check, back up the previous version (to the folder set by doc_ffi::set_backup_dir), rename, fsync the folder. Use it for every save of a user's file instead of write_file_atomically, with an engine check that reopens the bytes in memory and compares counts.
- doc_ffi::set_backup_dir_c(*const c_char) and remove_stale_temp_files_c(dir, min_age_seconds): ready-made bodies; export them as <kind>_set_backup_dir and <kind>_remove_stale_temp_files, and bind them in the package's Dart API (the app calls them in a later batch).
- Every engine call already runs on a 16 MB-stack worker (doc_ffi call wrappers); a session whose edit panicked refuses further edits with PANIC until reopened.
- doc_opc: PackageLimits (64 MB per XML part), duplicate_parts(); a part over the XML node budget or a size limit arrives as OpcError::Zip(ZipError::TooLarge(part)) (OpcError has no TooLarge of its own): map it to the FFI code TOO_LARGE, not CORRUPT. When duplicate_parts() is not empty, say so in the open result so the screen can show a note (only the first entry of a name is saved).
- doc_art blip budget API and doc_metafile render budget exist.
Rules:
- Engines are Rust from scratch: no new crates. Code reads like the code around it: plain-prose doc comments, same naming and idioms.
- Every hostile input gets a regression test built inside the Rust tests (no binary fixtures committed) that fails or aborts before the fix and passes after: run it on a 512 KiB-stack thread where recursion matters, under a time bound, and check memory where allocation matters (VmHWM from /proc/self/status, or prlimit --as). Prove "fails before" by running the test against the committed code in a scratch copy, never by reverting in the repository.
- Never damage a user's file; ordinary files must behave exactly as before (the existing tests keep passing; compare outputs on real files: test_corpus/, files you generate with headless LibreOffice /usr/bin/soffice --convert-to, and the engines' fixtures).
- Tooling: export PATH=/opt/flutter/bin:$HOME/.cargo/bin:$PATH. Build host libraries with bash scripts/build_engines.sh host --only <kind>; app tests need eval "$(bash scripts/build_engines.sh env)" first. Prefer cargo test --release (cached). 4 CPUs and limited disk are shared with other agents: check df -h / before big builds, and if under 4 GB is free delete target/debug folders.
- Widget tests: anything awaiting Isolate.run never finishes in the fake clock: alternate tester.runAsync(() => Future.delayed(...)) with tester.pump(...) (see the until/flush helpers in test/screens/*_test.dart); pumpAndSettle hangs while a spinner shows. Closures passed to Isolate.run must not capture this or a State. AppColors.of(context) only inside build.
- Do NOT git commit, push, stash, checkout or reset; the orchestrator commits. Edit ONLY your assigned files; other agents edit other files of the same engine at the same time, so re-read a file right before editing it and keep edits to shared files (lib.rs, mod.rs, Cargo.toml) minimal. Do not edit PLAN.md, CLAUDE.md, AGENTS.md or docs/PHASE10_PLAN.md.
- Report honestly: what you changed, before/after measurements, every test run with counts, and anything left undone.
Return a structured result.`

const RESULT = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    done: { type: 'array', items: { type: 'string' }, description: 'Each plan item done, with how and the before/after measurement' },
    notDone: { type: 'array', items: { type: 'string' }, description: 'Each assigned item not done, with why' },
    files: { type: 'array', items: { type: 'string' } },
    apis: { type: 'string', description: 'New or changed APIs others call (exact Rust, FFI and Dart signatures)' },
    tests: { type: 'string', description: 'Commands run and results with counts' },
  },
  required: ['summary', 'done', 'notDone', 'files', 'apis', 'tests'],
}

const B5A = `YOUR PART OF BATCH B5 (Word, packages/flutter_word_core): reading safety, B5 items 1-6 and item 12, in rust/crates/word_core only: A previous attempt at batch B5 was cut off by a usage limit after making edits in packages/flutter_word_core (git status and git diff there: word_core document.rs, document/, lib.rs, pdf.rs, limits.rs, hostile.rs). Do not start over: read that diff, keep what belongs to your part, finish it, make it compile and test it. the readers (DOCX, ODT, RTF, Word 97 doc.rs), numbering, the tree/walk code (Walk::walk, shown_text, tree::build, blocks_of and the ODT walks), length parsing, and pdf.rs (both the column sum at about line 401 and the row split at about 466-479: a table row taller than a page splits across pages). Item 5: give the main and styles parts Word's own limits through doc_opc::PackageLimits. Item 4 also: decode Word 97 pictures under one doc_art::Budget::import() per import through fbse_blip_within and find_blip_within (doc.rs calls the unbudgeted fbse_blip and find_blip). pdf::export now returns Result<Vec<u8>, WordError> in the diff: update its callers, word_ffi's word_export_pdf (map TooLarge to TOO_LARGE; tell the other agent's verifier) and examples/wordcli.rs, or the workspace does not build. Leave to the other agent: the document model's id lookups (projected, locate, patch, items_mut), find and replace, table windowing, word_ffi, the package's Dart code and the app. Verify: cd packages/flutter_word_core/rust && cargo test --release; cargo run --release --example wordcli over the .docx/.odt/.rtf/.doc files in test_corpus and ones you make with soffice, comparing output before and after; open the PDFs you export.`

const B5B = `YOUR PART OF BATCH B5 (Word): speed, the UI isolate and saving, B5 items 7-11: A previous attempt at batch B5 was cut off by a usage limit after making edits in packages/flutter_word_core (git status and git diff there: word_core document.rs, document/, lib.rs, pdf.rs, limits.rs, hostile.rs). Do not start over: read that diff, keep what belongs to your part, finish it, make it compile and test it. in word_core the id lookups (an id to path index for projected, locate, patch and items_mut; linear patch and replace-all; find capped at 10,000 results), table windowing (a summary, then rows by range; vertical merges found in one pass; serde structs instead of cloned json! trees), all of rust/crates/word_ffi (save through doc_ffi::save_verified with Word's check: the ZIP opens, the main part parses, the paragraph count matches; export word_set_backup_dir and word_remove_stale_temp_files; map TooLarge to TOO_LARGE, including word_core's From<doc_xml::XmlError>, which gives Corrupt today; report duplicate_parts() in the open result and show the note on the screen; unknown object ids in edits give INVALID_ARGUMENT instead of panicking; clippy unwrap_used outside tests), the package's Dart lib and test (bind the new exports and the table window API), and in the app lib/screens/document_editor_screen.dart and lib/widgets/word/ (find, replace-all, counts, outline, plainText and large block requests through Isolate.run with a busy state; DocTableView rows built lazily; pictures decoded at display size with cacheWidth; the doc_blocks.dart clamp mirroring the engine's; logError in every catch block) and their tests. Leave the readers, numbering, tree walks and pdf.rs to the other agent. Verify: cargo test --release in packages/flutter_word_core/rust; timing tests (counts on 60k paragraphs under 0.5 s, replace-all under 2 s, the first window of a 20k-row table under 0.5 s); bash scripts/build_engines.sh host --only word; the package flutter test with WORD_CORE_LIB_PATH; eval env && flutter test test/screens/document_editor_screen_test.dart; open saved DOCX and ODT in headless LibreOffice.`

const B6A = `YOUR PART OF BATCH B6 (Sheet, packages/flutter_sheet_core): formula parsing, evaluation and recalculation, B6 items 1-5: rust/crates/sheet_core parser.rs, unparse.rs, ast.rs, eval.rs, calc.rs and functions/mod.rs only. Operator chains (n-ary node or a loop, depth counted for every node, formulas capped at 8,192 characters, iterative Drop/unparse/walk), nested evaluation through an explicit work stack instead of recursion through Grid::value, range broadcasting with checked_mul and a 4M-element budget in lift2/lift, reference chains and cycles (defer and re-pass, report Kahn's leftovers as circular), the & length check, a calculation deadline and cancel flag leaving remaining cells dirty, pending checked only for formula cells. Also expose a "recalculate only these cells and their dependents" API for the editing agent and describe it exactly in your result. Others edit functions/* (except mod.rs), value.rs, criteria.rs, lookup.rs, the readers and writers, sheet_ffi and edit.rs at the same time. Verify: cargo test --release in packages/flutter_sheet_core/rust, hostile cases on 1 MiB and 512 KiB threads (chain8000, outer products, a 300-cell cycle wrapped in SUMs), each under 2 s and 300 MB.`

const B6B = `YOUR PART OF BATCH B6 (Sheet): the function library and comparisons, B6 items 6-8: rust/crates/sheet_core functions/* except functions/mod.rs, value.rs, criteria.rs and lookup.rs only. Magnitude guards for FACTDOUBLE, PERMUT, COMBIN, COMBINA, DDB, CUMIPMT, CUMPRINC and a sweep for every other loop sized by a user number; the IF budget in logic.rs; SUBSTITUTE and the other text builders check the 32,767-character limit before allocating; compare() exact first without format! and parse; lookups reuse their key columns (5,000 VLOOKUPs recalculate in under 1 s). Results must stay exactly as Excel gives them: keep and extend the function tests. Others edit parser/eval/calc/functions/mod.rs, the readers and writers, sheet_ffi and edit.rs at the same time. Verify: cargo test --release in packages/flutter_sheet_core/rust and the timing test.`

const B6C = `YOUR PART OF BATCH B6 (Sheet): readers, writers, memory and round trip, B6 items 9-14: rust/crates/sheet_core xlsx/*, ods/*, csv.rs, xls/* and rust/crates/sheet_ffi only. Array-formula member cells counted toward the cell budget (or stored as ranges); a phone budget for cells and memory passed in from the caller (an FFI option; default 4M cells), shared strings capped by count and bytes, ODS repeats checked before expanding, CSV streamed into cells, <col> information stored as ranges (cols20k: 3.7 KB took 20 s); shared formulas whose anchor does not parse kept as raw XML; cm, vm, ca, _xlws. and SINGLE/ANCHORARRAY kept; the original ODS table:formula text kept while a cell is unchanged; saving through doc_ffi::save_verified with the sheet check (reopen in memory, compare sheet, cell and formula counts) and reporting a failure only when the file was not written; export sheet_set_backup_dir and sheet_remove_stale_temp_files; map TooLarge to TOO_LARGE (today every OpcError maps to CORRUPT); CSV export walks only stored cells; ODS merges indexed before writing; XLS and ODS coordinates and spans clamped with checked arithmetic. Describe every new FFI function and option exactly in your result: the editing agent binds them in Dart afterwards. Others edit the formula engine, functions and edit.rs at the same time. Verify: cargo test --release; cargo run --release --example sheetcli over the corpus and soffice-made files, before and after; round trip files through headless LibreOffice.`

const B6D = `YOUR PART OF BATCH B6 (Sheet): editing and the screen, B6 items 15-16, done after the other three B6 agents (their reports follow): rust/crates/sheet_core edit.rs, the package's Dart lib and test, the app's lib/screens/sheet_editor_screen.dart, lib/widgets/sheet/ (sheet_grid_data.dart and the rest) and their tests. Structural edits snapshot only the sheets they touch, insert/delete recorded as inverse operations, rename/hide/move/define-name copy no cells, undo budgeted by bytes, recalculation only of what changed through the formula agent's new API; every apply, undo, redo and recalculate through applyAsync with a busy overlay; a structural snapshot restored after a panic; grid blocks far from the viewport evicted; logError in every catch block; bind in Dart the new sheet_ffi functions (backup dir, stale temp files, the cell budget option) described in the reports. Verify: cargo test --release; bash scripts/build_engines.sh host --only sheet; the package flutter test with SHEET_CORE_LIB_PATH; eval env && flutter test test/screens/sheet_editor_screen_test.dart, with a guard that fails any synchronous engine call over 16 ms on a large fixture.`

const BATCHES = [
  { batch: 'B5', scope: 'packages/flutter_word_core (word_core, word_ffi, Dart lib and tests), lib/screens/document_editor_screen.dart, lib/widgets/word/ and their tests', stages: [[{ key: 'B5a-word-reading', prompt: B5A }, { key: 'B5b-word-speed-saving', prompt: B5B }]] },
  { batch: 'B6', scope: 'packages/flutter_sheet_core (sheet_core, sheet_ffi, Dart lib and tests), lib/screens/sheet_editor_screen.dart, lib/widgets/sheet/ and their tests', stages: [[{ key: 'B6a-formulas', prompt: B6A }, { key: 'B6b-functions', prompt: B6B }, { key: 'B6c-readers-ffi', prompt: B6C }], [{ key: 'B6d-editing-screen', prompt: B6D }]] },
]

const FIXED = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    confirmed: { type: 'array', items: { type: 'string' }, description: 'Problems confirmed and fixed, each with how it was reproduced' },
    rejected: { type: 'array', items: { type: 'string' } },
    remaining: { type: 'array', items: { type: 'string' }, description: 'Plan items still not done and problems left, with why' },
    files: { type: 'array', items: { type: 'string' } },
    tests: { type: 'string', description: 'Every check run at the end, with counts' },
  },
  required: ['summary', 'confirmed', 'rejected', 'remaining', 'files', 'tests'],
}

const results = await pipeline(
  BATCHES,
  async (b) => {
    const reports = []
    for (const stage of b.stages) {
      const prior = reports.length ? `\n\nReports from the agents before you in this batch:\n${JSON.stringify(reports.map(r => ({ key: r.key, summary: r.summary, apis: r.apis, notDone: r.notDone })), null, 1).slice(0, 30000)}` : ''
      const got = await parallel(stage.map(s => () =>
        agent(`${COMMON}\n\n${s.prompt}${prior}`, { label: s.key, phase: 'Build', schema: RESULT })
          .then(r => ({ key: s.key, ...(r || { summary: 'builder failed (no result)', done: [], notDone: ['everything: the agent failed'], files: [], apis: '', tests: '' }) }))))
      reports.push(...got.filter(Boolean))
    }
    return reports
  },
  (reports, b) => agent(`${COMMON}\n\nYOUR TASK: adversarially verify and finish batch ${b.batch} (scope: ${b.scope}), then run its checks. The builders' reports:\n${JSON.stringify(reports, null, 1).slice(0, 40000)}\n\nDo not trust the reports. Read the uncommitted diff of the scope (git status and git diff in the engine submodule and in the app for the batch's app files; new files too) against the plan section for ${b.batch}. For every plan item check it is really done; run every hostile case in the plan yourself (your own generator, not only the builders' tests) and confirm it is now bounded (time, memory, stack at 512 KiB) and that each regression test fails on the committed code (in a scratch copy). Hunt for what the batch breaks: ordinary files (compare outputs before and after on real files, and round-trip saved files through headless LibreOffice), Excel- or Word-exact results, error codes the Dart side expects, hot-path speed, 32-bit overflow. Fix every problem you confirm, finish small items left undone when you can do them well, add tests, then run: cargo test --release for the engine; bash scripts/build_engines.sh test; bash scripts/build_engines.sh host; eval "$(bash scripts/build_engines.sh env)" && flutter test (the whole app; accepted failures are only test/pvs_pdf_test.dart cases with missing corpus files) and the engine package's flutter test. Leave everything uncommitted.`, { label: `verify-${b.batch}`, phase: 'Verify', schema: FIXED })
    .then(v => ({ batch: b.batch, builders: reports, ...(v || { summary: 'verifier failed (no result)', confirmed: [], rejected: [], remaining: ['verification not done'], files: [], tests: '' }) })),
)

return results.filter(Boolean)
