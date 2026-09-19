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
  Open, Share, Star, Rename, Delete, Ask AI, Merge with…, Split, or Open in
  Tools
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

**Ask** (on-device AI)
- Summarize a document or ask questions about it, with **page citations**
- Retrieval-augmented: the native core chunks the document, BM25 retrieval picks
  the passages that matter, and only those reach the model — which is what
  makes a small on-device model viable
- Ships with a zero-weights extractive fallback so the whole pipeline works
  before any model is installed. See [On-device AI](#on-device-ai).

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
from `/ExtGState`, image XObjects (JPEG, Flate, stencil masks, soft masks),
form XObjects, and TrueType glyph outlines including composite glyphs.

Deliberately skipped rather than failed — pages using these still render, minus
that element: shading and tiling patterns, inline images (`BI…EI`), blend
modes, and CFF/Type1 glyph outlines (`/FontFile3`). A PDF whose text is set in
a non-embedded or CFF font will show its graphics but not its glyphs.

## On-device AI

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

The Files tab walks shared storage on a background isolate, capped at 5000
files, depth 12, and 30 seconds so a huge or slow volume can never hang the
tab. Hidden directories, `cache`/`node_modules`-style directories and
`Android/data` / `Android/obb` are skipped; `Android/media` is deliberately
kept, because that is where messaging apps now store received documents.

What it can see depends on the grant:

| | Android ≤10 | Android 11+ | iOS |
|---|---|---|---|
| Default | app's own directories | app's own directories | app's own documents |
| After the grant | `READ_EXTERNAL_STORAGE` → all shared storage | All files access (`MANAGE_EXTERNAL_STORAGE`) → all shared storage | n/a — sandboxed; use Import |

Access is *probed* (by trying to list the root) rather than inferred from a
permission status, because the two disagree across Android versions. Without
the grant the tab still works, says what it is showing, and offers the grant
inline. On iOS the same banner offers Import instead.

## Platform support

| Platform | Status |
|----------|--------|
| Android  | supported (API 24+); scoped storage; one VIEW intent alias |
| iOS      | supported; required `NS*UsageDescription` keys are in `Info.plist` |
| macOS    | the core builds, the app is not wired up |
| Windows / Linux / web | not supported — the app uses `dart:io` throughout |

## Before publishing

- [ ] `android/key.properties` — without it, release builds fall back to the
      debug key and log a warning
- [ ] `GoogleService-Info.plist` — missing, so Crashlytics is Android-only today
- [ ] AdMob unit IDs — Android uses real IDs, iOS still uses Google's test IDs,
      and the iOS `GADApplicationIdentifier` is Google's sample app ID
- [ ] Rate / Privacy URLs in `lib/screens/settings_screen.dart` — `_rateAppUrl`
      is still `https://example.com/...`
- [ ] `android/app/src/main/res/xml/file_paths.xml` shares the whole external
      storage root; narrow it to the directories actually shared
- [ ] Play Console **Permissions Declaration** for `MANAGE_EXTERNAL_STORAGE`
      (the Files tab). The applicable use case is file/document management.
      Removing the permission is a supported alternative — the tab falls back
      to app-owned files on its own

See `IMPROVEMENTS.md` for the enhancement backlog.
