import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/providers/theme_provider.dart';
import 'package:pdfhelper/widgets/password_prompt.dart';
import 'package:provider/provider.dart';

/// The prompt used to exist only inside the Tools tab, so a locked PDF opened
/// from anywhere else reported itself as having no pages. It is shared now,
/// and these tests hold it to the contract every caller relies on: the typed
/// password comes back, and backing out comes back as null rather than an
/// empty string that would read as "no password".
void main() {
  Widget host(void Function(BuildContext) onReady) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => onReady(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('returns the typed password', (tester) async {
    String? result;
    var called = false;
    await tester.pumpWidget(
      host((context) async {
        called = true;
        result = await showPdfPasswordPrompt(context);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Password required'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, 'hunter2');
  });

  testWidgets('cancelling returns null, not an empty password', (tester) async {
    String? result = 'sentinel';
    await tester.pumpWidget(
      host((context) async {
        result = await showPdfPasswordPrompt(context);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('a retry says the last password was wrong', (tester) async {
    await tester.pumpWidget(
      host((context) => showPdfPasswordPrompt(context, retry: true)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Wrong password'), findsOneWidget);
    expect(find.textContaining('did not work'), findsOneWidget);
  });

  testWidgets('names the file when one is given', (tester) async {
    await tester.pumpWidget(
      host(
        (context) => showPdfPasswordPrompt(context, fileName: 'Payslip.pdf'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Payslip.pdf'), findsOneWidget);
  });

  testWidgets('the field is obscured', (tester) async {
    await tester.pumpWidget(host((context) => showPdfPasswordPrompt(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
  });
}
