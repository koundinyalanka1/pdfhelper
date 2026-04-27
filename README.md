# PDF Helper

A Flutter PDF toolkit for Android & iOS. Merge, split, scan-to-PDF, and view PDFs — fully offline, MIT-licensed PDF engine (`pdfrx`).

## Features

- **Merge PDFs** — combine multiple PDFs (with batch support for power users)
- **Split PDFs** — by page range, multiple ranges in one run, individual page selection (small docs), or extract every page
- **Scan to PDF** — camera capture or gallery pick → crop → 6 filters (auto, document, magic color, B&W, grayscale, original) → multi-page PDF
- **PDF viewer** — open and page through any PDF
- **System integration** — appears in Android "Open with" menu as **View / Merge / Split with PDF Helper**
- **Auto-save** to app-private `Downloads` or `Documents` folder
- **Output quality** setting (Low / Medium / High / Maximum) — controls JPEG re-compression for image-to-PDF
- **Undo / Redo** in scan editor (10-step history)
- **Skip Preview** mode for one-tap save (power users)
- **Dark / light theme**, completion notifications
- Just-in-time permission requests with rationale dialogs

## Tech Stack

- **Flutter** 3.10+
- **pdfrx** (^2.2) — single PDF engine for merge, split, render, encode (MIT)
- **provider** — settings state
- **image** + **crop_your_image** — scan filters & cropping
- **camera**, **image_picker**, **file_picker**
- **url_launcher** — Settings → Rate / Privacy / Terms
- **flutter_local_notifications**, **share_plus**, **permission_handler**, **receive_intent**

## Build

```bash
flutter pub get
flutter run             # debug
flutter build apk       # Android release
flutter build ipa       # iOS release (requires signing)
```

## Platform support

| Platform | Status |
|----------|--------|
| Android  | supported (API 21+); scoped storage; Merge/View/Split intent aliases |
| iOS      | supported; required `NS*UsageDescription` keys are in `Info.plist` |
| macOS / Windows / Linux | not currently maintained |

## Notes

- Auto-save uses **app-private** storage (`getApplicationDocumentsDirectory()/PDFHelper/{Downloads,Documents}`). No `MANAGE_EXTERNAL_STORAGE` is requested — Play Store compliant.
- The `Output Quality` setting re-encodes images as JPEG (50/70/85/100) before they're embedded into the PDF; merge/split preserve the source PDF's quality.
- Rate / Privacy / Terms URLs are placeholders (`https://example.com/...`); update them in `lib/screens/settings_screen.dart` before publishing.

## Project layout

```
lib/
  main.dart
  models/        # SelectedPdfFile
  providers/     # ThemeProvider + AppColors
  screens/       # splash, home, merge, convert, split, scan-edit, preview, viewer, settings
  services/      # PdfService, NotificationService, IntentService, PermissionService
  utils/         # format_utils, error_logger
  widgets/       # LazyIndexedStack, PdfIntentListener, settings_widgets
```

See `IMPROVEMENTS.md` for the open enhancements backlog.
