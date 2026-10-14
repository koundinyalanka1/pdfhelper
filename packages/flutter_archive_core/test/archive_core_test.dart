// Runs the Dart API against the real native library. Point
// ARCHIVE_CORE_LIB_PATH at libarchive_ffi (see scripts/build_engines.sh env).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// CRC-32 (IEEE), for hand-made ZIPs.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A ZIP of stored entries written exactly as given, hostile names and
/// "encrypted" flags included, which no real tool would produce.
List<int> _storedZip(Map<String, List<int>> entries, {int flags = 0}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    final crc = _crc32(data);
    void common(BytesBuilder b) {
      u16(b, 20);
      u16(b, flags | 0x800); // UTF-8 names
      u16(b, 0); // stored
      u16(b, 0);
      u16(b, 0x5865); // 2024-03-05
      u32(b, crc);
      u32(b, data.length);
      u32(b, data.length);
      u16(b, nameBytes.length);
      u16(b, 0);
    }

    u32(out, 0x04034b50);
    common(out);
    out.add(nameBytes);
    out.add(data);
    u32(central, 0x02014b50);
    u16(central, 20);
    common(central);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
  });
  final directory = out.length;
  final directoryBytes = central.takeBytes();
  out.add(directoryBytes);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, directoryBytes.length);
  u32(out, directory);
  u16(out, 0);
  return out.takeBytes();
}

Matcher _throwsCode(String code) =>
    throwsA(isA<ArchiveCoreException>().having((e) => e.code, 'code', code));

