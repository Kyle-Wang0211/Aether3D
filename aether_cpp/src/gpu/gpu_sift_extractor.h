// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// gpu_sift_extractor.h — reusable batched GPU DSP-SIFT extractor with a ONE-TIME
// pipeline + buffer cache.
//
// ROOT-FIX for the per-frame Tint-recompilation bug: the validated batched
// pipeline (bench/extract_fullgpu_batched.cc, 240ms/frame M3, reproj 1.0 /
// 329MB / 8192 pts) compiles its 11 WebGPU compute pipelines via
// CreateComputePipeline. The fused/prof harnesses paid that ~1334ms Tint
// compile INSIDE the per-frame loop (every frame). Here:
//
//   GpuSiftExtractor::init()  — creates the Dawn device ONCE, Tint-compiles ALL
//     11 compute pipelines ONCE, and allocates the size-stable resident buffers
//     (kp/cand/args caps etc.) ONCE. NO per-frame pipeline creation.
//   GpuSiftExtractor::extract(gray,w,h) — per-frame: REUSES the cached pipelines
//     and resident buffers; runs the single-command-buffer + indirect-dispatch
//     pipeline; ONE final readback. The gss pyramid is allocated lazily on the
//     first frame of a given (w,h) and cached for all subsequent same-size
//     frames (its size is image-dependent, so it is keyed by dimensions).
//
// The KERNELS, SHADERS, and MATH are byte-identical to extract_fullgpu_batched.cc
// — only host-side resource lifetime moves from per-frame to init().
//
// A clean C ABI (shared verbatim with the streaming-loop task) wraps the class.

#ifndef AETHER_GPU_SIFT_EXTRACTOR_H_
#define AETHER_GPU_SIFT_EXTRACTOR_H_

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus

#include <memory>
#include <vector>

namespace aether {
namespace gpu {

// Global running count of CreateComputePipeline (Tint compile) calls this module
// has issued. init() raises it by exactly 11; extract() NEVER touches it. A
// verifier reads this before/after each extract() to prove the per-frame Tint
// cost is zero (the root-fix for the per-frame recompilation bug).
extern long g_pipeline_compile_count;

// Per-frame timing + memory breakdown (execution-only; NO pipeline compile in
// extract() — that is paid once in init()).
struct GpuSiftTimings {
  // Host-side VLFeat scale-space build (vl_covdet_put_image): supplies the seed
  // level + scale-space geometry/sigmas that the GPU pyramid build consumes.
  // This is a per-image host cost, separate from the GPU pipeline (gpu_total_ms
  // below). The validated 240ms/frame number is the GPU pipeline (gpu_total_ms).
  double vlfeat_gss_ms = 0;
  double gss_ms = 0;             // GPU resident-pyramid build (1 cmd buffer)
  double detect_refine_ms = 0;
  double suppress_ms = 0;
  double affine_ms = 0;
  double orient_ms = 0;
  double desc_ms = 0;
  double host_restruct_ms = 0;
  double gpu_total_ms = 0;   // GPU pipeline B.1-B.7 (the ~240ms target number)
  double total_ms = 0;       // full extract() wall-clock (= vlfeat_gss + gpu_total)
  double gss_bytes = 0;      // resident gss pyramid bytes
  double desc_peak_bytes = 0;
  double peak_bytes = 0;     // gss + descriptor-stage peak
  // Pipeline-compile cost OBSERVED during this call. Should be ~0 for every
  // extract() call (pipelines are cached in init()); init() records its own
  // one-time compile cost in init_compile_ms below.
  double pipeline_compile_ms = 0;
  int    pipeline_compiles = 0;   // count of CreateComputePipeline during this call
};

// Per-frame output. Frames are in image (pixel) coordinates; descriptors are
// the 128-byte UBC-reordered DSP-SIFT descriptors (one row per keypoint).
struct GpuSiftFrame {
  std::size_t count = 0;
  std::vector<float> x;        // [count]
  std::vector<float> y;        // [count]
  std::vector<float> sigma;    // [count]
  std::vector<int>   octave;   // [count]
  std::vector<uint8_t> descriptors;  // [count * 128]
  GpuSiftTimings timings;
};

// Reusable extractor. init() once; extract() per-frame; destructor frees.
class GpuSiftExtractor {
 public:
  struct Config {
    int    octave_resolution = 3;
    double peak_threshold = 0.02 / 3.0;
    double edge_threshold = 10.0;
    int    max_num_features = 8192;
    double tol = 0.5;
    // Absolute path to the directory containing shaders/wgsl/*.wgsl (the
    // aether_cpp root). If empty, paths are resolved relative to CWD.
    const char* shader_root = nullptr;
    // Optional disk-backed Dawn persistent pipeline cache. When non-null, the
    // 11 WGSL→Tint→MSL→Metal pipeline compiles (the ~31.7s A16 first-launch
    // cost) are serialized to this dir and reloaded on a later launch, so a
    // warm start skips the recompile. cache_isolation_key is a stable version
    // string ("gpusift-v1") — bump it to invalidate when shaders change.
    const char* cache_dir = nullptr;
    const char* cache_isolation_key = nullptr;
  };

  GpuSiftExtractor();
  ~GpuSiftExtractor();
  GpuSiftExtractor(const GpuSiftExtractor&) = delete;
  GpuSiftExtractor& operator=(const GpuSiftExtractor&) = delete;

  // Create the Dawn device ONCE, compile ALL 11 pipelines ONCE, allocate the
  // size-stable resident buffers ONCE. Returns false on any failure.
  bool init(const Config& cfg);

  // One-time compile cost measured inside init() (Tint compile of all 11
  // pipelines). Valid after a successful init().
  double init_compile_ms() const;

  // Persistent-cache telemetry (valid after init() when cache_dir was set).
  // cache_load_hits() = #pipeline blobs Dawn loaded from disk this launch
  // (>0 ⇒ warm start). cache_store_count() = #blobs written this launch.
  long cache_load_hits() const;
  long cache_store_count() const;

  // Per-frame extraction. REUSES the cached pipelines + buffers. `gray` is a
  // row-major float image (intensity 0..255), w*h elements. Returns false on
  // failure (e.g. init() not called).
  bool extract(const float* gray, int w, int h, GpuSiftFrame* out);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace gpu
}  // namespace aether

#endif  // __cplusplus

// ════════════════════════════════════════════════════════════════════════════
//  C ABI — shared VERBATIM with the concurrent streaming-loop task.
// ════════════════════════════════════════════════════════════════════════════
#ifdef __cplusplus
extern "C" {
#endif

typedef void* aether_gpu_sift_handle;

// Create + init an extractor with default config. Returns NULL on failure.
aether_gpu_sift_handle aether_gpu_sift_init(void);

// Per-frame extract. `gray` = row-major float intensity image (0..255), w*h
// elements. On success returns 0 and:
//   *out_kp    -> malloc'd float[count*4] interleaved {x,y,sigma,octave}.
//   *out_desc  -> malloc'd uint8_t[count*128] descriptors.
//   *out_count -> keypoint count.
// The caller owns *out_kp and *out_desc and must free() them. Returns non-zero
// on failure (any out_* may be left untouched).
int aether_gpu_sift_extract(aether_gpu_sift_handle handle, const float* gray,
                            int w, int h, float** out_kp, unsigned char** out_desc,
                            unsigned int* out_count);

// Destroy an extractor created by aether_gpu_sift_init().
void aether_gpu_sift_free(aether_gpu_sift_handle handle);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_GPU_SIFT_EXTRACTOR_H_
