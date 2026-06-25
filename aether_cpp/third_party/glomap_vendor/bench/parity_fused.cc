// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// parity_fused.cc — GPU DSP-SIFT FUSED warp+descriptor parity gate.
//
// Validates shaders/wgsl/sift_descriptor_fused.wgsl (one kernel that warps the
// patch from the RESIDENT gss AND computes the descriptor, with NO intermediate
// 3.4 GB plane buffer) against the UNFUSED two-kernel chain
// (sift_descriptor_warp.wgsl warp_size+warp_fill -> sift_dsp_descriptor.wgsl).
//
//   PATH UNFUSED (the current production-validated bridge, = parity_warp.cc
//     PATH B): warp_size -> host prefix-sum -> warp_fill (writes ~3.4 GB
//     out_planes + emits PatchRecs) -> descriptor (reads out_planes back).
//
//   PATH FUSED (under test): descriptor_fused — for each (kp x scale) compute
//     the warp geometry in-register, sample the resident gss directly (edge
//     replication folded in), accumulate the descriptor. NO out_planes.
//
// Both paths receive the SAME oriented+affine keypoints (the CPU covdet path,
// identical to parity_warp.cc) and the SAME resident gss + the SAME WarpIn
// frames. We REPORT:
//   1. descriptor cosine FUSED-vs-UNFUSED (median / p95 / p99 / min) — must
//      be ~1.0 (ideally bit-identical) since the math is the same op stream.
//      Also: count of bit-identical descriptors (all 128 bytes equal).
//   2. peak GPU buffer memory before (unfused: out_planes total_floats) vs
//      after (fused: none) — must drop a lot.
//   3. kernel time before (warp_fill + descriptor) vs after (descriptor_fused)
//      — fused should be faster (no 3.4 GB write+read round-trip).
//
// keypoint count is UNCHANGED (both paths use the full CPU keypoint set; the
// fused kernel emits exactly N descriptors, one per keypoint).
//
// Build: build_fused.sh (worktree-only; unique obj dir /tmp/parity_fused_obj).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
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

// ── Production CPU-path constants (identical to parity_warp.cc). ──
constexpr int    kPatchResolution = 15;
constexpr int    kPatchSide = 2 * kPatchResolution + 1;  // 31
constexpr double kPatchRelativeExtent = 7.5;
constexpr double kPatchRelativeSmoothing = 1.0;
constexpr double kPatchStep = kPatchRelativeExtent / kPatchResolution;
constexpr double kSigma =
    kPatchRelativeExtent / (3.0 * (4 + 1) / 2) / kPatchStep;
constexpr double kMagnif = 3.0;
constexpr int    kFirstOctave = 0;
constexpr int    kOctaveResolution = 3;
constexpr double kEdgeThreshold = 10.0;
constexpr int    kMaxNumFeatures = 8192;
constexpr double kDspMinScale = 1.0 / 6.0;
constexpr double kDspMaxScale = 3.0;
constexpr int    kDspNumScales = 10;
constexpr double kPeakThreshold = 0.02 / 3.0;

