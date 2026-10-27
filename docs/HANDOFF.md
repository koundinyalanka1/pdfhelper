# Hand-off: where DocHelper stands and how to carry on

Written 2026-10-18 at the end of the session that finished phase 10's
first wave; brought up to date on 2026-10-19 by the Windows session that
finished waves 2 and 3 in the working tree (see "Uncommitted work in this
checkout"). It is for whoever continues: another coding agent or a person.
Read it with the app's [AGENTS.md](../AGENTS.md) (the rules) and
[PLAN.md](../PLAN.md) (the plan and the full progress log).

## In one paragraph

DocHelper is a Flutter app, Android first, that opens, edits and saves
PDF, Word, Excel, PowerPoint, OpenDocument, WPS, text, Markdown, HTML,
JSON, picture and archive files, with every engine written from scratch in
Rust. Phases 0 to 9 of [PLAN.md](../PLAN.md) are done: every file kind the
plan names opens, and the editable ones save back in place. Phase 10
(hardening and release) is nearly done. Wave 1 is committed. Waves 2 and 3
(hardening each editor engine, mutation fuzzers, draft autosave, editor
accessibility, a Backups screen) and the release configuration
(Crashlytics NDK, low-memory exit reports, a privacy-policy draft) are
done and checked in the working tree, **not committed** (the owner asked
for no commits). Still to do: the checks this Windows machine could not
run (listed below), the device rounds that need the owner's Mac or a
phone, the owner's release steps, and the release itself.

## What the MVP does

The everyday jobs of PLAN §1, as the code stands (none has been tried on a
phone or emulator since phase 2; see "Not checked yet" below):

- **PDF.** Fast viewer (multi-threaded, region rendering, pixel-identical
  to before), search, text selection, fill forms, sign, annotate, stamp
  page numbers and watermarks, merge, split, compress, password
  protection, pages to pictures, scan to PDF. Saves are incremental
  updates. A page too complex to draw in full is shown as far as it got,
  with a "page too complex" notice; one that fails or passes the 30 s
  timeout shows a placeholder with Retry instead of an endless spinner.
- **Word** (DOCX, ODT edited in place; RTF, Word 97-2003 `.doc` and WPS
  `.wps` imported and saved as DOCX; the engine can import TXT and
  Markdown too, but the app opens those in the text editor). Reflowing reading
  view, one paragraph edited at a time, find and replace, styles, lists,
  tables, pictures, page view and PDF export.
- **Spreadsheets** (XLSX, ODS edited in place; CSV; XLS and WPS `.et`
  imported). A custom-painted grid, about 240 functions, recalculation,
  number formats, row and column edits, PDF export.
- **Presentations** (PPTX, ODP edited in place; PPT and WPS `.dps`
  imported). Slides drawn as scenes, text edits, slide reorder, add and
  delete, a slide show, PDF export.
- **Text.** Any text file, saved back in its own encoding, byte-order mark
  and line endings; Markdown and HTML shown as a page; JSON as a tree.
- **Other files.** Pictures (zoom, turn, share, make a PDF), ZIP, TAR and
  gzip archives (browse, open, share, extract all), making a ZIP, flat
  OpenDocument (`.fodt/.fods/.fodp`), and "open with another app" for the
  rest.
- **Around them.** The Files tab finds the phone's PDFs, office
  documents, `.txt`/`.md` files and ZIPs (not pictures, HTML, JSON or
  TAR/gzip, which open through "Open with" or Tools > Open a file);
  "Open with" from other apps; saving in place, or a public copy in
  `Download/DocHelper` or `Documents/DocHelper`; New blank documents;
  engine errors reported to Crashlytics by kind (never with file names).

## Repositories

Work happens on `main` everywhere (the owner's rule; a cloud session's
harness may name some other branch, but the owner's rule wins). The
engines are git submodules of the app: commit and push inside one first,
then commit its gitlink in the app.

| Path | Repository | `main` at hand-off |
| --- | --- | --- |
| `.` (the app) | `koundinyalanka1/pdfhelper` | the latest commit that changes this file (`git log -1 -- docs/HANDOFF.md`) |
| `packages/flutter_pdf_core` | `koundinyalanka1/flutter_pdf_core` | `6d63d1c` |
| `packages/flutter_text_core` | `koundinyalanka1/flutter_text_core` | `b28a205` |
| `packages/flutter_sheet_core` | `koundinyalanka1/flutter_sheet_core` | `e748c82` |
| `packages/flutter_word_core` | `koundinyalanka1/flutter_word_core` (private) | `7d3520d` |
| `packages/flutter_slide_core` | `koundinyalanka1/flutter_slide_core` | `b99b5a1` |
| `packages/flutter_archive_core` | `koundinyalanka1/flutter_archive_core` | `8e52cbe` |
| `packages/doc_common` | none yet: part of the app's tree | (app) |

**Branches.** The owner wants `main` and nothing else in every
repository. On 2026-10-18 four other branches were left, all fully merged
into `main` (0 commits of their own). This session's GitHub access was
refused (HTTP 403) when it tried to delete them, so they still need
deleting, on GitHub's Branches page or with `git push origin --delete
<branch>` from a machine with full access:

- `pdfhelper`: `ccr-7000243f-cl0s82`, `production-audit-fixes`
- `flutter_pdf_core`: `production-audit-fixes`
- `flutter_sheet_core`: `ccr-7000243f-cl0s82`

`doc_common` gets its own repository once the owner creates
`koundinyalanka1/doc_common`; its [AGENTS.md](../packages/doc_common/AGENTS.md)
says how to move it.

Every repository has an `AGENTS.md` (the guide for any coding agent) and a
`CLAUDE.md` that imports it. The engines' guides were written on
2026-10-17, just before wave 1 landed: where they describe B1-B4 work
(`save_verified`, the 16 MB-stack backstop, PDF render budgets) as
coming, it has landed. Where a guide says to save with
`write_file_atomically`, phase 10 moves user files to `save_verified`.

### Changed since the engine guides were written

Wave 2 work on 2026-10-18 and 19 (PLAN.md's progress log has the detail)
changed things the engines' `AGENTS.md` files still describe the old way.
Trust this list, and the code, over them:

- **Saving.** Text, sheet, Word and slide saves go through
  `doc_ffi::save_verified` (written beside the file, read back, checked,
  then renamed). Each engine exports `<kind>_set_backup_dir`, and the app
  (`lib/services/engine_backups.dart`) points all four at a private
  `Backups` folder at start-up and sweeps stale temporary files from its
  own folders (`text_remove_stale_temp_files`).
- **File limits.** Decks open up to 200 MB (was 512 MB). On 32-bit
  builds, text, Word and workbook files open up to 128 MB (256 MB on
  64-bit), and workbooks hold at most 4 million cells (20 million on
  64-bit).
- **Counts read from files are clamped:** list starts (0 or 1 to 32,767),
  letter and Roman labels, ODT and DOCX column spans (1,024; 4,096
  columns a row), RTF cells (63 a row), PowerPoint group nesting (64) and
  ODP list nesting (10), non-finite slide lengths, and JSON indentation
  (64 levels, at most eight times the input).
- **Formulas.** Arrays past 4 million values, `&` past 32,767 characters,
  and loop-sized functions (FACTDOUBLE, COMBIN, COMBINA, PERMUT, DDB,
  CUMIPMT, CUMPRINC) past their limits answer `#NUM!` or `#VALUE!`.
- **Pictures.** Word, WPS and PowerPoint 97-2003 imports decode pictures
  under one `doc_art` budget each; the slide screen draws pictures past
  50 megapixels as grey boxes.
- **Robustness.** A slide edit that panics restores the deck; Extract all
  remembers the next free number per name; the four editor screens report
  every caught failure (kind and size only).
- **Sheets (uncommitted).** An in-tree `FastHasher` (`fasthash.rs`) for
  the calculation maps; the cell budget set from the phone's memory
  (`sheet_set_cell_budget`, 2 to 4 million cells, from
  `EngineBackups.setMemoryBudgets`); undo budgeted by bytes
  (`UNDO_BUDGET`, 4 MB) with structural edits recorded as inverses;
  `_xlfn._xlws.`, `SINGLE` and `ANCHORARRAY` kept when formulas are
  written back; every edit, undo, redo and recalculation off the UI
  isolate (`_applyAsync`, with a busy overlay), and a panicking edit
  restores the workbook.
- **Word (uncommitted).** `tree::find_path` and `paragraphs` are
  iterative; find, replace-all, counts, outline and plain text run off
  the UI isolate with a busy state; table rows load in windows
  (`loadRows`); pictures decode at display size (`cacheWidth`).
- **Text (uncommitted).** `doc_encoding::encode_lossless` pads text typed
  after a cut-off UTF-16 or UTF-32 character to a whole code unit.
- **Drafts (uncommitted).** `DraftService` and `EditorDraft` save a draft
  of the text, Word, sheet and slide editors a few seconds after an edit
  and when the app is hidden; reopening offers to restore it; Save or
  Discard deletes it. PDF fill-and-sign has no drafts yet.
- **Backups screen (uncommitted).** Settings > Backups
  (`lib/screens/backups_screen.dart`) lists the private `Backups` folder,
  newest first. Opening one works on a copy in the app's documents
  (`name (backup).ext`), so the backup itself is never changed; it can
  also be shared. Backups are kept by file name only (`doc_ffi`'s
  `back_up`), so the screen cannot put one back over its original.

## Setting up a fresh machine

Follow "Setting up" in [AGENTS.md](../AGENTS.md). What this session's Linux
cloud machine needed on top of it (4 CPUs, about 9 GB of free disk):

- Flutter 3.47.7 at `/opt/flutter`, installed during the session (the
  machine's image did not have it): `git clone --depth 1 -b 3.47.7
  https://github.com/flutter/flutter.git /opt/flutter`, then
  `/opt/flutter/bin/flutter --version` fetches the rest. Rust 1.97 came
  with the image (1.92 or newer is needed: the PDF engine's vendored
  codecs ask for it).
  `export PATH=/opt/flutter/bin:$HOME/.cargo/bin:$PATH`.
- `git submodule update --init --recursive` (the Word engine's repository
  is private: the session needs access to it). Submodules come up on a
  detached HEAD: run `git submodule foreach git switch main` (each `main`
  equals its gitlink at hand-off) before editing or committing in one.
- Some Rust tests pass without checking anything when the system lacks
  what they use: Carlito and Liberation fonts in
  `/usr/share/fonts/truetype` (`fonts-crosextra-carlito`,
  `fonts-liberation`), `pdftotext` and `pdfinfo` (`poppler-utils`) and
  `prlimit`. All were present here; install them on a new machine.
- For Android binaries and an APK: `rustup target add
  aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`,
  `cargo install cargo-ndk`, the NDK r27c zip, the command-line tools and
  `sdkmanager --licenses`, and `android/local.properties` with
  `flutter.sdk=` and `sdk.dir=` (git-ignored).
- Maven Central answers 429 to shared cloud addresses. This Gradle init
  script, saved as `~/.gradle/init.d/central-mirror.gradle`, fixes it:

  ```groovy
  def mirror = 'https://maven-central.storage-download.googleapis.com/maven2/'
  def redirect = { repo ->
      if (repo instanceof MavenArtifactRepository && repo.url.toString().startsWith('https://repo.maven.apache.org')) {
          repo.url = mirror
      }
  }
  settingsEvaluated { settings ->
      settings.pluginManagement.repositories.all(redirect)
      settings.dependencyResolutionManagement.repositories.all(redirect)
  }
  allprojects {
      buildscript.repositories.all(redirect)
      repositories.all(redirect)
  }
  ```
- LibreOffice (`soffice`) was installed and is handy for making test files
  and for checking that saved files open (`soffice --headless
  --convert-to`).
- The corpus (`test_corpus/`, git-ignored, about 220 MB) comes from the
  `scripts/download_*_corpus.py` scripts. Wikimedia throttles cloud
  addresses for hours; the files it refuses make the PDF sweep's only
  failures.
- Disk fills fast: Gradle caches, `build/` and the engines'
  `rust/target/debug` folders can all be deleted when it does.

## Checking the state

The owner's preference: after a change, run the changed engine's tests and
the screen tests that use it, not the full app suite (it takes long and
spends the usage budget). Run the full suite only when the owner asks.

From the app root, after the setup:

```bash
bash scripts/build_libs.sh host
bash scripts/build_libs.sh test
eval "$(bash scripts/build_libs.sh env)"
flutter analyze
flutter test
(cd packages/doc_common && cargo test --release)
(cd packages/flutter_pdf_core/rust && cargo test --workspace --release)
```

Results at hand-off (2026-10-19, this machine, after the wave 2 work):

| Check | Result |
| --- | --- |
| `cargo test --release` in `doc_common` | 176 passed |
| PDF engine, `cargo test --workspace --release` | 572 passed |
| `build_libs.sh test` (debug: shared crates 176, then text 94, sheet 80, word 26, slide 29, archive 26) | 431 passed |
| `flutter analyze` | 25 issues (also 25 before phase 10) |
| `flutter test` (the app, every engine loaded) | 798 passed, 2 skipped, 8 failed |

The app's 8 failures are all in `test/pvs_pdf_test.dart`, the PDF corpus
sweep, for corpus files Wikimedia would not serve: the 143 MB city
directory (4 tests), the Iliad and Ramayana (3) and one language sample
(1). Without the `eval` line the engine tests skip themselves and the
suite "passes" having tested less.

### Checks of the uncommitted work (2026-10-19, Windows)

Run on the owner's Windows laptop with `cargo +stable-x86_64-pc-windows-gnu`
and the five per-format engine DLLs copied to `build/engines` (each
`<KIND>_CORE_LIB_PATH` pointing there). The PDF engine cannot link on
this machine (`getrandom` 0.3 and `windows-sys` 0.61 need `dlltool`), so
there is no `pdf_ffi.dll`; `cargo check` passes for it.

| Check | Result |
| --- | --- |
| `doc_common`, `cargo test --workspace --release --exclude doc_layout --exclude doc_pdf` | all pass; the `doc_xml` doctest and the two excluded crates are blocked by antivirus ("Access is denied") |
| Sheet engine, release | 87 + 4 mutation + 4 + 3 pass |
| Word engine, release | 31 + 4 mutation + 2 pass |
| Text engine, release | 96 + 3 mutation + 8 FFI pass (the last two run directly, antivirus blocked cargo starting them) |
| Slide engine, release | 36 pass (run directly, as above) |
| Archive engine, release | 16 pass; 3 need `python3`, and Extract all of 6,000 same-named entries took 26 s against a 5 s limit (Windows file creation under Defender; numbering is already linear) |
| `flutter analyze` | 25 issues, the same old ones in `scripts/run_pvs_test.dart` and `test/pvs_pdf_test.dart` |
| `flutter test` (five engines loaded) | 741 pass, 10 skipped, 79 fail |

All 79 app failures are this machine's, not the code's: backslash paths
in tests that build expected paths with `/` (library service and screen,
PDF lifecycle, rename persistence, scan edit, recent strip, tools,
archive screen, markup view), the missing `pdf_ffi.dll` (merge and split,
PDF preview save, scan camera, library thumbnails) and the absent corpus
(`pvs_pdf_test`). Every suite this work touched passes: the editor
screens, `test/accessibility/` (including the new editor set at every
text scale and theme), drafts, backups, engine backups and Firebase
exit reports. A Linux or Mac run of the full suite is still owed.

## Uncommitted work in this checkout

The owner asked for nothing to be committed. The working tree of the app,
`packages/doc_common` and five engine submodules (text, sheet, word,
slide, archive; the PDF engine has only new tests and a release profile)
holds waves 2 and 3. The unfinished Word patch that used to sit in
`docs/wip/` was superseded and deleted. To commit when the owner asks:
inside each engine on `main` first (one plain sentence each, see
`git log`), then the app with the gitlinks.

- **B5 Word, B6 Sheet, B7 Slide, B8 Text and archive:** done (see
  "Changed since the engine guides were written" above and PLAN.md's
  progress log for 2026-10-19).
- **B9:** `doc_testkit` (no dependencies) and mutation tests with fixed
  seeds in five shared crates and every per-format engine
  (`tests/mutate.rs`): the readers never panic or hang on mutated
  files, unedited saves are byte-identical entry for entry, untouched
  parts are copied raw, extraction never writes outside its folder. The
  PDF engine has its own mutator (`pdf_ffi/tests/mutate.rs`), which only
  type-checks here. `scripts/verify_engines.py` runs `fuzz` and `sweep`.
- **B10:** drafts in four editors and a Backups screen (above);
  accessibility labels for the sheet grid ("A1, Rice"), slide stage,
  document end space and list, 48 dp style and size chips, the PDF
  viewer's pages ("Page 3 of 12") and readable active PdfEdit tool
  labels; `test/accessibility/editor_screens_test.dart` covers the
  editors at text scales 1.0 to 2.0 in both themes.
- **Release configuration:** `firebase-crashlytics-ndk` with
  `nativeSymbolUploadEnabled` and `ndk.debugSymbolLevel = "SYMBOL_TABLE"`
  in the release build type; `debug = "line-tables-only"` in every
  engine's release profile (the committed PDF `jniLibs` grow when
  rebuilt); low-memory and excessive-resource exits since the last launch
  reported as non-fatal events (`MainActivity` channel
  `com.yourmateapps.pdfhelper/diagnostics`, `FirebaseService`); a privacy
  policy draft in [privacy-policy-draft.md](privacy-policy-draft.md).
  Firebase Analytics (`firebase_analytics`, `AnalyticsService`) tracks
  document types and user actions offline without personal data.
  The version is bumped to `5.0.0+5`. The Tools tab and header are renamed
  to "PDF Tools".
- **Owner's phone feedback (2026-10-20):** an Enter button in the Word,
  text and slide toolbars and Enter (not Next) on the sheet formula
  bar's keyboard; complex-script shaping for exports and page view
  (`doc_font` `otl.rs` and `shape.rs`, clusters and bidi order in
  `doc_layout`, marks off the baseline and CID-keyed CFF codes in
  `doc_pdf`). Still to check on a phone: Telugu, Hindi and Arabic Word
  documents in page view against Android's Noto fonts.
- **Sheet resizing and formula bar (2026-10-20):** drag heading borders
  (`SheetGrid.onResize`, live preview through `AxisMetrics.withSizes`),
  a step-by-step resize sheet, and an expandable formula bar ("fx").
  `_apply` now reloads the layout after layout-only ops (`_layoutOps`).
  Still to check on a phone: dragging a border with a finger.
- **Dark theme readability (2026-10-20):** document colours shown on the
  app's dark surfaces go through `lib/utils/readable_color.dart`
  (`readableOn`, `textOn`, `darkThemeFill`): the sheet grid's text,
  fills and borders; Word's toolbar accent. The Word page wraps its
  content in `DocLook.onPaper` (a light theme and dark ink). Swatches use
  `AppColors.swatchBorder`. The light theme shows files' colours as they
  are.

## What to do next, in order

The batches are specified in [PHASE10_PLAN.md](PHASE10_PLAN.md): each has
its items, evidence, files and how to verify it. A batch is done when its
hostile inputs are bounded (time, memory, a 512 KiB stack), ordinary files
behave exactly as before, and its checks pass.

**Deferred checks** (could not run on the Windows laptop; run them on
Linux or the Mac before release):

- the corpus: B0's downloads, `test/pvs_pdf_test.dart`, the
  `wordcli`/`sheetcli`/`slidecli` corpus runs, `verify_engines.py sweep`
  and corpus-seeded mutation runs;
- LibreOffice round trips of saved files (`soffice` not installed);
- memory limits through `prlimit` or `VmHWM` (Linux only);
- the PDF engine's tests (about 570, plus the new mutator) and every
  screen test that loads `pdf_ffi`;
- the archive tests that run `python3`, and the 6,000-entry timing test
  off Windows;
- `doc_layout`, `doc_pdf` and the `doc_xml` doctest (antivirus blocks them
  here);
- `check_android_native.py` on an APK (no `python3` here). The five
  per-format engines were built for Android on Windows with `cargo-ndk`
  4.1.2 and NDK 28.2 (`cargo +stable-x86_64-pc-windows-gnu ndk -t
  arm64-v8a -t armeabi-v7a -t x86_64 -o <pkg>/android/src/main/jniLibs
  build -p <kind>_ffi --release`), and the Gradle preflight accepts them;
- the full `flutter test` without the Windows path failures.

**Still to build:** drafts for PDF fill-and-sign (pending items as JSON),
and making the tests' expected paths separator-neutral so the suite runs
on Windows.

**Left for the owner:** choose the `versionCode` and bump to 4.0.0; make a
signed release build on the Mac; rebuild the macOS and iOS PDF binaries;
the device rounds (emulator `pdfhelper_api36_16kb`, API 24, 28 and 29, a
32-bit phone, his father's phone); open saved files in real Office; host
the privacy policy and submit the All-files-access declaration; review
and commit everything; delete the stale branches; create
`koundinyalanka1/doc_common`.

The numbered list below is the order as it stood before this session;
items 1 and 2 are now done in the working tree.

0. **B0 never ran:** `test_corpus/office` is empty, so there are no
   Word, Excel or PowerPoint files in the corpus. Either run
   `GITHUB_TOKEN=... python3 scripts/download_office_corpus.py` first (the
   GitHub API rate-limits shared addresses), or make files with
   `soffice --headless --convert-to docx|doc|rtf|odt|xlsx|xls|ods|pptx|ppt|odp`
   from LibreOffice's own samples for the batches' corpus checks.
1. **Wave 2, one batch per engine** (independent of each other):
   - Done on 2026-10-18 and 19 (PLAN.md's log): B7 items 1, 2 and 6, B6
     items 3, 6, 7 and 13, B8 item 4, and part of B5 items 1, 4, 6 and 11,
     B6 item 9, B7 items 3, 5 and 9 and B8 items 3 and 5.
   - **B5 Word** (done in the working tree; the patch once kept here was
     superseded): clamp the counts still
     unclamped (the PDF column sum), NaN lengths, recursion, Word 97
     import amplification (its pictures are budgeted already), RTF grid
     spans by binary search; lookups by
     id, queries off the UI isolate, table windowing, `save_verified` with
     Word's check, picture decode size, row splitting in PDF export.
   - **B6 Sheet** (the largest, four parts): formula operator chains,
     nested evaluation and range broadcasting; function loops and lookup
     speed; array formulas, a phone cell budget and saving in the readers
     and FFI; then structural edits and the screen.
   - **B7 Slide**: clamp list numbering, cap group and list nesting,
     bound PowerPoint 97 import and undo memory, `save_verified` with the
     deck's check; saving and pictures off the UI isolate.
   - **B8 Text and archive**: lossless text round trip (including
     `doc_encoding`'s nine code pages), JSON formatting caps, calls off
     the UI isolate, Extract all with thousands of same-named entries.
   - Shared by the four editor engines. Done: saves through
     `doc_ffi::save_verified` with each engine's check;
     `<kind>_set_backup_dir`, set by the app at start-up
     (`EngineBackups`); stale temporary files swept from the app's own
     folders (`text_remove_stale_temp_files`). Left: report too-large
     parts and XML as `TOO_LARGE` (parts read through `doc_opc` arrive as
     `OpcError::Zip(ZipError::TooLarge(part))`; word and slide map those,
     sheet does not, and word's own `XmlError`s become `CORRUPT`); show a
     note when `Package::duplicate_parts()` is not empty; a screen to
     restore a backup.
2. **Wave 3:** B9 corpus sweeps and in-tree mutation fuzzers per engine;
   B10 draft autosave and crash recovery, and accessibility in every
   editor.
3. **Before any APK:** `bash scripts/build_libs.sh android`. The
   per-format engines' Android binaries are git-ignored and, on this
   machine, older than wave 1's changes to `doc_common`; the Gradle
   preflight refuses a stale one. The PDF engine's committed Android
   binaries are current (rebuilt 2026-10-18).
4. **Device rounds on the owner's Mac** ("Needs the owner's Mac, an
   emulator or a phone" in [PHASE10_PLAN.md](PHASE10_PLAN.md)): rebuild the
   PDF engine's macOS dylib and iOS XCFramework (last built 2026-10-13,
   before phase 8 and wave 1); open every kind of file on the emulator
   `pdfhelper_api36_16kb`; saving in place; process death; memory;
   TalkBack; saved files in real Office.
5. **Owner decisions** ("Owner decisions" in
   [PHASE10_PLAN.md](PHASE10_PLAN.md), each with a proposed default): the
   version (`pubspec.yaml` is bumped to `5.0.0+5`), the privacy policy and
   the All-files-access declaration, Crashlytics NDK, phone budgets and
   backups, armeabi-v7a, `cargo-fuzz`, the git-ignored binaries,
   `doc_common`'s repository, and whether untouched XML must stay
   byte-identical after an edit (decision 1: its Word default, keeping
   each top-level body element's original bytes, is a medium piece of B5
   saving work). Until the owner answers, agents use the proposed
   defaults for budgets, backups, armeabi-v7a and in-tree fuzzers, and
   leave the version, policy, Crashlytics, `cargo-fuzz` and repository
   questions to the owner.
6. **Release**, then after it: a complex-script shaper in `doc_layout`
   (Hindi, Telugu, Tamil in exports), embedded fonts for PDF form text, the
   office corpus sweep.

## How this session ran the work

Phases 9 and 10 were built mostly by orchestrated agents (the Workflow
tool), which the owner allowed explicitly. A new session needs the owner's
say-so again before running workflows (for example "ultracode" or "use a
workflow" in the request), and before its first commit or push: the
owner's rule is to commit or push only when asked (PHASE10_PLAN decision
11). The owner gave the last session standing permission to commit and
push each batch as it passed; that does not carry over.

- **Pattern.** Builder agents on disjoint files in parallel, then one
  adversarial verifier per batch that rebuilds the hostile inputs itself,
  compares ordinary files before and after, and fixes what it proves. The
  orchestrator (the main session) runs every check itself, commits per
  engine, updates PLAN.md, and pushes. Agents never commit.
- **Prompts.** [wip/workflows/phase10-wave1.js](wip/workflows/phase10-wave1.js)
  (done) and [wip/workflows/phase10-wave2a.js](wip/workflows/phase10-wave2a.js)
  (B5 in two parts, B6 in four, a verifier each; stopped early). Their
  shared `COMMON` preamble carries the rules agents need. Waves 2 and 3
  were since finished without them (the patch they assume is gone), so
  treat them as examples of the prompt style only. Paths in them assume
  the checkout is at `/home/user/pdfhelper`.
- **Limits met.** Usage limits cut agents off mid-edit several times;
  resuming the run (`resumeFromRunId`) replays finished agents, and adding
  a "continue from the diff" note to the cut-off prompts only keeps the
  others cached. Two agents at a time suited 4 CPUs. Check `df -h /`
  before big builds.

## Not checked yet

- Nothing has run on a phone or emulator since phase 2 (no KVM on the
  cloud machine). Every "confirm on device" item in the plan is open.
- No signed release build; the release smoke test with an AdMob test
  device is open.
- Draft autosave and crash recovery (PLAN §4.7) work in the text, Word,
  sheet and slide editors (uncommitted); PDF fill-and-sign has none yet.
- Phase 9's known gaps: pictures are not listed in Files, 7-Zip and RAR
  are recognised but not opened, HEIC and AVIF go through the phone's own
  codec untried.
- Complex scripts (Indic, Arabic) read correctly on screen but are not
  shaped in exports.
