# PDF Helper — application baseline

**Snapshot: 6 October 2026 · Android release scope**

This document describes the application that exists in the current source tree.
It is the starting point for future development, rather than a list of defects
from earlier implementations. Validation results, artifact identities and
publication gates belong in the [current production audit](PRODUCTION_AUDIT_2026-10-06.md).
Detailed PDF support and its limits belong in [renderer capabilities](RENDERER_CAPABILITIES_2026-10-06.md).

## 1. Snapshot identity and scope

| Item | Current baseline |
| --- | --- |
| Product | PDF Helper |
| Flutter package | `pdfhelper` |
| App version | `3.0.0+3` |
| App commit | `319dad1bdf7cc2483ea070455646fa0509b0a49c` |
| Engine base commit | `3641ee50c8c3f2a17df024c9f90b4d09c187ff1d` |
| Working-tree qualification | Final renderer fixes and associated rebuilt native libraries supplement the engine commit; the audit records their verification. These two commit hashes alone do not reproduce that final working tree. |
| Android release application ID | `com.yourmateapps.pdfhelper` |
| Android debug application ID | `com.yourmateapps.pdfhelper.debug` |
| Dart SDK constraint | `>=3.10.4 <4.0.0` |
| PDF implementation | Rust core in the `packages/flutter_pdf_core` Git submodule, exposed through Dart FFI |
| Current release platform | Android |
| iOS | Deferred by the user; not part of Android sign-off |
| Other platforms | macOS native library supports host verification; the desktop app is not configured as a supported product. Windows, Linux and web are not shipped. |

Source: [pubspec.yaml](../pubspec.yaml), [Android build configuration](../android/app/build.gradle.kts),
[native build script](../scripts/build_pdf_core.sh).

PDF reading, rendering, modification, text extraction and image composition run
locally. Advertising and release crash reporting can communicate with their
services. The app therefore should not be described as having no network use.
Ask AI is hidden from the released interface.

## 2. Navigation and startup

The home screen has four tabs: **Files**, **Tools**, **Scan** and **Settings**.
Tabs retain their state, while document operations open as routes above them.
The Tools tab can hold a working document so several tools can reuse one
selection. Returning from document operations refreshes the file library.

Normal launches enter the splash/home flow. Android external PDF launches
resolve the document during startup and choose the viewer as the initial route,
skipping the splash. Back from a viewer opened as the root returns to the home
screen. An external document already delivered to a running app is consumed by
the intent listener and opens in the viewer.

Startup initializes notifications, probes the native PDF library and attempts
release-only Firebase initialization. Missing reporting configuration does not
prevent startup. A missing native engine is reported through its availability
state; there is no alternate rendering engine.

Source: [main.dart](../lib/main.dart), [home_screen.dart](../lib/screens/home_screen.dart),
[pdf_intent_listener.dart](../lib/widgets/pdf_intent_listener.dart),
[pdf_core_service.dart](../lib/services/pdf_core_service.dart).

## 3. Current product capabilities

### Files and document discovery

| Capability | Current behavior |
| --- | --- |
| Library views | All PDFs, Recent, Starred and Created |
| Search | Case-insensitive matching against filename and folder name; this does not search PDF text |
| Sorting | Date modified, name or size; Recent retains its own most-recently-opened order |
| Layout | List or grid, with persisted preference and native-rendered covers |
| File actions | Open, Share, Star/Unstar, Rename, Delete, Merge with…, Split and Open in Tools |
| History | Up to 40 recent entries; stars and recents follow linked document renames and visible aliases |
| Discovery | Background traversal of accessible shared-storage volumes and app document directories |
| Refresh | Cached results appear while a new sweep runs; refreshes arriving during a sweep are queued |
| First granted scan | A progress dialog shows the first full discovery after access is granted; it can continue in the background |
| Routine scan | Resume/tab refresh uses a progress indication without reopening the first-scan dialog |

Discovery walks readable directories without treating a file-count, depth or
time cutoff as a complete result. It deduplicates root aliases and avoids
following nested symbolic links. OS-denied branches do not make other readable
branches inaccessible. Full-device discovery remains limited by Android's
storage protections, mounted volumes and the user's access grant.

