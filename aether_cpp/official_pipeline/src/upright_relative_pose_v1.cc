#include "upright_relative_pose_v1.h"

#include "PoseLib/solvers/relpose_upright_3pt.h"

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <algorithm>
#include <cmath>
#include <limits>

namespace aether::sfm {
namespace {

bool Normalize(const std::array<double, 3>& input, Eigen::Vector3d* output) {
  if (output == nullptr || !std::isfinite(input[0]) ||
      !std::isfinite(input[1]) || !std::isfinite(input[2])) {
    return false;
  }
  *output = Eigen::Vector3d(input[0], input[1], input[2]);
  const double norm = output->norm();
  if (!std::isfinite(norm) || norm <= 1e-12) return false;
  *output /= norm;
  return true;
}

Eigen::Matrix3d CrossProductMatrix(const Eigen::Vector3d& value) {
  Eigen::Matrix3d matrix;
  matrix << 0.0, -value.z(), value.y(), value.z(), 0.0, -value.x(),
      -value.y(), value.x(), 0.0;
  return matrix;
}

double SquaredSampsonError(const Eigen::Vector3d& ray1,
                           const Eigen::Vector3d& ray2,
                           const Eigen::Matrix3d& essential) {
  const Eigen::Vector3d e_ray1 = essential * ray1;
  const Eigen::Vector3d et_ray2 = essential.transpose() * ray2;
  const double numerator = ray2.dot(e_ray1);
  const double denominator =
      e_ray1.x() * e_ray1.x() + e_ray1.y() * e_ray1.y() +
      et_ray2.x() * et_ray2.x() + et_ray2.y() * et_ray2.y();
  if (!std::isfinite(denominator) || denominator <= 1e-24) {
    return std::numeric_limits<double>::infinity();
  }
  return numerator * numerator / denominator;
}

uint64_t NextRandom(uint64_t* state) {
  uint64_t value = *state;
  value ^= value >> 12;
  value ^= value << 25;
  value ^= value >> 27;
  *state = value;
  return value * UINT64_C(2685821657736338717);
}

std::array<int, 3> DrawSample(int count, uint64_t* state) {
  std::array<int, 3> sample{};
  sample[0] = static_cast<int>(NextRandom(state) % count);
  do {
    sample[1] = static_cast<int>(NextRandom(state) % count);
  } while (sample[1] == sample[0]);
  do {
    sample[2] = static_cast<int>(NextRandom(state) % count);
  } while (sample[2] == sample[0] || sample[2] == sample[1]);
  return sample;
}

int RequiredTrials(const double inlier_ratio,
                   const UprightRelativePoseOptionsV1& options) {
  const double clamped_ratio = std::clamp(inlier_ratio, 0.0, 1.0);
  const double all_inlier_probability =
      clamped_ratio * clamped_ratio * clamped_ratio;
  int trials = options.max_num_trials;
  if (all_inlier_probability >= 1.0) {
    trials = options.min_num_trials;
  } else if (all_inlier_probability > 0.0 && options.confidence > 0.0) {
    const double numerator = std::log1p(-options.confidence);
    const double denominator = std::log1p(-all_inlier_probability);
    if (std::isfinite(numerator) && std::isfinite(denominator) &&
        denominator < 0.0) {
      const double raw =
          options.dynamic_trials_multiplier * numerator / denominator;
      if (std::isfinite(raw) && raw > 0.0) {
        trials = static_cast<int>(std::min<double>(
            options.max_num_trials, std::ceil(raw)));
      }
    }
  }
  return std::clamp(trials, options.min_num_trials, options.max_num_trials);
}

}  // namespace

UprightRelativePoseStatusV1 EstimateUprightRelativePoseV1(
    const std::vector<UprightBearingMatchV1>& matches,
    const std::array<double, 3>& gravity_cam1,
    const std::array<double, 3>& gravity_cam2,
    const UprightRelativePoseOptionsV1& options,
    UprightRelativePoseResultV1* result) {
  if (result == nullptr || options.max_squared_sampson_error <= 0.0 ||
      !std::isfinite(options.max_squared_sampson_error) ||
      options.min_num_inliers < 3 || options.min_num_trials < 0 ||
      options.max_num_trials <= 0 ||
      options.min_num_trials > options.max_num_trials ||
      !std::isfinite(options.confidence) || options.confidence < 0.0 ||
      options.confidence > 1.0 ||
      !std::isfinite(options.min_inlier_ratio) ||
      options.min_inlier_ratio < 0.0 || options.min_inlier_ratio > 1.0 ||
      !std::isfinite(options.dynamic_trials_multiplier) ||
      options.dynamic_trials_multiplier <= 0.0) {
    return UprightRelativePoseStatusV1::kInvalidInput;
  }
  *result = UprightRelativePoseResultV1{};

  Eigen::Vector3d gravity1;
  Eigen::Vector3d gravity2;
  if (!Normalize(gravity_cam1, &gravity1) ||
      !Normalize(gravity_cam2, &gravity2)) {
    return UprightRelativePoseStatusV1::kInvalidInput;
  }
  if (matches.size() < 3) {
    return UprightRelativePoseStatusV1::kPendingInsufficientGeometry;
  }

  std::vector<Eigen::Vector3d> rays1(matches.size());
  std::vector<Eigen::Vector3d> rays2(matches.size());
  for (size_t i = 0; i < matches.size(); ++i) {
    if (!Normalize(matches[i].ray1, &rays1[i]) ||
        !Normalize(matches[i].ray2, &rays2[i])) {
      return UprightRelativePoseStatusV1::kInvalidInput;
    }
  }

  int best_inlier_count = 0;
  double best_error_sum = std::numeric_limits<double>::infinity();
  poselib::CameraPose best_pose;
  std::vector<int> best_inliers;
  uint64_t random_state = options.random_seed;
  if (random_state == 0) random_state = UINT64_C(0x9e3779b97f4a7c15);
  int dynamic_max_trials = RequiredTrials(options.min_inlier_ratio, options);

  for (int trial = 0; trial < dynamic_max_trials; ++trial) {
    result->num_trials = trial + 1;
    const std::array<int, 3> sample =
        DrawSample(static_cast<int>(matches.size()), &random_state);
    std::vector<Eigen::Vector3d> sample1;
    std::vector<Eigen::Vector3d> sample2;
    sample1.reserve(3);
    sample2.reserve(3);
    for (const int index : sample) {
      sample1.push_back(rays1[index]);
      sample2.push_back(rays2[index]);
    }

    poselib::CameraPoseVector poses;
    poselib::relpose_upright_3pt(sample1, sample2, gravity1, gravity2, &poses);
    for (const poselib::CameraPose& pose : poses) {
      const Eigen::Matrix3d rotation = pose.R();
      Eigen::Vector3d translation = pose.t;
      const double translation_norm = translation.norm();
      if (!rotation.allFinite() || !translation.allFinite() ||
          translation_norm <= 1e-12) {
        continue;
      }
      translation /= translation_norm;
      const Eigen::Matrix3d essential =
          CrossProductMatrix(translation) * rotation;
      std::vector<int> inliers;
      inliers.reserve(matches.size());
      double error_sum = 0.0;
      for (size_t i = 0; i < matches.size(); ++i) {
        const double error =
            SquaredSampsonError(rays1[i], rays2[i], essential);
        if (error <= options.max_squared_sampson_error) {
          inliers.push_back(static_cast<int>(i));
          error_sum += error;
        }
      }

      const int inlier_count = static_cast<int>(inliers.size());
      if (inlier_count > best_inlier_count ||
          (inlier_count == best_inlier_count && error_sum < best_error_sum)) {
        best_inlier_count = inlier_count;
        best_error_sum = error_sum;
        best_pose = poselib::CameraPose(rotation, translation);
        best_inliers = std::move(inliers);
        const double observed_ratio =
            static_cast<double>(best_inlier_count) / matches.size();
        dynamic_max_trials = std::max(
            trial + 1,
            std::min(dynamic_max_trials,
                     RequiredTrials(observed_ratio, options)));
      }
    }
  }

  if (best_inlier_count < options.min_num_inliers) {
    return UprightRelativePoseStatusV1::kPendingInsufficientGeometry;
  }

  Eigen::Quaterniond quaternion(best_pose.R());
  quaternion.normalize();
  result->cam2_from_cam1_qwxyz = {quaternion.w(), quaternion.x(),
                                  quaternion.y(), quaternion.z()};
  result->cam2_from_cam1_t_xyz = {best_pose.t.x(), best_pose.t.y(),
                                  best_pose.t.z()};
  result->inlier_indices = std::move(best_inliers);
  return UprightRelativePoseStatusV1::kValid;
}

}  // namespace aether::sfm
