// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// parity_descriptor.cc — GPU DSP-SIFT descriptor parity gate (Stage S3).
//
// Validates shaders/wgsl/sift_dsp_descriptor.wgsl against VLFeat's OWN
// domain-size-pooling descriptor. Strategy (isolate the S3 DESCRIPTOR kernel
// from the affine-shape / level-selection fp64 math that S4 owns):
//
//   1. Build the CPU reference oriented+affine keypoints via VLFeat covdet,
//      EXACTLY the production CPU path (aether_threaded_extract.cc /
//      colmap CovariantSiftCPUFeatureExtractor): vl_covdet_new(DOG),
//      first_octave/peak/edge/octave_resolution, put_image, detect, affine
//      shape, orientations, sort. -> N oriented+affine VlCovDetFeature frames.
//
//   2. For each keypoint i x each of dsp_num_scales (=10) dsp_scales s:
//        * scale the frame (a11*dsp_scale ... a22*dsp_scale) — extract.cc:256-260.
//        * reproduce vl_covdet_extract_patch_helper's HOST setup VERBATIM
//          (covdet.c:2222-2360): vl_svd2 -> factor=1/min(d1,d2) -> level (o,s)
//          search -> A/=step, T/=step -> bilinear-pad the chosen level plane.
//          This produces, per (i,s): the padded level plane bytes + the warp
//          PatchRec {A/step, T(shifted), extent, stephat, level_off, lw, lh}.
//          The GPU kernel's build_patch reproduces ONLY the resample inner loop
//          (covdet.c:2362-2399) over that EXACT plane -> byte-identical warp
//          INPUTS to VLFeat's resample. (The fp64 level pick lives on the CPU
//          for S3; S4 ports affine-shape — PLAN risk #4.)
//
//   3. CPU reference descriptor for (i): the SAME loop as
//      aether_threaded_extract.cc:252-304 — per scale
//      vl_covdet_extract_patch_for_frame -> vl_imgradient_polar_f ->
//      vl_sift_calc_raw_descriptor; colwise().mean(); L1_ROOT; ToUnsignedByte;
//      then TransformVLFeatToUBCFeatureDescriptors. -> 128 uint8.
//
//   4. GPU: feed the SAME PatchRecs + concatenated padded planes + the fast_expn
//      LUT to sift_dsp_descriptor.wgsl `descriptor`. -> 128 uint8 per kp.
//
//   5. Compare per-descriptor: cosine similarity (over the 128-D uint8 vectors)
//      -> median / p95 / min. Gate: median >= 0.998, p95 >= 0.99.
//      Plus descriptor MATCH-RECALL: brute-force nearest-neighbour cross-match
//      GPU descriptors against the CPU descriptors (L2 over uint8), report the
//      fraction whose NN is the same index. Gate: >= 0.95.
//
// Build: build_descriptor.sh (worktree-only; reuses prebuilt host Dawn + VLFeat
// + dawn_kernel_harness.cpp). Unique obj dir /tmp/parity_desc_obj.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// ─── VLFeat (CPU reference: detector + patch + gradient + raw descriptor) ───
extern "C" {
#include "covdet.h"
#include "scalespace.h"
#include "sift.h"
#include "imopv.h"
#include "mathop.h"
}

// ─── Dawn kernel harness (GPU under test) ───
#include "dawn_kernel_harness.h"

// ─── stb_image (JPEG decode) ───
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

// ── Production CPU-path constants (aether_threaded_extract.cc:223-231) ──
constexpr int    kPatchResolution = 15;
constexpr int    kPatchSide = 2 * kPatchResolution + 1;  // 31
constexpr double kPatchRelativeExtent = 7.5;
constexpr double kPatchRelativeSmoothing = 1.0;
constexpr double kPatchStep = kPatchRelativeExtent / kPatchResolution;
constexpr double kSigma =
    kPatchRelativeExtent / (3.0 * (4 + 1) / 2) / kPatchStep;
constexpr double kMagnif = 3.0;

// COLMAP SiftExtractionOptions defaults (sift.h) used by the production path.
constexpr int    kFirstOctave = 0;          // PLAN 06-25 port baseline (fo0).
constexpr int    kOctaveResolution = 3;
constexpr double kEdgeThreshold = 10.0;
constexpr int    kMaxNumFeatures = 8192;
constexpr double kDspMinScale = 1.0 / 6.0;
constexpr double kDspMaxScale = 3.0;
constexpr int    kDspNumScales = 10;
// peak_threshold default = 0.02/octave_resolution (sift.h:55).
constexpr double kPeakThreshold = 0.02 / 3.0;

