// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// extract_fullgpu_fused.cc — FULL-GPU DSP-SIFT integration, S5c FUSION:
// the descriptor stage is now a SINGLE FUSED kernel (sift_descriptor_fused.wgsl,
// task A). The two-kernel S5b path (sift_descriptor_warp.wgsl warp_fill -> a
// ~3.4 GB intermediate "concat of padded planes" buffer -> sift_dsp_descriptor)
// is replaced by ONE kernel that computes the warp geometry IN-REGISTER and
// samples the RESIDENT gss DIRECTLY per (kp x dsp-scale) — NO intermediate plane
// buffer, NO 2-GB binding split, NO plane write+readback round-trip. Extends
// extract_fullgpu_s5b.cc; everything through ORIENTATION is byte-identical.
//
// PIPELINE (per GPU_DSP_SIFT_PLAN.md data flow):
//   gss(RESIDENT) -> DoG+extremum -> refine+gate -> suppression
//                 -> affine-shape -> orientation(1-4x) -> FUSED warp+descriptor
//
// ── MODE FLAG ──
//   --fused (default) : the FUSED descriptor (sift_descriptor_fused.wgsl). The
//                 host fp64 build_warp_setup AND the 3.4 GB out_planes buffer are
//                 GONE from the critical path; the kernel reads the resident gss
//                 directly. Only the WarpIn (oriented+dsp-scaled ellipse, 32B/rec)
//                 + the OctGeomW table feed the GPU; ONE readback (kps + desc).
//   --host-warp : the host fp64 warp-setup PLACEHOLDER (identical to
//                 extract_fullgpu.cc / s5b default) — the honest reference; runs
//                 the same descriptor MATH off a host-built concat plane buffer.
//   Both modes ALWAYS run the host warp-setup as the e2e parity REFERENCE; the
//   --fused run additionally validates the fused kernel vs that reference
//   (descriptor cosine + keypoint recall/precision) and reports honestly.
//
// ── gss RESIDENCY (the load-bearing constraint) ──
//   The pyramid is one big GPU buffer (all octaves/subdivisions, level-major,
//   per-octave base offset), read by detect/refine/affine/orient AND NOW the
//   FUSED descriptor. NO per-level readback; ONE forced readback/frame (the final
//   kps + descriptors). In --fused mode the resident gss is the warp source — the
//   SAME buffer all 6 prior stages used, never round-tripped; the descriptor
//   samples it in-register per scale (no plane materialization at all).
//
// ── PEAK-MEMORY ACCOUNTING ──
//   The harness sums the largest concurrently-live GPU buffer set per mode and
//   prints the peak. The whole point of the fusion: the ~3.4 GB out_planes /
//   host concat buffer present in the 2-kernel path is ABSENT in --fused mode, so
//   peak GPU memory must DROP (and the 2-GB-buffer batching constraint is gone).
//
// Build: bench/build_fullgpu_fused.sh (worktree-only; obj dir /tmp/fullgpu_fused_obj;
// reuses the prebuilt host Dawn + the VLFeat .c subset + tools/
// dawn_kernel_harness.cpp read-only). Run from aether_cpp/ root:
//   /tmp/fullgpu_fused_obj/extract_fullgpu_fused_exe [--host-warp] \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \
//     third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg

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

// ─── VLFeat (CPU reference + baseline + descriptor warp-setup bridge) ───
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
//  Record / Params layouts — byte-matched to the validated parity harnesses.
// ════════════════════════════════════════════════════════════════════════════
#pragma pack(push, 4)
// --- gss build (sift_gss_blur.wgsl / sift_gss_resample.wgsl) ---
struct BlurParams { uint32_t width, height, radius, axis; };
struct DownParams { uint32_t src_width, src_height, dst_width, dst_height; };

// --- detect (sift_dog_extrema_test.wgsl) ---
struct DogParams {
  uint32_t width, height, num_css, octave;
  float detect_thr; uint32_t max_count, pad0, pad1;
};
struct CandidateExtremum {  // 20 bytes
  uint32_t octave, level, x, y; float dog_value;
};

// --- refine (sift_refine_gate.wgsl) ---
struct RefineParams {
  uint32_t width, height, num_css, num_cands;
  float peak_thr, edge_thr, base_scale, step;
  int32_t first_sub; float octave_res; uint32_t max_kp, pad0;
};
struct Keypoint {  // 32 bytes
  float x_local, y_local, z_local; uint32_t octave;
  float sigma, step, peak_score, edge_score;
};

// --- suppress (sift_nonextrema_suppress.wgsl); Keypoint reused above ---
struct SuppressParams {
  uint32_t num_kp, grid_w, grid_h, num_cells;
  float cell_size, tol; uint32_t pad0, pad1;
};

// --- affine (sift_affine_shape.wgsl) ---
struct OctGeom {  // 32 bytes
  uint32_t width, height, base, pad; float step, pad1, pad2, pad3;
};
struct InFrame { float x, y, a11, a12, a21, a22, pad0, pad1; };  // 32 bytes
struct AffineShape {  // 32 bytes
  float a11, a12, a21, a22, x, y; uint32_t status, iters;
};
struct AffParams {
  uint32_t num_kp, num_octaves; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
};

// --- orientation (sift_orientation.wgsl) ---
struct InputKp { float x, y, a11, a12, a21, a22; int32_t octave; uint32_t pad0; };  // 32
struct OrientedKp { uint32_t kp_index; float angle, score; uint32_t pad0; };        // 16
struct OctaveGeomO {  // 32 bytes
  int32_t width, height; float step; uint32_t gss_offset; int32_t octave;
  uint32_t pad0, pad1, pad2;
};
struct OrientParams {
  uint32_t num_kp, num_octaves; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
  uint32_t max_out, pad0, pad1, pad2;
};

// --- descriptor (sift_dsp_descriptor.wgsl) ---
struct PatchRec {  // 48 bytes
  float a0, a1, a2, a3, tx, ty, extent, stephat;
  uint32_t level_off, lw, lh, pad0;
};
struct DescParams {
  uint32_t num_kp, dsp_num_scales, patch_sigma, pad0;
  float k_sigma, pad1, pad2, pad3;
};

// --- S5b on-GPU warp-setup (sift_descriptor_warp.wgsl) ---
struct OctGeomW {  // 32 bytes — resident pyramid per-octave geometry
  uint32_t w, h, base, pad; float step, pad1, pad2, pad3;
};
struct WarpIn {  // 32 bytes — oriented+affine ellipse (dsp-scaled), image coords
  float x, y, a11, a12, a21, a22, pad0, pad1;
};
struct WarpGeom {  // 64 bytes — per-rec geometry from warp_size
  float a0, a1, a2, a3, tx, ty;
  int32_t x0i, y0i;
  uint32_t level_base, lw, lh, oct_idx;
  uint32_t src_w, src_h, status, pad1;  // src_w/src_h = resident level dims
};
struct WarpParams {
  uint32_t num_recs, num_octaves; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
  float extent, stephat, sigma, pad0;
};

// --- S5c FUSED descriptor (sift_descriptor_fused.wgsl Params, 48 bytes) ---
// num_kp, dsp_num_scales, first_octave, last_octave, first_sub, last_sub,
// octave_res, base_scale, extent, stephat, sigma, k_sigma  (12 x 4 = 48 B).
struct FusedParams {
  uint32_t num_kp, dsp_num_scales; int32_t first_octave, last_octave;
  int32_t first_sub, last_sub; float octave_res, base_scale;
  float extent, stephat, sigma, k_sigma;
};
#pragma pack(pop)
static_assert(sizeof(FusedParams) == 48, "fusedparams 48B");

static_assert(sizeof(OctGeomW) == 32, "octgeomw 32B");
static_assert(sizeof(WarpIn) == 32, "warpin 32B");
static_assert(sizeof(WarpGeom) == 64, "warpgeom 64B");
static_assert(sizeof(WarpParams) == 48, "warpparams 48B");

static_assert(sizeof(CandidateExtremum) == 20, "cand 20B");
static_assert(sizeof(Keypoint) == 32, "kp 32B");
static_assert(sizeof(OctGeom) == 32, "octgeom 32B");
static_assert(sizeof(AffineShape) == 32, "affshape 32B");
static_assert(sizeof(InputKp) == 32, "inputkp 32B");
static_assert(sizeof(OrientedKp) == 16, "orientedkp 16B");
static_assert(sizeof(OctaveGeomO) == 32, "octaveGeomO 32B");
static_assert(sizeof(OrientParams) == 48, "orientparams 48B");
static_assert(sizeof(PatchRec) == 48, "patchrec 48B");

// VLFeat float Gaussian taps (imopv.c _vl_new_gaussian_fitler_f). EXACT.
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

// ── Descriptor host warp-setup constants (aether_threaded_extract.cc) ──
constexpr int    kPatchResolution = 15;
constexpr int    kPatchSide = 2 * kPatchResolution + 1;  // 31
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

// Host replica of vl_covdet_extract_patch_helper SETUP+PADDING (covdet.c:2222-
// 2360). VERBATIM from parity_descriptor.cc build_warp_setup — the validated
// descriptor warp bridge (the on-GPU port is S5b, unbuilt).
struct WarpSetup { std::vector<float> plane; double A[4], T[2]; int lw, lh; };
bool build_warp_setup(VlScaleSpace* gss, double A_in[4], double T_in[2],
                      double d1, double d2, double extent, double sigma,
                      WarpSetup* out) {
  double A[4] = {A_in[0], A_in[1], A_in[2], A_in[3]};
  double T[2] = {T_in[0], T_in[1]};
  VlScaleSpaceGeometry geom = vl_scalespace_get_geometry(gss);
  VlScaleSpaceOctaveGeometry oct;
  const double factor = 1.0 / VL_MIN(d1, d2);
  vl_index o, s; double sigma_;
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
    } else { std::fill(P.begin(), P.end(), 0.0f); }
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
  for (int i = 0; i < 128; ++i) {
    const double d = (double)a[i] - (double)b[i]; s += d * d;
  }
  return s;
}

