#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "sift_extract_dawn.h"
#include "feature_selection_environment_v1.h"
#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL)
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#elif defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#else
#error "preclamp instr: feature-selection environment namespace is absent"
#endif
#include "../official_pipeline/src/official_preclamp_instr_v1.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <iostream>
#include <numeric>
#include <span>
#include <string>
#include <utility>

#ifdef AETHER_WGSL_DIR
#include <fstream>
#include <sstream>
#else
#include "aether/shaders/wgsl_sources.h"
#include <string_view>
#endif

// [EXTRACT-SELFHEAL 2026-08-10] 提取失败原因(线程本地,extract() 进入时清
// 空)。此前失败原因只进 stderr(真机上丢失)= 观测盲区:未命名(2) 4 帧
// GPU 瞬断 + 补算 4/4 掉 CPU,无从定罪。core 在 errExtract 时把它落逐帧账。
// 定义在文件最早处:read_u32 等匿名空间助手也要set。
static thread_local char g_aether_sed_fail_reason[192] = {0};
extern "C" const char* aether_sed_last_fail_reason() {
    return g_aether_sed_fail_reason;
}
static void sed_set_fail_reason(const char* what) {
    std::snprintf(g_aether_sed_fail_reason, sizeof(g_aether_sed_fail_reason),
                  "%s", what);
}

