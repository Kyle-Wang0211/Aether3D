// ba_replay_bench.cc — [AETHER LAPACK-TIER SCAN 2026-07-12] HOST-ONLY harness
// that replays ONLY the finalize/extra CAUCHY global BA on a saved
// pre-extra-BA colmap model (written by glomap_bench with AETHER_PREBA_DIR),
// alternating the dense Cholesky backend in the SAME process:
//   arm E = AETHER_DENSE_LAPACK=0  (force Eigen LLT)
//   arm L = AETHER_DENSE_LAPACK=1  (force Accelerate LAPACK)
//   arm D = env unset              (tier routing decides — default-path check)
// Every round starts from a pristine deep copy of the loaded model, so rounds
// are an identical workload; back-to-back same-process alternation is the
// project's heat-controlled timing recipe (single wall clocks are +-30%).
//
// BA options replicate the production finalize / glomap_bench extra BA:
// CAUCHY@1.0, ftol=1e-5 (AETHER_EXTRA_FTOL overrides), all hardware threads,
// TWO_CAMS_FROM_WORLD gauge, FilterObservationsWithNegativeDepth applied once
// on the template. max_num_images_direct_dense_cpu_solver=1000 mirrors the
// production finalize (incremental_pipeline.cc) so the solver routes
// DENSE_SCHUR exactly like on-device dome finalize.
//
// --subset=N prunes the loaded model to its first N registered images (by
// image id; contiguous dome arc, stays connected) BEFORE replaying: track
// elements of dropped images are removed, points falling under 2 observations
// are deleted. This carves size-N BA problems out of ONE parent model so every
// tier of the inflection scan shares provenance + convergence state (the
// GLOMAP chain's global-positioning stage dies on the small standalone dbs —
// a pre-existing 4.0.4-migration pathology unrelated to this scan).
//
// usage: ba_replay_bench_exe <model_dir> [--seq=E,L,E,L] [--threads=N]
//                            [--subset=N]

#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/sfm/observation_manager.h"

#include <glog/logging.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

namespace colmap {
// Telemetry stash written by bundle_adjustment_ceres.cc after every solve —
// signature must stay in lockstep with the definition there (and the
// declaration in aether_sfm_c.cc).
void AetherLastBaSolveInfo(std::string* solver_used,
                           std::string* sparse_backend,
                           int* mixed,
                           int* threads,
                           std::string* dense_backend);
}  // namespace colmap

namespace {

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

std::string ArgS(int argc, char** argv, const char* key, const char* def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::string(eq + 1);
    }
  return std::string(def);
}

}  // namespace

