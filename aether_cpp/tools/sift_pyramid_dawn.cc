// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "sift_pyramid_dawn.h"

#include <cmath>
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
    std::cerr << "[SiftPyramidDawn] unknown WGSL: " << filename << '\n';
    std::abort();
#endif
}

// VLFeat _vl_new_gaussian_fitler_f (imopv.c:620): width = ceil(sigma*3), the
// FIR is sampled exp(-0.5*(i/sigma)^2) and L1-normalized. Computed in double
// to be bit-identical to the CPU reference; the GPU only does the f32 FIR dot.
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

    const auto wg = [](int n) -> uint32_t {
        return static_cast<uint32_t>((n + 7) / 8);
    };

    // ── Allocate every level buffer ──
    octaves_.assign(static_cast<size_t>(last_octave_ + 1), {});
    for (int o = 0; o <= last_octave_; ++o) {
        OctaveBuffers& ob = octaves_[static_cast<size_t>(o)];
        ob.width = width_ >> o;
        ob.height = height_ >> o;
        const size_t bytes =
            static_cast<size_t>(ob.width) * ob.height * sizeof(float);
        ob.levels.resize(static_cast<size_t>(kLevelsPerOctave));
        for (int li = 0; li < kLevelsPerOctave; ++li) {
            ob.levels[static_cast<size_t>(li)] = harness.alloc(
                bytes,
                wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                    wgpu::BufferUsage::CopyDst);
        }
    }

    const auto level_buf = [&](int o, int s) -> wgpu::Buffer& {
        return octaves_[static_cast<size_t>(o)]
            .levels[static_cast<size_t>(s - kOctaveFirstSub)];
    };

    // Run one separable Gaussian (h then v) from `src` into `dst`, sized
    // (w,h), with kernel sigma `sigma_px` (already divided by octave step).
    // `scratch` is a same-sized intermediate the caller owns.
    const auto blur = [&](const wgpu::Buffer& src, const wgpu::Buffer& dst,
                          const wgpu::Buffer& scratch, int w, int h,
                          double sigma_px) {
        const std::vector<float> taps = make_gaussian_taps(sigma_px);
        const uint32_t radius = static_cast<uint32_t>((taps.size() - 1) / 2);
        wgpu::Buffer taps_buf =
            harness.upload(taps.data(), taps.size() * sizeof(float),
                           wgpu::BufferUsage::Storage);
        // Params: {width, height, radius, axis}
        struct BlurParams {
            uint32_t width, height, radius, axis;
        };
        // h pass: src → scratch (axis 0). Batched: encoded into the open batch,
        // submitted once at end_batch(). Dawn tracks the src/scratch/dst storage
        // hazards so the v-pass sees the h-pass writes (identical to per-call).
        BlurParams ph{static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                      radius, 0u};
        wgpu::Buffer ph_buf = harness.upload(&ph, sizeof(ph),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(pipe_blur, {src, taps_buf, scratch, ph_buf},
                                 wg(w), wg(h));
        // v pass: scratch → dst (axis 1)
        BlurParams pv{static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                      radius, 1u};
        wgpu::Buffer pv_buf = harness.upload(&pv, sizeof(pv),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(pipe_blur, {scratch, taps_buf, dst, pv_buf},
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
            uint32_t width, height;
        } gp{static_cast<uint32_t>(width_), static_cast<uint32_t>(height_)};
        wgpu::Buffer gp_buf = harness.upload(&gp, sizeof(gp),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(pipe_gray,
                                 {src_u8, level_buf(0, kOctaveFirstSub), gp_buf},
                                 wg(width_), wg(height_));
    }

    // ── Octave 0 base-level smoothing (_vl_scalespace_start_octave_from_image) ──
    // sigma = sigma(0, octaveFirstSubdivision); imageSigma = nominalScale.
    // If sigma > imageSigma, smooth the seed in place by deltaSigma (step=1).
    {
        OctaveBuffers& ob0 = octaves_[0];
        wgpu::Buffer scratch = harness.alloc(
            static_cast<size_t>(ob0.width) * ob0.height * sizeof(float),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        const double sigma = level_sigma(0, kOctaveFirstSub);
        if (sigma > kNominalScale) {
            const double delta =
                std::sqrt(sigma * sigma - kNominalScale * kNominalScale);
            // In-place smoothing: seed is src and dst. Use a temp dst to avoid
            // read/write aliasing across the v-pass, then copy back.
            wgpu::Buffer tmp = harness.alloc(
                static_cast<size_t>(ob0.width) * ob0.height * sizeof(float),
                wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
            blur(level_buf(0, kOctaveFirstSub), tmp, scratch, ob0.width,
                 ob0.height, delta /* /step, step=1 */);
            harness.copy_region_batched(tmp, 0, level_buf(0, kOctaveFirstSub), 0,
                                        static_cast<size_t>(ob0.width) *
                                            ob0.height * sizeof(float));
        }
    }

    // Helper: fill one octave's remaining sublevels by incremental smoothing
    // (_vl_scalespace_fill_octave): level[s] = smooth(level[s-1], deltaSigma/step).
    const auto fill_octave = [&](int o) {
        OctaveBuffers& ob = octaves_[static_cast<size_t>(o)];
        const double step = std::pow(2.0, static_cast<double>(o));
        wgpu::Buffer scratch = harness.alloc(
            static_cast<size_t>(ob.width) * ob.height * sizeof(float),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        for (int s = kOctaveFirstSub + 1; s <= kOctaveLastSub; ++s) {
            const double sigma = level_sigma(o, s);
            const double prev = level_sigma(o, s - 1);
            const double delta = std::sqrt(sigma * sigma - prev * prev);
            blur(level_buf(o, s - 1), level_buf(o, s), scratch, ob.width,
                 ob.height, delta / step);
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
            uint32_t src_width, dst_width, dst_height;
        } rp{static_cast<uint32_t>(prev.width),
             static_cast<uint32_t>(ob.width),
             static_cast<uint32_t>(ob.height)};
        wgpu::Buffer rp_buf = harness.upload(&rp, sizeof(rp),
                                             wgpu::BufferUsage::Uniform);
        harness.dispatch_batched(
            pipe_resample,
            {level_buf(o - 1, prev_sub), level_buf(o, kOctaveFirstSub), rp_buf},
            wg(ob.width), wg(ob.height));
        fill_octave(o);
    }

    // Submit the entire pyramid build as ONE command buffer + a single wait.
    harness.end_batch();
    return true;
}

const wgpu::Buffer& SiftPyramidDawn::level_buffer(int octave,
                                                  int sublevel) const {
    return octaves_[static_cast<size_t>(octave)]
        .levels[static_cast<size_t>(sublevel - kOctaveFirstSub)];
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

    uint32_t running = 0;  // element offset
    for (int o = 0; o < num_octaves; ++o) {
        const uint32_t ow =
            static_cast<uint32_t>(octaves_[static_cast<size_t>(o)].width);
        const uint32_t oh =
            static_cast<uint32_t>(octaves_[static_cast<size_t>(o)].height);
        for (int li = 0; li < kLevelsPerOctave; ++li) {
            LevelMeta& m =
                (*meta)[static_cast<size_t>(o) * kLevelsPerOctave + li];
            m.offset = running;
            m.width = ow;
            m.height = oh;
            m._pad = 0;
            running += ow * oh;
        }
    }

    const size_t total_bytes = static_cast<size_t>(running) * sizeof(float);
    wgpu::Buffer packed = harness.alloc(
        total_bytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
            wgpu::BufferUsage::CopyDst);

    // GPU-side assembly: copy each resident level buffer into its slot, ALL in
    // ONE command submit (was 48 separate submit+wait round-trips). No pixel
    // data crosses to the host.
    harness.begin_batch();
    for (int o = 0; o < num_octaves; ++o) {
        const size_t level_bytes =
            static_cast<size_t>(octaves_[static_cast<size_t>(o)].width) *
            octaves_[static_cast<size_t>(o)].height * sizeof(float);
        for (int s = kOctaveFirstSub; s <= kOctaveLastSub; ++s) {
            const size_t idx = static_cast<size_t>(o) * kLevelsPerOctave +
                               (s - kOctaveFirstSub);
            const uint64_t dst_byte =
                static_cast<uint64_t>((*meta)[idx].offset) * sizeof(float);
            harness.copy_region_batched(level_buffer(o, s), 0, packed, dst_byte,
                                        level_bytes);
        }
    }
    harness.end_batch();
    return packed;
}

std::vector<float> SiftPyramidDawn::read_level(DawnKernelHarness& harness,
                                               int octave, int sublevel) const {
    const OctaveBuffers& ob = octaves_[static_cast<size_t>(octave)];
    const size_t bytes =
        static_cast<size_t>(ob.width) * ob.height * sizeof(float);
    wgpu::Buffer staging = harness.alloc_staging_for_readback(bytes);
    harness.copy_to_staging(
        ob.levels[static_cast<size_t>(sublevel - kOctaveFirstSub)], staging,
        bytes);
    std::vector<uint8_t> raw = harness.readback(staging, bytes);
    std::vector<float> out(static_cast<size_t>(ob.width) * ob.height);
    std::memcpy(out.data(), raw.data(), bytes);
    return out;
}

}  // namespace tools
}  // namespace aether