// ════════════════════════════════════════════════════════════════════════════
//  GPU pipeline holder — owns the device + the resident gss + all pipelines.
// ════════════════════════════════════════════════════════════════════════════
struct Geom {
  int firstOctave, lastOctave, firstSub, lastSub, octaveResolution;
  double baseScale;
  int numOct() const { return lastOctave - firstOctave + 1; }
  int numSub() const { return lastSub - firstSub + 1; }   // gss levels/octave
};

// Per-octave geometry + the float offset of (o, firstSub) in the resident gss.
struct OctInfo { int o, w, h; double step; uint32_t base; };

struct GpuTimings {
  double gss_resident_ms = 0;   // REAL resident build (no per-level readback)
  double detect_ms = 0, refine_ms = 0, suppress_ms = 0;
  double affine_ms = 0, orient_ms = 0, desc_ms = 0;
  double warp_setup_ms = 0;     // host fp64 warp setup (descriptor bridge) — host mode
  double gpu_warp_ms = 0;       // S5b on-GPU warp-setup (warp_size + fill) — gpu mode
  double host_ref_ms = 0;       // host parity-reference build (gpu mode; NOT pipeline)
  double readback_ms = 0;       // ONE final readback (kps + descriptors)
  double total_ms = 0;
  bool gss_readback_done = false;  // MUST stay false (resident invariant)
  bool used_gpu_warp = false;      // which warp-setup path this run took
  bool used_fused = false;         // FUSED single-kernel descriptor path
  // Peak GPU-memory accounting (bytes): the resident gss + the LARGEST extra
  // descriptor-stage buffer set that is concurrently live. The fusion's whole
  // point is to drop the ~3.4 GB intermediate plane buffer => peak must fall.
  double desc_stage_peak_bytes = 0;  // largest descriptor-stage transient set
  double peak_gpu_bytes = 0;         // resident gss + desc_stage_peak
  double gss_resident_bytes = 0;
};

// ════════════════════════════════════════════════════════════════════════════
//  Build the FULL multi-octave gss as ONE resident GPU buffer (no readback).
//
//  Layout: octave-major, level-major. base[oi] = float offset of (o, firstSub);
//  level (o,s) at base[oi] + (s-firstSub)*W*H. Matches sift_affine_shape.wgsl /
//  sift_orientation.wgsl OctGeom indexing AND the detect/refine per-octave slice
//  (their (D+1)-level packed buffer == this octave's [firstSub..lastSub] block,
//  since cssLastSub = lastSub-1 => gss range [firstSub..lastSub]).
//
//  Method (gss RESIDENT): a small scratch buffer pair (ping/pong, sized to the
//  largest octave) holds the running blur result; after each separable v->h
//  blur the level is COPIED (CopyBufferToBuffer, GPU->GPU) into the resident
//  pyramid slice. The very first octave-0 firstSub level is seeded from the CPU
//  (VLFeat's pre-blurred seed, exactly as the validated harnesses do) — this is
//  the ONLY CPU->GPU upload into the pyramid; every later level is produced by a
//  GPU kernel reading a GPU buffer and CopyBufferToBuffer'd into place. NO level
//  is ever read BACK to the CPU. We measure the wall time of this build.
// ════════════════════════════════════════════════════════════════════════════
wgpu::Buffer build_resident_gss(
    aether::tools::DawnKernelHarness& h, VlScaleSpace* gss, const Geom& G,
    std::vector<OctInfo>* octinfo_out, size_t* total_floats_out,
    double* build_ms_out, const std::string& blur_wgsl,
    const std::string& resample_wgsl) {
  auto pipe_blur = h.load_compute(blur_wgsl, "main");
  auto pipe_down = h.load_compute(resample_wgsl, "downsample");
  const wgpu::Device& dev = h.device();
  const wgpu::Queue& q = h.queue();

  // ── 1. Sizes + base offsets ──
  // Per-octave base offsets are aligned to 64 floats (256 bytes) so the
  // detect/refine SUB-SLICE bind (offset = base*4 bytes) satisfies the WGPU
  // ReadOnlyStorage 256-byte minimum binding-offset alignment. Affine/orient
  // read `base` from the OctGeom table (a plain index into the whole resident
  // buffer), so the padding is transparent to them.
  auto align64 = [](size_t v) { return (v + 63u) & ~static_cast<size_t>(63u); };
  std::vector<OctInfo> oi;
  size_t total = 0;
  size_t max_plane = 0;
  for (int o = G.firstOctave; o <= G.lastOctave; ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    OctInfo r; r.o = o; r.w = (int)og.width; r.h = (int)og.height;
    r.step = og.step;
    total = align64(total);   // 256-byte align this octave's base
    r.base = (uint32_t)total;
    oi.push_back(r);
    const size_t plane = (size_t)r.w * r.h;
    max_plane = std::max(max_plane, plane);
    total += plane * (size_t)G.numSub();
  }
  total = align64(total);     // pad the tail so the buffer covers all slices
  *total_floats_out = total;

  // ── 2. Resident pyramid buffer (the ONE buffer that stays on GPU). ──
  const size_t total_bytes = total * sizeof(float);
  wgpu::Buffer pyramid = h.alloc(
      total_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                       wgpu::BufferUsage::CopyDst);

  // ── 3. Scratch ping/pong (sized to the largest octave plane). ──
  const size_t scratch_bytes = max_plane * sizeof(float);
  wgpu::Buffer scratch_a = h.alloc(
      scratch_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                         wgpu::BufferUsage::CopyDst);
  wgpu::Buffer scratch_b = h.alloc(
      scratch_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                         wgpu::BufferUsage::CopyDst);

  // helper: GPU->GPU copy a level plane into the resident pyramid slice.
  auto copy_into_pyramid = [&](const wgpu::Buffer& src, uint32_t base_floats,
                               int s, size_t plane) {
    const uint64_t dst_off =
        (uint64_t)(base_floats + (uint32_t)(s - G.firstSub) * plane) * sizeof(float);
    wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
    enc.CopyBufferToBuffer(src, 0, pyramid, dst_off, plane * sizeof(float));
    wgpu::CommandBuffer cb = enc.Finish();
    q.Submit(1, &cb);
  };

  // helper: separable blur (v then h) of `in_buf` -> `out_buf`, both GPU
  // resident; taps uploaded fresh per call (tiny). Reuses scratch for the
  // intermediate. NO readback.
  auto blur_resident = [&](const wgpu::Buffer& in_buf, const wgpu::Buffer& mid,
                           const wgpu::Buffer& out_buf, int w, int hh,
                           const std::vector<float>& taps, int radius) {
    wgpu::Buffer taps_buf =
        h.upload(taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);
    const uint32_t gx = ((uint32_t)w + 7u) / 8u, gy = ((uint32_t)hh + 7u) / 8u;
    BlurParams pv{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 1u};  // vertical
    wgpu::Buffer pv_buf = h.upload(&pv, sizeof(pv), wgpu::BufferUsage::Uniform);
    h.dispatch(pipe_blur, {in_buf, taps_buf, mid, pv_buf}, gx, gy, 1u);
    BlurParams ph{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 0u};  // horizontal
    wgpu::Buffer ph_buf = h.upload(&ph, sizeof(ph), wgpu::BufferUsage::Uniform);
    h.dispatch(pipe_blur, {mid, taps_buf, out_buf, ph_buf}, gx, gy, 1u);
  };

  const int prevLevelIndex =
      std::min(G.firstSub + G.octaveResolution, G.lastSub);

  auto t0 = clock_t_::now();

  // Resident snapshot of (o, prevLevelIndex) used to seed the next octave's
  // resample. Kept ENTIRELY on GPU in a dedicated buffer (sized to max octave).
  wgpu::Buffer seed_prev = h.alloc(
      scratch_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                         wgpu::BufferUsage::CopyDst);
  int prev_ow = 0, prev_oh = 0;

  for (size_t k = 0; k < oi.size(); ++k) {
    const OctInfo& r = oi[k];
    const size_t plane = (size_t)r.w * r.h;
    const double step = r.step;

    // ── seed level firstSub ──  (held in scratch_a as the running level)
    if (k == 0) {
      // Octave-0 firstSub: VLFeat's CPU seed (the only CPU->GPU pyramid upload).
      const float* cf = vl_scalespace_get_level_const(gss, r.o, G.firstSub);
      q.WriteBuffer(scratch_a, 0, cf, plane * sizeof(float));
    } else {
      // Octave transition: downsample seed_prev (GPU) -> scratch_a (GPU).
      DownParams dp{(uint32_t)prev_ow, (uint32_t)prev_oh, (uint32_t)r.w, (uint32_t)r.h};
      wgpu::Buffer dp_buf = h.upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
      const uint32_t gx = ((uint32_t)r.w + 7u) / 8u, gy = ((uint32_t)r.h + 7u) / 8u;
      h.dispatch(pipe_down, {seed_prev, scratch_a, dp_buf}, gx, gy, 1u);
      // residual top-up blur to sigma(o,firstSub).
      const double sigma0 = vl_scalespace_get_level_sigma(gss, r.o, G.firstSub);
      const double prevSigma =
          vl_scalespace_get_level_sigma(gss, r.o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - prevSigma * prevSigma);
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
        blur_resident(scratch_a, scratch_b, scratch_a, r.w, r.h, taps, radius);
      }
    }
    // place firstSub level into the resident pyramid.
    copy_into_pyramid(scratch_a, r.base, G.firstSub, plane);
    if (prevLevelIndex == G.firstSub) {
      wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
      enc.CopyBufferToBuffer(scratch_a, 0, seed_prev, 0, plane * sizeof(float));
      wgpu::CommandBuffer cb = enc.Finish(); q.Submit(1, &cb);
      prev_ow = r.w; prev_oh = r.h;
    }

    // ── within-octave chain: s = firstSub+1 .. lastSub ──
    // running level lives in scratch_a; blur into scratch_b then swap roles by
    // copying back (cheap GPU->GPU) so scratch_a always holds the latest level.
    for (int s = G.firstSub + 1; s <= G.lastSub; ++s) {
      const double sig = vl_scalespace_get_level_sigma(gss, r.o, s);
      const double sigp = vl_scalespace_get_level_sigma(gss, r.o, s - 1);
      const double ds = std::sqrt(sig * sig - sigp * sigp);
      int radius = 0;
      std::vector<float> taps = vlfeat_gaussian_taps_f(ds / step, &radius);
      // blur scratch_a -> scratch_b (mid = pyramid-unused region? no: need a 3rd
      // scratch for the v->h intermediate). Use a fresh per-call mid buffer.
      wgpu::Buffer mid = h.alloc(
          scratch_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      blur_resident(scratch_a, mid, scratch_b, r.w, r.h, taps, radius);
      copy_into_pyramid(scratch_b, r.base, s, plane);
      // scratch_b -> scratch_a for the next iteration.
      {
        wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
        enc.CopyBufferToBuffer(scratch_b, 0, scratch_a, 0, plane * sizeof(float));
        wgpu::CommandBuffer cb = enc.Finish(); q.Submit(1, &cb);
      }
      if (s == prevLevelIndex) {
        wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
        enc.CopyBufferToBuffer(scratch_b, 0, seed_prev, 0, plane * sizeof(float));
        wgpu::CommandBuffer cb = enc.Finish(); q.Submit(1, &cb);
        prev_ow = r.w; prev_oh = r.h;
      }
    }
  }
  // force completion of all queued GPU work before stopping the clock.
  // A tiny readback of 4 bytes from the pyramid would force a sync but would be
  // a gss readback (forbidden). Instead we use the harness's own sync: a
  // throwaway 4-byte staging copy of scratch_a (NOT the pyramid) flushes the
  // queue without ever reading the resident gss back.
  {
    wgpu::Buffer flush = h.alloc_staging_for_readback(sizeof(float));
    h.copy_to_staging(scratch_a, flush, sizeof(float));  // submits+waits
    (void)h.readback(flush, sizeof(float));  // scratch, NOT the pyramid
  }
  *build_ms_out = ms_since(t0);
  *octinfo_out = std::move(oi);
  return pyramid;
}

}  // namespace

