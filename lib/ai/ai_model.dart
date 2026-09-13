/// The seam an on-device model plugs into.
///
/// Nothing in the app calls a model directly — everything goes through
/// [LocalAiModel]. Embedding a small model later means writing one class that
/// implements this interface and registering it in [AiRuntimeRegistry];
/// no screen, service or prompt code has to change.
///
/// Concrete runtimes this is designed to accept:
///
/// | Runtime                | Model format | Package |
/// |------------------------|--------------|---------|
/// | llama.cpp (via FFI)    | `.gguf`      | a thin ffi plugin, same shape as `flutter_pdf_core` |
/// | MediaPipe LLM Inference| `.task`      | `flutter_gemma` / platform channels |
/// | ONNX Runtime           | `.onnx`      | `onnxruntime` |
///
/// The built-in [ExtractiveModel] implements the same interface without any
/// weights, so every AI screen is fully functional before a model ships.
library;

import 'dart:async';

/// What a model file on disk claims to be.
class AiModelDescriptor {
  const AiModelDescriptor({
    required this.id,
    required this.name,
    required this.runtime,
    this.filePath,
    this.sizeBytes = 0,
    this.contextTokens = 2048,
    this.quantization = '',
    this.requiresDownload = false,
  });

  /// Stable id, e.g. `builtin.extractive` or `gguf.qwen2.5-0.5b-instruct-q4km`.
  final String id;
  final String name;

  /// Which [AiRuntime] can execute this file.
  final AiRuntime runtime;

  /// Absolute path to the weights. `null` for runtimes that need no file.
  final String? filePath;
  final int sizeBytes;

  /// Usable context window, in tokens — bounds how many retrieved chunks the
  /// prompt builder is allowed to include.
  final int contextTokens;
  final String quantization;
  final bool requiresDownload;

  bool get isBuiltIn => runtime == AiRuntime.builtIn;

  AiModelDescriptor copyWith({String? filePath, int? sizeBytes}) =>
      AiModelDescriptor(
        id: id,
        name: name,
        runtime: runtime,
        filePath: filePath ?? this.filePath,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        contextTokens: contextTokens,
        quantization: quantization,
        requiresDownload: requiresDownload,
      );
}

/// Execution backends the app knows how to talk to.
enum AiRuntime {
  /// No weights — deterministic extractive summarisation + retrieval.
  builtIn,

  /// llama.cpp-style GGUF generation over dart:ffi.
  gguf,

  /// MediaPipe LLM Inference (`.task` bundles).
  mediaPipe,

  /// ONNX Runtime.
  onnx,
}

extension AiRuntimeLabel on AiRuntime {
  String get label => switch (this) {
    AiRuntime.builtIn => 'Built-in (no download)',
    AiRuntime.gguf => 'GGUF / llama.cpp',
    AiRuntime.mediaPipe => 'MediaPipe LLM',
    AiRuntime.onnx => 'ONNX Runtime',
  };

  /// File extensions [AiModelStore] will accept for this runtime.
  List<String> get extensions => switch (this) {
    AiRuntime.builtIn => const [],
    AiRuntime.gguf => const ['gguf'],
    AiRuntime.mediaPipe => const ['task', 'bin'],
    AiRuntime.onnx => const ['onnx'],
  };
}

/// A streamed token from [LocalAiModel.generate].
typedef AiToken = String;

/// The contract every on-device model implements.
abstract class LocalAiModel {
  AiModelDescriptor get descriptor;

  /// `true` once [load] has completed successfully.
  bool get isLoaded;

  /// Load weights into memory. Must be idempotent and safe to call twice.
  Future<void> load();

  /// Generate a completion for [prompt].
  ///
  /// Implementations should honour [maxTokens] and stop early when
  /// [cancelled] completes so the UI can abort a long generation.
  Stream<AiToken> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.2,
    Future<void>? cancelled,
  });

  /// Optional dense embedding for semantic retrieval.
  ///
  /// Returning `null` (the default) tells [AiDocumentIndex] to stay on its
  /// lexical BM25 retriever, so retrieval works with or without an embedder.
  Future<List<double>?> embed(String text) async => null;

  /// Release weights. Called when the user switches models or leaves AI.
  Future<void> dispose();
}

/// Maps a [AiRuntime] to the factory that can build it.
///
/// Register a real runtime at startup:
/// ```dart
/// AiRuntimeRegistry.register(AiRuntime.gguf, (d) => GgufModel(d));
/// ```
class AiRuntimeRegistry {
  AiRuntimeRegistry._();

  static final Map<AiRuntime, LocalAiModel Function(AiModelDescriptor)>
  _factories = {};

  static void register(
    AiRuntime runtime,
    LocalAiModel Function(AiModelDescriptor) factory,
  ) {
    _factories[runtime] = factory;
  }

  static bool supports(AiRuntime runtime) => _factories.containsKey(runtime);

  /// Runtimes with a registered factory, always including [AiRuntime.builtIn].
  static List<AiRuntime> get available => _factories.keys.toList();

  /// Build a model for [descriptor], or `null` when its runtime has no
  /// factory registered yet (i.e. the native backend has not been added).
  static LocalAiModel? create(AiModelDescriptor descriptor) =>
      _factories[descriptor.runtime]?.call(descriptor);
}

/// Raised when an AI operation cannot proceed.
class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}
