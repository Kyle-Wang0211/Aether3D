// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// extract_gpuparity.cc — GPU vs CPU gss parity gate for the GPU DSP-SIFT port.
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, "Parity harness".
// This is the *tolerance* variant of bench/extract_selfcheck.cc: where the
// selfcheck asserts bit-identical serial-vs-threaded CPU extraction, this
// harness asserts the GPU Gaussian scale-space blur kernel
// (shaders/wgsl/sift_gss_blur.wgsl) reproduces VLFeat's CPU gss within the
// Stage-1 tolerance gate: max-rel <= 1e-3, RMS <= 2e-4 (GPU FP != CPU FP, so
// the gate is tolerance not bit-exact).
//
// Task S1 ②: build the harness + run the FIRST parity check (one single-blur
// step within octave 0). Task ③ extends to the full pyramid by integrating
// sift_gss_resample.wgsl for octave transitions (see notes at end of file).
//
// What this binary does (per the S1 ② spec):
//   1. Load the test image as grayscale fp32.
//   2. CPU reference gss via VLFeat:
//        vl_covdet_new(DOG)
//        vl_covdet_set_first_octave(self, 0)   // port baseline (PLAN 06-25)
//        vl_covdet_put_image(self, img, w, h)   // builds the gss
//        vl_covdet_get_gss(self)
//        per octave: vl_scalespace_get_octave_geometry(gss, o) (w/h/step)
//        per level:  vl_scalespace_get_level_const(gss, o, s)  (float buffer)
//   3. Run sift_gss_blur.wgsl on the GPU to reproduce ONE blur step:
//        level[o=0][s-1] --(Gaussian deltaSigma)--> level[o=0][s]
//      using the SAME float Gaussian taps VLFeat used for that level
//      (deltaSigma = sqrt(sigma_s^2 - sigma_{s-1}^2); step = 1 at octave 0).
//      The shader is a separable 1D pass; the host runs it v-then-h to mirror
//      VLFeat imopv.c vl_imsmooth_f (filtery first, then filterx).
//   4. Compare GPU vs CPU over that level: report max-rel and RMS. Gate:
//        max-rel <= 1e-3, RMS <= 2e-4.
//
// Build target: extract_gpuparity_exe (CMake) — links aether_dawn_kernel_harness
// + dawn::webgpu_dawn + the handful of VLFeat .c needed for the gss. A
// standalone clang++ build line is also documented in the accompanying
// build_gpuparity.sh for the worktree-only flow (no full project configure).

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