void main() {
  final available = ArchiveCore.isAvailable;
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('archive_core_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('explains engine errors as a code and a message', () {
    final error = ArchiveCoreException.fromNative('ENCRYPTED: locked');
    expect(error.code, 'ENCRYPTED');
    expect(error.message, 'locked');
    expect(ArchiveCoreException.fromNative('plain').code, 'ERROR');
    expect(ArchiveFormat.fromCode('tar.gz'), ArchiveFormat.tarGzip);
    expect(ArchiveEntryKind.fromCode('dir'), ArchiveEntryKind.directory);
    expect(const ArchiveSource('/a/b.pdf').toJson(), {'path': '/a/b.pdf'});
  });

  test('loads the native library and reports its version', () {
    expect(ArchiveCore.version, isNotEmpty);
  }, skip: !available);

  test('creates, lists and extracts a ZIP', () async {
    final src = Directory('${dir.path}/src/रिपोर्ट')
      ..createSync(recursive: true);
    File('${src.path}/नोट.txt').writeAsStringSync('नमस्ते ' * 100);
    Directory('${src.path}/empty').createSync();
    final photo = File('${dir.path}/photo.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    final zip = '${dir.path}/bundle.zip';

    final files = await ArchiveCore.createAsync([
      ArchiveSource(src.path),
      ArchiveSource(photo.path, name: 'pictures/beach.jpg'),
      ArchiveSource(photo.path, name: 'pictures/beach.jpg'),
    ], zip);
    expect(files, 3);

    final listing = await ArchiveCore.listAsync(zip);
    expect(listing.format, ArchiveFormat.zip);
    expect(listing.entries.map((e) => e.path), [
      'रिपोर्ट/',
      'रिपोर्ट/empty/',
      'रिपोर्ट/नोट.txt',
      'pictures/',
      'pictures/beach.jpg',
      'pictures/beach (2).jpg',
    ]);
    final folder = listing.entries.first;
    expect(folder.isDir, isTrue);
    expect(folder.name, 'रिपोर्ट');
    expect(folder.canExtract, isFalse);
    final note = listing.entries[2];
    expect(note.kind, ArchiveEntryKind.file);
    expect(note.name, 'नोट.txt');
    expect(note.safePath, 'रिपोर्ट/नोट.txt');
    expect(note.size, utf8.encode('नमस्ते ' * 100).length);
    expect(note.compressedSize, lessThan(note.size));
    expect(note.method, 'deflated');
    expect(note.modified, isNotNull);
    expect(note.modified!.isUtc, isFalse);
    expect(note.canExtract, isTrue);
    expect(listing.entries[4].method, 'stored');

    final one = '${dir.path}/one.txt';
    expect(await ArchiveCore.extractAsync(zip, 2, one), note.size);
    expect(File(one).readAsStringSync(), 'नमस्ते ' * 100);
    expect(
      () => ArchiveCore.extract(zip, 0, one),
      _throwsCode('INVALID_ARGUMENT'),
    );
    expect(() => ArchiveCore.extract(zip, 42, one), _throwsCode('NOT_FOUND'));

    final out = '${dir.path}/out';
    final report = await ArchiveCore.extractAllAsync(zip, out);
    expect(report.skipped, isEmpty);
    expect(report.written, [
      '$out/रिपोर्ट/नोट.txt',
      '$out/pictures/beach.jpg',
      '$out/pictures/beach (2).jpg',
    ]);
    expect(Directory('$out/रिपोर्ट/empty').existsSync(), isTrue);
    expect(File('$out/pictures/beach.jpg').readAsBytesSync(), [
      0xFF,
      0xD8,
      0xFF,
      0xE0,
    ]);

    // Extracting again keeps the first copies.
    final again = ArchiveCore.extractAll(zip, out);
    expect(again.written.first, '$out/रिपोर्ट/नोट (2).txt');
  }, skip: !available);

  test('never writes outside the target folder', () {
    final zip = File('${dir.path}/slip.zip')
      ..writeAsBytesSync(
        _storedZip({
          '../escape.txt': [1],
          '/etc/passwd': [2],
          'C:\\Windows\\win.ini': [3],
          'a\\..\\..\\b.txt': [4],
          '..': [5],
        }),
      );
    final listing = ArchiveCore.list(zip.path);
    expect(listing.entries.map((e) => e.safePath), [
      'escape.txt',
      'etc/passwd',
      'Windows/win.ini',
      'a/b.txt',
      null,
    ]);
    final out = '${dir.path}/inner/target';
    final report = ArchiveCore.extractAll(zip.path, out);
    expect(report.written, hasLength(4));
    for (final path in report.written) {
      expect(path, startsWith('$out/'));
    }
    expect(report.skipped.single.path, '..');
    expect(File('${dir.path}/escape.txt').existsSync(), isFalse);
    expect(Directory('${dir.path}/inner').listSync(), hasLength(1));
  }, skip: !available);

  test('lists password-protected entries but does not extract them', () {
    final zip = File('${dir.path}/locked.zip')
      ..writeAsBytesSync(
        _storedZip({'secret.txt': utf8.encode('scrambled')}, flags: 1),
      );
    final entry = ArchiveCore.list(zip.path).entries.single;
    expect(entry.encrypted, isTrue);
    expect(entry.canExtract, isFalse);
    expect(
      () => ArchiveCore.extract(zip.path, 0, '${dir.path}/secret.txt'),
      _throwsCode('ENCRYPTED'),
    );
    final report = ArchiveCore.extractAll(zip.path, '${dir.path}/out');
    expect(report.written, isEmpty);
    expect(report.skipped.single.reason, contains('password'));
  }, skip: !available);

  test('reads gzip files', () {
    final gz = File('${dir.path}/notes.txt.gz')
      ..writeAsBytesSync(gzip.encode(utf8.encode('hello\n' * 1000)));
    final listing = ArchiveCore.list(gz.path);
    expect(listing.format, ArchiveFormat.gzip);
    final entry = listing.entries.single;
    expect(entry.path, 'notes.txt');
    expect(entry.size, 6000);
    final out = '${dir.path}/notes.txt';
    expect(ArchiveCore.extract(gz.path, 0, out), 6000);
    expect(File(out).readAsStringSync(), 'hello\n' * 1000);
  }, skip: !available);

  test('reports files that are not archives', () async {
    await expectLater(
      ArchiveCore.listAsync('${dir.path}/missing.zip'),
      throwsA(isA<ArchiveCoreException>().having((e) => e.code, 'code', 'IO')),
    );
    final text = File('${dir.path}/notes.txt')..writeAsStringSync('just text');
    expect(() => ArchiveCore.list(text.path), _throwsCode('UNSUPPORTED'));
    final rar = File('${dir.path}/old.rar')
      ..writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0x00]);
    expect(
      () => ArchiveCore.list(rar.path),
      throwsA(
        isA<ArchiveCoreException>().having(
          (e) => e.message,
          'message',
          startsWith('RAR'),
        ),
      ),
    );
    expect(
      () => ArchiveCore.create(const [], '${dir.path}/x.zip'),
      _throwsCode('INVALID_ARGUMENT'),
    );
  }, skip: !available);
}
