import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_service.dart';
import '../services/recent_files_service.dart';
import 'ai_screen.dart';
import 'extract_text_screen.dart';
import 'home_screen.dart';
import 'merge_pdf_screen.dart';
import 'metadata_screen.dart';
import 'organize_pages_screen.dart';
import 'protect_screen.dart';
import 'split_pdf_screen.dart';

/// Continuous-scroll PDF viewer built on the native Rust rasterizer.
///
/// Pages render lazily as they scroll into view and are cached by
/// [PdfRaster]. Pinching a page re-renders it at higher resolution so zoomed
/// text stays sharp instead of turning into an upscaled thumbnail.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.pdfPath,
    this.title,
    this.password = '',
  });

  final String pdfPath;
  final String? title;
  final String password;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final Map<int, double> _pageHeights = {};

  /// Zoom for the whole document.
  ///
  /// Previously every page carried its own [InteractiveViewer] inside the
  /// scrolling list. Two problems: the list's vertical drag recognizer beat
  /// each page's scale recognizer in the gesture arena, so pinching usually
  /// did nothing at all; and even when it won, the page scaled inside its own
  /// clipped box, so "zooming" just cropped the page. One viewer wrapping the
  /// list fixes both — it sees the gesture first, and it magnifies what is
  /// actually on screen.
  final TransformationController _zoomController = TransformationController();

  /// Current scale, watched by each visible page so it can re-rasterize
  /// sharper instead of showing a magnified thumbnail.
  final ValueNotifier<double> _zoom = ValueNotifier<double>(1.0);

  /// While zoomed, dragging pans instead of scrolling the list.
  bool _isZoomed = false;

  AnimationController? _zoomAnimation;

  int _currentPage = 1;
  int _totalPages = 0;
  double _aspectRatio = 0.7071; // A4 portrait until the real value lands
  bool _isLoading = true;
  String? _error;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  String get _fileName =>
      widget.title ?? widget.pdfPath.split(RegExp(r'[/\\]')).last;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _zoomController.addListener(_onZoomChanged);
    _open();
  }

  @override
  void dispose() {
    _zoomAnimation?.dispose();
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _zoom.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    _zoom.value = scale;
    final zoomed = scale > 1.02;
    if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
  }

  /// Double-tap toggles between fit-width and 2.5x, centred on the tap.
  ///
  /// Pinch works too, but a double-tap is a single-pointer gesture that can
  /// never be lost to the scroll view — so there is always a way to zoom.
  void _onDoubleTap(TapDownDetails details) {
    final target = doubleTapZoomTarget(
      isZoomed: _isZoomed,
      focalPoint: details.localPosition,
    );

    _zoomAnimation?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _zoomAnimation = controller;
    final animation = Matrix4Tween(
      begin: _zoomController.value,
      end: target,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOutCubic));
    animation.addListener(() => _zoomController.value = animation.value);
    controller.forward();
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
  }

  Future<void> _open() async {
    if (!await File(widget.pdfPath).exists()) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'File not found';
        });
      }
      return;
    }
    // Anything that reaches the viewer belongs in Recent — including files
    // opened from another app, which the library sweep never sees.
    unawaited(RecentFilesService.markOpened(widget.pdfPath));
    try {
      final count = await PdfRaster.pageCountOf(
        widget.pdfPath,
        password: widget.password,
      );
      final ratio = await PdfRaster.aspectRatio(
        widget.pdfPath,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() {
        _totalPages = count;
        _aspectRatio = ratio ?? _aspectRatio;
        _isLoading = false;
        if (count == 0) _error = 'This PDF has no pages to display.';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = PdfCoreService.describeError(e);
        });
      }
    }
  }

  /// Track which page is under the middle of the viewport for the counter.
  void _onScroll() {
    if (!_scrollController.hasClients || _pageHeights.isEmpty) return;
    final offset = _scrollController.offset + 100;
    double running = 0;
    for (int i = 0; i < _totalPages; i++) {
      running += _pageHeights[i] ?? _estimatedPageHeight;
      if (running > offset) {
        if (_currentPage != i + 1) setState(() => _currentPage = i + 1);
        return;
      }
    }
  }

  double get _estimatedPageHeight {
    final width = MediaQuery.of(context).size.width - 24;
    return width / _aspectRatio + 12;
  }

  /// Pop back if there is somewhere to return to, otherwise land on Home —
  /// which happens when a PDF intent opened the viewer as the root route.
  void _onBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  Future<void> _jumpToPage() async {
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text('Go to page', style: TextStyle(color: _colors.textPrimary)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: TextStyle(color: _colors.textPrimary),
          decoration: InputDecoration(hintText: '1 – $_totalPages'),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: _colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (target == null || target < 1 || target > _totalPages) return;
    _scrollController.jumpTo(
      ((target - 1) * _estimatedPageHeight).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      ),
    );
  }

  /// Everything you can do to the document you are reading.
  ///
  /// This is the only route to the rest of the app for a PDF opened from
  /// somewhere else: the "Open with" chooser offers one entry — view — rather
  /// than a menu of verbs chosen before the user has seen the document. Once
  /// it is on screen, picking a tool is an informed decision.
  void _showActions() {
    final isRoot = !Navigator.of(context).canPop();
    // Read, not watch: this runs from a tap handler rather than from build,
    // and `watch` outside build throws.
    final colors = AppColors(context.read<ThemeProvider>().isDarkMode);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.picture_as_pdf_rounded,
                      color: Color(0xFFE94560),
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: colors.divider, height: 20),
              _action(ctx, colors, Icons.merge_rounded, 'Merge with…', () {
                _push(MergePdfScreen(initialPdfPath: widget.pdfPath));
              }),
              _action(ctx, colors, Icons.content_cut_rounded, 'Split', () {
                _push(SplitPdfScreen(initialPdfPath: widget.pdfPath));
              }),
              _action(
                ctx,
                colors,
                Icons.dashboard_customize_rounded,
                'Organize pages',
                () => _push(
                  OrganizePagesScreen(
                    pdfPath: widget.pdfPath,
                    password: widget.password,
                  ),
                ),
              ),
              Divider(color: colors.divider, height: 20),
              _action(
                ctx,
                colors,
                Icons.auto_awesome_rounded,
                'Ask AI',
                () => _push(
                  AiScreen(pdfPath: widget.pdfPath, password: widget.password),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.text_snippet_rounded,
                'Extract text',
                () => _push(
                  ExtractTextScreen(
                    pdfPath: widget.pdfPath,
                    password: widget.password,
                  ),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.lock_rounded,
                'Protect',
                () => _push(
                  ProtectScreen(
                    pdfPath: widget.pdfPath,
                    password: widget.password,
                    isEncrypted: widget.password.isNotEmpty,
                  ),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.info_outline_rounded,
                'Document details',
                () => _push(
                  MetadataScreen(
                    pdfPath: widget.pdfPath,
                    password: widget.password,
                  ),
                ),
              ),
              Divider(color: colors.divider, height: 20),
              _action(
                ctx,
                colors,
                Icons.open_in_new_rounded,
                'Open in another app',
                () => PdfService.openPdf(widget.pdfPath),
              ),
              // Only when the viewer *is* the app — opened straight from
              // another app's "Open with". Otherwise there is already a stack
              // to go back through.
              if (isRoot)
                _action(
                  ctx,
                  colors,
                  Icons.folder_rounded,
                  'Browse all PDFs',
                  () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const HomeScreen()),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext sheetContext,
    AppColors colors,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: const Color(0xFFE94560), size: 21),
      title: Text(
        label,
        style: TextStyle(color: colors.textPrimary, fontSize: 14.5),
      ),
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
    );
  }

  void _push(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.isDark
          ? const Color(0xFF12121C)
          : Colors.grey.shade300,
      appBar: AppBar(
        title: Text(
          _fileName,
          style: TextStyle(color: _colors.textPrimary, fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _onBack,
          color: _colors.textPrimary,
        ),
        actions: [
          if (_isZoomed)
            IconButton(
              icon: const Icon(Icons.zoom_out_map_rounded),
              tooltip: 'Fit to width',
              onPressed: _resetZoom,
              color: _colors.textPrimary,
            ),
          if (_totalPages > 0)
            TextButton(
              onPressed: _jumpToPage,
              child: Text(
                '$_currentPage / $_totalPages',
                style: TextStyle(color: _colors.textSecondary, fontSize: 14),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: () => SharePlus.instance.share(
              ShareParams(files: [XFile(widget.pdfPath)], text: 'PDF'),
            ),
            color: _colors.textPrimary,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More actions',
            onPressed: _showActions,
            color: _colors.textPrimary,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE94560)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: _colors.textTertiary),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.textSecondary, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onDoubleTapDown: _onDoubleTap,
      // The handler lives on onDoubleTapDown so the tap position is known;
      // onDoubleTap still has to be present for the recognizer to fire.
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: _zoomController,
        minScale: 1.0,
        maxScale: 6.0,
        // Panning is handed to the list until the user actually zooms in;
        // otherwise a plain drag would never scroll the document.
        panEnabled: _isZoomed,
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 6),
          // Keep a screenful either side rendered so scrolling rarely shows a
          // blank page while the rasterizer catches up.
          scrollCacheExtent: const ScrollCacheExtent.viewport(1),
          physics: _isZoomed
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          itemCount: _totalPages,
          itemBuilder: (context, index) => _PageView(
            key: ValueKey('${widget.pdfPath}#$index'),
            path: widget.pdfPath,
            password: widget.password,
            pageIndex: index,
            fallbackAspectRatio: _aspectRatio,
            isDark: _colors.isDark,
            zoom: _zoom,
            onMeasured: (height) => _pageHeights[index] = height,
          ),
        ),
      ),
    );
  }
}

