import 'package:flutter/material.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../widgets/pdf_result_dialog.dart';

/// Read and rewrite the `/Info` dictionary.
///
/// Null vs empty matters to the native core: a field left untouched stays as
/// it was, a field cleared to `''` is *deleted* from the document. This screen
/// preserves that distinction by only sending fields the user actually edited.
class MetadataScreen extends StatefulWidget {
  const MetadataScreen({super.key, required this.pdfPath, this.password = ''});

  final String pdfPath;
  final String password;

  @override
  State<MetadataScreen> createState() => _MetadataScreenState();
}

class _MetadataScreenState extends State<MetadataScreen> {
  static const Color _accent = Color(0xFFFFC107);

  final _controllers = <String, TextEditingController>{};
  final _initial = <String, String>{};
  PdfMetadata? _original;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  static const _fields = <({String key, String label, IconData icon})>[
    (key: 'title', label: 'Title', icon: Icons.title_rounded),
    (key: 'author', label: 'Author', icon: Icons.person_rounded),
    (key: 'subject', label: 'Subject', icon: Icons.subject_rounded),
    (key: 'keywords', label: 'Keywords', icon: Icons.tag_rounded),
    (key: 'creator', label: 'Creator', icon: Icons.edit_note_rounded),
    (key: 'producer', label: 'Producer', icon: Icons.precision_manufacturing_rounded),
  ];

  bool get _isDirty =>
      _controllers.entries.any((e) => e.value.text != (_initial[e.key] ?? ''));

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      _controllers[field.key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await PdfCoreService.inspect(
        widget.pdfPath,
        password: widget.password,
      );
      if (info == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = 'The native PDF core is not built, so metadata cannot '
                'be read or written. Run ./scripts/build_pdf_core.sh.';
          });
        }
        return;
      }
      final m = info.metadata;
      final values = {
        'title': m.title ?? '',
        'author': m.author ?? '',
        'subject': m.subject ?? '',
        'keywords': m.keywords ?? '',
        'creator': m.creator ?? '',
        'producer': m.producer ?? '',
      };
      if (!mounted) return;
      setState(() {
        _original = m;
        _isLoading = false;
        values.forEach((key, value) {
          _controllers[key]!.text = value;
          _initial[key] = value;
        });
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

  /// Only changed fields are sent — untouched ones stay `null` so the core
  /// leaves them alone rather than rewriting identical values.
  String? _changed(String key) {
    final value = _controllers[key]!.text;
    return value == (_initial[key] ?? '') ? null : value;
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final output = await PdfCoreService.setMetadata(
        widget.pdfPath,
        PdfMetadata(
          title: _changed('title'),
          author: _changed('author'),
          subject: _changed('subject'),
          keywords: _changed('keywords'),
          creator: _changed('creator'),
          producer: _changed('producer'),
          // Dates are document history, not user-editable here.
          creationDate: _original?.creationDate,
          modDate: DateTime.now().toUtc().toIso8601String(),
        ),
        password: widget.password,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      await showPdfResultDialog(
        context: context,
        filePaths: [output],
        accent: _accent,
        adTrigger: 'metadata',
        message: 'Document details updated.',
      );
      if (mounted) Navigator.pop(context, output);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(PdfCoreService.describeError(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        iconTheme: IconThemeData(color: _colors.textPrimary),
        title: Text(
          'Document details',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                for (final field in _fields) ...[
                  _buildField(field),
                  const SizedBox(height: 14),
                ],
                if (_original?.creationDate?.isNotEmpty == true)
                  Text(
                    'Created ${_original!.creationDate}',
                    style: TextStyle(
                      color: _colors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Clearing a field removes it from the document.',
                  style: TextStyle(color: _colors.textTertiary, fontSize: 12),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: (_isSaving || !_isDirty || _error != null)
                        ? null
                        : _save,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black87,
                            ),
                          )
                        : const Icon(Icons.save_rounded),
                    label: Text(_isSaving ? 'Saving…' : 'Save details'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildField(({String key, String label, IconData icon}) field) {
    return TextField(
      controller: _controllers[field.key],
      enabled: _error == null,
      style: TextStyle(color: _colors.textPrimary),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: field.label,
        labelStyle: TextStyle(color: _colors.textSecondary),
        prefixIcon: Icon(field.icon, color: _accent, size: 20),
        filled: true,
        fillColor: _colors.cardBackground,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