Without broad storage access, the app still supports its own documents and
individual imports. Temporary picker/intent copies are excluded from All PDFs
and Created, but can appear in Recent or Starred. Cloud-only documents need to
be imported or downloaded before the local engine can use them.

Source: [library_screen.dart](../lib/screens/library_screen.dart),
[library_query.dart](../lib/models/library_query.dart),
[pdf_library_service.dart](../lib/services/pdf_library_service.dart),
[recent_files_service.dart](../lib/services/recent_files_service.dart),
[pdf_scan_dialog.dart](../lib/widgets/pdf_scan_dialog.dart).

### Viewer

The viewer displays a continuous vertical document, using each page's aspect
ratio. It supports pinch zoom, double-tap zoom, horizontal panning, vertical
drags and flings through the document while zoomed. It offers Fit to width, a
page counter and page-number jump. Jumping to a page resets the zoom.

Visible pages can rerender at a higher resolution as zoom increases. The UI
allows up to 6× zoom; higher-resolution requests scale to at most 4× the base
render size. Page rendering is lazy, rather than rasterizing the complete
document at once.

Long-press selects a word from the PDF text layer; selection handles, Copy and
page-level Select all are available. Image-only scans have no selectable text
unless the document already contains a text layer. OCR is not implemented.

The viewer can share the document, open it in another app or launch merge,
split, organize, text extraction, password protection and metadata tools.
Rendering warnings are carried with raster results and the first reported
warning is shown in a dismissible strip above the pages. This is an
approximation notice, not a complete per-page diagnostics report.

A consent-aware banner occupies the bottom of the viewer, outside the page
viewport. Opening, reading, zooming, sharing and saving a preview do not trigger
interstitial advertising.

In-document text search, last-read restoration, outline/bookmark navigation,
clickable PDF links, a viewer thumbnail strip, alternate reading modes,
printing and keep-screen-on are not current viewer capabilities.

Source: [pdf_viewer_screen.dart](../lib/screens/pdf_viewer_screen.dart),
[pdf_text_selection_service.dart](../lib/services/pdf_text_selection_service.dart),
[pdf_text_selection_overlay.dart](../lib/widgets/pdf_text_selection_overlay.dart),
[pdf_raster.dart](../lib/services/pdf_raster.dart).

### PDF tools

| Tool | Current behavior and boundaries |
| --- | --- |
| Merge | Ordered PDFs and multiple output batches; different input passwords are supported by the app |
| Split | Page ranges, multiple ranges, page selection and one output per page; a failed range set is not reported as a complete success |
| Organize | Stage page rotation, reordering and deletion before producing an output |
| Document details | Read and rewrite title, author, subject and keywords |
| Protect | Write AES-256 protection; optional owner password is an additional unlocking password |
| Remove password | Open with the supplied password and write an unencrypted copy |
| Extract text | Extract content-stream text for copying or saving as a text file |
| Output naming | User-provided PDF names are sanitized; output collisions are numbered instead of overwritten |
| Preview/save | Preview or configured immediate save; explicit Save works when Auto Save is disabled |

Per-input merge passwords are an existing user capability. Internally,
protected inputs are decrypted to temporary scratch PDFs, then merged; those
scratch files are removed after the operation. A direct native per-input
password merge API would simplify this implementation but is not required for
the current user flow.

The password tool does not expose permission restrictions: printing, copying
and editing remain allowed. Rewriting a digitally signed document invalidates
its existing signature; the app does not offer signature-preserving incremental
editing or signature verification.

Source: [tools_screen.dart](../lib/screens/tools_screen.dart),
[pdf_service.dart](../lib/services/pdf_service.dart),
[pdf_core_service.dart](../lib/services/pdf_core_service.dart),
[protect_screen.dart](../lib/screens/protect_screen.dart).

### Scan and image-to-PDF

The Scan tab supports camera capture and gallery import, multiple pages,
per-image editing and deletion, perspective crop/straightening and conversion
to a named PDF. Edge detection and perspective correction run in Dart. The
editor supports Original, Auto, Document, Magic, B&W and Grayscale filters,
along with undo/redo for edits.

