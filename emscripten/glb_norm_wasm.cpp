// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 4 — Emscripten module wrapper for the GLB normalizer C ABI.
//
// Why this TU exists when libaether3d_c.a already defines the four
// aether_glb_norm_* symbols:
// Emscripten's static linker dead-strips any archive object whose
// symbols aren't statically reachable from a kept entry point. With
// no `main` and no other live caller, libaether3d_c.a's glb_norm
// objects get dropped from the .wasm even when EXPORTED_FUNCTIONS
// names them — the linker resolves EXPORTED_FUNCTIONS *after* archive
// pruning, so by the time the export list is consulted the .o files
// have already been discarded.
//
// The fix is one live reference per symbol from a non-archive TU.
// `aether_glb_norm_keepalive()` below takes the address of each public
// symbol; that's enough to force the four objects in libaether3d_c.a
// into the link, after which EXPORTED_FUNCTIONS picks them up.
// EMSCRIPTEN_KEEPALIVE on the helper itself prevents Closure from
// folding the address-takes away.
//
// We do NOT redefine the public C ABI here — the names exposed to JS
// are exactly the symbols in aether_glb_norm_c.h, and the forwarder
// would otherwise collide at link time with libaether3d_c.a's copy.

#include "../aether_cpp/include/aether_glb_norm_c.h"

#include <emscripten/emscripten.h>

#ifdef __cplusplus
extern "C" {
#endif

// Volatile pointer table — assigning to a volatile sink prevents the
// optimizer from concluding the addresses are unused. One entry per
// public symbol; if a symbol disappears from aether_glb_norm_c.h, the
// build fails here loud rather than silently dropping from the .wasm.
EMSCRIPTEN_KEEPALIVE
void aether_glb_norm_keepalive(void) {
    static void* volatile sink[4];
    sink[0] = reinterpret_cast<void*>(&aether_glb_norm_run);
    sink[1] = reinterpret_cast<void*>(&aether_glb_norm_options_default);
    sink[2] = reinterpret_cast<void*>(&aether_glb_norm_buffer_free);
    sink[3] = reinterpret_cast<void*>(&aether_glb_norm_result_str);
    (void)sink;
}

#ifdef __cplusplus
}  // extern "C"
#endif
