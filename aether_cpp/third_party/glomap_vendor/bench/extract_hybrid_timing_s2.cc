// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// extract_hybrid_timing_s2.cc — S2 hybrid GPU->CPU DSP-SIFT extractor + e2e
// timing harness (GPU_DSP_SIFT_PLAN.md, Stage 2, task B).
//
// ═══════════════════════════════════════════════════════════════════════════
//  WHAT S2 ADDS OVER S1
// ═══════════════════════════════════════════════════════════════════════════
//  S1 (extract_hybrid_timing.cc) boundary:
//    GPU [gss build + fused DoG + 26-neighbour extremum TEST] -> readback of the
//    INTEGER candidate voxels -> CPU [Newton refine + peak/edge gates + append]
//    -> CPU [affine-shape + orientation + sort + DSP descriptor].
//
//  S2 moves the Newton-refine + the post-refine peak/edge GATES onto the GPU
//  (task A's sift_refine_gate.wgsl, the S2 task-A kernel, concurrent). The GPU
//  now outputs the FINAL detected keypoints (subpixel x/y/scale, post-gate).
//  The CPU continuation then starts at AFFINE-SHAPE, seeded with the GPU-refined
//  keypoints via vl_covdet_append_feature (the SAME append-feature continuation
//  path S1's harness established at extract_hybrid_timing.cc:758-807 — reused
//  here but seeded with the REFINED GPU keypoints, not the raw candidates).
//
//  S2 boundary:
//    GPU [gss + DoG + extremum + Newton refine + peak/edge gate] -> readback of
//    the FINAL refined keypoints (subpixel, post-gate, far fewer than the raw
//    candidates) -> CPU [affine-shape + orientation + sort + DSP descriptor].
//
//  S2 thus REMOVES from the per-frame CPU path:
//    (a) the CPU Newton refine + gate (S1's `refine_ms` block, ~37-72ms on M3),
//    (b) the per-octave CPU css rebuild that the CPU refine needed,
//    (c) the raw-candidate readback is replaced by the (smaller) refined-keypoint
//        readback.
//
// ═══════════════════════════════════════════════════════════════════════════
//  TASK-A KERNEL STATUS — sift_refine_gate.wgsl IS LANDED + WIRED (REAL GPU)
// ═══════════════════════════════════════════════════════════════════════════
//  Task A's shaders/wgsl/sift_refine_gate.wgsl (entry `refine`) is present + S2-
//  parity-validated (extract_gpuparity.cc --refine: recall=precision=1.000000,
//  median pos-err 0.000000px vs VLFeat's own vl_refine_local_extreum_3 + gates).
//  This harness WIRES IT: after the S1 DoG+extremum dispatch, the GPU refine+gate
//  kernel runs per-octave over that octave's candidates and atomic-appends the
//  FINAL refined+gated keypoints (subpixel x/y/z, post-gate) into a dense
//  `Keypoint` buffer — so detection finishes on the GPU. The CPU continuation
//  then starts at AFFINE-SHAPE, seeded with the GPU-refined keypoints via
//  vl_covdet_append_feature.
//
//  The kernel's refine+gate cost is therefore a MEASURED GPU number (refine_gpu_
//  ms), not a placeholder. The ONE detection step the GPU kernel does NOT do is
//  nonExtremaSuppression (covdet.c:2104, =0.5 ON by VLFeat default + NOT disabled
//  by COLMAP) — a GLOBAL O(N²) pass that is not expressible per-candidate; task
//  A's interface defers it to a host post-pass. We run that suppression on the
//  CPU here (suppress_ms) so the S2 keypoint set is PRODUCTION-EXACT (matches
//  vl_covdet_detect, within the GPU fp32 tolerance). NOTE: the naive O(N²)
//  suppression over ~26k survivors is ~0.9s on CPU — a real cost; a production
//  GPU/spatial-grid suppression is future work (flagged in the report, NOT
//  fabricated as already-GPU).
//
//  Timing accounting — the totals reported:
//   • "S2 (detection on GPU, gss-resident)": GPU [gss + DoG + refine+gate] (all
//     MEASURED GPU) + the CPU suppression post-pass + refined-kp readback + the
//     CPU affine-onward continuation. This is the honest S2 per-frame total with
//     gss kept resident (no gss readback counted).
//   • "+ gss-readback boundary": adds the gss readback the CPU affine/orient/
//     descriptor continuation actually needs (see the gss-readback section).
//   • "suppression -> GPU (future)": the same total with the CPU suppression
//     post-pass moved off the CPU path (the future GPU suppression stage), to
//     show the headroom — clearly MARKED as not-yet-built.
//
// ═══════════════════════════════════════════════════════════════════════════
//  THE gss READBACK — IS IT REMOVED BY S2?  (the task's honest question)
// ═══════════════════════════════════════════════════════════════════════════
//  NO — S2 does NOT remove the gss readback. The CPU continuation that S2 keeps
//  (affine-shape + orientation + DSP descriptor) STILL reads gss patches on the
//  CPU (vl_covdet_extract_affine_shape_for_frame, vl_covdet_extract_orientations,
//  vl_covdet_extract_patch_for_frame all sample the gss pyramid). So the gss must
//  still come back to CPU memory once per frame. What S2 removes is the CPU
//  Newton refine + the per-octave CPU css rebuild + shrinks the keypoint readback
//  — NOT the gss round-trip. The gss readback only goes away when affine/orient/
//  descriptor are ALSO on the GPU (S3 descriptor + S4 affine/orient). This
//  harness measures the gss readback the SAME way S1 did (probe) and reports both
//  the "gss-resident" total and the "+ gss-readback boundary" total so the cost
//  is grounded, not assumed.
//
//  Build: bench/build_hybrid_timing_s2.sh (worktree-only, reuses prebuilt Dawn).

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

// ─── VLFeat (CPU reference + CPU continuation) ───
extern "C" {
#include "covdet.h"
#include "imopv.h"
#include "scalespace.h"
#include "sift.h"

typedef struct _VlCovDetExtremum3 {
  vl_index xi, yi, zi;
  float x, y, z;
  float peakScore, edgeScore;
} VlCovDetExtremum3;
vl_size vl_find_local_extrema_3(vl_index** extrema, vl_size* bufferSize,
                                float const* map, vl_size width, vl_size height,
                                vl_size depth, double threshold);
vl_bool vl_refine_local_extreum_3(VlCovDetExtremum3* refined, float const* map,
                                  vl_size width, vl_size height, vl_size depth,
                                  vl_index x, vl_index y, vl_index z);
}

// ─── Dawn kernel harness (GPU under test) ───
#include "dawn_kernel_harness.h"

// ─── stb_image (JPEG decode) ───
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

using clock_t_ = std::chrono::steady_clock;
inline double ms_since(clock_t_::time_point t0) {
  return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}

