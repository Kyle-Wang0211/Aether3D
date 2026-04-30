// Dart port of Core/Auth/CurrentUser.swift.
//
// ChangeNotifier between AuthService and UI. Views observe this, not
// AuthService directly. Publishes three states:
//   bootstrapping — persisted session not yet checked
//   signedIn(user) — show the app
//   signedOut — show the sign-in flow
//
// 30-day idle sign-out timestamp mirrors the Swift impl exactly so the
// SharedPreferences key can be shared cross-platform later.

import 'package:flutter/foundation.dart';

import '../aether_prefs.dart';
import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';

sealed class CurrentUserState {
  const CurrentUserState();
}

class CurrentUserBootstrapping extends CurrentUserState {
  const CurrentUserBootstrapping();
}

class CurrentUserSignedIn extends CurrentUserState {
  final AuthenticatedUser user;
  const CurrentUserSignedIn(this.user);
}

class CurrentUserSignedOut extends CurrentUserState {
  const CurrentUserSignedOut();
}

class CurrentUser extends ChangeNotifier {
  /// If the app hasn't seen activity in this many seconds, the session
  /// is force-signed-out. "Activity" = successful sign-in, successful
  /// bootstrap, or scene-active while already signed-in.
  ///
  /// Done locally (SharedPreferences) rather than through Firebase
  /// because Firebase tokens don't expire by default — we want a hard
  /// lockout the user controls even offline.
  static const Duration idleSignOutInterval = Duration(days: 30);

  AuthService _service;

  CurrentUserState _state = const CurrentUserBootstrapping();
  AuthException? _lastError;
  bool _isPerformingAuthAction = false;

  CurrentUser({required AuthService service}) : _service = service;

  /// Debug-only: logs every SignedOut state mutation with a stack trace
  /// so we can answer "who flipped me to SignedOut?" when a stale
  /// detail / settings page surfaces AuthRootView underneath. Wired in
  /// front of every `_state = const CurrentUserSignedOut()` site
  /// (bootstrap / signOut / deleteAccount). Keep cheap in release —
  /// debugPrint is a no-op outside debug.
  void _logSignedOut(String reason) {
    debugPrint('[CurrentUser] → SignedOut ($reason)\n'
        '${StackTrace.current}');
  }

  /// Swap the concrete auth backend at runtime. main() uses this to
  /// launch the app on a mock service (so runApp doesn't block on
  /// Firebase.initializeApp) and upgrade to the Firebase-backed
  /// service once initialization settles.
  void swapService(AuthService newService) {
    _service = newService;
  }

  CurrentUserState get state => _state;
  AuthException? get lastError => _lastError;
  bool get isPerformingAuthAction => _isPerformingAuthAction;
  bool get isSignedIn => _state is CurrentUserSignedIn;
  AuthenticatedUser? get signedInUser {
    final s = _state;
    return s is CurrentUserSignedIn ? s.user : null;
  }

  void clearLastError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Called once at app launch. Reads the persisted session and jumps
  /// to signedIn / signedOut. Force-signs-out if idle.
  Future<void> bootstrap() async {
    try {
      final user = await _service.currentUser();
      // ignore: avoid_print
      print('[AUTH-DEBUG] CurrentUser.bootstrap: _service.currentUser() '
          '→ ${user == null ? "null (will go to signedOut)" : "user=${user.email ?? user.id.rawValue}"}');
      if (user == null) {
        await _clearPersistedUserID();
        _logSignedOut('bootstrap: currentUser==null');
        _state = const CurrentUserSignedOut();
        notifyListeners();
        return;
      }
      final idleExpired = await _isIdleExpired();
      // ignore: avoid_print
      print('[AUTH-DEBUG] CurrentUser.bootstrap: isIdleExpired=$idleExpired');
      if (idleExpired) {
        try {
          await _service.signOut();
        } catch (_) {/* best effort */}
        await _clearIdleTimestamp();
        await _clearPersistedUserID();
        _logSignedOut('bootstrap: idle expired');
        _state = const CurrentUserSignedOut();
        notifyListeners();
        return;
      }
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      notifyListeners();
    } catch (e) {
      _logSignedOut('bootstrap: caught exception: $e');
      _state = const CurrentUserSignedOut();
      notifyListeners();
    }
  }

