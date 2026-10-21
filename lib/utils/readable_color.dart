import 'package:flutter/painting.dart';

/// Colours from documents (a cell's font colour, a fill) shown on the
/// app's own backgrounds, kept readable in the dark theme.
///
/// Documents are written for white paper: black text, pale fills. On a
/// dark background black text disappears, and light text set on a pale
/// fill disappears too. These helpers change only what is shown; the
/// document keeps its colours.

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

/// The WCAG contrast ratio between two colours, from 1 to 21 (alpha is
/// ignored).
double contrastRatio(Color a, Color b) {
  final la = a.withValues(alpha: 1).computeLuminance();
  final lb = b.withValues(alpha: 1).computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Whether light text reads better than dark text on [background].
bool prefersLightText(Color background) =>
    contrastRatio(_white, background) >= contrastRatio(_black, background);

/// Black or white, whichever reads better on [background].
Color textOn(Color background) =>
    prefersLightText(background) ? _white : _black;

/// [foreground] when it reads on [background] at [minRatio] (4.5:1 is the
/// WCAG minimum for text, 3:1 for icons and large text); otherwise the same
/// hue made lighter (on a dark background) or darker (on a light one) until
/// it does.
Color readableOn(
  Color foreground,
  Color background, {
  double minRatio = 4.5,
}) {
  final opaque = foreground.withValues(alpha: 1);
  if (contrastRatio(opaque, background) >= minRatio) return foreground;
  final lighten = prefersLightText(background);
  final hsl = HSLColor.fromColor(opaque);
  for (var step = 1; step < 20; step++) {
    final t = step / 20;
    final l = lighten
        ? hsl.lightness + (1 - hsl.lightness) * t
        : hsl.lightness * (1 - t);
    final c = hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
    if (contrastRatio(c, background) >= minRatio) return c;
  }
  return lighten ? _white : _black;
}

/// A document's fill as the dark theme shows it: white and near-white
/// become [background], other pale fills become dark shades of the same
/// hue (so light text reads on them), and dark fills stay as they are.
Color darkThemeFill(Color fill, Color background) {
  final hsl = HSLColor.fromColor(fill.withValues(alpha: 1));
  final l = hsl.lightness;
  if (l <= 0.5) return fill;
  if ((l > 0.94 && hsl.saturation < 0.25) || l > 0.98) return background;
  final base = HSLColor.fromColor(background.withValues(alpha: 1)).lightness;
  // 0.5 stays 0.5 and white lands on the background, in a straight line.
  final shown = base + (1 - l) * (0.5 - base) / 0.5;
  final saturation = hsl.saturation * (1 - 0.3 * (l - 0.5) / 0.5);
  return hsl
      .withLightness(shown.clamp(0.0, 1.0))
      .withSaturation(saturation.clamp(0.0, 1.0))
      .toColor();
}
