import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/widgets/banner_ad_widget.dart';

void main() {
  testWidgets('unavailable home banner adds no gap above the system inset', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(bottom: 24)),
          child: Scaffold(
            body: SizedBox.expand(key: ValueKey('body')),
            bottomNavigationBar: SafeArea(
              top: false,
              child: BannerAdWidget(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(BannerAdWidget)).height, 0);
    expect(tester.getSize(find.byKey(const ValueKey('body'))).height, 576);
  });

  testWidgets('a narrow window leaves no banner gap or overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(key: ValueKey('body')),
          bottomNavigationBar: BannerAdWidget(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(BannerAdWidget)).height, 0);
    expect(tester.getSize(find.byKey(const ValueKey('body'))).height, 600);
    expect(tester.takeException(), isNull);
  });
}
