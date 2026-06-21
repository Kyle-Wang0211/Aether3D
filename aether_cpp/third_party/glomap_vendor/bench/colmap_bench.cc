// colmap_bench.cc — on-device benchmark of COLMAP *incremental* SfM
// (register one image at a time + repeated local/global BA), for apples-to-
// apples comparison vs the GLOMAP global mapper on the same db_50.
// C ABI for Dart FFI / native harness.

#include "colmap/controllers/incremental_pipeline.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"

#include <glog/logging.h>

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

static double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

extern "C" int colmap_bench(const char* db_path,
                            const char* image_path,
                            char* out_json,
                            int out_cap) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    auto recon_manager = std::make_shared<colmap::ReconstructionManager>();

    const double t0 = NowMs();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                         recon_manager);
    pipeline.Run();
    const double solve_ms = NowMs() - t0;

    // pick the largest reconstruction; report its quality (incl. reproj error —
    // COLMAP incremental triangulates + retriangulates natively, so this IS the
    // "with re-tri" quality number).
    size_t best_reg = 0, best_pts = 0;
    double best_reproj = 0.0, best_track = 0.0;
    for (size_t i = 0; i < recon_manager->Size(); ++i) {
      const auto& recon = recon_manager->Get(i);
      if (recon->NumRegImages() > best_reg) {
        best_reg = recon->NumRegImages();
        best_pts = recon->NumPoints3D();
        best_reproj = recon->ComputeMeanReprojectionError();
        best_track = recon->ComputeMeanTrackLength();
      }
    }

    std::snprintf(out_json, out_cap,
                  "{\"solve_ms\":%.1f,\"n_models\":%zu,\"n_registered\":%zu,"
                  "\"n_points3d\":%zu,\"reproj_px\":%.4f,\"track_len\":%.3f}",
                  solve_ms, recon_manager->Size(), best_reg, best_pts, best_reproj,
                  best_track);
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

// Per-frame incremental cost: record a cumulative timestamp every time the
// incremental pipeline registers an image, via COLMAP's registration callbacks.
// Deltas between consecutive stamps = cost to register that image (incl. the
// local/global BA fired in between) -> validates "can it keep up with capture".
extern "C" int colmap_bench_perframe(const char* db_path,
                                     const char* image_path,
                                     char* out_json,
                                     int out_cap) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    auto recon_manager = std::make_shared<colmap::ReconstructionManager>();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                         recon_manager);
    std::vector<double> stamps;
    const double t0 = NowMs();
    pipeline.AddCallback(
        colmap::IncrementalPipeline::INITIAL_IMAGE_PAIR_REG_CALLBACK,
        [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.AddCallback(
        colmap::IncrementalPipeline::NEXT_IMAGE_REG_CALLBACK,
        [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.Run();
    const double total = NowMs() - t0;

    std::string arr = "[";
    for (size_t i = 0; i < stamps.size(); ++i) {
      char b[24];
      std::snprintf(b, sizeof(b), "%s%.0f", i ? "," : "", stamps[i]);
      arr += b;
    }
    arr += "]";
    std::snprintf(out_json, out_cap,
                  "{\"total_ms\":%.0f,\"n_steps\":%zu,\"cum_ms\":%s}", total,
                  stamps.size(), arr.c_str());
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}
