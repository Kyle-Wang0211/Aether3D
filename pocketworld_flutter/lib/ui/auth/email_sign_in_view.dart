// Dart port of App/Auth/EmailSignInView.swift — email+password flow.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_error.dart';
import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_shared_widgets.dart';
import 'otp_verification_view.dart';
import 'reset_password_view.dart';

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
    // Static call, mounted check unnecessary. Triggers the iOS
    // "Save Password to Keychain?" prompt on success. iOS internally
    // suppresses the prompt if it can tell the credential was wrong
    // (e.g. user immediately retyped a different password).
    TextInput.finishAutofillContext();
  }

  void _forgotPassword() {
    // Push the dedicated reset flow (email → OTP + new password). The
    // legacy "fire-and-forget recover email" pattern doesn't work on a
    // mobile-only app — clicking the link in mail opens a browser with
    // nowhere good to land.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResetPasswordView(currentUser: widget.currentUser),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final working = widget.currentUser.isPerformingAuthAction;
    final l = AppL10n.of(context);
    return AutofillGroup(
      child: Column(
        children: [
          AuthField(
            title: l.authEmailHint,
            controller: _email,
            keyboard: AuthFieldKeyboard.email,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: AetherSpacing.md),
          AuthField(
            title: l.authPasswordHint,
            controller: _password,
            isSecure: true,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
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
            onTap: working ? null : _forgotPassword,
            child: Text(
              l.authForgotPassword,
              style: const TextStyle(
                fontSize: 14,
                color: AetherColors.textSecondary,
                decoration: TextDecoration.underline,
                decorationColor: AetherColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
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
    try {
      await widget.currentUser.signUp(
        SignUpRequest.email(
          email: _normalizedEmail,
          password: _password.text,
          displayName: _displayName.text.trim().isEmpty
              ? null
              : _displayName.text.trim(),
        ),
      );
    } on EmailVerificationPending catch (e) {
      // signup-start has emailed an OTP and stashed the request in
      // pending_signups. The auth.users row doesn't exist yet — it
      // gets created when OtpVerificationView calls verifySignupOtp
      // (which then signInWithPasswords using e.password).
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OtpVerificationView(
            currentUser: widget.currentUser,
            email: e.email,
            password: e.password,
          ),
          fullscreenDialog: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final working = widget.currentUser.isPerformingAuthAction;
    final l = AppL10n.of(context);
    return AutofillGroup(
      child: Column(
        children: [
          AuthField(
            title: l.authEmailHint,
            controller: _email,
            keyboard: AuthFieldKeyboard.email,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: AetherSpacing.md),
          AuthField(
            title: l.authPasswordHint,
            controller: _password,
            isSecure: true,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
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
      ),
    );
  }
}
