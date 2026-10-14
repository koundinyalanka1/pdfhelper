// The public Dart API over the Rust archive engine.

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A failure reported by the archive engine.
class ArchiveCoreException implements Exception {
  ArchiveCoreException(this.code, this.message);

  /// Parse the engine's `"CODE: message"`.
  factory ArchiveCoreException.fromNative(String raw) {
    final colon = raw.indexOf(': ');
    if (colon <= 0) return ArchiveCoreException('ERROR', raw);
    return ArchiveCoreException(
      raw.substring(0, colon),
      raw.substring(colon + 2),
    );
  }

  /// Stable code: `IO`, `INVALID_ARGUMENT`, `UNSUPPORTED` (not an archive
  /// this engine reads, or an entry it cannot unpack), `ENCRYPTED` (a
  /// password-protected entry), `CORRUPT`, `TOO_LARGE` (including zip
  /// bombs), `NOT_FOUND`, `PANIC` or `ERROR`.
  final String code;
  final String message;

  @override
  String toString() => 'ArchiveCoreException($code): $message';
}

/// Kinds of archive the engine reads.
enum ArchiveFormat {
  zip('zip', 'ZIP'),
  tar('tar', 'TAR'),
  gzip('gzip', 'GZ'),
  tarGzip('tar.gz', 'TAR.GZ');

  const ArchiveFormat(this.code, this.label);

  /// The engine's name for it.
  final String code;

  /// How to describe it to a person.
  final String label;

  static ArchiveFormat fromCode(String? code) =>
      values.firstWhere((f) => f.code == code, orElse: () => ArchiveFormat.zip);
}

/// What an entry is. Only files and folders are extracted; links could point
/// anywhere, so they are listed but never written.
enum ArchiveEntryKind {
  file('file'),
  directory('dir'),
  symlink('symlink'),
  hardLink('hardlink'),

  /// A device, pipe or socket.
  special('special');

  const ArchiveEntryKind(this.code);

  /// The engine's name for it.
  final String code;

  static ArchiveEntryKind fromCode(String? code) => values.firstWhere(
    (k) => k.code == code,
    orElse: () => ArchiveEntryKind.file,
  );
}

/// One file, folder or link in an archive.
class ArchiveEntry {
  const ArchiveEntry({
    required this.index,
    required this.path,
    required this.name,
    required this.kind,
    required this.size,
    required this.method,
    this.safePath,
    this.compressedSize,
    this.modified,
    this.encrypted = false,
  });

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) => ArchiveEntry(
    index: json['index'] as int? ?? 0,
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    safePath: json['safePath'] as String?,
    kind: ArchiveEntryKind.fromCode(json['kind'] as String?),
    size: json['size'] as int? ?? 0,
    compressedSize: json['compressedSize'] as int?,
    modified: DateTime.tryParse(json['modified'] as String? ?? ''),
    encrypted: json['encrypted'] == true,
    method: json['method'] as String? ?? 'stored',
  );

  /// Position in the listing, which [ArchiveCore.extract] takes.
  final int index;

  /// The name exactly as stored, `/`-separated.
  final String path;

  /// The last part of [path], for showing in a list.
  final String name;

  /// Where [ArchiveCore.extractAll] puts it, relative to the target folder
  /// (before any " (2)" for a clash); null when nothing of the name is
  /// usable, or it names the archive's root folder.
  final String? safePath;
  final ArchiveEntryKind kind;

  /// Uncompressed size in bytes; 0 for folders.
  final int size;

  /// Bytes it takes in the archive, when known (not for the entries of a
  /// `.tar.gz`, which is compressed as a whole).
  final int? compressedSize;

  /// Local time for ZIP entries (ZIP records no time zone), UTC for TAR and
  /// gzip; null when the archive does not say.
  final DateTime? modified;

  /// Protected with a password: listed, but cannot be extracted.
  final bool encrypted;

  /// `stored`, `deflated`, or the name of a method the engine cannot unpack
  /// (`bzip2`, `lzma`, `aes`, `sparse`, ...).
  final String method;

  bool get isDir => kind == ArchiveEntryKind.directory;

  /// Whether [ArchiveCore.extract] can write it.
  bool get canExtract =>
      kind == ArchiveEntryKind.file &&
      !encrypted &&
      (method == 'stored' || method == 'deflated');

  @override
  String toString() => 'ArchiveEntry($index, $path)';
}

/// What an archive holds.
class ArchiveListing {
  const ArchiveListing({
    required this.format,
    required this.entries,
    this.comment = '',
  });

  factory ArchiveListing.fromJson(Map<String, dynamic> json) => ArchiveListing(
    format: ArchiveFormat.fromCode(json['format'] as String?),
    entries: [
      for (final e in (json['entries'] as List? ?? const []))
        ArchiveEntry.fromJson(e as Map<String, dynamic>),
    ],
    comment: json['comment'] as String? ?? '',
  );

  final ArchiveFormat format;
  final List<ArchiveEntry> entries;

  /// The ZIP comment or gzip header comment; usually empty.
  final String comment;
}

/// An entry [ArchiveCore.extractAll] did not write, and why.
class ArchiveSkipped {
  const ArchiveSkipped(this.index, this.path, this.reason);

  final int index;

  /// The entry's name as stored.
  final String path;

  /// A readable explanation, e.g. "'a.txt' is protected with a password".
  final String reason;

  @override
  String toString() => 'ArchiveSkipped($path: $reason)';
}

/// What [ArchiveCore.extractAll] did.
class ArchiveExtraction {
  const ArchiveExtraction({required this.written, required this.skipped});

