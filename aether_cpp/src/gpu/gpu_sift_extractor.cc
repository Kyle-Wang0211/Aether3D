// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// gpu_sift_extractor.cc — implementation of the reusable batched GPU DSP-SIFT
// extractor. The orchestration (ONE command buffer + INDIRECT dispatch +
// gss-resident pyramid) and ALL kernel math are byte-identical to the validated
// bench/extract_fullgpu_batched.cc. The ONLY structural change: the Dawn device,
// the 11 compute pipelines, and the size-stable resident buffers are created
// ONCE in init() and reused by every extract() call — root-fixing the per-frame
// Tint-recompilation bug.

#include "gpu_sift_extractor.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// NOTE: This module no longer builds (or links) any VLFeat scale space. The
// gss pyramid is built FULLY ON THE GPU from the raw image, and the scale-space
// geometry/sigmas are computed directly from the deterministic VLFeat formula
// (see compute_geometry / level_sigma_geom below). The ~900ms/frame
// vl_covdet_put_image host build is removed. No VLFeat headers are included.

#include "dawn_kernel_harness.h"

namespace aether {
namespace gpu {

// Global count of CreateComputePipeline (Tint compile) calls issued by this
// module. init() bumps it by 11; extract() must NEVER bump it. The verification
// driver reads this before/after each extract() to prove the per-frame Tint cost
// is ZERO (the root-fix). Single-threaded host orchestration → plain int is OK.
long g_pipeline_compile_count = 0;

namespace {

using clock_t_ = std::chrono::steady_clock;
inline double ms_since(clock_t_::time_point t0) {
  return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}

std::string read_file(const std::string& path) {
  std::FILE* f = std::fopen(path.c_str(), "rb");
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

// ════════════════════════════════════════════════════════════════════════════
//  Record / Params layouts — byte-matched to extract_fullgpu_batched.cc.
// ════════════════════════════════════════════════════════════════════════════
#pragma pack(push, 4)
struct BlurParams { uint32_t width, height, radius, axis; };
struct DownParams { uint32_t src_width, src_height, dst_width, dst_height; };
struct DogParams {
  uint32_t width, height, num_css, octave;
  float detect_thr; uint32_t max_count, pad0, pad1;
};
struct CandidateExtremum { uint32_t octave, level, x, y; float dog_value; };
struct RefineParams {
  uint32_t width, height, num_css, num_cands;
  float peak_thr, edge_thr, base_scale, step;
  int32_t first_sub; float octave_res; uint32_t max_kp, pad0;
};
struct Keypoint {
  float x_local, y_local, z_local; uint32_t octave;
  float sigma, step, peak_score, edge_score;
};
struct SuppressParams {
  uint32_t num_kp, grid_w, grid_h, num_cells;
  float cell_size, tol; uint32_t pad0, pad1;
};
struct OctGeom { uint32_t width, height, base, pad; float step, pad1, pad2, pad3; };
struct InFrame { float x, y, a11, a12, a21, a22, pad0, pad1; };
struct AffineShape { float a11, a12, a21, a22, x, y; uint32_t status, iters; };
struct AffParams {
  uint32_t num_kp, num_octaves; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
};
struct InputKp { float x, y, a11, a12, a21, a22; int32_t octave; uint32_t pad0; };
struct OrientedKp { uint32_t kp_index; float angle, score; uint32_t pad0; };
struct OctaveGeomO {
  int32_t width, height; float step; uint32_t gss_offset; int32_t octave;
  uint32_t pad0, pad1, pad2;
};
struct OrientParams {
  uint32_t num_kp, num_octaves; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
  uint32_t max_out, pad0, pad1, pad2;
};
struct OctGeomW { uint32_t w, h, base, pad; float step, pad1, pad2, pad3; };
struct WarpIn { float x, y, a11, a12, a21, a22, pad0, pad1; };
struct FusedParams {
  uint32_t num_kp, dsp_num_scales; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
  float extent, stephat, sigma, k_sigma;
};
struct ArgsPrepParams { uint32_t wg_size, cap, pad0, pad1; };
#pragma pack(pop)
static_assert(sizeof(FusedParams) == 48, "fusedparams 48B");
static_assert(sizeof(CandidateExtremum) == 20, "cand 20B");
static_assert(sizeof(Keypoint) == 32, "kp 32B");
static_assert(sizeof(AffineShape) == 32, "affshape 32B");
static_assert(sizeof(OrientedKp) == 16, "orientedkp 16B");

std::vector<float> vlfeat_gaussian_taps_f(double sigma, int* out_radius) {
  const int width = static_cast<int>(std::ceil(sigma * 3.0));
  const int size = 2 * width + 1;
  std::vector<float> filter(static_cast<size_t>(size));
  float mass = 1.0f;
  filter[static_cast<size_t>(width)] = 1.0f;
  for (int i = 1; i <= width; ++i) {
    const double x = static_cast<double>(i) / sigma;
    const float gg = static_cast<float>(std::exp(-0.5 * x * x));
    mass += gg + gg;
    filter[static_cast<size_t>(width - i)] = gg;
    filter[static_cast<size_t>(width + i)] = gg;
  }
  for (int i = 0; i < size; ++i) filter[static_cast<size_t>(i)] /= mass;
  *out_radius = width;
  return filter;
}

constexpr int    kPatchResolution = 15;
constexpr int    kPatchSide = 2 * kPatchResolution + 1;
constexpr double kPatchRelativeExtent = 7.5;
constexpr double kPatchRelativeSmoothing = 1.0;
constexpr double kPatchStep = kPatchRelativeExtent / kPatchResolution;
constexpr double kSigma = kPatchRelativeExtent / (3.0 * (4 + 1) / 2) / kPatchStep;
constexpr double kDspMinScale = 1.0 / 6.0;
constexpr double kDspMaxScale = 3.0;
constexpr int    kDspNumScales = 10;

std::vector<float> build_expn_lut() {
  const int EXPN_SZ = 256; const double EXPN_MAX = 25.0;
  std::vector<float> tab(EXPN_SZ + 1);
  for (int k = 0; k < EXPN_SZ + 1; ++k)
    tab[k] = static_cast<float>(std::exp(-static_cast<double>(k) * (EXPN_MAX / EXPN_SZ)));
  return tab;
}

struct Geom {
  int firstOctave, lastOctave, firstSub, lastSub, octaveResolution;
  double baseScale;
  double nominalScale;
  int numOct() const { return lastOctave - firstOctave + 1; }
  int numSub() const { return lastSub - firstSub + 1; }
};
struct OctInfo { int o, w, h; double step; uint32_t base; };

// ── Deterministic VLFeat scale-space geometry (DoG, first_octave=0) ──────────
// Replicates, WITHOUT building any VLFeat gss, the geometry that
// vl_covdet_put_image / vl_scalespace_get_default_geometry would produce for a
// w×h image with the given octave resolution. References (worktree VLFeat):
//   covdet.c vl_covdet_put_image (lines 1683-1730): DoG => octaveFirstSub=-1,
//     octaveLastSub=octaveResolution+1; lastOctave = floor(log2(min(w-1,h-1)/15)).
//   scalespace.c vl_scalespace_get_default_geometry (306-319): octaveRes=3,
//     baseScale=1.6*2^(1/octaveRes), nominalScale=0.5, firstOctave=0 here.
//   scalespace.c vl_scalespace_get_octave_geometry (369-376):
//     width=w>>o, height=h>>o, step=2^o  (VL_SHIFT_LEFT(x,-o)=x>>o for o>=0).
// VLFeat sigma recurrence: sigma(o,s)=baseScale*2^(o+s/octaveResolution)
//   (scalespace.c vl_scalespace_get_level_sigma, line 431-433).
inline double level_sigma_geom(const Geom& G, int o, int s) {
  return G.baseScale * std::pow(2.0, o + (double)s / (double)G.octaveResolution);
}

// Build Geom for a w×h image (DoG method, first_octave=0). Matches
// vl_covdet_put_image exactly for octave_resolution>=1.
Geom compute_geometry(int w, int h, int octave_resolution) {
  Geom G{};
  G.firstOctave = 0;
  G.octaveResolution = octave_resolution;
  // lastOctave = vl_floor_d(vl_log2_d(min(w-1,h-1) / (minOctaveSize-1)))
  const double minDim = (double)std::min(w - 1, h - 1);
  const double lo = std::floor(std::log2(minDim / 15.0));  // minOctaveSize=16
  G.lastOctave = (int)lo;
  if (G.lastOctave < G.firstOctave) G.lastOctave = G.firstOctave;
  // DoG: octaveFirstSubdivision=-1, octaveLastSubdivision=octaveResolution+1.
  G.firstSub = -1;
  G.lastSub = octave_resolution + 1;
  // default geometry baseScale/nominalScale (firstOctave overridden to 0).
  G.baseScale = 1.6 * std::pow(2.0, 1.0 / (double)octave_resolution);
  G.nominalScale = 0.5;
  return G;
}

// Octave dims (w>>o, h>>o) and step (2^o) from the geometry — no VLFeat object.
inline void octave_dims(const Geom& G, int o, int w0, int h0, int* ow, int* oh,
                        double* step) {
  *ow = w0 >> o;
  *oh = h0 >> o;
  *step = std::pow(2.0, o);
}

wgpu::BindGroup make_bind_group(
    const wgpu::Device& dev, const wgpu::ComputePipeline& pipe,
    const std::vector<wgpu::Buffer>& bufs,
    const std::vector<std::pair<uint64_t, uint64_t>>& slices) {
  std::vector<wgpu::BindGroupEntry> ents(bufs.size());
  for (size_t i = 0; i < bufs.size(); ++i) {
    ents[i].binding = (uint32_t)i;
    ents[i].buffer = bufs[i];
    ents[i].offset = slices.empty() ? 0 : slices[i].first;
    ents[i].size = slices.empty() ? WGPU_WHOLE_SIZE : slices[i].second;
  }
  wgpu::BindGroupDescriptor bgd{};
  bgd.layout = pipe.GetBindGroupLayout(0);
  bgd.entryCount = (uint32_t)ents.size();
  bgd.entries = ents.data();
  return dev.CreateBindGroup(&bgd);
}

// Pre-compiled pipelines (compiled ONCE in init(), reused every frame).
struct Pipelines {
  wgpu::ComputePipeline blur, down, detect, args_prep, refine;
  wgpu::ComputePipeline bin_count, bin_scatter, suppress;
  wgpu::ComputePipeline affine, orient, fused;
};

// gss RESIDENT build — FULLY ON GPU FROM THE RAW IMAGE. Collapsed to ONE command
// buffer. Within-octave and octave-transition math identical to the validated
// extract_fullgpu_batched.cc / extract_gpuparity.cc --full chained build. The
// ONLY change vs the old build is the SEED: octave-0 level firstSub is produced
// on the GPU from the uploaded raw image (copy + top-up Gaussian to the firstSub
// sigma) instead of being read back from a host-built VLFeat gss level. ALL
// geometry (dims, step) and per-level sigmas come from the deterministic VLFeat
// formula (compute_geometry / level_sigma_geom), so NO VLFeat gss is built.
//
// Octave-0 seed replicates scalespace.c _vl_scalespace_start_octave_from_image
// for first_octave=0 (lines 700-745): copy_and_downsample with numOctaves=0 is a
// pure copy of the raw image into level firstSub; then, since
// sigma(0,firstSub) > nominalScale(0.5), a top-up vl_imsmooth by
// deltaSigma = sqrt(sigma(0,firstSub)^2 - nominalScale^2), step=1. The GPU blur
// shader's clamp-to-edge handling matches vl_imsmooth_f's VL_PAD_BY_CONTINUITY.
wgpu::Buffer build_resident_gss_from_image(
    aether::tools::DawnKernelHarness& h, const Pipelines& P,
    const float* image, int img_w, int img_h, const Geom& G,
    std::vector<OctInfo>* octinfo_out, size_t* total_floats_out,
    double* build_ms_out) {
  const wgpu::Device& dev = h.device();
  const wgpu::Queue& q = h.queue();

  auto align64 = [](size_t v) { return (v + 63u) & ~static_cast<size_t>(63u); };
  std::vector<OctInfo> oi;
  size_t total = 0, max_plane = 0;
  for (int o = G.firstOctave; o <= G.lastOctave; ++o) {
    int ow = 0, oh = 0; double step = 0;
    octave_dims(G, o, img_w, img_h, &ow, &oh, &step);
    OctInfo r; r.o = o; r.w = ow; r.h = oh; r.step = step;
    total = align64(total); r.base = (uint32_t)total; oi.push_back(r);
    const size_t plane = (size_t)r.w * r.h;
    max_plane = std::max(max_plane, plane);
    total += plane * (size_t)G.numSub();
  }
  // octave-0 firstSub seed copies the whole raw image into scratch_a; that plane
  // is (img_w*img_h) which equals octave-0's plane (w>>0 == img_w), already the
  // max — but be defensive in case of any dim rounding.
  max_plane = std::max(max_plane, (size_t)img_w * (size_t)img_h);
  total = align64(total);
  *total_floats_out = total;
  const size_t total_bytes = total * sizeof(float);
  wgpu::Buffer pyramid = h.alloc(total_bytes,
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);

  const size_t scratch_bytes = max_plane * sizeof(float);
  auto mk = [&](wgpu::BufferUsage u) { return h.alloc(scratch_bytes, u); };
  wgpu::Buffer scratch_a = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  wgpu::Buffer scratch_b = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  wgpu::Buffer seed_prev = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);

  const int prevLevelIndex = std::min(G.firstSub + G.octaveResolution, G.lastSub);

  std::vector<wgpu::Buffer> keepalive;
  auto upload = [&](const void* d, size_t n, wgpu::BufferUsage u) {
    wgpu::Buffer b = h.upload(d, n, u); keepalive.push_back(b); return b;
  };

  auto t0 = clock_t_::now();
  wgpu::CommandEncoder enc = dev.CreateCommandEncoder();

  auto blur_rec = [&](const wgpu::Buffer& in_buf, const wgpu::Buffer& mid,
                      const wgpu::Buffer& out_buf, int w, int hh,
                      const std::vector<float>& taps, int radius) {
    wgpu::Buffer taps_buf = upload(taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);
    const uint32_t gx = ((uint32_t)w + 7u) / 8u, gy = ((uint32_t)hh + 7u) / 8u;
    BlurParams pv{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 1u};
    wgpu::Buffer pv_buf = upload(&pv, sizeof(pv), wgpu::BufferUsage::Uniform);
    {
      wgpu::ComputePassEncoder pass = enc.BeginComputePass();
      pass.SetPipeline(P.blur);
      pass.SetBindGroup(0, make_bind_group(dev, P.blur, {in_buf, taps_buf, mid, pv_buf}, {}));
      pass.DispatchWorkgroups(gx, gy, 1u);
      pass.End();
    }
    BlurParams ph{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 0u};
    wgpu::Buffer ph_buf = upload(&ph, sizeof(ph), wgpu::BufferUsage::Uniform);
    {
      wgpu::ComputePassEncoder pass = enc.BeginComputePass();
      pass.SetPipeline(P.blur);
      pass.SetBindGroup(0, make_bind_group(dev, P.blur, {mid, taps_buf, out_buf, ph_buf}, {}));
      pass.DispatchWorkgroups(gx, gy, 1u);
      pass.End();
    }
  };
  auto copy_into_pyramid = [&](const wgpu::Buffer& src, uint32_t base_floats,
                               int s, size_t plane) {
    const uint64_t dst_off =
        (uint64_t)(base_floats + (uint32_t)(s - G.firstSub) * plane) * sizeof(float);
    enc.CopyBufferToBuffer(src, 0, pyramid, dst_off, plane * sizeof(float));
  };

  int prev_ow = 0, prev_oh = 0;
  for (size_t k = 0; k < oi.size(); ++k) {
    const OctInfo& r = oi[k];
    const size_t plane = (size_t)r.w * r.h;
    const double step = r.step;
    if (k == 0) {
      // ── OCTAVE-0 firstSub SEED, FULLY FROM THE RAW IMAGE ──
      // first_octave=0: copy_and_downsample(numOctaves=0) == pure copy of the
      // raw image into scratch_a. (octave-0 dims == image dims.)
      q.WriteBuffer(scratch_a, 0, image, plane * sizeof(float));
      // Top-up: sigma(0,firstSub) > nominalScale(0.5) => smooth by
      // deltaSigma = sqrt(sigma^2 - nominalScale^2), smoothSigma = deltaSigma/step
      // (step==1 at octave 0). scalespace.c lines 734-744.
      const double sigma0 = level_sigma_geom(G, r.o, G.firstSub);
      const double imageSigma = G.nominalScale;
      if (sigma0 > imageSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - imageSigma * imageSigma);
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
        wgpu::Buffer mid = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        keepalive.push_back(mid);
        blur_rec(scratch_a, mid, scratch_b, r.w, r.h, taps, radius);
        enc.CopyBufferToBuffer(scratch_b, 0, scratch_a, 0, plane * sizeof(float));
      }
    } else {
      DownParams dp{(uint32_t)prev_ow, (uint32_t)prev_oh, (uint32_t)r.w, (uint32_t)r.h};
      wgpu::Buffer dp_buf = upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
      const uint32_t gx = ((uint32_t)r.w + 7u) / 8u, gy = ((uint32_t)r.h + 7u) / 8u;
      {
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(P.down);
        pass.SetBindGroup(0, make_bind_group(dev, P.down, {seed_prev, scratch_a, dp_buf}, {}));
        pass.DispatchWorkgroups(gx, gy, 1u);
        pass.End();
      }
      const double sigma0 = level_sigma_geom(G, r.o, G.firstSub);
      const double prevSigma = level_sigma_geom(G, r.o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - prevSigma * prevSigma);
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
        wgpu::Buffer mid = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        keepalive.push_back(mid);
        blur_rec(scratch_a, mid, scratch_b, r.w, r.h, taps, radius);
        enc.CopyBufferToBuffer(scratch_b, 0, scratch_a, 0, plane * sizeof(float));
      }
    }
    copy_into_pyramid(scratch_a, r.base, G.firstSub, plane);
    if (prevLevelIndex == G.firstSub) {
      enc.CopyBufferToBuffer(scratch_a, 0, seed_prev, 0, plane * sizeof(float));
      prev_ow = r.w; prev_oh = r.h;
    }
    for (int s = G.firstSub + 1; s <= G.lastSub; ++s) {
      const double sig = level_sigma_geom(G, r.o, s);
      const double sigp = level_sigma_geom(G, r.o, s - 1);
      const double ds = std::sqrt(sig * sig - sigp * sigp);
      int radius = 0;
      std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
      wgpu::Buffer mid = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      keepalive.push_back(mid);
      blur_rec(scratch_a, mid, scratch_b, r.w, r.h, taps, radius);
      copy_into_pyramid(scratch_b, r.base, s, plane);
      enc.CopyBufferToBuffer(scratch_b, 0, scratch_a, 0, plane * sizeof(float));
      if (s == prevLevelIndex) {
        enc.CopyBufferToBuffer(scratch_b, 0, seed_prev, 0, plane * sizeof(float));
        prev_ow = r.w; prev_oh = r.h;
      }
    }
  }

