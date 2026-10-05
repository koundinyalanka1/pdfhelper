**PDF Helper production-readiness audit — 4 October 2026**

**Original audit verdict: hold the release.** The findings below record the defects observed before the repair pass. Current fixes and verification are tracked in [PRODUCTION_FIX_PLAN.md](PRODUCTION_FIX_PLAN.md). The user has deferred iOS; current implementation and release validation focus on Android.

**Renderer follow-up (5 October):** the receipt spacing defect is fixed and visually checked against CoreGraphics. Expanded rendering changes and their latest source/build/device results are tracked in [RENDERER_COMPLETION_PLAN.md](RENDERER_COMPLETION_PLAN.md). Counts below remain the original audit evidence.

This review covers the current working tree, including pre-existing uncommitted application and native-engine changes. The user subsequently requested a fix for scrolling while zoomed, then authorized the broader repair pass and a bottom viewer banner. The original zoom follow-up and its historical artifact are recorded below; they are superseded by the repair tracker's final validation when available. Nothing has been uploaded or published. AI remains disabled by `Features.ai` and was excluded from the shipped-feature assessment. Desktop/web are not supported release targets in this repository.

**Verification completed**

| Check | Result | Practical limit |
| --- | --- | --- |
| Flutter static analysis | Passed, no issues | Does not prove runtime correctness |
| Flutter suite using bundled macOS PDF library | Original 318 passed; final 321 passed after the viewer fix on 4 October | Three new viewer regressions; the unrepaired audit findings remain outside this passing suite |
| Rust workspace | 262 unit tests and 1 documentation test passed | Native correctness tests do not establish universal PDF compatibility |
| Packaged Android PDF integration test | Passed on Motorola edge 70 fusion, Android 16/API 36 | Exercises native image composition, merge, extraction, rotation, encryption/decryption and rendering; not every interactive UI flow |
| Focused scan-cancel regression | Failed as expected: source image no longer exists after cancel | Confirms finding 1 |
| Focused export delete/rename regressions | Both failed as expected: deleted copy reappears; rename produces two entries | Confirms finding 2 |
| Android release AAB | Rebuilt with the zoom fix on 4 October, approximately 72.7 MB | No store upload, account approval, or release signing ownership verification |
| Packaged native artifact check | All 3 PDF ABIs present; 14 ELF64 libraries pass static 16 KB alignment/RELRO checks | Connected phone uses 4 KB pages; actual 16 KB runtime remains untested |
| Existing debug APK ZIP alignment | Passed `zipalign -c -P 16 4` on 4 October | Does not establish release APK or 16 KB runtime behavior |
| Independent PDF fidelity check | Bundled macOS engine compared with Apple CoreGraphics on 4 October | Confirms hidden-layer and dashed-line defects on tiny valid fixtures |
| iOS | Source/configuration review | No iOS build or physical-device verification in this audit |

The initial compilation, native suite, 318-test Flutter suite, device integration test and three failing audit regressions ran on 3 October during this review. On resuming on 4 October, source checks and the saved release artifact were reconfirmed, and the final 321-test Flutter suite and clean static analysis verified the requested viewer fix. Earlier `/tmp` logs and focused audit test files were no longer present, so those transient paths should not be treated as retained release evidence. Final Flutter output is temporarily available at `/tmp/pdfhelper-final-tests.log`.

**Original confirmed findings, ordered by priority**