std::vector<float> build_expn_lut() {
  const int EXPN_SZ = 256;
  const double EXPN_MAX = 25.0;
  std::vector<float> tab(EXPN_SZ + 1);
  for (int k = 0; k < EXPN_SZ + 1; ++k)
    tab[k] = static_cast<float>(std::exp(-static_cast<double>(k) *
                                         (EXPN_MAX / EXPN_SZ)));
  return tab;
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

#pragma pack(push, 4)
// sift_dsp_descriptor.wgsl PatchRec (48B).
struct PatchRec {
  float a0, a1, a2, a3;
  float tx, ty;
  float extent;
  float stephat;
  uint32_t level_off;
  uint32_t lw, lh;
  uint32_t pad0;
};
struct DescParams {
  uint32_t num_kp;
  uint32_t dsp_num_scales;
  uint32_t patch_sigma;
  uint32_t pad0;
  float k_sigma;
  float pad1, pad2, pad3;
};
// sift_descriptor_warp.wgsl OctGeomW (32B).
struct OctGeomW {
  uint32_t w, h, base, pad;
  float step, pad1, pad2, pad3;
};
// sift_descriptor_warp.wgsl WarpIn (32B).
struct WarpIn {
  float x, y, a11, a12, a21, a22, pad0, pad1;
};
// sift_descriptor_warp.wgsl WarpGeom (64B).
struct WarpGeom {
  float a0, a1, a2, a3;
  float tx, ty;
  int32_t x0i, y0i;
  uint32_t level_base, lw, lh, oct_idx;
  uint32_t src_w, src_h, status, pad1;
};
// sift_descriptor_warp.wgsl Params (48B).
struct WarpParams {
  uint32_t num_recs, num_octaves;
  int32_t first_octave, last_octave, first_sub, last_sub;
  float octave_res, base_scale, extent, stephat, sigma, pad0;
};
// sift_descriptor_fused.wgsl Params (48B): num_kp, dsp_num_scales, then the
// warp geometry params + k_sigma. 12 x 4-byte scalars.
struct FusedParams {
  uint32_t num_kp;
  uint32_t dsp_num_scales;
  int32_t first_octave, last_octave, first_sub, last_sub;
  float octave_res, base_scale, extent, stephat, sigma, k_sigma;
};
#pragma pack(pop)
static_assert(sizeof(PatchRec) == 48, "PatchRec 48B");
static_assert(sizeof(DescParams) == 32, "DescParams 32B");
static_assert(sizeof(OctGeomW) == 32, "OctGeomW 32B");
static_assert(sizeof(WarpIn) == 32, "WarpIn 32B");
static_assert(sizeof(WarpGeom) == 64, "WarpGeom 64B");
static_assert(sizeof(WarpParams) == 48, "WarpParams 48B");
static_assert(sizeof(FusedParams) == 48, "FusedParams 48B");

double cosine_u8(const uint8_t* a, const uint8_t* b) {
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < 128; ++i) {
    const double x = a[i], y = b[i]; dot += x * y; na += x * x; nb += y * y;
  }
  if (na == 0.0 || nb == 0.0) return (na == 0.0 && nb == 0.0) ? 1.0 : 0.0;
  return dot / (std::sqrt(na) * std::sqrt(nb));
}

}  // namespace

