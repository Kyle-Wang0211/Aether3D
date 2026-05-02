// SceneBridge — Dart-side wrapper around the `aether_texture` Flutter
// MethodChannel that the iOS / macOS Runner already exposes for the
// home-screen DamagedHelmet renderer (Phase 6.4e).
//
// The native side calls into aether_cpp's `aether_scene_renderer_*`
// C API. We piggyback on the same channel + native plugin so the
// community feed can ride the same shipped infrastructure instead of
// going through Dart FFI directly.
//
// Why MethodChannel + not Dart FFI for the texture path:
//   • FlutterTexture registration HAS to be native — Dart can't call
//     `FlutterTextureRegistry.register()`.
//   • The home-screen path is already a working multi-instance
//     implementation; reusing it is much faster than rebuilding via
//     FFI + figuring out IOSurface ↔ Texture id plumbing in Dart.
//   • The ScopedCallbacks / lifecycle / thermal handling that
//     AetherTexturePlugin already does is non-trivial; reproducing
//     that in Dart would be churn.
// FFI stubs in lib/aether_view/scene_renderer_bindings.dart stay for
// LATER use cases that don't need a Flutter Texture (headless splat
// compute, training kernels, golden image tests).
//
// Native API surface (verbatim from AetherTexturePlugin.swift):
//   createSharedNativeTexture({width: int, height: int}) → int
//      Returns the textureId Flutter should hand to a Texture widget.
//      Multi-instance: every call creates a new SharedNativeTexture +
//      a new aether_scene_renderer instance, both keyed by textureId
//      in the plugin's registry.
//
//   disposeTexture({textureId: int})
//      Tears down both the FlutterTexture and the underlying
//      aether_scene_renderer. Safe to call on unknown ids.
//
//   loadGlb({textureId: int, path: String}) → throws on failure
//      Loads a .glb file via aether_scene_renderer_load_glb. Path must
//      be a real on-disk path (file://-stripped); native side opens it
//      with cgltf + stb_image.
//
//   setMatrices({textureId: int, view: Float32List(16), model: Float32List(16)})
//      Push a frame's view + model (NOT projection — projection is
//      derived inside the native renderer from the texture's
//      width/height aspect). Triggers a render through the displayLink.
//
//   pauseRendering / resumeRendering
//      Lifecycle hooks. Already wired to AppLifecycleObserver in
//      lib/lifecycle_observer.dart for the home-screen renderer.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

// Conditional import: picks platform_check_io.dart on dart:io targets
// (iOS, macOS, Android, Linux, Windows) and platform_check_web.dart on
// dart:html / web. The latter just returns false unconditionally.
import 'platform_check_io.dart'
    if (dart.library.html) 'platform_check_web.dart';

class SceneBridge {
  SceneBridge._() {
    // Listen on the warning channel so widgets can react to native-side
    // events (mainly iOS memory warnings, which trigger
    // AetherTexturePlugin.handleMemoryWarning() to dispose ALL textures).
    // Without this listener the disposed textures' Flutter Texture
    // widgets render nothing and never recover; AetherCppCardDemo sees
    // the broadcast on its memory-warning subscription and rebuilds.
    _warningChannel.setMethodCallHandler(_handleWarning);
  }
  static final SceneBridge instance = SceneBridge._();

  static const _channel = MethodChannel('aether_texture');
  static const _warningChannel = MethodChannel('aether_texture/warning');

  /// Broadcast stream of native-side warnings. Currently fires for
  /// iOS memory warnings (kind="memory"); thermal events use the same
  /// pattern when wired. Subscribers should drop GPU references and
  /// rebuild lazily — the underlying SharedNativeTextures are GONE
  /// when this fires, the textureIds Flutter is rendering reference
  /// nothing.
  Stream<String> get warnings => _warningController.stream;
  final StreamController<String> _warningController =
      StreamController<String>.broadcast();

  Future<void> _handleWarning(MethodCall call) async {
    if (call.method != 'warning') return;
    final args = call.arguments;
    final kind = (args is Map && args['kind'] is String) ? args['kind'] as String : 'unknown';
    _warningController.add(kind);
  }

  /// Create a renderer instance + return its Flutter textureId. The
  /// caller wraps the id in a `Texture(textureId: ...)` widget.
  Future<int> createTexture({required int width, required int height}) async {
    final id = await _channel.invokeMethod<int>(
      'createSharedNativeTexture',
      <String, dynamic>{'width': width, 'height': height},
    );
    if (id == null) {
      throw StateError(
        'createSharedNativeTexture returned null — see Xcode Console '
        'for [Aether3D][scene_renderer] diagnostic',
      );
    }
    return id;
  }

  /// Destroy a renderer. Safe on unknown ids (no-op on the native side).
  Future<void> destroyTexture(int textureId) async {
    await _channel.invokeMethod<void>(
      'disposeTexture',
      <String, dynamic>{'textureId': textureId},
    );
  }

