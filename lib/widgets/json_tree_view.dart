import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/theme_provider.dart';
import '../utils/format_utils.dart';

/// What [parseJsonForTree] made of a text: the decoded value, or why it is
/// not JSON and where the problem is.
class JsonParseResult {
  const JsonParseResult({this.value, this.error, this.line, this.column});

  final Object? value;

  /// A sentence saying what is wrong, with the line and column when known.
  final String? error;

  /// 1-based position of the problem, counted in UTF-16 code units.
  final int? line;
  final int? column;

  bool get ok => error == null;
}

/// A number as the JSON text writes it, where Dart's own number would show
/// it differently: `12345678901234567890` (more digits than a double holds),
/// `1.50`, `1e3` or `1e400`. [parseJsonForTree] gives these in place of the
/// number, so the tree shows and copies what the file says.
class JsonNumber {
  const JsonNumber(this.text);

  final String text;

  /// The nearest Dart number.
  num get value => num.parse(text);

  @override
  bool operator ==(Object other) => other is JsonNumber && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

/// Decodes [text] as JSON on a background isolate, so a large file does not
/// stall the screen. Never throws: a text that is not JSON comes back with
/// [JsonParseResult.error] set. Numbers that a Dart number would show
/// differently come back as [JsonNumber]s.
Future<JsonParseResult> parseJsonForTree(String text) =>
    Isolate.run(() => _parseJson(text));

JsonParseResult _parseJson(String text) {
  // A byte-order mark is not part of the JSON, and editors do not show it.
  final source = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF
      ? text.substring(1)
      : text;
  if (source.trim().isEmpty) {
    return const JsonParseResult(
      error: 'The file is empty, so there is no JSON to show.',
    );
  }
  try {
    final value = jsonDecode(source);
    // Read again, keeping the numbers' text, only when some number needs
    // it: most documents then cost no more than a decode.
    return JsonParseResult(
      value: _hasAlteredNumber(source) ? _JsonReader(source).read() : value,
    );
  } on FormatException catch (e) {
    final offset = e.offset;
    if (offset == null) return JsonParseResult(error: '${e.message}.');
    final character = offset < source.length ? source.codeUnitAt(offset) : null;
    final what = _describeJsonError(e.message, character);
    final (line, column) = _lineAndColumn(source, offset);
    return JsonParseResult(
      error: '$what at line $line, column $column.',
      line: line,
      column: column,
    );
  } catch (e) {
    return JsonParseResult(error: 'This is not valid JSON ($e).');
  }
}

/// Whether a number in [json] (valid JSON) would show differently once
/// decoded.
bool _hasAlteredNumber(String json) {
  for (var i = 0; i < json.length; i++) {
    final unit = json.codeUnitAt(i);
    if (unit == 0x22) {
      // Skip a string, escapes and all.
      for (i++; i < json.length; i++) {
        final inside = json.codeUnitAt(i);
        if (inside == 0x5C) {
          i++;
        } else if (inside == 0x22) {
          break;
        }
      }
    } else if (unit == 0x2D || (unit >= 0x30 && unit <= 0x39)) {
      final end = _numberEnd(json, i);
      if (_JsonReader.number(json.substring(i, end)) is JsonNumber) {
        return true;
      }
      i = end - 1;
    }
  }
  return false;
}

/// Where the number starting at [start] in [json] ends.
int _numberEnd(String json, int start) {
  var end = start;
  while (end < json.length) {
    final unit = json.codeUnitAt(end);
    final part =
        (unit >= 0x30 && unit <= 0x39) ||
        unit == 0x2D ||
        unit == 0x2B ||
        unit == 0x2E ||
        unit == 0x65 ||
        unit == 0x45;
    if (!part) break;
    end++;
  }
  return end;
}

/// Reads JSON that `jsonDecode` has already found valid into the same
/// values, but with [JsonNumber]s for numbers a Dart number would show
/// differently. A loop rather than recursion, so nesting thousands deep is
/// safe.
class _JsonReader {
  _JsonReader(this.json);

  final String json;
  int _at = 0;