  /// Called on scene-active transitions from lifecycle observer.
  Future<void> refreshIdleSession() async {
    if (_state is! CurrentUserSignedIn) return;
    if (await _isIdleExpired()) {
      await signOut();
      return;
    }
    await _touchIdleTimestamp();
  }

  Future<void> signIn(SignInRequest request) async {
    await _runAuthAction(() => _service.signIn(request));
  }

  Future<void> signUp(SignUpRequest request) async {
    // Inline (instead of _runAuthAction) so we can surface
    // EmailVerificationPending to the UI: the email/password sign-up
    // form catches it and pushes the OTP verification page.
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.signUp(request);
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
    } on EmailVerificationPending {
      rethrow;
    } on AuthException catch (e) {
      _lastError = e;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Re-issue the 6-digit signup OTP for a pending email account.
  /// Returns true on success; populates `lastError` on failure (so the
  /// OTP page can show "频率太高，稍后再试" / similar).
  ///
  /// Requires the password the user typed at signup. In the strict-
  /// confirmation backend the resend goes through the same Edge
  /// Function as initial signup, which writes (still-unverified) into
  /// pending_signups.
  Future<bool> resendSignupOtp({
    required String email,
    required String password,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      await _service.resendEmailOtp(email: email, password: password);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Verify a 6-digit signup OTP. Promotes state to CurrentUserSignedIn
  /// on success. Sets lastError on failure (caller's UI shows it).
  ///
  /// Requires the password the user typed at signup. The Edge Function
  /// creates the auth.users row server-side, then this method calls
  /// signInWithPassword to obtain the session.
  Future<bool> verifySignupOtp({
    required String email,
    required String token,
    required String password,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.verifyEmailSignupOtp(
        email: email,
        token: token,
        password: password,
      );
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<PhoneVerificationChallenge?> startPhoneVerification(
    String phoneNumber,
  ) async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      final result = await _service.startPhoneVerification(phoneNumber);
      return result;
    } on AuthException catch (e) {
      _lastError = e;
      return null;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return null;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<bool> sendPasswordReset(String email) async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      await _service.sendPasswordReset(email);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Verify the password-reset OTP and rotate to a new password in a
  /// single round trip. On success, the user is signed in (Supabase
  /// recovery verifyOTP issues a session) and we promote state to
  /// CurrentUserSignedIn so AuthGate routes to HomeScreen.
  Future<bool> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.resetPasswordWithOtp(
        email: email,
        token: token,
        newPassword: newPassword,
      );
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      await _service.signOut();
    } catch (_) {/* best effort */}
    await _clearIdleTimestamp();
    await _clearPersistedUserID();
    _logSignedOut('signOut() called');
    _state = const CurrentUserSignedOut();
    _lastError = null;
    notifyListeners();
  }

  Future<bool> deleteAccount() async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      await _service.deleteAccount();
      await _clearIdleTimestamp();
      await _clearPersistedUserID();
      _logSignedOut('deleteAccount() succeeded');
      _state = const CurrentUserSignedOut();
      _lastError = null;
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────

  Future<void> _runAuthAction(
    Future<AuthenticatedUser> Function() action,
  ) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await action();
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
    } on AuthException catch (e) {
      _lastError = e;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<bool> _isIdleExpired() async {
    final prefs = await AetherPrefs.getInstance();
    final lastMs = (await prefs.getInt(AuthPersistenceKeys.lastActivityAt)) ?? 0;
    if (lastMs <= 0) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (nowMs - lastMs) > idleSignOutInterval.inMilliseconds;
  }

  Future<void> _touchIdleTimestamp() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.setInt(
      AuthPersistenceKeys.lastActivityAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _clearIdleTimestamp() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.remove(AuthPersistenceKeys.lastActivityAt);
  }

  static Future<void> _persistUserID(String uid) async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.setString(AuthPersistenceKeys.currentUserID, uid);
  }

  static Future<void> _clearPersistedUserID() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.remove(AuthPersistenceKeys.currentUserID);
  }

  /// Synchronous read of the persisted user ID for modules that need
  /// to scope per-user storage at allocation time. Returns null if no
  /// one's signed in. Prefer this over awaiting CurrentUser.
  static Future<String?> readPersistedUserID() async {
    final prefs = await AetherPrefs.getInstance();
    return prefs.getString(AuthPersistenceKeys.currentUserID);
  }
}
