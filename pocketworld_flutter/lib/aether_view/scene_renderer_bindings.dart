// Dart FFI bindings for aether_scene_renderer_* (mesh PBR + splat
// overlay 2-pass IOSurface renderer, shipped in aether_cpp Phase 6.4b
// stage 2 / 6.4e).
//
// ⚠️ NOT used by the community feed viewer.
//
// G3 picked the MethodChannel pattern over Dart FFI for the texture
// rendering path — see lib/aether_view/scene_bridge.dart and
// aether_cpp/PHASE_FLUTTER_VIEWER_PLAN.md. The reason is FlutterTexture
// registration MUST happen on the native side; the existing
// AetherTexturePlugin.swift already does multi-instance management
// keyed by textureId, so reusing that channel was much simpler than
// rebuilding it via FFI.
//
// This file STAYS as a deliberate stub for FUTURE non-texture compute
// paths that don't need a Flutter Texture:
//   • headless splat training kernels (Phase 7 freemium local tier)
//   • golden-image regression tests
//   • batch processing tools
// G3 leaves the typedefs in place so future fillers don't have to
// rebuild the surface from scratch.
//
// C API surface (verbatim from
//   aether_cpp/include/aether/pocketworld/scene_iosurface_renderer.h):
//
//   AetherSceneRenderer* aether_scene_renderer_create(
//       void* iosurface, uint32_t width, uint32_t height);
//   void aether_scene_renderer_destroy(AetherSceneRenderer* r);
//   bool aether_scene_renderer_load_glb(AetherSceneRenderer* r,
//                                       const char* glb_path);
//   void aether_scene_renderer_render_full(
//       AetherSceneRenderer* r,
//       const float* view_matrix /*column-major 4x4*/,
//       const float* proj_matrix /*column-major 4x4*/);
//
// G2 ships only the stub. G3 fills in actual `DynamicLibrary.open` /
// `lookup<NativeFunction>` calls and validates via the macOS Dart CLI
// smoke pattern documented in CROSS_PLATFORM_STACK.md.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opaque pointer to a `AetherSceneRenderer` instance.
typedef SceneRendererHandle = Pointer<Opaque>;

/// Loaded by [_loadAetherLib]; null until G3 wires it.
DynamicLibrary? _lib;

DynamicLibrary _loadAetherLib() {
  // TODO(G3): Platform-specific resolution.
  //   iOS:    DynamicLibrary.process()  (statically linked into Runner)
  //   macOS:  DynamicLibrary.open('libaether3d_ffi.dylib')  via @rpath
  //   Android: DynamicLibrary.open('libaether3d_ffi.so')
  //   Web: not applicable; web uses a different bridge entirely.
  throw UnimplementedError(
      'G3: load libaether3d_ffi via DynamicLibrary.process()/.open');
}

/// `AetherSceneRenderer* aether_scene_renderer_create(void*, uint32_t, uint32_t)`
typedef _NativeCreate = SceneRendererHandle Function(
    Pointer<Void> iosurface, Uint32 w, Uint32 h);
typedef _DartCreate = SceneRendererHandle Function(
    Pointer<Void> iosurface, int w, int h);

/// `void aether_scene_renderer_destroy(AetherSceneRenderer*)`
typedef _NativeDestroy = Void Function(SceneRendererHandle r);
typedef _DartDestroy = void Function(SceneRendererHandle r);

/// `bool aether_scene_renderer_load_glb(AetherSceneRenderer*, const char*)`
typedef _NativeLoadGlb = Bool Function(
    SceneRendererHandle r, Pointer<Utf8> glbPath);
typedef _DartLoadGlb = bool Function(
    SceneRendererHandle r, Pointer<Utf8> glbPath);

/// `void aether_scene_renderer_render_full(...)`
typedef _NativeRenderFull = Void Function(
  SceneRendererHandle r,
  Pointer<Float> viewMatrix,
  Pointer<Float> projMatrix,
);
typedef _DartRenderFull = void Function(
  SceneRendererHandle r,
  Pointer<Float> viewMatrix,
  Pointer<Float> projMatrix,
);

/// Public Dart-friendly façade. Each method asserts the lib is loaded
/// and forwards to the bound function. G3 fills the bodies in.
class SceneRendererBindings {
  SceneRendererBindings._();
  static final SceneRendererBindings instance = SceneRendererBindings._();

  late final _DartCreate _create;
  late final _DartDestroy _destroy;
  late final _DartLoadGlb _loadGlb;
  late final _DartRenderFull _renderFull;

  bool _initialized = false;

  void ensureInitialized() {
    if (_initialized) return;
    _lib ??= _loadAetherLib();
    _create = _lib!.lookupFunction<_NativeCreate, _DartCreate>(
        'aether_scene_renderer_create');
    _destroy = _lib!.lookupFunction<_NativeDestroy, _DartDestroy>(
        'aether_scene_renderer_destroy');
    _loadGlb = _lib!.lookupFunction<_NativeLoadGlb, _DartLoadGlb>(
        'aether_scene_renderer_load_glb');
    _renderFull = _lib!.lookupFunction<_NativeRenderFull, _DartRenderFull>(
        'aether_scene_renderer_render_full');
    _initialized = true;
  }

  /// Create a renderer bound to the platform-specific surface
  /// representation pointed to by [iosurface]. iOS passes an
  /// IOSurface*; macOS passes the same; Android/Web are TODO.
  SceneRendererHandle create({
    required Pointer<Void> iosurface,
    required int width,
    required int height,
  }) {
    ensureInitialized();
    return _create(iosurface, width, height);
  }

  void destroy(SceneRendererHandle r) {
    ensureInitialized();
    _destroy(r);
  }

  bool loadGlb(SceneRendererHandle r, String glbPath) {
    ensureInitialized();
    final pathPtr = glbPath.toNativeUtf8();
    try {
      return _loadGlb(r, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// View + projection matrices passed as 16 floats each, column-major
  /// (matches both Filament and Dart's vector_math `Matrix4.storage`).
  void renderFull(
    SceneRendererHandle r,
    Pointer<Float> viewMatrix,
    Pointer<Float> projMatrix,
  ) {
    ensureInitialized();
    _renderFull(r, viewMatrix, projMatrix);
  }
}
