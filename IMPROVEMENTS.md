# PDF Helper – Project Analysis & Improvement Prompts

This document summarizes how the project works and lists improvement opportunities. Use each item as a prompt for future development.

---

## How the Project Works

### Architecture
- **Flutter app** with screens, providers, and services
- **Screens**: `SplashScreen` → `HomeScreen` (IndexedStack with bottom nav) → Merge, Convert, Split, Settings
- **State**: `ThemeProvider` (ChangeNotifier) for theme + settings; screens use local `setState`
- **Navigation**: Direct `Navigator.push` / `pushReplacement` with `MaterialPageRoute` or `PageRouteBuilder` (no named routes)
- **PDF**: Syncfusion for merge/split/image-to-PDF; pdfx for thumbnails and page previews

### Key Flows
1. **Merge**: Pick PDFs → ReorderableListView → merge in isolate → save → optional auto-save to Downloads/Documents
2. **Convert**: Camera/gallery → `ScanEditScreen` (crop + filters) → images to PDF → save → optional auto-save
3. **Split**: Pick PDF → page range or page selection (<30 pages) or extract all → save → optional auto-save

### Services
- **PdfService**: Static methods, `compute()` for heavy work (merge, split, image-to-PDF)
- **NotificationService**: Singleton, local notifications on completion
- **ThemeProvider**: Theme, auto-save, save location, notifications; persisted via SharedPreferences

---

## Improvement Prompts (Copy & Use)

### 1. Wire Output Quality to PdfService
**Current**: `_outputQuality` in `SettingsScreen` is local state only; not persisted or used by `PdfService`.
**Prompt**: "Wire the Output Quality setting (Low/Medium/High/Maximum) from Settings to PdfService. Persist it in ThemeProvider/SharedPreferences. Apply it when converting images to PDF and when merging/splitting (e.g., image compression, PDF compression level)."

---

### 2. Implement About Actions (Rate App, Privacy, Terms)
**Current**: Rate App, Privacy Policy, Terms of Service in Settings use empty `() {}` callbacks.
**Prompt**: "Implement the About section actions in SettingsScreen: (a) Rate App – open store listing via url_launcher or in_app_review, (b) Privacy Policy – open URL or show in-app browser, (c) Terms of Service – same. Add placeholder URLs if needed."

---

### 3. Add State Management (Provider/Riverpod)
**Current**: Only ThemeProvider; screens use local state; output quality is screen-local.
**Prompt**: "Introduce Provider or Riverpod for shared state. Move output quality, and any other cross-screen settings, into a provider. Use it for dependency injection and cleaner testability."

---

### 4. Add Named Routes / go_router
**Current**: Direct `Navigator.push` / `pushReplacement` with `MaterialPageRoute`.
**Prompt**: "Add go_router (or named routes) for navigation. Define routes for /, /merge, /convert, /split, /settings, /scan-edit. Support deep linking for PDFs if possible."

---

### 5. Improve Project Structure
**Current**: No `models/`, `widgets/`, `utils/`; data classes and helpers mixed in screens/services.
**Prompt**: "Refactor into: lib/models/ (SelectedPdfFile, ImageFilterRequest, etc.), lib/widgets/ (shared UI like cards, tiles, buttons), lib/utils/ (AppColors, formatFileSize, etc.). Keep screens focused on layout and logic."

---

### 6. Add Unit and Widget Tests
**Current**: No tests in the project.
**Prompt**: "Add unit tests for PdfService (merge, split, imagesToPdf), ThemeProvider (load/save settings), and image filter logic. Add widget tests for critical screens (e.g., SettingsScreen)."

---

### 7. Consolidate PDF Libraries
**Current**: Syncfusion for operations; pdfx for thumbnails and previews.
**Prompt**: "Evaluate whether Syncfusion alone can generate thumbnails and page previews. If yes, remove pdfx to reduce size and complexity. If no, document why both are needed."

---

