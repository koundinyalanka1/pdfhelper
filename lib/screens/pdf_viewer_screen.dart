import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/features.dart';
import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_service.dart';
import '../services/pdf_text_search.dart';
import '../services/pdf_text_selection_service.dart';
import '../services/recent_files_service.dart';
import '../utils/error_logger.dart';
import '../widgets/password_prompt.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/pdf_text_selection_overlay.dart';
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
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final PdfTextSelectionController _textSelectionController =
      PdfTextSelectionController();
  double _lastScrollOffset = 0;

  /// Find in document. Created once the page count is known; the find bar
  /// replaces the app bar while [_finding].
  PdfDocumentSearch? _search;
  bool _finding = false;
  final TextEditingController _findText = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  Timer? _findDebounce;

  /// Whether this find session has already explained that the document has
  /// no text to search, so each new query doesn't repeat it.
  bool _explainedNoText = false;

  /// Every page's width/height as it becomes known — all of them shortly
  /// after opening (see [_loadPageRatios]), or from the page itself if it
  /// renders first. Held here rather than in each page so that a page rebuilt
  /// after scrolling away is laid out at its real height straight away.
  final Map<int, double> _pageRatios = {};

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
  Matrix4 _lastDocumentTransform = Matrix4.identity();

  /// Current scale, watched by each visible page so it can re-rasterize
  /// sharper instead of showing a magnified thumbnail.
  final ValueNotifier<double> _zoom = ValueNotifier<double>(1.0);

  /// While zoomed, the scale recognizer owns dragging. Its vertical movement
  /// scrolls the page list; its horizontal movement pans the enlarged page.
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
  late final AnimationController _verticalPanAnimation;
  double _lastVerticalPanValue = 0;
  bool _verticalPanGesture = false;

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
    _verticalPanAnimation = AnimationController.unbounded(vsync: this)
      ..addListener(_onVerticalPanTick);
    _textSelectionController.addListener(_onSelectionChanged);
    _scrollController.addListener(_onScroll);
    _zoomController.addListener(_onZoomChanged);
    _open();
  }

  @override
  void dispose() {
    _findDebounce?.cancel();
    _search?.dispose();
    _findText.dispose();
    _findFocus.dispose();
    _textSelectionController.removeListener(_onSelectionChanged);
    _textSelectionController.dispose();
    _zoomAnimation?.dispose();
    _verticalPanAnimation.dispose();
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _zoom.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent _) {
    _verticalPanAnimation.stop();
    _verticalPanGesture = false;
    _activePointers++;
    if (_activePointers > 1) _textSelectionController.clear();
    _syncMultiTouch();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  void _onPointerFinished(PointerEvent event) {
    if (event is PointerCancelEvent) {
      _verticalPanGesture = false;
      _verticalPanAnimation.stop();
    }
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
    final transform = _zoomController.value;
    if (!listEquals(transform.storage, _lastDocumentTransform.storage)) {
      _lastDocumentTransform = Matrix4.copy(transform);
      // Controls live above the page to keep their touch targets unscaled.
      // Dismiss them when the reader moves the document, before they can
      // follow selected text into the app bar or beyond the viewport.
      _textSelectionController.clear();
    }
    final scale = transform.getMaxScaleOnAxis();
    _zoom.value = scale;
    final zoomed = scale > 1.02;
    if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
    _updateCurrentPage();
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    // The list has no competing drag recognizer while zoomed. Only consume a
    // recognized one-finger pan, so pinches and text-selection handles retain
    // their own gestures and focal points.
    _verticalPanGesture =
        _isZoomed && details.pointerCount == 1 && details.scale == 1.0;
    if (_verticalPanGesture) _panVertically(details.focalPointDelta.dy);
  }

  /// Move in screen pixels while keeping the list lazy and the zoom intact.
  /// InteractiveViewer's child is only a viewport high, so translating that
  /// child alone cannot reach the rest of a document. Scroll through its pages
  /// first, then use the remaining vertical pan at the document's two ends to
  /// expose the top/bottom of the enlarged viewport.
  bool _panVertically(double delta) {
    if (delta == 0 || !_scrollController.hasClients) return false;
    final transform = _zoomController.value;
    final scale = transform.getMaxScaleOnAxis();
    final position = _scrollController.position;
    final before = position.pixels;
    final after = (before - delta / scale).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final oldY = transform.storage[13];
    final newY = (oldY + delta + (after - before) * scale).clamp(
      position.viewportDimension * (1 - scale),
      0.0,
    );
    if (after != before) _scrollController.jumpTo(after);
    if ((newY - oldY).abs() > 0.001) {
      _zoomController.value = Matrix4.copy(transform)..setEntry(1, 3, newY);
    }
    return after != before || (newY - oldY).abs() > 0.001;
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (!_verticalPanGesture || velocity.abs() < kMinFlingVelocity) return;
    _verticalPanGesture = false;
    _lastVerticalPanValue = 0;
    _verticalPanAnimation.value = 0;
    // InteractiveViewer supplies horizontal inertia. Vertical inertia follows
    // the same document/viewport boundary handling as a drag, including when
    // the final page needs a little more pan after the list reaches its end.
    unawaited(
      _verticalPanAnimation.animateWith(
        ClampingScrollSimulation(position: 0, velocity: velocity),
      ),
    );
  }

  void _onVerticalPanTick() {
    final value = _verticalPanAnimation.value;
    final delta = value - _lastVerticalPanValue;
    _lastVerticalPanValue = value;
    if (delta != 0 && !_panVertically(delta)) _verticalPanAnimation.stop();
  }

  /// Double-tap toggles between fit-width and 2.5x, centred on the tap.
  ///
  /// Pinch works too, but a double-tap is a single-pointer gesture that can
  /// never be lost to the scroll view — so there is always a way to zoom.
  void _onDoubleTap(TapDownDetails details) {
    _verticalPanAnimation.stop();
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
    _verticalPanAnimation.stop();
    _zoomAnimation?.stop();
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
          if (ratio != null) _pageRatios[0] = ratio;
          _isLoading = false;
          _needsPassword = false;
          if (count == 0) _error = 'This PDF has no pages to display.';
        });
        _createSearch(count);
        unawaited(_loadPageRatios());
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

  /// Learn every page's shape, a batch at a time, so pages are laid out at
  /// their real height before they are ever built.
  ///
  /// Pages used to take page 1's shape until each one rendered. A document
  /// whose pages differ — a portrait cover ahead of landscape spreads — then
  /// had every page resize mid-scroll, and each resize above the viewport
  /// shoved the page being read out of view: scrolling bounced between the
  /// same two pages.
  Future<void> _loadPageRatios() async {
    const batchSize = 16;
    for (int start = 0; start < _totalPages; start += batchSize) {
      final end = start + batchSize < _totalPages
          ? start + batchSize
          : _totalPages;
      final List<double?> ratios;
      try {
        ratios = await PdfRaster.aspectRatios(
          widget.pdfPath,
          start,
          end,
          password: _password,
        );
      } catch (e) {
        // Pages still learn their own shape as they render.
        logError('PdfViewer._loadPageRatios', e);
        return;
      }
      if (!mounted) return;
      setState(() {
        for (int i = start; i < end; i++) {
          final ratio = ratios[i - start];
          if (ratio != null) _pageRatios[i] = ratio;
        }
      });
    }
  }

  double get _pageWidth => MediaQuery.of(context).size.width - 24;

  /// Height page [index] occupies in the list, margins included.
  double _pageExtent(int index) =>
      pageHeight(
        _pageWidth,
        pageAspectRatio(_pageRatios, index, _aspectRatio),
      ) +
      12;

  /// Clear selection when the document scrolls, then update the page counter.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final scrollOffset = _scrollController.offset;
    if (scrollOffset != _lastScrollOffset) {
      _lastScrollOffset = scrollOffset;
      _textSelectionController.clear();
    }
    _updateCurrentPage();
  }

  void _updateCurrentPage() {
    final page = _pageIndexAt(100);
    if (page != null && _currentPage != page + 1) {
      setState(() => _currentPage = page + 1);
    }
  }

  /// Index of the page drawn [y] pixels down the viewport, scroll and zoom
  /// included; null before there is a page list or past its end.
  int? _pageIndexAt(double y) {
    if (!_scrollController.hasClients) return null;
    final transform = _zoomController.value;
    final offset =
        _scrollController.offset +
        (y - transform.storage[13]) / transform.getMaxScaleOnAxis();
    double running = 0;
    for (int i = 0; i < _totalPages; i++) {
      running += _pageExtent(i);
      if (running > offset) return i;
    }
    return null;
  }

  /// Pop back if there is somewhere to return to, otherwise land on Home —
  /// which happens when a PDF intent opened the viewer as the root route.
  void _onBack() {
    if (_textSelectionController.hasSelection) {
      _textSelectionController.clear();
      return;
    }
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
    final target = await showDialog<int>(
      context: context,
      builder: (_) => _PageNumberDialog(
        currentPage: _currentPage,
        totalPages: _totalPages,
        colors: _colors,
      ),
    );
    if (!mounted || target == null || !_scrollController.hasClients) return;
    _textSelectionController.clear();
    _resetZoom();
    double offset = 0;
    for (int i = 0; i < target - 1; i++) {
      offset += _pageExtent(i);
    }
    _scrollController.jumpTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
  }

  /// The document's search, reading text with the same password as the
  /// pages. Nothing is read until the reader searches.
  void _createSearch(int pageCount) {
    _search?.dispose();
    final path = widget.pdfPath;
    final password = _password;
    _search = PdfDocumentSearch(
      pageCount: pageCount,
      loadLayout: (index) =>
          PdfTextSelectionService.load(path, index, password: password),
      loadIndex: () => PdfTextSearch.loadIndex(
        path,
        password: password,
        pageCount: pageCount,
      ),
      onMatch: _revealMatch,
    )..addListener(_onSearchChanged);
  }

  void _openFind() {
    _textSelectionController.clear();
    _explainedNoText = false;
    // A reopened find bar keeps its last query, selected so that typing
    // replaces it.
    _findText.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findText.text.length,
    );
    setState(() => _finding = true);
    if (_findText.text.trim().isNotEmpty) _runFind();
  }

  void _closeFind() {
    _findDebounce?.cancel();
    _findFocus.unfocus();
    _search?.clear();
    setState(() => _finding = false);
  }

  /// Search as the reader types, once they pause.
  void _onFindChanged(String _) {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 250), _runFind);
  }

  /// Search from the page in the middle of the screen: the current match's
  /// page once one is centred, or wherever the reader has scrolled to since.
  void _runFind() {
    _findDebounce?.cancel();
    final middle = _scrollController.hasClients
        ? _pageIndexAt(_scrollController.position.viewportDimension / 2)
        : null;
    _search?.search(_findText.text, startPage: middle ?? _currentPage - 1);
  }

  /// The keyboard's search key runs a query that hasn't run yet. Stepping is
  /// left to the arrows, so putting the keyboard away never skips past the
  /// match just found.
  void _submitFind() {
    final search = _search;
    if (search == null) return;
    if ((_findDebounce?.isActive ?? false) || _findText.text != search.query) {
      _runFind();
    }
  }

  void _clearFind() {
    _findText.clear();
    _runFind();
    _findFocus.requestFocus();
  }

  /// An image-only scan has nothing to find. Say so once, rather than leave
  /// "0/0" looking as though the query were wrong.
  void _onSearchChanged() {
    final search = _search;
    if (search == null || !_finding || _explainedNoText) return;
    if (search.isSearching || search.query.isEmpty) return;
    if (search.documentHasText != false) return;
    _explainedNoText = true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'This PDF has no searchable text. Scanned pages need OCR.',
          ),
        ),
      );
  }

  /// Bring a match into view without changing the zoom.
  ///
  /// A match already comfortably on screen stays where it is, so stepping
  /// through one paragraph doesn't jolt the page. Otherwise it is centred:
  /// the list scrolls to it and, when zoomed in, the transform pans to it.
  void _revealMatch(PdfSearchMatch match) {
    if (!mounted || !_scrollController.hasClients) return;
    _textSelectionController.clear();
    _verticalPanAnimation.stop();
    _zoomAnimation?.stop();
    final position = _scrollController.position;
    final viewport = Size(
      MediaQuery.sizeOf(context).width,
      position.viewportDimension,
    );
    final target = _matchRectInList(match);
    final transform = _zoomController.value;
    final scale = transform.getMaxScaleOnAxis();
    var offset = position.pixels;
    var dx = transform.storage[12];
    var dy = transform.storage[13];
    // Where the match is drawn now: the list scrolls it, then the zoom
    // scales and pans the whole viewport.
    final shown = Rect.fromLTRB(
      target.left * scale + dx,
      (target.top - offset) * scale + dy,
      target.right * scale + dx,
      (target.bottom - offset) * scale + dy,
    );
    final comfortable = (Offset.zero & viewport).deflate(24);
    if (shown.top < comfortable.top || shown.bottom > comfortable.bottom) {
      final centre = viewport.height / 2;
      offset = (target.center.dy - (centre - dy) / scale).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      // Near either end the list cannot scroll far enough. While zoomed the
      // transform makes up the rest, as it does for a vertical pan.
      dy = (centre - (target.center.dy - offset) * scale).clamp(
        math.min(0.0, viewport.height * (1 - scale)),
        0.0,
      );
    }
    if (shown.left < comfortable.left || shown.right > comfortable.right) {
      dx = (viewport.width / 2 - target.center.dx * scale).clamp(
        math.min(0.0, viewport.width * (1 - scale)),
        0.0,
      );
    }
    if (offset != position.pixels) _scrollController.jumpTo(offset);
    if (dx != transform.storage[12] || dy != transform.storage[13]) {
      _zoomController.value = Matrix4.copy(transform)
        ..setEntry(0, 3, dx)
        ..setEntry(1, 3, dy);
    }
  }

  /// [match] in the page list's own coordinates, before scrolling and zoom.
  Rect _matchRectInList(PdfSearchMatch match) {
    final width = _pageWidth;
    final height = pageHeight(
      width,
      pageAspectRatio(_pageRatios, match.pageIndex, _aspectRatio),
    );
    // The list's top padding, every page above with its margins, then this
    // page's own top margin.
    var top = 6.0;
    for (int i = 0; i < match.pageIndex; i++) {
      top += _pageExtent(i);
    }
    top += 6;
    final scaleX = width / match.pageSize.width;
    final scaleY = height / match.pageSize.height;
    return Rect.fromLTRB(
      12 + match.bounds.left * scaleX,
      top + match.bounds.top * scaleY,
      12 + match.bounds.right * scaleX,
      top + match.bounds.bottom * scaleY,
    );
  }

  /// Everything you can do to the document you are reading.
  ///
  /// This is the only route to the rest of the app for a PDF opened from
  /// somewhere else: the "Open with" chooser offers one entry — view — rather
  /// than a menu of verbs chosen before the user has seen the document. Once
  /// it is on screen, picking a tool is an informed decision.
  void _showActions() {
    _textSelectionController.clear();
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
                  MetadataScreen(pdfPath: widget.pdfPath, password: _password),
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
    final search = _finding ? _search : null;
    return PopScope(
      canPop: !_textSelectionController.hasSelection && !_finding,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_textSelectionController.hasSelection) {
          _textSelectionController.clear();
        } else if (_finding) {
          _closeFind();
        }
      },
      child: Scaffold(
        backgroundColor: _colors.isDark
            ? const Color(0xFF12121C)
            : Colors.grey.shade300,
        appBar: search != null ? _findBar(search) : _viewerBar(),
        body: SafeArea(
          top: false,
          left: false,
          right: false,
          child: Column(
            children: [
              _approximateBanner(),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildBody()),
                    if (search != null)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _findProgress(search),
                      ),
                  ],
                ),
              ),
              const BannerAdWidget(),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _viewerBar() {
    return AppBar(
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
        if (_totalPages > 0)
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find in document',
            onPressed: _openFind,
            color: _colors.textPrimary,
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
    );
  }

  /// The app bar while finding: the query, where the current match falls
  /// among all of them, and arrows to step between them.
  PreferredSizeWidget _findBar(PdfDocumentSearch search) {
    return AppBar(
      backgroundColor: _colors.cardBackground,
      elevation: 0,
      centerTitle: false,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Close find',
        onPressed: _closeFind,
        color: _colors.textPrimary,
      ),
      title: ListenableBuilder(
        listenable: _findText,
        builder: (context, _) => TextField(
          controller: _findText,
          focusNode: _findFocus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(color: _colors.textPrimary, fontSize: 16),
          cursorColor: _colors.accent,
          decoration: InputDecoration(
            hintText: 'Find in document',
            hintStyle: TextStyle(color: _colors.textTertiary),
            border: InputBorder.none,
            filled: false,
            suffixIcon: _findText.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Clear',
                    onPressed: _clearFind,
                    color: _colors.textSecondary,
                  ),
          ),
          onChanged: _onFindChanged,
          onSubmitted: (_) => _submitFind(),
          // Touching the page puts the keyboard away so the matches can be
          // read. The arrows keep it: they share the field's tap region.
          onTapOutside: (_) => _findFocus.unfocus(),
        ),
      ),
      actions: [
        TextFieldTapRegion(
          child: ListenableBuilder(
            listenable: search,
            builder: (context, _) {
              final canStep = search.matchCount > 0;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _findStatus(search),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up),
                    tooltip: 'Previous match',
                    onPressed: canStep ? search.previous : null,
                    color: _colors.textPrimary,
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down),
                    tooltip: 'Next match',
                    onPressed: canStep ? search.next : null,
                    color: _colors.textPrimary,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// "3/17", a spinner until the first match turns up, or "0/0".
  Widget _findStatus(PdfDocumentSearch search) {
    if (search.query.isEmpty) return const SizedBox.shrink();
    final number = search.currentNumber;
    if (number == null && search.isSearching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: _colors.textTertiary,
          ),
        ),
      );
    }
    final total = '${search.matchCount}${search.isCapped ? '+' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        label: number == null ? 'No matches' : 'Match $number of $total',
        excludeSemantics: true,
        child: Text(
          number == null ? '0/0' : '$number/$total',
          style: TextStyle(
            color: number == null ? _colors.accent : _colors.textSecondary,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  /// A hairline under the find bar while pages are still being read, so a
  /// count that is still growing doesn't pass for the total.
  Widget _findProgress(PdfDocumentSearch search) => IgnorePointer(
    child: ListenableBuilder(
      listenable: search,
      builder: (context, _) => search.isSearching
          ? LinearProgressIndicator(
              value: search.progress,
              minHeight: 2,
              color: _colors.accent,
              backgroundColor: Colors.transparent,
            )
          : const SizedBox.shrink(),
    ),
  );

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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
        // Also clear a selection when tapping a different page or its margins.
        // Handles and the Copy toolbar handle their own taps first.
        onTap: _textSelectionController.hasSelection
            ? _textSelectionController.clear
            : null,
        // Withdrawn during a pinch: a tap recognizer wrapping an
        // InteractiveViewer delays and sometimes swallows the zoom while the
        // arena waits to see whether a second tap is coming
        // (flutter/flutter#58636). With one finger down it is free to work.
        onDoubleTapDown: _isMultiTouch || _textSelectionController.hasSelection
            ? null
            : _onDoubleTap,
        // The handler lives on onDoubleTapDown so the tap position is known;
        // onDoubleTap still has to be present for the recognizer to fire.
        onDoubleTap: _isMultiTouch || _textSelectionController.hasSelection
            ? null
            : () {},
        child: InteractiveViewer(
          transformationController: _zoomController,
          minScale: 1.0,
          maxScale: 6.0,
          // Let a pinch move freely around its focal point. One-finger pans
          // use the list for vertical travel and this transform for horizontal
          // travel, so zooming never limits reading to one screenful.
          panAxis: _isMultiTouch ? PanAxis.free : PanAxis.horizontal,
          onInteractionStart: (_) => _zoomAnimation?.stop(),
          onInteractionUpdate: _onInteractionUpdate,
          onInteractionEnd: _onInteractionEnd,
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
            physics:
                shouldLockScroll(
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
              aspectRatio: pageAspectRatio(_pageRatios, index, _aspectRatio),
              aspectRatioKnown: _pageRatios.containsKey(index),
              isDark: _colors.isDark,
              zoom: _zoom,
              textSelectionController: _textSelectionController,
              search: _search,
              // Recorded without a rebuild: the page resizes itself, and the
              // counter and Go to page read the map when they need it.
              onAspectRatio: (ratio) => _pageRatios[index] = ratio,
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
    required this.aspectRatio,
    required this.aspectRatioKnown,
    required this.isDark,
    required this.zoom,
    required this.onAspectRatio,
    required this.onWarnings,
    required this.textSelectionController,
    this.search,
  });

  final String path;
  final String password;
  final int pageIndex;

  /// The viewer's best width/height for this page: the real one once known,
  /// an estimate from the pages before it until then.
  final double aspectRatio;

  /// Whether [aspectRatio] is the page's real shape rather than an estimate.
  final bool aspectRatioKnown;
  final bool isDark;
  final ValueListenable<double> zoom;

  /// Reports the page's real shape when it had to look it up itself.
  final ValueChanged<double> onAspectRatio;
  final ValueChanged<List<String>> onWarnings;
  final PdfTextSelectionController textSelectionController;

  /// Matches to highlight on this page. The page finds its own in the text
  /// layout it already holds for selection.
  final PdfDocumentSearch? search;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> {
  Uint8List? _bytes;
  double? _aspectRatio;
  int _renderedLongEdge = 0;
  bool _isRendering = false;
  bool _renderFailed = false;
  PdfPageTextLayout? _textLayout;
  bool _loadingText = false;
  String? _textError;

  /// This page's find highlights and the query and layout they came from.
  String _highlightQuery = '';
  PdfPageTextLayout? _highlightLayout;
  List<List<Rect>> _highlights = const [];

  @override
  void initState() {
    super.initState();
    widget.zoom.addListener(_onZoom);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _render();
      _loadText();
    });
  }

  Future<void> _loadText() async {
    if (_loadingText || _textLayout != null) return;
    setState(() {
      _loadingText = true;
      _textError = null;
    });
    try {
      final layout = await PdfTextSelectionService.load(
        widget.path,
        widget.pageIndex,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() => _textLayout = layout);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _textError =
            error is PdfException && error.code == 'TEXT_SELECTION_UNAVAILABLE'
            ? 'Text selection is unavailable. Use Extract text from More actions.'
            : 'Could not load text for this page.';
      });
    } finally {
      if (mounted) setState(() => _loadingText = false);
    }
  }

  Widget _withTextSelection(Widget page) {
    final layout = _textLayout;
    if (layout != null && layout.hasText) {
      return PdfTextSelectionOverlay(
        layout: layout,
        enabled: true,
        controller: widget.textSelectionController,
        child: page,
      );
    }
    // Keep the page unobstructed while loading and for image-only scans.
    // Explain unavailable text only when the reader tries to select it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _explainUnavailableText,
      child: page,
    );
  }

  void _explainUnavailableText() {
    widget.textSelectionController.clear();
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _loadingText
              ? 'Text is still loading. Try again in a moment.'
              : _textError ??
                    'No selectable text on this page. Scanned images need OCR.',
        ),
        action: _textError == null
            ? null
            : SnackBarAction(label: 'Retry', onPressed: _loadText),
      ),
    );
  }

  List<List<Rect>> _highlightsFor(String query) {
    final layout = _textLayout;
    if (layout == null || query.isEmpty) return const [];
    if (query != _highlightQuery || !identical(layout, _highlightLayout)) {
      _highlightQuery = query;
      _highlightLayout = layout;
      _highlights = PdfTextSearch.highlights(layout, query);
    }
    return _highlights;
  }

  /// Every match on this page tinted, the current one more strongly. Drawn
  /// over the page and the text selection, and never in the way of touches.
  Widget _findHighlights(PdfDocumentSearch search) => ListenableBuilder(
    listenable: search,
    builder: (context, _) {
      final layout = _textLayout;
      final matches = _highlightsFor(search.query);
      if (layout == null || matches.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        key: const ValueKey('pdf-find-highlights'),
        child: CustomPaint(
          painter: _FindHighlightPainter(
            matches,
            search.currentIndexOn(widget.pageIndex),
            Size(layout.width, layout.height),
          ),
        ),
      );
    },
  );

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
    if (_renderFailed) setState(() => _renderFailed = false);
    try {
      final ratio = widget.aspectRatioKnown
          ? null
          : _aspectRatio ??
                await PdfRaster.aspectRatio(
                  widget.path,
                  pageIndex: widget.pageIndex,
                  password: widget.password,
                );
      final useCache = target <= PdfRaster.thumbnailSize * 4;
      final rendered = await PdfRaster.renderPageWithWarnings(
        widget.path,
        widget.pageIndex,
        longEdge: target,
        password: widget.password,
        // High-resolution zoom renders are one-offs; keeping them would
        // evict every thumbnail in the cache.
        useCache: useCache,
      );
      final bytes = rendered?.bytes;
      if (rendered != null) widget.onWarnings(rendered.warnings);
      if (!mounted) return;
      if (ratio != null && _aspectRatio == null) widget.onAspectRatio(ratio);
      setState(() {
        _bytes = bytes ?? _bytes;
        _aspectRatio = ratio ?? _aspectRatio;
        _renderFailed = bytes == null && _bytes == null;
        if (bytes != null) _renderedLongEdge = target;
      });
    } catch (e) {
      // One page failing is not the document failing: keep whatever was
      // already drawn and leave the placeholder for this one. The document
      // itself already opened, so this is a per-page problem.
      logError('PdfViewer._render', e);
      if (mounted && _bytes == null) setState(() => _renderFailed = true);
    } finally {
      _isRendering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.aspectRatioKnown
        ? widget.aspectRatio
        : _aspectRatio ?? widget.aspectRatio;
    final width = MediaQuery.of(context).size.width - 24;
    final height = pageHeight(width, ratio);

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
        child: _renderFailed
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Could not display page ${widget.pageIndex + 1}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black54),
                      ),
                      TextButton.icon(
                        onPressed: () => _render(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              )
            : _bytes == null
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
            : Stack(
                fit: StackFit.expand,
                children: [
                  _withTextSelection(
                    Image.memory(
                      _bytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      // The whole document is magnified by one
                      // InteractiveViewer above the list, so the page itself
                      // just draws at its natural size — and re-rasterizes
                      // when the zoom changes.
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  if (widget.search case final search?) _findHighlights(search),
                ],
              ),
      ),
    );
  }
}

