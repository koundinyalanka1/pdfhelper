import 'dart:async';
import 'dart:math' as math;

import 'ai_model.dart';
import 'document_index.dart';

/// The zero-weights fallback model.
///
/// It is *not* a language model: it selects and stitches together sentences
/// already present in the document (TextRank-style centrality scoring). That
/// keeps the whole AI pipeline — chunking, retrieval, prompt assembly,
/// citations, streaming UI — exercisable and shippable today, and makes the
/// day a real model arrives a one-line registry change rather than a rewrite.
///
/// Because it only ever quotes the source, it cannot hallucinate; the trade is
/// that it paraphrases nothing.
class ExtractiveModel implements LocalAiModel {
  ExtractiveModel();

  static const AiModelDescriptor builtInDescriptor = AiModelDescriptor(
    id: 'builtin.extractive',
    name: 'Built-in extractive',
    runtime: AiRuntime.builtIn,
    contextTokens: 8192,
  );

  bool _loaded = false;

  @override
  AiModelDescriptor get descriptor => builtInDescriptor;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load() async => _loaded = true;

  @override
  Future<void> dispose() async => _loaded = false;

  /// No vectors — [AiDocumentIndex] stays on BM25.
  @override
  Future<List<double>?> embed(String text) async => null;

  /// Reads the structured prompt [AiService] builds and answers from the
  /// `CONTEXT:` block it contains. A generative runtime would simply feed the
  /// same string to its tokenizer.
  @override
  Stream<AiToken> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.2,
    Future<void>? cancelled,
  }) async* {
    final context = _section(prompt, 'CONTEXT');
    final question = _section(prompt, 'QUESTION');
    final task = _section(prompt, 'TASK');

    final String answer;
    if (context.trim().isEmpty) {
      answer = 'I could not find anything relevant in this document.';
    } else if (task.contains('summar')) {
      answer = summarize(context, maxSentences: math.max(3, maxTokens ~/ 60));
    } else {
      answer = _answer(question, context);
    }

    // Stream word by word so the UI path is identical for a real model.
    var cancelledFlag = false;
    unawaited(cancelled?.then((_) => cancelledFlag = true) ?? Future.value());
    for (final word in answer.split(' ')) {
      if (cancelledFlag) return;
      yield '$word ';
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
  }

  /// TextRank-lite: score sentences by how much vocabulary they share with the
  /// rest of the text, then return the best ones in original order.
  static String summarize(String text, {int maxSentences = 5}) {
    final sentences = splitSentences(text);
    if (sentences.length <= maxSentences) return sentences.join(' ');

    final tokenized = sentences.map(tokenize).toList();
    final termFreq = <String, int>{};
    for (final terms in tokenized) {
      for (final t in terms.toSet()) {
        termFreq[t] = (termFreq[t] ?? 0) + 1;
      }
    }

    final scores = <int, double>{};
    for (int i = 0; i < sentences.length; i++) {
      final terms = tokenized[i];
      if (terms.isEmpty) continue;
      final weight = terms
          .toSet()
          .fold<double>(0, (s, t) => s + math.log(1 + (termFreq[t] ?? 0)));
      // Normalise by length so long sentences don't automatically win, and
      // give a small bonus to early sentences (abstract / intro effect).
      final positionBonus = 1 + (sentences.length - i) / (sentences.length * 4);
      scores[i] = (weight / math.sqrt(terms.length)) * positionBonus;
    }

    final picked =
        (scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(maxSentences)
            .map((e) => e.key)
            .toList()
          ..sort();
    return picked.map((i) => sentences[i]).join(' ');
  }

  /// Pick the sentences from [context] that best overlap the question.
  static String _answer(String question, String context) {
    final queryTerms = tokenize(question).toSet();
    final sentences = splitSentences(context);
    if (sentences.isEmpty) return context.trim();
    if (queryTerms.isEmpty) return summarize(context, maxSentences: 3);

    final ranked =
        sentences
            .map((s) {
              final terms = tokenize(s).toSet();
              final overlap = terms.intersection(queryTerms).length;
              return MapEntry(s, overlap / (1 + math.log(1 + terms.length)));
            })
            .where((e) => e.value > 0)
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    if (ranked.isEmpty) {
      return 'The document does not appear to answer that directly. '
          'Here is the closest passage:\n\n${sentences.first}';
    }
    return ranked.take(3).map((e) => e.key).join(' ');
  }

  /// Pull one `LABEL:` block out of the structured prompt.
  static String _section(String prompt, String label) {
    final match = RegExp(
      '^$label:\\s*\$(.*?)(?=^[A-Z ]+:\\s*\$|\\Z)',
      multiLine: true,
      dotAll: true,
    ).firstMatch(prompt);
    return match?.group(1)?.trim() ?? '';
  }
}
