# PDF Helper

A Flutter PDF reader and toolkit with a Rust engine. The current release scope
is **Android**. Read, merge, split, organize, scan, protect and extract text from
PDFs locally. Ads and release crash reporting use network services; Ask AI is
hidden and is not a shipped feature. iOS is deferred.

Start with the [documentation index](docs/README.md):

- [Application baseline](docs/APP_BASELINE_2026-10-06.md): current features, architecture, storage and configuration.
- [Production audit](docs/PRODUCTION_AUDIT_2026-10-06.md): verification, release artifacts and outstanding release checks.
- [Renderer capabilities](docs/RENDERER_CAPABILITIES_2026-10-06.md): supported PDF features and concrete compatibility limits.
- [Improvements](IMPROVEMENTS.md): work beyond the current baseline.

## Features

| Area | Available now |
| --- | --- |
| Files | All/Recent/Starred/Created, filename/folder search, sorting, list/grid, covers, share, rename and linked-copy deletion |
| Viewer | Continuous scrolling, pinch/double-tap zoom, document-wide scrolling while zoomed, sharper rerendering, page jump, find in document, text selection/copy and tool shortcuts |
| Assemble | Ordered merge and output batches; split by range, selection or individual pages |
| Edit | Page rotation/reordering/deletion, metadata, AES-256 protection and password removal |
| Extract | Content-stream text extraction for copying or saving as text |
| Scan | Camera/gallery input, perspective crop/straighten, six filters, undo/redo and multipage image-to-PDF |
| Output | Named PDFs, collision handling, preview, explicit Save and optional Auto Save |
| Settings | Dark/light theme, output quality/location, notifications and applicable ad privacy choices |

Four tabs—Files, Tools, Scan and Settings—provide the main navigation. Tools
reuse a selected working document. Android offers one PDF **Open with** entry;
external launches go directly to the viewer.

Files search matches names and folders, not PDF contents; the viewer's find
searches the open document's text. Last-read restoration, interactive form
editing, OCR and redaction remain future work. Image-only scans have no
selectable or searchable text without an existing text layer. Password protection does not expose printing/copying/editing restrictions.
The app supports different merge-input passwords through temporary decryption.

## PDF engine

