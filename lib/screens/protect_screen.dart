import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../services/pdf_core_service.dart';
import '../widgets/pdf_result_dialog.dart';

/// Add or remove a PDF password.
///
/// Protection is AES-256 (PDF 2.0, revision 6) — the only algorithm the native
/// core *writes*. It can still open RC4 and AES-128 documents, so removing a
/// password works on older files too.
class ProtectScreen extends StatefulWidget {
  const ProtectScreen({
    super.key,
    required this.pdfPath,
    this.password = '',
    this.isEncrypted = false,
  });

  final String pdfPath;

  /// Password already used to open the document, if any.
  final String password;
  final bool isEncrypted;

  @override
  State<ProtectScreen> createState() => _ProtectScreenState();
}

class _ProtectScreenState extends State<ProtectScreen> {
  static const Color _accent = Color(0xFF4CAF50);

  final _userController = TextEditingController();
  final _confirmController = TextEditingController();
  final _ownerController = TextEditingController();
  final _unlockController = TextEditingController();

  bool _obscure = true;
  bool _isWorking = false;
  String? _error;

  bool get _isDarkMode => context.watch<ThemeProvider>().isDarkMode;
  AppColors get _colors => AppColors(_isDarkMode);

  @override
  void initState() {
    super.initState();
    _unlockController.text = widget.password;
  }

  @override
  void dispose() {
    _userController.dispose();
    _confirmController.dispose();
    _ownerController.dispose();
    _unlockController.dispose();
    super.dispose();
  }

  String? _validateNewPassword() {
    final password = _userController.text;
    if (password.isEmpty) return 'Enter a password.';
    if (password.length < 4) return 'Use at least 4 characters.';
    if (password != _confirmController.text) return 'Passwords do not match.';
    return null;
  }

  Future<void> _protect() async {
    final problem = _validateNewPassword();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await _run(
      () => PdfCoreService.protect(
        widget.pdfPath,
        _userController.text,
        ownerPassword: _ownerController.text,
        password: widget.password,
      ),
      'Password added. Keep it somewhere safe — it cannot be recovered.',
      'protect',
    );
  }

  Future<void> _unlock() async {
    if (_unlockController.text.isEmpty) {
      setState(() => _error = 'Enter the current password.');
      return;
    }
    await _run(
      () => PdfCoreService.unlock(widget.pdfPath, _unlockController.text),
      'Password removed. The new file opens without one.',
      'unlock',
    );
  }

  Future<void> _run(
    Future<String> Function() operation,
    String message,
    String trigger,
  ) async {
    if (!PdfCoreService.isAvailable) {
      setState(() {
        _error = 'The native PDF core is not built, so encryption is '
            'unavailable. Run ./scripts/build_pdf_core.sh.';
      });
      return;
    }
    setState(() {
      _isWorking = true;
      _error = null;
    });
    try {
      final output = await operation();
      if (!mounted) return;
      setState(() => _isWorking = false);
      await showPdfResultDialog(
        context: context,
        filePaths: [output],
        accent: _accent,
        adTrigger: trigger,
        message: message,
      );
      if (mounted) Navigator.pop(context, output);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWorking = false;
          _error = PdfCoreService.describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        backgroundColor: _colors.cardBackground,
        elevation: 0,
        iconTheme: IconThemeData(color: _colors.textPrimary),
        title: Text(
          widget.isEncrypted ? 'Remove password' : 'Protect PDF',
          style: TextStyle(color: _colors.textPrimary, fontSize: 17),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          _buildBanner(),
          const SizedBox(height: 20),
          if (widget.isEncrypted) ..._buildUnlockFields() else ..._buildProtectFields(),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              style: TextStyle(color: Colors.red.shade400, fontSize: 13),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _isWorking
                  ? null
                  : (widget.isEncrypted ? _unlock : _protect),
              icon: _isWorking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      widget.isEncrypted
                          ? Icons.lock_open_rounded
                          : Icons.lock_rounded,
                    ),
              label: Text(
                _isWorking
                    ? 'Working…'
                    : widget.isEncrypted
                    ? 'Remove password'
                    : 'Protect with password',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
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

  Widget _buildBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_rounded, color: _accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.isEncrypted
                  ? 'Enter the current password to save an unprotected copy. '
                        'The original file is left untouched.'
                  : 'Encryption is AES-256 (PDF 2.0). Everything happens on '
                        'this device — the password never leaves it, and it '
                        'cannot be recovered if you forget it.',
              style: TextStyle(color: _colors.textSecondary, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildProtectFields() => [
    _field(
      _userController,
      'Password',
      obscure: _obscure,
      trailing: IconButton(
        onPressed: () => setState(() => _obscure = !_obscure),
        icon: Icon(
          _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          color: _colors.textSecondary,
          size: 20,
        ),
      ),
    ),
    const SizedBox(height: 14),
    _field(_confirmController, 'Confirm password', obscure: _obscure),
    const SizedBox(height: 14),
    _field(_ownerController, 'Owner password (optional)', obscure: _obscure),
    const SizedBox(height: 6),
    Text(
      'The owner password controls permissions. Leave it blank to reuse the '
      'password above.',
      style: TextStyle(color: _colors.textTertiary, fontSize: 12),
    ),
  ];

  List<Widget> _buildUnlockFields() => [
    _field(
      _unlockController,
      'Current password',
      obscure: _obscure,
      trailing: IconButton(
        onPressed: () => setState(() => _obscure = !_obscure),
        icon: Icon(
          _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          color: _colors.textSecondary,
          size: 20,
        ),
      ),
    ),
  ];

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    Widget? trailing,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(color: _colors.textPrimary),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _colors.textSecondary),
        prefixIcon: const Icon(Icons.key_rounded, color: _accent, size: 20),
        suffixIcon: trailing,
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
