import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/features.dart';
import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_service.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../widgets/password_prompt.dart';
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

  /// Fingers currently on the glass, counted by a [Listener].
  ///
  /// A `Listener` reports raw pointer events without entering the gesture
  /// arena, so counting here costs nothing and steals nothing. See
  /// [_isMultiTouch] for what the count is for.
  int _activePointers = 0;

  /// True from the moment a second finger lands until it lifts.
  ///
  /// This is the fix for zoom working only sometimes. `InteractiveViewer`'s
  /// scale recognizer and the page list's vertical-drag recognizer both enter
  /// the gesture arena when two fingers go down, and whichever passes its
  /// threshold first wins outright. Two fingers that drift downwards before
  /// they spread — which is most of them — hand the arena to the drag, and the
  /// pinch is silently discarded; spread them cleanly and scale wins. Same
  /// gesture, different outcome, which is exactly what it looked like.
  ///
  /// While this is true the list is given [NeverScrollableScrollPhysics] and
  /// the double-tap recognizer is withdrawn, so nothing is left in the arena
  /// to beat the pinch. See flutter/flutter#65006 and #58636.
  bool _isMultiTouch = false;

  AnimationController? _zoomAnimation;

  /// The password actually in use. Starts as whatever the caller knew (Tools
  /// passes one along) and is replaced by whatever the user types when the
  /// document turns out to be locked.
  late String _password = widget.password;

  /// Set when the document is locked and we have no working password, so the
  /// error view can offer another attempt instead of being a dead end.
  bool _needsPassword = false;

  /// The first "this page is not exactly as authored" note any page reported,
  /// shown once and dismissible. Worth saying because the alternative — a
  /// silently approximate page — is what made substituted fonts and skipped
  /// images so hard to diagnose.
  String? _approximateNotice;
  bool _noticeDismissed = false;

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

  void _onPointerDown(PointerDownEvent _) {
    _activePointers++;
    _syncMultiTouch();
  }

  void _onPointerFinished(PointerEvent _) {
    if (_activePointers > 0) _activePointers--;
    _syncMultiTouch();
  }

  /// Rebuild only when crossing the one-to-two finger boundary — a third
  /// finger changes nothing, and rebuilding the page list per pointer event
  /// would be far more expensive than the problem being solved.
  void _syncMultiTouch() {
    final isMultiTouch = _activePointers >= 2;
    if (isMultiTouch == _isMultiTouch) return;
    setState(() => _isMultiTouch = isMultiTouch);
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
    await _load();
  }

  /// Read the document, asking for a password for as long as it takes.
  ///
  /// Every route into the viewer ends up here, which is why the prompt lives
  /// in the viewer rather than at each call site: the library, a share intent
  /// and the splash route all used to open locked files with an empty
  /// password and report them as having no pages.
  Future<void> _load() async {
    bool isRetry = false;
    while (true) {
      try {
        final count = await PdfRaster.pageCountOf(
          widget.pdfPath,
          password: _password,
        );
        final ratio = await PdfRaster.aspectRatio(
          widget.pdfPath,
          password: _password,
        );
        if (!mounted) return;
        setState(() {
          _totalPages = count;
          _aspectRatio = ratio ?? _aspectRatio;
          _isLoading = false;
          _needsPassword = false;
          if (count == 0) _error = 'This PDF has no pages to display.';
        });
        return;
      } on PdfException catch (e) {
        if (!mounted) return;
        if (!e.isEncrypted && !e.isWrongPassword) {
          setState(() {
            _isLoading = false;
            _error = PdfCoreService.describeError(e);
          });
          return;
        }
        final entered = await showPdfPasswordPrompt(
          context,
          retry: isRetry || e.isWrongPassword,
          fileName: _fileName,
        );
        if (!mounted) return;
        if (entered == null) {
          setState(() {
            _isLoading = false;
            _needsPassword = true;
            _error = 'This PDF is password protected.';
          });
          return;
        }
        isRetry = true;
        setState(() {
          _password = entered;
          _isLoading = true;
          _error = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _error = PdfCoreService.describeError(e);
        });
        return;
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
                    password: _password,
                  ),
                ),
              ),
              Divider(color: colors.divider, height: 20),
              if (Features.ai)
                _action(
                  ctx,
                  colors,
                  Icons.auto_awesome_rounded,
                  'Ask AI',
                  () => _push(
                    AiScreen(pdfPath: widget.pdfPath, password: _password),
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
                    password: _password,
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
                    password: _password,
                    isEncrypted: _password.isNotEmpty,
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
                    password: _password,
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
      body: Column(
        children: [
          _approximateBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// Remember the first page warning so the reader can be told once.
  void _noteWarnings(List<String> warnings) {
    if (warnings.isEmpty || _approximateNotice != null || !mounted) return;
    setState(() => _approximateNotice = warnings.first);
  }

  /// A quiet strip above the pages, not a dialog: the document is readable,
  /// it is just not pixel-exact.
  Widget _approximateBanner() {
    final notice = _approximateNotice;
    if (notice == null || _noticeDismissed) return const SizedBox.shrink();
    return Material(
      color: _colors.cardBackground,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: _colors.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                notice,
                style: TextStyle(color: _colors.textSecondary, fontSize: 12),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: _colors.textTertiary),
              onPressed: () => setState(() => _noticeDismissed = true),
              tooltip: 'Dismiss',
            ),
          ],
        ),
      ),
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
              if (_needsPassword) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _error = null;
                    });
                    _load();
                  },
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Enter password'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Listener(
      // Outside the arena, so this sees every finger without competing for
      // any of them.
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerFinished,
      onPointerCancel: _onPointerFinished,
      child: GestureDetector(
        // Withdrawn during a pinch: a tap recognizer wrapping an
        // InteractiveViewer delays and sometimes swallows the zoom while the
        // arena waits to see whether a second tap is coming
        // (flutter/flutter#58636). With one finger down it is free to work.
        onDoubleTapDown: _isMultiTouch ? null : _onDoubleTap,
        // The handler lives on onDoubleTapDown so the tap position is known;
        // onDoubleTap still has to be present for the recognizer to fire.
        onDoubleTap: _isMultiTouch ? null : () {},
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
            // Keep a screenful either side rendered so scrolling rarely shows
            // a blank page while the rasterizer catches up.
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            // Locking the list removes its drag recognizer from the arena
            // outright, which is what leaves the pinch uncontested.
            physics: shouldLockScroll(
              isZoomed: _isZoomed,
              activePointers: _activePointers,
            )
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            itemCount: _totalPages,
            itemBuilder: (context, index) => _PageView(
              key: ValueKey('${widget.pdfPath}#$index'),
              path: widget.pdfPath,
              password: _password,
              pageIndex: index,
              fallbackAspectRatio: _aspectRatio,
              isDark: _colors.isDark,
              zoom: _zoom,
              onMeasured: (height) => _pageHeights[index] = height,
              onWarnings: _noteWarnings,
            ),
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
    required this.onWarnings,
  });

  final String path;
  final String password;
  final int pageIndex;
  final double fallbackAspectRatio;
  final bool isDark;
  final ValueListenable<double> zoom;
  final ValueChanged<double> onMeasured;
  final ValueChanged<List<String>> onWarnings;

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
      final useCache = target <= PdfRaster.thumbnailSize * 4;
      final bytes = await PdfRaster.renderPage(
        widget.path,
        widget.pageIndex,
        longEdge: target,
        password: widget.password,
        // High-resolution zoom renders are one-offs; keeping them would
        // evict every thumbnail in the cache.
        useCache: useCache,
      );
      if (bytes != null) {
        widget.onWarnings(
          PdfRaster.warningsFor(
            widget.path,
            widget.pageIndex,
            longEdge: target,
            password: widget.password,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes ?? _bytes;
        _aspectRatio = ratio ?? _aspectRatio;
        _renderedLongEdge = target;
      });
    } catch (e) {
      // One page failing is not the document failing: keep whatever was
      // already drawn and leave the placeholder for this one. The document
      // itself already opened, so this is a per-page problem.
      logError('PdfViewer._render', e);
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
/// Whether the page list should refuse drags right now.
///
/// Two reasons, and they are different in kind. While zoomed, dragging means
/// pan, not scroll. And from the moment a second finger lands, the list has to
/// stand down so the pinch is not stolen: `InteractiveViewer`'s scale
/// recognizer and the list's vertical-drag recognizer compete in the same
/// gesture arena, and the drag frequently wins on the downward drift that
/// precedes a spread. Refusing here removes the drag recognizer from the
/// arena entirely, which is what makes zoom fire every time instead of most
/// times (flutter/flutter#65006).
bool shouldLockScroll({required bool isZoomed, required int activePointers}) =>
    isZoomed || activePointers >= 2;

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
