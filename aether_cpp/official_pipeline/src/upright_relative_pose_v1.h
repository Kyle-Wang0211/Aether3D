#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace aether::sfm {

struct UprightBearingMatchV1 {
  std::array<double, 3> ray1{};
  std::array<double, 3> ray2{};
};

struct UprightRelativePoseOptionsV1 {
  double max_squared_sampson_error = 1e-4;
  int min_num_inliers = 15;
  double confidence = 0.999;
  double min_inlier_ratio = 0.25;
  double dynamic_trials_multiplier = 3.0;
  int min_num_trials = 100;
  int max_num_trials = 1000;
  uint64_t random_seed = 20260804;
};

enum class UprightRelativePoseStatusV1 {
  kValid = 0,
  kPendingInsufficientGeometry,
  kInvalidInput,
};

struct UprightRelativePoseResultV1 {
  std::array<double, 4> cam2_from_cam1_qwxyz{};
  std::array<double, 3> cam2_from_cam1_t_xyz{};
  std::vector<int> inlier_indices;
  int num_trials = 0;
};

// Deterministic robust wrapper around PoseLib's known-gravity upright 3-point
// relative-pose solver. It has exactly two geometric outcomes: valid upright
// pose, or pending until more/better correspondences exist. It never invokes
// an unconstrained relative-pose or absolute-pose fallback.
UprightRelativePoseStatusV1 EstimateUprightRelativePoseV1(
    const std::vector<UprightBearingMatchV1>& matches,
    const std::array<double, 3>& gravity_cam1,
    const std::array<double, 3>& gravity_cam2,
    const UprightRelativePoseOptionsV1& options,
    UprightRelativePoseResultV1* result);

}  // namespace aether::sfm