namespace aether {
namespace tools {

namespace {

// The 8 production passes. Host parity/e2e benches define AETHER_WGSL_DIR and
// read from the shaders/wgsl tree; iOS/production uses the baked-in
// aether::shaders::*_wgsl symbols (zero filesystem dependency). Single source
// of truth on both — the .wgsl files — so host and device cannot diverge.
std::string load_wgsl(const char* filename) {
// [EXTRACT-WGSL-DIR 2026-09-06] 运行期覆盖:env OFFICIAL_AETHER_EXTRACT_WGSL_DIR=<dir>("~/…" 按 HOME 展开)且 <dir>/<file> 存在
//   ⇒ 用文件文本(台架推文件迭代,不重装);否则回落编译期常量目录 / 烘焙表。管线缓存以源码全文为键,换文件即换管线。
    if (const char* d = std::getenv("OFFICIAL_AETHER_EXTRACT_WGSL_DIR")) {
        std::string dir = d;
        if (dir.size() > 1 && dir[0] == '~' && dir[1] == '/') { if (const char* h = std::getenv("HOME")) dir = std::string(h) + dir.substr(1); }
        std::ifstream of(dir + "/" + filename, std::ios::binary);
        if (of) { std::ostringstream ss; ss << of.rdbuf(); std::fprintf(stderr, "[SiftExtractDawn] WGSL override %s/%s (%zu B)\n", dir.c_str(), filename, (size_t)ss.str().size()); return ss.str(); }
    }
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
    if (f == "sift_suppress_grid_count.wgsl") return std::string(sift_suppress_grid_count_wgsl);
    if (f == "sift_suppress_grid_scan.wgsl") return std::string(sift_suppress_grid_scan_wgsl);
    if (f == "sift_suppress_grid_scatter.wgsl") return std::string(sift_suppress_grid_scatter_wgsl);
    if (f == "sift_suppress_grid.wgsl") return std::string(sift_suppress_grid_wgsl);
    if (f == "sift_affine_shape.wgsl")        return std::string(sift_affine_shape_wgsl);
    if (f == "sift_orientation.wgsl")         return std::string(sift_orientation_wgsl);
    if (f == "sift_orientation_atomic.wgsl")
        return std::string(sift_orientation_atomic_wgsl);
    if (f == "sift_dsp_descriptor.wgsl")      return std::string(sift_dsp_descriptor_wgsl);
    if (f == "sift_dsp_descriptor_f16.wgsl")  return std::string(sift_dsp_descriptor_f16_wgsl);
    if (f == "sift_dsp_descriptor_f16_atomic.wgsl")
        return std::string(sift_dsp_descriptor_f16_atomic_wgsl);
    if (f == "sift_dsp_descriptor_par.wgsl")  return std::string(sift_dsp_descriptor_par_wgsl);
    if (f == "sift_dsp_mean.wgsl")            return std::string(sift_dsp_mean_wgsl);
    std::cerr << "[SiftExtractDawn] unknown WGSL pass: " << filename << '\n';
    std::abort();
#endif
}

// [W256 2026-09-07] 关键点阶段(affine/orient/descriptor)一次 dispatch 跨所有
// 八度取样,打包金字塔 ≈400 MB 超过 Mali 单次绑定上限 256 MB ⇒ 绑成两个窗口:
// lo=[0,2^26) 元素、hi=[2^26,total);内核 level_at 按偏移选窗(层不跨窗)。
// 小图(total ≤ 2^26)hi 与 lo 同区间——同缓冲只读双绑定合法。
// [W256 2026-09-07] 关键点阶段(affine/orient/descriptor)着色器**一字不改**,
// 只把 packed 绑成 A 区子区间 [0, keypoint_region_end):A 区装着它们会读的全部
// 层(见 sift_pyramid_dawn.h)。A 区必须 ≤ 2^26 元素(256 MB):12MP ≈195 MB。
// [W256-KPBIND 2026-09-08 诊断] 只把**关键点阶段那一次绑定**单拎出来做变量。
// 09-08 P50 段账:5.62x 里 6.8/7.2 s 压在 affine/orient/clamp/descriptor,
// 而它们与 w256=0 唯一的差别就是这一句——起点同样是 0,只是 size 从整块
// 缩到 A 区。OFFICIAL_AETHER_W256_KPBIND=0 ⇒ 这一句退回整缓冲,其余全不动。
static bool kp_bind_subrange() {
    if (const char* v = std::getenv("OFFICIAL_AETHER_W256_KPBIND")) {
        return !(v[0] == '0' && v[1] == '\0');
    }
    return SiftPyramidDawn::w256_bind_enabled();
}

static DawnKernelHarness::BufBinding w256_kp(const wgpu::Buffer& b,
                                             const SiftPyramidDawn& pyr) {
    // [SPLITBUF 2026-09-08] A 区本来就是独立缓冲 ⇒ 整块绑,零子区间、零拷贝。
    if (SiftPyramidDawn::splitbuf_enabled()) {
        SiftPyramidDawn::note_kp_bind(3);   // 3 = 两缓冲布局的 A 区
        return DawnKernelHarness::BufBinding(b);
    }
    // [KPBUF 2026-09-08] 有独立 A 区缓冲时:整块绑它,零子区间。
    if (SiftPyramidDawn::kpbuf_enabled() && pyr.keypoint_buffer_ready()) {
        SiftPyramidDawn::note_kp_bind(2);   // 2 = 走独立缓冲
        return DawnKernelHarness::BufBinding(pyr.keypoint_buffer());
    }
    const bool sub = kp_bind_subrange();
    SiftPyramidDawn::note_kp_bind(sub ? 1 : 0);
    if (!sub) return DawnKernelHarness::BufBinding(b);
    return DawnKernelHarness::BufBinding(
        b, 0u, static_cast<uint64_t>(pyr.keypoint_region_end()) * 4u);
}

// Read `n` u32 from a Storage|CopySrc buffer to host.
std::vector<uint32_t> read_u32(DawnKernelHarness& h, const wgpu::Buffer& b,
                               size_t n) {
    const size_t bytes = n * sizeof(uint32_t);
    wgpu::Buffer st = h.alloc_staging_for_readback(bytes);
    h.copy_to_staging(b, st, bytes);
    std::vector<uint8_t> raw = h.readback(st, bytes);
    // [READBACK-GUARD 2026-08-09] readback() 在 GPU 等待超时/设备失活/map
    // 失败三条路径上都返回空 vector —— 旧代码不检查直接 memcpy 空指针,
    // 真机 SIGSEGV 实锤(2026-08-09 18:19 Runner.ips:read_u32→memmove
    // KERN_INVALID_ADDRESS at 0x0;GPU_WAIT_MS=1 复现,热态真超时同路径)。
    // 抛异常 → dsp_sift_gpu_c.cc 的 catch(...) → fallback(OOM 闸把关)→
    // errExtract → 帧记欠账拍完补算 —— 崩溃变成"晚一点",一帧不丢。
    if (raw.size() < bytes) {
        sed_set_fail_reason("readback_short_or_timeout");
        throw std::runtime_error(
            "[SiftExtractDawn] GPU readback short/failed (timeout or device "
            "loss) — aborting this frame's extraction");
    }
    std::vector<uint32_t> out(n);
    std::memcpy(out.data(), raw.data(), bytes);
    return out;
}

}  // namespace

aether::sfm::FeatureSelectionPolicyDecisionV1
SiftExtractDawn::feature_selection_policy() {
    return aether::sfm::ParseFeatureSelectionPolicyV1(std::getenv(
        detail::kFeatureSelectionPolicyEnvironmentV1));
}

// [AETHER-T-EXTRACT 2026-07-27] Per-stage duration stash (9 mark() stages in
// extract() order: pyramid, pack, detect, suppress+rb, affine+rb, orient,
// clamp, descriptor, desc-rb). The stash is caller-thread-owned: the GPU ABI
// serializes Dawn work, but the official session reads after that mutex is
// released, so a process-global array would race with the next session.
static constexpr int kAetherSedStageCount = 9;
static thread_local double g_aether_sed_stage_ms[kAetherSedStageCount] = {0};

extern "C" void aether_sed_last_stages(double* out, int cap) {
    if (out == nullptr || cap <= 0) return;
    const int n = cap < kAetherSedStageCount ? cap : kAetherSedStageCount;
    for (int i = 0; i < n; ++i) out[i] = g_aether_sed_stage_ms[i];
}

// [GPU-TS 2026-07-29] The GPU-side twin of the stash above.
//
// g_aether_sed_stage_ms is HOST wall clock: each entry brackets host loops,
// buffer uploads, the blocking readback AND the GPU work in one number. Three
// separate optimisation candidates (constant-mask precompute, (o,s) pruning,
// deleting the CPU round-trips) all target the NON-GPU part of that bundle, so
// ranking them on the host number is circular. This array carries the GPU-only
// share of the same nine stages, summed from per-pass timestamp deltas; the
// difference (host − gpu) is the host/transfer/sync overhead per stage.
//
// Zero unless AETHER_GPU_TIMESTAMPS=1 — with the env unset no query set exists,
// no pass descriptor is attached, and the command stream is unchanged.
static thread_local double
    g_aether_sed_stage_gpu_ms[kAetherSedStageCount] = {0};

extern "C" void aether_sed_last_stages_gpu(double* out, int cap) {
    if (out == nullptr || cap <= 0) return;
    const int n = cap < kAetherSedStageCount ? cap : kAetherSedStageCount;
    for (int i = 0; i < n; ++i) out[i] = g_aether_sed_stage_gpu_ms[i];
}

// [HOST-BD 2026-09-08] 上面两个数组的第三个同伴:host−gpu 那一块到底花在哪。
// 五列 = upload / encode(建 bind group + 编码)/ submit+wait / map / create。
// 剩下的 host − gpu − 这五列 = 提取器自己的 CPU 循环。
// 只有 OFFICIAL_AETHER_HOST_BD=1(或 GPU 时间戳开着)时非零。
static thread_local double
    g_aether_sed_stage_hb[kAetherSedStageCount][7] = {{0}};

extern "C" void aether_sed_last_stages_hb(double* out, int cap) {
    if (out == nullptr || cap <= 0) return;
    const int n = cap < kAetherSedStageCount * 7 ? cap : kAetherSedStageCount * 7;
    for (int i = 0; i < n; ++i) out[i] = g_aether_sed_stage_hb[i / 7][i % 7];
}

extern "C" void aether_sed_clear_last_stages() {
    for (int i = 0; i < kAetherSedStageCount; ++i) {
        g_aether_sed_stage_ms[i] = 0.0;
        g_aether_sed_stage_gpu_ms[i] = 0.0;
    }
}


extern "C" void aether_pyr_persist_end_frame();

bool SiftExtractDawn::extract(DawnKernelHarness& harness, const uint8_t* gray,
                              int width, int height, int max_features,
                              Result* out) {
    if (out == nullptr) return false;
    out->xy.clear();
    out->octave.clear();
    out->scale.clear();
    out->kp_scale.clear();
    out->kp_orientation.clear();
    out->raw_desc.clear();
    out->stable_ids.clear();
    out->count = 0;
    const aether::sfm::FeatureSelectionPolicyDecisionV1 selection_decision =
        feature_selection_policy();
    out->selection_policy = selection_decision.policy;
    out->selection_policy_reason = selection_decision.reason;
    if (gray == nullptr || width < 2 || height < 2) return false;
    const bool canonical_selection =
        selection_decision.policy ==
        aether::sfm::FeatureSelectionPolicyV1::kCanonicalExact8192;
    const bool coverage_selection =
        selection_decision.policy ==
        aether::sfm::FeatureSelectionPolicyV1::kCoverageExact8192;

    // [P0 崩溃修复 2026-07-27] Dawn 的设备级错误(校验/OOM/internal)现在
    // 只记录不 abort(见 DawnKernelHarness::take_device_error 的注释),所以
    // **消费 GPU 结果之前必须显式查一次** —— 漏查就等于拿脏数据静默往下走,
    // 那才是真正最坏的失败模式。先清掉上一帧可能残留的状态。
    DawnKernelHarness::take_device_error(nullptr);
    g_aether_sed_fail_reason[0] = '\0';  // [EXTRACT-SELFHEAL] 每次进入清空
    const auto dawn_failed = [](const char* where) {
        std::string err;
        if (!DawnKernelHarness::take_device_error(&err)) {
            return false;
        }
        std::cerr << "[SiftExtractDawn] Dawn device error at " << where << ": "
                  << err << " (fallback)\n";
        sed_set_fail_reason(
            (std::string("dawn_error@") + where + ": " + err).c_str());
        return true;
    };

    // Per-stage host timing is diagnostic-only. SED_TIMING prints it, while a
    // requested/enabled TimestampQuery run records it beside GPU durations.
    // With both gates off, mark() returns before reading a clock: the default
    // product path remains observationally inert.
    const bool timing = std::getenv("SED_TIMING") != nullptr;
    const bool observe_timing = timing || harness.gpu_ts_enabled();
    aether_sed_clear_last_stages();
    int sed_idx = 0;
    // [GPU-TS] Record which compute passes fall inside each stage. Resolving
    // per stage would add a readback per stage — exactly the round-trip under
    // investigation — so only the pass-index boundaries are captured here and
    // the single resolve happens after the last mark().
    harness.gpu_ts_reset();
    harness.host_breakdown_reset();               // [HOST-BD]
    uint32_t ts_bounds[kAetherSedStageCount] = {0};
    // [HOST-BD] Per-stage harness cost, so the extractor's OWN host loops fall
    // out as: host_ms - gpu_ms - (upload+encode+wait+map). That residual is the
    // only part no existing counter can see, and it is where the compaction
    // loops / ellipse repacking / host sorts live.
    double hb_stage[kAetherSedStageCount][7] = {{0}};  // upload, encode, wait, map, create
    auto hb_snap = harness.host_breakdown();
    std::chrono::high_resolution_clock::time_point t_prev{};
    if (observe_timing) {
        t_prev = std::chrono::high_resolution_clock::now();
    }
    auto mark = [&](const char* label) {
        if (!observe_timing) return;
        auto now = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(now - t_prev).count();
        if (sed_idx < kAetherSedStageCount) {
            ts_bounds[sed_idx] = harness.gpu_ts_pass_count();  // [GPU-TS]
            const auto& h = harness.host_breakdown();          // [HOST-BD]
            hb_stage[sed_idx][0] = h.upload_ms - hb_snap.upload_ms;
            hb_stage[sed_idx][1] = h.encode_ms - hb_snap.encode_ms;
            hb_stage[sed_idx][2] = h.submit_wait_ms - hb_snap.submit_wait_ms;
            hb_stage[sed_idx][3] = h.map_ms - hb_snap.map_ms;
            hb_stage[sed_idx][4] = h.create_ms - hb_snap.create_ms;
            hb_stage[sed_idx][5] = double(h.n_submit) - double(hb_snap.n_submit);
            hb_stage[sed_idx][6] = double(h.n_copy) - double(hb_snap.n_copy);
            for (int c = 0; c < 7; ++c)          // [HOST-BD] 导出给台架
                g_aether_sed_stage_hb[sed_idx][c] = hb_stage[sed_idx][c];
            hb_snap = h;
            g_aether_sed_stage_ms[sed_idx++] = ms;
        }
        if (timing) {
            std::printf("  [SED] %-22s %.1f ms\n", label, ms);
            std::fflush(stdout);
        }
        t_prev = now;
    };

    // ── GSS pyramid (resident) + packed all-octave buffer ──
    SiftPyramidDawn pyr;
    if (!pyr.build(harness, gray, width, height)) {
        std::cerr << "[SiftExtractDawn] pyramid build failed\n";
        sed_set_fail_reason("pyramid_build_failed");
        return false;
    }
    mark("pyramid build");
    std::vector<SiftPyramidDawn::LevelMeta> meta;
    wgpu::Buffer packed = pyr.pack_levels(harness, &meta);
    wgpu::Buffer meta_buf =
        harness.upload(meta.data(), meta.size() * sizeof(SiftPyramidDawn::LevelMeta),
                       wgpu::BufferUsage::Storage);
    if (kp_bind_subrange() &&
        pyr.keypoint_region_end() > SiftPyramidDawn::window_elems()) {
        // [W256] A 区超 256 MB(> ~16.7 MP)——关键点阶段无法单绑定;显式失败
        // 走既有回退,绝不静默(见 feedback_silent_exit_is_the_default_bug)。
        sed_set_fail_reason("w256_keypoint_region_exceeds_256mb");
        return false;
    }
    // [KPBUF 2026-09-08] 金字塔已定稿 ⇒ 把 A 区拷进独立缓冲。开销落在 pack 段,
    // 段账里看得见(不藏进别的段)。默认关,OFFICIAL_AETHER_KPBUF=1 打开。
    pyr.sync_keypoint_buffer(harness);
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
        // [PACK-ZERO 2026-08-10] 本 octave 6 层在 packed 大缓冲中的偏移。
        uint32_t off[6];
        uint32_t z0, _pad1;   // [W256] z0 = 拆分 dispatch 的 z 起点
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
                    static_cast<float>(kOctaveResolution),
                    {0, 0, 0, 0, 0, 0}, 0, 0};
        for (int s = SiftPyramidDawn::kOctaveFirstSub;
             s <= SiftPyramidDawn::kOctaveLastSub; ++s)
            P.off[s - SiftPyramidDawn::kOctaveFirstSub] = pyr.level_offset(o, s);
        // [W256 2026-09-07] 绑定子区间 ≤ 2^26 元素(256 MB)。检测在 zc 读
        // dog(zc-1..zc+1) = gss(zc-1..zc+2):整八度 6 层若超窗(12MP octave0
        // = 292 MB),按 z 拆两次:zc∈{1,2} 绑 gss 0..4,zc=3 绑 gss 2..5;
        // 偏移改为相对绑定起点。集合不变(只是 kp_counter 原子顺序变)。
        using BB = DawnKernelHarness::BufBinding;
        const uint32_t n_oct =
            static_cast<uint32_t>(ow) * static_cast<uint32_t>(oh);
        struct Part { int z0, zn, l0, l1; };
        std::vector<Part> parts;
        {
            // 6 层区间(A 区 li 0..2 与 B 区 li 3..5 相隔很远)若 ≤ 256 MB 则
            // 一次 dispatch;否则每个 zc 单独一次:zc 读 gss (zc-1)..(zc+2)。
            const auto span = [&](int l0, int l1) {
                uint32_t lo = P.off[l0], hi = P.off[l0] + n_oct;
                for (int k = l0; k <= l1; ++k) {
                    lo = std::min(lo, P.off[k]);
                    hi = std::max(hi, P.off[k] + n_oct);
                }
                return hi - lo;
            };
            // [SPLITBUF] 两块缓冲各自 < 绑定上限 ⇒ 整块绑、不拆 z、不开窗。
            if (SiftPyramidDawn::splitbuf_enabled() ||
                !SiftPyramidDawn::w256_bind_enabled() ||
                span(0, 5) <= SiftPyramidDawn::window_elems()) {
                parts = {{0, 3, 0, 5}};
            } else {
                for (int zc = 1; zc <= 3; ++zc) {
                    if (span(zc - 1, zc + 2) > SiftPyramidDawn::window_elems()) {
                        sed_set_fail_reason("w256_detect_span_exceeds_256mb");
                        return false;
                    }
                    parts.push_back({zc - 1, 1, zc - 1, zc + 2});
                }
            }
        }
        const bool w256 = SiftPyramidDawn::w256_bind_enabled();
        for (const Part& pt : parts) {
            DetParams Q = P;
            uint32_t lo = P.off[pt.l0], hi = P.off[pt.l0] + n_oct;
            for (int k = pt.l0; k <= pt.l1; ++k) {
                lo = std::min(lo, P.off[k]);
                hi = std::max(hi, P.off[k] + n_oct);
            }
            if (!w256) lo = 0u;   // 旧模式:整缓冲绑定、绝对偏移
            const bool split = SiftPyramidDawn::splitbuf_enabled();
            if (split) lo = 0u;   // [SPLITBUF] 偏移就是区内绝对值
            for (int k = 0; k < 6; ++k)
                Q.off[k] = (k >= pt.l0 && k <= pt.l1) ? P.off[k] - lo : 0u;
            Q.z0 = static_cast<uint32_t>(pt.z0);
            wgpu::Buffer p_buf =
                harness.upload(&Q, sizeof(Q), wgpu::BufferUsage::Uniform);
            if (std::getenv("W256_DIAG"))
                std::fprintf(stderr, "[W256] detect o=%d z0=%d zn=%d bind=%.1fMB\n",
                             o, pt.z0, pt.zn, (hi - lo) * 4.0 / 1048576.0);
            harness.dispatch_batched(
                pipe_detect,
                {(w256 && !split) ? BB(packed, static_cast<uint64_t>(lo) * 4u,
                                       static_cast<uint64_t>(hi - lo) * 4u)
                                  : BB(packed),
                 BB(det_counter), BB(det_buf), BB(p_buf),
                 // [SPLITBUF 2026-09-08] binding(4) = 高三层的来源。现在还指向
                 // 同一块同一窗口(纯等价),两缓冲落地后换成 B 缓冲。
                 // 同缓冲的两个**只读**绑定是合法的。
                 split ? BB(pyr.packed_hi_buffer())
                       : (w256 ? BB(packed, static_cast<uint64_t>(lo) * 4u,
                                    static_cast<uint64_t>(hi - lo) * 4u)
                               : BB(packed))},
                static_cast<uint32_t>((ow + 7) / 8),
                static_cast<uint32_t>((oh + 7) / 8),
                static_cast<uint32_t>(pt.zn));
        }
    }
    harness.end_batch();
    uint32_t n_detect = read_u32(harness, det_counter, 1)[0];
    mark("detect (all oct)");
    // 顺序要紧:先判 Dawn 错误,再判 0 特征 —— 否则金字塔/检测阶段的校验
    // 失败会被误读成"这帧就是没有特征"的合法空结果。
    if (dawn_failed("pyramid/detect")) {
        return false;
    }
    if (n_detect > kDetectCap) {
        std::cerr << "[SiftExtractDawn] detect overflow " << n_detect << " > "
                  << kDetectCap << " (fallback)\n";
        char why[96];
        std::snprintf(why, sizeof(why), "detect_overflow n=%u cap=%u",
                      n_detect, kDetectCap);
        sed_set_fail_reason(why);
        return false;
    }
    // [P0 崩溃修复 2026-07-27] 全黑 / 完全无纹理的帧(手机扣在桌面上拍)
    // 检测数为 0。若继续往下走,Stage B++ 会 upload 一个 **0 字节** 的
    // keep_buf(keep_init 是空 vector),而 WebGPU 不允许把零尺寸 storage
    // buffer 绑进 bind group → Dawn 判校验失败 → on_uncaptured_error →
    // 进程 abort,整个 App 闪退。真机三份崩溃报告(14:57:00/07/27)签名
    // 完全一致,栈顶就是 CreateBindGroup。
    //
    // 这里提前收工,语义与下面 n_kept == 0 那条守卫**完全一致**:
    // 0 个特征是合法的空结果,不是失败,所以 return true 而不是走 CPU 回退
    // (CPU 在同一帧上同样会得到 0 个特征,重算一遍纯属浪费)。
    if (n_detect == 0) {
        out->count = 0;
        aether_preclamp_instr_v1::DiscardPending(
            aether_preclamp_instr_v1::PendingDiscardReason::kZeroCandidate);
        return true;
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
        // [K7 SUPPRESS-GRID 2026-09-06] 网格分桶版:count→scan→scatter→
        // 分桶抑制四个 pass 一次提交。谓词逐字符不变,候选集是可能压制者的
        // 超集(证明见 sift_suppress_grid.wgsl)⇒ keep[] 逐位相同;把 O(N²)
        // 对检查降到 O(N·邻域)。kill switch:OFFICIAL_AETHER_SUPPRESS_GRID=0。
        static const bool grid_on = [] {
            const char* v = std::getenv("OFFICIAL_AETHER_SUPPRESS_GRID");
            return v == nullptr || !(v[0] == '0' && v[1] == '\0');
        }();
        if (grid_on) {
            constexpr uint32_t kCell = 16u;
            const uint32_t ncx = (static_cast<uint32_t>(width) + kCell - 1u) / kCell;
            const uint32_t ncy = (static_cast<uint32_t>(height) + kCell - 1u) / kCell;
            const uint32_t ncells = ncx * ncy;
            struct GridParams {
                uint32_t count; float tol; uint32_t width, height;
                uint32_t cell, ncx, ncy, ncells;
            } gp{n_detect, static_cast<float>(kSuppressTol),
                 static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                 kCell, ncx, ncy, ncells};
            wgpu::Buffer gp_buf =
                harness.upload(&gp, sizeof(gp), wgpu::BufferUsage::Uniform);
            std::vector<uint32_t> zeros(static_cast<size_t>(ncells) + 1u, 0u);
            wgpu::Buffer cell_count = harness.upload(
                zeros.data(), zeros.size() * sizeof(uint32_t),
                wgpu::BufferUsage::Storage);
            wgpu::Buffer cell_cursor = harness.upload(
                zeros.data(), zeros.size() * sizeof(uint32_t),
                wgpu::BufferUsage::Storage);
            wgpu::Buffer cell_start = harness.alloc(
                zeros.size() * sizeof(uint32_t), wgpu::BufferUsage::Storage);
            wgpu::Buffer cell_items = harness.alloc(
                static_cast<size_t>(n_detect) * sizeof(uint32_t),
                wgpu::BufferUsage::Storage);
            wgpu::ComputePipeline pipe_cnt =
                harness.load_compute(load_wgsl("sift_suppress_grid_count.wgsl"));
            wgpu::ComputePipeline pipe_scan =
                harness.load_compute(load_wgsl("sift_suppress_grid_scan.wgsl"));
            wgpu::ComputePipeline pipe_scat =
                harness.load_compute(load_wgsl("sift_suppress_grid_scatter.wgsl"));
            wgpu::ComputePipeline pipe_grid =
                harness.load_compute(load_wgsl("sift_suppress_grid.wgsl"));
            const uint32_t wgs = (n_detect + 63u) / 64u;
            harness.begin_batch();
            harness.dispatch_batched(pipe_cnt, {det_buf, cell_count, gp_buf}, wgs, 1u);
            harness.dispatch_batched(pipe_scan, {cell_count, cell_start, gp_buf}, 1u, 1u);
            harness.dispatch_batched(pipe_scat,
                                     {det_buf, cell_start, cell_cursor, cell_items, gp_buf},
                                     wgs, 1u);
            harness.dispatch_batched(pipe_grid,
                                     {det_buf, cell_start, cell_items, keep_buf, gp_buf},
                                     wgs, 1u);
            harness.end_batch();
        } else {
            wgpu::ComputePipeline pipe_sup =
                harness.load_compute(load_wgsl("sift_nonextrema_suppress.wgsl"));
            harness.dispatch(pipe_sup, {det_buf, keep_buf, sp_buf},
                             (n_detect + 63u) / 64u);
        }
    }

