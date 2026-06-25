// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// extract_fullgpu_batched.cc — FULL-GPU DSP-SIFT, S6 ORCHESTRATION re-architecture
// of extract_fullgpu_fused.cc. The KERNELS + MATH are byte-identical to the
// fused harness; only the host-side orchestration changes:
//
//   (1) INDIRECT DISPATCH for the GPU-only count-coupled chain. detect writes
//       its atomic count; a tiny args-prep pass (sift_indirect_args_prep.wgsl)
//       converts count -> [ceil(count/64),1,1]; refine launches via
//       dispatchWorkgroupsIndirect. The CPU NEVER reads the per-octave candidate
//       count between detect and refine. Output buffers are over-allocated to the
//       known caps so no CPU-side resize is needed.
//
//   (2) ONE COMMAND BUFFER for the whole detect+args+refine sequence across ALL
//       octaves (one CommandEncoder -> one Submit -> one wait), with Dawn's
//       auto-inserted storage R/W + storage->indirect barriers between dependent
//       dispatches. The gss build is likewise collapsed to ONE command buffer
//       (was ~100+ tiny Submits). Only the FINAL kp count + records read back.
//
//   (3) PIPELINE COMPILATION HOISTED out of the per-frame loop. The fused harness
//       Tint-compiles every shader (affine 30KB / orient 33KB / desc 23KB) INSIDE
//       the image loop; that compile cost is in the e2e wall but in NO stage timer
//       — a prime suspect for the ~1280ms gap. Here every pipeline is compiled
//       ONCE up front (compile_ms reported separately) + a warm-up frame primes
//       the Tint->Metal pipeline cache; per-frame timing is execution-only.
//
// What is NOT changed (honest scope): suppress (host prefix-sum on cell counts +
// fixed-point iteration), affine->orient record restructuring (ST_REJECT_OOB drop
// + matrix rotation), and the S5a sort+clamp-to-8192 are genuine CPU data
// restructuring (a sort + a filter + rotation math), NOT count-readbacks. Moving
// them to GPU is a radix-sort + GPU-reduction rewrite = NOT "pure orchestration".
// They are kept identical so quality/points/memory are provably unchanged; their
// forced round-trips are reported in the residual.
//
// Build: bench/build_fullgpu_batched.sh (worktree-only; obj /tmp/fullgpu_batched_obj).
// Run from aether_cpp/ root:
//   /tmp/fullgpu_batched_obj/extract_fullgpu_batched_exe \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \
//     third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg
//   --reps N   : run the per-frame pipeline N times warm, report MIN-of-N wall.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern "C" {
#include "covdet.h"
#include "scalespace.h"
#include "sift.h"
#include "imopv.h"
#include "mathop.h"
}

#include "dawn_kernel_harness.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

using clock_t_ = std::chrono::steady_clock;
inline double ms_since(clock_t_::time_point t0) {
  return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
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

// ════════════════════════════════════════════════════════════════════════════
//  Record / Params layouts — byte-matched to extract_fullgpu_fused.cc.
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
// args-prep uniform (sift_indirect_args_prep.wgsl).
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
constexpr double kMagnif = 3.0;
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

void ubc_reorder(const uint8_t* in, uint8_t* out) {
  static const int q[8] = {0, 7, 6, 5, 4, 3, 2, 1};
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      for (int k = 0; k < 8; ++k)
        out[8 * (j + 4 * i) + q[k]] = in[8 * (j + 4 * i) + k];
}

double cosine_u8(const uint8_t* a, const uint8_t* b) {
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < 128; ++i) {
    const double x = a[i], y = b[i]; dot += x * y; na += x * x; nb += y * y;
  }
  if (na == 0.0 || nb == 0.0) return (na == 0.0 && nb == 0.0) ? 1.0 : 0.0;
  return dot / (std::sqrt(na) * std::sqrt(nb));
}
double l2sq_u8(const uint8_t* a, const uint8_t* b) {
  double s = 0;
  for (int i = 0; i < 128; ++i) { const double d = (double)a[i] - (double)b[i]; s += d * d; }
  return s;
}

struct Geom {
  int firstOctave, lastOctave, firstSub, lastSub, octaveResolution;
  double baseScale;
  int numOct() const { return lastOctave - firstOctave + 1; }
  int numSub() const { return lastSub - firstSub + 1; }
};
struct OctInfo { int o, w, h; double step; uint32_t base; };