int main(int argc, char** argv) {
  const char* img_path = argc > 1
      ? argv[1]
      : "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* desc_wgsl_path =
      argc > 2 ? argv[2] : "shaders/wgsl/sift_dsp_descriptor.wgsl";
  const char* warp_wgsl_path =
      argc > 3 ? argv[3] : "shaders/wgsl/sift_descriptor_warp.wgsl";
  const char* fused_wgsl_path =
      argc > 4 ? argv[4] : "shaders/wgsl/sift_descriptor_fused.wgsl";
  const int kp_cap = argc > 5 ? std::atoi(argv[5]) : 0;

  // ── 1. Load grayscale fp32. ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s): %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d\n", img_path, iw, ih);
  std::vector<float> gray(static_cast<size_t>(iw) * ih);
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]) / 255.0f;
  stbi_image_free(pixels);

  // ── 2. CPU detector path (identical to parity_warp.cc). ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(covdet, kFirstOctave);
  vl_covdet_set_octave_resolution(covdet, kOctaveResolution);
  vl_covdet_set_peak_threshold(covdet, kPeakThreshold);
  vl_covdet_set_edge_threshold(covdet, kEdgeThreshold);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  vl_covdet_detect(covdet, kMaxNumFeatures);
  vl_covdet_extract_affine_shape(covdet);
  vl_covdet_extract_orientations(covdet);
  int N = vl_covdet_get_num_features(covdet);
  VlCovDetFeature* features = vl_covdet_get_features(covdet);
  std::sort(features, features + N,
            [](const VlCovDetFeature& a, const VlCovDetFeature& b) {
              if (a.o == b.o) return a.s > b.s;
              return a.o > b.o;
            });
  if (kp_cap > 0 && N > kp_cap) N = kp_cap;
  std::printf("CPU oriented+affine keypoints: %d  (dsp_num_scales=%d)\n", N,
              kDspNumScales);
  if (N == 0) { std::fprintf(stderr, "FAIL: 0 keypoints\n"); return 2; }

  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const double dsp_scale_step = (kDspMaxScale - kDspMinScale) / kDspNumScales;

  // ── 3. Build the resident gss (one flat buffer) + OctGeomW table. ──
  const int firstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int lastSub = static_cast<int>(g.octaveLastSubdivision);
  const int nLevels = lastSub - firstSub + 1;
  const int firstO = static_cast<int>(g.firstOctave);
  const int lastO = static_cast<int>(g.lastOctave);
  const int nOct = lastO - firstO + 1;
  std::vector<OctGeomW> octs(nOct);
  std::vector<float> pyramid;
  {
    uint32_t off = 0u;
    for (int o = firstO; o <= lastO; ++o) {
      VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
      const int W = (int)og.width, H = (int)og.height;
      OctGeomW& gg = octs[o - firstO];
      gg.w = (uint32_t)W; gg.h = (uint32_t)H; gg.base = off;
      gg.pad = 0u; gg.step = (float)og.step;
      gg.pad1 = gg.pad2 = gg.pad3 = 0.0f;
      off += (uint32_t)W * (uint32_t)H * (uint32_t)nLevels;
    }
    pyramid.resize(off);
    for (int o = firstO; o <= lastO; ++o) {
      VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
      const int W = (int)og.width, H = (int)og.height;
      const size_t plane = (size_t)W * H;
      const uint32_t base = octs[o - firstO].base;
      for (int lvl0 = 0; lvl0 < nLevels; ++lvl0) {
        const int s = firstSub + lvl0;
        const float* lv = vl_scalespace_get_level_const(gss, o, s);
        std::memcpy(pyramid.data() + base + (size_t)lvl0 * plane, lv,
                    plane * sizeof(float));
      }
    }
  }
  const double resident_mb = pyramid.size() * sizeof(float) / 1e6;
  std::printf("resident gss: %d oct, %d lvl/oct, %zu floats (%.1f MB)\n", nOct,
              nLevels, pyramid.size(), resident_mb);

  // ── 4. WarpIn frames (a11..a22 pre-scaled by dsp; same as parity_warp.cc). ──
  const int M = N * kDspNumScales;
  std::vector<WarpIn> w_in(M);
  for (int i = 0; i < N; ++i) {
    for (int s = 0; s < kDspNumScales; ++s) {
      const double dsp = kDspMinScale + s * dsp_scale_step;
      VlFrameOrientedEllipse sf = features[i].frame;
      WarpIn& wi = w_in[(size_t)i * kDspNumScales + s];
      wi.x = sf.x; wi.y = sf.y;
      wi.a11 = (float)(sf.a11 * dsp); wi.a12 = (float)(sf.a12 * dsp);
      wi.a21 = (float)(sf.a21 * dsp); wi.a22 = (float)(sf.a22 * dsp);
      wi.pad0 = wi.pad1 = 0.0f;
    }
  }

  // ── Dawn init. ──
  aether::tools::DawnKernelHarness h;
  if (!h.init()) { std::fprintf(stderr, "FAIL: Dawn init\n"); return 2; }
  std::string warp_wgsl = read_file(warp_wgsl_path);
  std::string desc_wgsl = read_file(desc_wgsl_path);
  std::string fused_wgsl = read_file(fused_wgsl_path);
  if (warp_wgsl.empty() || desc_wgsl.empty() || fused_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: read WGSL\n"); return 2;
  }
  std::vector<float> lut = build_expn_lut();

  // Shared GPU buffers (resident gss, octs, WarpIn, LUT).
  wgpu::Buffer gss_buf = h.upload(pyramid.data(), pyramid.size() * sizeof(float),
                                  wgpu::BufferUsage::Storage);
  wgpu::Buffer octs_buf = h.upload(octs.data(), octs.size() * sizeof(OctGeomW),
                                   wgpu::BufferUsage::Storage);
  wgpu::Buffer win_buf = h.upload(w_in.data(), w_in.size() * sizeof(WarpIn),
                                  wgpu::BufferUsage::Storage);
  wgpu::Buffer lut_buf = h.upload(lut.data(), lut.size() * sizeof(float),
                                  wgpu::BufferUsage::Storage);

  // ═══════════════════════════════════════════════════════════════════════════
  //  PATH UNFUSED: warp_size -> prefix-sum -> warp_fill (3.4 GB plane) ->
  //  descriptor. (= parity_warp.cc PATH B, the production-validated bridge.)
  // ═══════════════════════════════════════════════════════════════════════════
  WarpParams WP{};
  WP.num_recs = (uint32_t)M;
  WP.num_octaves = (uint32_t)nOct;
  WP.first_octave = firstO; WP.last_octave = lastO;
  WP.first_sub = firstSub; WP.last_sub = lastSub;
  WP.octave_res = (float)g.octaveResolution;
  WP.base_scale = (float)g.baseScale;
  WP.extent = (float)kPatchRelativeExtent;
  WP.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
  WP.sigma = (float)kPatchRelativeSmoothing;

  // warp_size.
  auto pipe_size = h.load_compute(warp_wgsl, "warp_size");
  wgpu::Buffer geom_buf = h.alloc((size_t)M * sizeof(WarpGeom),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  wgpu::Buffer pf_buf = h.alloc((size_t)M * sizeof(uint32_t),
                                wgpu::BufferUsage::Storage |
                                    wgpu::BufferUsage::CopySrc);
  wgpu::Buffer wp_buf = h.upload(&WP, sizeof(WP), wgpu::BufferUsage::Uniform);
  const uint32_t gx = ((uint32_t)M + 63u) / 64u;
  h.dispatch(pipe_size, {win_buf, octs_buf, geom_buf, pf_buf, wp_buf}, gx, 1u, 1u);

  std::vector<WarpGeom> geom(M);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback((size_t)M * sizeof(WarpGeom));
    h.copy_to_staging(geom_buf, st, (size_t)M * sizeof(WarpGeom));
    std::vector<uint8_t> raw = h.readback(st, (size_t)M * sizeof(WarpGeom));
    std::memcpy(geom.data(), raw.data(), (size_t)M * sizeof(WarpGeom));
  }
  std::vector<uint32_t> plane_floats(M);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback((size_t)M * sizeof(uint32_t));
    h.copy_to_staging(pf_buf, st, (size_t)M * sizeof(uint32_t));
    std::vector<uint8_t> raw = h.readback(st, (size_t)M * sizeof(uint32_t));
    std::memcpy(plane_floats.data(), raw.data(), (size_t)M * sizeof(uint32_t));
  }

  // host prefix-sum.
  std::vector<uint32_t> rec_offset(M);
  uint64_t total_floats = 0;
  for (int i = 0; i < M; ++i) {
    rec_offset[i] = (uint32_t)total_floats;
    total_floats += plane_floats[i];
  }
  const double out_planes_mb = (double)total_floats * sizeof(float) / 1e6;
  std::printf("UNFUSED out_planes: %llu floats (%.1f MB) <-- intermediate buffer\n",
              (unsigned long long)total_floats, out_planes_mb);

  const int kReps = 3;
  const uint64_t kDawnMaxBuffer = 2147483648ull;  // 2 GB Dawn default cap
  const uint64_t out_planes_bytes = total_floats * sizeof(float);
  const bool unfused_buildable = out_planes_bytes <= kDawnMaxBuffer;
  std::vector<uint8_t> desc_unfused;
  double t_fill_ms = 0.0, t_desc_ms = 0.0;
  const size_t out_words = static_cast<size_t>(N) * 32;
  const size_t dbg_n = static_cast<size_t>(N) * 128;

  if (!unfused_buildable) {
    std::printf(
        "\n*** UNFUSED PATH UNBUILDABLE: out_planes %.1f MB > Dawn 2048 MB buffer\n"
        "    limit. This is THE bottleneck the fusion removes — the unfused\n"
        "    descriptor cannot run on the full keypoint set without host-side\n"
        "    batching. Running the FUSED path ALONE (it needs no plane buffer)\n"
        "    and reporting it produces all %d descriptors. Re-run with a\n"
        "    kp_cap <= ~12000 to get a numeric cosine comparison vs unfused.\n",
        out_planes_mb, N);
  }

  if (unfused_buildable) {
  // warp_fill (fill planes + emit PatchRecs). TIMED.
  auto pipe_fill = h.load_compute(warp_wgsl, "warp_fill");
  wgpu::Buffer geomIn_buf = h.upload(geom.data(), geom.size() * sizeof(WarpGeom),
                                     wgpu::BufferUsage::Storage);
  wgpu::Buffer roff_buf = h.upload(rec_offset.data(),
                                   rec_offset.size() * sizeof(uint32_t),
                                   wgpu::BufferUsage::Storage);
  wgpu::Buffer planes_buf = h.alloc(
      (size_t)total_floats * sizeof(float),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  wgpu::Buffer recsB_buf = h.alloc((size_t)M * sizeof(PatchRec),
                                   wgpu::BufferUsage::Storage |
                                       wgpu::BufferUsage::CopySrc);
  wgpu::Buffer wp2_buf = h.upload(&WP, sizeof(WP), wgpu::BufferUsage::Uniform);
  const uint32_t kWarpFillGrid = 32768u;
  const uint32_t fill_wg = std::min((uint32_t)M, kWarpFillGrid);

  t_fill_ms = 1e30;
  for (int rep = 0; rep < kReps; ++rep) {
    auto t0 = std::chrono::high_resolution_clock::now();
    h.dispatch(pipe_fill,
               {gss_buf, geomIn_buf, roff_buf, planes_buf, recsB_buf, wp2_buf},
               fill_wg, 1u, 1u);
    auto t1 = std::chrono::high_resolution_clock::now();
    t_fill_ms = std::min(t_fill_ms,
        std::chrono::duration<double, std::milli>(t1 - t0).count());
  }

  std::vector<PatchRec> recs_B(M);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback((size_t)M * sizeof(PatchRec));
    h.copy_to_staging(recsB_buf, st, (size_t)M * sizeof(PatchRec));
    std::vector<uint8_t> raw = h.readback(st, (size_t)M * sizeof(PatchRec));
    std::memcpy(recs_B.data(), raw.data(), (size_t)M * sizeof(PatchRec));
  }

  // descriptor (reads out_planes back). TIMED.
  auto pipe_desc = h.load_compute(desc_wgsl, "descriptor");
  wgpu::Buffer recs_buf = h.upload(recs_B.data(), recs_B.size() * sizeof(PatchRec),
                                   wgpu::BufferUsage::Storage);
  wgpu::Buffer outU_buf = h.alloc(out_words * sizeof(uint32_t),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  wgpu::Buffer dbgU_buf = h.alloc(dbg_n * sizeof(float),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  DescParams dp{};
  dp.num_kp = (uint32_t)N;
  dp.dsp_num_scales = (uint32_t)kDspNumScales;
  dp.k_sigma = (float)kSigma;
  wgpu::Buffer dp_buf = h.upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
  const uint32_t desc_wg = ((uint32_t)N + 63u) / 64u;
  // The unfused descriptor reads the MATERIALIZED planes (planes_buf) via
  // PatchRec.level_off — binding 0 is the plane buffer, NOT the resident pyramid.
  t_desc_ms = 1e30;
  for (int rep = 0; rep < kReps; ++rep) {
    auto t0 = std::chrono::high_resolution_clock::now();
    h.dispatch(pipe_desc,
               {planes_buf, recs_buf, lut_buf, outU_buf, dp_buf, dbgU_buf},
               desc_wg, 1u, 1u);
    auto t1 = std::chrono::high_resolution_clock::now();
    t_desc_ms = std::min(t_desc_ms,
        std::chrono::duration<double, std::milli>(t1 - t0).count());
  }

  desc_unfused.assign((size_t)N * 128, 0);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback(out_words * sizeof(uint32_t));
    h.copy_to_staging(outU_buf, st, out_words * sizeof(uint32_t));
    std::vector<uint8_t> raw = h.readback(st, out_words * sizeof(uint32_t));
    std::memcpy(desc_unfused.data(), raw.data(), desc_unfused.size());
  }
  }  // end if (unfused_buildable)

  // ═══════════════════════════════════════════════════════════════════════════
  //  PATH FUSED: descriptor_fused — warp from resident gss + descriptor in one
  //  pass, NO out_planes. TIMED.
  // ═══════════════════════════════════════════════════════════════════════════
  const uint32_t desc_wg = ((uint32_t)N + 63u) / 64u;
  FusedParams FP{};
  FP.num_kp = (uint32_t)N;
  FP.dsp_num_scales = (uint32_t)kDspNumScales;
  FP.first_octave = firstO; FP.last_octave = lastO;
  FP.first_sub = firstSub; FP.last_sub = lastSub;
  FP.octave_res = (float)g.octaveResolution;
  FP.base_scale = (float)g.baseScale;
  FP.extent = (float)kPatchRelativeExtent;
  FP.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
  FP.sigma = (float)kPatchRelativeSmoothing;
  FP.k_sigma = (float)kSigma;

  auto pipe_fused = h.load_compute(fused_wgsl, "descriptor_fused");
  wgpu::Buffer outF_buf = h.alloc(out_words * sizeof(uint32_t),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  wgpu::Buffer dbgF_buf = h.alloc(dbg_n * sizeof(float),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  wgpu::Buffer fp_buf = h.upload(&FP, sizeof(FP), wgpu::BufferUsage::Uniform);
  double t_fused_ms = 1e30;
  for (int rep = 0; rep < kReps; ++rep) {
    auto t0 = std::chrono::high_resolution_clock::now();
    h.dispatch(pipe_fused,
               {gss_buf, win_buf, octs_buf, lut_buf, outF_buf, fp_buf, dbgF_buf},
               desc_wg, 1u, 1u);
    auto t1 = std::chrono::high_resolution_clock::now();
    t_fused_ms = std::min(t_fused_ms,
        std::chrono::duration<double, std::milli>(t1 - t0).count());
  }

  std::vector<uint8_t> desc_fused((size_t)N * 128);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback(out_words * sizeof(uint32_t));
    h.copy_to_staging(outF_buf, st, out_words * sizeof(uint32_t));
    std::vector<uint8_t> raw = h.readback(st, out_words * sizeof(uint32_t));
    std::memcpy(desc_fused.data(), raw.data(), desc_fused.size());
  }

  // ── Sanity: the fused kernel emitted a non-empty descriptor for every kp
  //    (keypoint count unchanged — no point reduction). ──
  int fused_nonzero = 0;
  for (int i = 0; i < N; ++i) {
    const uint8_t* b = desc_fused.data() + (size_t)i * 128;
    for (int k = 0; k < 128; ++k) { if (b[k] != 0) { ++fused_nonzero; break; } }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  COMPARE (only when the unfused path was buildable, i.e. out_planes <= 2 GB).
  // ═══════════════════════════════════════════════════════════════════════════
  bool cos_ok = true;
  if (unfused_buildable) {
    std::vector<double> cos(N);
    int bit_identical = 0;
    int max_byte_diff = 0;
    for (int i = 0; i < N; ++i) {
      const uint8_t* a = desc_unfused.data() + (size_t)i * 128;
      const uint8_t* b = desc_fused.data() + (size_t)i * 128;
      cos[i] = cosine_u8(a, b);
      bool same = true;
      for (int k = 0; k < 128; ++k) {
        int d = std::abs((int)a[k] - (int)b[k]);
        if (d != 0) same = false;
        max_byte_diff = std::max(max_byte_diff, d);
      }
      if (same) ++bit_identical;
    }
    std::vector<double> sorted = cos;
    std::sort(sorted.begin(), sorted.end());
    auto pct = [&](double p) {
      if (sorted.empty()) return 1.0;
      double idx = p * (sorted.size() - 1);
      size_t lo = (size_t)std::floor(idx), hi = (size_t)std::ceil(idx);
      double frac = idx - lo;
      return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
    };
    const double median = pct(0.5);
    const double p95 = pct(0.05);
    const double p01 = pct(0.01);
    const double cmin = sorted.front();
    double mean = 0; for (double c : cos) mean += c; mean /= N;

    std::printf(
        "\n=== FUSED vs UNFUSED descriptor parity ===\n"
        "keypoints                : %d  (UNCHANGED — fused emits one desc/kp)\n"
        "fused non-zero descs     : %d / %d\n"
        "bit-identical descriptors: %d / %d (%.4f%%)\n"
        "max single-byte |Δ|      : %d\n"
        "per-desc cosine mean     : %.8f\n"
        "per-desc cosine MEDIAN   : %.8f   (must be ~1.0)\n"
        "per-desc cosine p95      : %.8f\n"
        "per-desc cosine p99      : %.8f\n"
        "per-desc cosine MIN      : %.8f\n",
        N, fused_nonzero, N, bit_identical, N, 100.0 * bit_identical / N,
        max_byte_diff, mean, median, p95, p01, cmin);

    cos_ok = (median >= 0.9999) && (p95 >= 0.999) && (cmin >= 0.99);
  } else {
    std::printf(
        "\n=== FUSED (alone — unfused unbuildable at this scale) ===\n"
        "keypoints                : %d  (UNCHANGED — fused emits one desc/kp)\n"
        "fused non-zero descs     : %d / %d  (fused ran where unfused cannot)\n"
        "cosine vs unfused        : N/A (unfused needs %.1f MB > 2 GB buffer cap)\n",
        N, fused_nonzero, N, out_planes_mb);
    cos_ok = (fused_nonzero == N);
  }

  std::printf(
      "\n=== MEMORY (intermediate plane buffer) ===\n"
      "UNFUSED out_planes buffer: %.1f MB  (write + read back; %s)\n"
      "FUSED   out_planes buffer: 0.0 MB   (eliminated; gss sampled in-register)\n"
      "resident gss (shared)    : %.1f MB  (present in BOTH paths)\n",
      out_planes_mb,
      unfused_buildable ? "fits under 2 GB at this kp_cap"
                        : "EXCEEDS 2 GB Dawn cap — forced host batching",
      resident_mb);

  if (unfused_buildable) {
    std::printf(
        "\n=== KERNEL TIME (best of %d, host Dawn — ratio is the portable signal) ===\n"
        "UNFUSED warp_fill        : %.2f ms\n"
        "UNFUSED descriptor       : %.2f ms\n"
        "UNFUSED warp_fill+desc   : %.2f ms\n"
        "FUSED   descriptor_fused : %.2f ms\n"
        "speedup (unfused/fused)  : %.2fx\n",
        kReps, t_fill_ms, t_desc_ms, t_fill_ms + t_desc_ms, t_fused_ms,
        (t_fill_ms + t_desc_ms) / t_fused_ms);
  } else {
    std::printf(
        "\n=== KERNEL TIME (best of %d, host Dawn) ===\n"
        "UNFUSED warp_fill+desc   : N/A (cannot allocate 3.4 GB plane buffer)\n"
        "FUSED   descriptor_fused : %.2f ms  (no round-trip, single pass)\n",
        kReps, t_fused_ms);
  }

  std::printf(
      "\nresult: %s%s\n",
      cos_ok ? "PASS" : "FAIL",
      unfused_buildable ? "" : "  (fused-alone: produced all N descriptors)");

  vl_covdet_delete(covdet);
  return cos_ok ? 0 : 1;
}
