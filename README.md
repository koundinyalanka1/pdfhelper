# PDF Helper

An end-to-end Flutter PDF app for Android & iOS. Browse every PDF on the
device, then read, merge, split, organize, scan, protect, extract text and ask
questions of a document — fully offline.

**One PDF engine, no third-party PDF library.** Everything goes through
[`flutter_pdf_core`](https://github.com/koundinyalanka1/flutter_pdf_core), a
from-scratch PDF implementation in Rust, vendored here as a git submodule and
reached over `dart:ffi`. Parsing, rewriting, rendering, composition and text
extraction all come from the same object model, so what the viewer draws is
exactly the document that was written.

## Quick start

```bash
git clone --recurse-submodules <this repo>
cd pdfhelper

./scripts/build_pdf_core.sh          # build the native core (once, per platform)
flutter pub get
flutter run
```

Already cloned without submodules? `git submodule update --init --recursive`.

The native build needs [Rust](https://rustup.rs). Android additionally needs
`cargo install cargo-ndk` plus an NDK; the script finds one under
`$ANDROID_HOME/ndk` automatically. Without this step the app still launches,
but every PDF screen reports that the core is missing — see
`PdfCoreService.isAvailable`.

## Getting around

Four tabs, one per *place* in the app:

| Tab | What lives there |
| --- | --- |
| **Files** | Every PDF on the device — search, sort, star, and per-file actions |
| **Tools** | The whole catalogue of operations, grouped by intent |
| **Scan** | Camera and gallery capture |
| **Settings** | Appearance, output, permissions, about |

Anything you *do* to a document is a route pushed over the tabs, not a tab of
its own — merge and split included. That is what keeps the bar at four
readable destinations while leaving every operation one or two taps away, and
it is why back from a tool returns you to where you launched it.

The Tools tab holds an optional **working document**: pick a PDF once and every
single-document tool uses it, so a run of tools on the same file costs one pick
rather than one per tool. Tools that need a document and do not have one simply
ask for one when tapped.

## Features

**Files** — the landing tab
- Every PDF on the phone on one screen, the way a document reader works: a
  background sweep of shared storage, not a file picker you have to drive
- **All / Recent / Starred / Created**, search, sort by date, name or size,
  and a grid or list view that is remembered
- Covers are rendered by the native core and cached; long-press any file for
  Open, Share, Star, Rename, Delete, Merge with…, Split, or Open in Tools
- Results are cached to disk, so reopening the tab is instant while a fresh
  sweep runs behind it

**Assemble**
- **Merge** — combine PDFs, with batches for producing several outputs in one run
- **Split** — by page range, several ranges at once, page thumbnails, or every page
- **Scan to PDF** — camera or gallery → crop → 6 filters → multi-page PDF.
  JPEGs are embedded as `DCTDecode` streams without being decoded, so at
  Maximum quality the camera's own bytes land in the PDF untouched.
- **Crop & straighten** — four corner handles plus a handle per edge, so the
  crop follows a page that is not square to the camera, and a homography
  flattens it back to a rectangle. The page edges are found automatically on
  open (gradient-steered Hough transform, pure Dart, no OpenCV); a rectangle
  mode with paper-size ratios is one tap away for photos that are already flat.
- Every tool **names its output** before it runs — the title reaches the file
  itself, not just the auto-saved copy, and collisions are numbered rather
  than overwritten.

**Edit** (the Tools tab)
- **Organize pages** — rotate, reorder and delete in one staged pass
- **Document details** — read and rewrite `/Info` metadata
- **Protect** — AES-256 (PDF 2.0) passwords; opens and removes RC4 / AES-128 / AES-256
- **Extract text** — real content-stream extraction (encodings, ToUnicode CMaps, CID fonts), copy or save as `.txt`

**Ask** (on-device AI) — *built, not yet shipped; planned for a future update*
- Summarize a document or ask questions about it, with **page citations**
- Retrieval-augmented: the native core chunks the document, BM25 retrieval picks
  the passages that matter, and only those reach the model — which is what
  makes a small on-device model viable
- Ships with a zero-weights extractive fallback so the whole pipeline works
  before any model is installed. See [On-device AI](#on-device-ai).
- The entry points are hidden behind `Features.ai` (`lib/config/features.dart`)
  until the model line-up and first-run experience are settled.

**Also**
- Continuous-scroll viewer with pinch-zoom that re-renders sharper as you zoom
- Android "Open with" integration: **one** entry, because opening a PDF from
  another app means one thing — read it. Every tool is then a tap away in the
  viewer's own menu, chosen once the document is actually on screen
- Auto-save, output quality, dark/light theme, completion notifications
- Just-in-time permission requests with rationale dialogs

## Architecture

```
lib/
  ai/            # LocalAiModel interface, model store, BM25 index, orchestration
  models/        # SelectedPdfFile, LibraryQuery (Files tab filter/sort rules),
                 # HomeTabs + DocHandoff (the navigation model)
  providers/     # ThemeProvider + AppColors
  screens/       # splash, home, library, merge, convert, split, tools, organize,
                 # metadata, protect, extract-text, ai, ai-models, scan-edit,
                 # preview, viewer, settings
  services/      # PdfCoreService (FFI wrapper), PdfService (operations),
                 # PdfRaster (page pixels + cache), PdfLibraryService (device
                 # sweep), RecentFilesService, notifications, intents, ads
  utils/         # format_utils, error_logger
  widgets/       # LazyIndexedStack, PdfIntentListener, result dialog, settings

packages/
  flutter_pdf_core/   # git submodule — the Rust PDF core
```

Three services sit between the app and the native core:

| Service | Owns |
|---|---|
| `PdfCoreService` | the FFI surface, availability probing, error message mapping |
| `PdfService` | document operations — merge, split, extract, image→PDF |
| `PdfRaster` | page pixels, with one bounded LRU cache shared by every screen |
| `PdfLibraryService` | finding every readable PDF on the device, and caching the result |

Screens never call `PdfCore` directly, so the engine stays swappable.

### The Rust core

Crates inside the submodule (`packages/flutter_pdf_core/rust/crates`):

| Crate | Purpose |
|---|---|
| `pdf_core` | lexer, parser, object model, xref (+ streams), filters, writer, crypto |
| `pdf_ops` | page tree, split/delete/reorder, merge, rotate/crop, metadata, **image→PDF composition** |
| `pdf_text` | content streams, fonts, text extraction |
| `pdf_render` | **page rasterizer** — scanline AA fills, clipping, images, TrueType text |
| `pdf_ai` | chunking + JSON/NDJSON export for local models |
| `pdf_ffi` | the C ABI consumed by `dart:ffi` |

Run the native test suite with `./scripts/build_pdf_core.sh test`.

**Renderer coverage.** The graphics state stack, path construction and painting
(fill/stroke, non-zero and even-odd), arbitrary clipping paths,
DeviceGray/RGB/CMYK plus ICCBased/Indexed/Separation colour, constant alpha
from `/ExtGState`, image XObjects (JPEG, CCITT G3/G4, Flate, LZW, stencil
masks, soft masks), form XObjects, and glyph outlines from both TrueType
(including composite glyphs) and CFF/Type1C.

Text whose font the document never embedded — the standard 14, or a program in
a format the renderer cannot parse — is drawn in a substitute face (Roboto,
bundled) rather than skipped, because a page of invisible text is
indistinguishable from a broken file. Advances still come from the document's
own `/Widths` wherever it supplies them.

Deliberately skipped rather than failed — pages using these still render, minus
that element: shading and tiling patterns, inline images (`BI…EI`), blend
modes, and the JPXDecode / JBIG2Decode image codecs. A render that had to leave
something out reports it, so the viewer can say the page is approximate instead
of presenting it as exact.

## On-device AI

> **Not shipped yet.** `Features.ai` in `lib/config/features.dart` is `false`,
> so the "Ask AI" entries and the model manager are hidden from the UI. The
> layer below them is complete and still builds and tests — what is unsettled
> is which models to offer, how large a download to ask for, and how first run
> should read. Setting the flag to `true` is the whole of what it takes to put
> it back in front of users.

The AI layer is built so that adding a model is one class and one line, not a
rewrite. Everything routes through `LocalAiModel` (`lib/ai/ai_model.dart`):

```dart
abstract class LocalAiModel {
  AiModelDescriptor get descriptor;
  bool get isLoaded;
  Future<void> load();
  Stream<String> generate(String prompt, {int maxTokens, double temperature, Future<void>? cancelled});
  Future<List<double>?> embed(String text);   // null => retrieval stays on BM25
  Future<void> dispose();
}
```

To embed a real model:

1. Implement `LocalAiModel` over your runtime (llama.cpp via FFI, MediaPipe LLM
   Inference, or ONNX Runtime — `AiRuntime` already names all three).
2. Register it at startup:
   ```dart
   AiRuntimeRegistry.register(AiRuntime.gguf, (d) => GgufModel(d));
   ```
3. Import the weights in-app: **Tools → Ask AI → model chip → Import a model file**.
   Accepted extensions come from `AiRuntime.extensions` (`.gguf`, `.task`, `.onnx`).

Nothing else changes. `AiService` already handles chunking, retrieval, prompt
assembly against the model's declared `contextTokens`, streaming, cancellation
and citations. Returning vectors from `embed()` automatically upgrades
retrieval from BM25 to a blended dense/lexical search.

Until a model is registered, `ExtractiveModel` answers by selecting sentences
from the document itself. It cannot hallucinate — and it cannot paraphrase. The
AI screen says which of the two is running.

Weights live in app-private storage (`<app support>/ai_models/`) and are never
uploaded.

## Build

```bash
./scripts/build_pdf_core.sh            # all platforms this host can build
./scripts/build_pdf_core.sh android    # or one at a time
./scripts/build_pdf_core.sh test       # cargo test --workspace

flutter run                            # debug
flutter build apk --release            # Android
flutter build ipa                      # iOS (requires signing)
```

Rebuild the native core whenever the submodule moves; `flutter clean` first so
the new binaries are picked up.

## Finding files on the device

The Files tab walks all accessible shared-storage volumes on a background
isolate. It uses Android's volume paths for the current user, including mounted
SD/USB drives, and scans to completion without a file-count, depth, or time
cutoff. Hidden files/folders and folders named `cache` or `node_modules` are
included if they contain PDFs. Root aliases are deduplicated and nested symbolic
links are not followed, preventing loops. An unreadable branch does not stop
other folders or volumes from being scanned.

Android 11+ still protects other apps' private directories (`Android/data` and
`Android/obb`); the scan skips branches the OS denies access to. Readable folders
on older Android versions remain included. PDF Helper's own document directories
are scanned separately. `Android/media`, including messaging-app folders, is
included. Cloud-only files need to be downloaded or imported first.

What it can see depends on the grant:

| | Android ≤10 | Android 11+ | iOS |
|---|---|---|---|
| Default | app's own directories | app's own directories | app's own documents |
| After the grant | `READ_EXTERNAL_STORAGE` → all shared storage | All files access (`MANAGE_EXTERNAL_STORAGE`) → all shared storage | n/a — sandboxed; use Import |

Access is checked with `Environment.isExternalStorageManager()` on Android 11+
and the storage permission/legacy-storage state on older versions. Listing a
root is not proof of full access: scoped storage can return a filtered view.
Android 10 uses `requestLegacyExternalStorage`; Android 11+ uses the All files
access Settings screen. The Files tab rechecks on every app resume and queues
another scan if a refresh arrives during a sweep. Without the grant, the tab
shows app documents and offers **Allow access**. On iOS it offers Import.

Regression checks: `flutter test test/services/android_storage_service_test.dart
test/services/pdf_library_service_test.dart test/screens/library_screen_test.dart`.
On a phone, test granting/revoking access and returning immediately, then verify
PDFs in Download, Documents, Android/media, hidden folders, deeply nested folders,
and a mounted SD/USB drive. The list must refresh without restarting the app.

## Platform support

| Platform | Status |
|----------|--------|
| Android  | supported (API 24+); scoped storage; one VIEW intent alias |
| iOS      | supported; required `NS*UsageDescription` keys are in `Info.plist` |
| macOS    | the core builds, the app is not wired up |
| Windows / Linux / web | not supported — the app uses `dart:io` throughout |

## Before publishing

The Android app and native library have been audited and repaired. See
[Play Store readiness](docs/PLAY_STORE_READINESS.md) for changes, validation,
remaining compatibility limits, and the device test checklist. AI features and
signing configuration were excluded from this audit.

- [x] Android debug/profile builds use test ad units; release uses the configured
      production units. UMP consent gates ad requests and Settings exposes ad
      privacy choices when required.
- [x] Rate App points to the application’s Play listing. Firebase/Crashlytics
      Gradle integration is connected for production; debug skips production
      Firebase. Crashlytics upload tasks require `-PuploadCrashlytics=true`.
- [x] Removed unused broad photo/video, microphone, and legacy write permissions.
      Gallery import uses the system picker. PDF sharing uses the sharing plugin;
      the unused app FileProvider with broad storage exposure was removed.
- [x] Flutter analysis and 222 Flutter tests passed; the Rust workspace passed.
      Android/macOS native libraries were rebuilt. A release app bundle built,
      and native artifact checks verified all three PDF ABIs and all 14 packaged
      ELF64 libraries for 16 KB LOAD alignment and RELRO/writable-data overlap.
- [ ] Verify the public privacy policy URL loads and accurately describes local
      document handling, AdMob and Crashlytics. Its availability was not verified
      during this audit.
- [ ] Configure and publish the required privacy messages in AdMob, then test
      consent acceptance, refusal and changes on a registered test device.
- [ ] Complete Play Console **Permissions Declaration** and obtain approval for
      `MANAGE_EXTERNAL_STORAGE`, with a document-management justification for
      full-device discovery. Access remains optional in the app; approval is a
      separate Play review requirement.
- [ ] Complete Data safety, ads/content-rating declarations and store listing.
      Confirm the production ad units and Firebase project belong to the release.
- [ ] Complete physical-device and 16 KB runtime checks in the readiness document,
      including camera, gallery, external intents, share and permission changes.
- [ ] Commit the native library changes in `packages/flutter_pdf_core` separately,
      then update this repository’s submodule reference so clean builds include
      the repaired engine.

For an iOS release, separately supply production AdMob identifiers and Firebase
configuration (`GoogleService-Info.plist`) and validate that platform; this audit
focused on Android/Google Play.

See `IMPROVEMENTS.md` for the enhancement backlog.
