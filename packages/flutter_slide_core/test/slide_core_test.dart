import 'dart:io';

import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final skip = !SlideCore.isAvailable;

  test('makes a deck, edits it, saves it and reads it back', () async {
    final deck = SlideCore.create();
    var info = deck.info();
    expect(info.slideCount, 1);
    expect(info.width / info.height, closeTo(16 / 9, 0.01));
    final title = deck
        .scene(0)
        .items
        .firstWhere((i) => i.placeholder == 'ctrTitle');
    expect(title.text!.prompt, 'Tap to add a title');
    deck.setText(0, title.id, ['Family budget']);
    deck.formatText(0, title.id, bold: true);
    final added = deck.addSlide(after: 0);
    expect(added.slide, 1);
    final box = deck.addShape(1, 'ellipse', 100, 100, 200, 120);
    deck.setText(1, box.shape!, ['Savings']);
    deck.setNotes(0, 'Say hello');
    expect(deck.info().canUndo, isTrue);

    final dir = await Directory.systemTemp.createTemp('slide_core_test');
    final path = '${dir.path}/budget.pptx';
    expect(await deck.save(path), 'pptx');
    deck.close();

    final again = await SlideCore.open(path);
    info = again.info();
    expect(info.slideCount, 2);
    final t = again
        .scene(0)
        .items
        .firstWhere((i) => i.placeholder == 'ctrTitle');
    expect(t.text!.paras.first.text, 'Family budget');
    expect(t.text!.paras.first.runs.first.bold, isTrue);
    expect(again.notes(0), 'Say hello');
    final ellipse = again.scene(1).items.firstWhere((i) => i.id == box.shape);
    expect(ellipse.paths.first.cmds.first.op, 'M');
    expect(ellipse.fill?.type, 'solid');
    expect(again.plainText(), contains('Savings'));
    again.close();
    await dir.delete(recursive: true);
  }, skip: skip);

  test('undo and redo a new slide', () {
    final deck = SlideCore.create();
    deck.addSlide();
    expect(deck.info().slideCount, 2);
    expect(deck.undo(), isTrue);
    expect(deck.info().slideCount, 1);
    expect(deck.redo(), isTrue);
    expect(deck.info().slideCount, 2);
    deck.close();
  }, skip: skip);
}
