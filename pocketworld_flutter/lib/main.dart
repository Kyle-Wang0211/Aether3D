// Phase 2.4 PocketWorld hello main screen + Phase 4.1/4.5 Flutter Texture
// widget + Phase 5.4 FFI version string + Phase 6.4a IOSurface splat
// renderer + Phase 6.4c camera/object transform gestures.
//
// Below the "PocketWorld" title we render a 256×256 Flutter Texture widget
// fed by an IOSurface-backed Dawn-rendered splat scene (Phase 6.4a). The
// widget is wrapped in a GestureDetector that drives 4 transforms:
//   single-finger drag        → camera orbit (OrbitControls)
//   two-finger pinch          → camera dolly (OrbitControls)
//   two-finger same-direction → object pan (ObjectTransform)
//   two-finger counter-rotate → object rotate Y (ObjectTransform)
//
// On every gesture event the new view + model matrices are pushed to the
// native plugin via `setMatrices` method-channel call. The plugin's
// CADisplayLink loop reads the latest matrices on every frame.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'aether_ffi.dart';
import 'orbit_controls.dart';
import 'object_transform.dart';

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
  bool _isRetrying = false;

  // Phase 6.4c: camera + object transform state. State changes on gesture
  // events; matrices are pushed to native plugin via setMatrices method
  // channel. The plugin's displayLink reads the latest matrices each frame.
  final OrbitControls _orbit = OrbitControls();
  final ObjectTransform _object = ObjectTransform();
  // Vertical FOV used for object pan unprojection. Phase 6.4d may make
  // this device-tier dependent; for now it matches the C++ pipeline's
  // 60° default.
  static const double _fovYRadians = 60.0 * 3.14159265 / 180.0;
  // Texture widget renders at this size in Flutter logical pixels. The
  // gesture math uses this for screen→world projection and rotateSpeed
  // calibration. Kept in sync with the SizedBox in build().
  static const Size _textureWidgetSize = Size(256, 256);

  @override
  void initState() {
    super.initState();
    _requestTexture();
  }

  /// Phase 4 polish #6: explicit-retry path for texture create failures.
  /// Native plugin returns one of 8 distinct FlutterError codes (see
  /// AetherTexturePlugin handle("createSharedNativeTexture")). Most are
  /// non-recoverable (NO_METAL, SHADER_COMPILE_FAILED) — but some can be
  /// transient (IOSURFACE_FAILED under memory pressure, MTLTEXTURE_FAILED
  /// after a GPU reset). Without retry, a single failure bricks the
  /// widget for the session.
  Future<void> _requestTexture({bool isManualRetry = false}) async {
    if (_isRetrying) return;
    setState(() {
      _isRetrying = true;
      _textureError = null;
      if (isManualRetry) _textureId = null;
    });
    try {
      final id = await _channel.invokeMethod<int>('createSharedNativeTexture');
      if (!mounted) return;
      setState(() {
        _textureId = id;
        _isRetrying = false;
      });
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _textureError =
            'plugin not registered (running on a non-iOS/macOS target?)';
        _isRetrying = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _textureError = '${e.code}: ${e.message}';
        _isRetrying = false;
      });
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

  /// Push the current orbit + object matrices to the native plugin.
  /// Called from gesture handlers — Flutter's gesture stream is sparse
  /// (one event per finger movement frame), so this is NOT per-render-
  /// frame. The plugin's displayLink uses the most recently set matrices
  /// for every render frame in between gesture events.
  void _pushMatrices() {
    final id = _textureId;
    if (id == null) return;
    final viewBytes = _orbit.viewMatrix();
    final modelBytes = _object.modelMatrix();
    // Fire-and-forget. Errors here are diagnostic-only — a missed
    // setMatrices means the next render uses the previously-stored
    // matrices, which is graceful degradation rather than a crash.
    _channel.invokeMethod('setMatrices', {
      'textureId': id,
      'view': viewBytes,
      'model': modelBytes,
    }).catchError((_) {});
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
                  // Phase 4.1 → 6.4c: Texture widget wrapped in
                  // GestureDetector that drives camera + object transform.
                  // SizedBox keeps the texture at its native 256×256 size
                  // — _textureWidgetSize is kept in sync for the gesture
                  // math's screen→world projection.
                  SizedBox(
                    width: _textureWidgetSize.width,
                    height: _textureWidgetSize.height,
                    child: _textureId != null
                        ? GestureDetector(
                            // Single-finger drag → camera orbit.
                            onPanUpdate: (d) {
                              setState(() {
                                _orbit.rotate(
                                    d.delta.dx, d.delta.dy, _textureWidgetSize);
                              });
                              _pushMatrices();
                            },
                            // Two-finger gestures: pinch + pan + rotate
                            // arrive as a single ScaleUpdateDetails.
                            // Flutter's gesture arena auto-disambiguates
                            // single-vs-double touch — no manual handling
                            // required (decision pin 11: zero tutorial).
                            onScaleUpdate: (d) {
                              setState(() {
                                _orbit.dolly(d.scale);
                                _object.pan(
                                    d.focalPointDelta,
                                    _orbit.viewMatrix(),
                                    _fovYRadians,
                                    _orbit.distance,
                                    _textureWidgetSize);
                                _object.rotate(d.rotation);
                              });
                              _pushMatrices();
                            },
                            child: Texture(textureId: _textureId!),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              // Phase 4 polish #6: retry button when
                              // create failed; "creating…" placeholder
                              // otherwise. _isRetrying disables the button
                              // so back-to-back taps don't spawn parallel
                              // create calls (which would leak texture
                              // IDs the user can't dispose).
                              child: _textureError != null
                                  ? Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          _textureError!,
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                        const SizedBox(height: 12),
                                        ElevatedButton(
                                          onPressed: _isRetrying
                                              ? null
                                              : () => _requestTexture(
                                                  isManualRetry: true),
                                          child: Text(_isRetrying
                                              ? 'retrying\u2026'
                                              : 'retry'),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      _isRetrying
                                          ? 'retrying\u2026'
                                          : 'creating texture\u2026',
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
