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
#include <chrono>
#include <mutex>
#include <numeric>
#include <string>
#include <vector>

#include "dawn_kernel_harness.h"
#include "dawn_histogram_sink.h"
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
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
thread_local bool g_force_next_gpu_fallback_for_test = false;
#endif

// Ready harness (init'd once) or nullptr if Dawn init has failed.
// Caller must hold g_gpu_harness_mu.
aether::tools::DawnKernelHarness* acquire_gpu_harness() {
    if (g_gpu_harness_init_failed) return nullptr;
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
    } catch (...) {
        return fallback();
    }
}

// [WARMUP 2026-09-10] 预热:建单例 harness + 预编生产路径全部 WGSL 管线。
//
// 真机账(未命名(2) cap_1789024293272808):第 0 帧 extract_ms 9293 ms,同帧
// GPU 时间戳九段合计 438 ms ⇒ 8.9 s 是主机侧的 Dawn init + 管线编译,全压在
// 第 0 帧。第 0 帧就是用户按下开始之后盯着的第一秒。这个入口把那笔钱挪到
// 拍摄期间(见 official_aether_sfm_c.cc 里 aether_sfm_create 的调用点)。
//
// 无损:只做两件本来第 0 帧也要做的事 —— acquire_gpu_harness()(幂等)和
// load_compute()(纯记忆化)。不分配缓冲、不派发、不提交,GPU 上没有一条
// 命令被执行。拿的是**同一把互斥锁**,所以就算第 0 帧在预热跑一半时到达,
// 它也只是等锁,最坏情况与今天等价 —— 严格不劣。
//
// 幂等:重复调用第二次起全是缓存命中(几十微秒)。Dawn init 失败时
// acquire_gpu_harness() 返回 nullptr,这里静默返回:预热失败绝不能让
// 采集路径出错,第 0 帧仍会走它自己的失败/回落逻辑。
// 返回本次**真正新编**的管线条数;-1 = Dawn 不可用。
// out_init_ms   = acquire_gpu_harness()(Dawn instance/adapter/device 创建)
// out_compile_ms= SiftExtractDawn::warmup()(12 条 WGSL 编译)
//
// [PIPE-BD 2026-09-11] compile_ms 再拆三段 —— 三段可缓存性完全不同,不拆开就不知道
// 预编译管线该投哪一级:
//   ② out_msl_ms  = Metal.newLibraryWithSource.CacheMiss           (MSL→MTLLibrary)
//   ③ out_pso_ms  = Metal.newComputePipelineStateWithDescriptor.CacheMiss(→GPU 机器码)
//   ① Tint WGSL→MSL = compile_ms − ② − ③
// ②③ 是 **Dawn 自己埋的**(metal/ShaderModuleMTL.mm:549 / metal/ComputePipelineMTL.mm:87),
// 我们只接了个 platform 去收,没改 Dawn 一行。
// out_msl_n / out_pso_n = 采样次数:**0 毫秒与「回调根本没响」必须分得开**。
int aether_dsp_sift_extract_gpu_warmup(double* out_init_ms,
                                       double* out_compile_ms,
                                       double* out_msl_ms, unsigned* out_msl_n,
                                       double* out_pso_ms, unsigned* out_pso_n) {
    if (out_init_ms) *out_init_ms = 0.0;
    if (out_compile_ms) *out_compile_ms = 0.0;
    if (out_msl_ms) *out_msl_ms = 0.0;
    if (out_msl_n) *out_msl_n = 0u;
    if (out_pso_ms) *out_pso_ms = 0.0;
    if (out_pso_n) *out_pso_n = 0u;
    try {
        std::lock_guard<std::mutex> gpu_lock(g_gpu_harness_mu);
        const auto t0 = std::chrono::steady_clock::now();
        aether::tools::DawnKernelHarness* harness_ptr = acquire_gpu_harness();
        const auto t1 = std::chrono::steady_clock::now();
        if (out_init_ms) {
            *out_init_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
        if (harness_ptr == nullptr) return -1;
        const size_t before = harness_ptr->pipeline_cache_size();
        aether::tools::SiftExtractDawn::warmup(*harness_ptr);
        const auto t2 = std::chrono::steady_clock::now();
        if (out_compile_ms) {
            *out_compile_ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
        }
        harness_ptr->dawn_histogram(aether::tools::kDawnHistMslLibrary, out_msl_ms, out_msl_n);
        harness_ptr->dawn_histogram(aether::tools::kDawnHistPipelineState, out_pso_ms, out_pso_n);
        return static_cast<int>(harness_ptr->pipeline_cache_size() - before);
    } catch (...) {
        // 预热是纯优化,任何异常都吞掉:第 0 帧照旧自己编。
        return -1;
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
