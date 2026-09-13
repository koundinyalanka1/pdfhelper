import 'dart:math' as math;

import '../services/pdf_core_service.dart';
import 'ai_model.dart';

/// A chunk plus its retrieval score.
class ScoredChunk {
  const ScoredChunk(this.chunk, this.score);
  final AiChunk chunk;
  final double score;
}

/// Retrieval over the chunks `flutter_pdf_core` produced for a document.
///
/// Two retrieval modes, chosen automatically:
///
/// * **Lexical (BM25)** — always available, no model, no weights. This is what
///   runs today.
/// * **Dense** — used as soon as the active [LocalAiModel] returns vectors
///   from `embed()`. [buildEmbeddings] populates the vectors; [search] then
///   blends cosine similarity with the BM25 score so a half-built index still
///   returns sensible results.
///
/// Chunks carry their source page range, so every answer can cite pages.
class AiDocumentIndex {
  AiDocumentIndex._(this.export, this._docFreq, this._avgLength);

  /// Build an index from a PDF. Throws [AiException] if there is no text layer.
  static Future<AiDocumentIndex> build(
    String pdfPath, {
    String password = '',
    int maxChars = 1200,
    int overlap = 150,
  }) async {
    final export = await PdfCoreService.exportForAi(
      pdfPath,
      password: password,
      maxChars: maxChars,
      overlap: overlap,
    );
    if (!export.hasTextLayer) {
      throw AiException(
        'This PDF has no text layer — it looks like a scan. '
        'OCR is needed before the assistant can read it.',
      );
    }
    return _index(export);
  }

  static AiDocumentIndex _index(AiExport export) {
    final docFreq = <String, int>{};
    var totalLength = 0;
    for (final chunk in export.chunks) {
      final terms = tokenize(chunk.text);
      totalLength += terms.length;
      for (final term in terms.toSet()) {
        docFreq[term] = (docFreq[term] ?? 0) + 1;
      }
    }
    final avg = export.chunks.isEmpty ? 1.0 : totalLength / export.chunks.length;
    return AiDocumentIndex._(export, docFreq, avg);
  }

  final AiExport export;
  final Map<String, int> _docFreq;
  final double _avgLength;

  /// chunk id -> unit-normalised embedding, when an embedder is available.
  final Map<int, List<double>> _embeddings = {};

  List<AiChunk> get chunks => export.chunks;
  int get pageCount => export.pageCount;
  String get title => export.title?.trim().isNotEmpty == true
      ? export.title!.trim()
      : 'Untitled document';

  bool get hasEmbeddings => _embeddings.length == chunks.length && chunks.isNotEmpty;

  /// Ask [model] to embed every chunk. Silently no-ops for models without an
  /// embedder, leaving the index on BM25.
  Future<void> buildEmbeddings(
    LocalAiModel model, {
    void Function(int done, int total)? onProgress,
  }) async {
    _embeddings.clear();
    for (int i = 0; i < chunks.length; i++) {
      final vector = await model.embed(chunks[i].text);
      if (vector == null) {
        _embeddings.clear();
        return;
      }
      _embeddings[chunks[i].id] = _normalize(vector);
      onProgress?.call(i + 1, chunks.length);
    }
  }

  /// Top [limit] chunks for [query], best first.
  Future<List<ScoredChunk>> search(
    String query, {
    int limit = 5,
    LocalAiModel? model,
  }) async {
    if (chunks.isEmpty) return const [];

    final lexical = _bm25(query);
    if (!hasEmbeddings || model == null) {
      return _top(lexical, limit);
    }

    final queryVector = await model.embed(query);
    if (queryVector == null) return _top(lexical, limit);
    final q = _normalize(queryVector);

    // Blend: dense similarity dominates, lexical keeps exact terms honest.
    final blended = <int, double>{};
    final maxLexical = lexical.values.fold<double>(0, math.max);
    for (final chunk in chunks) {
      final dense = _cosine(q, _embeddings[chunk.id]!);
      final lex = maxLexical > 0 ? (lexical[chunk.id] ?? 0) / maxLexical : 0.0;
      blended[chunk.id] = dense * 0.7 + lex * 0.3;
    }
    return _top(blended, limit);
  }

  /// Chunks covering [page] (0-based) — used by "explain this page".
  List<AiChunk> chunksForPage(int page) =>
      chunks.where((c) => page >= c.pageStart && page <= c.pageEnd).toList();

  List<ScoredChunk> _top(Map<int, double> scores, int limit) {
    final byId = {for (final c in chunks) c.id: c};
    final ranked = scores.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked
        .take(limit)
        .map((e) => ScoredChunk(byId[e.key]!, e.value))
        .toList();
  }

  /// Okapi BM25 with the usual k1/b constants.
  Map<int, double> _bm25(String query, {double k1 = 1.5, double b = 0.75}) {
    final queryTerms = tokenize(query);
    final n = chunks.length;
    final scores = <int, double>{};

    for (final chunk in chunks) {
      final terms = tokenize(chunk.text);
      final length = terms.length;
      if (length == 0) continue;
      final freq = <String, int>{};
      for (final t in terms) {
        freq[t] = (freq[t] ?? 0) + 1;
      }

      double score = 0;
      for (final term in queryTerms) {
        final f = freq[term];
        if (f == null) continue;
        final df = _docFreq[term] ?? 0;
        final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
        score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * length / _avgLength));
      }
      if (score > 0) scores[chunk.id] = score;
    }
    return scores;
  }

  static List<double> _normalize(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return [for (final x in v) x / norm];
  }

  static double _cosine(List<double> a, List<double> b) {
    final len = math.min(a.length, b.length);
    double dot = 0;
    for (int i = 0; i < len; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }
}

/// Very small English stop list — enough to stop BM25 ranking on "the".
const Set<String> _stopWords = {
  'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'for', 'from', 'has',
  'have', 'he', 'her', 'his', 'how', 'i', 'in', 'is', 'it', 'its', 'of', 'on',
  'or', 'she', 'that', 'the', 'their', 'them', 'there', 'these', 'they', 'this',
  'to', 'was', 'were', 'what', 'when', 'where', 'which', 'who', 'will', 'with',
  'you', 'your',
};

/// Lowercase word tokens, stop words and 1-character noise removed.
List<String> tokenize(String text) {
  return RegExp(r"[a-z0-9][a-z0-9'\-]*")
      .allMatches(text.toLowerCase())
      .map((m) => m.group(0)!)
      .where((t) => t.length > 1 && !_stopWords.contains(t))
      .toList();
}

/// Split [text] into sentences. Shared by the extractive summariser.
List<String> splitSentences(String text) {
  return text
      .replaceAll(RegExp(r'\s+'), ' ')
      .split(RegExp(r'(?<=[.!?])\s+(?=[A-Z0-9"“])'))
      .map((s) => s.trim())
      .where((s) => s.length > 25)
      .toList();
}