  /// [text] as `jsonDecode` reads it, or as a [JsonNumber] when that would
  /// show differently.
  static Object number(String text) {
    final value = num.tryParse(text);
    return value != null && '$value' == text ? value : JsonNumber(text);
  }

  Object? read() {
    // Each open container, and for an object the key its next value has.
    final containers = <Object>[];
    final keys = <String?>[];
    Object? result;
    while (true) {
      _skipSpace();
      final unit = json.codeUnitAt(_at);
      Object? value;
      var opened = false;
      switch (unit) {
        case 0x7B: // {
          _at++;
          containers.add(<String, Object?>{});
          keys.add(null);
          opened = true;
        case 0x5B: // [
          _at++;
          containers.add(<Object?>[]);
          keys.add(null);
          opened = true;
        case 0x22: // "
          value = _string();
        case 0x74: // true
          _at += 4;
          value = true;
        case 0x66: // false
          _at += 5;
          value = false;
        case 0x6E: // null
          _at += 4;
          value = null;
        default:
          final end = _numberEnd(json, _at);
          value = number(json.substring(_at, end));
          _at = end;
      }
      if (opened) {
        _skipSpace();
        final close = json.codeUnitAt(_at);
        if (close == 0x7D || close == 0x5D) {
          // Empty: closed at once.
          _at++;
          value = containers.removeLast();
          keys.removeLast();
        } else {
          if (containers.last is Map) _key(keys);
          continue;
        }
      }
      // Put the value in its container, and close the containers that end
      // after it.
      while (true) {
        if (containers.isEmpty) {
          result = value;
          return result;
        }
        final container = containers.last;
        if (container is Map<String, Object?>) {
          container[keys.last!] = value;
        } else {
          (container as List<Object?>).add(value);
        }
        _skipSpace();
        if (json.codeUnitAt(_at) == 0x2C) {
          // A comma: another member follows.
          _at++;
          if (container is Map) _key(keys);
          break;
        }
        _at++; // } or ]
        value = containers.removeLast();
        keys.removeLast();
      }
    }
  }

  /// Reads an object member's key and its colon.
  void _key(List<String?> keys) {
    _skipSpace();
    keys.last = _string();
    _skipSpace();
    _at++; // :
  }

  String _string() {
    final start = _at;
    var escaped = false;
    for (_at++; ; _at++) {
      final unit = json.codeUnitAt(_at);
      if (unit == 0x5C) {
        escaped = true;
        _at++;
      } else if (unit == 0x22) {
        break;
      }
    }
    _at++;
    return escaped
        ? jsonDecode(json.substring(start, _at)) as String
        : json.substring(start + 1, _at - 1);
  }

  void _skipSpace() {
    while (_at < json.length) {
      final unit = json.codeUnitAt(_at);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) return;
      _at++;
    }
  }
}

/// Dart's parser messages, said the way a person would.
String _describeJsonError(String message, int? character) {
  switch (message) {
    case 'Unexpected character':
      if (character == null) return 'Unexpected character';
      // Printable characters are shown; others by their code.
      if (character > 0x20 && character < 0xD800) {
        return "Unexpected '${String.fromCharCode(character)}'";
      }
      final code = character.toRadixString(16).toUpperCase().padLeft(4, '0');
      return 'Unexpected character U+$code';
    case 'Unexpected end of input':
      return 'The JSON ends before it is complete';
    case 'Unterminated string':
      return 'A text value has no closing quote';
    case 'Control character in string':
      return 'A text value has a line break or tab in it, which JSON does '
          'not allow';
    default:
      return message.isEmpty ? 'This is not valid JSON' : message;
  }
}

/// The 1-based line and column of [offset] in [text]. A line ends at LF,
/// CR LF or a lone CR.
(int, int) _lineAndColumn(String text, int offset) {
  final end = offset.clamp(0, text.length);
  var line = 1;
  var lineStart = 0;
  for (var i = 0; i < end; i++) {
    final unit = text.codeUnitAt(i);
    final lineFeed = unit == 0x0A;
    final loneReturn =
        unit == 0x0D &&
        (i + 1 >= text.length || text.codeUnitAt(i + 1) != 0x0A);
    if (lineFeed || loneReturn) {
      line++;
      lineStart = i + 1;
    }
  }
  return (line, end - lineStart + 1);
}

