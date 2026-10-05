import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/scan_image_store.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('scan_store_test');
    FakePathProvider.install(root);
  });
  tearDown(() {
    FakePathProvider.restore();
    root.deleteSync(recursive: true);
  });

  test(
    'discard deletes owned copies while preserving imported originals',
    () async {
      final original = File('${root.path}/gallery.jpg')
        ..writeAsBytesSync([1, 2]);
      final store = ScanImageStore();
      final first = await store.importFile(original.path);
      final second = await store.importFile(original.path);
      expect(first, contains('/temporary/scan_images/'));
      await store.dispose();
      expect(File(first).existsSync(), isFalse);
      expect(File(second).existsSync(), isFalse);
      expect(original.readAsBytesSync(), [1, 2]);
    },
  );

  test(
    'successful edit transfers ownership until the scan is saved/discarded',
    () async {
      final editor = ScanImageStore();
      final scan = ScanImageStore();
      final output = await editor.write(Uint8List.fromList([3, 4]));
      scan.adopt(output);
      editor.release(output);
      await editor.dispose();
      expect(File(output).readAsBytesSync(), [3, 4]);
      await scan.clear();
      expect(File(output).existsSync(), isFalse);
    },
  );

  test(
    'failed output keeps the draft and disposal waits for an active reader',
    () async {
      final store = ScanImageStore();
      final image = await store.write(Uint8List.fromList([5]));
      await expectLater(
        store.retainWhile<void>(() async => throw StateError('save failed')),
        throwsStateError,
      );
      expect(File(image).existsSync(), isTrue);
      final finished = Completer<void>();
      final reader = store.retainWhile(() => finished.future);
      await store.dispose();
      expect(File(image).existsSync(), isTrue);
      finished.complete();
      await reader;
      expect(File(image).existsSync(), isFalse);
    },
  );
}
