// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// orchestrator_bindings.h — production wiring of the StreamingOrchestrator
// stages to the real on-device ABIs.
//
// The orchestrator (streaming_orchestrator.h) is deliberately decoupled: it
// takes the two stages as std::function so the per-frame loop / bounded queue /
// pipelining logic is testable host-side. These factory functions build those
// std::functions from the REAL device ABIs:
//
//   make_gpu_extract_fn()  → wraps aether_gpu_sift_extract
//                            (src/gpu/gpu_sift_extractor.h, task A — the GPU
//                             DSP-SIFT extractor: ~240ms M3 / ~697ms A16).
//                            Handles the impedance match the contract requires:
//                              - uint8 gray → float intensity (task A wants float*)
//                              - lib-malloc'd, stride-4 {x,y,sigma,octave} kp →
//                                the orchestrator's stride-2 {x,y} xy buffer
//                              - frees task A's malloc'd out_kp / out_desc.
//
//   make_cpu_extract_fn()  → wraps aether_dsp_sift_extract / the threaded
//                            variant (dsp_sift_c.cc). The fallback the
//                            orchestrator uses when the GPU device is
//                            unavailable, AND the placeholder the host harness
//                            can use before task A's module is wired into a
//                            given build. Same FrameFeatures output shape.
//
//   make_sfm_ingest_fn()   → wraps the SfM C ABI (aether_sfm_c.h):
//                            aether_sfm_add_frame (write kp/desc + ARKit-pose-
//                            prior guided match) → a per-frame LOCAL solve →
//                            aether_sfm_get_points → CloudSnapshot for the UI.
//                            defer_global_ba=true keeps the per-frame cost
//                            LOCAL-BA-only (~640ms device).
//
// All three return an empty std::function on a build where the underlying ABI is
// not linked (e.g. simulator), so the caller can detect "no real stage here" and
// fall back. The device build links the real implementations.

#ifndef AETHER_GPU_ORCHESTRATOR_BINDINGS_H
#define AETHER_GPU_ORCHESTRATOR_BINDINGS_H

#ifdef __cplusplus

#include "aether/gpu/streaming_orchestrator.h"

namespace aether {
namespace gpu {

// Opaque GPU extractor handle (aether_gpu_sift_handle == void*). Owned by the
// returned ExtractFn closure; freed when the closure is destroyed.
//
// Returns an empty ExtractFn if aether_gpu_sift_init() returns NULL (no GPU
// device). max_features clamps the keypoint count copied forward.
ExtractFn make_gpu_extract_fn(int max_features);

// CPU DSP-SIFT extractor (aether_dsp_sift_extract). num_threads<=0 → the
// threaded variant with hardware concurrency; 1 → the serial path. Always
// available wherever dsp_sift_c.cc is linked; the host harness can use this as
// the placeholder stage before/without task A's GPU module.
ExtractFn make_cpu_extract_fn(int max_features, int num_threads);

// SfM ingest stage bound to the streaming SfM session (aether_sfm_session_t*).
// The returned IngestFn owns the session; it calls aether_sfm_add_frame per
// frame (ARKit pose carried in CaptureFrame is the matching prior), runs the
// per-frame local solve, and reads back the growing cloud via
// aether_sfm_get_points into the CloudSnapshot. `db_path` is the private sqlite
// db the session accumulates into. Returns empty IngestFn if the session cannot
// be created (e.g. simulator stub returns UNSUPPORTED).
IngestFn make_sfm_ingest_fn(const char* db_path, int max_features,
                            int k_neighbors, float match_max_ratio);

}  // namespace gpu
}  // namespace aether

#endif  // __cplusplus
#endif  // AETHER_GPU_ORCHESTRATOR_BINDINGS_H
