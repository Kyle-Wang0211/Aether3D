// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TOOLS_SIFT_PYRAMID_DAWN_H
#define AETHER_CPP_TOOLS_SIFT_PYRAMID_DAWN_H

// GPU DSP-SIFT — M0 Gaussian Scale Space (GSS) pyramid driver.
//
// Builds the VLFeat covariant-SIFT scale space on the GPU via the Dawn kernel
// harness, using three WGSL passes:
//   S0  sift_gray_to_f32.wgsl    u8/255 → f32        (octave 0, base level seed)
//   S1  sift_gss_blur.wgsl       separable Gaussian  (within-octave fill, h then v)
//   S1b sift_gss_resample.wgsl   2× decimation       (octave transition)
//
// The geometry replicates colmap/feature/sift.cc's vl_covdet_new(DOG) path with
// first_octave = 0 (the validated port baseline, GPU_DSP_SIFT_PLAN.md:129):
//   octaveResolution      = 3
//   octaveFirstSubdivision = -1
//   octaveLastSubdivision  =  octaveResolution + 1 = 4   (6 levels/octave)
//   baseScale  = 1.6 * 2^(1/3)
//   nominalScale = 0.5
//   lastOctave = floor(log2(min(W-1,H-1) / (minOctaveSize-1)))   minOctaveSize=16
//
// fp32 throughout (the PLAN's fp16-store optimization is layered on AFTER parity).
// Gaussian taps are computed on the host in double precision (bit-identical to
// VLFeat _vl_new_gaussian_fitler_f); only the FIR dot product runs in GPU f32.

#include <cstdint>
#include <vector>

#include "dawn_kernel_harness.h"

namespace aether {
namespace tools {

class SiftPyramidDawn {
public:
    static constexpr int kOctaveResolution = 3;
    static constexpr int kOctaveFirstSub = -1;             // s_min
    static constexpr int kOctaveLastSub = kOctaveResolution + 1;  // s_max = 4
    static constexpr int kLevelsPerOctave = kOctaveLastSub - kOctaveFirstSub + 1;  // 6
    static constexpr int kMinOctaveSize = 16;

    struct LevelGeom {
        int octave;     // o
        int sublevel;   // s, in [kOctaveFirstSub, kOctaveLastSub]
        int width;      // pixels at this octave
        int height;
        double sigma;   // vl_scalespace_get_level_sigma(o, s)
    };

    // `harness` must already be init()'d. Builds the pyramid for the given
    // grayscale image (row-major, tightly packed, `width*height` bytes).
    // Returns false on dimension error.
    bool build(DawnKernelHarness& harness,
               const uint8_t* gray, int width, int height);

    int first_octave() const { return 0; }
    int last_octave() const { return last_octave_; }
    int width() const { return width_; }
    int height() const { return height_; }

    // Geometry of one (octave, sublevel). Octave width = width >> o.
    LevelGeom level_geom(int octave, int sublevel) const;

    // Read one GSS level back to host as f32 (octave_w * octave_h floats).
    // `harness` must be the same instance passed to build().
    std::vector<float> read_level(DawnKernelHarness& harness,
                                  int octave, int sublevel) const;

    // [PACK-ZERO 2026-08-10] 每层不再是独立 buffer:build() 一开始就把全部
    // (octave, sublevel) 层排进**一个** packed f32 大缓冲(布局与 pack_levels
    // 的 meta 完全一致),blur/resample 直写各自偏移 ⇒ pack_levels 变零拷贝
    // (原先 48 次 copy ≈ 数百 MB/帧)。层的身份 = packed_buffer() + 偏移。
    const wgpu::Buffer& packed_buffer() const { return packed_buf_; }
    uint32_t level_offset(int octave, int sublevel) const;  // element offset

    // Octave width/height (== width >> o, height >> o).
    int octave_width(int octave) const;
    int octave_height(int octave) const;

    // Per-(octave, sublevel) descriptor in the packed GSS buffer (pack_levels()).
    struct LevelMeta {
        uint32_t offset;  // element offset into the packed f32 buffer
        uint32_t width;
        uint32_t height;
        uint32_t _pad;    // 16-byte align for std140-ish uniform/storage use
    };

    // Concatenate EVERY (octave, sublevel) GSS level into a single GPU storage
    // buffer (row-major, f32), so a cross-octave consumer (affine warp, DSP
    // descriptor) can sample any level via one binding + an index table. Returns
    // the packed buffer; fills `meta` with one LevelMeta per (octave, sublevel)
    // indexed as `o * kLevelsPerOctave + (s - kOctaveFirstSub)`. Built once on
    // the GPU via buffer-to-buffer copies (no host round-trip of pixel data).
    wgpu::Buffer pack_levels(DawnKernelHarness& harness,
                             std::vector<LevelMeta>* meta) const;

    // Flat index into the pack_levels() meta table for (octave, sublevel).
    int level_index(int octave, int sublevel) const {
        return octave * kLevelsPerOctave + (sublevel - kOctaveFirstSub);
    }

    // baseScale = 1.6 * 2^(1/3); nominalScale = 0.5.
    static double base_scale();
    static constexpr double kNominalScale = 0.5;

    // sigma(o, s) = baseScale * 2^(o + s/octaveResolution).
    static double level_sigma(int octave, int sublevel);

private:
    // Octave geometry; pixel storage lives in packed_buf_ at level_offsets_.
    struct OctaveBuffers {
        int width = 0;
        int height = 0;
    };

    int width_ = 0;
    int height_ = 0;
    int last_octave_ = 0;
    std::vector<OctaveBuffers> octaves_;  // index = octave (first_octave = 0)
    wgpu::Buffer packed_buf_;             // 所有层的唯一驻留缓冲
    std::vector<uint32_t> level_offsets_; // index = o*kLevelsPerOctave+(s-first)
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_SIFT_PYRAMID_DAWN_H
