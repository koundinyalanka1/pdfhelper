import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_word_core/flutter_word_core.dart';

void main() {
  final skip = !WordCore.isAvailable;

  test('writes a letter, saves it and reads it back', () async {
    final doc = WordCore.create();
    final first = doc.blocks(0, 10).first as ParaBlock;
    final mark = first.style.mark;
    final r = doc.setParagraphs(first.id, first.id, [
      NewParagraph([TextEdit('Dear Sir,', mark)]),
      NewParagraph([
        TextEdit('Bold ', mark.copyWith(bold: true)),
        TextEdit('and plain', mark),
      ]),
    ]);
    expect(r.ids, hasLength(2));
    doc.patch([r.ids[1]], list: 'number', align: ParaAlign.center);
    doc.insertTable(r.ids[1], 2, 2);
    expect(doc.info().canUndo, isTrue);

    final dir = await Directory.systemTemp.createTemp('word_core_test');
    final path = '${dir.path}/letter.docx';
    expect(await doc.save(path), 'docx');
    doc.close();

    final again = await WordCore.open(path);
    final info = again.info();
    expect(info.format, 'docx');
    expect(info.blockCount, 4);
    final blocks = again.blocks(0, 10);
    final second = blocks[1] as ParaBlock;
    expect(second.text, 'Bold and plain');
    expect(second.list?.text, '1.');
    expect(second.style.align, ParaAlign.center);
    expect((second.inlines.first as TextInline).style.bold, isTrue);
    expect(blocks[2], isA<TableBlock>());
    expect(again.find('plain').single.start, 9);
    expect(again.counts().words, 5);
    again.close();
    await dir.delete(recursive: true);
  }, skip: skip);

  test('undo and redo a split', () {
    final doc = WordCore.create();
    final p = doc.blocks(0, 1).first as ParaBlock;
    doc.setParagraphs(p.id, p.id, [
      NewParagraph([TextEdit('One', p.style.mark)]),
    ]);
    doc.setParagraphs(p.id, p.id, [
      NewParagraph([TextEdit('O', p.style.mark)]),
      NewParagraph([TextEdit('ne', p.style.mark)]),
    ]);
    expect(doc.info().blockCount, 2);
    expect(doc.undo(), isTrue);
    expect(doc.info().blockCount, 1);
    expect((doc.blocks(0, 1).first as ParaBlock).text, 'One');
    expect(doc.redo(), isTrue);
    expect(doc.info().blockCount, 2);
    doc.close();
  }, skip: skip);

  test('reports errors with their code', () async {
    final dir = await Directory.systemTemp.createTemp('word_core_test');
    final path = '${dir.path}/bad.docx';
    await File(path).writeAsString('not a document');
    await expectLater(
      WordCore.open(path),
      throwsA(isA<WordCoreException>().having((e) => e.code, 'code', 'CORRUPT')),
    );
    await dir.delete(recursive: true);
  }, skip: skip);
}
