// Dart port of Core/Auth/AuthModels.swift + AuthService.swift value types.

/// Strongly-typed wrapper so string user IDs don't get confused with
/// other strings (job IDs, record IDs) at call sites. This is the ONLY
/// identifier the app is allowed to persist or reference long-term.
///
/// Today the raw value IS the Firebase UID, but callers must never
/// assume that. If we ever add our own backend that mints internal IDs,
/// switching is a one-line change in FirebaseAuthService.
class InternalUserID {
  final String rawValue;
  const InternalUserID(this.rawValue);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InternalUserID && other.rawValue == rawValue);
  @override
  int get hashCode => rawValue.hashCode;
  @override
  String toString() => rawValue;
}

/// The authenticated user as the app sees them.
class AuthenticatedUser {
  final InternalUserID id;
  final String? email;
  final String? phone;
  final String? displayName;

  const AuthenticatedUser({
    required this.id,
    this.email,
    this.phone,
    this.displayName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuthenticatedUser &&
          other.id == id &&
          other.email == email &&
          other.phone == phone &&
          other.displayName == displayName);
  @override
  int get hashCode => Object.hash(id, email, phone, displayName);
}

/// Intent passed to `signIn` so UI code doesn't pick between overloaded
/// methods. New sign-in methods land as new types under this sealed class.
sealed class SignInRequest {
  const SignInRequest();

  const factory SignInRequest.email({
    required String email,
    required String password,
  }) = SignInRequestEmail;

  const factory SignInRequest.phone({
    required String phoneNumber,
    required String verificationID,
    required String code,
  }) = SignInRequestPhone;
}

class SignInRequestEmail extends SignInRequest {
  final String email;
  final String password;
  const SignInRequestEmail({required this.email, required this.password});
}

class SignInRequestPhone extends SignInRequest {
  final String phoneNumber;
  final String verificationID;
  final String code;
  const SignInRequestPhone({
    required this.phoneNumber,
    required this.verificationID,
    required this.code,
  });
}

sealed class SignUpRequest {
  const SignUpRequest();

  const factory SignUpRequest.email({
    required String email,
    required String password,
    String? displayName,
  }) = SignUpRequestEmail;

  const factory SignUpRequest.phone({
    required String phoneNumber,
    required String verificationID,
    required String code,
    String? displayName,
  }) = SignUpRequestPhone;
}

class SignUpRequestEmail extends SignUpRequest {
  final String email;
  final String password;
  final String? displayName;
  const SignUpRequestEmail({
    required this.email,
    required this.password,
    this.displayName,
  });
}

class SignUpRequestPhone extends SignUpRequest {
  final String phoneNumber;
  final String verificationID;
  final String code;
  final String? displayName;
  const SignUpRequestPhone({
    required this.phoneNumber,
    required this.verificationID,
    required this.code,
    this.displayName,
  });
}

/// Opaque handle returned from `startPhoneVerification`. Provider-defined.
class PhoneVerificationChallenge {
  final String verificationID;
  final String phoneNumber;
  final DateTime? expiresAt;

  const PhoneVerificationChallenge({
    required this.verificationID,
    required this.phoneNumber,
    this.expiresAt,
  });
}

/// SharedPreferences keys the auth layer persists so other modules can
/// read `currentUserID` synchronously without waiting on CurrentUser.
class AuthPersistenceKeys {
  AuthPersistenceKeys._();

  /// Read by e.g. cloud scan-record queries so they can scope per user
  /// at construction time. CurrentUser writes on sign-in/bootstrap
  /// success, clears on sign-out.
  static const currentUserID = 'Aether3D.auth.currentUserID';

  /// Timestamp (ms since epoch) of the last activity — used by the 30-day
  /// idle sign-out policy. Mirrors the Swift UserDefaults key exactly so
  /// future shared-preferences cross-platform migration is trivial.
  static const lastActivityAt = 'Aether3D.auth.lastActivityAt';
}
