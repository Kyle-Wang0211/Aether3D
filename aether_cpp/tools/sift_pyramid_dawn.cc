#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <cstdio>
#include <cstdlib>
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "sift_pyramid_dawn.h"

#include <algorithm>
#include <cmath>
#include <vector>
#include <cstring>
#include <iostream>
#include <string>

#ifdef AETHER_WGSL_DIR
// Host parity benches define AETHER_WGSL_DIR and read shaders from the tree
// (no baked .cpp linked into those targets).
#include <fstream>
#include <sstream>
#else
// iOS / production: no filesystem — use the baked-in WGSL symbols.
#include "aether/shaders/wgsl_sources.h"
#include <string_view>
#endif

namespace aether {
namespace tools {

namespace {

// Three M0 passes: gray_to_f32, gss_blur, gss_resample. On host (AETHER_WGSL_DIR
// defined) read from the tree; on iOS use the baked aether::shaders::*_wgsl
// symbols (zero filesystem dependency).
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
        std::cerr << "[SiftPyramidDawn] cannot open WGSL: " << path << '\n';
        std::abort();
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
#else
    using namespace aether::shaders;
    const std::string_view fn(filename);
    if (fn == "sift_gray_to_f32.wgsl")   return std::string(sift_gray_to_f32_wgsl);
    if (fn == "sift_gss_blur.wgsl")      return std::string(sift_gss_blur_wgsl);
    if (fn == "sift_gss_resample.wgsl")  return std::string(sift_gss_resample_wgsl);
    if (fn == "sift_gss_blur_fused.wgsl") return std::string(sift_gss_blur_fused_wgsl);
    std::cerr << "[SiftPyramidDawn] unknown WGSL: " << filename << '\n';
    std::abort();
#endif
}

// VLFeat _vl_new_gaussian_fitler_f (imopv.c:620): width = ceil(sigma*3), the
// FIR is sampled exp(-0.5*(i/sigma)^2) and L1-normalized. Computed in double
// to be bit-identical to the CPU reference; the GPU only does the f32 FIR dot.

// [K8 PYR-PERSIST 2026-09-06] 金字塔三个大缓冲(packed ≈ 390 MB @12MP、
// scratch/tmp 各 ≈ 49 MB)原来每帧新建;Dawn 对新建 storage buffer 首次使用
// 时惰性清零(lazy_clear_resource_on_first_use)⇒ 每帧白写 ≈ 490 MB 的 0
// (Mac M3 实测 pyramid 段 wait 45.7 ms vs GPU 计算 20.7 ms 的差就是它)。
// 这里按 (device, size) 复用上一帧的缓冲。无损:每一层都在本帧被整段写满
// (gray→f32 / blur / resample 都是全层写),读到的每个 f32 都是本帧写的。
// kill switch:OFFICIAL_AETHER_PYR_PERSIST=0。
namespace {
struct PersistBuf {
    int slot = -1;
    WGPUDevice dev = nullptr;
    size_t size = 0;
    wgpu::Buffer buf;
};
// 0 packed, 1 seed scratch, 2 seed tmp, 3 octave scratch(2-pass,按 size 分条目)
thread_local std::vector<PersistBuf> g_pyr_persist;
// [K8 策略 2026-09-06 用户裁决] 三端一致:默认**不常驻**(每帧现分配,与原来
// 相同);OFFICIAL_AETHER_PYR_PERSIST=1 开启"拍摄会话内复用",配合
// aether_pyr_persist_release()(会话结束 / 内存告警时由产品层调用,iOS
// didReceiveMemoryWarning 与 Android onTrimMemory 走同一接口)。不用任何
// 平台独有机制(Metal purgeable 已撤)。
bool pyr_persist_on() {
    static const bool on = [] {
        const char* v = std::getenv("OFFICIAL_AETHER_PYR_PERSIST");
        return v != nullptr && v[0] == '1' && v[1] == '\0';
    }();
    return on;
}
wgpu::Buffer pyr_persist_alloc(aether::tools::DawnKernelHarness& h, int slot,
                               size_t size, wgpu::BufferUsage usage) {
    if (!pyr_persist_on()) return h.alloc(size, usage);
    const WGPUDevice dev = h.device().Get();
    for (auto& p : g_pyr_persist) {
        if (p.slot == slot && p.dev == dev && p.size == size) return p.buf;
    }
    // 同 slot 的旧条目(尺寸/设备变了)丢掉,避免无限增长;slot 3 按尺寸留多条。
    if (slot != 3) {
        g_pyr_persist.erase(
            std::remove_if(g_pyr_persist.begin(), g_pyr_persist.end(),
                           [&](const PersistBuf& p) { return p.slot == slot; }),
            g_pyr_persist.end());
    }
    PersistBuf nb; nb.slot = slot; nb.dev = dev; nb.size = size;
    nb.buf = h.alloc(size, usage);
    g_pyr_persist.push_back(nb);
    return nb.buf;
}
}  // namespace

// 产品层在拍摄会话结束 / 内存告警时调用(三端同一接口):释放本线程的常驻缓冲。
extern "C" void aether_pyr_persist_release() { g_pyr_persist.clear(); }
// 兼容:帧末钩子(当前策略下无操作,保留调用点)。
extern "C" void aether_pyr_persist_end_frame() {}

std::vector<float> make_gaussian_taps(double sigma) {
    const int width = static_cast<int>(std::ceil(sigma * 3.0));
    const int size = 2 * width + 1;
    std::vector<double> filt(static_cast<size_t>(size));
    double mass = 1.0;
    filt[static_cast<size_t>(width)] = 1.0;
    for (int i = 1; i <= width; ++i) {
        const double x = static_cast<double>(i) / sigma;
        const double g = std::exp(-0.5 * x * x);
        mass += g + g;
        filt[static_cast<size_t>(width - i)] = g;
        filt[static_cast<size_t>(width + i)] = g;
    }
    std::vector<float> taps(static_cast<size_t>(size));
    for (int i = 0; i < size; ++i) {
        taps[static_cast<size_t>(i)] = static_cast<float>(filt[static_cast<size_t>(i)] / mass);
    }
    return taps;
}

}  // namespace

double SiftPyramidDawn::base_scale() {
    return 1.6 * std::pow(2.0, 1.0 / static_cast<double>(kOctaveResolution));
}

double SiftPyramidDawn::level_sigma(int octave, int sublevel) {
    return base_scale() *
           std::pow(2.0, static_cast<double>(octave) +
                             static_cast<double>(sublevel) /
                                 static_cast<double>(kOctaveResolution));
}

SiftPyramidDawn::LevelGeom SiftPyramidDawn::level_geom(int octave,
                                                       int sublevel) const {
    LevelGeom g;
    g.octave = octave;
    g.sublevel = sublevel;
    g.width = width_ >> octave;
    g.height = height_ >> octave;
    g.sigma = level_sigma(octave, sublevel);
    return g;
}

bool SiftPyramidDawn::build(DawnKernelHarness& harness, const uint8_t* gray,
                            int width, int height) {
    if (width < 2 || height < 2 || gray == nullptr) {
        std::cerr << "[SiftPyramidDawn] invalid dimensions\n";
        return false;
    }
    width_ = width;
    height_ = height;

    // lastOctave per vl_covdet_put_image (covdet.c:1699):
    //   floor(log2(min(W-1,H-1) / (minOctaveSize-1)))
    const double r =
        static_cast<double>(std::min(width - 1, height - 1)) /
        static_cast<double>(kMinOctaveSize - 1);
    last_octave_ = static_cast<int>(std::floor(std::log2(r)));
    if (last_octave_ < 0) last_octave_ = 0;

    // ── Compile the three passes once ──
    const std::string s0_src = load_wgsl("sift_gray_to_f32.wgsl");
    const std::string s1_src = load_wgsl("sift_gss_blur.wgsl");
    const std::string s1b_src = load_wgsl("sift_gss_resample.wgsl");
    wgpu::ComputePipeline pipe_gray = harness.load_compute(s0_src);
    wgpu::ComputePipeline pipe_blur = harness.load_compute(s1_src);
    wgpu::ComputePipeline pipe_resample = harness.load_compute(s1b_src);
    // [GSS-FUSED 2026-08-10] H+V 融合 blur(FidelityFX Blur 结构,逐位同
    // 2-pass)。kill switch:OFFICIAL_AETHER_GSS_FUSED=0;radius>16 自动回落。
    static const bool fused_on = [] {
        const char* v = std::getenv("OFFICIAL_AETHER_GSS_FUSED");
        return v == nullptr || !(v[0] == '0' && v[1] == '\0');
    }();
    wgpu::ComputePipeline pipe_blur_fused =
        harness.load_compute(load_wgsl("sift_gss_blur_fused.wgsl"));

    const auto wg = [](int n) -> uint32_t {
        return static_cast<uint32_t>((n + 7) / 8);
    };

    // ── [PACK-ZERO 2026-08-10] 布局先行:全部层排进一个 packed 大缓冲 ──
    // 布局与旧 pack_levels() 的 meta 完全一致(逐层 element offset 前缀和),
    // blur/resample/gray 直写各自偏移 ⇒ pack 阶段零拷贝。数值逐位不变:
    // 只是像素的"住址"变了,每条数学路径原样。
    octaves_.assign(static_cast<size_t>(last_octave_ + 1), {});
    for (int o = 0; o <= last_octave_; ++o) {
        OctaveBuffers& ob = octaves_[static_cast<size_t>(o)];
        ob.width = width_ >> o;
        ob.height = height_ >> o;
    }
    // [W256 2026-09-07] 布局由 level_layout() 统一给出(64 元素对齐 + 不跨
    // 256 MB 窗口);pack_levels() 用同一函数复核。
    // [W256-BY-LIMIT 2026-09-08 用户批准] 先按设备能力定布局,再算布局。
    // 这里用 level_layout() 的**单区(w256=0)**递推算总量 —— 那正是旧布局下
    // 关键点阶段要一次绑上去的那一块的字节数,所以它就是判据本身,不是近似:
    // 绑得下就用旧布局(快),绑不下才切子区间。不构成循环依赖。
    {
        uint64_t req_elems = 0;
        for (int o = 0; o <= last_octave_; ++o) {
            const uint64_t n = static_cast<uint64_t>(width_ >> o) *
                               static_cast<uint64_t>(height_ >> o);
            for (int li = 0; li < kLevelsPerOctave; ++li) {
                req_elems = (req_elems + kAlignElems - 1u) / kAlignElems * kAlignElems;
                req_elems += n;
            }
        }
        wgpu::Limits dev_limits{};
        const uint64_t lim =
            harness.device().GetLimits(&dev_limits) == wgpu::Status::Success
                ? static_cast<uint64_t>(dev_limits.maxStorageBufferBindingSize)
                : 0ull;
        configure_w256_by_limit(req_elems * 4ull, lim);
        note_kp_bind(-1);
    }
    level_offsets_ = level_layout(width_, height_, last_octave_,
                                  &packed_total_elems_, &keypoint_region_end_);
    packed_buf_ = pyr_persist_alloc(harness, 0,
        static_cast<size_t>(packed_total_elems_) * sizeof(float),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
            wgpu::BufferUsage::CopyDst);

    // 层的身份 = packed 偏移(element)。
    const auto level_off = [&](int o, int s) -> uint32_t {
        return level_offsets_[static_cast<size_t>(o) * kLevelsPerOctave +
                              (s - kOctaveFirstSub)];
    };
    // [W256] 子区间绑定:[lo, hi) 元素 → 字节 offset/size。lo 总是某层起点
    // (64 元素对齐 = 256 B);每次 dispatch 只绑它真正触碰的层。
    const bool w256 = w256_bind_enabled();
    const auto rng = [&](uint32_t lo, uint32_t hi) {
        if (!w256) return DawnKernelHarness::BufBinding(packed_buf_);
        return DawnKernelHarness::BufBinding(
            packed_buf_, static_cast<uint64_t>(lo) * 4u,
            static_cast<uint64_t>(hi - lo) * 4u);
    };
    // 相对偏移:着色器里的 *_off 相对本次绑定的起点 lo(旧模式:绝对)。
    const auto rel = [&](uint32_t off, uint32_t lo) -> uint32_t {
        return w256 ? (off - lo) : off;
    };
    // resample 在两种模式下都绑两个不相交子区间(同缓冲两个可写绑定不得重叠)。
    const auto rng_always = [&](uint32_t lo, uint32_t hi) {
        return DawnKernelHarness::BufBinding(
            packed_buf_, static_cast<uint64_t>(lo) * 4u,
            static_cast<uint64_t>(hi - lo) * 4u);
    };
    using BB = DawnKernelHarness::BufBinding;

    // Run one separable Gaussian (h then v) from packed@src_off into
    // dst_buf@dst_off, sized (w,h), with kernel sigma `sigma_px` (already
    // divided by octave step). `scratch` is a same-sized separate intermediate
    // (offset 0). dst_buf 一般就是 packed_buf_(dst_off=层偏移);基层平滑的
    // 临时目标传独立 tmp(dst_off=0)。
    // [K2g 2026-09-06] 2-pass blur:src/dst/scratch 全在 packed_buf_ 里(单一
    // read_write 绑定 + 偏移),scratch 用"下一层的槽"(此刻尚未写入)。
    const auto blur = [&](uint32_t src_off, uint32_t dst_off, uint32_t scratch_off,
                          int w, int h, double sigma_px, uint32_t scratch_n) {
        const std::vector<float> taps = make_gaussian_taps(sigma_px);
        const uint32_t n = static_cast<uint32_t>(w) * static_cast<uint32_t>(h);
        const uint32_t lo = std::min({src_off, dst_off, scratch_off});
        const uint32_t hi =
            std::max({src_off + n, dst_off + n, scratch_off + scratch_n});
        const uint32_t radius = static_cast<uint32_t>((taps.size() - 1) / 2);
        wgpu::Buffer taps_buf = harness.upload(taps.data(),
                                               taps.size() * sizeof(float),
                                               wgpu::BufferUsage::Storage);
        struct BlurParams {
            uint32_t width, height, radius, axis, src_off, dst_off;
            uint32_t _pad0, _pad1;
        };
        BlurParams ph{static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                      radius, 0u, rel(src_off, lo), rel(scratch_off, lo), 0u, 0u};
        wgpu::Buffer ph_buf = harness.upload(&ph, sizeof(ph),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(pipe_blur, {rng(lo, hi), BB(taps_buf), BB(ph_buf)},
                                 wg(w), wg(h));
        BlurParams pv{static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                      radius, 1u, rel(scratch_off, lo), rel(dst_off, lo), 0u, 0u};
        wgpu::Buffer pv_buf = harness.upload(&pv, sizeof(pv),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(pipe_blur, {rng(lo, hi), BB(taps_buf), BB(pv_buf)},
                                 wg(w), wg(h));
    };

    // ── Batch the ENTIRE pyramid build (S0 + all blur passes + octave
    //    transitions) into ONE command submit. Per-dispatch submit+WaitAny sync
    //    latency dominated (measured: batching the 48 pack copies alone cut 64→
    //    35ms). Dawn tracks all storage-buffer hazards within the encoder, so the
    //    serial dependency chain (s reads s-1, resample reads prev octave) is
    //    preserved → bit-identical to per-call dispatch.
    harness.begin_batch();

    // ── S0: seed octave 0, base sublevel (s = octaveFirstSubdivision) from u8 ──
    // copy_and_downsample(numOctaves=0) is identity for octave 0, so the seed
    // is just gray/255 at full resolution.
    {
        // Upload u8 packed 4-per-word, tightly packed (no row padding).
        const size_t n = static_cast<size_t>(width_) * height_;
        const size_t words = (n + 3) / 4;
        std::vector<uint32_t> packed(words, 0u);
        std::memcpy(packed.data(), gray, n);
        wgpu::Buffer src_u8 =
            harness.upload(packed.data(), words * sizeof(uint32_t),
                           wgpu::BufferUsage::Storage);
        struct GrayParams {
            uint32_t width, height, dst_off, _pad;
        } gp{static_cast<uint32_t>(width_), static_cast<uint32_t>(height_),
             0u /* [W256] 绑定从 level0 起点开始;下面按旋钮改写 */, 0u};
        const uint32_t l0 = level_off(0, kOctaveFirstSub);
        gp.dst_off = rel(l0, l0);
        wgpu::Buffer gp_buf = harness.upload(&gp, sizeof(gp),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(
            pipe_gray,
            {BB(src_u8), rng(l0, l0 + static_cast<uint32_t>(n)), BB(gp_buf)},
            wg(width_), wg(height_));
    }

    // ── Octave 0 base-level smoothing (_vl_scalespace_start_octave_from_image) ──
    // sigma = sigma(0, octaveFirstSubdivision); imageSigma = nominalScale.
    // If sigma > imageSigma, smooth the seed in place by deltaSigma (step=1).
    {
        OctaveBuffers& ob0 = octaves_[0];
        const double sigma = level_sigma(0, kOctaveFirstSub);
        if (sigma > kNominalScale) {
            const double delta =
                std::sqrt(sigma * sigma - kNominalScale * kNominalScale);
            // [K2g] 种子原地平滑:H 从槽 A(level first)写到槽 B(level first+1,
            // 尚未使用),V 从 B 写回 A。零额外缓冲、零拷贝,数学与原 2-pass 相同。
            blur(level_off(0, kOctaveFirstSub), level_off(0, kOctaveFirstSub),
                 level_off(0, kOctaveFirstSub + 1), ob0.width, ob0.height,
                 delta /* /step, step=1 */,
                 static_cast<uint32_t>(ob0.width) *
                     static_cast<uint32_t>(ob0.height));
        }
    }

    const auto fill_octave = [&](int o) {
        OctaveBuffers& ob = octaves_[static_cast<size_t>(o)];
        const double step = std::pow(2.0, static_cast<double>(o));
        for (int s = kOctaveFirstSub + 1; s <= kOctaveLastSub; ++s) {
            const double sigma = level_sigma(o, s);
            const double prev = level_sigma(o, s - 1);
            const double delta = std::sqrt(sigma * sigma - prev * prev);
            const double sigma_px = delta / step;
            const std::vector<float> taps = make_gaussian_taps(sigma_px);
            const uint32_t radius =
                static_cast<uint32_t>((taps.size() - 1) / 2);
            if (fused_on && radius <= 16u) {
                // [GSS-FUSED] 单 dispatch,条带滑动;scratch 往返消失。
                wgpu::Buffer taps_buf = harness.upload(
                    taps.data(), taps.size() * sizeof(float),
                    wgpu::BufferUsage::Storage);
                struct FusedParams {
                    uint32_t width, height, radius, src_off;
                    uint32_t dst_off, _pad0, _pad1, _pad2;
                } fp{static_cast<uint32_t>(ob.width),
                     static_cast<uint32_t>(ob.height), radius,
                     rel(level_off(o, s - 1), level_off(o, s - 1)), rel(level_off(o, s), level_off(o, s - 1)), 0u, 0u, 0u};
                wgpu::Buffer fp_buf = harness.upload(
                    &fp, sizeof(fp), wgpu::BufferUsage::Uniform);
                harness.dispatch_batched(
                    pipe_blur_fused,
                    {rng(level_off(o, s - 1),
                         level_off(o, s) + static_cast<uint32_t>(ob.width) *
                                               static_cast<uint32_t>(ob.height)),
                     BB(taps_buf), BB(fp_buf)},
                    static_cast<uint32_t>((ob.width + 7) / 8), 1u);
            } else {
                // [K2g] scratch = 下一层的槽(本 octave 的 s+1;最后一层用下一
                // octave 的首层槽;最后 octave 的最后一层没有空槽 ⇒ 用 fused 核)。
                uint32_t scratch_off = 0u; bool have = false; uint32_t scratch_n = 0u;
                if (s + 1 <= kOctaveLastSub) { scratch_off = level_off(o, s + 1); have = true; scratch_n = static_cast<uint32_t>(ob.width) * static_cast<uint32_t>(ob.height); }
                else if (o + 1 <= last_octave_) { scratch_off = level_off(o + 1, kOctaveFirstSub); have = true; const OctaveBuffers& nb = octaves_[static_cast<size_t>(o + 1)]; scratch_n = static_cast<uint32_t>(nb.width) * static_cast<uint32_t>(nb.height); }
                if (have) {
                    blur(level_off(o, s - 1), level_off(o, s), scratch_off,
                         ob.width, ob.height, sigma_px, scratch_n);
                } else {
                    wgpu::Buffer taps_buf = harness.upload(
                        taps.data(), taps.size() * sizeof(float),
                        wgpu::BufferUsage::Storage);
                    struct FusedParams {
                        uint32_t width, height, radius, src_off;
                        uint32_t dst_off, _pad0, _pad1, _pad2;
                    } fp{static_cast<uint32_t>(ob.width),
                         static_cast<uint32_t>(ob.height), radius,
                         rel(level_off(o, s - 1), level_off(o, s - 1)), rel(level_off(o, s), level_off(o, s - 1)), 0u, 0u, 0u};
                    wgpu::Buffer fp_buf = harness.upload(
                        &fp, sizeof(fp), wgpu::BufferUsage::Uniform);
                    harness.dispatch_batched(
                        pipe_blur_fused,
                        {rng(level_off(o, s - 1),
                             level_off(o, s) + static_cast<uint32_t>(ob.width) *
                                                   static_cast<uint32_t>(ob.height)),
                         BB(taps_buf), BB(fp_buf)},
                        static_cast<uint32_t>((ob.width + 7) / 8), 1u);
                }
            }
        }
    };

    // Octave 0: fill from the seed.
    fill_octave(0);

    // Octaves 1..lastOctave: seed from previous octave then fill.
    // _vl_scalespace_start_octave_from_previous_octave:
    //   prevLevelIndex = min(octaveFirstSubdivision + octaveResolution,
    //                        octaveLastSubdivision) = min(-1+3, 4) = 2
    //   downsample(level[o-1, 2]) → level[o, octaveFirstSubdivision]
    //   sigma(o,-1) == sigma(o-1,2) → NO extra smoothing.
    for (int o = 1; o <= last_octave_; ++o) {
        OctaveBuffers& ob = octaves_[static_cast<size_t>(o)];
        const int prev_sub = std::min(kOctaveFirstSub + kOctaveResolution,
                                      kOctaveLastSub);  // = 2
        OctaveBuffers& prev = octaves_[static_cast<size_t>(o - 1)];
        struct ResampleParams {
            uint32_t src_width, dst_width, dst_height, src_off;
            uint32_t dst_off, _pad0, _pad1, _pad2;
        } rp{static_cast<uint32_t>(prev.width),
             static_cast<uint32_t>(ob.width),
             static_cast<uint32_t>(ob.height),
             0u, 0u /* [W256] src/dst 各自子区间绑定,偏移归零 */, 0u, 0u, 0u};
        const uint32_t rs_src = level_off(o - 1, prev_sub);
        const uint32_t rs_dst = level_off(o, kOctaveFirstSub);
        rp.src_off = 0u;   // resample 两种模式都用子区间绑定
        rp.dst_off = 0u;
        wgpu::Buffer rp_buf = harness.upload(&rp, sizeof(rp),
                                             wgpu::BufferUsage::Uniform);
        // 同一 buffer 不能在一个 dispatch 里同时绑 read 与 read_write
        // (WebGPU aliasing 校验)——resample 改为单一 read_write 绑定+双偏移。
        harness.dispatch_batched(
            pipe_resample,
            {rng_always(rs_src, rs_src + static_cast<uint32_t>(prev.width) *
                                             static_cast<uint32_t>(prev.height)),
             rng_always(rs_dst, rs_dst + static_cast<uint32_t>(ob.width) *
                                             static_cast<uint32_t>(ob.height)),
             BB(rp_buf)},
            wg(ob.width), wg(ob.height));
        fill_octave(o);
    }

    // Submit the entire pyramid build as ONE command buffer + a single wait.
    harness.end_batch();
    return true;
}

namespace {
// [W256-BY-LIMIT 2026-09-08] build() 在算布局之前填这两个值。
uint64_t g_w256_required_bytes = 0;
uint64_t g_w256_limit_bytes = 0;
bool g_w256_configured = false;
}  // namespace

void SiftPyramidDawn::configure_w256_by_limit(uint64_t required_bytes,
                                              uint64_t limit_bytes) {
    g_w256_required_bytes = required_bytes;
    g_w256_limit_bytes = limit_bytes;
    g_w256_configured = true;
}

void SiftPyramidDawn::w256_last_decision(uint64_t* required_bytes,
                                         uint64_t* limit_bytes, int* enabled,
                                         int* forced_by_env) {
    if (required_bytes) *required_bytes = g_w256_required_bytes;
    if (limit_bytes) *limit_bytes = g_w256_limit_bytes;
    if (enabled) *enabled = w256_enabled() ? 1 : 0;
    if (forced_by_env)
        *forced_by_env = std::getenv("OFFICIAL_AETHER_W256") != nullptr ? 1 : 0;
}

namespace { int g_last_kp_bind = -1; }
void SiftPyramidDawn::note_kp_bind(int subrange) { g_last_kp_bind = subrange; }
int SiftPyramidDawn::last_kp_bind() { return g_last_kp_bind; }

uint32_t SiftPyramidDawn::window_elems() {
    if (!g_w256_configured || g_w256_limit_bytes == 0) return kWindowElems;
    const uint64_t elems = g_w256_limit_bytes / 4ull;
    return elems > 0xFFFFFFFFull ? 0xFFFFFFFFu
                                 : static_cast<uint32_t>(elems);
}

bool SiftPyramidDawn::w256_bind_enabled() {
    if (const char* v = std::getenv("OFFICIAL_AETHER_W256_BIND")) {
        return !(v[0] == '0' && v[1] == '\0');
    }
    return w256_enabled();
}

bool SiftPyramidDawn::w256_enabled() {
    // env 两个方向都强制:台架单变量 A/B 与生产回滚都要用。
    if (const char* v = std::getenv("OFFICIAL_AETHER_W256")) {
        return !(v[0] == '0' && v[1] == '\0');
    }
    // 未设 env ⇒ 按设备自报能力选。**未知一律选能跑的那个**(子区间):
    // 猜错方向的代价不对称 —— 选错成"整缓冲"在 Mali 上是跑不起来,
    // 选错成"子区间"只是慢。
    if (!g_w256_configured || g_w256_limit_bytes == 0) return true;
    return g_w256_required_bytes > g_w256_limit_bytes;
}

std::vector<uint32_t> SiftPyramidDawn::level_layout(int width, int height,
                                                    int last_octave,
                                                    uint32_t* total_elems,
                                                    uint32_t* keypoint_region_end) {
    std::vector<uint32_t> offs(
        static_cast<size_t>(last_octave + 1) * kLevelsPerOctave, 0u);
    uint32_t running = 0;
    const bool w256 = w256_enabled();
    // A 区:所有八度的 li < kKeypointLevels;B 区:其余。层内顺序保持 (o, li)。
    // 旧模式:单区,(o, li) 顺序(A 区末尾 = 总量,关键点阶段绑整缓冲)。
    for (int region = 0; region < (w256 ? 2 : 1); ++region) {
        for (int o = 0; o <= last_octave; ++o) {
            const uint32_t ow = static_cast<uint32_t>(width >> o);
            const uint32_t oh = static_cast<uint32_t>(height >> o);
            const uint32_t n = ow * oh;
            for (int li = 0; li < kLevelsPerOctave; ++li) {
                const bool in_a = !w256 || li < kKeypointLevels;
                if ((region == 0) != in_a) continue;
                running = (running + kAlignElems - 1u) / kAlignElems * kAlignElems;
                offs[static_cast<size_t>(o) * kLevelsPerOctave + li] = running;
                running += n;
            }
        }
        if (region == 0 && keypoint_region_end) *keypoint_region_end = running;
    }
    if (total_elems) *total_elems = running;
    return offs;
}

uint32_t SiftPyramidDawn::level_offset(int octave, int sublevel) const {
    return level_offsets_[static_cast<size_t>(octave) * kLevelsPerOctave +
                          (sublevel - kOctaveFirstSub)];
}

int SiftPyramidDawn::octave_width(int octave) const {
    return octaves_[static_cast<size_t>(octave)].width;
}

int SiftPyramidDawn::octave_height(int octave) const {
    return octaves_[static_cast<size_t>(octave)].height;
}

wgpu::Buffer SiftPyramidDawn::pack_levels(DawnKernelHarness& harness,
                                          std::vector<LevelMeta>* meta) const {
    // Lay out every (octave, sublevel) level back-to-back, row-major f32. Each
    // level's element offset is the running prefix sum; the byte offset
    // (offset*4) is inherently 4-byte aligned for CopyBufferToBuffer.
    const int num_octaves = last_octave_ + 1;
    const size_t num_levels =
        static_cast<size_t>(num_octaves) * kLevelsPerOctave;
    meta->assign(num_levels, LevelMeta{});

    uint32_t total = 0, kp_end = 0;
    const std::vector<uint32_t> offs =
        level_layout(width_, height_, last_octave_, &total, &kp_end);  // [W256]
    for (int o = 0; o < num_octaves; ++o) {
        const uint32_t ow =
            static_cast<uint32_t>(octaves_[static_cast<size_t>(o)].width);
        const uint32_t oh =
            static_cast<uint32_t>(octaves_[static_cast<size_t>(o)].height);
        for (int li = 0; li < kLevelsPerOctave; ++li) {
            LevelMeta& m =
                (*meta)[static_cast<size_t>(o) * kLevelsPerOctave + li];
            m.offset = offs[static_cast<size_t>(o) * kLevelsPerOctave + li];
            m.width = ow;
            m.height = oh;
            m._pad = 0;
        }
    }

    // [PACK-ZERO 2026-08-10] 层从出生就住在 packed_buf_ 的这些偏移上,
    // 校验布局与 build() 一致后直接返回 —— 零拷贝。
    for (size_t i = 0; i < num_levels; ++i) {
        if ((*meta)[i].offset != level_offsets_[i]) {
            std::cerr << "[SiftPyramidDawn] pack layout drift at level " << i
                      << "\n";
            return wgpu::Buffer();
        }
    }
    (void)harness;
    return packed_buf_;
}

std::vector<float> SiftPyramidDawn::read_level(DawnKernelHarness& harness,
                                               int octave, int sublevel) const {
    const OctaveBuffers& ob = octaves_[static_cast<size_t>(octave)];
    const size_t bytes =
        static_cast<size_t>(ob.width) * ob.height * sizeof(float);
    wgpu::Buffer staging = harness.alloc_staging_for_readback(bytes);
    harness.copy_region(
        packed_buf_,
        static_cast<uint64_t>(level_offset(octave, sublevel)) * sizeof(float),
        staging, 0, bytes);
    std::vector<uint8_t> raw = harness.readback(staging, bytes);
    std::vector<float> out(static_cast<size_t>(ob.width) * ob.height);
    std::memcpy(out.data(), raw.data(), bytes);
    return out;
}

}  // namespace tools
}  // namespace aether
