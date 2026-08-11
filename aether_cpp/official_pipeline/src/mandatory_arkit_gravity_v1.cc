#include "mandatory_arkit_gravity_v1.h"

#include <cmath>

namespace aether::sfm {
namespace {

bool IsFinite(const double* values, int count) {
  for (int i = 0; i < count; ++i) {
    if (!std::isfinite(values[i])) return false;
  }
  return true;
}

std::array<double, 3> RotateVectorByUnitQuaternion(
    const std::array<double, 4>& q,
    const std::array<double, 3>& v) {
  const double w = q[0];
  const double x = q[1];
  const double y = q[2];
  const double z = q[3];
  const double tx = 2.0 * (y * v[2] - z * v[1]);
  const double ty = 2.0 * (z * v[0] - x * v[2]);
  const double tz = 2.0 * (x * v[1] - y * v[0]);
  return {
      v[0] + w * tx + (y * tz - z * ty),
      v[1] + w * ty + (z * tx - x * tz),
      v[2] + w * tz + (x * ty - y * tx),
  };
}

}  // namespace

MandatoryArkitGravityPoseStatusV1 BuildMandatoryArkitGravityPoseV1(
    const double* arkit_w2c_qwxyz,
    const double* arkit_w2c_t_xyz,
    MandatoryArkitGravityPoseV1* output) {
  if (output == nullptr) {
    return MandatoryArkitGravityPoseStatusV1::kMissingOutput;
  }
  if (arkit_w2c_qwxyz == nullptr) {
    return MandatoryArkitGravityPoseStatusV1::kMissingQuaternion;
  }
  if (arkit_w2c_t_xyz == nullptr) {
    return MandatoryArkitGravityPoseStatusV1::kMissingTranslation;
  }
  if (!IsFinite(arkit_w2c_qwxyz, 4) || !IsFinite(arkit_w2c_t_xyz, 3)) {
    return MandatoryArkitGravityPoseStatusV1::kNonFinite;
  }

  const double norm_squared =
      arkit_w2c_qwxyz[0] * arkit_w2c_qwxyz[0] +
      arkit_w2c_qwxyz[1] * arkit_w2c_qwxyz[1] +
      arkit_w2c_qwxyz[2] * arkit_w2c_qwxyz[2] +
      arkit_w2c_qwxyz[3] * arkit_w2c_qwxyz[3];
  if (!std::isfinite(norm_squared) || norm_squared <= 1e-24) {
    return MandatoryArkitGravityPoseStatusV1::kDegenerateQuaternion;
  }

  const double inverse_norm = 1.0 / std::sqrt(norm_squared);
  const std::array<double, 4> q{
      arkit_w2c_qwxyz[0] * inverse_norm,
      arkit_w2c_qwxyz[1] * inverse_norm,
      arkit_w2c_qwxyz[2] * inverse_norm,
      arkit_w2c_qwxyz[3] * inverse_norm,
  };

  // q_colmap = q_C * q_arkit, where q_C is 180 degrees about camera +X.
  MandatoryArkitGravityPoseV1 converted{};
  converted.cam_from_world_qwxyz = {-q[1], q[0], -q[3], q[2]};
  converted.cam_from_world_t_xyz = {
      arkit_w2c_t_xyz[0], -arkit_w2c_t_xyz[1], -arkit_w2c_t_xyz[2]};

  const std::array<double, 3> gravity_arkit_cam =
      RotateVectorByUnitQuaternion(q, {0.0, -1.0, 0.0});
  converted.gravity_cam_xyz = {
      gravity_arkit_cam[0], -gravity_arkit_cam[1],
      -gravity_arkit_cam[2]};

  const double gravity_norm = std::sqrt(
      converted.gravity_cam_xyz[0] * converted.gravity_cam_xyz[0] +
      converted.gravity_cam_xyz[1] * converted.gravity_cam_xyz[1] +
      converted.gravity_cam_xyz[2] * converted.gravity_cam_xyz[2]);
  if (!std::isfinite(gravity_norm) || gravity_norm <= 1e-12) {
    return MandatoryArkitGravityPoseStatusV1::kNonFinite;
  }
  for (double& value : converted.gravity_cam_xyz) value /= gravity_norm;

  *output = converted;
  return MandatoryArkitGravityPoseStatusV1::kOk;
}

}  // namespace aether::sfm
