import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../widgets/pdf_result_dialog.dart';

/// Rotate, reorder and delete pages in one pass.
///
/// The whole edit is staged locally as a list of [_PageEdit]s and committed in
/// one shot when the user taps Apply — one `reorder` (which also drops deleted
/// pages) followed by one `rotate` per distinct angle, rather than rewriting
/// the file after every tap.
///
/// Pops the path of the rewritten PDF, or `null` if nothing was applied.
class OrganizePagesScreen extends StatefulWidget {
  const OrganizePagesScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
  });

  final String pdfPath;
  final String password;

  @override
  State<OrganizePagesScreen> createState() => _OrganizePagesScreenState();
}

class _OrganizePagesScreenState extends State<OrganizePagesScreen> {
  static const Color _accent = Color(0xFF00D9FF);

  List<_PageEdit> _pages = [];
  bool _isLoading = true;
  bool _isApplying = false;
  String _status = '';

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  bool get _isDirty =>
      _pages.any((p) => p.rotation != 0 || p.deleted) ||
      _pages.asMap().entries.any((e) => e.value.sourceIndex != e.key);

  int get _keptCount => _pages.where((p) => !p.deleted).length;

  @override
  void initState() {
    super.initState();
    _loadThumbnails();
  }

  Future<void> _loadThumbnails() async {
    try {
      final count = await PdfRaster.pageCountOf(
        widget.pdfPath,
        password: widget.password,
      );
      final pages = <_PageEdit>[];
      for (int i = 0; i < count; i++) {
        final thumbnail = await PdfRaster.renderPage(
          widget.pdfPath,
          i,
          longEdge: 320,
          password: widget.password,
        );
        pages.add(_PageEdit(sourceIndex: i, thumbnail: thumbnail));
        // Show pages as they arrive rather than after the whole document.
        if (mounted && (i == 0 || i % 8 == 7)) {
          setState(() {
            _pages = List.of(pages);
            _isLoading = false;
          });
        }
      }
      if (mounted) {
        setState(() {
          _pages = pages;
          _isLoading = false;
          if (pages.isEmpty) _status = 'This PDF has no pages.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _status = PdfCoreService.describeError(e);
        });
      }
    }
  }

  void _rotate(int index, int delta) {
    HapticFeedback.selectionClick();
    setState(() {
      final page = _pages[index];
      page.rotation = (page.rotation + delta) % 360;
      if (page.rotation < 0) page.rotation += 360;
    });
  }

  void _toggleDelete(int index) {
    HapticFeedback.lightImpact();
    setState(() => _pages[index].deleted = !_pages[index].deleted);
  }

