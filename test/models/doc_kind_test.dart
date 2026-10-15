import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/doc_kind.dart';
import 'package:pdfhelper/utils/format_utils.dart';

void main() {
  test('kinds come from extensions, case-insensitively', () {
    expect(DocKind.ofPath('/a/Report.PDF'), DocKind.pdf);
    expect(DocKind.ofPath('letter.docx'), DocKind.word);
    expect(DocKind.ofPath('old.DOC'), DocKind.word);
    expect(DocKind.ofPath('writer.wps'), DocKind.word);
    expect(DocKind.ofPath('calc.ods'), DocKind.sheet);
    expect(DocKind.ofPath('wps sheet.et'), DocKind.sheet);
    expect(DocKind.ofPath('list.csv'), DocKind.sheet);
    expect(DocKind.ofPath('talk.pptx'), DocKind.slides);
    expect(DocKind.ofPath('show.dps'), DocKind.slides);
    expect(DocKind.ofPath('notes.txt'), DocKind.text);
    expect(DocKind.ofPath('photo.jpeg'), DocKind.image);
    expect(DocKind.ofPath('bundle.zip'), DocKind.archive);
    expect(DocKind.ofPath('Makefile'), DocKind.other);
    expect(DocKind.ofPath('.hidden'), DocKind.other);
    expect(DocKind.ofPath('trailing.'), DocKind.other);
  });

  test('the Files tab lists documents and ZIP files, not code or photos', () {
    for (final name in [
      'a.pdf', 'a.docx', 'a.xlsx', 'a.pptx', 'a.odt', 'a.fods', 'a.txt',
      'a.md', 'a.csv', 'a.zip', 'A.ZIP',
    ]) {
      expect(DocKind.isListed(name), isTrue, reason: name);
    }
    for (final name in [
      'a.json', 'a.py', 'a.jpg', 'a.png', 'a.heic', 'a.tar', 'a.tar.gz',
      'a.tgz', 'a.7z', 'a.rar', 'a', 'a.bin',
    ]) {
      expect(DocKind.isListed(name), isFalse, reason: name);
    }
    expect(
      DocKind.importExtensions,
      containsAll(['pdf', 'docx', 'xlsx', 'txt', 'fodt', 'zip']),
    );
    for (final extension in ['jpg', 'tar', 'gz', '7z', 'rar']) {
      expect(DocKind.importExtensions, isNot(contains(extension)));
    }
  });

  test('the Files tab filters by every listed kind', () {
    expect(DocKind.filterable, [
      DocKind.pdf,
      DocKind.word,
      DocKind.sheet,
      DocKind.slides,
      DocKind.text,
      DocKind.archive,
    ]);
    expect(DocKind.archive.label, 'Archive');
    expect(DocKind.archive.pluralLabel, 'archives');
  });

  test('which files DocHelper opens itself', () {
    for (final name in [
      'a.pdf', 'a.txt', 'a.docx', 'a.doc', 'a.wps', 'a.fodt', 'a.xlsx',
      'a.xls', 'a.fods', 'a.pptx', 'a.ppt', 'a.FODP', 'a.jpg', 'a.jpeg',
      'a.png', 'a.webp', 'a.gif', 'a.bmp', 'a.heic', 'a.heif', 'a.zip',
      'a.tar', 'a.gz', 'a.tgz', 'backup.tar.gz',
    ]) {
      expect(DocKind.canOpenPath(name), isTrue, reason: name);
    }
    // 7-Zip and RAR are archives another app has to open.
    for (final name in ['a.7z', 'a.rar', 'Makefile', 'a.bin']) {
      expect(DocKind.canOpenPath(name), isFalse, reason: name);
    }
    expect(DocKind.ofPath('a.tgz'), DocKind.archive);
    expect(DocKind.ofPath('a.7z'), DocKind.archive);
    expect(DocKind.image.canOpen, isTrue);
    expect(DocKind.archive.canOpen, isTrue);
    expect(DocKind.other.canOpen, isFalse);
  });

  test('titles drop known extensions only', () {
    expect(DocKind.titleOf('Budget 2026.xlsx'), 'Budget 2026');
    expect(DocKind.titleOf('v1.2 notes.txt'), 'v1.2 notes');
    expect(DocKind.titleOf('archive.tar.bin'), 'archive.tar.bin');
    expect(DocKind.titleOf('README'), 'README');
  });

  test('content settles PDFs and containers by name', () {
    final pdf = '%PDF-1.7\n'.codeUnits;
    final zip = [0x50, 0x4B, 0x03, 0x04, 0, 0];
    final ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    expect(DocKind.sniff(pdf), DocKind.pdf);
    expect(DocKind.sniff([...'junk'.codeUnits, ...pdf]), DocKind.pdf);
    expect(DocKind.sniff(zip, name: 'a.docx'), DocKind.word);
    expect(DocKind.sniff(zip, name: 'a.zip'), DocKind.archive);
    expect(DocKind.sniff(zip), DocKind.archive);
    expect(DocKind.sniff(ole, name: 'a.xls'), DocKind.sheet);
    expect(DocKind.sniff(ole), isNull);
    expect(DocKind.sniff('{\\rtf1\\ansi'.codeUnits), DocKind.word);
    expect(DocKind.sniff([0xFF, 0xD8, 0xFF, 0xE0]), DocKind.image);
    expect(DocKind.sniff('plain words'.codeUnits), isNull);
  });

  test('content settles gzip and TAR archives', () {
    expect(DocKind.sniff([0x1F, 0x8B, 0x08, 0x00, 0, 0]), DocKind.archive);
    expect(
      DocKind.sniff([0x1F, 0x8B, 0x08, 0x00], name: 'backup.tar.gz'),
      DocKind.archive,
    );
    // TAR's magic follows the first entry's name and sizes.
    final tar = List<int>.filled(1024, 0)
      ..setAll(0, 'report.pdf'.codeUnits)
      ..setAll(257, 'ustar\x0000'.codeUnits)
      // The entry is a PDF, within the kilobyte a PDF header is looked for.
      ..setAll(512, '%PDF-1.7\n'.codeUnits);
    expect(DocKind.sniff(tar), DocKind.archive);
    final gnu = List<int>.filled(512, 0x20)..setAll(257, 'ustar  \x00'.codeUnits);
    expect(DocKind.sniff(gnu), DocKind.archive);
    // Too short to reach the magic.
    expect(DocKind.sniff(tar.sublist(0, 260)), isNull);
  });

  test('content settles WebP and BMP pictures', () {
    final webp = [...'RIFF'.codeUnits, 0x24, 0, 0, 0, ...'WEBPVP8 '.codeUnits];
    expect(DocKind.sniff(webp), DocKind.image);
    final wave = [...'RIFF'.codeUnits, 0x24, 0, 0, 0, ...'WAVEfmt '.codeUnits];
    expect(DocKind.sniff(wave), isNull);

    List<int> bmp({required int infoSize, required int pixels}) => [
      ...'BM'.codeUnits,
      0x46, 0, 0, 0, // file size
      0, 0, 0, 0, // reserved
      pixels, 0, 0, 0,
      infoSize, 0, 0, 0,
      1, 0, 0, 0, // width
    ];
    expect(DocKind.sniff(bmp(infoSize: 40, pixels: 54)), DocKind.image);
    expect(DocKind.sniff(bmp(infoSize: 12, pixels: 26)), DocKind.image);
    expect(DocKind.sniff(bmp(infoSize: 124, pixels: 138)), DocKind.image);
    // The pixels cannot start inside the headers.
    expect(DocKind.sniff(bmp(infoSize: 40, pixels: 20)), isNull);
    // Text that happens to start "BM".
    expect(DocKind.sniff('BMW service history, 2019 to 2026'.codeUnits), isNull);
    expect(DocKind.sniff('BM'.codeUnits), isNull);
  });

  group('flat OpenDocument', () {
    const office = 'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"';
    List<int> flat(
      String type, {
      String prolog = '<?xml version="1.0" encoding="UTF-8"?>\n',
      String namespaces = office,
    }) => utf8.encode(
      '$prolog<office:document $namespaces office:version="1.3" '
      'office:mimetype="application/vnd.oasis.opendocument.$type">'
      '<office:body/></office:document>',
    );

    test('the root\'s mimetype settles the kind', () {
      expect(DocKind.sniff(flat('text')), DocKind.word);
      expect(DocKind.sniff(flat('spreadsheet')), DocKind.sheet);
      expect(DocKind.sniff(flat('presentation')), DocKind.slides);
      expect(DocKind.sniff(flat('text-template')), DocKind.word);
      // A name never overrides what the content says.
      expect(DocKind.sniff(flat('presentation'), name: 'a.fodt'), DocKind.slides);
      // Drawings and charts are not documents DocHelper opens.
      expect(DocKind.sniff(flat('graphics')), isNull);
      expect(DocKind.sniff(flat('chart'), name: 'a.fodt'), isNull);
    });

    test('a byte-order mark, comments or no declaration change nothing', () {
      expect(DocKind.sniff([0xEF, 0xBB, 0xBF, ...flat('text')]), DocKind.word);
      expect(
        DocKind.sniff(flat('spreadsheet', prolog: '<!-- by hand -->\n\n')),
        DocKind.sheet,
      );
      expect(DocKind.sniff(flat('text', prolog: '')), DocKind.word);
      expect(
        DocKind.sniff(flat('text', prolog: "<?xml version='1.0'?>\r\n\t")),
        DocKind.word,
      );
      final singleQuotes = utf8.encode(
        "<office:document $office office:mimetype='application/vnd.oasis.opendocument.presentation'/>",
      );
      expect(DocKind.sniff(singleQuotes), DocKind.slides);
    });

    test('office suites put the mimetype after 2 KB of namespaces', () {
      final namespaces = [
        office,
        for (var i = 0; i < 40; i++)
          'xmlns:ns$i="urn:oasis:names:tc:opendocument:xmlns:part:$i.0"',
      ].join(' ');
      final suite = flat('spreadsheet', namespaces: namespaces);
      expect(utf8.decode(suite).indexOf('office:mimetype'), greaterThan(2048));
      expect(DocKind.sniff(suite), DocKind.sheet);
      // A kilobyte stops inside the root's start tag: the name decides,
      // and without a document's name nothing is settled.
      final kilobyte = suite.sublist(0, 1024);
      expect(DocKind.sniff(kilobyte, name: 'Budget.fods'), DocKind.sheet);
      expect(DocKind.sniff(kilobyte, name: 'Budget.ods'), DocKind.sheet);
      expect(DocKind.sniff(kilobyte), isNull);
      expect(DocKind.sniff(kilobyte, name: 'notes.xml'), isNull);
    });

    test('other XML, SVG and HTML are not taken for it', () {
      for (final text in [
        '<?xml version="1.0"?>\n<note><to>Tove</to></note>',
        // The words alone, outside a root of that name.
        '<?xml version="1.0"?><notes office:mimetype='
            '"application/vnd.oasis.opendocument.text"><office:document/></notes>',
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
            '<text>office:mimetype="application/vnd.oasis.opendocument.text"'
            '</text></svg>',
        '<!DOCTYPE html>\n<html><body><pre>&lt;office:document '
            'office:mimetype="application/vnd.oasis.opendocument.text"&gt;'
            '</pre></body></html>',
        '<html><head><title>office:document</title></head></html>',
        // A part of a package rather than a whole document.
        '<office:document-content $office office:version="1.3">'
            '<office:body/></office:document-content>',
        // A root without a mimetype, holding an object that has one.
        '<office:document $office office:version="1.3"><office:body>'
            '<office:document office:mimetype='
            '"application/vnd.oasis.opendocument.text"/></office:body>'
            '</office:document>',
        // An attribute that merely ends in the name.
        '<office:document $office xoffice:mimetype='
            '"application/vnd.oasis.opendocument.text"/>',
        // A comment that never ends.
        '<!-- <office:document office:mimetype='
            '"application/vnd.oasis.opendocument.text">',
      ]) {
        expect(DocKind.sniff(utf8.encode(text)), isNull, reason: text);
        // Nor does a flat document's name make them one.
        for (final name in ['a.xml', 'a.fodt', 'a.svg', 'a.html']) {
          expect(
            DocKind.sniff(utf8.encode(text), name: name),
            isNull,
            reason: '$name: $text',
          );
        }
      }
      // A head that ends in the middle of the prolog settles nothing.
      expect(DocKind.sniff('<?xml version="1.0"'.codeUnits), isNull);
    });
  });

  test('MIME types for sharing', () {
    expect(DocKind.mimeTypeOf('a.pdf'), 'application/pdf');
    expect(
      DocKind.mimeTypeOf('a.xlsx'),
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(DocKind.mimeTypeOf('a.log'), 'text/plain');
    expect(DocKind.mimeTypeOf('a.unknown'), 'application/octet-stream');
    const types = {
      'a.fodt': 'application/vnd.oasis.opendocument.text-flat-xml',
      'a.fods': 'application/vnd.oasis.opendocument.spreadsheet-flat-xml',
      'a.fodp': 'application/vnd.oasis.opendocument.presentation-flat-xml',
      'a.ott': 'application/vnd.oasis.opendocument.text-template',
      'a.ots': 'application/vnd.oasis.opendocument.spreadsheet-template',
      'a.otp': 'application/vnd.oasis.opendocument.presentation-template',
      'a.docm': 'application/vnd.ms-word.document.macroEnabled.12',
      'a.dotx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.template',
      'a.dotm': 'application/vnd.ms-word.template.macroEnabled.12',
      'a.xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
      'a.xltx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.template',
      'a.xltm': 'application/vnd.ms-excel.template.macroEnabled.12',
      'a.pptm': 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
      'a.ppsx':
          'application/vnd.openxmlformats-officedocument.presentationml.slideshow',
      'a.ppsm': 'application/vnd.ms-powerpoint.slideshow.macroEnabled.12',
      'a.potx':
          'application/vnd.openxmlformats-officedocument.presentationml.template',
      'a.potm': 'application/vnd.ms-powerpoint.template.macroEnabled.12',
      'a.dot': 'application/msword',
      'a.xlt': 'application/vnd.ms-excel',
      'a.pps': 'application/vnd.ms-powerpoint',
      'a.pot': 'application/vnd.ms-powerpoint',
      'a.bmp': 'image/bmp',
      'a.heic': 'image/heic',
      'a.HEIF': 'image/heif',
      'a.zip': 'application/zip',
      'a.tar': 'application/x-tar',
      'a.tar.gz': 'application/gzip',
      'a.tgz': 'application/gzip',
      'a.7z': 'application/x-7z-compressed',
      'a.rar': 'application/vnd.rar',
    };
    for (final MapEntry(key: name, value: type) in types.entries) {
      expect(DocKind.mimeTypeOf(name), type, reason: name);
    }
  });

  test('display names strip Open-with prefixes and fall back by kind', () {
    expect(documentDisplayName('/c/intent_123_Letter.docx'), 'Letter.docx');
    expect(documentDisplayName('/c/notes.txt'), 'notes.txt');
    expect(documentDisplayName('/c/intent_9_opened.txt'), 'Text file');
    expect(documentDisplayName('/c/opened.pdf'), 'View PDF');
    expect(documentDisplayName('/c/intent_5'), 'Document');
  });
}