// ─── candidate record — MUST match shaders/wgsl/sift_dog_extrema_test.wgsl. ───
#pragma pack(push, 4)
struct CandidateExtremum {
  uint32_t octave;
  uint32_t level;
  uint32_t x;
  uint32_t y;
  float dog_value;
};
struct DogExtremaParams {
  uint32_t width;
  uint32_t height;
  uint32_t num_css;
  uint32_t octave;
  float detect_thr;
  uint32_t max_count;
  uint32_t pad0;
  uint32_t pad1;
};
struct BlurParams {
  uint32_t width;
  uint32_t height;
  uint32_t radius;
  uint32_t axis;
};
struct DownParams {
  uint32_t src_width;
  uint32_t src_height;
  uint32_t dst_width;
  uint32_t dst_height;
};
// ─── S2: the FINAL refined-keypoint record task A's sift_refine_gate.wgsl
// emits (entry `refine`) — MUST byte-match the .wgsl `Keypoint` struct
// (48 bytes, std430, 8 x 4-byte scalars). Read back to CPU + seeded into the
// affine-onward continuation.
struct Keypoint {
  float    x_local;     // refined subpixel x in octave-local css coords
  float    y_local;     // refined subpixel y in octave-local css coords
  float    z_local;     // refined subpixel css-local scale (0-based)
  uint32_t octave;      // detection octave o
  float    sigma;       // baseScale * 2^(o + (z_local+first_sub)/octave_res)
  float    step;        // per-octave step (frame.x = x_local*step)
  float    peak_score;  // refined.peakScore (signed)
  float    edge_score;  // refined.edgeScore
};
// RefineParams uniform — MUST byte-match the .wgsl RefineParams (12 x 4 bytes).
struct RefineParams {
  uint32_t width;
  uint32_t height;
  uint32_t num_css;
  uint32_t num_cands;
  float    peak_thr;    // FULL peakThreshold (post-refine gate; NOT the 0.8x)
  float    edge_thr;
  float    base_scale;
  float    step;
  int32_t  first_sub;   // octaveFirstSubdivision (signed; default -1)
  float    octave_res;
  uint32_t max_kp;
  uint32_t pad0;
};
#pragma pack(pop)
static_assert(sizeof(CandidateExtremum) == 20, "candidate record must be 20B");
static_assert(sizeof(Keypoint) == 32, "keypoint record must be 32B");
static_assert(sizeof(RefineParams) == 48, "refine params must be 48B");

std::vector<float> vlfeat_gaussian_taps_f(double sigma, int* out_radius) {
  const int width = static_cast<int>(std::ceil(sigma * 3.0));
  const int size = 2 * width + 1;
  std::vector<float> filter(static_cast<size_t>(size));
  float mass = 1.0f;
  filter[static_cast<size_t>(width)] = 1.0f;
  for (int i = 1; i <= width; ++i) {
    const double xx = static_cast<double>(i) / sigma;
    const float g = static_cast<float>(std::exp(-0.5 * xx * xx));
    mass += g + g;
    filter[static_cast<size_t>(width - i)] = g;
    filter[static_cast<size_t>(width + i)] = g;
  }
  for (int i = 0; i < size; ++i) filter[static_cast<size_t>(i)] /= mass;
  *out_radius = width;
  return filter;
}

std::string read_file(const char* path) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f) return {};
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::string s(static_cast<size_t>(sz), '\0');
  size_t rd = std::fread(s.data(), 1, static_cast<size_t>(sz), f);
  std::fclose(f);
  s.resize(rd);
  return s;
}

void transform_vlfeat_to_ubc(std::vector<uint8_t>& desc, size_t n) {
  static const std::array<int, 8> q{{0, 7, 6, 5, 4, 3, 2, 1}};
  std::vector<uint8_t> tmp(desc.size());
  for (size_t row = 0; row < n; ++row) {
    const uint8_t* src = desc.data() + row * 128;
    uint8_t* dst = tmp.data() + row * 128;
    for (int i = 0; i < 4; ++i)
      for (int j = 0; j < 4; ++j)
        for (int k = 0; k < 8; ++k)
          dst[8 * (j + 4 * i) + q[k]] = src[8 * (j + 4 * i) + k];
  }
  desc.swap(tmp);
}

struct DspOpts {
  double peak_threshold;
  double edge_threshold;
  bool estimate_affine_shape = true;
  bool domain_size_pooling = true;
  bool upright = false;
  int max_num_features = 8192;
  double dsp_min_scale = 1.0 / 6.0;
  double dsp_max_scale = 3.0;
  int dsp_num_scales = 10;
  bool l1_root = true;
};

void dsp_descriptor_threaded(VlCovDet* covdet, const DspOpts& o,
                             size_t num_kp, std::vector<uint8_t>* out_desc,
                             int num_threads) {
  out_desc->assign(num_kp * 128, 0);
  if (num_kp == 0) return;
  VlCovDetFeature* features = vl_covdet_get_features(covdet);
  VlScaleSpace* shared_gss = vl_covdet_get_gss(covdet);

  const int hw = static_cast<int>(std::thread::hardware_concurrency());
  int nthreads = num_threads > 0 ? num_threads : (hw > 0 ? hw : 1);
  if (nthreads > static_cast<int>(num_kp))
    nthreads = std::max<int>(1, static_cast<int>(num_kp));

  auto worker = [&](size_t lo, size_t hi) {
    VlCovDet* wd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    if (!wd) return;
    vl_covdet_set_gss(wd, shared_gss);
    VlSiftFilt* sift = vl_sift_new(16, 16, 1, 3, 0);
    if (!sift) {
      vl_covdet_set_gss(wd, nullptr);
      vl_covdet_delete(wd);
      return;
    }
    vl_sift_set_magnif(sift, 3.0);

    const size_t kPatchResolution = 15;
    const size_t kPatchSide = 2 * kPatchResolution + 1;
    const double kPatchRelativeExtent = 7.5;
    const double kPatchRelativeSmoothing = 1;
    const double kPatchStep = kPatchRelativeExtent / kPatchResolution;
    const double kSigma = kPatchRelativeExtent / (3.0 * (4 + 1) / 2) / kPatchStep;

    std::vector<float> patch(kPatchSide * kPatchSide);
    std::vector<float> patchXY(2 * kPatchSide * kPatchSide);

    float dsp_min_scale = 1, dsp_scale_step = 0;
    int dsp_num_scales = 1;
    if (o.domain_size_pooling) {
      dsp_min_scale = static_cast<float>(o.dsp_min_scale);
      dsp_scale_step = static_cast<float>(
          (o.dsp_max_scale - o.dsp_min_scale) / o.dsp_num_scales);
      dsp_num_scales = o.dsp_num_scales;
    }

    std::vector<float> descriptor(128);
    std::vector<float> scaled(static_cast<size_t>(dsp_num_scales) * 128);

    for (size_t i = lo; i < hi; ++i) {
      for (int s = 0; s < dsp_num_scales; ++s) {
        const double dsp_scale = dsp_min_scale + s * dsp_scale_step;
        VlFrameOrientedEllipse sf = features[i].frame;
        sf.a11 *= dsp_scale; sf.a12 *= dsp_scale;
        sf.a21 *= dsp_scale; sf.a22 *= dsp_scale;
        vl_covdet_extract_patch_for_frame(wd, patch.data(), kPatchResolution,
                                          kPatchRelativeExtent,
                                          kPatchRelativeSmoothing, sf);
        vl_imgradient_polar_f(patchXY.data(), patchXY.data() + 1, 2,
                              2 * kPatchSide, patch.data(), kPatchSide,
                              kPatchSide, kPatchSide);
        vl_sift_calc_raw_descriptor(sift, patchXY.data(),
                                    scaled.data() + s * 128, kPatchSide,
                                    kPatchSide, kPatchResolution,
                                    kPatchResolution, kSigma, 0);
      }
      for (int d = 0; d < 128; ++d) {
        double acc = 0;
        for (int s = 0; s < dsp_num_scales; ++s) acc += scaled[s * 128 + d];
        descriptor[d] = static_cast<float>(acc / dsp_num_scales);
      }
      if (o.l1_root) {
        double l1 = 0;
        for (int d = 0; d < 128; ++d) l1 += std::fabs(descriptor[d]);
        const double inv = l1 > 0 ? 1.0 / l1 : 0.0;
        for (int d = 0; d < 128; ++d)
          descriptor[d] = static_cast<float>(std::sqrt(descriptor[d] * inv));
      } else {
        double l2 = 0;
        for (int d = 0; d < 128; ++d) l2 += descriptor[d] * descriptor[d];
        const double inv = l2 > 0 ? 1.0 / std::sqrt(l2) : 0.0;
        for (int d = 0; d < 128; ++d) descriptor[d] *= static_cast<float>(inv);
      }
      uint8_t* row = out_desc->data() + i * 128;
      for (int d = 0; d < 128; ++d) {
        double v = descriptor[d] * 512.0;
        if (v < 0) v = 0; if (v > 255) v = 255;
        row[d] = static_cast<uint8_t>(std::lround(v));
      }
    }
    vl_covdet_set_gss(wd, nullptr);
    vl_sift_delete(sift);
    vl_covdet_delete(wd);
  };

  if (nthreads <= 1) {
    worker(0, num_kp);
  } else {
    std::vector<std::thread> pool;
    const size_t chunk = (num_kp + nthreads - 1) / nthreads;
    for (int t = 0; t < nthreads; ++t) {
      const size_t lo = std::min<size_t>(static_cast<size_t>(t) * chunk, num_kp);
      const size_t hi = std::min<size_t>(lo + chunk, num_kp);
      if (lo >= hi) break;
      pool.emplace_back(worker, lo, hi);
    }
    for (auto& th : pool) th.join();
  }
  transform_vlfeat_to_ubc(*out_desc, num_kp);
}

