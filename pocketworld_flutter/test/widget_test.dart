import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocketworld_flutter/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aether_texture');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('PocketWorld shell handles missing native plugin gracefully', (
    tester,
  ) async {
    await tester.pumpWidget(const PocketWorldApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('PocketWorld'), findsOneWidget);
    expect(find.textContaining('plugin not registered'), findsOneWidget);
  });
}
