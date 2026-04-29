// Supabase implementation of the lib/auth/AuthService contract.
// Replaces the Firebase implementation 2026-04-28. UI layer doesn't
// change — it still talks to AuthService through the sealed
// SignInRequest / SignUpRequest types.
//
// Wiring:
//   • Supabase.initialize(url, anonKey) called once in main.dart before
//     anything else.
//   • CurrentUser holds an instance of this and dispatches to it.
//   • Phone OTP is wired through Supabase's signInWithOtp (channel:sms).
//
// Errors: every failure path maps to AuthException with a typed
// AuthErrorKind. The detail string stays in English (Supabase's
// upstream message) — UI shows the localized message from
// AuthException.message.

// Hide Supabase's own AuthException so our app-level AuthException is
// the only one that compiles into call sites. We catch the underlying
// Supabase errors via AuthApiException (still imported below) and
// re-throw as the app type with a typed AuthErrorKind.
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';

class SupabaseAuthServiceImpl implements AuthService {
  final SupabaseClient _client;

  SupabaseAuthServiceImpl({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  @override
  Future<AuthenticatedUser?> currentUser() async {
    final session = _client.auth.currentSession;
    final user = session?.user;
    if (user == null) return null;
    return _wrap(user);
  }

  @override
  Future<AuthenticatedUser> signIn(SignInRequest request) async {
    try {
      switch (request) {
        case SignInRequestEmail(email: final email, password: final pw):
          final res = await _client.auth.signInWithPassword(
            email: email,
            password: pw,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidCredentials);
          }
          return _wrap(user);

        case SignInRequestPhone(
            phoneNumber: final phone,
            code: final code,
          ):
          final res = await _client.auth.verifyOTP(
            phone: phone,
            token: code,
            type: OtpType.sms,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidVerificationCode);
          }
          return _wrap(user);
      }
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<AuthenticatedUser> signUp(SignUpRequest request) async {
    try {
      switch (request) {
        case SignUpRequestEmail(
            email: final email,
            password: final pw,
            displayName: final name,
          ):
          final res = await _client.auth.signUp(
            email: email,
            password: pw,
            data: name == null ? null : {'display_name': name},
          );
          final user = res.user;
          if (user == null) {
            // Should not happen on a successful signUp, but be defensive
            // in case the project has email-confirm gating turned on
            // and the API returns no session yet.
            throw const AuthException(AuthErrorKind.unknown,
                'Sign-up returned no user');
          }
          return _wrap(user);

        case SignUpRequestPhone(
            phoneNumber: final phone,
            code: final code,
            displayName: final name,
          ):
          // Supabase has no separate sign-up for phone — verifyOTP on a
          // never-seen phone creates the user automatically. We pass
          // display_name as user metadata via updateUser after the OTP
          // exchange succeeds.
          final res = await _client.auth.verifyOTP(
            phone: phone,
            token: code,
            type: OtpType.sms,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidVerificationCode);
          }
          if (name != null) {
            await _client.auth.updateUser(
              UserAttributes(data: {'display_name': name}),
            );
          }
          return _wrap(user);
      }
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<PhoneVerificationChallenge> startPhoneVerification(
    String phoneNumber,
  ) async {
    try {
      await _client.auth.signInWithOtp(phone: phoneNumber);
      return PhoneVerificationChallenge(
        // Supabase does not return a server-side verification ID; the
        // pair (phone, code) is enough for verifyOTP. Pass the phone
        // back as the handle so callers can keep the same shape as
        // Firebase did.
        verificationID: phoneNumber,
        phoneNumber: phoneNumber,
      );
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> sendEmailVerification() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    final email = user.email;
    if (email == null) {
      throw const AuthException(
          AuthErrorKind.unknown, 'User has no email on file');
    }
    try {
      await _client.auth.resend(type: OtpType.signup, email: email);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      // signOut failures are best-effort — we still wipe local state.
      // (Network outage shouldn't trap the user signed-in.)
    }
  }

  @override
  Future<void> deleteAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    try {
      // Supabase doesn't expose user-self-delete from anon-key client
      // by default. Production should call an Edge Function with
      // service_role privileges to admin-delete the user. For now we
      // sign out and surface a TODO so callers know it didn't actually
      // remove the row server-side.
      await _client.auth.signOut();
      throw const AuthException(
        AuthErrorKind.providerUnavailable,
        'Account deletion not yet wired — needs a server-side Edge Function '
        'with service_role to call admin.deleteUser. Local session cleared.',
      );
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  // ─── helpers ─────────────────────────────────────────────────────

  AuthenticatedUser _wrap(User user) {
    final meta = user.userMetadata ?? const {};
    final display = meta['display_name'] as String? ??
        meta['full_name'] as String? ??
        meta['name'] as String?;
    return AuthenticatedUser(
      id: InternalUserID(user.id),
      email: user.email,
      phone: user.phone,
      displayName: display,
    );
  }

  AuthErrorKind _mapAuthApi(AuthApiException e) {
    final code = e.code?.toLowerCase() ?? '';
    final msg = e.message.toLowerCase();
    if (code.contains('invalid_credentials') ||
        msg.contains('invalid login') ||
        msg.contains('invalid password')) {
      return AuthErrorKind.invalidCredentials;
    }
    if (code.contains('user_already_exists') ||
        msg.contains('already registered') ||
        msg.contains('already exists')) {
      return AuthErrorKind.accountAlreadyExists;
    }
    if (code.contains('weak_password') || msg.contains('password')) {
      return AuthErrorKind.weakPassword;
    }
    if (code.contains('over_request_rate_limit') ||
        msg.contains('rate limit') ||
        msg.contains('too many')) {
      return AuthErrorKind.rateLimited;
    }
    if (code.contains('otp') || msg.contains('otp') ||
        msg.contains('expired') ||
        msg.contains('verification code')) {
      return AuthErrorKind.invalidVerificationCode;
    }
    if (code.contains('network') || msg.contains('network')) {
      return AuthErrorKind.network;
    }
    return AuthErrorKind.unknown;
  }
}
