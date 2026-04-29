// Hard-coded FirebaseOptions extracted from the TestFlight Aether3D
// project's GoogleService-Info.plist. These values are not secrets —
// Firebase API keys are client-facing quota limiters, not auth
// secrets. They're committed to source in every flutterfire-generated
// options file upstream too.

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class Aether3DFirebaseOptions {
  Aether3DFirebaseOptions._();

  // PocketWorld iOS app — registered 2026-04-28 in the same Aether3D
  // Firebase project. Shares Authentication / Firestore / Storage with
  // Aether3D iOS and Aether3D TestFlight (one user pool, three iOS clients).
  // No iosClientId: PocketWorld iOS isn't wired to Google Sign-In yet —
  // email/password is the only enabled provider for now.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAxKYTFHHaf35z8grwdiPrjdJLTIRPPAy4',
    appId: '1:290256460620:ios:ed18afd8a9df8c015acde9',
    messagingSenderId: '290256460620',
    projectId: 'aether3d',
    storageBucket: 'aether3d.firebasestorage.app',
    iosBundleId: 'com.kyle.PocketWorld',
  );

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('FirebaseOptions for web not yet configured.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return ios;
      case TargetPlatform.android:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'Platform ${defaultTargetPlatform.name} not yet configured.',
        );
    }
  }

  static bool get isPlatformSupported {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isMacOS;
  }
}
