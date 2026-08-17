#include "mandatory_arkit_gravity_v1.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {

using aether::sfm::BuildMandatoryArkitGravityPoseV1;
using aether::sfm::MandatoryArkitGravityPoseStatusV1;
using aether::sfm::MandatoryArkitGravityPoseV1;

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

void ExpectNear(double actual, double expected, double tolerance,
                const std::string& message) {
  if (std::abs(actual - expected) > tolerance) {
    std::cerr << "actual=" << actual << " expected=" << expected << '\n';
    Fail(message);
  }
}

void TestMissingInputsFailClosed() {
  const std::array<double, 4> q{1.0, 0.0, 0.0, 0.0};
  const std::array<double, 3> t{0.0, 0.0, 0.0};
  MandatoryArkitGravityPoseV1 out{};
  Expect(BuildMandatoryArkitGravityPoseV1(nullptr, t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kMissingQuaternion,
         "missing quaternion must fail closed");
  Expect(BuildMandatoryArkitGravityPoseV1(q.data(), nullptr, &out) ==
             MandatoryArkitGravityPoseStatusV1::kMissingTranslation,
         "missing translation must fail closed");
  Expect(BuildMandatoryArkitGravityPoseV1(q.data(), t.data(), nullptr) ==
             MandatoryArkitGravityPoseStatusV1::kMissingOutput,
         "missing output must fail closed");
}

void TestInvalidNumbersFailClosed() {
  const std::array<double, 4> good_q{1.0, 0.0, 0.0, 0.0};
  const std::array<double, 3> good_t{0.0, 0.0, 0.0};
  MandatoryArkitGravityPoseV1 out{};

  std::array<double, 4> bad_q = good_q;
  bad_q[2] = std::numeric_limits<double>::quiet_NaN();
  Expect(BuildMandatoryArkitGravityPoseV1(bad_q.data(), good_t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kNonFinite,
         "non-finite quaternion must fail closed");

  std::array<double, 3> bad_t = good_t;
  bad_t[1] = std::numeric_limits<double>::infinity();
  Expect(BuildMandatoryArkitGravityPoseV1(good_q.data(), bad_t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kNonFinite,
         "non-finite translation must fail closed");

  const std::array<double, 4> zero_q{0.0, 0.0, 0.0, 0.0};
  Expect(BuildMandatoryArkitGravityPoseV1(zero_q.data(), good_t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kDegenerateQuaternion,
         "zero quaternion must fail closed");
}

void TestIdentityPoseConvertsToColmapAndGravity() {
  // ARKit gravity-aligned world has +Y up; physical gravity is world -Y.
  // The production C=diag(1,-1,-1) camera-axis conversion maps that to
  // COLMAP camera +Y (image-down) for an identity ARKit world-to-camera pose.
  const std::array<double, 4> q{2.0, 0.0, 0.0, 0.0};
  const std::array<double, 3> t{1.0, 2.0, 3.0};
  MandatoryArkitGravityPoseV1 out{};
  Expect(BuildMandatoryArkitGravityPoseV1(q.data(), t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kOk,
         "finite identity pose accepted");

  ExpectNear(out.cam_from_world_qwxyz[0], 0.0, 1e-12,
             "COLMAP axis-conversion quaternion w");
  ExpectNear(std::abs(out.cam_from_world_qwxyz[1]), 1.0, 1e-12,
             "COLMAP axis-conversion quaternion x");
  ExpectNear(out.cam_from_world_qwxyz[2], 0.0, 1e-12,
             "COLMAP axis-conversion quaternion y");
  ExpectNear(out.cam_from_world_qwxyz[3], 0.0, 1e-12,
             "COLMAP axis-conversion quaternion z");
  ExpectNear(out.cam_from_world_t_xyz[0], 1.0, 1e-12,
             "COLMAP translation x");
  ExpectNear(out.cam_from_world_t_xyz[1], -2.0, 1e-12,
             "COLMAP translation y");
  ExpectNear(out.cam_from_world_t_xyz[2], -3.0, 1e-12,
             "COLMAP translation z");
  ExpectNear(out.gravity_cam_xyz[0], 0.0, 1e-12, "gravity x");
  ExpectNear(out.gravity_cam_xyz[1], 1.0, 1e-12, "gravity y");
  ExpectNear(out.gravity_cam_xyz[2], 0.0, 1e-12, "gravity z");
}

void TestRotatedPoseTransformsGravityDeterministically() {
  const double s = std::sqrt(0.5);
  // +90 degrees around ARKit Z, expressed world-to-camera.
  const std::array<double, 4> q{s, 0.0, 0.0, s};
  const std::array<double, 3> t{0.0, 0.0, 0.0};
  MandatoryArkitGravityPoseV1 out{};
  Expect(BuildMandatoryArkitGravityPoseV1(q.data(), t.data(), &out) ==
             MandatoryArkitGravityPoseStatusV1::kOk,
         "rotated pose accepted");
  ExpectNear(out.gravity_cam_xyz[0], 1.0, 1e-12,
             "rotated gravity x");
  ExpectNear(out.gravity_cam_xyz[1], 0.0, 1e-12,
             "rotated gravity y");
  ExpectNear(out.gravity_cam_xyz[2], 0.0, 1e-12,
             "rotated gravity z");
  const double norm = std::sqrt(
      out.gravity_cam_xyz[0] * out.gravity_cam_xyz[0] +
      out.gravity_cam_xyz[1] * out.gravity_cam_xyz[1] +
      out.gravity_cam_xyz[2] * out.gravity_cam_xyz[2]);
  ExpectNear(norm, 1.0, 1e-12, "gravity direction remains normalized");
}

}  // namespace

int main() {
  TestMissingInputsFailClosed();
  TestInvalidNumbersFailClosed();
  TestIdentityPoseConvertsToColmapAndGravity();
  TestRotatedPoseTransformsGravityDeterministically();
  std::cout << "PASS mandatory_arkit_gravity_v1\n";
  return 0;
}