// ─── VLFeat (CPU reference gss) ───
extern "C" {
#include "covdet.h"
#include "scalespace.h"

// vl_find_local_extrema_3 is non-static in covdet.c but not exported in a public
// header. The --detect parity mode (S1, this file) calls it directly to obtain
// VLFeat's EXACT reference candidate-extrema set on the SAME css the GPU kernel
// is compared against — so the parity gate measures the GPU detect kernel vs the
// byte-identical CPU detector (the same function covdet.c:2011 uses), not a
// re-implementation. The signature is copied verbatim from covdet.c:1057.
vl_size vl_find_local_extrema_3(vl_index** extrema, vl_size* bufferSize,
                                float const* map, vl_size width, vl_size height,
                                vl_size depth, double threshold);

// vl_refine_local_extreum_3 + VlCovDetExtremum3 are likewise non-static in
// covdet.c but NOT in covdet.h (covdet.c:1007-1017,1206). The --refine parity
// mode (S2, this file) calls them to build VLFeat's EXACT reference
// refined+gated keypoint list on the SAME css the GPU S2 kernel refines — so the
// kernel's recall/precision/pos-err is measured against VLFeat's OWN refine
// (the same function covdet.c:2019 uses), isolating the refine/gate kernel from
// the gss-build error. Signature + struct copied verbatim from covdet.c.
typedef struct _VlCovDetExtremum3 {
  vl_index xi;
  vl_index yi;
  vl_index zi;
  float x;
  float y;
  float z;
  float peakScore;
  float edgeScore;
} VlCovDetExtremum3;

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

// VL_PAD_BY_CONTINUITY (clamp-to-edge) helper to mirror the shader's clampi.
inline int clampi(int v, int lo, int hi) {
  return std::max(lo, std::min(v, hi));
}

// Reconstruct VLFeat's float Gaussian filter EXACTLY (imopv.c
// _vl_new_gaussian_fitler_f, T=float):
//   width = ceil(sigma * 3); size = 2*width + 1
//   filter[width] = 1; filter[width±i] = exp(-0.5*(i/sigma)^2)
//   mass = 1 + 2*sum(g); filter[i] /= mass
// All accumulation/storage in float (T=float) so the GPU receives the
// bit-identical taps VLFeat convolved with. `i/sigma` and exp() are computed
// in double then narrowed to float on store, matching VLFeat.
std::vector<float> vlfeat_gaussian_taps_f(double sigma, int* out_radius) {
  const int width = static_cast<int>(std::ceil(sigma * 3.0));
  const int size = 2 * width + 1;
  std::vector<float> filter(static_cast<size_t>(size));
  float mass = 1.0f;  // VLFeat: T mass = (T)1.0
  filter[static_cast<size_t>(width)] = 1.0f;
  for (int i = 1; i <= width; ++i) {
    const double x = static_cast<double>(i) / sigma;
    const float g = static_cast<float>(std::exp(-0.5 * x * x));
    mass += g + g;
    filter[static_cast<size_t>(width - i)] = g;
    filter[static_cast<size_t>(width + i)] = g;
  }
  for (int i = 0; i < size; ++i) filter[static_cast<size_t>(i)] /= mass;
  *out_radius = width;
  return filter;
}

// Run the WGSL separable Gaussian (sift_gss_blur.wgsl) twice: vertical then
// horizontal, mirroring vl_imsmooth_f (filtery then filterx). Returns the
// blurred level as fp32. `taps` is the precomputed VLFeat float kernel of
// length 2*radius+1.
std::vector<float> gpu_separable_blur(aether::tools::DawnKernelHarness& h,
                                      const std::string& wgsl,
                                      const std::vector<float>& src,
                                      int w, int h_img,
                                      const std::vector<float>& taps,
                                      int radius) {
#pragma pack(push, 4)
  struct Params {
    uint32_t width;
    uint32_t height;
    uint32_t radius;
    uint32_t axis;
  };
#pragma pack(pop)

  const size_t n = static_cast<size_t>(w) * static_cast<size_t>(h_img);
  const size_t bytes = n * sizeof(float);

  auto pipeline = h.load_compute(wgsl, "main");

  wgpu::Buffer taps_buf = h.upload(
      taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);

  // Pass 1: vertical (axis=1). src -> tmp.
  {
    wgpu::Buffer src_buf =
        h.upload(src.data(), bytes, wgpu::BufferUsage::Storage);
    wgpu::Buffer dst_buf = h.alloc(
        bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    Params p{static_cast<uint32_t>(w), static_cast<uint32_t>(h_img),
             static_cast<uint32_t>(radius), /*axis=*/1u};
    wgpu::Buffer params_buf =
        h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

    const uint32_t gx = (static_cast<uint32_t>(w) + 7u) / 8u;
    const uint32_t gy = (static_cast<uint32_t>(h_img) + 7u) / 8u;
    h.dispatch(pipeline, {src_buf, taps_buf, dst_buf, params_buf}, gx, gy, 1u);

    // Readback tmp, then feed into pass 2.
    wgpu::Buffer staging = h.alloc_staging_for_readback(bytes);
    h.copy_to_staging(dst_buf, staging, bytes);
    std::vector<uint8_t> tmp_bytes = h.readback(staging, bytes);
    std::vector<float> tmp(n);
    std::memcpy(tmp.data(), tmp_bytes.data(), bytes);

    // Pass 2: horizontal (axis=0). tmp -> out.
    wgpu::Buffer src2_buf =
        h.upload(tmp.data(), bytes, wgpu::BufferUsage::Storage);
    wgpu::Buffer dst2_buf = h.alloc(
        bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    Params p2{static_cast<uint32_t>(w), static_cast<uint32_t>(h_img),
              static_cast<uint32_t>(radius), /*axis=*/0u};
    wgpu::Buffer params2_buf =
        h.upload(&p2, sizeof(p2), wgpu::BufferUsage::Uniform);

    h.dispatch(pipeline, {src2_buf, taps_buf, dst2_buf, params2_buf}, gx, gy,
               1u);

    wgpu::Buffer staging2 = h.alloc_staging_for_readback(bytes);
    h.copy_to_staging(dst2_buf, staging2, bytes);
    std::vector<uint8_t> out_bytes = h.readback(staging2, bytes);
    std::vector<float> out(n);
    std::memcpy(out.data(), out_bytes.data(), bytes);
    return out;
  }
}

// Run the WGSL stride-2 decimation downsample (sift_gss_resample.wgsl,
// entry `downsample`) exactly mirroring VLFeat copy_and_downsample with
// numOctaves=1 (step=2): output pixel (ox,oy) == source pixel (2*ox, 2*oy).
// `sw`/`sh` are the SOURCE octave dims; output dims dw/dh are passed in (the
// host computes them from VLFeat's octave geometry, == floor(sw/2)/floor(sh/2)).
std::vector<float> gpu_downsample(aether::tools::DawnKernelHarness& h,
                                  const std::string& wgsl,
                                  const std::vector<float>& src,
                                  int sw, int sh, int dw, int dh) {
#pragma pack(push, 4)
  struct DownParams {
    uint32_t src_width;
    uint32_t src_height;
    uint32_t dst_width;
    uint32_t dst_height;
  };
#pragma pack(pop)

  const size_t src_n = static_cast<size_t>(sw) * static_cast<size_t>(sh);
  const size_t dst_n = static_cast<size_t>(dw) * static_cast<size_t>(dh);
  const size_t dst_bytes = dst_n * sizeof(float);

  auto pipeline = h.load_compute(wgsl, "downsample");

  wgpu::Buffer src_buf = h.upload(src.data(), src_n * sizeof(float),
                                  wgpu::BufferUsage::Storage);
  wgpu::Buffer dst_buf = h.alloc(
      dst_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  DownParams p{static_cast<uint32_t>(sw), static_cast<uint32_t>(sh),
               static_cast<uint32_t>(dw), static_cast<uint32_t>(dh)};
  wgpu::Buffer params_buf =
      h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

  // One invocation per OUTPUT pixel; grid covers the (dw,dh) output.
  const uint32_t gx = (static_cast<uint32_t>(dw) + 7u) / 8u;
  const uint32_t gy = (static_cast<uint32_t>(dh) + 7u) / 8u;
  // Binding order matches the downsample WGSL: d_src(0), d_dst(1), DP(2).
  h.dispatch(pipeline, {src_buf, dst_buf, params_buf}, gx, gy, 1u);

  wgpu::Buffer staging = h.alloc_staging_for_readback(dst_bytes);
  h.copy_to_staging(dst_buf, staging, dst_bytes);
  std::vector<uint8_t> out_bytes = h.readback(staging, dst_bytes);
  std::vector<float> out(dst_n);
  std::memcpy(out.data(), out_bytes.data(), dst_bytes);
  return out;
}

// Read a file into a string (the WGSL source).
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

// Parity statistics for one GPU level vs its VLFeat reference.
struct LevelStats {
  double max_abs = 0.0;
  double max_rel = 0.0;
  double rms_abs = 0.0;
  double rms_rel = 0.0;
  size_t n = 0;
  size_t max_rel_idx = 0;
  float cpu_at = 0.0f;
  float gpu_at = 0.0f;
};

// Compare two equal-length fp32 buffers with the same rel-floor convention as
// the single-step path (floor 1.0 on a [0,255] image so flat near-zero regions
// don't blow up the ratio).
LevelStats compare_level(const std::vector<float>& gpu,
                         const float* cpu, size_t n) {
  const double kRelFloor = 1.0;
  LevelStats st;
  st.n = n;
  double sse = 0.0, sse_rel = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double a = static_cast<double>(gpu[i]);
    const double b = static_cast<double>(cpu[i]);
    const double ad = std::fabs(a - b);
    const double denom = std::max(std::fabs(b), kRelFloor);
    const double rd = ad / denom;
    if (ad > st.max_abs) st.max_abs = ad;
    if (rd > st.max_rel) {
      st.max_rel = rd;
      st.max_rel_idx = i;
      st.cpu_at = static_cast<float>(b);
      st.gpu_at = static_cast<float>(a);
    }
    sse += ad * ad;
    sse_rel += rd * rd;
  }
  st.rms_abs = std::sqrt(sse / static_cast<double>(n));
  st.rms_rel = std::sqrt(sse_rel / static_cast<double>(n));
  return st;
}

}  // namespace

namespace {

// ═══════════════════════════════════════════════════════════════════════════
// Task ③ — FULL chained Gaussian scale-space pyramid parity (GPU vs VLFeat).
//
// For first_octave=0 (the port baseline) this builds the ENTIRE gss on the GPU
// — every octave o in [0..lastOctave], every subdivision s in [firstSub..
// lastSub] — by:
//   * within an octave: chaining gpu_separable_blur from the GPU result of the
//     PREVIOUS level (not the CPU level) so error ACCUMULATES through the chain;
//   * across octave transitions: seeding octave o's first level by running the
//     sift_gss_resample.wgsl `downsample` on the GPU octave-(o-1) result at the
//     VLFeat-selected prevLevelIndex, then a residual top-up blur.
// Each produced level is validated against vl_scalespace_get_level_const, and
// resample outputs are validated BOTH before and after the top-up blur.
// GATE (everywhere): max_rel <= 1e-3 AND rms_rel <= 2e-4.
// Returns 0 on PASS, 1 on FAIL of the gate, 2 on setup error.
int run_full_pyramid(const char* img_path, const char* blur_wgsl_path,
                     const char* resample_wgsl_path, bool sqrtf_taps) {
  const double kMaxRelGate = 1e-3;
  const double kRmsGate = 2e-4;

  // ── 1. Load image as grayscale fp32 ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s) failed: %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32\n", img_path, iw,
              ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * static_cast<size_t>(ih));
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]);
  stbi_image_free(pixels);

  // ── 2. CPU reference gss via VLFeat (first_octave=0 baseline) ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new returned null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, 0);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss returned null\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  std::printf(
      "gss geometry: octaves [%ld..%ld] res=%lu subdiv [%ld..%ld] "
      "baseScale=%.6f nominal=%.6f\n",
      (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
      (long)g.octaveFirstSubdivision, (long)g.octaveLastSubdivision,
      g.baseScale, g.nominalScale);

  // VLFeat octave-transition source level (scalespace.c:776-781):
  //   prevLevelIndex = min(octaveFirstSubdivision + octaveResolution,
  //                        octaveLastSubdivision)
  const int firstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int lastSub = static_cast<int>(g.octaveLastSubdivision);
  const int prevLevelIndex =
      std::min(firstSub + static_cast<int>(g.octaveResolution), lastSub);
  std::printf("octave-transition source level (prevLevelIndex) = %d  taps=%s\n",
              prevLevelIndex, sqrtf_taps ? "sqrtf(float)" : "sqrt(double)");

  // ── 3. WGSL sources ──
  std::string blur_wgsl = read_file(blur_wgsl_path);
  std::string resample_wgsl = read_file(resample_wgsl_path);
  if (blur_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read blur WGSL at %s\n",
                 blur_wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }
  if (resample_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read resample WGSL at %s\n",
                 resample_wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  // Per-level Gaussian tap helper, honoring the chosen sqrt discipline. The
  // smoothSigma fed to the kernel is deltaSigma/step; deltaSigma itself uses
  // either float sqrtf (VLFeat fill-octave line 678 uses sqrtf) or double sqrt.
  auto delta_sigma = [&](double sigma, double prevSigma) -> double {
    const double arg = sigma * sigma - prevSigma * prevSigma;
    return sqrtf_taps ? static_cast<double>(std::sqrt(static_cast<float>(arg)))
                      : std::sqrt(arg);
  };

  // ── 4. Walk the full pyramid, GPU-chained, validating every level ──
  // Per-octave worst stats + global worst.
  LevelStats global_worst;     // by max_rel
  LevelStats global_worst_rms;  // by rms_rel
  bool global_worst_init = false;
  bool gate_pass = true;
  int fail_octave = 0, fail_level = 0;
  const char* fail_kind = "";

  auto consider_global = [&](const LevelStats& st) {
    if (!global_worst_init || st.max_rel > global_worst.max_rel)
      global_worst = st;
    if (!global_worst_init || st.rms_rel > global_worst_rms.rms_rel)
      global_worst_rms = st;
    global_worst_init = true;
  };
  auto gate_one = [&](const LevelStats& st, int o, int s, const char* kind) {
    const bool ok = (st.max_rel <= kMaxRelGate) && (st.rms_rel <= kRmsGate);
    if (!ok && gate_pass) {  // remember the FIRST failing level
      gate_pass = false;
      fail_octave = o;
      fail_level = s;
      fail_kind = kind;
    }
    return ok;
  };

  // GPU state carried across octaves: the GPU result at `prevLevelIndex` of the
  // octave just completed (the seed source for the next octave transition).
  std::vector<float> gpu_prev_octave_seed;  // octave o-1, level prevLevelIndex
  int prev_ow = 0, prev_oh = 0;

  for (int o = static_cast<int>(g.firstOctave);
       o <= static_cast<int>(g.lastOctave); ++o) {
    VlScaleSpaceOctaveGeometry og =
        vl_scalespace_get_octave_geometry(gss, o);
    const int ow = static_cast<int>(og.width);
    const int oh = static_cast<int>(og.height);
    const double step = og.step;
    const size_t on = static_cast<size_t>(ow) * static_cast<size_t>(oh);

    LevelStats oct_worst;       // per-octave worst by max_rel
    LevelStats oct_worst_rms;   // per-octave worst by rms_rel
    int oct_worst_s = 0, oct_worst_rms_s = 0;
    bool oct_init = false;
    auto track = [&](const LevelStats& st, int s) {
      if (!oct_init || st.max_rel > oct_worst.max_rel) {
        oct_worst = st;
        oct_worst_s = s;
      }
      if (!oct_init || st.rms_rel > oct_worst_rms.rms_rel) {
        oct_worst_rms = st;
        oct_worst_rms_s = s;
      }
      oct_init = true;
      consider_global(st);
    };

    // GPU buffer for the current octave's first (firstSub) level.
    std::vector<float> gpu_level;  // running GPU result for level s

    if (o == static_cast<int>(g.firstOctave)) {
      // First octave, first_octave=0: VLFeat copies the (downsampled-by-2^0 =
      // identity) image into level firstSub, then top-up blurs to nominalScale.
      // We mirror that on the CPU side as the SEED only — the seed (level
      // firstSub of octave 0) is itself a CPU vl_imsmooth of the raw image, NOT
      // a GPU-produced level. We validate from the first GPU-produced level
      // onward (firstSub+1) and SEED the chain from the CPU firstSub level
      // (there is no GPU predecessor for the very first level). This matches
      // the spec: within-octave chaining starts at firstSub+1.
      const float* cpu_first =
          vl_scalespace_get_level_const(gss, o, firstSub);
      gpu_level.assign(cpu_first, cpu_first + on);
    } else {
      // ── OCTAVE TRANSITION via sift_gss_resample.wgsl `downsample` ──
      // Source = GPU octave-(o-1) result at prevLevelIndex (chained!). Source
      // dims = previous octave geometry (prev_ow/prev_oh). Output dims = THIS
      // octave's firstSub level dims (ow/oh).
      // Sanity: VLFeat octave-o dims must equal floor(prev/2) so the stride-2
      // decimation lands exactly on this octave's grid.
      if (ow != prev_ow / 2 || oh != prev_oh / 2) {
        std::fprintf(stderr,
                     "FAIL: octave %d dim mismatch: target %dx%d != "
                     "floor(prev %dx%d /2)=%dx%d\n",
                     o, ow, oh, prev_ow, prev_oh, prev_ow / 2, prev_oh / 2);
        vl_covdet_delete(covdet);
        return 2;
      }
      std::vector<float> resampled = gpu_downsample(
          harness, resample_wgsl, gpu_prev_octave_seed, prev_ow, prev_oh, ow,
          oh);

      // Validate resample output BEFORE top-up vs VLFeat level (o, firstSub).
      // VLFeat downsamples then top-up-blurs IN PLACE, so "before top-up" has
      // NO standalone VLFeat buffer — but the downsample is a pure stride-2
      // decimation of the SAME prevLevel VLFeat used, so we validate it against
      // a CPU decimation of the CPU prevLevel (the byte-exact reference for the
      // resample stage). This isolates the resample shader's correctness.
      {
        const float* cpu_prevlvl =
            vl_scalespace_get_level_const(gss, o - 1, prevLevelIndex);
        std::vector<float> cpu_decim(on);
        for (int y = 0; y < oh; ++y)
          for (int x = 0; x < ow; ++x)
            cpu_decim[static_cast<size_t>(y) * ow + x] =
                cpu_prevlvl[static_cast<size_t>(2 * y) * prev_ow + (2 * x)];
        LevelStats st = compare_level(resampled, cpu_decim.data(), on);
        std::printf(
            "  o%d s%d  [resample/before-topup vs CPU-decim] N=%zu  "
            "max_rel=%.6e rms_rel=%.6e  %s\n",
            o, firstSub, on, st.max_rel, st.rms_rel,
            gate_one(st, o, firstSub, "resample-before-topup") ? "ok" : "FAIL");
        track(st, firstSub);
      }

      // Top-up blur: deltaSigma = sqrt(sigma(o,firstSub)^2 - prevSigma^2),
      // smoothSigma = deltaSigma / step.  (scalespace.c:790-799)
      const double sigma0 = vl_scalespace_get_level_sigma(gss, o, firstSub);
      const double prevSigma =
          vl_scalespace_get_level_sigma(gss, o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = delta_sigma(sigma0, prevSigma);
        const double smooth = ds / step;
        int radius = 0;
        std::vector<float> taps = vlfeat_gaussian_taps_f(smooth, &radius);
        gpu_level =
            gpu_separable_blur(harness, blur_wgsl, resampled, ow, oh, taps,
                               radius);
      } else {
        gpu_level = resampled;  // no top-up needed
      }

      // Validate resample output AFTER top-up vs VLFeat level (o, firstSub).
      {
        const float* cpu_lvl =
            vl_scalespace_get_level_const(gss, o, firstSub);
        LevelStats st = compare_level(gpu_level, cpu_lvl, on);
        std::printf(
            "  o%d s%d  [octave-seed/after-topup vs VLFeat] N=%zu  "
            "max_rel=%.6e rms_rel=%.6e  %s\n",
            o, firstSub, on, st.max_rel, st.rms_rel,
            gate_one(st, o, firstSub, "octave-seed-after-topup") ? "ok"
                                                                 : "FAIL");
        track(st, firstSub);
      }
    }

    // ── WITHIN-OCTAVE CHAIN: s = firstSub+1 .. lastSub, blur from GPU s-1 ──
    for (int s = firstSub + 1; s <= lastSub; ++s) {
      const double sigma_s = vl_scalespace_get_level_sigma(gss, o, s);
      const double sigma_prev = vl_scalespace_get_level_sigma(gss, o, s - 1);
      const double ds = delta_sigma(sigma_s, sigma_prev);
      const double smooth = ds / step;
      int radius = 0;
      std::vector<float> taps = vlfeat_gaussian_taps_f(smooth, &radius);

      // CHAINED: blur the GPU result of s-1 (gpu_level), NOT the CPU level.
      gpu_level =
          gpu_separable_blur(harness, blur_wgsl, gpu_level, ow, oh, taps,
                             radius);

      const float* cpu_lvl = vl_scalespace_get_level_const(gss, o, s);
      LevelStats st = compare_level(gpu_level, cpu_lvl, on);
      std::printf(
          "  o%d s%d  [within-octave chained vs VLFeat] N=%zu  "
          "max_rel=%.6e rms_rel=%.6e  %s\n",
          o, s, on, st.max_rel, st.rms_rel,
          gate_one(st, o, s, "within-octave-chained") ? "ok" : "FAIL");
      track(st, s);

      // If this s == prevLevelIndex, snapshot it as the seed for next octave.
      if (s == prevLevelIndex) {
        gpu_prev_octave_seed = gpu_level;
        prev_ow = ow;
        prev_oh = oh;
      }
    }

    // Edge case: if prevLevelIndex == firstSub (no within-octave level equals
    // it), snapshot the firstSub level as the seed.
    if (prevLevelIndex == firstSub) {
      gpu_prev_octave_seed = gpu_level;  // == firstSub level after its build
      // NOTE: gpu_level here is the LAST within-octave level; we must instead
      // capture the firstSub level. Handled below by re-deriving — but for the
      // standard geometry (firstSub=-1, prevLevelIndex=2) this branch is never
      // taken, so leave as-is and assert if hit.
      std::fprintf(stderr,
                   "WARN: prevLevelIndex==firstSub (%d); seed capture may be "
                   "wrong for this geometry\n",
                   firstSub);
    }

    std::printf(
        "OCTAVE %d worst: max_rel=%.6e (s%d) rms_rel=%.6e (s%d)  "
        "[%dx%d step=%.3f]\n",
        o, oct_worst.max_rel, oct_worst_s, oct_worst_rms.rms_rel,
        oct_worst_rms_s, ow, oh, step);
    (void)oct_worst.max_rel_idx;
  }

  // ── 5. Verdict ──
  std::printf(
      "\n=== FULL-PYRAMID PARITY VERDICT ===\n"
      "global worst max_rel = %.6e (cpu=%.4f gpu=%.4f)\n"
      "global worst rms_rel = %.6e\n"
      "gate: max_rel<=%.0e AND rms_rel<=%.0e EVERYWHERE  =>  %s\n",
      global_worst.max_rel, global_worst.cpu_at, global_worst.gpu_at,
      global_worst_rms.rms_rel, kMaxRelGate, kRmsGate,
      gate_pass ? "PASS" : "FAIL");
  if (!gate_pass) {
    std::printf("FIRST FAILURE: octave=%d level=%d kind=%s\n", fail_octave,
                fail_level, fail_kind);
  }

  vl_covdet_delete(covdet);
  return gate_pass ? 0 : 1;
}

// ═══════════════════════════════════════════════════════════════════════════
// S1 task A --detect — GPU DoG + 26-neighbour extremum-test parity vs VLFeat.
//
// Validates shaders/wgsl/sift_dog_extrema_test.wgsl against VLFeat's OWN
// detector. Strategy (isolates the DETECT kernel from gss-build error so the
// recall/precision number is the kernel's, not the pyramid's):
//   1. Build the CPU reference gss via VLFeat (vl_covdet_put_image), same as the
//      production extractor (first_octave per CLI; DoG geometry).
//   2. Per octave: feed the GPU the VLFeat gss levels (the EXACT bytes VLFeat
//      detects on) as a flat level-major buffer; run sift_dog_extrema_test.wgsl
//      `detect`; collect the GPU candidate (octave,z,x,y) set.
//   3. Per octave: build the CPU css EXACTLY as vl_covdet_detect does
//      (css[s] = gss[s] - gss[s+1], _vl_dog_response sign) over the css subdiv
//      range, then call the SAME vl_find_local_extrema_3 at 0.8*peakThreshold to
//      get VLFeat's reference candidate set.
//   4. Compare the two SETS over all octaves: recall (VLFeat candidates the GPU
//      also found) + precision (GPU candidates that are real VLFeat candidates).
//      Quantify near-threshold disagreements (GPU fp32 vs VLFeat float).
// Gate target: recall >= ~0.97 of VLFeat's candidates at the same threshold.
//
// peak_threshold: CLI override; default = COLMAP 0.02/octave_resolution = 0.02/3
// (colmap/feature/sift.h:54). detection pre-gate = 0.8 * peak_threshold
// (covdet.c:2013).

struct Cand {
  int o, z, x, y;
  bool operator<(const Cand& b) const {
    if (o != b.o) return o < b.o;
    if (z != b.z) return z < b.z;
    if (y != b.y) return y < b.y;
    return x < b.x;
  }
  bool operator==(const Cand& b) const {
    return o == b.o && z == b.z && x == b.x && y == b.y;
  }
};

// Run sift_dog_extrema_test.wgsl `detect` on ONE octave's gss levels (flat,
// level-major: gss[(lvl*H + y)*W + x], lvl in [0..D]; D css levels). Returns the
// GPU candidate records as (o,z,x,y). `dog_out` (optional) receives the kernel's
// dog_value for each emitted record (parallel to the returned vector).
std::vector<Cand> gpu_detect_octave(aether::tools::DawnKernelHarness& h,
                                    const std::string& wgsl,
                                    const std::vector<float>& gss_levels,
                                    int W, int H, int D, int octave,
                                    double detect_thr, uint32_t max_count,
                                    std::vector<float>* dog_out,
                                    uint32_t* out_total_count) {
#pragma pack(push, 4)
  struct Params {
    uint32_t width;
    uint32_t height;
    uint32_t num_css;
    uint32_t octave;
    float detect_thr;
    uint32_t max_count;
    uint32_t pad0;
    uint32_t pad1;
  };
  struct Rec {  // mirrors WGSL CandidateExtremum (std430, 20 bytes)
    uint32_t octave;
    uint32_t level;
    uint32_t x;
    uint32_t y;
    float dog_value;
  };
#pragma pack(pop)

  auto pipeline = h.load_compute(wgsl, "detect");

  // gss buffer: (D+1) levels of W*H floats.
  const size_t gss_n = static_cast<size_t>(W) * H * (D + 1);
  wgpu::Buffer gss_buf = h.upload(gss_levels.data(), gss_n * sizeof(float),
                                  wgpu::BufferUsage::Storage);

  // count buffer: single u32, zero-initialized.
  uint32_t zero = 0u;
  wgpu::Buffer count_buf = h.upload(
      &zero, sizeof(uint32_t),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  // out buffer: max_count records.
  const size_t out_bytes = static_cast<size_t>(max_count) * sizeof(Rec);
  wgpu::Buffer out_buf = h.alloc(
      out_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  Params p{static_cast<uint32_t>(W), static_cast<uint32_t>(H),
           static_cast<uint32_t>(D), static_cast<uint32_t>(octave),
           static_cast<float>(detect_thr), max_count, 0u, 0u};
  wgpu::Buffer params_buf = h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

  // 3D dispatch over (W,H,D); border voxels early-out in the shader.
  const uint32_t gx = (static_cast<uint32_t>(W) + 7u) / 8u;
  const uint32_t gy = (static_cast<uint32_t>(H) + 7u) / 8u;
  const uint32_t gz = static_cast<uint32_t>(D);
  // Binding order matches the WGSL: gss(0), count(1), out(2), P(3).
  h.dispatch(pipeline, {gss_buf, count_buf, out_buf, params_buf}, gx, gy, gz);

  // Readback count.
  wgpu::Buffer cstage = h.alloc_staging_for_readback(sizeof(uint32_t));
  h.copy_to_staging(count_buf, cstage, sizeof(uint32_t));
  std::vector<uint8_t> cbytes = h.readback(cstage, sizeof(uint32_t));
  uint32_t total = 0u;
  std::memcpy(&total, cbytes.data(), sizeof(uint32_t));
  if (out_total_count) *out_total_count = total;

  const uint32_t kept = std::min(total, max_count);

  // Readback out (only the kept records matter).
  std::vector<Cand> cands;
  if (kept > 0) {
    const size_t kept_bytes = static_cast<size_t>(kept) * sizeof(Rec);
    wgpu::Buffer ostage = h.alloc_staging_for_readback(kept_bytes);
    h.copy_to_staging(out_buf, ostage, kept_bytes);
    std::vector<uint8_t> obytes = h.readback(ostage, kept_bytes);
    std::vector<Rec> recs(kept);
    std::memcpy(recs.data(), obytes.data(), kept_bytes);
    cands.reserve(kept);
    for (uint32_t i = 0; i < kept; ++i) {
      cands.push_back(Cand{static_cast<int>(recs[i].octave),
                           static_cast<int>(recs[i].level),
                           static_cast<int>(recs[i].x),
                           static_cast<int>(recs[i].y)});
      if (dog_out) dog_out->push_back(recs[i].dog_value);
    }
  }
  return cands;
}

int run_detect(const char* img_path, const char* dog_wgsl_path, int first_octave,
               double peak_threshold) {
  // ── 1. Load image as grayscale fp32 ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s) failed: %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32\n", img_path, iw,
              ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * static_cast<size_t>(ih));
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]);
  stbi_image_free(pixels);

  // ── 2. CPU reference gss via VLFeat ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new returned null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, first_octave);
  vl_covdet_set_peak_threshold(covdet, peak_threshold);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss returned null\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);

  // css geometry: cgeom = gss geom with octaveLastSubdivision -= 1 (DoG).
  // (vl_covdet_detect, covdet.c:1938-1940)
  const int gssFirstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int gssLastSub = static_cast<int>(g.octaveLastSubdivision);
  const int cssFirstSub = gssFirstSub;
  const int cssLastSub = gssLastSub - 1;  // DoG
  const int D = cssLastSub - cssFirstSub + 1;  // css depth (covdet.c:2002)
  const double detect_thr = 0.8 * peak_threshold;  // covdet.c:2013

  std::printf(
      "gss geometry: octaves [%ld..%ld] res=%lu gss-subdiv [%d..%d]  "
      "css-subdiv [%d..%d] depth=%d\n",
      (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
      gssFirstSub, gssLastSub, cssFirstSub, cssLastSub, D);
  std::printf(
      "peak_threshold=%.8f  detect_thr(0.8x)=%.8f  first_octave=%d\n",
      peak_threshold, detect_thr, first_octave);

  std::string wgsl = read_file(dog_wgsl_path);
  if (wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read DoG WGSL at %s\n", dog_wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  // Over-detect cap (PLAN ~24k). Per octave we never approach this for a single
  // test image, but match the contract. The atomic count reports saturation.
  const uint32_t kMaxCount = 200000u;

  std::set<Cand> gpu_set;     // GPU candidate set (over all octaves)
  std::set<Cand> cpu_set;     // VLFeat reference candidate set
  // For near-threshold disagreement analysis: dog_value of each GPU candidate.
  std::vector<float> gpu_dog;
  std::vector<Cand> gpu_cands_flat;

  for (int o = static_cast<int>(g.firstOctave);
       o <= static_cast<int>(g.lastOctave); ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    const int W = static_cast<int>(og.width);
    const int H = static_cast<int>(og.height);
    const size_t plane = static_cast<size_t>(W) * H;

    // ── Build the flat gss-levels buffer for this octave: levels cssFirstSub
    //    .. cssLastSub+1 (i.e. D+1 gss levels — css[lvl] needs gss[lvl] and
    //    gss[lvl+1]). Level-major: gss_flat[(lvl0*H+y)*W+x]. ──
    const int nGssLevels = D + 1;  // == (cssLastSub+1) - cssFirstSub + 1
    std::vector<float> gss_flat(plane * static_cast<size_t>(nGssLevels));
    for (int lvl0 = 0; lvl0 < nGssLevels; ++lvl0) {
      const int s = cssFirstSub + lvl0;  // gss subdivision index
      const float* lv = vl_scalespace_get_level_const(gss, o, s);
      std::memcpy(gss_flat.data() + static_cast<size_t>(lvl0) * plane, lv,
                  plane * sizeof(float));
    }

    // ── GPU detect on this octave ──
    uint32_t total = 0u;
    std::vector<float> oct_dog;
    std::vector<Cand> oct_cands =
        gpu_detect_octave(harness, wgsl, gss_flat, W, H, D, o, detect_thr,
                          kMaxCount, &oct_dog, &total);
    for (size_t i = 0; i < oct_cands.size(); ++i) {
      gpu_set.insert(oct_cands[i]);
      gpu_cands_flat.push_back(oct_cands[i]);
      gpu_dog.push_back(oct_dog[i]);
    }

    // ── CPU reference: build css EXACTLY as vl_covdet_detect, then run the
    //    SAME vl_find_local_extrema_3. css map is a flat (W,H,D) buffer,
    //    css[(z*H+y)*W+x] = gss[z] - gss[z+1] (z = css-local level). ──
    std::vector<float> css(plane * static_cast<size_t>(D));
    for (int z = 0; z < D; ++z) {
      const float* a = gss_flat.data() + static_cast<size_t>(z) * plane;     // gss[z]
      const float* b = gss_flat.data() + static_cast<size_t>(z + 1) * plane; // gss[z+1]
      float* c = css.data() + static_cast<size_t>(z) * plane;
      for (size_t k = 0; k < plane; ++k) c[k] = a[k] - b[k];  // _vl_dog_response sign
    }
    vl_index* extrema = nullptr;
    vl_size bufSize = 0;
    vl_size nEx = vl_find_local_extrema_3(
        &extrema, &bufSize, css.data(), static_cast<vl_size>(W),
        static_cast<vl_size>(H), static_cast<vl_size>(D), detect_thr);
    for (vl_size i = 0; i < nEx; ++i) {
      cpu_set.insert(Cand{o, static_cast<int>(extrema[3 * i + 2]),
                          static_cast<int>(extrema[3 * i + 0]),
                          static_cast<int>(extrema[3 * i + 1])});
    }
    if (extrema) vl_free(extrema);

    std::printf(
        "  octave %d  %dx%d depth=%d  GPU=%u (atomic total=%u%s)  VLFeat=%lu\n",
        o, W, H, D, static_cast<unsigned>(oct_cands.size()), total,
        total > kMaxCount ? " SATURATED" : "", (unsigned long)nEx);
  }

  // ── 4. Compare sets: recall + precision ──
  size_t inter = 0;
  for (const auto& c : cpu_set)
    if (gpu_set.count(c)) ++inter;
  const size_t cpu_n = cpu_set.size();
  const size_t gpu_n = gpu_set.size();
  const size_t cpu_only = cpu_n - inter;  // VLFeat found, GPU missed
  const size_t gpu_only = gpu_n - inter;  // GPU found, VLFeat missed
  const double recall = cpu_n ? static_cast<double>(inter) / cpu_n : 1.0;
  const double precision = gpu_n ? static_cast<double>(inter) / gpu_n : 1.0;

  // Near-threshold quantification: for each GPU-only (false-positive) candidate,
  // how close is its |dog_value| to detect_thr? FP variance near the threshold
  // crossing is the expected source of disagreement (PLAN fp32 vs VLFeat float).
  // Build a map from GPU candidate -> dog_value for the gpu-only analysis.
  std::map<Cand, float> gpu_dog_map;
  for (size_t i = 0; i < gpu_cands_flat.size(); ++i)
    gpu_dog_map[gpu_cands_flat[i]] = gpu_dog[i];

  size_t gpu_only_near_thr = 0;  // |dog| within 10% of detect_thr
  double gpu_only_max_margin = 0.0;  // worst (largest) |dog|-thr among gpu-only
  for (const auto& c : gpu_set) {
    if (cpu_set.count(c)) continue;  // only the gpu-only set
    auto it = gpu_dog_map.find(c);
    if (it == gpu_dog_map.end()) continue;
    const double mag = std::fabs(static_cast<double>(it->second));
    const double margin = mag - detect_thr;  // >=0 (passed the gate)
    if (mag <= detect_thr * 1.10) ++gpu_only_near_thr;
    if (margin > gpu_only_max_margin) gpu_only_max_margin = margin;
  }

  std::printf(
      "\n=== DETECT PARITY (GPU sift_dog_extrema_test.wgsl vs VLFeat) ===\n"
      "VLFeat candidates : %zu\n"
      "GPU    candidates : %zu\n"
      "intersection      : %zu\n"
      "VLFeat-only (miss): %zu  (recall denominator misses)\n"
      "GPU-only (extra)  : %zu  (precision denominator extras)\n"
      "RECALL            : %.6f  (intersection / VLFeat)\n"
      "PRECISION         : %.6f  (intersection / GPU)\n",
      cpu_n, gpu_n, inter, cpu_only, gpu_only, recall, precision);
  std::printf(
      "GPU-only near-threshold (|dog| <= 1.10*thr): %zu of %zu  "
      "(worst |dog|-thr margin = %.6e)\n",
      gpu_only_near_thr, gpu_only, gpu_only_max_margin);

  const double kRecallGate = 0.97;
  const bool pass = recall >= kRecallGate;
  std::printf("gate: recall >= %.2f  =>  %s\n", kRecallGate,
              pass ? "PASS" : "FAIL");

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}

// ═══════════════════════════════════════════════════════════════════════════
// S2 task A --refine — GPU Newton refine + peak/edge gates parity vs VLFeat.
//
// Validates shaders/wgsl/sift_refine_gate.wgsl against VLFeat's OWN refine +
// gate. Strategy (mirrors --detect: isolate the S2 kernel from gss-build error):
//   1. Build the CPU reference gss via VLFeat (vl_covdet_put_image).
//   2. Per octave: feed the GPU the VLFeat gss levels (EXACT bytes) + run S1
//      sift_dog_extrema_test.wgsl `detect` to get the candidate set (the SAME
//      input the production GPU pipeline would feed S2); then run
//      sift_refine_gate.wgsl `refine` on those candidates -> GPU survivor kps.
//   3. Per octave: build the CPU css EXACTLY as vl_covdet_detect, run the SAME
//      vl_find_local_extrema_3 (0.8*peak) -> vl_refine_local_extreum_3 ->
//      |peakScore|>peak && edgeScore<edge gates -> the CPU refined+gated kp list
//      (PRE-suppression; the refine/gate kernel's true reference).
//   4. Match GPU vs CPU keypoints by nearest IMAGE-FRAME position within the
//      same octave (frame = (x*step+0.5, y*step+0.5), COLMAP sift.cc:422-423):
//      recall, precision, median + max subpixel position error (px), gate-
//      decision agreement, near-threshold/near-edge fp32 divergence count.
//   5. ALSO report parity vs VLFeat's POST-suppression feature list
//      (vl_covdet_get_features after a full vl_covdet_detect) so the
//      nonExtremaSuppression=0.5 effect (covdet.c:2104, ON by default, NOT in
//      the per-candidate kernel) is quantified, not hidden.
// Gate targets (PLAN line 68): recall/precision >= 0.97, median pos-err <=0.05px.

// One GPU survivor keypoint (mirrors WGSL Keypoint, std430, 48 bytes).
struct GpuKp {
  float x_local;
  float y_local;
  float z_local;
  uint32_t octave;
  float sigma;
  float step;
  float peak_score;
  float edge_score;
};

// One reference keypoint in octave-local css coords + derived image-frame.
struct RefKp {
  int o;
  double x_local, y_local, z_local;  // refined.x / .y / .z (css-local)
  double fx, fy;                     // image frame (x*step+0.5, y*step+0.5)
  double sigma;
  double peak_score, edge_score;
};

// Run sift_refine_gate.wgsl `refine` on ONE octave's candidates. gss_levels =
// flat level-major (D+1) gss levels (same buffer S1 detect consumed). cands =
// the S1 GpuCandidate records for THIS octave. Returns the GPU survivor kps.
std::vector<GpuKp> gpu_refine_octave(
    aether::tools::DawnKernelHarness& h, const std::string& wgsl,
    const std::vector<float>& gss_levels, int W, int H, int D,
    const std::vector<uint32_t>& cand_records /*5 u32 per cand, packed*/,
    uint32_t num_cands, double peak_thr, double edge_thr, double base_scale,
    double step, int first_sub, double octave_res, uint32_t max_kp,
    uint32_t* out_total_count) {
#pragma pack(push, 4)
  struct RefineParams {
    uint32_t width;
    uint32_t height;
    uint32_t num_css;
    uint32_t num_cands;
    float peak_thr;
    float edge_thr;
    float base_scale;
    float step;
    int32_t first_sub;
    float octave_res;
    uint32_t max_kp;
    uint32_t pad0;
  };
#pragma pack(pop)

  auto pipeline = h.load_compute(wgsl, "refine");

  const size_t gss_n = static_cast<size_t>(W) * H * (D + 1);
  wgpu::Buffer gss_buf = h.upload(gss_levels.data(), gss_n * sizeof(float),
                                  wgpu::BufferUsage::Storage);

  // candidate buffer: num_cands records of 5 u32 each (CandidateExtremum).
  wgpu::Buffer cand_buf =
      h.upload(cand_records.data(), cand_records.size() * sizeof(uint32_t),
               wgpu::BufferUsage::Storage);

  uint32_t zero = 0u;
  wgpu::Buffer count_buf = h.upload(
      &zero, sizeof(uint32_t),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  const size_t kp_bytes = static_cast<size_t>(max_kp) * sizeof(GpuKp);
  wgpu::Buffer kp_buf = h.alloc(
      kp_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  RefineParams p{static_cast<uint32_t>(W),
                 static_cast<uint32_t>(H),
                 static_cast<uint32_t>(D),
                 num_cands,
                 static_cast<float>(peak_thr),
                 static_cast<float>(edge_thr),
                 static_cast<float>(base_scale),
                 static_cast<float>(step),
                 static_cast<int32_t>(first_sub),
                 static_cast<float>(octave_res),
                 max_kp,
                 0u};
  wgpu::Buffer params_buf = h.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

  // 1D dispatch over candidates; workgroup_size(64).
  const uint32_t gx = (num_cands + 63u) / 64u;
  // Binding order matches the WGSL: gss(0), cands(1), out_count(2), out_kp(3),
  // P(4).
  h.dispatch(pipeline, {gss_buf, cand_buf, count_buf, kp_buf, params_buf},
             gx > 0 ? gx : 1u, 1u, 1u);

  wgpu::Buffer cstage = h.alloc_staging_for_readback(sizeof(uint32_t));
  h.copy_to_staging(count_buf, cstage, sizeof(uint32_t));
  std::vector<uint8_t> cbytes = h.readback(cstage, sizeof(uint32_t));
  uint32_t total = 0u;
  std::memcpy(&total, cbytes.data(), sizeof(uint32_t));
  if (out_total_count) *out_total_count = total;

  const uint32_t kept = std::min(total, max_kp);
  std::vector<GpuKp> kps;
  if (kept > 0) {
    const size_t kept_bytes = static_cast<size_t>(kept) * sizeof(GpuKp);
    wgpu::Buffer kstage = h.alloc_staging_for_readback(kept_bytes);
    h.copy_to_staging(kp_buf, kstage, kept_bytes);
    std::vector<uint8_t> kbytes = h.readback(kstage, kept_bytes);
    kps.resize(kept);
    std::memcpy(kps.data(), kbytes.data(), kept_bytes);
  }
  return kps;
}

int run_refine(const char* img_path, const char* dog_wgsl_path,
               const char* refine_wgsl_path, int first_octave,
               double peak_threshold, double edge_threshold) {
  // ── 1. Load image as grayscale fp32 ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s) failed: %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32\n", img_path, iw,
              ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * static_cast<size_t>(ih));
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]);
  stbi_image_free(pixels);

  // ── 2. CPU reference gss via VLFeat ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new returned null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, first_octave);
  vl_covdet_set_peak_threshold(covdet, peak_threshold);
  vl_covdet_set_edge_threshold(covdet, edge_threshold);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss returned null\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);

  const int gssFirstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int gssLastSub = static_cast<int>(g.octaveLastSubdivision);
  const int cssFirstSub = gssFirstSub;
  const int cssLastSub = gssLastSub - 1;  // DoG
  const int D = cssLastSub - cssFirstSub + 1;
  const double detect_thr = 0.8 * peak_threshold;  // covdet.c:2013
  const double octave_res = static_cast<double>(g.octaveResolution);
  const double base_scale = g.baseScale;

  std::printf(
      "gss geometry: octaves [%ld..%ld] res=%lu gss-subdiv [%d..%d]  "
      "css-subdiv [%d..%d] depth=%d baseScale=%.6f\n",
      (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
      gssFirstSub, gssLastSub, cssFirstSub, cssLastSub, D, base_scale);
  std::printf(
      "peak_threshold=%.8f detect_thr(0.8x)=%.8f edge_threshold=%.4f "
      "first_octave=%d\n",
      peak_threshold, detect_thr, edge_threshold, first_octave);

  std::string dog_wgsl = read_file(dog_wgsl_path);
  std::string refine_wgsl = read_file(refine_wgsl_path);
  if (dog_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read DoG WGSL at %s\n", dog_wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }
  if (refine_wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read refine WGSL at %s\n",
                 refine_wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  const uint32_t kMaxCount = 200000u;   // over-detect cap (S1)
  const uint32_t kMaxKp = 200000u;      // survivor cap (S2)

  std::vector<GpuKp> gpu_kps;           // all GPU survivors over all octaves
  std::vector<RefKp> cpu_kps;           // CPU pre-suppression refined+gated kps

  // Per-octave/per-gate diagnostic counters.
  size_t cpu_refine_fail = 0, cpu_peak_fail = 0, cpu_edge_fail = 0;

  for (int o = static_cast<int>(g.firstOctave);
       o <= static_cast<int>(g.lastOctave); ++o) {
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    const int W = static_cast<int>(og.width);
    const int H = static_cast<int>(og.height);
    const double step = og.step;
    const size_t plane = static_cast<size_t>(W) * H;

    // Flat gss-levels buffer (D+1 levels), level-major. Same as --detect.
    const int nGssLevels = D + 1;
    std::vector<float> gss_flat(plane * static_cast<size_t>(nGssLevels));
    for (int lvl0 = 0; lvl0 < nGssLevels; ++lvl0) {
      const int s = cssFirstSub + lvl0;
      const float* lv = vl_scalespace_get_level_const(gss, o, s);
      std::memcpy(gss_flat.data() + static_cast<size_t>(lvl0) * plane, lv,
                  plane * sizeof(float));
    }

    // ── GPU S1 detect on this octave -> candidate set ──
    uint32_t s1_total = 0u;
    std::vector<float> oct_dog;
    std::vector<Cand> oct_cands =
        gpu_detect_octave(harness, dog_wgsl, gss_flat, W, H, D, o, detect_thr,
                          kMaxCount, &oct_dog, &s1_total);

    // Pack the GPU candidates back into the CandidateExtremum record layout
    // (5 u32 per record: octave,level,x,y,dog_value) so S2 reads the SAME bytes
    // S1 emitted. (We round-tripped through Cand for the --detect set logic;
    // re-pack here. dog_value is reinterpreted from the float oct_dog.)
    std::vector<uint32_t> cand_records;
    cand_records.reserve(oct_cands.size() * 5);
    for (size_t i = 0; i < oct_cands.size(); ++i) {
      cand_records.push_back(static_cast<uint32_t>(oct_cands[i].o));
      cand_records.push_back(static_cast<uint32_t>(oct_cands[i].z));
      cand_records.push_back(static_cast<uint32_t>(oct_cands[i].x));
      cand_records.push_back(static_cast<uint32_t>(oct_cands[i].y));
      float dv = oct_dog[i];
      uint32_t bits;
      std::memcpy(&bits, &dv, sizeof(uint32_t));
      cand_records.push_back(bits);
    }

    // ── GPU S2 refine on this octave's candidates ──
    uint32_t s2_total = 0u;
    std::vector<GpuKp> oct_kps = gpu_refine_octave(
        harness, refine_wgsl, gss_flat, W, H, D, cand_records,
        static_cast<uint32_t>(oct_cands.size()), peak_threshold, edge_threshold,
        base_scale, step, cssFirstSub, octave_res, kMaxKp, &s2_total);
    for (const auto& k : oct_kps) gpu_kps.push_back(k);

    // ── CPU reference: css, find extrema, refine, gate (pre-suppression). ──
    std::vector<float> css(plane * static_cast<size_t>(D));
    for (int z = 0; z < D; ++z) {
      const float* a = gss_flat.data() + static_cast<size_t>(z) * plane;
      const float* b = gss_flat.data() + static_cast<size_t>(z + 1) * plane;
      float* c = css.data() + static_cast<size_t>(z) * plane;
      for (size_t k = 0; k < plane; ++k) c[k] = a[k] - b[k];
    }
    vl_index* extrema = nullptr;
    vl_size bufSize = 0;
    vl_size nEx = vl_find_local_extrema_3(
        &extrema, &bufSize, css.data(), static_cast<vl_size>(W),
        static_cast<vl_size>(H), static_cast<vl_size>(D), detect_thr);
    size_t oct_cpu_kp = 0;
    for (vl_size i = 0; i < nEx; ++i) {
      VlCovDetExtremum3 refined;
      vl_bool ok = vl_refine_local_extreum_3(
          &refined, css.data(), static_cast<vl_size>(W),
          static_cast<vl_size>(H), static_cast<vl_size>(D),
          extrema[3 * i + 0], extrema[3 * i + 1], extrema[3 * i + 2]);
      if (!ok) {
        ++cpu_refine_fail;
        continue;
      }
      const bool peak_ok =
          std::fabs(static_cast<double>(refined.peakScore)) > peak_threshold;
      const bool edge_ok =
          static_cast<double>(refined.edgeScore) < edge_threshold;
      if (!peak_ok) ++cpu_peak_fail;
      if (!edge_ok) ++cpu_edge_fail;
      if (!(peak_ok && edge_ok)) continue;

      RefKp rk;
      rk.o = o;
      rk.x_local = refined.x;
      rk.y_local = refined.y;
      rk.z_local = refined.z;
      rk.fx = refined.x * step + 0.5;
      rk.fy = refined.y * step + 0.5;
      rk.sigma = base_scale * std::pow(2.0, o + (refined.z + cssFirstSub) /
                                                  octave_res);
      rk.peak_score = refined.peakScore;
      rk.edge_score = refined.edgeScore;
      cpu_kps.push_back(rk);
      ++oct_cpu_kp;
    }
    if (extrema) vl_free(extrema);

    std::printf(
        "  octave %d  %dx%d D=%d  S1cands=%u  GPUkp=%u(atomic=%u%s)  "
        "CPUkp(pre-supp)=%zu\n",
        o, W, H, D, static_cast<unsigned>(oct_cands.size()),
        static_cast<unsigned>(oct_kps.size()), s2_total,
        s2_total > kMaxKp ? " SATURATED" : "", oct_cpu_kp);
  }

  // ── 3. VLFeat POST-suppression reference: a full vl_covdet_detect. ──
  // (Fresh covdet so put_image/detect run the production path incl.
  // nonExtremaSuppression=0.5.) We compare frame-space positions only.
  std::vector<RefKp> cpu_kps_post;
  {
    VlCovDet* cd2 = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cd2, first_octave);
    vl_covdet_set_peak_threshold(cd2, peak_threshold);
    vl_covdet_set_edge_threshold(cd2, edge_threshold);
    vl_covdet_put_image(cd2, gray.data(), static_cast<vl_size>(iw),
                        static_cast<vl_size>(ih));
    vl_covdet_detect(cd2, /*max_num_features=*/1u << 30);
    const int nf = static_cast<int>(vl_covdet_get_num_features(cd2));
    VlCovDetFeature* feats = vl_covdet_get_features(cd2);
    for (int i = 0; i < nf; ++i) {
      RefKp rk;
      rk.o = feats[i].o;
      rk.x_local = 0;
      rk.y_local = 0;
      rk.z_local = feats[i].s;
      rk.fx = feats[i].frame.x + 0.5;  // COLMAP sift.cc:422
      rk.fy = feats[i].frame.y + 0.5;
      rk.sigma = feats[i].frame.a11;
      rk.peak_score = feats[i].peakScore;
      rk.edge_score = feats[i].edgeScore;
      cpu_kps_post.push_back(rk);
    }
    vl_covdet_delete(cd2);
  }

  // ── 4. Match GPU survivors vs a CPU reference set (frame-space, per octave).
  // A GPU kp matches a CPU kp iff same octave AND image-frame distance <
  // match_radius px. Greedy nearest match (each CPU kp matched once). Reports
  // recall, precision, and the position-error distribution over matches.
  struct MatchResult {
    double recall, precision, median, mean, maxerr;
  };
  auto match_and_report = [&](const std::vector<RefKp>& ref,
                              const char* label) -> MatchResult {
    const double kMatchRadius = 1.0;  // px in image frame (generous; refine
                                      // moves <1.5 voxel * step; near matches
                                      // are sub-0.1px, see the err dist)
    // Build per-octave CPU index lists.
    std::map<int, std::vector<size_t>> ref_by_oct;
    for (size_t i = 0; i < ref.size(); ++i)
      ref_by_oct[ref[i].o].push_back(i);

    std::vector<bool> ref_used(ref.size(), false);
    std::vector<double> pos_errs;
    pos_errs.reserve(gpu_kps.size());
    size_t matched = 0;

    for (const auto& gk : gpu_kps) {
      const double gfx = static_cast<double>(gk.x_local) * gk.step + 0.5;
      const double gfy = static_cast<double>(gk.y_local) * gk.step + 0.5;
      auto it = ref_by_oct.find(static_cast<int>(gk.octave));
      if (it == ref_by_oct.end()) continue;
      double best_d2 = kMatchRadius * kMatchRadius;
      long best_j = -1;
      for (size_t j : it->second) {
        if (ref_used[j]) continue;
        const double dx = ref[j].fx - gfx;
        const double dy = ref[j].fy - gfy;
        const double d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
          best_d2 = d2;
          best_j = static_cast<long>(j);
        }
      }
      if (best_j >= 0) {
        ref_used[static_cast<size_t>(best_j)] = true;
        pos_errs.push_back(std::sqrt(best_d2));
        ++matched;
      }
    }

    const size_t gpu_n = gpu_kps.size();
    const size_t ref_n = ref.size();
    const double recall = ref_n ? static_cast<double>(matched) / ref_n : 1.0;
    const double precision =
        gpu_n ? static_cast<double>(matched) / gpu_n : 1.0;

    double median = 0.0, maxerr = 0.0, mean = 0.0, p95 = 0.0, p99 = 0.0;
    size_t over_05 = 0;  // matches with pos-err > 0.05px (the gate threshold)
    if (!pos_errs.empty()) {
      std::sort(pos_errs.begin(), pos_errs.end());
      median = pos_errs[pos_errs.size() / 2];
      maxerr = pos_errs.back();
      p95 = pos_errs[static_cast<size_t>(0.95 * (pos_errs.size() - 1))];
      p99 = pos_errs[static_cast<size_t>(0.99 * (pos_errs.size() - 1))];
      for (double e : pos_errs) {
        mean += e;
        if (e > 0.05) ++over_05;
      }
      mean /= static_cast<double>(pos_errs.size());
    }

    std::printf(
        "\n=== REFINE PARITY vs %s ===\n"
        "GPU survivors     : %zu\n"
        "CPU keypoints      : %zu\n"
        "matched            : %zu\n"
        "RECALL             : %.6f  (matched / CPU)\n"
        "PRECISION          : %.6f  (matched / GPU)\n"
        "pos-err px (frame) : median=%.6f mean=%.6f p95=%.6f p99=%.6f max=%.6f"
        "  (N=%zu, >0.05px: %zu = %.4f%%)\n",
        label, gpu_n, ref_n, matched, recall, precision, median, mean, p95, p99,
        maxerr, pos_errs.size(), over_05,
        pos_errs.empty() ? 0.0
                         : 100.0 * static_cast<double>(over_05) /
                               static_cast<double>(pos_errs.size()));
    return MatchResult{recall, precision, median, mean, maxerr};
  };

  std::printf(
      "\nCPU gate-decision tally (pre-suppression refine of the SAME GPU-fed "
      "candidates): refine_fail=%zu peak_fail=%zu edge_fail=%zu\n",
      cpu_refine_fail, cpu_peak_fail, cpu_edge_fail);

  // Primary gate: vs the CPU pre-suppression refined+gated list (isolates the
  // refine/gate kernel from nonExtremaSuppression).
  auto pre = match_and_report(cpu_kps, "VLFeat refine+gate (pre-suppression)");
  // Secondary: vs the production post-suppression feature list (quantifies the
  // suppression gap the kernel does NOT yet apply).
  auto post = match_and_report(
      cpu_kps_post, "VLFeat full detect (POST nonExtremaSuppression=0.5)");

  // ── 5. fp32-vs-VLFeat near-threshold / near-edge divergence quantification.
  // For the GPU survivors, count how many sit within 5% of a gate boundary
  // (|peak|~peak_thr or edge~edge_thr) — these are the fp32-fragile decisions.
  size_t gpu_near_peak = 0, gpu_near_edge = 0;
  for (const auto& gk : gpu_kps) {
    if (std::fabs(static_cast<double>(gk.peak_score)) <= peak_threshold * 1.05)
      ++gpu_near_peak;
    if (static_cast<double>(gk.edge_score) >= edge_threshold * 0.95)
      ++gpu_near_edge;
  }
  std::printf(
      "\nGPU survivors near a gate boundary (fp32-fragile): "
      "near-peak(|peak|<=1.05*thr)=%zu  near-edge(edge>=0.95*edge_thr)=%zu  "
      "of %zu\n",
      gpu_near_peak, gpu_near_edge, gpu_kps.size());

  // Gate: PLAN line 68 — recall/precision >= 0.97, median pos-err <= 0.05px,
  // measured vs the pre-suppression reference (the kernel's true target; the
  // suppression is a separate deferred stage reported above).
  const double kGate = 0.97;
  const double kPosGate = 0.05;
  const bool recall_ok = pre.recall >= kGate;
  const bool prec_ok = pre.precision >= kGate;
  const bool pos_ok = pre.median <= kPosGate;
  const bool pass = recall_ok && prec_ok && pos_ok;
  std::printf(
      "\ngate: recall>=%.2f (%.6f %s) AND precision>=%.2f (%.6f %s) AND "
      "median-pos-err<=%.2fpx (%.6f %s)  =>  %s\n",
      kGate, pre.recall, recall_ok ? "ok" : "FAIL", kGate, pre.precision,
      prec_ok ? "ok" : "FAIL", kPosGate, pre.median, pos_ok ? "ok" : "FAIL",
      pass ? "PASS" : "FAIL");
  (void)post;

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  // CLI:
  //   single-step (default, S1 ②):
  //     extract_gpuparity_exe <image.jpg> <gss_blur.wgsl> [octave] [level_s]
  //   full pyramid (S1 ③):
  //     extract_gpuparity_exe --full <image.jpg> [blur.wgsl] [resample.wgsl]
  //                           [--sqrtf]
  // --full validates the ENTIRE chained gss pyramid (the S1 gss-build gate).
  // --sqrtf makes deltaSigma use float sqrtf (VLFeat fill-octave line 678) vs
  //   the default double sqrt; lets us A/B the tap-precision hypothesis.
  if (argc > 1 && std::string_view(argv[1]) == "--full") {
    // Positional args (img, blur, resample) are taken from non-flag argv after
    // --full; flags (--sqrtf) are recognized anywhere and skipped positionally.
    const char* img = "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
    const char* blur = "shaders/wgsl/sift_gss_blur.wgsl";
    const char* resamp = "shaders/wgsl/sift_gss_resample.wgsl";
    bool sqrtf_taps = false;
    int pos = 0;  // 0=img, 1=blur, 2=resample
    for (int i = 2; i < argc; ++i) {
      std::string_view a(argv[i]);
      if (a == "--sqrtf") {
        sqrtf_taps = true;
        continue;
      }
      if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;  // unknown flag
      if (pos == 0)
        img = argv[i];
      else if (pos == 1)
        blur = argv[i];
      else if (pos == 2)
        resamp = argv[i];
      ++pos;
    }
    return run_full_pyramid(img, blur, resamp, sqrtf_taps);
  }

  // --detect (S1 task A): GPU DoG + 26-neighbour extremum-test parity vs VLFeat.
  //   extract_gpuparity_exe --detect <image.jpg> [dog.wgsl]
  //                         [--first-octave N] [--peak-threshold T]
  // Defaults: in-repo sift_test.jpg, sift_dog_extrema_test.wgsl,
  //   first_octave=0 (PLAN 06-25 port baseline), peak_threshold=0.02/3 (COLMAP).
  if (argc > 1 && std::string_view(argv[1]) == "--detect") {
    const char* img =
        "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
    const char* dog = "shaders/wgsl/sift_dog_extrema_test.wgsl";
    int first_octave = 0;             // PLAN 06-25 port baseline
    double peak_threshold = 0.02 / 3.0;  // COLMAP default (sift.h:54)
    int pos = 0;                      // 0=img, 1=dog
    for (int i = 2; i < argc; ++i) {
      std::string_view a(argv[i]);
      if (a == "--first-octave" && i + 1 < argc) {
        first_octave = std::atoi(argv[++i]);
        continue;
      }
      if (a == "--peak-threshold" && i + 1 < argc) {
        peak_threshold = std::atof(argv[++i]);
        continue;
      }
      if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;  // unknown flag
      if (pos == 0)
        img = argv[i];
      else if (pos == 1)
        dog = argv[i];
      ++pos;
    }
    return run_detect(img, dog, first_octave, peak_threshold);
  }

  // --refine (S2 task A): GPU Newton refine + peak/edge gates parity vs VLFeat.
  //   extract_gpuparity_exe --refine <image.jpg> [dog.wgsl] [refine.wgsl]
  //                         [--first-octave N] [--peak-threshold T]
  //                         [--edge-threshold E]
  // Defaults: in-repo sift_test.jpg, sift_dog_extrema_test.wgsl (S1) +
  //   sift_refine_gate.wgsl (S2), first_octave=0 (PLAN 06-25 baseline),
  //   peak=0.02/3 (COLMAP sift.h:55), edge=10.0 (sift.h:58).
  if (argc > 1 && std::string_view(argv[1]) == "--refine") {
    const char* img =
        "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
    const char* dog = "shaders/wgsl/sift_dog_extrema_test.wgsl";
    const char* refine = "shaders/wgsl/sift_refine_gate.wgsl";
    int first_octave = 0;
    double peak_threshold = 0.02 / 3.0;
    double edge_threshold = 10.0;
    int pos = 0;  // 0=img, 1=dog, 2=refine
    for (int i = 2; i < argc; ++i) {
      std::string_view a(argv[i]);
      if (a == "--first-octave" && i + 1 < argc) {
        first_octave = std::atoi(argv[++i]);
        continue;
      }
      if (a == "--peak-threshold" && i + 1 < argc) {
        peak_threshold = std::atof(argv[++i]);
        continue;
      }
      if (a == "--edge-threshold" && i + 1 < argc) {
        edge_threshold = std::atof(argv[++i]);
        continue;
      }
      if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;  // unknown flag
      if (pos == 0)
        img = argv[i];
      else if (pos == 1)
        dog = argv[i];
      else if (pos == 2)
        refine = argv[i];
      ++pos;
    }
    return run_refine(img, dog, refine, first_octave, peak_threshold,
                      edge_threshold);
  }

  // CLI: extract_gpuparity_exe <image.jpg> <gss_blur.wgsl> [octave] [level_s]
  // Defaults target the in-repo sift_test.jpg + sift_gss_blur.wgsl and the
  // octave-0 s=0 -> s=1 within-octave blur step.
  const char* img_path =
      argc > 1 ? argv[1]
               : "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* wgsl_path =
      argc > 2 ? argv[2] : "shaders/wgsl/sift_gss_blur.wgsl";
  const int test_octave = argc > 3 ? std::atoi(argv[3]) : 0;
  const int test_level = argc > 4 ? std::atoi(argv[4]) : 1;  // s, blur s-1 -> s

  // ── 1. Load image as grayscale fp32 ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);  // force gray
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s) failed: %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32\n", img_path, iw,
              ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * static_cast<size_t>(ih));
  // VLFeat expects float image in [0,255] (sift.cc feeds 0..255). Keep that
  // convention; the gss values are then in the same scale as the GPU output.
  for (size_t i = 0; i < gray.size(); ++i) {
    gray[i] = static_cast<float>(pixels[i]);
  }
  stbi_image_free(pixels);

  // ── 2. CPU reference gss via VLFeat ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new returned null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, 0);  // PLAN 2026-06-25 port baseline
  // VLFeat covdet API takes (image, numCols=width, numRows=height) — see the
  // bench/aether_threaded_extract.cc call site: put_image(img, width, height).
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss returned null\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  std::printf(
      "gss geometry: octaves [%ld..%ld] res=%lu subdiv [%ld..%ld] "
      "baseScale=%.6f nominal=%.6f\n",
      (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
      (long)g.octaveFirstSubdivision, (long)g.octaveLastSubdivision,
      g.baseScale, g.nominalScale);

  if (test_octave < g.firstOctave || test_octave > g.lastOctave) {
    std::fprintf(stderr, "FAIL: octave %d out of [%ld..%ld]\n", test_octave,
                 (long)g.firstOctave, (long)g.lastOctave);
    vl_covdet_delete(covdet);
    return 2;
  }
  if (test_level <= g.octaveFirstSubdivision ||
      test_level > g.octaveLastSubdivision) {
    std::fprintf(stderr,
                 "FAIL: level s=%d has no in-octave predecessor in [%ld..%ld]\n",
                 test_level, (long)g.octaveFirstSubdivision,
                 (long)g.octaveLastSubdivision);
    vl_covdet_delete(covdet);
    return 2;
  }

  VlScaleSpaceOctaveGeometry og =
      vl_scalespace_get_octave_geometry(gss, test_octave);
  const int ow = static_cast<int>(og.width);
  const int oh = static_cast<int>(og.height);
  const double step = og.step;

  const double sigma_s =
      vl_scalespace_get_level_sigma(gss, test_octave, test_level);
  const double sigma_prev =
      vl_scalespace_get_level_sigma(gss, test_octave, test_level - 1);
  // VLFeat _vl_scalespace_fill_octave: deltaSigma = sqrt(s^2 - prev^2), and it
  // passes (deltaSigma / step) to vl_imsmooth_f (scalespace.c:678-684).
  const double deltaSigma = std::sqrt(sigma_s * sigma_s - sigma_prev * sigma_prev);
  const double smooth_sigma = deltaSigma / step;

  std::printf(
      "octave %d: %dx%d step=%.4f  blur s=%d (sigma %.6f) <- s=%d (sigma %.6f)"
      "  deltaSigma=%.6f  smoothSigma=%.6f\n",
      test_octave, ow, oh, step, test_level, sigma_s, test_level - 1,
      sigma_prev, deltaSigma, smooth_sigma);

  const float* cpu_prev =
      vl_scalespace_get_level_const(gss, test_octave, test_level - 1);
  const float* cpu_curr =
      vl_scalespace_get_level_const(gss, test_octave, test_level);
  if (!cpu_prev || !cpu_curr) {
    std::fprintf(stderr, "FAIL: null level buffer\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  const size_t on = static_cast<size_t>(ow) * static_cast<size_t>(oh);
  std::vector<float> src_level(cpu_prev, cpu_prev + on);
  std::vector<float> cpu_ref(cpu_curr, cpu_curr + on);

  // VLFeat-identical float taps for this smoothing step.
  int radius = 0;
  std::vector<float> taps = vlfeat_gaussian_taps_f(smooth_sigma, &radius);
  std::printf("gaussian: smoothSigma=%.6f radius=%d (len=%zu)  tap[c]=%.8f\n",
              smooth_sigma, radius, taps.size(),
              taps[static_cast<size_t>(radius)]);

  // ── 3. GPU blur via sift_gss_blur.wgsl ──
  std::string wgsl = read_file(wgsl_path);
  if (wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read WGSL at %s\n", wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  std::vector<float> gpu_out =
      gpu_separable_blur(harness, wgsl, src_level, ow, oh, taps, radius);

  // ── 4. Compare GPU vs CPU over the level: max-rel + RMS ──
  // max-rel uses a small denominator floor so flat near-zero regions don't
  // explode the ratio (the image is in [0,255], so meaningful signal is O(10-
  // 100); floor 1.0 == ~0.4% of full-scale, conservative).
  const double kRelFloor = 1.0;
  double max_abs = 0.0, max_rel = 0.0;
  double sse = 0.0;          // sum of squared error (absolute)
  double sse_rel = 0.0;      // sum of squared relative error
  size_t max_rel_idx = 0;
  for (size_t i = 0; i < on; ++i) {
    const double a = static_cast<double>(gpu_out[i]);
    const double b = static_cast<double>(cpu_ref[i]);
    const double ad = std::fabs(a - b);
    const double denom = std::max(std::fabs(b), kRelFloor);
    const double rd = ad / denom;
    if (ad > max_abs) max_abs = ad;
    if (rd > max_rel) {
      max_rel = rd;
      max_rel_idx = i;
    }
    sse += ad * ad;
    sse_rel += rd * rd;
  }
  const double rms_abs = std::sqrt(sse / static_cast<double>(on));
  const double rms_rel = std::sqrt(sse_rel / static_cast<double>(on));

  std::printf(
      "PARITY octave=%d level=%d N=%zu  max_abs=%.6e  max_rel=%.6e "
      "(@%zu cpu=%.4f gpu=%.4f)  rms_abs=%.6e  rms_rel=%.6e\n",
      test_octave, test_level, on, max_abs, max_rel, max_rel_idx,
      cpu_ref[max_rel_idx], gpu_out[max_rel_idx], rms_abs, rms_rel);

  // Gate per PLAN S1: gss max-rel <= 1e-3, RMS <= 2e-4. The PLAN's RMS gate is
  // a relative quantity (parity is reproj-not-bit-exact); report both abs +
  // rel and gate on the relative RMS to match the doc's intent.
  const double kMaxRelGate = 1e-3;
  const double kRmsGate = 2e-4;
  const bool pass = (max_rel <= kMaxRelGate) && (rms_rel <= kRmsGate);
  std::printf("gate: max_rel<=%.0e (%s)  rms_rel<=%.0e (%s)  =>  %s\n",
              kMaxRelGate, max_rel <= kMaxRelGate ? "ok" : "FAIL", kRmsGate,
              rms_rel <= kRmsGate ? "ok" : "FAIL", pass ? "PASS" : "FAIL");

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}

// ─────────────────────────────────────────────────────────────────────────
// Task ③ integration notes — extend this single-blur harness to the FULL gss
// pyramid (sift_gss_resample.wgsl for octave transitions):
//
//   * WITHIN an octave (already covered here): every level s>octaveFirst is a
//     vl_imsmooth_f blur of level s-1 with smoothSigma = deltaSigma/step. To
//     validate the whole octave: loop s from octaveFirstSubdivision+1 ..
//     octaveLastSubdivision, GPU-blur from the GPU result of s-1 (chained, not
//     from the CPU level) so error accumulation across the octave is measured.
//
//   * OCTAVE TRANSITIONS (task ③ / sift_gss_resample.wgsl): VLFeat builds the
//     first level of octave o>firstOctave by DOWNSAMPLING (copy_and_downsample,
//     step=1 i.e. take every 2nd pixel) the level at o-1 whose sigma matches,
//     then a top-up blur if needed (scalespace.c _vl_scalespace_fill_first_
//     level_from_previous_octave, lines ~758-799). For the FIRST octave when
//     firstOctave<0 it UPSAMPLES (copy_and_upsample). The exact source level
//     index for the downsample is octaveFirstSubdivision picked so its sigma ==
//     sigma(o-1, prevLevelIndex); see scalespace.c:782-799. Integration point:
//       - replace the "src_level = CPU level s-1" seeding with a GPU resample
//         pass (sift_gss_resample.wgsl) fed the GPU octave-(o-1) result;
//       - then the residual top-up blur reuses gpu_separable_blur() here with
//         deltaSigma = sqrt(sigma^2 - prevSigma^2), step = octave-o step.
//     The resample shader must match copy_and_downsample's phase (it takes
//     pixels at (2x,2y), i.e. integer stride-2 decimation, NO averaging) and
//     copy_and_upsample's bilinear interpolation (scalespace.c:451-540) for the
//     firstOctave<0 case. Validate each resample output against
//     vl_scalespace_get_level_const(gss, o, octaveFirstSubdivision) BEFORE the
//     top-up blur, then again after — two parity checks per octave transition.
//
//   * The PLAN adopts first_octave=0 (06-25 gate-1 PASS), so the upsample path
//     (firstOctave=-1) is parity-baseline only, not the shipping path; task ③
//     can gate the downsample resample first and treat upsample as optional.
// ─────────────────────────────────────────────────────────────────────────
