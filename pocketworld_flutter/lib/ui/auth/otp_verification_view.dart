// OTP 6-digit verification page. Pushed by EmailSignUpView after the
// Supabase signUp call returns EmailVerificationPending (i.e. the
// project has Confirm-email turned on, account created but session not
// issued until the user proves they own the email).
//
// Visual layout (black & white minimalist, matches AuthRootView):
//   • back arrow + "验证邮箱 / Verify your email"
//   • subtitle "We sent a 6-digit code to <email>"
//   • six independent digit boxes; tapping anywhere focuses a hidden
//     TextField that captures the keyboard
//   • Resend code link with 60s cooldown timer
//
// Submission UX:
//   • As soon as the 6th digit lands, _verify fires automatically — no
//     "Verify" button to tap.
//   • On success the auth stack pops back to AuthGate, which sees
//     CurrentUserSignedIn and renders HomeScreen.
//   • On wrong code: clear all six boxes, refocus, run a damped-sine
//     shake on the row, and trigger HapticFeedback.heavyImpact so the
//     user feels the error without having to read the inline message.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_shared_widgets.dart';

class OtpVerificationView extends StatefulWidget {
  final CurrentUser currentUser;
  final String email;
  // Held in memory only; forwarded to verifySignupOtp so we can sign in
  // immediately after the Edge Function creates the auth.users row.
  // EmailSignUpView passes this through via EmailVerificationPending.
  final String password;

  const OtpVerificationView({
    super.key,
    required this.currentUser,
    required this.email,
    required this.password,
  });

  @override
  State<OtpVerificationView> createState() => _OtpVerificationViewState();
}

class _OtpVerificationViewState extends State<OtpVerificationView>
    with SingleTickerProviderStateMixin {
  final TextEditingController _code = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _cooldownTimer;
  int _resendCooldownSec = 0;
  late final AnimationController _shake;

  static const int _resendCooldownSeconds = 60;
  static const int _otpLength = 6;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _focusNode.addListener(_onExternalChanged);
    _startCooldown();
    widget.currentUser.addListener(_onExternalChanged);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _focusNode.removeListener(_onExternalChanged);
    widget.currentUser.removeListener(_onExternalChanged);
    _code.dispose();
    _focusNode.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    if (!mounted) return;
    setState(() {});
  }

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

  bool get _canSubmit => _code.text.length == _otpLength;

  void _onCodeChanged(String value) {
    setState(() {});
    if (value.length == _otpLength &&
        !widget.currentUser.isPerformingAuthAction) {
      _verify();
    }
  }

  Future<void> _verify() async {
    if (!_canSubmit || widget.currentUser.isPerformingAuthAction) return;
    final ok = await widget.currentUser.verifySignupOtp(
      email: widget.email,
      token: _code.text.trim(),
      password: widget.password,
    );
    if (!mounted) return;
    if (ok) {
      // Sign-up just completed → tell iOS the autofill flow finished
      // so it offers "Save Password to Keychain". The username+password
      // came from the AutofillGroup back on EmailSignUpView, which is
      // still alive in the navigator stack until we pop it below.
      TextInput.finishAutofillContext();
      // CurrentUser is now signedIn; popping back to AuthGate makes it
      // re-evaluate state and show HomeScreen.
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    // Wrong code — wipe boxes, refocus, shake, buzz. Inline error text
    // stays visible below the boxes as a secondary signal.
    _code.clear();
    _focusNode.requestFocus();
    HapticFeedback.heavyImpact();
    _shake.forward(from: 0);
    setState(() {});
  }

  Future<void> _resend() async {
    if (_resendCooldownSec > 0) return;
    final ok = await widget.currentUser.resendSignupOtp(
      email: widget.email,
      password: widget.password,
    );
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
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final working = widget.currentUser.isPerformingAuthAction;
    final err = widget.currentUser.lastError;
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded,
              color: AetherColors.textPrimary),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.otpVerifyTitle, style: AetherTextStyles.h1),
              const SizedBox(height: AetherSpacing.sm),
              Text(
                l.otpVerifySubtitle(widget.email),
                style: AetherTextStyles.bodySm,
              ),
              const SizedBox(height: AetherSpacing.xl),
              OtpBoxRow(
                controller: _code,
                focusNode: _focusNode,
                otpLength: _otpLength,
                shake: _shake,
                onChanged: _onCodeChanged,
              ),
              if (err != null) ...[
                const SizedBox(height: AetherSpacing.md),
                Center(
                  child: Text(
                    err.message,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AetherColors.danger,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AetherSpacing.lg),
              if (working)
                const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AetherColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: AetherSpacing.lg),
              Center(
                child: GestureDetector(
                  onTap: (_resendCooldownSec > 0 || working) ? null : _resend,
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
              const Spacer(),
              Center(
                child: GestureDetector(
                  onTap: working
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: Text(
                    l.otpUseAnotherEmail,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AetherColors.textTertiary,
                    ),
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

// _OtpBoxRow / _OtpBox moved to auth_shared_widgets.dart so
// ResetPasswordView can reuse the same six-box affordance.