/// Find matches over a page, in page points scaled to the page as drawn.
class _FindHighlightPainter extends CustomPainter {
  const _FindHighlightPainter(this.matches, this.current, this.pageSize);

  final List<List<Rect>> matches;
  final int? current;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / pageSize.width;
    final scaleY = size.height / pageSize.height;
    final match = Paint()..color = const Color(0x66FFC107);
    final currentMatch = Paint()..color = const Color(0x99FF6D00);
    for (int i = 0; i < matches.length; i++) {
      for (final rect in matches[i]) {
        canvas.drawRect(
          Rect.fromLTRB(
            rect.left * scaleX,
            rect.top * scaleY,
            rect.right * scaleX,
            rect.bottom * scaleY,
          ),
          i == current ? currentMatch : match,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FindHighlightPainter oldDelegate) =>
      !identical(matches, oldDelegate.matches) ||
      current != oldDelegate.current ||
      pageSize != oldDelegate.pageSize;
}

class _PageNumberDialog extends StatefulWidget {
  const _PageNumberDialog({
    required this.currentPage,
    required this.totalPages,
    required this.colors,
  });

  final int currentPage;
  final int totalPages;
  final AppColors colors;

  @override
  State<_PageNumberDialog> createState() => _PageNumberDialogState();
}

class _PageNumberDialogState extends State<_PageNumberDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: '${widget.currentPage}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, int.parse(_controller.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: widget.colors.cardBackground,
    title: Text(
      'Go to page',
      style: TextStyle(color: widget.colors.textPrimary),
    ),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        style: TextStyle(color: widget.colors.textPrimary),
        decoration: InputDecoration(hintText: '1 – ${widget.totalPages}'),
        validator: (value) {
          final page = int.tryParse(value?.trim() ?? '');
          return page == null || page < 1 || page > widget.totalPages
              ? 'Enter a page from 1 to ${widget.totalPages}'
              : null;
        },
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(
          'Cancel',
          style: TextStyle(color: widget.colors.textSecondary),
        ),
      ),
      FilledButton(onPressed: _submit, child: const Text('Go')),
    ],
  );
}

/// Width/height to lay page [index] out at: its own when [known], otherwise
/// the nearest earlier page's, otherwise [fallback].
///
/// Neighbouring pages usually share a size, while page 1 — often a cover — is
/// the page most likely to differ from the rest, so it makes a poor stand-in
/// for pages further on.
double pageAspectRatio(Map<int, double> known, int index, double fallback) {
  for (int i = index; i >= 0; i--) {
    final ratio = known[i];
    if (ratio != null && ratio.isFinite && ratio > 0) return ratio;
  }
  return fallback;
}

/// Height of a page drawn [width] wide. Pages and the viewer's scroll maths
/// both size pages with this, so the two always agree.
double pageHeight(double width, double aspectRatio) =>
    width / (aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 0.7071);

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
/// While zoomed, the scale recognizer handles horizontal panning and forwards
/// vertical movement to the list. When a second finger lands, the list has to
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
