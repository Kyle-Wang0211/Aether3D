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

  /// Re-send the 6-digit OTP code to a pending email signup. Used when
  /// the user clicks "重新发送 / Resend" on the OTP entry page.
  ///
  /// `password` is required because in the strict-confirmation backend
  /// the OTP rotation goes through the same Edge Function as initial
  /// signup, which writes the (still-unverified) password into
  /// pending_signups. The OTP screen has the password in memory from
  /// EmailVerificationPending.
  Future<void> resendEmailOtp({
    required String email,
    required String password,
  });

  /// Verify a signup OTP code against the pending email account. Returns
  /// the now-active AuthenticatedUser on success. Throws AuthException
  /// (kind=invalidVerificationCode) on bad / expired code.
  ///
  /// `password` is required because the strict-confirmation backend
  /// creates the auth.users row server-side on success and the client
  /// has to immediately `signInWithPassword` to obtain a session.
  Future<AuthenticatedUser> verifyEmailSignupOtp({
    required String email,
    required String token,
    required String password,
  });

  /// Start password-reset email flow for a given email. With the
  /// Supabase "Reset password" template configured to render `{{ .Token }}`,
  /// this sends a 6-digit OTP rather than a clickable link.
  Future<void> sendPasswordReset(String email);

  /// Verify the password-reset OTP and atomically set a new password.
  /// On success the user is signed in (Supabase verifyOTP for type
  /// `recovery` issues a session, which we then use to call
  /// `auth.updateUser` and rotate the password). Returns the now-signed-
  /// in user. Throws AuthException(invalidVerificationCode) on bad /
  /// expired OTP, weakPassword for too-short new password.
  Future<AuthenticatedUser> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  });

  /// Drop the current session locally and in the provider.
  Future<void> signOut();

  /// Delete the user's account at the provider AND clear local state.
  /// Irreversible.
  Future<void> deleteAccount();
}
