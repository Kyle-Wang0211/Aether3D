// Dart port of Core/Auth/AuthError.swift.
//
// Provider-agnostic error surface — FirebaseAuthService maps Firebase
// errors into these cases so UI code never has to switch on raw codes.

enum AuthErrorKind {
  /// Invalid email / phone / password.
  invalidCredentials,

  /// Requested email/phone already has an account.
  accountAlreadyExists,

  /// SMS verification code didn't match or expired.
  invalidVerificationCode,

  /// Password too weak for provider policy.
  weakPassword,

  /// Provider rate-limited the request.
  rateLimited,

  /// Network transport error; user can retry.
  network,

  /// Provider backend not reachable / misconfigured.
  providerUnavailable,

  /// Action requires a signed-in user but there was none.
  notSignedIn,

  /// Catch-all.
  unknown,
}

/// Raised by `signUp` when the OTP has been sent and the UI should
/// transition to the 6-digit entry screen. Not a hard error.
///
/// Carries the password the user just typed so the OTP screen can
/// forward it to `verifyEmailSignupOtp`. We need it because in the
/// strict-confirmation flow the *real* auth.users row is created
/// server-side at OTP verification time; the client then has to
/// `signInWithPassword` to obtain a session, and that requires the
/// password again. Holding it on the OTP page (in memory only) avoids
/// asking the user to retype it.
class EmailVerificationPending implements Exception {
  final String email;
  final String password;
  const EmailVerificationPending(this.email, this.password);

  @override
  String toString() => 'EmailVerificationPending($email)';
}

class AuthException implements Exception {
  final AuthErrorKind kind;
  final String? detail;

  const AuthException(this.kind, [this.detail]);

  String get message {
    switch (kind) {
      case AuthErrorKind.invalidCredentials:
        return '账号或密码不正确';
      case AuthErrorKind.accountAlreadyExists:
        return '该账号已注册，请直接登录';
      case AuthErrorKind.invalidVerificationCode:
        return '验证码错误或已过期';
      case AuthErrorKind.weakPassword:
        return '密码强度不足（至少 6 位）';
      case AuthErrorKind.rateLimited:
        return '请求过于频繁，请稍后再试';
      case AuthErrorKind.network:
        return '网络连接失败，请检查网络后重试';
      case AuthErrorKind.providerUnavailable:
        return '登录服务暂时不可用';
      case AuthErrorKind.notSignedIn:
        return '请先登录';
      case AuthErrorKind.unknown:
        return '登录失败，请重试';
    }
  }

  @override
  String toString() => 'AuthException($kind${detail == null ? '' : ': $detail'})';
}
