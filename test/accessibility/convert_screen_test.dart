import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/screens/convert_screen.dart';

import 'guidelines.dart';

/// The Scan tab's camera page at every phone width, text size and theme:
/// its top bar and controls fit (the title and focus hint used to push the
/// flash button off a narrow phone), and they meet the guidelines.
void main() {
  useEmptyAppFolders();

  const camera = MethodChannel('plugins.flutter.io/camera');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (_) async => 1);
    // A phone whose camera cannot be reached: the page still shows its
    // bar and controls, without a live preview to measure contrast over.
    messenger.setMockMethodCallHandler(camera, (call) async {
      if (call.method == 'availableCameras') return <Object>[];
      return null;
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(camera, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });

  for (final setup in phoneSetups) {
    testWidgets('the camera page meets the guidelines at $setup', (
      tester,
    ) async {
      usePhone(tester, setup);
      await tester.pumpWidget(themedApp(const ConvertScreen()));
      await settle(tester);
      expect(find.text('Gallery'), findsOneWidget);
      await expectGuidelinesMet(tester);
    });
  }
}
