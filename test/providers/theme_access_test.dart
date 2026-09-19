import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the one rule that keeps theme reads from crashing: `context.watch()`
/// asserts unless a build is in progress, so it may only be called from
/// `build`, and screens must hold their colours in a field rather than behind
/// a getter.
///
/// A getter looks harmless right up until some gesture handler, popup
/// `itemBuilder` or async callback reads it outside the build phase — and
/// then it throws on that one path, once someone taps it. That is a bug this
/// app has shipped into twice, which is why it is checked here rather than
/// left to review.
void main() {
  group('theme access convention', () {
    /// Every Dart source file in the app, as (path, lines).
    List<(String, List<String>)> sources() {
      return Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => (f.path, f.readAsLinesSync()))
          .toList();
    }

    /// Strips the doc comments that *describe* this rule.
    bool isCode(String line) {
      final trimmed = line.trimLeft();
      return !trimmed.startsWith('//');
    }

    test('no getter watches the provider', () {
      final offenders = <String>[];
      for (final (path, lines) in sources()) {
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!isCode(line)) continue;
          if (RegExp(r'\bget\s+\w+\s*=>').hasMatch(line) &&
              line.contains('context.watch')) {
            offenders.add('$path:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Assign the value to a field at the top of build() instead — see '
            'AppColors.of. Offending getters:\n${offenders.join('\n')}',
      );
    });

    test('every watch happens inside build', () {
      // Nearest preceding member declaration. Exactly two spaces of indent:
      // anything deeper is a continuation line, which would otherwise be
      // mistaken for a declaration of its own.
      final member = RegExp(r'^  (?! )[\w<>?,\[\]\s\.]*\b(\w+)\s*\(');
      final offenders = <String>[];

      for (final (path, lines) in sources()) {
        var enclosing = '<top level>';
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!isCode(line)) continue;
          final match = member.firstMatch(line);
          if (match != null) enclosing = match.group(1)!;
          if (!line.contains('context.watch')) continue;
          // `AppColors.of` is the sanctioned wrapper; it documents the rule
          // and is only ever called from build.
          if (enclosing == 'build' || enclosing == 'of') continue;
          offenders.add('$path:${i + 1}: in $enclosing() — ${line.trim()}');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'context.watch() outside build() throws when the surrounding code '
            'runs from a callback:\n${offenders.join('\n')}',
      );
    });
  });

  group('AppColors.of', () {
    testWidgets('tracks the provider and repaints on a theme change', (
      tester,
    ) async {
      // The provider persists every change before notifying, so without this
      // the toggle below never completes and nothing rebuilds.
      SharedPreferences.setMockInitialValues({});
      final provider = ThemeProvider();
      AppColors? seen;

      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                seen = AppColors.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      final before = seen!.isDark;
      await tester.runAsync(() => provider.toggleTheme(!before));
      await tester.pump();

      expect(
        seen!.isDark,
        !before,
        reason: 'the screen should rebuild with the new palette',
      );
    });
  });
}
