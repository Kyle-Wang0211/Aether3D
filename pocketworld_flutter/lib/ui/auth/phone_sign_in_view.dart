// Dart port of App/Auth/PhoneSignInView.swift.
//
// Two-step flow:
//   1) country code + national number → provider issues verificationID
//   2) enter 6-digit code → sign in / sign up
//
// Not surfaced by AuthRootView today (intent line 75 in Swift: "Phone
// sign-in is intentionally not surfaced here"), but retained so MFA
// can be re-enabled by flipping a flag in auth_root_view.dart without
// re-scaffolding.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../design_system.dart';
import 'auth_shared_widgets.dart';

enum PhoneIntent { signIn, signUp }

class PhoneSignInView extends StatefulWidget {
  final CurrentUser currentUser;
  final PhoneIntent intent;

  const PhoneSignInView({
    super.key,
    required this.currentUser,
    required this.intent,
  });

  @override
  State<PhoneSignInView> createState() => _PhoneSignInViewState();
}

class _PhoneSignInViewState extends State<PhoneSignInView> {
  final _countryCode = TextEditingController(text: '+86');
  final _nationalNumber = TextEditingController();
  final _displayName = TextEditingController();
  final _code = TextEditingController();

  PhoneVerificationChallenge? _challenge;

  @override
  void dispose() {
    _countryCode.dispose();
    _nationalNumber.dispose();
    _displayName.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _e164 {
    final cc = _countryCode.text.replaceAll(RegExp(r'[^0-9]'), '');
    final number = _nationalNumber.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cc.isEmpty || number.isEmpty) return '';
    return '+$cc$number';
  }

  bool get _canStart =>
      _e164.isNotEmpty &&
      _nationalNumber.text.replaceAll(RegExp(r'[^0-9]'), '').length >= 6;

  Future<void> _startVerification() async {
    final result = await widget.currentUser.startPhoneVerification(_e164);
    if (!mounted) return;
    setState(() => _challenge = result);
  }

  Future<void> _submitCode() async {
    final ch = _challenge;
    if (ch == null) return;
    switch (widget.intent) {
      case PhoneIntent.signIn:
        await widget.currentUser.signIn(
          SignInRequest.phone(
            phoneNumber: ch.phoneNumber,
            verificationID: ch.verificationID,
            code: _code.text,
          ),
        );
      case PhoneIntent.signUp:
        await widget.currentUser.signUp(
          SignUpRequest.phone(
            phoneNumber: ch.phoneNumber,
            verificationID: ch.verificationID,
            code: _code.text,
            displayName: _displayName.text.trim().isEmpty
                ? null
                : _displayName.text.trim(),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final working = widget.currentUser.isPerformingAuthAction;
    if (_challenge != null) {
      return _codeEntryStep(working);
    }
    return _phoneEntryStep(working);
  }

  Widget _phoneEntryStep(bool working) {
    return Column(
      children: [
        Row(
          children: [
            AuthField(
              title: '+86',
              controller: _countryCode,
              keyboard: AuthFieldKeyboard.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
              ],
              width: 84,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(width: AetherSpacing.sm),
            Expanded(
              child: AuthField(
                title: '手机号（不含国际区号）',
                controller: _nationalNumber,
                keyboard: AuthFieldKeyboard.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        if (widget.intent == PhoneIntent.signUp) ...[
          const SizedBox(height: AetherSpacing.md),
          AuthField(
            title: '昵称（可选）',
            controller: _displayName,
          ),
        ],
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: '发送验证码',
          isWorking: working,
          isEnabled: _canStart,
          onTap: _startVerification,
        ),
        const SizedBox(height: AetherSpacing.md),
        Text(
          '我们会发送一次性验证码到 ${_e164.isEmpty ? '你的手机号' : _e164}。标准短信费可能适用。',
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

  Widget _codeEntryStep(bool working) {
    final ch = _challenge!;
    return Column(
      children: [
        Text(
          '验证码已发送到 ${ch.phoneNumber}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: AetherColors.textSecondary,
          ),
        ),
        const SizedBox(height: AetherSpacing.md),
        AuthField(
          title: '6 位验证码',
          controller: _code,
          keyboard: AuthFieldKeyboard.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: widget.intent == PhoneIntent.signIn ? '登录' : '完成注册',
          isWorking: working,
          isEnabled: _code.text.length >= 6,
          onTap: _submitCode,
        ),
        const SizedBox(height: AetherSpacing.md),
        GestureDetector(
          onTap: working
              ? null
              : () => setState(() {
                    _challenge = null;
                    _code.clear();
                  }),
          child: const Text(
            '换个手机号',
            style: TextStyle(
              fontSize: 14,
              color: AetherColors.textSecondary,
              decoration: TextDecoration.underline,
              decorationColor: AetherColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
