#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <Eigen/Dense>

namespace aether::sfm {

struct LiveCloudBaDeltaSummaryV1 {
  bool valid = false;
  std::size_t count = 0;
  std::array<double, 3> median_delta_m{0.0, 0.0, 0.0};
  double coherent_median_norm_m = 0.0;
  double p50_norm_m = 0.0;
  double p90_norm_m = 0.0;
  double max_norm_m = 0.0;
  std::array<double, 3> latest_delta_m{0.0, 0.0, 0.0};
  double latest_norm_m = 0.0;
  double residual_rms_m = 0.0;
};

inline double LiveCloudDiagNearestPercentileV1(
    const std::vector<double>& sorted, const double p) {
  if (sorted.empty()) return 0.0;
  const double clamped = std::max(0.0, std::min(1.0, p));
  const std::size_t index = static_cast<std::size_t>(
      std::llround(clamped * static_cast<double>(sorted.size() - 1)));
  return sorted[index];
}

inline double LiveCloudDiagMedianV1(std::vector<double> values) {
  if (values.empty()) return 0.0;
  std::sort(values.begin(), values.end());
  const std::size_t middle = values.size() / 2;
  if ((values.size() & 1u) != 0u) return values[middle];
  return 0.5 * (values[middle - 1] + values[middle]);
}

inline LiveCloudBaDeltaSummaryV1 SummarizeLiveCloudBaDeltasV1(
    const std::vector<std::array<double, 3>>& input) {
  LiveCloudBaDeltaSummaryV1 out;
  std::vector<std::array<double, 3>> deltas;
  deltas.reserve(input.size());
  for (const auto& delta : input) {
    if (std::isfinite(delta[0]) && std::isfinite(delta[1]) &&
        std::isfinite(delta[2])) {
      deltas.push_back(delta);
    }
  }
  if (deltas.empty()) return out;

  out.valid = true;
  out.count = deltas.size();
  out.latest_delta_m = deltas.back();
  std::array<std::vector<double>, 3> components;
  std::vector<double> norms;
  norms.reserve(deltas.size());
  for (const auto& delta : deltas) {
    for (int axis = 0; axis < 3; ++axis) {
      components[axis].push_back(delta[axis]);
    }
    norms.push_back(std::sqrt(
        delta[0] * delta[0] + delta[1] * delta[1] +
        delta[2] * delta[2]));
  }
  for (int axis = 0; axis < 3; ++axis) {
    out.median_delta_m[axis] =
        LiveCloudDiagMedianV1(std::move(components[axis]));
  }
  out.coherent_median_norm_m = std::sqrt(
      out.median_delta_m[0] * out.median_delta_m[0] +
      out.median_delta_m[1] * out.median_delta_m[1] +
      out.median_delta_m[2] * out.median_delta_m[2]);
  out.latest_norm_m = norms.back();
  std::sort(norms.begin(), norms.end());
  out.p50_norm_m = LiveCloudDiagNearestPercentileV1(norms, 0.50);
  out.p90_norm_m = LiveCloudDiagNearestPercentileV1(norms, 0.90);
  out.max_norm_m = norms.back();

  double residual_sq_sum = 0.0;
  for (const auto& delta : deltas) {
    const double dx = delta[0] - out.median_delta_m[0];
    const double dy = delta[1] - out.median_delta_m[1];
    const double dz = delta[2] - out.median_delta_m[2];
    residual_sq_sum += dx * dx + dy * dy + dz * dz;
  }
  out.residual_rms_m =
      std::sqrt(residual_sq_sum / static_cast<double>(deltas.size()));
  return out;
}

struct LiveCloudArkitBaCenterPairV2 {
  std::array<double, 3> arkit_center_m{0.0, 0.0, 0.0};
  std::array<double, 3> ba_center_m{0.0, 0.0, 0.0};
};

struct LiveCloudArkitBaSim3SummaryV2 {
  bool valid = false;
  std::string status = "not_enough_pairs";
  std::size_t input_pair_count = 0;
  std::size_t pair_count = 0;
  std::size_t inlier_count = 0;
  double ba_to_arkit_scale = 1.0;
  std::array<double, 3> ba_to_arkit_translation_m{0.0, 0.0, 0.0};
  std::array<double, 4> ba_to_arkit_quaternion_xyzw{0.0, 0.0, 0.0, 1.0};
  double ba_to_arkit_rotation_deg = 0.0;
  double arkit_to_ba_scale = 1.0;
  std::array<double, 3> arkit_to_ba_translation_m{0.0, 0.0, 0.0};
  std::array<double, 4> arkit_to_ba_quaternion_xyzw{0.0, 0.0, 0.0, 1.0};
  double arkit_to_ba_rotation_deg = 0.0;
  double residual_p50_m = 0.0;
  double residual_p90_m = 0.0;
  double residual_max_m = 0.0;
  double residual_all_max_m = 0.0;
};

namespace live_cloud_diag_internal_v2 {

struct Sim3Fit {
  bool valid = false;
  double scale = 1.0;
  Eigen::Matrix3d rotation = Eigen::Matrix3d::Identity();
  Eigen::Vector3d translation = Eigen::Vector3d::Zero();
};

inline bool FinitePoint(const std::array<double, 3>& point) {
  return std::isfinite(point[0]) && std::isfinite(point[1]) &&
         std::isfinite(point[2]);
}

inline Eigen::Vector3d ToEigen(const std::array<double, 3>& point) {
  return Eigen::Vector3d(point[0], point[1], point[2]);
}

inline Sim3Fit FitSim3(
    const std::vector<LiveCloudArkitBaCenterPairV2>& pairs,
    const std::vector<std::size_t>& indices) {
  Sim3Fit out;
  if (indices.size() < 3) return out;

  Eigen::Vector3d ba_mean = Eigen::Vector3d::Zero();
  Eigen::Vector3d arkit_mean = Eigen::Vector3d::Zero();
  for (const std::size_t index : indices) {
    ba_mean += ToEigen(pairs[index].ba_center_m);
    arkit_mean += ToEigen(pairs[index].arkit_center_m);
  }
  const double count = static_cast<double>(indices.size());
  ba_mean /= count;
  arkit_mean /= count;

  Eigen::Matrix3d covariance = Eigen::Matrix3d::Zero();
  double ba_variance = 0.0;
  for (const std::size_t index : indices) {
    const Eigen::Vector3d ba = ToEigen(pairs[index].ba_center_m) - ba_mean;
    const Eigen::Vector3d arkit =
        ToEigen(pairs[index].arkit_center_m) - arkit_mean;
    covariance += arkit * ba.transpose();
    ba_variance += ba.squaredNorm();
  }
  covariance /= count;
  ba_variance /= count;
  if (!std::isfinite(ba_variance) || ba_variance <= 1e-12) return out;

  const Eigen::JacobiSVD<Eigen::Matrix3d> svd(
      covariance, Eigen::ComputeFullU | Eigen::ComputeFullV);
  const Eigen::Vector3d singular = svd.singularValues();
  if (!singular.allFinite() || singular[1] <= 1e-12) return out;

  Eigen::Matrix3d sign = Eigen::Matrix3d::Identity();
  if ((svd.matrixU() * svd.matrixV().transpose()).determinant() < 0.0) {
    sign(2, 2) = -1.0;
  }
  const Eigen::Matrix3d rotation =
      svd.matrixU() * sign * svd.matrixV().transpose();
  const double scale = singular.dot(sign.diagonal()) / ba_variance;
  if (!rotation.allFinite() || !std::isfinite(scale) || scale <= 1e-12) {
    return out;
  }

  const Eigen::Vector3d translation = arkit_mean - scale * rotation * ba_mean;
  if (!translation.allFinite()) return out;
  out.valid = true;
  out.scale = scale;
  out.rotation = rotation;
  out.translation = translation;
  return out;
}

inline double Residual(
    const LiveCloudArkitBaCenterPairV2& pair, const Sim3Fit& fit) {
  const Eigen::Vector3d predicted =
      fit.scale * fit.rotation * ToEigen(pair.ba_center_m) + fit.translation;
  return (predicted - ToEigen(pair.arkit_center_m)).norm();
}

inline std::array<double, 4> QuaternionXyzw(const Eigen::Matrix3d& rotation) {
  Eigen::Quaterniond quaternion(rotation);
  quaternion.normalize();
  if (quaternion.w() < 0.0) quaternion.coeffs() *= -1.0;
  return {quaternion.x(), quaternion.y(), quaternion.z(), quaternion.w()};
}

inline double RotationDegrees(const Eigen::Matrix3d& rotation) {
  Eigen::Quaterniond quaternion(rotation);
  quaternion.normalize();
  const double w = std::max(-1.0, std::min(1.0, std::abs(quaternion.w())));
  return 2.0 * std::acos(w) * 180.0 / 3.14159265358979323846;
}

}  // namespace live_cloud_diag_internal_v2

inline LiveCloudArkitBaSim3SummaryV2 SummarizeLiveCloudArkitBaSim3V2(
    const std::vector<LiveCloudArkitBaCenterPairV2>& input) {
  namespace internal = live_cloud_diag_internal_v2;
  LiveCloudArkitBaSim3SummaryV2 out;
  out.input_pair_count = input.size();

  std::vector<LiveCloudArkitBaCenterPairV2> pairs;
  pairs.reserve(input.size());
  for (const auto& pair : input) {
    if (internal::FinitePoint(pair.arkit_center_m) &&
        internal::FinitePoint(pair.ba_center_m)) {
      pairs.push_back(pair);
    }
  }
  out.pair_count = pairs.size();
  if (pairs.size() < 3) return out;

  std::vector<std::size_t> all_indices(pairs.size());
  for (std::size_t i = 0; i < pairs.size(); ++i) all_indices[i] = i;
  internal::Sim3Fit fit = internal::FitSim3(pairs, all_indices);
  if (!fit.valid) {
    out.status = "degenerate_geometry";
    return out;
  }

  std::vector<double> initial_residuals;
  initial_residuals.reserve(pairs.size());
  for (const auto& pair : pairs) {
    initial_residuals.push_back(internal::Residual(pair, fit));
  }
  const double residual_median = LiveCloudDiagMedianV1(initial_residuals);
  std::vector<double> deviations;
  deviations.reserve(initial_residuals.size());
  for (const double residual : initial_residuals) {
    deviations.push_back(std::abs(residual - residual_median));
  }
  const double mad = LiveCloudDiagMedianV1(std::move(deviations));
  const double threshold =
      std::max(0.01, residual_median + 3.0 * 1.4826 * mad);

  std::vector<std::size_t> inlier_indices;
  inlier_indices.reserve(pairs.size());
  for (std::size_t i = 0; i < initial_residuals.size(); ++i) {
    if (initial_residuals[i] <= threshold) inlier_indices.push_back(i);
  }
  if (inlier_indices.size() < 3) {
    out.status = "not_enough_inliers";
    return out;
  }
  if (inlier_indices.size() != all_indices.size()) {
    fit = internal::FitSim3(pairs, inlier_indices);
    if (!fit.valid) {
      out.status = "degenerate_inliers";
      return out;
    }
  }

  std::vector<double> inlier_residuals;
  inlier_residuals.reserve(inlier_indices.size());
  double all_max = 0.0;
  for (std::size_t i = 0; i < pairs.size(); ++i) {
    const double residual = internal::Residual(pairs[i], fit);
    all_max = std::max(all_max, residual);
  }
  for (const std::size_t index : inlier_indices) {
    inlier_residuals.push_back(internal::Residual(pairs[index], fit));
  }
  std::sort(inlier_residuals.begin(), inlier_residuals.end());

  out.valid = true;
  out.status = "ok";
  out.inlier_count = inlier_indices.size();
  out.ba_to_arkit_scale = fit.scale;
  for (int axis = 0; axis < 3; ++axis) {
    out.ba_to_arkit_translation_m[axis] = fit.translation[axis];
  }
  out.ba_to_arkit_quaternion_xyzw = internal::QuaternionXyzw(fit.rotation);
  out.ba_to_arkit_rotation_deg = internal::RotationDegrees(fit.rotation);

  out.arkit_to_ba_scale = 1.0 / fit.scale;
  const Eigen::Matrix3d inverse_rotation = fit.rotation.transpose();
  const Eigen::Vector3d inverse_translation =
      -out.arkit_to_ba_scale * inverse_rotation * fit.translation;
  for (int axis = 0; axis < 3; ++axis) {
    out.arkit_to_ba_translation_m[axis] = inverse_translation[axis];
  }
  out.arkit_to_ba_quaternion_xyzw =
      internal::QuaternionXyzw(inverse_rotation);
  out.arkit_to_ba_rotation_deg = internal::RotationDegrees(inverse_rotation);
  out.residual_p50_m =
      LiveCloudDiagNearestPercentileV1(inlier_residuals, 0.50);
  out.residual_p90_m =
      LiveCloudDiagNearestPercentileV1(inlier_residuals, 0.90);
  out.residual_max_m = inlier_residuals.back();
  out.residual_all_max_m = all_max;
  return out;
}

using LiveCloudDiagPointMapV2 =
    std::unordered_map<std::uint64_t, std::array<double, 3>>;

struct LiveCloudSameIdPointDeltaSummaryV2 {
  bool valid = false;
  std::size_t previous_count = 0;
  std::size_t current_count = 0;
  std::size_t common_count = 0;
  std::size_t valid_delta_count = 0;
  std::size_t new_count = 0;
  std::size_t dropped_count = 0;
  std::array<double, 3> median_delta_m{0.0, 0.0, 0.0};
  double coherent_median_norm_m = 0.0;
  double p50_norm_m = 0.0;
  double p90_norm_m = 0.0;
  double p99_norm_m = 0.0;
  double max_norm_m = 0.0;
  std::size_t warning_5cm_count = 0;
  std::size_t severe_10cm_count = 0;
  std::uint64_t worst_point_id = 0;
};

inline LiveCloudSameIdPointDeltaSummaryV2
SummarizeLiveCloudSameIdPointDeltasV2(
    const LiveCloudDiagPointMapV2& previous,
    const LiveCloudDiagPointMapV2& current) {
  LiveCloudSameIdPointDeltaSummaryV2 out;
  out.previous_count = previous.size();
  out.current_count = current.size();

  std::array<std::vector<double>, 3> components;
  std::vector<std::pair<double, std::uint64_t>> norm_and_id;
  norm_and_id.reserve(std::min(previous.size(), current.size()));
  for (const auto& entry : current) {
    const auto previous_it = previous.find(entry.first);
    if (previous_it == previous.end()) continue;
    ++out.common_count;
    if (!live_cloud_diag_internal_v2::FinitePoint(previous_it->second) ||
        !live_cloud_diag_internal_v2::FinitePoint(entry.second)) {
      continue;
    }
    const std::array<double, 3> delta = {
        entry.second[0] - previous_it->second[0],
        entry.second[1] - previous_it->second[1],
        entry.second[2] - previous_it->second[2],
    };
    for (int axis = 0; axis < 3; ++axis) {
      components[axis].push_back(delta[axis]);
    }
    const double norm = std::sqrt(delta[0] * delta[0] +
                                  delta[1] * delta[1] +
                                  delta[2] * delta[2]);
    norm_and_id.emplace_back(norm, entry.first);
    if (norm >= 0.05) ++out.warning_5cm_count;
    if (norm >= 0.10) ++out.severe_10cm_count;
  }
  out.new_count = current.size() - out.common_count;
  out.dropped_count = previous.size() - out.common_count;
  out.valid_delta_count = norm_and_id.size();
  if (norm_and_id.empty()) return out;

  out.valid = true;
  for (int axis = 0; axis < 3; ++axis) {
    out.median_delta_m[axis] =
        LiveCloudDiagMedianV1(std::move(components[axis]));
  }
  out.coherent_median_norm_m = std::sqrt(
      out.median_delta_m[0] * out.median_delta_m[0] +
      out.median_delta_m[1] * out.median_delta_m[1] +
      out.median_delta_m[2] * out.median_delta_m[2]);
  std::sort(norm_and_id.begin(), norm_and_id.end(),
            [](const auto& lhs, const auto& rhs) {
              if (lhs.first != rhs.first) return lhs.first < rhs.first;
              return lhs.second < rhs.second;
            });
  std::vector<double> norms;
  norms.reserve(norm_and_id.size());
  for (const auto& entry : norm_and_id) norms.push_back(entry.first);
  out.p50_norm_m = LiveCloudDiagNearestPercentileV1(norms, 0.50);
  out.p90_norm_m = LiveCloudDiagNearestPercentileV1(norms, 0.90);
  out.p99_norm_m = LiveCloudDiagNearestPercentileV1(norms, 0.99);
  out.max_norm_m = norms.back();
  out.worst_point_id = norm_and_id.back().second;
  return out;
}

}  // namespace aether::sfm
