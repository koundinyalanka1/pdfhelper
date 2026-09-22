import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/recent_files_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RecentFilesService.resetCacheForTesting();
  });

  test(
    'concurrent cold-start opens preserve every document after restart',
    () async {
      await Future.wait(
        List.generate(20, (i) => RecentFilesService.markOpened('/$i.pdf')),
      );
      RecentFilesService.resetCacheForTesting();
      expect((await RecentFilesService.recents()).toSet(), {
        for (var i = 0; i < 20; i++) '/$i.pdf',
      });
    },
  );

  test('concurrent cold-start stars preserve every selection', () async {
    await Future.wait(
      List.generate(20, (i) => RecentFilesService.toggleStar('/$i.pdf')),
    );
    RecentFilesService.resetCacheForTesting();
    expect(await RecentFilesService.starred(), {
      for (var i = 0; i < 20; i++) '/$i.pdf',
    });
  });

  group('recents', () {
    test('start empty', () async {
      expect(await RecentFilesService.recents(), isEmpty);
    });

    test('most recently opened comes first', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.markOpened('/b.pdf');
      await RecentFilesService.markOpened('/c.pdf');

      expect(await RecentFilesService.recents(), [
        '/c.pdf',
        '/b.pdf',
        '/a.pdf',
      ]);
    });

    test(
      'reopening moves a file to the front without duplicating it',
      () async {
        await RecentFilesService.markOpened('/a.pdf');
        await RecentFilesService.markOpened('/b.pdf');
        await RecentFilesService.markOpened('/a.pdf');

        expect(await RecentFilesService.recents(), ['/a.pdf', '/b.pdf']);
      },
    );

    test('ignores an empty path', () async {
      await RecentFilesService.markOpened('');
      expect(await RecentFilesService.recents(), isEmpty);
    });

    test('caps the list, dropping the oldest', () async {
      for (var i = 0; i < RecentFilesService.maxRecents + 10; i++) {
        await RecentFilesService.markOpened('/file$i.pdf');
      }

      final recents = await RecentFilesService.recents();
      expect(recents, hasLength(RecentFilesService.maxRecents));
      expect(recents.first, '/file${RecentFilesService.maxRecents + 9}.pdf');
      expect(recents, isNot(contains('/file0.pdf')));
    });

    test('survives a restart', () async {
      await RecentFilesService.markOpened('/kept.pdf');

      // A cold start re-reads from storage rather than the in-memory copy.
      RecentFilesService.resetCacheForTesting();

      expect(await RecentFilesService.recents(), ['/kept.pdf']);
    });

    test('records when a file was opened', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await RecentFilesService.markOpened('/a.pdf');

      final opened = await RecentFilesService.lastOpened('/a.pdf');

      expect(opened, isNotNull);
      expect(opened!.isAfter(before), isTrue);
      expect(await RecentFilesService.lastOpened('/never.pdf'), isNull);
    });

    test('clearRecents empties the list', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.clearRecents();
      expect(await RecentFilesService.recents(), isEmpty);
    });

    test('ignores a corrupt stored value', () async {
      SharedPreferences.setMockInitialValues({
        'library.recents.v1': 'not json at all',
      });
      RecentFilesService.resetCacheForTesting();

      expect(await RecentFilesService.recents(), isEmpty);
    });

    test('skips malformed records inside a valid list', () async {
      SharedPreferences.setMockInitialValues({
        'library.recents.v1':
            '[{"p":"/good.pdf","t":1},{"t":2},{"p":123},{"p":""}]',
      });
      RecentFilesService.resetCacheForTesting();

      expect(await RecentFilesService.recents(), ['/good.pdf']);
    });
  });

  group('starring', () {
    test('toggles on and off', () async {
      expect(await RecentFilesService.isStarred('/a.pdf'), isFalse);

      expect(await RecentFilesService.toggleStar('/a.pdf'), isTrue);
      expect(await RecentFilesService.isStarred('/a.pdf'), isTrue);

      expect(await RecentFilesService.toggleStar('/a.pdf'), isFalse);
      expect(await RecentFilesService.isStarred('/a.pdf'), isFalse);
    });

    test('survives a restart', () async {
      await RecentFilesService.toggleStar('/a.pdf');
      RecentFilesService.resetCacheForTesting();

      expect(await RecentFilesService.starred(), {'/a.pdf'});
    });

    test('starred() hands back a copy, not the live set', () async {
      await RecentFilesService.toggleStar('/a.pdf');

      (await RecentFilesService.starred()).clear();

      expect(await RecentFilesService.isStarred('/a.pdf'), isTrue);
    });
  });

  group('forget', () {
    test('removes a path from both lists', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.markOpened('/b.pdf');
      await RecentFilesService.toggleStar('/a.pdf');

      await RecentFilesService.forget('/a.pdf');

      expect(await RecentFilesService.recents(), ['/b.pdf']);
      expect(await RecentFilesService.isStarred('/a.pdf'), isFalse);
    });

    test('is a no-op for an unknown path', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.forget('/unknown.pdf');
      expect(await RecentFilesService.recents(), ['/a.pdf']);
    });
  });

  group('rename', () {
    test('follows the file, keeping its position', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.markOpened('/b.pdf');
      await RecentFilesService.markOpened('/c.pdf');

      await RecentFilesService.rename('/b.pdf', '/renamed.pdf');

      expect(await RecentFilesService.recents(), [
        '/c.pdf',
        '/renamed.pdf',
        '/a.pdf',
      ]);
    });

    test('carries a star across', () async {
      await RecentFilesService.toggleStar('/a.pdf');

      await RecentFilesService.rename('/a.pdf', '/b.pdf');

      expect(await RecentFilesService.isStarred('/a.pdf'), isFalse);
      expect(await RecentFilesService.isStarred('/b.pdf'), isTrue);
    });

    test('does not star an unstarred file that is renamed', () async {
      await RecentFilesService.markOpened('/a.pdf');
      await RecentFilesService.rename('/a.pdf', '/b.pdf');
      expect(await RecentFilesService.starred(), isEmpty);
    });
  });
}
