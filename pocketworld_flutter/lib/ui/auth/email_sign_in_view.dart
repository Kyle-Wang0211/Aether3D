// EmailSignUpPage — Ultra-Minimal sign-up flow.
//
// Pushed by AuthRootView when the user taps "REQUEST NEW ACCESS / 注册".
// Visual conventions identical to AuthRootView (top bar with back
// chevron + wordmark + 中/EN, big caps heading, underline-only inputs,
// caps text CTA). Differs only in copy and the post-submit handler:
// when the strict-confirmation backend returns EmailVerificationPending,
// we push OtpVerificationView (carrying the password forward so the
// OTP page can signInWithPassword once the user is created).
//
// Filename note: this used to also host the sign-IN form. Sign-in
// moved to auth_root_view.dart in the 2026-04-29 redesign. Renaming
// the file would churn git history more than it's worth right now.

import 'package:flutter/material.dart';

import '../../auth/auth_error.dart';
import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_minimal_widgets.dart';
import 'otp_verification_view.dart';

class EmailSignUpPage extends StatefulWidget {
  final CurrentUser currentUser;

  const EmailSignUpPage({super.key, required this.currentUser});

  @override
  State<EmailSignUpPage> createState() => _EmailSignUpPageState();
}

class _EmailSignUpPageState extends State<EmailSignUpPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.currentUser.addListener(_onUserChanged);
  }

  @override
  void dispose() {
    widget.currentUser.removeListener(_onUserChanged);
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onUserChanged() {
    final err = widget.currentUser.lastError;
    if (err != null && mounted) {
      _showErrorDialog(err);
    }
    if (mounted) setState(() {});
  }

  Future<void> _showErrorDialog(AuthException err) async {
    final message = err.message;
    widget.currentUser.clearLastError();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: AetherColors.bgCanvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        title: Text(
          AppL10n.of(context).authErrorDialogTitle,
          style: AetherTextStyles.h2,
        ),
        content: Text(message, style: AetherTextStyles.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AetherColors.primary),
            child: Text(
              AppL10n.of(context).commonOk,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
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
    final l = AppL10n.of(context);
    final working = widget.currentUser.isPerformingAuthAction;
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      body: SafeArea(
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthTopBar(leading: AuthTopBarBack()),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AetherSpacing.xl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 80),
                      AuthHeading(
                        title: l.authSignUp,
                        subtitle: l.authCreateAccount,
                      ),
                      const SizedBox(height: 64),
                      LabeledField(
                        label: l.authEmailHint,
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: AetherSpacing.xl),
                      LabeledField(
                        label: l.authPasswordHintMin,
                        controller: _password,
                        isSecure: true,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (_canSubmit && !working) _submit();
                        },
                      ),
                      const SizedBox(height: 56),
                      MinimalCta(
                        title: l.authSignUp,
                        enabled: _canSubmit && !working,
                        working: working,
                        onTap: _submit,
                      ),
                      const SizedBox(height: AetherSpacing.xxl),
                      // Tiny terms / privacy reminder. Plain (not link)
                      // for now — when we ship a real privacy policy
                      // page, this can become two MinimalLinks.
                      Text(
                        l.authTermsAcceptance,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AetherColors.textTertiary,
                          height: 1.5,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: AetherSpacing.xl),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