### 8. Platform-Specific Save Location
**Current**: `getAutoSavePath()` uses hardcoded paths for Android (`/storage/emulated/0/Download`, `/storage/emulated/0/Documents`); iOS uses app documents.
**Prompt**: "Improve auto-save path: use Android Storage Access Framework or MediaStore for Downloads/Documents; support iOS Downloads; add Windows/macOS paths. Handle permission errors gracefully."

---

### 9. Error Handling and User Feedback
**Current**: Errors logged with `debugPrint`; SnackBars for user feedback; some errors may not surface.
**Prompt**: "Improve error handling: centralize error logging; show user-friendly messages for failures (merge, split, save, permissions); add retry options where appropriate."

---

### 10. Accessibility
**Current**: No explicit semantics or accessibility labels.
**Prompt**: "Add Semantics and accessibility labels for buttons, icons, and navigation. Ensure sufficient contrast and support TalkBack/VoiceOver."

---

### 11. IndexedStack Performance
**Current**: All screens built and kept in memory via IndexedStack.
**Prompt**: "Consider lazy-loading screens or using AutomaticKeepAliveClientMixin only for screens that need to preserve state. Avoid unnecessary rebuilds when switching tabs."

---

### 12. Permission Handling UX
**Current**: Permissions requested on splash; notification permission when enabling in settings.
**Prompt**: "Improve permission UX: request permissions just-in-time (e.g., camera when opening Convert); show rationale dialogs; handle 'denied' and 'permanently denied' with guidance to open settings."

---

### 13. Update README
**Current**: Default Flutter README.
**Prompt**: "Replace README with project-specific content: features, screenshots, build instructions, platform support (Android, iOS, macOS, Windows), and any setup notes."

---

### 14. Android MANAGE_EXTERNAL_STORAGE
**Current**: `MANAGE_EXTERNAL_STORAGE` in manifest; may cause Play Store rejection.
**Prompt**: "Remove MANAGE_EXTERNAL_STORAGE if not strictly needed. Use scoped storage or SAF for file access. Ensure compatibility with Android 10+ storage model."

---

### 15. Image Compression for Scan-to-PDF
**Current**: `img.encodeJpg(processed, quality: 100)` in scan filters; no quality control from settings.
**Prompt**: "Make image quality configurable for scan-to-PDF. Use output quality setting when encoding images before PDF conversion. Balance file size vs quality."

---

### 16. Progress Feedback for Long Operations
**Current**: Merge/split show progress; some flows may not.
**Prompt**: "Ensure all long-running operations (merge, split, image-to-PDF, batch extract) show clear progress (e.g., CircularProgressIndicator or linear progress). Add cancel support where feasible."

---

### 17. Undo/Redo for Crop/Filter
**Current**: ScanEditScreen: crop and filter applied; no undo.
**Prompt**: "Add undo/redo for crop and filter changes in ScanEditScreen. Allow reverting to original state before saving."

---

### 18. Batch Operations (e.g., Merge Multiple Sets)
**Current**: One merge at a time.
**Prompt**: "Support batch operations: e.g., merge multiple groups of PDFs in one session, or split one PDF into multiple outputs with different ranges. Improve UX for power users."

---

### 19. PDF Preview Before Save
**Current**: Preview exists for split page selection; merge/convert show final result after save.
**Prompt**: "Add optional preview of merged or converted PDF before saving. Allow last-minute changes or reorder."

---

### 20. Localization
**Current**: All strings in English.
**Prompt**: "Add localization (flutter_localizations, intl). Extract strings to ARB files. Support at least one additional language."

---

## Quick Reference

| Area | File(s) | Notes |
|------|---------|-------|
| Output quality | `settings_screen.dart`, `pdf_service.dart` | Not wired |
| About actions | `settings_screen.dart` | Placeholders |
| Auto-save path | `theme_provider.dart` | Android-specific |
| PDF operations | `pdf_service.dart` | Syncfusion |
| Thumbnails | `merge_pdf_screen.dart`, `split_pdf_screen.dart` | pdfx |
| Filters | `scan_edit_screen.dart` | image package |
| Permissions | `splash_screen.dart`, `settings_screen.dart` | permission_handler |

---

*Generated from project analysis. Use these prompts as starting points for future development.*