    // Read detect records + keep flags; compact on host into the affine input
    // (the affine kernel needs [x,y,sigma] in slots 0,1,2 — the detect record
    // already has that, so compaction is a straight copy of kept rows).
    // [SYNC-MERGE 2026-09-07] det_recs 与 keep 原来各回读一次(两次 submit+
    // wait+map);合成一个 staging、一次 map:内容逐字节相同,少一次 GPU 同步。
    const size_t det_bytes = static_cast<size_t>(n_detect) * kKpStride * sizeof(uint32_t);
    const size_t keep_bytes = static_cast<size_t>(n_detect) * sizeof(uint32_t);
    const size_t keep_off = (det_bytes + 255u) & ~static_cast<size_t>(255u);  // 拷贝偏移 256 对齐
    std::vector<uint32_t> det_recs(static_cast<size_t>(n_detect) * kKpStride);
    std::vector<uint32_t> keep(n_detect);
    {
        wgpu::Buffer st = harness.alloc_staging_for_readback(keep_off + keep_bytes);
        harness.begin_batch();
        harness.copy_region_batched(det_buf, 0, st, 0, det_bytes);
        harness.copy_region_batched(keep_buf, 0, st, keep_off, keep_bytes);
        harness.end_batch();
        std::vector<uint8_t> raw = harness.readback(st, keep_off + keep_bytes);
        if (raw.size() < keep_off + keep_bytes) {
            sed_set_fail_reason("readback_short_or_timeout");
            throw std::runtime_error("readback short (det+keep)");
        }
        std::memcpy(det_recs.data(), raw.data(), det_bytes);
        std::memcpy(keep.data(), raw.data() + keep_off, keep_bytes);
    }
    mark("suppress+readback");