int affine_shape_threaded(VlCovDet* covdet, int num_threads) {
  const int nf = vl_covdet_get_num_features(covdet);
  if (nf <= 0) return 0;
  VlCovDetFeature* feats = vl_covdet_get_features(covdet);
  VlScaleSpace* aff_gss = vl_covdet_get_gss(covdet);
  std::vector<VlFrameOrientedEllipse> adapted(nf);
  std::vector<char> ok(nf, 0);
  const int hwa = static_cast<int>(std::thread::hardware_concurrency());
  int athreads = num_threads > 0 ? num_threads : (hwa > 0 ? hwa : 1);
  if (athreads > nf) athreads = std::max<int>(1, nf);

  auto aff_worker = [&](int lo, int hi) {
    VlCovDet* wd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    if (!wd) return;
    vl_covdet_set_gss(wd, aff_gss);
    for (int i = lo; i < hi; ++i)
      ok[i] = (vl_covdet_extract_affine_shape_for_frame(
                   wd, &adapted[i], feats[i].frame) == VL_ERR_OK) ? 1 : 0;
    vl_covdet_set_gss(wd, nullptr);
    vl_covdet_delete(wd);
  };
  if (athreads <= 1) {
    aff_worker(0, nf);
  } else {
    std::vector<std::thread> pool;
    const int chunk = (nf + athreads - 1) / athreads;
    for (int t = 0; t < athreads; ++t) {
      const int lo = std::min(t * chunk, nf);
      const int hi = std::min(lo + chunk, nf);
      if (lo >= hi) break;
      pool.emplace_back(aff_worker, lo, hi);
    }
    for (auto& th : pool) th.join();
  }
  int j = 0;
  for (int i = 0; i < nf; ++i) {
    if (ok[i]) { feats[j] = feats[i]; feats[j].frame = adapted[i]; ++j; }
  }
  vl_covdet_set_num_features(covdet, static_cast<vl_size>(j));
  return j;
}

size_t sort_and_clamp(VlCovDet* covdet, int max_num_features) {
  const int num_features = vl_covdet_get_num_features(covdet);
  VlCovDetFeature* features = vl_covdet_get_features(covdet);
  const int kMaxOctaveResolution = 1000;
  std::sort(features, features + num_features,
            [](const VlCovDetFeature& a, const VlCovDetFeature& b) {
              if (a.o == b.o) return a.s > b.s;
              return a.o > b.o;
            });
  const size_t cap = static_cast<size_t>(max_num_features);
  size_t kept = 0;
  int prev = std::numeric_limits<int>::max();
  for (int i = 0; i < num_features; ++i) {
    ++kept;
    const int osi = features[i].o * kMaxOctaveResolution + features[i].s;
    if (osi != prev && kept >= cap) break;
    prev = osi;
  }
  return kept;
}

struct GssOctave {
  int o;
  int width, height;
  double step;
  std::vector<std::vector<float>> levels;
};