  Future<void> _apply() async {
    if (_keptCount == 0) {
      _snack('Keep at least one page.');
      return;
    }
    if (!PdfCoreService.isAvailable) {
      _snack('The native PDF core is not built — page editing is unavailable.');
      return;
    }

    setState(() {
      _isApplying = true;
      _status = 'Rewriting document…';
    });

    try {
      final kept = _pages.where((p) => !p.deleted).toList();

      // One pass for order + deletions: extractPages takes a 1-based
      // selection and emits pages in the order given.
      final selection = kept.map((p) => '${p.sourceIndex + 1}').join(',');
      String current = await PdfCoreService.extractPages(
        widget.pdfPath,
        selection,
        prefix: 'organized',
        password: widget.password,
      );

      // Then one rotate call per distinct non-zero angle, addressing the
      // pages by their *new* positions.
      final byAngle = <int, List<int>>{};
      for (int i = 0; i < kept.length; i++) {
        final rotation = kept[i].rotation;
        if (rotation != 0) (byAngle[rotation] ??= []).add(i);
      }
      for (final entry in byAngle.entries) {
        if (!mounted) return;
        setState(() => _status = 'Rotating ${entry.value.length} page(s)…');
        current = await PdfCoreService.rotatePages(
          current,
          entry.key,
          pages: PdfCoreService.toPageSelection(entry.value),
        );
      }

      if (!mounted) return;
      setState(() => _isApplying = false);
      final removed = _pages.length - kept.length;
      await showPdfResultDialog(
        context: context,
        filePaths: [current],
        accent: _accent,
        adTrigger: 'organize',
        message: [
          '${kept.length} page${kept.length == 1 ? '' : 's'} kept',
          if (removed > 0) '$removed removed',
          if (byAngle.isNotEmpty) 'rotations applied',
        ].join(', '),
      );
      if (mounted) Navigator.pop(context, current);
    } catch (e) {
      if (mounted) {
        setState(() => _isApplying = false);
        _snack(PdfCoreService.describeError(e));
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        title: Text(
          'Organize pages',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
        iconTheme: IconThemeData(color: _colors.textPrimary),
        actions: [
          if (_isDirty && !_isApplying)
            TextButton(
              onPressed: () => setState(() {
                _pages.sort((a, b) => a.sourceIndex.compareTo(b.sourceIndex));
                for (final p in _pages) {
                  p.rotation = 0;
                  p.deleted = false;
                }
              }),
              child: Text(
                'Reset',
                style: TextStyle(color: _colors.textSecondary),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$_keptCount of ${_pages.length} pages kept · '
                          'drag handles to reorder',
                          style: TextStyle(
                            color: _colors.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildList()),
                _buildBottomBar(),
              ],
            ),
    );
  }

  Widget _buildList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _pages.length,
      onReorderItem: (oldIndex, newIndex) {
        setState(() => _pages.insert(newIndex, _pages.removeAt(oldIndex)));
      },
      itemBuilder: (context, index) {
        final page = _pages[index];
        return Container(
          key: ValueKey(page.sourceIndex),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _colors.cardBackground,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: page.deleted
                  ? Colors.red.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    color: _colors.textTertiary,
                  ),
                ),
              ),
              Opacity(
                opacity: page.deleted ? 0.35 : 1,
                child: Container(
                  width: 56,
                  height: 74,
                  decoration: BoxDecoration(
                    color: _colors.divider,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: page.thumbnail == null
                      ? Icon(
                          Icons.description_outlined,
                          color: _colors.textTertiary,
                        )
                      : RotatedBox(
                          quarterTurns: page.rotation ~/ 90,
                          child: Image.memory(
                            page.thumbnail!,
                            fit: BoxFit.contain,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Page ${page.sourceIndex + 1}',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        decoration: page.deleted
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    if (page.rotation != 0)
                      Text(
                        'Rotated ${page.rotation}°',
                        style: const TextStyle(color: _accent, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Rotate left',
                onPressed: () => _rotate(index, -90),
                icon: Icon(
                  Icons.rotate_left_rounded,
                  color: _colors.textSecondary,
                  size: 21,
                ),
              ),
              IconButton(
                tooltip: 'Rotate right',
                onPressed: () => _rotate(index, 90),
                icon: Icon(
                  Icons.rotate_right_rounded,
                  color: _colors.textSecondary,
                  size: 21,
                ),
              ),
              IconButton(
                tooltip: page.deleted ? 'Restore page' : 'Delete page',
                onPressed: () => _toggleDelete(index),
                icon: Icon(
                  page.deleted
                      ? Icons.restore_from_trash_rounded
                      : Icons.delete_outline_rounded,
                  color: page.deleted ? _accent : Colors.red.shade400,
                  size: 21,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _colors.cardBackground,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _colors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: (_isApplying || !_isDirty) ? null : _apply,
                icon: _isApplying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_isApplying ? 'Applying…' : 'Apply changes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Staged edit for one page. [sourceIndex] is its 0-based position in the
/// *original* document — list position is where it will end up.
class _PageEdit {
  _PageEdit({required this.sourceIndex, this.thumbnail});

  final int sourceIndex;
  final Uint8List? thumbnail;
  int rotation = 0;
  bool deleted = false;
}
