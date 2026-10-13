import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/features.dart';
import '../providers/theme_provider.dart';
import '../services/ads_service.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../services/pdf_service.dart';
import '../services/pdf_text_search.dart';
import '../services/pdf_text_selection_service.dart';
import '../services/recent_files_service.dart';
import '../services/recognized_text_store.dart';
import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import '../widgets/password_prompt.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/device_pixel_snap.dart';
import '../widgets/pdf_name_dialog.dart';
import '../widgets/pdf_result_dialog.dart';
import '../widgets/pdf_edit/edit_items.dart';
import '../widgets/pdf_text_selection_overlay.dart';
import 'ai_screen.dart';
import 'compress_screen.dart';
import 'extract_text_screen.dart';
import 'home_screen.dart';
import 'merge_pdf_screen.dart';
import 'metadata_screen.dart';
import 'organize_pages_screen.dart';
import 'page_images_screen.dart';
import 'pdf_edit_screen.dart';
import 'pdf_stamp_screen.dart';
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
    this.recordRecent = true,
  });

  final String pdfPath;
  final String? title;
  final String password;

  /// False for a preview made on the fly (a document's page view), which
  /// does not belong in Recent.
  final bool recordRecent;

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

  /// Whether this find session has already pointed at Recognize text for a
  /// document with no text to search, so each new query doesn't repeat it.
  bool _explainedNoText = false;

  /// Text OCR found on this document's scanned pages: kept in the app on an
  /// earlier visit, or read just now. Pages fall back on it for selection
  /// and find where the PDF has no text of its own.
  RecognizedText _recognized = RecognizedText.none;

  /// Pages that loaded without any selectable text, and whether find came up
  /// with no text anywhere. Either one brings up the Recognize text button.
  final Set<int> _pagesWithoutText = {};
  bool _documentWithoutText = false;

  /// Pages read and the total while text is being recognized, or the
  /// moment a searchable copy is being written ([_savingCopy]).
  (int, int)? _ocrProgress;
  bool _ocrCancelRequested = false;
  bool _savingCopy = false;

  /// The Recognize text button's tooltip, shown to point at the button when
  /// the reader tries to select text that isn't there.
  final GlobalKey<TooltipState> _ocrTooltip = GlobalKey();
  Timer? _ocrTooltipTimer;

  /// Every page's width/height as it becomes known — all of them shortly
  /// after opening (see [_loadPageRatios]), or from the page itself if it
  /// renders first. Held here rather than in each page so that a page rebuilt
  /// after scrolling away is laid out at its real height straight away.
  final Map<int, double> _pageRatios = {};

  /// Bumped when the file is saved over, so every page renders again.
  int _generation = 0;

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

  /// Fires when a double-tap zoom has finished animating: where it ends is
  /// known, so pages redraw their visible part at once instead of waiting to
  /// see whether the view keeps moving, as they must after a pinch.
  final ValueNotifier<int> _zoomSettled = ValueNotifier<int>(0);

  /// Anything that moves what is on screen — zoom, pan or scroll — so each
  /// page can redraw its visible part sharp once the movement stops.
  late final Listenable _viewportChanges = Listenable.merge([
    _zoomController,
    _scrollController,
  ]);

  /// The document viewport, whose on-screen area pages measure themselves
  /// against when deciding what of them to redraw while zoomed.
  final GlobalKey _viewerKey = GlobalKey();

  Rect? _viewportRect() {
    final box = _viewerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

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

  /// The password the engine keeps this document parsed under (see
  /// [PdfRaster.openDocument]), released when the viewer closes. Pages, page
  /// sizes, text and find all read the document at once; without the pin
  /// each of them parsed the whole file again, which for a large scan used
  /// enough memory for Android to kill the app.
  String? _pinnedPassword;

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
    final pinned = _pinnedPassword;
    if (pinned != null) {
      unawaited(PdfRaster.closeDocument(widget.pdfPath, password: pinned));
    }
    _findDebounce?.cancel();
    _ocrTooltipTimer?.cancel();
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
    _zoomSettled.dispose();
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
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _zoomSettled.value++;
    });
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
    if (widget.recordRecent) {
      unawaited(RecentFilesService.markOpened(widget.pdfPath));
    }
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
        final count = await _pinDocument();
        if (count == null) return;
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
        unawaited(_loadRecognizedText());
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

  /// Open the document for the life of this viewer and return its page
  /// count, or null when the viewer closed meanwhile. Throws like
  /// [PdfRaster.pageCountOf], so a locked document still asks for its
  /// password.
  Future<int?> _pinDocument() async {
    final password = _password;
    final count = await PdfRaster.openDocument(
      widget.pdfPath,
      password: password,
    );
    if (!mounted) {
      // dispose() already ran and found nothing to release.
      unawaited(PdfRaster.closeDocument(widget.pdfPath, password: password));
      return null;
    }
    final previous = _pinnedPassword;
    _pinnedPassword = password;
    if (previous != null) {
      unawaited(PdfRaster.closeDocument(widget.pdfPath, password: previous));
    }
    return count;
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

  /// Text kept in the app when this document was recognized before.
  /// Protected documents never have any (see [RecognizedTextStore]).
  Future<void> _loadRecognizedText() async {
    if (_password.isNotEmpty || !PdfCoreService.isAvailable) return;
    final kept = await RecognizedTextStore.load(
      widget.pdfPath,
      pageCount: _totalPages,
    );
    if (!mounted || kept.isEmpty || _ocrProgress != null) return;
    _useRecognizedText(kept);
  }

  /// Show [text] on the pages it was recognized on, and search it.
  void _useRecognizedText(RecognizedText text) {
    setState(() {
      _recognized = text;
      _documentWithoutText = false;
    });
    _createSearch(_totalPages);
    if (_finding) _runFind();
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
  /// pages, and recognized text on scanned pages. Nothing is read until the
  /// reader searches.
  void _createSearch(int pageCount) {
    _search?.dispose();
    final path = widget.pdfPath;
    final password = _password;
    final recognized = {
      for (final MapEntry(:key, :value) in _recognized.pages.entries)
        key: ?value.layout,
    };
    _search = PdfDocumentSearch(
      pageCount: pageCount,
      loadLayout: (index) async =>
          recognized[index] ??
          await PdfTextSelectionService.load(path, index, password: password),
      loadIndex: () => PdfTextSearch.loadIndex(
        path,
        password: password,
        pageCount: pageCount,
        recognized: {
          for (final MapEntry(:key, :value) in recognized.entries)
            key: value.text,
        },
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

  /// An image-only scan has nothing to find. Rather than leave "0/0" looking
  /// as though the query were wrong, bring up Recognize text, once, and
  /// point at it.
  void _onSearchChanged() {
    final search = _search;
    if (search == null || !_finding || _explainedNoText) return;
    if (search.isSearching || search.query.isEmpty) return;
    if (search.documentHasText != false) return;
    _explainedNoText = true;
    setState(() => _documentWithoutText = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pointAtRecognizeButton('This PDF has no text to search.');
    });
  }

  // ------------------------------------------------------- recognize text

  /// Whether some page has no text to select or find, and OCR has not been
  /// through it yet. Shows the Recognize text button.
  bool get _needsRecognition {
    if (!PdfCoreService.isAvailable || _totalPages == 0) return false;
    bool unread(int page) => !_recognized.hasRead(page);
    if (_pagesWithoutText.any(unread)) return true;
    return _documentWithoutText &&
        Iterable<int>.generate(_totalPages).any(unread);
  }

  void _notePageWithoutText(int index) {
    if (!mounted || _pagesWithoutText.contains(index)) return;
    final before = _needsRecognition;
    _pagesWithoutText.add(index);
    if (_needsRecognition != before) setState(() {});
  }

  /// Show what the Recognize text button does, right where it is, instead of
  /// a message to dismiss. [otherwise] is said when there is no button.
  void _pointAtRecognizeButton(String otherwise) {
    _textSelectionController.clear();
    final tooltip = _ocrTooltip.currentState;
    if (tooltip == null) {
      _snack(otherwise);
      return;
    }
    tooltip.ensureTooltipVisible();
    // A tooltip shown this way would otherwise stay until the next touch.
    _ocrTooltipTimer?.cancel();
    _ocrTooltipTimer = Timer(
      const Duration(seconds: 3),
      Tooltip.dismissAllToolTips,
    );
  }

  /// Read the text on the pages that have none, here in the viewer, then
  /// ask whether to keep it in the app or save it as a new PDF.
  ///
  /// Pages OCR has already been through are not read again, so asking from
  /// More actions after keeping text in the app goes straight to the choice.
  Future<void> _recognizeText() async {
    if (_ocrProgress != null || _savingCopy) return;
    if (!PdfCoreService.isAvailable) {
      _snack('Text recognition is unavailable in this build.');
      return;
    }
    _textSelectionController.clear();
    _ocrTooltipTimer?.cancel();
    Tooltip.dismissAllToolTips();
    var before = _recognized;
    var pages = [
      for (var index = 0; index < _totalPages; index++)
        if (!before.hasRead(index)) index + 1,
    ];
    if (pages.isEmpty && before.pages.isEmpty) {
      // Read before, and nothing kept: read it all again, so that what is
      // said afterwards is about this run.
      before = RecognizedText.none;
      pages = [for (var page = 1; page <= _totalPages; page++) page];
    }
    setState(() {
      _ocrProgress = (0, pages.length);
      _ocrCancelRequested = false;
    });
    final List<PdfOcrPage> results;
    try {
      results = pages.isEmpty
          ? const []
          : await PdfCoreService.recognizeText(
              widget.pdfPath,
              password: _password,
              pages: pages,
              onProgress: (done, total) {
                if (mounted) setState(() => _ocrProgress = (done, total));
              },
              isCancelled: () => _ocrCancelRequested || !mounted,
            );
    } on OcrCancelled {
      if (mounted) setState(() => _ocrProgress = null);
      return;
    } catch (error) {
      logError('PdfViewer.recognizeText', error);
      if (!mounted) return;
      setState(() => _ocrProgress = null);
      _snack(PdfCoreService.describeError(error));
      return;
    }
    if (!mounted) return;
    setState(() => _ocrProgress = null);
    bool hasText(PdfOcrPage page) =>
        page.status == PdfOcrStatus.recognized &&
        page.lines.isNotEmpty &&
        (page.layout?.hasText ?? false);
    final found = RecognizedText(
      pages: {
        ...before.pages,
        for (final page in results)
          if (hasText(page)) page.page - 1: page,
      },
      skipped: {
        ...before.skipped,
        for (final page in results)
          if (!hasText(page)) page.page - 1,
      },
    );
    if (found.pages.isEmpty) {
      // Nothing to keep or save. Which pages OCR went through is remembered
      // all the same, so the button doesn't offer them again.
      _keepInApp(found);
      final hadText = results.every(
        (page) =>
            page.status == PdfOcrStatus.hasText ||
            page.status == PdfOcrStatus.hasOcrLayer,
      );
      _snack(
        hadText
            ? 'Every page already has text. Select and find work on this '
                  'PDF as it is.'
            : 'No readable text was found. Text recognition reads printed '
                  'text; handwriting is not recognized.',
      );
      return;
    }
    while (mounted) {
      switch (await _askWhereTextGoes(found)) {
        case _TextDestination.app:
          _keepInApp(found);
          _snack('Text recognized. Select it or find it in this PDF.');
          return;
        case _TextDestination.newPdf:
          // Backing out of the name goes back to the choice.
          if (await _saveSearchableCopy(found)) return;
        case null:
          return;
      }
    }
  }

  void _cancelRecognition() {
    if (_ocrProgress != null) setState(() => _ocrCancelRequested = true);
  }

  /// Use [text] on the pages from now on and, for an unprotected document,
  /// the next time it is opened as well.
  void _keepInApp(RecognizedText text) {
    _useRecognizedText(text);
    if (_password.isNotEmpty || text.isEmpty) return;
    unawaited(
      RecognizedTextStore.save(
        widget.pdfPath,
        pageCount: _totalPages,
        text: text,
      ).catchError((Object error) => logError('PdfViewer.keepText', error)),
    );
  }

  /// Write [text] into a new, searchable PDF. False when the reader backed
  /// out of naming it.
  Future<bool> _saveSearchableCopy(RecognizedText text) async {
    final title = stripPdfExtension(_fileName);
    // An opened file whose provider gave no name is titled generically.
    final base = title == 'View PDF' ? 'Document' : title;
    final name = await askPdfName(
      context: context,
      initialName: '$base (searchable)',
      confirmLabel: 'Save',
      accent: _colors.accent,
    );
    if (name == null || !mounted) return false;
    setState(() => _savingCopy = true);
    try {
      final output = await PdfCoreService.saveSearchableCopy(
        widget.pdfPath,
        text.pages.values.toList(),
        password: _password,
        fileName: name,
      );
      if (!mounted) return true;
      setState(() => _savingCopy = false);
      final pages = text.pages.length;
      await showPdfResultDialog(
        context: context,
        filePaths: [output],
        accent: _colors.accent,
        operation: PdfOperation.ocr,
        title: 'Searchable copy saved',
        message: [
          'Text on ${pages == 1 ? 'one page' : '$pages pages'} can be '
              'searched, selected and copied in any PDF app.',
          if (_password.isNotEmpty)
            'The copy opens with the same password as the original.',
        ].join(' '),
      );
    } catch (error) {
      logError('PdfViewer.saveSearchableCopy', error);
      if (!mounted) return true;
      setState(() => _savingCopy = false);
      _snack(PdfCoreService.describeError(error));
    }
    return true;
  }

  /// Where the text OCR found should go: kept in the app, or written into a
  /// new PDF. Null when the reader discards it.
  Future<_TextDestination?> _askWhereTextGoes(RecognizedText found) {
    final colors = _colors;
    final pages = found.pages.length;
    Widget option(
      BuildContext dialog,
      _TextDestination destination,
      IconData icon,
      String title,
      String detail,
    ) => Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pop(dialog, destination),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return showDialog<_TextDestination>(
      context: context,
      // Reading took a while; a stray tap outside must not throw it away.
      barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        backgroundColor: colors.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Text recognized',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Found text on ${pages == 1 ? 'one page' : '$pages pages'}. '
              'Where should it go?',
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            option(
              dialog,
              _TextDestination.app,
              Icons.smartphone_rounded,
              'Keep in DocHelper',
              _password.isEmpty
                  ? 'Select and find it whenever you open this PDF here. '
                        'The file is not changed.'
                  : 'Select and find it until you close this PDF. Text '
                        'from password-protected PDFs is not stored.',
            ),
            const SizedBox(height: 10),
            option(
              dialog,
              _TextDestination.newPdf,
              Icons.note_add_rounded,
              'Save as a new PDF',
              'A searchable copy that works in any PDF app.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(
              'Discard',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
              _action(
                ctx,
                colors,
                Icons.draw_rounded,
                'Fill & sign',
                () => _edit(
                  PdfEditScreen(pdfPath: widget.pdfPath, password: _password),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.border_color_rounded,
                'Annotate',
                () => _edit(
                  PdfEditScreen(
                    pdfPath: widget.pdfPath,
                    password: _password,
                    tool: PdfEditTool.highlight,
                    title: 'Annotate',
                  ),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.format_list_numbered_rounded,
                'Page numbers & watermark',
                () => _edit(
                  PdfStampScreen(pdfPath: widget.pdfPath, password: _password),
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
                Icons.compress_rounded,
                'Compress',
                () => _push(
                  CompressScreen(pdfPath: widget.pdfPath, password: _password),
                ),
              ),
              _action(
                ctx,
                colors,
                Icons.collections_rounded,
                'Save pages as pictures',
                () => _push(
                  PageImagesScreen(
                    pdfPath: widget.pdfPath,
                    password: _password,
                  ),
                ),
              ),
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
                Icons.document_scanner_rounded,
                'Recognize text (OCR)',
                _recognizeText,
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

  /// Open an editing screen, then show what it saved: this file again when
  /// it was saved in place, otherwise the copy it was saved to.
  Future<void> _edit(Widget screen) async {
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (saved == null || !mounted) return;
    if (saved != widget.pdfPath) {
      unawaited(
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                PdfViewerScreen(pdfPath: saved, password: _password),
          ),
        ),
      );
      return;
    }
    PdfRaster.invalidate(widget.pdfPath);
    setState(() {
      _generation++;
      _isLoading = true;
      _pageRatios.clear();
    });
    await _load();
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
              _recognitionProgress(),
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
        if (_needsRecognition || _ocrProgress != null) _recognizeButton(),
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
        // Outside the field's tap region, so reaching for it also puts the
        // keyboard away and the pages come into view.
        if (_needsRecognition || _ocrProgress != null) _recognizeButton(),
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

  /// Recognize text, offered while some page has no text to select. The icon
  /// is the one for reading text off a scanned page: a page of text inside
  /// a viewfinder.
  Widget _recognizeButton() => Tooltip(
    key: _ocrTooltip,
    message: 'Recognize text (OCR)',
    child: IconButton(
      icon: const Icon(Icons.document_scanner_outlined),
      // The strip below the bar shows the run and stops it.
      onPressed: _ocrProgress == null && !_savingCopy ? _recognizeText : null,
      color: _colors.textPrimary,
    ),
  );

  /// Progress while text is recognized or a searchable copy is written,
  /// with a way to stop reading. The pages stay readable meanwhile.
  Widget _recognitionProgress() {
    final progress = _ocrProgress;
    if (progress == null && !_savingCopy) return const SizedBox.shrink();
    final String label;
    double? value;
    if (progress == null) {
      label = 'Saving the searchable copy…';
    } else if (_ocrCancelRequested) {
      label = 'Stopping after this page…';
    } else {
      final (done, total) = progress;
      value = total == 0 ? null : done / total;
      label = done < total
          ? 'Recognizing text: page ${done + 1} of $total'
          : 'Finishing…';
    }
    return Material(
      key: const ValueKey('pdf-recognition-progress'),
      color: _colors.cardBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: value,
            minHeight: 2,
            color: _colors.accent,
            backgroundColor: Colors.transparent,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Icon(
                  Icons.document_scanner_outlined,
                  size: 18,
                  color: _colors.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: _colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (progress != null)
                  TextButton(
                    onPressed: _ocrCancelRequested ? null : _cancelRecognition,
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: _ocrCancelRequested
                            ? _colors.textTertiary
                            : _colors.textSecondary,
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 48),
              ],
            ),
          ),
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
          key: _viewerKey,
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
            // A save over the file starts every page afresh.
            itemBuilder: (context, index) => KeyedSubtree(
              key: ValueKey((_generation, index)),
              child: _PageView(
                key: ValueKey('${widget.pdfPath}#$index'),
                path: widget.pdfPath,
                password: _password,
                pageIndex: index,
                aspectRatio: pageAspectRatio(_pageRatios, index, _aspectRatio),
                aspectRatioKnown: _pageRatios.containsKey(index),
                isDark: _colors.isDark,
                zoom: _zoom,
                viewportChanges: _viewportChanges,
                zoomSettled: _zoomSettled,
                viewport: _viewportRect,
                textSelectionController: _textSelectionController,
                search: _search,
                recognizedText: _recognized.pages[index]?.layout,
                // Recorded without a rebuild: the page resizes itself, and the
                // counter and Go to page read the map when they need it.
                onAspectRatio: (ratio) => _pageRatios[index] = ratio,
                onWarnings: _noteWarnings,
                onNoText: () => _notePageWithoutText(index),
                onSelectMissingText: () => _pointAtRecognizeButton(
                  _recognized.skipped.contains(index)
                      ? 'No text could be recognized on this page.'
                      : 'No selectable text on this page.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where text recognized in the viewer goes.
enum _TextDestination {
  /// Kept by the app and used whenever the document is opened in it.
  app,

  /// Written into a new, searchable copy of the document.
  newPdf,
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
    required this.viewportChanges,
    required this.zoomSettled,
    required this.viewport,
    required this.onAspectRatio,
    required this.onWarnings,
    required this.textSelectionController,
    required this.onNoText,
    required this.onSelectMissingText,
    this.search,
    this.recognizedText,
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

  /// Fires whenever what is on screen moves: a zoom, a pan, a scroll. While
  /// zoomed, the page then redraws the part of itself on screen at the zoom
  /// it is shown at.
  final Listenable viewportChanges;

  /// Fires when an animated zoom has come to rest, so the page redraws its
  /// visible part without the wait that follows other movement.
  final Listenable zoomSettled;

  /// The viewer's visible area in global coordinates, or null before layout.
  final Rect? Function() viewport;

  /// Reports the page's real shape when it had to look it up itself.
  final ValueChanged<double> onAspectRatio;
  final ValueChanged<List<String>> onWarnings;
  final PdfTextSelectionController textSelectionController;

  /// Matches to highlight on this page. The page finds its own in the text
  /// layout it already holds for selection.
  final PdfDocumentSearch? search;

  /// Text OCR read on this page, used when the page has none of its own.
  final PdfPageTextLayout? recognizedText;

  /// Called once the page turns out to have no selectable text of its own.
  final VoidCallback onNoText;

  /// Called when the reader tries to select text on a page that has none.
  final VoidCallback onSelectMissingText;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> {
  Uint8List? _bytes;
  double? _aspectRatio;

  /// Pixel width the page bitmap was rendered at.
  int _renderedWidth = 0;
  bool _isRendering = false;
  bool _renderFailed = false;
  PdfPageTextLayout? _textLayout;
  bool _loadingText = false;
  String? _textError;

  /// The page box, measured against the viewport to find what is on screen.
  final GlobalKey _pageKey = GlobalKey();

  /// Whether the document is zoomed in, which magnifies the page bitmap and
  /// so needs it filtered rather than copied pixel for pixel.
  bool _zoomed = false;

  /// While zoomed: the part of the page on screen, rendered at the zoom it
  /// is shown at and laid over the page bitmap, so text stays sharp however
  /// far the reader zooms in. Rendering the whole page that large instead
  /// would take 120 MB at 4x for an A4 page. [rect] is in the page's own
  /// logical pixels.
  ({ui.Image image, Rect rect, double zoom})? _tile;

  /// Whether [_tile] was rendered for the zoom now shown, so it lies pixel
  /// for pixel on the screen.
  bool _tileAtZoom = false;
  Timer? _tileTimer;

  /// Bumped for each tile request, so a slower, older one is dropped.
  int _tileRequest = 0;

  /// This page's find highlights and the query and layout they came from.
  String _highlightQuery = '';
  PdfPageTextLayout? _highlightLayout;
  List<List<Rect>> _highlights = const [];

  @override
  void initState() {
    super.initState();
    widget.viewportChanges.addListener(_onViewportChanged);
    widget.zoomSettled.addListener(_onZoomSettled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _render();
      _loadText();
    });
  }

  @override
  void didUpdateWidget(covariant _PageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewportChanges != widget.viewportChanges) {
      oldWidget.viewportChanges.removeListener(_onViewportChanged);
      widget.viewportChanges.addListener(_onViewportChanged);
    }
    if (oldWidget.zoomSettled != widget.zoomSettled) {
      oldWidget.zoomSettled.removeListener(_onZoomSettled);
      widget.zoomSettled.addListener(_onZoomSettled);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The page's width on screen changed (a rotation, split screen): redraw
    // it for the new width rather than stretch a bitmap made for the old one.
    if (_renderedWidth != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rerenderIfResized());
    }
  }

  void _rerenderIfResized() {
    if (!mounted || _zoomed || _isRendering || _renderedWidth == 0) return;
    final target = _renderSize(_aspectRatio ?? widget.aspectRatio).width;
    if (target != _renderedWidth) _render();
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
        isWanted: () => mounted,
      );
      if (!mounted) return;
      setState(() => _textLayout = layout);
      if (!layout.hasText) widget.onNoText();
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

  /// The text to select and find on this page: its own, or what OCR read on
  /// it when it has none.
  PdfPageTextLayout? get _layout {
    final own = _textLayout;
    if (own != null && own.hasText) return own;
    return widget.recognizedText ?? own;
  }

  Widget _withTextSelection(Widget page) {
    final layout = _layout;
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
    if (!_loadingText && _textError == null) {
      // A scan: the Recognize text button says what to do about it.
      widget.onSelectMissingText();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _textError ?? 'Text is still loading. Try again in a moment.',
        ),
        // A snack bar with an action otherwise stays until it is tapped.
        persist: false,
        action: _textError != null
            ? SnackBarAction(label: 'Retry', onPressed: _loadText)
            : null,
      ),
    );
  }

  List<List<Rect>> _highlightsFor(String query) {
    final layout = _layout;
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
      final layout = _layout;
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
    widget.viewportChanges.removeListener(_onViewportChanged);
    widget.zoomSettled.removeListener(_onZoomSettled);
    _tileTimer?.cancel();
    _tile?.image.dispose();
    super.dispose();
  }

  /// Show [tile] instead of the zoom tile shown now. The old one's image is
  /// let go once the frame that stops drawing it is done; the picture drawing
  /// it holds a clone of its own.
  void _replaceTile(({ui.Image image, Rect rect, double zoom})? tile) {
    final old = _tile;
    _tile = tile;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.image.dispose());
    }
  }

  /// A zoom, pan or scroll. Once it stops, the part of the page on screen is
  /// redrawn at the zoom it is shown at.
  void _onViewportChanged() {
    if (!mounted) return;
    final zoom = widget.zoom.value;
    final zoomed = zoom > 1.02;
    final tileAtZoom = _tile != null && (_tile!.zoom - zoom).abs() < 0.001;
    if (zoomed != _zoomed || tileAtZoom != _tileAtZoom) {
      setState(() {
        _zoomed = zoomed;
        _tileAtZoom = tileAtZoom;
        if (!zoomed) _replaceTile(null);
      });
    }
    _tileTimer?.cancel();
    if (zoomed) {
      _tileTimer = Timer(const Duration(milliseconds: 150), _refreshTile);
    } else {
      _tileRequest++; // whatever is in flight is no longer wanted
    }
  }

  void _onZoomSettled() {
    if (!mounted || !_zoomed) return;
    _tileTimer?.cancel();
    _refreshTile();
  }

  Future<void> _refreshTile() async {
    final zoom = widget.zoom.value;
    if (!mounted || zoom <= 1.02) return;
    final ratio = _aspectRatio ?? widget.aspectRatio;
    if (!PdfRaster.canRenderRegions) {
      // An engine without region rendering: redraw the whole page at the
      // zoomed size instead, within a memory budget.
      final wanted = _renderSize(ratio, zoom: zoom).width;
      if (!_isRendering && wanted > _renderedWidth * 1.15) _render(zoom: zoom);
      return;
    }
    final page = _pageKey.currentContext?.findRenderObject();
    final viewport = widget.viewport();
    if (page is! RenderBox || !page.hasSize || !page.attached) return;
    if (viewport == null) return;
    final toScreen = page.getTransformTo(null);
    final onScreen = MatrixUtils.transformRect(
      toScreen,
      Offset.zero & page.size,
    ).intersect(viewport);
    final fromScreen = Matrix4.tryInvert(toScreen);
    if (onScreen.isEmpty || fromScreen == null) return;
    final visible = MatrixUtils.transformRect(fromScreen, onScreen);
    final current = _tile;
    if (current != null &&
        (current.zoom - zoom).abs() < 0.001 &&
        _covers(current.rect, visible)) {
      return;
    }
    final size = pageRenderSize(
      displayWidth: page.size.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context) * zoom,
      aspectRatio: ratio,
      // Only the region is drawn, so the page itself may be any size.
      maxPixels: 1 << 40,
    );
    final region = zoomTileRegion(
      visible: visible,
      pageSize: page.size,
      pixelWidth: size.width,
      aspectRatio: ratio,
    );
    if (region == null) return;
    final request = ++_tileRequest;
    final rendered = await PdfRaster.renderRegion(
      widget.path,
      widget.pageIndex,
      pageWidth: size.width,
      pageHeight: size.height,
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
      password: widget.password,
      isWanted: () => mounted && request == _tileRequest,
    );
    if (rendered == null) return;
    if (!mounted || request != _tileRequest) {
      rendered.image.dispose();
      return;
    }
    setState(() {
      _replaceTile((
        image: rendered.image,
        rect: Rect.fromLTWH(
          region.x / region.scale,
          region.y / region.scale,
          region.width / region.scale,
          region.height / region.scale,
        ),
        zoom: zoom,
      ));
      _tileAtZoom = (widget.zoom.value - zoom).abs() < 0.001;
    });
  }

  static bool _covers(Rect outer, Rect inner) =>
      outer.left <= inner.left + 0.5 &&
      outer.top <= inner.top + 0.5 &&
      outer.right >= inner.right - 0.5 &&
      outer.bottom >= inner.bottom - 0.5;

  /// The bitmap size for this page shown at [zoom]: one bitmap pixel per
  /// device pixel of the page's width on screen.
  ({int width, int height}) _renderSize(double ratio, {double zoom = 1}) {
    final media = MediaQuery.of(context);
    return pageRenderSize(
      displayWidth: media.size.width - 24,
      devicePixelRatio: media.devicePixelRatio * zoom,
      aspectRatio: ratio,
      // A zoomed whole page (only without region rendering) may be larger,
      // but not without limit.
      maxPixels: zoom == 1 ? maxPageBitmapPixels : 16000000,
    );
  }

  Future<void> _render({double zoom = 1}) async {
    if (_isRendering || !mounted) return;
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
      if (!mounted) return;
      // The page's real shape, so the bitmap is exactly as wide as the page
      // on screen: fitting it into a square the width of the screen, as this
      // used to, drew a portrait page at 70% of the screen's resolution.
      final size = _renderSize(ratio ?? widget.aspectRatio, zoom: zoom);
      final rendered = await PdfRaster.renderPageWithWarnings(
        widget.path,
        widget.pageIndex,
        width: size.width,
        height: size.height,
        password: widget.password,
        // Zoomed whole-page renders are one-offs; keeping them would evict
        // every page in the cache.
        useCache: zoom == 1,
        isWanted: () => mounted,
      );
      final bytes = rendered?.bytes;
      if (rendered != null) widget.onWarnings(rendered.warnings);
      if (!mounted) return;
      if (ratio != null && _aspectRatio == null) widget.onAspectRatio(ratio);
      setState(() {
        _bytes = bytes ?? _bytes;
        _aspectRatio = ratio ?? _aspectRatio;
        _renderFailed = bytes == null && _bytes == null;
        if (bytes != null) _renderedWidth = size.width;
      });
      // The width may have changed while this render ran.
      if (zoom == 1 && bytes != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _rerenderIfResized(),
        );
      }
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
    final media = MediaQuery.of(context);
    final width = media.size.width - 24;
    final height = pageHeight(width, ratio);
    // Rendered for exactly this width: then the bitmap is drawn at its own
    // size, one bitmap pixel per device pixel, and copied rather than
    // filtered. Filtering a bitmap at a fractional screen position (and the
    // page's position nearly always is fractional) softens every glyph edge.
    final exact = _renderedWidth == (width * media.devicePixelRatio).floor();

    // Copied pixel for pixel, the bitmap must also start on a whole device
    // pixel. The page box, its clip and the selection over it move with it,
    // by under a pixel, wherever scrolling and zoom put the page.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SnapToDevicePixels(
        devicePixelRatio: media.devicePixelRatio,
        repaint: widget.viewportChanges,
        child: Container(
          key: _pageKey,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: widget.isDark ? 0.5 : 0.2,
                ),
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
                      Stack(
                        fit: StackFit.expand,
                        children: [
                          // The whole document is magnified by one
                          // InteractiveViewer above the list, so the page itself
                          // draws at its natural size, and while zoomed the part
                          // on screen is redrawn sharp on top of it.
                          Image.memory(
                            _bytes!,
                            scale: exact ? media.devicePixelRatio : 1,
                            // A bitmap rendered for another width (mid-rotation,
                            // or a page too long for full resolution) is
                            // stretched over the page until it is redrawn.
                            fit: exact ? BoxFit.none : BoxFit.fill,
                            alignment: Alignment.topLeft,
                            gaplessPlayback: true,
                            filterQuality: exact && !_zoomed
                                ? FilterQuality.none
                                : FilterQuality.medium,
                          ),
                          if (_tile case final tile?)
                            Positioned.fromRect(
                              rect: tile.rect,
                              // The tile's corner falls between device pixels
                              // at most zooms, so it snaps on its own too.
                              child: SnapToDevicePixels(
                                devicePixelRatio: media.devicePixelRatio,
                                child: RawImage(
                                  image: tile.image,
                                  key: const ValueKey('pdf-zoom-tile'),
                                  fit: BoxFit.fill,
                                  // At the zoom it was drawn for it lies pixel
                                  // for pixel on the screen; mid-pinch it is
                                  // being scaled, which filtering keeps smooth.
                                  filterQuality: _tileAtZoom
                                      ? FilterQuality.none
                                      : FilterQuality.medium,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.search case final search?)
                      _findHighlights(search),
                  ],
                ),
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

/// Most pixels a page bitmap is rendered with at normal size. A phone page
/// is about two million; only very long pages (receipts, banners) and large
/// tablets reach this, and they are drawn a little softer rather than as
/// bitmaps of tens of megabytes each.
const int maxPageBitmapPixels = 8000000;

/// The pixel box to render a page into so it shows one bitmap pixel per
/// device pixel: [displayWidth] logical pixels across at [devicePixelRatio],
/// for a page whose width/height is [aspectRatio].
///
/// The width is exact and the height has room to spare, so the engine, which
/// fits the page inside the box, is always limited by the width. A page that
/// would need more than [maxPixels] keeps its shape at a lower resolution.
({int width, int height}) pageRenderSize({
  required double displayWidth,
  required double devicePixelRatio,
  required double aspectRatio,
  int maxPixels = maxPageBitmapPixels,
}) {
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 0.7071;
  final exact = displayWidth * devicePixelRatio;
  var width = exact.isFinite && exact >= 1 ? exact.floor() : 1;
  if (width * (width / ratio) > maxPixels) {
    width = math.max(1, math.sqrt(maxPixels * ratio).floor());
  }
  return (width: width, height: (width / ratio).ceil() + 1);
}

/// What of a zoomed page to render sharp: the part on screen ([visible], in
/// the page's logical pixels, laid out [pageSize]) plus [margin] device
/// pixels around it, so a small pan does not uncover the magnified page
/// bitmap underneath. In the pixels of the whole page rendered [pixelWidth]
/// wide, with [scale] of those pixels to a logical pixel. Null when none of
/// the page is on screen.
({int x, int y, int width, int height, double scale})? zoomTileRegion({
  required Rect visible,
  required Size pageSize,
  required int pixelWidth,
  required double aspectRatio,
  int margin = 96,
}) {
  if (visible.isEmpty || pageSize.width <= 0 || pixelWidth <= 0) return null;
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 0.7071;
  final scale = pixelWidth / pageSize.width;
  final pixelHeight = (pixelWidth / ratio).round();
  final left = math.max(0, (visible.left * scale).floor() - margin);
  final top = math.max(0, (visible.top * scale).floor() - margin);
  final right = math.min(pixelWidth, (visible.right * scale).ceil() + margin);
  final bottom = math.min(
    pixelHeight,
    (visible.bottom * scale).ceil() + margin,
  );
  if (right <= left || bottom <= top) return null;
  return (
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
    scale: scale,
  );
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