    std::vector<uint32_t> aff_in;  // KP_STRIDE-packed kept detect records
    aff_in.reserve(static_cast<size_t>(n_detect) * kKpStride);
    for (uint32_t i = 0; i < n_detect; ++i) {
        if (!keep[i]) continue;
        const uint32_t* r = det_recs.data() + static_cast<size_t>(i) * kKpStride;
        for (uint32_t w = 0; w < kKpStride; ++w) aff_in.push_back(r[w]);
    }
    uint32_t n_kept = static_cast<uint32_t>(aff_in.size() / kKpStride);
    if (dawn_failed("suppress")) {
        return false;
    }
    if (n_kept == 0) {
        out->count = 0;
        aether_preclamp_instr_v1::DiscardPending(
            aether_preclamp_instr_v1::PendingDiscardReason::kZeroCandidate);
        return true;
    }

    // ════════ [PRECLAMP-PRUNE 2026-08-10] (o,s) 组前置剪枝 ════════
    // 依据 = 下方 [Q5A-AUDIT 2026-08-08] 的证明:COLMAP clamp 按 (octave
    // desc, scale desc) 排序且只在组边界停 ⇒ 幸存集恒为「完整粗组前缀 +
    // 断点组首条」。把候选按 (o,s) 降序累加,取首个 cum>=max_features 的组
    // j*,保留 G0..G_{j*+1}(off-by-one:断点组首条可落在 j*+1 组),更细
    // 的组在 k>=1(每候选至少 1 个定向)时全部必被裁 —— 对它们跑
    // affine/orient 是 100% 白工。真机 12MP 实测可剪 31-56%。
    // ⚠️ k=0(候选定向产出为空)会破坏该下界(12MP 实测 6 帧有 3 帧
    // prefix_violations>0),所以剪枝不是无条件的:定向后校验「粗于最细
    // 保留组的定向产物数 >= max_features」,不满足则用全量候选重跑
    // affine+orient(fail-safe:推迟不丢)。输出集合与不剪枝时逐点相同;
    // 唯一既有的 run-to-run 变数(atomic 追加序对断点组首条的影响)不变。
    std::vector<uint32_t> aff_in_full;
    uint32_t n_kept_full = n_kept;
    long long prune_validate_os = LLONG_MIN;  // hist[j*] 的 os 键(校验阈)
    bool did_prune = false;
    {
        static const bool prune_on = [] {  // kill switch,默认开
            const char* v = std::getenv("OFFICIAL_AETHER_PRECLAMP_PRUNE");
            return v == nullptr || !(v[0] == '0' && v[1] == '\0');
        }();
        if (prune_on && !canonical_selection && !coverage_selection &&
            max_features > 0 && n_kept > static_cast<uint32_t>(max_features)) {
            constexpr long long kOsRes = 1000;
            std::vector<std::pair<long long, uint32_t>> hist;
            for (uint32_t i = 0; i < n_kept; ++i) {
                int o, s;
                std::memcpy(&o, &aff_in[static_cast<size_t>(i) * kKpStride + 5], 4);
                std::memcpy(&s, &aff_in[static_cast<size_t>(i) * kKpStride + 6], 4);
                const long long os = static_cast<long long>(o) * kOsRes + s;
                bool found = false;
                for (auto& e : hist) {
                    if (e.first == os) { ++e.second; found = true; break; }
                }
                if (!found) hist.emplace_back(os, 1u);
            }
            std::sort(hist.begin(), hist.end(),
                      [](const auto& a, const auto& b) { return a.first > b.first; });
            long long guard_os = LLONG_MIN;  // 最细保留组 G_{j*+1} 的 os 键
            unsigned long long cum = 0;
            for (size_t j = 0; j < hist.size(); ++j) {
                cum += hist[j].second;
                if (cum >= static_cast<unsigned long long>(max_features)) {
                    if (j + 1 < hist.size()) {
                        prune_validate_os = hist[j].first;
                        guard_os = hist[j + 1].first;
                    }
                    break;
                }
            }
            if (guard_os != LLONG_MIN) {
                std::vector<uint32_t> pruned;
                pruned.reserve(aff_in.size());
                for (uint32_t i = 0; i < n_kept; ++i) {
                    int o, s;
                    std::memcpy(&o, &aff_in[static_cast<size_t>(i) * kKpStride + 5], 4);
                    std::memcpy(&s, &aff_in[static_cast<size_t>(i) * kKpStride + 6], 4);
                    const long long os = static_cast<long long>(o) * kOsRes + s;
                    if (os >= guard_os) {
                        const uint32_t* r =
                            aff_in.data() + static_cast<size_t>(i) * kKpStride;
                        for (uint32_t w = 0; w < kKpStride; ++w) pruned.push_back(r[w]);
                    }
                }
                const uint32_t n_pruned =
                    static_cast<uint32_t>(pruned.size() / kKpStride);
                if (n_pruned < n_kept) {
                    aff_in_full.swap(aff_in);  // 全量备份(fail-safe 重跑用)
                    aff_in.swap(pruned);
                    n_kept = n_pruned;
                    did_prune = true;
                } else {
                    prune_validate_os = LLONG_MIN;
                }
            } else {
                prune_validate_os = LLONG_MIN;
            }
        }
    }

