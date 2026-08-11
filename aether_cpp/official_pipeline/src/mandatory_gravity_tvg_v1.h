#pragma once

#include "colmap/estimators/two_view_geometry.h"

#include <Eigen/Core>

#include <array>
#include <vector>

namespace aether::sfm {

enum class MandatoryGravityTwoViewStatusV1 {
  kValid = 0,
  kPlanar,
  kPending,
  kRejectedWatermark,
  kInvalidInput,
};

struct MandatoryGravityTwoViewResultV1 {
  MandatoryGravityTwoViewStatusV1 status =
      MandatoryGravityTwoViewStatusV1::kInvalidInput;
  colmap::TwoViewGeometry geometry;
};

// Production TwoViewGeometry route: PoseLib upright relative pose plus an
// independent homography-only planar/panoramic guard. No generic E/F or
// absolute-pose solver is reachable from this function.
MandatoryGravityTwoViewResultV1 EstimateMandatoryGravityTwoViewGeometryV1(
    const colmap::Camera& camera1,
    const std::vector<Eigen::Vector2d>& points1,
    const std::array<double, 3>& gravity_cam1,
    const colmap::Camera& camera2,
    const std::vector<Eigen::Vector2d>& points2,
    const std::array<double, 3>& gravity_cam2,
    const colmap::FeatureMatches& matches,
    const colmap::TwoViewGeometryOptions& options);

}  // namespace aether::sfm