[`flutter_pdf_core`](https://github.com/koundinyalanka1/flutter_pdf_core) is a
Git submodule under `packages/`. Its Rust parser, object model, document
operations, text extraction and page renderer are exposed through `dart:ffi`.
Standalone image codecs are dependencies of that engine; there is no second PDF
parser or viewer fallback.

The renderer includes paths/dashes, text painting and clipping, common embedded
font outlines, inline/XObject images, JPEG 2000/JBIG2, shadings and patterns,
blend modes, Form transparency groups, masks, default layer visibility and
annotation/widget appearances with common fallbacks.

Compatibility is bounded. Vertical writing, arbitrary composite-font CMaps,
Type3 glyph programs, advanced colour management/overprint, page transparency
groups and some annotation details remain limited. Warnings report many
unsupported or approximate cases, but warning coverage is incomplete:
**no warning does not establish exact rendering**. Displayed signature artwork
does not verify a signature, and rewriting signed PDFs invalidates signatures.
See the renderer document before making compatibility claims.

## Development setup

Use Flutter with Dart **3.12.1 or later, below 4.0**: the engine dependency sets
this effective minimum. Native builds need Rust 1.92 or later; Android needs its SDK,
NDK, `cargo-ndk` and the Rust Android targets. macOS host tests need a macOS
native library and Apple build tools.

```bash
git clone --recurse-submodules <repository-url>
cd pdfhelper
flutter pub get
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
bash scripts/build_pdf_core.sh android
bash scripts/build_pdf_core.sh macos
flutter run
```

For an existing clone, initialize the engine with
`git submodule update --init --recursive`. The build script locates an installed
NDK or accepts `ANDROID_NDK_HOME`. Run `macos` only on a Mac when its host
library is needed. Explicit targets avoid the script's macOS default also
attempting the deferred iOS build.

Rebuild native libraries after engine changes, then rebuild the Flutter app;
hot reload cannot replace native binaries. Missing native libraries fail the
Android build preflight. Runtime availability checks also give the app a
readable error if its engine cannot load.

## Source layout

| Path | Responsibility |
| --- | --- |
| `lib/screens`, `lib/widgets` | App routes, document workflows, viewer and controls |
| `lib/services/pdf_core_service.dart` | Engine availability and path-based native operations |
| `lib/services/pdf_service.dart`, `pdf_raster.dart` | Operation workflows, raster scheduling and bounded caches |
| `lib/services/pdf_library_service.dart`, `public_pdf_save_service.dart` | Discovery, linked document records and public-copy lifecycle |
| `lib/services/scan_image_store.dart` | Owned scan temporary files and cleanup |
| `lib/providers`, `lib/models` | Preferences, themes and UI/document models |
| `lib/ai`, `lib/config/features.dart` | Hidden AI implementation and feature gate |
| `android/app/src/main/kotlin` | Incoming PDF URI handling, storage access and public exports |
| `packages/flutter_pdf_core/rust/crates` | `pdf_core`, `pdf_ops`, `pdf_text`, `pdf_render`, `pdf_ai`, `pdf_ffi` |

## Storage, privacy and advertising

The Files tab scans readable storage in the background. Broad discovery access
is optional; without it, app documents and individual imports still work.
Android storage protections continue to apply. The first scan after a new grant
shows progress; routine refreshes reuse cached results while discovery runs.

Android Save retains a private working PDF and publishes a durable copy under
`Download/PDFHelper` or `Documents/PDFHelper`. Public copies survive uninstall.
Linked rename/delete operations cover tracked working and public copies, with
partial failures reported. Scan sessions clean files they own and preserve
borrowed originals when an edit is cancelled.

A consent-aware bottom banner appears on the home screen and viewer. Reading
does not trigger interstitials. An available interstitial may appear after every
fourth successful document-producing operation in a session. Debug/profile use
test ad units; Android release uses configured production units. UMP gates ad
requests, and Settings exposes privacy choices when required.

Firebase Crashlytics initializes only in release mode. Firebase Analytics is
not a dependency. The app disables backup/cleartext traffic and does not require
broad photo/video or microphone permissions. See the
[privacy policy](https://yourmateapps.github.io/pdfhelper/privacy-policy.html)
and current audit for configuration and release-account checks.

## Validation and release

Run host checks against rebuilt native libraries:

```bash
bash scripts/build_pdf_core.sh test
flutter analyze
PDF_CORE_LIB_PATH="$PWD/packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib" flutter test
flutter test integration_test/pdf_workflows_test.dart -d <android-device-id>
flutter build appbundle --release
python3 scripts/check_android_native.py build/app/outputs/bundle/release/app-release.aab
```

Release builds require `android/key.properties`, or an external signing file
selected through `ORG_GRADLE_PROJECT_signingPropertiesFile`. Missing signing
credentials fail the release build; there is no debug-key fallback. Debug uses
the separate `com.yourmateapps.pdfhelper.debug` application ID. Keep signing
credentials outside version control.

Local builds skip Crashlytics mapping uploads. The intended production pipeline
opts in with `ORG_GRADLE_PROJECT_uploadCrashlytics=true`. For an APK, also run
Android Build Tools `zipalign -c -P 16 4 <apk-path>`. Static native alignment
checks do not replace runtime testing on a genuine 16 KiB-page Android system.

Record engine changes in the submodule and its matching revision in this
repository, including corresponding native artifacts or reproducible builds.
The production audit records the current snapshot, evidence and remaining
phone/account/store work. Passing automated checks alone does not imply Play
approval or a published release.
