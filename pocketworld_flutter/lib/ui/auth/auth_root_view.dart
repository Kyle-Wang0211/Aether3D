// Dart port of App/Auth/AuthRootView.swift, simplified per user
// direction 2026-04-27: **email only** — phone sign-in removed from
// the UI because the product doesn't support phone auth yet. The
// Phone-number Dart view stays in the repo (phone_sign_in_view.dart)
// so MFA can be re-enabled later without re-scaffolding.

import 'package:flutter/material.dart';

import '../../auth/auth_error.dart';
import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'email_sign_in_view.dart';

enum AuthMode { signIn, signUp }

extension AuthModeLabel on AuthMode {
  String localizedTitle(AppL10n l) {
    switch (this) {
      case AuthMode.signIn:
        return l.authSignIn;
      case AuthMode.signUp:
        return l.authSignUp;
    }
  }

  String localizedHeroTagline(AppL10n l) {
    switch (this) {
      case AuthMode.signIn:
        return l.authWelcomeBack;
      case AuthMode.signUp:
        return l.authSignUp;
    }
  }
}

class AuthRootView extends StatefulWidget {
  final CurrentUser currentUser;

  const AuthRootView({super.key, required this.currentUser});

  @override
  State<AuthRootView> createState() => _AuthRootViewState();
}

class _AuthRootViewState extends State<AuthRootView> {
  AuthMode _mode = AuthMode.signIn;

  @override
  void initState() {
    super.initState();
    widget.currentUser.addListener(_onUserChanged);
  }

  @override
  void dispose() {
    widget.currentUser.removeListener(_onUserChanged);
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
        title: Text(AppL10n.of(context).authErrorDialogTitle,
            style: AetherTextStyles.h2),
        content: Text(message, style: AetherTextStyles.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: AetherColors.primary,
            ),
            child: const Text(
              '好的',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AetherSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AetherSpacing.huge),
              _Header(mode: _mode),
              const SizedBox(height: AetherSpacing.xl),
              _ModePicker(
                mode: _mode,
                onChange: (m) => setState(() => _mode = m),
              ),
              const SizedBox(height: AetherSpacing.xl),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: _mode == AuthMode.signIn
                      ? EmailSignInView(currentUser: widget.currentUser)
                      : EmailSignUpView(currentUser: widget.currentUser),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AuthMode mode;

  const _Header({required this.mode});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      children: [
        Text(
          l.appBrand,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            color: AetherColors.primary,
          ),
        ),
        const SizedBox(height: 6),
        Text(mode.localizedHeroTagline(l), style: AetherTextStyles.bodySm),
      ],
    );
  }
}

class _ModePicker extends StatelessWidget {
  final AuthMode mode;
  final ValueChanged<AuthMode> onChange;

  const _ModePicker({required this.mode, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AetherColors.bgElevated,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        children: [
          for (final m in AuthMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onChange(m),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color:
                        m == mode ? AetherColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AetherRadii.pill),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    m.localizedTitle(AppL10n.of(context)),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: m == mode
                          ? Colors.white
                          : AetherColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
