# DocHelper: notes for Claude Code sessions

DocHelper (formerly PDF Helper) is a Flutter app, Android first, whose
engines are written from scratch in Rust. The owner is growing it from a PDF
toolkit into an all-in-one office app, like LibreOffice on a phone: a word
processor, spreadsheets, presentations and PDFs in one app. His father will
use it to do office work (PDFs, Word, Excel, PowerPoint, WPS/LibreOffice and
text files) on a phone instead of a laptop.

**Start every session by reading [PLAN.md](PLAN.md).** Its phase table,
progress log and "Next steps" say exactly where work stands. Update it
whenever work lands.

## The owner's standing rules

- **Never change the package identifiers.** That covers
  `com.yourmateapps.pdfhelper`, which is the Android `applicationId`,
  namespace and Kotlin package, plus the iOS bundle ID and the `.debug`
  suffix scheme. It also covers the Dart package name `pdfhelper`. AdMob
  and Google Play are linked to them. Only display names and visible text
  change. Internal file and class names may be renamed freely. Keep
  Android component names such as `.ViewPdfAlias`: renaming one resets
  users' "Always open with" choices.
- **Everything is Rust, written from scratch**: the engines and their FFI
  layers. No C or C++ is written or vendored. `extern "C"` on exported Rust
  functions is only the calling convention `dart:ffi` needs. Do not add document,
  ZIP, XML, spreadsheet, font or Office crates. The allowed dependencies are
  the small primitives already in use:
  - `flate2` (raw deflate);
  - RustCrypto (`aes`, `cbc`, `sha2`, `md-5`) and `getrandom`;
  - `serde`/`serde_json`, only at the FFI boundary;
  - `thiserror`.

  The PDF engine also vendors standalone image codecs (JPEG, JPEG 2000,
  JBIG2). Data such as code-page tables and open-licensed fonts is fine.
- **One library per kind of file.** Each engine is a self-contained Flutter
  FFI plugin with its own Rust workspace and native library:
  `packages/flutter_<kind>_core`, `lib<kind>_ffi`. Code that every engine
  needs lives in the Rust-only `packages/doc_common`.
- **Commit or push only when the owner asks.**
  - Work on `main`, in the app and in every engine repository. No feature
    branches.
  - Commit messages are one plain imperative sentence that says what the
    change does for the user (see `git log`), without a type prefix.
  - The PDF, text, sheet, word, slide and archive engines are git
    submodules. Commit and push inside them first, then commit the updated
    gitlink in the app.
  - Each package gets its own GitHub repository (`koundinyalanka1/<package>`)
    and becomes a submodule of the app once its phase is done. Until then it
    lives in the app's tree. To move one: `git subtree split` its history
    into the new repository's `main`, then `git submodule add` it at the
    same path.
- **Never damage a user's file.**
  - Edit documents in place: copy unchanged ZIP entries raw, and keep XML
    you don't understand.
  - Save atomically (`doc_ffi::write_file_atomically`).
  - Formats that cannot be written back are saved as their modern
    equivalent, and the app says so.
- **AI features are deferred, not abandoned.** `Features.ai` in
  `lib/config/features.dart` is `false`. Keep that code compiling and
  tested; do not delete it.
- When working on the owner's Mac, device checks go on the emulator
  `pdfhelper_api36_16kb` rather than his phones.

## Layout

