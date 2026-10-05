import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_library_service.dart';
import '../utils/format_utils.dart';

/// Show the first full search of the device after storage access is granted.
///
/// That search is the payoff for a permission the user just went out of
/// their way to give, and on a full phone it takes long enough to need
/// explaining. A one-line hint above a list that has not changed yet reads as
/// "nothing happened"; a live count says the grant worked and what it is
/// finding. The search never depends on the dialog: "Run in background" (or
/// Back) closes it and the sweep carries on.
///
/// [found] resolves to the number of PDFs found, or null if the search could
/// not finish. [progress] defaults to [PdfLibraryService.progress].
Future<void> showPdfScanDialog(
  BuildContext context, {
  required Future<int?> found,
  ValueListenable<PdfScanProgress?>? progress,
}) {
  return showDialog<void>(
    context: context,
    // A stray tap beside the dialog should not hide a search the user is
    // watching. Back still closes it; the search carries on either way.
    barrierDismissible: false,
    builder: (_) => _PdfScanDialog(
      found: found,
      progress: progress ?? PdfLibraryService.progress,
    ),
  );
}

enum _Phase { searching, found, empty, failed }

class _PdfScanDialog extends StatefulWidget {
  const _PdfScanDialog({required this.found, required this.progress});

  final Future<int?> found;
  final ValueListenable<PdfScanProgress?> progress;

  @override
  State<_PdfScanDialog> createState() => _PdfScanDialogState();
}

class _PdfScanDialogState extends State<_PdfScanDialog> {
  static const Color _accent = Color(0xFFE94560);
  static const Color _success = Color(0xFF4CAF50);
  static const Duration _morph = Duration(milliseconds: 220);

  _Phase _phase = _Phase.searching;
  int _count = 0;

  /// The latest counts, held here because the service clears its progress
  /// as soon as the walk ends — before the screen has finished with the
  /// result. Reading the listenable directly would drop the count to zero
  /// for that moment.
  PdfScanProgress? _latest;

  @override
  void initState() {
    super.initState();
    _latest = widget.progress.value;
    widget.progress.addListener(_onProgress);
    widget.found.then<void>(_finish, onError: (Object _) => _finish(null));
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    final value = widget.progress.value;
    if (value == null || _phase != _Phase.searching || !mounted) return;
    setState(() => _latest = value);
  }

  void _finish(int? count) {
    if (!mounted) return;
    setState(() {
      _count = count ?? 0;
      _phase = switch (count) {
        null => _Phase.failed,
        0 => _Phase.empty,
        _ => _Phase.found,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final searching = _phase == _Phase.searching;
    final pdfs = searching ? (_latest?.pdfs ?? 0) : _count;
    final folders = _latest?.folders ?? 0;

    final (IconData icon, Color tint) = switch (_phase) {
      _Phase.searching => (Icons.manage_search_rounded, _accent),
      _Phase.found => (Icons.check_rounded, _success),
      _Phase.empty => (Icons.search_off_rounded, colors.textSecondary),
      _Phase.failed => (Icons.error_outline_rounded, Colors.red.shade400),
    };
    final title = switch (_phase) {
      _Phase.searching => 'Finding your PDFs',
      _Phase.found => 'Search complete',
      _Phase.empty => 'No PDFs found',
      _Phase.failed => 'Couldn\'t finish searching',
    };
    final message = switch (_phase) {
      _Phase.searching =>
        'Looking through internal storage and any SD card or USB drive.',
      _Phase.found => 'They\'re listed in Files, ready to open.',
      _Phase.empty =>
        'Nothing in internal storage or on a connected drive yet. PDFs you '
            'download or receive will show up in Files.',
      _Phase.failed =>
        'Something interrupted the search. Pull down on the list to try '
            'again.',
    };
    const tabular = [FontFeature.tabularFigures()];

    return Dialog(
      backgroundColor: colors.cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: AnimatedSize(
          duration: _morph,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: _morph,
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Container(
                    key: ValueKey(_phase),
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: tint, size: 28),
                  ),
                ),
                const SizedBox(height: 16),
                // Announced on each change, so a screen reader hears the
                // outcome without the running counts being read every tick.
                Semantics(
                  liveRegion: true,
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
                if (searching || _phase == _Phase.found) ...[
                  const SizedBox(height: 20),
                  Text(
                    formatCount(pdfs),
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      fontFeatures: tabular,
                    ),
                  ),
                  Text(
                    pdfs == 1 ? 'PDF found' : 'PDFs found',
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                ],
                if (searching) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                    color: _accent,
                    backgroundColor: _accent.withValues(alpha: 0.12),
                    semanticsLabel: 'Searching for PDFs',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    folders == 1
                        ? '1 folder searched'
                        : '${formatCount(folders)} folders searched',
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 12,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedSwitcher(
                    duration: _morph,
                    child: searching
                        ? TextButton(
                            key: const ValueKey('background'),
                            onPressed: () => Navigator.pop(context),
                            child: Text(
                              'Run in background',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          )
                        : FilledButton(
                            key: const ValueKey('done'),
                            onPressed: () => Navigator.pop(context),
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                            ),
                            child: Text(
                              _phase == _Phase.found ? 'View PDFs' : 'OK',
                            ),
                          ),
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