/// A JSON value (as `jsonDecode` returns it) shown as a tree: objects and
/// arrays open and close with a tap, values are coloured by type, and a
/// long-press copies a value or its path.
///
/// Only the rows on screen are built. The rows that are open are kept as a
/// flat list, changed only when something opens or closes, so documents with
/// hundreds of thousands of values scroll as smoothly as small ones.
///
/// The root is always open; its members are the top rows. Containers less
/// than [initiallyExpandedDepth] levels deep start open (the root is level
/// 0, so the default shows the root's members closed). Fills the height it
/// is given.
class JsonTreeView extends StatefulWidget {
  const JsonTreeView({
    super.key,
    required this.value,
    this.initiallyExpandedDepth = 1,
  });

  final Object? value;
  final int initiallyExpandedDepth;

  /// Expand all stops opening containers once about this many rows show,
  /// and says so. A tap can still open any container.
  static const int expandAllLimit = 20000;

  @override
  State<JsonTreeView> createState() => _JsonTreeViewState();
}

/// Identifies an opened string by where it is: its container and its key or
/// index. Containers compare by identity.
typedef _TextKey = (Object, Object?);

const Object _rootMarker = Object();

/// One line of the tree.
class _Row {
  _Row(this.parent, this.depth, this.slot, this.value)
    : line = null,
      note = false;

  /// A line of an opened string's text, shown below the string's row.
  _Row.line(_Row owner, String this.line, {this.note = false})
    : parent = owner,
      depth = owner.depth + 1,
      slot = null,
      value = owner.value;

  /// The row of the container this value is in; null at the top. For a line
  /// of text, the string's own row.
  final _Row? parent;

  /// 0 for the root's members.
  final int depth;

  /// The member name (a String) or array index (an int); null for a root
  /// that is a single value, and for lines of text.
  final Object? slot;
  final Object? value;

  final String? line;

  /// A line saying the text was cut short, rather than a line of it.
  final bool note;

  bool get isLine => line != null;
}

bool _isContainer(Object? value) => value is Map || value is List;

int _childCount(Object? value) => switch (value) {
  Map() => value.length,
  List() => value.length,
  _ => 0,
};

Iterable<Object?> _childValues(Object container) =>
    container is Map ? container.values : container as List;

/// Walks one container's members, making their rows as it goes.
class _Frame {
  _Frame(this.parent, Object container, this.depth)
    : _entries = container is Map ? container.entries.iterator : null,
      _list = container is List ? container : null;

  final _Row? parent;
  final int depth;
  final Iterator<MapEntry<dynamic, dynamic>>? _entries;
  final List<dynamic>? _list;
  int _index = 0;

  _Row? next() {
    final entries = _entries;
    if (entries != null) {
      if (!entries.moveNext()) return null;
      final entry = entries.current;
      final key = entry.key;
      return _Row(parent, depth, key is String ? key : '$key', entry.value);
    }
    final list = _list!;
    if (_index >= list.length) return null;
    final index = _index++;
    return _Row(parent, depth, index, list[index]);
  }
}

enum _CopyChoice { value, path }

class _JsonTreeViewState extends State<JsonTreeView> {
  static const double _indent = 16;
  static const double _chevronWidth = 20;
  static const double _badgeWidth = 30;
  static const double _gap = 4;
  static const double _sidePadding = 8;

  /// The most of a row the key may take, as a share of the room after the
  /// indent.
  static const double _keyShare = 0.6;

  /// Strings longer than this are cut short on their row.
  static const int _previewLength = 200;

  /// The most of a string shown when it is opened; the rest can be copied.
  static const int _openTextLimit = 20000;

  /// Longer copies are refused: Android's clipboard fails on about a
  /// megabyte, which is half a million UTF-16 characters.
  static const int _copyLimit = 500000;

