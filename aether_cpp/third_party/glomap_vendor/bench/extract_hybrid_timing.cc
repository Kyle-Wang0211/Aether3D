// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// extract_hybrid_timing.cc — S1 hybrid GPU->CPU DSP-SIFT extractor + e2e
// timing harness (GPU_DSP_SIFT_PLAN.md, Stage 1, task B).
//
// ═══════════════════════════════════════════════════════════════════════════
//  WHAT THIS BUILDS
// ═══════════════════════════════════════════════════════════════════════════
//  S1 moves the EARLY DSP-SIFT stages to the GPU (gss build + fused DoG +
//  26-neighbour extremum TEST) and keeps the REST on the CPU (Newton refine +
//  affine-shape + orientation + DSP descriptor). This harness:
//
//   (1) HYBRID PATH — drives the real GPU kernels:
//        a. GPU gss build: shaders/wgsl/sift_gss_blur.wgsl (separable Gaussian,
//           chained within octave) + sift_gss_resample.wgsl (octave transition),
//           first_octave=0 baseline (PLAN 2026-06-25 gate-1 PASS). This is the
//           same code path the gss-build PARITY GATE already validated
//           (commit 9a1b4b6f: 2.18e-6 max-rel across the full pyramid).
//        b. GPU DoG + extremum test: shaders/wgsl/sift_dog_extrema_test.wgsl
//           (task A, entry `detect`), per octave, atomic-append candidates.
//        c. GPU->CPU readback of the candidate-extrema buffer (the ONE forced
//           round-trip/frame; the PLAN's known budget risk — measured here).
//        d. CPU continuation seeded by the GPU candidates: Newton refine
//           (vl_refine_local_extreum_3) + peak/edge gates -> vl_covdet_append_
//           feature -> vl_covdet_extract_affine_shape -> _extract_orientations
//           -> sort + clamp -> threaded DSP descriptor (the exact continuation
//           from bench/aether_threaded_extract.cc, gss BORROWED read-only).
//
//   (2) CPU BASELINE — the pure-CPU reference for the speedup: the SAME VLFeat
//        covdet pipeline run monolithically (vl_covdet_detect does css+find+
//        refine+append internally) at first_octave=0, then affine/orient/sort/
//        descriptor. Controlled comparison: ONLY the detect boundary differs.
//
//   (3) BREAKDOWN — per-stage wall time for both paths: GPU gss, GPU DoG/extrema,
//        candidate readback, css readback (the 161MB-class budget probe), CPU
//        refine, CPU affine, CPU orient, CPU descriptor. Plus a candidate-set
//        CORRECTNESS check: the GPU candidate set vs VLFeat vl_find_local_
//        extrema_3 on the CPU css (recall/precision) — so "GPU detect" is proven
//        equivalent to the VLFeat candidates it replaces, not just fast.
//
//  Honest scope: the GPU candidate detect (task A) IS landed + used here. The
//  ONE deliberate scaffold is that the CPU continuation still reads the css/gss
//  from CPU memory (VLFeat owns them after put_image); in S1 the gss is built on
//  the GPU and the CPU continuation would need it read back — this harness
//  MEASURES that readback cost explicitly (gss_readback_ms) so the boundary's
//  budget impact is grounded, not assumed. S2 removes the boundary (detect
//  finishes on GPU); S4 keeps gss GPU-resident through affine+descriptor.
//
//  Build: bench/build_hybrid_timing.sh (worktree-only, reuses prebuilt Dawn).

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

// vl_find_local_extrema_3 / vl_refine_local_extreum_3 + VlCovDetExtremum3 are
// VL_EXPORT (externally linkable, defined in covdet.c) but NOT declared in
// covdet.h — they are the detector's internal extrema/refine primitives. The
// hybrid path drives them directly (seed the SAME VLFeat Newton refine VLFeat's
// own vl_covdet_detect uses, covdet.c:2011-2040). Forward-declare verbatim from
// covdet.c:1007-1035 so we can link them.
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