    // [PRECLAMP-PRUNE] 剪枝失准时(k=0 过多)整段重跑 affine+orient,故
    // stage C/D 包进 attempt 环;重跑不再 mark()(sed_idx 顺序推进,重复
    // mark 会串桶),其成本落进 clamp 桶 —— 稀有路径,可观测不失真。
    wgpu::Buffer ori_out_buf, ori_counter, dbg_buf;
    uint32_t n_oriented = 0;
    std::vector<uint32_t> ori_all;
    for (int prune_attempt = 0;; ++prune_attempt) {
    const bool prune_first_attempt = (prune_attempt == 0);

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
        // [2D-DISPATCH 2026-08-10] WebGPU 单维派发上限 65535;n_kept 超限
        // (128k 检测上限后实测 80,904)按 (x<=65535, y=层数) 拆分,shader 里
        // kp = y*65535+x 重组;n<=65535 时 y=1 逐位同旧。
        {
            using BB = DawnKernelHarness::BufBinding;
            harness.dispatch(pipe_aff,
                             {w256_kp(packed, pyr), BB(meta_buf), BB(aff_in_buf),
                              BB(ell_buf), BB(p_buf)},
                             std::min(n_kept, 65535u),
                             (n_kept + 65534u) / 65535u, 1u);
        }
    }
    std::vector<uint32_t> ell_raw =
        read_u32(harness, ell_buf, static_cast<size_t>(n_kept) * 5);
    if (prune_first_attempt) mark("affine+readback");
    if (dawn_failed("affine")) {
        return false;
    }

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
        sed_set_fail_reason("nan_affine");
        return false;
    }

    // ════════════════ Stage D: orientation (1→K) ════════════════
    wgpu::Buffer ori_in_buf =
        harness.upload(ori_in.data(), ori_in.size() * sizeof(uint32_t),
                       wgpu::BufferUsage::Storage);
    ori_counter = harness.upload(
        &zero, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<uint32_t> ori_out_init(static_cast<size_t>(kOrientCap) * kKpStride,
                                       0u);
    ori_out_buf = harness.upload(
        ori_out_init.data(), ori_out_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<float> dbg_init(static_cast<size_t>(kOrientCap) * 2, 0.0f);
    wgpu::BufferUsage dbg_usage = wgpu::BufferUsage::Storage;
    if (canonical_selection || coverage_selection) {
        dbg_usage |= wgpu::BufferUsage::CopySrc;
    }
    dbg_buf =
        harness.upload(dbg_init.data(), dbg_init.size() * sizeof(float),
                       dbg_usage);
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
        // [ORIENT-ATOMIC 2026-08-10 用户签] 36 格定点原子黑板版默认开;
        // kill switch:OFFICIAL_AETHER_ORIENT_ATOMIC=0 回原版。
        static const bool orient_atomic_on = [] {
            const char* v = std::getenv("OFFICIAL_AETHER_ORIENT_ATOMIC");
            return v == nullptr || !(v[0] == '0' && v[1] == '\0');
        }();
        wgpu::ComputePipeline pipe_ori = harness.load_compute(
            load_wgsl(orient_atomic_on ? "sift_orientation_atomic.wgsl"
                                       : "sift_orientation.wgsl"));
        // [2D-DISPATCH 2026-08-10] 同 affine:二维拆分过 65535 上限。
        {
            using BB = DawnKernelHarness::BufBinding;
            harness.dispatch(pipe_ori,
                             {w256_kp(packed, pyr), BB(meta_buf), BB(ori_in_buf),
                              BB(ori_out_buf), BB(ori_counter), BB(dbg_buf),
                              BB(p_buf)},
                             std::min(n_kept, 65535u),
                             (n_kept + 65534u) / 65535u, 1u);
        }
    }
    n_oriented = read_u32(harness, ori_counter, 1)[0];
    if (std::getenv("W256_DIAG")) {
        std::fprintf(stderr,
                     "[W256] n_detect=%u n_kept=%u n_oriented=%u "
                     "kp_region=%.1fMB packed_total=%.1fMB (bind cap 256MB)\n",
                     static_cast<unsigned>(n_detect), static_cast<unsigned>(n_kept),
                     static_cast<unsigned>(n_oriented),
                     pyr.keypoint_region_end() * 4.0 / 1048576.0,
                     pyr.packed_total_elems() * 4.0 / 1048576.0);
    }
    if (prune_first_attempt) mark("orient (1->K)");
    if (dawn_failed("orientation")) {
        return false;
    }
    if (std::getenv("SED_DEBUG")) {
        std::cerr << "[SiftExtractDawn] n_detect=" << n_detect
                  << " n_kept(suppress)=" << n_kept
                  << " n_oriented=" << n_oriented << "\n";
    }
    if (n_oriented > kOrientCap) {
        std::cerr << "[SiftExtractDawn] orient overflow " << n_oriented << " > "
                  << kOrientCap << " (fallback)\n";
        char why[96];
        std::snprintf(why, sizeof(why), "orient_overflow n=%u cap=%u",
                      n_oriented, kOrientCap);
        sed_set_fail_reason(why);
        return false;
    }
    if (n_oriented == 0) {
        if (did_prune) {
            // [PRECLAMP-PRUNE] 剪枝集定向产出为空(病态 k=0)——不许据此
            // 判空帧,全量重跑后再定夺。
            std::cerr << "[PRECLAMP-PRUNE] pruned set yielded 0 orientations "
                         "— rerunning full set\n";
            aff_in.swap(aff_in_full);
            n_kept = n_kept_full;
            did_prune = false;
            continue;
        }
        aether_preclamp_instr_v1::DiscardPending(
            aether_preclamp_instr_v1::PendingDiscardReason::kZeroCandidate);
        return true;
    }
    ori_all = read_u32(
        harness, ori_out_buf, static_cast<size_t>(n_oriented) * kKpStride);
    if (!did_prune || prune_validate_os == LLONG_MIN) break;
    {
        // [PRECLAMP-PRUNE] 校验:粗于最细保留组(即 G0..G_{j*})的定向产物
        // 数 >= max_features ⇒ 真实断点 m <= j*,幸存集 ⊆ 保留组 ⇒ 与全量
        // 跑逐点相同。不满足(k=0 太多)则全量重跑 —— 只多花一次,不丢。
        constexpr long long kOsResV = 1000;
        unsigned long long coarse_ori = 0;
        for (uint32_t i = 0; i < n_oriented; ++i) {
            int o, s;
            std::memcpy(&o, &ori_all[static_cast<size_t>(i) * kKpStride + 6], 4);
            std::memcpy(&s, &ori_all[static_cast<size_t>(i) * kKpStride + 7], 4);
            if (static_cast<long long>(o) * kOsResV + s >= prune_validate_os)
                ++coarse_ori;
        }
        if (coarse_ori >= static_cast<unsigned long long>(max_features)) break;
        std::cerr << "[PRECLAMP-PRUNE] validation failed coarse_ori="
                  << coarse_ori << " < max_features=" << max_features
                  << " — rerunning full set\n";
        aff_in.swap(aff_in_full);
        n_kept = n_kept_full;
        did_prune = false;
    }
    }  // for (prune_attempt)
    aether_preclamp_instr_v1::BeginLegacyClamp(n_oriented);
    // Preserve the frozen legacy clamp block below byte-for-byte. Canonical
    // mode bypasses it by temporarily disabling its existing max_features
    // condition, then applies the shared exact selector after the frozen mark.
    const int requested_max_features = max_features;
    if (canonical_selection) {
        max_features = 0;
    }

    // ════════════════ COLMAP clamp BEFORE descriptor (sift.cc:403-444) ════════
    // Read the oriented kp records, sort the 1→K-expanded set by (octave desc,
    // scale desc), apply the per-(octave,scale)-group cap rule, and keep only the
    // ≤max_features survivors. The descriptor stage then runs over THIS subset —
    // the dominant cost shrinks from ~21000-27000 to ~max_features keypoints. The
    // surviving descriptors are bit-identical (deterministic per-keypoint); the
    // set is exactly COLMAP's. Repack the survivors into a dense buffer.
    // [PRECLAMP-PRUNE] ori_all 已在 attempt 环内读回(校验需要),此处直接用。
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
    // [Q5A-AUDIT 2026-08-08] env 门控纯观测(默认关,不改任何缓冲/结果)。
    // 量化 (o,s) 预剪枝的**可证明上界**:COLMAP clamp 按 (octave desc,
    // scale desc) 排序,且只在 **组边界** 处停(sift.cc:430-439,见上面的
    // 循环:os != prev_os && kept >= max 才 break)⇒ 幸存集永远是若干个
    // **完整**的 (o,s) 组。因此任何 (o,s) 严格小于幸存最小组的候选点,其
    // 全部 1→K 定向产物都必然排在幸存组之后、必被裁掉 —— 对这些候选跑
    // affine/orient 是 100% 白工,砍掉它们对输出的影响恰好为零。
    // 这里只统计"能砍多少",不实际砍。
    static const bool q5a_audit = [] {
        const char* v = std::getenv("OFFICIAL_AETHER_Q5A_AUDIT");
        return v != nullptr && v[0] == '1' && v[1] == '\0';
    }();
    if (q5a_audit) {
        constexpr long long kOsRes = 1000;
        long long os_min = 0;
        bool have_min = false;
        for (uint32_t i = 0; i < n_desc; ++i) {
            int o, s;
            std::memcpy(&o, &ori_all[static_cast<size_t>(i) * kKpStride + 6], 4);
            std::memcpy(&s, &ori_all[static_cast<size_t>(i) * kKpStride + 7], 4);
            const long long os = static_cast<long long>(o) * kOsRes + s;
            if (!have_min || os < os_min) { os_min = os; have_min = true; }
        }
        uint32_t prunable = 0;
        for (uint32_t i = 0; i < n_kept; ++i) {
            int o, s;
            std::memcpy(&o, &aff_in[static_cast<size_t>(i) * kKpStride + 5], 4);
            std::memcpy(&s, &aff_in[static_cast<size_t>(i) * kKpStride + 6], 4);
            const long long os = static_cast<long long>(o) * kOsRes + s;
            if (have_min && os < os_min) ++prunable;
        }
        // 07-29 设计书自己给的**保守 k=1 下界**规则(它才是可在 affine 之前
        // 落地的那个,因为它只用 det 阶段就已知的 (o,s) 直方图):
        // 按 (o,s) 降序累加候选数 c_i(每点至少 1 个方向),取第一个使
        // 累计 >= max_features 的组 M;真实 break 组 m <= M,故严格细于 M
        // 的组在任何 k∈[1,4] 下都必被丢弃 —— 这是设计书宣称"逐字节不变"
        // 的那部分。下面同时报出它,与上面的"事后最优"上界对照。
        std::vector<std::pair<long long, uint32_t>> hist;
        for (uint32_t i = 0; i < n_kept; ++i) {
            int o, s;
            std::memcpy(&o, &aff_in[static_cast<size_t>(i) * kKpStride + 5], 4);
            std::memcpy(&s, &aff_in[static_cast<size_t>(i) * kKpStride + 6], 4);
            const long long os = static_cast<long long>(o) * kOsRes + s;
            bool found = false;
            for (auto& e : hist) {
                if (e.first == os) { ++e.second; found = true; break; }
            }
            if (!found) hist.emplace_back(os, 1u);
        }
        std::sort(hist.begin(), hist.end(),
                  [](const auto& a, const auto& b) { return a.first > b.first; });
        // ⚠️ 关键的 off-by-one:clamp 的 break 条件是"进入**新组的第一条**记录
        // 且 kept >= max",所以它保留的是「完整的 1..m 组」**外加 m+1 组的
        // 第一条记录」。因此可安全剪掉的是严格细于 **m+1** 组的部分,不是
        // 严格细于 m 组。少算这一格会砍掉一个真实幸存点(实测正是如此)。
        long long os_safe = LLONG_MIN;
        unsigned long long cum = 0;
        for (size_t j = 0; j < hist.size(); ++j) {
            cum += hist[j].second;
            if (max_features > 0 &&
                cum >= static_cast<unsigned long long>(max_features)) {
                if (j + 1 < hist.size()) os_safe = hist[j + 1].first;
                break;
            }
        }
        uint32_t prunable_safe = 0;
        if (os_safe != LLONG_MIN) {
            for (const auto& e : hist) {
                if (e.first < os_safe) prunable_safe += e.second;
            }
        }
        // 逐组对照:候选数 c_i(定向前)vs 定向产物数 o_i。设计书的证明
        // 假设 k∈[1,4](每个候选点至少产出 1 个方向)⇒ o_i >= c_i。
        // 若实测出现 o_i < c_i,说明 k 可以为 0,那条"保守下界"就不成立。
        std::vector<uint32_t> ori_full = read_u32(
            harness, ori_out_buf, static_cast<size_t>(n_oriented) * kKpStride);
        std::vector<std::pair<long long, uint32_t>> ohist;
        for (uint32_t i = 0; i < n_oriented; ++i) {
            int o, s;
            std::memcpy(&o, &ori_full[static_cast<size_t>(i) * kKpStride + 6], 4);
            std::memcpy(&s, &ori_full[static_cast<size_t>(i) * kKpStride + 7], 4);
            const long long os = static_cast<long long>(o) * kOsRes + s;
            bool found = false;
            for (auto& e : ohist) {
                if (e.first == os) { ++e.second; found = true; break; }
            }
            if (!found) ohist.emplace_back(os, 1u);
        }
        unsigned long long cc = 0, co = 0;
        int shown = 0, shrink_groups = 0;
        for (const auto& e : hist) {
            uint32_t oi = 0;
            for (const auto& g : ohist) {
                if (g.first == e.first) { oi = g.second; break; }
            }
            cc += e.second;
            co += oi;
            if (oi < e.second) ++shrink_groups;
            if (shown < 12) {
                std::fprintf(stderr,
                             "[Q5A-GROUP] os=%-6lld cand=%-6u ori=%-6u "
                             "cum_cand=%-7llu cum_ori=%-7llu %s\n",
                             e.first, e.second, oi, cc, co,
                             oi < e.second ? "<-- ori<cand (k=0 存在)" : "");
                ++shown;
            }
        }
        // 证明真正需要的条件不是逐组 o_i >= c_i,而是**每个前缀**
        // cum_ori >= cum_cand。前缀一旦破,保守阈值就可能过粗、砍掉真幸存点。
        unsigned long long pc = 0, po = 0;
        int prefix_violations = 0;
        for (const auto& e : hist) {
            uint32_t oi = 0;
            for (const auto& g : ohist) {
                if (g.first == e.first) { oi = g.second; break; }
            }
            pc += e.second;
            po += oi;
            if (po < pc) ++prefix_violations;
        }
        std::fprintf(stderr,
                     "[Q5A-AUDIT] groups_with_ori_lt_cand=%d/%zu "
                     "prefix_violations=%d\n",
                     shrink_groups, hist.size(), prefix_violations);
        std::fprintf(stderr,
                     "[Q5A-AUDIT] n_detect=%u n_kept=%u n_oriented=%u "
                     "n_desc=%u max_feat=%d groups=%zu | posthoc_os_min=%lld "
                     "prunable_max=%u (%.2f%%) | conservative_os=%lld "
                     "prunable_safe=%u (%.2f%%)\n",
                     n_detect, n_kept, n_oriented, n_desc, max_features,
                     hist.size(), os_min, prunable,
                     n_kept ? 100.0 * prunable / n_kept : 0.0, os_safe,
                     prunable_safe,
                     n_kept ? 100.0 * prunable_safe / n_kept : 0.0);
    }
    aether_preclamp_instr_v1::UpdateLegacyClampResult(n_desc);
    max_features = requested_max_features;

    if (canonical_selection || coverage_selection) {
        const std::vector<uint32_t> full_orientation_sidecar =
            read_u32(harness, dbg_buf,
                     static_cast<size_t>(n_oriented) * 2);
        std::vector<uint32_t> coverage_orientation_sidecar;
        std::span<const uint32_t> orientation_sidecar =
            full_orientation_sidecar;
        if (coverage_selection) {
            const std::vector<uint32_t> full_oriented_rows =
                read_u32(harness, ori_out_buf,
                         static_cast<size_t>(n_oriented) * kKpStride);
            const auto sidecar_gather_status =
                aether::sfm::GatherSelectedSidecarByRowsV1(
                    full_oriented_rows, ori_all, full_orientation_sidecar,
                    &coverage_orientation_sidecar);
            if (sidecar_gather_status !=
                aether::sfm::SelectedSidecarGatherStatusV1::kOk) {
                std::cerr << "[SiftExtractDawn] coverage sidecar gather failed status="
                          << static_cast<uint32_t>(sidecar_gather_status)
                          << " (fallback)\n";
                return false;
            }
            orientation_sidecar = coverage_orientation_sidecar;
        }
        std::vector<aether::sfm::CanonicalFeatureCandidateV1> candidates;
        const auto build_status =
            aether::sfm::BuildCanonicalCandidatesFromSidecarV1(
                ori_all, orientation_sidecar, aff_in, &candidates);
        if (build_status !=
            aether::sfm::CanonicalCandidateBuildStatusV1::kOk) {
            std::cerr << "[SiftExtractDawn] canonical sidecar invalid status="
                      << static_cast<uint32_t>(build_status)
                      << " (fallback)\n";
            return false;
        }

        aether::sfm::CanonicalFeatureSelectionV1 selection;
        const uint32_t canonical_cap =
            requested_max_features > 0
                ? static_cast<uint32_t>(requested_max_features)
                : static_cast<uint32_t>(candidates.size());
        const auto select_status = coverage_selection
            ? aether::sfm::SelectCoverageFeaturesV1(
                  candidates, canonical_cap, static_cast<uint32_t>(width),
                  static_cast<uint32_t>(height), &selection)
            : aether::sfm::SelectCanonicalFeaturesV1(
                  candidates, canonical_cap, &selection);
        if (select_status !=
            aether::sfm::CanonicalFeatureSelectionStatusV1::kOk) {
            std::cerr << "[SiftExtractDawn] feature selector failed status="
                      << static_cast<uint32_t>(select_status)
                      << " (fallback)\n";
            return false;
        }

        std::vector<uint32_t> canonical_rows;
        const auto gather_status = aether::sfm::GatherCanonicalRowsV1(
            ori_all, kKpStride, selection.input_indices, &canonical_rows);
        if (gather_status !=
            aether::sfm::CanonicalRowGatherStatusV1::kOk) {
            std::cerr << "[SiftExtractDawn] canonical row gather failed status="
                      << static_cast<uint32_t>(gather_status)
                      << " (fallback)\n";
            return false;
        }
        n_desc = static_cast<uint32_t>(selection.input_indices.size());
        out->stable_ids = std::move(selection.stable_ids);
        ori_all = std::move(canonical_rows);
        if (n_desc > 0) {
            desc_in_buf = harness.upload(
                ori_all.data(), ori_all.size() * sizeof(uint32_t),
                wgpu::BufferUsage::Storage);
        }

        // The frozen legacy mark precedes this deterministic readback/select
        // block so its source SHA remains an exact oracle. Fold the extra host
        // and transfer cost back into the same clamp accounting bucket, then
        // reset t_prev so the descriptor stage does not double-count it.
        if (observe_timing) {
            const auto now = std::chrono::high_resolution_clock::now();
            g_aether_sed_stage_ms[6] +=
                std::chrono::duration<double, std::milli>(now - t_prev)
                    .count();
            const auto& h = harness.host_breakdown();
            hb_stage[6][0] += h.upload_ms - hb_snap.upload_ms;
            hb_stage[6][1] += h.encode_ms - hb_snap.encode_ms;
            hb_stage[6][2] += h.submit_wait_ms - hb_snap.submit_wait_ms;
            hb_stage[6][3] += h.map_ms - hb_snap.map_ms;
            hb_stage[6][4] += h.create_ms - hb_snap.create_ms;
            hb_snap = h;
            t_prev = now;
        }
        if (n_desc == 0) {
            out->xy.clear();
            out->octave.clear();
            out->scale.clear();
            out->kp_scale.clear();
            out->kp_orientation.clear();
            out->raw_desc.clear();
            out->count = 0;
            return true;
        }
    }

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
            {
                using BB = DawnKernelHarness::BufBinding;
                harness.dispatch(pipe_par,
                                 {w256_kp(packed, pyr), BB(meta_buf),
                                  BB(desc_in_buf), BB(scale_desc), BB(p_buf2)},
                                 groups_x, groups_y, 1u);
            }
            struct MeanParams { uint32_t count; } MP{n_oriented};
            wgpu::Buffer mp_buf =
                harness.upload(&MP, sizeof(MP), wgpu::BufferUsage::Uniform);
            wgpu::ComputePipeline pipe_mean =
                harness.load_compute(load_wgsl("sift_dsp_mean.wgsl"));
            {
                // [2D-DISPATCH 2026-08-10] groups=2n 可超 65535(n_oriented
                // 40,452 实测 X=80,904 爆限)。
                const uint32_t mg = (n_oriented * 128u + 63u) / 64u;
                harness.dispatch(pipe_mean, {scale_desc, rd_buf, mp_buf},
                                 std::min(mg, 65535u),
                                 (mg + 65534u) / 65535u, 1u);
            }
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
            // [DESC-ATOMIC 2026-08-10 用户签 cosine>=0.998 门] f16 设备默认走
            // 定点共享原子加版(消私有 lh[128]+归约树);kill switch:
            // OFFICIAL_AETHER_DESC_ATOMIC=0 回 _f16 版。非 f16 设备维持 f32 版。
            static const bool atomic_on = [] {
                const char* v = std::getenv("OFFICIAL_AETHER_DESC_ATOMIC");
                return v == nullptr || !(v[0] == '0' && v[1] == '\0');
            }();
            const char* desc_shader = want_f16
                ? (atomic_on ? "sift_dsp_descriptor_f16_atomic.wgsl"
                             : "sift_dsp_descriptor_f16.wgsl")
                : "sift_dsp_descriptor.wgsl";
            wgpu::ComputePipeline pipe_desc =
                harness.load_compute(load_wgsl(desc_shader));
            // [2D-DISPATCH 2026-08-10] n_oriented 可超 65535,二维拆分。
            {
                using BB = DawnKernelHarness::BufBinding;
                harness.dispatch(pipe_desc,
                                 {w256_kp(packed, pyr), BB(meta_buf),
                                  BB(desc_in_buf), BB(rd_buf), BB(p_buf)},
                                 std::min(n_oriented, 65535u),
                                 (n_oriented + 65534u) / 65535u, 1u);
            }
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
    out->kp_scale.resize(n_oriented);
    out->kp_orientation.resize(n_oriented);
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
        // [SCALE-PERSIST 2026-08-06] oriented kp record slots [2..5] hold the
        // rotated affine ellipse (a11,a12,a21,a22) — see sift_orientation.wgsl
        // OUT_STRIDE layout. Reduce with COLMAP's official formulas
        // (FeatureKeypoint::ComputeScale/ComputeScaleX/ComputeScaleY/
        // ComputeOrientation, colmap/feature/types.cc:137-151), verbatim.
        float a11, a12, a21, a22;
        std::memcpy(&a11, &r[2], 4);
        std::memcpy(&a12, &r[3], 4);
        std::memcpy(&a21, &r[4], 4);
        std::memcpy(&a22, &r[5], 4);
        const float scale_x = std::sqrt(a11 * a11 + a21 * a21);
        const float scale_y = std::sqrt(a12 * a12 + a22 * a22);
        out->kp_scale[i] = (scale_x + scale_y) / 2.0f;
        out->kp_orientation[i] = std::atan2(a21, a11);
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
        sed_set_fail_reason("nan_descriptor");
        return false;
    }
    // 最后一道:定向/描述子阶段若出过 Dawn 错误,上面读回的就是脏数据,
    // 宁可让调用方走 CPU 回退,也不能把它当成功交出去。
    if (dawn_failed("orient/descriptor")) {
        return false;
    }

    // [GPU-TS 2026-07-29] Publish evidence only after every check that can
    // reject the GPU result. If NaN/device validation forces the C ABI to fall
    // back to CPU, no valid GPU-success frame may survive that attempt.
    // [GPU-TS-DIAG 2026-08-08] env 门控隔离插桩,默认完全关闭。
    static const bool ts_diag = [] {  // 每进程一次 getenv,默认 false
        const char* v = std::getenv("OFFICIAL_AETHER_GPU_TS_DIAG");
        return v != nullptr && v[0] == '1' && v[1] == '\0';
    }();
    if (ts_diag) {
        std::fprintf(stderr,
                     "[GPU-TS-DIAG] sed gpu_ts_enabled=%d pass_count=%u "
                     "bounds=%u,%u,%u,%u,%u,%u,%u,%u,%u\n",
                     harness.gpu_ts_enabled() ? 1 : 0,
                     harness.gpu_ts_pass_count(), ts_bounds[0], ts_bounds[1],
                     ts_bounds[2], ts_bounds[3], ts_bounds[4], ts_bounds[5],
                     ts_bounds[6], ts_bounds[7], ts_bounds[8]);
    }
    // [HOST-BD 2026-09-08] 外层门也绑在 GPU 时间戳上 ⇒ Mali(无 TimestampQuery)
    // 一行都出不来。放开:只要主机侧分解开着就进来,gpu 列留 0。
    if (harness.gpu_ts_enabled() || harness.host_breakdown().n_dispatch > 0) {
        std::vector<uint64_t> pass_ns;
        const bool ts_resolved = harness.gpu_ts_resolve(&pass_ns);
        const bool ts_final =
            ts_resolved &&
            harness.gpu_ts_finalize_frame(ts_bounds, kAetherSedStageCount);
        if (ts_diag) {
            std::fprintf(stderr,
                         "[GPU-TS-DIAG] sed resolve=%d finalize=%d "
                         "pass_ns=%zu\n",
                         ts_resolved ? 1 : 0, ts_final ? 1 : 0, pass_ns.size());
        }
        // [HOST-BD 2026-09-08] 没有 TimestampQuery 的设备(Mali-G72)也要能看
        // 主机侧分解 —— gpu 列留 0,encode/wait/own-loop 照样成立。
        if (ts_final || harness.host_breakdown().n_dispatch > 0) {
            uint32_t lo = 0;
            for (int s = 0; s < kAetherSedStageCount; ++s) {
                const uint32_t hi =
                    ts_bounds[s] < pass_ns.size()
                        ? ts_bounds[s]
                        : static_cast<uint32_t>(pass_ns.size());
                double ns = 0.0;
                for (uint32_t p = lo; p < hi; ++p) ns += double(pass_ns[p]);
                g_aether_sed_stage_gpu_ms[s] = ns / 1.0e6;
                lo = hi;
            }
            if (timing) {
                static const char* kStage[kAetherSedStageCount] = {
                    "pyramid", "pack", "detect", "suppress", "affine",
                    "orient",  "clamp", "descriptor", "desc-rb"};
                const auto& H = harness.host_breakdown();
                std::printf(
                    "  [SED-SPLIT] passes=%zu dispatches=%u uploads=%u "
                    "readbacks=%u pipeline_compiles=%u (%.1f ms)\n",
                    pass_ns.size(), H.n_dispatch, H.n_upload, H.n_readback,
                    H.n_create, H.create_ms);
                std::printf("  %-12s %8s %8s %8s %8s %8s %8s %8s %10s\n",
                            "stage", "host", "gpu", "compile", "upload",
                            "encode", "wait", "map", "own-loop");
                for (int s = 0; s < kAetherSedStageCount; ++s) {
                    const double host = g_aether_sed_stage_ms[s];
                    const double gpu = g_aether_sed_stage_gpu_ms[s];
                    // `wait` already contains the GPU time it was waiting on,
                    // so it must not be double-counted against the residual.
                    const double harness_cpu = hb_stage[s][0] + hb_stage[s][1] +
                                               hb_stage[s][2] + hb_stage[s][3] +
                                               hb_stage[s][4];
                    std::printf(
                        "  %-12s %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %10.1f\n",
                        kStage[s], host, gpu, hb_stage[s][4], hb_stage[s][0],
                        hb_stage[s][1], hb_stage[s][2], hb_stage[s][3],
                        host - harness_cpu);
                }
                std::fflush(stdout);
            }
        }
    }
    return true;
}

}  // namespace tools
}  // namespace aether
