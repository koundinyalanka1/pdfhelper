# PDF Helper improvements

This replaces the pre-Rust audit. The app now uses the vendored
`packages/flutter_pdf_core` engine for parsing, rendering and PDF operations.

## Current repair pass: six confirmed bugs

1. **Gradient and pattern paints:** render supported axial/radial shadings and
   tiling patterns. Unsupported or malformed paints must produce warnings and
   must never fall back to misleading solid black rectangles.
2. **Missing viewer content:** render supported inline images and annotation
   appearance streams, with fallbacks for common highlights and form values.
   Unsupported or approximate content must be reported through render warnings.
3. **Split/merge preservation:** retain AcroForm fields, widgets, their resources
   and retained-page bookmarks. Merge disambiguates colliding field names;
   extraction removes destinations to discarded pages. XFA operations fail
   explicitly instead of silently losing the form.
4. **Damaged indexes:** conservatively reconstruct complete PDF objects when
   cross-reference parsing fails. Preserve password authentication and warn
   that recovered documents may be incomplete. Missing download bytes cannot
   be reconstructed.
5. **Password wording:** describe the owner password as another unlocking
   password. The current writer allows printing, copying and editing; it does
   not expose permission restrictions.
6. **Android public saves:** publish PDFs to `Download/PDFHelper` or
   `Documents/PDFHelper`. Keep local working copies for the native engine;
   public exports are separate durable documents. Explicit Save also works
   with Auto Save disabled. Report failed exports without discarding the source.

Focused regressions live in the native `pdf_core`, `pdf_ops`, and `pdf_render`
crates, plus the app's public-save, preview-save and library tests. Build and
test the native libraries before running the Flutter suite against them.

### Validation (2026-10-02)

- Rust workspace: 262 unit tests and 1 documentation test passed.
- Flutter: 318 tests passed against the rebuilt native library; analysis clean.
- Android storage: all 4 native instrumentation checks passed on a Motorola
  edge 70 fusion. Both public folders, final filenames/paths, published state,
  byte preservation, collisions and rejected invalid inputs were checked.
- Native libraries rebuilt for Android (three ABIs), universal macOS and iOS
  device/simulator. The debug APK built and was installed on the phone; its
  native code/data/build IDs match the rebuilt Android libraries.
- iOS runtime and Android 9-or-earlier public saving were not device-tested.

The phone checks found and fixed a MediaStore detail: final filenames must be
queried after publishing a pending file, because collision resolution can
rename it at that point. Tests remove only their own fixture PDFs.

## Viewer follow-up (2026-10-04)

- Fixed scrolling while zoomed: vertical drags and flings now travel through
  the entire document, including the first and last page edges. Horizontal
  panning, pinch focal points, double-tap zoom and text selection are preserved.
- Added gesture regressions for reading all six fixture pages and returning
  to the start without resetting zoom, stopping a fling with a new touch, and
  horizontal panning/pinching after scrolling.
- Validation: all 321 Flutter tests pass, analysis is clean, and the Android
  release bundle builds and passes the packaged native alignment checks.
- The production audit of that date (since replaced by the
  [7 October audit](docs/PRODUCTION_AUDIT_2026-10-07.md)) recorded the
  remaining scan, export, PDF-fidelity, iOS and release-readiness issues.

## Renderer expansion (2026-10-05)

A completion tracker (since folded into the
[renderer capabilities](docs/RENDERER_CAPABILITIES_2026-10-06.md)) recorded the
expanded work and its verification. Implemented JPEG 2000/JBIG2 decoding, shading
functions/meshes, blend modes/groups/masks, annotation/widget fallbacks, text
painting/clipping and stroke joins/miter limits. Fixed the reported receipt's
spacing by resolving nested indirect CID width arrays. New codec allocations
and recursive graphics states are bounded; unsupported or approximate output
continues to warn.

## Production audit fixes (2026-10-07)

The [production audit](docs/PRODUCTION_AUDIT_2026-10-07.md) records the
evidence for each of these.

1. **Large PDFs:** the engine pins a parsed document
   (`pdf_document_open`/`close`, `PdfCore.openDocument`/`closeDocument`).
   Read-only calls share it while the file is unchanged, instead of each
   reading and parsing the whole file. The viewer and tool previews pin their
   document; text-layout loads run two at a time, and work for pages scrolled
   past is skipped. A ~185 MB scan no longer gets the app killed on a 2.5 GB
   phone.
2. **False "damaged" warnings:** index entries in use at offset 0, `endobj`
   omitted before a clean boundary, and overflowing object numbers no longer
   send valid files (mostly Apple-written) through recovery.
3. **Passwords:** RC4/AES-128 files take PDFDocEncoding passwords, AES-256 uses
   SASLprep, and raw UTF-8 remains a fallback.
4. **Scans:** the camera captures at 3840×2160 instead of 1280×720; filters
   work at up to 2400 px (3000 px at Maximum), with the Document filter's
   window scaled to match.
5. **HEIC/HEIF/AVIF gallery photos** are converted to JPEG at import, so
   Maximum quality no longer fails to create the PDF.
6. Documentation links point at existing documents again.
7. Protect warns that non-ASCII passwords do not open in Apple Preview.
8. Protect and Remove password ask for an output name, like the other tools.
9. Handled errors reach Crashlytics as non-fatal events with no document
   names or paths, and errors the app survives are no longer counted as crashes.

## Remaining backlog (outside this repair pass)

- Renderer compatibility: XFA, rich-text fallback styling, cloudy borders,
  display-dependent NoZoom and exact advanced colour-space conversion remain
  limited. Generated missing-appearance artwork remains approximate. Displaying
  a signature appearance does not verify it.
- Core API: operation progress/cancellation, per-input merge passwords,
  permission settings, and additional page APIs.
- Viewer: last-read page, bookmarks/links, thumbnails, display modes,
  printing and keep-screen-on.
- Tools: compression, PDF-to-images, watermark/page numbers, interactive form
  filling, annotation editing, redaction, and OCR for scripts beyond Latin
  (Devanagari, CJK, Cyrillic).
- Files/scan: multi-selection, folders, reverse sorting, capture reordering,
  paper sizes/margins and explicit Save As.
- Platform/app: Android share-in, follow-system theme, licenses/feedback,
  localization and additional desktop/web builds.
- Editing signed PDFs currently rewrites them and invalidates existing digital
  signatures. Signature-preserving incremental editing is separate work.
- Ask AI stays disabled through `Features.ai`.

## Native build housekeeping

The engine is a Git submodule. App commits alone do not record edits inside it.
When preparing a release, record the engine changes and required native
artifacts in the submodule, then update the parent repository's submodule
revision. Alternatively, rebuild the artifacts from that revision in CI.
Rebuild the Flutter app after changing native libraries; hot reload cannot
replace them.