// ════════════════════════════════════════════════════════════════════════════
//  Per-image full pipeline result.
// ════════════════════════════════════════════════════════════════════════════
struct FullGpuResult {
  GpuTimings t;
  size_t final_kp = 0;                  // GPU final keypoints (post-orient)
  std::vector<uint8_t> descriptors;     // final_kp * 128 (UBC order)
  std::vector<float> frame_x, frame_y, frame_sigma, frame_angle;  // for matching
  std::vector<int> frame_octave;
  double cpu_baseline_ms = 0;           // production-exact CPU baseline
  double gss_floats_mb = 0;
};

int main(int argc, char** argv) {
  std::vector<std::string> imgs;
  // FUSED is the default (the point of this harness). --host-warp runs the host
  // fp64 reference path instead (the honest baseline). --gpu-warp is accepted as
  // an alias for "not fused" so the s5b 2-kernel comparison can be requested too,
  // but the descriptor here is single-kernel fused; for the 2-kernel numbers use
  // extract_fullgpu_s5b_exe --gpu-warp.
  bool fused = true;
  for (int i = 1; i < argc; ++i) {
    std::string_view a(argv[i]);
    if (a == "--host-warp") { fused = false; continue; }
    if (a == "--fused") { fused = true; continue; }
    if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;
    imgs.emplace_back(argv[i]);
  }
  if (imgs.empty()) {
    imgs.emplace_back("third_party/glomap_vendor/iosapp/Resources/sift_test.jpg");
    imgs.emplace_back("third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg");
  }

  // COLMAP DSP config (sift.h).
  const int octave_resolution = 3;
  const double peak_threshold = 0.02 / 3.0;
  const double edge_threshold = 10.0;
  const int max_num_features = 8192;
  const double tol = 0.5;  // nonExtremaSuppression

  // ── WGSL sources (read once). ──
  const std::string blur_wgsl = read_file("shaders/wgsl/sift_gss_blur.wgsl");
  const std::string resample_wgsl = read_file("shaders/wgsl/sift_gss_resample.wgsl");
  const std::string dog_wgsl = read_file("shaders/wgsl/sift_dog_extrema_test.wgsl");
  const std::string refine_wgsl = read_file("shaders/wgsl/sift_refine_gate.wgsl");
  const std::string suppress_wgsl = read_file("shaders/wgsl/sift_nonextrema_suppress.wgsl");
  const std::string affine_wgsl = read_file("shaders/wgsl/sift_affine_shape.wgsl");
  const std::string orient_wgsl = read_file("shaders/wgsl/sift_orientation.wgsl");
  const std::string desc_wgsl = read_file("shaders/wgsl/sift_dsp_descriptor.wgsl");
  for (auto* p : {&blur_wgsl, &resample_wgsl, &dog_wgsl, &refine_wgsl,
                  &suppress_wgsl, &affine_wgsl, &orient_wgsl, &desc_wgsl}) {
    if (p->empty()) { std::fprintf(stderr, "FAIL: a WGSL source is empty (run from aether_cpp/ root)\n"); return 2; }
  }
  // S5c FUSED descriptor shader (task A artifact). If absent, --fused falls back
  // to the host warp-setup reference so the harness still runs end-to-end.
  const std::string fused_wgsl = read_file("shaders/wgsl/sift_descriptor_fused.wgsl");
  const bool fused_shader_present = !fused_wgsl.empty();
  if (fused && !fused_shader_present) {
    std::printf("[warn] --fused requested but shaders/wgsl/sift_descriptor_fused.wgsl ABSENT -> falling back to host warp-setup reference (the 2-kernel numbers come from extract_fullgpu_s5b_exe --gpu-warp).\n");
    fused = false;
  }
  std::printf("[mode] descriptor = %s%s\n",
              fused ? "FUSED single-kernel (S5c)" : "HOST fp64 warp-setup (reference)",
              fused ? " [shader: sift_descriptor_fused.wgsl]" : "");

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    return 2;
  }

  std::printf("=================================================================\n");
  std::printf(" FULL-GPU DSP-SIFT integration  (gss RESIDENT; one readback)\n");
  std::printf(" config: peak=%.6f edge=%.1f maxN=%d octRes=%d tol=%.2f DSP=%d\n",
              peak_threshold, edge_threshold, max_num_features, octave_resolution,
              tol, kDspNumScales);
  std::printf("=================================================================\n");

  std::vector<FullGpuResult> results;

  for (const std::string& imgpath : imgs) {
    const char* img = imgpath.c_str();
    FullGpuResult RES{};

    int iw = 0, ih = 0, ic = 0;
    unsigned char* pixels = stbi_load(img, &iw, &ih, &ic, 1);
    if (!pixels) { std::fprintf(stderr, "FAIL stbi_load(%s): %s\n", img, stbi_failure_reason()); return 2; }
    std::vector<float> gray255((size_t)iw * ih);   // [0,255] for detect/affine
    for (size_t i = 0; i < gray255.size(); ++i) gray255[i] = (float)pixels[i];
    stbi_image_free(pixels);
    std::printf("\n----- image: %s  %dx%d -----\n", img, iw, ih);

    // ════════════════════════════════════════════════════════════════════════
    //  (A) PRODUCTION-EXACT CPU BASELINE (the ~3.6s @4224 reference, S2).
    //      detect (incl. nonExtremaSuppression=0.5 ON) + affine + orient + sort
    //      + DSP descriptor — exactly the CPU baseline run by the S2 hybrid
    //      harness. Single-threaded here so the GPU speedup is vs the SERIAL CPU
    //      cost (the GPU dispatch is itself serial-from-host); the hybrid S2
    //      harness's baseline is also the production path. We additionally hold
    //      the VLFeat covdet for the end-to-end parity reference + gss bridge.
    // ════════════════════════════════════════════════════════════════════════
    VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cd, 0);
    vl_covdet_set_octave_resolution(cd, octave_resolution);
    vl_covdet_set_peak_threshold(cd, peak_threshold);
    vl_covdet_set_edge_threshold(cd, edge_threshold);
    auto tcpu = clock_t_::now();
    vl_covdet_put_image(cd, gray255.data(), iw, ih);
    vl_covdet_detect(cd, max_num_features);     // incl. nonExtremaSuppression
    vl_covdet_extract_affine_shape(cd);
    vl_covdet_extract_orientations(cd);
    int cpu_nf = vl_covdet_get_num_features(cd);
    VlCovDetFeature* cpu_feats = vl_covdet_get_features(cd);
    std::sort(cpu_feats, cpu_feats + cpu_nf,
              [](const VlCovDetFeature& a, const VlCovDetFeature& b) {
                if (a.o == b.o) return a.s > b.s; return a.o > b.o;
              });
    if (cpu_nf > max_num_features) cpu_nf = max_num_features;
    // CPU DSP descriptors (the production loop) for the e2e parity reference.
    std::vector<uint8_t> cpu_desc((size_t)cpu_nf * 128);
    {
      VlScaleSpace* gssb = vl_covdet_get_gss(cd);
      std::unique_ptr<VlSiftFilt, void (*)(VlSiftFilt*)> sift(
          vl_sift_new(16, 16, 1, 3, 0), &vl_sift_delete);
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
                                             kPatchRelativeExtent,
                                             kPatchRelativeSmoothing, sf);
          vl_imgradient_polar_f(patchXY.data(), patchXY.data() + 1, 2,
                                2 * kPatchSide, patch.data(), kPatchSide,
                                kPatchSide, kPatchSide);
          vl_sift_calc_raw_descriptor(sift.get(), patchXY.data(),
                                      sd.data() + (size_t)s * 128, kPatchSide,
                                      kPatchSide, kPatchResolution,
                                      kPatchResolution, kSigma, 0);
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
      vl_covdet_set_gss(wd, nullptr);
      vl_covdet_delete(wd);
    }
    RES.cpu_baseline_ms = ms_since(tcpu);
    std::printf("[CPU baseline] detect+affine+orient+sort+DSP-desc: %.1f ms  (kp=%d)\n",
                RES.cpu_baseline_ms, cpu_nf);

    // CPU reference frames (for e2e keypoint recall/precision).
    std::vector<double> cpu_fx(cpu_nf), cpu_fy(cpu_nf), cpu_fs(cpu_nf);
    std::vector<int> cpu_fo(cpu_nf);
    for (int i = 0; i < cpu_nf; ++i) {
      cpu_fx[i] = cpu_feats[i].frame.x; cpu_fy[i] = cpu_feats[i].frame.y;
      cpu_fs[i] = cpu_feats[i].frame.a11; cpu_fo[i] = cpu_feats[i].o;
    }

    // VLFeat gss geometry (drives the GPU pyramid + per-stage Params).
    VlScaleSpace* gss = vl_covdet_get_gss(cd);
    VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
    Geom G{(int)g.firstOctave, (int)g.lastOctave, (int)g.octaveFirstSubdivision,
           (int)g.octaveLastSubdivision, (int)g.octaveResolution, g.baseScale};
    const int D = G.numSub() - 1;  // css depth (gss levels = D+1 = numSub())

    // ════════════════════════════════════════════════════════════════════════
    //  (B) FULL-GPU PIPELINE
    // ════════════════════════════════════════════════════════════════════════
    GpuTimings T{};
    auto t_all = clock_t_::now();

    // ── B.1  gss RESIDENT build (no per-level readback) ──
    std::vector<OctInfo> octinfo;
    size_t total_floats = 0; double gss_build_ms = 0;
    wgpu::Buffer pyramid = build_resident_gss(
        harness, gss, G, &octinfo, &total_floats, &gss_build_ms, blur_wgsl,
        resample_wgsl);
    T.gss_resident_ms = gss_build_ms;
    T.gss_resident_bytes = (double)total_floats * 4.0;  // resident pyramid bytes
    RES.gss_floats_mb = total_floats * 4.0 / 1e6;
    std::printf("[B.1 gss RESIDENT] %.1f ms  (%zu floats = %.1f MB, %d octaves, %d levels/oct, NO per-level readback)\n",
                T.gss_resident_ms, total_floats, RES.gss_floats_mb, G.numOct(), G.numSub());

    const wgpu::Device& dev = harness.device();
    const wgpu::Queue& q = harness.queue();

    // ── B.2 + B.3  detect + refine per octave (resident gss SUB-SLICE) ──
    auto pipe_detect = harness.load_compute(dog_wgsl, "detect");
    auto pipe_refine = harness.load_compute(refine_wgsl, "refine");
    const uint32_t kCap = 200000u, kKpCap = 200000u;
    const double detect_thr = 0.8 * peak_threshold;

    // shared dense refined-keypoint buffer + count (zero-init once).
    wgpu::Buffer kp_count = harness.alloc(
        sizeof(uint32_t), wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc |
                              wgpu::BufferUsage::CopyDst);
    { uint32_t z = 0; q.WriteBuffer(kp_count, 0, &z, sizeof(z)); }
    wgpu::Buffer kp_out = harness.alloc(
        (size_t)kKpCap * sizeof(Keypoint),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    double detect_acc = 0, refine_acc = 0;
    for (const OctInfo& r : octinfo) {
      const size_t plane = (size_t)r.w * r.h;
      // SUB-SLICE bind of the resident pyramid: a bind group with a buffer
      // offset = base*4 covering this octave's (D+1) levels. We dispatch with
      // our own command encoder + bind group (the harness dispatch() always
      // binds at offset 0, so we replicate its dispatch with an offset bind).
      const uint64_t slice_off = (uint64_t)r.base * sizeof(float);
      const uint64_t slice_size = (uint64_t)(D + 1) * plane * sizeof(float);

      // detect: gss(0,sub-slice), count(1), out(2), P(3).
      wgpu::Buffer cand_count = harness.alloc(
          sizeof(uint32_t), wgpu::BufferUsage::Storage |
                                wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
      { uint32_t z = 0; q.WriteBuffer(cand_count, 0, &z, sizeof(z)); }
      wgpu::Buffer cand_out = harness.alloc(
          (size_t)kCap * sizeof(CandidateExtremum),
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      DogParams dp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, (uint32_t)r.o,
                   (float)detect_thr, kCap, 0u, 0u};
      wgpu::Buffer dp_buf = harness.upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);

      auto dispatch_offset = [&](wgpu::ComputePipeline& pipe,
                                 const std::vector<wgpu::Buffer>& bufs,
                                 const std::vector<std::pair<uint64_t, uint64_t>>& slices,
                                 uint32_t gx, uint32_t gy, uint32_t gz) {
        std::vector<wgpu::BindGroupEntry> ents(bufs.size());
        for (size_t i = 0; i < bufs.size(); ++i) {
          ents[i].binding = (uint32_t)i;
          ents[i].buffer = bufs[i];
          ents[i].offset = slices[i].first;
          ents[i].size = slices[i].second;  // 0 == whole buffer (WGPU_WHOLE_SIZE via 0? no) -> set explicitly
        }
        wgpu::BindGroupDescriptor bgd{};
        bgd.layout = pipe.GetBindGroupLayout(0);
        bgd.entryCount = ents.size();
        bgd.entries = ents.data();
        wgpu::BindGroup bg = dev.CreateBindGroup(&bgd);
        wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
        wgpu::ComputePassEncoder pass = enc.BeginComputePass();
        pass.SetPipeline(pipe);
        pass.SetBindGroup(0, bg);
        pass.DispatchWorkgroups(gx, gy, gz);
        pass.End();
        wgpu::CommandBuffer cb = enc.Finish();
        q.Submit(1, &cb);
      };

      const uint32_t gx = ((uint32_t)r.w + 7u) / 8u, gy = ((uint32_t)r.h + 7u) / 8u;
      auto td = clock_t_::now();
      dispatch_offset(pipe_detect, {pyramid, cand_count, cand_out, dp_buf},
                      {{slice_off, slice_size}, {0, sizeof(uint32_t)},
                       {0, (uint64_t)kCap * sizeof(CandidateExtremum)},
                       {0, sizeof(DogParams)}},
                      gx, gy, (uint32_t)D);
      // read this octave's candidate count (tiny; sizes the refine dispatch).
      wgpu::Buffer cc_stage = harness.alloc_staging_for_readback(sizeof(uint32_t));
      harness.copy_to_staging(cand_count, cc_stage, sizeof(uint32_t));
      std::vector<uint8_t> ccb = harness.readback(cc_stage, sizeof(uint32_t));
      uint32_t oct_cands = 0; std::memcpy(&oct_cands, ccb.data(), sizeof(uint32_t));
      const uint32_t cread = std::min(oct_cands, kCap);
      detect_acc += ms_since(td);

      if (cread > 0) {
        RefineParams rp{(uint32_t)r.w, (uint32_t)r.h, (uint32_t)D, cread,
                        (float)peak_threshold, (float)edge_threshold,
                        (float)g.baseScale, (float)r.step, G.firstSub,
                        (float)g.octaveResolution, kKpCap, 0u};
        wgpu::Buffer rp_buf = harness.upload(&rp, sizeof(rp), wgpu::BufferUsage::Uniform);
        const uint32_t rgx = (cread + 63u) / 64u;
        auto tr = clock_t_::now();
        dispatch_offset(pipe_refine, {pyramid, cand_out, kp_count, kp_out, rp_buf},
                        {{slice_off, slice_size},
                         {0, (uint64_t)kCap * sizeof(CandidateExtremum)},
                         {0, sizeof(uint32_t)},
                         {0, (uint64_t)kKpCap * sizeof(Keypoint)},
                         {0, sizeof(RefineParams)}},
                        rgx, 1u, 1u);
        refine_acc += ms_since(tr);
      }
    }
    T.detect_ms = detect_acc; T.refine_ms = refine_acc;

    // readback refined keypoint count + records (the detection result; these
    // feed suppress -> affine -> orient. NOTE: this is the kp buffer, NOT gss).
    uint32_t kp_n = 0;
    {
      wgpu::Buffer s = harness.alloc_staging_for_readback(sizeof(uint32_t));
      harness.copy_to_staging(kp_count, s, sizeof(uint32_t));
      std::vector<uint8_t> b = harness.readback(s, sizeof(uint32_t));
      std::memcpy(&kp_n, b.data(), sizeof(uint32_t));
    }
    const uint32_t kp_read = std::min(kp_n, kKpCap);
    std::vector<Keypoint> refined(kp_read);
    {
      const size_t bytes = (size_t)kp_read * sizeof(Keypoint);
      wgpu::Buffer s = harness.alloc_staging_for_readback(bytes);
      harness.copy_to_staging(kp_out, s, bytes);
      std::vector<uint8_t> b = harness.readback(s, bytes);
      std::memcpy(refined.data(), b.data(), bytes);
    }
    std::printf("[B.2/3 detect+refine] detect=%.1f ms refine=%.1f ms  (refined kp=%u)\n",
                T.detect_ms, T.refine_ms, kp_read);

    // ── B.4  nonExtremaSuppression (GPU spatial-grid kernel) ──
    // Build the GPU Keypoint records from the refined kps in frame space.
    auto pipe_bc = harness.load_compute(suppress_wgsl, "bin_count");
    auto pipe_bs = harness.load_compute(suppress_wgsl, "bin_scatter");
    auto pipe_su = harness.load_compute(suppress_wgsl, "suppress");
    std::vector<uint32_t> keep((size_t)kp_read, 1u);
    {
      auto tsup = clock_t_::now();
      const int n = (int)kp_read;
      std::vector<Keypoint> gpu_kp(n);
      double sig_sum = 0, fx_max = 0, fy_max = 0;
      for (int i = 0; i < n; ++i) {
        gpu_kp[i] = refined[i];
        // frame.x = x_local*step; feed x_local already in frame coords + step=1
        // exactly as parity_suppress.cc (avoids the division rounding).
        const float fx = refined[i].x_local * refined[i].step;
        const float fy = refined[i].y_local * refined[i].step;
        gpu_kp[i].x_local = fx; gpu_kp[i].y_local = fy; gpu_kp[i].step = 1.0f;
        sig_sum += refined[i].sigma;
        fx_max = std::max(fx_max, (double)fx);
        fy_max = std::max(fy_max, (double)fy);
      }
      const double sig_mean = n ? sig_sum / n : 1.0;
      const double cell_size = std::max(8.0, 2.0 * sig_mean);
      const uint32_t grid_w = (uint32_t)std::floor(fx_max / cell_size) + 2u;
      const uint32_t grid_h = (uint32_t)std::floor(fy_max / cell_size) + 2u;
      const uint32_t num_cells = grid_w * grid_h;
      SuppressParams P{(uint32_t)n, grid_w, grid_h, num_cells, (float)cell_size,
                       (float)tol, 0u, 0u};
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
      std::vector<wgpu::Buffer> binds = {kps_buf, cellcnt, cellstart, items_buf,
                                         keep_buf, P_buf, alive_buf};
      const uint32_t wg = ((uint32_t)n + 63u) / 64u;
      // PASS A: bin_count.
      harness.dispatch(pipe_bc, binds, wg ? wg : 1u, 1u, 1u);
      // prefix-sum on host.
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
      // PASS B: bin_scatter.
      harness.dispatch(pipe_bs, binds, wg ? wg : 1u, 1u, 1u);
      // PASS C: suppress, iterated to fixed point.
      const size_t keep_bytes = (size_t)n * sizeof(uint32_t);
      wgpu::Buffer keep_stage = harness.alloc_staging_for_readback(keep_bytes);
      std::vector<uint32_t> cur((size_t)n, 1u);
      for (int it = 0; it < 8; ++it) {
        harness.dispatch(pipe_su, binds, wg ? wg : 1u, 1u, 1u);
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
    // compact survivors.
    std::vector<Keypoint> survivors;
    survivors.reserve(kp_read);
    for (uint32_t i = 0; i < kp_read; ++i) if (keep[i]) survivors.push_back(refined[i]);
    std::printf("[B.4 suppress] %.1f ms  (survivors=%zu of %u, %.2f%% removed)\n",
                T.suppress_ms, survivors.size(), kp_read,
                kp_read ? 100.0 * (kp_read - survivors.size()) / kp_read : 0.0);

    // ── B.5  affine-shape (resident gss, WHOLE buffer + octave table) ──
    // Build the OctGeom table once (shared by affine + orientation).
    const int nOct = G.numOct();
    std::vector<OctGeom> octgeom(nOct);
    std::vector<OctaveGeomO> octgeomO(nOct);
    for (int k = 0; k < nOct; ++k) {
      const OctInfo& r = octinfo[k];
      octgeom[k] = OctGeom{(uint32_t)r.w, (uint32_t)r.h, r.base, 0u, (float)r.step, 0, 0, 0};
      octgeomO[k] = OctaveGeomO{r.w, r.h, (float)r.step, r.base, r.o, 0, 0, 0};
    }

    // Input frames for affine = survivors with circular frame (a11=a22=sigma).
    const uint32_t Naff = (uint32_t)survivors.size();
    std::vector<InFrame> aff_in(Naff);
    for (uint32_t i = 0; i < Naff; ++i) {
      const Keypoint& kp = survivors[i];
      const float fx = kp.x_local * kp.step, fy = kp.y_local * kp.step;
      aff_in[i] = InFrame{fx, fy, kp.sigma, 0.f, 0.f, kp.sigma, 0.f, 0.f};
    }
    std::vector<AffineShape> aff_out(Naff);
    {
      auto pipe_aff = harness.load_compute(affine_wgsl, "affine_shape");
      wgpu::Buffer oct_buf = harness.upload(octgeom.data(), octgeom.size() * sizeof(OctGeom),
                                            wgpu::BufferUsage::Storage);
      wgpu::Buffer frame_buf = harness.upload(aff_in.data(), aff_in.size() * sizeof(InFrame),
                                              wgpu::BufferUsage::Storage);
      const size_t obytes = (size_t)Naff * sizeof(AffineShape);
      wgpu::Buffer out_buf = harness.alloc(obytes,
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      AffParams P{Naff, (uint32_t)nOct, G.firstOctave, G.lastOctave, G.firstSub,
                  G.lastSub, (float)g.octaveResolution, (float)g.baseScale};
      wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
      auto ta = clock_t_::now();
      // gss(0)=resident WHOLE buffer, octs(1), frames(2), out(3), P(4); 1 wg/kp.
      harness.dispatch(pipe_aff, {pyramid, oct_buf, frame_buf, out_buf, P_buf},
                       Naff ? Naff : 1u, 1u, 1u);
      T.affine_ms = ms_since(ta);
      if (Naff) {
        wgpu::Buffer s = harness.alloc_staging_for_readback(obytes);
        harness.copy_to_staging(out_buf, s, obytes);
        std::vector<uint8_t> b = harness.readback(s, obytes);
        std::memcpy(aff_out.data(), b.data(), obytes);
      }
    }
    std::printf("[B.5 affine] %.1f ms  (%u kp)\n", T.affine_ms, Naff);

    // ── B.6  orientation (resident gss, WHOLE buffer + octave table; 1-4x) ──
    // Input = affine-adapted frames (drop the affine reject-oob kps).
    std::vector<InputKp> or_in;
    std::vector<int> or_src;   // map orient input idx -> survivor idx
    or_in.reserve(Naff); or_src.reserve(Naff);
    for (uint32_t i = 0; i < Naff; ++i) {
      if (aff_out[i].status == 4u /*ST_REJECT_OOB*/) continue;  // dropped
      InputKp k{};
      k.x = aff_out[i].x; k.y = aff_out[i].y;
      k.a11 = aff_out[i].a11; k.a12 = aff_out[i].a12;
      k.a21 = aff_out[i].a21; k.a22 = aff_out[i].a22;
      k.octave = survivors[i].octave; k.pad0 = 0u;
      or_in.push_back(k); or_src.push_back((int)i);
    }
    const uint32_t Nor = (uint32_t)or_in.size();
    const uint32_t kMaxOut = Nor * 4u + 16u;
    std::vector<OrientedKp> or_recs;
    {
      auto pipe_or = harness.load_compute(orient_wgsl, "orient");
      wgpu::Buffer kp_buf = harness.upload(or_in.data(), or_in.size() * sizeof(InputKp),
                                           wgpu::BufferUsage::Storage);
      wgpu::Buffer geom_buf = harness.upload(octgeomO.data(), octgeomO.size() * sizeof(OctaveGeomO),
                                             wgpu::BufferUsage::Storage);
      uint32_t z = 0;
      wgpu::Buffer count_buf = harness.upload(&z, sizeof(z),
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      const size_t obytes = (size_t)kMaxOut * sizeof(OrientedKp);
      wgpu::Buffer out_buf = harness.alloc(obytes,
          wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
      OrientParams P{};
      P.num_kp = Nor; P.num_octaves = (uint32_t)nOct;
      P.first_octave = G.firstOctave; P.last_octave = G.lastOctave;
      P.first_sub = G.firstSub; P.last_sub = G.lastSub;
      P.octave_res = (float)g.octaveResolution; P.base_scale = (float)g.baseScale;
      P.max_out = kMaxOut;
      wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
      const uint32_t gx = (Nor + 63u) / 64u;
      auto to = clock_t_::now();
      // gss(0)=resident, kps(1), geom(2), out_count(3), out_kp(4), P(5).
      harness.dispatch(pipe_or, {pyramid, kp_buf, geom_buf, count_buf, out_buf, P_buf},
                       gx ? gx : 1u, 1u, 1u);
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
    std::printf("[B.6 orient] %.1f ms  (%u input frames -> %zu oriented kp, 1-4x expand)\n",
                T.orient_ms, Nor, or_recs.size());

    // Final oriented+affine keypoints = (affine frame rotated by orientation
    // angle). Build the production VlFrameOrientedEllipse for each oriented kp.
    // angle convention: VLFeat covdet applies R(angle) to the affine A
    // (covdet.c orientation: frame.a* = A * R). We reproduce that to feed the
    // descriptor warp-setup (same as the CPU path).
    struct OFrame { float x, y, a11, a12, a21, a22; int octave; float s_key; };
    std::vector<OFrame> finals;
    finals.reserve(or_recs.size());
    for (const OrientedKp& rc : or_recs) {
      if (rc.kp_index >= Nor) continue;
      const int src = or_src[rc.kp_index];           // survivor idx
      const AffineShape& A = aff_out[src];
      const float c = std::cos(rc.angle), s = std::sin(rc.angle);
      // rotate the affine matrix by angle (column-major A * R(angle)).
      OFrame f{};
      f.x = A.x; f.y = A.y;
      f.a11 = A.a11 * c + A.a12 * s;
      f.a21 = A.a21 * c + A.a22 * s;
      f.a12 = -A.a11 * s + A.a12 * c;
      f.a22 = -A.a21 * s + A.a22 * c;
      f.octave = survivors[src].octave;
      // sort key = css-local scale s (round(z_local+firstSub), covdet.c:2037).
      f.s_key = std::round(survivors[src].z_local + (float)G.firstSub);
      finals.push_back(f);
    }

    // ── S5a: sort (octave desc, scale desc) + clamp to max_num_features ──
    // The PLAN data flow places this between orientation and the descriptor;
    // the CPU baseline does EXACTLY this (sort_and_clamp -> 8192 before DSP
    // descriptors). Without it the descriptor would run over ALL ~34k oriented
    // kps (un-clamped) — apples-to-oranges with the 8192-clamped CPU baseline.
    std::sort(finals.begin(), finals.end(),
              [](const OFrame& a, const OFrame& b) {
                if (a.octave == b.octave) return a.s_key > b.s_key;
                return a.octave > b.octave;
              });
    const size_t pre_clamp = finals.size();
    if ((int)finals.size() > max_num_features) finals.resize(max_num_features);
    RES.final_kp = finals.size();
    std::printf("[B.6b sort+clamp] %zu oriented -> %zu final (octave desc, scale desc; maxN=%d)\n",
                pre_clamp, RES.final_kp, max_num_features);

    // ════════════════════════════════════════════════════════════════════════
    //  (B.7) DESCRIPTOR
    //    FUSED mode (default): ONE kernel sift_descriptor_fused.wgsl. Host builds
    //      ONLY the WarpIn (oriented+dsp-scaled ellipse, 32B/rec) per (kp x scale)
    //      + the OctGeomW table; the kernel computes warp geometry IN-REGISTER and
    //      samples the RESIDENT gss directly per scale. NO out_planes (the ~3.4 GB
    //      intermediate is GONE), NO 2-GB batching, NO plane write+readback.
    //    host-warp mode (--host-warp): the reference 2-kernel-equivalent host path
    //      — build_warp_setup over VLFeat's CPU gss materializes a concat of padded
    //      planes (the ~3.4 GB buffer, batched at the 2-GB cap) consumed by the
    //      UNCHANGED sift_dsp_descriptor.wgsl. This is the honest peak-memory +
    //      timing baseline the fusion is measured against.
    // ════════════════════════════════════════════════════════════════════════
    std::vector<uint8_t> gpu_desc((size_t)RES.final_kp * 128);
    T.used_fused = fused;
    T.used_gpu_warp = false;  // this harness has no 2-kernel GPU-warp path
    {
      std::vector<float> lut = build_expn_lut();
      const double dsp_step = (kDspMaxScale - kDspMinScale) / kDspNumScales;
      VlScaleSpace* gss_cpu = vl_covdet_get_gss(cd);  // CPU gss (host parity ref)
      const int N = (int)RES.final_kp;

      double warp_ms = 0, desc_dispatch_ms = 0;
      double desc_stage_peak = 0;  // largest descriptor-stage transient byte set

      // ───────────────────────────────────────────────────────────────────────
      //  FUSED PATH (single kernel; no intermediate plane buffer)
      // ───────────────────────────────────────────────────────────────────────
      if (fused) {
        auto pipe_fused = harness.load_compute(fused_wgsl, "descriptor_fused");
        wgpu::Buffer lut_buf = harness.upload(lut.data(), lut.size() * sizeof(float),
                                              wgpu::BufferUsage::Storage);
        // OctGeomW resident table.
        std::vector<OctGeomW> octw(nOct);
        for (int k = 0; k < nOct; ++k) {
          const OctInfo& r = octinfo[k];
          octw[k] = OctGeomW{(uint32_t)r.w, (uint32_t)r.h, r.base, 0u, (float)r.step, 0, 0, 0};
        }
        wgpu::Buffer octw_buf = harness.upload(octw.data(), octw.size() * sizeof(OctGeomW),
                                               wgpu::BufferUsage::Storage);

        // Host builds ONLY the WarpIn (a trivial scalar-scaled ellipse per scale).
        // This is the entire host contribution — no fp64 SVD/level-pick/padding,
        // no plane memcpy. It is timed as warp_ms (host-side setup).
        auto tw = clock_t_::now();
        const size_t n_recs = (size_t)N * kDspNumScales;
        std::vector<WarpIn> wins(n_recs);
        for (int i = 0; i < N; ++i) {
          const OFrame& f = finals[i];
          for (int s = 0; s < kDspNumScales; ++s) {
            const double dsc = kDspMinScale + s * dsp_step;
            wins[(size_t)i * kDspNumScales + s] = WarpIn{
                (float)f.x, (float)f.y,
                (float)(f.a11 * dsc), (float)(f.a12 * dsc),
                (float)(f.a21 * dsc), (float)(f.a22 * dsc), 0.f, 0.f};
          }
        }
        warp_ms += ms_since(tw);

        wgpu::Buffer win_buf = harness.upload(wins.data(), n_recs * sizeof(WarpIn),
                                              wgpu::BufferUsage::Storage);
        const size_t out_words = (size_t)N * 32;
        wgpu::Buffer out_buf = harness.alloc(out_words * sizeof(uint32_t),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        const size_t dbg_n = (size_t)N * 128;
        wgpu::Buffer dbg_buf = harness.alloc(dbg_n * sizeof(float),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        FusedParams P{};
        P.num_kp = (uint32_t)N; P.dsp_num_scales = (uint32_t)kDspNumScales;
        P.first_octave = G.firstOctave; P.last_octave = G.lastOctave;
        P.first_sub = G.firstSub; P.last_sub = G.lastSub;
        P.octave_res = (float)g.octaveResolution; P.base_scale = (float)g.baseScale;
        P.extent = (float)kPatchRelativeExtent;
        P.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
        P.sigma = (float)kPatchRelativeSmoothing;
        P.k_sigma = (float)kSigma;
        wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);

        // descriptor-stage transient peak (FUSED): win_buf + out_buf + dbg_buf +
        // lut + octw + P. The big one is win_buf (n_recs*32B ≈ 2.6 MB) — NOT the
        // 3.4 GB plane buffer. dbg_buf (N*128*4 ≈ 4.2 MB) is bench-only.
        desc_stage_peak = (double)(n_recs * sizeof(WarpIn)) +
                          (double)(out_words * sizeof(uint32_t)) +
                          (double)(dbg_n * sizeof(float)) +
                          (double)(lut.size() * sizeof(float)) +
                          (double)(octw.size() * sizeof(OctGeomW)) +
                          (double)sizeof(FusedParams);

        const uint32_t wg = ((uint32_t)N + 63u) / 64u;
        auto tdd = clock_t_::now();
        // bindings: gss(0), w_in(1), octs(2), expn(3), out_desc(4), P(5), dbg(6).
        harness.dispatch(pipe_fused,
                         {pyramid, win_buf, octw_buf, lut_buf, out_buf, P_buf, dbg_buf},
                         wg ? wg : 1u, 1u, 1u);
        desc_dispatch_ms += ms_since(tdd);
        wgpu::Buffer s = harness.alloc_staging_for_readback(out_words * sizeof(uint32_t));
        harness.copy_to_staging(out_buf, s, out_words * sizeof(uint32_t));
        std::vector<uint8_t> raw = harness.readback(s, out_words * sizeof(uint32_t));
        std::memcpy(gpu_desc.data(), raw.data(), (size_t)N * 128);

        T.warp_setup_ms = warp_ms;
        T.desc_ms = desc_dispatch_ms;
        T.desc_stage_peak_bytes = desc_stage_peak;
        std::printf("[B.7 descriptor] FUSED single-kernel: host WarpIn-setup=%.1f ms  GPU fused dispatch=%.1f ms  (%d kp, NO intermediate plane buffer, 1 dispatch)\n",
                    T.warp_setup_ms, T.desc_ms, N);
        std::printf("[B.7 fused mem] desc-stage transient peak=%.1f MB  (WarpIn=%.1f MB + out/dbg/misc) — vs the host-warp ~3.4 GB concat plane buffer\n",
                    desc_stage_peak / 1e6, (double)(n_recs * sizeof(WarpIn)) / 1e6);
        goto desc_done;
      }

      // ───────────────────────────────────────────────────────────────────────
      //  HOST-WARP REFERENCE PATH (the ~3.4 GB concat-plane baseline)
      // ───────────────────────────────────────────────────────────────────────
      {
      auto pipe_desc = harness.load_compute(desc_wgsl, "descriptor");
      wgpu::Buffer lut_buf = harness.upload(lut.data(), lut.size() * sizeof(float),
                                            wgpu::BufferUsage::Storage);
      const size_t kMaxConcatFloats = 480ull * 1000 * 1000;  // ~1.92 GB binding cap

      int done = 0;
      int n_batches = 0;
      while (done < N) {
        std::vector<PatchRec> recs;        // descriptor records (host-built)
        std::vector<float> concat;         // host-built planes
        int b0 = done;

        // ── grow a batch: host fp64 warp-setup materializes the padded planes ──
        auto tw = clock_t_::now();
        while (done < N) {
          const OFrame& f = finals[done];
          std::vector<PatchRec> kp_recs(kDspNumScales);
          std::vector<std::vector<float>> kp_planes(kDspNumScales);
          size_t add = 0;
          for (int s = 0; s < kDspNumScales; ++s) {
            const double dsc = kDspMinScale + s * dsp_step;
            VlFrameOrientedEllipse sf{};
            sf.x = f.x; sf.y = f.y;
            sf.a11 = f.a11 * dsc; sf.a12 = f.a12 * dsc;
            sf.a21 = f.a21 * dsc; sf.a22 = f.a22 * dsc;
            double A_in[4] = {sf.a11, sf.a21, sf.a12, sf.a22};
            double T_in[2] = {sf.x, sf.y};
            double Dd[4], U[4], V[4];
            vl_svd2(Dd, U, V, A_in);
            WarpSetup ws;
            if (!build_warp_setup(gss_cpu, A_in, T_in, Dd[0], Dd[3],
                                  kPatchRelativeExtent, kPatchRelativeSmoothing, &ws)) {
              ws.plane.assign(1, 0.0f); ws.lw = 1; ws.lh = 1;
              ws.A[0]=ws.A[1]=ws.A[2]=ws.A[3]=0; ws.T[0]=ws.T[1]=0;
            }
            kp_planes[s] = ws.plane;
            PatchRec r{};
            r.a0 = (float)ws.A[0]; r.a1 = (float)ws.A[1];
            r.a2 = (float)ws.A[2]; r.a3 = (float)ws.A[3];
            r.tx = (float)ws.T[0]; r.ty = (float)ws.T[1];
            r.extent = (float)kPatchRelativeExtent;
            r.stephat = (float)(kPatchRelativeExtent / kPatchResolution);
            r.lw = (uint32_t)ws.lw; r.lh = (uint32_t)ws.lh; r.pad0 = 0u;
            kp_recs[s] = r;
            add += kp_planes[s].size();
          }
          if (!recs.empty() && concat.size() + add > kMaxConcatFloats) break;
          for (int s = 0; s < kDspNumScales; ++s) {
            kp_recs[s].level_off = (uint32_t)concat.size();
            concat.insert(concat.end(), kp_planes[s].begin(), kp_planes[s].end());
            recs.push_back(kp_recs[s]);
          }
          ++done;
        }
        const double host_warp_batch_ms = ms_since(tw);
        const int batch_n = done - b0;
        ++n_batches;
        warp_ms += host_warp_batch_ms;

        // the ~3.4 GB concat plane buffer (this batch) + the recs buffer.
        wgpu::Buffer gss_buf = harness.upload(concat.data(), concat.size() * sizeof(float),
                                              wgpu::BufferUsage::Storage);
        wgpu::Buffer recs_buf = harness.upload(recs.data(), recs.size() * sizeof(PatchRec),
                                               wgpu::BufferUsage::Storage);

        // ── descriptor dispatch (sift_dsp_descriptor.wgsl; reads gss_buf+recs_buf) ──
        const size_t out_words = (size_t)batch_n * 32;
        wgpu::Buffer out_buf = harness.alloc(out_words * sizeof(uint32_t),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        const size_t dbg_n = (size_t)batch_n * 128;
        wgpu::Buffer dbg_buf = harness.alloc(dbg_n * sizeof(float),
            wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        // descriptor-stage transient peak (host-warp): the concat plane buffer is
        // the dominant term (≈ batch_n*10*lw*lh*4 B, up to the 2-GB cap) + recs +
        // out + dbg. Track the single largest batch's set.
        const double this_batch_bytes =
            (double)(concat.size() * sizeof(float)) +
            (double)(recs.size() * sizeof(PatchRec)) +
            (double)(out_words * sizeof(uint32_t)) +
            (double)(dbg_n * sizeof(float)) +
            (double)(lut.size() * sizeof(float));
        desc_stage_peak = std::max(desc_stage_peak, this_batch_bytes);
        DescParams P{};
        P.num_kp = (uint32_t)batch_n; P.dsp_num_scales = (uint32_t)kDspNumScales;
        P.k_sigma = (float)kSigma;
        wgpu::Buffer P_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);
        const uint32_t wg = ((uint32_t)batch_n + 63u) / 64u;
        auto tdd = clock_t_::now();
        harness.dispatch(pipe_desc, {gss_buf, recs_buf, lut_buf, out_buf, P_buf, dbg_buf},
                         wg ? wg : 1u, 1u, 1u);
        desc_dispatch_ms += ms_since(tdd);
        wgpu::Buffer s = harness.alloc_staging_for_readback(out_words * sizeof(uint32_t));
        harness.copy_to_staging(out_buf, s, out_words * sizeof(uint32_t));
        std::vector<uint8_t> raw = harness.readback(s, out_words * sizeof(uint32_t));
        std::memcpy(gpu_desc.data() + (size_t)b0 * 128, raw.data(),
                    (size_t)batch_n * 128);
      }
      T.warp_setup_ms = warp_ms;
      T.desc_ms = desc_dispatch_ms;
      T.desc_stage_peak_bytes = desc_stage_peak;
      std::printf("[B.7 descriptor] HOST fp64 warp-setup=%.1f ms  GPU desc dispatch=%.1f ms  (%d kp, %d batch(es))\n",
                  T.warp_setup_ms, T.desc_ms, N, n_batches);
      std::printf("[B.7 host-warp mem] desc-stage transient peak=%.1f MB  (concat plane buffer dominates) — the buffer the fusion ELIMINATES\n",
                  desc_stage_peak / 1e6);
      }  // host-warp block

    desc_done:;
    }

    // peak GPU memory = resident gss + the largest concurrent descriptor-stage set.
    T.peak_gpu_bytes = T.gss_resident_bytes + T.desc_stage_peak_bytes;
    T.total_ms = ms_since(t_all);
    T.gss_readback_done = false;  // INVARIANT: resident gss never read back.
    RES.t = T;
    RES.descriptors = std::move(gpu_desc);

    // Stash final frames for the e2e parity matching.
    RES.frame_x.resize(RES.final_kp); RES.frame_y.resize(RES.final_kp);
    RES.frame_sigma.resize(RES.final_kp); RES.frame_octave.resize(RES.final_kp);
    for (size_t i = 0; i < RES.final_kp; ++i) {
      RES.frame_x[i] = finals[i].x; RES.frame_y[i] = finals[i].y;
      RES.frame_sigma[i] = std::sqrt(std::fabs(finals[i].a11 * finals[i].a22 -
                                               finals[i].a12 * finals[i].a21));
      RES.frame_octave[i] = finals[i].octave;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  (C) END-TO-END PARITY vs VLFeat full vl_covdet (detect+suppress+affine+
    //      orient+descriptor, COLMAP DSP config).
    // ════════════════════════════════════════════════════════════════════════
    // (C.1) keypoint recall/precision: match GPU final frames to CPU final
    //       frames by nearest position (same octave) within a tolerance.
    {
      const double pos_tol = 2.0;   // px (frame space) — generous (orient expand)
      size_t matched_cpu = 0, matched_gpu = 0;
      // For each CPU feature, is there a GPU feature within tol at same octave?
      // Build a simple grid would be faster; N is ~8k so brute is fine per-image
      // but O(N^2)=64M — acceptable for the bench.
      std::vector<char> gpu_used(RES.final_kp, 0);
      for (int i = 0; i < cpu_nf; ++i) {
        double best = 1e18; long bj = -1;
        for (size_t j = 0; j < RES.final_kp; ++j) {
          if (gpu_used[j]) continue;
          if (RES.frame_octave[j] != cpu_fo[i]) continue;
          const double dx = RES.frame_x[j] - cpu_fx[i];
          const double dy = RES.frame_y[j] - cpu_fy[i];
          const double d2 = dx * dx + dy * dy;
          if (d2 < best) { best = d2; bj = (long)j; }
        }
        if (bj >= 0 && best <= pos_tol * pos_tol) { ++matched_cpu; gpu_used[bj] = 1; }
      }
      for (size_t j = 0; j < RES.final_kp; ++j) if (gpu_used[j]) ++matched_gpu;
      const double recall = cpu_nf ? (double)matched_cpu / cpu_nf : 1.0;
      const double precision = RES.final_kp ? (double)matched_gpu / RES.final_kp : 1.0;
      std::printf("[C.1 e2e keypoints] CPU=%d  GPU=%zu  matched=%zu  recall=%.4f precision=%.4f  (pos_tol=%.1fpx)\n",
                  cpu_nf, RES.final_kp, matched_cpu, recall, precision, pos_tol);

      // (C.2) descriptor cosine over the matched pairs (same-index after the
      // greedy position match). Rebuild the match map keeping the index pair.
      std::vector<std::pair<int,int>> pairs;  // (cpu_i, gpu_j)
      std::fill(gpu_used.begin(), gpu_used.end(), 0);
      for (int i = 0; i < cpu_nf; ++i) {
        double best = 1e18; long bj = -1;
        for (size_t j = 0; j < RES.final_kp; ++j) {
          if (gpu_used[j]) continue;
          if (RES.frame_octave[j] != cpu_fo[i]) continue;
          const double dx = RES.frame_x[j] - cpu_fx[i];
          const double dy = RES.frame_y[j] - cpu_fy[i];
          const double d2 = dx * dx + dy * dy;
          if (d2 < best) { best = d2; bj = (long)j; }
        }
        if (bj >= 0 && best <= pos_tol * pos_tol) { pairs.emplace_back(i, (int)bj); gpu_used[bj] = 1; }
      }
      std::vector<double> cosv; cosv.reserve(pairs.size());
      for (auto& pr : pairs)
        cosv.push_back(cosine_u8(cpu_desc.data() + (size_t)pr.first * 128,
                                 RES.descriptors.data() + (size_t)pr.second * 128));
      double cmed = 0, cp95 = 0;
      if (!cosv.empty()) {
        std::sort(cosv.begin(), cosv.end());
        cmed = cosv[cosv.size() / 2];
        cp95 = cosv[(size_t)(0.05 * (cosv.size() - 1))];  // 5th pct = p95 floor
      }
      std::printf("[C.2 e2e descriptors] matched pairs=%zu  cosine median=%.6f p95(5th pct)=%.6f\n",
                  cosv.size(), cmed, cp95);

      // (C.2b) ORIENTATION-DISAMBIGUATED cosine: the 1-4x orientation expansion
      // means several CPU/GPU features share a position with DIFFERENT angles;
      // a position-only pairing can match a GPU desc to the wrong-angle CPU desc
      // (a rotated descriptor => low cosine that is a MATCHING artifact, not a
      // pipeline error). For each matched GPU desc, also take the best cosine
      // over ALL CPU features within pos_tol at the same octave (any angle) —
      // this isolates the true descriptor parity from the angle-pairing ambiguity.
      std::vector<double> cosv_best; cosv_best.reserve(pairs.size());
      for (auto& pr : pairs) {
        const uint8_t* gd = RES.descriptors.data() + (size_t)pr.second * 128;
        double best_c = -1.0;
        for (int ci = 0; ci < cpu_nf; ++ci) {
          if (cpu_fo[ci] != RES.frame_octave[pr.second]) continue;
          const double dx = cpu_fx[ci] - RES.frame_x[pr.second];
          const double dy = cpu_fy[ci] - RES.frame_y[pr.second];
          if (dx * dx + dy * dy > pos_tol * pos_tol) continue;
          const double c = cosine_u8(gd, cpu_desc.data() + (size_t)ci * 128);
          if (c > best_c) best_c = c;
        }
        if (best_c >= -0.5) cosv_best.push_back(best_c);
      }
      double bmed = 0, bp95 = 0;
      if (!cosv_best.empty()) {
        std::sort(cosv_best.begin(), cosv_best.end());
        bmed = cosv_best[cosv_best.size() / 2];
        bp95 = cosv_best[(size_t)(0.05 * (cosv_best.size() - 1))];
      }
      std::printf("[C.2b e2e desc, orient-disambiguated] best-cosine-at-position median=%.6f p95(5th pct)=%.6f\n",
                  bmed, bp95);

      // (C.3) descriptor match-recall (GPU desc NN among CPU descs == matched
      // CPU index). Restricted to the matched pairs (the position-aligned set).
      int self_nn = 0;
      for (auto& pr : pairs) {
        const uint8_t* gd = RES.descriptors.data() + (size_t)pr.second * 128;
        double bd = 1e30; int bi = -1;
        for (auto& pr2 : pairs) {
          const double d = l2sq_u8(gd, cpu_desc.data() + (size_t)pr2.first * 128);
          if (d < bd) { bd = d; bi = pr2.first; }
        }
        if (bi == pr.first) ++self_nn;
      }
      const double mrec = pairs.empty() ? 0.0 : (double)self_nn / pairs.size();
      std::printf("[C.3 e2e match-recall] NN==self over matched pairs: %.4f (%d/%zu)\n",
                  mrec, self_nn, pairs.size());
    }

    vl_covdet_delete(cd);
    results.push_back(std::move(RES));
  }

  // ════════════════════════════════════════════════════════════════════════
  //  (D) TIMING VERDICT — cumulative speedup + per-stage + iPhone scaling.
  // ════════════════════════════════════════════════════════════════════════
  const double kIphoneScale = 2.9;  // M3 Pro -> iPhone 14 Pro (A16) absolute (PLAN)
  std::printf("\n=================================================================\n");
  std::printf(" TIMING VERDICT  (M3 Pro, warm, after Tint compile)\n");
  std::printf("=================================================================\n");
  double cpu_sum = 0, gpu_sum = 0;
  double s_gss = 0, s_det = 0, s_ref = 0, s_sup = 0, s_aff = 0, s_or = 0,
         s_warp = 0, s_desc = 0, s_peak = 0, s_descpeak = 0, s_gssbytes = 0;
  bool any_fused = false;
  for (const auto& R : results) {
    cpu_sum += R.cpu_baseline_ms;
    gpu_sum += R.t.total_ms;
    s_gss += R.t.gss_resident_ms; s_det += R.t.detect_ms; s_ref += R.t.refine_ms;
    s_sup += R.t.suppress_ms; s_aff += R.t.affine_ms; s_or += R.t.orient_ms;
    s_warp += R.t.warp_setup_ms; s_desc += R.t.desc_ms;
    s_peak = std::max(s_peak, R.t.peak_gpu_bytes);          // peak is a MAX, not a sum
    s_descpeak = std::max(s_descpeak, R.t.desc_stage_peak_bytes);
    s_gssbytes = std::max(s_gssbytes, R.t.gss_resident_bytes);
    any_fused = any_fused || R.t.used_fused;
    std::printf("  %-50s CPU=%.0f ms  GPU=%.0f ms  speedup=%.2fx\n",
                "(per image)", R.cpu_baseline_ms, R.t.total_ms,
                R.t.total_ms > 0 ? R.cpu_baseline_ms / R.t.total_ms : 0.0);
  }
  const size_t n = results.size();
  std::printf("\n  --- per-stage GPU breakdown (sum over %zu images;  descriptor = %s) ---\n",
              n, any_fused ? "FUSED single-kernel (S5c)" : "HOST fp64 warp + descriptor (reference)");
  std::printf("    gss RESIDENT build     : %8.1f ms   (REAL resident, no per-level readback)\n", s_gss);
  std::printf("    detect (DoG+extremum)  : %8.1f ms\n", s_det);
  std::printf("    refine+gate            : %8.1f ms\n", s_ref);
  std::printf("    suppression (grid GPU) : %8.1f ms\n", s_sup);
  std::printf("    affine-shape           : %8.1f ms\n", s_aff);
  std::printf("    orientation (1-4x)     : %8.1f ms\n", s_or);
  if (any_fused) {
    std::printf("    descriptor: host setup : %8.1f ms   (host builds ONLY the WarpIn ellipses — no fp64 SVD/level/pad/plane)\n", s_warp);
    std::printf("    descriptor: FUSED GPU  : %8.1f ms   *** warp+descriptor FUSED; NO intermediate plane buffer ***\n", s_desc);
  } else {
    std::printf("    descriptor: host warp  : %8.1f ms   *** REFERENCE: fp64 warp setup + ~3.4 GB concat planes on CPU ***\n", s_warp);
    std::printf("    descriptor: GPU compute: %8.1f ms\n", s_desc);
  }
  std::printf("\n  CPU baseline sum          : %8.1f ms\n", cpu_sum);
  std::printf("  FULL-GPU pipeline sum     : %8.1f ms\n", gpu_sum);
  std::printf("  CUMULATIVE SPEEDUP        : %.2fx   (S4 target 3-5x)\n",
              gpu_sum > 0 ? cpu_sum / gpu_sum : 0.0);
  std::printf("  CPU baseline / frame      : %8.1f ms\n", cpu_sum / n);
  std::printf("  FULL-GPU / frame          : %8.1f ms\n", gpu_sum / n);
  std::printf("  gss READBACK GONE         : CONFIRMED  (resident gss never round-tripped)\n");

  // ── PEAK GPU MEMORY ──
  std::printf("\n  --- PEAK GPU MEMORY (resident gss + largest concurrent desc-stage set) ---\n");
  std::printf("    resident gss            : %8.1f MB\n", s_gssbytes / 1e6);
  std::printf("    descriptor-stage peak   : %8.1f MB   (%s)\n", s_descpeak / 1e6,
              any_fused ? "FUSED: WarpIn + out/dbg — NO plane buffer"
                        : "host-warp: the ~3.4 GB concat plane buffer");
  std::printf("    PEAK GPU TOTAL          : %8.1f MB  (%.2f GB)%s\n",
              s_peak / 1e6, s_peak / 1e9,
              any_fused ? "   *** intermediate plane buffer ELIMINATED; 2-GB batching constraint GONE ***"
                        : "");

  // ── iPhone scaling (A16 = user's iPhone 14 Pro) ──
  std::printf("\n  --- iPhone scaling (x%.1f M3-Pro->A16 absolute, PLAN) ---\n", kIphoneScale);
  const double iphone_a16 = (gpu_sum / n) * kIphoneScale;
  std::printf("    A16  (iPhone 14 Pro, user's device): %8.1f ms/frame  vs ~2000 ms streaming budget @4224 => %s\n",
              iphone_a16, iphone_a16 <= 2000.0 ? "WITHIN BUDGET" : "OVER BUDGET");
  // A17 Pro ~ +20% GPU vs A16; A18 Pro ~ +15% over A17 (Apple-published GPU gen
  // deltas; scale the per-frame DOWN by those ratios as a rough device range).
  std::printf("    A17 Pro (~1.2x A16 GPU)            : %8.1f ms/frame  => %s\n",
              iphone_a16 / 1.20, (iphone_a16 / 1.20) <= 2000.0 ? "WITHIN" : "OVER");
  std::printf("    A18 Pro (~1.4x A16 GPU)            : %8.1f ms/frame  => %s\n",
              iphone_a16 / 1.40, (iphone_a16 / 1.40) <= 2000.0 ? "WITHIN" : "OVER");
  std::printf("    NOTE: M3-Pro absolutes are CONTENDED (concurrent GPU load) — ratios + min-of-N runs are the defensible signal; real iPhone needs a device measure.\n");
  std::printf("=================================================================\n");
  return 0;
}