The camera is owned only while the Scan tab is active, its route is visible and
the app is in the foreground. Controller disposal coordinates with in-flight
capture. Torch state is handled without turning it off before taking the
requested photograph. Camera hardware is optional for installation, and gallery
import remains available without it.

JPEG output quality options map to 50, 70, 85 and 100. Image conversion preserves
suitable original JPEG data when transcoding is unnecessary and handles EXIF
orientation where conversion is needed. Failed conversion retains the user's
draft and removes incomplete operation output.

Capture reordering and configurable PDF paper sizes/margins remain future
work. Existing crop aspect-ratio controls should not be confused with PDF output
page-layout controls.

Source: [convert_screen.dart](../lib/screens/convert_screen.dart),
[scan_edit_screen.dart](../lib/screens/scan_edit_screen.dart),
[quad_crop_view.dart](../lib/widgets/quad_crop_view.dart),
[document_detector.dart](../lib/utils/document_detector.dart),
[scan_image_store.dart](../lib/services/scan_image_store.dart).

### Settings and hidden features

Settings includes dark/light appearance, Auto Save, completion notifications,
skip-preview behavior, image output quality, Downloads/Documents save location,
app version, the Play listing and the privacy policy. Ad privacy choices appear
when required by the consent SDK. Theme selection is explicit dark/light; it
does not currently follow the system automatically.

The local AI services, extractive fallback, retrieval/indexing and model screens
remain in the source tree. `Features.ai` is `false`, so Ask AI and model-manager
entry points are hidden. This baseline does not describe model inference as a
shipped feature or claim that enabling a flag completes a model-release review.

Source: [settings_screen.dart](../lib/screens/settings_screen.dart),
[theme_provider.dart](../lib/providers/theme_provider.dart),
[features.dart](../lib/config/features.dart), [AI source](../lib/ai).

## 4. Architecture and ownership

| Layer | Responsibility |
| --- | --- |
| Screens/widgets | Navigation, document selection, rendering presentation, gestures and user feedback |
| `ThemeProvider` | Persisted display/output preferences, permission-aware notification preference, save orchestration |
| `PdfCoreService` | Native availability, path-based engine calls, output paths and user-facing error mapping |
| `PdfService` | Merge/split/image conversion workflows and operation cleanup |
| `PdfRaster` | PNG rendering, warnings, bounded raster caches and concurrent-render scheduling |
| `PdfLibraryService` | Storage discovery, cached file inventory and reconciliation of linked copies |
| `PublicPdfSaveService` | Serialized public exports, stable document records, linked rename/delete and partial outcomes |
| `RecentFilesService` | Serialized recent/starred mutations and document alias updates |
| `ScanImageStore` | Ownership and cleanup of image files created for a scan/editor session |
| Android native code | Storage access, MediaStore publishing/mutations and incoming PDF URI resolution |
| `flutter_pdf_core` | Parser, document model, PDF operations, text extraction, renderer and C ABI |

The native engine is reached through `dart:ffi`; asynchronous Dart wrappers use
background isolates for document work. The Android native bridge performs
document-provider file copying and exporter operations off the UI thread.
Independent native image codec dependencies are part of the engine; this is not
a second PDF parser or viewer.

Raster caches have separate bounds: page renders use up to **40 entries / 24 MiB**
of encoded PNG data, while library covers use up to **70 entries / 16 MiB**.
At most **three rendering calls** run concurrently. These are cache/scheduling
bounds, not a claim that all process memory is limited to those amounts. Flutter
decoded images, active render buffers and the native document model consume
additional memory.

## 5. Files, storage and lifecycle

### Private working files and public exports

Native operations produce local working files that remain readable by the app.
On Android, Save also publishes a separate durable public copy in
`Download/PDFHelper` or `Documents/PDFHelper`. The public copy survives app
uninstallation; the private working file does not have that durability.

Each tracked document can have one working path and multiple saved public
copies. Its stable record links those copies even when names change. Under
scoped storage the provider URI identifies the public copy; an inaccessible
filesystem alias is not treated as proof that the document was deleted.

