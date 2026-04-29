// Firebase initialization — explicit FirebaseOptions (don't rely on
// plist auto-lookup). Returns false on any failure so AuthGate can
// fall back to MockAuthService and at least render the sign-in page.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options_aether3d.dart';

Future<bool> initializeFirebaseSafely() async {
  if (!Aether3DFirebaseOptions.isPlatformSupported) {
    debugPrint(
      '[FirebaseBootstrap] Platform not yet configured for Firebase; '
      'using MockAuthService fallback.',
    );
    return false;
  }
  try {
    await Firebase.initializeApp(
      options: Aether3DFirebaseOptions.currentPlatform,
    );
    return true;
  } catch (e, st) {
    debugPrint('[FirebaseBootstrap] initializeApp failed: $e\n$st');
    return false;
  }
}
