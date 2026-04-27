# PDF Helper — Improvements Backlog

Open improvements after the recent fix-up pass. Status as of this commit:

## Recently completed

- ✅ iOS `Info.plist` permission strings (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, etc.) — without these the app crashed on iOS prompts
- ✅ Wired the **Output Quality** setting into `PdfService.imagesToPdf` (decode + re-encode as JPEG at chosen quality off the UI thread)
- ✅ User-facing SnackBars for previously-silent PDF preview load failures
- ✅ **Settings → Rate App / Privacy Policy / Terms of Service** wired via `url_launcher` (placeholder URLs marked with `TODO`)
- ✅ Android **Merge / Split intent aliases** added; trampoline now reads action from `<meta-data>` (was hardcoded to "view")
- ✅ **Skip Preview** toggle in Settings for one-tap save
- ✅ **Undo / Redo** in scan editor (10-state history)
- ✅ Removed unused duplicate `lib/utils/app_colors.dart`
- ✅ Centralized error logger helper (`lib/utils/error_logger.dart`)
- ✅ README rewritten with project-specific content

## Stack reality check

The project uses **`pdfrx` only** (MIT) — no Syncfusion, no `pdfx`. Earlier docs incorrectly mentioned Syncfusion + pdfx; this is now corrected.

## Open prompts

### Just-in-time permissions
The camera permission is currently requested on splash. Move it to the first camera open in `convert_screen.dart`. Show rationale dialog; on "permanently denied", offer a button to `openAppSettings()`. Same for photo library on Android <13.

### Accessibility
No explicit `Semantics` labels yet. Wrap icon-only buttons (capture, flash, undo/redo, tab nav) in `Semantics(label: ..., button: true)`. Verify ≥48dp tap targets and contrast on gradient/accent text.

### Cancel support for long operations
`PdfService.imagesToPdf` and `splitPdfAllPagesFromBytes` are loop-based and could accept a `Completer<bool>` cancel token checked between iterations. Add a Cancel button next to the existing progress indicator. Skip merge — it's a single `pdfrx` call.

### Consistent progress indicators
Merge has a value-driven `LinearProgressIndicator`. Verify split-all and image-to-PDF show similar value-based progress (not just spinning).

### Memory cleanup
`SelectedPdfFile.cachedBytes` is held until the screen is disposed. Clear it in merge/split screens immediately after the operation completes.

### Tests
No `test/` folder. Suggested coverage:
- `pdf_service_test.dart` — merge two small PDFs, split, image-to-PDF (uses fixture bytes)
- `theme_provider_test.dart` — load/save settings via `SharedPreferences.setMockInitialValues`
- `format_utils_test.dart` — file size formatting
- One widget test for `SettingsScreen` (toggles persist)

### Named routes / `go_router`
All navigation is direct `Navigator.push(MaterialPageRoute(...))`. Add `go_router` and define `/`, `/home`, `/merge`, `/convert`, `/split`, `/settings`, `/scan-edit`, `/preview`, `/viewer`. Update splash + intent listener to `context.go(...)`.

### Localization
All strings are English. Add `flutter_localizations` + `intl`, `l10n.yaml`, and extract user-facing strings to `lib/l10n/app_en.arb` (+ at least one second locale).

### Quick reference

| Area | File(s) |
|------|---------|
| Output quality | `pdf_service.dart` (image-to-PDF wired); merge/split preserve source quality by design |
| About URLs | `settings_screen.dart` — placeholders marked with `TODO` |
| Auto-save path | `theme_provider.dart` — app-private scoped storage |
| Intent aliases | `AndroidManifest.xml`, `PdfIntentTrampolineActivity.kt` |
| Filters | `scan_edit_screen.dart` (uses `image` package, runs in isolate via `compute`) |
| Permissions | `splash_screen.dart`, `settings_screen.dart`, `permission_service.dart` |
