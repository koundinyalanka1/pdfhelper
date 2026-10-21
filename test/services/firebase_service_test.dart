import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/firebase_service.dart';

/// Android's record of the app being stopped for memory becomes a
/// non-fatal Crashlytics event; anything else in the record is ignored.
void main() {
  test('a low-memory exit becomes an event with its size', () {
    final event = MemoryExit.fromMap({
      'reason': 'low_memory',
      'timestamp': 1,
      'pssKb': 300 * 1024,
      'foreground': true,
      'description': null,
    });
    expect(event, isNotNull);
    expect(event!.reason, 'low_memory');
    expect(event.foreground, isTrue);
    expect(event.pssKb, 300 * 1024);
    expect(event.toString(), 'MemoryExit(low_memory, foreground, 300 MB)');
  });

  test('records without a reason, or not maps, are skipped', () {
    expect(MemoryExit.fromMap(null), isNull);
    expect(MemoryExit.fromMap('low_memory'), isNull);
    expect(MemoryExit.fromMap({'reason': ''}), isNull);
    final background = MemoryExit.fromMap({
      'reason': 'excessive_resource_usage',
      'pssKb': 0,
    });
    expect(background!.foreground, isFalse);
    expect(background.pssKb, isNull);
    expect(background.toString(), 'MemoryExit(excessive_resource_usage, background)');
  });
}
