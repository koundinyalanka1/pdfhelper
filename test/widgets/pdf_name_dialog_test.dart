import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/widgets/pdf_name_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dialog's text controller used to be disposed as soon as the result
/// arrived, while the closing animation was still rebuilding the field.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget app(void Function(BuildContext) onReady) => ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(
      home: Builder(
        builder: (context) {
          onReady(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  for (final (action, expected) in [('Cancel', null), ('Create', 'Invoice')]) {
    testWidgets('closing with $action survives the exit animation', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(app((ready) => context = ready));
      final result = askPdfName(context: context, initialName: 'Invoice');
      await tester.pumpAndSettle();
      expect(find.text('Invoice'), findsOneWidget);

      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(await result, expected);
    });
  }
}
