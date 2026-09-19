import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../ai/ai_model.dart';
import '../ai/model_store.dart';
import '../providers/theme_provider.dart';
import '../utils/format_utils.dart';

/// Manage the on-device AI model.
///
/// This is the slot a small local model drops into. Importing a `.gguf`,
/// `.task` or `.onnx` file registers it here; whether the app can actually
/// *run* it depends on a matching runtime being registered in
/// [AiRuntimeRegistry] at startup, which the screen states plainly rather
/// than failing later with a confusing error.
class AiModelsScreen extends StatefulWidget {
  const AiModelsScreen({super.key});

  @override
  State<AiModelsScreen> createState() => _AiModelsScreenState();
}

class _AiModelsScreenState extends State<AiModelsScreen> {
  static const Color _accent = Color(0xFF7C4DFF);

  List<AiModelDescriptor> _models = const [];
  String _activeId = '';
  bool _isLoading = true;
  bool _isImporting = false;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final models = await AiModelStore.instance.list();
    final active = await AiModelStore.instance.activeModelId();
    if (!mounted) return;
    setState(() {
      _models = models;
      _activeId = active;
      _isLoading = false;
    });
  }

  Future<void> _import() async {
    setState(() => _isImporting = true);
    try {
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: AiRuntime.values
            .expand((r) => r.extensions)
            .toList(),
      );
      final path = result?.path;
      if (path == null) return;
      final descriptor = await AiModelStore.instance.import(path);
      await AiModelStore.instance.setActiveModelId(descriptor.id);
      await _load();
      if (mounted) _snack('${descriptor.name} imported');
    } on AiException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('Could not import that model: $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _select(AiModelDescriptor model) async {
    await AiModelStore.instance.setActiveModelId(model.id);
    await _load();
  }

  Future<void> _delete(AiModelDescriptor model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _colors.cardBackground,
        title: Text(
          'Delete model?',
          style: TextStyle(color: _colors.textPrimary),
        ),
        content: Text(
          '${model.name} will be removed from this device. '
          'You can import it again later.',
          style: TextStyle(color: _colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: _colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AiModelStore.instance.delete(model);
    await _load();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
          'AI model',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _buildExplainer(),
                const SizedBox(height: 20),
                ..._models.map(_buildModelTile),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _isImporting ? null : _import,
                  icon: _isImporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_rounded, size: 18),
                  label: Text(
                    _isImporting ? 'Importing…' : 'Import a model file',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _accent,
                    side: const BorderSide(color: _accent),
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Accepted: '
                  '${AiRuntime.values.expand((r) => r.extensions).map((e) => ".$e").join(", ")}. '
                  'Models are stored in app-private storage and never uploaded.',
                  style: TextStyle(color: _colors.textTertiary, fontSize: 11.5),
                ),
              ],
            ),
    );
  }

  Widget _buildExplainer() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_rounded, color: _accent, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Everything runs on this device. The PDF text is chunked by the '
              'native core, the question retrieves only the passages it needs, '
              'and the answer cites the pages it used.',
              style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelTile(AiModelDescriptor model) {
    final isActive = model.id == _activeId;
    final runnable = model.isBuiltIn || AiRuntimeRegistry.supports(model.runtime);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _colors.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive ? _accent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        onTap: () => _select(model),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Icon(
          model.isBuiltIn ? Icons.bolt_rounded : Icons.memory_rounded,
          color: isActive ? _accent : _colors.textTertiary,
        ),
        title: Text(
          model.name,
          style: TextStyle(
            color: _colors.textPrimary,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            [
              model.runtime.label,
              if (model.sizeBytes > 0) formatFileSize(model.sizeBytes),
              if (model.quantization.isNotEmpty) model.quantization,
              if (!runnable) 'runtime not installed',
            ].join(' · '),
            style: TextStyle(
              color: runnable ? _colors.textTertiary : Colors.orange,
              fontSize: 11.5,
            ),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              const Icon(Icons.check_circle_rounded, color: _accent, size: 20),
            if (!model.isBuiltIn)
              IconButton(
                tooltip: 'Delete',
                onPressed: () => _delete(model),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red.shade400,
                  size: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
