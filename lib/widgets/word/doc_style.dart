import 'package:flutter/material.dart';
import 'package:flutter_word_core/flutter_word_core.dart';

/// How document formatting (in points) looks on screen.
///
/// The document screen reflows text to the screen's width, the way Word's
/// mobile view does: sizes keep their proportions, scaled by [scale]
/// logical pixels per point.
class DocLook {
  const DocLook({this.scale = 1.3});

  /// Logical pixels per point.
  final double scale;

  static const Color ink = Color(0xFF1F1F1F);
  static const Color paper = Colors.white;
  static const Color linkColor = Color(0xFF0563C1);

  /// The theme on the white page, whatever the app's theme: anything on
  /// it without a colour of its own ("Loading rows…", buttons, icons)
  /// is drawn dark on white rather than in the dark theme's light text.
  static final ThemeData paperTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2B579A),
      brightness: Brightness.light,
    ),
  );

  /// Puts [child] on the page: the paper's theme and ink.
  static Widget onPaper(Widget child) => Theme(
    data: paperTheme,
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: ink),
      child: child,
    ),
  );

  /// Fonts Android has (or close enough) for the families documents name.
  static String? family(String font) {
    final f = font.toLowerCase();
    if (f.isEmpty) return null;
    const serif = [
      'times',
      'cambria',
      'georgia',
      'garamond',
      'book antiqua',
      'palatino',
      'century',
      'caladea',
      'liberation serif',
      'noto serif',
      'bookman',
      'constantia',
      'mangal',
    ];
    const mono = ['courier', 'consolas', 'mono', 'lucida console'];
    if (mono.any(f.contains)) return 'monospace';
    if (serif.any(f.contains)) return 'serif';
    return null;
  }

  double lineHeight(LineSpacing line, double fontPt) {
    switch (line.rule) {
      case 'exactly':
        return (line.value / fontPt).clamp(0.6, 6.0);
      case 'atLeast':
        return (line.value / fontPt).clamp(1.15, 6.0);
      default:
        return (1.17 * line.value).clamp(0.8, 6.0);
    }
  }

  TextStyle text(RunStyle s, {LineSpacing? line, String? link}) {
    final decorations = <TextDecoration>[
      if (s.underlined || link != null) TextDecoration.underline,
      if (s.strike) TextDecoration.lineThrough,
    ];
    final small = s.vert != null;
    final size = (small ? s.size * 0.65 : s.size) * scale;
    return TextStyle(
      fontSize: size,
      fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
      fontFamily: family(s.font),
      color: s.color != null
          ? Color(0xFF000000 | s.color!)
          : (link != null ? linkColor : ink),
      backgroundColor: s.highlight == null
          ? null
          : Color(0xFF000000 | s.highlight!),
      decoration: decorations.isEmpty
          ? TextDecoration.none
          : TextDecoration.combine(decorations),
      decorationStyle: switch (s.underline) {
        'double' => TextDecorationStyle.double,
        'dotted' || 'dottedHeavy' => TextDecorationStyle.dotted,
        'dash' || 'dashLong' || 'dashedHeavy' => TextDecorationStyle.dashed,
        'wave' || 'wavyHeavy' || 'wavyDouble' => TextDecorationStyle.wavy,
        _ => TextDecorationStyle.solid,
      },
      height: line == null ? null : lineHeight(line, s.size),
      letterSpacing: s.smallCaps ? 0.5 : null,
    );
  }

  TextAlign align(ParaAlign a) => switch (a) {
    ParaAlign.center => TextAlign.center,
    ParaAlign.right => TextAlign.right,
    ParaAlign.justify => TextAlign.justify,
    ParaAlign.left => TextAlign.left,
  };

  /// Indents and spacing around a paragraph's text, in pixels, kept
  /// sensible on a narrow screen.
  EdgeInsets padding(ParaStyle s, double width) {
    final maxIndent = width * 0.4;
    final left = (s.indentLeft * scale).clamp(0.0, maxIndent);
    final right = (s.indentRight * scale).clamp(0.0, maxIndent);
    return EdgeInsets.fromLTRB(
      left,
      (s.spaceBefore * scale).clamp(0.0, 80.0),
      right,
      (s.spaceAfter * scale).clamp(0.0, 80.0),
    );
  }

  /// Text as it shows: capitals for all-caps runs.
  static String shown(String text, RunStyle s) =>
      s.caps || s.smallCaps ? text.toUpperCase() : text;
}

/// Colours offered for text and highlight.
const List<int> docTextColors = [
  0x000000,
  0x404040,
  0x7F7F7F,
  0xC00000,
  0xFF0000,
  0xFFC000,
  0x00B050,
  0x0070C0,
  0x002060,
  0x7030A0,
];

const List<int> docHighlightColors = [
  0xFFFF00,
  0x00FF00,
  0x00FFFF,
  0xFF00FF,
  0xC0C0C0,
  0xFFC000,
];

const List<double> docFontSizes = [
  8,
  9,
  10,
  10.5,
  11,
  12,
  14,
  16,
  18,
  20,
  24,
  28,
  36,
  48,
  72,
];
