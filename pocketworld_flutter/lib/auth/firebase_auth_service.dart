// Real AuthService backed by Firebase (via firebase_auth pub plugin).

import 'package:firebase_auth/firebase_auth.dart' as fb;

import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';

class FirebaseAuthServiceImpl implements AuthService {
  final fb.FirebaseAuth _auth;

  FirebaseAuthServiceImpl({fb.FirebaseAuth? auth})
      : _auth = auth ?? fb.FirebaseAuth.instance;

  @override
  Future<AuthenticatedUser?> currentUser() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return _toAuthenticatedUser(user);
  }

  @override
  Future<AuthenticatedUser> signIn(SignInRequest request) async {
    return _mapErrors(() async {
      switch (request) {
        case SignInRequestEmail(:final email, :final password):
          final cred = await _auth.signInWithEmailAndPassword(
            email: email,
            password: password,
          );
          final user = cred.user;
          if (user == null) throw const AuthException(AuthErrorKind.unknown);
          return _toAuthenticatedUser(user);
        case SignInRequestPhone(:final verificationID, :final code):
          final phoneCred = fb.PhoneAuthProvider.credential(
            verificationId: verificationID,
            smsCode: code,
          );
          final cred = await _auth.signInWithCredential(phoneCred);
          final user = cred.user;
          if (user == null) throw const AuthException(AuthErrorKind.unknown);
          return _toAuthenticatedUser(user);
      }
    });
  }

  @override
  Future<AuthenticatedUser> signUp(SignUpRequest request) async {
    return _mapErrors(() async {
      late fb.User firebaseUser;
      String? intendedName;
      switch (request) {
        case SignUpRequestEmail(
            :final email,
            :final password,
            :final displayName
          ):
          final cred = await _auth.createUserWithEmailAndPassword(
            email: email,
            password: password,
          );
          final user = cred.user;
          if (user == null) throw const AuthException(AuthErrorKind.unknown);
          firebaseUser = user;
          intendedName = displayName;
        case SignUpRequestPhone(
            :final verificationID,
            :final code,
            :final displayName
          ):
          final phoneCred = fb.PhoneAuthProvider.credential(
            verificationId: verificationID,
            smsCode: code,
          );
          final cred = await _auth.signInWithCredential(phoneCred);
          final user = cred.user;
          if (user == null) throw const AuthException(AuthErrorKind.unknown);
          firebaseUser = user;
          intendedName = displayName;
      }
      if (intendedName != null && intendedName.isNotEmpty) {
        try {
          await firebaseUser.updateDisplayName(intendedName);
        } catch (_) {}
      }
      return _toAuthenticatedUser(firebaseUser);
    });
  }

  @override
  Future<PhoneVerificationChallenge> startPhoneVerification(
    String phoneNumber,
  ) async {
    final completer = _PhoneVerificationCompleter();
    await _mapErrors(() async {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(minutes: 2),
        verificationCompleted: (_) {},
        verificationFailed: (e) {
          completer.completeError(_mapFirebaseAuthException(e));
        },
        codeSent: (verificationId, _) {
          completer.complete(PhoneVerificationChallenge(
            verificationID: verificationId,
            phoneNumber: phoneNumber,
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          ));
        },
        codeAutoRetrievalTimeout: (verificationId) {
          if (!completer.isCompleted) {
            completer.complete(PhoneVerificationChallenge(
              verificationID: verificationId,
              phoneNumber: phoneNumber,
              expiresAt: DateTime.now().add(const Duration(minutes: 5)),
            ));
          }
        },
      );
    });
    return completer.future;
  }

  @override
  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    await _mapErrors(() => user.sendEmailVerification());
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    await _mapErrors(() => _auth.sendPasswordResetEmail(email: email));
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  @override
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    await _mapErrors(() => user.delete());
  }

  AuthenticatedUser _toAuthenticatedUser(fb.User user) {
    return AuthenticatedUser(
      id: InternalUserID(user.uid),
      email: user.email,
      phone: user.phoneNumber,
      displayName: user.displayName,
    );
  }

  Future<T> _mapErrors<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  AuthException _mapFirebaseAuthException(fb.FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-credential':
        return AuthException(AuthErrorKind.invalidCredentials, e.code);
      case 'email-already-in-use':
      case 'credential-already-in-use':
        return AuthException(AuthErrorKind.accountAlreadyExists, e.code);
      case 'weak-password':
        return AuthException(AuthErrorKind.weakPassword, e.code);
      case 'too-many-requests':
        return AuthException(AuthErrorKind.rateLimited, e.code);
      case 'network-request-failed':
        return AuthException(AuthErrorKind.network, e.code);
      case 'invalid-verification-code':
      case 'invalid-verification-id':
      case 'session-expired':
        return AuthException(AuthErrorKind.invalidVerificationCode, e.code);
      default:
        return AuthException(
          AuthErrorKind.unknown,
          'firebase_${e.code}:${e.message ?? ''}',
        );
    }
  }
}

class _PhoneVerificationCompleter {
  bool _completed = false;
  final _inner = <PhoneVerificationChallenge>[];
  final _errors = <Object>[];

  void complete(PhoneVerificationChallenge v) {
    if (_completed) return;
    _completed = true;
    _inner.add(v);
  }

  void completeError(Object e) {
    if (_completed) return;
    _completed = true;
    _errors.add(e);
  }

  bool get isCompleted => _completed;

  Future<PhoneVerificationChallenge> get future async {
    while (!_completed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_errors.isNotEmpty) throw _errors.first;
    return _inner.first;
  }
}
