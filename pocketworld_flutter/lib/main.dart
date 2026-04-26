// Phase 2.4 PocketWorld hello main screen + Phase 4.1/4.5 Flutter Texture
// widget + Phase 5.4 FFI version string.
//
// Below the "PocketWorld" title we render a 256×256 Flutter Texture widget
// fed by an IOSurface-backed MTLTexture (Phase 4.2 macOS / 5.1 iOS). The
// triangle is rotated 1 rad/s by a CADisplayLink-driven Metal render pass.
//
// Footer was P2.4 placeholder `'v0.1.0-phase2'`; Phase 5.4 replaces it
// with the real `AetherFfi.versionString()` FFI call against
// `aether_cpp/src/core/version.cpp`. If the binding fails (e.g. the
// static lib didn't link into the host binary), the footer shows the
// FfiResolutionError reason instead of crashing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'aether_ffi.dart';

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
  void dispose() {
    final id = _textureId;
    if (id != null) {
      // Fire-and-forget: widget is going away, no point awaiting. Native
      // side stops the displayLink, unregisters the texture, drops its
      // strong ref. Without this call the texture leaks on widget rebuild.
      _channel
          .invokeMethod('disposeTexture', {'textureId': id})
          .catchError((_) {});
    }
    super.dispose();
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
                  // Phase 5.4: real FFI call replacing the P2.4 placeholder.
                  // Resolved per build (not memoized) — the lookup is
                  // process-symbol-table search, microseconds. If the
                  // symbol isn't present in the host binary (link issue),
                  // the footer surfaces the FfiResolutionError so the
                  // failure is visible, not silent.
                  _resolveVersionFooter(),
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

/// Returns the version footer string. Wraps [AetherFfi.versionString] so
/// FFI failures surface as a readable label instead of an exception
/// bubbling out of the build phase. Failure modes worth distinguishing:
///   - "FFI: <reason>"  → symbol resolved but call failed (rare)
///   - "FFI miss: <reason>" → symbol not in binary (Phase 5.0 link issue)
///   - "FFI error: <type>" → unexpected exception type (Dart VM / SDK bug)
String _resolveVersionFooter() {
  try {
    return AetherFfi.versionString();
  } on FfiResolutionError catch (e) {
    return 'FFI miss: ${e.message}';
  } on ArgumentError catch (e) {
    // DynamicLibrary.process().lookupFunction throws ArgumentError on
    // unresolved symbol (the common Phase 5.0 failure path before the
    // -force_load fix landed).
    return 'FFI miss: ${e.message ?? e.toString()}';
  } catch (e) {
    return 'FFI error: ${e.runtimeType}';
  }
}
