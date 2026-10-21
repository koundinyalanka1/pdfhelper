import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_word_core/flutter_word_core.dart';

import 'doc_style.dart';

/// What stands for an object in the text being edited.
const String objectChar = '￼';

/// A line break inside a paragraph (the engine's `\n`); a typed newline
/// starts a new paragraph instead.
const String lineBreakChar = ' ';

/// Sits before the text so that a backspace at the start reaches the
/// controller (and joins the paragraph to the one before).
const String _sentinel = '​';

/// One run of a paragraph being edited: text with its formatting, or an
/// object of the document.
class DocSeg {
  DocSeg.text(this.text, this.style, [this.link]) : object = null;

  DocSeg.object(DocObject this.object)
    : text = objectChar,
      style = object.style,
      link = null;

  String text;
  RunStyle style;
  String? link;
  final DocObject? object;

  bool get isObject => object != null;

  DocSeg copy() =>
      isObject ? DocSeg.object(object!) : DocSeg.text(text, style, link);
}

/// The runs of a paragraph, ready to edit.
List<DocSeg> segsOf(ParaBlock p) => [
  for (final i in p.inlines)
    switch (i) {
      TextInline(:final text, :final style, :final link) => DocSeg.text(
        text.replaceAll('\n', lineBreakChar),
        style,
        link,
      ),
      ObjectInline(:final object) => DocSeg.object(object),
    },
];

/// Runs as edit content for the engine, neighbours with the same look
/// merged.
List<InlineEdit> editsOf(List<DocSeg> segs) {
  final out = <InlineEdit>[];
  for (final s in segs) {
    if (s.isObject) {
      out.add(ObjectEdit(s.object!.id));
      continue;
    }
    if (s.text.isEmpty) continue;
    final text = s.text.replaceAll(lineBreakChar, '\n');
    final last = out.isEmpty ? null : out.last;
    if (last is TextEdit && last.style == s.style && last.link == s.link) {
      out[out.length - 1] = TextEdit(last.text + text, s.style, s.link);
    } else {
      out.add(TextEdit(text, s.style, s.link));
    }
  }
  return out;
}

/// Splits runs at each newline: the paragraphs typing Enter makes.
List<List<DocSeg>> splitAtNewlines(List<DocSeg> segs) {
  final parts = <List<DocSeg>>[[]];
  for (final s in segs) {
    if (s.isObject || !s.text.contains('\n')) {
      parts.last.add(s);
      continue;
    }
    final pieces = s.text.split('\n');
    for (var k = 0; k < pieces.length; k++) {
      if (k > 0) parts.add([]);
      if (pieces[k].isNotEmpty) {
        parts.last.add(DocSeg.text(pieces[k], s.style, s.link));
      }
    }
  }
  return parts;
}

