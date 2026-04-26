// Phase 2.4 PocketWorld hello main screen + Phase 4.1/4.5 Flutter Texture widget.
//
// Below the "PocketWorld" title we render a 256×256 Flutter Texture widget
// fed by native-side CVPixelBuffer (currently a static CPU-rendered RGB
// gradient — Phase 4.2 will replace the buffer source with an IOSurface-
// backed MTLTexture so native GPU writes feed the same widget).
//
// Footer "v0.1.0-phase2" is still the Phase 3.5 placeholder; the FFI
// hookup landed on macOS Dart CLI but the iOS Pod final-mile is deferred.
// See aether_cpp/PHASE_BACKLOG.md.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const PocketWorldApp());
}

class PocketWorldApp extends StatelessWidget {
  const PocketWorldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketWorld',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _channel = MethodChannel('aether_texture');
  int? _textureId;
  String? _textureError;

  @override
  void initState() {
    super.initState();
    _requestTexture();
  }

  Future<void> _requestTexture() async {
    try {
      final id = await _channel.invokeMethod<int>('createGradientTexture');
      if (!mounted) return;
      setState(() => _textureId = id);
    } on MissingPluginException {
      if (!mounted) return;
      setState(() => _textureError =
          'plugin not registered (running on a non-macOS target?)');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _textureError = '${e.code}: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'PocketWorld',
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Phase 4.1 + 4.5 Texture widget. Phase 4.2 swaps the
                  // CPU-rendered CVPixelBuffer for an IOSurface-backed
                  // MTLTexture; widget tree doesn't change.
                  SizedBox(
                    width: 256,
                    height: 256,
                    child: _textureId != null
                        ? Texture(textureId: _textureId!)
                        : Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text(
                                _textureError ?? 'creating texture\u2026',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Text(
                  'v0.1.0-phase2',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
