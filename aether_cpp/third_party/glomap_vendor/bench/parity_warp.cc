// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// parity_warp.cc — GPU DSP-SIFT descriptor WARP-SETUP parity gate (Stage S5b).
//
// Validates shaders/wgsl/sift_descriptor_warp.wgsl (the on-GPU warp-setup that
// reads the RESIDENT gss directly) by feeding the SAME GPU oriented+affine
// keypoints to BOTH:
//
//   PATH A (host, the CURRENTLY VALIDATED descriptor bridge):
//     build_warp_setup (covdet.c:2222-2360, fp64, over the VLFeat gss) → per-rec
//     PatchRec + padded plane (concatenated) → sift_dsp_descriptor.wgsl → 128
//     uint8 descriptors A.  This is byte-for-byte the parity_descriptor.cc S3
//     path (cosine median 1.0 vs VLFeat).
//
//   PATH B (the kernel UNDER TEST):
//     Build the resident gss as ONE flat buffer + OctGeomW table; upload the
//     oriented+affine frames; run warp_size (geometry + level pick + plane dims)
//     → host prefix-sum the per-rec plane float counts → run warp_fill (fill the
//     planes from the resident gss + emit PatchRecs into out_planes) →
//     sift_dsp_descriptor.wgsl → 128 uint8 descriptors B.
//
// COMPARE: per-descriptor cosine A-vs-B (median / p95 / min). Gate (same as S3,
// now with the GPU warp-setup): median >= 0.998, p95 >= 0.99.
// ALSO report: (i) LEVEL-PICK agreement — GPU fp32 (octave,s) vs the fp64 host
// pick (count any octave/level flips near boundaries); (ii) the warped-PATCH
// max-abs diff — host padded plane resampled with the descriptor's build_patch
// math vs the GPU out_planes resampled the same way (i.e. compare the descriptor
// INPUT, not just the output).
//
// Build: build_warp.sh (worktree-only; unique obj dir /tmp/parity_warp_obj).

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
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

// ── Production CPU-path constants (aether_threaded_extract.cc / S3 harness) ──
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
#pragma pack(pop)
static_assert(sizeof(PatchRec) == 48, "PatchRec 48B");
static_assert(sizeof(DescParams) == 32, "DescParams 32B");
static_assert(sizeof(OctGeomW) == 32, "OctGeomW 32B");
static_assert(sizeof(WarpIn) == 32, "WarpIn 32B");
static_assert(sizeof(WarpGeom) == 64, "WarpGeom 64B");
static_assert(sizeof(WarpParams) == 48, "WarpParams 48B");

// ── Host replica of build_warp_setup (PATH A) — VERBATIM from
// parity_descriptor.cc:159-276 / extract_fullgpu.cc:232. fp64 over VLFeat gss.
struct WarpSetup {
  std::vector<float> plane;
  double A[4];
  double T[2];
  int lw, lh;
  int picked_o, picked_s;  // the fp64 level pick (for the agreement report)
};

