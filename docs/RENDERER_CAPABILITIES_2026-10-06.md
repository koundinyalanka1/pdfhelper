# Renderer capabilities and limitations — 6 October 2026

This is a fresh baseline of the renderer in the current working tree. The targeted renderer expansion and receipt-layout repair are implemented. The engine does not support every PDF feature, and an absence of render warnings does not prove that a page is reproduced faithfully.

Use the [application baseline](APP_BASELINE_2026-10-06.md) for the app's current scope and the [production audit](PRODUCTION_AUDIT_2026-10-06.md) for release evidence, artifact identity and outstanding release checks. This document describes capabilities and compatibility boundaries; it does not replace release approval or device testing.

## Rendering architecture

The app uses the Rust engine in the `packages/flutter_pdf_core` Git submodule. The renderer parses PDF content operators and paints page content into an RGBA bitmap. It uses standalone image codecs for compressed pictures; these codecs do not replace the PDF parser or page renderer.

The primary entry point is [`pdf_render/src/page.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page.rs). It resolves inherited page properties, prefers CropBox over MediaBox, applies page rotation, renders page content, and draws annotation appearances. A page result contains pixels and a warning list. If every page content stream fails to decode, the renderer returns an error instead of treating an empty white page as successful content.

Page rasterization has no independent view of the Flutter viewer's current display zoom. The viewer scales the page bitmap. This matters for display-dependent annotation flags such as NoZoom.

## Implemented capability matrix

“Implemented” describes supported code paths. It does not promise exact rendering of every combination, malformed document or resource-intensive input.

| Area | Current capability | Principal implementation |
| --- | --- | --- |
| Page geometry | CropBox/MediaBox selection, normal quarter-turn page rotations, transforms and clipping | `pdf_render/src/page.rs` |
| Paths | Fill, even-odd fill, stroke, dash pattern/phase, line caps, joins, miter limits and device hairlines | `page_strokes.rs`, `canvas.rs`, `geom.rs` |
| Text | Embedded TrueType, CFF and applicable OpenType outlines; substitute fonts; simple encodings and ToUnicode mappings; common Identity-H CID fonts | `font/mod.rs`, `pdf_text/src/font.rs` |
| Text paint | Fill, stroke, fill/stroke, invisible and clipping rendering modes 0–7; text clipping accumulates until ET | `page.rs`, `page_text.rs` |
| Text metrics | Explicit widths, indirect CID width arrays, CID default width, descriptor MissingWidth and text-spacing operators | `pdf_text/src/font.rs`, `font/mod.rs` |
| Image data | JPEG, CCITT Group 3/4, JPEG 2000, JBIG2 with JBIG2Globals, raw component images, indexed palettes, stencil and soft masks | `image.rs`, `image_codecs.rs`, `ccitt.rs` |
| Patterns | Coloured/uncoloured tiling patterns and shading patterns, including a shading pattern's ExtGState | `page_paints.rs` |
| Shadings | Function-based, axial, radial, triangle/lattice meshes, Coons patches and tensor patches: types 1–7, within supported colour spaces | `page_paints.rs`, `page_mesh.rs` |
| PDF functions | Sampled, exponential, stitching and calculator functions: types 0, 2, 3 and 4, within evaluator limits | `page_functions.rs` |
| Transparency | All 16 standard PDF blend modes; isolated/non-isolated Form groups; knockout groups; alpha-is-shape; alpha/luminosity soft masks and transfer functions | `blend.rs`, `canvas.rs`, `page_forms.rs` |
| Group colour | DeviceRGB and DeviceGray blend spaces, inherited group space and explicit overrides | `canvas.rs`, `page_forms.rs` |
| Text knockout | TK true/default and TK false behavior, graphics-state restoration, and fill/stroke glyph composition | `page_text.rs` |
| Optional content | Default screen layer state, OCG/OCMD policies and visibility expressions, applicable View usage state; painting suppressed inside hidden content | `page_optional_content.rs` |
| Annotations | Normal appearance streams fitted to Rect; appearance state selection; hidden/no-view handling; NoRotate; common missing-appearance fallbacks | `page_annotations.rs` |
| AcroForm display | Inherited field values/resources and appearance streams; fallback text, choice/list/combo, checkbox, radio and push-button artwork | `page_annotations.rs` |

The default RGB output is intended for on-screen viewing. DeviceCMYK conversion does not provide colour-managed print proofing.

## Specific repairs represented by this baseline

### Receipt text spacing

The reported receipt used an indirect array inside a CID font's `/W` entry. The previous width loader discarded that array, so proportional glyphs advanced using the default width and collided with separately positioned text runs. Width parsing now resolves those nested references and numeric values. Rendering and text-selection geometry share the corrected metrics.

The [synthetic receipt regression](../packages/flutter_pdf_core/rust/crates/pdf_render/tests/font_widths.rs) exercises a serialized and reopened document. Direct and indirect width arrays must produce identical page pixels and selection layout, and glyph positions must match expected advances. This fixture contains no private receipt data. Related font tests cover default-width precedence and MissingWidth.

### Text knockout and combined fill/stroke

Text objects now preserve the initial backdrop required by TK behavior. Overlapping translucent glyphs behave differently with TK true and false. Alpha, masks and blend mode are applied to glyphs without being applied again when the text group closes. Fill/stroke glyphs are composed as one knockout object where required, including when TK is false.

The [text regression suite](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page_text_tests.rs) covers overlapping glyphs, separate text objects, q/Q restoration, graphics-state changes inside BT/ET, an opaque glyph followed by a translucent glyph, fill/stroke overlap, blend mode, soft masks and an unterminated text object.

### DeviceGray transparency groups

DeviceGray groups convert incoming RGB sources before blending and convert the resulting group back into the parent space. Nested groups inherit the active blend space unless they explicitly select a different supported space. Tests are in [`page_transparency_tests.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page_transparency_tests.rs).