Save, rename and delete mutations are serialized. The service validates its
catalogue before publishing or deleting files. Failed save bookkeeping attempts
to remove only the public row just created. Rename updates linked copies and
attempts to restore the working-file name if its final catalogue write fails.
Partial outcomes report which files changed and preserve usable surviving
copies and their links. Delete confirmation names both working and linked public
copies, so deletion is not presented as removing only a list entry.

The implementation supports output names and explicit Save. It does not yet
provide a general Android document-provider destination chooser for Save As.

Source: [public_pdf_save_service.dart](../lib/services/public_pdf_save_service.dart),
[PublicPdfExporter.kt](../android/app/src/main/kotlin/com/yourmateapps/pdfhelper/PublicPdfExporter.kt),
[theme_provider.dart](../lib/providers/theme_provider.dart).

### Temporary image and PDF ownership

Scan/editor sessions track only files they create or explicitly adopt.
Imported originals are borrowed and must survive Cancel, Back and editor
disposal. Successful edits transfer ownership where appropriate. Disposal
removes owned temporary images after any operation actively reading them
finishes; a late completion after disposal does not retain a new session file.

External content URIs are copied to the app's `opened_pdfs` cache. Display names
are sanitized, the input is checked for a PDF header and copied imports are
limited to **512 MiB**. Failed copies are deleted. This import limit applies to
that content-URI copying path, not to every possible native PDF open. Cached
imports should not be advertised as permanent archival copies.

Temporary-file handling is normal lifecycle cleanup; it is not a secure-erasure
feature. No claim is made that a process crash immediately removes every
temporary file.

Source: [scan_image_store.dart](../lib/services/scan_image_store.dart),
[MainActivity.kt](../android/app/src/main/kotlin/com/yourmateapps/pdfhelper/MainActivity.kt).

### Android access and intents

Full-device discovery uses the access supported by the Android version:
legacy shared-storage access on older releases and All files access on Android
11+. The grant remains optional. Public saving on Android 10+ uses MediaStore;
legacy public saving requests storage permission where needed. The manifest
limits legacy write permission to API 28 and below.

The manifest exposes one **Open with** alias for PDFs via `ACTION_VIEW`. The
trampoline preserves the URI grant and forwards the document to MainActivity.
Incoming `file:` paths are canonicalized, checked for readability/PDF content
and rejected if they point inside private app data. Incoming `content:` URIs
are copied for the path-based engine. Android `ACTION_SEND`/`SEND_MULTIPLE`
share-in is not currently declared. Sharing out uses the sharing plugin.

Source: [AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml),
[PdfIntentTrampolineActivity.kt](../android/app/src/main/kotlin/com/yourmateapps/pdfhelper/PdfIntentTrampolineActivity.kt),
[MainActivity.kt](../android/app/src/main/kotlin/com/yourmateapps/pdfhelper/MainActivity.kt),
[android_storage_service.dart](../lib/services/android_storage_service.dart).

## 6. Advertising, reporting and privacy configuration

### Advertising behavior

The home screen and PDF viewer each contain a standard **320 × 50** bottom
banner. The widget occupies space only when an ad is available and the layout
is wide enough. Consent changes dispose existing banner state before a new
request can occur.

An available interstitial may appear after every **fourth successful
document-producing operation in the current session**: merge, split, create,
organize, protect, unlock or metadata update. Presentation checks foreground
and current-route eligibility, avoids stacking full-screen ads and waits for
dismissal before navigating to the result. Reading does not count toward it.

Android debug/profile builds use Google's test ad units. Release builds use
configured production units. UMP refreshes consent and permits ad requests only
when `canRequestAds()` allows them. Settings reopens required privacy options;
ads are disabled while that form is open or when updated eligibility cannot be
established. Consent refusal can still permit limited ads under the SDK's
result; the implementation does not promise an ad-free app after refusal.

Source: [ads_service.dart](../lib/services/ads_service.dart),
[operation_ad_policy.dart](../lib/services/operation_ad_policy.dart),
[banner_ad_widget.dart](../lib/widgets/banner_ad_widget.dart).

### Crash reporting and app configuration