  wgpu::CommandBuffer cb = enc.Finish();
  q.Submit(1, &cb);
  {
    wgpu::Buffer flush = h.alloc_staging_for_readback(sizeof(float));
    h.copy_to_staging(scratch_a, flush, sizeof(float));
    (void)h.readback(flush, sizeof(float));
  }
  *build_ms_out = ms_since(t0);
  *octinfo_out = std::move(oi);
  return pyramid;
}

}  // namespace

// ════════════════════════════════════════════════════════════════════════════
//  Impl — owns the harness, the pre-compiled pipelines, and the size-stable
//  resident buffers (all created ONCE in init()). extract() reuses them.
// ════════════════════════════════════════════════════════════════════════════
struct GpuSiftExtractor::Impl {
  aether::tools::DawnKernelHarness harness;
  Pipelines PIPE;
  Config cfg{};
  double compile_ms = 0;
  bool ready = false;

  // Resident, size-stable (content-independent) caps — allocated ONCE.
  static constexpr uint32_t kCap = 200000u;     // per-octave candidate cap
  static constexpr uint32_t kKpCap = 200000u;   // refined-kp cap
  // Final-readback / accumulator buffers (independent of image size).
  wgpu::Buffer kp_count;   // 1 u32
  wgpu::Buffer kp_out;     // kKpCap * Keypoint
  // Pre-zeroed candidate-clear pattern (kCap * CandidateExtremum), reused to
  // reset each octave's cand_out before detect.
  std::vector<uint8_t> cand_zeros;

