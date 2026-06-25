// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// parity_orient.cc — GPU vs CPU parity gate for the GPU DSP-SIFT Stage-4b
// orientation-assignment kernel (shaders/wgsl/sift_orientation.wgsl).
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S4 scope:
//   "orientation: per-kp 36-bin histogram, 1-4x expand (reads gss)".
// Stage gate (PLAN line 70): orient median <= 1 deg; this harness ALSO reports
// the keypoint-expansion-count agreement (same # of orientations per kp / same
// total expanded count), per the task spec.
//
// ────────────────────────────────────────────────────────────────────────────
//  Methodology (mirrors --detect / --refine in extract_gpuparity.cc: isolate the
//  S4b kernel from the upstream stages it depends on, so the measured error is
//  the orientation kernel's OWN divergence, not gss-build / affine-shape error):
//
//   1. Build a VLFeat covdet (DOG), put_image -> builds the gss; detect; then
//      vl_covdet_extract_affine_shape so each feature.frame carries the affine
//      ellipse the orientation pass consumes. (COLMAP's DSP-SIFT path runs
//      estimate_affine_shape — the kernel is fed the SAME affine frames.)
//   2. CPU REFERENCE: for EACH feature.frame, call VLFeat's OWN
//      vl_covdet_extract_orientations_for_frame -> the exact (angle,score)[]
//      and count VLFeat would produce (the same function covdet.c:2866 uses).
//   3. Build the full multi-octave gss pyramid as ONE flat fp32 buffer + a
//      per-octave geometry table (offset/width/height/step), upload the input
//      frames, dispatch sift_orientation.wgsl (entry `orient`), read back the
//      oriented-kp records (1-4 per input kp via atomic-append).
//   4. COMPARE per input kp:
//        * expansion-count agreement: GPU #orientations == CPU #orientations.
//        * orientation error: for each kp, greedily match GPU angles to CPU
//          angles (min circular distance) and report the matched angle-error
//          distribution (median/mean/p95/max) in DEGREES, plus the fraction
//          > 1 deg (the gate). Circular distance wraps at 2pi.
//
//  The frames fed to BOTH sides are byte-identical VlFrameOrientedEllipse, so a
//  divergence is the GPU svd2/warp/smooth/hist/peak path vs VLFeat's double path
//  — NOT an affine-shape or gss-build difference.
// ────────────────────────────────────────────────────────────────────────────
//
// Build: third_party/glomap_vendor/bench/build_orient.sh (worktree-only fast
// path; reuses the prebuilt host Dawn + the VLFeat .c subset + the read-only
// tools/dawn_kernel_harness.cpp). Unique obj dir /tmp/parity_orient_obj.
//
// Run (from aether_cpp/):
//   /tmp/parity_orient_obj/parity_orient_exe \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \
//     shaders/wgsl/sift_orientation.wgsl

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <string_view>
#include <vector>

// ─── VLFeat (CPU reference: gss + affine + orientation) ───
extern "C" {
#include "covdet.h"
#include "scalespace.h"
}

// ─── Dawn kernel harness (GPU under test) ───
#include "dawn_kernel_harness.h"

// ─── stb_image (JPEG decode) ───
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

constexpr double kPi = 3.141592653589793;
constexpr double kTwoPi = 6.283185307179586;

std::string read_file(const char* path) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f) return {};
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::string s(static_cast<size_t>(sz), '\0');
  size_t rd = std::fread(s.data(), 1, static_cast<size_t>(sz), f);
  (void)rd;
  std::fclose(f);
  return s;
}

// ── Host-side mirrors of the WGSL record layouts (std430, 4-byte scalars). ──
#pragma pack(push, 4)
struct InputKp {
  float x, y;
  float a11, a12, a21, a22;
  int32_t octave;
  uint32_t pad0;
};
struct OrientedKp {
  uint32_t kp_index;
  float angle;
  float score;
  uint32_t pad0;
};
struct OctaveGeom {
  int32_t width;
  int32_t height;
  float step;
  uint32_t gss_offset;
  int32_t octave;
  uint32_t pad0, pad1, pad2;
};
struct OrientParams {
  uint32_t num_kp;
  uint32_t num_octaves;
  int32_t first_octave;
  int32_t last_octave;
  int32_t first_sub;
  int32_t last_sub;
  float octave_res;
  float base_scale;
  uint32_t max_out;
  uint32_t pad0, pad1, pad2;
};
#pragma pack(pop)