  static const TextStyle _baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13.5,
    height: 1.3,
  );

  static final RegExp _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  final Set<Object> _open = HashSet<Object>.identity();
  final Set<_TextKey> _openTexts = {};
  List<_Row> _rows = [];
  final _scroll = ScrollController();

  /// Why Expand all stopped short, until the tree next changes.
  String? _notice;

  /// The layout rows were last measured for: opened strings wrap to it.
  double _width = 0;
  TextScaler _textScaler = TextScaler.noScaling;
  TextStyle _style = _baseStyle;
  double _rowExtent = 34;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(JsonTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value) ||
        oldWidget.initiallyExpandedDepth != widget.initiallyExpandedDepth) {
      _reset();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _open.clear();
    _openTexts.clear();
    _notice = null;
    _openLevels(levels: widget.initiallyExpandedDepth - 1);
    _rows = _flatten();
  }

  // ------------------------------------------------------------- the rows

  /// Opens containers a level at a time, the top level first, until
  /// [levels] levels are open (all of them when null) or about
  /// [JsonTreeView.expandAllLimit] rows show. False when it stopped at the
  /// limit with containers left closed.
  bool _openLevels({int? levels}) {
    final root = widget.value;
    if (root == null || !_isContainer(root)) return true;
    if (levels != null && levels <= 0) return true;
    var shown = _childCount(root);
    var frontier = [
      for (final child in _childValues(root))
        if (_isContainer(child)) child!,
    ];
    for (var depth = 0; frontier.isNotEmpty; depth++) {
      if (levels != null && depth >= levels) break;
      final next = <Object>[];
      for (final container in frontier) {
        if (shown >= JsonTreeView.expandAllLimit) return false;
        _open.add(container);
        shown += _childCount(container);
        for (final child in _childValues(container)) {
          if (_isContainer(child)) next.add(child!);
        }
      }
      frontier = next;
    }
    return true;
  }

  /// Every visible row, top to bottom. Iterative, so a document nested
  /// thousands deep cannot overflow the stack.
  List<_Row> _flatten() {
    final rows = <_Row>[];
    final root = widget.value;
    if (root != null && _isContainer(root)) {
      _appendChildren(rows, null, root, 0);
    } else {
      final row = _Row(null, 0, null, root);
      rows.add(row);
      if (root is String && _openTexts.contains(_textKey(row))) {
        rows.addAll(_linesOf(row));
      }
    }
    return rows;
  }

  /// The visible rows under [container], whose own row is [parent].
  void _appendChildren(
    List<_Row> out,
    _Row? parent,
    Object container,
    int depth,
  ) {
    final stack = [_Frame(parent, container, depth)];
    while (stack.isNotEmpty) {
      final row = stack.last.next();
      if (row == null) {
        stack.removeLast();
        continue;
      }
      out.add(row);
      final value = row.value;
      if (value != null && _isContainer(value)) {
        if (_open.contains(value)) {
          stack.add(_Frame(row, value, row.depth + 1));
        }
      } else if (value is String &&
          _openTexts.isNotEmpty &&
          _openTexts.contains(_textKey(row))) {
        out.addAll(_linesOf(row));
      }
    }
  }

  _TextKey _textKey(_Row row) => (row.parent?.value ?? _rootMarker, row.slot);

  /// An opened string's text, wrapped into rows the width of the view.
  List<_Row> _linesOf(_Row owner) {
    final text = owner.value as String;
    final shown = _clip(text, _openTextLimit);
    // A pixel to spare, so a line never ends up a hair too wide for its row.
    final width = _geometry(owner.depth + 1).content - 1;
    final painter = TextPainter(
      text: TextSpan(text: shown, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout(maxWidth: math.max(20.0, width));
    final lines = <_Row>[];
    try {
      var start = 0;
      while (start < shown.length) {
        final range = painter.getLineBoundary(TextPosition(offset: start));
        var end = math.max(range.end, start);
        // The line's break (LF, CR LF or CR) belongs to it: the next line
        // starts after it, not on it as an empty line of its own.
        if (end < shown.length && shown.codeUnitAt(end) == 0x0D) end++;
        if (end < shown.length && shown.codeUnitAt(end) == 0x0A) end++;
        if (end == start) end++;
        var line = shown.substring(start, end);
        if (line.endsWith('\n')) line = line.substring(0, line.length - 1);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        lines.add(_Row.line(owner, line));
        start = end;
      }
    } finally {
      painter.dispose();
    }
    if (lines.isEmpty) lines.add(_Row.line(owner, ''));
    if (shown.length < text.length) {
      final rest = formatCount(text.length - shown.length);
      lines.add(
        _Row.line(
          owner,
          '…and $rest more characters. Long-press to copy them all.',
          note: true,
        ),
      );
    }
    return lines;
  }

  /// The first [limit] code units of [text], without splitting a
  /// surrogate pair.
  static String _clip(String text, int limit) {
    if (text.length <= limit) return text;
    var cut = limit;
    final last = text.codeUnitAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) cut--;
    return text.substring(0, cut);
  }

  /// Where a row at [depth] draws: how many guide lines, whether the depth
  /// is too great to indent further (a badge says it instead), and the room
  /// left for its key and value.
  ({int levels, bool badge, double content}) _geometry(int depth) {
    final usable = math.max(0.0, _width - 2 * _sidePadding);
    final maxLevels = math.max(1, (usable * 0.4 / _indent).floor());
    final badge = depth > maxLevels;
    final levels = badge ? maxLevels : depth;
    final left =
        levels * _indent + (badge ? _badgeWidth : 0) + _chevronWidth + _gap;
    return (
      levels: levels,
      badge: badge,
      content: math.max(40.0, usable - left),
    );
  }

  /// Keeps the rows of opened strings wrapped to the current width.
  void _syncLayout(double width, TextScaler scaler, TextStyle style) {
    if (width == _width && scaler == _textScaler && style == _style) return;
    _width = width;
    _textScaler = scaler;
    _style = style;
    if (_openTexts.isNotEmpty) _rows = _flatten();
  }

  double _measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Whether a string's row already shows all of it.
  bool _fitsOnRow(_Row row) {
    final text = row.value as String;
    if (text.length > _previewLength || text.contains(RegExp(r'[\r\n\t]'))) {
      return false;
    }
    final geometry = _geometry(row.depth);
    var room = geometry.content;
    final label = _labelOf(row);
    if (label != null) {
      room -= math.min(_measure(label), geometry.content * _keyShare);
      room -= _measure(': ');
    }
    return _measure(_preview(text)) <= room;
  }

  // ------------------------------------------------------------- actions

  void _onTap(int index) {
    if (_rows[index].isLine) index = _ownerIndex(index);
    final value = _rows[index].value;
    if (_isContainer(value)) {
      if (_childCount(value) > 0) _toggleContainer(index);
    } else if (value is String) {
      _toggleText(index);
    }
  }

  int _ownerIndex(int index) {
    var i = index;
    while (i > 0 && _rows[i].isLine) {
      i--;
    }
    return i;
  }

  void _toggleContainer(int index) {
    final row = _rows[index];
    final value = row.value!;
    setState(() {
      _notice = null;
      if (_open.remove(value)) {
        _removeBelow(index);
      } else {
        _open.add(value);
        final added = <_Row>[];
        _appendChildren(added, row, value, row.depth + 1);
        _rows.insertAll(index + 1, added);
      }
    });
  }

  void _toggleText(int index) {
    final row = _rows[index];
    final key = _textKey(row);
    if (_openTexts.contains(key)) {
      setState(() {
        _openTexts.remove(key);
        _removeBelow(index);
      });
      return;
    }
    if (_fitsOnRow(row)) return;
    setState(() {
      _notice = null;
      _openTexts.add(key);
      _rows.insertAll(index + 1, _linesOf(row));
    });
  }

  /// Drops the rows shown inside the row at [index].
  void _removeBelow(int index) {
    final depth = _rows[index].depth;
    var end = index + 1;
    while (end < _rows.length && _rows[end].depth > depth) {
      end++;
    }
    _rows.removeRange(index + 1, end);
  }

  void _expandAll() {
    setState(() {
      final complete = _openLevels();
      _rows = _flatten();
      _notice = complete
          ? null
          : 'Stopped at ${formatCount(_rows.length)} rows to keep this quick. '
                'Tap a row to open it.';
    });
  }

  void _collapseAll() {
    setState(() {
      _open.clear();
      _openTexts.clear();
      _notice = null;
      _rows = _flatten();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Where [row] is, as a JSONPath: `$.items[3].name`, with keys that are
  /// not identifiers quoted: `$['odd key']`.
  String _pathOf(_Row row) {
    final segments = <String>[];
    for (_Row? at = row; at != null; at = at.parent) {
      final slot = at.slot;
      if (slot is int) {
        segments.add('[$slot]');
      } else if (slot is String) {
        if (_identifier.hasMatch(slot)) {
          segments.add('.$slot');
        } else {
          final quoted = slot.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
          segments.add("['$quoted']");
        }
      }
    }
    return '\$${segments.reversed.join()}';
  }

  Future<void> _showActions(int index) async {
    final row = _rows[_ownerIndex(index)];
    final path = _pathOf(row);
    final container = _isContainer(row.value);
    final choice = await showModalBottomSheet<_CopyChoice>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CopySheet(path: path, container: container),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _CopyChoice.value:
        final text = _copyText(row.value);
        if (text == null) {
          _snack('This is too large to copy.');
          return;
        }
        await _copy(text, container ? 'Copied as JSON' : 'Value copied');
      case _CopyChoice.path:
        await _copy(path, 'Path copied');
    }
  }

  /// [value] as copied: strings as they are, containers as indented JSON.
  /// Null when it is longer than the clipboard takes.
  static String? _copyText(Object? value) {
    if (value is String) return value.length > _copyLimit ? null : value;
    if (!_isContainer(value)) return '$value';
    return _indentedJson(value, _copyLimit);
  }

  /// [root] written as `JsonEncoder.withIndent('  ')` writes it, but with
  /// [JsonNumber]s as the file wrote them; null once longer than [limit].
  /// A loop rather than recursion, so any depth can be copied.
  static String? _indentedJson(Object? root, int limit) {
    final out = StringBuffer();
    final open = <_OpenContainer>[];
    void newLine(int depth) {
      out.write('\n');
      for (var i = 0; i < depth; i++) {
        out.write('  ');
      }
    }

    void begin(Object? value, int depth) {
      if (value is Map && value.isNotEmpty) {
        out.write('{');
        open.add(
          _OpenContainer(
            value.entries.map((e) => ('${e.key}', e.value)).iterator,
            depth,
            '}',
          ),
        );
      } else if (value is List && value.isNotEmpty) {
        out.write('[');
        open.add(
          _OpenContainer(value.map((e) => (null, e)).iterator, depth, ']'),
        );
      } else {
        out.write(switch (value) {
          Map() => '{}',
          List() => '[]',
          JsonNumber(:final text) => text,
          // JSON has no Infinity (which a number too large for a double
          // decodes to): write it as text.
          double() when !value.isFinite => jsonEncode('$value'),
          String() || num() || bool() || null => jsonEncode(value),
          _ => jsonEncode('$value'),
        });
      }
    }

    begin(root, 0);
    while (open.isNotEmpty) {
      if (out.length > limit) return null;
      final container = open.last;
      if (!container.members.moveNext()) {
        open.removeLast();
        newLine(container.depth);
        out.write(container.closer);
        continue;
      }
      if (container.started) out.write(',');
      container.started = true;
      newLine(container.depth + 1);
      final (key, value) = container.members.current;
      if (key != null) out.write('${jsonEncode(key)}: ');
      begin(value, container.depth + 1);
    }
    return out.length > limit ? null : out.toString();
  }

  Future<void> _copy(String text, String done) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _snack(done);
    } catch (_) {
      _snack('Could not copy.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --------------------------------------------------------------- build

  static String? _labelOf(_Row row) => switch (row.slot) {
    final int index => '$index',
    final String key => key.isEmpty ? '""' : key,
    _ => null,
  };

  /// A string as its row shows it: quoted, cut short, with line breaks and
  /// tabs written as escapes so it stays on one line.
  static String _preview(String text) {
    final shown = _clip(text, _previewLength);
    final escaped = shown
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped${shown.length < text.length ? '…' : ''}"';
  }

  String _summary() {
    final root = widget.value;
    return switch (root) {
      Map() => 'Object · ${_plural(root.length, 'key', 'keys')}',
      List() => 'Array · ${_plural(root.length, 'item', 'items')}',
      String() => 'Text',
      num() || JsonNumber() => 'Number',
      bool() => 'True or false',
      null => 'Null',
      _ => '',
    };
  }

  static String _plural(int count, String one, String many) =>
      '${formatCount(count)} ${count == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final palette = _Palette(colors);
    final scaler = MediaQuery.textScalerOf(context);
    _rowExtent = math.max(
      34.0,
      (scaler.scale(_baseStyle.fontSize!) * _baseStyle.height! + 14)
          .ceilToDouble(),
    );
    final root = widget.value;
    final hasChildren = root != null && _childCount(root) > 0;
    final notice = _notice;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Container(
            color: colors.cardBackground,
            padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _summary(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('json-expand-all'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colors.textPrimary,
                  ),
                  onPressed: hasChildren ? _expandAll : null,
                  icon: const Icon(Icons.unfold_more_rounded, size: 18),
                  label: const Text('Expand all'),
                ),
                TextButton.icon(
                  key: const ValueKey('json-collapse-all'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colors.textPrimary,
                  ),
                  onPressed: hasChildren ? _collapseAll : null,
                  icon: const Icon(Icons.unfold_less_rounded, size: 18),
                  label: const Text('Collapse all'),
                ),
              ],
            ),
          ),
          if (notice != null)
            Container(
              key: const ValueKey('json-expand-capped'),
              width: double.infinity,
              color: colors.accentSecondary.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                notice,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
            ),
          Expanded(
            child: root != null && _isContainer(root) && !hasChildren
                ? Center(
                    child: Text(
                      root is Map
                          ? 'This object is empty.'
                          : 'This array is empty.',
                      style: TextStyle(color: colors.textTertiary),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Measured with the style the rows' text will have,
                      // under this widget's own Material.
                      final style = DefaultTextStyle.of(
                        context,
                      ).style.merge(_baseStyle);
                      _syncLayout(constraints.maxWidth, scaler, style);
                      return Scrollbar(
                        controller: _scroll,
                        interactive: true,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(bottom: 24),
                          itemExtent: _rowExtent,
                          itemCount: _rows.length,
                          itemBuilder: (context, index) =>
                              _buildRow(index, palette),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int index, _Palette palette) {
    final row = _rows[index];
    final geometry = _geometry(row.depth);
    final value = row.value;
    final container = value != null && _isContainer(value);
    final open = container
        ? _open.contains(value)
        : value is String &&
              _openTexts.isNotEmpty &&
              _openTexts.contains(_textKey(row));
    final children = <Widget>[
      if (geometry.levels > 0)
        CustomPaint(
          size: Size(geometry.levels * _indent, _rowExtent),
          painter: _GuidePainter(
            levels: geometry.levels,
            step: _indent,
            offset: _chevronWidth / 2,
            color: palette.guide,
          ),
        ),
      if (geometry.badge)
        SizedBox(
          width: _badgeWidth,
          child: Text(
            '${row.depth + 1}',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(color: palette.hint, fontSize: 10),
          ),
        ),
      SizedBox(
        width: _chevronWidth,
        child: container && !row.isLine && _childCount(value) > 0
            ? Icon(
                open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                size: 18,
                color: palette.hint,
              )
            : null,
      ),
      const SizedBox(width: _gap),
    ];
    if (row.isLine) {
      children.add(
        Expanded(
          child: Text(
            row.line!,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: _style.copyWith(
              color: row.note ? palette.hint : palette.string,
              fontStyle: row.note ? FontStyle.italic : null,
            ),
          ),
        ),
      );
    } else {
      final label = _labelOf(row);
      if (label != null) {
        children
          ..add(
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: geometry.content * _keyShare,
              ),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: _style.copyWith(
                  color: row.slot is int ? palette.index : palette.key,
                ),
              ),
            ),
          )
          ..add(Text(': ', style: _style.copyWith(color: palette.hint)));
      }
      final (text, color, italic) = switch (value) {
        Map() => ('{${formatCount(value.length)}}', palette.hint, false),
        List() => ('[${formatCount(value.length)}]', palette.hint, false),
        String() when open => (
          _plural(value.length, 'character', 'characters'),
          palette.hint,
          true,
        ),
        String() => (_preview(value), palette.string, false),
        JsonNumber(:final text) => (text, palette.number, false),
        num() => ('$value', palette.number, false),
        bool() => ('$value', palette.boolean, false),
        null => ('null', palette.nothing, true),
        _ => ('$value', palette.string, false),
      };
      children.add(
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: _style.copyWith(
              color: color,
              fontStyle: italic ? FontStyle.italic : null,
            ),
          ),
        ),
      );
    }
    return InkWell(
      key: ValueKey('json-row-$index'),
      onTap: () => _onTap(index),
      onLongPress: () => _showActions(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _sidePadding),
        child: Row(children: children),
      ),
    );
  }
}

