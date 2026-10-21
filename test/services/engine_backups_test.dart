import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/services/engine_backups.dart';

void main() {
  const gb = 1024 * 1024 * 1024;

  test('the cell budget grows with the phone\'s memory', () {
    expect(EngineBackups.cellBudgetFor(2 * gb), 2000000);
    expect(EngineBackups.cellBudgetFor(4 * gb), 3000000);
    expect(EngineBackups.cellBudgetFor(8 * gb), 4000000);
  });

  test('MemTotal is read from /proc/meminfo in bytes', () {
    const text =
        'MemTotal:        3884512 kB\n'
        'MemFree:          123456 kB\n';
    expect(EngineBackups.parseMemTotal(text), 3884512 * 1024);
    expect(EngineBackups.parseMemTotal('MemFree: 1 kB\n'), isNull);
  });

  test('the sheet engine takes a cell budget', () {
    expect(SheetCore.setCellBudget(3000000), 3000000);
    expect(SheetCore.setCellBudget(0), isNull);
    // Back to the engine's base budget for the tests after this one.
    SheetCore.setCellBudget(2000000);
  }, skip: !SheetCore.isAvailable);
}
