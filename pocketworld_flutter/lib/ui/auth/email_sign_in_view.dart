// Dart port of App/Auth/EmailSignInView.swift — email+password flow.

import 'package:flutter/material.dart';

import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_shared_widgets.dart';

class EmailSignInView extends StatefulWidget {
  final CurrentUser currentUser;

  const EmailSignInView({super.key, required this.currentUser});

  @override
  State<EmailSignInView> createState() => _EmailSignInViewState();
}

class _EmailSignInViewState extends State<EmailSignInView> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _normalizedEmail => _email.text.trim().toLowerCase();

  bool get _canSubmit =>
      _normalizedEmail.isNotEmpty && _password.text.length >= 6;

  Future<void> _submit() async {
    await widget.currentUser.signIn(
      SignInRequest.email(email: _normalizedEmail, password: _password.text),
    );
  }

  Future<void> _forgotPassword() async {
    final ok = await widget.currentUser.sendPasswordReset(_normalizedEmail);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('重置邮件已发送至 $_normalizedEmail'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final working = widget.currentUser.isPerformingAuthAction;
    final l = AppL10n.of(context);
    return Column(
      children: [
        AuthField(
          title: l.authEmailHint,
          controller: _email,
          keyboard: AuthFieldKeyboard.email,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AetherSpacing.md),
        AuthField(
          title: l.authPasswordHint,
          controller: _password,
          isSecure: true,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: l.authSignIn,
          isWorking: working,
          isEnabled: _canSubmit,
          onTap: _submit,
        ),
        const SizedBox(height: AetherSpacing.md),
        GestureDetector(
          onTap: (_normalizedEmail.isEmpty || working) ? null : _forgotPassword,
          child: Text(
            l.authForgotPassword,
            style: TextStyle(
              fontSize: 14,
              color: _normalizedEmail.isEmpty
                  ? AetherColors.textTertiary
                  : AetherColors.textSecondary,
              decoration: TextDecoration.underline,
              decorationColor: AetherColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class EmailSignUpView extends StatefulWidget {
  final CurrentUser currentUser;

  const EmailSignUpView({super.key, required this.currentUser});

  @override
  State<EmailSignUpView> createState() => _EmailSignUpViewState();
}

class _EmailSignUpViewState extends State<EmailSignUpView> {
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _displayName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _normalizedEmail => _email.text.trim().toLowerCase();

  bool get _canSubmit =>
      _normalizedEmail.isNotEmpty && _password.text.length >= 8;

  Future<void> _submit() async {
    await widget.currentUser.signUp(
      SignUpRequest.email(
        email: _normalizedEmail,
        password: _password.text,
        displayName:
            _displayName.text.trim().isEmpty ? null : _displayName.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final working = widget.currentUser.isPerformingAuthAction;
    final l = AppL10n.of(context);
    return Column(
      children: [
        AuthField(
          title: l.authEmailHint,
          controller: _email,
          keyboard: AuthFieldKeyboard.email,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AetherSpacing.md),
        AuthField(
          title: l.authPasswordHint,
          controller: _password,
          isSecure: true,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: l.authSignUp,
          isWorking: working,
          isEnabled: _canSubmit,
          onTap: _submit,
        ),
        const SizedBox(height: AetherSpacing.md),
        Text(
          l.authTermsAcceptance,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            color: AetherColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
