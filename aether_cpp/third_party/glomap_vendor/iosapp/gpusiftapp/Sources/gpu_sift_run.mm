// On-device GPU DSP-SIFT extractor runner (iOS, Dawn->Tint->Metal, A16).
//
// Runs the production GpuSiftExtractor (src/gpu/gpu_sift_extractor.{h,cc}) on the
// iPhone's GPU: init() ONCE (compile-once: all 11 compute pipelines Tint-compiled
// in init, NOT per frame), then extract() on a 4224x2376 grayscale frame for N=10
// frames in a loop. Per-frame ms (frame-1 cold vs frames 2..10 warm) + keypoint
// count + the extractor's internal GPU-stage timing breakdown are logged.
//
// This is the on-device confirmation of the M3-Pro->A16 x2.9 estimate (~790ms).
// Peak RSS + thermal state are sampled by the AppDelegate harness around this run.
//
// Exposes a single C entry `gpu_sift_run_all(const char* shader_root,
// const char* jpg_path, char* out, int out_cap)` callable from the ObjC
// AppDelegate. Logs progress via printf (mirrored to the on-screen console +
// Documents/aether_console.log by the AppDelegate). Returns 0 on success.

#include "gpu_sift_extractor.h"

#include <os/log.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

void logline(const char* s) {
  printf("%s\n", s);
  fflush(stdout);
  os_log(OS_LOG_DEFAULT, "%{public}s", s);
}

using clk = std::chrono::high_resolution_clock;
double ms_since(std::chrono::time_point<clk> t0) {
  return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}

}  // namespace

// gray: row-major float intensity image (0..255), w*h elements. The AppDelegate
// decodes the bundled sift_test.jpg to this format and passes it in.
extern "C" int gpu_sift_run_all(const char* shader_root, const float* gray,
                                int w, int h, char* out, int out_cap) {
  if (out && out_cap > 0) out[0] = 0;
  char b[512];

  snprintf(b, sizeof(b), "GPUSIFT_BEGIN shader_root=%s img=%dx%d",
           shader_root ? shader_root : "(null)", w, h);
  logline(b);

  if (!gray || w <= 0 || h <= 0) { logline("GPUSIFT_FAIL bad_image"); return 1; }

  // ── init() ONCE: device + 11 Tint pipeline compiles + resident buffers. The
  //    compile-once root-fix: the per-frame loop below must NOT recompile (the
  //    g_pipeline_compile_count delta proves it). ──
  aether::gpu::GpuSiftExtractor ex;
  aether::gpu::GpuSiftExtractor::Config cfg{};
  cfg.shader_root = shader_root;  // bundle dir holding shaders/wgsl/*.wgsl

  long compiles_before = aether::gpu::g_pipeline_compile_count;
  auto t_init = clk::now();
  if (!ex.init(cfg)) {
    logline("GPUSIFT_FAIL init (Dawn device / WGSL->Tint->Metal compile / buffer "
            "limits) — see stderr above");
    return 2;
  }
  double init_ms = ms_since(t_init);
  long compiles_init = aether::gpu::g_pipeline_compile_count - compiles_before;
  snprintf(b, sizeof(b),
           "GPUSIFT_INIT_OK init_ms=%.1f tint_compile_ms=%.1f pipelines_compiled=%ld",
           init_ms, ex.init_compile_ms(), compiles_init);
  logline(b);

  // ── extract() x N: frame 1 = cold, frames 2..N = warm. ──
  constexpr int N = 10;
  std::vector<double> warm_ms;
  warm_ms.reserve(N);
  double frame1_ms = 0.0;

  for (int f = 0; f < N; ++f) {
    long pc_before = aether::gpu::g_pipeline_compile_count;
    aether::gpu::GpuSiftFrame frame;
    auto t0 = clk::now();
    bool ok = ex.extract(gray, w, h, &frame);
    double e_ms = ms_since(t0);
    long pc_delta = aether::gpu::g_pipeline_compile_count - pc_before;

    if (!ok) {
      snprintf(b, sizeof(b), "GPUSIFT_FAIL extract frame=%d", f);
      logline(b);
      return 3;
    }
    const aether::gpu::GpuSiftTimings& T = frame.timings;
    snprintf(b, sizeof(b),
             "GPUSIFT_FRAME f=%d %s ms=%.1f kp=%zu recompiles=%ld | gss=%.1f "
             "detect=%.1f suppress=%.1f affine=%.1f orient=%.1f desc=%.1f "
             "gpu_total=%.1f gss_MB=%.0f peak_MB=%.0f",
             f, (f == 0 ? "COLD" : "warm"), e_ms, frame.count, pc_delta,
             T.gss_ms, T.detect_refine_ms, T.suppress_ms, T.affine_ms,
             T.orient_ms, T.desc_ms, T.gpu_total_ms,
             T.gss_bytes / (1024.0 * 1024.0), T.peak_bytes / (1024.0 * 1024.0));
    logline(b);

    if (f == 0) frame1_ms = e_ms;
    else warm_ms.push_back(e_ms);
  }

  // ── Summary: cold (frame 1) vs warm (frames 2..N) median/min/max. ──
  double wmin = 0, wmax = 0, wmed = 0;
  if (!warm_ms.empty()) {
    std::vector<double> s = warm_ms;
    std::sort(s.begin(), s.end());
    wmin = s.front();
    wmax = s.back();
    wmed = s[s.size() / 2];
  }
  snprintf(b, sizeof(b),
           "GPUSIFT_SUMMARY cold_ms=%.1f warm_med_ms=%.1f warm_min_ms=%.1f "
           "warm_max_ms=%.1f n_warm=%zu (M3Pro~240-273ms; A16 x2.9 est~790ms)",
           frame1_ms, wmed, wmin, wmax, warm_ms.size());
  logline(b);
  logline("GPUSIFT_DONE");
  if (out && out_cap > 0) { strncpy(out, b, out_cap - 1); out[out_cap - 1] = 0; }
  return 0;
}
