import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../services/document_save_service.dart';
import '../services/pdf_core_service.dart';
import '../services/pdf_raster.dart';
import '../utils/error_logger.dart';

/// What is drawn onto the pages.
enum StampKind { pageNumbers, watermark, headerFooter }

/// Add page numbers, a watermark, or a header or footer to a PDF's pages,
/// with a preview of the first page. Saving appends to the file, like the
/// other editing screens; the screen pops with the path it saved to.
class PdfStampScreen extends StatefulWidget {
  const PdfStampScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
    this.kind = StampKind.pageNumbers,
  });

  final String pdfPath;
  final String password;
  final StampKind kind;

  @override
  State<PdfStampScreen> createState() => _PdfStampScreenState();
}

const _numberFormats = <(String, String)>[
  ('{page}', '1'),
  ('Page {page}', 'Page 1'),
  ('Page {page} of {pages}', 'Page 1 of 9'),
  ('{page} / {pages}', '1 / 9'),
];

const _positions = <(PdfMarkPosition, String)>[
  (PdfMarkPosition.topLeft, 'Top left'),
  (PdfMarkPosition.topCenter, 'Top centre'),
  (PdfMarkPosition.topRight, 'Top right'),
  (PdfMarkPosition.bottomLeft, 'Bottom left'),
  (PdfMarkPosition.bottomCenter, 'Bottom centre'),
  (PdfMarkPosition.bottomRight, 'Bottom right'),
];

const _colorsToPick = <Color>[
  Color(0xFF000000),
  Color(0xFF555555),
  Color(0xFFE53935),
  Color(0xFF1E88E5),
  Color(0xFF43A047),
  Color(0xFFFB8C00),
];

class _PdfStampScreenState extends State<PdfStampScreen> {
  static const Color _accent = Color(0xFF00BFA5);

  AppColors _colors = AppColors(false);
  late StampKind _kind = widget.kind;
  String _format = '{page}';
  final _text = TextEditingController(text: 'CONFIDENTIAL');
  final _header = TextEditingController();
  final _pages = TextEditingController();
  PdfMarkPosition _position = PdfMarkPosition.bottomCenter;
  double _size = 10;
  double _opacity = 0.25;
  bool _diagonal = true;
  Color _color = const Color(0xFF000000);
  int _pageCount = 0;

  Uint8List? _preview;
  bool _previewing = false;
  Timer? _debounce;
  bool _saving = false;
  String? _error;
  Directory? _scratch;

  @override
  void initState() {
    super.initState();
    _applyKindDefaults();
    _init();
  }

  Future<void> _init() async {
    try {
      final count = await PdfRaster.pageCountOf(
        widget.pdfPath,
        password: widget.password,
      );
      _scratch = await (await getTemporaryDirectory()).createTemp('stamp_');
      if (!mounted) return;
      setState(() => _pageCount = count);
      _schedulePreview();
    } catch (e) {
      if (mounted) setState(() => _error = PdfCoreService.describeError(e));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _header.dispose();
    _pages.dispose();
    final scratch = _scratch;
    if (scratch != null)
      unawaited(scratch.delete(recursive: true).catchError((_) => scratch));
    super.dispose();
  }

  void _applyKindDefaults() {
    switch (_kind) {
      case StampKind.pageNumbers:
        _position = PdfMarkPosition.bottomCenter;
        _size = 10;
        _color = const Color(0xFF000000);
      case StampKind.watermark:
        _size = 64;
        _opacity = 0.25;
        _color = const Color(0xFFE53935);
      case StampKind.headerFooter:
        _position = PdfMarkPosition.topCenter;
        _size = 10;
        _color = const Color(0xFF555555);
    }
  }

  /// The pages chosen, 1-based; empty for all, null when the entry is not
  /// understood.
  List<int>? _chosenPages() {
    final spec = _pages.text.trim();
    if (spec.isEmpty) return const [];
    final pages = <int>{};
    for (final part in spec.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final range = p.split('-');
      final from = int.tryParse(range.first.trim());
      final to = range.length > 1 ? int.tryParse(range.last.trim()) : from;
      if (from == null ||
          to == null ||
          from < 1 ||
          to < from ||
          to > _pageCount)
        return null;
      for (var n = from; n <= to; n++) {
        pages.add(n);
      }
    }
    return pages.toList()..sort();
  }

  PdfPageMark? _mark() {
    final pages = _chosenPages();
    if (pages == null) return null;
    final argb = _color.toARGB32();
    switch (_kind) {
      case StampKind.pageNumbers:
        return PdfPageMark(
          pages: pages,
          text: _format,
          position: _position,
          fontSize: _size,
          color: argb,
        );
      case StampKind.watermark:
        if (_text.text.trim().isEmpty) return null;
        return PdfPageMark(
          pages: pages,
          text: _text.text.trim(),
          position: PdfMarkPosition.center,
          fontSize: _size,
          bold: true,
          color: argb,
          opacity: _opacity,
          rotation: _diagonal ? 45 : 0,
        );
      case StampKind.headerFooter:
        if (_header.text.trim().isEmpty) return null;
        return PdfPageMark(
          pages: pages,
          text: _header.text.trim(),
          position: _position,
          fontSize: _size,
          color: argb,
        );
    }
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _renderPreview);
  }

