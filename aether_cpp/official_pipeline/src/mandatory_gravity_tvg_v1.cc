#include "mandatory_gravity_tvg_v1.h"

#include "upright_relative_pose_v1.h"

#include "colmap/geometry/essential_matrix.h"

#include <Eigen/Geometry>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

namespace aether::sfm {

// [TVG-SPLIT 2026-08-08] Observation-only. Each pair runs TWO independent
// RANSACs: the gravity-constrained upright relative pose, then a homography
// with force_H_use for the planar-degeneracy classification. Their split has
// never been measured, and TVG is 21% of the live stream — if the H pass is the
// larger half and its only consumer is the planar/valid label, there may be a
// lossless early-out. Drained per frame into frame_split like the ilr_* fields.
extern "C" double aether_tvg_upright_ms = 0.0;
extern "C" double aether_tvg_homography_ms = 0.0;
extern "C" int aether_tvg_upright_calls = 0;
extern "C" int aether_tvg_homography_calls = 0;
namespace {
inline double TvgNowMs() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace
namespace {

colmap::FeatureMatches ExtractMatches(
    const colmap::FeatureMatches& matches,
    const std::vector<int>& indices) {
  colmap::FeatureMatches output;
  output.reserve(indices.size());
  for (const int index : indices) output.push_back(matches[index]);
  return output;
}

std::vector<char> BuildMask(size_t size, const std::vector<int>& indices) {
  std::vector<char> mask(size, false);
  for (const int index : indices) mask[index] = true;
  return mask;
}

std::array<double, 3> ToArray(const Eigen::Vector3d& value) {
  return {value.x(), value.y(), value.z()};
}

}  // namespace

MandatoryGravityTwoViewResultV1 EstimateMandatoryGravityTwoViewGeometryV1(
    const colmap::Camera& camera1,
    const std::vector<Eigen::Vector2d>& points1,
    const std::array<double, 3>& gravity_cam1,
    const colmap::Camera& camera2,
    const std::vector<Eigen::Vector2d>& points2,
    const std::array<double, 3>& gravity_cam2,
    const colmap::FeatureMatches& matches,
    const colmap::TwoViewGeometryOptions& options) {
  MandatoryGravityTwoViewResultV1 output;
  output.geometry.config = colmap::TwoViewGeometry::DEGENERATE;
  if (options.min_num_inliers < 3 || options.ransac_options.max_error <= 0.0 ||
      !std::isfinite(options.ransac_options.max_error)) {
    return output;
  }

  std::vector<Eigen::Vector2d> matched_points1;
  std::vector<Eigen::Vector2d> matched_points2;
  std::vector<UprightBearingMatchV1> upright_matches;
  matched_points1.reserve(matches.size());
  matched_points2.reserve(matches.size());
  upright_matches.reserve(matches.size());
  for (const colmap::FeatureMatch& match : matches) {
    if (match.point2D_idx1 >= points1.size() ||
        match.point2D_idx2 >= points2.size()) {
      output.status = MandatoryGravityTwoViewStatusV1::kInvalidInput;
      return output;
    }
    const Eigen::Vector2d& point1 = points1[match.point2D_idx1];
    const Eigen::Vector2d& point2 = points2[match.point2D_idx2];
    const std::optional<Eigen::Vector3d> ray1 = camera1.CamRayFromImg(point1);
    const std::optional<Eigen::Vector3d> ray2 = camera2.CamRayFromImg(point2);
    if (!ray1.has_value() || !ray2.has_value() || !ray1->allFinite() ||
        !ray2->allFinite()) {
      output.status = MandatoryGravityTwoViewStatusV1::kInvalidInput;
      return output;
    }
    matched_points1.push_back(point1);
    matched_points2.push_back(point2);
    upright_matches.push_back({ToArray(ray1->normalized()),
                               ToArray(ray2->normalized())});
  }

  if (matches.size() < static_cast<size_t>(options.min_num_inliers)) {
    output.status = MandatoryGravityTwoViewStatusV1::kPending;
    return output;
  }

  UprightRelativePoseOptionsV1 upright_options;
  const double normalized_threshold =
      0.5 * (camera1.CamFromImgThreshold(options.ransac_options.max_error) +
             camera2.CamFromImgThreshold(options.ransac_options.max_error));
  upright_options.max_squared_sampson_error =
      normalized_threshold * normalized_threshold;
  upright_options.min_num_inliers = options.min_num_inliers;
  upright_options.confidence = options.ransac_options.confidence;
  upright_options.min_inlier_ratio = options.ransac_options.min_inlier_ratio;
  upright_options.dynamic_trials_multiplier =
      options.ransac_options.dyn_num_trials_multiplier;
  upright_options.min_num_trials = options.ransac_options.min_num_trials;
  upright_options.max_num_trials = options.ransac_options.max_num_trials;
  upright_options.random_seed =
      options.ransac_options.random_seed < 0
          ? UINT64_C(20260804)
          : static_cast<uint64_t>(options.ransac_options.random_seed);

  UprightRelativePoseResultV1 upright;
  const double tvg_t0 = TvgNowMs();
  const UprightRelativePoseStatusV1 upright_status =
      EstimateUprightRelativePoseV1(upright_matches, gravity_cam1,
                                    gravity_cam2, upright_options, &upright);
  aether_tvg_upright_ms += TvgNowMs() - tvg_t0;
  ++aether_tvg_upright_calls;
  if (upright_status == UprightRelativePoseStatusV1::kInvalidInput) {
    output.status = MandatoryGravityTwoViewStatusV1::kInvalidInput;
    return output;
  }

  // Retain the upstream homography/planar test without invoking its generic
  // E/F estimators or relative-pose recovery.
  colmap::TwoViewGeometryOptions homography_options = options;
  homography_options.force_H_use = true;
  homography_options.compute_relative_pose = false;
  if (homography_options.ransac_options.random_seed < 0) {
    homography_options.ransac_options.random_seed = 20260804;
  }
  const double tvg_t1 = TvgNowMs();
  const colmap::TwoViewGeometry homography = colmap::EstimateTwoViewGeometry(
      camera1, points1, camera2, points2, matches, homography_options);
  aether_tvg_homography_ms += TvgNowMs() - tvg_t1;
  ++aether_tvg_homography_calls;
  const size_t homography_inliers = homography.inlier_matches.size();

  if (upright_status != UprightRelativePoseStatusV1::kValid) {
    if (homography.config == colmap::TwoViewGeometry::PLANAR_OR_PANORAMIC &&
        homography_inliers >= static_cast<size_t>(options.min_num_inliers)) {
      output.status = MandatoryGravityTwoViewStatusV1::kPlanar;
      output.geometry = homography;
    } else {
      output.status = MandatoryGravityTwoViewStatusV1::kPending;
    }
    return output;
  }

  const double upright_ratio =
      static_cast<double>(upright.inlier_indices.size()) / matches.size();
  if (options.min_inlier_ratio > 0.0 &&
      upright_ratio < options.min_inlier_ratio) {
    output.status = MandatoryGravityTwoViewStatusV1::kPending;
    return output;
  }

  const Eigen::Quaterniond quaternion(
      upright.cam2_from_cam1_qwxyz[0],
      upright.cam2_from_cam1_qwxyz[1],
      upright.cam2_from_cam1_qwxyz[2],
      upright.cam2_from_cam1_qwxyz[3]);
  const Eigen::Vector3d translation(upright.cam2_from_cam1_t_xyz[0],
                                    upright.cam2_from_cam1_t_xyz[1],
                                    upright.cam2_from_cam1_t_xyz[2]);
  output.geometry.cam2_from_cam1 = colmap::Rigid3d(quaternion, translation);
  output.geometry.E =
      colmap::EssentialMatrixFromPose(*output.geometry.cam2_from_cam1);
  output.geometry.inlier_matches =
      ExtractMatches(matches, upright.inlier_indices);
  output.geometry.config = colmap::TwoViewGeometry::CALIBRATED;

  const double homography_to_upright =
      static_cast<double>(homography_inliers) /
      std::max<size_t>(1, upright.inlier_indices.size());
  if (homography.config == colmap::TwoViewGeometry::PLANAR_OR_PANORAMIC &&
      homography_to_upright > options.max_H_inlier_ratio) {
    output.status = MandatoryGravityTwoViewStatusV1::kPlanar;
    output.geometry.config = colmap::TwoViewGeometry::PLANAR_OR_PANORAMIC;
    output.geometry.H = homography.H;
    if (homography_inliers > upright.inlier_indices.size()) {
      output.geometry.inlier_matches = homography.inlier_matches;
    }
  } else {
    output.status = MandatoryGravityTwoViewStatusV1::kValid;
  }

  if (options.detect_watermark &&
      output.geometry.config == colmap::TwoViewGeometry::CALIBRATED) {
    const std::vector<char> mask =
        BuildMask(matches.size(), upright.inlier_indices);
    if (colmap::DetectWatermarkMatches(
            camera1, matched_points1, camera2, matched_points2,
            upright.inlier_indices.size(), mask, options)) {
      output.geometry.config = colmap::TwoViewGeometry::WATERMARK;
      output.status = MandatoryGravityTwoViewStatusV1::kRejectedWatermark;
    }
  }
  return output;
}

}  // namespace aether::sfm
