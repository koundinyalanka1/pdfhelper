import 'dart:async';

import '../services/pdf_core_service.dart';
import 'ai_model.dart';
import 'document_index.dart';
import 'extractive_model.dart';
import 'model_store.dart';

/// One turn in an AI conversation about a document.
class AiMessage {
  AiMessage({
    required this.role,
    required this.text,
    this.citations = const [],
    this.isStreaming = false,
  });

  final AiRole role;
  String text;

  /// Page ranges the answer drew on, e.g. `['p. 3', 'pp. 7–8']`.
  List<String> citations;
  bool isStreaming;
}

enum AiRole { user, assistant, system }

/// Orchestrates document → chunks → retrieval → prompt → model → answer.
///
/// The retrieval-augmented shape is deliberate: a small on-device model has a
/// tiny context window, so it must never see the whole PDF. [ask] retrieves
/// only the chunks that matter and cites the pages they came from, which keeps
/// prompts short and answers checkable.
class AiService {
  AiService._();
  static final AiService instance = AiService._();

  LocalAiModel? _model;
  AiDocumentIndex? _index;
  String? _indexedPath;

  LocalAiModel get model => _model ?? ExtractiveModel();
  AiDocumentIndex? get index => _index;

  /// True when answers come from the no-weights fallback rather than a real
  /// model — the UI says so, so nobody mistakes quoting for reasoning.
  bool get isUsingFallbackModel =>
      model.descriptor.runtime == AiRuntime.builtIn;

  /// Load (or reload) the user's selected model.
  Future<LocalAiModel> ensureModel({bool reload = false}) async {
    if (_model != null && !reload && _model!.isLoaded) return _model!;
    if (reload) await _model?.dispose();
    final model = await AiModelStore.instance.loadActiveModel();
    await model.load();
    return _model = model;
  }

  /// Build the retrieval index for [pdfPath]. Cached per path.
  Future<AiDocumentIndex> openDocument(
    String pdfPath, {
    String password = '',
    bool force = false,
    void Function(String stage)? onProgress,
  }) async {
    if (!force && _indexedPath == pdfPath && _index != null) return _index!;

    if (!PdfCoreService.isAvailable) {
      throw AiException(
        'The native PDF core is not built, so text cannot be extracted. '
        'Run ./scripts/build_pdf_core.sh and reinstall the app.',
      );
    }

    onProgress?.call('Extracting text…');
    final model = await ensureModel();
    final index = await AiDocumentIndex.build(pdfPath, password: password);

    onProgress?.call('Indexing ${index.chunks.length} passages…');
    await index.buildEmbeddings(model);

    _index = index;
    _indexedPath = pdfPath;
    return index;
  }

  void closeDocument() {
    _index = null;
    _indexedPath = null;
  }

  /// Answer [question] about the open document, streaming tokens as they land.
  ///
  /// Yields the growing answer text; [onCitations] fires once, as soon as
  /// retrieval has picked its passages, so the UI can show sources first.
  Stream<String> ask(
    String question, {
    int maxPassages = 5,
    Future<void>? cancelled,
    void Function(List<String> citations)? onCitations,
  }) async* {
    final index = _index;
    if (index == null) {
      throw AiException('Open a document before asking a question.');
    }
    final model = await ensureModel();

    final hits = await index.search(question, limit: maxPassages, model: model);
    if (hits.isEmpty) {
      onCitations?.call(const []);
      yield 'I could not find anything about that in this document.';
      return;
    }
    onCitations?.call(hits.map((h) => h.chunk.citation).toList());

    final prompt = buildPrompt(
      task: 'Answer the question using only the context below. '
          'If the context does not contain the answer, say so.',
      context: _contextBlock(hits, model.descriptor.contextTokens),
      question: question,
      documentTitle: index.title,
    );

    final buffer = StringBuffer();
    await for (final token in model.generate(
      prompt,
      maxTokens: 400,
      cancelled: cancelled,
    )) {
      buffer.write(token);
      yield buffer.toString();
    }
  }

  /// Summarize the whole open document.
  Stream<String> summarize({
    int maxPassages = 12,
    Future<void>? cancelled,
    void Function(List<String> citations)? onCitations,
  }) async* {
    final index = _index;
    if (index == null) {
      throw AiException('Open a document before summarizing it.');
    }
    final model = await ensureModel();

    // Spread the sample across the document rather than taking the first N
    // chunks, so a long report's conclusion is represented too.
    final chunks = _evenlySpaced(index.chunks, maxPassages);
    onCitations?.call(chunks.map((c) => c.citation).toList());

    final prompt = buildPrompt(
      task: 'Write a concise summary of the document from the context below.',
      context: chunks.map((c) => '[${c.citation}] ${c.text}').join('\n\n'),
      question: '',
      documentTitle: index.title,
    );

    final buffer = StringBuffer();
    await for (final token in model.generate(
      prompt,
      maxTokens: 600,
      cancelled: cancelled,
    )) {
      buffer.write(token);
      yield buffer.toString();
    }
  }

  /// Suggested questions, derived from the document's own vocabulary — a
  /// starting point when the user opens the assistant on a fresh PDF.
  List<String> suggestedQuestions() {
    final index = _index;
    if (index == null) return const [];
    return [
      'What is this document about?',
      'List the key points.',
      if (index.pageCount > 4) 'What does it conclude?',
      'Are there any dates or deadlines?',
    ];
  }

  /// The prompt template every runtime receives.
  ///
  /// Uppercase `LABEL:` sections keep it parseable by the built-in model and
  /// map cleanly onto a chat template for a real one.
  static String buildPrompt({
    required String task,
    required String context,
    required String question,
    required String documentTitle,
  }) {
    return '''
SYSTEM:
You are a careful assistant answering questions about a PDF titled "$documentTitle".
Use only the supplied context. Cite the page markers in square brackets.

TASK:
$task

CONTEXT:
$context

QUESTION:
$question

ANSWER:
''';
  }

  /// Assemble retrieved passages, stopping before the model's context window.
  /// ~4 characters per token is the usual rough conversion; half the window is
  /// reserved for the prompt scaffolding and the answer itself.
  String _contextBlock(List<ScoredChunk> hits, int contextTokens) {
    final budget = (contextTokens * 4) ~/ 2;
    final buffer = StringBuffer();
    for (final hit in hits) {
      final block = '[${hit.chunk.citation}] ${hit.chunk.text}\n\n';
      if (buffer.length + block.length > budget) break;
      buffer.write(block);
    }
    return buffer.toString().trim();
  }

  static List<AiChunk> _evenlySpaced(List<AiChunk> chunks, int count) {
    if (chunks.length <= count) return chunks;
    final step = chunks.length / count;
    return [for (int i = 0; i < count; i++) chunks[(i * step).floor()]];
  }
}