  Future<void> _renderPreview() async {
    final scratch = _scratch;
    final mark = _mark();
    if (scratch == null || !mounted) return;
    setState(() => _previewing = true);
    try {
      final pages = mark?.pages ?? const [];
      final page = pages.isEmpty ? 1 : pages.first;
      var source = widget.pdfPath;
      if (mark != null) {
        source =
            '${scratch.path}/preview_${DateTime.now().microsecondsSinceEpoch}.pdf';
        await PdfCore.applyEditsAsync(
          widget.pdfPath,
          PdfEdits(marks: [mark]),
          source,
          password: widget.password,
        );
      }
      final rendered = await PdfRaster.renderPageWithWarnings(
        source,
        page - 1,
        longEdge: 900,
        password: widget.password,
        useCache: false,
      );
      if (source != widget.pdfPath)
        unawaited(File(source).delete().catchError((_) => File(source)));
      if (mounted) setState(() => _preview = rendered?.bytes ?? _preview);
    } catch (e) {
      logError('PdfStamp.preview', e);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _save() async {
    final mark = _mark();
    if (mark == null) {
      _snack(
        _chosenPages() == null
            ? 'Those pages are not in this PDF.'
            : 'Type the text first.',
      );
      return;
    }
    setState(() => _saving = true);
    final location = context.read<ThemeProvider>().saveLocation;
    try {
      final target = await DocumentSaveService.workingPathFor(widget.pdfPath);
      final warnings = await PdfCore.applyEditsAsync(
        widget.pdfPath,
        PdfEdits(marks: [mark]),
        target,
        password: widget.password,
      );
      PdfRaster.invalidate(target);
      PdfRaster.invalidate(widget.pdfPath);
      final message = await DocumentSaveService.afterSave(
        workingPath: target,
        location: location,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text([message, ...warnings].join(' '))));
      Navigator.pop(context, target);
    } catch (e) {
      logError('PdfStamp.save', e);
      if (mounted) {
        setState(() => _saving = false);
        _snack('Could not save: ${PdfCoreService.describeError(e)}');
      }
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  void _changed(VoidCallback change) {
    setState(change);
    _schedulePreview();
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        foregroundColor: _colors.textPrimary,
        title: const Text('Stamp pages'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('stamp-save'),
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: _saving || _pageCount == 0 ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _colors.textSecondary),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<StampKind>(
                  segments: const [
                    ButtonSegment(
                      value: StampKind.pageNumbers,
                      label: Text('Numbers'),
                      icon: Icon(Icons.format_list_numbered_rounded),
                    ),
                    ButtonSegment(
                      value: StampKind.watermark,
                      label: Text('Watermark'),
                      icon: Icon(Icons.water_drop_outlined),
                    ),
                    ButtonSegment(
                      value: StampKind.headerFooter,
                      label: Text('Header'),
                      icon: Icon(Icons.short_text_rounded),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => _changed(() {
                    _kind = s.first;
                    _applyKindDefaults();
                  }),
                ),
                const SizedBox(height: 16),
                ..._options(),
                const SizedBox(height: 12),
                TextField(
                  controller: _pages,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                    labelText: 'Pages',
                    hintText: 'All $_pageCount pages, or e.g. 2-5,8',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _schedulePreview(),
                ),
                const SizedBox(height: 16),
                _previewCard(),
              ],
            ),
    );
  }

  List<Widget> _options() {
    final label = TextStyle(color: _colors.textSecondary, fontSize: 13);
    final positions = Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final (p, name) in _positions)
          ChoiceChip(
            label: Text(name),
            selected: _position == p,
            onSelected: (_) => _changed(() => _position = p),
          ),
      ],
    );
    final colors = Row(
      children: [
        Text('Colour', style: label),
        const SizedBox(width: 12),
        for (final c in _colorsToPick)
          GestureDetector(
            onTap: () => _changed(() => _color = c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _color == c ? _accent : _colors.divider,
                  width: _color == c ? 3 : 1.5,
                ),
              ),
            ),
          ),
      ],
    );
    final size = Row(
      children: [
        Text('Size', style: label),
        Expanded(
          child: Slider(
            value: _size,
            min: _kind == StampKind.watermark ? 24 : 6,
            max: _kind == StampKind.watermark ? 120 : 24,
            onChanged: (v) => setState(() => _size = v.roundToDouble()),
            onChangeEnd: (_) => _schedulePreview(),
          ),
        ),
        Text('${_size.round()} pt', style: label),
      ],
    );
    switch (_kind) {
      case StampKind.pageNumbers:
        return [
          Text('Style', style: label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (format, example) in _numberFormats)
                ChoiceChip(
                  label: Text(example),
                  selected: _format == format,
                  onSelected: (_) => _changed(() => _format = format),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Where', style: label),
          const SizedBox(height: 6),
          positions,
          size,
          colors,
        ];
      case StampKind.watermark:
        return [
          TextField(
            controller: _text,
            decoration: const InputDecoration(
              labelText: 'Watermark text',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _schedulePreview(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Across the page diagonally'),
            value: _diagonal,
            onChanged: (v) => _changed(() => _diagonal = v),
          ),
          size,
          Row(
            children: [
              Text('Strength', style: label),
              Expanded(
                child: Slider(
                  value: _opacity,
                  min: 0.05,
                  max: 1,
                  onChanged: (v) => setState(() => _opacity = v),
                  onChangeEnd: (_) => _schedulePreview(),
                ),
              ),
              Text('${(_opacity * 100).round()}%', style: label),
            ],
          ),
          colors,
        ];
      case StampKind.headerFooter:
        return [
          TextField(
            controller: _header,
            decoration: const InputDecoration(
              labelText: 'Text',
              helperText: '{page} is the page number, {pages} the count',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _schedulePreview(),
          ),
          const SizedBox(height: 12),
          Text('Where', style: label),
          const SizedBox(height: 6),
          positions,
          size,
          colors,
        ];
    }
  }

  Widget _previewCard() {
    final preview = _preview;
    return Container(
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: _colors.shadowColor, blurRadius: 6)],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Preview',
                style: TextStyle(
                  color: _colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_previewing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (preview == null)
            const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Image.memory(preview, gaplessPlayback: true),
        ],
      ),
    );
  }
}