// ── Helpers to build bind groups + dispatch into a CALLER-OWNED compute pass. ──
// These let us encode many dispatches into ONE command buffer (vs the harness
// dispatch() which submits+waits per call).
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

}  // namespace

// ════════════════════════════════════════════════════════════════════════════
//  Pre-compiled pipelines (compiled ONCE, reused every frame).
// ════════════════════════════════════════════════════════════════════════════
struct Pipelines {
  wgpu::ComputePipeline blur, down, detect, args_prep, refine;
  wgpu::ComputePipeline bin_count, bin_scatter, suppress;
  wgpu::ComputePipeline affine, orient, fused;
};

// ════════════════════════════════════════════════════════════════════════════
//  gss RESIDENT build — collapsed to ONE command buffer (was ~100+ Submits).
//  Math identical to extract_fullgpu_fused.cc build_resident_gss: same seed,
//  same separable v->h blur taps, same CopyBufferToBuffer placement, same
//  resample. The ONLY change: every encoder.* op is recorded into a SINGLE
//  CommandEncoder and submitted once. Each per-level blur needs its own `mid`
//  scratch (a level's v-pass output must not be clobbered before its h-pass);
//  to keep within one encoder without read-after-write hazards on a shared
//  scratch we allocate per-level ping/pong/mid buffers up front (over-alloc to
//  max plane). NO level is ever read back. Returns the resident pyramid.
// ════════════════════════════════════════════════════════════════════════════
static wgpu::Buffer build_resident_gss_batched(
    aether::tools::DawnKernelHarness& h, const Pipelines& P, VlScaleSpace* gss,
    const Geom& G, std::vector<OctInfo>* octinfo_out, size_t* total_floats_out,
    double* build_ms_out) {
  const wgpu::Device& dev = h.device();
  const wgpu::Queue& q = h.queue();

  auto align64 = [](size_t v) { return (v + 63u) & ~static_cast<size_t>(63u); };
  std::vector<OctInfo> oi;
  size_t total = 0, max_plane = 0;
  for (int o = G.firstOctave; o <= G.lastOctave; ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    OctInfo r; r.o = o; r.w = (int)og.width; r.h = (int)og.height; r.step = og.step;
    total = align64(total); r.base = (uint32_t)total; oi.push_back(r);
    const size_t plane = (size_t)r.w * r.h;
    max_plane = std::max(max_plane, plane);
    total += plane * (size_t)G.numSub();
  }
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

  // Keep all per-call uniform/taps/mid buffers alive until submit by holding them.
  std::vector<wgpu::Buffer> keepalive;
  auto upload = [&](const void* d, size_t n, wgpu::BufferUsage u) {
    wgpu::Buffer b = h.upload(d, n, u); keepalive.push_back(b); return b;
  };

  auto t0 = clock_t_::now();
  wgpu::CommandEncoder enc = dev.CreateCommandEncoder();

  // separable blur (v then h) recorded into `enc`. mid is a dedicated scratch.
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
      const float* cf = vl_scalespace_get_level_const(gss, r.o, G.firstSub);
      q.WriteBuffer(scratch_a, 0, cf, plane * sizeof(float));
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
      const double sigma0 = vl_scalespace_get_level_sigma(gss, r.o, G.firstSub);
      const double prevSigma = vl_scalespace_get_level_sigma(gss, r.o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - prevSigma * prevSigma);
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
        wgpu::Buffer mid = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        keepalive.push_back(mid);
        // blur scratch_a -> scratch_b then copy back to scratch_a (avoid in/out alias).
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
      const double sig = vl_scalespace_get_level_sigma(gss, r.o, s);
      const double sigp = vl_scalespace_get_level_sigma(gss, r.o, s - 1);
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

  // ONE submit for the whole pyramid build.
  wgpu::CommandBuffer cb = enc.Finish();
  q.Submit(1, &cb);
  // sync via a tiny scratch staging copy (NOT the pyramid).
  {
    wgpu::Buffer flush = h.alloc_staging_for_readback(sizeof(float));
    h.copy_to_staging(scratch_a, flush, sizeof(float));
    (void)h.readback(flush, sizeof(float));
  }
  *build_ms_out = ms_since(t0);
  *octinfo_out = std::move(oi);
  return pyramid;
}

