import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_router.dart';
import '../services/engine_backups.dart';
import '../utils/error_logger.dart';

/// The versions that saves replaced, kept in the app's private `Backups`
/// folder. A backup is never changed here: opening one works on a copy in
/// the app's documents, which the editor saves or shares like any file.
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key, this.backupDir, this.documentsDir});

  /// Where backups are listed from; the engines' folder unless given.
  final Directory? backupDir;

  /// Where opened copies go; the app's documents unless given.
  final Directory? documentsDir;

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  List<BackupFile>? _backups;
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final found = await EngineBackups.list(widget.backupDir);
    if (mounted) setState(() => _backups = found);
  }

  /// A copy of [backup] in the app's documents, under a name no file has.
  Future<String> _copyOut(BackupFile backup) async {
    final folder =
        widget.documentsDir ?? await getApplicationDocumentsDirectory();
    final dot = backup.name.lastIndexOf('.');
    final stem = dot > 0 ? backup.name.substring(0, dot) : backup.name;
    final extension = dot > 0 ? backup.name.substring(dot) : '';
    var target = '${folder.path}/$stem (backup)$extension';
    for (
      var n = 2;
      await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      target = '${folder.path}/$stem (backup $n)$extension';
    }
    await File(backup.path).copy(target);
    return target;
  }

  Future<void> _open(BackupFile backup) async {
    final String copy;
    try {
      copy = await _copyOut(backup);
    } catch (e, stack) {
      logError('Backups.open', e, stack);
      _snack('Could not open ${backup.name}: the backup could not be copied.');
      return;
    }
    if (!mounted) return;
    await DocumentRouter.open(context, copy, title: copy.split('/').last);
  }

  Future<void> _share(BackupFile backup) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(backup.path, mimeType: DocKind.mimeTypeOf(backup.name)),
          ],
        ),
      );
    } catch (e, stack) {
      logError('Backups.share', e, stack);
      _snack('Could not share ${backup.name}.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _when(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = time.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final backups = _backups;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        foregroundColor: _colors.textPrimary,
        elevation: 0,
        title: const Text('Backups'),
      ),
      body: SafeArea(
        child: backups == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Text(
                      'Each time DocHelper saves over a document, it keeps '
                      'the version it replaced here. Opening one works on a '
                      'copy, so the backup stays as it is.',
                      style: TextStyle(
                        color: _colors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (backups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No backups yet.',
                        style: TextStyle(color: _colors.textPrimary),
                      ),
                    ),
                  for (final backup in backups) _tile(backup),
                ],
              ),
      ),
    );
  }

  Widget _tile(BackupFile backup) {
    final kind = DocKind.ofPath(backup.name);
    return ListTile(
      leading: Icon(kind.icon, color: kind.color),
      title: Text(
        backup.name,
        style: TextStyle(color: _colors.textPrimary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        'Replaced ${_when(backup.modified)} · ${_size(backup.size)}',
        style: TextStyle(color: _colors.textSecondary),
      ),
      onTap: kind.canOpen && DocKind.canOpenPath(backup.name)
          ? () => _open(backup)
          : null,
      trailing: IconButton(
        tooltip: 'Share ${backup.name}',
        icon: Icon(Icons.share_rounded, color: _colors.textSecondary),
        onPressed: () => _share(backup),
      ),
    );
  }
}