This repair does not add ICC, Lab, Separation or general CMYK transparency-group compositing. Other declared group spaces still use an RGB approximation and produce a warning.

### Live masks and temporary memory

The offscreen budget now counts masks still held by saved graphics states, including masks that survive beyond the operation that created them. Shared masks are tracked by allocation rather than counted once for every reference. When clipping would exceed the budget, subsequent painting stops and a warning is returned; continuing with an older, wider clip could otherwise paint outside the document's requested bounds.

Implementation and regression coverage are in [`page_limits.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page_limits.rs). This supplements the image-codec and recursive-content limits below.

## Known limitations with explicit warning paths

| Feature or condition | Current behavior |
| --- | --- |
| XFA forms | XFA content is unsupported; available AcroForm appearances are shown. |
| Annotation NoZoom | Warns that the page raster scales with the viewer; does not implement a screen-fixed annotation layer. |
| Missing widget appearances | Uses approximate value/layout artwork where possible. Unsupported field types without appearances are reported. |
| Rich FreeText without a usable appearance | Uses plain Contents rather than reproducing rich text styling. |
| Cloudy annotation borders | Uses the underlying geometric outline. |
| Generated annotation icons | Uses approximate artwork when a usable appearance stream is absent. |
| Unsupported annotation type without an appearance | Reports that an appearance must be regenerated in a fuller PDF editor. |
| Ambiguous radio fallback state | Reports when no appearance state permits a reliable checked-state decision. |
| Transparency group spaces other than DeviceRGB/DeviceGray | Converts to RGB and reports possible colour differences. |
| Shadings outside DeviceGray/RGB/CMYK | Skips the shading and reports the unsupported colour space. |
| Pattern-coloured stencil images | Skips this paint combination with a warning. |
| Environment-dependent optional-content usage | Shows the default layer state and warns; no dynamic zoom/language/user layer evaluation is provided. |
| Unsupported content operators | Reports possible appearance differences. |
| Unusable image data or a rejected top-level image decode | Skips the image and reports a decode warning. The message does not distinguish every codec failure from every resource limit. |
| Excessive form recursion, graphics-state nesting, pattern density, mesh/function work, dash detail or temporary memory | Rejects or skips the affected detail with a warning; clipping-memory exhaustion stops subsequent painting. |

Font substitution is reported, but it may still change glyph shape or coverage. Displaying a signature appearance is visual rendering only: it does not verify cryptographic validity, signer identity or document integrity. Interactive form editing, JavaScript execution and annotation actions are not supplied by these visual fallbacks.

## Known gaps without comprehensive warning coverage

These are concrete limits visible in the current implementation. They must not be described as completely handled merely because a page renders without warnings.

| Gap | Current behavior and evidence |
| --- | --- |
| Vertical writing | Identity-V is recognized as two-byte codes, but text advances remain horizontal; vertical W2/DW2 metrics are not implemented. `pdf_text/src/font.rs`, `pdf_render/src/page.rs`. |
| Arbitrary composite-font encoding CMaps | The decoder supports common Identity-H/ToUnicode cases, not general custom code-to-CID mapping or variable code widths. No dedicated compatibility warning covers all such fonts. `pdf_text/src/font.rs`, `font/mod.rs`. |
| Type3 glyph programs | CharProcs are not executed. The font loader may substitute a face and issue only a generic font warning. That substitute cannot reproduce arbitrary Type3 artwork. `font/mod.rs`. |
| ICC/calibrated/Lab image colours | ICCBased is interpreted by component count; CalRGB/Lab use RGB-like values and CalGray uses gray. Profile/calibration conversion is not applied or specifically warned. `image.rs`. |
| Separation/DeviceN image colours | Uses an approximate grayscale ink-coverage conversion instead of evaluating the alternate space and tint transform. `image.rs`. |
| General vector colour spaces | ColorSpace selection tracks component counts; this is not full palette, profile, calibrated or tint-transform interpretation for vector paints. `page.rs`. |
| Overprint and advanced ExtGState entries | OP/op/OPM, graphics transfer functions, halftones, black-generation/undercolour-removal and rendering-intent settings are not implemented by the ExtGState handler. `page.rs`. |
| Rendering-intent and flatness content hints | ri and i operators are explicitly ignored without warnings. `page.rs`. |
| Page-level transparency Group | The page entry point does not apply the page's Group dictionary; implemented group handling is for Form XObjects. `page.rs`, `page_forms.rs`. |
| Failed nested image soft masks | A corrupt, cyclic or over-limit soft mask may be ignored while the base image remains drawable, without a separate warning. `image.rs`. |
| Less common annotation fallback details | Geometric fallbacks do not cover every optional field, such as line captions and leader-line settings. Not every ignored detail has a warning. `page_annotations.rs`. |
| Missing or unknown XObjects | Some absent resources or unrecognized XObject subtypes return without a warning. `page.rs`. |

Generated missing-appearance artwork is a viewing aid, not a complete appearance-generation implementation. Existing valid appearance streams generally provide a stronger fidelity path than reconstructing artwork from field or annotation dictionaries.

## Resource bounds and their practical meaning

| Resource | Current bound or handling |
| --- | --- |
| Page bitmap | Caller-supplied max_pixels, default 32,000,000 pixels. Dimensions are checked before allocation. |
| Offscreen rendering and retained masks | 128 MiB shared temporary budget per renderer, including live saved-state masks. |
| Decoded image area | 64,000,000 pixels per image. |
| Image relationships | Mask recursion bounded to eight image levels; colour-space recursion to 16 levels; at most 32 image colour components. |
| JPX/JBIG2 compressed inputs | Adapter checks 32 MiB payload limits. |
| JPEG 2000 samples | 32,000,000 decoded component samples; tile/framing and decoder-internal precinct/packet/storage limits also apply. |
| JBIG2 | Segment/reference/symbol and explicit region checks, plus a vendored 128 MiB cumulative large-buffer allocation budget per decoded image. |
| Form/pattern/function recursion | Bounded depth and work limits in the corresponding interpreters. |
| Dash detail, calculator functions and meshes | Bounded iteration/evaluation/tessellation work; excessive detail is rejected. |

These bounds apply to particular structures or rendering stages. They are not a hard cap on application RSS, total decoding time, all document allocations or concurrent work. The page bitmap, image buffers, parser state and app caches also consume memory. Large documents may legitimately lose detail or fail within these limits on a phone.

See [`image_codecs.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/image_codecs.rs), [`image.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/image.rs), [`page_limits.rs`](../packages/flutter_pdf_core/rust/crates/pdf_render/src/page_limits.rs) and the [vendored-codec notes](../packages/flutter_pdf_core/rust/vendor/README.md) for exact checks.

## Codec provenance and maintenance

JPEG 2000 uses vendored `hayro-jpeg2000` 0.4.1 and JBIG2 uses vendored `hayro-jbig2` 0.3.1, with `hayro-ccitt` 0.4.0 as a dependency. These are standalone image-codec components. SIMD and image-crate integrations are disabled for the current native configuration.

The codec licenses are MIT OR Apache-2.0. Full redistribution texts are retained under [`pdf_render/licenses`](../packages/flutter_pdf_core/rust/crates/pdf_render/licenses/README.md); the JPEG 2000 ICC assets and their CC0 license remain in the vendored assets directory. These notices supplement the other project/font/dependency licenses.

Local resource hardening is material to this baseline. It includes fallible bitmap growth/cloning and accounting in JBIG2, plus JPEG 2000 precinct/code-block/layer/packet allocation checks. An upstream version upgrade must preserve or replace these guards and rerun their regression cases. Replacing the vendored sources with unmodified registry versions would change the security and memory assumptions recorded here.

## Validation snapshot and boundaries

The final validation snapshot supplied for this baseline is **351 passing Rust tests: 348 unit, one integration and two documentation tests**, plus **357 passing Flutter tests against the final native libraries**. The production audit owns the precise commands, logs, package checks and artifact identities.

The native coverage includes the synthetic receipt widths/layout fixture, text knockout and text clipping, transparency groups and masks, DeviceGray groups, retained-mask accounting, annotation/widget fallbacks, shadings/functions/meshes, codecs and codec resource-limit regressions. Passing these tests demonstrates the covered cases; it does not certify every PDF feature or file.

There is **no fresh physical-phone or 16 KiB-page Android runtime verification of the final native revision** in this snapshot. Earlier device or emulator observations must not be presented as verification of later library changes. The user elected to perform the phone checks personally. See the [production audit](PRODUCTION_AUDIT_2026-10-06.md) for the release decision and remaining operational checks.

## How to use this baseline

For renderer regressions, preserve a minimal synthetic PDF when possible, assert both pixels and text geometry when relevant, and distinguish a code fix from a rebuilt library or tested application package. Keep private customer PDFs out of committed fixtures.

For compatibility planning, use the two limitations tables above. Completing the targeted repair pass does not close the remaining custom-CMap, Type3, colour-management, overprint, page-group or warning-coverage work. Features requiring display context or interactive editing also need changes beyond the page rasterizer.
