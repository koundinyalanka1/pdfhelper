# flutter_archive_core

DocHelper's archive engine, written from scratch in Rust and called from
Dart through `dart:ffi`. One of DocHelper's per-format libraries (see
`PLAN.md` in the app repository).

- Browses, extracts and creates ZIP files: stored and deflated entries,
  ZIP64, UTF-8 and old DOS (CP437) names, self-extracting archives.
- Browses and extracts `.tar` (POSIX ustar and pax, GNU long names), `.gz`
  (several members, the original file name from the header) and `.tar.gz`.
- Safe with archives from anywhere: names are reduced to plain relative
  paths (no `..`, no absolute paths or drive letters, `\` read as a folder
  separator, characters memory cards reject replaced), so nothing lands
  outside the target folder; links are listed but never written; a file
  already there is never replaced (the new one becomes `name (2).ext`);
  every file is written atomically and checked against its CRC-32.
- Zip bombs are refused before anything is written: limits on the number of
  entries, the total size and how many times an archive expands.
- Password-protected entries are listed and flagged; extracting one fails
  with `ENCRYPTED`. RAR, 7-Zip, bzip2 and xz files are recognised and
  named in the error.

```dart
final listing = await ArchiveCore.listAsync('/path/backup.zip');
for (final entry in listing.entries) {
  print('${entry.path} ${entry.size} ${entry.modified}');
}
await ArchiveCore.extractAsync('/path/backup.zip', 3, '/cache/preview.pdf');
final report = await ArchiveCore.extractAllAsync('/path/backup.zip', '/path/backup');
print('${report.written.length} files; skipped ${report.skipped}');
await ArchiveCore.createAsync([
  const ArchiveSource('/path/Photos'),
  const ArchiveSource('/path/notes.txt', name: 'docs/notes.txt'),
], '/path/bundle.zip');
```

## Layout

| Path | What |
| --- | --- |
| `rust/crates/archive_core` | the engine: ZIP (over `doc_zip`), TAR, gzip, safe extraction, creation |
| `rust/crates/archive_ffi` | the Rust FFI layer (`archive_*` functions, exported `extern "C"` for `dart:ffi`) |
| `lib/` | the Dart API |

Shared building blocks (ZIP container, FFI plumbing) come from
`packages/doc_common`.

## Limits

ZIP files are read through `doc_zip`, which holds the archive in memory, so
ZIPs over 512 MB are refused (`TOO_LARGE`), and `create` packs at most 512
MB of files. Each entry is inflated as a stream, so it never has to fit in
memory. TAR and gzip files are streamed and have no such limit. An entry may
be up to 4 GB and an archive may expand to 16 GB; anything that expands
more than 100 times its size past 256 MB is treated as a zip bomb.

## Building and testing

```bash
bash scripts/build_engines.sh macos --only archive     # host library for tests
bash scripts/build_engines.sh android --only archive   # jniLibs for the app
(cd packages/flutter_archive_core/rust && cargo test)
(cd packages/flutter_archive_core/rust && cargo run --release --example archivecli -- list some.zip)
ARCHIVE_CORE_LIB_PATH=$PWD/packages/flutter_archive_core/macos/Frameworks/libarchive_ffi.dylib \
  flutter test packages/flutter_archive_core
```

On Linux, `cargo build --release` in `rust/` leaves
`rust/target/release/libarchive_ffi.so` for `ARCHIVE_CORE_LIB_PATH`.
