#pragma once

#include <cmath>

#include <Eigen/Core>
#include <Eigen/Geometry>

namespace aether::sfm {

inline bool IsValidGravityBaPriorV1(const Eigen::Vector3d& gravity_cam) {
  return gravity_cam.allFinite() && gravity_cam.squaredNorm() > 1e-12;
}

// A roll/pitch-only BA residual. The production world frame is the mandatory
// ARKit gravity-aligned frame, so physical gravity is world -Y. The optimized
// COLMAP pose is camera_from_world in [qx,qy,qz,qw,tx,ty,tz] order. The cross
// product has rank two: it constrains roll and pitch while deliberately leaving
// rotation about gravity (yaw) free for image evidence to optimize.
//
// ⚠️ READ THIS BEFORE REASONING ABOUT WHAT THIS TERM MEASURES.
// `gravity_cam` is NOT an independent IMU observation. It is produced by
// BuildMandatoryArkitGravityPoseV1 as R(q_arkit) * (0,-1,0) — i.e. it is derived
// algebraically from the same ARKit quaternion that seeds this frame's pose.
// Consequences that are easy to get wrong:
//   1. At ingest the residual is IDENTICALLY ZERO by construction, because
//      predicted = R_C*R(q_arkit)*(0,-1,0) is exactly the stored measured
//      vector. This term therefore adds no new information to the first solve;
//      it is an ANCHOR that resists rotating away from the VIO attitude, not a
//      gravity measurement that can correct one.
//   2. Because it starts at zero, a sign error or a frame-convention regression
//      in the ARKit->COLMAP conversion does NOT show up as a large residual.
//      Residual monitoring cannot validate this path. The consistency check in
//      MaybeAddAetherGravityPriors exists precisely because of that blind spot.
//   3. It follows that pairwise upright TVG is immune to absolute VIO tilt
//      error (PoseLib's upright solver cancels g_world, and both frames' vectors
//      come from one pose chain), but BA is NOT: here absolute attitude matters,
//      so a wrong ARKit tilt is faithfully preserved rather than corrected.
//      That is why this term must stay robustified at the call site.
struct GravityBaPriorCostV1 {
  GravityBaPriorCostV1(const Eigen::Vector3d& gravity_cam,
                       const double inverse_sigma)
      : gravity_cam_(gravity_cam.normalized()),
        inverse_sigma_(inverse_sigma) {}

  template <typename T>
  bool operator()(const T* const camera_from_world, T* residuals) const {
    if (!IsValidGravityBaPriorV1(gravity_cam_) ||
        !std::isfinite(inverse_sigma_) || inverse_sigma_ <= 0.0) {
      return false;
    }
    const Eigen::Map<const Eigen::Quaternion<T>> rotation(camera_from_world);
    const Eigen::Matrix<T, 3, 1> gravity_world(T(0), T(-1), T(0));
    const Eigen::Matrix<T, 3, 1> predicted = rotation * gravity_world;
    const Eigen::Matrix<T, 3, 1> measured = gravity_cam_.cast<T>();
    const Eigen::Matrix<T, 3, 1> error =
        T(inverse_sigma_) * predicted.cross(measured);
    residuals[0] = error.x();
    residuals[1] = error.y();
    residuals[2] = error.z();
    return true;
  }

  Eigen::Vector3d gravity_cam_;
  double inverse_sigma_ = 1.0;
};

}  // namespace aether::sfm