/// Colours for each kind of value, readable on both themes' backgrounds.
class _Palette {
  _Palette(AppColors colors)
    : key = colors.isDark ? const Color(0xFFCE93D8) : const Color(0xFF7B1FA2),
      string = colors.isDark
          ? const Color(0xFFA5D6A7)
          : const Color(0xFF2E7D32),
      number = colors.isDark
          ? const Color(0xFF81D4FA)
          : const Color(0xFF1565C0),
      boolean = colors.isDark
          ? const Color(0xFFFFCC80)
          : const Color(0xFFBF360C),
      nothing = colors.textSecondary,
      index = colors.textSecondary,
      hint = colors.textTertiary,
      guide = colors.textTertiary.withValues(alpha: 0.4);

  final Color key;
  final Color string;
  final Color number;
  final Color boolean;
  final Color nothing;
  final Color index;

  /// Brackets, counts, chevrons and other marks that are not the data.
  final Color hint;
  final Color guide;
}

/// The thin vertical lines that join a container's rows under its chevron.
class _GuidePainter extends CustomPainter {
  const _GuidePainter({
    required this.levels,
    required this.step,
    required this.offset,
    required this.color,
  });

  final int levels;
  final double step;
  final double offset;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i < levels; i++) {
      final x = (i * step + offset).floorToDouble() + 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GuidePainter oldDelegate) =>
      oldDelegate.levels != levels ||
      oldDelegate.step != step ||
      oldDelegate.offset != offset ||
      oldDelegate.color != color;
}

