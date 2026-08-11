#pragma once

#include <array>

namespace aether::sfm {

enum class MandatoryArkitGravityPoseStatusV1 {
  kOk = 0,
  kMissingOutput,
  kMissingQuaternion,
  kMissingTranslation,
  kNonFinite,
  kDegenerateQuaternion,
};

// Validated production-frame pose expressed in COLMAP camera coordinates.
// Quaternion order is [w,x,y,z]. gravity_cam_xyz is the normalized physical
// gravity direction (down), expressed in the same camera coordinates.
struct MandatoryArkitGravityPoseV1 {
  std::array<double, 4> cam_from_world_qwxyz{};
  std::array<double, 3> cam_from_world_t_xyz{};
  std::array<double, 3> gravity_cam_xyz{};
};

// Converts ARKit world-to-camera pose to the production COLMAP camera axes
// C=diag(1,-1,-1). ARKit's gravity-aligned world uses +Y up, so physical
// gravity is world -Y. No default, inferred, or fallback pose is accepted.
MandatoryArkitGravityPoseStatusV1 BuildMandatoryArkitGravityPoseV1(
    const double* arkit_w2c_qwxyz,
    const double* arkit_w2c_t_xyz,
    MandatoryArkitGravityPoseV1* output);

}  // namespace aether::sfm
