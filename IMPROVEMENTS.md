Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/pubspec.yaml)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/IMPROVEMENTS.md)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/README.md)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/providers)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/utils)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/widgets)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/models)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/android/app/src/main/AndroidManifest.xml)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/main.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/pdf_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/providers/theme_provider.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/splash_screen.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/intent_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/merge_pdf_screen.dart#1-1), lines 1 to 400

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/convert_screen.dart#1-1), lines 1 to 500

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/permission_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/split_pdf_screen.dart#1-1), lines 1 to 600

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/pdf_preview_screen.dart#1-1), lines 1 to 400

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/scan_edit_screen.dart#1-1), lines 1 to 400

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/utils/error_logger.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/firebase_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/ads_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/services/notification_service.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/utils/format_utils.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/home_screen.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/widgets/pdf_intent_listener.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/settings_screen.dart#1-1), lines 1 to 300

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/test)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/android/app/src/main)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/models/selected_pdf_file.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/widgets/lazy_indexed_stack.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/widgets/banner_ad_widget.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/analysis_options.yaml)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/pdf_viewer_screen.dart#1-1), lines 1 to 100

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/android/app/src/main/kotlin)

Searched for files matching `**/test/**/*.dart`, 1 match

Searched for regex `withValues\(alpha:|withOpacity\(|getApplicationDocumentsDirectory|debugPrint` (`**/lib/**/*.dart`), 80 results

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/test/utils/format_utils_test.dart)

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/lib/screens/scan_edit_screen.dart#390-390), lines 390 to 700

Searched for text `UsageDescription` (`**/ios/Runner/Info.plist`), 4 results

