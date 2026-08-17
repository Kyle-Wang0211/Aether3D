#include "../../official_pipeline/src/gravity_ba_prior_v1.h"

#include <cassert>
#include <cmath>

#include <Eigen/Geometry>

namespace {

constexpr double kPi = 3.14159265358979323846;

void FillPose(const Eigen::Quaterniond& q, double pose[7]) {
  const Eigen::Quaterniond normalized = q.normalized();
  pose[0] = normalized.x();
  pose[1] = normalized.y();
  pose[2] = normalized.z();
  pose[3] = normalized.w();
  pose[4] = 0.0;
  pose[5] = 0.0;
  pose[6] = 0.0;
}

double ResidualNorm(const Eigen::Quaterniond& q,
                    const Eigen::Vector3d& gravity_cam) {
  double pose[7];
  FillPose(q, pose);
  double residuals[3] = {};
  const aether::sfm::GravityBaPriorCostV1 cost(gravity_cam, 1.0);
  assert(cost(pose, residuals));
  return Eigen::Map<Eigen::Vector3d>(residuals).norm();
}

}  // namespace

int main() {
  const Eigen::Vector3d gravity_world(0.0, -1.0, 0.0);
  const Eigen::Quaterniond base =
      Eigen::AngleAxisd(25.0 * kPi / 180.0, Eigen::Vector3d::UnitY()) *
      Eigen::AngleAxisd(-12.0 * kPi / 180.0, Eigen::Vector3d::UnitX());
  const Eigen::Vector3d gravity_cam = base * gravity_world;

  // The ARKit-aligned pose must be a zero-residual solution.
  assert(ResidualNorm(base, gravity_cam) < 1e-12);

  // World-yaw is the one unconstrained rotational DOF: it must not change the
  // camera-frame gravity prediction.
  const Eigen::Quaterniond world_yaw =
      base * Eigen::AngleAxisd(71.0 * kPi / 180.0,
                               Eigen::Vector3d::UnitY());
  assert(ResidualNorm(world_yaw, gravity_cam) < 1e-12);

  // Roll/pitch violate the measured gravity and must produce a real residual.
  const Eigen::Quaterniond wrong_roll =
      Eigen::AngleAxisd(8.0 * kPi / 180.0, Eigen::Vector3d::UnitZ()) * base;
  const Eigen::Quaterniond wrong_pitch =
      Eigen::AngleAxisd(6.0 * kPi / 180.0, Eigen::Vector3d::UnitX()) * base;
  assert(ResidualNorm(wrong_roll, gravity_cam) > 0.05);
  assert(ResidualNorm(wrong_pitch, gravity_cam) > 0.05);

  // The cost constructor is fail-closed for invalid gravity inputs.
  assert(!aether::sfm::IsValidGravityBaPriorV1(Eigen::Vector3d::Zero()));
  assert(aether::sfm::IsValidGravityBaPriorV1(gravity_cam));
  return 0;
}
