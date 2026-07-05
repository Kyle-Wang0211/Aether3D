#pragma once

// #include "glomap/estimators/bundle_adjustment.h"
#include "glomap/estimators/optimization_base.h"
#include "glomap/scene/types_sfm.h"
#include "glomap/types.h"

#include <ceres/ceres.h>

#include <unordered_set>

namespace glomap {

struct BundleAdjusterOptions : public OptimizationBaseOptions {
 public:
  // [AETHER BA-COVGAIN 2026-07-06] Optional redundant-track exclusion set
  // (borrowed from colmap 4.0.4 FindRedundantPoints3D coverage-gain pruning,
  // ported to glomap structures in global_mapper.cc). When non-null, tracks in
  // the set are SKIPPED in AddPointToCameraConstraints — they contribute no
  // residual blocks, shrinking the internal-BA problem. The tracks themselves
  // stay in the map untouched (positions later refreshed by retriangulation +
  // the full-set finishing BAs), so the delivered point cloud is unaffected.
  // Default nullptr = exact upstream behavior. Non-owning; caller guarantees
  // the set outlives Solve().
  const std::unordered_set<track_t>* aether_exclude_tracks = nullptr;

  // Flags for which parameters to optimize
  bool optimize_rig_poses = false;  // Whether to optimize the rig poses
  bool optimize_rotations = true;
  bool optimize_translation = true;
  bool optimize_intrinsics = true;
  bool optimize_principal_point = false;
  bool optimize_points = true;

  bool use_gpu = true;
  std::string gpu_index = "-1";
  int min_num_images_gpu_solver = 50;

  // Constrain the minimum number of views per track
  int min_num_view_per_track = 3;

  // [AETHER] loss kernel selector — replicate COLMAP's CAUCHY (default) while keeping
  // Huber switchable for the global-SfM A/B (Cauchy's heavier down-weighting can
  // under-constrain a rough global init -> measure before locking; see port plan Risk #2).
  int loss_type = 2;  // 0=Trivial(squared) 1=Huber 2=Cauchy

  BundleAdjusterOptions() : OptimizationBaseOptions() {
    thres_loss_function = 1.;
    solver_options.max_num_iterations = 200;
    solver_options.function_tolerance = 1e-6;  // [AETHER] converge-stop (mirror COLMAP)
  }

  std::shared_ptr<ceres::LossFunction> CreateLossFunction() {
    switch (loss_type) {
      case 0: return nullptr;  // TRIVIAL (squared loss)
      case 1: return std::make_shared<ceres::HuberLoss>(thres_loss_function);
      default: return std::make_shared<ceres::CauchyLoss>(thres_loss_function);
    }
  }
};
class BundleAdjuster {
 public:
  BundleAdjuster(const BundleAdjusterOptions& options) : options_(options) {}

  // Returns true if the optimization was a success, false if there was a
  // failure.
  // Assume tracks here are already filtered
  bool Solve(std::unordered_map<rig_t, Rig>& rigs,
             std::unordered_map<camera_t, Camera>& cameras,
             std::unordered_map<frame_t, Frame>& frames,
             std::unordered_map<image_t, Image>& images,
             std::unordered_map<track_t, Track>& tracks);

  BundleAdjusterOptions& GetOptions() { return options_; }

 private:
  // Reset the problem
  void Reset();

  // Add tracks to the problem
  void AddPointToCameraConstraints(
      std::unordered_map<rig_t, Rig>& rigs,
      std::unordered_map<camera_t, Camera>& cameras,
      std::unordered_map<frame_t, Frame>& frames,
      std::unordered_map<image_t, Image>& images,
      std::unordered_map<track_t, Track>& tracks);

  // Set the parameter groups
  void AddCamerasAndPointsToParameterGroups(
      std::unordered_map<rig_t, Rig>& rigs,
      std::unordered_map<camera_t, Camera>& cameras,
      std::unordered_map<frame_t, Frame>& frames,
      std::unordered_map<track_t, Track>& tracks);

  // Parameterize the variables, set some variables to be constant if desired
  void ParameterizeVariables(std::unordered_map<rig_t, Rig>& rigs,
                             std::unordered_map<camera_t, Camera>& cameras,
                             std::unordered_map<frame_t, Frame>& frames,
                             std::unordered_map<track_t, Track>& tracks);

  BundleAdjusterOptions options_;

  std::unique_ptr<ceres::Problem> problem_;
  std::shared_ptr<ceres::LossFunction> loss_function_;
};

}  // namespace glomap
