// dsp_sift_gpu_c.cc — GPU C ABI for on-device DSP-SIFT extraction (M2-2).
//
// aether_dsp_sift_extract_gpu(...) has the SAME signature as the CPU
// aether_dsp_sift_extract_threaded (dsp_sift_c.cc:87) and the SAME output
// contract (xy order, 128-d, UBC reorder, RootSIFT round(512v)). It runs the
// full GPU pipeline (SiftExtractDawn), applies the 8192 clamp by (octave,scale)
// descending + the CPU finishing (L1RootNormalize → round(512) u8 →
// VLFeat→UBC). Legacy policy keeps transparent CPU fallback on GPU failure.
// An explicit deterministic selector request never substitutes legacy output:
// GPU failure returns kCanonicalGpuUnavailable (numeric C ABI status 2) with
// out_count cleared.
//
// This is a SEPARATE translation unit from dsp_sift_c.cc: it pulls in Dawn
// (webgpu_cpp.h, C++20, RAII/exceptions) which must not mix with the colmap C
// ABI TU. The finishing math is replicated here (verbatim colmap/feature/utils.cc
// + aether_threaded_extract.cc:38) to avoid linking colmap into the Dawn TU.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>   // per-frame feature-count telemetry (file append)
#include <cstdlib>  // getenv
#include <cstring>
#include <mutex>
#include <numeric>
#include <string>
#include <vector>

#include "dawn_kernel_harness.h"
#include "sift_extract_dawn.h"
#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL)
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#elif defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#else
#error "preclamp instr: feature-selection environment namespace is absent"
#endif
#include "official_preclamp_instr_v1.h"

extern "C" {

// CPU fallback (dsp_sift_c.cc) — same signature; declared so we can delegate.
int aether_dsp_sift_extract_threaded(const uint8_t* gray, int width, int height,
                                     int max_features, int num_threads,
                                     float* out_xy, uint8_t* out_desc,
                                     int out_cap, int* out_count);
// [SCALE-PERSIST 2026-08-06] _v2 CPU fallback sibling (dsp_sift_c.cc): same
// contract plus optional out_scales/out_orientations (either may be NULL).
int aether_dsp_sift_extract_threaded_v2(const uint8_t* gray, int width,
                                        int height, int max_features,
                                        int num_threads, float* out_xy,
                                        uint8_t* out_desc, float* out_scales,
                                        float* out_orientations, int out_cap,
                                        int* out_count);
void aether_sed_clear_last_stages();
void aether_sed_last_stages_gpu(double* out, int cap);

}  // extern "C"

