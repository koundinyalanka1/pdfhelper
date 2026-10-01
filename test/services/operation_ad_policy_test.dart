import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/operation_ad_policy.dart';

void main() {
  test('mixed successful operations show ads on 4, 8 and 12 only', () async {
    final shownAt = <int>[];
    var count = 0;
    final policy = OperationAdPolicy(
      showInterstitial: (_) async => shownAt.add(count),
    );
    for (var i = 0; i < 13; i++) {
      count++;
      await policy.completed(
        PdfOperation.values[i % PdfOperation.values.length],
      );
    }
    expect(shownAt, [4, 8, 12]);
  });

  test(
    'hidden completion counts but never presents over another screen',
    () async {
      var ads = 0;
      final policy = OperationAdPolicy(showInterstitial: (_) async => ads++);
      for (var i = 0; i < 4; i++) {
        await policy.completed(PdfOperation.create, allowPresentation: false);
      }
      expect(ads, 0);
      for (var i = 0; i < 3; i++) {
        await policy.completed(PdfOperation.merge);
      }
      expect(ads, 0);
      await policy.completed(PdfOperation.split);
      expect(ads, 1);
    },
  );

  test(
    'result navigation waits for dismissal, with no overlapping ads',
    () async {
      final dismissed = Completer<void>();
      var ads = 0;
      final policy = OperationAdPolicy(
        showInterstitial: (_) {
          ads++;
          return dismissed.future;
        },
      );
      for (var i = 0; i < 3; i++) {
        await policy.completed(PdfOperation.merge);
      }
      var firstFinished = false;
      var secondFinished = false;
      final first = policy
          .completed(PdfOperation.split)
          .then((_) => firstFinished = true);
      for (var i = 0; i < 3; i++) {
        await policy.completed(PdfOperation.create);
      }
      final second = policy
          .completed(PdfOperation.organize)
          .then((_) => secondFinished = true);
      expect(ads, 1);
      expect(firstFinished, false);
      expect(secondFinished, false);
      dismissed.complete();
      await Future.wait([first, second]);
      expect(firstFinished, true);
      expect(secondFinished, true);
      for (var i = 0; i < 4; i++) {
        await policy.completed(PdfOperation.merge);
      }
      expect(ads, 2);
    },
  );

  test(
    'an unavailable ad is skipped without making the next operation show',
    () async {
      var available = false;
      var ads = 0;
      final policy = OperationAdPolicy(
        showInterstitial: (_) async {
          if (available) ads++;
        },
      );
      for (var i = 0; i < 4; i++) {
        await policy.completed(PdfOperation.create);
      }
      available = true;
      for (var i = 0; i < 3; i++) {
        await policy.completed(PdfOperation.create);
      }
      expect(ads, 0);
      await policy.completed(PdfOperation.create);
      expect(ads, 1);
    },
  );
}
