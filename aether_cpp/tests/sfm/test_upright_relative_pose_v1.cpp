#include "upright_relative_pose_v1.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using aether::sfm::EstimateUprightRelativePoseV1;
using aether::sfm::UprightBearingMatchV1;
using aether::sfm::UprightRelativePoseOptionsV1;
using aether::sfm::UprightRelativePoseResultV1;
using aether::sfm::UprightRelativePoseStatusV1;

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

std::array<double, 3> Normalize(std::array<double, 3> value) {
  const double norm = std::sqrt(value[0] * value[0] + value[1] * value[1] +
                                value[2] * value[2]);
  for (double& element : value) element /= norm;
  return value;
}

std::array<double, 3> TransformPoint(double yaw,
                                     const std::array<double, 3>& t,
                                     const std::array<double, 3>& point) {
  const double c = std::cos(yaw);
  const double s = std::sin(yaw);
  return {c * point[0] + s * point[2] + t[0], point[1] + t[1],
          -s * point[0] + c * point[2] + t[2]};
}

void TestInsufficientGeometryStaysPending() {
  std::vector<UprightBearingMatchV1> matches(2);
  matches[0] = {{{0.0, 0.0, 1.0}}, {{0.1, 0.0, 1.0}}};
  matches[1] = {{{0.1, 0.0, 1.0}}, {{0.2, 0.0, 1.0}}};
  UprightRelativePoseResultV1 result{};
  Expect(EstimateUprightRelativePoseV1(
             matches, {0.0, 1.0, 0.0}, {0.0, 1.0, 0.0}, {}, &result) ==
             UprightRelativePoseStatusV1::kPendingInsufficientGeometry,
         "fewer than three correspondences stay pending");
  Expect(result.inlier_indices.empty(), "pending result has no false inliers");
}

void TestKnownUprightPoseWithOutliers() {
  constexpr double kYaw = 0.31;
  const std::array<double, 3> translation{0.28, 0.03, 0.07};
  std::vector<UprightBearingMatchV1> matches;
  for (int i = 0; i < 30; ++i) {
    const std::array<double, 3> point{
        -1.2 + 0.11 * i,
        -0.7 + 0.13 * (i % 9),
        3.5 + 0.17 * (i % 7),
    };
    matches.push_back({Normalize(point),
                       Normalize(TransformPoint(kYaw, translation, point))});
  }
  for (int i = 0; i < 8; ++i) {
    matches.push_back({Normalize({0.2 + i, -0.4 + 0.3 * i, 2.0}),
                       Normalize({-0.7 + 0.2 * i, 0.8 - 0.1 * i, 1.0})});
  }

  UprightRelativePoseOptionsV1 options{};
  options.max_squared_sampson_error = 1e-8;
  options.min_num_inliers = 25;
  options.max_num_trials = 800;
  options.random_seed = 20260804;
  UprightRelativePoseResultV1 result{};
  Expect(EstimateUprightRelativePoseV1(
             matches, {0.0, 1.0, 0.0}, {0.0, 1.0, 0.0}, options, &result) ==
             UprightRelativePoseStatusV1::kValid,
         "upright solver survives outliers");
  Expect(result.inlier_indices.size() >= 29,
         "upright solver recovers the synthetic inlier support");
  Expect(result.num_trials >= options.min_num_trials &&
             result.num_trials < options.max_num_trials,
         "strong support stops deterministically before the hard trial cap");

  // The relative rotation must preserve the gravity direction exactly.
  const double w = result.cam2_from_cam1_qwxyz[0];
  const double x = result.cam2_from_cam1_qwxyz[1];
  const double y = result.cam2_from_cam1_qwxyz[2];
  const double z = result.cam2_from_cam1_qwxyz[3];
  const std::array<double, 3> rotated_gravity{
      2.0 * (x * y - w * z),
      1.0 - 2.0 * (x * x + z * z),
      2.0 * (y * z + w * x),
  };
  Expect(std::abs(rotated_gravity[0]) < 1e-9 &&
             std::abs(rotated_gravity[1] - 1.0) < 1e-9 &&
             std::abs(rotated_gravity[2]) < 1e-9,
         "estimated rotation honors gravity exactly");

  const double estimated_yaw =
      std::atan2(2.0 * (w * y + x * z),
                 1.0 - 2.0 * (y * y + z * z));
  Expect(std::abs(estimated_yaw - kYaw) < 1e-6,
         "estimated yaw matches the known pose");
}

void TestInvalidGravityFailsClosed() {
  std::vector<UprightBearingMatchV1> matches(3);
  matches[0] = {{{0.0, 0.0, 1.0}}, {{0.1, 0.0, 1.0}}};
  matches[1] = {{{0.1, 0.0, 1.0}}, {{0.2, 0.0, 1.0}}};
  matches[2] = {{{0.0, 0.1, 1.0}}, {{0.1, 0.1, 1.0}}};
  UprightRelativePoseResultV1 result{};
  Expect(EstimateUprightRelativePoseV1(
             matches, {0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {}, &result) ==
             UprightRelativePoseStatusV1::kInvalidInput,
         "zero gravity cannot fall back to unconstrained geometry");
}

}  // namespace

int main() {
  TestInsufficientGeometryStaysPending();
  TestKnownUprightPoseWithOutliers();
  TestInvalidGravityFailsClosed();
  std::cout << "PASS upright_relative_pose_v1\n";
  return 0;
}