/// A container [_JsonTreeViewState._indentedJson] is writing: the members
/// left, as (key, value) with no key for an array, how deep it is, and the
/// bracket that closes it.
class _OpenContainer {
  _OpenContainer(this.members, this.depth, this.closer);

  final Iterator<(String?, Object?)> members;
  final int depth;
  final String closer;

  /// A member has been written, so the next needs a comma.
  bool started = false;
}

class _CopySheet extends StatelessWidget {
  const _CopySheet({required this.path, required this.container});

  final String path;
  final bool container;

  @override
  Widget build(BuildContext context) {
    // Read in build: AppColors.of listens, which is only allowed here.
    final colors = AppColors.of(context);
    // A Material, not a coloured box: list tiles draw their ink on it.
    return Material(
      color: colors.cardBackground,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
              child: Text(
                path,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            Divider(color: colors.divider, height: 1),
            ListTile(
              key: const ValueKey('json-copy-value'),
              leading: Icon(Icons.copy_rounded, color: colors.textSecondary),
              title: Text(
                'Copy value',
                style: TextStyle(color: colors.textPrimary),
              ),
              subtitle: container
                  ? Text(
                      'As formatted JSON',
                      style: TextStyle(color: colors.textTertiary),
                    )
                  : null,
              onTap: () => Navigator.pop(context, _CopyChoice.value),
            ),
            ListTile(
              key: const ValueKey('json-copy-path'),
              leading: Icon(
                Icons.account_tree_outlined,
                color: colors.textSecondary,
              ),
              title: Text(
                'Copy path',
                style: TextStyle(color: colors.textPrimary),
              ),
              onTap: () => Navigator.pop(context, _CopyChoice.path),
            ),
          ],
        ),
      ),
    );
  }
}
