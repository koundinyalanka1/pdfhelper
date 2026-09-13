import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/error_logger.dart';
import 'ai_model.dart';
import 'extractive_model.dart';

/// Where on-device model weights live, and which one is active.
///
/// Weights are kept in `<app support>/ai_models/` — app-private, excluded
/// from backup pressure, and never in `getApplicationDocumentsDirectory()`
/// where the PDF outputs live. Import a `.gguf` / `.task` / `.onnx` with
/// [import]; the descriptor is derived from the filename plus the runtime the
/// extension implies.
class AiModelStore {
  AiModelStore._();
  static final AiModelStore instance = AiModelStore._();

  static const String _activeModelKey = 'ai.activeModelId';
  static const String _modelDirName = 'ai_models';

  Directory? _dir;

  Future<Directory> _modelsDir() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_modelDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Every model the app can offer right now: the built-in one, plus any
  /// weights the user has imported.
  Future<List<AiModelDescriptor>> list() async {
    final models = <AiModelDescriptor>[ExtractiveModel.builtInDescriptor];
    try {
      final dir = await _modelsDir();
      for (final entity in await dir.list().toList()) {
        if (entity is! File) continue;
        final descriptor = await _describe(entity);
        if (descriptor != null) models.add(descriptor);
      }
    } catch (e) {
      logError('AiModelStore.list', e);
    }
    return models;
  }

  /// Copy [sourcePath] into the model directory. Returns its descriptor.
  Future<AiModelDescriptor> import(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw AiException('That model file no longer exists.');
    }
    final runtime = runtimeForFile(sourcePath);
    if (runtime == null) {
      throw AiException(
        'Unsupported model format. Expected one of: '
        '${AiRuntime.values.expand((r) => r.extensions).join(", ")}.',
      );
    }
    final dir = await _modelsDir();
    final name = sourcePath.split(RegExp(r'[/\\]')).last;
    final dest = File('${dir.path}/$name');
    await source.copy(dest.path);
    final descriptor = await _describe(dest);
    if (descriptor == null) {
      throw AiException('Could not read the imported model.');
    }
    return descriptor;
  }

  Future<void> delete(AiModelDescriptor descriptor) async {
    final path = descriptor.filePath;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (e) {
      logError('AiModelStore.delete', e);
    }
    if (await activeModelId() == descriptor.id) {
      await setActiveModelId(ExtractiveModel.builtInDescriptor.id);
    }
  }

  Future<String> activeModelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeModelKey) ??
        ExtractiveModel.builtInDescriptor.id;
  }

  Future<void> setActiveModelId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeModelKey, id);
  }

  /// Instantiate the active model.
  ///
  /// Falls back to [ExtractiveModel] whenever the stored choice is gone or
  /// its runtime has no factory registered — the AI screens must never be
  /// left without a model.
  Future<LocalAiModel> loadActiveModel() async {
    final id = await activeModelId();
    if (id == ExtractiveModel.builtInDescriptor.id) return ExtractiveModel();

    final descriptor = (await list()).where((m) => m.id == id).firstOrNull;
    if (descriptor == null) return ExtractiveModel();

    final model = AiRuntimeRegistry.create(descriptor);
    if (model == null) {
      logError(
        'AiModelStore',
        'no runtime registered for ${descriptor.runtime.label}; '
            'falling back to the built-in model',
      );
      return ExtractiveModel();
    }
    return model;
  }

  /// Which runtime, if any, can execute the file at [path].
  static AiRuntime? runtimeForFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    for (final runtime in AiRuntime.values) {
      if (runtime.extensions.contains(ext)) return runtime;
    }
    return null;
  }

  Future<AiModelDescriptor?> _describe(File file) async {
    final runtime = runtimeForFile(file.path);
    if (runtime == null) return null;
    final name = file.path.split(RegExp(r'[/\\]')).last;
    final stem = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    return AiModelDescriptor(
      id: '${runtime.name}.$stem'.toLowerCase(),
      name: stem,
      runtime: runtime,
      filePath: file.path,
      sizeBytes: await file.length(),
      quantization: _quantizationFromName(stem),
    );
  }

  /// Best-effort read of the quant tag GGUF filenames conventionally carry
  /// (`...-Q4_K_M.gguf`).
  static String _quantizationFromName(String stem) {
    final match = RegExp(
      r'(?:^|[-_.])(q\d+(?:_[a-z0-9]+)*|f16|f32|bf16)(?:$|[-_.])',
      caseSensitive: false,
    ).firstMatch(stem);
    return match?.group(1)?.toUpperCase() ?? '';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
