// Dart port of App/Auth/AuthSharedViews.swift.
//
// Shared presentational helpers for the email / phone sign-in forms.
// Visual direction: black & white minimalist, consistent with
// AetherColors / AetherRadii from ui/design_system.dart.

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
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      obscureText: isSecure,
      keyboardType: keyboard.flutter,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      onChanged: onChanged,
      autocorrect: keyboard != AuthFieldKeyboard.email,
      enableSuggestions: keyboard != AuthFieldKeyboard.email,
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