/// The text controller of the paragraph being edited: keeps the runs and
/// their formatting in step with what is typed, and draws them.
class ParaController extends TextEditingController {
  ParaController({
    required ParaBlock para,
    required this.look,
    required this.onSplit,
    required this.onJoinBack,
    required this.onChanged,
    int? cursor,
  }) : segs = segsOf(para),
       mark = para.style.mark,
       line = para.style.line {
    final text = _sentinel + segs.map((s) => s.text).join();
    final at = (cursor ?? text.length - 1) + 1;
    super.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at.clamp(1, text.length)),
    );
  }

  final DocLook look;

  /// Enter was typed: the runs now hold newlines where paragraphs end.
  final void Function(ParaController) onSplit;

  /// Backspace at the very start.
  final void Function(ParaController) onJoinBack;

  /// The runs changed (typing or formatting).
  final void Function(ParaController) onChanged;

  List<DocSeg> segs;
  final RunStyle mark;
  final LineSpacing line;

  /// Formatting chosen for what is typed next at a collapsed cursor.
  RunStyle? pending;
  bool dirty = false;

  /// The paragraph's text (without the start marker).
  String get plain => segs.map((s) => s.text).join();

  /// The cursor or selection in paragraph offsets.
  TextSelection get modelSelection {
    final s = value.selection;
    if (!s.isValid) return TextSelection.collapsed(offset: plain.length);
    return TextSelection(
      baseOffset: (s.baseOffset - 1).clamp(0, plain.length),
      extentOffset: (s.extentOffset - 1).clamp(0, plain.length),
    );
  }

  /// Put the cursor or a selection at paragraph offsets.
  void select(int start, [int? end]) {
    final len = plain.length;
    super.value = value.copyWith(
      selection: TextSelection(
        baseOffset: start.clamp(0, len) + 1,
        extentOffset: (end ?? start).clamp(0, len) + 1,
      ),
      composing: TextRange.empty,
    );
  }

  List<InlineEdit> get edits => editsOf(segs);

  TextSelection _clamp(TextSelection s, int length) {
    if (!s.isValid) return s;
    int c(int o) => o.clamp(1, length);
    return s.copyWith(
      baseOffset: c(s.baseOffset),
      extentOffset: c(s.extentOffset),
    );
  }

  @override
  set value(TextEditingValue newValue) {
    final old = super.value;
    var v = newValue;
    if (!v.text.startsWith(_sentinel)) {
      final oneGone =
          old.text.length - v.text.length == 1 &&
          old.selection.isCollapsed &&
          old.selection.baseOffset <= 1;
      if (oneGone || v.text.isEmpty && old.text.length <= 1) {
        // Backspace at the start: keep the text, join paragraphs.
        scheduleMicrotask(() => onJoinBack(this));
        super.value = old.copyWith(composing: TextRange.empty);
        return;
      }
      // Everything replaced: put the marker back.
      v = TextEditingValue(
        text: _sentinel + v.text,
        selection: v.selection.isValid
            ? TextSelection(
                baseOffset: v.selection.baseOffset + 1,
                extentOffset: v.selection.extentOffset + 1,
              )
            : v.selection,
      );
    }
    if (v.text != old.text) {
      _applyChange(old.text, v.text, v.selection);
      dirty = true;
      final canonical = _sentinel + plain;
      if (canonical != v.text) {
        // Something the runs cannot hold (a pasted object mark) was dropped.
        final end = v.selection.isValid
            ? v.selection.end.clamp(1, canonical.length)
            : canonical.length;
        v = TextEditingValue(
          text: canonical,
          selection: TextSelection.collapsed(offset: end),
        );
      }
    } else if (v.selection != old.selection) {
      pending = null;
    }
    super.value = v.copyWith(selection: _clamp(v.selection, v.text.length));
    if (v.text != old.text) {
      if (plain.contains('\n')) {
        scheduleMicrotask(() => onSplit(this));
      } else {
        onChanged(this);
      }
    }
  }

  void _applyChange(String a, String b, TextSelection after) {
    var p = 0;
    final maxP = a.length < b.length ? a.length : b.length;
    while (p < maxP && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    // Where the cursor ended up disambiguates repeated letters.
    if (after.isValid && after.isCollapsed && b.length > a.length) {
      final insertedEnd = after.baseOffset;
      final start = insertedEnd - (b.length - a.length);
      if (start >= 1 &&
          start <= p &&
          b.substring(0, start) == a.substring(0, start)) {
        p = start;
      }
    }
    var s = 0;
    while (s < a.length - p &&
        s < b.length - p &&
        a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    final from = (p - 1).clamp(0, plain.length);
    final to = (a.length - s - 1).clamp(from, plain.length);
    var inserted = b.substring(p, b.length - s).replaceAll(objectChar, '');
    inserted = inserted.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final style = pending ?? _typingStyle(from, to);
    final link = _linkAround(from, to);
    _delete(from, to);
    if (inserted.isNotEmpty) _insert(from, inserted, style, link);
  }

  /// Formatting for text typed over [from, to): the character before, or
  /// the first one replaced, or the paragraph mark.
  RunStyle _typingStyle(int from, int to) {
    var pos = 0;
    RunStyle? before;
    RunStyle? first;
    for (final s in segs) {
      final end = pos + s.text.length;
      if (!s.isObject && s.text.isNotEmpty) {
        if (end <= from || (pos < from && end >= from)) before = s.style;
        if (first == null && end > from) first = s.style;
      }
      pos = end;
    }
    return before ?? first ?? mark;
  }

  /// A link continues when typing inside it.
  String? _linkAround(int from, int to) {
    String? before;
    String? after;
    var pos = 0;
    for (final s in segs) {
      final end = pos + s.text.length;
      if (end <= from && end > 0) before = s.link;
      if (after == null && pos >= to && s.text.isNotEmpty) {
        after = s.link;
        break;
      }
      pos = end;
    }
    return before != null && before == after ? before : null;
  }

  /// Make a run boundary at [offset]; returns the index of the run that
  /// starts there.
  int _cut(int offset) {
    var pos = 0;
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      if (offset == pos) return i;
      final end = pos + s.text.length;
      if (offset < end && !s.isObject) {
        final k = offset - pos;
        segs[i] = DocSeg.text(s.text.substring(0, k), s.style, s.link);
        segs.insert(i + 1, DocSeg.text(s.text.substring(k), s.style, s.link));
        return i + 1;
      }
      pos = end;
    }
    return segs.length;
  }

  void _delete(int from, int to) {
    if (to <= from) return;
    final a = _cut(from);
    final b = _cut(to);
    segs.removeRange(a, b);
  }

  void _insert(int at, String text, RunStyle style, String? link) {
    final i = _cut(at);
    segs.insert(i, DocSeg.text(text, style, link));
    _normalize();
  }

  void _normalize() {
    final out = <DocSeg>[];
    for (final s in segs) {
      if (!s.isObject && s.text.isEmpty) continue;
      final last = out.isEmpty ? null : out.last;
      if (last != null &&
          !last.isObject &&
          !s.isObject &&
          last.style == s.style &&
          last.link == s.link) {
        last.text += s.text;
      } else {
        out.add(s.copy());
      }
    }
    segs = out;
  }

  /// The formatting the toolbar shows: the selection's first character, or
  /// what typing would use.
  RunStyle get currentStyle {
    final sel = modelSelection;
    if (pending != null && sel.isCollapsed) return pending!;
    if (sel.isCollapsed) return _typingStyle(sel.start, sel.start);
    var pos = 0;
    for (final s in segs) {
      final end = pos + s.text.length;
      if (end > sel.start && !s.isObject) return s.style;
      pos = end;
    }
    return mark;
  }

  /// The link at the cursor (the character before it) or at the start of
  /// the selection.
  String? get currentLink {
    final sel = modelSelection;
    final at = sel.isCollapsed ? sel.start - 1 : sel.start;
    if (at < 0) return null;
    var pos = 0;
    for (final s in segs) {
      final end = pos + s.text.length;
      if (at < end) return s.link;
      pos = end;
    }
    return null;
  }

  /// Change the formatting of the selection (or of what is typed next).
  void format(RunStyle Function(RunStyle) change) {
    final sel = modelSelection;
    if (sel.isCollapsed) {
      pending = change(currentStyle);
      notifyListeners();
      return;
    }
    final a = _cut(sel.start);
    final b = _cut(sel.end);
    for (var i = a; i < b; i++) {
      if (!segs[i].isObject) segs[i].style = change(segs[i].style);
    }
    _normalize();
    dirty = true;
    notifyListeners();
    onChanged(this);
  }

  /// Make the selection a link (or remove links with null).
  void setLink(String? url, {String? text}) {
    final sel = modelSelection;
    if (sel.isCollapsed) {
      if (url == null || text == null || text.isEmpty) return;
      final style = currentStyle.copyWith(color: 0x0563C1, underline: 'single');
      final i = _cut(sel.start);
      segs.insert(i, DocSeg.text(text, style, url));
      _normalize();
      dirty = true;
      final at = sel.start + text.length;
      super.value = TextEditingValue(
        text: _sentinel + plain,
        selection: TextSelection.collapsed(offset: at + 1),
      );
      onChanged(this);
      return;
    }
    final a = _cut(sel.start);
    final b = _cut(sel.end);
    for (var i = a; i < b; i++) {
      final s = segs[i];
      if (s.isObject) continue;
      s.link = url;
      if (url != null) {
        s.style = s.style.copyWith(color: 0x0563C1, underline: 'single');
      }
    }
    _normalize();
    dirty = true;
    notifyListeners();
    onChanged(this);
  }

  /// Insert text at the cursor (replacing the selection).
  void insertText(String text) {
    final sel = value.selection;
    final t = value.text;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    value = TextEditingValue(
      text: t.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final children = <InlineSpan>[TextSpan(text: _sentinel)];
    for (final s in segs) {
      if (s.isObject) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ObjectChip(object: s.object!, look: look),
          ),
        );
      } else {
        children.add(
          TextSpan(
            text: s.text,
            style: look.text(s.style, line: line, link: s.link),
          ),
        );
      }
    }
    return TextSpan(style: style, children: children);
  }
}

/// How an object shows inside a paragraph being edited.
class ObjectChip extends StatelessWidget {
  const ObjectChip({super.key, required this.object, required this.look});

  final DocObject object;
  final DocLook look;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (object.kind) {
      DocObjectKind.image => (Icons.image_outlined, 'Picture'),
      DocObjectKind.pageBreak => (
        Icons.insert_page_break_outlined,
        'Page break',
      ),
      DocObjectKind.columnBreak => (Icons.view_column_outlined, 'Column break'),
      DocObjectKind.shape => (Icons.category_outlined, 'Shape'),
      DocObjectKind.equation => (Icons.functions, object.text),
      DocObjectKind.note => (Icons.notes, object.text),
      DocObjectKind.field => (Icons.data_object, object.text),
      DocObjectKind.control => (Icons.check_box_outlined, object.text),
      DocObjectKind.other => (Icons.widgets_outlined, object.text),
    };
    final size = object.style.size * look.scale;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0x14000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: size, color: const Color(0xFF5F6368)),
          if (label.trim().isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(
              label.length > 40 ? '${label.substring(0, 40)}…' : label,
              style: look.text(object.style),
            ),
          ],
        ],
      ),
    );
  }
}