bool build_warp_setup(VlScaleSpace* gss, double A_in[4], double T_in[2],
                      double d1, double d2, double extent, double sigma,
                      WarpSetup* out) {
  double A[4] = {A_in[0], A_in[1], A_in[2], A_in[3]};
  double T[2] = {T_in[0], T_in[1]};
  VlScaleSpaceGeometry geom = vl_scalespace_get_geometry(gss);
  VlScaleSpaceOctaveGeometry oct;
  const double factor = 1.0 / VL_MIN(d1, d2);
  vl_index o, s;
  double sigma_;
  for (o = geom.firstOctave + 1; o <= geom.lastOctave; ++o) {
    s = vl_floor_d(vl_log2_d(sigma / (factor * geom.baseScale)) - o);
    s = VL_MAX(s, geom.octaveFirstSubdivision);
    s = VL_MIN(s, geom.octaveLastSubdivision);
    sigma_ = geom.baseScale * pow(2.0, o + (double)s / geom.octaveResolution);
    if (factor * sigma_ > sigma) { o--; break; }
  }
  o = VL_MIN(o, geom.lastOctave);
  s = vl_floor_d(vl_log2_d(sigma / (factor * geom.baseScale)) - o);
  s = VL_MAX(s, geom.octaveFirstSubdivision);
  s = VL_MIN(s, geom.octaveLastSubdivision);
  out->picked_o = static_cast<int>(o);
  out->picked_s = static_cast<int>(s);
  const float* level = vl_scalespace_get_level(gss, o, s);
  oct = vl_scalespace_get_octave_geometry(gss, o);
  vl_size width = oct.width, height = oct.height;
  const double step = oct.step;
  A[0] /= step; A[1] /= step; A[2] /= step; A[3] /= step;
  T[0] /= step; T[1] /= step;
  double x0 = +VL_INFINITY_D, x1 = -VL_INFINITY_D;
  double y0 = +VL_INFINITY_D, y1 = -VL_INFINITY_D;
  double boxx[4] = {extent, extent, -extent, -extent};
  double boxy[4] = {-extent, extent, extent, -extent};
  for (int i = 0; i < 4; ++i) {
    double x = A[0] * boxx[i] + A[2] * boxy[i] + T[0];
    double y = A[1] * boxx[i] + A[3] * boxy[i] + T[1];
    x0 = VL_MIN(x0, x); x1 = VL_MAX(x1, x);
    y0 = VL_MIN(y0, y); y1 = VL_MAX(y1, y);
  }
  vl_index x0i = (vl_index)floor(x0) - 1, y0i = (vl_index)floor(y0) - 1;
  vl_index x1i = (vl_index)ceil(x1) + 1, y1i = (vl_index)ceil(y1) + 1;
  if (x0i < 0 || x1i > (signed)width - 1 || y0i < 0 || y1i > (signed)height - 1) {
    vl_index padx0 = VL_MAX(0, -x0i), pady0 = VL_MAX(0, -y0i);
    vl_index padx1 = VL_MAX(0, x1i - ((signed)width - 1));
    vl_index pady1 = VL_MAX(0, y1i - ((signed)height - 1));
    vl_index patchWidth = x1i - x0i + 1, patchHeight = y1i - y0i + 1;
    std::vector<float> P(static_cast<size_t>(patchWidth) * patchHeight, 0.0f);
    if (pady0 < patchHeight - pady1) {
      for (vl_index yi = y0i + pady0; yi < y0i + patchHeight - pady1; ++yi) {
        float* dst = P.data() + (yi - y0i) * patchWidth;
        const float* src = level + yi * (signed)width +
                           VL_MIN(VL_MAX(0, x0i), (signed)width - 1);
        vl_index xi = x0i;
        for (; xi < x0i + padx0; ++xi) *dst++ = *src;
        for (; xi < x0i + patchWidth - padx1 - 2; ++xi) *dst++ = *src++;
        for (; xi < x0i + patchWidth; ++xi) *dst++ = *src;
      }
      for (vl_index yi = 0; yi < pady0; ++yi)
        std::memcpy(P.data() + yi * patchWidth, P.data() + pady0 * patchWidth,
                    static_cast<size_t>(patchWidth) * sizeof(float));
      for (vl_index yi = patchHeight - pady1; yi < patchHeight; ++yi)
        std::memcpy(P.data() + yi * patchWidth,
                    P.data() + (patchHeight - pady1 - 1) * patchWidth,
                    static_cast<size_t>(patchWidth) * sizeof(float));
    } else {
      std::fill(P.begin(), P.end(), 0.0f);
    }
    out->plane = std::move(P);
    out->lw = (int)patchWidth; out->lh = (int)patchHeight;
    T[0] -= x0i; T[1] -= y0i;
  } else {
    vl_index patchWidth = x1i - x0i + 1, patchHeight = y1i - y0i + 1;
    std::vector<float> P(static_cast<size_t>(patchWidth) * patchHeight);
    for (vl_index yi = 0; yi < patchHeight; ++yi) {
      const float* src = level + (y0i + yi) * (signed)width + x0i;
      std::memcpy(P.data() + yi * patchWidth, src,
                  static_cast<size_t>(patchWidth) * sizeof(float));
    }
    out->plane = std::move(P);
    out->lw = (int)patchWidth; out->lh = (int)patchHeight;
    T[0] -= x0i; T[1] -= y0i;
  }
  out->A[0] = A[0]; out->A[1] = A[1]; out->A[2] = A[2]; out->A[3] = A[3];
  out->T[0] = T[0]; out->T[1] = T[1];
  return true;
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

// Reproduce sift_dsp_descriptor.wgsl build_patch on a host plane: resample the
// 31x31 patch from a PatchRec + plane (so PATH A and PATH B descriptor INPUTS
// can be compared pixel-for-pixel — the "warped-patch max-abs diff").
void resample_patch(const PatchRec& r, const float* plane,
                    std::vector<float>* patch_out) {
  patch_out->assign(static_cast<size_t>(kPatchSide) * kPatchSide, 0.0f);
  const int w = static_cast<int>(r.lw);
  int pt = 0;
  float yhat = -r.extent;
  for (int yyi = 0; yyi < kPatchSide; ++yyi) {
    float xhat = -r.extent;
    const float rx = r.a2 * yhat + r.tx;
    const float ry = r.a3 * yhat + r.ty;
    for (int xxi = 0; xxi < kPatchSide; ++xxi) {
      const float x = r.a0 * xhat + rx;
      const float y = r.a1 * xhat + ry;
      const int xi = static_cast<int>(std::floor(x));
      const int yi = static_cast<int>(std::floor(y));
      const float i00 = plane[yi * w + xi];
      const float i10 = plane[yi * w + xi + 1];
      const float i01 = plane[(yi + 1) * w + xi];
      const float i11 = plane[(yi + 1) * w + xi + 1];
      const float wx = x - static_cast<float>(xi);
      const float wy = y - static_cast<float>(yi);
      (*patch_out)[pt++] =
          (1.0f - wy) * ((1.0f - wx) * i00 + wx * i10) +
          wy * ((1.0f - wx) * i01 + wx * i11);
      xhat += r.stephat;
    }
    yhat += r.stephat;
  }
}

// Run sift_dsp_descriptor.wgsl over a (gss_concat, recs) pair -> N*128 uint8.
std::vector<uint8_t> run_descriptor(aether::tools::DawnKernelHarness& h,
                                    const std::string& wgsl,
                                    const std::vector<float>& gss_concat,
                                    const std::vector<PatchRec>& recs,
                                    const std::vector<float>& lut, int N) {
  auto pipeline = h.load_compute(wgsl, "descriptor");
  wgpu::Buffer gss_buf = h.upload(gss_concat.data(),
                                  gss_concat.size() * sizeof(float),
                                  wgpu::BufferUsage::Storage);
  wgpu::Buffer recs_buf = h.upload(recs.data(), recs.size() * sizeof(PatchRec),
                                   wgpu::BufferUsage::Storage);
  wgpu::Buffer lut_buf = h.upload(lut.data(), lut.size() * sizeof(float),
                                  wgpu::BufferUsage::Storage);
  const size_t out_words = static_cast<size_t>(N) * 32;
  wgpu::Buffer out_buf = h.alloc(out_words * sizeof(uint32_t),
                                 wgpu::BufferUsage::Storage |
                                     wgpu::BufferUsage::CopySrc);
  const size_t dbg_n = static_cast<size_t>(N) * 128;
  wgpu::Buffer dbg_buf = h.alloc(dbg_n * sizeof(float),
                                 wgpu::BufferUsage::Storage |
                                     wgpu::BufferUsage::CopySrc);
  DescParams p{};
  p.num_kp = static_cast<uint32_t>(N);
  p.dsp_num_scales = static_cast<uint32_t>(kDspNumScales);
  p.k_sigma = static_cast<float>(kSigma);
  wgpu::Buffer params_buf = h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);
  const uint32_t wg = (static_cast<uint32_t>(N) + 63u) / 64u;
  h.dispatch(pipeline, {gss_buf, recs_buf, lut_buf, out_buf, params_buf, dbg_buf},
             wg, 1u, 1u);
  wgpu::Buffer staging = h.alloc_staging_for_readback(out_words * sizeof(uint32_t));
  h.copy_to_staging(out_buf, staging, out_words * sizeof(uint32_t));
  std::vector<uint8_t> raw = h.readback(staging, out_words * sizeof(uint32_t));
  std::vector<uint8_t> desc(static_cast<size_t>(N) * 128);
  std::memcpy(desc.data(), raw.data(), desc.size());
  return desc;
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
  const int kp_cap = argc > 4 ? std::atoi(argv[4]) : 0;

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

  // ── 2. CPU detector path: detect + affine + orient + sort. ──
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

  // ─────────────────────────────────────────────────────────────────────────
  // PATH A: host fp64 build_warp_setup → recs_A + gss_concat_A (the validated
  // descriptor bridge). Also stash the host level picks + per-rec resampled
  // patch for the diagnostics.
  // ─────────────────────────────────────────────────────────────────────────
  std::vector<PatchRec> recs_A(static_cast<size_t>(N) * kDspNumScales);
  std::vector<float> gss_concat_A;
  std::vector<int> host_pick_o(static_cast<size_t>(N) * kDspNumScales);
  std::vector<int> host_pick_s(static_cast<size_t>(N) * kDspNumScales);
  std::vector<std::vector<float>> host_patch(static_cast<size_t>(N) * kDspNumScales);
  for (int i = 0; i < N; ++i) {
    for (int s = 0; s < kDspNumScales; ++s) {
      const double dsp = kDspMinScale + s * dsp_scale_step;
      VlFrameOrientedEllipse sf = features[i].frame;
      sf.a11 *= dsp; sf.a12 *= dsp; sf.a21 *= dsp; sf.a22 *= dsp;
      double A_in[4] = {sf.a11, sf.a21, sf.a12, sf.a22};
      double T_in[2] = {sf.x, sf.y};
      double D[4], U[4], V[4];
      vl_svd2(D, U, V, A_in);
      WarpSetup ws;
      build_warp_setup(gss, A_in, T_in, D[0], D[3], kPatchRelativeExtent,
                       kPatchRelativeSmoothing, &ws);
      const size_t ri = static_cast<size_t>(i) * kDspNumScales + s;
      PatchRec& r = recs_A[ri];
      r.a0 = (float)ws.A[0]; r.a1 = (float)ws.A[1];
      r.a2 = (float)ws.A[2]; r.a3 = (float)ws.A[3];
      r.tx = (float)ws.T[0]; r.ty = (float)ws.T[1];
      r.extent = (float)kPatchRelativeExtent;
      r.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
      r.level_off = static_cast<uint32_t>(gss_concat_A.size());
      r.lw = static_cast<uint32_t>(ws.lw);
      r.lh = static_cast<uint32_t>(ws.lh);
      r.pad0 = 0u;
      host_pick_o[ri] = ws.picked_o;
      host_pick_s[ri] = ws.picked_s;
      resample_patch(r, ws.plane.data(), &host_patch[ri]);
      gss_concat_A.insert(gss_concat_A.end(), ws.plane.begin(), ws.plane.end());
    }
  }
  std::printf("PATH A (host fp64): %zu recs, gss_concat %.1f MB\n",
              recs_A.size(), gss_concat_A.size() * sizeof(float) / 1e6);

  // ─────────────────────────────────────────────────────────────────────────
  // Build the resident gss (one flat buffer) + OctGeomW table for PATH B.
  // ─────────────────────────────────────────────────────────────────────────
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
  std::printf("resident gss: %d oct, %d lvl/oct, %zu floats (%.1f MB)\n", nOct,
              nLevels, pyramid.size(), pyramid.size() * sizeof(float) / 1e6);

  // WarpIn frames: a11..a22 pre-scaled by dsp on the host (the shader's
  // contract — the dsp scalar is trivial). One rec per (kp x scale).
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
  if (warp_wgsl.empty() || desc_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: read WGSL\n"); return 2;
  }
  std::vector<float> lut = build_expn_lut();

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

  // ── PATH B pass 1: warp_size (geometry + level pick + plane dims). ──
  auto pipe_size = h.load_compute(warp_wgsl, "warp_size");
  wgpu::Buffer win_buf = h.upload(w_in.data(), w_in.size() * sizeof(WarpIn),
                                  wgpu::BufferUsage::Storage);
  wgpu::Buffer octs_buf = h.upload(octs.data(), octs.size() * sizeof(OctGeomW),
                                   wgpu::BufferUsage::Storage);
  wgpu::Buffer geom_buf = h.alloc((size_t)M * sizeof(WarpGeom),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  wgpu::Buffer pf_buf = h.alloc((size_t)M * sizeof(uint32_t),
                                wgpu::BufferUsage::Storage |
                                    wgpu::BufferUsage::CopySrc);
  wgpu::Buffer wp_buf = h.upload(&WP, sizeof(WP), wgpu::BufferUsage::Uniform);
  const uint32_t gx = ((uint32_t)M + 63u) / 64u;
  h.dispatch(pipe_size, {win_buf, octs_buf, geom_buf, pf_buf, wp_buf}, gx, 1u, 1u);

  // Read back the geometry + plane float counts.
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

  // ── HOST PREFIX-SUM: per-rec plane offset into out_planes. ──
  std::vector<uint32_t> rec_offset(M);
  uint64_t total_floats = 0;
  for (int i = 0; i < M; ++i) {
    rec_offset[i] = (uint32_t)total_floats;
    total_floats += plane_floats[i];
  }
  std::printf("PATH B: out_planes %llu floats (%.1f MB)\n",
              (unsigned long long)total_floats,
              (double)total_floats * sizeof(float) / 1e6);

  // ── PATH B pass 2: warp_fill (materialize planes + emit PatchRecs). ──
  auto pipe_fill = h.load_compute(warp_wgsl, "warp_fill");
  wgpu::Buffer gssR_buf = h.upload(pyramid.data(), pyramid.size() * sizeof(float),
                                   wgpu::BufferUsage::Storage);
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
  // warp_fill strides over recs: it dispatches WARP_FILL_GRID workgroups (must
  // match the shader's const WARP_FILL_GRID), each striding r += GRID. This
  // stays within Dawn's 65535-workgroups-per-dimension cap for the ~82k recs.
  const uint32_t kWarpFillGrid = 32768u;  // == sift_descriptor_warp.wgsl WARP_FILL_GRID
  const uint32_t fill_wg = std::min((uint32_t)M, kWarpFillGrid);
  h.dispatch(pipe_fill,
             {gssR_buf, geomIn_buf, roff_buf, planes_buf, recsB_buf, wp2_buf},
             fill_wg, 1u, 1u);

  // Read back PATH B PatchRecs + planes.
  std::vector<PatchRec> recs_B(M);
  {
    wgpu::Buffer st = h.alloc_staging_for_readback((size_t)M * sizeof(PatchRec));
    h.copy_to_staging(recsB_buf, st, (size_t)M * sizeof(PatchRec));
    std::vector<uint8_t> raw = h.readback(st, (size_t)M * sizeof(PatchRec));
    std::memcpy(recs_B.data(), raw.data(), (size_t)M * sizeof(PatchRec));
  }
  std::vector<float> gss_concat_B((size_t)total_floats);
  {
    wgpu::Buffer st =
        h.alloc_staging_for_readback((size_t)total_floats * sizeof(float));
    h.copy_to_staging(planes_buf, st, (size_t)total_floats * sizeof(float));
    std::vector<uint8_t> raw = h.readback(st, (size_t)total_floats * sizeof(float));
    std::memcpy(gss_concat_B.data(), raw.data(), (size_t)total_floats * sizeof(float));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DIAGNOSTIC 1: level-pick agreement (GPU fp32 vs host fp64).
  // ─────────────────────────────────────────────────────────────────────────
  int pick_match = 0, oct_flip = 0, s_flip = 0;
  for (int i = 0; i < M; ++i) {
    const int go = firstO + (int)geom[i].oct_idx;
    // Recover GPU s from level_base: s = (level_base - base)/(w*h) + firstSub.
    const OctGeomW& oc = octs[geom[i].oct_idx];
    const uint32_t rel = geom[i].level_base - oc.base;
    const int gs = (oc.w * oc.h) ? (int)(rel / (oc.w * oc.h)) + firstSub : firstSub;
    const bool om = (go == host_pick_o[i]);
    const bool sm = (gs == host_pick_s[i]);
    if (om && sm) ++pick_match;
    if (!om) ++oct_flip;
    if (om && !sm) ++s_flip;
  }
  std::printf(
      "\n--- LEVEL-PICK agreement (GPU fp32 vs host fp64) ---\n"
      "  recs                 : %d\n"
      "  (octave,s) match     : %d (%.4f%%)\n"
      "  octave flips         : %d\n"
      "  s flips (oct ok)     : %d\n",
      M, pick_match, 100.0 * pick_match / M, oct_flip, s_flip);

  // ─────────────────────────────────────────────────────────────────────────
  // DIAGNOSTIC 2: warped-patch max-abs diff (descriptor INPUT). Resample each
  // PATH B plane with build_patch math and compare to the host patch.
  // ─────────────────────────────────────────────────────────────────────────
  double patch_max_abs = 0.0, patch_sum_abs = 0.0;
  size_t patch_cmp = 0;
  std::vector<float> gpu_patch;
  for (int i = 0; i < M; ++i) {
    resample_patch(recs_B[i], gss_concat_B.data() + recs_B[i].level_off,
                   &gpu_patch);
    for (size_t k = 0; k < gpu_patch.size(); ++k) {
      const double d = std::fabs((double)gpu_patch[k] - (double)host_patch[i][k]);
      patch_max_abs = std::max(patch_max_abs, d);
      patch_sum_abs += d;
      ++patch_cmp;
    }
  }
  std::printf(
      "\n--- WARPED-PATCH diff (PATH B plane vs PATH A plane, build_patch resample) ---\n"
      "  patches compared     : %d (each %dx%d)\n"
      "  max |Δ|              : %.6e\n"
      "  mean |Δ|             : %.6e\n",
      M, kPatchSide, kPatchSide, patch_max_abs,
      patch_cmp ? patch_sum_abs / patch_cmp : 0.0);

  // ─────────────────────────────────────────────────────────────────────────
  // Run sift_dsp_descriptor.wgsl on BOTH paths.
  // ─────────────────────────────────────────────────────────────────────────
  std::vector<uint8_t> desc_A =
      run_descriptor(h, desc_wgsl, gss_concat_A, recs_A, lut, N);
  std::vector<uint8_t> desc_B =
      run_descriptor(h, desc_wgsl, gss_concat_B, recs_B, lut, N);

  // ── Compare descriptor cosine A vs B. ──
  std::vector<double> cos(N);
  for (int i = 0; i < N; ++i)
    cos[i] = cosine_u8(desc_A.data() + (size_t)i * 128,
                       desc_B.data() + (size_t)i * 128);
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
      "\n=== DSP WARP-SETUP PARITY (GPU warp-setup vs host fp64 build_warp_setup,\n"
      "    both -> sift_dsp_descriptor.wgsl) ===\n"
      "keypoints              : %d\n"
      "per-desc cosine mean   : %.6f\n"
      "per-desc cosine MEDIAN : %.6f   (gate >= 0.998  %s)\n"
      "per-desc cosine p95    : %.6f   (gate >= 0.99   %s)\n"
      "per-desc cosine p99    : %.6f\n"
      "per-desc cosine MIN    : %.6f\n",
      N, mean, median, median >= 0.998 ? "ok" : "FAIL", p95,
      p95 >= 0.99 ? "ok" : "FAIL", p01, cmin);

  const bool pass = (median >= 0.998) && (p95 >= 0.99);
  std::printf("gate: median>=0.998 AND p95>=0.99  =>  %s\n",
              pass ? "PASS" : "FAIL");

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}