  /// Load a GLB into the renderer. Throws PlatformException on parse /
  /// IO / GPU-allocation failure (caller surfaces as `_loadFailed`).
  ///
  /// Returns the loaded mesh's local-space AABB as a map with keys
  /// `minX/minY/minZ/maxX/maxY/maxZ` (all doubles), or an empty map if
  /// the native side couldn't surface bounds. Older Runners that
  /// pre-date G4 will return `null` (the typed result is `Map<...>?`).
  Future<Map<String, double>?> loadGlb({
    required int textureId,
    required String path,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'loadGlb',
      <String, dynamic>{'textureId': textureId, 'path': path},
    );
    return _decodeBounds(raw);
  }

  /// Load a 3D Gaussian Splat .ply file.
  ///
  /// Phase 6.4f.3.b adds two memory caps:
  ///   • `maxSplats` — 0 means no cap. >0 strides through the file
  ///     keeping every k-th gaussian, where k = ceil(N/maxSplats).
  ///     Use a low cap (~50_000) for feed thumbnails.
  ///   • `maxShDegree` — 3 = full quality (file's degree honored), 0 =
  ///     drop higher-order spherical harmonics. The DC coefficient is
  ///     always retained. At sh_degree=3 the higher orders cost
  ///     ~540 B/splat — capping to 0 for a 786 k splat scene saves
  ///     ~425 MB of GPU memory at zero perceptual cost on a thumb.
  Future<Map<String, double>?> loadPly({
    required int textureId,
    required String path,
    int maxSplats = 0,
    int maxShDegree = 3,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'loadPly',
      <String, dynamic>{
        'textureId': textureId,
        'path': path,
        'maxSplats': maxSplats,
        'maxShDegree': maxShDegree,
      },
    );
    return _decodeBounds(raw);
  }

  /// Load a Niantic Lightship SPZ-format compressed splat scene.
  /// Same cap semantics as [loadPly].
  Future<Map<String, double>?> loadSpz({
    required int textureId,
    required String path,
    int maxSplats = 0,
    int maxShDegree = 3,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'loadSpz',
      <String, dynamic>{
        'textureId': textureId,
        'path': path,
        'maxSplats': maxSplats,
        'maxShDegree': maxShDegree,
      },
    );
    return _decodeBounds(raw);
  }

  /// Shared bounds-decode used by load_glb / load_ply / load_spz —
  /// the native side surfaces bounds the same way for all three.
  Map<String, double>? _decodeBounds(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final bounds = raw['bounds'];
    if (bounds is! Map) return <String, double>{};
    final out = <String, double>{};
    for (final key in const ['minX', 'minY', 'minZ', 'maxX', 'maxY', 'maxZ']) {
      final v = bounds[key];
      if (v is num) out[key] = v.toDouble();
    }
    if (out.length != 6) return <String, double>{};
    return out;
  }

  /// Push view + model matrices for one frame. Both are 16 floats,
  /// column-major (matches `vector_math_64.Matrix4.storage`). The
  /// native side derives projection from the texture's known
  /// width/height aspect.
  Future<void> setMatrices({
    required int textureId,
    required Float32List view,
    required Float32List model,
  }) async {
    assert(view.length == 16, 'view matrix must be 16 floats');
    assert(model.length == 16, 'model matrix must be 16 floats');
    await _channel.invokeMethod<void>(
      'setMatrices',
      <String, dynamic>{
        'textureId': textureId,
        'view': view,
        'model': model,
      },
    );
  }

  /// Pause / resume the displayLink (lifecycle hooks). Both are
  /// app-global, not per-texture — the LifecycleObserver already
  /// drives them for the home renderer; the feed just inherits.
  Future<void> pauseRendering() =>
      _channel.invokeMethod<void>('pauseRendering');
  Future<void> resumeRendering() =>
      _channel.invokeMethod<void>('resumeRendering');
}

/// True iff the current platform has a registered `aether_texture`
/// MethodChannel handler. iOS + macOS Runners do (Phase 6.4e wires
/// AetherTexturePlugin); Android + Web don't yet (G6 / G8 lands the
/// platform-specific Texture↔Dawn glue when those targets enter
/// scope. The pocketworld_flutter project doesn't even have an
/// android/ directory at the time of writing — App Store launch is
/// iOS-only per the project plan).
///
/// Callers (LiveModelView, AetherCppCardDemo, AetherCppViewerImpl)
/// gate on this and raise UnsupportedViewerFormatError on platforms
/// where it's false, so the UI can show a "platform not supported"
/// cover instead of crashing on the first MethodChannel call.
///
/// Implementation lives in platform_check_io.dart /
/// platform_check_web.dart so this file doesn't have to import
/// `dart:io` (which fails to compile on web). See the conditional
/// import at the top.
final bool kAetherSceneBridgeAvailable =
    aetherSceneBridgeAvailableForPlatform();
