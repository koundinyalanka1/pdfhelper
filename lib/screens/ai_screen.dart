import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_model.dart';
import '../ai/ai_service.dart';
import '../providers/theme_provider.dart';
import 'ai_models_screen.dart';

/// Ask questions about one PDF, entirely on device.
///
/// The pipeline is retrieval-augmented on purpose: a small on-device model has
/// a tiny context window, so the document is chunked by the native core, the
/// question retrieves only the passages that matter, and the answer cites the
/// pages it came from. Nothing leaves the phone.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, required this.pdfPath, this.password = ''});

  final String pdfPath;
  final String password;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  static const Color _accent = Color(0xFF7C4DFF);

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<AiMessage> _messages = [];

  bool _isPreparing = true;
  bool _isGenerating = false;
  String _status = 'Opening document…';
  String? _error;
  Completer<void>? _cancel;

  /// Theme colours, assigned at the top of [build] rather than read
  /// through a `context.watch()` getter — see [AppColors.of].
  AppColors _colors = AppColors(false);

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _cancel?.complete();
    _controller.dispose();
    _scrollController.dispose();
    AiService.instance.closeDocument();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      await AiService.instance.openDocument(
        widget.pdfPath,
        password: widget.password,
        onProgress: (stage) {
          if (mounted) setState(() => _status = stage);
        },
      );
      if (mounted) setState(() => _isPreparing = false);
    } on AiException catch (e) {
      if (mounted) {
        setState(() {
          _isPreparing = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPreparing = false;
          _error = 'Could not read this document: $e';
        });
      }
    }
  }

  Future<void> _send(String question, {bool summarize = false}) async {
    if (_isGenerating) return;
    final trimmed = question.trim();
    if (!summarize && trimmed.isEmpty) return;

    _controller.clear();
    final answer = AiMessage(role: AiRole.assistant, text: '', isStreaming: true);
    setState(() {
      if (!summarize) {
        _messages.add(AiMessage(role: AiRole.user, text: trimmed));
      } else {
        _messages.add(
          AiMessage(role: AiRole.user, text: 'Summarize this document'),
        );
      }
      _messages.add(answer);
      _isGenerating = true;
    });
    _scrollToEnd();

    final cancel = Completer<void>();
    _cancel = cancel;

    try {
      final stream = summarize
          ? AiService.instance.summarize(
              cancelled: cancel.future,
              onCitations: (c) => answer.citations = c,
            )
          : AiService.instance.ask(
              trimmed,
              cancelled: cancel.future,
              onCitations: (c) => answer.citations = c,
            );

      await for (final text in stream) {
        if (!mounted) return;
        setState(() => answer.text = text);
        _scrollToEnd();
      }
    } on AiException catch (e) {
      answer.text = e.message;
    } catch (e) {
      answer.text = 'Something went wrong: $e';
    } finally {
      if (mounted) {
        setState(() {
          answer.isStreaming = false;
          _isGenerating = false;
        });
      }
      if (!cancel.isCompleted) cancel.complete();
      _cancel = null;
    }
  }

  void _stop() {
    if (!(_cancel?.isCompleted ?? true)) _cancel!.complete();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
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
          'Ask this PDF',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
        actions: [
          IconButton(
            tooltip: 'AI model',
            icon: const Icon(Icons.memory_rounded),
            color: _colors.textSecondary,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiModelsScreen()),
              );
              // The user may have switched models while they were in there.
              await AiService.instance.ensureModel(reload: true);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isPreparing && _error == null) _buildModelBanner(),
          Expanded(child: _buildBody()),
          if (_error == null) _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildModelBanner() {
    final service = AiService.instance;
    final index = service.index;
    final fallback = service.isUsingFallbackModel;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: (fallback ? Colors.orange : _accent).withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(
            fallback ? Icons.info_outline_rounded : Icons.memory_rounded,
            size: 15,
            color: fallback ? Colors.orange : _accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fallback
                  ? 'No model loaded — answers quote the document directly. '
                        'Tap the chip to add one.'
                  : '${service.model.descriptor.name} · '
                        '${index?.chunks.length ?? 0} passages indexed',
              style: TextStyle(
                fontSize: 11.5,
                color: fallback ? Colors.orange.shade800 : _accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isPreparing) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _accent),
            const SizedBox(height: 16),
            Text(_status, style: TextStyle(color: _colors.textSecondary)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 56,
                color: _colors.textTertiary,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.textSecondary, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) return _buildSuggestions();

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessage(_messages[index]),
    );
  }

  Widget _buildSuggestions() {
    final index = AiService.instance.index;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: _accent,
              size: 30,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          index?.title ?? 'This document',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _colors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${index?.pageCount ?? 0} pages · ${index?.chunks.length ?? 0} passages · '
          'answered on this device',
          textAlign: TextAlign.center,
          style: TextStyle(color: _colors.textTertiary, fontSize: 12.5),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: () => _send('', summarize: true),
          icon: const Icon(Icons.summarize_rounded, size: 18),
          label: const Text('Summarize the document'),
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            minimumSize: const Size.fromHeight(46),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Or ask something',
          style: TextStyle(color: _colors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 10),
        ...AiService.instance.suggestedQuestions().map(
          (question) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => _send(question),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                foregroundColor: _colors.textPrimary,
                side: BorderSide(color: _colors.divider),
                minimumSize: const Size.fromHeight(44),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(question, style: const TextStyle(fontSize: 13.5)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessage(AiMessage message) {
    final isUser = message.role == AiRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? _accent : _colors.cardBackground,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: isUser ? const Radius.circular(4) : null,
            bottomLeft: isUser ? null : const Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text.isEmpty && message.isStreaming
                  ? 'Thinking…'
                  : message.text,
              style: TextStyle(
                color: isUser ? Colors.white : _colors.textPrimary,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            if (message.citations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: message.citations
                    .map(
                      (citation) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          citation,
                          style: const TextStyle(
                            color: _accent,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            if (!isUser && !message.isStreaming && message.text.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Answer copied')),
                    );
                  },
                  icon: Icon(
                    Icons.copy_rounded,
                    size: 15,
                    color: _colors.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: _colors.cardBackground,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: !_isPreparing && _error == null,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                minLines: 1,
                maxLines: 4,
                style: TextStyle(color: _colors.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Ask about this document…',
                  hintStyle: TextStyle(color: _colors.textTertiary),
                  filled: true,
                  fillColor: _colors.background,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _isPreparing
                  ? null
                  : _isGenerating
                  ? _stop
                  : () => _send(_controller.text),
              style: IconButton.styleFrom(backgroundColor: _accent),
              icon: Icon(
                _isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