// ── fast_expn LUT, host-built with the SAME exp() VLFeat uses (sift.c:713-719).
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

// std430 PatchRec (mirrors WGSL struct, 48 bytes = 12 * 4).
#pragma pack(push, 4)
struct PatchRec {
  float a0, a1, a2, a3;  // A divided by step (column-major map patch->level)
  float tx, ty;          // T divided by step, shifted by pad origin
  float extent;
  float stephat;
  uint32_t level_off;    // first float index of the padded plane in `gss`
  uint32_t lw, lh;       // padded plane dims
  uint32_t pad0;
};
struct Params {
  uint32_t num_kp;
  uint32_t dsp_num_scales;
  uint32_t patch_sigma;  // unused
  uint32_t pad0;
  float k_sigma;
  float pad1, pad2, pad3;
};
#pragma pack(pop)
static_assert(sizeof(PatchRec) == 48, "PatchRec must be 48 bytes");
static_assert(sizeof(Params) == 32, "Params must be 32 bytes");

// ── Host replica of vl_covdet_extract_patch_helper SETUP + PADDING ──
// VERBATIM transcription of covdet.c:2222-2360 (everything BEFORE the resample
// inner loop). Produces the warp params + the padded level plane the GPU
// resamples. Returns false if the geometry is degenerate (skip the kp).
//
// `A_in` = {a11,a21,a12,a22} (column-major, covdet.c:2438); `T_in`={x,y};
// d1,d2 = SVD singular values from vl_svd2.
struct WarpSetup {
  std::vector<float> plane;  // the (lw*lh) level plane the kernel resamples
  double A[4];               // A/step  (A[0],A[1],A[2],A[3] = a0,a1,a2,a3)
  double T[2];               // T/step (+pad shift)
  int lw, lh;
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
    sigma_ = geom.baseScale *
             pow(2.0, o + (double)s / geom.octaveResolution);
    if (factor * sigma_ > sigma) {
      o--;
      break;
    }
  }
  o = VL_MIN(o, geom.lastOctave);
  s = vl_floor_d(vl_log2_d(sigma / (factor * geom.baseScale)) - o);
  s = VL_MAX(s, geom.octaveFirstSubdivision);
  s = VL_MIN(s, geom.octaveLastSubdivision);

  const float* level = vl_scalespace_get_level(gss, o, s);
  oct = vl_scalespace_get_octave_geometry(gss, o);
  vl_size width = oct.width;
  vl_size height = oct.height;
  const double step = oct.step;

  A[0] /= step; A[1] /= step; A[2] /= step; A[3] /= step;
  T[0] /= step; T[1] /= step;

  // bounding box of the warped patch domain (covdet.c:2274-2295)
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
  vl_index x0i = (vl_index)floor(x0) - 1;
  vl_index y0i = (vl_index)floor(y0) - 1;
  vl_index x1i = (vl_index)ceil(x1) + 1;
  vl_index y1i = (vl_index)ceil(y1) + 1;

  if (x0i < 0 || x1i > (signed)width - 1 || y0i < 0 ||
      y1i > (signed)height - 1) {
    // pad: replicate covdet.c:2305-2358 exactly into a fresh plane.
    vl_index padx0 = VL_MAX(0, -x0i);
    vl_index pady0 = VL_MAX(0, -y0i);
    vl_index padx1 = VL_MAX(0, x1i - ((signed)width - 1));
    vl_index pady1 = VL_MAX(0, y1i - ((signed)height - 1));
    vl_index patchWidth = x1i - x0i + 1;
    vl_index patchHeight = y1i - y0i + 1;
    std::vector<float> P(static_cast<size_t>(patchWidth) * patchHeight, 0.0f);

    if (pady0 < patchHeight - pady1) {
      for (vl_index yi = y0i + pady0; yi < y0i + patchHeight - pady1; ++yi) {
        float* dst = P.data() + (yi - y0i) * patchWidth;
        const float* src =
            level + yi * (signed)width + VL_MIN(VL_MAX(0, x0i), (signed)width - 1);
        vl_index xi = x0i;
        for (; xi < x0i + padx0; ++xi) *dst++ = *src;
        for (; xi < x0i + patchWidth - padx1 - 2; ++xi) *dst++ = *src++;
        for (; xi < x0i + patchWidth; ++xi) *dst++ = *src;
      }
      for (vl_index yi = 0; yi < pady0; ++yi)
        std::memcpy(P.data() + yi * patchWidth,
                    P.data() + pady0 * patchWidth,
                    static_cast<size_t>(patchWidth) * sizeof(float));
      for (vl_index yi = patchHeight - pady1; yi < patchHeight; ++yi)
        std::memcpy(P.data() + yi * patchWidth,
                    P.data() + (patchHeight - pady1 - 1) * patchWidth,
                    static_cast<size_t>(patchWidth) * sizeof(float));
    } else {
      // covdet.c:2342-2344 "should be handled better" — zero plane.
      std::fill(P.begin(), P.end(), 0.0f);
    }
    out->plane = std::move(P);
    out->lw = static_cast<int>(patchWidth);
    out->lh = static_cast<int>(patchHeight);
    T[0] -= x0i;
    T[1] -= y0i;
  } else {
    // No padding needed (box fully in-bounds). To keep each rec's plane small
    // (the full octave-0 plane is ~40 MB and there are N*10 recs -> multi-GB),
    // CROP to the SAME [x0i,y0i,x1i,y1i] box VLFeat's resample touches and shift
    // T by (-x0i,-y0i) — byte-IDENTICAL to resampling the full plane, since the
    // bilinear loop only ever reads pixels inside that box (no edge replication
    // is needed because the box is in-bounds). This is a pure host memory
    // optimization; it does not change a single sampled value.
    vl_index patchWidth = x1i - x0i + 1;
    vl_index patchHeight = y1i - y0i + 1;
    std::vector<float> P(static_cast<size_t>(patchWidth) * patchHeight);
    for (vl_index yi = 0; yi < patchHeight; ++yi) {
      const float* src = level + (y0i + yi) * (signed)width + x0i;
      std::memcpy(P.data() + yi * patchWidth, src,
                  static_cast<size_t>(patchWidth) * sizeof(float));
    }
    out->plane = std::move(P);
    out->lw = static_cast<int>(patchWidth);
    out->lh = static_cast<int>(patchHeight);
    T[0] -= x0i;
    T[1] -= y0i;
  }
  out->A[0] = A[0]; out->A[1] = A[1]; out->A[2] = A[2]; out->A[3] = A[3];
  out->T[0] = T[0]; out->T[1] = T[1];
  return true;
}

