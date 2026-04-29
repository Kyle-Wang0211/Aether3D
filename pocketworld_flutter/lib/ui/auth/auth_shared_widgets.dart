// Dart port of App/Auth/AuthSharedViews.swift.
//
// Shared presentational helpers for the email / phone sign-in forms.
// Visual direction: black & white minimalist, consistent with
// AetherColors / AetherRadii from ui/design_system.dart.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_system.dart';

enum AuthFieldKeyboard {
  text,
  email,
  phone,
  number,
}

extension _KeyboardTypeMap on AuthFieldKeyboard {
  TextInputType get flutter {
    switch (this) {
      case AuthFieldKeyboard.text:
        return TextInputType.text;
      case AuthFieldKeyboard.email:
        return TextInputType.emailAddress;
      case AuthFieldKeyboard.phone:
        return TextInputType.phone;
      case AuthFieldKeyboard.number:
        return TextInputType.number;
    }
  }
}

class AuthField extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final AuthFieldKeyboard keyboard;
  final bool isSecure;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final void Function(String)? onChanged;
  final double? width;
  // iOS Keychain / Android autofill hints. Set to e.g.
  // [AutofillHints.username] for email, [AutofillHints.password] for
  // sign-in password, [AutofillHints.newPassword] for sign-up / reset
  // password. Pair with an AutofillGroup wrapping the form and
  // TextInput.finishAutofillContext() on successful submit so iOS
  // prompts to save / update credentials.
  final Iterable<String>? autofillHints;

  const AuthField({
    super.key,
    required this.title,
    required this.controller,
    this.keyboard = AuthFieldKeyboard.text,
    this.isSecure = false,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.width,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    // iOS Keychain heuristic: it only offers "Save Password" if the
    // secure field has autocorrect / enableSuggestions / textCapitalization
    // all OFF. Same goes for the email field — autocorrecting an email
    // makes iOS think it's a generic text field and skip the save flow.
    final isPasswordLike = isSecure;
    final isEmailLike = keyboard == AuthFieldKeyboard.email;
    final shouldDisableInputAssistance = isPasswordLike || isEmailLike;
    final field = TextField(
      controller: controller,
      obscureText: isSecure,
      keyboardType: keyboard.flutter,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      onChanged: onChanged,
      autocorrect: !shouldDisableInputAssistance,
      enableSuggestions: !shouldDisableInputAssistance,
      autofillHints: autofillHints,
      textCapitalization: TextCapitalization.none,
      style: const TextStyle(
        fontSize: 15,
        color: AetherColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: title,
        hintStyle: const TextStyle(
          color: AetherColors.textTertiary,
          fontSize: 15,
        ),
        filled: true,
        fillColor: AetherColors.bgCanvas,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AetherRadii.md),
          borderSide: const BorderSide(color: AetherColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AetherRadii.md),
          borderSide: const BorderSide(
            color: AetherColors.primary,
            width: 1.4,
          ),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AetherRadii.md),
          borderSide: const BorderSide(color: AetherColors.border),
        ),
      ),
    );
    if (width != null) {
      return SizedBox(width: width, child: field);
    }
    return field;
  }
}

class AuthPrimaryButton extends StatelessWidget {
  final String title;
  final bool isWorking;
  final bool isEnabled;
  final VoidCallback onTap;

  const AuthPrimaryButton({
    super.key,
    required this.title,
    required this.isWorking,
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effective = isEnabled && !isWorking;
    return GestureDetector(
      onTap: effective ? onTap : null,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: effective ? AetherColors.primary : AetherColors.textTertiary,
          borderRadius: BorderRadius.circular(AetherRadii.md),
        ),
        alignment: Alignment.center,
        child: isWorking
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}

/// Six (or N) independent digit boxes backed by a single hidden TextField.
/// Used by OtpVerificationView (signup) and ResetPasswordView (forgot
/// password) — same look-and-feel; differs only in what the parent does
/// when the row fills.
///
/// Behavior:
///   • Tapping anywhere in the row focuses the hidden field, opens the
///     numeric keyboard. The active box outlines in primary color.
///   • Each digit typed advances visually; backspace deletes from the
///     end. iOS shows the "From Messages" auto-fill suggestion via
///     AutofillHints.oneTimeCode.
///   • The parent supplies a [shake] AnimationController; calling
///     shake.forward(from:0) causes a damped-sine horizontal jiggle —
///     used for "wrong code" feedback paired with HapticFeedback in the
///     parent's verify handler.
class OtpBoxRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final int otpLength;
  final AnimationController shake;
  final ValueChanged<String> onChanged;

  const OtpBoxRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.otpLength,
    required this.shake,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final value = controller.text;
    final hasFocus = focusNode.hasFocus;
    return AnimatedBuilder(
      animation: shake,
      builder: (context, child) {
        // Damped sine: two oscillations over the duration, amplitude
        // 8 px decaying linearly to 0. Gentle enough to read as "wrong"
        // without feeling like an error dialog.
        final t = shake.value;
        final dx = math.sin(t * math.pi * 4) * 8 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: GestureDetector(
        onTap: focusNode.requestFocus,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(otpLength, (i) {
                final char = i < value.length ? value[i] : '';
                final isActive = i == value.length && hasFocus;
                return OtpBox(char: char, isActive: isActive);
              }),
            ),
            // Invisible TextField stacked on top — captures the
            // keyboard, drives `controller`. Visual feedback comes from
            // the boxes below, which read controller.text on rebuild.
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  maxLength: otpLength,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(otpLength),
                  ],
                  onChanged: onChanged,
                  showCursor: false,
                  cursorColor: Colors.transparent,
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                  ),
                  style: const TextStyle(
                    fontSize: 1,
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OtpBox extends StatelessWidget {
  final String char;
  final bool isActive;

  const OtpBox({super.key, required this.char, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 48,
      height: 60,
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.md),
        border: Border.all(
          color: isActive ? AetherColors.primary : AetherColors.border,
          width: isActive ? 2 : 1,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: AetherColors.textPrimary,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
