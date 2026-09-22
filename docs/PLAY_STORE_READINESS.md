# Android / Google Play readiness

Audit date: 2026-09-20. Scope: PDF Helper and its `flutter_pdf_core` native
library, excluding AI features and signing configuration. Existing local edits
were retained. No account changes, Play upload or publication were performed.

The application builds and automated checks pass. Publication still depends on
account configuration, policy declarations and the remaining device checks
below; a successful build does not establish Play approval or complete PDF
rendering compatibility.

## Repairs included

| Area | Result |
| --- | --- |
| PDF writes and parsing | Native writes use a sibling temporary file and atomic replacement, including encrypted output, preserving an existing destination when serialization fails. Parser nesting and object-number bounds reject malformed inputs before stack overflow or numeric truncation. Render allocation is bounded for extreme page dimensions. |
| Native packaging | Rebuilt Android libraries for `arm64-v8a`, `armeabi-v7a` and `x86_64`, plus the macOS library used by host tests. Android builds fail early if an expected PDF ABI is missing. The checker inspects packaged ELF LOAD alignment and whether rounded RELRO protection overlaps writable data. |
| PDF operations | Split ranges fail as a complete operation instead of reporting partial output as success. Image conversion fails visibly on unreadable images, cleans temporary output, and applies EXIF orientation. Organize-pages editing starts with the complete page list and preserves edits while thumbnails arrive. |
| Files and rendering | Recent/starred mutations are serialized, filenames are bounded by UTF-8 bytes, collision checks include existing non-file entries, and password-specific raster caches no longer reuse pixels for a different password. Viewer and file workflows received lifecycle, navigation and asynchronous-state fixes. |
| Camera and photos | Camera initialization/disposal handles background/resume races. Gallery import uses the system picker and no longer requires broad library access. Selected images are staged before the edit callback completes. |
| External PDF opens | Forwarded intents preserve both MIME type and URI. Native imports run off the UI thread, consume each delivery, sanitize provider filenames, validate the PDF header, cap copied imports, and clean failed copies. Reads of app-private paths through incoming file URIs are rejected. |
| Startup and notifications | Optional notification/reporting failures do not make PDF operations or startup fail. Notification permission is requested when needed, and stored permission state is rechecked. |
| Advertising | Debug/profile use Google test ad units; Android release retains production units. UMP refreshes consent and allows ad requests only when permitted. Settings exposes required privacy options, and banners react to consent and initialization changes. |
| Android integration | Removed unused photo/video, microphone and legacy write permissions, made camera hardware optional, disabled app backup and cleartext traffic, and removed the unused broad app FileProvider. Rate App opens the actual package listing. Firebase/Crashlytics plugins are connected. |

## Confirmed validation

| Check | Result |
| --- | --- |
| `flutter analyze` | Passed, no issues; session log `/tmp/pdfhelper-analyze.log`. |
| Full Flutter tests with native library | **222 passed**; session log `/tmp/pdfhelper-tests.log`. |
| Rust workspace tests | Passed, including parser, atomic-write and renderer-bound regression tests; session log `/tmp/pdfhelper-rust-tests.log`. |
| Native Android/macOS rebuild | Completed. |
| Android release app bundle | Built successfully; first checked bundle approximately **71.4 MB**. Final artifact rebuild verification is recorded below when complete. |
| Packaged native verification | PDF core present for **3 ABIs**; **14 ELF64 libraries** pass LOAD alignment and RELRO/writable-data-overlap checks. This is a static artifact check; 16 KB device execution remains separate. |
| Android SDK configuration | Current installed Flutter supplies minimum API **24** and target API **36**; compile SDK is **37**. Recheck the target when changing Flutter versions. |
| Physical-device verification | Pending final device test report. |
| Final rebuilt artifact | Pending final build/check report. |

The logs above are local audit evidence, not tracked release artifacts. The
Flutter suite intentionally includes invalid PDF fixtures, so expected parser
errors can appear in its passing output.

Reproduce the automated checks from the repository root on macOS:

```bash
bash scripts/build_pdf_core.sh test
bash scripts/build_pdf_core.sh android
bash scripts/build_pdf_core.sh macos
flutter analyze
PDF_CORE_LIB_PATH="$PWD/packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib" flutter test
flutter build appbundle --release
python3 scripts/check_android_native.py build/app/outputs/bundle/release/app-release.aab
```

