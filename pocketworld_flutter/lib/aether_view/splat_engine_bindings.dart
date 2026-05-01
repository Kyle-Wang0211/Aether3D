// Dart FFI bindings for aether_splat_* (3D Gaussian Splat engine,
// shipped in aether_cpp Phase 6.3a).
//
// C API surface (verbatim from
//   aether_cpp/include/aether/splat/aether_splat_c.h):
//
//   int  aether_splat_default_config(aether_splat_config_t* out_config);
//   int  aether_splat_engine_create(void* gpu_device_ptr,
//                                   const aether_splat_config_t* config,
//                                   aether_splat_engine_t** out_engine);
//   void aether_splat_engine_destroy(aether_splat_engine_t* engine);
//   int  aether_splat_load_ply(aether_splat_engine_t* engine, ...);
//   (additional functions for camera + render — fill in G3 from the
//    full header)
//
// G2 ships only the stub. G5 fills these in alongside the PLY/SPZ
// path enablement.

import 'dart:ffi';

/// Opaque pointer to a `aether_splat_engine_t` instance.
typedef SplatEngineHandle = Pointer<Opaque>;

/// `aether_splat_config_t` — keep in sync with the C struct.
/// G3 confirms the exact layout from aether_splat_c.h:21–35.
final class SplatConfig extends Struct {
  // TODO(G3): mirror the C struct fields exactly. Likely contains:
  //   uint32_t max_splats;
  //   uint32_t output_width;
  //   uint32_t output_height;
  //   float    sh_degree;
  // ...placeholder so the file compiles.
  @Uint32()
  external int placeholder;
}

class SplatEngineBindings {
  SplatEngineBindings._();
  static final SplatEngineBindings instance = SplatEngineBindings._();

  // TODO(G3): all the function pointers, mirror SceneRendererBindings.
  // For now this class is a deliberately empty shell so other files
  // can `import` it without compile errors during the G2 hand-off.

  void ensureInitialized() {
    // TODO(G3)
    throw UnimplementedError('G3: bind aether_splat_* functions');
  }
}
