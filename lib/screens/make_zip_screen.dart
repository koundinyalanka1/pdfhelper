import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/doc_kind.dart';
import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/public_pdf_save_service.dart';
import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';
import 'archive_screen.dart';

/// Packs files into one new ZIP through the archive engine
/// (`flutter_archive_core`): pick files from anywhere on the phone, name the
/// archive, and create it.
///
/// The files are only read. The ZIP is written in the app's documents and,
/// where Android needs one, as a public copy in `Download/DocHelper` or
/// `Documents/DocHelper`.
class MakeZipScreen extends StatefulWidget {
  const MakeZipScreen({super.key, this.initialPaths = const []});

  /// Files (or folders) to start with, as if they had been picked.
  final List<String> initialPaths;

  /// The name each of [names] gets in the archive: its own, or with
  /// " (2)", " (3)"… when an earlier one has it. Letter case is ignored, as
  /// it is on memory cards and Windows, so extracting never writes one file
  /// over another. The archive engine numbers names the same way.
  static List<String> entryNames(List<String> names) {
    final taken = <String>{};
    String claim(String name) {
      if (taken.add(name.toLowerCase())) return name;
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var n = 2; ; n++) {
        final candidate = '$stem ($n)$extension';
        if (taken.add(candidate.toLowerCase())) return candidate;
      }
    }

    return [for (final name in names) claim(name)];
  }

  @override
  State<MakeZipScreen> createState() => _MakeZipScreenState();
}

/// A file or folder chosen for the archive.
class _Picked {
  const _Picked(this.path, this.name, {this.size, this.folder = false});

  final String path;

  /// Its own name, which the archive uses unless another file has it.
  final String name;

  /// Bytes; null for a folder.
  final int? size;
  final bool folder;
}

/// A ZIP just made.
class _Made {
  const _Made({
    required this.path,
    required this.files,
    required this.size,
    this.publicPath,
    this.publishProblem,
  });

  final String path;
  final int files;
  final int size;

  /// Where the public copy went, such as `Download/DocHelper/Archive.zip`;
  /// null when none was needed or it failed.
  final String? publicPath;

  /// Why the public copy failed; null when it did not.
  final String? publishProblem;

  String get name => path.split('/').last;
}

class _MakeZipScreenState extends State<MakeZipScreen> {
  AppColors _colors = AppColors(false);
  Color get _accent => DocKind.archive.color;

  final List<_Picked> _files = [];
  final _nameController = TextEditingController(text: 'Archive');
  final _scroll = ScrollController();

  /// The user typed a name, so adding or removing files no longer changes
  /// it.
  bool _nameEdited = false;

  bool _adding = false;
  bool _working = false;
  String? _error;
  _Made? _made;

