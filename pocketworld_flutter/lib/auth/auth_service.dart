// Dart port of Core/Auth/AuthService.swift — provider-agnostic protocol.
// Concrete implementations: firebase_auth_service.dart / mock_auth_service.dart.

import 'auth_models.dart';

abstract class AuthService {
  /// Currently signed-in user, or null if signed out.
  Future<AuthenticatedUser?> currentUser();

  /// Sign in with an existing account. Throws `AuthException` on failure.
  Future<AuthenticatedUser> signIn(SignInRequest request);

  /// Create a new account. Throws `AuthException` on failure.
  Future<AuthenticatedUser> signUp(SignUpRequest request);

  /// Send an OTP to a phone number. Returns a verification handle.
  Future<PhoneVerificationChallenge> startPhoneVerification(String phoneNumber);

  /// Resend email verification link to the currently-signed-in user.
  Future<void> sendEmailVerification();

  /// Start password-reset email flow for a given email.
  Future<void> sendPasswordReset(String email);

  /// Drop the current session locally and in the provider.
  Future<void> signOut();

  /// Delete the user's account at the provider AND clear local state.
  /// Irreversible.
  Future<void> deleteAccount();
}