struct GpuTimings {
  double gss_ms = 0, detect_refine_ms = 0, suppress_ms = 0, affine_ms = 0,
         orient_ms = 0, desc_ms = 0, host_restruct_ms = 0, readback_ms = 0,
         total_ms = 0;
  double gss_bytes = 0, desc_peak_bytes = 0, peak_bytes = 0;
};
struct FullGpuResult {
  GpuTimings t;
  size_t final_kp = 0;
  std::vector<uint8_t> descriptors;
  std::vector<float> frame_x, frame_y, frame_sigma;
  std::vector<int> frame_octave;
  double cpu_baseline_ms = 0, gss_mb = 0;
  int cpu_nf = 0;
  std::vector<double> cpu_fx, cpu_fy; std::vector<int> cpu_fo;
  std::vector<uint8_t> cpu_desc;
};

// ════════════════════════════════════════════════════════════════════════════
//  ONE per-frame GPU pipeline run (execution only; pipelines pre-compiled).
//  Returns the wall-clock for the full B.1-B.7 pipeline.
// ════════════════════════════════════════════════════════════════════════════
static double run_frame(
    aether::tools::DawnKernelHarness& harness, const Pipelines& PIPE,
    VlScaleSpace* gss, const Geom& G, double peak_threshold, double edge_threshold,
    int max_num_features, double tol, GpuTimings* T_out,
    FullGpuResult* RES /*frames+desc out; null to skip stashing*/) {
  const wgpu::Device& dev = harness.device();
  const wgpu::Queue& q = harness.queue();
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const int D = G.numSub() - 1;
  const int nOct = G.numOct();

  GpuTimings T{};
  auto t_all = clock_t_::now();

  // ── B.1 gss RESIDENT (ONE command buffer) ──
  std::vector<OctInfo> octinfo; size_t total_floats = 0; double gss_ms = 0;
  wgpu::Buffer pyramid = build_resident_gss_batched(
      harness, PIPE, gss, G, &octinfo, &total_floats, &gss_ms);
  T.gss_ms = gss_ms;
  T.gss_bytes = (double)total_floats * 4.0;

  // ── B.2/B.3 detect + args-prep + refine — ONE command buffer, INDIRECT. ──
  // Per octave: detect (8x8xD) -> args_prep (1x1x1, count->[ceil/64,1,1]) ->
  // refine via dispatchWorkgroupsIndirect. ALL octaves into ONE encoder, ONE
  // submit, ONE wait. The CPU never reads a per-octave count. cand_out + kp_out
  // over-allocated to caps. Each octave has its OWN cand_count/cand_out/args so
  // there is no cross-octave write hazard; the shared kp_count/kp_out accumulate.
  const uint32_t kCap = 200000u, kKpCap = 200000u;
  const double detect_thr = 0.8 * peak_threshold;

  wgpu::Buffer kp_count = harness.alloc(sizeof(uint32_t),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  { uint32_t z = 0; q.WriteBuffer(kp_count, 0, &z, sizeof(z)); }
  wgpu::Buffer kp_out = harness.alloc((size_t)kKpCap * sizeof(Keypoint),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

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
      // Zero-init the trailing candidate records so refine over-run lanes (≤63
      // past the real count, since indirect grid = ceil(count/64)*64) read
      // all-zero candidates that the gates reject — keeps the count exact w/o a
      // CPU count read. (Verified empirically: recall/precision/count unchanged.)
      { std::vector<uint8_t> zeros((size_t)kCap * sizeof(CandidateExtremum), 0);
        q.WriteBuffer(cand_out, 0, zeros.data(), zeros.size()); }
      dr_keepalive.push_back(cand_out);

      // indirect-args buffer for this octave's refine launch.
      uint32_t args0[3] = {0u, 1u, 1u};
      wgpu::Buffer args_buf = harness.alloc(sizeof(args0),
          wgpu::BufferUsage::Indirect | wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
      q.WriteBuffer(args_buf, 0, args0, sizeof(args0));
      dr_keepalive.push_back(args_buf);

      DogParams dp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, (uint32_t)r.o,
                   (float)detect_thr, kCap, 0u, 0u};
      wgpu::Buffer dp_buf = dr_up(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
      ArgsPrepParams ap{64u, kCap, 0u, 0u};   // refine workgroup_size.x = 64
      wgpu::Buffer ap_buf = dr_up(&ap, sizeof(ap), wgpu::BufferUsage::Uniform);
      // refine num_cands = kCap: real cands [0,count) all run; trailing lanes
      // process zeroed cands (rejected by gates). max_kp = kKpCap.
      RefineParams rp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, kCap,
                      (float)peak_threshold, (float)edge_threshold,
                      (float)g.baseScale, (float)r.step, G.firstSub,
                      (float)g.octaveResolution, kKpCap, 0u};
      wgpu::Buffer rp_buf = dr_up(&rp, sizeof(rp), wgpu::BufferUsage::Uniform);

      const uint32_t gx = ((uint32_t)r.w + 7u) / 8u, gy = ((uint32_t)r.h + 7u) / 8u;

      // detect (direct dispatch).
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
      // args-prep: count -> indirect triple (NO CPU readback).
      {
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(PIPE.args_prep);
        pass.SetBindGroup(0, make_bind_group(dev, PIPE.args_prep,
            {cand_count, args_buf, ap_buf}, {}));
        pass.DispatchWorkgroups(1u, 1u, 1u);
        pass.End();
      }
      // refine: INDIRECT dispatch (grid from args_buf).
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
    // ONE wait + ONE final readback of the accumulated kp count + records.
    bool done = false;
    harness.instance().WaitAny(q.OnSubmittedWorkDone(wgpu::CallbackMode::WaitAnyOnly,
        [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView){ done = true; }), UINT64_MAX);
  }
  T.detect_refine_ms = ms_since(t_dr);

  // FINAL readback: refined kp count + records (this is the kp buffer, NOT gss).
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

  // ── B.4 nonExtremaSuppression — math identical to fused (host prefix-sum +
  //    fixed-point iteration). Genuine CPU restructuring; kept verbatim. ──
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

  // Octave geometry tables.
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
                (float)g.octaveResolution, (float)g.baseScale};
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

  // affine -> orient restructuring (host; identical to fused).
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
    P.octave_res = (float)g.octaveResolution; P.base_scale = (float)g.baseScale;
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

  // oriented frames + sort + clamp (host; identical to fused).
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
    P.octave_res = (float)g.octaveResolution; P.base_scale = (float)g.baseScale;
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
  T.total_ms = ms_since(t_all);
  *T_out = T;

  if (RES) {
    RES->final_kp = (size_t)N;
    RES->descriptors = std::move(gpu_desc);
    RES->gss_mb = total_floats * 4.0 / 1e6;
    RES->frame_x.resize(N); RES->frame_y.resize(N);
    RES->frame_sigma.resize(N); RES->frame_octave.resize(N);
    for (int i = 0; i < N; ++i) {
      RES->frame_x[i] = finals[i].x; RES->frame_y[i] = finals[i].y;
      RES->frame_sigma[i] = std::sqrt(std::fabs(finals[i].a11 * finals[i].a22 -
                                                finals[i].a12 * finals[i].a21));
      RES->frame_octave[i] = finals[i].octave;
    }
  }
  return T.total_ms;
}