When validating an APK, also run Android Build Tools `zipalign -c -P 16 4`
against that APK. ELF checks alone do not establish APK ZIP alignment or prove
runtime behavior. Follow the official [16 KB build and test guidance](https://developer.android.com/guide/practices/page-sizes).

## Account and publication work still required

- **Privacy policy:** verify that
  `https://yourmateapps.github.io/pdfhelper/privacy-policy.html` is publicly
  reachable and suitable for this exact release. It could not be verified in
  this audit. The policy should cover document handling, permissions, AdMob,
  Crashlytics, retention/deletion and a real contact channel.
- **AdMob:** configure the applicable privacy messages for the production app
  and publish them. Test consent and the Settings privacy entry with UMP test
  geography/test-device configuration. App-side UMP integration cannot create
  the account’s messages. See Google’s [Flutter UMP setup](https://developers.google.com/admob/flutter/privacy).
- **All files access:** complete the Play Permissions Declaration and obtain
  review approval for `MANAGE_EXTERNAL_STORAGE`. Explain why full-device PDF
  discovery is core document-management functionality and why picker-only
  access is insufficient for it. The optional runtime grant is preserved;
  without it, app-owned documents and individual imports remain available.
  Eligibility is subject to [Google Play’s all-files-access review](https://support.google.com/googleplay/android-developer/answer/10467955).
- **Data safety and listing:** review actual release SDK behavior and complete
  Data safety, advertising, content-rating and store-listing declarations. Local
  PDF processing does not mean the entire app collects no data when advertising
  and crash-reporting SDKs are enabled. See [Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469).
- **Target SDK:** current target API 36 meets the standard phone/tablet new-app
  and update requirement effective August 31, 2026. Verify the final uploaded
  artifact against the [current target API requirements](https://developer.android.com/google/play/requirements/target-sdk).
- **Firebase:** confirm production ownership/configuration and validate a test
  crash in the intended Firebase project. Debug skips the production client;
  an optional `android/app/src/debug/google-services.json` can supply a registered
  debug client. FirebaseService currently enables runtime reporting only for
  release builds. Local builds suppress `uploadCrashlytics*` tasks; the release
  pipeline must explicitly opt in with Gradle `-PuploadCrashlytics=true` when
  symbol/mapping upload is intended. No upload was performed during this audit.
- **Submodule:** commit/push the repaired native library and required Android
  binaries in its own repository, then commit the new submodule reference here.
  Otherwise a clean checkout may silently recover the old native implementation.

## Remaining device checks

Record device/OS, installed artifact and outcome for each item. Physical-device
results are pending; automated coverage does not substitute for these checks.

- Clean launch and relaunch; open a PDF from another app while cold, foreground
  and background; return to the Files tab with Back.
- Merge, split, reorder/rotate/delete, protect/unprotect and extract text using
  normal, encrypted, malformed and large PDFs. Reopen outputs with an independent
  PDF reader and compare page counts/content.
- Camera capture, denial/permanent denial, rotate/background/resume, gallery
  multi-select, crop and conversion. Check JPEG EXIF orientation and a device
  without camera hardware if included in supported-device testing.
- Allow/deny/revoke all-files access and notification permission. Verify library
  refresh after returning from Settings, imported files, Android/media, nested
  folders and removable storage where available.
- Share/export to another app and confirm it receives only the selected document.
- Consent acceptance/refusal/reopening privacy choices, network failure and
  delayed ad initialization on a configured test device.
- Execute the release build on a genuine **16 KB** Android environment, confirm
  page size with `adb shell getconf PAGE_SIZE`, then open/render and modify PDFs.
  A passing alignment script alone is insufficient.

## Known PDF compatibility limits

The in-house renderer remains incomplete for shading, tiling patterns, inline
images, some blend modes, and JPX/JBIG2 image codecs. Affected documents may
render approximately or omit those elements; retain the viewer’s approximation
warnings and test a representative real-world corpus. Do not advertise universal
rendering fidelity based solely on the passing unit suite.

AI functionality and signing configuration were deliberately not changed or
assessed. iOS release configuration and device validation are separate work.
