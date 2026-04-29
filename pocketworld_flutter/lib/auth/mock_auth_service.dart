// Dart port of Core/Auth/MockAuthService.swift.
//
// In-memory AuthService for tests / when Firebase plugin isn't reachable
// (e.g. running `flutter test` without a Firebase emulator). Never used
// in production — main.dart picks the Firebase impl.

import 'auth_models.dart';
import 'auth_service.dart';

class MockAuthServiceImpl implements AuthService {
  AuthenticatedUser? _cached;

  MockAuthServiceImpl({AuthenticatedUser? initial}) : _cached = initial;

  @override
  Future<AuthenticatedUser?> currentUser() async => _cached;

  @override
  Future<AuthenticatedUser> signIn(SignInRequest request) async {
    final AuthenticatedUser user;
    switch (request) {
      case SignInRequestEmail(:final email):
        user = AuthenticatedUser(
          id: InternalUserID('mock_${_slug(email)}'),
          email: email,
        );
      case SignInRequestPhone(:final phoneNumber):
        user = AuthenticatedUser(
          id: InternalUserID('mock_${_slug(phoneNumber)}'),
          phone: phoneNumber,
        );
    }
    _cached = user;
    return user;
  }

  @override
  Future<AuthenticatedUser> signUp(SignUpRequest request) async {
    final AuthenticatedUser user;
    switch (request) {
      case SignUpRequestEmail(:final email, :final displayName):
        user = AuthenticatedUser(
          id: InternalUserID('mock_${_slug(email)}'),
          email: email,
          displayName: displayName,
        );
      case SignUpRequestPhone(:final phoneNumber, :final displayName):
        user = AuthenticatedUser(
          id: InternalUserID('mock_${_slug(phoneNumber)}'),
          phone: phoneNumber,
          displayName: displayName,
        );
    }
    _cached = user;
    return user;
  }

  @override
  Future<PhoneVerificationChallenge> startPhoneVerification(
    String phoneNumber,
  ) async {
    return PhoneVerificationChallenge(
      verificationID: 'mock_vid_${_slug(phoneNumber)}',
      phoneNumber: phoneNumber,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<void> sendEmailVerification() async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signOut() async {
    _cached = null;
  }

  @override
  Future<void> deleteAccount() async {
    _cached = null;
  }

  static String _slug(String input) {
    final buf = StringBuffer();
    for (final c in input.toLowerCase().runes) {
      final isAlphaNum = (c >= 48 && c <= 57) ||
          (c >= 97 && c <= 122);
      buf.writeCharCode(isAlphaNum ? c : 95 /* '_' */);
    }
    return buf.toString();
  }
}
