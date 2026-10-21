import 'dart:io';

import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:flutter_word_core/flutter_word_core.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/error_logger.dart';

/// Backups of what saves replace: each editor engine keeps the previous
/// version of every file it saves in the app's private `Backups` folder
/// (500 MB at most in all, the oldest dropped first), so a save that went
/// wrong can still be undone by hand.
class EngineBackups {
  EngineBackups._();

  /// The private folder the engines keep backups in.
  static Future<Directory> directory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/Backups');
  }

  /// The backups in [dir] (the engines' folder unless given), newest
  /// first. Hidden files, such as a backup still being written, are left
  /// out. Never throws: an unreadable folder lists nothing.
  static Future<List<BackupFile>> list([Directory? dir]) async {
    try {
      final folder = dir ?? await directory();
      if (!await folder.exists()) return const [];
      final found = <BackupFile>[];
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.isEmpty || name.startsWith('.')) continue;
        final stat = await entity.stat();
        found.add(BackupFile(entity.path, name, stat.modified, stat.size));
      }
      found.sort((a, b) => b.modified.compareTo(a.modified));
      return found;
    } catch (e, stack) {
      logError('EngineBackups.list', e, stack);
      return const [];
    }
  }

  /// Point every editor engine at the backup folder. Each engine library
  /// keeps its own setting, so all four are told. Never throws: an engine
  /// that is missing, or older than backups, just keeps none.
  static Future<void> enable() async {
    try {
      final dir = await directory();
      await dir.create(recursive: true);
      TextCore.setBackupDir(dir.path);
      SheetCore.setBackupDir(dir.path);
      WordCore.setBackupDir(dir.path);
      SlideCore.setBackupDir(dir.path);
    } catch (e, stack) {
      logError('EngineBackups.enable', e, stack);
    }
  }

  /// Size the spreadsheet engine's cell budget to the phone's memory, so a
  /// huge workbook is refused with a clear message instead of the system
  /// killing the app. Never throws; where the memory cannot be read the
  /// engine keeps its own default.
  static Future<void> setMemoryBudgets() async {
    try {
      final total = await _totalMemoryBytes();
      if (total == null) return;
      SheetCore.setCellBudget(cellBudgetFor(total));
    } catch (e, stack) {
      logError('EngineBackups.setMemoryBudgets', e, stack);
    }
  }

  /// Cells a workbook may hold on a phone with [totalBytes] of memory:
  /// 2 million under 3 GB, 3 million under 6 GB, 4 million above.
  static int cellBudgetFor(int totalBytes) {
    const gb = 1024 * 1024 * 1024;
    if (totalBytes < 3 * gb) return 2000000;
    if (totalBytes < 6 * gb) return 3000000;
    return 4000000;
  }

  /// `MemTotal` from `/proc/meminfo` (Android and Linux), or null.
  static Future<int?> _totalMemoryBytes() async {
    if (!Platform.isAndroid && !Platform.isLinux) return null;
    final file = File('/proc/meminfo');
    if (!await file.exists()) return null;
    return parseMemTotal(await file.readAsString());
  }

  /// The `MemTotal:` line of a `/proc/meminfo` text in bytes, or null.
  static int? parseMemTotal(String meminfo) {
    final match = RegExp(
      r'^MemTotal:\s+(\d+)\s*kB',
      multiLine: true,
    ).firstMatch(meminfo);
    final kb = match == null ? null : int.tryParse(match.group(1)!);
    return kb == null ? null : kb * 1024;
  }

  /// Remove what saves killed halfway left in the app's own folders: the
  /// hidden temporary files beside the working copies, once an hour old.
  /// Folders outside the app are never swept.
  static Future<void> removeStaleTempFiles() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      for (final dir in [documents.path, '${documents.path}/Edited']) {
        if (await Directory(dir).exists()) {
          TextCore.removeStaleTempFiles(dir);
        }
      }
    } catch (e, stack) {
      logError('EngineBackups.removeStaleTempFiles', e, stack);
    }
  }
}

/// One backup: the version of [name] that a save replaced, kept as it was.
class BackupFile {
  const BackupFile(this.path, this.name, this.modified, this.size);

  final String path;
  final String name;

  /// When the backup was made.
  final DateTime modified;

  /// Its size in bytes.
  final int size;
}