| Path | What |
| --- | --- |
| `lib/` | The Flutter app (`screens/`, `services/`, `widgets/`, `models/`) |
| `lib/models/doc_kind.dart` | Kinds of file: extensions, icons, colours, which kinds can be opened (`canOpen`), MIME types, content sniffing |
| `lib/services/document_router.dart` | Which screen opens a path; the "open with another app" sheet for kinds without one |
| `lib/services/document_save_service.dart` | Save policy: in place when writable shared storage; otherwise publish/update a public copy in `Download/DocHelper` or `Documents/DocHelper` |
| `lib/services/library_service.dart` | The Files tab's storage sweep (every listed kind), cache and linked copies |
| `lib/screens/text_editor_screen.dart` | The text editor; Markdown and HTML preview as a page (`lib/widgets/markup_view.dart`, built lazily piece by piece), JSON as a tree (`lib/widgets/json_tree_view.dart`) |
| `lib/screens/image_viewer_screen.dart` | Pictures: zoom, turn, details, share, make a PDF |
| `lib/screens/archive_screen.dart`, `make_zip_screen.dart` | Browse an archive (open, share or save a file, Extract all, published in one batch with `PublicPdfSaveService.saveAll`); make a ZIP |
| `lib/screens/sheet_editor_screen.dart`, `lib/widgets/sheet/` | The spreadsheet screen and its custom-painted grid |
| `lib/screens/document_editor_screen.dart`, `lib/widgets/word/` | The document screen: reflowing paragraphs and tables, one paragraph edited at a time (`ParaController`) |
| `packages/flutter_pdf_core` | PDF engine (git submodule; commits its Android/Apple binaries); `pdf_edit` fills forms, annotates and stamps, saving incremental updates; `pdf_compress` makes smaller copies and page pictures |
| `packages/doc_common` | Shared Rust crates: `doc_zip`, `doc_xml`, `doc_encoding`, `doc_opc`, `doc_ffi`; for PDF export `doc_image`, `doc_font`, `doc_pdf`, `doc_layout`; for Office 97-2003 files `doc_cfb` and `doc_art`; `doc_metafile` draws WMF and EMF pictures; `doc_odf` turns flat OpenDocument (`.fodt/.fods/.fodp`) into packages |
| `packages/flutter_text_core` | Text engine (`text_core`, `text_ffi`, Dart `TextCore`); `text_core::markup` reads Markdown and HTML into blocks to draw (`TextCore.markdown`/`html`, Dart `MarkupDocument`), cut short at `MAX_PARTS` |
| `packages/flutter_archive_core` | Archive engine (git submodule, its own repository): `archive_core`, `archive_ffi`, Dart `ArchiveCore`; ZIP, TAR, gzip and `.tar.gz` listed and extracted safely, ZIP files made; `cargo run --example archivecli` tries real files |
| `packages/flutter_sheet_core` | Spreadsheet engine (`sheet_core`, `sheet_ffi`, Dart `SheetCore`; `cargo run --example sheetcli` tries real files) |
| `packages/flutter_word_core` | Word-processing engine (git submodule, a private repository): `word_core`, `word_ffi`, Dart `WordCore`; DOCX and ODT in place, RTF/TXT/MD and Word 97-2003 imported; `cargo run --example wordcli` tries real files |
| `packages/flutter_slide_core` | Presentation engine (git submodule, its own repository): `slide_core`, `slide_ffi`, Dart `SlideCore`; PowerPoint and OpenDocument decks as scenes to draw, edited in place, PowerPoint 97-2003 imported; `cargo run --example slidecli` tries real files |
| `lib/screens/slide_editor_screen.dart`, `lib/widgets/slide/` | The slides screen and its scene painter; `slide_show_screen.dart` presents |
| `lib/screens/pdf_edit_screen.dart`, `lib/widgets/pdf_edit/` | Fill & sign and annotate: pending items over the pages, saved through `PdfCore.applyEdits`; `pdf_stamp_screen.dart` adds page numbers and watermarks; `compress_screen.dart` and `page_images_screen.dart` make smaller copies and pictures of pages |
| `android/app/src/main/kotlin/...` | "Open with" resolution (`MainActivity`), public saves (`PublicPdfExporter`) |
| `scripts/build_engines.sh` | Builds and tests the per-format engines |
| `scripts/build_pdf_core.sh` | Builds and tests the PDF engine |
| `scripts/download_*_corpus.py` | Rebuild the git-ignored `test_corpus/` |

## Setting up (including a fresh Linux cloud machine)

```bash
git submodule update --init --recursive
flutter pub get
# Rust 1.88 or newer (the code uses slice::as_chunks).
bash scripts/build_engines.sh host     # text, sheet, word, slide and archive engines for this machine; on Linux also libpdf_ffi.so
eval "$(bash scripts/build_engines.sh env)"   # exports *_CORE_LIB_PATH for flutter test
flutter analyze
flutter test                           # the app (about 700 tests)
(cd packages/flutter_text_core && flutter test)
(cd packages/flutter_archive_core && flutter test)
bash scripts/build_engines.sh test     # cargo tests: doc_common, text, sheet, word, slide, archive
(cd packages/flutter_pdf_core/rust && cargo test --workspace --release)   # PDF engine, about 510 tests
```

- **Binaries.**
  - The per-format engines' binaries are git-ignored. Build them with
    `bash scripts/build_engines.sh android` (needs `cargo-ndk`, an NDK and
    the Android Rust targets) or `macos`.
  - The Android Gradle preflight (`verifyEngines` in
    `android/app/build.gradle.kts`) refuses a build when an engine binary
    is missing or older than its Rust source.
  - When adding an engine, add it to that list and to `ENGINES` in
    `scripts/check_android_native.py`.
- **Android binaries on a Linux cloud machine.** `rustup target add
  aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`,
  `cargo install cargo-ndk`, and the NDK zip from
  `dl.google.com/android/repository/android-ndk-r27c-linux.zip`; then
  `ANDROID_NDK_HOME=<ndk> bash scripts/build_pdf_core.sh android`. Apple
  binaries need the Mac.
