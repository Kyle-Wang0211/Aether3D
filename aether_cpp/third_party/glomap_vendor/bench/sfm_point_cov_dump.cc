// sfm_point_cov_dump.cc — [FLOATER-COV 2026-08-07] HOST-ONLY harness that
// computes the per-point BA covariance (conditional covariance, Schur point
// block, colmap/estimators/covariance.cc) on a saved COLMAP bin model and
// dumps a per-point scalar for offline AUC validation against the shell-band
// floater labels (same bands as analyze_shell.py / analyze_metadata_filter.py).
//
// The BA problem replicates the production finalize / ba_replay_bench setup:
// CAUCHY@1.0, TWO_CAMS_FROM_WORLD gauge, all registered images. No Solve() is
// run — the covariance is evaluated at the loaded (already-converged) model.
// BACovarianceOptions::Params::POINTS = conditional point covariance (poses
// conditioned fixed), which is exactly the "how well is this point pinned by
// its own observations" scalar we want for low-parallax shell points.
//
// Output txt, one line per point3D:
//   point3D_id sqrt_trace c00 c01 c02 c11 c12 c22
// (upper triangle of the 3x3 world-frame covariance so the offline analysis
// can also project it along the mean viewing ray). Failed points: id -1.
//
// usage: sfm_point_cov_dump_exe <colmap_bin_model_dir> <out_txt>

#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"
#include "colmap/estimators/covariance.h"
#include "colmap/scene/reconstruction.h"

#include <glog/logging.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <colmap_bin_model_dir> <out_txt>\n",
                 argv[0]);
    return 1;
  }
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;

  const std::string model_dir = argv[1];
  const std::string out_path = argv[2];

  colmap::Reconstruction recon;
  recon.Read(model_dir);
  std::printf("model=%s images=%zu points=%zu\n",
              model_dir.c_str(),
              recon.NumRegImages(),
              recon.NumPoints3D());
  std::fflush(stdout);

  // BA options: production finalize parity (ba_replay_bench.cc recipe).
  colmap::BundleAdjustmentOptions ba_options;
  ba_options.ceres->loss_function_type =
      colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
  ba_options.ceres->loss_function_scale = 1.0;
  ba_options.ceres->solver_options.num_threads =
      static_cast<int>(std::thread::hardware_concurrency());
  ba_options.print_summary = false;

  colmap::BundleAdjustmentConfig ba_config;
  for (const colmap::image_t image_id : recon.RegImageIds())
    ba_config.AddImage(image_id);
  ba_config.FixGauge(colmap::BundleAdjustmentGauge::TWO_CAMS_FROM_WORLD);

  // Problem is fully built in the constructor; no Solve() needed (covariance
  // is evaluated at the current parameter values = the saved model).
  std::unique_ptr<colmap::CeresBundleAdjuster> ba =
      colmap::CreateDefaultCeresBundleAdjuster(ba_options, ba_config, recon);

  colmap::BACovarianceOptions cov_options;
  cov_options.params = colmap::BACovarianceOptions::Params::POINTS;

  std::optional<colmap::BACovariance> cov =
      colmap::EstimateBACovariance(cov_options, recon, *ba);
  if (!cov) {
    std::fprintf(stderr, "EstimateBACovariance failed\n");
    return 2;
  }

  FILE* out = std::fopen(out_path.c_str(), "w");
  if (!out) {
    std::fprintf(stderr, "cannot open %s\n", out_path.c_str());
    return 3;
  }
  size_t n_ok = 0, n_fail = 0;
  for (const auto& [point3D_id, point3D] : recon.Points3D()) {
    const std::optional<Eigen::MatrixXd> c = cov->GetPointCov(point3D_id);
    if (!c || c->rows() != 3 || c->cols() != 3 ||
        !std::isfinite(c->trace())) {
      std::fprintf(out, "%llu -1\n",
                   static_cast<unsigned long long>(point3D_id));
      ++n_fail;
      continue;
    }
    const Eigen::MatrixXd& m = *c;
    std::fprintf(out,
                 "%llu %.10e %.10e %.10e %.10e %.10e %.10e %.10e\n",
                 static_cast<unsigned long long>(point3D_id),
                 std::sqrt(m.trace()),
                 m(0, 0), m(0, 1), m(0, 2), m(1, 1), m(1, 2), m(2, 2));
    ++n_ok;
  }
  std::fclose(out);
  std::printf("wrote %s ok=%zu fail=%zu\n", out_path.c_str(), n_ok, n_fail);
  return 0;
}