  factory ArchiveExtraction.fromJson(Map<String, dynamic> json) =>
      ArchiveExtraction(
        written: (json['written'] as List? ?? const []).cast<String>(),
        skipped: [
          for (final s
              in (json['skipped'] as List? ?? const [])
                  .cast<Map<String, dynamic>>())
            ArchiveSkipped(
              s['index'] as int? ?? 0,
              s['path'] as String? ?? '',
              s['reason'] as String? ?? '',
            ),
        ],
      );

  /// Every file written (full paths), in archive order. Folders are not
  /// listed.
  final List<String> written;
  final List<ArchiveSkipped> skipped;
}

/// A file or folder to put in a new ZIP.
class ArchiveSource {
  const ArchiveSource(this.path, {this.name});

  final String path;

  /// Its name inside the archive (`docs/a.pdf`); null uses the file or
  /// folder's own name.
  final String? name;

  Map<String, dynamic> toJson() => {
    'path': path,
    if (name != null) 'name': name,
  };
}

T _withStrings<T>(List<String?> values, T Function(List<Pointer<Utf8>>) body) {
  final pointers = [
    for (final value in values) value == null ? nullptr : value.toNativeUtf8(),
  ];
  try {
    return body(pointers);
  } finally {
    for (final p in pointers) {
      if (p != nullptr) malloc.free(p);
    }
  }
}

ArchiveCoreException _lastError(ArchiveBindings b) =>
    ArchiveCoreException.fromNative(b.lastError().toDartString());

String _takeString(ArchiveBindings b, Pointer<Utf8> ptr) {
  if (ptr == nullptr) throw _lastError(b);
  try {
    return ptr.toDartString();
  } finally {
    b.freeString(ptr);
  }
}

int _checked(ArchiveBindings b, int result) {
  if (result < 0) throw _lastError(b);
  return result;
}

/// Entry points of the archive engine: browse, extract and create ZIP
/// files, and browse and extract `.tar`, `.gz` and `.tar.gz`.
///
/// Every call names the archive by path and opens it afresh; there is
/// nothing to close. The plain calls block, so use the `Async` versions,
/// which run on a background isolate, from the UI.
class ArchiveCore {
  ArchiveCore._();

  /// Whether the native library could be loaded.
  static bool get isAvailable {
    try {
      ArchiveBindings.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The engine's version, or null when it cannot be loaded.
  static String? get version {
    try {
      return ArchiveBindings.instance.version().toDartString();
    } catch (_) {
      return null;
    }
  }

  /// What the archive at [path] holds. Throws [ArchiveCoreException]:
  /// `UNSUPPORTED` when it is not a ZIP, TAR or GZ file (RAR and 7-Zip are
  /// named in the message), `TOO_LARGE` for a zip bomb or a ZIP over
  /// 512 MB, `CORRUPT` when it is damaged.
  static ArchiveListing list(String path) {
    final b = ArchiveBindings.instance;
    final json = _withStrings([path], (p) => _takeString(b, b.listJson(p[0])));
    return ArchiveListing.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// Extract entry [index] to [outPath], replacing that file atomically.
  /// Returns the number of bytes written. Throws `ENCRYPTED` for a
  /// password-protected entry, `UNSUPPORTED` for a link or an unsupported
  /// method, and `INVALID_ARGUMENT` for a folder.
  static int extract(String path, int index, String outPath) {
    final b = ArchiveBindings.instance;
    return _withStrings([
      path,
      outPath,
    ], (p) => _checked(b, b.extract(p[0], index, p[1])));
  }

  /// Extract everything into the folder [outDir], creating it if needed.
  /// Nothing is written outside [outDir], files already there are kept (a
  /// new file whose name is taken becomes `name (2).ext`), and links,
  /// password-protected and damaged entries are skipped and reported.
  /// Throws only when the archive cannot be read or the folder written.
  static ArchiveExtraction extractAll(String path, String outDir) {
    final b = ArchiveBindings.instance;
    final json = _withStrings([
      path,
      outDir,
    ], (p) => _takeString(b, b.extractAllJson(p[0], p[1])));
    return ArchiveExtraction.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// Write a ZIP of [sources] to [outPath], atomically. Folders are added
  /// with everything in them; clashing names are numbered. Entries are
  /// stamped in [utcOffset]'s local time (the phone's by default), as ZIP
  /// expects. Returns the number of files packed.
  static int create(
    List<ArchiveSource> sources,
    String outPath, {
    Duration? utcOffset,
  }) {
    final b = ArchiveBindings.instance;
    final request = jsonEncode({
      'sources': [for (final s in sources) s.toJson()],
      'utcOffsetMinutes':
          (utcOffset ?? DateTime.now().timeZoneOffset).inMinutes,
    });
    return _withStrings([
      request,
      outPath,
    ], (p) => _checked(b, b.create(p[0], p[1])));
  }

  /// [list] on a background isolate.
  static Future<ArchiveListing> listAsync(String path) =>
      Isolate.run(() => list(path));

  /// [extract] on a background isolate.
  static Future<int> extractAsync(String path, int index, String outPath) =>
      Isolate.run(() => extract(path, index, outPath));

  /// [extractAll] on a background isolate.
  static Future<ArchiveExtraction> extractAllAsync(
    String path,
    String outDir,
  ) => Isolate.run(() => extractAll(path, outDir));

  /// [create] on a background isolate.
  static Future<int> createAsync(
    List<ArchiveSource> sources,
    String outPath, {
    Duration? utcOffset,
  }) {
    final offset = utcOffset ?? DateTime.now().timeZoneOffset;
    return Isolate.run(() => create(sources, outPath, utcOffset: offset));
  }
}
