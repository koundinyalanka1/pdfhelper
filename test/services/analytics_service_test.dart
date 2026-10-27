import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/models/doc_kind.dart';
import 'package:pdfhelper/services/analytics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnalyticsService (uninitialized safe no-ops)', () {
    test('logDocOpened executes safely without throwing', () async {
      await expectLater(
        AnalyticsService.instance.logDocOpened(
          kind: DocKind.pdf,
          extension: '.pdf',
        ),
        completes,
      );
      await expectLater(
        AnalyticsService.instance.logDocOpened(
          kind: DocKind.word,
          extension: 'docx',
        ),
        completes,
      );
    });

    test('logDocAction executes safely without throwing', () async {
      await expectLater(
        AnalyticsService.instance.logDocAction(
          action: 'merge',
          kind: DocKind.pdf,
          parameters: {'page_count': 5},
        ),
        completes,
      );
      await expectLater(
        AnalyticsService.instance.logDocAction(
          action: 'save',
          kind: DocKind.sheet,
        ),
        completes,
      );
    });

    test('logScreenView executes safely without throwing', () async {
      await expectLater(
        AnalyticsService.instance.logScreenView(screenName: 'HomeScreen'),
        completes,
      );
    });

    test('observer is null when not initialized', () {
      expect(AnalyticsService.instance.observer, isNull);
    });
  });
}
