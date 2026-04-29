// Two-step password reset, OTP-based. Replaces the legacy "click the
// link in your email" flow which doesn't survive on a mobile-only app.
//
// Step 1 — collect the email, fire CurrentUser.sendPasswordReset which
// triggers Supabase Auth's recovery email (template renders 6-digit
// `{{ .Token }}` instead of `{{ .ConfirmationURL }}`).
//
// Step 2 — show six OTP boxes plus a new-password field on the same
// page. Single submit calls resetPasswordWithOtp, which verifyOTPs
// (yields a session) and updateUsers the password atomically. On
// success the user is signed in and AuthGate routes to HomeScreen.
//
// Resend: tappable after a 60s cooldown, identical to the signup OTP
// page's behavior.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_shared_widgets.dart';

class ResetPasswordView extends StatefulWidget {
  final CurrentUser currentUser;

  const ResetPasswordView({super.key, required this.currentUser});

  @override
  State<ResetPasswordView> createState() => _ResetPasswordViewState();
}

enum _Step { enterEmail, enterOtpAndPassword }

class _ResetPasswordViewState extends State<ResetPasswordView>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.enterEmail;
  String _email = '';

  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _otpFocusNode = FocusNode();
  final _newPasswordController = TextEditingController();
  late final AnimationController _shake;

  Timer? _cooldownTimer;
  int _resendCooldownSec = 0;

  static const int _resendCooldownSeconds = 60;
  static const int _otpLength = 6;
  static const int _minPasswordLength = 8;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _otpFocusNode.addListener(_onExternalChanged);
    widget.currentUser.addListener(_onExternalChanged);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _otpFocusNode.removeListener(_onExternalChanged);
    widget.currentUser.removeListener(_onExternalChanged);
    _emailController.dispose();
    _otpController.dispose();
    _otpFocusNode.dispose();
    _newPasswordController.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String get _normalizedEmail =>
      _emailController.text.trim().toLowerCase();

  bool get _step1CanSubmit => _normalizedEmail.contains('@');
  bool get _step2CanSubmit =>
      _otpController.text.length == _otpLength &&
      _newPasswordController.text.length >= _minPasswordLength;

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldownSec = _resendCooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _resendCooldownSec--;
        if (_resendCooldownSec <= 0) {
          _resendCooldownSec = 0;
          t.cancel();
        }
      });
    });
  }

  Future<void> _sendOtp() async {
    if (!_step1CanSubmit) return;
    final ok = await widget.currentUser.sendPasswordReset(_normalizedEmail);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _email = _normalizedEmail;
        _step = _Step.enterOtpAndPassword;
      });
      _startCooldown();
      // Auto-focus the OTP boxes on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _otpFocusNode.requestFocus();
      });
    }
    // Failure path: lastError is set; AuthRootView's listener already
    // pops a dialog. We stay on step 1.
  }

  Future<void> _resendOtp() async {
    if (_resendCooldownSec > 0 || _email.isEmpty) return;
    final ok = await widget.currentUser.sendPasswordReset(_email);
    if (!mounted) return;
    if (ok) {
      _startCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).otpResendSent),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _confirmReset() async {
    if (!_step2CanSubmit ||
        widget.currentUser.isPerformingAuthAction) {
      return;
    }
    final ok = await widget.currentUser.resetPasswordWithOtp(
      email: _email,
      token: _otpController.text.trim(),
      newPassword: _newPasswordController.text,
    );
    if (!mounted) return;
    if (ok) {
      // Tell iOS the new credential is committed so it offers to
      // update Keychain (the email + new password were entered inside
      // the AutofillGroup wrapping step 2).
      TextInput.finishAutofillContext();
      // Signed in; pop everything back to AuthGate, which sees
      // CurrentUserSignedIn and renders HomeScreen.
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    // Wrong OTP / weak password / etc — clear OTP, refocus, shake.
    // The AuthRootView dialog already shows the localized error
    // message via lastError.
    _otpController.clear();
    _otpFocusNode.requestFocus();
    _shake.forward(from: 0);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final working = widget.currentUser.isPerformingAuthAction;
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.chevron_left_rounded,
            color: AetherColors.textPrimary,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            AetherSpacing.lg,
          ),
          // Wrap both steps in a single AutofillGroup so the email
          // (step 1) and new password (step 2) are linked from iOS's
          // perspective — finishAutofillContext at success updates the
          // user's Keychain entry rather than creating a new one.
          child: AutofillGroup(
            child: _step == _Step.enterEmail
                ? _buildStep1(l, working)
                : _buildStep2(l, working),
          ),
        ),
      ),
    );
  }

  Widget _buildStep1(AppL10n l, bool working) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.resetTitle, style: AetherTextStyles.h1),
        const SizedBox(height: AetherSpacing.sm),
        Text(l.resetSubtitleEnterEmail, style: AetherTextStyles.bodySm),
        const SizedBox(height: AetherSpacing.xl),
        AuthField(
          title: l.authEmailHint,
          controller: _emailController,
          keyboard: AuthFieldKeyboard.email,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.username],
        ),
        const SizedBox(height: AetherSpacing.xl),
        AuthPrimaryButton(
          title: l.resetSendCode,
          isWorking: working,
          isEnabled: _step1CanSubmit && !working,
          onTap: _sendOtp,
        ),
      ],
    );
  }

  Widget _buildStep2(AppL10n l, bool working) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.resetTitle, style: AetherTextStyles.h1),
        const SizedBox(height: AetherSpacing.sm),
        Text(
          l.resetSubtitleEnterCode(_email),
          style: AetherTextStyles.bodySm,
        ),
        const SizedBox(height: AetherSpacing.xl),
        OtpBoxRow(
          controller: _otpController,
          focusNode: _otpFocusNode,
          otpLength: _otpLength,
          shake: _shake,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AetherSpacing.lg),
        AuthField(
          title: l.resetNewPasswordHint,
          controller: _newPasswordController,
          isSecure: true,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.newPassword],
        ),
        const SizedBox(height: AetherSpacing.xl),
        AuthPrimaryButton(
          title: l.resetConfirm,
          isWorking: working,
          isEnabled: _step2CanSubmit && !working,
          onTap: _confirmReset,
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: GestureDetector(
            onTap: (_resendCooldownSec > 0 || working) ? null : _resendOtp,
            child: Text(
              _resendCooldownSec > 0
                  ? l.otpResendCooldown(_resendCooldownSec)
                  : l.otpResend,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: (_resendCooldownSec > 0 || working)
                    ? AetherColors.textTertiary
                    : AetherColors.textSecondary,
                decoration: (_resendCooldownSec > 0 || working)
                    ? TextDecoration.none
                    : TextDecoration.underline,
                decorationColor: AetherColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
