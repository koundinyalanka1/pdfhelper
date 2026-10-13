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

  test('the Files tab lists documents, not code, photos or archives', () {
    for (final name in ['a.pdf', 'a.docx', 'a.xlsx', 'a.pptx', 'a.odt', 'a.txt', 'a.md', 'a.csv']) {
      expect(DocKind.isListed(name), isTrue, reason: name);
    }
    for (final name in ['a.json', 'a.py', 'a.jpg', 'a.zip', 'a', 'a.bin']) {
      expect(DocKind.isListed(name), isFalse, reason: name);
    }
    expect(DocKind.importExtensions, containsAll(['pdf', 'docx', 'xlsx', 'txt']));
    expect(DocKind.importExtensions, isNot(contains('jpg')));
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

  test('MIME types for sharing', () {
    expect(DocKind.mimeTypeOf('a.pdf'), 'application/pdf');
    expect(
      DocKind.mimeTypeOf('a.xlsx'),
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(DocKind.mimeTypeOf('a.log'), 'text/plain');
    expect(DocKind.mimeTypeOf('a.unknown'), 'application/octet-stream');
  });

  test('display names strip Open-with prefixes and fall back by kind', () {
    expect(documentDisplayName('/c/intent_123_Letter.docx'), 'Letter.docx');
    expect(documentDisplayName('/c/notes.txt'), 'notes.txt');
    expect(documentDisplayName('/c/intent_9_opened.txt'), 'Text file');
    expect(documentDisplayName('/c/opened.pdf'), 'View PDF');
    expect(documentDisplayName('/c/intent_5'), 'Document');
  });
}