// ─── candidate record — MUST match shaders/wgsl/sift_dog_extrema_test.wgsl +
// bench/gpu_extrema_iface.md (20 bytes, std430, 5x4-byte scalars). ───
#pragma pack(push, 4)
struct CandidateExtremum {
  uint32_t octave;
  uint32_t level;  // css-local scale index z (0-based; s = z + octaveFirstSubdivision)
  uint32_t x;
  uint32_t y;
  float dog_value;
};
// Params uniform — MUST match the .wgsl Params struct (8x4 bytes).
struct DogExtremaParams {
  uint32_t width;
  uint32_t height;
  uint32_t num_css;
  uint32_t octave;
  float detect_thr;   // already 0.8 * peakThreshold
  uint32_t max_count;
  uint32_t pad0;
  uint32_t pad1;
};
// gss_blur Params.
struct BlurParams {
  uint32_t width;
  uint32_t height;
  uint32_t radius;
  uint32_t axis;
};
// resample downsample Params.
struct DownParams {
  uint32_t src_width;
  uint32_t src_height;
  uint32_t dst_width;
  uint32_t dst_height;
};
#pragma pack(pop)
static_assert(sizeof(CandidateExtremum) == 20, "candidate record must be 20B");

// VLFeat float Gaussian taps — bit-identical to imopv.c _vl_new_gaussian_
// filter_f (same as extract_gpuparity.cc). All accumulation in float.
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

// VLFeat->UBC descriptor bin reorder (verbatim from aether_threaded_extract.cc).
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

// ─── The DSP descriptor continuation (threaded), reused from
// aether_threaded_extract.cc. Operates on a covdet whose feature list is
// already populated + sorted + clamped, gss frozen. Writes 128xN uint8 UBC. ──
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
  bool l1_root = true;  // L1_ROOT normalization (COLMAP default)
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
      // mean over scales (DSP) or single.
      for (int d = 0; d < 128; ++d) {
        double acc = 0;
        for (int s = 0; s < dsp_num_scales; ++s) acc += scaled[s * 128 + d];
        descriptor[d] = static_cast<float>(acc / dsp_num_scales);
      }
      // L1_ROOT normalize (COLMAP default for DSP/affine): L1 then sqrt.
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
        double v = descriptor[d] * 512.0;  // colmap FeatureDescriptorsToUnsignedByte
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

// Threaded affine-shape (verbatim continuation from aether_threaded_extract.cc).
// Compacts the feature list in place; publishes the new count. Returns count.
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

// Sort + clamp (verbatim from aether_threaded_extract.cc) -> returns kp count.
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

// ════════════════════════════════════════════════════════════════════════════
//  GPU gss build — chained separable blur within octave + downsample across.
//  Returns ALL gss octave levels in CPU memory (the gss readback). Reuses the
//  exact recurrence the parity gate validated. Times each sub-stage.
// ════════════════════════════════════════════════════════════════════════════
struct GssOctave {
  int o;
  int width, height;
  double step;
  std::vector<std::vector<float>> levels;  // [firstSub..lastSub], 0-based
};

std::vector<float> gpu_blur(aether::tools::DawnKernelHarness& h,
                            wgpu::ComputePipeline& pipe,
                            const std::vector<float>& src, int w, int hh,
                            const std::vector<float>& taps, int radius) {
  const size_t n = static_cast<size_t>(w) * hh;
  const size_t bytes = n * sizeof(float);
  wgpu::Buffer taps_buf =
      h.upload(taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);
  // vertical
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
  // horizontal
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

}  // namespace

