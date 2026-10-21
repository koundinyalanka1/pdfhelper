import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/utils/readable_color.dart';

void main() {
  const darkGrid = Color(0xFF1E1E26);
  const card = Color(0xFF16213E);

  test('contrast ratios match WCAG', () {
    expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    expect(contrastRatio(darkGrid, darkGrid), closeTo(1, 0.001));
  });

  test('black text turns light on a dark background', () {
    final shown = readableOn(const Color(0xFF000000), darkGrid);
    expect(contrastRatio(shown, darkGrid), greaterThanOrEqualTo(4.5));
  });

  test('readable colours are left alone', () {
    const white = Color(0xFFFFFFFF);
    expect(readableOn(white, darkGrid), white);
    const darkBlue = Color(0xFF1F4E78);
    expect(readableOn(darkBlue, const Color(0xFFFFFFFF)), darkBlue);
  });

  test('a dim colour keeps its hue while it is made readable', () {
    const navy = Color(0xFF002060);
    final shown = readableOn(navy, darkGrid);
    expect(contrastRatio(shown, darkGrid), greaterThanOrEqualTo(4.5));
    expect(
      HSLColor.fromColor(shown).hue,
      closeTo(HSLColor.fromColor(navy).hue, 1),
    );
    // Word's blue, as an icon on the dark theme's card.
    final accent = readableOn(const Color(0xFF2B579A), card, minRatio: 3);
    expect(contrastRatio(accent, card), greaterThanOrEqualTo(3));
  });

  test('light text on a pale fill turns dark', () {
    const paleYellow = Color(0xFFFFF2CC);
    final shown = readableOn(const Color(0xFFFFFFFF), paleYellow);
    expect(contrastRatio(shown, paleYellow), greaterThanOrEqualTo(4.5));
    expect(textOn(paleYellow), const Color(0xFF000000));
    expect(textOn(darkGrid), const Color(0xFFFFFFFF));
  });

  test('the dark theme shows white fills as the background and pale ones dark', () {
    expect(darkThemeFill(const Color(0xFFFFFFFF), darkGrid), darkGrid);
    expect(darkThemeFill(const Color(0xFFF2F2F2), darkGrid), darkGrid);
    const paleYellow = Color(0xFFFFF2CC);
    final shown = darkThemeFill(paleYellow, darkGrid);
    expect(HSLColor.fromColor(shown).lightness, lessThan(0.3));
    expect(
      HSLColor.fromColor(shown).hue,
      closeTo(HSLColor.fromColor(paleYellow).hue, 1),
    );
    // White text reads on it.
    expect(contrastRatio(const Color(0xFFFFFFFF), shown), greaterThanOrEqualTo(4.5));
    // Dark fills, such as a navy header, are kept.
    const navy = Color(0xFF1F4E78);
    expect(darkThemeFill(navy, darkGrid), navy);
  });
}