1. **P1 — Cancelling an edit destroys an existing scan page.**

   Add a scan page, finish editing, reopen that page from the scan strip, then tap the editor's X. The editor deletes the existing image while the parent's page list still references it. Subsequent conversion encounters a missing image. The focused widget regression confirmed that the source exists before X and does not exist afterward.

   References: [existing page passed into editor](../lib/screens/convert_screen.dart#L546), [unconditional cancellation deletion](../lib/screens/scan_edit_screen.dart#L575).

   Fix: distinguish a newly captured temporary image from an existing saved page, edit a temporary copy, and replace the original only after a successful save. Cancel must leave an existing page intact. Cover both X and system Back.

2. **P1 — Delete does not remove an exported document as promised; rename creates duplicates.**

   Android keeps a private working PDF and a public export, but the library treats their relationship only as display deduplication. With storage access granted, the public path is shown and the working path is hidden. Delete removes only the displayed public path. On the next scan, the private copy becomes visible again, despite the confirmation saying the document will be permanently deleted from the device. Rename similarly leaves the export record pointing at the old public name, exposing both the working copy and renamed export. Two focused filesystem/reconciliation tests reproduced these results. Without broad storage access, deleting the displayed private copy can instead leave the public export behind.

   References: [delete](../lib/screens/library_screen.dart#L533), [rename](../lib/screens/library_screen.dart#L475), [export reconciliation](../lib/services/pdf_library_service.dart#L218), [export record storage](../lib/services/public_pdf_save_service.dart#L51).

   Fix: maintain a document identity with its working path, public URI and public path; make delete/rename update the relevant files, export records, recents and stars together. Explicitly handle partial failure and inaccessible public copies. The confirmation text must match the actual scope of deletion.

3. **P1 for iOS — Camera permission code is compiled out of the current CocoaPods configuration.**

   Scan gates camera initialization on `Permission.camera`. The Podfile does not enable the permission handler camera macro; in the installed CocoaPods plugin this permission is disabled by default. Usage-description strings in Info.plist do not enable that implementation. This is a source/configuration finding, not an iPhone runtime reproduction.

   References: [Podfile build configuration](../ios/Podfile#L41), [camera permission gate](../lib/screens/convert_screen.dart#L88).

   Fix: enable the required camera permission implementation and validate first request, denial, permanent denial and return from Settings on iOS.

4. **P2 — Some PDF graphics are silently rendered incorrectly.**

   The renderer's default operator branch ignores unsupported operators without warning. Tiny valid fixtures showed dashed and solid lines producing identical pixels, and a layer configured as OFF still producing its red artwork. Both returned empty warnings. A fresh comparison against Apple CoreGraphics on 4 October confirmed the bundled engine draws 9,600 red pixels for the hidden layer where CoreGraphics draws none; the dashed fixture produces 628 black pixels versus CoreGraphics' 320. This changes document appearance without the viewer's approximation notice.

   Reference: [renderer operator dispatch](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page.rs#L580).

   Fix: implement dash and optional-content visibility semantics, or report these features as unsupported. Compare output with an independent PDF renderer, not only this engine's own writer.

5. **P2 — Page extraction drops PDF layer visibility configuration.**

   Extraction installs a new catalog and carries forms/outlines but not `/OCProperties`. A valid layered fixture retained its layer objects after extraction while losing its visibility configuration. Apple CoreGraphics independently renders the extracted document with the formerly hidden layer visible, confirming that the saved document changes outside this app too. Organize uses the extraction path, and merge uses the same catalog-preservation helpers. Extraction was reproduced; the other paths were traced in source.

   References: [catalog extras](../packages/flutter_pdf_core/rust/crates/pdf_ops/src/preserve.rs#L100), [new catalog](../packages/flutter_pdf_core/rust/crates/pdf_ops/src/split.rs#L138), [organize extraction](../lib/screens/organize_pages_screen.dart#L130).

   Fix: preserve/remap optional-content groups and their configurations for retained pages. Until supported, reject or clearly warn before operations that lose this configuration.

6. **P2 — Large viewer renders discard compatibility warnings.**

   Viewer targets above 1,680 pixels bypass the bitmap cache, but warnings are stored only when caching is enabled. The viewer then asks that cache for warnings. A tablet's initial render can exceed this threshold, so omitted images or approximate content can be displayed without notice even when native rendering reports the problem. Source-confirmed; not reproduced on a tablet.

   References: [viewer cache threshold and warning lookup](../lib/screens/pdf_viewer_screen.dart#L1056), [warning storage conditional](../lib/services/pdf_raster.dart#L107).

   Fix: return bytes and warnings together, independent of whether bitmap caching is enabled.

7. **P2 — Rewriting a small sparse-numbered PDF can greatly inflate it.**

   The writer emits a cross-reference row for every object number up to the highest ID and builds the complete output in memory. A bounded valid one-page fixture grew from 500 bytes to 20,000,387 bytes after rotation. The observation establishes unnecessary storage and memory growth; no crash or exhaustion test was attempted.

   Reference: [dense xref generation](../packages/flutter_pdf_core/rust/crates/pdf_core/src/writer.rs#L46).

   Fix: compact object IDs or emit sparse xref subsections, and avoid unnecessary whole-output buffering for large files.

8. **P2 — Leaving Scan does not release the camera.**

   Home passes `isActive` to Scan, but Scan uses it only when deciding whether an ad may appear. There is no tab-change handler to stop the camera; the kept-alive tab releases it only when the app becomes inactive or the widget is disposed. App resume also initializes it without checking the active tab. This can leave camera use and an enabled torch active while users browse another tab.

   References: [Home passes active state](../lib/screens/home_screen.dart#L99), [camera lifecycle](../lib/screens/convert_screen.dart#L68), [only active-state use](../lib/screens/convert_screen.dart#L403). The attempted physical-device follow-up was inconclusive because foreground switched to another app; interactions were stopped. This finding remains based on source analysis.

   Fix: make camera ownership depend on app lifecycle, active tab and route visibility. Stop the controller and torch when Scan is hidden.

9. **P2 — Enabled scan illumination is switched off for the actual photo.**

   Capture explicitly sets `FlashMode.off` immediately before `takePicture`, then restores torch afterward. The illuminated preview therefore does not represent the lighting used for capture. This follows directly from command order; low-light photography was not tested.

   Reference: [capture flash sequence](../lib/screens/convert_screen.dart#L274).

   Fix: keep torch active through capture or use a supported capture flash mode, then restore the intended preview state.

10. **P2 — Scan photographs and crop intermediates accumulate in durable app storage.**

    Successful PDF saves clear `_capturedImages` without deleting their files. Disposal does not clean them either. Cropping creates document-directory files while cleanup only considers the current/original paths, leaving earlier crop versions. This grows storage and retains document photos after their UI references are gone. On iOS the app also enables file sharing, so these are especially inappropriate as unmanaged document-directory intermediates.

    References: [save clears paths only](../lib/screens/convert_screen.dart#L421), [editor crop writes](../lib/screens/scan_edit_screen.dart#L439), [editor cleanup](../lib/screens/scan_edit_screen.dart#L534), [iOS file sharing](../ios/Runner/Info.plist#L86).

    Fix: track ownership of all scan intermediates, delete them after successful output creation or explicit discard, and use temporary storage unless implementing recoverable drafts.

11. **P2 for iOS — Registered external PDF opens have no document routing.**

    Info.plist advertises PDF document handling, but `IntentService` returns null on every non-Android platform and there is no app-side iOS URL-to-viewer implementation. Choosing PDF Helper from Files therefore has no implemented path to open the supplied document. File-picker import is a separate flow.

    References: [document registration](../ios/Runner/Info.plist#L11), [Android-only intent service](../lib/services/intent_service.dart#L15), [AppDelegate](../ios/Runner/AppDelegate.swift#L4).

    Fix: handle cold and warm iOS document deliveries, including security-scoped file access/copying, and route the resolved file to the viewer.

12. **P2 for iOS — Notification preference resets on restart.**

    iOS startup sets `_hasPermission` to false without querying authorization. Theme initialization interprets that as permission revocation and persists notifications=false. A user who enabled notifications must enable them again after restarting.

    References: [permission state](../lib/services/notification_service.dart#L55), [stored preference overwritten](../lib/providers/theme_provider.dart#L79).

    Fix: query real iOS notification authorization and keep the user's preference separate from current OS permission.

13. **iOS release configuration is incomplete.**

    iOS uses Google's sample AdMob app/unit IDs even in release, and the Firebase configuration plist is absent. Ads and crash reporting cannot be assessed as the intended production setup. The Firebase failure is caught, so missing configuration is an observability gap rather than necessarily a startup crash.

    References: [sample app ID](../ios/Runner/Info.plist#L42), [iOS ad units](../lib/services/ads_service.dart#L47), [Firebase initialization](../lib/services/firebase_service.dart#L20).

    Fix: provide the intended iOS service configuration, validate consent/privacy controls and a test crash, and complete an iOS release build and device pass.

14. **Privacy policy describes the wrong Firebase service.**

    The live [privacy policy](https://yourmateapps.github.io/pdfhelper/privacy-policy.html), fetched on 4 October, describes Firebase Analytics app-open/screen-view collection. This app depends on Firebase Core and Crashlytics, enables release crash collection, and has no Firebase Analytics dependency. The policy omits Crashlytics and the app's ad privacy controls. Correct the service/data descriptions and consent-choice instructions before publishing. [Google Play's User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311) requires accurate app/SDK data disclosures.

    References: [dependencies](../pubspec.yaml#L61), [Crashlytics collection](../lib/services/firebase_service.dart#L35), [ad privacy controls](../lib/screens/settings_screen.dart#L286).

**Release and verification gaps**

- The native engine and application include uncommitted changes; several native implementation files and application save files are untracked. The successful local artifact includes those changes. Commit the native changes/artifacts in the submodule, update the parent pointer, and verify a clean checkout reproduces the release before distribution. No commits were made by this audit.
- The Android Gradle configuration falls back to a debug signing key when `key.properties` is absent. This does not establish that the current bundle is debug-signed; it means a clean release environment can produce an unpublishable artifact instead of failing. Require the intended signing configuration in a release pipeline.
- Crashlytics upload tasks are opt-in via `-PuploadCrashlytics=true`; this local build does not prove that mappings are available in the production project. Confirm release crash reporting and symbolication separately.
- Play Console approval/declarations, production service ownership and store metadata cannot be established from source. The app declares all-files access, which requires a qualifying use case, declaration and approval under [Play's all-files policy](https://support.google.com/googleplay/android-developer/answer/10467955). Verify actual approval; the unchecked repository checklist is not proof of rejection. Review SDK behavior in the Console's [Data safety declarations](https://support.google.com/googleplay/android-developer/answer/10787469), including advertising and crash reporting.
- No genuine 16 KB device execution, Android 9-or-earlier public-save test, iOS runtime pass, broad low-memory/large-document corpus, or accessibility sweep was completed here. The Android integration test does not exercise camera/gallery permission denial, external sharing targets, or the entire UI.
- The renderer still has acknowledged gaps including JPEG 2000/JBIG2 and some shading/blending/form variants. Warnings should remain visible, and outputs need independent-reader checks. Existing signed PDFs are rewritten by editing operations; displaying a signature appearance is not signature verification.
- The build emits a Firebase plugin Kotlin Gradle migration warning. It does not prevent this build, but should be addressed before a future Flutter upgrade removes compatibility.

**Recommended order**

1. Fix findings 1 and 2 and retain regressions for cancel/delete/rename, including storage permission changes and partial export failures.
2. Repair camera lifecycle, capture illumination and scan cleanup; verify on the connected physical device.
3. Correct or explicitly warn about layer/dash rendering and layer preservation; keep warnings independent of image caching. Compare representative outputs in an independent PDF reader.
4. Complete iOS configuration and runtime work if iOS is part of this release.
5. Finish release-account checks and required platform testing, then build from a clean committed revision and retain logs plus the artifact hash.

Reproduce the main automated checks with `flutter analyze`, `PDF_CORE_LIB_PATH="$PWD/packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib" flutter test`, `cargo test --workspace --offline` from the engine's `rust` directory, `flutter test integration_test/pdf_workflows_test.dart -d <device>`, `flutter build appbundle --release`, and `python3 scripts/check_android_native.py build/app/outputs/bundle/release/app-release.aab`. Review device-test setup before running on a device containing personal documents.

**User-reported viewer follow-up**

**Fixed in source and verified by tests.** The user reported being unable to move more than about one and a half pages while zoomed. The cause was zoom disabling ListView scrolling while InteractiveViewer panned only its viewport-sized child. Recognized vertical drags now move the page list at the current scale, with bounded vertical translation at the document's ends; horizontal panning and two-finger focal-point scaling remain with InteractiveViewer. Vertical fling uses the same document-boundary handling and stops on a new touch. The page counter accounts for the zoom transform.

Three new tests exercise travel to page 6 and back at 2.5x without resetting zoom, fling continuation/interruption, and horizontal pan plus focal-point pinch after scrolling. The multipage test failed before the change with the underlying scroll offset stuck at zero. All 321 Flutter tests pass afterward, including existing double-tap and text-selection checks; final static analysis is clean. No fresh physical-device gesture verification or installation of this fix was performed.

Implementation: [viewer vertical scrolling](../lib/screens/pdf_viewer_screen.dart#L212). Regressions: [viewer gesture tests](../test/screens/pdf_viewer_gesture_test.dart#L190).

Final release artifact: `build/app/outputs/bundle/release/app-release.aab`, rebuilt successfully after the fix. Its packaged native check again passes for all three PDF ABIs and 14 ELF64 libraries. SHA-256: `9463b2324220bb165080bc4fdea7f590f9022a146a1371e73acfe06271e3e00f`. Build log: `/tmp/pdfhelper-final-release-build.log`.
