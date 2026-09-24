import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/selected_pdf_file.dart';
import '../services/ads_service.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_service.dart';
import '../providers/theme_provider.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';
import '../widgets/password_prompt.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/recent_pdfs_strip.dart';
import 'pdf_preview_screen.dart';
import 'pdf_viewer_screen.dart';

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key, this.initialPdfPath});

  final String? initialPdfPath;

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<List<SelectedPdfFile>> _batches = [[]];
  bool _isProcessing = false;
  double _mergeProgress = 0.0;
  String _mergeStatus = '';

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    if (widget.initialPdfPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _addInitialPdf(widget.initialPdfPath!);
      });
    }
  }

  Future<void> _addInitialPdf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final name = path.split(RegExp(r'[/\\]')).last;
      final size = await file.length();
      final newFile = SelectedPdfFile(
        path: path,
        name: name,
        fileSize: size,
        isLoading: true,
      );
      if (mounted) {
        setState(() {
          if (_batches.isEmpty) _batches.add([]);
          _batches.last.insert(0, newFile);
        });
        _loadPdfDetails(newFile);
      }
    } catch (e) {
      debugPrint('Error adding initial PDF: $e');
    }
  }

  Future<void> _pickPdfFiles() async {
    try {
      // pickFiles is static and returns the selected files directly — an
      // empty list on cancel, never null.
      final List<PlatformFile> result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result.isNotEmpty) {
        _addFiles([
          for (final file in result)
            if (file.path != null)
              SelectedPdfFile(
                path: file.path!,
                name: file.name,
                // `lengthSync()` (which replaced `size`) returns null when the
                // platform picker didn't report a size, rather than doing I/O
                // for it. SelectedPdfFile.fileSize is already nullable and the
                // card renders "0 B" for null, so the list appears instantly.
                fileSize: file.lengthSync(),
                isLoading: true,
              ),
        ]);
      }
    } catch (e) {
      _showSnackBar('Error selecting files: $e', isError: true);
    }
  }

  /// Add one already-known file — the Recent strip's path in, where the file
  /// browser was never involved and the size can be read directly.
  void _addRecent(String path) {
    if (_selectedPaths.contains(path)) return;
    final file = File(path);
    if (!file.existsSync()) {
      _showSnackBar('That file is no longer there.', isError: true);
      return;
    }
    _addFiles([
      SelectedPdfFile(
        path: path,
        name: path.split(Platform.pathSeparator).last,
        fileSize: file.lengthSync(),
        isLoading: true,
      ),
    ]);
  }

  /// Append to the batch being built and start reading each file's details.
  void _addFiles(List<SelectedPdfFile> newFiles) {
    if (newFiles.isEmpty) return;
    setState(() {
      if (_batches.isEmpty) _batches.add([]);
      _batches.last.addAll(newFiles);
    });
    // Load all files in PARALLEL (not sequential)
    for (final file in newFiles) {
      _loadPdfDetails(file);
    }
  }

  /// Every path already in any batch, so the Recent strip can leave them out.
  Set<String> get _selectedPaths => {
    for (final batch in _batches)
      for (final file in batch) file.path,
  };

  /// Password prompts, one at a time. Files load in parallel, so two locked
  /// files added together would otherwise stack two dialogs.
  Future<void> _promptQueue = Future.value();

  /// Null when the user declines, or removed [file] while its prompt queued.
  Future<String?> _askPassword(SelectedPdfFile file, {required bool retry}) {
    final answer = _promptQueue.then(
      (_) => mounted && _batches.any((batch) => batch.contains(file))
          ? showPdfPasswordPrompt(context, retry: retry, fileName: file.name)
          : null,
    );
    _promptQueue = answer.then((_) {}, onError: (_) {});
    return answer;
  }

  Future<void> _loadPdfDetails(SelectedPdfFile file) async {
    bool isRetry = false;
    while (true) {
      try {
        // The native core reads the file itself, so nothing is buffered
        // here — this used to hold every selected PDF in memory at once.
        final results = await Future.wait([
          PdfService.getPageCount(file.path, password: file.password),
          PdfService.generateThumbnail(file.path, password: file.password),
          PdfService.getFirstPageAspectRatio(
            file.path,
            password: file.password,
          ),
        ]);
        final pageCount = results[0] as int;
        final thumbnail = results[1] as Uint8List?;
        final aspectRatio = results[2] as double?;

        if (mounted) {
          setState(() {
            file.pageCount = pageCount;
            file.thumbnail = thumbnail;
            file.aspectRatio = aspectRatio;
            file.isLoading = false;
          });
        }
        return;
      } on PdfException catch (e) {
        if (!mounted) return;
        if (e.isEncrypted || e.isWrongPassword) {
          final entered = await _askPassword(
            file,
            retry: isRetry || e.isWrongPassword,
          );
          if (!mounted) return;
          if (entered != null) {
            file.password = entered;
            isRetry = true;
            continue;
          }
          if (!_batches.any((batch) => batch.contains(file))) return;
          // Without its password the file cannot be merged; leaving it in
          // would only fail the whole batch later.
          setState(() {
            for (final batch in _batches) {
              batch.remove(file);
            }
          });
          _showSnackBar(
            '"${file.name}" is password protected and was not added',
          );
          return;
        }
        debugPrint('Error loading PDF: $e');
        setState(() => file.isLoading = false);
        return;
      } catch (e) {
        debugPrint('Error loading PDF: $e');
        if (mounted) {
          setState(() => file.isLoading = false);
        }
        return;
      }
    }
  }

  bool get _allFilesLoaded =>
      _batches.every((b) => b.every((f) => !f.isLoading));
  int get _mergeableBatchCount => _batches.where((b) => b.length >= 2).length;
  int get _totalBatchesPages =>
      _batches.fold(0, (sum, b) => sum + b.fold(0, (s, f) => s + f.pageCount));
  int get _totalFileCount => _batches.fold(0, (sum, b) => sum + b.length);
  int get _loadingCount =>
      _batches.fold(0, (sum, b) => sum + b.where((f) => f.isLoading).length);

  void _addNewBatch() {
    setState(() => _batches.add([]));
  }

  void _removeBatch(int batchIndex) {
    setState(() {
      _batches.removeAt(batchIndex);
      if (_batches.isEmpty) _batches.add([]);
    });
  }

  Future<void> _mergePdfs() async {
    if (_mergeableBatchCount == 0) return;

    if (!_allFilesLoaded) {
      _showSnackBar('Please wait for all files to load', isError: false);
      return;
    }

    // Asked up front so the name reaches the output file itself rather than
    // only the auto-saved copy (auto-save can be off).
    final fileName = await askPdfName(
      context: context,
      initialName: defaultPdfName('Merged'),
      confirmLabel: 'Merge',
      accent: const Color(0xFFE94560),
      hint: _mergeableBatchCount > 1
          ? '$_mergeableBatchCount files, numbered 1-$_mergeableBatchCount'
          : null,
    );
    if (fileName == null || !mounted) return;

    setState(() {
      _isProcessing = true;
      _mergeProgress = 0.05;
      _mergeStatus = 'Preparing $_mergeableBatchCount batch(es)...';
    });

    try {
      final themeProvider = context.read<ThemeProvider>();

      // Group the mergeable batches by *path*: the native core streams files
      // from disk, so it never needs the bytes we cached for thumbnails.
      final List<List<SelectedPdfFile>> mergeable = _batches
          .where((b) => b.length >= 2)
          .toList();

      setState(() {
        _mergeProgress = 0.2;
        _mergeStatus = 'Merging ${mergeable.length} batch(es)...';
      });

      final List<String> outputPaths = [];
      for (int i = 0; i < mergeable.length; i++) {
        final batch = mergeable[i];
        final path = await PdfService.mergeFiles(
          batch.map((f) => f.path).toList(),
          passwords: batch.map((f) => f.password).toList(),
          // One title, several batches: number them so the outputs stay
          // distinguishable.
          fileName: mergeable.length > 1 ? '$fileName ${i + 1}' : fileName,
        );
        if (path != null) outputPaths.add(path);
        if (!mounted) return;
        setState(() {
          _mergeProgress = 0.2 + 0.6 * ((i + 1) / mergeable.length);
          _mergeStatus = 'Merged ${i + 1} of ${mergeable.length}...';
        });
      }

      setState(() {
        _mergeProgress = 0.8;
        _mergeStatus = 'Saving...';
      });

      if (outputPaths.isNotEmpty) {
        setState(() => _mergeProgress = 1.0);
        if (!mounted) return;
        if (themeProvider.skipPreview && themeProvider.autoSave) {
          // Fast path: save immediately, skip the preview screen.
          await autoSavePdfs(
            themeProvider: themeProvider,
            filePaths: outputPaths,
            sourceType: PdfPreviewSourceType.merge,
            pageCount: _totalBatchesPages,
            fileName: fileName,
          );
          if (!mounted) return;
          _showSnackBar(
            'Merged ${outputPaths.length} PDF${outputPaths.length > 1 ? "s" : ""}',
          );
          setState(() => _batches = [[]]);
          AdsService.instance.maybeShowInterstitial(trigger: 'merge');
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfPreviewScreen(
                filePaths: outputPaths,
                sourceType: PdfPreviewSourceType.merge,
                pageCount: _totalBatchesPages,
                fileName: fileName,
                onSaved: () {
                  setState(() => _batches = [[]]);
                },
              ),
            ),
          );
        }
      } else {
        _showSnackBar('Failed to merge PDFs', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() {
        _isProcessing = false;
        _mergeProgress = 0.0;
      });
    }
  }

  Widget _buildBatchesList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _batches.length,
      itemBuilder: (context, batchIndex) {
        final batch = _batches[batchIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (batchIndex > 0) const SizedBox(height: 8),
            if (batchIndex > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Batch ${batchIndex + 1}',
                        style: const TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (batch.isEmpty)
                      TextButton.icon(
                        onPressed: () => _removeBatch(batchIndex),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Remove'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                  ],
                ),
              ),
            ...batch.asMap().entries.map((entry) {
              final fileIndex = entry.key;
              final file = entry.value;
              return _buildPdfCard(file, batchIndex, fileIndex);
            }),
          ],
        );
      },
    );
  }

  Widget _buildPdfCard(SelectedPdfFile file, int batchIndex, int fileIndex) {
    return Container(
      key: ValueKey('${file.path}_${batchIndex}_$fileIndex'),
      margin: const EdgeInsets.only(bottom: 12),
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
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFFE94560),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '${fileIndex + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final ratio = file.aspectRatio ?? 0.7;
                const base = 88.0;
                final w = ratio >= 1 ? base : (base * ratio).clamp(50.0, 90.0);
                final h = ratio >= 1 ? (base / ratio).clamp(55.0, 110.0) : base;
                return Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: _colors.isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _colors.divider, width: 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: file.isLoading
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFE94560),
                              ),
                            ),
                          )
                        : file.thumbnail != null
                        ? Image.memory(file.thumbnail!, fit: BoxFit.contain)
                        : Center(
                            child: Icon(
                              Icons.picture_as_pdf_rounded,
                              color: const Color(0xFFE94560),
                              size: 28,
                            ),
                          ),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: TextStyle(
                      color: _colors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE94560).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: file.isLoading
                            ? const Text(
                                'Loading...',
                                style: TextStyle(
                                  color: Color(0xFFE94560),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : Text(
                                '${file.pageCount} page${file.pageCount != 1 ? 's' : ''}',
                                style: const TextStyle(
                                  color: Color(0xFFE94560),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatFileSize(file.fileSize),
                        style: TextStyle(
                          color: _colors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!file.isLoading)
              Semantics(
                label: 'View ${file.name}',
                button: true,
                child: IconButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    if (!File(file.path).existsSync()) {
                      _showSnackBar(
                        'That file is no longer available',
                        isError: true,
                      );
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PdfViewerScreen(
                          pdfPath: file.path,
                          title: file.name,
                          password: file.password,
                        ),
                      ),
                    );
                  },
                  icon: Icon(
                    Icons.visibility_rounded,
                    color: _colors.textSecondary,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),
            Semantics(
              label: 'Remove ${file.name} from batch',
              button: true,
              child: IconButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _batches[batchIndex].removeAt(fileIndex);
                    if (_batches[batchIndex].isEmpty && _batches.length > 1) {
                      _batches.removeAt(batchIndex);
                    }
                  });
                },
                icon: Icon(
                  Icons.close_rounded,
                  color: Colors.red.shade400,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFFE94560),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Semantics(
          label: 'New batch',
          button: true,
          child: IconButton(
            onPressed: _isProcessing ? null : _addNewBatch,
            icon: Text(
              '+B',
              style: TextStyle(
                color: _colors.textTertiary.withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            tooltip: 'New batch',
          ),
        ),
        title: Text(
          'Merge PDF',
          style: TextStyle(
            color: _colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_batches.any((b) => b.isNotEmpty))
            Semantics(
              label: 'Clear all batches',
              button: true,
              child: IconButton(
                onPressed: () {
                  setState(() => _batches = [[]]);
                },
                icon: Icon(Icons.delete_outline, color: _colors.textSecondary),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Add files button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Semantics(
                label: _batches.every((b) => b.isEmpty)
                    ? 'Tap to select PDF files to merge'
                    : 'Add more PDF files to current batch',
                button: true,
                enabled: !_isProcessing,
                child: GestureDetector(
                  onTap: _isProcessing ? null : _pickPdfFiles,
                  child: Container(
                    width: double.infinity,
                    height: _batches.every((b) => b.isEmpty) ? 140 : 70,
                    decoration: BoxDecoration(
                      color: _colors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFE94560).withValues(alpha: 0.3),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _colors.shadowColor,
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: _batches.every((b) => b.isEmpty)
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFE94560,
                                  ).withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add_circle_outline_rounded,
                                  size: 36,
                                  color: Color(0xFFE94560),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Tap to select PDF files',
                                style: TextStyle(
                                  color: _colors.textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFE94560,
                                  ).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  size: 24,
                                  color: Color(0xFFE94560),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Add more PDFs',
                                style: TextStyle(
                                  color: _colors.textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            // Anything just opened in the viewer is very likely what is
            // being merged, so offer it before the file browser is needed.
            // It stays put as files are added — merging wants more than one.
            RecentPdfsStrip(
              onSelected: _addRecent,
              excludePaths: _selectedPaths,
            ),

            // Stats bar
            if (_batches.any((b) => b.isNotEmpty))
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      'Batches',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE94560).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _loadingCount > 0
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: Color(0xFFE94560),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$_totalFileCount files loading...',
                                  style: const TextStyle(
                                    color: Color(0xFFE94560),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              '${_batches.where((b) => b.isNotEmpty).length} batch(es) • $_totalFileCount files',
                              style: const TextStyle(
                                color: Color(0xFFE94560),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

            // Hint
            if (_mergeableBatchCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.swap_vert_rounded,
                        size: 16,
                        color: Color(0xFF00D9FF),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _batches.length > 1
                              ? 'Long press to reorder. Use "New batch" for separate merge groups.'
                              : 'Long press and drag to reorder',
                          style: TextStyle(
                            color: const Color(0xFF00D9FF),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 10),

            // PDF grid with previews
            Expanded(
              child: _batches.every((b) => b.isEmpty)
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            size: 70,
                            color: _colors.textTertiary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No files selected',
                            style: TextStyle(
                              color: _colors.textTertiary,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _buildBatchesList(),
            ),

            // Merge button
            if (_mergeableBatchCount > 0)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    if (_isProcessing) ...[
                      // Progress bar
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _mergeStatus,
                                  style: TextStyle(
                                    color: _colors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${(_mergeProgress * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Color(0xFFE94560),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _mergeProgress,
                                minHeight: 8,
                                backgroundColor: _colors.cardBackground,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFE94560),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Semantics(
                      label: _isProcessing
                          ? 'Merging PDFs in progress'
                          : _allFilesLoaded
                          ? 'Merge $_totalBatchesPages pages'
                          : 'Loading files, please wait',
                      button: true,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: (_isProcessing || !_allFilesLoaded)
                              ? null
                              : _mergePdfs,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE94560),
                            disabledBackgroundColor: const Color(
                              0xFFE94560,
                            ).withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                            elevation: 0,
                          ),
                          child: _isProcessing
                              ? const Text(
                                  'Merging...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.merge_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      _allFilesLoaded
                                          ? 'Merge $_mergeableBatchCount Batch(es)'
                                          : 'Loading files...',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