namespace {

constexpr int kCanonicalGpuUnavailable = 2;

// ─── Persistent GPU harness ───
// This entry point used to build a fresh DawnKernelHarness on every call, so
// BOTH the one-time Dawn instance/adapter/device init AND the WGSL pipeline
// compiles (~1.3s across the SIFT kernels) were paid per frame. A capture
// extracts hundreds of frames serially, so we keep ONE harness alive for the
// process: its pipeline_cache_ turns every frame after the first into cache
// hits, and Dawn init happens once. Guarded by a mutex — one wgpu::Device must
// not be driven concurrently (extract may run on a worker thread). Leak-on-exit
// is intentional; Dawn tears down at process exit.
std::mutex g_gpu_harness_mu;
aether::tools::DawnKernelHarness* g_gpu_harness = nullptr;
bool g_gpu_harness_init_failed = false;
// [GPU-HANG-A1 2026-08-06] 挂死自愈重建计数(Chromium 降级阶梯:重建有上限)。
int g_gpu_harness_rebuilds = 0;
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
thread_local bool g_force_next_gpu_fallback_for_test = false;
#endif

// Ready harness (init'd once) or nullptr if Dawn init has failed.
// Caller must hold g_gpu_harness_mu.
aether::tools::DawnKernelHarness* acquire_gpu_harness() {
    if (g_gpu_harness_init_failed) return nullptr;
    // [GPU-HANG-A1 2026-08-06] 挂死自愈:GPU 等待超时后 harness 被标记不健康
    // (所有操作已短路),遗弃旧实例并走下方既有重建逻辑。**故意不 delete**:
    // Dawn 的 Device/Queue 析构含 wait-idle 语义,对已挂死的设备 delete 会
    // 二次挂死;按 Chromium 的遗弃模式(docs/gpu/device_facilities.md ——
    // 失活设备只标记弃用,交进程退出回收)接受一次性内存泄漏。重建有上限
    // (Chromium 降级阶梯):超过 2 次即粘死 init_failed,后续走现有 CPU
    // fallback。
    if (g_gpu_harness != nullptr && !g_gpu_harness->healthy()) {
        g_gpu_harness = nullptr;  // 遗弃,不 delete(见上)
        ++g_gpu_harness_rebuilds;
        // [EXTRACT-SELFHEAL 2026-08-10] 上限 2→6:设备错误类瞬断(未命名(2)
        // 一场就 4 次)现在也走遗弃重建,旧上限几次就永久粘死 CPU。6 次仍是
        // Chromium 降级阶梯语义,只是给瞬断留出余量。
        if (g_gpu_harness_rebuilds > 6) {
            g_gpu_harness_init_failed = true;
            return nullptr;
        }
    }
    if (g_gpu_harness == nullptr) {
        auto* h = new aether::tools::DawnKernelHarness();
        if (!h->init()) {
            delete h;
            g_gpu_harness_init_failed = true;
            return nullptr;
        }
        g_gpu_harness = h;
    }
    return g_gpu_harness;
}

// L1RootNormalize (colmap/feature/utils.cc:49) + round(512) u8 + VLFeat→UBC
// reorder (aether_threaded_extract.cc:38), on one 128-d raw descriptor row.
void finish_descriptor(const float* raw128, uint8_t* out128) {
    double l1 = 0.0;
    for (int i = 0; i < 128; ++i) l1 += std::abs(static_cast<double>(raw128[i]));
    std::array<float, 128> root{};
    if (l1 > 0.0) {
        for (int i = 0; i < 128; ++i)
            root[i] = static_cast<float>(
                std::sqrt(std::abs(static_cast<double>(raw128[i])) / l1));
    }
    std::array<uint8_t, 128> tmp{};
    for (int i = 0; i < 128; ++i) {
        const float v = std::round(512.0f * root[i]);
        int iv = static_cast<int>(v);
        iv = std::max(0, std::min(255, iv));
        tmp[i] = static_cast<uint8_t>(iv);
    }
    // VLFeat→UBC reorder: q = {0,7,6,5,4,3,2,1}.
    static const int q[8] = {0, 7, 6, 5, 4, 3, 2, 1};
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            for (int k = 0; k < 8; ++k)
                out128[8 * (j + 4 * i) + q[k]] = tmp[8 * (j + 4 * i) + k];
}

}  // namespace

