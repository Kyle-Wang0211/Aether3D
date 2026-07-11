// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "sift_extract_dawn.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#ifdef AETHER_WGSL_DIR
#include <fstream>
#include <sstream>
#else
#include "aether/shaders/wgsl_sources.h"
#include <string_view>
#endif

namespace aether {
namespace tools {

namespace {

// The 8 production passes. Host parity/e2e benches define AETHER_WGSL_DIR and
// read from the shaders/wgsl tree; iOS/production uses the baked-in
// aether::shaders::*_wgsl symbols (zero filesystem dependency). Single source
// of truth on both — the .wgsl files — so host and device cannot diverge.
std::string load_wgsl(const char* filename) {
#ifdef AETHER_WGSL_DIR
    const std::string path = std::string(AETHER_WGSL_DIR) + "/" + filename;
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::cerr << "[SiftExtractDawn] cannot open WGSL: " << path << '\n';
        std::abort();
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
#else
    using namespace aether::shaders;
    const std::string_view f(filename);
    if (f == "sift_gray_to_f32.wgsl")         return std::string(sift_gray_to_f32_wgsl);
    if (f == "sift_gss_blur.wgsl")            return std::string(sift_gss_blur_wgsl);
    if (f == "sift_gss_resample.wgsl")        return std::string(sift_gss_resample_wgsl);
    if (f == "sift_dog_detect.wgsl")          return std::string(sift_dog_detect_wgsl);
    if (f == "sift_nonextrema_suppress.wgsl") return std::string(sift_nonextrema_suppress_wgsl);
    if (f == "sift_affine_shape.wgsl")        return std::string(sift_affine_shape_wgsl);
    if (f == "sift_orientation.wgsl")         return std::string(sift_orientation_wgsl);
    if (f == "sift_dsp_descriptor.wgsl")      return std::string(sift_dsp_descriptor_wgsl);
    if (f == "sift_dsp_descriptor_f16.wgsl")  return std::string(sift_dsp_descriptor_f16_wgsl);
    if (f == "sift_dsp_descriptor_par.wgsl")  return std::string(sift_dsp_descriptor_par_wgsl);
    if (f == "sift_dsp_mean.wgsl")            return std::string(sift_dsp_mean_wgsl);
    std::cerr << "[SiftExtractDawn] unknown WGSL pass: " << filename << '\n';
    std::abort();
#endif
}

// Read `n` u32 from a Storage|CopySrc buffer to host.
std::vector<uint32_t> read_u32(DawnKernelHarness& h, const wgpu::Buffer& b,
                               size_t n) {
    const size_t bytes = n * sizeof(uint32_t);
    wgpu::Buffer st = h.alloc_staging_for_readback(bytes);
    h.copy_to_staging(b, st, bytes);
    std::vector<uint8_t> raw = h.readback(st, bytes);
    std::vector<uint32_t> out(n);
    std::memcpy(out.data(), raw.data(), bytes);
    return out;
}

}  // namespace

bool SiftExtractDawn::extract(DawnKernelHarness& harness, const uint8_t* gray,
                              int width, int height, int max_features,
                              Result* out) {
    if (gray == nullptr || width < 2 || height < 2 || out == nullptr) {
        return false;
    }

    // Per-stage timing (env SED_TIMING). Each mark() prints ms since the prev
    // mark — to attribute the per-frame cost across pyramid / detect / suppress /
    // affine / orient / descriptor / readback, and isolate the host-repack
    // round-trips (the GPU-side-compaction optimization target).
    const bool timing = std::getenv("SED_TIMING") != nullptr;
    auto t_prev = std::chrono::high_resolution_clock::now();
    auto mark = [&](const char* label) {
        if (!timing) return;
        auto now = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(now - t_prev).count();
        std::printf("  [SED] %-22s %.1f ms\n", label, ms);
        std::fflush(stdout);
        t_prev = now;
    };

    // ── GSS pyramid (resident) + packed all-octave buffer ──
    SiftPyramidDawn pyr;
    if (!pyr.build(harness, gray, width, height)) {
        std::cerr << "[SiftExtractDawn] pyramid build failed\n";
        return false;
    }
    mark("pyramid build");
    std::vector<SiftPyramidDawn::LevelMeta> meta;
    wgpu::Buffer packed = pyr.pack_levels(harness, &meta);
    wgpu::Buffer meta_buf =
        harness.upload(meta.data(), meta.size() * sizeof(SiftPyramidDawn::LevelMeta),
                       wgpu::BufferUsage::Storage);
    mark("pack_levels");

    const float base_scale = static_cast<float>(SiftPyramidDawn::base_scale());
    const float peak = static_cast<float>(peak_threshold());

    // ════════════════ Stage B+: detect over all octaves ════════════════
    uint32_t zero = 0u;
    wgpu::Buffer det_counter = harness.upload(
        &zero, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<uint32_t> det_init(static_cast<size_t>(kDetectCap) * kKpStride, 0u);
    wgpu::Buffer det_buf = harness.upload(
        det_init.data(), det_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    struct DetParams {
        uint32_t width, height, cap, octave;
        float peak_threshold, edge_threshold, base_scale, oct_resolution;
    };
    wgpu::ComputePipeline pipe_detect =
        harness.load_compute(load_wgsl("sift_dog_detect.wgsl"));
    // Batch all octave detect passes into ONE submit (was one sync wait per
    // octave). Every octave atomic-appends to the shared det_buf/det_counter;
    // the keypoint SET is identical (the append order was already
    // atomic-nondeterministic), only the per-octave sync waits are removed.
    harness.begin_batch();
    for (int o = pyr.first_octave(); o <= pyr.last_octave(); ++o) {
        const int ow = pyr.octave_width(o);
        const int oh = pyr.octave_height(o);
        if (ow < 3 || oh < 3) continue;
        DetParams P{static_cast<uint32_t>(ow), static_cast<uint32_t>(oh),
                    kDetectCap, static_cast<uint32_t>(o), peak,
                    static_cast<float>(kEdgeThreshold), base_scale,
                    static_cast<float>(kOctaveResolution)};
        wgpu::Buffer p_buf =
            harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
        std::vector<wgpu::Buffer> bind;
        for (int s = SiftPyramidDawn::kOctaveFirstSub;
             s <= SiftPyramidDawn::kOctaveLastSub; ++s)
            bind.push_back(pyr.level_buffer(o, s));
        bind.push_back(det_counter);
        bind.push_back(det_buf);
        bind.push_back(p_buf);
        harness.dispatch_batched(pipe_detect, bind,
                                 static_cast<uint32_t>((ow + 7) / 8),
                                 static_cast<uint32_t>((oh + 7) / 8), 3u);
    }
    harness.end_batch();
    uint32_t n_detect = read_u32(harness, det_counter, 1)[0];
    mark("detect (all oct)");
    if (n_detect > kDetectCap) {
        std::cerr << "[SiftExtractDawn] detect overflow " << n_detect << " > "
                  << kDetectCap << " (fallback)\n";
        return false;
    }

    // ════════════════ Stage B++: non-extrema suppression ════════════════
    std::vector<uint32_t> keep_init(n_detect, 1u);
    wgpu::Buffer keep_buf = harness.upload(
        keep_init.data(), keep_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    {
        struct SupParams {
            uint32_t count;
            float tol;
        } sp{n_detect, static_cast<float>(kSuppressTol)};
        wgpu::Buffer sp_buf =
            harness.upload(&sp, sizeof(sp), wgpu::BufferUsage::Uniform);
        wgpu::ComputePipeline pipe_sup =
            harness.load_compute(load_wgsl("sift_nonextrema_suppress.wgsl"));
        harness.dispatch(pipe_sup, {det_buf, keep_buf, sp_buf},
                         (n_detect + 63u) / 64u);
    }

    // Read detect records + keep flags; compact on host into the affine input
    // (the affine kernel needs [x,y,sigma] in slots 0,1,2 — the detect record
    // already has that, so compaction is a straight copy of kept rows).
    std::vector<uint32_t> det_recs =
        read_u32(harness, det_buf, static_cast<size_t>(n_detect) * kKpStride);
    std::vector<uint32_t> keep = read_u32(harness, keep_buf, n_detect);
    mark("suppress+readback");

    std::vector<uint32_t> aff_in;  // KP_STRIDE-packed kept detect records
    aff_in.reserve(static_cast<size_t>(n_detect) * kKpStride);
    for (uint32_t i = 0; i < n_detect; ++i) {
        if (!keep[i]) continue;
        const uint32_t* r = det_recs.data() + static_cast<size_t>(i) * kKpStride;
        for (uint32_t w = 0; w < kKpStride; ++w) aff_in.push_back(r[w]);
    }
    const uint32_t n_kept = static_cast<uint32_t>(aff_in.size() / kKpStride);
    if (n_kept == 0) {
        out->count = 0;
        return true;
    }

    // ════════════════ Stage C: affine shape ════════════════
    wgpu::Buffer aff_in_buf =
        harness.upload(aff_in.data(), aff_in.size() * sizeof(uint32_t),
                       wgpu::BufferUsage::Storage);
    std::vector<float> ell_init(static_cast<size_t>(n_kept) * 5, 0.0f);
    wgpu::Buffer ell_buf = harness.upload(
        ell_init.data(), ell_init.size() * sizeof(float),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    {
        struct AffParams {
            uint32_t count;
            int first_octave, last_octave, oct_res;
            float base_scale;
            int oct_first_sub, oct_last_sub;
            uint32_t levels_per_oct;
        } P{n_kept, 0, pyr.last_octave(), kOctaveResolution, base_scale,
            SiftPyramidDawn::kOctaveFirstSub, SiftPyramidDawn::kOctaveLastSub,
            static_cast<uint32_t>(SiftPyramidDawn::kLevelsPerOctave)};
        wgpu::Buffer p_buf =
            harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
        wgpu::ComputePipeline pipe_aff =
            harness.load_compute(load_wgsl("sift_affine_shape.wgsl"));
        harness.dispatch(pipe_aff, {packed, meta_buf, aff_in_buf, ell_buf, p_buf},
                         n_kept, 1u, 1u);
    }
    std::vector<uint32_t> ell_raw =
        read_u32(harness, ell_buf, static_cast<size_t>(n_kept) * 5);
    mark("affine+readback");

    // Repack: merge the affine ellipse (a11,a12,a21,a22) into the kp record at
    // slots [2..5], preserving x,y (slots 0,1) and o,s (slots 5,6 of the detect
    // record). Detect record: [x,y,sigma,peak,edge,o,s,0] → oriented-input
    // record: [x,y,a11,a12,a21,a22,o,s].  ell buffer: [a11,a12,a21,a22,ok].
    std::vector<uint32_t> ori_in(static_cast<size_t>(n_kept) * kKpStride, 0u);
    bool nan_seen = false;
    for (uint32_t i = 0; i < n_kept; ++i) {
        const uint32_t* d = aff_in.data() + static_cast<size_t>(i) * kKpStride;
        const uint32_t* e = ell_raw.data() + static_cast<size_t>(i) * 5;
        float a11, a12, a21, a22;
        std::memcpy(&a11, &e[0], 4);
        std::memcpy(&a12, &e[1], 4);
        std::memcpy(&a21, &e[2], 4);
        std::memcpy(&a22, &e[3], 4);
        if (std::isnan(a11) || std::isnan(a12) || std::isnan(a21) ||
            std::isnan(a22)) {
            nan_seen = true;
            break;
        }
        uint32_t* r = ori_in.data() + static_cast<size_t>(i) * kKpStride;
        r[0] = d[0];  // x
        r[1] = d[1];  // y
        std::memcpy(&r[2], &a11, 4);
        std::memcpy(&r[3], &a12, 4);
        std::memcpy(&r[4], &a21, 4);
        std::memcpy(&r[5], &a22, 4);
        r[6] = d[5];  // octave (detect slot 5)
        r[7] = d[6];  // s (detect slot 6)
    }
    if (nan_seen) {
        std::cerr << "[SiftExtractDawn] NaN affine ellipse (fallback)\n";
        return false;
    }

    // ════════════════ Stage D: orientation (1→K) ════════════════
    wgpu::Buffer ori_in_buf =
        harness.upload(ori_in.data(), ori_in.size() * sizeof(uint32_t),
                       wgpu::BufferUsage::Storage);
    wgpu::Buffer ori_counter = harness.upload(
        &zero, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<uint32_t> ori_out_init(static_cast<size_t>(kOrientCap) * kKpStride,
                                       0u);
    wgpu::Buffer ori_out_buf = harness.upload(
        ori_out_init.data(), ori_out_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<float> dbg_init(static_cast<size_t>(kOrientCap) * 2, 0.0f);
    wgpu::Buffer dbg_buf =
        harness.upload(dbg_init.data(), dbg_init.size() * sizeof(float),
                       wgpu::BufferUsage::Storage);
    {
        struct OriParams {
            uint32_t count;
            int fo, lo, res;
            float base;
            int ofs, ols;
            uint32_t lpo;
        } P{n_kept, 0, pyr.last_octave(), kOctaveResolution, base_scale,
            SiftPyramidDawn::kOctaveFirstSub, SiftPyramidDawn::kOctaveLastSub,
            static_cast<uint32_t>(SiftPyramidDawn::kLevelsPerOctave)};
        wgpu::Buffer p_buf =
            harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
        wgpu::ComputePipeline pipe_ori =
            harness.load_compute(load_wgsl("sift_orientation.wgsl"));
        harness.dispatch(pipe_ori,
                         {packed, meta_buf, ori_in_buf, ori_out_buf, ori_counter,
                          dbg_buf, p_buf},
                         n_kept, 1u, 1u);
    }
    uint32_t n_oriented = read_u32(harness, ori_counter, 1)[0];
    mark("orient (1->K)");
    if (std::getenv("SED_DEBUG")) {
        std::cerr << "[SiftExtractDawn] n_detect=" << n_detect
                  << " n_kept(suppress)=" << n_kept
                  << " n_oriented=" << n_oriented << "\n";
    }
    if (n_oriented > kOrientCap) {
        std::cerr << "[SiftExtractDawn] orient overflow " << n_oriented << " > "
                  << kOrientCap << " (fallback)\n";
        return false;
    }

    // ════════════════ COLMAP clamp BEFORE descriptor (sift.cc:403-444) ════════
    // Read the oriented kp records, sort the 1→K-expanded set by (octave desc,
    // scale desc), apply the per-(octave,scale)-group cap rule, and keep only the
    // ≤max_features survivors. The descriptor stage then runs over THIS subset —
    // the dominant cost shrinks from ~21000-27000 to ~max_features keypoints. The
    // surviving descriptors are bit-identical (deterministic per-keypoint); the
    // set is exactly COLMAP's. Repack the survivors into a dense buffer.
    std::vector<uint32_t> ori_all = read_u32(
        harness, ori_out_buf, static_cast<size_t>(n_oriented) * kKpStride);
    uint32_t n_desc = n_oriented;
    wgpu::Buffer desc_in_buf = ori_out_buf;
    if (max_features > 0 && n_oriented > static_cast<uint32_t>(max_features)) {
        std::vector<int> idx(n_oriented);
        for (uint32_t i = 0; i < n_oriented; ++i) idx[i] = static_cast<int>(i);
        auto oct_of = [&](int i) {
            int o; std::memcpy(&o, &ori_all[static_cast<size_t>(i) * kKpStride + 6], 4); return o;
        };
        auto scl_of = [&](int i) {
            int s; std::memcpy(&s, &ori_all[static_cast<size_t>(i) * kKpStride + 7], 4); return s;
        };
        std::sort(idx.begin(), idx.end(), [&](int a, int b) {
            if (oct_of(a) != oct_of(b)) return oct_of(a) > oct_of(b);
            return scl_of(a) > scl_of(b);
        });
        // colmap clamp rule (sift.cc:430-439): emit until size>=max AND the next
        // kp begins a new (octave,scale) group.
        constexpr int kMaxOctaveResolution = 1000;
        int prev_os = INT32_MAX;
        std::vector<uint32_t> clamped;
        clamped.reserve(static_cast<size_t>(max_features + 64) * kKpStride);
        uint32_t kept = 0;
        for (uint32_t n = 0; n < n_oriented; ++n) {
            const int i = idx[n];
            const uint32_t* r = ori_all.data() + static_cast<size_t>(i) * kKpStride;
            for (uint32_t w = 0; w < kKpStride; ++w) clamped.push_back(r[w]);
            ++kept;
            const int os = oct_of(i) * kMaxOctaveResolution + scl_of(i);
            if (os != prev_os && kept >= static_cast<uint32_t>(max_features)) break;
            prev_os = os;
        }
        n_desc = kept;
        desc_in_buf = harness.upload(clamped.data(),
                                     clamped.size() * sizeof(uint32_t),
                                     wgpu::BufferUsage::Storage);
        // keep ori_all as the survivor metadata for Result assembly below.
        ori_all.assign(clamped.begin(), clamped.end());
    }
    mark("clamp (pre-desc)");

    // ════════════════ Stage E: DSP descriptor (on the clamped set) ════════════
    const uint32_t n_oriented_full = n_oriented;
    (void)n_oriented_full;
    n_oriented = n_desc;  // descriptor + readback + Result now operate on the clamp
    struct DescParams {
        uint32_t count;
        int fo, lo, res;
        float base;
        int ofs, ols;
        uint32_t lpo;
        float dmin, dstep;
        uint32_t p0, p1;
    } DP{n_oriented,
         0,
         pyr.last_octave(),
         kOctaveResolution,
         base_scale,
         SiftPyramidDawn::kOctaveFirstSub,
         SiftPyramidDawn::kOctaveLastSub,
         static_cast<uint32_t>(SiftPyramidDawn::kLevelsPerOctave),
         kDspMinScale,
         (kDspMaxScale - kDspMinScale) / kDspNumScales,
         0u,
         0u};
    wgpu::Buffer rd_buf;
    {
        std::vector<float> rd_init(static_cast<size_t>(n_oriented) * 128, 0.0f);
        rd_buf = harness.upload(rd_init.data(), rd_init.size() * sizeof(float),
                                wgpu::BufferUsage::Storage |
                                    wgpu::BufferUsage::CopySrc);
        wgpu::Buffer p_buf =
            harness.upload(&DP, sizeof(DP), wgpu::BufferUsage::Uniform);

        // Descriptor path: the SERIAL single-workgroup-per-kp kernel is the
        // DEFAULT — it is fastest on A16 (982→682ms). The ③ scale-parallel path
        // (one workgroup per (kp,scale) + a mean pass) was implemented and proven
        // BIT-IDENTICAL (clamp_parity ③-vs-serial: 21002/21002 byte-exact), but
        // measured 44% SLOWER on A16: the A16 was already saturated at ~12k
        // workgroups, so 10× more workgroups + 61MB of scale_desc global traffic
        // (write + mean re-read) outweighed any parallelism. Kept behind
        // SED_PARALLEL_DESC for other GPUs / future profiling, OFF by default.
        if (std::getenv("SED_PARALLEL_DESC") != nullptr) {
            const uint32_t n_sd =
                static_cast<uint32_t>(n_oriented) * kDspNumScales;
            std::vector<float> sd_init(static_cast<size_t>(n_sd) * 128, 0.0f);
            wgpu::Buffer scale_desc = harness.upload(
                sd_init.data(), sd_init.size() * sizeof(float),
                wgpu::BufferUsage::Storage);
            // 2D dispatch: n_sd (~119k) exceeds the 65535 per-dim limit. Split
            // into (groups_x, ceil(n_sd/groups_x)); the kernel re-flattens via
            // P.groups_x (DP.p0). 32768 keeps both dims well under the cap.
            const uint32_t groups_x = 32768u;
            const uint32_t groups_y = (n_sd + groups_x - 1u) / groups_x;
            DP.p0 = groups_x;
            wgpu::Buffer p_buf2 =
                harness.upload(&DP, sizeof(DP), wgpu::BufferUsage::Uniform);
            wgpu::ComputePipeline pipe_par =
                harness.load_compute(load_wgsl("sift_dsp_descriptor_par.wgsl"));
            harness.dispatch(pipe_par,
                             {packed, meta_buf, desc_in_buf, scale_desc, p_buf2},
                             groups_x, groups_y, 1u);
            struct MeanParams { uint32_t count; } MP{n_oriented};
            wgpu::Buffer mp_buf =
                harness.upload(&MP, sizeof(MP), wgpu::BufferUsage::Uniform);
            wgpu::ComputePipeline pipe_mean =
                harness.load_compute(load_wgsl("sift_dsp_mean.wgsl"));
            harness.dispatch(pipe_mean, {scale_desc, rd_buf, mp_buf},
                             (n_oriented * 128u + 63u) / 64u, 1u, 1u);
        } else {
            // serial (one workgroup per kp, 10 scales looped). PRODUCTION
            // DEFAULT = f16 descriptor variant WHEN the device advertises
            // ShaderF16 (Apple Silicon / A16): ~10% faster (1578→1425ms on A16),
            // cosine 0.99998 (the CPU L1Root + round(512) quantization absorbs
            // the f16 round-off — dsp_descriptor_parity-validated ≥0.998). Adreno
            // (no ShaderF16 / f16-crash history) → f32, bit-faithful. Overrides:
            //   SED_FORCE_F32=1 → force the f32 kernel (parity / A-B reference)
            //   SED_F16_DESC=1  → force f16 even if has_f16() misreports
            const bool want_f16 =
                (harness.has_f16() && std::getenv("SED_FORCE_F32") == nullptr) ||
                std::getenv("SED_F16_DESC") != nullptr;
            const char* desc_shader = want_f16
                ? "sift_dsp_descriptor_f16.wgsl"
                : "sift_dsp_descriptor.wgsl";
            wgpu::ComputePipeline pipe_desc =
                harness.load_compute(load_wgsl(desc_shader));
            harness.dispatch(pipe_desc,
                             {packed, meta_buf, desc_in_buf, rd_buf, p_buf},
                             n_oriented, 1u, 1u);
        }
    }
    mark("descriptor");

    // ── readback raw descriptors + oriented kp metadata (the ONLY bulk readback) ──
    const size_t rbytes = static_cast<size_t>(n_oriented) * 128 * sizeof(float);
    wgpu::Buffer rd_st = harness.alloc_staging_for_readback(rbytes);
    harness.copy_to_staging(rd_buf, rd_st, rbytes);
    std::vector<uint8_t> rd_raw = harness.readback(rd_st, rbytes);

    // `ori_all` already holds the kp records the descriptor ran on (the clamped
    // survivors, or the full set when no clamp) — no extra readback needed.
    const std::vector<uint32_t>& ori_recs = ori_all;
    mark("desc readback");

    // ── assemble Result (the clamp, if any, was applied before the descriptor) ──
    out->count = static_cast<int>(n_oriented);
    out->xy.resize(static_cast<size_t>(n_oriented) * 2);
    out->octave.resize(n_oriented);
    out->scale.resize(n_oriented);
    out->raw_desc.resize(static_cast<size_t>(n_oriented) * 128);
    std::memcpy(out->raw_desc.data(), rd_raw.data(), rbytes);
    bool desc_nan = false;
    for (uint32_t i = 0; i < n_oriented; ++i) {
        const uint32_t* r = ori_recs.data() + static_cast<size_t>(i) * kKpStride;
        float x, y;
        std::memcpy(&x, &r[0], 4);
        std::memcpy(&y, &r[1], 4);
        out->xy[2 * i] = x;
        out->xy[2 * i + 1] = y;
        int o, s;
        std::memcpy(&o, &r[6], 4);
        std::memcpy(&s, &r[7], 4);
        out->octave[i] = o;
        out->scale[i] = s;
    }
    // NaN guard on the descriptor (E's atan2(0,0) guard should prevent this, but
    // a cross-stage regression would surface here → fall back).
    for (size_t i = 0; i < out->raw_desc.size(); ++i) {
        if (std::isnan(out->raw_desc[i])) {
            desc_nan = true;
            break;
        }
    }
    if (desc_nan) {
        std::cerr << "[SiftExtractDawn] NaN descriptor (fallback)\n";
        return false;
    }
    return true;
}

}  // namespace tools
}  // namespace aether