int main(int argc, char** argv) {
  const char* img_path =
      argc > 1 ? argv[1]
               : "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const int num_threads = argc > 2 ? std::atoi(argv[2]) : 0;  // 0 = hw concurrency
  const char* blur_wgsl_path = "shaders/wgsl/sift_gss_blur.wgsl";
  const char* resample_wgsl_path = "shaders/wgsl/sift_gss_resample.wgsl";
  const char* dog_wgsl_path = "shaders/wgsl/sift_dog_extrema_test.wgsl";

  const int max_num_features = 8192;
  const int octave_resolution = 3;
  const double peak_threshold = 0.02 / octave_resolution;  // COLMAP default
  const double edge_threshold = 10.0;

  // ── Load image as grayscale fp32 in [0,255] (VLFeat convention). ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s): %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::vector<float> gray((size_t)iw * ih);
  for (size_t i = 0; i < gray.size(); ++i) gray[i] = (float)pixels[i];
  stbi_image_free(pixels);
  std::printf("image: %s  %dx%d  (peak_thr=%.6f edge_thr=%.1f maxN=%d)\n",
              img_path, iw, ih, peak_threshold, edge_threshold,
              max_num_features);
  const int hw = (int)std::thread::hardware_concurrency();
  std::printf("threads: %d (hw concurrency=%d)\n",
              num_threads > 0 ? num_threads : hw, hw);

  // ═══════════════════════════════════════════════════════════════════════
  //  (A) CPU BASELINE — full VLFeat covdet pipeline, first_octave=0.
  // ═══════════════════════════════════════════════════════════════════════
  size_t cpu_kp = 0;
  double cpu_total_ms = 0, cpu_putimg_ms = 0, cpu_detect_ms = 0,
         cpu_affine_ms = 0, cpu_orient_ms = 0, cpu_sort_ms = 0, cpu_desc_ms = 0;
  {
    auto t_all = clock_t_::now();
    VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cd, 0);
    vl_covdet_set_octave_resolution(cd, octave_resolution);
    vl_covdet_set_peak_threshold(cd, peak_threshold);
    vl_covdet_set_edge_threshold(cd, edge_threshold);

    auto t = clock_t_::now();
    vl_covdet_put_image(cd, gray.data(), iw, ih);
    cpu_putimg_ms = ms_since(t);

    t = clock_t_::now();
    vl_covdet_detect(cd, max_num_features);
    cpu_detect_ms = ms_since(t);

    t = clock_t_::now();
    affine_shape_threaded(cd, num_threads);
    cpu_affine_ms = ms_since(t);

    t = clock_t_::now();
    vl_covdet_extract_orientations(cd);
    cpu_orient_ms = ms_since(t);

    t = clock_t_::now();
    cpu_kp = sort_and_clamp(cd, max_num_features);
    cpu_sort_ms = ms_since(t);

    std::vector<uint8_t> desc;
    DspOpts o;
    o.peak_threshold = peak_threshold;
    o.edge_threshold = edge_threshold;
    o.max_num_features = max_num_features;
    t = clock_t_::now();
    dsp_descriptor_threaded(cd, o, cpu_kp, &desc, num_threads);
    cpu_desc_ms = ms_since(t);

    cpu_total_ms = ms_since(t_all);
    vl_covdet_delete(cd);
  }
  std::printf(
      "\n=== CPU BASELINE (first_octave=0, DSP-SIFT) ===\n"
      "  put_image(gss build) : %8.1f ms\n"
      "  detect(css+find+refine): %8.1f ms\n"
      "  affine-shape          : %8.1f ms\n"
      "  orientation           : %8.1f ms\n"
      "  sort+clamp            : %8.1f ms\n"
      "  DSP descriptor        : %8.1f ms\n"
      "  -------------------------------------\n"
      "  CPU TOTAL             : %8.1f ms   (kp=%zu)\n",
      cpu_putimg_ms, cpu_detect_ms, cpu_affine_ms, cpu_orient_ms, cpu_sort_ms,
      cpu_desc_ms, cpu_total_ms, cpu_kp);

  // ═══════════════════════════════════════════════════════════════════════
  //  (B) HYBRID — GPU gss + GPU DoG/extrema (task A) -> readback -> CPU cont.
  // ═══════════════════════════════════════════════════════════════════════
  // Dawn init (one-time per process; NOT counted in per-frame budget — on
  // device this is done once at app launch / kept warm).
  auto t_dawn = clock_t_::now();
  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    return 2;
  }
  const double dawn_init_ms = ms_since(t_dawn);

  std::string blur_wgsl = read_file(blur_wgsl_path);
  std::string resample_wgsl = read_file(resample_wgsl_path);
  std::string dog_wgsl = read_file(dog_wgsl_path);
  if (blur_wgsl.empty() || resample_wgsl.empty() || dog_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: missing WGSL (blur/resample/dog)\n");
    return 2;
  }
  auto t_pipe = clock_t_::now();
  wgpu::ComputePipeline blur_pipe = harness.load_compute(blur_wgsl, "main");
  wgpu::ComputePipeline resample_pipe =
      harness.load_compute(resample_wgsl, "downsample");
  wgpu::ComputePipeline dog_pipe = harness.load_compute(dog_wgsl, "detect");
  const double pipe_ms = ms_since(t_pipe);

  // We need the VLFeat gss GEOMETRY to drive the GPU recurrence (sigmas/dims/
  // step) + the CPU seed of octave-0 firstSub level. Build a covdet to read
  // geometry + seed; this geometry read is host metadata, not the gss compute.
  VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cd, 0);
  vl_covdet_set_octave_resolution(cd, octave_resolution);
  vl_covdet_set_peak_threshold(cd, peak_threshold);
  vl_covdet_set_edge_threshold(cd, edge_threshold);
  vl_covdet_put_image(cd, gray.data(), iw, ih);  // builds CPU gss (seed source)
  VlScaleSpace* gss = vl_covdet_get_gss(cd);
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const int firstSub = (int)g.octaveFirstSubdivision;
  const int lastSub = (int)g.octaveLastSubdivision;
  const int prevLevelIndex =
      std::min(firstSub + (int)g.octaveResolution, lastSub);
  const int num_gss_levels = lastSub - firstSub + 1;
  const int num_css_levels = num_gss_levels - 1;  // DoG = adjacent subtract

  // ── B.1  GPU gss build (chained), holding every octave's levels. ──
  auto t_gss = clock_t_::now();
  std::vector<GssOctave> octs;
  std::vector<float> seed_prev;  // GPU octave-(o-1) result @ prevLevelIndex
  int prev_ow = 0, prev_oh = 0;
  for (int o = (int)g.firstOctave; o <= (int)g.lastOctave; ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    const int ow = (int)og.width, oh = (int)og.height;
    const double step = og.step;
    GssOctave oct;
    oct.o = o; oct.width = ow; oct.height = oh; oct.step = step;
    oct.levels.resize(num_gss_levels);

    std::vector<float> level0;  // firstSub level of this octave
    if (o == (int)g.firstOctave) {
      // first_octave=0: seed firstSub from CPU (raw-image smoothing; no GPU
      // predecessor for the very first level — same convention as the parity
      // harness). All subsequent levels are GPU-produced.
      const float* cf = vl_scalespace_get_level_const(gss, o, firstSub);
      level0.assign(cf, cf + (size_t)ow * oh);
    } else {
      // octave transition: GPU downsample of GPU octave-(o-1) @ prevLevelIndex.
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
    oct.levels[0] = level0;  // index 0 == firstSub
    // within-octave chain firstSub+1..lastSub.
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
  const double gss_ms = ms_since(t_gss);

  // ── B.2  GPU DoG + extremum test (task A `detect`), per octave. ──
  // Over-detect cap: PLAN suggests ~24k, but @4224 the pre-refine candidate
  // count (before the post-refine gates + the 8192 clamp) is ~37k on this
  // fixture — so we size the cap above the observed atomic count to avoid
  // buffer-truncation recall loss (the GPU FINDS all of them; truncation only
  // limits how many we READ BACK). 65536 covers it with margin; the real 8192
  // clamp is deferred to S5a (PLAN).
  const uint32_t kCap = 65536u;
  std::vector<CandidateExtremum> gpu_cands;
  double dog_ms = 0, readback_ms = 0;
  uint32_t gpu_total_count = 0;
  {
    // Shared count buffer (zero-init) + shared out buffer; appended across
    // octaves (the iface's per-octave invocation pattern).
    wgpu::Buffer count_buf =
        harness.alloc(sizeof(uint32_t),
                      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                          wgpu::BufferUsage::CopyDst);
    uint32_t zero = 0;
    harness.queue().WriteBuffer(count_buf, 0, &zero, sizeof(zero));
    wgpu::Buffer out_buf = harness.alloc(
        (size_t)kCap * sizeof(CandidateExtremum),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto t = clock_t_::now();
    for (const auto& oct : octs) {
      // Pack this octave's gss levels into one flat buffer (level-major).
      const size_t plane = (size_t)oct.width * oct.height;
      std::vector<float> packed((size_t)num_gss_levels * plane);
      for (int l = 0; l < num_gss_levels; ++l)
        std::memcpy(packed.data() + (size_t)l * plane, oct.levels[l].data(),
                    plane * sizeof(float));
      wgpu::Buffer gss_buf = harness.upload(
          packed.data(), packed.size() * sizeof(float), wgpu::BufferUsage::Storage);
      DogExtremaParams p{};
      p.width = (uint32_t)oct.width;
      p.height = (uint32_t)oct.height;
      p.num_css = (uint32_t)num_css_levels;
      p.octave = (uint32_t)oct.o;
      p.detect_thr = (float)(0.8 * peak_threshold);  // host applies the 0.8
      p.max_count = kCap;
      wgpu::Buffer p_buf =
          harness.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);
      const uint32_t gx = ((uint32_t)oct.width + 7u) / 8u;
      const uint32_t gy = ((uint32_t)oct.height + 7u) / 8u;
      const uint32_t gz = (uint32_t)num_css_levels;  // iface: cover D in z
      // binding order: gss(0), count(1), out(2), P(3)  (gpu_extrema_iface.md)
      harness.dispatch(dog_pipe, {gss_buf, count_buf, out_buf, p_buf}, gx, gy, gz);
    }
    dog_ms = ms_since(t);

    // ── B.3  THE forced GPU->CPU readback: candidate count + buffer. ──
    auto tr = clock_t_::now();
    wgpu::Buffer cnt_stage = harness.alloc_staging_for_readback(sizeof(uint32_t));
    harness.copy_to_staging(count_buf, cnt_stage, sizeof(uint32_t));
    std::vector<uint8_t> cb = harness.readback(cnt_stage, sizeof(uint32_t));
    std::memcpy(&gpu_total_count, cb.data(), sizeof(uint32_t));
    const uint32_t n_read = std::min(gpu_total_count, kCap);
    const size_t cand_bytes = (size_t)n_read * sizeof(CandidateExtremum);
    if (cand_bytes > 0) {
      wgpu::Buffer out_stage = harness.alloc_staging_for_readback(cand_bytes);
      harness.copy_to_staging(out_buf, out_stage, cand_bytes);
      std::vector<uint8_t> ob = harness.readback(out_stage, cand_bytes);
      gpu_cands.resize(n_read);
      std::memcpy(gpu_cands.data(), ob.data(), cand_bytes);
    }
    readback_ms = ms_since(tr);
  }

  // ── B.4  css readback PROBE (the 161MB-class budget risk). ──
  // The CPU continuation (refine + affine + descriptor) needs the css (for
  // refine) + gss (for affine/descriptor patches). In S1 those live on the GPU
  // and must be read back. Measure that transfer for the WHOLE gss pyramid so
  // the boundary's budget impact is grounded. (The CPU continuation below
  // actually reuses the VLFeat-resident gss for parity convenience; this probe
  // is the standalone transfer cost the real boundary would pay.)
  size_t gss_floats = 0;
  for (const auto& oct : octs)
    gss_floats += (size_t)num_gss_levels * oct.width * oct.height;
  const double gss_mb = gss_floats * sizeof(float) / (1024.0 * 1024.0);
  double gss_readback_ms = 0;
  {
    // Upload the largest octave (octave 0) then copy-back to staging to time a
    // representative round-trip bandwidth, scaled to the full pyramid size.
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
    // Scale octave-0 readback time to the full pyramid by MB (bandwidth-bound).
    gss_readback_ms = oct0_ms * (gss_mb / oct0_mb);
    (void)rb;
  }

  // ── B.5  CPU continuation seeded by GPU candidates. ──
  // Build css (DoG) per octave on CPU (needed by vl_refine_local_extreum_3),
  // refine each GPU candidate, gate, append. Then affine/orient/sort/descriptor.
  // Reset the covdet feature list (put_image already built gss; we discard its
  // detect and seed ours from the GPU candidates).
  vl_covdet_set_num_features(cd, 0);

  // Pre-build CPU css octave buffers (depth = num_css_levels), grouped by
  // octave, in css-local z order. This IS the data the GPU produced; building
  // it on CPU here lets us call the VLFeat refine verbatim (the boundary
  // scaffold — see file header). Timed as part of refine.
  double refine_ms = 0;
  int appended = 0;
  {
    auto t = clock_t_::now();
    // group candidates by octave for buffer reuse.
    for (const auto& oct : octs) {
      const int o = oct.o;
      const size_t plane = (size_t)oct.width * oct.height;
      // css volume: depth=num_css_levels, css[z] = gss[z] - gss[z+1].
      std::vector<float> css((size_t)num_css_levels * plane);
      for (int z = 0; z < num_css_levels; ++z) {
        const float* a = oct.levels[z].data();      // gss[z]
        const float* b = oct.levels[z + 1].data();  // gss[z+1]
        float* d = css.data() + (size_t)z * plane;
        for (size_t k = 0; k < plane; ++k) d[k] = a[k] - b[k];  // VLFeat sign
      }
      for (const auto& c : gpu_cands) {
        if ((int)c.octave != o) continue;
        VlCovDetExtremum3 refined;
        const vl_bool ok0 = vl_refine_local_extreum_3(
            &refined, css.data(), oct.width, oct.height, num_css_levels,
            (vl_index)c.x, (vl_index)c.y, (vl_index)c.level);
        bool ok = ok0 && std::fabs(refined.peakScore) > peak_threshold &&
                  refined.edgeScore < edge_threshold;
        if (!ok) continue;
        const double sigma =
            g.baseScale *
            std::pow(2.0, o + (refined.z + firstSub) / (double)g.octaveResolution);
        VlCovDetFeature feature;
        std::memset(&feature, 0, sizeof(feature));
        feature.frame.x = (float)(refined.x * oct.step);
        feature.frame.y = (float)(refined.y * oct.step);
        feature.frame.a11 = (float)sigma; feature.frame.a12 = 0;
        feature.frame.a21 = 0; feature.frame.a22 = (float)sigma;
        feature.o = o;
        feature.s = (int)std::lround(refined.z) + firstSub;
        feature.peakScore = refined.peakScore;
        feature.edgeScore = refined.edgeScore;
        vl_covdet_append_feature(cd, &feature);
        ++appended;
      }
    }
    refine_ms = ms_since(t);
  }

  auto t = clock_t_::now();
  affine_shape_threaded(cd, num_threads);
  const double h_affine_ms = ms_since(t);

  t = clock_t_::now();
  vl_covdet_extract_orientations(cd);
  const double h_orient_ms = ms_since(t);

  t = clock_t_::now();
  const size_t hyb_kp = sort_and_clamp(cd, max_num_features);
  const double h_sort_ms = ms_since(t);

  std::vector<uint8_t> hyb_desc;
  DspOpts ho;
  ho.peak_threshold = peak_threshold;
  ho.edge_threshold = edge_threshold;
  ho.max_num_features = max_num_features;
  t = clock_t_::now();
  dsp_descriptor_threaded(cd, ho, hyb_kp, &hyb_desc, num_threads);
  const double h_desc_ms = ms_since(t);
  vl_covdet_delete(cd);

  // ── candidate-set correctness vs VLFeat vl_find_local_extrema_3 ──
  // Re-run the CPU find-extrema per octave to get the reference candidate set,
  // compare to the GPU set (recall/precision at the integer-voxel level).
  size_t ref_cands = 0, matched = 0;
  {
    // Build a lookup of GPU candidates by (o, z, x, y).
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
      ref_cands += ne;
      for (vl_size i = 0; i < ne; ++i) {
        const int x = (int)extrema[3 * i + 0];
        const int y = (int)extrema[3 * i + 1];
        const int z = (int)extrema[3 * i + 2];
        const uint64_t k = key(oct.o, z, x, y);
        if (std::binary_search(gpu_keys.begin(), gpu_keys.end(), k)) ++matched;
      }
      if (extrema) vl_free(extrema);
    }
  }

  const double hyb_total_ms = gss_ms + dog_ms + readback_ms + refine_ms +
                              h_affine_ms + h_orient_ms + h_sort_ms + h_desc_ms;

  std::printf(
      "\n=== HYBRID (GPU gss + GPU DoG/extrema [task A] -> CPU cont.) ===\n"
      "  [one-time, NOT per-frame] Dawn init   : %8.1f ms\n"
      "  [one-time, NOT per-frame] pipelines   : %8.1f ms\n"
      "  ----- per-frame -----\n"
      "  GPU gss build (chained blur+resample) : %8.1f ms\n"
      "  GPU DoG + extremum test (task A)      : %8.1f ms\n"
      "  GPU->CPU candidate readback (forced)  : %8.1f ms   (cands=%u read=%zu)\n"
      "  [probe] gss readback %.0f MB (S1 risk) : %8.1f ms\n"
      "  CPU refine+gate+append (+ css build)  : %8.1f ms   (appended=%d)\n"
      "  CPU affine-shape                      : %8.1f ms\n"
      "  CPU orientation                       : %8.1f ms\n"
      "  CPU sort+clamp                        : %8.1f ms\n"
      "  CPU DSP descriptor                    : %8.1f ms\n"
      "  -------------------------------------------------\n"
      "  HYBRID TOTAL (per-frame, gss/dog GPU) : %8.1f ms   (kp=%zu)\n"
      "  HYBRID TOTAL + gss-readback boundary  : %8.1f ms\n",
      dawn_init_ms, pipe_ms, gss_ms, dog_ms, readback_ms, gpu_total_count,
      gpu_cands.size(), gss_mb, gss_readback_ms, refine_ms, appended,
      h_affine_ms, h_orient_ms, h_sort_ms, h_desc_ms, hyb_total_ms, hyb_kp,
      hyb_total_ms + gss_readback_ms);

  std::printf(
      "\n=== CANDIDATE CORRECTNESS (GPU detect vs VLFeat find_extrema_3) ===\n"
      "  VLFeat ref candidates : %zu\n"
      "  GPU candidates        : %zu  (atomic count=%u)\n"
      "  matched (GPU∩ref)     : %zu\n"
      "  recall  (matched/ref) : %.4f\n"
      "  precision(matched/gpu): %.4f\n",
      ref_cands, gpu_cands.size(), gpu_total_count, matched,
      ref_cands ? (double)matched / ref_cands : 0.0,
      gpu_cands.empty() ? 0.0 : (double)matched / gpu_cands.size());

  // ═══════════════════════════════════════════════════════════════════════
  //  VERDICT — speedup vs the 1.4-1.7x S1 target.
  // ═══════════════════════════════════════════════════════════════════════
  const double sp_core = cpu_total_ms / hyb_total_ms;
  const double sp_bnd = cpu_total_ms / (hyb_total_ms + gss_readback_ms);
  std::printf(
      "\n=== S1 SPEEDUP @%dx%d ===\n"
      "  CPU baseline total            : %8.1f ms\n"
      "  Hybrid total (gss/dog on GPU) : %8.1f ms   -> speedup %.2fx\n"
      "  Hybrid + gss-readback boundary: %8.1f ms   -> speedup %.2fx\n"
      "  S1 target                     : 1.40-1.70x  (~6-7s if CPU ~10s)\n"
      "  core speedup vs target        : %s\n",
      iw, ih, cpu_total_ms, hyb_total_ms, sp_core,
      hyb_total_ms + gss_readback_ms, sp_bnd,
      (sp_core >= 1.40 ? "MEETS/EXCEEDS" : "BELOW"));

  return 0;
}
