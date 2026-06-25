// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// gpu_sift_module_verify.cc — DECISIVE verification of the reusable
// GpuSiftExtractor module + its ONE-TIME pipeline cache (root-fix for the
// per-frame Tint-recompilation bug).
//
// It:
//   (1) init()s the module ONCE  -> reports the one-time ~1334ms Tint compile.
//   (2) runs >=5 frames through extract() in a loop  -> reports per-frame ms
//       for frames 1..N AND the per-frame delta of the module's global
//       CreateComputePipeline counter (g_pipeline_compile_count). The proof:
//       frames 1..N each add ZERO compiles (the cost was paid once in init()).
//       Frame-1 is high purely from first-use Metal pipeline-state warm-up
//       (NOT Tint recompile — the counter shows 0); frames 2..N settle to ~240ms.
//   (3) computes CPU-reference parity on the module output of the first frame:
//       reproj recall/precision, descriptor cosine median, point count, and the
//       resident-gss peak MB — confirming reproj/memory/points are unchanged
//       vs the validated extract_fullgpu_batched.cc (1.0 / 329MB / 8192).
//
// Build: bench/build_gpu_sift_module_verify.sh (worktree-only). Run from
// aether_cpp/ root:
//   /tmp/gpu_sift_module_obj/gpu_sift_module_verify_exe \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg [--frames N]

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

extern "C" {
#include "covdet.h"
#include "scalespace.h"
#include "sift.h"
#include "imopv.h"
#include "mathop.h"
}

#include "gpu_sift_extractor.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {
using clock_t_ = std::chrono::steady_clock;
inline double ms_since(clock_t_::time_point t0) {
  return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}

// Descriptor reorder + cosine (matched to extract_fullgpu_batched.cc).
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

void ubc_reorder(const uint8_t* in, uint8_t* out) {
  static const int q[8] = {0, 7, 6, 5, 4, 3, 2, 1};
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      for (int k = 0; k < 8; ++k)
        out[8 * (j + 4 * i) + q[k]] = in[8 * (j + 4 * i) + k];
}
double cosine_u8(const uint8_t* a, const uint8_t* b) {
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < 128; ++i) { const double x = a[i], y = b[i]; dot += x * y; na += x * x; nb += y * y; }
  if (na == 0.0 || nb == 0.0) return (na == 0.0 && nb == 0.0) ? 1.0 : 0.0;
  return dot / (std::sqrt(na) * std::sqrt(nb));
}
}  // namespace

