// Phase 2.4 PocketWorld hello main screen + Phase 4.1/4.5 Flutter Texture
// widget + Phase 5.4 FFI version string + Phase 6.4a IOSurface splat
// renderer + Phase 6.4c camera/object transform gestures + Phase 6.4b
// stage 2 GLB mesh load (DamagedHelmet) under the splat overlay.
//
// Below the "PocketWorld" title we render a 256×256 Flutter Texture widget
// fed by an IOSurface-backed Dawn-rendered scene (mesh PBR + splat
// overlay). The widget is wrapped in a GestureDetector that drives 4
// transforms:
//   single-finger drag        → camera orbit (OrbitControls)
//   two-finger pinch          → camera dolly (OrbitControls)
//   two-finger same-direction → object pan (ObjectTransform)
//   two-finger counter-rotate → object rotate Y (ObjectTransform)
//
// On every gesture event the new view + model matrices are pushed to the
// native plugin via `setMatrices` method-channel call. The plugin's
// CADisplayLink loop reads the latest matrices on every frame.
//
// Phase 6.4b stage 2 caveat: the mesh DOES respond to view+model
// matrices through Filament-style PBR. The splat overlay is still
// hardcoded screen-space (Phase 6.4f tracks Brush full-pipeline
// integration → splat world-space + gesture-responsive).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'aether_ffi.dart';
import 'lifecycle_observer.dart';
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

  // Phase 6.4b stage 2: status of the GLB load, surfaced as a small
  // overlay above the texture (success "mesh: DamagedHelmet" or failure
  // "mesh: <error>"). The texture widget keeps working either way — a
  // failed loadGlb just leaves the renderer in splat-overlay-only mode.
  String? _glbStatus;

  // Phase 6.4c: camera + object transform state. State changes on gesture
  // events; matrices are pushed to native plugin via setMatrices method
  // channel. The plugin's displayLink reads the latest matrices each frame.
  final OrbitControls _orbit = OrbitControls();
  final ObjectTransform _object = ObjectTransform();
  LifecycleObserver? _lifecycle;
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
    _lifecycle = LifecycleObserver(
      orbit: _orbit,
      obj: _object,
      onStateChanged: () {
        if (!mounted) return;
        setState(() {});
        _pushMatrices();
      },
    );
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
      if (id != null) {
        // Phase 6.4b stage 2: push the initial OrbitControls + object
        // matrices BEFORE any gesture happens. Without this, the
        // renderer's per-frame matrices stay at identity (Swift's
        // default), which puts the camera AT the helmet's origin → no
        // visible mesh. _pushMatrices() makes the very first frame use
        // distance=5 / polar=π/2 / azimuth=0 lookAt so the helmet
        // appears in frame.
        _pushMatrices();
        // Kick off the default GLB load. We do this AFTER the texture is
        // registered (so the displayLink already ticking renders splat-
        // only frames during the parse/upload, not a black screen). The
        // renderer handles GLB-replace gracefully (drops old mesh
        // resources before installing new ones).
        unawaited(_loadDefaultGlb(id));
      }
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
    _lifecycle?.dispose();
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

  /// Phase 6.4b stage 2 — locate DamagedHelmet.glb and ask the native
  /// plugin to load it. Search candidates mirror the dylib search in
  /// MainFlutterWindow.swift (relative to flutter run's cwd). On
  /// success we set _glbStatus to a green "mesh: …" label; on failure
  /// the user sees the platform-error message so the failure isn't
  /// silent (Phase 6.3a catastrophe rule).
  Future<void> _loadDefaultGlb(int textureId) async {
    const filename = 'DamagedHelmet.glb';
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/aether_cpp/build/test_assets/$filename',
      '$cwd/../aether_cpp/build/test_assets/$filename',
      '$cwd/../../aether_cpp/build/test_assets/$filename',
      // Last-ditch absolute path for this dev tree.
      '/Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/build/test_assets/$filename',
    ];
    String? found;
    for (final c in candidates) {
      try {
        if (await File(c).exists()) {
          found = c;
          break;
        }
      } catch (_) {
        // Permission / IO issues — try the next candidate.
      }
    }
    if (found == null) {
      if (!mounted) return;
      setState(() {
        _glbStatus =
            'mesh: $filename not found (looked in cwd / ../ / ../../ / dev abspath)';
      });
      return;
    }
    try {
      await _channel.invokeMethod('loadGlb', {
        'textureId': textureId,
        'path': found,
      });
      if (!mounted) return;
      setState(() {
        _glbStatus = 'mesh: $filename';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _glbStatus = 'mesh: ${e.code} — ${e.message ?? "(no message)"}';
      });
    }
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
                  if (_glbStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _glbStatus!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _glbStatus!.startsWith('mesh: DamagedHelmet')
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  SizedBox(
                    width: _textureWidgetSize.width,
                    height: _textureWidgetSize.height,
                    child: _textureId != null
                        ? GestureDetector(
                            // Flutter API constraint: onScaleUpdate is a
                            // SUPERSET of onPanUpdate (a 1-pointer scale
                            // event has scale=1, rotation=0, with the
                            // pointer's drag in focalPointDelta). Using
                            // both raises FlutterError "Incorrect
                            // GestureDetector arguments". So we route
                            // both gesture branches through one handler
                            // and dispatch on pointerCount.
                            onScaleUpdate: (d) {
                              setState(() {
                                if (d.pointerCount <= 1) {
                                  // Single-finger drag → camera orbit.
                                  // focalPointDelta IS the drag delta.
                                  _orbit.rotate(
                                      d.focalPointDelta.dx,
                                      d.focalPointDelta.dy,
                                      _textureWidgetSize);
                                } else {
                                  // Two-finger: pinch + pan + rotate.
                                  _orbit.dolly(d.scale);
                                  _object.pan(
                                      d.focalPointDelta,
                                      _orbit.viewMatrix(),
                                      _fovYRadians,
                                      _orbit.distance,
                                      _textureWidgetSize);
                                  _object.rotate(d.rotation);
                                  // Bug fix (post-cleanup): orbit.target
                                  // must follow object.position so the
                                  // single-finger orbit AFTER a pan
                                  // rotates around the (now moved) helmet
                                  // — not around world origin (which
                                  // would make the helmet swing past the
                                  // camera looking like a translation,
                                  // and pinch dolly toward empty air
                                  // looking like "broken zoom").
                                  // Per decision pin "object.pan moves
                                  // the object, not the orbit target",
                                  // we keep pan acting on _object but
                                  // sync target afterwards so the camera
                                  // stays correctly framed.
                                  _orbit.target.setFrom(_object.position);
                                }
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
