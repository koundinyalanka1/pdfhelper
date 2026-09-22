import 'package:flutter/material.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_library_service.dart';
import '../services/recent_files_service.dart';
import '../utils/format_utils.dart';

/// A horizontal row of recently-opened PDFs, for picking one without going
/// through the system file browser.
///
/// Merge and Split both start by asking for a document, and the answer is very
/// often one that was just open in the viewer — so making the file browser the
/// only way in meant leaving the app to find something the app already knew
/// about. A strip rather than a list because both screens need the vertical
/// space for their own work, and it has to stay on screen while more files are
/// added rather than only decorating an empty state.
///
/// Renders nothing at all when there is nothing to offer, so neither screen
/// has to reason about an empty section.
class RecentPdfsStrip extends StatefulWidget {
  const RecentPdfsStrip({
    super.key,
    required this.onSelected,
    this.excludePaths = const {},
    this.maxItems = 12,
    this.accent = const Color(0xFFE94560),
  });

  /// Called with the chosen file's path.
  final ValueChanged<String> onSelected;

  /// Files already in play on the host screen. Offering a document that is
  /// visibly on screen twice is noise, and in Merge it is a mistake waiting
  /// to happen.
  final Set<String> excludePaths;

  final int maxItems;

  /// Matches the host screen's accent so the strip does not look bolted on.
  final Color accent;

  @override
  State<RecentPdfsStrip> createState() => _RecentPdfsStripState();
}

class _RecentPdfsStripState extends State<RecentPdfsStrip> {
  List<PdfFileEntry> _entries = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final paths = await RecentFilesService.recents();
    final entries = <PdfFileEntry>[];
    for (final path in paths) {
      if (entries.length >= widget.maxItems) break;
      // describe() returns null for a file that has since been deleted or
      // moved, which is exactly the filter wanted here.
      final entry = await PdfLibraryService.describe(path);
      if (entry != null) entries.add(entry);
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final visible = _entries
        .where((e) => !widget.excludePaths.contains(e.path))
        .toList();
    // Nothing yet, or nothing left to offer: take up no room.
    if (!_loaded || visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Icon(Icons.history_rounded, size: 15, color: colors.textTertiary),
                const SizedBox(width: 6),
                Text(
                  'Recent',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _chip(colors, visible[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(AppColors colors, PdfFileEntry entry) {
    return Semantics(
      button: true,
      label: 'Use recent PDF ${entry.title}',
      child: Material(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onSelected(entry.path),
          child: Container(
            width: 180,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.accent.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.picture_as_pdf_rounded,
                  size: 20,
                  color: widget.accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatFileSize(entry.sizeBytes),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