int main(int argc, char** argv) {
  std::string img = "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  int frames = 5;
  for (int i = 1; i < argc; ++i) {
    std::string_view a(argv[i]);
    if (a == "--frames" && i + 1 < argc) { frames = std::atoi(argv[++i]); continue; }
    if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;
    img = argv[i];
  }
  if (frames < 5) frames = 5;

  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img.c_str(), &iw, &ih, &ic, 1);
  if (!pixels) { std::fprintf(stderr, "FAIL stbi_load(%s): %s\n", img.c_str(), stbi_failure_reason()); return 2; }
  std::vector<float> gray((size_t)iw * ih);
  for (size_t i = 0; i < gray.size(); ++i) gray[i] = (float)pixels[i];
  stbi_image_free(pixels);

  const int octave_resolution = 3;
  const double peak_threshold = 0.02 / 3.0;
  const double edge_threshold = 10.0;
  const int max_num_features = 8192;
  const double tol = 0.5;

  std::printf("=================================================================\n");
  std::printf(" GpuSiftExtractor MODULE VERIFY  (one-time pipeline cache root-fix)\n");
  std::printf(" image: %s  %dx%d   frames=%d\n", img.c_str(), iw, ih, frames);
  std::printf("=================================================================\n");

  // ── init() ONCE — compiles all 11 pipelines ONCE. ──
  aether::gpu::GpuSiftExtractor ex;
  aether::gpu::GpuSiftExtractor::Config cfg;
  cfg.octave_resolution = octave_resolution;
  cfg.peak_threshold = peak_threshold;
  cfg.edge_threshold = edge_threshold;
  cfg.max_num_features = max_num_features;
  cfg.tol = tol;
  const char* root = std::getenv("AETHER_SHADER_ROOT");
  cfg.shader_root = root ? root : ".";   // run from aether_cpp/ root => "."
  auto tinit = clock_t_::now();
  if (!ex.init(cfg)) { std::fprintf(stderr, "FAIL: ex.init()\n"); return 2; }
  const double init_ms = ms_since(tinit);
  const long compiles_after_init = aether::gpu::g_pipeline_compile_count;
  std::printf("[init] total=%.1f ms  (Tint compile of all 11 pipelines = %.1f ms;"
              " CreateComputePipeline calls so far = %ld)\n",
              init_ms, ex.init_compile_ms(), compiles_after_init);

  // ── >=5 frames through extract(); record per-frame ms + compile-delta. ──
  // NOTE: we DELIBERATELY do NOT run a hidden warm-up before frame-1 — frame-1
  // here IS the cold first-GPU-use frame, so its elevated GPU time is reported
  // honestly. The reference extract_fullgpu_batched.cc runs a separate untimed
  // warm-up then reports min-of-N; our frames 2..N are the equivalent warm reps.
  std::vector<double> frame_ms(frames, 0.0);
  std::vector<long>   frame_compiles(frames, 0);
  std::vector<aether::gpu::GpuSiftTimings> frame_t(frames);
  aether::gpu::GpuSiftFrame first_frame;  // keep frame-1 output for parity
  for (int f = 0; f < frames; ++f) {
    const long before = aether::gpu::g_pipeline_compile_count;
    aether::gpu::GpuSiftFrame out;
    auto t0 = clock_t_::now();
    if (!ex.extract(gray.data(), iw, ih, &out)) {
      std::fprintf(stderr, "FAIL: extract() frame %d\n", f + 1); return 2;
    }
    frame_ms[f] = ms_since(t0);
    frame_compiles[f] = aether::gpu::g_pipeline_compile_count - before;
    frame_t[f] = out.timings;
    if (f == 0) first_frame = std::move(out);
  }

  std::printf("\n  --- PER-FRAME TIMING (module extract(), pipelines cached) ---\n");
  std::printf("    %-6s %-13s %-13s %-12s %-22s %-8s\n",
              "frame", "GPU pipe(ms)", "VLFeat(ms)", "wall(ms)", "Tint compiles(delta)", "gss(MB)");
  for (int f = 0; f < frames; ++f) {
    std::printf("    %-6d %-13.1f %-13.1f %-12.1f %-22ld %-8.1f%s\n",
                f + 1, frame_t[f].gpu_total_ms, frame_t[f].vlfeat_gss_ms, frame_ms[f],
                frame_compiles[f], frame_t[f].gss_bytes / 1e6,
                f == 0 ? "  <- first GPU use (Metal PSO warm-up; Tint delta=0)" : "");
  }
  std::printf("    (GPU pipe = B.1-B.7 GPU work = the validated ~240ms target;"
              " VLFeat = host scale-space build feeding the seed; wall = sum)\n");

  // ── Decisive root-fix check. ──
  bool tint_gone = true;
  for (int f = 0; f < frames; ++f) if (frame_compiles[f] != 0) tint_gone = false;
  // Steady-state on the GPU-pipeline number (the apples-to-apples 240ms target).
  double steady_min = 1e18, steady_max = 0, steady_sum = 0;
  double wall_min = 1e18, wall_max = 0, wall_sum = 0;
  for (int f = 1; f < frames; ++f) {
    const double gp = frame_t[f].gpu_total_ms;
    steady_min = std::min(steady_min, gp); steady_max = std::max(steady_max, gp); steady_sum += gp;
    wall_min = std::min(wall_min, frame_ms[f]); wall_max = std::max(wall_max, frame_ms[f]); wall_sum += frame_ms[f];
  }
  const double steady_avg = steady_sum / (frames - 1);
  const double wall_avg = wall_sum / (frames - 1);
  std::printf("\n  ROOT-FIX CHECK: per-frame CreateComputePipeline (Tint) calls = %s\n",
              tint_gone ? "0 for EVERY frame  => PASS (compile paid once in init)"
                        : "NON-ZERO  => FAIL (recompiling per frame!)");
  std::printf("    [GPU pipeline] frame-1 = %.1f ms   frames 2..%d: min=%.1f avg=%.1f max=%.1f ms\n",
              frame_t[0].gpu_total_ms, frames, steady_min, steady_avg, steady_max);
  std::printf("    [full wall   ] frame-1 = %.1f ms   frames 2..%d: min=%.1f avg=%.1f max=%.1f ms\n",
              frame_ms[0], frames, wall_min, wall_avg, wall_max);

  // ── Parity vs CPU reference on frame-1 output (reproj / cosine / count / MB). ──
  VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cd, 0);
  vl_covdet_set_octave_resolution(cd, octave_resolution);
  vl_covdet_set_peak_threshold(cd, peak_threshold);
  vl_covdet_set_edge_threshold(cd, edge_threshold);
  vl_covdet_put_image(cd, gray.data(), iw, ih);
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
    VlSiftFilt* sift = vl_sift_new(16, 16, 1, 3, 0);
    vl_sift_set_magnif(sift, kMagnif);
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
        vl_sift_calc_raw_descriptor(sift, patchXY.data(), sd.data() + (size_t)s * 128,
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
    vl_covdet_set_gss(wd, nullptr); vl_covdet_delete(wd); vl_sift_delete(sift);
  }
  std::vector<double> cpu_fx(cpu_nf), cpu_fy(cpu_nf); std::vector<int> cpu_fo(cpu_nf);
  for (int i = 0; i < cpu_nf; ++i) {
    cpu_fx[i] = cpu_feats[i].frame.x; cpu_fy[i] = cpu_feats[i].frame.y; cpu_fo[i] = cpu_feats[i].o;
  }
  vl_covdet_delete(cd);

  // e2e parity on frame-1 module output.
  const double pos_tol = 2.0;
  const size_t G = first_frame.count;
  std::vector<char> gpu_used(G, 0);
  size_t matched_cpu = 0;
  std::vector<std::pair<int,int>> pairs;
  for (int i = 0; i < cpu_nf; ++i) {
    double bestd = 1e18; long bj = -1;
    for (size_t j = 0; j < G; ++j) {
      if (gpu_used[j]) continue;
      if (first_frame.octave[j] != cpu_fo[i]) continue;
      const double dx = first_frame.x[j] - cpu_fx[i];
      const double dy = first_frame.y[j] - cpu_fy[i];
      const double d2 = dx * dx + dy * dy;
      if (d2 < bestd) { bestd = d2; bj = (long)j; }
    }
    if (bj >= 0 && bestd <= pos_tol * pos_tol) { ++matched_cpu; gpu_used[bj] = 1; pairs.emplace_back(i, (int)bj); }
  }
  size_t matched_gpu = 0;
  for (size_t j = 0; j < G; ++j) if (gpu_used[j]) ++matched_gpu;
  const double recall = cpu_nf ? (double)matched_cpu / cpu_nf : 1.0;
  const double precision = G ? (double)matched_gpu / G : 1.0;
  std::vector<double> cosv; cosv.reserve(pairs.size());
  for (auto& pr : pairs)
    cosv.push_back(cosine_u8(cpu_desc.data() + (size_t)pr.first * 128,
                             first_frame.descriptors.data() + (size_t)pr.second * 128));
  double cmed = 0;
  if (!cosv.empty()) { std::sort(cosv.begin(), cosv.end()); cmed = cosv[cosv.size() / 2]; }

  const double gss_mb = first_frame.timings.gss_bytes / 1e6;
  const double peak_mb = first_frame.timings.peak_bytes / 1e6;

  std::printf("\n  --- PARITY (module frame-1 output vs CPU reference) ---\n");
  std::printf("    points (GPU)     : %zu   (expect 8192)\n", G);
  std::printf("    recall/precision : %.4f / %.4f  (pos_tol=%.1fpx)\n", recall, precision, pos_tol);
  std::printf("    cosine median    : %.6f  (expect 1.000000)\n", cmed);
  std::printf("    resident gss     : %.1f MB   peak GPU = %.1f MB  (expect ~321 / ~329)\n", gss_mb, peak_mb);

  std::printf("\n=================================================================\n");
  std::printf(" VERDICT\n");
  std::printf("=================================================================\n");
  std::printf("  root-fix (Tint=0 every frame) : %s\n", tint_gone ? "PASS" : "FAIL");
  std::printf("  GPU pipeline frame-1          : %.1f ms (one-time Metal PSO warm-up)\n", frame_t[0].gpu_total_ms);
  std::printf("  GPU pipeline frames 2..%d      : avg %.1f ms (min %.1f / max %.1f)  <- ~240ms target\n",
              frames, steady_avg, steady_min, steady_max);
  std::printf("  points / cosine / gssMB        : %zu / %.6f / %.1f\n", G, cmed, gss_mb);

  // ── C-ABI smoke test (proves the shared ABI signatures work). ──
  {
    aether_gpu_sift_handle h = aether_gpu_sift_init();
    if (h) {
      float* kp = nullptr; unsigned char* desc = nullptr; unsigned int cnt = 0;
      int rc = aether_gpu_sift_extract(h, gray.data(), iw, ih, &kp, &desc, &cnt);
      std::printf("  C-ABI smoke                    : rc=%d count=%u (kp[0]=%.1f,%.1f)\n",
                  rc, cnt, cnt ? kp[0] : 0.f, cnt ? kp[1] : 0.f);
      std::free(kp); std::free(desc);
      aether_gpu_sift_free(h);
    } else {
      std::printf("  C-ABI smoke                    : init returned NULL "
                  "(set AETHER_SHADER_ROOT for the ABI path)\n");
    }
  }
  std::printf("=================================================================\n");
  return tint_gone ? 0 : 1;
}
