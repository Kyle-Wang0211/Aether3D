// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// orchestrator_bindings.cc — wires the StreamingOrchestrator stages to the real
// on-device ABIs. See orchestrator_bindings.h.
//
// FEATURE MACROS (defined by the build that links the corresponding archive):
//   AETHER_HAS_GPU_SIFT  — task A's GPU extractor (src/gpu/gpu_sift_extractor)
//   AETHER_HAS_SFM       — the COLMAP SfM C ABI + DSP-SIFT CPU extractor
//                          (glomap_vendor: aether_sfm_c.cc + dsp_sift_c.cc)
//
// When a macro is undefined (e.g. the default aether3d_core host build, which
// does NOT link the arm64-only archives), the matching factory returns an empty
// std::function. The orchestrator treats an empty stage as "skip", so callers
// detect the missing stage and fall back. The host TEST harness does NOT use
// these factories — it injects its own mock stages — so it builds and runs
// without any of these archives. These bindings are the PRODUCTION glue.

#include "aether/gpu/orchestrator_bindings.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#if defined(AETHER_HAS_GPU_SIFT)
#include "gpu_sift_extractor.h"  // task A: aether_gpu_sift_* C ABI (src/gpu/)
#endif

#if defined(AETHER_HAS_SFM)
#include "aether_sfm_c.h"
// CPU DSP-SIFT extractor (dsp_sift_c.cc) — caller-allocated, uint8 gray,
// stride-2 {x,y} keypoints, 128-byte RootSIFT descriptors.
extern "C" int aether_dsp_sift_extract(const uint8_t* gray, int width,
                                       int height, int max_features,
                                       float* out_xy, uint8_t* out_desc,
                                       int out_cap, int* out_count);
extern "C" int aether_dsp_sift_extract_threaded(const uint8_t* gray, int width,
                                                int height, int max_features,
                                                int num_threads, float* out_xy,
                                                uint8_t* out_desc, int out_cap,
                                                int* out_count);
#endif

