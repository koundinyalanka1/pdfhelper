**Production repair tracker — started 4 October, updated 5 October 2026**

**Expanded scope:** the user requested completion of the remaining renderer changes on 5 October. Follow the [renderer completion tracker](RENDERER_COMPLETION_PLAN.md); the audit-repair baseline below does not mean every PDF rendering capability is implemented.

Requested order: bottom viewer banner first, then the production audit fixes in priority order. Independent areas can be implemented in parallel; completed means implemented and verified, not merely reviewed. The original findings remain in [the audit](PRODUCTION_AUDIT_2026-10-04.md).

| Step | Scope / audit findings | Status | Completion evidence |
| --- | --- | --- | --- |
| 0 | Bottom viewer banner; only banner advertising while reading | Verified | Existing consent-aware 320×50 widget below the page viewport; viewer/raster suite: 34 passed |
| 1 | Scan cancel data loss (1) | Verified | Cancel/X/Back retain borrowed originals; included in 16 passing scan/editor/store regressions |
| 2 | Export delete/rename consistency (2) | Verified by automated tests | Linked copies, repeated exports, stale URI protection, save rollback and rename persistence-failure rollback covered; 357-test complete Flutter suite passes |
| 3 | PDF layers, dashed lines, sparse xref output (4, 5, 7) | Verified in native source | 274 Rust unit tests + 1 doctest; CoreGraphics matches dashed-line and hidden-layer results before/after extraction/merge; sparse rewrite 501 → 494 bytes |
| 4 | Preserve warnings for uncached/high-resolution rendering (6) | Verified | Warnings travel with render results at 1800 px even without caching; cache eviction remains bounded; included in 34 passing viewer/raster tests |
| 5 | Camera visibility, flash and scan-file cleanup (8, 9, 10) | Verified by automated tests | 16 scan/editor/store regressions pass, including hidden tab/route/background camera release and late capture cleanup; physical low-light check remains |
| 6 | iOS permissions, external PDF delivery and notifications (3, 11, 12) | Deferred by user | Android is the current release scope |
| 7 | Android production configuration, privacy policy and release checks (14 + audit release gaps) | Signing/policy verified; account checks remain | Signing preflight passes with local credentials and fails safely with missing credentials. User merged/deployed [website PR #1](https://github.com/yourmateapps/yourmateapps.github.io/pull/1); live policy verified 5 October with Crashlytics and ad privacy corrections. iOS configuration (13) deferred |
| 8 | Native Android/macOS rebuilds, full Flutter/Rust suites, Android build verification, final audit update | Audit baseline verified | 357 Flutter tests, clean analyzer; genuine 16 KB runtime PDF/export tests pass. Signed APK/AAB built; 3 PDF ABIs and 14 ELF64 libraries pass static checks; release APK ZIP alignment and viewer smoke pass. Expanded renderer work requires a fresh rebuild |

**Already completed before this repair pass:** zoomed scrolling now traverses the whole document; three gesture regressions pass. The prior final Flutter suite had 321 passing tests and a clean analyzer.

**External release items:** Play Console approvals/declarations and service ownership require real release-account information. They will not be marked complete from source changes alone. No app release upload or account declaration has been performed. The user merged and deployed website PR #1 (`b090fd2d361c071245d994cdbcf3d7a4ea30e2be`); the [live privacy policy](https://yourmateapps.github.io/pdfhelper/privacy-policy.html) was fetched and verified on 5 October.

**Scope update:** the user deferred iOS on 4 October. Step 6 and the iOS portion of steps 7–8 are deferred, not release blockers for the current Android-only repair. Native Android/macOS builds are still required (macOS runs the host tests).

**Remaining compatibility limits:** merges involving incompatible alternate layer configurations fail explicitly instead of changing layer visibility. Environment-dependent layer choices use defaults and warn. Other existing codec/rendering limits still apply. Old scan JPEGs whose ownership was never recorded remain untouched; new sessions use tracked temporary files and cleanup.

**Release signing:** provide `android/key.properties` with `keyAlias`, `keyPassword`, `storeFile` and `storePassword`, or use Gradle's `-PsigningPropertiesFile=/absolute/path/key.properties`. Flutter release builds can use the equivalent environment variable `ORG_GRADLE_PROJECT_signingPropertiesFile`. Release builds never use the debug key as a fallback. Keep credentials out of Git. Debug builds continue to work without release credentials.

**Release crash reporting:** local builds still skip mapping upload. The authorized production pipeline should opt in with `ORG_GRADLE_PROJECT_uploadCrashlytics=true flutter build appbundle --release`, then verify a symbolicated test crash in the intended Firebase project. This repair pass does not publish mappings or send a deliberate production crash.

**Validation on 5 October:** full Flutter suite: 357 passed; analyzer: no issues. The isolated ARM64 Android 16/API 36 emulator `pdfhelper_api36_16kb` (`emulator-5556`) reports `getconf PAGE_SIZE = 16384`. Both packaged native workflow/fidelity tests pass, including merge/extract/rotation/encryption, dash rendering, hidden-layer preservation and sparse rewriting. All 6 Kotlin exporter checks pass against real MediaStore without an all-files grant. Those checks use a debug APK containing the rebuilt release Rust libraries; final release-app validation is recorded separately. The debug instrumentation build also succeeded with a deliberately absent release-signing configuration.