int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: %s <model_dir> [--seq=E,L,E,L] [--threads=N]\n",
                 argv[0]);
    return 1;
  }
  const std::string model_dir = argv[1];
  const std::string seq = ArgS(argc, argv, "--seq", "E,L,E,L");
  const int threads =
      std::atoi(ArgS(argc, argv, "--threads",
                     std::to_string(std::thread::hardware_concurrency())
                         .c_str())
                    .c_str());

  // Template: load once, sanitize once (same pre-BA filter production runs),
  // then deep-copy per round so every round solves the identical problem.
  colmap::Reconstruction tmpl;
  tmpl.Read(model_dir);

  const int subset = std::atoi(ArgS(argc, argv, "--subset", "0").c_str());
  if (subset > 0) {
    std::vector<colmap::image_t> reg = tmpl.RegImageIds();
    std::sort(reg.begin(), reg.end());
    if (static_cast<size_t>(subset) < reg.size()) {
      std::unordered_set<colmap::image_t> keep(reg.begin(),
                                               reg.begin() + subset);
      // DeRegisterFrame goes through DeleteObservation for every observed
      // point2D, which keeps tracks/backlinks consistent and deletes points
      // that fall under 2 observations — exactly the pruning we want.
      std::unordered_set<colmap::frame_t> drop_frames;
      for (const colmap::image_t iid : reg)
        if (!keep.count(iid)) drop_frames.insert(tmpl.Image(iid).FrameId());
      // Never deregister a frame that also carries a kept image (dome
      // captures are one image per frame; this is a safety guard).
      for (const colmap::image_t iid : reg)
        if (keep.count(iid)) drop_frames.erase(tmpl.Image(iid).FrameId());
      for (const colmap::frame_t fid : drop_frames) tmpl.DeRegisterFrame(fid);
    }
  }

  colmap::ObservationManager(tmpl).FilterObservationsWithNegativeDepth();
  const size_t n_img = tmpl.NumRegImages();
  const size_t n_pts = tmpl.NumPoints3D();
  double reproj_before = -1.0;
  try {
    reproj_before = tmpl.ComputeMeanReprojectionError();
  } catch (...) {}
  std::printf("TEMPLATE model=%s n_reg_images=%zu n_points=%zu "
              "reproj_before=%.4f threads=%d seq=%s\n",
              model_dir.c_str(), n_img, n_pts, reproj_before, threads,
              seq.c_str());
  std::fflush(stdout);

  int round = 0;
  for (size_t pos = 0; pos < seq.size(); ++pos) {
    const char arm = seq[pos];
    if (arm == ',' || arm == ' ') continue;
    ++round;
    if (arm == 'E') {
      setenv("AETHER_DENSE_LAPACK", "0", 1);
    } else if (arm == 'L') {
      setenv("AETHER_DENSE_LAPACK", "1", 1);
    } else if (arm == 'D') {
      unsetenv("AETHER_DENSE_LAPACK");
    } else {
      std::fprintf(stderr, "unknown arm '%c' (want E/L/D)\n", arm);
      return 1;
    }

    auto recon = std::make_shared<colmap::Reconstruction>(tmpl);  // deep copy

    colmap::BundleAdjustmentOptions ba_options;
    ba_options.ceres->loss_function_type =
        colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
    ba_options.ceres->loss_function_scale = 1.0;
    ba_options.ceres->solver_options.num_threads = threads;
    ba_options.ceres->solver_options.function_tolerance = 1e-5;
    if (const char* e = std::getenv("AETHER_EXTRA_FTOL"))
      ba_options.ceres->solver_options.function_tolerance = atof(e);
    // Production finalize parity: DENSE_SCHUR for <=1000 images
    // (incremental_pipeline.cc [AETHER] 2026-06-25 FINAL; sparse cap must be
    // raised in lockstep — options.Check() requires dense < sparse).
    ba_options.ceres->max_num_images_direct_dense_cpu_solver = 1000;
    ba_options.ceres->max_num_images_direct_sparse_cpu_solver = 5000;

    colmap::BundleAdjustmentConfig ba_config;
    for (const colmap::image_t image_id : recon->RegImageIds())
      ba_config.AddImage(image_id);
    ba_config.FixGauge(colmap::BundleAdjustmentGauge::TWO_CAMS_FROM_WORLD);

    const double t0 = NowMs();
    std::shared_ptr<colmap::BundleAdjustmentSummary> summary;
    try {
      std::unique_ptr<colmap::BundleAdjuster> bundle_adjuster =
          colmap::CreateDefaultBundleAdjuster(ba_options, ba_config, *recon);
      summary = bundle_adjuster->Solve();
    } catch (const std::exception& e) {
      std::printf("ROUND round=%d arm=%c status=throw what=%s\n", round, arm,
                  e.what());
      std::fflush(stdout);
      continue;
    }
    const double ba_ms = NowMs() - t0;
    recon->UpdatePoint3DErrors();
    double reproj_after = -1.0;
    try {
      reproj_after = recon->ComputeMeanReprojectionError();
    } catch (...) {}

    std::string solver_used, sparse_backend, dense_backend;
    int mixed = 0, used_threads = 0;
    colmap::AetherLastBaSolveInfo(&solver_used, &sparse_backend, &mixed,
                                  &used_threads, &dense_backend);
    int iters = -1;
    double final_cost = -1.0;
    if (auto ceres_sum =
            std::dynamic_pointer_cast<colmap::CeresBundleAdjustmentSummary>(
                summary)) {
      iters = static_cast<int>(ceres_sum->ceres_summary.iterations.size());
      final_cost = ceres_sum->ceres_summary.final_cost;
    }
    std::printf("ROUND round=%d arm=%c dense_backend=%s solver_used=%s "
                "ba_ms=%.1f reproj_after=%.4f iters=%d final_cost=%.6e "
                "threads=%d n_img=%zu n_pts=%zu\n",
                round, arm, dense_backend.c_str(), solver_used.c_str(), ba_ms,
                reproj_after, iters, final_cost, used_threads, n_img, n_pts);
    std::fflush(stdout);
  }
  return 0;
}