- **An APK on a Linux cloud machine.** Unzip the command-line tools from
  `dl.google.com/android/repository/commandlinetools-linux-<n>_latest.zip`
  into `<sdk>/cmdline-tools/latest`, accept the licences with
  `sdkmanager --licenses`, add `sdk.dir=<sdk>` to `android/local.properties`
  (git-ignored), build every engine for Android, then
  `flutter build apk --debug` and check it with
  `python3 scripts/check_android_native.py <apk>`. Maven Central answers
  429 to the shared address; a Gradle init script in `~/.gradle/init.d`
  that points `repo.maven.apache.org` at
  `maven-central.storage-download.googleapis.com/maven2/` gets round it.
  There is no KVM, so no emulator.
- **Engine tests skip themselves** when their native library cannot be
  loaded (`skip: !TextCore.isAvailable`). A suite that "passes" without
  the env exports has tested less than it seems.
- **`test_corpus/` is git-ignored.**
  - Rebuild it with `scripts/download_test_corpus.py`,
    `download_diverse_corpus.py`, and `download_office_corpus.py` for
    office files.
  - The office script lists directories through the GitHub API, which
    allows 60 requests an hour without a token, so set `GITHUB_TOKEN`.
  - Wikimedia throttles hard; the diverse script honours `Retry-After`.
  - `test/pvs_pdf_test.dart` sweeps every corpus folder as PDFs, except the
    ones it names (including `office`).

## Engine conventions

- **The FFI layer**, shared through `doc_ffi`. It is Rust functions exported with
  `#[no_mangle] extern "C"`; `extern "C"` is only the calling convention
  that `dart:ffi` uses. There is no C or C++ code anywhere.
  - UTF-8 strings. Results are owned by the caller and freed with
    `<kind>_free_string`.
  - Failures return a negative number or NULL, and `<kind>_last_error`
    returns `"CODE: message"`. Codes: `IO`, `INVALID_ARGUMENT`,
    `BAD_HANDLE`, `UNSUPPORTED`, `ENCRYPTED`, `WRONG_PASSWORD`, `CORRUPT`,
    `TOO_LARGE`, `NOT_FOUND`, `PANIC`, `ERROR`.
  - Panics are caught.
  - Documents being edited live in a `Registry` of sessions with handles
    starting at 1.
  - Structured data crosses as JSON. Text offsets given to Dart are UTF-16.
- **Dart bindings** load `lib<kind>_ffi.so` on Android. On macOS they check
  the process first, then the dylib. `<KIND>_CORE_LIB_PATH` overrides the
  location (tests, desktop).
  - Heavy calls run in `Isolate.run`. Handles are plain integers, usable
    from any isolate.
- **Android builds** link with 16 KB pages: copy `build.rs` from
  `text_ffi` into new FFI crates.
- **New Rust crates** set their dependency versions themselves (no
  `workspace = true`), so they work as path dependencies from any
  workspace.

## Pitfalls already met

- **Widget tests and isolates.** Anything awaiting `Isolate.run` (opening
  or saving through an engine) never finishes inside the test's fake clock.
  Alternate `tester.runAsync(() => Future.delayed(...))` with
  `tester.pump(...)`; see `flush` in `test/screens/text_editor_screen_test.dart`.
  `pumpAndSettle` hangs while a loading spinner shows, so pump by duration.
- **`AppColors.of(context)`** uses `context.watch`. Call it only inside
  `build`. In sheets and dialogs, read it in the builder; the opener's
  context throws silently.
- **Flutter 3.47.**
  - A `SnackBar` with an action persists unless given `persist: false`.
  - `Tooltip.ensureTooltipVisible` never hides on its own.
- **Viewer zoom tests** schedule a region render; flush before the test
  ends or later tests stop rendering (`flushZoomRender`).
- **Tooling on the owner's Mac.**
  - zsh does not word-split unquoted variables, so use `xargs`.
  - BSD `sed` has no `\b`.
  - Cargo lives in `~/.cargo/bin`, which is not on `PATH`.
- **The file-writing tool decodes `\uXXXX` escapes** in file content. To
  put a literal backslash-u sequence in source, build it with `concat!` or
  an escaped string.

## Owner decisions still pending

See PLAN.md §6 and `docs/PRODUCTION_AUDIT_2026-10-07.md`.

- **Git-ignored engine binaries.** The per-format binaries are git-ignored
  for now; the alternatives are committing them or Git LFS.
- **`doc_common`'s home.** The engines reference `packages/doc_common` by
  relative path, so they build inside this checkout but not standalone. Per
  the owner's rule it gets its own repository and becomes a submodule once
  its planned crates (fonts, layout, PDF writer, CFB; phases 6 and 7) land.
- **Metric-compatible fonts.** Bundling Carlito, Caladea and Liberation is
  proposed, so Word and Excel documents lay out as Office does.
- **Play Console All-files-access declaration.** DocHelper now edits
  documents in place, which fits Google's "document management" use case
  better than a viewer did.
- **Earlier open items:** versionCode, the release smoke test with an
  AdMob test device, and Crashlytics NDK.