  @override
  void initState() {
    super.initState();
    if (widget.initialPaths.isNotEmpty) {
      _adding = true;
      _add(widget.initialPaths);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ----------------------------------------------------------------- files

  Future<void> _pick() async {
    if (_adding || _working) return;
    try {
      // Any kind of file; pickFiles lets several be chosen at once.
      final picked = await FilePicker.pickFiles();
      await _add([
        for (final file in picked)
          if (file.path != null) file.path!,
      ]);
    } catch (e) {
      logError('MakeZip.pick', e);
      _snack('Could not add those files: $e');
    }
  }

  /// The name a picked file had before "Open with" or the picker copied it.
  static String _ownName(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final stripped = name.replaceFirst(RegExp(r'^intent_\d+_'), '');
    return stripped.isEmpty ? name : stripped;
  }

  Future<void> _add(List<String> paths) async {
    if (!_adding) setState(() => _adding = true);
    final added = <_Picked>[];
    var missing = 0;
    for (final path in paths) {
      // The same file picked twice is packed once.
      if (_files.any((f) => f.path == path) ||
          added.any((f) => f.path == path)) {
        continue;
      }
      final stat = await FileStat.stat(path);
      switch (stat.type) {
        case FileSystemEntityType.notFound:
          missing++;
        case FileSystemEntityType.directory:
          added.add(_Picked(path, _ownName(path), folder: true));
        default:
          added.add(_Picked(path, _ownName(path), size: stat.size));
      }
    }
    if (!mounted) return;
    setState(() {
      _adding = false;
      _files.addAll(added);
      _made = null;
      _error = null;
      _suggestName();
    });
    if (missing > 0) {
      _snack(
        missing == 1
            ? 'One file could not be found, so it was left out.'
            : '$missing files could not be found, so they were left out.',
      );
    }
  }

  void _remove(int index) {
    setState(() {
      _files.removeAt(index);
      _made = null;
      _error = null;
      _suggestName();
    });
  }

  /// "Archive", or the single file's own title, until the user names it.
  void _suggestName() {
    if (_nameEdited) return;
    final suggestion = _files.length == 1
        ? sanitizeFileName(
            DocKind.titleOf(_files.single.name),
            fallback: 'Archive',
          )
        : 'Archive';
    _nameController.text = suggestion;
  }

  /// The archive's file name without `.zip`, made safe to write.
  String get _archiveName {
    var name = _nameController.text.trim();
    // Typing the extension too ("photos.zip") must not double it.
    if (name.toLowerCase().endsWith('.zip')) {
      name = name.substring(0, name.length - 4);
    }
    return sanitizeFileName(name, fallback: 'Archive');
  }

  // ---------------------------------------------------------------- create

  static String _publicFolder(String location) =>
      location == 'Documents' ? 'Documents/DocHelper' : 'Download/DocHelper';

  /// A failure to make the archive, in plain words.
  static String _describe(Object error) {
    if (error is! ArchiveCoreException) return 'Could not make the ZIP: $error';
    // The engine's message often starts with a file name, so its case is
    // kept.
    final detail = error.message.trim().replaceFirst(RegExp(r'[.!?]$'), '');
    return switch (error.code) {
      'TOO_LARGE' =>
        'These files are too large to pack on the phone ($detail).',
      'IO' || 'NOT_FOUND' =>
        'A file could not be read. It may have been moved or deleted '
            '($detail).',
      _ => 'Could not make the ZIP: $detail.',
    };
  }

  Future<void> _create() async {
    if (_files.isEmpty || _working || _adding) return;
    if (!ArchiveCore.isAvailable) return;
    FocusScope.of(context).unfocus();
    final location = context.read<ThemeProvider>().saveLocation;
    final name = _archiveName;
    setState(() {
      _working = true;
      _error = null;
      _made = null;
    });

    final String output;
    final int count;
    try {
      final documents = (await getApplicationDocumentsDirectory()).path;
      output = await uniqueFilePath(documents, '$name.zip');
      final names = MakeZipScreen.entryNames([for (final f in _files) f.name]);
      count = await ArchiveCore.createAsync([
        for (var i = 0; i < _files.length; i++)
          ArchiveSource(_files[i].path, name: names[i]),
      ], output);
    } catch (e) {
      logError('MakeZip.create', e);
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _describe(e);
      });
      return;
    }

    String? publicPath;
    String? publishProblem;
    final fileName = output.split('/').last;
    try {
      if (await DocumentSaveService.needsPublicCopy(output)) {
        await PublicPdfSaveService.save(
          sourcePath: output,
          displayName: fileName,
          location: location,
          mimeType: 'application/zip',
        );
        final copy = await PublicPdfSaveService.latestCopy(output);
        publicPath = copy == null
            ? '${_publicFolder(location)}/$fileName'
            : DocumentSaveService.describePublicPath(copy.path);
      }
    } on PublicPdfSaveException catch (e) {
      logError('MakeZip.publish', e);
      publishProblem = e.message;
    } catch (e) {
      logError('MakeZip.publish', e);
      publishProblem = '$e';
    }
    var size = 0;
    try {
      size = await File(output).length();
    } on FileSystemException catch (e) {
      logError('MakeZip.size', e);
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _made = _Made(
        path: output,
        files: count,
        size: size,
        publicPath: publicPath,
        publishProblem: publishProblem == null
            ? null
            : "It is saved in DocHelper's documents, but not in "
                  '${_publicFolder(location)}: $publishProblem',
      );
    });
    // The result shows above the list, which may be scrolled far down.
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _share(_Made made) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(made.path, mimeType: 'application/zip')]),
      );
    } catch (e) {
      _snack('Could not share ${made.name}: $e');
    }
  }

  void _open(_Made made) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ArchiveScreen(path: made.path)),
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final available = ArchiveCore.isAvailable;
    final made = _made;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        foregroundColor: _colors.textPrimary,
        title: const Text('Make a ZIP'),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (!available) ...[
            _buildMissingEngine(),
            const SizedBox(height: 16),
          ],
          if (made != null) ...[_buildResult(made), const SizedBox(height: 16)],
          _buildNameField(),
          const SizedBox(height: 20),
          _buildFilesHeader(),
          const SizedBox(height: 8),
          if (_files.isEmpty) _buildEmpty() else _buildFileList(),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('make-zip-add'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accent,
                side: BorderSide(color: _accent.withValues(alpha: 0.6)),
              ),
              onPressed: _adding || _working ? null : _pick,
              icon: _adding
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  : const Icon(Icons.add_rounded),
              label: Text(_files.isEmpty ? 'Add files' : 'Add more'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              key: const ValueKey('make-zip-error'),
              style: const TextStyle(color: Color(0xFFE53935)),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const ValueKey('make-zip-create'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: available && _files.isNotEmpty && !_working && !_adding
                ? _create
                : null,
            icon: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.folder_zip_rounded),
            label: Text(_working ? 'Making the ZIP…' : 'Create ZIP'),
          ),
        ),
      ),
    );
  }

  Widget _buildMissingEngine() {
    return Container(
      key: const ValueKey('make-zip-missing'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.orange, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'The archive engine is missing from this copy of DocHelper, so '
              'it cannot make ZIP files.',
              style: TextStyle(color: Colors.orange, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameField() {
    // As in the name dialog: characters a file system refuses are not
    // typed at all, rather than rewritten afterwards.
    return TextField(
      key: const ValueKey('make-zip-name'),
      controller: _nameController,
      enabled: !_working,
      maxLength: maxBaseNameLength,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.done,
      style: TextStyle(color: _colors.textPrimary),
      inputFormatters: [
        FilteringTextInputFormatter.deny(RegExp(r'[<>:"/\\|?*]')),
      ],
      onChanged: (_) => _nameEdited = true,
      decoration: InputDecoration(
        labelText: 'Name of the ZIP',
        labelStyle: TextStyle(color: _colors.textSecondary),
        counterText: '',
        suffixText: '.zip',
        suffixStyle: TextStyle(color: _colors.textTertiary),
        filled: true,
        fillColor: _colors.cardBackground,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _colors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _colors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _accent, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildFilesHeader() {
    final bytes = _files.fold<int>(0, (sum, f) => sum + (f.size ?? 0));
    final count = _files.length;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        count == 0
            ? 'Files'
            : '${formatCount(count)} ${count == 1 ? 'item' : 'items'} · '
                  '${formatFileSize(bytes)}',
        style: TextStyle(
          color: _colors.textSecondary,
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
      key: const ValueKey('make-zip-empty'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.folder_zip_rounded, size: 44, color: _accent),
          const SizedBox(height: 10),
          Text(
            'Add the files to pack into one ZIP. Any kind of file can go in.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _colors.textSecondary, fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    final names = MakeZipScreen.entryNames([for (final f in _files) f.name]);
    return Container(
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _colors.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < _files.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: _colors.divider,
                indent: 62,
                endIndent: 14,
              ),
            _buildFileRow(i, _files[i], names[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildFileRow(int index, _Picked file, String packedAs) {
    final kind = DocKind.ofPath(file.name);
    final icon = file.folder ? Icons.folder_rounded : kind.icon;
    final color = file.folder ? _accent : kind.color;
    final details = [
      file.folder ? 'Folder, with everything in it' : formatFileSize(file.size),
      if (packedAs != file.name) 'packed as $packedAs',
    ].join(' · ');
    return Padding(
      key: ValueKey('make-zip-file-$index'),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: TextStyle(color: _colors.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('make-zip-remove-$index'),
            tooltip: 'Remove',
            onPressed: _working ? null : () => _remove(index),
            icon: Icon(Icons.close_rounded, color: _colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(_Made made) {
    const success = Color(0xFF4CAF50);
    final problem = made.publishProblem;
    return Container(
      key: const ValueKey('make-zip-result'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: success.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: success, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  made.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _colors.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${formatCount(made.files)} ${made.files == 1 ? 'file' : 'files'}'
            ' · ${formatFileSize(made.size)}',
            style: TextStyle(color: _colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            made.publicPath != null
                ? 'Saved to ${made.publicPath}.'
                : problem ?? "Saved in DocHelper's documents.",
            style: TextStyle(
              color: problem == null ? _colors.textSecondary : Colors.orange,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('make-zip-share'),
                  onPressed: () => _share(made),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Share'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('make-zip-open'),
                  style: FilledButton.styleFrom(backgroundColor: _accent),
                  onPressed: () => _open(made),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Open'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