static_assert(sizeof(InputKp) == 32, "InputKp layout");
static_assert(sizeof(OrientedKp) == 16, "OrientedKp layout");
static_assert(sizeof(OctaveGeom) == 32, "OctaveGeom layout");
static_assert(sizeof(OrientParams) == 48, "OrientParams layout");

// Circular distance between two angles, in [0, pi].
double circ_dist(double a, double b) {
  double d = std::fmod(std::fabs(a - b), kTwoPi);
  if (d > kPi) d = kTwoPi - d;
  return d;
}

int run(const char* img_path, const char* wgsl_path) {
  // ── 1. Load grayscale fp32. ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s) failed: %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::vector<float> gray(static_cast<size_t>(iw) * ih);
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]) / 255.0f;
  stbi_image_free(pixels);
  std::printf("image: %s  %dx%d\n", img_path, iw, ih);

  // ── 2. VLFeat: build gss + detect + affine-shape -> feature frames. ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new returned null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, 0);          // PLAN 06-25 port baseline
  vl_covdet_set_peak_threshold(covdet, 0.02 / 3.0);   // COLMAP default
  vl_covdet_set_edge_threshold(covdet, 10.0);
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  vl_covdet_detect(covdet, 1u << 30);
  vl_covdet_extract_affine_shape(covdet);   // ellipse frames for orientation

  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss returned null\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  std::printf(
      "gss geometry: firstOctave=%ld lastOctave=%ld octaveResolution=%lu "
      "firstSub=%ld lastSub=%ld baseScale=%.9g\n",
      (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
      (long)g.octaveFirstSubdivision, (long)g.octaveLastSubdivision,
      g.baseScale);

  const int nf = static_cast<int>(vl_covdet_get_num_features(covdet));
  VlCovDetFeature* feats = vl_covdet_get_features(covdet);
  std::printf("features (post-affine, pre-orientation): %d\n", nf);
  if (nf == 0) {
    std::fprintf(stderr, "FAIL: 0 features\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  // ── 3a. CPU REFERENCE orientations (VLFeat's own, per frame). ──
  // Store the per-kp orientation lists; also the input frames for the GPU.
  std::vector<InputKp> input_kps(nf);
  std::vector<std::vector<double>> cpu_angle(nf);
  std::vector<std::vector<double>> cpu_score(nf);
  size_t cpu_total_or = 0;
  // Histogram of CPU orientation counts (index 0..4).
  size_t cpu_count_hist[6] = {0, 0, 0, 0, 0, 0};

  for (int i = 0; i < nf; ++i) {
    VlFrameOrientedEllipse fr = feats[i].frame;
    input_kps[i].x = fr.x;
    input_kps[i].y = fr.y;
    input_kps[i].a11 = fr.a11;
    input_kps[i].a12 = fr.a12;
    input_kps[i].a21 = fr.a21;
    input_kps[i].a22 = fr.a22;
    input_kps[i].octave = feats[i].o;
    input_kps[i].pad0 = 0u;

    vl_size numOr = 0;
    VlCovDetFeatureOrientation* ors =
        vl_covdet_extract_orientations_for_frame(covdet, &numOr, fr);
    for (vl_size k = 0; k < numOr; ++k) {
      cpu_angle[i].push_back(ors[k].angle);
      cpu_score[i].push_back(ors[k].score);
    }
    cpu_total_or += static_cast<size_t>(numOr);
    cpu_count_hist[std::min<size_t>(numOr, 5)]++;
  }
  std::printf(
      "CPU orientations: total=%zu  per-kp count hist [0]=%zu [1]=%zu [2]=%zu "
      "[3]=%zu [4]=%zu\n",
      cpu_total_or, cpu_count_hist[0], cpu_count_hist[1], cpu_count_hist[2],
      cpu_count_hist[3], cpu_count_hist[4]);

  // CPU BASELINE timing (ORIENT_TIME set): time the BATCHED
  // vl_covdet_extract_orientations stage — the exact function the hybrid harness
  // (extract_hybrid_timing_s2.cc:561,872 cpu_orient_ms) measures as the ~47% /
  // ~955ms lever — on a FRESH covdet (detect+affine done, orientations not yet
  // run) so the cost is the orientation stage alone, apples-to-apples with the
  // GPU dispatch time reported below.
  if (std::getenv("ORIENT_TIME")) {
    VlCovDet* cdt = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(cdt, 0);
    vl_covdet_set_peak_threshold(cdt, 0.02 / 3.0);
    vl_covdet_set_edge_threshold(cdt, 10.0);
    vl_covdet_put_image(cdt, gray.data(), static_cast<vl_size>(iw),
                        static_cast<vl_size>(ih));
    vl_covdet_detect(cdt, 1u << 30);
    vl_covdet_extract_affine_shape(cdt);
    struct timespec c0, c1;
    clock_gettime(CLOCK_MONOTONIC, &c0);
    vl_covdet_extract_orientations(cdt);   // the measured CPU lever
    clock_gettime(CLOCK_MONOTONIC, &c1);
    const double cpu_ms =
        (c1.tv_sec - c0.tv_sec) * 1e3 + (c1.tv_nsec - c0.tv_nsec) / 1e6;
    std::printf(
        "CPU orientation stage (vl_covdet_extract_orientations, this host): "
        "%.1f ms  (%d input frames)\n",
        cpu_ms, nf);
    vl_covdet_delete(cdt);
  }

  // ── 3b. Build the flat multi-octave gss pyramid + geometry table. ──
  const int firstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int lastSub = static_cast<int>(g.octaveLastSubdivision);
  const int nLevels = lastSub - firstSub + 1;   // gss levels per octave
  const int firstO = static_cast<int>(g.firstOctave);
  const int lastO = static_cast<int>(g.lastOctave);
  const int nOct = lastO - firstO + 1;

  std::vector<OctaveGeom> geom(nOct);
  std::vector<float> pyramid;   // flat, octave-major then level-major
  {
    // First pass: sizes + offsets.
    uint32_t off = 0u;
    for (int o = firstO; o <= lastO; ++o) {
      VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
      const int W = static_cast<int>(og.width);
      const int H = static_cast<int>(og.height);
      OctaveGeom& gg = geom[o - firstO];
      gg.width = W;
      gg.height = H;
      gg.step = static_cast<float>(og.step);
      gg.gss_offset = off;
      gg.octave = o;
      gg.pad0 = gg.pad1 = gg.pad2 = 0u;
      off += static_cast<uint32_t>(W) * static_cast<uint32_t>(H) *
             static_cast<uint32_t>(nLevels);
    }
    pyramid.resize(off);
    // Second pass: copy level data.
    for (int o = firstO; o <= lastO; ++o) {
      VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
      const int W = static_cast<int>(og.width);
      const int H = static_cast<int>(og.height);
      const size_t plane = static_cast<size_t>(W) * H;
      const uint32_t base = geom[o - firstO].gss_offset;
      for (int lvl0 = 0; lvl0 < nLevels; ++lvl0) {
        const int s = firstSub + lvl0;
        const float* lv = vl_scalespace_get_level_const(gss, o, s);
        std::memcpy(pyramid.data() + base + static_cast<size_t>(lvl0) * plane,
                    lv, plane * sizeof(float));
      }
    }
  }
  std::printf("pyramid: %d octaves, %d levels/octave, %zu floats (%.1f MB)\n",
              nOct, nLevels, pyramid.size(),
              pyramid.size() * sizeof(float) / 1e6);

  // ── 4. Dispatch the GPU orientation kernel. ──
  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: Dawn harness init failed\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  std::string wgsl = read_file(wgsl_path);
  if (wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read WGSL %s\n", wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  const uint32_t kMaxOut = static_cast<uint32_t>(nf) * 4u + 16u;  // 4x cap

  auto pipeline = harness.load_compute(wgsl, "orient");

  wgpu::Buffer gss_buf =
      harness.upload(pyramid.data(), pyramid.size() * sizeof(float),
                     wgpu::BufferUsage::Storage);
  wgpu::Buffer kp_buf =
      harness.upload(input_kps.data(), input_kps.size() * sizeof(InputKp),
                     wgpu::BufferUsage::Storage);
  wgpu::Buffer geom_buf = harness.upload(
      geom.data(), geom.size() * sizeof(OctaveGeom), wgpu::BufferUsage::Storage);

  uint32_t zero = 0u;
  wgpu::Buffer count_buf =
      harness.upload(&zero, sizeof(uint32_t),
                     wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  const size_t out_bytes = static_cast<size_t>(kMaxOut) * sizeof(OrientedKp);
  wgpu::Buffer out_buf = harness.alloc(
      out_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  OrientParams P{};
  P.num_kp = static_cast<uint32_t>(nf);
  P.num_octaves = static_cast<uint32_t>(nOct);
  P.first_octave = firstO;
  P.last_octave = lastO;
  P.first_sub = firstSub;
  P.last_sub = lastSub;
  P.octave_res = static_cast<float>(g.octaveResolution);
  P.base_scale = static_cast<float>(g.baseScale);
  P.max_out = kMaxOut;
  wgpu::Buffer params_buf =
      harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);

  const uint32_t gx = (static_cast<uint32_t>(nf) + 63u) / 64u;
  // Binding order matches the WGSL: gss(0) kps(1) geom(2) out_count(3)
  // out_kp(4) P(5).
  harness.dispatch(pipeline,
                   {gss_buf, kp_buf, geom_buf, count_buf, out_buf, params_buf},
                   gx > 0 ? gx : 1u, 1u, 1u);

  // Read back the count + the records.
  wgpu::Buffer cstage = harness.alloc_staging_for_readback(sizeof(uint32_t));
  harness.copy_to_staging(count_buf, cstage, sizeof(uint32_t));
  std::vector<uint8_t> cbytes = harness.readback(cstage, sizeof(uint32_t));
  uint32_t gpu_total = 0u;
  std::memcpy(&gpu_total, cbytes.data(), sizeof(uint32_t));
  const uint32_t kept = std::min(gpu_total, kMaxOut);

  std::vector<OrientedKp> gpu_recs(kept);
  if (kept > 0) {
    const size_t kbytes = static_cast<size_t>(kept) * sizeof(OrientedKp);
    wgpu::Buffer kstage = harness.alloc_staging_for_readback(kbytes);
    harness.copy_to_staging(out_buf, kstage, kbytes);
    std::vector<uint8_t> kb = harness.readback(kstage, kbytes);
    std::memcpy(gpu_recs.data(), kb.data(), kbytes);
  }
  std::printf("GPU orientations: total=%u (atomic=%u%s)\n", kept, gpu_total,
              gpu_total > kMaxOut ? " SATURATED" : "");

  // ── 5. Group GPU records by kp_index. ──
  std::vector<std::vector<double>> gpu_angle(nf);
  std::vector<std::vector<double>> gpu_score(nf);
  for (const auto& r : gpu_recs) {
    if (r.kp_index < static_cast<uint32_t>(nf)) {
      gpu_angle[r.kp_index].push_back(static_cast<double>(r.angle));
      gpu_score[r.kp_index].push_back(static_cast<double>(r.score));
    }
  }

  // ── 6. Expansion-count agreement + orientation-error distribution. ──
  size_t count_match = 0;
  size_t count_mismatch = 0;
  size_t gpu_count_hist[6] = {0, 0, 0, 0, 0, 0};
  std::vector<double> ang_err_deg;   // matched-orientation errors, degrees
  ang_err_deg.reserve(cpu_total_or);
  size_t over_1deg = 0;
  // count of kps where #orientations differ, broken down.
  size_t both_have = 0;  // kps where both produced >=1 orientation

  for (int i = 0; i < nf; ++i) {
    const size_t cN = cpu_angle[i].size();
    const size_t gN = gpu_angle[i].size();
    gpu_count_hist[std::min<size_t>(gN, 5)]++;
    if (cN == gN) {
      ++count_match;
    } else {
      ++count_mismatch;
    }
    if (cN == 0 || gN == 0) continue;
    ++both_have;

    // Greedy match: for each CPU angle, find the nearest unused GPU angle.
    std::vector<bool> used(gN, false);
    for (size_t c = 0; c < cN; ++c) {
      double best = 1e9;
      long bj = -1;
      for (size_t gj = 0; gj < gN; ++gj) {
        if (used[gj]) continue;
        double d = circ_dist(cpu_angle[i][c], gpu_angle[i][gj]);
        if (d < best) {
          best = d;
          bj = static_cast<long>(gj);
        }
      }
      if (bj >= 0) {
        used[static_cast<size_t>(bj)] = true;
        const double deg = best * 180.0 / kPi;
        ang_err_deg.push_back(deg);
        if (deg > 1.0) ++over_1deg;
      }
    }
  }

  // Stats.
  double median = 0, mean = 0, p95 = 0, p99 = 0, maxe = 0;
  if (!ang_err_deg.empty()) {
    std::sort(ang_err_deg.begin(), ang_err_deg.end());
    median = ang_err_deg[ang_err_deg.size() / 2];
    maxe = ang_err_deg.back();
    p95 = ang_err_deg[static_cast<size_t>(0.95 * (ang_err_deg.size() - 1))];
    p99 = ang_err_deg[static_cast<size_t>(0.99 * (ang_err_deg.size() - 1))];
    for (double e : ang_err_deg) mean += e;
    mean /= static_cast<double>(ang_err_deg.size());
  }

  std::printf(
      "\n=== ORIENTATION PARITY vs VLFeat vl_covdet_extract_orientations ===\n");
  std::printf("input keypoints (frames)     : %d\n", nf);
  std::printf("CPU total orientations       : %zu\n", cpu_total_or);
  std::printf("GPU total orientations       : %u\n", kept);
  std::printf(
      "GPU per-kp count hist        : [0]=%zu [1]=%zu [2]=%zu [3]=%zu [4]=%zu\n",
      gpu_count_hist[0], gpu_count_hist[1], gpu_count_hist[2], gpu_count_hist[3],
      gpu_count_hist[4]);
  std::printf(
      "expansion-count agreement    : %zu/%d kps match (%.4f%%), %zu mismatch\n",
      count_match, nf, 100.0 * static_cast<double>(count_match) / nf,
      count_mismatch);
  std::printf("total-count agreement        : GPU %u vs CPU %zu (delta %+ld)\n",
              kept, cpu_total_or,
              static_cast<long>(kept) - static_cast<long>(cpu_total_or));
  std::printf(
      "orientation error (deg)      : median=%.6f mean=%.6f p95=%.6f p99=%.6f "
      "max=%.6f  (N=%zu matched, >1deg: %zu = %.4f%%)\n",
      median, mean, p95, p99, maxe, ang_err_deg.size(), over_1deg,
      ang_err_deg.empty() ? 0.0
                          : 100.0 * static_cast<double>(over_1deg) /
                                static_cast<double>(ang_err_deg.size()));

  // ── Gate: PLAN line 70 — orient median <= 1 deg. Also require the
  // expansion-count to substantially agree (a kernel that drops/adds many
  // orientations would pass a median test on the survivors while corrupting the
  // feature set). Report both; gate on the median (the PLAN's stated gate) and a
  // generous >=0.97 count-agreement guard.
  const double kMedianGateDeg = 1.0;
  const double kCountAgreeGate = 0.97;
  const double count_agree = static_cast<double>(count_match) / nf;
  const bool median_ok = median <= kMedianGateDeg;
  const bool count_ok = count_agree >= kCountAgreeGate;
  const bool pass = median_ok && count_ok && !ang_err_deg.empty();
  std::printf(
      "\ngate: orient-median<=%.2fdeg (%.6f %s) AND count-agree>=%.2f (%.6f %s) "
      " =>  %s\n",
      kMedianGateDeg, median, median_ok ? "ok" : "FAIL", kCountAgreeGate,
      count_agree, count_ok ? "ok" : "FAIL", pass ? "PASS" : "FAIL");

  // ── Optional timing (ORIENT_TIME=N): re-dispatch N times measuring
  // wall-clock. Placed AFTER the parity readback so it cannot pollute the
  // validated result (the re-dispatches keep incrementing the shared atomic
  // out_count, but the GPU WORK per dispatch — svd2/warp/smooth/histogram — is
  // identical regardless of the count, so the time/dispatch is valid). dispatch()
  // submits+waits synchronously; gss is already resident (in S4 it never
  // round-trips), so this is the per-frame orientation-stage GPU cost. Default
  // (env unset) leaves the parity run untouched.
  if (const char* tn = std::getenv("ORIENT_TIME")) {
    int reps = std::atoi(tn);
    if (reps < 1) reps = 1;
    for (int w = 0; w < 2; ++w) {   // warm pipeline/cache
      harness.dispatch(
          pipeline,
          {gss_buf, kp_buf, geom_buf, count_buf, out_buf, params_buf},
          gx > 0 ? gx : 1u, 1u, 1u);
    }
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < reps; ++r) {
      harness.dispatch(
          pipeline,
          {gss_buf, kp_buf, geom_buf, count_buf, out_buf, params_buf},
          gx > 0 ? gx : 1u, 1u, 1u);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    const double ms =
        ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6) /
        static_cast<double>(reps);
    std::printf(
        "\nGPU orient dispatch (incl submit+wait, gss resident): %.3f "
        "ms/dispatch  (%d kps over %d reps)\n",
        ms, nf, reps);
  }

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  const char* img =
      "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* wgsl = "shaders/wgsl/sift_orientation.wgsl";
  if (argc > 1) img = argv[1];
  if (argc > 2) wgsl = argv[2];
  return run(img, wgsl);
}