int main(int argc, char** argv) {
  std::vector<std::string> imgs;
  int reps = 5;
  for (int i = 1; i < argc; ++i) {
    std::string_view a(argv[i]);
    if (a == "--reps" && i + 1 < argc) { reps = std::atoi(argv[++i]); continue; }
    if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;
    imgs.emplace_back(argv[i]);
  }
  if (imgs.empty()) {
    imgs.emplace_back("third_party/glomap_vendor/iosapp/Resources/sift_test.jpg");
    imgs.emplace_back("third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg");
  }

  const int octave_resolution = 3;
  const double peak_threshold = 0.02 / 3.0;
  const double edge_threshold = 10.0;
  const int max_num_features = 8192;
  const double tol = 0.5;

  // WGSL sources.
  auto rd = [](const char* p) { return read_file(p); };
  const std::string blur_wgsl = rd("shaders/wgsl/sift_gss_blur.wgsl");
  const std::string resample_wgsl = rd("shaders/wgsl/sift_gss_resample.wgsl");
  const std::string dog_wgsl = rd("shaders/wgsl/sift_dog_extrema_test.wgsl");
  const std::string args_wgsl = rd("shaders/wgsl/sift_indirect_args_prep.wgsl");
  const std::string refine_wgsl = rd("shaders/wgsl/sift_refine_gate.wgsl");
  const std::string suppress_wgsl = rd("shaders/wgsl/sift_nonextrema_suppress.wgsl");
  const std::string affine_wgsl = rd("shaders/wgsl/sift_affine_shape.wgsl");
  const std::string orient_wgsl = rd("shaders/wgsl/sift_orientation.wgsl");
  const std::string fused_wgsl = rd("shaders/wgsl/sift_descriptor_fused.wgsl");
  for (auto* p : {&blur_wgsl, &resample_wgsl, &dog_wgsl, &args_wgsl, &refine_wgsl,
                  &suppress_wgsl, &affine_wgsl, &orient_wgsl, &fused_wgsl}) {
    if (p->empty()) { std::fprintf(stderr, "FAIL: a WGSL source empty (run from aether_cpp/ root)\n"); return 2; }
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) { std::fprintf(stderr, "FAIL: harness.init()\n"); return 2; }

  std::printf("=================================================================\n");
  std::printf(" FULL-GPU DSP-SIFT  BATCHED (1 cmd buffer + INDIRECT dispatch)\n");
  std::printf(" config: peak=%.6f edge=%.1f maxN=%d octRes=%d tol=%.2f DSP=%d  reps=%d\n",
              peak_threshold, edge_threshold, max_num_features, octave_resolution,
              tol, kDspNumScales, reps);
  std::printf("=================================================================\n");

  // ── Pre-compile ALL pipelines ONCE (the cost the fused harness paid PER FRAME). ──
  auto tc = clock_t_::now();
  Pipelines PIPE;
  PIPE.blur = harness.load_compute(blur_wgsl, "main");
  PIPE.down = harness.load_compute(resample_wgsl, "downsample");
  PIPE.detect = harness.load_compute(dog_wgsl, "detect");
  PIPE.args_prep = harness.load_compute(args_wgsl, "prep");
  PIPE.refine = harness.load_compute(refine_wgsl, "refine");
  PIPE.bin_count = harness.load_compute(suppress_wgsl, "bin_count");
  PIPE.bin_scatter = harness.load_compute(suppress_wgsl, "bin_scatter");
  PIPE.suppress = harness.load_compute(suppress_wgsl, "suppress");
  PIPE.affine = harness.load_compute(affine_wgsl, "affine_shape");
  PIPE.orient = harness.load_compute(orient_wgsl, "orient");
  PIPE.fused = harness.load_compute(fused_wgsl, "descriptor_fused");
  const double compile_ms = ms_since(tc);
  std::printf("[compile] all 11 pipelines Tint-compiled ONCE: %.1f ms (hoisted out of per-frame loop)\n", compile_ms);

  std::vector<FullGpuResult> results;

  for (const std::string& imgpath : imgs) {
    const char* img = imgpath.c_str();
    FullGpuResult RES{};
    int iw = 0, ih = 0, ic = 0;
    unsigned char* pixels = stbi_load(img, &iw, &ih, &ic, 1);
    if (!pixels) { std::fprintf(stderr, "FAIL stbi_load(%s): %s\n", img, stbi_failure_reason()); return 2; }
    std::vector<float> gray255((size_t)iw * ih);
    for (size_t i = 0; i < gray255.size(); ++i) gray255[i] = (float)pixels[i];
    stbi_image_free(pixels);
    std::printf("\n----- image: %s  %dx%d -----\n", img, iw, ih);

    // CPU baseline + reference (detect+affine+orient+sort+DSP-desc).
    VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cd, 0);
    vl_covdet_set_octave_resolution(cd, octave_resolution);
    vl_covdet_set_peak_threshold(cd, peak_threshold);
    vl_covdet_set_edge_threshold(cd, edge_threshold);
    auto tcpu = clock_t_::now();
    vl_covdet_put_image(cd, gray255.data(), iw, ih);
    vl_covdet_detect(cd, max_num_features);
    vl_covdet_extract_affine_shape(cd);
    vl_covdet_extract_orientations(cd);
    int cpu_nf = vl_covdet_get_num_features(cd);
    VlCovDetFeature* cpu_feats = vl_covdet_get_features(cd);
    std::sort(cpu_feats, cpu_feats + cpu_nf, [](const VlCovDetFeature& a, const VlCovDetFeature& b) {
      if (a.o == b.o) return a.s > b.s; return a.o > b.o; });
    if (cpu_nf > max_num_features) cpu_nf = max_num_features;
    std::vector<uint8_t> cpu_desc((size_t)cpu_nf * 128);
    {
      VlScaleSpace* gssb = vl_covdet_get_gss(cd);
      std::unique_ptr<VlSiftFilt, void (*)(VlSiftFilt*)> sift(vl_sift_new(16, 16, 1, 3, 0), &vl_sift_delete);
      vl_sift_set_magnif(sift.get(), kMagnif);
      VlCovDet* wd = vl_covdet_new(VL_COVDET_METHOD_DOG);
      vl_covdet_set_gss(wd, gssb);
      std::vector<float> patch((size_t)kPatchSide * kPatchSide);
      std::vector<float> patchXY(2 * (size_t)kPatchSide * kPatchSide);
      const double dsp_step = (kDspMaxScale - kDspMinScale) / kDspNumScales;
      for (int i = 0; i < cpu_nf; ++i) {
        std::vector<float> sd((size_t)kDspNumScales * 128);
        for (int s = 0; s < kDspNumScales; ++s) {
          const double dsc = kDspMinScale + s * dsp_step;
          VlFrameOrientedEllipse sf = cpu_feats[i].frame;
          sf.a11 *= dsc; sf.a12 *= dsc; sf.a21 *= dsc; sf.a22 *= dsc;
          vl_covdet_extract_patch_for_frame(wd, patch.data(), kPatchResolution,
              kPatchRelativeExtent, kPatchRelativeSmoothing, sf);
          vl_imgradient_polar_f(patchXY.data(), patchXY.data() + 1, 2, 2 * kPatchSide,
              patch.data(), kPatchSide, kPatchSide, kPatchSide);
          vl_sift_calc_raw_descriptor(sift.get(), patchXY.data(), sd.data() + (size_t)s * 128,
              kPatchSide, kPatchSide, kPatchResolution, kPatchResolution, kSigma, 0);
        }
        float descf[128];
        for (int b = 0; b < 128; ++b) {
          double acc = 0;
          for (int s = 0; s < kDspNumScales; ++s) acc += sd[(size_t)s * 128 + b];
          descf[b] = (float)(acc / kDspNumScales);
        }
        double l1 = 0; for (int b = 0; b < 128; ++b) l1 += std::fabs(descf[b]);
        const float inv = (float)(1.0 / l1);
        for (int b = 0; b < 128; ++b) descf[b] = std::sqrt(descf[b] * inv);
        uint8_t vo[128];
        for (int b = 0; b < 128; ++b) {
          const float sv = std::round(512.0f * descf[b]);
          const float c = sv < 0 ? 0 : (sv > 255 ? 255 : sv);
          vo[b] = (uint8_t)c;
        }
        ubc_reorder(vo, cpu_desc.data() + (size_t)i * 128);
      }
      vl_covdet_set_gss(wd, nullptr); vl_covdet_delete(wd);
    }
    RES.cpu_baseline_ms = ms_since(tcpu);
    RES.cpu_nf = cpu_nf;
    RES.cpu_fx.resize(cpu_nf); RES.cpu_fy.resize(cpu_nf); RES.cpu_fo.resize(cpu_nf);
    for (int i = 0; i < cpu_nf; ++i) {
      RES.cpu_fx[i] = cpu_feats[i].frame.x; RES.cpu_fy[i] = cpu_feats[i].frame.y;
      RES.cpu_fo[i] = cpu_feats[i].o;
    }
    RES.cpu_desc = std::move(cpu_desc);
    std::printf("[CPU baseline] %.1f ms  (kp=%d)\n", RES.cpu_baseline_ms, cpu_nf);

    VlScaleSpace* gss = vl_covdet_get_gss(cd);
    VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
    Geom G{(int)g.firstOctave, (int)g.lastOctave, (int)g.octaveFirstSubdivision,
           (int)g.octaveLastSubdivision, (int)g.octaveResolution, g.baseScale};

    // ── WARM-UP frame (primes Tint->Metal pipeline cache; not timed). ──
    GpuTimings warm{};
    run_frame(harness, PIPE, gss, G, peak_threshold, edge_threshold, max_num_features, tol, &warm, &RES);

    // ── timed reps: MIN-of-N wall + min per-stage. ──
    GpuTimings best = RES.t; double best_total = warm.total_ms;
    best = warm;
    for (int rep = 0; rep < reps; ++rep) {
      GpuTimings T{};
      double total = run_frame(harness, PIPE, gss, G, peak_threshold, edge_threshold,
                               max_num_features, tol, &T, nullptr);
      if (total < best_total) { best_total = total; best = T; }
    }
    RES.t = best;
    std::printf("[BATCHED min-of-%d] total=%.1f ms  | gss=%.1f detect+refine=%.1f suppress=%.1f affine=%.1f orient=%.1f desc=%.1f host-restruct=%.1f\n",
                reps, best.total_ms, best.gss_ms, best.detect_refine_ms, best.suppress_ms,
                best.affine_ms, best.orient_ms, best.desc_ms, best.host_restruct_ms);

    // ── e2e parity (recall/precision + cosine + match-recall). ──
    {
      const double pos_tol = 2.0;
      std::vector<char> gpu_used(RES.final_kp, 0);
      size_t matched_cpu = 0;
      for (int i = 0; i < RES.cpu_nf; ++i) {
        double bestd = 1e18; long bj = -1;
        for (size_t j = 0; j < RES.final_kp; ++j) {
          if (gpu_used[j]) continue;
          if (RES.frame_octave[j] != RES.cpu_fo[i]) continue;
          const double dx = RES.frame_x[j] - RES.cpu_fx[i];
          const double dy = RES.frame_y[j] - RES.cpu_fy[i];
          const double d2 = dx * dx + dy * dy;
          if (d2 < bestd) { bestd = d2; bj = (long)j; }
        }
        if (bj >= 0 && bestd <= pos_tol * pos_tol) { ++matched_cpu; gpu_used[bj] = 1; }
      }
      size_t matched_gpu = 0;
      for (size_t j = 0; j < RES.final_kp; ++j) if (gpu_used[j]) ++matched_gpu;
      const double recall = RES.cpu_nf ? (double)matched_cpu / RES.cpu_nf : 1.0;
      const double precision = RES.final_kp ? (double)matched_gpu / RES.final_kp : 1.0;
      std::printf("[C.1 e2e keypoints] CPU=%d GPU=%zu matched=%zu recall=%.4f precision=%.4f (pos_tol=%.1fpx)\n",
                  RES.cpu_nf, RES.final_kp, matched_cpu, recall, precision, pos_tol);

      std::vector<std::pair<int,int>> pairs;
      std::fill(gpu_used.begin(), gpu_used.end(), 0);
      for (int i = 0; i < RES.cpu_nf; ++i) {
        double bestd = 1e18; long bj = -1;
        for (size_t j = 0; j < RES.final_kp; ++j) {
          if (gpu_used[j]) continue;
          if (RES.frame_octave[j] != RES.cpu_fo[i]) continue;
          const double dx = RES.frame_x[j] - RES.cpu_fx[i];
          const double dy = RES.frame_y[j] - RES.cpu_fy[i];
          const double d2 = dx * dx + dy * dy;
          if (d2 < bestd) { bestd = d2; bj = (long)j; }
        }
        if (bj >= 0 && bestd <= pos_tol * pos_tol) { pairs.emplace_back(i, (int)bj); gpu_used[bj] = 1; }
      }
      std::vector<double> cosv; cosv.reserve(pairs.size());
      for (auto& pr : pairs)
        cosv.push_back(cosine_u8(RES.cpu_desc.data() + (size_t)pr.first * 128,
                                 RES.descriptors.data() + (size_t)pr.second * 128));
      double cmed = 0, cp95 = 0;
      if (!cosv.empty()) { std::sort(cosv.begin(), cosv.end());
        cmed = cosv[cosv.size() / 2]; cp95 = cosv[(size_t)(0.05 * (cosv.size() - 1))]; }
      std::printf("[C.2 e2e descriptors] matched=%zu cosine median=%.6f p95(5th)=%.6f\n", cosv.size(), cmed, cp95);

      int self_nn = 0;
      for (auto& pr : pairs) {
        const uint8_t* gd = RES.descriptors.data() + (size_t)pr.second * 128;
        double bd = 1e30; int bi = -1;
        for (auto& pr2 : pairs) {
          const double d = l2sq_u8(gd, RES.cpu_desc.data() + (size_t)pr2.first * 128);
          if (d < bd) { bd = d; bi = pr2.first; }
        }
        if (bi == pr.first) ++self_nn;
      }
      const double mrec = pairs.empty() ? 0.0 : (double)self_nn / pairs.size();
      std::printf("[C.3 e2e match-recall] NN==self: %.4f (%d/%zu)\n", mrec, self_nn, pairs.size());
    }

    vl_covdet_delete(cd);
    results.push_back(std::move(RES));
  }

  // ── VERDICT ──
  const double kIphoneScale = 2.9;
  std::printf("\n=================================================================\n");
  std::printf(" TIMING VERDICT  (M3 Pro, warm, MIN-of-%d, pipelines pre-compiled)\n", reps);
  std::printf("=================================================================\n");
  double cpu_sum = 0, gpu_sum = 0;
  double s_gss = 0, s_dr = 0, s_sup = 0, s_aff = 0, s_or = 0, s_desc = 0, s_hr = 0;
  double s_peak = 0, s_descpeak = 0, s_gssbytes = 0;
  for (const auto& R : results) {
    cpu_sum += R.cpu_baseline_ms; gpu_sum += R.t.total_ms;
    s_gss += R.t.gss_ms; s_dr += R.t.detect_refine_ms; s_sup += R.t.suppress_ms;
    s_aff += R.t.affine_ms; s_or += R.t.orient_ms; s_desc += R.t.desc_ms; s_hr += R.t.host_restruct_ms;
    s_peak = std::max(s_peak, R.t.peak_bytes);
    s_descpeak = std::max(s_descpeak, R.t.desc_peak_bytes);
    s_gssbytes = std::max(s_gssbytes, R.t.gss_bytes);
    std::printf("  (per image) CPU=%.0f ms  GPU=%.0f ms  speedup=%.2fx\n",
                R.cpu_baseline_ms, R.t.total_ms, R.t.total_ms > 0 ? R.cpu_baseline_ms / R.t.total_ms : 0.0);
  }
  const size_t n = results.size();
  std::printf("\n  --- per-stage GPU breakdown (sum over %zu images) ---\n", n);
  std::printf("    gss RESIDENT (1 cmd buf): %8.1f ms\n", s_gss);
  std::printf("    detect+refine (1 buf,IND): %8.1f ms\n", s_dr);
  std::printf("    suppression (host scan)  : %8.1f ms\n", s_sup);
  std::printf("    affine-shape             : %8.1f ms\n", s_aff);
  std::printf("    orientation (1-4x)       : %8.1f ms\n", s_or);
  std::printf("    descriptor FUSED         : %8.1f ms\n", s_desc);
  std::printf("    host restructuring       : %8.1f ms   (affine->orient filter + rotate + sort+clamp)\n", s_hr);
  std::printf("\n  CPU baseline sum          : %8.1f ms\n", cpu_sum);
  std::printf("  BATCHED pipeline sum      : %8.1f ms\n", gpu_sum);
  std::printf("  CUMULATIVE SPEEDUP        : %.2fx\n", gpu_sum > 0 ? cpu_sum / gpu_sum : 0.0);
  std::printf("  BATCHED / frame           : %8.1f ms   (vs fused 1657 ms/frame)\n", gpu_sum / n);
  const double removed = 1657.0 - gpu_sum / n;
  const double overhead_pct = (removed / (1657.0 - 377.0)) * 100.0;
  std::printf("  vs 1657 ms baseline       : %.1f ms removed/frame = %.1f%% of the ~1280 ms overhead\n",
              removed, overhead_pct);

  std::printf("\n  --- PEAK GPU MEMORY ---\n");
  std::printf("    resident gss            : %8.1f MB\n", s_gssbytes / 1e6);
  std::printf("    descriptor-stage peak   : %8.1f MB\n", s_descpeak / 1e6);
  std::printf("    PEAK GPU TOTAL          : %8.1f MB  (%.3f GB)\n", s_peak / 1e6, s_peak / 1e9);

  std::printf("\n  --- iPhone scaling (x%.1f M3-Pro->A16, PLAN) ---\n", kIphoneScale);
  const double iphone = (gpu_sum / n) * kIphoneScale;
  std::printf("    A16 (iPhone 14 Pro): %8.1f ms/frame  vs 2000 ms budget => %s\n",
              iphone, iphone <= 2000.0 ? "WITHIN BUDGET" : "OVER BUDGET");
  std::printf("    A17 Pro (~1.2x A16): %8.1f ms/frame  => %s\n", iphone / 1.20, (iphone / 1.20) <= 2000.0 ? "WITHIN" : "OVER");
  std::printf("    A18 Pro (~1.4x A16): %8.1f ms/frame  => %s\n", iphone / 1.40, (iphone / 1.40) <= 2000.0 ? "WITHIN" : "OVER");
  std::printf("=================================================================\n");
  return 0;
}