extern "C" {

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
__attribute__((visibility("hidden"))) void
aether_preclamp_instr_force_next_gpu_fallback_for_test() {
    g_force_next_gpu_fallback_for_test = true;
}
#endif

// GPU DSP-SIFT. Signature identical to aether_dsp_sift_extract_threaded_v2.
// num_threads is ignored (kept for ABI compatibility). Returns 0 on success,
// 2 when an explicitly requested canonical GPU result is unavailable, and a
// different nonzero status for invalid input/other hard failure.
//
// [SCALE-PERSIST 2026-08-06] _v2: identical contract plus two OPTIONAL
// per-keypoint outputs (either may be NULL — NULL reproduces the v1 behaviour
// exactly; the v1 symbol below is a thin wrapper passing NULL, so there is
// exactly one extraction logic). Values come from the orchestrator's Result
// (kp_scale/kp_orientation: COLMAP ComputeScale/ComputeOrientation formulas
// over the oriented kp record's affine ellipse — see sift_extract_dawn.cc).
// The CPU fallback delegates to _threaded_v2, which fills them from the
// official colmap keypoint structs — the two routes report the same quantity.
int aether_dsp_sift_extract_gpu_v2(const uint8_t* gray, int width, int height,
                                   int max_features, int num_threads,
                                   float* out_xy, uint8_t* out_desc,
                                   float* out_scales, float* out_orientations,
                                   int out_cap, int* out_count) {
    aether_preclamp_instr_v1::ClearPendingAtGpuEntry();
    aether::tools::DawnKernelHarness::gpu_ts_clear_caller_thread_frame();
    aether_sed_clear_last_stages();
    if (out_count) *out_count = 0;
    (void)num_threads;
    if (gray == nullptr || width <= 0 || height <= 0 || out_cap <= 0) return 1;

    const auto selection_policy =
        aether::tools::SiftExtractDawn::feature_selection_policy();
    const bool deterministic_selection_requested =
        selection_policy.policy !=
        aether::sfm::FeatureSelectionPolicyV1::kLegacyColmapGroup;

    auto fallback = [&]() -> int {
        aether_preclamp_instr_v1::DiscardPending(
            aether_preclamp_instr_v1::PendingDiscardReason::
                kGpuFailureOrFallback);
        aether::tools::DawnKernelHarness::gpu_ts_clear_caller_thread_frame();
        aether_sed_clear_last_stages();
        if (deterministic_selection_requested) return kCanonicalGpuUnavailable;
        // [OOM-FALLBACK-GATE 2026-08-09] "transparent CPU fallback" 在拍摄期
        // 是颗雷:GPU 失败(热态 20s TimedWaitAny 超时)后在 12MP 原图上跑
        // CPU DSP-SIFT —— 热瘫的 CPU 要几十秒且分配 GB 级金字塔/工作区。
        // 实测定罪(cap_1786237277896041 fid=33,2026-08-09):worker 卡在
        // add_frame 35s+,footprint 1.97GB→3.16GB,jetsam vm-pageshortage
        // 全 app 阵亡,整机挤兑。政策:大图(>4MP)默认不再 CPU 兜底,返回
        // status 2 → add_frame 走既有 AETHER_SFM_ERR_EXTRACT 丢帧路径,拍摄
        // 继续 —— 宁丢一帧不死全场。小图(host 工具/低分辨率档)保留原兜底。
        // env OFFICIAL_AETHER_EXTRACT_CPU_FALLBACK:=1 恒开(旧行为)/=0 恒关/
        // 未设=按面积(≤4MP 允许)。C 层默认,跨端。
        {
            // ⚠️ 不做 static 缓存,失败路径每次现读 —— [EXTRACT-DEBT REPAY]
            // facade 在拍完等待期 setenv=1 临时放开兜底重喂欠账帧,靠的就是
            // 这里的即时生效。失败路径极冷,getenv 成本可忽略。
            const int fallback_mode = [] {
                const char* e =
                    std::getenv("OFFICIAL_AETHER_EXTRACT_CPU_FALLBACK");
                if (e && e[0] == '1' && e[1] == '\0') return 1;
                if (e && e[0] == '0' && e[1] == '\0') return 0;
                return 2;  // auto: gate by image area
            }();
            const long long px =
                static_cast<long long>(width) * static_cast<long long>(height);
            const bool allowed =
                fallback_mode == 1 || (fallback_mode == 2 && px <= 4000000ll);
            if (!allowed) {
                std::fprintf(stderr,
                             "[DspSiftGpu] GPU extract failed; CPU fallback "
                             "blocked for %dx%d (OOM guard, status 2 -> "
                             "frame drop)\n",
                             width, height);
                return kCanonicalGpuUnavailable;
            }
        }
        return aether_dsp_sift_extract_threaded_v2(
            gray, width, height, max_features, num_threads, out_xy, out_desc,
            out_scales, out_orientations, out_cap, out_count);
    };

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
    if (g_force_next_gpu_fallback_for_test) {
        g_force_next_gpu_fallback_for_test = false;
        return fallback();
    }
#endif

    try {
        // Serialize GPU use + reuse the persistent, pipeline-cached harness.
        // The lock spans the whole GPU extract: one device, one frame at a time.
        std::lock_guard<std::mutex> gpu_lock(g_gpu_harness_mu);
        // [EXTRACT-SELFHEAL 2026-08-10] 设备错误类失败(dawn_error/回读短缺)
        // 此前不标失活 ⇒ 坏实例被 100% 复用:未命名(2) 补算期 GPU 重试 4/4
        // 连败全掉 CPU(39s/帧,用户多等 2 分钟)。现改:第一次失败 →
        // mark_unhealthy 遗弃 → acquire 重建 → 同帧重试一次 → 再败才 CPU。
        for (int attempt = 0; attempt < 2; ++attempt) {
        aether::tools::DawnKernelHarness* harness_ptr = acquire_gpu_harness();
        if (harness_ptr == nullptr) return fallback();
        aether::tools::DawnKernelHarness& harness = *harness_ptr;

        const int max_num0 = max_features > 0 ? max_features : 8192;
        aether::tools::SiftExtractDawn extractor;
        aether::tools::SiftExtractDawn::Result res;
        // Orchestrator applies the COLMAP (octave,scale) clamp BEFORE the
        // descriptor stage — so res already holds ≤max_features keypoints with
        // their final descriptors. The clamp loop below is then a straight emit
        // (+0.5 half-pixel + finishing), already in (octave desc, scale desc)
        // order from the orchestrator's clamp sort, so it stays COLMAP-faithful.
        if (!extractor.extract(harness, gray, width, height, max_num0, &res)) {
            if (attempt == 0) {
                harness.mark_unhealthy();  // 遗弃,下轮 acquire 重建
                continue;
            }
            return fallback();
        }
        if (res.count == 0) {
            aether_preclamp_instr_v1::DiscardPending(
                aether_preclamp_instr_v1::PendingDiscardReason::kZeroCandidate);
            if (out_count) *out_count = 0;
            harness.gpu_ts_stash_frame_for_caller_thread();
            return 0;
        }
        const bool deterministic_selection =
            res.selection_policy !=
            aether::sfm::FeatureSelectionPolicyV1::kLegacyColmapGroup;
        if (deterministic_selection_requested != deterministic_selection ||
            selection_policy.policy != res.selection_policy) {
            return fallback();
        }
        if (deterministic_selection) {
            aether_preclamp_instr_v1::DiscardPending(
                aether_preclamp_instr_v1::PendingDiscardReason::
                    kCanonicalRoute);
            if (res.stable_ids.size() !=
                static_cast<size_t>(res.count)) {
                return fallback();
            }
            for (size_t rank = 0; rank < res.stable_ids.size(); ++rank) {
                if (res.stable_ids[rank] != rank) {
                    return fallback();
                }
            }
        }

        const int max_num =
            max_features > 0 ? max_features : 8192;

        // 8192 clamp by (octave desc, scale desc) — sift.cc:403-440. Sort indices
        // so the highest-octave / highest-scale keypoints survive the cap, then
        // the per-(octave,scale) group rule: stop once size>=max AND the next
        // keypoint starts a new (octave,scale) group.
        const int K = res.count;
        std::vector<int> idx(K);
        if (deterministic_selection) {
            // The shared selector already emitted the total canonical order.
            // Keep row rank unchanged: it is the per-frame Stable ID.
            std::iota(idx.begin(), idx.end(), 0);
        } else {
            for (int i = 0; i < K; ++i) idx[i] = i;
            std::sort(idx.begin(), idx.end(), [&](int a, int b) {
                if (res.octave[a] != res.octave[b])
                    return res.octave[a] > res.octave[b];
                return res.scale[a] > res.scale[b];
            });
        }

        // Emit up to out_cap keypoints, applying the colmap clamp rule.
        const int kMaxOctaveResolution = 1000;
        int prev_os = INT32_MAX;
        int emitted = 0;
        for (int n = 0; n < K && emitted < out_cap; ++n) {
            const int i = idx[n];
            if (out_xy) {
                out_xy[2 * emitted] = res.xy[2 * i] + 0.5f;       // +0.5 half-pixel
                out_xy[2 * emitted + 1] = res.xy[2 * i + 1] + 0.5f;
            }
            // [SCALE-PERSIST 2026-08-06] the scale/orientation are properties
            // of the SAME record row i, emitted in the SAME clamp order as xy.
            if (out_scales) out_scales[emitted] = res.kp_scale[i];
            if (out_orientations) out_orientations[emitted] = res.kp_orientation[i];
            if (out_desc) {
                finish_descriptor(res.raw_desc.data() +
                                      static_cast<size_t>(i) * 128,
                                  out_desc + static_cast<size_t>(emitted) * 128);
            }
            ++emitted;

            const int os = res.octave[i] * kMaxOctaveResolution + res.scale[i];
            if (os != prev_os && emitted >= max_num) break;
            prev_os = os;
        }
        if (out_count) *out_count = emitted;
        if (!deterministic_selection_requested && !deterministic_selection) {
            double gpu_stage_ms[9] = {0.0};
            aether_sed_last_stages_gpu(gpu_stage_ms, 9);
            double gpu_ms = 0.0;
            bool valid_gpu_ms = true;
            for (double stage_ms : gpu_stage_ms) {
                valid_gpu_ms = valid_gpu_ms && std::isfinite(stage_ms) &&
                               stage_ms >= 0.0;
                gpu_ms += stage_ms;
            }
            valid_gpu_ms = valid_gpu_ms && gpu_ms > 0.0;
            (void)aether_preclamp_instr_v1::SealAcceptedLegacyGpuResult(
                static_cast<uint32_t>(res.count),
                valid_gpu_ms
                    ? aether_preclamp_instr_v1::FieldStatus::kValid
                    : aether_preclamp_instr_v1::FieldStatus::kUnavailable,
                valid_gpu_ms ? static_cast<float>(gpu_ms) : 0.0f);
        }
        // Per-frame detection telemetry (peak_threshold-tuning A/B): raw = #DoG
        // keypoints detected BEFORE the 8192 (octave,scale) clamp — the direct
        // signal a lower peak_threshold moves; kept = #emitted after the clamp.
        // Appended to <container>/Documents/gpu_sift_feat.log so it pulls with
        // the same devicectl copy as pw_device_log.txt (no root / os_log dance).
        if (const char* home = std::getenv("HOME")) {
            const std::string path =
                std::string(home) + "/Documents/gpu_sift_feat.log";
            if (FILE* lf = std::fopen(path.c_str(), "a")) {
                std::fprintf(
                    lf,
                    "feat_raw=%d kept=%d %dx%d selector_policy=%u "
                    "selector_reason=%u\n",
                    K, emitted, width, height,
                    static_cast<uint32_t>(res.selection_policy),
                    static_cast<uint32_t>(res.selection_policy_reason));
                std::fclose(lf);
            }
        }
        harness.gpu_ts_stash_frame_for_caller_thread();
        return 0;
        }  // for (attempt) — [EXTRACT-SELFHEAL] 重试环
        return fallback();  // 不可达(环内必 return/continue),保编译器
    } catch (...) {
        // [EXTRACT-SELFHEAL] 异常类失败(如回读守卫)同样标失活,下一次
        // 调用 acquire 走遗弃重建,不再复用坏实例。
        if (g_gpu_harness != nullptr) g_gpu_harness->mark_unhealthy();
        return fallback();
    }
}

// v1 ABI kept verbatim (ABI is add-only): thin wrapper over _v2 with the new
// outputs disabled — same logic, bit-identical output.
int aether_dsp_sift_extract_gpu(const uint8_t* gray, int width, int height,
                                int max_features, int num_threads, float* out_xy,
                                uint8_t* out_desc, int out_cap, int* out_count) {
    return aether_dsp_sift_extract_gpu_v2(
        gray, width, height, max_features, num_threads, out_xy, out_desc,
        /*out_scales=*/nullptr, /*out_orientations=*/nullptr, out_cap,
        out_count);
}

}  // extern "C"
