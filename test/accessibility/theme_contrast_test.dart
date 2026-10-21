import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';

import 'guidelines.dart';

/// The app's text colours against the surfaces they are drawn on, in both
/// themes. WCAG asks 4.5:1 of small text; the tertiary colour, used for
/// hints and footers, measured 2.65:1 before it was raised.
void main() {
  for (final dark in [false, true]) {
    final colors = AppColors(dark);
    final theme = dark ? 'dark' : 'light';
    final texts = {
      'textPrimary': colors.textPrimary,
      'textSecondary': colors.textSecondary,
      'textTertiary': colors.textTertiary,
    };
    final surfaces = {
      'background': colors.background,
      'cardBackground': colors.cardBackground,
    };
    for (final text in texts.entries) {
      for (final surface in surfaces.entries) {
        test(
          '${text.key} on ${surface.key} reads at 4.5:1 or more ($theme)',
          () {
            // The colours are partly transparent: what shows is the blend.
            final shown = Color.alphaBlend(text.value, surface.value);
            final ratio = contrastRatio(shown, surface.value);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '${text.key} measured ${ratio.toStringAsFixed(2)}:1',
            );
          },
        );
      }
    }

    test('the text colours still step down from primary to tertiary '
        '($theme)', () {
      double on(Color text) => contrastRatio(
        Color.alphaBlend(text, colors.background),
        colors.background,
      );
      expect(on(colors.textPrimary), greaterThan(on(colors.textSecondary)));
      expect(on(colors.textSecondary), greaterThan(on(colors.textTertiary)));
    });
  }
}
