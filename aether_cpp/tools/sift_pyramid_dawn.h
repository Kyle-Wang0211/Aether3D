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
    // [KPBUF 2026-09-08] 关键点三段(affine/orient/descriptor)专用的 A 区缓冲。
    // 动机(09-08 Mali 主机侧分解):这三段 wait 合计 2809/4355 ms,而它们与
    // 快路径的唯一差别就是"packed 绑成子区间"。09-08 在 Adreno 上已证明**把它们
    // 改绑整块 packed 并不变快**(KPBIND=0 臂),所以问题不在绑定形状本身,
    // 而疑似在**与被子区间写过的同一块缓冲共存**(Dawn 只能保守下屏障)。
    // 独立缓冲切断这层别名关系:整块绑、无子区间、着色器一字不改。
    // 逐字节按构造无损 —— 拷的就是同一批字节。
    const wgpu::Buffer& keypoint_buffer() const { return kp_buf_; }
    bool keypoint_buffer_ready() const { return kp_buf_ != nullptr; }
    // 金字塔建完后调用:把 [0, keypoint_region_end) 拷进 kp_buf_。
    void sync_keypoint_buffer(DawnKernelHarness& harness);
    static bool kpbuf_enabled();
    uint32_t level_offset(int octave, int sublevel) const;  // element offset

    // [W256 2026-09-07] 打包布局(Mali-G72 单次绑定 ≤256 MB,缓冲本身可到 1 GB):
    //  * 层起点按 64 元素(256 B)对齐(minStorageBufferOffsetAlignment);
    //  * **A 区**先放所有八度的前 kKeypointLevels(=3,即 s∈{-1,0,1})层,
    //    **B 区**再放其余层。关键点阶段(affine/orient/descriptor,原着色器
    //    一字不改)只读 A 区:VLFeat pick_level 对非末八度恒取 s=0、首八度可取
    //    s=-1、末八度可取到 s=4(末八度极小,整八度也在 A 区之外时用 B 区……
    //    见 keypoint_region_end())。12MP:A 区 ≈195 MB < 256 MB。
    //  * 金字塔/检测阶段按 dispatch 只绑真正触碰的层区间(宿主侧,已证逐位)。
    //  build() 与 pack_levels() 共用同一函数 ⇒ 布局不可能漂移。
    static constexpr uint32_t kAlignElems = 64u;
    static constexpr uint32_t kWindowElems = 1u << 26;   // 256 MB / 4(下限缺省)
    // [W256-BY-LIMIT 2026-09-08] 窗口大小同样不该写死成 Mali 的 256 MB ——
    // 那是"这台机器一次能绑多少",按 build() 查到的 granted limit 走;
    // 查不到就退回 kWindowElems(保守 = 能跑)。
    static uint32_t window_elems();
    static constexpr int kKeypointLevels = 3;
    // 回退开关(三端同一):OFFICIAL_AETHER_W256=0 ⇒ 旧的 (o, li) 顺序布局 +
    // 整缓冲绑定 + 检测不拆(仅 64 元素对齐保留:resample 的子区间绑定需要)。
    // 只用于台架单变量 A/B 与生产回滚;Mali 12MP 在旧模式下不可用(>256 MB)。
    static bool w256_enabled();
    // [W256-SPLIT 2026-09-08] 把 W256 的两件事拆成两个变量,才能问出
    // 「7.2 s 是布局重排的钱,还是子区间绑定的钱」:
    //   w256_enabled()      → **布局**(A/B 区重排)
    //   w256_bind_enabled() → **绑定**(每次 dispatch 只绑触碰的层区间)
    // 默认二者同步;只有显式设 OFFICIAL_AETHER_W256_BIND 才分开(诊断臂)。
    static bool w256_bind_enabled();
    // 🔴 09-08 教训:KPBIND 那一臂拿不到阳性对照 ⇒ 结果不可用。
    // 旋钮**必须自报它真的生效了**,而且要走产物通道(不是 stderr)。
    // note_kp_bind() 由提取器在真正建绑定的那一刻记;-1 = 这一趟没走到那里。
    static void note_kp_bind(int subrange);
    static int last_kp_bind();
    // [W256-BY-LIMIT 2026-09-08 用户批准] 按设备**自报的** maxStorageBufferBindingSize
    // 选布局,而不是按机型分叉:整缓冲绑得下就用旧布局(快),绑不下才用子区间。
    // 依据是 WebGPU 的能力协商本身 —— Mali-G72 给 256 MB、Adreno 660 给得下整块。
    // 实测(09-08,P50/Adreno 660,13312):子区间布局在绑得下的设备上要 5.7x 代价
    // (8836 vs 1550 ms);而 Mali 不用它 12MP 根本起不来(390 MB > 256 MB)。
    // env OFFICIAL_AETHER_W256 仍然两个方向都强制,供台架单变量 A/B 与回滚。
    static void configure_w256_by_limit(uint64_t required_bytes,
                                        uint64_t limit_bytes);
    // 自证:上一次 build() 的判定输入与结果。**必须能从产物侧读到** ——
    // 只走 stderr 的自证在设备上必然丢(09-07 教训),所以这里给取值口,
    // 由调用方(探针/产线埋点)和自己的输出通道一起走。
    // forced_by_env: 0=按能力判 1=env 强制
    static void w256_last_decision(uint64_t* required_bytes,
                                   uint64_t* limit_bytes, int* enabled,
                                   int* forced_by_env);
    static std::vector<uint32_t> level_layout(int width, int height,
                                              int last_octave,
                                              uint32_t* total_elems,
                                              uint32_t* keypoint_region_end);
    uint32_t packed_total_elems() const { return packed_total_elems_; }
    // A 区末尾(元素):关键点阶段把 packed 绑成 [0, keypoint_region_end)。
    uint32_t keypoint_region_end() const { return keypoint_region_end_; }

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
    wgpu::Buffer kp_buf_;                 // [KPBUF] A 区独立副本(可选)
    std::vector<uint32_t> level_offsets_; // index = o*kLevelsPerOctave+(s-first)
    uint32_t packed_total_elems_ = 0;     // [W256] 含对齐填充
    uint32_t keypoint_region_end_ = 0;    // [W256] A 区末尾
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_SIFT_PYRAMID_DAWN_H