std::vector<float> gpu_blur(aether::tools::DawnKernelHarness& h,
                            wgpu::ComputePipeline& pipe,
                            const std::vector<float>& src, int w, int hh,
                            const std::vector<float>& taps, int radius) {
  const size_t n = static_cast<size_t>(w) * hh;
  const size_t bytes = n * sizeof(float);
  wgpu::Buffer taps_buf =
      h.upload(taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);
  wgpu::Buffer src_buf = h.upload(src.data(), bytes, wgpu::BufferUsage::Storage);
  wgpu::Buffer dst_buf =
      h.alloc(bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  BlurParams pv{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 1u};
  wgpu::Buffer pv_buf = h.upload(&pv, sizeof(pv), wgpu::BufferUsage::Uniform);
  const uint32_t gx = ((uint32_t)w + 7u) / 8u, gy = ((uint32_t)hh + 7u) / 8u;
  h.dispatch(pipe, {src_buf, taps_buf, dst_buf, pv_buf}, gx, gy, 1u);
  wgpu::Buffer st = h.alloc_staging_for_readback(bytes);
  h.copy_to_staging(dst_buf, st, bytes);
  std::vector<uint8_t> tb = h.readback(st, bytes);
  std::vector<float> tmp(n);
  std::memcpy(tmp.data(), tb.data(), bytes);
  wgpu::Buffer s2 = h.upload(tmp.data(), bytes, wgpu::BufferUsage::Storage);
  wgpu::Buffer d2 =
      h.alloc(bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  BlurParams ph{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 0u};
  wgpu::Buffer ph_buf = h.upload(&ph, sizeof(ph), wgpu::BufferUsage::Uniform);
  h.dispatch(pipe, {s2, taps_buf, d2, ph_buf}, gx, gy, 1u);
  wgpu::Buffer st2 = h.alloc_staging_for_readback(bytes);
  h.copy_to_staging(d2, st2, bytes);
  std::vector<uint8_t> ob = h.readback(st2, bytes);
  std::vector<float> out(n);
  std::memcpy(out.data(), ob.data(), bytes);
  return out;
}

std::vector<float> gpu_downsample(aether::tools::DawnKernelHarness& h,
                                  wgpu::ComputePipeline& pipe,
                                  const std::vector<float>& src, int sw, int sh,
                                  int dw, int dh) {
  const size_t src_n = (size_t)sw * sh, dst_n = (size_t)dw * dh;
  const size_t dst_bytes = dst_n * sizeof(float);
  wgpu::Buffer src_buf =
      h.upload(src.data(), src_n * sizeof(float), wgpu::BufferUsage::Storage);
  wgpu::Buffer dst_buf =
      h.alloc(dst_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  DownParams p{(uint32_t)sw, (uint32_t)sh, (uint32_t)dw, (uint32_t)dh};
  wgpu::Buffer p_buf = h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);
  const uint32_t gx = ((uint32_t)dw + 7u) / 8u, gy = ((uint32_t)dh + 7u) / 8u;
  h.dispatch(pipe, {src_buf, dst_buf, p_buf}, gx, gy, 1u);
  wgpu::Buffer st = h.alloc_staging_for_readback(dst_bytes);
  h.copy_to_staging(dst_buf, st, dst_bytes);
  std::vector<uint8_t> ob = h.readback(st, dst_bytes);
  std::vector<float> out(dst_n);
  std::memcpy(out.data(), ob.data(), dst_bytes);
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
//  Run the WHOLE extraction for one image: CPU baseline + S2 hybrid + report.
//  Returns the cumulative core speedup (CPU / S2-gpu-resident-with-refine->0).
// ════════════════════════════════════════════════════════════════════════════
struct StageResult {
  // CPU baseline
  double cpu_total_ms = 0, cpu_putimg_ms = 0, cpu_detect_ms = 0,
         cpu_affine_ms = 0, cpu_orient_ms = 0, cpu_sort_ms = 0, cpu_desc_ms = 0;
  size_t cpu_kp = 0;
  // S2 hybrid stages
  double gss_ms = 0, dog_ms = 0, cand_readback_ms = 0, refine_ms = 0,
         suppress_ms = 0, kp_readback_ms = 0, gss_readback_ms = 0,
         h_affine_ms = 0, h_orient_ms = 0, h_sort_ms = 0, h_desc_ms = 0;
  double gss_mb = 0;
  uint32_t gpu_cand_count = 0;
  int refined_kp = 0;          // GPU refine+gate survivors (seeded into affine)
  size_t hyb_kp = 0;           // final kp after sort+clamp
  // correctness
  size_t ref_cands = 0, matched = 0;
  int vlfeat_full_kp = 0;      // VLFeat monolithic detect kp count (parity ref)
};

StageResult run_image(const char* img_path, int num_threads,
                      aether::tools::DawnKernelHarness& harness,
                      wgpu::ComputePipeline& blur_pipe,
                      wgpu::ComputePipeline& resample_pipe,
                      wgpu::ComputePipeline& dog_pipe,
                      wgpu::ComputePipeline& refine_pipe) {
  StageResult R{};
  const int octave_resolution = 3;
  const double peak_threshold = 0.02 / octave_resolution;  // COLMAP default
  const double edge_threshold = 10.0;
  const int max_num_features = 8192;

  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s): %s\n", img_path,
                 stbi_failure_reason());
    std::exit(2);
  }
  std::vector<float> gray((size_t)iw * ih);
  for (size_t i = 0; i < gray.size(); ++i) gray[i] = (float)pixels[i];
  stbi_image_free(pixels);
  std::printf("\nimage: %s  %dx%d  (peak_thr=%.6f edge_thr=%.1f maxN=%d)\n",
              img_path, iw, ih, peak_threshold, edge_threshold,
              max_num_features);

  // ── (A) CPU BASELINE ──
  {
    auto t_all = clock_t_::now();
    VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cd, 0);
    vl_covdet_set_octave_resolution(cd, octave_resolution);
    vl_covdet_set_peak_threshold(cd, peak_threshold);
    vl_covdet_set_edge_threshold(cd, edge_threshold);
    auto t = clock_t_::now();
    vl_covdet_put_image(cd, gray.data(), iw, ih);
    R.cpu_putimg_ms = ms_since(t);
    t = clock_t_::now();
    vl_covdet_detect(cd, max_num_features);
    R.cpu_detect_ms = ms_since(t);
    R.vlfeat_full_kp = vl_covdet_get_num_features(cd);  // refined+gated count
    t = clock_t_::now();
    affine_shape_threaded(cd, num_threads);
    R.cpu_affine_ms = ms_since(t);
    t = clock_t_::now();
    vl_covdet_extract_orientations(cd);
    R.cpu_orient_ms = ms_since(t);
    t = clock_t_::now();
    R.cpu_kp = sort_and_clamp(cd, max_num_features);
    R.cpu_sort_ms = ms_since(t);
    std::vector<uint8_t> desc;
    DspOpts o;
    o.peak_threshold = peak_threshold;
    o.edge_threshold = edge_threshold;
    o.max_num_features = max_num_features;
    t = clock_t_::now();
    dsp_descriptor_threaded(cd, o, R.cpu_kp, &desc, num_threads);
    R.cpu_desc_ms = ms_since(t);
    R.cpu_total_ms = ms_since(t_all);
    vl_covdet_delete(cd);
  }

  // ── (B) S2 HYBRID ──
  // Build a covdet for geometry + the seed octave-0 firstSub level + the
  // gss (borrowed read-only by the CPU affine/orient/descriptor continuation).
  VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cd, 0);
  vl_covdet_set_octave_resolution(cd, octave_resolution);
  vl_covdet_set_peak_threshold(cd, peak_threshold);
  vl_covdet_set_edge_threshold(cd, edge_threshold);
  vl_covdet_put_image(cd, gray.data(), iw, ih);
  VlScaleSpace* gss = vl_covdet_get_gss(cd);
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const int firstSub = (int)g.octaveFirstSubdivision;
  const int lastSub = (int)g.octaveLastSubdivision;
  const int prevLevelIndex =
      std::min(firstSub + (int)g.octaveResolution, lastSub);
  const int num_gss_levels = lastSub - firstSub + 1;
  const int num_css_levels = num_gss_levels - 1;

  // B.1 GPU gss build (chained).
  auto t_gss = clock_t_::now();
  std::vector<GssOctave> octs;
  std::vector<float> seed_prev;
  int prev_ow = 0, prev_oh = 0;
  for (int o = (int)g.firstOctave; o <= (int)g.lastOctave; ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    const int ow = (int)og.width, oh = (int)og.height;
    const double step = og.step;
    GssOctave oct;
    oct.o = o; oct.width = ow; oct.height = oh; oct.step = step;
    oct.levels.resize(num_gss_levels);
    std::vector<float> level0;
    if (o == (int)g.firstOctave) {
      const float* cf = vl_scalespace_get_level_const(gss, o, firstSub);
      level0.assign(cf, cf + (size_t)ow * oh);
    } else {
      std::vector<float> rs =
          gpu_downsample(harness, resample_pipe, seed_prev, prev_ow, prev_oh, ow, oh);
      const double sigma0 = vl_scalespace_get_level_sigma(gss, o, firstSub);
      const double prevSigma =
          vl_scalespace_get_level_sigma(gss, o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - prevSigma * prevSigma);
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
        level0 = gpu_blur(harness, blur_pipe, rs, ow, oh, taps, radius);
      } else {
        level0 = rs;
      }
    }
    oct.levels[0] = level0;
    std::vector<float> cur = level0;
    for (int s = firstSub + 1; s <= lastSub; ++s) {
      const double sig = vl_scalespace_get_level_sigma(gss, o, s);
      const double sigp = vl_scalespace_get_level_sigma(gss, o, s - 1);
      const double ds = std::sqrt(sig * sig - sigp * sigp);
      int radius = 0;
      std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
      cur = gpu_blur(harness, blur_pipe, cur, ow, oh, taps, radius);
      oct.levels[s - firstSub] = cur;
      if (s == prevLevelIndex) { seed_prev = cur; prev_ow = ow; prev_oh = oh; }
    }
    octs.push_back(std::move(oct));
  }
  R.gss_ms = ms_since(t_gss);

  // ── B.2 + B.3  GPU DETECTION-FULL, per octave:
  //   DoG+extremum (S1 sift_dog_extrema_test.wgsl `detect`)  ->  per-octave
  //   candidate buffer  ->  Newton refine+gate (task A sift_refine_gate.wgsl
  //   `refine`)  ->  shared DENSE keypoint buffer (atomic-appended across
  //   octaves). The candidate buffer never leaves the GPU; the gss is uploaded
  //   per octave and re-read by BOTH kernels (PLAN "gss resident, re-read ~4x").
  //   This is the S2 boundary: the GPU outputs the FINAL refined+gated kps.
  const uint32_t kCap = 65536u;     // candidate over-detect cap (per octave)
  const uint32_t kKpCap = 65536u;   // refined keypoint cap (shared)
  std::vector<Keypoint> gpu_kps;
  std::vector<CandidateExtremum> gpu_cands;  // for correctness check only
  {
    // Shared dense survivor buffer + survivor count (zero-init once).
    wgpu::Buffer kp_count_buf =
        harness.alloc(sizeof(uint32_t),
                      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                          wgpu::BufferUsage::CopyDst);
    uint32_t zero = 0;
    harness.queue().WriteBuffer(kp_count_buf, 0, &zero, sizeof(zero));
    wgpu::Buffer kp_out_buf = harness.alloc(
        (size_t)kKpCap * sizeof(Keypoint),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    uint32_t total_cands = 0;
    auto t_det = clock_t_::now();
    double dog_acc = 0, refine_acc = 0;
    for (const auto& oct : octs) {
      const size_t plane = (size_t)oct.width * oct.height;
      // Pack this octave's gss levels (re-read by both kernels).
      std::vector<float> packed((size_t)num_gss_levels * plane);
      for (int l = 0; l < num_gss_levels; ++l)
        std::memcpy(packed.data() + (size_t)l * plane, oct.levels[l].data(),
                    plane * sizeof(float));
      wgpu::Buffer gss_buf = harness.upload(
          packed.data(), packed.size() * sizeof(float), wgpu::BufferUsage::Storage);

      // ── B.2  DoG + extremum (S1 kernel) -> per-octave candidate buffer. ──
      wgpu::Buffer cand_count_buf =
          harness.alloc(sizeof(uint32_t),
                        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                            wgpu::BufferUsage::CopyDst);
      harness.queue().WriteBuffer(cand_count_buf, 0, &zero, sizeof(zero));
      wgpu::Buffer cand_out_buf = harness.alloc(
          (size_t)kCap * sizeof(CandidateExtremum),
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      DogExtremaParams dp{};
      dp.width = (uint32_t)oct.width;
      dp.height = (uint32_t)oct.height;
      dp.num_css = (uint32_t)num_css_levels;
      dp.octave = (uint32_t)oct.o;
      dp.detect_thr = (float)(0.8 * peak_threshold);
      dp.max_count = kCap;
      wgpu::Buffer dp_buf =
          harness.upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
      const uint32_t gx = ((uint32_t)oct.width + 7u) / 8u;
      const uint32_t gy = ((uint32_t)oct.height + 7u) / 8u;
      const uint32_t gz = (uint32_t)num_css_levels;
      auto td = clock_t_::now();
      harness.dispatch(dog_pipe, {gss_buf, cand_count_buf, cand_out_buf, dp_buf},
                       gx, gy, gz);
      // Read this octave's candidate count (tiny, needed to size the refine
      // dispatch — this is the per-octave count readback, the only mid-pipeline
      // readback; the PLAN defers the indirect-args removal to a later stage).
      wgpu::Buffer cc_stage = harness.alloc_staging_for_readback(sizeof(uint32_t));
      harness.copy_to_staging(cand_count_buf, cc_stage, sizeof(uint32_t));
      std::vector<uint8_t> ccb = harness.readback(cc_stage, sizeof(uint32_t));
      uint32_t oct_cands = 0;
      std::memcpy(&oct_cands, ccb.data(), sizeof(uint32_t));
      const uint32_t oct_cands_read = std::min(oct_cands, kCap);
      dog_acc += ms_since(td);
      total_cands += oct_cands;

      // Pull this octave's candidates for the correctness check (diagnostic).
      if (oct_cands_read > 0) {
        const size_t cb = (size_t)oct_cands_read * sizeof(CandidateExtremum);
        wgpu::Buffer cs = harness.alloc_staging_for_readback(cb);
        harness.copy_to_staging(cand_out_buf, cs, cb);
        std::vector<uint8_t> cob = harness.readback(cs, cb);
        const size_t base = gpu_cands.size();
        gpu_cands.resize(base + oct_cands_read);
        std::memcpy(gpu_cands.data() + base, cob.data(), cb);
      }

      // ── B.3  Newton refine + gate (task A kernel) -> shared dense kps. ──
      RefineParams rp{};
      rp.width = (uint32_t)oct.width;
      rp.height = (uint32_t)oct.height;
      rp.num_css = (uint32_t)num_css_levels;
      rp.num_cands = oct_cands_read;
      rp.peak_thr = (float)peak_threshold;   // FULL peakThreshold (post-gate)
      rp.edge_thr = (float)edge_threshold;
      rp.base_scale = (float)g.baseScale;
      rp.step = (float)oct.step;
      rp.first_sub = firstSub;
      rp.octave_res = (float)g.octaveResolution;
      rp.max_kp = kKpCap;
      wgpu::Buffer rp_buf =
          harness.upload(&rp, sizeof(rp), wgpu::BufferUsage::Uniform);
      if (oct_cands_read > 0) {
        const uint32_t rgx = (oct_cands_read + 63u) / 64u;  // workgroup_size(64)
        auto tr = clock_t_::now();
        // binding order: gss(0), cands(1), out_count(2), out_kp(3), P(4)
        harness.dispatch(refine_pipe,
                         {gss_buf, cand_out_buf, kp_count_buf, kp_out_buf, rp_buf},
                         rgx, 1u, 1u);
        refine_acc += ms_since(tr);
      }
    }
    R.dog_ms = dog_acc;
    R.refine_ms = refine_acc;   // MEASURED GPU refine+gate (task A kernel)
    R.gpu_cand_count = total_cands;
    (void)ms_since(t_det);

    // ── B.3b  THE S2 boundary readback: the dense refined-keypoint buffer. ──
    auto tr = clock_t_::now();
    wgpu::Buffer kc_stage = harness.alloc_staging_for_readback(sizeof(uint32_t));
    harness.copy_to_staging(kp_count_buf, kc_stage, sizeof(uint32_t));
    std::vector<uint8_t> kcb = harness.readback(kc_stage, sizeof(uint32_t));
    uint32_t kp_count = 0;
    std::memcpy(&kp_count, kcb.data(), sizeof(uint32_t));
    const uint32_t kp_read = std::min(kp_count, kKpCap);
    const size_t kp_bytes = (size_t)kp_read * sizeof(Keypoint);
    if (kp_bytes > 0) {
      wgpu::Buffer ks = harness.alloc_staging_for_readback(kp_bytes);
      harness.copy_to_staging(kp_out_buf, ks, kp_bytes);
      std::vector<uint8_t> kob = harness.readback(ks, kp_bytes);
      gpu_kps.resize(kp_read);
      std::memcpy(gpu_kps.data(), kob.data(), kp_bytes);
    }
    R.kp_readback_ms = ms_since(tr);
  }

  // The GPU refine+gate kernel produced the FINAL refined+gated keypoints.
  // Move into the working `refined` vector (the seed source for affine-onward).
  std::vector<Keypoint> refined = std::move(gpu_kps);

  // ── B.4b  nonExtremaSuppression (VLFeat covdet.c:2104-2139, tol=0.5). ──
  //  VLFeat's vl_covdet_detect ALWAYS runs this as the LAST step of detection
  //  (default nonExtremaSuppression=0.5, covdet.c:1536) — the production
  //  extractor (aether_threaded_extract.cc:85, COLMAP sift.cc:389) inherits it.
  //  It suppresses spatially+scale-near duplicates (keep the higher |peakScore|).
  //  This is part of DETECTION finalization, so it belongs in task A's GPU
  //  refine+gate stage (or a tiny post-pass); replicated here verbatim so the
  //  S2 keypoint set is PRODUCTION-EXACT (matches vl_covdet_detect, not the raw
  //  find+refine set, which over-counts by ~1.4%). Timed as a detection sub-stage.
  {
    auto t = clock_t_::now();
    const double tol = 0.5;
    const int nf = (int)refined.size();
    std::vector<float> sup_x(nf), sup_y(nf), sup_sigma(nf), sup_score(nf);
    for (int i = 0; i < nf; ++i) {
      sup_x[i] = refined[i].x_local * refined[i].step;   // frame.x (image coords)
      sup_y[i] = refined[i].y_local * refined[i].step;   // frame.y
      sup_sigma[i] = refined[i].sigma;                   // frame.a11
      sup_score[i] = refined[i].peak_score;
    }
    for (int i = 0; i < nf; ++i) {
      const double x = sup_x[i], y = sup_y[i], sigma = sup_sigma[i];
      const double score = sup_score[i];
      if (score == 0) continue;
      for (int j = 0; j < nf; ++j) {
        const double dx_ = sup_x[j] - x, dy_ = sup_y[j] - y;
        const double sigma_ = sup_sigma[j], score_ = sup_score[j];
        if (score_ == 0) continue;
        if (sigma < (1 + tol) * sigma_ && sigma_ < (1 + tol) * sigma &&
            std::fabs(dx_) < tol * sigma && std::fabs(dy_) < tol * sigma &&
            std::fabs(score) > std::fabs(score_)) {
          sup_score[j] = 0;
        }
      }
    }
    std::vector<Keypoint> kept;
    kept.reserve(refined.size());
    for (int i = 0; i < nf; ++i)
      if (sup_score[i] != 0) kept.push_back(refined[i]);
    refined.swap(kept);
    R.suppress_ms = ms_since(t);
  }
  R.refined_kp = (int)refined.size();

  // ── B.6  gss readback PROBE (STILL NEEDED in S2 — see file header). ──
  size_t gss_floats = 0;
  for (const auto& oct : octs)
    gss_floats += (size_t)num_gss_levels * oct.width * oct.height;
  R.gss_mb = gss_floats * sizeof(float) / (1024.0 * 1024.0);
  {
    const auto& o0 = octs.front();
    const size_t plane = (size_t)o0.width * o0.height;
    const size_t bytes = (size_t)num_gss_levels * plane * sizeof(float);
    std::vector<float> packed((size_t)num_gss_levels * plane);
    for (int l = 0; l < num_gss_levels; ++l)
      std::memcpy(packed.data() + (size_t)l * plane, o0.levels[l].data(),
                  plane * sizeof(float));
    wgpu::Buffer b = harness.upload(packed.data(), bytes,
                                    wgpu::BufferUsage::Storage |
                                        wgpu::BufferUsage::CopySrc);
    auto t = clock_t_::now();
    wgpu::Buffer st = harness.alloc_staging_for_readback(bytes);
    harness.copy_to_staging(b, st, bytes);
    std::vector<uint8_t> rb = harness.readback(st, bytes);
    const double oct0_ms = ms_since(t);
    const double oct0_mb = bytes / (1024.0 * 1024.0);
    R.gss_readback_ms = oct0_ms * (R.gss_mb / oct0_mb);
    (void)rb;
  }

  // ── B.7  CPU continuation: seed affine-onward with the REFINED GPU kps. ──
  //  S2 starts the CPU at AFFINE-SHAPE (NOT refine — that is now GPU). Seed the
  //  covdet feature list from the refined keypoints via vl_covdet_append_feature
  //  (the SAME append-feature path S1 used, but seeded with REFINED kps).
  vl_covdet_set_num_features(cd, 0);
  for (const auto& rk : refined) {
    VlCovDetFeature feature;
    std::memset(&feature, 0, sizeof(feature));
    feature.frame.x = rk.x_local * rk.step;   // covdet.c:2030 (no +0.5; VLFeat)
    feature.frame.y = rk.y_local * rk.step;
    feature.frame.a11 = rk.sigma; feature.frame.a12 = 0;
    feature.frame.a21 = 0;        feature.frame.a22 = rk.sigma;
    feature.o = (int)rk.octave;
    feature.s = (int)std::lround(rk.z_local) + firstSub;  // covdet.c:2037
    feature.peakScore = rk.peak_score;
    feature.edgeScore = rk.edge_score;
    vl_covdet_append_feature(cd, &feature);
  }

  auto t = clock_t_::now();
  affine_shape_threaded(cd, num_threads);
  R.h_affine_ms = ms_since(t);
  t = clock_t_::now();
  vl_covdet_extract_orientations(cd);
  R.h_orient_ms = ms_since(t);
  t = clock_t_::now();
  R.hyb_kp = sort_and_clamp(cd, max_num_features);
  R.h_sort_ms = ms_since(t);
  std::vector<uint8_t> hyb_desc;
  DspOpts ho;
  ho.peak_threshold = peak_threshold;
  ho.edge_threshold = edge_threshold;
  ho.max_num_features = max_num_features;
  t = clock_t_::now();
  dsp_descriptor_threaded(cd, ho, R.hyb_kp, &hyb_desc, num_threads);
  R.h_desc_ms = ms_since(t);
  vl_covdet_delete(cd);

  // ── candidate-set correctness vs VLFeat vl_find_local_extrema_3 ──
  {
    auto key = [](int o, int z, int x, int y) -> uint64_t {
      return ((uint64_t)(uint32_t)o << 48) ^ ((uint64_t)(uint32_t)z << 36) ^
             ((uint64_t)(uint32_t)x << 18) ^ (uint64_t)(uint32_t)y;
    };
    std::vector<uint64_t> gpu_keys;
    gpu_keys.reserve(gpu_cands.size());
    for (const auto& c : gpu_cands)
      gpu_keys.push_back(key((int)c.octave, (int)c.level, (int)c.x, (int)c.y));
    std::sort(gpu_keys.begin(), gpu_keys.end());
    for (const auto& oct : octs) {
      const size_t plane = (size_t)oct.width * oct.height;
      std::vector<float> css((size_t)num_css_levels * plane);
      for (int z = 0; z < num_css_levels; ++z) {
        const float* a = oct.levels[z].data();
        const float* b = oct.levels[z + 1].data();
        float* d = css.data() + (size_t)z * plane;
        for (size_t k = 0; k < plane; ++k) d[k] = a[k] - b[k];
      }
      vl_index* extrema = nullptr;
      vl_size bufSize = 0;
      vl_size ne = vl_find_local_extrema_3(&extrema, &bufSize, css.data(),
                                           oct.width, oct.height,
                                           num_css_levels, 0.8 * peak_threshold);
      R.ref_cands += ne;
      for (vl_size i = 0; i < ne; ++i) {
        const int x = (int)extrema[3 * i + 0];
        const int y = (int)extrema[3 * i + 1];
        const int z = (int)extrema[3 * i + 2];
        const uint64_t k = key(oct.o, z, x, y);
        if (std::binary_search(gpu_keys.begin(), gpu_keys.end(), k)) ++R.matched;
      }
      if (extrema) vl_free(extrema);
    }
  }
  return R;
}

void print_report(const char* img_path, const StageResult& R) {
  std::printf(
      "\n=== [%s] CPU BASELINE (first_octave=0, DSP-SIFT) ===\n"
      "  put_image(gss build)    : %8.1f ms\n"
      "  detect(css+find+refine) : %8.1f ms\n"
      "  affine-shape            : %8.1f ms\n"
      "  orientation             : %8.1f ms\n"
      "  sort+clamp              : %8.1f ms\n"
      "  DSP descriptor          : %8.1f ms\n"
      "  --------------------------------------\n"
      "  CPU TOTAL               : %8.1f ms   (kp=%zu)\n",
      img_path, R.cpu_putimg_ms, R.cpu_detect_ms, R.cpu_affine_ms,
      R.cpu_orient_ms, R.cpu_sort_ms, R.cpu_desc_ms, R.cpu_total_ms, R.cpu_kp);

  // S2 GPU detection-full wall = gss + DoG + refine+gate, ALL MEASURED GPU
  // (task A's sift_refine_gate.wgsl is wired). The only CPU detection step is
  // nonExtremaSuppression (suppress_ms) — task A defers it to a host post-pass.
  const double gpu_detection_full_ms = R.gss_ms + R.dog_ms + R.refine_ms;
  const double cont_ms =
      R.h_affine_ms + R.h_orient_ms + R.h_sort_ms + R.h_desc_ms;
  // Honest S2 per-frame total (gss kept resident): GPU detection-full + the CPU
  // suppression post-pass + the refined-kp readback + the CPU affine-onward.
  const double s2_resident_ms =
      gpu_detection_full_ms + R.suppress_ms + R.kp_readback_ms + cont_ms;
  const double s2_with_gss_readback_ms = s2_resident_ms + R.gss_readback_ms;
  // Future headroom: suppression moved to a GPU/spatial-grid stage (NOT built).
  const double s2_suppress_gpu_ms =
      gpu_detection_full_ms + R.kp_readback_ms + cont_ms;

  std::printf(
      "\n=== [%s] S2 HYBRID (GPU detection-full -> CPU affine-onward) ===\n"
      "  ----- GPU detection-full (all MEASURED GPU) -----\n"
      "  GPU gss build (chained blur+resample) : %8.1f ms\n"
      "  GPU DoG + extremum test (S1 kernel)   : %8.1f ms\n"
      "  GPU Newton refine + peak/edge gate    : %8.1f ms   (task A kernel, MEASURED)\n"
      "  GPU DETECTION-FULL wall (gss+DoG+ref) : %8.1f ms\n"
      "  ----- detection finalize (CPU post-pass; task A defers to host) -----\n"
      "  CPU nonExtremaSuppress O(N^2) tol=0.5 : %8.1f ms   (->GPU spatial-grid = future)\n"
      "  ----- S2 boundary readback -----\n"
      "  refined-kp readback (%d kp x 32B)     : %8.1f ms   (the S2 boundary readback)\n"
      "  [diagnostic] per-octave cand readback : %8.1f ms   (cands=%u; for parity check)\n"
      "  [STILL NEEDED] gss readback %.0f MB    : %8.1f ms   (affine/orient/desc read gss on CPU)\n"
      "  ----- CPU continuation (starts at affine-shape) -----\n"
      "  CPU affine-shape                      : %8.1f ms\n"
      "  CPU orientation                       : %8.1f ms\n"
      "  CPU sort+clamp                        : %8.1f ms\n"
      "  CPU DSP descriptor                    : %8.1f ms\n"
      "  ==================================================\n"
      "  S2 (gss-resident, GPU detect+CPU supp): %8.1f ms   (kp=%zu)\n"
      "  S2 + gss-readback boundary             : %8.1f ms\n"
      "  S2 if suppression->GPU (future)       : %8.1f ms\n",
      img_path, R.gss_ms, R.dog_ms, R.refine_ms, gpu_detection_full_ms,
      R.suppress_ms, R.refined_kp, R.kp_readback_ms, R.cand_readback_ms,
      R.gpu_cand_count, R.gss_mb, R.gss_readback_ms, R.h_affine_ms,
      R.h_orient_ms, R.h_sort_ms, R.h_desc_ms, s2_resident_ms, R.hyb_kp,
      s2_with_gss_readback_ms, s2_suppress_gpu_ms);

  std::printf(
      "\n=== [%s] CORRECTNESS ===\n"
      "  candidate detect (GPU vs VLFeat find_extrema_3):\n"
      "    VLFeat ref cands : %zu   GPU cands : %u   matched : %zu\n"
      "    recall %.4f  precision %.4f\n"
      "  refined+gated keypoints:\n"
      "    GPU-refine survivors (seeded into affine) : %d\n"
      "    VLFeat monolithic vl_covdet_detect kp     : %d\n"
      "    final kp after affine+orient+sort+clamp   : %zu\n"
      "    kp-count match vs VLFeat detect           : %s (%+d)\n",
      img_path, R.ref_cands, R.gpu_cand_count, R.matched,
      R.ref_cands ? (double)R.matched / R.ref_cands : 0.0,
      R.gpu_cand_count ? (double)R.matched / R.gpu_cand_count : 0.0,
      R.refined_kp, R.vlfeat_full_kp, R.hyb_kp,
      (R.refined_kp == R.vlfeat_full_kp ? "EXACT" : "DIFF"),
      R.refined_kp - R.vlfeat_full_kp);

  std::printf(
      "\n=== [%s] S2 CUMULATIVE SPEEDUP (vs ~2x S2 target) ===\n"
      "  CPU baseline                          : %8.1f ms\n"
      "  S2 (gss-resident, GPU detect+CPU supp): %.2fx\n"
      "  S2 + gss-readback boundary             : %.2fx\n"
      "  S2 if suppression->GPU (future)       : %.2fx\n"
      "  S2 target ~2x : %s\n",
      img_path, R.cpu_total_ms, R.cpu_total_ms / s2_resident_ms,
      R.cpu_total_ms / s2_with_gss_readback_ms,
      R.cpu_total_ms / s2_suppress_gpu_ms,
      (R.cpu_total_ms / s2_resident_ms >= 2.0
           ? "MEETS/EXCEEDS"
           : (R.cpu_total_ms / s2_suppress_gpu_ms >= 2.0
                  ? "MEETS only if suppression->GPU"
                  : "BELOW")));
}

}  // namespace