Firebase/Crashlytics runtime initialization is limited to release mode. The
manifest starts with crash collection disabled; successful release
initialization enables it and installs Flutter/uncaught-error reporting.
Initialization failures are tolerated. Debug builds skip the production Firebase
client; an optional registered debug configuration can be supplied separately.
There is no Firebase Analytics dependency in the app's dependency manifest.

App backup and cleartext traffic are disabled. Broad photo/video library
permissions and microphone recording are removed from the merged manifest;
gallery selection uses the system picker and scan capture does not record
audio. Camera and notification access are requested for the relevant feature.

Settings points to the public privacy policy at
`https://yourmateapps.github.io/pdfhelper/privacy-policy.html`. The audit owns
deployment/verification evidence. The privacy text and store declarations must
continue to describe local documents separately from advertising and crash
reporting SDK behavior.

Source: [firebase_service.dart](../lib/services/firebase_service.dart),
[AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml),
[settings_screen.dart](../lib/screens/settings_screen.dart).

## 7. Build and release configuration

| Configuration | Current implementation |
| --- | --- |
| Native Android targets | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| Native preflight | Android pre-build requires `libpdf_ffi.so` for all three targets |
| SDK configuration | Compile SDK 37; minimum/target SDK supplied by the installed Flutter toolchain |
| Java/Kotlin bytecode | JVM 17 |
| Release optimization | R8 minification and resource shrinking enabled |
| Signing | `android/key.properties`, or an external file selected by `signingPropertiesFile` |
| Signing failure behavior | Missing credentials/keystore fail release preflight; no debug-key fallback |
| Debug installation | Separate application ID and version suffix; release credentials are not required |
| Crashlytics uploads | Skipped locally unless Gradle property `uploadCrashlytics=true` is explicitly supplied |

For this Android-only scope, build native targets explicitly rather than using
the script's macOS default that also attempts iOS:

```bash
bash scripts/build_pdf_core.sh android
bash scripts/build_pdf_core.sh macos
flutter pub get
flutter build appbundle --release
```

macOS is included above only when host tests need its native library. Rebuild
the Flutter artifact after changing native libraries; hot reload does not
replace bundled native code. A release snapshot must record engine changes in
the engine repository and the matching submodule revision in the app repository,
with corresponding native binaries or a reproducible build of them.

The local signing file must contain `keyAlias`, `keyPassword`, `storeFile` and
`storePassword` and must remain outside version control. CI may select its
external signing configuration with
`ORG_GRADLE_PROJECT_signingPropertiesFile`. The intended release pipeline can
opt into mapping upload with `ORG_GRADLE_PROJECT_uploadCrashlytics=true`; the
audit distinguishes configured behavior from an actual successful upload.

Source: [build.gradle.kts](../android/app/build.gradle.kts),
[build_pdf_core.sh](../scripts/build_pdf_core.sh),
[check_android_native.py](../scripts/check_android_native.py).

## 8. Explicit product boundaries

These boundaries are part of the current baseline, not evidence that older
fixed defects have returned:

- Rendering compatibility remains bounded. Many unsupported or approximate PDF
  features produce warnings, but warning coverage is incomplete; a page without
  warnings is not necessarily faithful. See the renderer capabilities document.
- Interactive form editing, annotation editing, OCR, redaction, compression,
  watermark/page-number tools and PDF-to-image export are not shipped tools.
- Native open-once document handles, fine-grained operation progress and
  cancellation remain engine/API enhancements. Existing app-level batch status
  does not imply cancellable native operations.
- In-document search, reading-position restoration and advanced viewer
  navigation remain separate from implemented Files search and page jumps.
- File multi-selection/folders, reverse sort, scan capture reordering and
  destination-chooser Save As are future work.
- Follow-system theme, localization and an in-app licenses/feedback experience
  are not implemented product flows.
- AI remains hidden, iOS deferred and desktop/web unsupported as release apps.

Publication still requires the external decisions and confirmations recorded in
the [production audit](PRODUCTION_AUDIT_2026-10-06.md), including account/store
declarations, intended service ownership and remaining user-owned phone checks.
This source inventory itself does not assert store approval or a completed
production rollout.
