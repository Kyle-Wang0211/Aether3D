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

class SceneBridge {
  SceneBridge._();
  static final SceneBridge instance = SceneBridge._();

  static const _channel = MethodChannel('aether_texture');

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
  Future<void> loadGlb({required int textureId, required String path}) async {
    await _channel.invokeMethod<void>(
      'loadGlb',
      <String, dynamic>{'textureId': textureId, 'path': path},
    );
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

/// Banner constant the rest of the codebase references when deciding
/// whether to attempt the AetherCpp path. iOS-first: native plugin is
/// shipping, Android / Web stubs land in G6 / G8.
const bool kAetherSceneBridgeAvailable = true;
