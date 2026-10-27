import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/doc_kind.dart';
import '../models/home_tabs.dart';
import '../providers/theme_provider.dart';
import '../services/document_router.dart';
import '../services/pdf_core_service.dart';
import '../utils/format_utils.dart';
import 'ai_models_screen.dart';
import 'ai_screen.dart';
import 'archive_screen.dart';
import 'compress_screen.dart';
import 'extract_text_screen.dart';
import 'make_zip_screen.dart';
import 'merge_pdf_screen.dart';
import 'metadata_screen.dart';
import 'ocr_screen.dart';
import 'organize_pages_screen.dart';
import 'page_images_screen.dart';
import 'pdf_edit_screen.dart';
import 'pdf_stamp_screen.dart';
import 'protect_screen.dart';
import 'split_pdf_screen.dart';

import '../config/features.dart';
import '../widgets/password_prompt.dart';
import '../widgets/pdf_edit/edit_items.dart';

/// Every document operation in the app, on one screen, grouped by what you
/// are trying to get done. Scanning is not here: it has its own tab.
///
/// The old version showed a file picker and nothing else until you had chosen
/// a document — you had to commit to a file before the app would tell you what
/// it could do with one. The order is reversed here: the catalogue is always
/// visible, and picking happens when a tool actually needs a document. A
/// document chosen once stays selected, so a run of tools on the same file
/// costs one pick rather than one per tool.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key, this.initialPdfPath, this.onSendTo});

  final String? initialPdfPath;

  /// Open merge or split over the tab scaffold. Null when this screen is
  /// pushed as a standalone route.
  final void Function(DocHandoff action, String? path)? onSendTo;

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String? _path;
  String? _name;
  int? _fileSize;
  PdfInfo? _info;
  bool _isLoading = false;
  String? _error;

  /// Password the user supplied for an encrypted document; kept in memory only.
  String _password = '';

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);
  static const Color _accent = Color(0xFF7C4DFF);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPdfPath;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(initial));
    }
  }

  // ------------------------------------------------------------- document

  /// Choose a document. Returns false if the user backed out, or if the file
  /// could not be opened at all.
  Future<bool> _pick() async {
    try {
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      final path = result?.path;
      if (path == null) return false;
      return await _load(path);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that file: $e');
      return false;
    }
  }

  /// Read a document's summary into the header card.
  ///
  /// Returns whether the document is usable. A missing native core still
  /// counts as usable: the tools that need it say so themselves, and the ones
  /// that don't — the viewer, for instance — should not be blocked by it.
  Future<bool> _load(String path, {String password = ''}) async {
    setState(() {
      _path = path;
      _name = path.split(RegExp(r'[/\\]')).last;
      _password = password;
      _isLoading = true;
      _error = null;
      _info = null;
    });
    try {
      _fileSize = await File(path).length();
      final info = await PdfCoreService.inspect(path, password: password);
      if (!mounted) return false;
      setState(() {
        _info = info;
        _isLoading = false;
        if (info == null) {
          _error =
              'The native PDF core is not built, so document details are '
              'unavailable. Run ./scripts/build_libs.sh --only pdf.';
        }
      });
      return true;
    } on PdfException catch (e) {
      if (!mounted) return false;
      setState(() => _isLoading = false);
      if (e.isEncrypted || e.isWrongPassword) {
        final entered = await showPdfPasswordPrompt(
          context,
          retry: e.isWrongPassword,
          fileName: _name,
        );
        if (entered != null) return _load(path, password: entered);
      }
      if (mounted) {
        setState(() => _error = PdfCoreService.describeError(e));
      }
      return false;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not read that PDF: $e';
        });
      }
      return false;
    }
  }

  void _clearDocument() {
    setState(() {
      _path = null;
      _name = null;
      _info = null;
      _fileSize = null;
      _error = null;
      _password = '';
    });
  }

  // ---------------------------------------------------------------- launch

  /// Run a tool that works on exactly one document, picking one first if none
  /// is selected. Reloads the summary if the tool produced a new file.
  Future<void> _runOnDocument(
    Widget Function(String path, String password) builder, {
    bool requireEncrypted = false,
  }) async {
    if (_isLoading) return;
    if (_path == null && !await _pick()) return;
    final path = _path;
    if (path == null || !mounted) return;
    if (requireEncrypted && _info?.encrypted == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This PDF is not password-protected.')),
      );
      return;
    }
    final replacement = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => builder(path, _password)),
    );
    if (replacement != null && mounted) await _load(replacement);
  }

  /// Hand the selected document — if there is one — to merge or split.
  void _sendTo(DocHandoff action) {
    final send = widget.onSendTo;
    if (send != null) {
      send(action, _path);
      return;
    }
    // Standalone (no tab scaffold above us): push it ourselves so the tool
    // still works rather than silently doing nothing.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => switch (action) {
          DocHandoff.merge => MergePdfScreen(initialPdfPath: _path),
          DocHandoff.split => SplitPdfScreen(initialPdfPath: _path),
        },
      ),
    );
  }

  /// Choose any file and open it the way the Files tab would: a picture in
  /// the picture viewer, a web page or Markdown as a page, an archive in the
  /// archive browser, and a kind DocHelper cannot open in another app. The
  /// PDF chosen for the other tools stays chosen.
  Future<void> _openFile() async {
    try {
      final picked = await FilePicker.pickFile();
      final path = picked?.path;
      if (picked == null || path == null || !mounted) return;
      await DocumentRouter.open(context, path, title: picked.name);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that file: $e');
    }
  }

  /// Choose an archive and browse it. Archives are not working documents:
  /// the PDF chosen for the other tools stays chosen.
  Future<void> _openArchive() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip', 'tar', 'gz', 'tgz'],
      );
      final path = picked?.path;
      if (picked == null || path == null || !mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ArchiveScreen(path: path, title: picked.name),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that file: $e');
    }
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(
          'PDF Tools',
          style: TextStyle(
            color: _colors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: _path == null ? 'Choose a PDF' : 'Choose a different PDF',
            onPressed: _isLoading ? null : _pick,
            icon: Icon(Icons.folder_open_rounded, color: _colors.textPrimary),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _buildDocumentCard(),
            if (_error != null) ...[const SizedBox(height: 12), _buildError()],
            const SizedBox(height: 22),
            ..._buildSections(),
          ],
        ),
      ),
    );
  }

  /// The tool catalogue.
  ///
  /// Grouped by intent rather than by which engine happens to back each one —
  /// somebody looking to lock a file looks under "Protect", not under
  /// "flutter_pdf_core".
  List<Widget> _buildSections() {
    final sections = <_Section>[
      _Section('Combine & split', [
        _Tool(
          'Merge PDFs',
          'Join several files into one document',
          Icons.merge_rounded,
          const Color(0xFF00BFA5),
          () => _sendTo(DocHandoff.merge),
        ),
        _Tool(
          'Split PDF',
          'Extract a range, or divide into parts',
          Icons.content_cut_rounded,
          const Color(0xFFFFC107),
          () => _sendTo(DocHandoff.split),
        ),
      ]),
      _Section('Fill, sign & mark up', [
        _Tool(
          'Fill & sign',
          'Fill in a form, sign it, or type onto the page',
          Icons.draw_rounded,
          const Color(0xFF1E88E5),
          () => _runOnDocument(
            (p, pw) => PdfEditScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Annotate',
          'Highlight, underline, draw, and add notes',
          Icons.border_color_rounded,
          const Color(0xFFFFB300),
          () => _runOnDocument(
            (p, pw) => PdfEditScreen(
              pdfPath: p,
              password: pw,
              tool: PdfEditTool.highlight,
              title: 'Annotate',
            ),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Page numbers & watermark',
          'Number the pages, or add a watermark, header or footer',
          Icons.format_list_numbered_rounded,
          const Color(0xFF00BFA5),
          () => _runOnDocument(
            (p, pw) => PdfStampScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
      ]),
      _Section('Edit document', [
        _Tool(
          'Organize pages',
          'Rotate, reorder and delete pages',
          Icons.dashboard_customize_rounded,
          const Color(0xFF00D9FF),
          () => _runOnDocument(
            (p, pw) => OrganizePagesScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Compress PDF',
          'Make the file smaller to send or upload',
          Icons.compress_rounded,
          const Color(0xFF26A69A),
          () => _runOnDocument(
            (p, pw) => CompressScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Document details',
          'Title, author, subject and keywords',
          Icons.sell_rounded,
          const Color(0xFFFFC107),
          () => _runOnDocument(
            (p, pw) => MetadataScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Protect with a password',
          'Lock the file with AES-256 encryption',
          Icons.lock_rounded,
          const Color(0xFF4CAF50),
          () => _runOnDocument(
            (p, pw) => ProtectScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Remove password',
          'Save a copy without password protection',
          Icons.lock_open_rounded,
          const Color(0xFF4CAF50),
          () => _runOnDocument(
            (p, pw) =>
                ProtectScreen(pdfPath: p, password: pw, isEncrypted: true),
            requireEncrypted: true,
          ),
          needsDocument: true,
        ),
      ]),
      _Section('Read & extract', [
        _Tool(
          'Open in viewer',
          'Read, zoom and jump to any page',
          Icons.menu_book_rounded,
          const Color(0xFFE94560),
          () async {
            if (_path == null && !await _pick()) return;
            final path = _path;
            if (path == null || !mounted) return;
            await DocumentRouter.open(
              context,
              path,
              title: _name,
              password: _password,
            );
          },
          needsDocument: true,
        ),
        _Tool(
          'Extract text',
          'Copy it, or save it as a .txt file',
          Icons.text_snippet_rounded,
          const Color(0xFFE94560),
          () => _runOnDocument(
            (p, pw) => ExtractTextScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Pages as pictures',
          'Save pages as JPEG or PNG images',
          Icons.collections_rounded,
          const Color(0xFF7E57C2),
          () => _runOnDocument(
            (p, pw) => PageImagesScreen(pdfPath: p, password: pw),
          ),
          needsDocument: true,
        ),
        _Tool(
          'Recognize text (OCR)',
          'Make a scanned PDF searchable and copyable',
          Icons.document_scanner_rounded,
          const Color(0xFFE94560),
          () => _runOnDocument((p, pw) => OcrScreen(pdfPath: p, password: pw)),
          needsDocument: true,
        ),
        if (Features.ai)
          _Tool(
            'Ask AI',
            'Summarize, or ask questions about the text',
            Icons.auto_awesome_rounded,
            _accent,
            () => _runOnDocument((p, pw) => AiScreen(pdfPath: p, password: pw)),
            needsDocument: true,
          ),
      ]),
      // Files of any kind, not only PDFs.
      _Section('Files', [
        _Tool(
          'Open a file',
          'Pictures, web pages and any other file on the phone',
          Icons.file_open_rounded,
          DocKind.image.color,
          _openFile,
        ),
        _Tool(
          'Make a ZIP',
          'Pack files of any kind into one ZIP to send',
          Icons.folder_zip_rounded,
          DocKind.archive.color,
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const MakeZipScreen()),
          ),
        ),
        _Tool(
          'Open a ZIP',
          'See what is inside, then open, share or save the files',
          Icons.unarchive_rounded,
          DocKind.archive.color,
          _openArchive,
        ),
      ]),
      if (Features.ai)
        _Section('On-device AI', [
          _Tool(
            'AI models',
            'Download, switch or remove local models',
            Icons.memory_rounded,
            _accent,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiModelsScreen()),
            ),
          ),
        ]),
    ];

    return [
      for (final section in sections) ...[
        _buildSectionHeader(section.title),
        const SizedBox(height: 10),
        _buildSectionCard(section.tools),
        const SizedBox(height: 22),
      ],
    ];
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          color: _colors.textSecondary,
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildSectionCard(List<_Tool> tools) {
    return Container(
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
      child: Column(
        children: [
          for (var i = 0; i < tools.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: _colors.divider,
                indent: 62,
                endIndent: 14,
              ),
            _buildToolRow(tools[i], tools.length, i),
          ],
        ],
      ),
    );
  }

  Widget _buildToolRow(_Tool tool, int count, int index) {
    final enabled = !tool.needsDocument || !_isLoading;
    // Round only the outer corners so the ripple stays inside the card.
    const radius = Radius.circular(16);
    final shape = BorderRadius.only(
      topLeft: index == 0 ? radius : Radius.zero,
      topRight: index == 0 ? radius : Radius.zero,
      bottomLeft: index == count - 1 ? radius : Radius.zero,
      bottomRight: index == count - 1 ? radius : Radius.zero,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? tool.onTap : null,
        borderRadius: shape,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: tool.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(tool.icon, color: tool.color, size: 21),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tool.title,
                        style: TextStyle(
                          color: _colors.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tool.subtitle,
                        style: TextStyle(
                          color: _colors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // A tool that needs a document and has none will ask for one.
                // Saying so up front beats a file picker appearing unexplained.
                if (tool.needsDocument && _path == null)
                  Icon(
                    Icons.folder_open_rounded,
                    size: 17,
                    color: _colors.textTertiary,
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 21,
                    color: _colors.textTertiary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------- document card

  Widget _buildDocumentCard() {
    if (_isLoading) {
      return Container(
        height: 88,
        decoration: BoxDecoration(
          color: _colors.cardBackground,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: _accent, strokeWidth: 2.5),
        ),
      );
    }
    return _path == null ? _buildEmptyDocumentCard() : _buildLoadedCard();
  }

  Widget _buildEmptyDocumentCard() {
    return Material(
      color: _colors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _pick,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _accent.withValues(alpha: 0.35),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.picture_as_pdf_rounded,
                  color: _accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose a PDF',
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Every tool below will use it — or just tap a tool and '
                      'pick one then.',
                      style: TextStyle(
                        color: _colors.textTertiary,
                        fontSize: 12,
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
  }

  Widget _buildLoadedCard() {
    final info = _info;
    final title = info?.metadata.title?.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.picture_as_pdf_rounded,
                  color: _accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title != null && title.isNotEmpty ? title : (_name ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _colors.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Working document',
                      style: TextStyle(
                        color: _colors.textTertiary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Choose a different PDF',
                onPressed: _pick,
                icon: Icon(
                  Icons.swap_horiz_rounded,
                  color: _colors.textSecondary,
                  size: 21,
                ),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: _clearDocument,
                icon: Icon(
                  Icons.close_rounded,
                  color: _colors.textSecondary,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (info != null) _chip('${info.pageCount} pages'),
                _chip(formatFileSize(_fileSize)),
                if (info != null) _chip('PDF ${info.version}'),
                if (info?.encrypted == true) _chip('Encrypted', Colors.orange),
                if (info?.metadata.author?.isNotEmpty == true)
                  _chip('by ${info!.metadata.author}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, [Color? color]) {
    final c = color ?? _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: Colors.orange, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.orange, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section {
  const _Section(this.title, this.tools);
  final String title;
  final List<_Tool> tools;
}

class _Tool {
  const _Tool(
    this.title,
    this.subtitle,
    this.icon,
    this.color,
    this.onTap, {
    this.needsDocument = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// Whether the tool acts on a single chosen document, which changes the
  /// trailing affordance from a chevron to a "will ask for a file" folder.
  final bool needsDocument;
}
