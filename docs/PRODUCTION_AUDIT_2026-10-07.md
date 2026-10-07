# PDF Helper — production audit

**7 October 2026 · Android release scope**

This audit asked whether the app is ready for a production release on a
single bar: it must not crash, and every shipped feature must work as
expected. It covered the app, the `flutter_pdf_core` engine and the release
configuration, and it fixed every defect it found. The
[application baseline](APP_BASELINE_2026-10-06.md) describes the product; the
[renderer capabilities](RENDERER_CAPABILITIES_2026-10-06.md) describe PDF
compatibility limits, which are product boundaries rather than defects.

## 1. Snapshot

| Item | Value |
| --- | --- |
| App version | `3.0.0+3` |
| App source | `main` after merging branch `production-audit-fixes` (the fixes below, on top of `aa99a34`, which merged find in document) |
| Engine source | submodule `main` at `2360999` (the fixes below, on top of `48f210e`), with Android, iOS and macOS libraries rebuilt from it |
| Release platform | Android (minSdk 24, targetSdk 36, compileSdk 37); iOS deferred |
| Test devices | Motorola edge 70 fusion (Android 16, 12 GB); emulator `pdfhelper_api36_16kb` (Android 16, 16 KB pages, 2.5 GB) |

## 2. Defects found and fixed

| Defect | Cause | Fix | Evidence |
| --- | --- | --- | --- |
| Opening a large PDF crashed the app on low-RAM phones | Every engine call read and parsed the whole file (about 2.3× its size in memory), and the viewer made many at once: each page loaded its text layout immediately and without limit, beside three renders and a page-size pass that reopened the file per page | The engine pins a parsed document (`pdf_document_open`/`close`; `PdfCore.openDocument`/`closeDocument`) and read-only calls share it while the file is unchanged. The viewer and tool previews pin their document. Text-layout loads run two at a time, and loads and renders for pages scrolled past are skipped | On the 2.5 GB emulator a ~185 MB scan was OOM-killed within 2 s in 2/2 runs before; after, it survived 2/2 (peak under 900 MB) and a ~290 MB scan also survived |
| Valid PDFs showed "The PDF's damaged index was recovered. Some content may be missing" | The parser treated common writer quirks, mostly from Apple's PDF writer, as damage: index entries marked in use at offset 0, `endobj` omitted after `endstream`, and object numbers too large for 64 bits | Offset-0 entries are read as free; a missing `endobj` is accepted when the next object, the index or the end of the file follows; overflowing numbers saturate, and references to impossible object numbers read as null. Genuinely damaged files still recover with the warning | Of 295 real PDFs, files showing the warning fell from 134 to 0, with no failed operation; Apple PDFKit opened all 1,475 split/rotate/merge/encrypt/decrypt outputs with correct page counts |
| Correct passwords with accented letters were rejected for RC4/AES-128 PDFs | The engine hashed passwords as UTF-8; revisions 2–4 use PDFDocEncoding | Authentication tries the spec encoding first, then UTF-8. AES-256 now applies SASLprep, as required, when writing and reading; files encrypted by the previous engine still open | Fixtures written by pypdf (RC4-128, AES-128, AES-256) open with the typed password in Rust tests and through the app's Dart → FFI path |
| Camera scans were 1280×720, about 85 dpi across A4 | `ResolutionPreset.high` sets the still-capture size as well as the preview | Scans request 3840×2160 (`ultraHigh`); all filters work at up to 2400 px (3000 px at Maximum quality), the size the crop step already keeps, with the Document filter's window scaled to match | The preset initializes and captures on the emulator; filters on large photos run about 2.5× faster than before; a real 4K capture still needs a phone check (section 4) |
| At Maximum quality, HEIC gallery photos ended in "Failed to create PDF" | The picker passes the original file through at quality 100, and the Dart `image` package cannot decode HEIC | Gallery photos in HEIC/HEIF/AVIF are recognized from their header and converted to JPEG with Android's decoder at import | A real HEIC converts on the Motorola phone (`integration_test/photo_import_test.dart`) |

Smaller fixes made in the same pass: documentation links to missing files,
a compatibility notice for non-ASCII passwords (Apple Preview rejects them in
every encryption revision), naming of password-protected output, and crash
reporting of handled errors. See [IMPROVEMENTS.md](../IMPROVEMENTS.md).

## 3. Verification

Final run on 7 October, after all fixes, with every native library rebuilt
from the final engine source:

| Check | Result |
| --- | --- |
| `flutter analyze` | No issues |
| Flutter tests against the rebuilt macOS library | 416 passed (388 before the audit; 28 new) |
| Rust workspace tests | 363 passed (351 before; 12 new) |
| Real-world corpus: 295 distinct PDFs through every engine call the app makes | No crash, hang or failed operation; no false "recovered" warnings; Apple PDFKit opened all 1,475 outputs with correct page counts |
| `flutter test integration_test` on the Motorola phone | 4 passed |
| `flutter test integration_test` on the 16 KB-page emulator | 4 passed |
| Viewer with a ~185 MB / ~290 MB scan on the 2.5 GB emulator, flung through | Both survive: peak RSS 849 MB / 969 MB (debug build, ~400 MB baseline) |
| `flutter build appbundle --release` and `scripts/check_android_native.py` | 75.3 MB bundle; engine present for three ABIs, 16 KB aligned, and exporting the new document-pinning functions |

The audit did not install the release build on a phone: release builds use
production AdMob units, and ads served to a developer's own device can count
as invalid traffic.

## 4. Release checks outstanding

These need an owner's decision or action; the source cannot settle them.

1. **All files access.** Google Play allows `MANAGE_EXTERNAL_STORAGE` for
   document-management apps that find, open *and edit* files outside their
   own storage. PDF Helper finds and opens PDFs and writes new copies, so the
   Console declaration may be refused. The app works without the grant (the
   Files tab then lists app documents and imports); if Play refuses, remove
   the permission from the manifest and ship.
2. **Push the engine first.** The app's `main` points at engine commit
   `2360999`. Push the submodule's `main` before the app's, or clones and CI
   cannot check the engine out.
3. **Version code.** `3` must exceed every version code already uploaded.
4. **Release smoke test.** Install the signed bundle through Play internal
   testing on a phone registered as an AdMob test device, and exercise open,
   scan, merge, split, protect and save. R8 problems appear only in release
   builds.
5. **Camera.** Scan a printed page on a real phone and confirm small text is
   legible; the emulator's virtual camera stops at 1280×720.

## 5. Known limits (not defects)

- A pinned document stays in memory while it is open, about the size of the
  file. Files in the hundreds of megabytes still need that much free memory.
- Apple Preview and PDFKit reject non-ASCII passwords in every encryption
  revision; the Protect screen says so when such a password is typed.
- Rendering compatibility is bounded as described in the renderer document.
