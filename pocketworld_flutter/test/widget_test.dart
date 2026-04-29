import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/aether_prefs.dart';
import 'package:pocketworld_flutter/auth/auth_models.dart';
import 'package:pocketworld_flutter/auth/current_user.dart';
import 'package:pocketworld_flutter/auth/mock_auth_service.dart';
import 'package:pocketworld_flutter/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aether_texture');

  setUp(() {
    AetherPrefs.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createSharedNativeTexture') {
            throw MissingPluginException();
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('AuthGate boots to sign-in when no session is persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final currentUser = CurrentUser(service: MockAuthServiceImpl());
    await currentUser.bootstrap();

    await tester.pumpWidget(PocketWorldApp(currentUser: currentUser));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    // Splash's wordmark ("Aether3D") OR AuthRootView's header should appear.
    expect(find.text('Aether3D'), findsAtLeastNWidgets(1));
  });

  testWidgets('AuthGate advances to vault shell after signIn', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = MockAuthServiceImpl();
    final currentUser = CurrentUser(service: service);
    await currentUser.bootstrap();

    await tester.pumpWidget(PocketWorldApp(currentUser: currentUser));
    // Let the splash min-duration + auth state transitions settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    // Sign in (mock), then wait for state propagation.
    await currentUser.signIn(
      const SignInRequest.email(
        email: 'test@aether3d.app',
        password: '123456',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));

    // After sign-in, vault-shell wordmark appears (all caps).
    expect(find.text('AETHER3D'), findsAtLeastNWidgets(1));
  });
}