int main(int argc, char** argv) {
  // Args: [img1] [img2] [num_threads].  Defaults: the two sift_test fixtures.
  std::vector<std::string> imgs;
  int num_threads = 0;
  std::vector<std::string> pos;
  for (int i = 1; i < argc; ++i) pos.emplace_back(argv[i]);
  // last positional that parses as an int (and isn't a path) = num_threads.
  // Simpler: if the final arg is a bare integer, treat it as threads.
  if (!pos.empty()) {
    const std::string& last = pos.back();
    bool is_int = !last.empty() &&
                  last.find_first_not_of("0123456789") == std::string::npos;
    if (is_int) { num_threads = std::atoi(last.c_str()); pos.pop_back(); }
  }
  if (pos.empty()) {
    imgs = {"third_party/glomap_vendor/iosapp/Resources/sift_test.jpg",
            "third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg"};
  } else {
    imgs = pos;
  }

  const int hw = (int)std::thread::hardware_concurrency();
  std::printf("threads: %d (hw concurrency=%d)\n",
              num_threads > 0 ? num_threads : hw, hw);
  std::printf(
      "S2 hybrid: GPU [gss + DoG+extremum + Newton-refine+gate (task A kernel, "
      "MEASURED)] -> CPU [nonExtremaSuppress O(N^2) + affine + orient + sort + "
      "descriptor]\n");

  auto t_dawn = clock_t_::now();
  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    return 2;
  }
  const double dawn_init_ms = ms_since(t_dawn);

  std::string blur_wgsl = read_file("shaders/wgsl/sift_gss_blur.wgsl");
  std::string resample_wgsl = read_file("shaders/wgsl/sift_gss_resample.wgsl");
  std::string dog_wgsl = read_file("shaders/wgsl/sift_dog_extrema_test.wgsl");
  std::string refine_wgsl = read_file("shaders/wgsl/sift_refine_gate.wgsl");
  if (blur_wgsl.empty() || resample_wgsl.empty() || dog_wgsl.empty() ||
      refine_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: missing WGSL (blur/resample/dog/refine)\n");
    return 2;
  }
  auto t_pipe = clock_t_::now();
  wgpu::ComputePipeline blur_pipe = harness.load_compute(blur_wgsl, "main");
  wgpu::ComputePipeline resample_pipe =
      harness.load_compute(resample_wgsl, "downsample");
  wgpu::ComputePipeline dog_pipe = harness.load_compute(dog_wgsl, "detect");
  wgpu::ComputePipeline refine_pipe =
      harness.load_compute(refine_wgsl, "refine");
  const double pipe_ms = ms_since(t_pipe);
  std::printf("[one-time, NOT per-frame] Dawn init %.1f ms, pipelines %.1f ms\n",
              dawn_init_ms, pipe_ms);

  // WARM: run each image once (warm GPU + caches) BEFORE the measured pass.
  std::vector<StageResult> results;
  for (const auto& im : imgs) {
    (void)run_image(im.c_str(), num_threads, harness, blur_pipe, resample_pipe,
                    dog_pipe, refine_pipe);  // warm-up, discarded
    StageResult R = run_image(im.c_str(), num_threads, harness, blur_pipe,
                              resample_pipe, dog_pipe, refine_pipe);
    results.push_back(R);
    print_report(im.c_str(), R);
  }

  // Aggregate cumulative speedup across the fixtures.
  //   gpu_det = gss + DoG + refine+gate (ALL MEASURED GPU)
  //   resident = gpu_det + CPU suppression + kp readback + CPU affine-onward
  double cpu_sum = 0, s2_resident_sum = 0, s2_bnd_sum = 0, s2_suppgpu_sum = 0;
  for (const auto& R : results) {
    const double gpu_det = R.gss_ms + R.dog_ms + R.refine_ms;
    const double cont = R.h_affine_ms + R.h_orient_ms + R.h_sort_ms + R.h_desc_ms;
    cpu_sum += R.cpu_total_ms;
    s2_resident_sum += gpu_det + R.suppress_ms + R.kp_readback_ms + cont;
    s2_bnd_sum +=
        gpu_det + R.suppress_ms + R.kp_readback_ms + R.gss_readback_ms + cont;
    s2_suppgpu_sum += gpu_det + R.kp_readback_ms + cont;
  }
  const double n = (double)results.size();
  const double kIphoneScale = 2.9;  // M3 Pro -> iPhone 14 Pro absolute (PLAN)
  std::printf(
      "\n╔══════════════════════════════════════════════════════════════╗\n"
      "║  S2 AGGREGATE @4224 (warm, %zu fixtures, M3 Pro)               \n"
      "╠══════════════════════════════════════════════════════════════╣\n"
      "║  CPU baseline sum                       : %8.1f ms           \n"
      "║  S2 gss-resident (GPU detect+CPU supp)  : %8.1f ms -> %.2fx  \n"
      "║  S2 + gss-readback boundary              : %8.1f ms -> %.2fx  \n"
      "║  S2 if suppression->GPU (future)        : %8.1f ms -> %.2fx  \n"
      "║  S2 target ~2x                                                 \n"
      "╠══ per-frame avg (M3 Pro) ═════════════════════════════════════╣\n"
      "║  CPU baseline / frame                   : %8.1f ms           \n"
      "║  S2 gss-resident / frame                : %8.1f ms           \n"
      "║  S2 supp->GPU / frame                   : %8.1f ms           \n"
      "╠══ iPhone 14 Pro est. (x%.1f M3-Pro abs, PLAN) ════════════════╣\n"
      "║  S2 gss-resident / frame  (iPhone est.) : %8.1f ms           \n"
      "║  S2 supp->GPU / frame     (iPhone est.) : %8.1f ms           \n"
      "║  streaming budget                       : ~2000   ms/frame    \n"
      "╚══════════════════════════════════════════════════════════════╝\n",
      results.size(), cpu_sum, s2_resident_sum, cpu_sum / s2_resident_sum,
      s2_bnd_sum, cpu_sum / s2_bnd_sum, s2_suppgpu_sum,
      cpu_sum / s2_suppgpu_sum, cpu_sum / n, s2_resident_sum / n,
      s2_suppgpu_sum / n, kIphoneScale, (s2_resident_sum / n) * kIphoneScale,
      (s2_suppgpu_sum / n) * kIphoneScale);

  return 0;
}
