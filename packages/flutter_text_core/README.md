# flutter_text_core

DocHelper's plain-text engine, written from scratch in Rust and called from
Dart through `dart:ffi`. One of DocHelper's per-format libraries (see
`PLAN.md` in the app repository).

- Detects and decodes UTF-8, UTF-16, UTF-32 and the common single-byte code
  pages; saves back in the same encoding, byte-order mark and line endings,
  or converts them on request.
- Warns before saving characters an encoding cannot hold.
- Re-reads an unedited file in another encoding when the guess was wrong.
- Pages through very large files by line.
- Find and replace (match case, whole words), with UTF-16 offsets for Dart.
- Validates and re-indents JSON without reordering keys or rewriting numbers.

```dart
final doc = await TextCore.open('/path/notes.txt');
final info = doc.info();            // encoding, line endings, lines, ...
doc.setText(doc.text.replaceAll('teh', 'the'));
doc.setFormat(lineEnding: LineEnding.crlf);
await doc.save('/path/notes.txt');  // atomic
doc.close();
```

## Layout

| Path | What |
| --- | --- |
| `rust/crates/text_core` | the engine: documents, encodings, search, JSON |
| `rust/crates/text_ffi` | the Rust FFI layer (`text_*` functions, exported `extern "C"` for `dart:ffi`) |
| `lib/` | the Dart API |

Shared building blocks (encodings, FFI plumbing) come from
`packages/doc_common`.

## Building and testing

```bash
bash scripts/build_engines.sh macos --only text     # host library for tests
bash scripts/build_engines.sh android --only text   # jniLibs for the app
(cd packages/flutter_text_core/rust && cargo test)
TEXT_CORE_LIB_PATH=$PWD/packages/flutter_text_core/macos/Frameworks/libtext_ffi.dylib \
  flutter test packages/flutter_text_core
```