/// One page: renders on first appearance, re-renders sharper when zoomed.
class _PageView extends StatefulWidget {
  const _PageView({
    super.key,
    required this.path,
    required this.password,
    required this.pageIndex,
    required this.fallbackAspectRatio,
    required this.isDark,
    required this.zoom,
    required this.onMeasured,
  });

  final String path;
  final String password;
  final int pageIndex;
  final double fallbackAspectRatio;
  final bool isDark;
  final ValueListenable<double> zoom;
  final ValueChanged<double> onMeasured;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> {
  Uint8List? _bytes;
  double? _aspectRatio;
  int _renderedLongEdge = 0;
  bool _isRendering = false;

  @override
  void initState() {
    super.initState();
    widget.zoom.addListener(_onZoom);
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  @override
  void dispose() {
    widget.zoom.removeListener(_onZoom);
    super.dispose();
  }

  /// Past ~1.4x the rendered resolution starts to show, so ask for a sharper
  /// raster at the zoomed size.
  void _onZoom() {
    final scale = widget.zoom.value;
    if (scale < 1.4 || _isRendering || !mounted) return;
    final wanted = (_baseLongEdge * scale.clamp(1.0, 4.0)).round();
    if (wanted > _renderedLongEdge * 1.4) _render(longEdge: wanted);
  }

  int get _baseLongEdge {
    final media = MediaQuery.of(context);
    // Render at real device pixels, capped so a tablet at 3x doesn't ask for
    // a 4000px page on every scroll.
    return ((media.size.width - 24) * media.devicePixelRatio)
        .clamp(360.0, 2400.0)
        .round();
  }

  Future<void> _render({int? longEdge}) async {
    if (_isRendering || !mounted) return;
    final target = longEdge ?? _baseLongEdge;
    _isRendering = true;
    try {
      final ratio =
          _aspectRatio ??
          await PdfRaster.aspectRatio(
            widget.path,
            pageIndex: widget.pageIndex,
            password: widget.password,
          );
      final bytes = await PdfRaster.renderPage(
        widget.path,
        widget.pageIndex,
        longEdge: target,
        password: widget.password,
        // High-resolution zoom renders are one-offs; keeping them would
        // evict every thumbnail in the cache.
        useCache: target <= PdfRaster.thumbnailSize * 4,
      );
      if (!mounted) return;
      setState(() {
        _bytes = bytes ?? _bytes;
        _aspectRatio = ratio ?? _aspectRatio;
        _renderedLongEdge = target;
      });
    } finally {
      _isRendering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatio ?? widget.fallbackAspectRatio;
    final width = MediaQuery.of(context).size.width - 24;
    final height = width / (ratio <= 0 ? 0.7071 : ratio);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onMeasured(height + 12),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: widget.isDark ? 0.5 : 0.2),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: _bytes == null
            ? Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.grey.shade400,
                  ),
                ),
              )
            : Image.memory(
                _bytes!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // The whole document is magnified by one InteractiveViewer
                // above the list, so the page itself just draws at its
                // natural size — and re-rasterizes when the zoom changes.
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}

/// Transform a double-tap should settle on.
///
/// Zooming in keeps the tapped point under the finger: scaling by `scale`
/// about the origin moves a point at `focalPoint` out to `focalPoint * scale`,
/// so the view is translated back by `focalPoint * (scale - 1)` to cancel it.
/// Zooming out always returns to fit-width.
///
/// Pulled out of the widget because this is the part that is easy to get
/// subtly wrong — an off-by-one in the translation sends the page off screen
/// and looks exactly like "zoom is broken".
Matrix4 doubleTapZoomTarget({
  required bool isZoomed,
  required Offset focalPoint,
  double scale = 2.5,
}) {
  if (isZoomed) return Matrix4.identity();
  final shift = scale - 1.0;
  return Matrix4.identity()
    ..translateByDouble(-focalPoint.dx * shift, -focalPoint.dy * shift, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}