Read [](file:///Users/koundinya/flutter_projects/pdfhelper/android/app/build.gradle.kts)

Here's the analysis. I focused on real defects and high-impact improvements rather than nitpicks.

## Critical / High-priority defects

### 1. AdMob: real ad-unit IDs shipping as "test" (policy risk)
ads_service.dart claims "Uses Google's published test ad-unit IDs everywhere", but the Android IDs (`ca-app-pub-2596031675923197/...`) are your real publisher unit IDs. Only the iOS fallbacks are Google's test IDs. Combined with the real `APPLICATION_ID` in AndroidManifest.xml, every dev/QA run on Android serves real ads — that's an AdMob policy violation that can get the account suspended. Use `ca-app-pub-3940256099942544/6300978111` (banner) and `.../1033173712` (interstitial) for Android in debug builds.

### 2. `outputQuality` parameter is dead in merge/split
pdf_service.dart accepts `outputQuality` on `mergePdfsFromBytes`, `splitPdfByRangeFromBytes`, `extractPagesFromBytes`, `splitPdfAllPagesFromBytes` etc. but never uses it. README/IMPROVEMENTS.md says merge/split "preserve source quality by design" — then drop the parameter to stop misleading callers. `mergePdfs(List<String>)` is also unreferenced dead code.

### 3. Sync I/O on the UI thread
- pdf_viewer_screen.dart calls `File(...).existsSync()` inside `build()` — runs on every rebuild.
- scan_edit_screen.dart calls `File.deleteSync()` from the close button.
- convert_screen.dart `_removeImage` uses `deleteSync` inside `setState`.

These can ANR on slow storage. Convert to `await ...delete().catchError(...)`.

### 4. Document filter is pathologically slow
scan_edit_screen.dart: for each pixel, iterates a 31×31 (step 3) local window — about 120 random reads per pixel. On a 12MP photo that's ~1.4B reads. Even in `compute`, this freezes the isolate for many seconds. Use an integral image (summed-area table) so each window mean/min/max is O(1), or downscale to ~1500px before processing.

### 5. `pdf_viewer_screen` back-button blows away the navigation stack
pdf_viewer_screen.dart and the lower one do `Navigator.pushReplacement(... HomeScreen())`. That:
- Drops every previous route (e.g. preview screen below it) so users can't go back to the merge result list.
- Recreates `HomeScreen` from scratch, losing the active tab and any in-progress state.

Use `Navigator.maybePop(context)` and only fall back to `HomeScreen` when the route can't pop.

### 6. `PermissionService._showSettingsDialog` always returns `false`
permission_service.dart: even when the user taps "Open Settings", the function returns `false` (after a meaningless 500ms delay). Most call sites then treat the permission as denied and show the denial UI even if the user just granted it in settings. Fix: re-check `permission.status` after `openAppSettings()` resolves and on app `resumed` lifecycle, then re-evaluate.

### 7. Originals are never cleaned up after auto-save → duplicate storage
theme_provider.dart copies the produced PDF into `PDFHelper/Downloads/` but the source under `getApplicationDocumentsDirectory()` is left behind. Same pattern in split_pdf_screen.dart. Over time the app's documents dir grows unbounded. Either move-rename, or delete the source after a successful copy.

### 8. `SelectedPdfFile.cachedBytes` retained until screen dispose
Already noted in IMPROVEMENTS.md but not done. With several 50MB PDFs queued for merge, this is the dominant memory contributor. Clear `cachedBytes` in the merge completion path before navigating to preview.

### 9. `loadPagePreviews` renders every page at full resolution
pdf_service.dart and split_pdf_screen.dart render each page up to 1500×1700 JPEG and hold them all in a `List<Uint8List?>`. For a 29-page A4 PDF that's ~30–60MB of decoded bitmaps before display. Use ~250–400px for the grid thumbnails, keep full-res only for the page being viewed.

### 10. `unused` `WRITE_EXTERNAL_STORAGE` with `tools:replace`
AndroidManifest.xml declares `WRITE_EXTERNAL_STORAGE` (maxSdkVersion=29) with `tools:replace`. Since storage is fully app-private, this permission isn't needed on any supported SDK and the `tools:replace` only papers over a manifest-merge complaint that is no longer relevant. Remove both lines and `READ_EXTERNAL_STORAGE` (file_picker uses SAF on API 29+).

## Medium-priority issues

### 11. `_isProcessing = false` in `finally` without `mounted` check
merge_pdf_screen.dart, convert_screen.dart, split_pdf_screen.dart — if the widget is popped (e.g. user backs out during processing), `setState` is called on an unmounted state and throws (caught silently in release, but warns in debug).

### 12. Redundant keep-alive
`HomeScreen` uses `LazyIndexedStack` (which is an `IndexedStack` underneath) AND every tab screen uses `AutomaticKeepAliveClientMixin`. The mixin is a no-op inside `IndexedStack` since the stack already keeps subtrees alive. Drop the mixin from `MergePdfScreen`/`SplitPdfScreen`/`ConvertScreen`.

### 13. Two paths reading native intent state can race
splash_screen.dart calls `IntentService.getOpenedPdfIntent()` and pdf_intent_listener.dart listens to `receivedIntentStream`. Both navigate. On cold start with a PDF intent, the listener may also fire and push a duplicate route. Add a guard (e.g. consume the native data once and ignore subsequent identical events for ~1s, or have splash signal "intent consumed" before listener subscribes).

### 14. Nothing deletes resolved-intent temp files
The native side copies content:// URIs to `intent_<ts>_<name>.pdf` in app cache/docs. Nothing ever deletes them. Add cleanup of `intent_*` files older than 24h on splash.

### 15. `requestWithRationale` skips rationale on the very first request (Android)
On Android, `shouldShowRequestRationale` is `false` until the user has denied at least once, so first-time users go straight to the OS prompt with no context — this is what the OS recommends, but the code paths around it are written as if rationale always precedes the request. If a rationale before the first prompt is desired, gate it on a SharedPreferences "first ask" flag too.

### 16. No file-size guard
`File.readAsBytes()` is used everywhere (merge_pdf_screen.dart, split_pdf_screen.dart, pdf_service, etc.). A 1GB PDF will OOM the app. Add a size check (e.g. reject >200MB with a SnackBar) at the picker step.

### 17. `getPageCount` re-opens the file even when bytes are cached
split_pdf_screen.dart opens the file via path for page count, then re-reads it as bytes a line later. Use `getPageCountFromBytes` once.

### 18. URL placeholders still marked `TODO`
settings_screen.dart — `_rateAppUrl` is `https://example.com/...`. Don't ship without replacing with the real Play Store / privacy URLs. The Terms of Service URL referenced in IMPROVEMENTS.md isn't even surfaced in the UI.

### 19. `applicationId` is a placeholder
build.gradle.kts — `com.yourmateapps.pdfhelper` with a `TODO` to specify your own. Confirm this is the real intended package; if not, changing it later breaks signing/upgrade paths for installed users.

### 20. Verbose `debugPrint` chatter in production code paths
~50 `debugPrint` calls in intent_service.dart, pdf_intent_listener.dart, splash_screen.dart, ads_service.dart. `debugPrint` is no-op in release builds, but the string concatenations (especially the `intent.extra.toString()` one in pdf_intent_listener.dart) still execute. The shiny new error_logger.dart helper isn't used anywhere — adopt it and gate verbose logging on `kDebugMode`.

## Lower-priority polish

- analysis_options.yaml doesn't enable any extra lints. Add `strict-casts: true`, `strict-inference: true`, and rules like `prefer_const_constructors`, `use_build_context_synchronously`, `unawaited_futures`.
- Theming: `AppColors` is reconstructed on every widget access (e.g. `_colors` getters in every screen). Consider `AppColors.of(context)` with a single instance per theme change.
- All navigation is direct `Navigator.push(MaterialPageRoute(...))`. Switching to `go_router` (already in IMPROVEMENTS.md) would also fix the splash↔listener race.
- Localization: zero `intl` integration; whole UI is English only.
- Tests: only format_utils_test.dart exists. No coverage for `PdfService`, `ThemeProvider`, intent parsing.
- No cancel for long-running splits/conversions (also in IMPROVEMENTS.md).
- Splash hard-codes 800ms+500ms delays before navigating; on fast devices that's pure latency.
- `PdfDocument` instances are disposed manually; some catch-blocks return early without disposing the source doc on error (e.g. extracted-pages range check at pdf_service.dart — it does dispose; but other early-error returns may not). Consider a `try { ... } finally { sourceDoc.dispose(); }` wrapper.
- `BannerAdWidget` doesn't reload if `AdsService` finishes init *after* the widget mounted (when `_initialized` was false in `initState`, no listener triggers a retry).
- iOS Info.plist is missing `LSApplicationQueriesSchemes` for any deep-link/share targets (only matters if you add them).

Want me to implement any of these? The quick wins I'd suggest tackling first: #1 (test ad IDs), #3 (sync I/O), #5 (viewer back nav), #6 (settings dialog return value), #10 (manifest cleanup), and #20 (debug log gating).