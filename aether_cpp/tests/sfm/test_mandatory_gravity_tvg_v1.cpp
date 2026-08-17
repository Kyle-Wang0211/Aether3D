#include "mandatory_gravity_tvg_v1.h"

#include "colmap/sensor/models.h"

#include <Eigen/Core>

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using aether::sfm::EstimateMandatoryGravityTwoViewGeometryV1;
using aether::sfm::MandatoryGravityTwoViewStatusV1;

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

colmap::Camera Camera() {
  colmap::Camera camera = colmap::Camera::CreateFromModelId(
      colmap::kInvalidCameraId, colmap::PinholeCameraModel::model_id,
      800.0, 1280, 960);
  camera.SetFocalLengthX(800.0);
  camera.SetFocalLengthY(800.0);
  camera.SetPrincipalPointX(640.0);
  camera.SetPrincipalPointY(480.0);
  camera.has_prior_focal_length = true;
  return camera;
}

Eigen::Vector2d Project(const Eigen::Vector3d& point) {
  return {800.0 * point.x() / point.z() + 640.0,
          800.0 * point.y() / point.z() + 480.0};
}

void BuildScene(bool planar,
                std::vector<Eigen::Vector2d>* points1,
                std::vector<Eigen::Vector2d>* points2,
                colmap::FeatureMatches* matches) {
  const double yaw = 0.17;
  const Eigen::Matrix3d rotation =
      Eigen::AngleAxisd(yaw, Eigen::Vector3d::UnitY()).toRotationMatrix();
  const Eigen::Vector3d translation(0.35, 0.02, 0.08);
  for (int i = 0; i < 48; ++i) {
    const double z = planar ? 4.5 : 3.2 + 0.23 * (i % 9);
    const Eigen::Vector3d point(-1.4 + 0.07 * i,
                                -0.8 + 0.17 * (i % 10), z);
    points1->push_back(Project(point));
    points2->push_back(Project(rotation * point + translation));
    matches->push_back({static_cast<colmap::point2D_t>(i),
                        static_cast<colmap::point2D_t>(i)});
  }
}

void TestNonPlanarUsesUprightGeometry() {
  std::vector<Eigen::Vector2d> points1;
  std::vector<Eigen::Vector2d> points2;
  colmap::FeatureMatches matches;
  BuildScene(false, &points1, &points2, &matches);
  colmap::TwoViewGeometryOptions options;
  options.min_num_inliers = 15;
  options.ransac_options.max_error = 1.0;
  options.ransac_options.random_seed = 20260804;

  const auto result = EstimateMandatoryGravityTwoViewGeometryV1(
      Camera(), points1, {0.0, 1.0, 0.0}, Camera(), points2,
      {0.0, 1.0, 0.0}, matches, options);
  Expect(result.status == MandatoryGravityTwoViewStatusV1::kValid,
         "non-planar scene yields valid upright TVG");
  Expect(result.geometry.config == colmap::TwoViewGeometry::CALIBRATED,
         "non-planar upright TVG is calibrated");
  Expect(result.geometry.inlier_matches.size() >= 46,
         "upright TVG retains synthetic inliers");
  Expect(result.geometry.cam2_from_cam1.has_value(),
         "upright pose is stored without generic pose recovery");
}

void TestPlanarGuardRemainsActive() {
  std::vector<Eigen::Vector2d> points1;
  std::vector<Eigen::Vector2d> points2;
  colmap::FeatureMatches matches;
  BuildScene(true, &points1, &points2, &matches);
  colmap::TwoViewGeometryOptions options;
  options.min_num_inliers = 15;
  options.ransac_options.max_error = 1.0;
  options.ransac_options.random_seed = 20260804;

  const auto result = EstimateMandatoryGravityTwoViewGeometryV1(
      Camera(), points1, {0.0, 1.0, 0.0}, Camera(), points2,
      {0.0, 1.0, 0.0}, matches, options);
  Expect(result.status == MandatoryGravityTwoViewStatusV1::kPlanar,
         "planar scene is not mislabeled as ordinary epipolar geometry");
  Expect(result.geometry.config ==
             colmap::TwoViewGeometry::PLANAR_OR_PANORAMIC,
         "homography planar classification is preserved");
}

void TestExhaustionStaysPending() {
  std::vector<Eigen::Vector2d> points1{{640.0, 480.0}, {650.0, 480.0}};
  std::vector<Eigen::Vector2d> points2{{641.0, 480.0}, {651.0, 480.0}};
  colmap::FeatureMatches matches{{0, 0}, {1, 1}};
  colmap::TwoViewGeometryOptions options;
  options.min_num_inliers = 3;
  const auto result = EstimateMandatoryGravityTwoViewGeometryV1(
      Camera(), points1, {0.0, 1.0, 0.0}, Camera(), points2,
      {0.0, 1.0, 0.0}, matches, options);
  Expect(result.status == MandatoryGravityTwoViewStatusV1::kPending,
         "insufficient geometry remains pending without fallback");
  Expect(result.geometry.config == colmap::TwoViewGeometry::DEGENERATE,
         "pending TVG cannot be persisted as valid geometry");
}

}  // namespace

int main() {
  TestNonPlanarUsesUprightGeometry();
  TestPlanarGuardRemainsActive();
  TestExhaustionStaysPending();
  std::cout << "PASS mandatory_gravity_tvg_v1\n";
  return 0;
}
