// AuthRootView — the sign-in page (entry point of the auth stack).
//
// Visual direction (per Figma 2026-04-29 "Login (Ultra-Minimal)"):
//   • Single column on white. No tabs, no card chrome.
//   • Top bar: brand wordmark (centered) + 中/EN toggle (right). Root
//     page so no leading widget. Sign-up + reset-password sub-pages
//     get a back-chevron leading via AuthTopBarBack.
//   • Heading "登录 / SIGN IN" + subtitle "欢迎回来 / WELCOME BACK"
//     in upper third, lots of breathing room.
//   • Two underline-only inputs (label above, no border box).
//   • Primary CTA "登录 → / SIGN IN →" rendered as bold caps text.
//   • Secondary "注册 / SIGN UP" link → pushes EmailSignUpPage.
//   • Tertiary "忘记密码？/ FORGOT PASSWORD" link → pushes
//     ResetPasswordView.
//
// Design widgets live in auth_minimal_widgets.dart so the sign-up and
// reset-password pages share the same look-and-feel.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_error.dart';
import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_minimal_widgets.dart';
import 'email_sign_in_view.dart';
import 'reset_password_view.dart';

class AuthRootView extends StatefulWidget {
  final CurrentUser currentUser;

  const AuthRootView({super.key, required this.currentUser});

  @override
  State<AuthRootView> createState() => _AuthRootViewState();
}

class _AuthRootViewState extends State<AuthRootView> {
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
      _normalizedEmail.isNotEmpty && _password.text.length >= 6;

  Future<void> _submit() async {
    await widget.currentUser.signIn(
      SignInRequest.email(email: _normalizedEmail, password: _password.text),
    );
    TextInput.finishAutofillContext();
  }

  void _pushSignUp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmailSignUpPage(currentUser: widget.currentUser),
      ),
    );
  }

  void _pushReset() {
    // Plain push (no fullscreenDialog) so iOS edge-swipe-back works,
    // matching the sign-up page's behavior. The previous fullscreenDialog
    // presented this as a modal sheet from the bottom which iOS
    // intentionally disables swipe-back for.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResetPasswordView(currentUser: widget.currentUser),
      ),
    );
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
              const AuthTopBar(),
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
                        title: l.authSignIn,
                        subtitle: l.authWelcomeBack,
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
                        label: l.authPasswordHint,
                        controller: _password,
                        isSecure: true,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (_canSubmit && !working) _submit();
                        },
                      ),
                      const SizedBox(height: 56),
                      MinimalCta(
                        title: l.authSignIn,
                        enabled: _canSubmit && !working,
                        working: working,
                        onTap: _submit,
                      ),
                      const SizedBox(height: AetherSpacing.xxl),
                      MinimalLink(
                        title: l.authSignUp,
                        emphasis: MinimalLinkEmphasis.medium,
                        onTap: working ? null : _pushSignUp,
                      ),
                      const SizedBox(height: AetherSpacing.xl),
                      MinimalLink(
                        title: l.authForgotPassword,
                        emphasis: MinimalLinkEmphasis.faint,
                        onTap: working ? null : _pushReset,
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