// ── UBC reorder (aether_threaded_extract.cc:34-50), applied to one 128-vector.
void ubc_reorder(const uint8_t* in, uint8_t* out) {
  static const int q[8] = {0, 7, 6, 5, 4, 3, 2, 1};
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      for (int k = 0; k < 8; ++k)
        out[8 * (j + 4 * i) + q[k]] = in[8 * (j + 4 * i) + k];
}

// ── Cosine similarity between two uint8 128-vectors. ──
double cosine_u8(const uint8_t* a, const uint8_t* b) {
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < 128; ++i) {
    const double x = a[i], y = b[i];
    dot += x * y; na += x * x; nb += y * y;
  }
  if (na == 0.0 || nb == 0.0) return (na == 0.0 && nb == 0.0) ? 1.0 : 0.0;
  return dot / (std::sqrt(na) * std::sqrt(nb));
}

double l2sq_u8(const uint8_t* a, const uint8_t* b) {
  double s = 0;
  for (int i = 0; i < 128; ++i) {
    const double d = static_cast<double>(a[i]) - static_cast<double>(b[i]);
    s += d * d;
  }
  return s;
}

}  // namespace

int main(int argc, char** argv) {
  const char* img_path = argc > 1
      ? argv[1]
      : "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* wgsl_path =
      argc > 2 ? argv[2] : "shaders/wgsl/sift_dsp_descriptor.wgsl";
  // optional cap on #keypoints for a quick run (0 = all).
  const int kp_cap = argc > 3 ? std::atoi(argv[3]) : 0;

  // ── 1. Load image as grayscale fp32 in [0,1] (extract.cc:76-80). ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s): %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32 [0,1]\n",
              img_path, iw, ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * ih);
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]) / 255.0f;
  stbi_image_free(pixels);

  // ── 2. CPU detector path: detect + affine + orient + sort (extract.cc:60-163).
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) { std::fprintf(stderr, "FAIL: vl_covdet_new\n"); return 2; }
  vl_covdet_set_first_octave(covdet, kFirstOctave);
  vl_covdet_set_octave_resolution(covdet, kOctaveResolution);
  vl_covdet_set_peak_threshold(covdet, kPeakThreshold);
  vl_covdet_set_edge_threshold(covdet, kEdgeThreshold);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  vl_covdet_detect(covdet, kMaxNumFeatures);
  vl_covdet_extract_affine_shape(covdet);   // estimate_affine_shape = true
  vl_covdet_extract_orientations(covdet);   // upright = false

  int num_features = vl_covdet_get_num_features(covdet);
  VlCovDetFeature* features = vl_covdet_get_features(covdet);
  std::sort(features, features + num_features,
            [](const VlCovDetFeature& f1, const VlCovDetFeature& f2) {
              if (f1.o == f2.o) return f1.s > f2.s;
              return f1.o > f2.o;
            });
  if (kp_cap > 0 && num_features > kp_cap) num_features = kp_cap;
  std::printf("CPU oriented+affine keypoints: %d  (dsp_num_scales=%d)\n",
              num_features, kDspNumScales);
  if (num_features == 0) {
    std::fprintf(stderr, "FAIL: 0 keypoints\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  VlScaleSpace* gss = vl_covdet_get_gss(covdet);

  const double dsp_scale_step =
      (kDspMaxScale - kDspMinScale) / kDspNumScales;

  // ── 3. CPU reference descriptor (extract.cc:209-304) using VLFeat directly. ──
  // Single-threaded here (parity, not perf). Bit-identical to the worker loop.
  std::unique_ptr<VlSiftFilt, void (*)(VlSiftFilt*)> sift(
      vl_sift_new(16, 16, 1, 3, 0), &vl_sift_delete);
  vl_sift_set_magnif(sift.get(), kMagnif);
  // covdet for patch extraction borrows the same gss (extract.cc:210-214).
  VlCovDet* wd = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_gss(wd, gss);

  std::vector<float> patch(static_cast<size_t>(kPatchSide) * kPatchSide);
  std::vector<float> patchXY(2 * static_cast<size_t>(kPatchSide) * kPatchSide);

  const int N = num_features;
  std::vector<uint8_t> cpu_desc(static_cast<size_t>(N) * 128);
  std::vector<float> cpu_descf(static_cast<size_t>(N) * 128);  // VLFeat order, post-L1Root

  // GPU input buffers, built in lockstep so the kernel sees the SAME warp:
  std::vector<PatchRec> recs(static_cast<size_t>(N) * kDspNumScales);
  std::vector<float> gss_concat;  // all per-rec padded planes, concatenated
  gss_concat.reserve(static_cast<size_t>(N) * kDspNumScales * 1024);

  int skipped = 0;
  for (int i = 0; i < N; ++i) {
    std::vector<float> scaled_descriptors(static_cast<size_t>(kDspNumScales) * 128);
    for (int s = 0; s < kDspNumScales; ++s) {
      const double dsp_scale = kDspMinScale + s * dsp_scale_step;
      VlFrameOrientedEllipse sf = features[i].frame;
      sf.a11 *= dsp_scale; sf.a12 *= dsp_scale;
      sf.a21 *= dsp_scale; sf.a22 *= dsp_scale;

      // --- CPU patch + gradient + raw descriptor (the production calls) ---
      vl_covdet_extract_patch_for_frame(wd, patch.data(), kPatchResolution,
                                        kPatchRelativeExtent,
                                        kPatchRelativeSmoothing, sf);
      vl_imgradient_polar_f(patchXY.data(), patchXY.data() + 1, 2,
                            2 * kPatchSide, patch.data(), kPatchSide,
                            kPatchSide, kPatchSide);
      vl_sift_calc_raw_descriptor(sift.get(), patchXY.data(),
                                  scaled_descriptors.data() + static_cast<size_t>(s) * 128,
                                  kPatchSide, kPatchSide, kPatchResolution,
                                  kPatchResolution, kSigma, 0);

      // --- GPU PatchRec: reproduce extract_patch_helper SETUP host-side ---
      double A_in[4] = {sf.a11, sf.a21, sf.a12, sf.a22};  // covdet.c:2438
      double T_in[2] = {sf.x, sf.y};
      double D[4], U[4], V[4];
      vl_svd2(D, U, V, A_in);
      WarpSetup ws;
      // sigma arg = kPatchRelativeSmoothing (the 5th arg to
      // vl_covdet_extract_patch_for_frame in extract.cc:262-267), NOT kSigma.
      // It drives the scale-space LEVEL pick in extract_patch_helper.
      build_warp_setup(gss, A_in, T_in, D[0], D[3], kPatchRelativeExtent,
                       kPatchRelativeSmoothing, &ws);
      PatchRec& r = recs[static_cast<size_t>(i) * kDspNumScales + s];
      r.a0 = static_cast<float>(ws.A[0]);
      r.a1 = static_cast<float>(ws.A[1]);
      r.a2 = static_cast<float>(ws.A[2]);
      r.a3 = static_cast<float>(ws.A[3]);
      r.tx = static_cast<float>(ws.T[0]);
      r.ty = static_cast<float>(ws.T[1]);
      r.extent = static_cast<float>(kPatchRelativeExtent);
      r.stephat = static_cast<float>(kPatchRelativeExtent / kPatchResolution);
      r.level_off = static_cast<uint32_t>(gss_concat.size());
      r.lw = static_cast<uint32_t>(ws.lw);
      r.lh = static_cast<uint32_t>(ws.lh);
      r.pad0 = 0u;
      gss_concat.insert(gss_concat.end(), ws.plane.begin(), ws.plane.end());
    }

    // colwise().mean() over the 10 scales (extract.cc:289-290).
    float descf[128];
    for (int b = 0; b < 128; ++b) {
      double acc = 0.0;
      for (int s = 0; s < kDspNumScales; ++s)
        acc += scaled_descriptors[static_cast<size_t>(s) * 128 + b];
      descf[b] = static_cast<float>(acc / kDspNumScales);
    }
    // L1_ROOT (utils.cc:49-55): d *= 1/sum(|d|); d = sqrt(d).
    double l1 = 0.0;
    for (int b = 0; b < 128; ++b) l1 += std::fabs(descf[b]);
    const float inv_l1 = static_cast<float>(1.0 / l1);
    for (int b = 0; b < 128; ++b) descf[b] = std::sqrt(descf[b] * inv_l1);
    std::memcpy(cpu_descf.data() + static_cast<size_t>(i) * 128, descf,
                128 * sizeof(float));  // VLFeat order, post-L1Root (debug)
    // ToUnsignedByte (utils.cc:57-69): round(512*d) clamp [0,255].
    uint8_t vlfeat_order[128];
    for (int b = 0; b < 128; ++b) {
      const float sv = std::round(512.0f * descf[b]);
      const float c = sv < 0.0f ? 0.0f : (sv > 255.0f ? 255.0f : sv);
      vlfeat_order[b] = static_cast<uint8_t>(c);
    }
    // UBC reorder into the final row (extract.cc:332).
    ubc_reorder(vlfeat_order, cpu_desc.data() + static_cast<size_t>(i) * 128);
  }
  vl_covdet_set_gss(wd, nullptr);
  vl_covdet_delete(wd);
  (void)skipped;

  std::printf("GPU input: %zu recs, gss_concat %.1f MB\n", recs.size(),
              gss_concat.size() * sizeof(float) / 1e6);

  // ── 4. GPU run ──
  std::string wgsl = read_file(wgsl_path);
  if (wgsl.empty()) {
    std::fprintf(stderr, "FAIL: read WGSL %s\n", wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }
  aether::tools::DawnKernelHarness h;
  if (!h.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  auto pipeline = h.load_compute(wgsl, "descriptor");

  std::vector<float> lut = build_expn_lut();

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
  Params p{};
  p.num_kp = static_cast<uint32_t>(N);
  p.dsp_num_scales = static_cast<uint32_t>(kDspNumScales);
  p.k_sigma = static_cast<float>(kSigma);
  wgpu::Buffer params_buf =
      h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

  const uint32_t wg = (static_cast<uint32_t>(N) + 63u) / 64u;
  h.dispatch(pipeline,
             {gss_buf, recs_buf, lut_buf, out_buf, params_buf, dbg_buf}, wg,
             1u, 1u);

  wgpu::Buffer staging =
      h.alloc_staging_for_readback(out_words * sizeof(uint32_t));
  h.copy_to_staging(out_buf, staging, out_words * sizeof(uint32_t));
  std::vector<uint8_t> raw = h.readback(staging, out_words * sizeof(uint32_t));
  std::vector<uint8_t> gpu_desc(static_cast<size_t>(N) * 128);
  std::memcpy(gpu_desc.data(), raw.data(), gpu_desc.size());

  // Debug float readback (GPU post-L1Root, VLFeat bin order).
  wgpu::Buffer dstage = h.alloc_staging_for_readback(dbg_n * sizeof(float));
  h.copy_to_staging(dbg_buf, dstage, dbg_n * sizeof(float));
  std::vector<uint8_t> draw = h.readback(dstage, dbg_n * sizeof(float));
  std::vector<float> gpu_descf(dbg_n);
  std::memcpy(gpu_descf.data(), draw.data(), dbg_n * sizeof(float));
  if (getenv("DBG_KP")) {
    const int k = std::atoi(getenv("DBG_KP"));
    std::printf("\n--- DEBUG kp %d  CPU-float vs GPU-float (VLFeat order) ---\n", k);
    double maxd = 0; int maxb = -1; double cf = 0;
    for (int b = 0; b < 128; ++b) {
      const float c = cpu_descf[static_cast<size_t>(k) * 128 + b];
      const float gpv = gpu_descf[static_cast<size_t>(k) * 128 + b];
      const double d = std::fabs(c - gpv);
      if (d > maxd) { maxd = d; maxb = b; cf = c; }
      if (b < 24) std::printf("  bin %3d  cpu=%.6f  gpu=%.6f  d=%.6e\n", b, c, gpv, d);
    }
    std::printf("  ... max|d|=%.6e at bin %d (cpu=%.6f gpu=%.6f)\n", maxd, maxb,
                cf, gpu_descf[static_cast<size_t>(k) * 128 + maxb]);
    double cz = cosine_u8(cpu_desc.data() + static_cast<size_t>(k) * 128,
                          gpu_desc.data() + static_cast<size_t>(k) * 128);
    std::printf("  uint8 cosine for kp %d = %.6f\n", k, cz);
  }

  // ── 5. Compare: per-descriptor cosine (median/p95/min) + match-recall. ──
  std::vector<double> cos(N);
  for (int i = 0; i < N; ++i)
    cos[i] = cosine_u8(cpu_desc.data() + static_cast<size_t>(i) * 128,
                       gpu_desc.data() + static_cast<size_t>(i) * 128);
  std::vector<double> sorted = cos;
  std::sort(sorted.begin(), sorted.end());
  auto pct = [&](double p) {
    if (sorted.empty()) return 1.0;
    double idx = p * (sorted.size() - 1);
    size_t lo = static_cast<size_t>(std::floor(idx));
    size_t hi = static_cast<size_t>(std::ceil(idx));
    double frac = idx - lo;
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
  };
  const double median = pct(0.5);
  const double p95 = pct(0.05);   // 5th percentile = the "p95 >= 0.99" floor
  const double p01 = pct(0.01);
  const double cmin = sorted.front();
  double mean = 0; for (double c : cos) mean += c; mean /= N;

  // identity-match recall: for each GPU desc, NN among CPU descs == same index?
  int self_nn = 0;
  for (int i = 0; i < N; ++i) {
    const uint8_t* gi = gpu_desc.data() + static_cast<size_t>(i) * 128;
    double best = 1e30; int besti = -1;
    for (int j = 0; j < N; ++j) {
      const double d = l2sq_u8(gi, cpu_desc.data() + static_cast<size_t>(j) * 128);
      if (d < best) { best = d; besti = j; }
    }
    if (besti == i) ++self_nn;
  }
  const double match_recall = static_cast<double>(self_nn) / N;

  std::printf(
      "\n=== DSP DESCRIPTOR PARITY (GPU sift_dsp_descriptor.wgsl vs VLFeat) ===\n"
      "keypoints              : %d\n"
      "per-desc cosine mean   : %.6f\n"
      "per-desc cosine MEDIAN : %.6f   (gate >= 0.998  %s)\n"
      "per-desc cosine p95    : %.6f   (gate >= 0.99   %s)\n"
      "per-desc cosine p99    : %.6f\n"
      "per-desc cosine MIN    : %.6f\n"
      "match-recall (NN==self): %.6f   (gate >= 0.95   %s)\n",
      N, mean, median, median >= 0.998 ? "ok" : "FAIL", p95,
      p95 >= 0.99 ? "ok" : "FAIL", p01, cmin, match_recall,
      match_recall >= 0.95 ? "ok" : "FAIL");

  const bool pass =
      (median >= 0.998) && (p95 >= 0.99) && (match_recall >= 0.95);
  std::printf("gate: median>=0.998 AND p95>=0.99 AND match-recall>=0.95  =>  %s\n",
              pass ? "PASS" : "FAIL");

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}
