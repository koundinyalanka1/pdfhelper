**Renderer completion pass — 5 October 2026**

The user expanded the repair scope after the original audit fixes passed. This pass implements the remaining documented rendering capabilities; a warning alone is not treated as feature completion. Existing warnings remain for damaged input, bounded-resource limits and features that require additional viewer architecture.

| Area | Work | Status / evidence |
| --- | --- | --- |
| Image codecs | JPEG 2000/JPX and JBIG2, including shared globals, palette/alpha/filter chains and allocation limits | Implemented; 22 image tests plus 6 vendor tests pass |
| Shading/functions | Types 1–7, sampled/calculator functions, pattern graphics state, packed mesh continuation | Implemented; focused regressions and combined native suite pass |
| Transparency | 16 blend modes, alpha/luminosity masks with TR, isolated/nonisolated/knockout groups and AIS | Implemented; numerical and independent-reader checks; advanced group colour spaces warn |
| Annotations/forms | Geometric/text/icon fallbacks, widget rotation, comb, choices, buttons, font widths and borders | Implemented; 9 targeted regressions; generated artwork explicitly approximate |
| Stroke/text paint | Cap/join/miter geometry; text modes 0–7, delayed ET clipping; indirect width arrays | Implemented; raster, pixel-equivalence and selection-layout regressions pass |
| Validation | Independent-reader fixtures, native/Flutter regressions, Android/macOS rebuilds and genuine 16 KB execution | Pending updated engine |

Annotation `NoZoom` requires the viewer's display zoom and density, which a page-bitmap-only renderer does not receive. Native output alone cannot establish correct fixed-screen-size annotations during Flutter texture zoom. Digital-signature verification and interactive form editing are separate features.

**Verified baseline before this expansion:** 357 Flutter tests, clean analyzer, 274 Rust tests + 1 doctest, 2 packaged PDF tests and 6 real MediaStore checks on Android 16 with `PAGE_SIZE=16384`. The signed release APK opens an eight-page PDF, renders dashed lines, displays the approximation warning, and shows the bottom test banner on that emulator. APK ZIP/native checks and AAB native checks pass. These artifacts predate this renderer completion pass:

- AAB SHA-256: `65954067ec8767548f6c9557f459c744ddf2cd0515c6d54444a9213cdc782b0b`.
- APK SHA-256: `e64d1d1bfbd8732f4b77b21726c8103a3704fd7d0b627c25c12c76ccc17165eb`.

The user merged/deployed the corrected privacy policy, verified live on 5 October. iOS remains deferred.

**Receipt investigation:** The locally supplied receipt reproduces the reported widely spaced/overlapping text. Its Type0 font stores CID widths in an indirect nested `/W` array. The parser ignored that referenced array and fell back to `/DW 1000` for every glyph, although the declared widths differ. A synthetic regression covers indirect width arrays without storing the user's financial document in the repository. Visual comparison of the corrected renderer against an independent reader is pending.

**Receipt visual check:** The corrected native output (893 × 1263) now has normal character spacing and agrees with CoreGraphics on text positions and field clipping. Mean absolute RGB difference was 2.03/255 over the page; differences include raster antialiasing. This is a local comparison, not a claim of pixel-identical rendering. The source PDF is kept outside the repository.

**Transparency reference checks:** Hand-authored fixtures exercise group opacity, isolation, knockout/AIS, alpha/luminosity masks with inverted transfer functions, and three stroke joins. PDFium agrees on group opacity/isolation, mask transfer values and stroke geometry. MuPDF agrees on opacity knockout; PDFium and CoreGraphics disagree on that case. MuPDF disagrees on inverted alpha outside the group bounds, while PDFium agrees with the explicit ISO 32000-1 §11.6.5.2 rule. Knockout/AIS and outside-mask tests therefore also assert the specification's numerical results instead of treating a single reader as authoritative. Nested knockout backdrops follow §11.4.6.

**Combined source validation:** 332 unit tests + 1 font-width integration test + 2 doctests pass, including the vendored codec tests (335 total). Flutter analysis is clean. Retained soft masks share a conservative per-page allocation budget; graphics-state nesting and recursive forms/masks are bounded.

**Packaged engine validation:** all 357 Flutter tests pass against the rebuilt macOS library. All 3 Android integration tests pass on the connected Motorola edge 70 fusion (`getconf PAGE_SIZE=4096`), including synthetic receipt-width equivalence, group opacity, luminosity masks and calculator shading. Native libraries rebuilt for universal macOS and Android arm64/armv7/x86_64. Actual 16 KB runtime evidence above is the earlier baseline; the expanded build has not yet run on a 16 KB device.