namespace aether {
namespace gpu {

// ─── GPU extractor binding (task A) ──────────────────────────────────────────
ExtractFn make_gpu_extract_fn(int max_features) {
#if defined(AETHER_HAS_GPU_SIFT)
    // One handle per capture session, owned by the closure (shared_ptr with a
    // custom deleter so the std::function stays copyable).
    aether_gpu_sift_handle raw = aether_gpu_sift_init();
    if (!raw) return ExtractFn{};  // no GPU device → caller falls back to CPU
    std::shared_ptr<void> handle(raw, [](void* h) {
        if (h) aether_gpu_sift_free(h);
    });
    return [handle, max_features](const CaptureFrame& f,
                                  FrameFeatures* out) -> bool {
        if (!f.gray || f.width <= 0 || f.height <= 0) return false;
        // Task A's extractor wants float intensity (0..255), row-major.
        const std::size_t n =
            static_cast<std::size_t>(f.width) * f.height;
        std::vector<float> grayf(n);
        for (std::size_t i = 0; i < n; ++i) {
            grayf[i] = static_cast<float>(f.gray[i]);
        }
        float* kp = nullptr;          // lib-malloc'd, stride-4 {x,y,sigma,octave}
        unsigned char* desc = nullptr;  // lib-malloc'd, 128*count
        unsigned int count = 0;
        const int rc = aether_gpu_sift_extract(handle.get(), grayf.data(),
                                               f.width, f.height, &kp, &desc,
                                               &count);
        if (rc != 0) {
            std::free(kp);
            std::free(desc);
            return false;
        }
        int n_kp = static_cast<int>(count);
        if (max_features > 0 && n_kp > max_features) n_kp = max_features;
        out->count = n_kp;
        out->xy.resize(static_cast<std::size_t>(n_kp) * 2);
        out->desc.resize(static_cast<std::size_t>(n_kp) * 128);
        // Repack stride-4 {x,y,sigma,octave} → orchestrator's stride-2 {x,y}.
        for (int i = 0; i < n_kp; ++i) {
            out->xy[2 * i] = kp ? kp[i * 4 + 0] : 0.f;
            out->xy[2 * i + 1] = kp ? kp[i * 4 + 1] : 0.f;
        }
        if (desc) {
            std::memcpy(out->desc.data(), desc,
                        static_cast<std::size_t>(n_kp) * 128);
        }
        std::free(kp);
        std::free(desc);
        return n_kp > 0;
    };
#else
    (void)max_features;
    return ExtractFn{};  // GPU extractor not linked in this build
#endif
}

// ─── CPU DSP-SIFT extractor binding (fallback / placeholder) ─────────────────
ExtractFn make_cpu_extract_fn(int max_features, int num_threads) {
#if defined(AETHER_HAS_SFM)
    const int caps = max_features > 0 ? max_features : 2048;
    return [caps, num_threads](const CaptureFrame& f,
                               FrameFeatures* out) -> bool {
        if (!f.gray || f.width <= 0 || f.height <= 0) return false;
        out->xy.assign(static_cast<std::size_t>(caps) * 2, 0.f);
        out->desc.assign(static_cast<std::size_t>(caps) * 128, 0);
        int n = 0;
        int rc;
        if (num_threads == 1) {
            rc = aether_dsp_sift_extract(f.gray, f.width, f.height, caps,
                                         out->xy.data(), out->desc.data(), caps,
                                         &n);
        } else {
            rc = aether_dsp_sift_extract_threaded(f.gray, f.width, f.height, caps,
                                                  num_threads, out->xy.data(),
                                                  out->desc.data(), caps, &n);
        }
        if (rc != 0 || n <= 0) return false;
        out->count = n;
        out->xy.resize(static_cast<std::size_t>(n) * 2);
        out->desc.resize(static_cast<std::size_t>(n) * 128);
        return true;
    };
#else
    (void)max_features;
    (void)num_threads;
    return ExtractFn{};
#endif
}

// ─── SfM ingest binding ──────────────────────────────────────────────────────
IngestFn make_sfm_ingest_fn(const char* db_path, int max_features,
                            int k_neighbors, float match_max_ratio) {
#if defined(AETHER_HAS_SFM)
    aether_sfm_options_t opts;
    aether_sfm_options_default(&opts);
    if (max_features > 0) opts.max_features = max_features;
    if (k_neighbors > 0) opts.k_neighbors = k_neighbors;
    if (match_max_ratio > 0) opts.match_max_ratio = match_max_ratio;

    aether_sfm_session_t* raw = nullptr;
    if (aether_sfm_create(db_path, &opts, &raw) != AETHER_SFM_OK || !raw) {
        return IngestFn{};  // simulator stub / db failure → no real ingest
    }
    std::shared_ptr<aether_sfm_session_t> session(raw, [](aether_sfm_session_t* s) {
        if (s) aether_sfm_free(s);
    });

    return [session](const CaptureFrame& f, const FrameFeatures& feats,
                     CloudSnapshot* out) -> bool {
        (void)feats;  // aether_sfm_add_frame re-extracts internally in v1; when
                      // the SfM ABI grows a "add pre-extracted features" entry
                      // this passes feats.xy/desc straight through (no re-extract).
        int frame_id = -1;
        const aether_sfm_result_t rc = aether_sfm_add_frame(
            session.get(), f.gray, f.width, f.height, f.fx, f.fy, f.cx, f.cy,
            f.has_pose ? f.pose_qwxyz : nullptr,
            f.has_pose ? f.pose_t : nullptr, &frame_id);
        if (rc != AETHER_SFM_OK) return false;

        // Per-frame LOCAL solve so the cloud GROWS during capture. finalize()
        // with defer_global_ba=true is LOCAL-BA-only (~640ms device); the heavy
        // O(N) global BA is deferred to post-capture (aether_sfm_finalize_async).
        char json[256] = {0};
        const aether_sfm_result_t frc =
            aether_sfm_finalize(session.get(), json, sizeof(json));
        // NOT_REGISTERED early in the session (before the initial pair) is
        // normal — the cloud is just empty so far; keep streaming.
        if (frc != AETHER_SFM_OK && frc != AETHER_SFM_ERR_NOT_REGISTERED) {
            return false;
        }

        // Read back the growing sparse cloud for the UI.
        if (out) {
            aether_sfm_point_t* pts = nullptr;
            int n = 0;
            if (aether_sfm_get_points(session.get(), &pts, &n) ==
                    AETHER_SFM_OK &&
                n >= 0) {
                out->points.resize(static_cast<std::size_t>(n));
                for (int i = 0; i < n; ++i) {
                    out->points[i].x = pts[i].x;
                    out->points[i].y = pts[i].y;
                    out->points[i].z = pts[i].z;
                    out->points[i].r = pts[i].r;
                    out->points[i].g = pts[i].g;
                    out->points[i].b = pts[i].b;
                    out->points[i]._pad = 0;
                }
            }
            aether_sfm_points_free(pts);
            out->last_frame_index = f.frame_index;
            // registered count via poses (count-only query).
            int pose_total = 0;
            aether_sfm_get_poses(session.get(), nullptr, 0, &pose_total);
            out->registered_frames = pose_total;
        }
        return frc == AETHER_SFM_OK;
    };
#else
    (void)db_path;
    (void)max_features;
    (void)k_neighbors;
    (void)match_max_ratio;
    return IngestFn{};
#endif
}

}  // namespace gpu
}  // namespace aether