  // Per-(w,h) cached gss pyramid (image-size-dependent — keyed by dims).
  struct Cached {
    wgpu::Buffer pyramid;
    std::vector<OctInfo> octinfo;
    size_t total_floats = 0;
  };
  std::map<std::pair<int, int>, Cached> gss_cache;

  bool run_frame(const float* image, int w, int h, const Geom& G,
                 GpuSiftFrame* out);
};

GpuSiftExtractor::GpuSiftExtractor() : impl_(new Impl()) {}
GpuSiftExtractor::~GpuSiftExtractor() = default;

bool GpuSiftExtractor::init(const Config& cfg) {
  impl_->cfg = cfg;
  // Wire the disk-backed Dawn persistent pipeline cache when a cache_dir is
  // configured (skips the ~31.7s A16 first-launch pipeline compiles on a warm
  // start). Falls back to a plain init() (no cache) when cache_dir is null.
  bool cache_warm = false;
  bool ok = cfg.cache_dir
                ? impl_->harness.init_with_cache(cfg.cache_dir,
                                                 cfg.cache_isolation_key,
                                                 &cache_warm)
                : impl_->harness.init();
  if (!ok) {
    std::fprintf(stderr, "GpuSiftExtractor::init: harness.init() failed\n");
    return false;
  }

  // Resolve shader paths.
  std::string root = cfg.shader_root ? cfg.shader_root : ".";
  if (!root.empty() && root.back() == '/') root.pop_back();
  auto wgsl = [&](const char* name) { return read_file(root + "/shaders/wgsl/" + name); };
  const std::string blur_wgsl = wgsl("sift_gss_blur.wgsl");
  const std::string resample_wgsl = wgsl("sift_gss_resample.wgsl");
  const std::string dog_wgsl = wgsl("sift_dog_extrema_test.wgsl");
  const std::string args_wgsl = wgsl("sift_indirect_args_prep.wgsl");
  const std::string refine_wgsl = wgsl("sift_refine_gate.wgsl");
  const std::string suppress_wgsl = wgsl("sift_nonextrema_suppress.wgsl");
  const std::string affine_wgsl = wgsl("sift_affine_shape.wgsl");
  const std::string orient_wgsl = wgsl("sift_orientation.wgsl");
  const std::string fused_wgsl = wgsl("sift_descriptor_fused.wgsl");
  for (const std::string* p : {&blur_wgsl, &resample_wgsl, &dog_wgsl, &args_wgsl,
                               &refine_wgsl, &suppress_wgsl, &affine_wgsl,
                               &orient_wgsl, &fused_wgsl}) {
    if (p->empty()) {
      std::fprintf(stderr, "GpuSiftExtractor::init: a WGSL source is empty "
                           "(shader_root=%s)\n", root.c_str());
      return false;
    }
  }

  // ── Compile ALL 11 pipelines ONCE (the cost the fused/prof harness paid
  //    PER FRAME). This is the root-fix. Each compile bumps the global compile
  //    counter so the verifier can prove extract() never recompiles. ──
  auto compile_one = [&](const std::string& src, const char* ep) {
    wgpu::ComputePipeline p = impl_->harness.load_compute(src, ep);
    ++g_pipeline_compile_count;
    return p;
  };
  auto tc = clock_t_::now();
  impl_->PIPE.blur = compile_one(blur_wgsl, "main");
  impl_->PIPE.down = compile_one(resample_wgsl, "downsample");
  impl_->PIPE.detect = compile_one(dog_wgsl, "detect");
  impl_->PIPE.args_prep = compile_one(args_wgsl, "prep");
  impl_->PIPE.refine = compile_one(refine_wgsl, "refine");
  impl_->PIPE.bin_count = compile_one(suppress_wgsl, "bin_count");
  impl_->PIPE.bin_scatter = compile_one(suppress_wgsl, "bin_scatter");
  impl_->PIPE.suppress = compile_one(suppress_wgsl, "suppress");
  impl_->PIPE.affine = compile_one(affine_wgsl, "affine_shape");
  impl_->PIPE.orient = compile_one(orient_wgsl, "orient");
  impl_->PIPE.fused = compile_one(fused_wgsl, "descriptor_fused");
  impl_->compile_ms = ms_since(tc);

  // ── Allocate the size-stable resident buffers ONCE. ──
  impl_->kp_count = impl_->harness.alloc(sizeof(uint32_t),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  impl_->kp_out = impl_->harness.alloc((size_t)Impl::kKpCap * sizeof(Keypoint),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  impl_->cand_zeros.assign((size_t)Impl::kCap * sizeof(CandidateExtremum), 0);

  impl_->ready = true;
  return true;
}

double GpuSiftExtractor::init_compile_ms() const { return impl_->compile_ms; }

long GpuSiftExtractor::cache_load_hits() const {
  return impl_->harness.cache_load_hits();
}
long GpuSiftExtractor::cache_store_count() const {
  return impl_->harness.cache_store_count();
}

// ── ONE per-frame GPU pipeline run (execution only; pipelines + caps reused). ──
bool GpuSiftExtractor::Impl::run_frame(const float* image, int img_w, int img_h,
                                       const Geom& G, GpuSiftFrame* out) {
  aether::tools::DawnKernelHarness& harness = this->harness;
  const Pipelines& PIPE = this->PIPE;
  const double peak_threshold = cfg.peak_threshold;
  const double edge_threshold = cfg.edge_threshold;
  const int max_num_features = cfg.max_num_features;
  const double tol = cfg.tol;

  const wgpu::Device& dev = harness.device();
  const wgpu::Queue& q = harness.queue();
  // Scale-space geometry scalars from the deterministic formula (no VLFeat gss).
  const double geom_base_scale = G.baseScale;
  const double geom_octave_res = (double)G.octaveResolution;
  const int D = G.numSub() - 1;
  const int nOct = G.numOct();

  GpuSiftTimings T{};
  auto t_all = clock_t_::now();

  // ── B.1 gss RESIDENT — built FULLY ON GPU FROM THE RAW IMAGE. The octave-0
  //    seed is produced on the GPU (image copy + top-up blur); all subsequent
  //    levels/octaves chain on the GPU. No VLFeat host gss build. The resident
  //    pyramid is allocated each frame here (image-size-dependent). ──
  (void)gss_cache;  // size-keyed cache retained for future reuse of the buffer.
  std::vector<OctInfo> octinfo; size_t total_floats = 0; double gss_ms = 0;
  wgpu::Buffer pyramid = build_resident_gss_from_image(
      harness, PIPE, image, img_w, img_h, G, &octinfo, &total_floats, &gss_ms);
  T.gss_ms = gss_ms;
  T.gss_bytes = (double)total_floats * 4.0;

  // ── B.2/B.3 detect + args-prep + refine — ONE command buffer, INDIRECT. ──
  const uint32_t kCap = Impl::kCap, kKpCap = Impl::kKpCap;
  const double detect_thr = 0.8 * peak_threshold;

  // Reuse the resident kp accumulator (zero its count).
  { uint32_t z = 0; q.WriteBuffer(kp_count, 0, &z, sizeof(z)); }

  std::vector<wgpu::Buffer> dr_keepalive;
  auto dr_up = [&](const void* d, size_t n, wgpu::BufferUsage u) {
    wgpu::Buffer b = harness.upload(d, n, u); dr_keepalive.push_back(b); return b;
  };

  auto t_dr = clock_t_::now();
  {
    wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
    for (const OctInfo& r : octinfo) {
      const size_t plane = (size_t)r.w * r.h;
      const uint64_t slice_off = (uint64_t)r.base * sizeof(float);
      const uint64_t slice_size = (uint64_t)(D + 1) * plane * sizeof(float);

      wgpu::Buffer cand_count = harness.alloc(sizeof(uint32_t),
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
      { uint32_t z = 0; q.WriteBuffer(cand_count, 0, &z, sizeof(z)); }
      dr_keepalive.push_back(cand_count);
      wgpu::Buffer cand_out = harness.alloc((size_t)kCap * sizeof(CandidateExtremum),
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
      q.WriteBuffer(cand_out, 0, cand_zeros.data(), cand_zeros.size());
      dr_keepalive.push_back(cand_out);

      uint32_t args0[3] = {0u, 1u, 1u};
      wgpu::Buffer args_buf = harness.alloc(sizeof(args0),
          wgpu::BufferUsage::Indirect | wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
      q.WriteBuffer(args_buf, 0, args0, sizeof(args0));
      dr_keepalive.push_back(args_buf);

      DogParams dp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, (uint32_t)r.o,
                   (float)detect_thr, kCap, 0u, 0u};
      wgpu::Buffer dp_buf = dr_up(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
      ArgsPrepParams ap{64u, kCap, 0u, 0u};
      wgpu::Buffer ap_buf = dr_up(&ap, sizeof(ap), wgpu::BufferUsage::Uniform);
      RefineParams rp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, kCap,
                      (float)peak_threshold, (float)edge_threshold,
                      (float)geom_base_scale, (float)r.step, G.firstSub,
                      (float)geom_octave_res, kKpCap, 0u};
      wgpu::Buffer rp_buf = dr_up(&rp, sizeof(rp), wgpu::BufferUsage::Uniform);

      const uint32_t gx = ((uint32_t)r.w + 7u) / 8u, gy = ((uint32_t)r.h + 7u) / 8u;

      {
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(PIPE.detect);
        pass.SetBindGroup(0, make_bind_group(dev, PIPE.detect,
            {pyramid, cand_count, cand_out, dp_buf},
            {{slice_off, slice_size}, {0, sizeof(uint32_t)},
             {0, (uint64_t)kCap * sizeof(CandidateExtremum)}, {0, sizeof(DogParams)}}));
        pass.DispatchWorkgroups(gx, gy, (uint32_t)D);
        pass.End();
      }
      {
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(PIPE.args_prep);
        pass.SetBindGroup(0, make_bind_group(dev, PIPE.args_prep,
            {cand_count, args_buf, ap_buf}, {}));
        pass.DispatchWorkgroups(1u, 1u, 1u);
        pass.End();
      }
      {
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(PIPE.refine);
        pass.SetBindGroup(0, make_bind_group(dev, PIPE.refine,
            {pyramid, cand_out, kp_count, kp_out, rp_buf},
            {{slice_off, slice_size}, {0, (uint64_t)kCap * sizeof(CandidateExtremum)},
             {0, sizeof(uint32_t)}, {0, (uint64_t)kKpCap * sizeof(Keypoint)},
             {0, sizeof(RefineParams)}}));
        pass.DispatchWorkgroupsIndirect(args_buf, 0);
        pass.End();
      }
    }
    wgpu::CommandBuffer cb = enc.Finish();
    q.Submit(1, &cb);
    bool done = false;
    harness.instance().WaitAny(q.OnSubmittedWorkDone(wgpu::CallbackMode::WaitAnyOnly,
        [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView){ done = true; }), UINT64_MAX);
  }
  T.detect_refine_ms = ms_since(t_dr);

  uint32_t kp_n = 0;
  {
    wgpu::Buffer s = harness.alloc_staging_for_readback(sizeof(uint32_t));
    harness.copy_to_staging(kp_count, s, sizeof(uint32_t));
    std::vector<uint8_t> b = harness.readback(s, sizeof(uint32_t));
    std::memcpy(&kp_n, b.data(), sizeof(uint32_t));
  }
  const uint32_t kp_read = std::min(kp_n, kKpCap);
  std::vector<Keypoint> refined(kp_read);
  if (kp_read) {
    const size_t bytes = (size_t)kp_read * sizeof(Keypoint);
    wgpu::Buffer s = harness.alloc_staging_for_readback(bytes);
    harness.copy_to_staging(kp_out, s, bytes);
    std::vector<uint8_t> b = harness.readback(s, bytes);
    std::memcpy(refined.data(), b.data(), bytes);
  }

  // ── B.4 nonExtremaSuppression (host prefix-sum + fixed-point; verbatim). ──
  std::vector<uint32_t> keep((size_t)kp_read, 1u);
  {
    auto tsup = clock_t_::now();
    const int n = (int)kp_read;
    std::vector<Keypoint> gpu_kp(n);
    double sig_sum = 0, fx_max = 0, fy_max = 0;
    for (int i = 0; i < n; ++i) {
      gpu_kp[i] = refined[i];
      const float fx = refined[i].x_local * refined[i].step;
      const float fy = refined[i].y_local * refined[i].step;
      gpu_kp[i].x_local = fx; gpu_kp[i].y_local = fy; gpu_kp[i].step = 1.0f;
      sig_sum += refined[i].sigma;
      fx_max = std::max(fx_max, (double)fx); fy_max = std::max(fy_max, (double)fy);
    }
    const double sig_mean = n ? sig_sum / n : 1.0;
    const double cell_size = std::max(8.0, 2.0 * sig_mean);
    const uint32_t grid_w = (uint32_t)std::floor(fx_max / cell_size) + 2u;
    const uint32_t grid_h = (uint32_t)std::floor(fy_max / cell_size) + 2u;
    const uint32_t num_cells = grid_w * grid_h;
    SuppressParams P{(uint32_t)n, grid_w, grid_h, num_cells, (float)cell_size, (float)tol, 0u, 0u};
    const size_t kp_bytes = (size_t)n * sizeof(Keypoint);
    wgpu::Buffer kps_buf = harness.upload(gpu_kp.data(), kp_bytes, wgpu::BufferUsage::Storage);
    wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
    std::vector<uint32_t> zc(num_cells, 0u);
    const size_t cc_bytes = (size_t)num_cells * sizeof(uint32_t);
    wgpu::Buffer cellcnt = harness.upload(zc.data(), cc_bytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
    std::vector<uint32_t> cstart(num_cells + 1u, 0u);
    wgpu::Buffer cellstart = harness.upload(cstart.data(), cstart.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
    std::vector<uint32_t> items((size_t)n, 0xFFFFFFFFu);
    wgpu::Buffer items_buf = harness.upload(items.data(), items.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    std::vector<uint32_t> keep0((size_t)n, 0u);
    wgpu::Buffer keep_buf = harness.upload(keep0.data(), keep0.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
    std::vector<uint32_t> alive0((size_t)n, 1u);
    wgpu::Buffer alive_buf = harness.upload(alive0.data(), alive0.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
    std::vector<wgpu::Buffer> binds = {kps_buf, cellcnt, cellstart, items_buf, keep_buf, P_buf, alive_buf};
    const uint32_t wg = ((uint32_t)n + 63u) / 64u;
    harness.dispatch(PIPE.bin_count, binds, wg ? wg : 1u, 1u, 1u);
    {
      wgpu::Buffer s = harness.alloc_staging_for_readback(cc_bytes);
      harness.copy_to_staging(cellcnt, s, cc_bytes);
      std::vector<uint8_t> b = harness.readback(s, cc_bytes);
      std::vector<uint32_t> counts(num_cells);
      std::memcpy(counts.data(), b.data(), cc_bytes);
      uint32_t acc = 0;
      for (uint32_t c = 0; c < num_cells; ++c) { cstart[c] = acc; acc += counts[c]; }
      cstart[num_cells] = acc;
      q.WriteBuffer(cellstart, 0, cstart.data(), cstart.size() * sizeof(uint32_t));
      q.WriteBuffer(cellcnt, 0, zc.data(), cc_bytes);
    }
    harness.dispatch(PIPE.bin_scatter, binds, wg ? wg : 1u, 1u, 1u);
    const size_t keep_bytes = (size_t)n * sizeof(uint32_t);
    wgpu::Buffer keep_stage = harness.alloc_staging_for_readback(keep_bytes);
    std::vector<uint32_t> cur((size_t)n, 1u);
    for (int it = 0; it < 8; ++it) {
      harness.dispatch(PIPE.suppress, binds, wg ? wg : 1u, 1u, 1u);
      harness.copy_to_staging(keep_buf, keep_stage, keep_bytes);
      std::vector<uint8_t> kb = harness.readback(keep_stage, keep_bytes);
      std::vector<uint32_t> kn((size_t)n);
      std::memcpy(kn.data(), kb.data(), keep_bytes);
      if (it > 0 && kn == cur) break;
      cur = kn;
      q.WriteBuffer(alive_buf, 0, cur.data(), keep_bytes);
    }
    keep = cur;
    T.suppress_ms = ms_since(tsup);
  }
  std::vector<Keypoint> survivors; survivors.reserve(kp_read);
  for (uint32_t i = 0; i < kp_read; ++i) if (keep[i]) survivors.push_back(refined[i]);

  std::vector<OctGeom> octgeom(nOct);
  std::vector<OctaveGeomO> octgeomO(nOct);
  for (int k = 0; k < nOct; ++k) {
    const OctInfo& r = octinfo[k];
    octgeom[k] = OctGeom{(uint32_t)r.w, (uint32_t)r.h, r.base, 0u, (float)r.step, 0, 0, 0};
    octgeomO[k] = OctaveGeomO{r.w, r.h, (float)r.step, r.base, r.o, 0, 0, 0};
  }

  // ── B.5 affine-shape (single dispatch; math identical) ──
  const uint32_t Naff = (uint32_t)survivors.size();
  std::vector<InFrame> aff_in(Naff);
  for (uint32_t i = 0; i < Naff; ++i) {
    const Keypoint& kp = survivors[i];
    const float fx = kp.x_local * kp.step, fy = kp.y_local * kp.step;
    aff_in[i] = InFrame{fx, fy, kp.sigma, 0.f, 0.f, kp.sigma, 0.f, 0.f};
  }
  std::vector<AffineShape> aff_out(Naff);
  {
    wgpu::Buffer oct_buf = harness.upload(octgeom.data(), octgeom.size() * sizeof(OctGeom), wgpu::BufferUsage::Storage);
    wgpu::Buffer frame_buf = harness.upload(aff_in.data(), aff_in.size() * sizeof(InFrame), wgpu::BufferUsage::Storage);
    const size_t obytes = (size_t)Naff * sizeof(AffineShape);
    wgpu::Buffer out_buf = harness.alloc(std::max<size_t>(obytes, 4),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    AffParams P{Naff, (uint32_t)nOct, G.firstOctave, G.lastOctave, G.firstSub, G.lastSub,
                (float)geom_octave_res, (float)geom_base_scale};
    wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
    auto ta = clock_t_::now();
    harness.dispatch(PIPE.affine, {pyramid, oct_buf, frame_buf, out_buf, P_buf}, Naff ? Naff : 1u, 1u, 1u);
    T.affine_ms = ms_since(ta);
    if (Naff) {
      wgpu::Buffer s = harness.alloc_staging_for_readback(obytes);
      harness.copy_to_staging(out_buf, s, obytes);
      std::vector<uint8_t> b = harness.readback(s, obytes);
      std::memcpy(aff_out.data(), b.data(), obytes);
    }
  }

  auto t_hr = clock_t_::now();
  std::vector<InputKp> or_in; std::vector<int> or_src;
  or_in.reserve(Naff); or_src.reserve(Naff);
  for (uint32_t i = 0; i < Naff; ++i) {
    if (aff_out[i].status == 4u) continue;
    InputKp k{};
    k.x = aff_out[i].x; k.y = aff_out[i].y;
    k.a11 = aff_out[i].a11; k.a12 = aff_out[i].a12;
    k.a21 = aff_out[i].a21; k.a22 = aff_out[i].a22;
    k.octave = survivors[i].octave; k.pad0 = 0u;
    or_in.push_back(k); or_src.push_back((int)i);
  }
  T.host_restruct_ms += ms_since(t_hr);
  const uint32_t Nor = (uint32_t)or_in.size();
  const uint32_t kMaxOut = Nor * 4u + 16u;

  // ── B.6 orientation (single dispatch; math identical) ──
  std::vector<OrientedKp> or_recs;
  {
    wgpu::Buffer kp_buf = harness.upload(or_in.data(), std::max<size_t>(or_in.size() * sizeof(InputKp), 4), wgpu::BufferUsage::Storage);
    wgpu::Buffer geom_buf = harness.upload(octgeomO.data(), octgeomO.size() * sizeof(OctaveGeomO), wgpu::BufferUsage::Storage);
    uint32_t z = 0;
    wgpu::Buffer count_buf = harness.upload(&z, sizeof(z), wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    const size_t obytes = (size_t)kMaxOut * sizeof(OrientedKp);
    wgpu::Buffer out_buf = harness.alloc(obytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    OrientParams P{};
    P.num_kp = Nor; P.num_octaves = (uint32_t)nOct;
    P.first_octave = G.firstOctave; P.last_octave = G.lastOctave;
    P.first_sub = G.firstSub; P.last_sub = G.lastSub;
    P.octave_res = (float)geom_octave_res; P.base_scale = (float)geom_base_scale;
    P.max_out = kMaxOut;
    wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
    const uint32_t gx = (Nor + 63u) / 64u;
    auto to = clock_t_::now();
    harness.dispatch(PIPE.orient, {pyramid, kp_buf, geom_buf, count_buf, out_buf, P_buf}, gx ? gx : 1u, 1u, 1u);
    T.orient_ms = ms_since(to);
    uint32_t or_total = 0;
    {
      wgpu::Buffer s = harness.alloc_staging_for_readback(sizeof(uint32_t));
      harness.copy_to_staging(count_buf, s, sizeof(uint32_t));
      std::vector<uint8_t> b = harness.readback(s, sizeof(uint32_t));
      std::memcpy(&or_total, b.data(), sizeof(uint32_t));
    }
    const uint32_t kept = std::min(or_total, kMaxOut);
    or_recs.resize(kept);
    if (kept) {
      const size_t kb = (size_t)kept * sizeof(OrientedKp);
      wgpu::Buffer s = harness.alloc_staging_for_readback(kb);
      harness.copy_to_staging(out_buf, s, kb);
      std::vector<uint8_t> b = harness.readback(s, kb);
      std::memcpy(or_recs.data(), b.data(), kb);
    }
  }

  t_hr = clock_t_::now();
  struct OFrame { float x, y, a11, a12, a21, a22; int octave; float s_key; };
  std::vector<OFrame> finals; finals.reserve(or_recs.size());
  for (const OrientedKp& rc : or_recs) {
    if (rc.kp_index >= Nor) continue;
    const int src = or_src[rc.kp_index];
    const AffineShape& A = aff_out[src];
    const float c = std::cos(rc.angle), s = std::sin(rc.angle);
    OFrame f{};
    f.x = A.x; f.y = A.y;
    f.a11 = A.a11 * c + A.a12 * s; f.a21 = A.a21 * c + A.a22 * s;
    f.a12 = -A.a11 * s + A.a12 * c; f.a22 = -A.a21 * s + A.a22 * c;
    f.octave = survivors[src].octave;
    f.s_key = std::round(survivors[src].z_local + (float)G.firstSub);
    finals.push_back(f);
  }
  std::sort(finals.begin(), finals.end(), [](const OFrame& a, const OFrame& b) {
    if (a.octave == b.octave) return a.s_key > b.s_key; return a.octave > b.octave;
  });
  if ((int)finals.size() > max_num_features) finals.resize(max_num_features);
  const int N = (int)finals.size();
  T.host_restruct_ms += ms_since(t_hr);

  // ── B.7 FUSED descriptor (single dispatch; math identical) ──
  std::vector<uint8_t> gpu_desc((size_t)N * 128);
  {
    std::vector<float> lut = build_expn_lut();
    const double dsp_step = (kDspMaxScale - kDspMinScale) / kDspNumScales;
    wgpu::Buffer lut_buf = harness.upload(lut.data(), lut.size() * sizeof(float), wgpu::BufferUsage::Storage);
    std::vector<OctGeomW> octw(nOct);
    for (int k = 0; k < nOct; ++k) {
      const OctInfo& r = octinfo[k];
      octw[k] = OctGeomW{(uint32_t)r.w, (uint32_t)r.h, r.base, 0u, (float)r.step, 0, 0, 0};
    }
    wgpu::Buffer octw_buf = harness.upload(octw.data(), octw.size() * sizeof(OctGeomW), wgpu::BufferUsage::Storage);
    const size_t n_recs = (size_t)N * kDspNumScales;
    std::vector<WarpIn> wins(n_recs);
    for (int i = 0; i < N; ++i) {
      const OFrame& f = finals[i];
      for (int s = 0; s < kDspNumScales; ++s) {
        const double dsc = kDspMinScale + s * dsp_step;
        wins[(size_t)i * kDspNumScales + s] = WarpIn{
            (float)f.x, (float)f.y, (float)(f.a11 * dsc), (float)(f.a12 * dsc),
            (float)(f.a21 * dsc), (float)(f.a22 * dsc), 0.f, 0.f};
      }
    }
    wgpu::Buffer win_buf = harness.upload(wins.data(), std::max<size_t>(n_recs * sizeof(WarpIn), 4), wgpu::BufferUsage::Storage);
    const size_t out_words = (size_t)N * 32;
    wgpu::Buffer out_buf = harness.alloc(std::max<size_t>(out_words * sizeof(uint32_t), 4),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    const size_t dbg_n = (size_t)N * 128;
    wgpu::Buffer dbg_buf = harness.alloc(std::max<size_t>(dbg_n * sizeof(float), 4),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    FusedParams P{};
    P.num_kp = (uint32_t)N; P.dsp_num_scales = (uint32_t)kDspNumScales;
    P.first_octave = G.firstOctave; P.last_octave = G.lastOctave;
    P.first_sub = G.firstSub; P.last_sub = G.lastSub;
    P.octave_res = (float)geom_octave_res; P.base_scale = (float)geom_base_scale;
    P.extent = (float)kPatchRelativeExtent;
    P.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
    P.sigma = (float)kPatchRelativeSmoothing; P.k_sigma = (float)kSigma;
    wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
    T.desc_peak_bytes = (double)(n_recs * sizeof(WarpIn)) + (double)(out_words * sizeof(uint32_t)) +
        (double)(dbg_n * sizeof(float)) + (double)(lut.size() * sizeof(float)) +
        (double)(octw.size() * sizeof(OctGeomW)) + (double)sizeof(FusedParams);
    const uint32_t wg = ((uint32_t)N + 63u) / 64u;
    auto tdd = clock_t_::now();
    harness.dispatch(PIPE.fused, {pyramid, win_buf, octw_buf, lut_buf, out_buf, P_buf, dbg_buf}, wg ? wg : 1u, 1u, 1u);
    T.desc_ms = ms_since(tdd);
    if (N) {
      wgpu::Buffer s = harness.alloc_staging_for_readback(out_words * sizeof(uint32_t));
      harness.copy_to_staging(out_buf, s, out_words * sizeof(uint32_t));
      std::vector<uint8_t> raw = harness.readback(s, out_words * sizeof(uint32_t));
      std::memcpy(gpu_desc.data(), raw.data(), (size_t)N * 128);
    }
  }

  T.peak_bytes = T.gss_bytes + T.desc_peak_bytes;
  T.gpu_total_ms = ms_since(t_all);   // GPU pipeline only (the ~240ms target)
  T.total_ms = T.gpu_total_ms;        // extract() adds vlfeat_gss_ms on top

  out->count = (size_t)N;
  out->descriptors = std::move(gpu_desc);
  out->x.resize(N); out->y.resize(N); out->sigma.resize(N); out->octave.resize(N);
  for (int i = 0; i < N; ++i) {
    out->x[i] = finals[i].x; out->y[i] = finals[i].y;
    out->sigma[i] = std::sqrt(std::fabs(finals[i].a11 * finals[i].a22 -
                                        finals[i].a12 * finals[i].a21));
    out->octave[i] = finals[i].octave;
  }
  out->timings = T;
  return true;
}

bool GpuSiftExtractor::extract(const float* gray, int w, int h, GpuSiftFrame* out) {
  if (!impl_->ready || !gray || w <= 0 || h <= 0 || !out) return false;

  // ── NO VLFeat host gss build. The scale-space geometry (octave dims, per-level
  //    sigmas, octave count) is computed directly from (w,h,octaveResolution) via
  //    the deterministic VLFeat formula; the gss pyramid is then built FULLY ON
  //    the GPU from the raw image. This removes the ~900ms/frame
  //    vl_covdet_put_image host cost (the critical-path fix). ──
  const Geom G = compute_geometry(w, h, impl_->cfg.octave_resolution);

  // vlfeat_gss_ms is now ZERO by construction (kept in the timings struct for
  // reporting continuity with the pre-fix verifier).
  const double vlfeat_gss_ms = 0.0;

  bool ok = impl_->run_frame(gray, w, h, G, out);
  if (ok) {
    out->timings.vlfeat_gss_ms = vlfeat_gss_ms;
    out->timings.total_ms = out->timings.gpu_total_ms + vlfeat_gss_ms;
  }
  return ok;
}

}  // namespace gpu
}  // namespace aether

// ════════════════════════════════════════════════════════════════════════════
//  C ABI
// ════════════════════════════════════════════════════════════════════════════
extern "C" {

aether_gpu_sift_handle aether_gpu_sift_init(void) {
  auto* ex = new aether::gpu::GpuSiftExtractor();
  aether::gpu::GpuSiftExtractor::Config cfg{};
  // Resolve shader_root from env so the ABI default works regardless of CWD.
  const char* root = std::getenv("AETHER_SHADER_ROOT");
  cfg.shader_root = root;  // null => CWD-relative
  if (!ex->init(cfg)) { delete ex; return nullptr; }
  return reinterpret_cast<aether_gpu_sift_handle>(ex);
}

int aether_gpu_sift_extract(aether_gpu_sift_handle handle, const float* gray,
                            int w, int h, float** out_kp, unsigned char** out_desc,
                            unsigned int* out_count) {
  if (!handle) return 1;
  auto* ex = reinterpret_cast<aether::gpu::GpuSiftExtractor*>(handle);
  aether::gpu::GpuSiftFrame frame;
  if (!ex->extract(gray, w, h, &frame)) return 2;
  const size_t n = frame.count;
  if (out_count) *out_count = (unsigned int)n;
  if (out_kp) {
    float* kp = (float*)std::malloc(std::max<size_t>(n, 1) * 4 * sizeof(float));
    for (size_t i = 0; i < n; ++i) {
      kp[i * 4 + 0] = frame.x[i];
      kp[i * 4 + 1] = frame.y[i];
      kp[i * 4 + 2] = frame.sigma[i];
      kp[i * 4 + 3] = (float)frame.octave[i];
    }
    *out_kp = kp;
  }
  if (out_desc) {
    unsigned char* d = (unsigned char*)std::malloc(std::max<size_t>(n, 1) * 128);
    if (n) std::memcpy(d, frame.descriptors.data(), n * 128);
    *out_desc = d;
  }
  return 0;
}

void aether_gpu_sift_free(aether_gpu_sift_handle handle) {
  if (!handle) return;
  delete reinterpret_cast<aether::gpu::GpuSiftExtractor*>(handle);
}

}  // extern "C"
