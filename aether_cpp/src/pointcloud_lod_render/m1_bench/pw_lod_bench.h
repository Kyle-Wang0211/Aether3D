// PWLodBench -- C entry for the LOD render bench.
//
// The engine behind this header is platform-neutral C++ + WebGPU (Dawn) + WGSL.
// A thin shell (iOS SwiftUI app, macOS CLI, later an NDK shell) calls pwlod_run()
// and may pass a probe callback for the things only the OS knows (thermal state,
// process memory footprint). Nothing OS-specific lives on the engine side.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct PwLodProbeSample {
  // Shell maps its OS scale onto 0 nominal / 1 fair / 2 serious / 3 critical.
  // -1 = unknown (e.g. a desktop CLI shell).
  int thermal_state;
  double footprint_mb;   // process physical footprint, -1 unknown
  double avail_mb;       // memory still available to the process, -1 unknown
} PwLodProbeSample;

typedef void (*PwLodProbeFn)(PwLodProbeSample* out, void* ctx);

// octree_dir: holds metadata.json / hierarchy.bin / octree.bin (Potree 2.0)
// out_dir:    results are written here (created by the caller)
// args:       space separated key=value pairs, see pw_lod_bench.cpp ParseArgs
// Returns the path of the result JSON, or a diagnostic string on failure.
const char* pwlod_run(const char* octree_dir, const char* out_dir,
                      const char* args, PwLodProbeFn probe, void* probe_ctx);

#ifdef __cplusplus
}
#endif
