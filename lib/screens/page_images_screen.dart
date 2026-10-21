import 'package:flutter/material.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/theme_provider.dart';
import '../services/ads_service.dart';
import '../services/document_save_service.dart';
import '../services/pdf_core_service.dart';
import '../services/public_pdf_save_service.dart';
import '../utils/error_logger.dart';
import '../utils/file_naming.dart';
import '../utils/format_utils.dart';

/// Save a PDF's pages as pictures (PNG or JPEG), one a page, then share
/// them or keep them in `Download/DocHelper`.
class PageImagesScreen extends StatefulWidget {
  const PageImagesScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
  });

  final String pdfPath;
  final String password;

  @override
  State<PageImagesScreen> createState() => _PageImagesScreenState();
}

class _PageImagesScreenState extends State<PageImagesScreen> {
  static const Color _accent = Color(0xFF7E57C2);

  AppColors _colors = AppColors(false);
  PdfPageImageFormat _format = PdfPageImageFormat.jpeg;
  double _dpi = 150;
  final _pages = TextEditingController();
  bool _working = false;
  String? _error;
  List<String> _files = const [];

  static const _sharpness = <(double, String)>[
    (96, 'Small'),
    (150, 'Normal'),
    (220, 'Sharp'),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  String get _title {
    final title = stripPdfExtension(getPdfDisplayTitle(widget.pdfPath));
    return title == 'View PDF' ? 'Document' : title;
  }

  Future<void> _run() async {
    if (!PdfCoreService.isAvailable) {
      setState(
        () => _error =
            'The native PDF core is not built, so this is unavailable.',
      );
      return;
    }
    final location = context.read<ThemeProvider>().saveLocation;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final files = await PdfCoreService.pageImages(
        widget.pdfPath,
        _title,
        pages: _pages.text.trim(),
        format: _format,
        dpi: _dpi,
        password: widget.password,
      );
      var saved = false;
      if (await DocumentSaveService.needsPublicCopy(files.first)) {
        for (final file in files) {
          await PublicPdfSaveService.save(
            sourcePath: file,
            displayName: file.split('/').last,
            location: location,
            mimeType: _format == PdfPageImageFormat.png
                ? 'image/png'
                : 'image/jpeg',
          );
        }
        saved = true;
      }
      if (!mounted) return;
      await AdsService.instance.operationCompleted(
        PdfOperation.images,
        canPresent: () =>
            mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      );
      if (!mounted) return;
      setState(() {
        _working = false;
        _files = files;
      });
      final where = saved ? ' in $location/DocHelper' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${files.length} picture${files.length == 1 ? '' : 's'}$where.',
          ),
        ),
      );
    } catch (e) {
      logError('PageImages.run', e);
      if (mounted) {
        setState(() {
          _working = false;
          _error = e is PdfException && e.code == 'PAGE_OUT_OF_RANGE'
              ? 'Those pages are not in this PDF.'
              : PdfCoreService.describeError(e);
        });
      }
    }
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [for (final f in _files) XFile(f)]),
      );
    } catch (e) {
      logError('PageImages.share', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    final label = TextStyle(color: _colors.textSecondary, fontSize: 13);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        foregroundColor: _colors.textPrimary,
        title: const Text('Pages as pictures'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            getPdfDisplayTitle(widget.pdfPath),
            style: TextStyle(color: _colors.textSecondary),
          ),
          const SizedBox(height: 16),
          Text('Format', style: label),
          const SizedBox(height: 6),
          SegmentedButton<PdfPageImageFormat>(
            segments: const [
              ButtonSegment(
                value: PdfPageImageFormat.jpeg,
                label: Text('JPEG'),
                icon: Icon(Icons.photo_rounded),
              ),
              ButtonSegment(
                value: PdfPageImageFormat.png,
                label: Text('PNG'),
                icon: Icon(Icons.image_rounded),
              ),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 4),
          Text(
            _format == PdfPageImageFormat.jpeg
                ? 'Smaller files; best for photos and sharing.'
                : 'Exact pixels; best for text and drawings.',
            style: TextStyle(color: _colors.textTertiary, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          Text('Sharpness', style: label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final (dpi, name) in _sharpness)
                ChoiceChip(
                  label: Text(name),
                  selected: _dpi == dpi,
                  onSelected: (_) => setState(() => _dpi = dpi),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pages,
            decoration: const InputDecoration(
              labelText: 'Pages',
              hintText: 'All pages, or e.g. 1-3,5',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFE53935))),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('page-images-run'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _working ? null : _run,
            icon: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.collections_rounded),
            label: Text(_working ? 'Saving pictures…' : 'Save as pictures'),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.share_rounded),
              label: Text(
                'Share ${_files.length} picture${_files.length == 1 ? '' : 's'}',
              ),
            ),
            const SizedBox(height: 8),
            for (final f in _files.take(6))
              Text(
                '• ${f.split('/').last}',
                style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
              ),
            if (_files.length > 6)
              Text(
                '…and ${_files.length - 6} more',
                style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
              ),
          ],
        ],
      ),
    );
  }
}
