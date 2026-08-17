#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

#include "../../official_pipeline/src/live_cloud_diagnostics_v1.h"

namespace {

bool Near(const double actual, const double expected, const double tolerance) {
  return std::abs(actual - expected) <= tolerance;
}

std::array<double, 3> TransformBaToArkit(
    const std::array<double, 3>& ba) {
  constexpr double kScale = 1.2;
  constexpr double kCos30 = 0.8660254037844386;
  constexpr double kSin30 = 0.5;
  return {
      kScale * (kCos30 * ba[0] - kSin30 * ba[1]) + 0.3,
      kScale * (kSin30 * ba[0] + kCos30 * ba[1]) - 0.2,
      kScale * ba[2] + 0.5,
  };
}

void TestRobustArkitBaSim3() {
  using aether::sfm::LiveCloudArkitBaCenterPairV2;
  using aether::sfm::SummarizeLiveCloudArkitBaSim3V2;

  const std::vector<std::array<double, 3>> ba_centers = {
      {-1.0, -0.5, 0.2}, {0.0, 0.0, 0.0},    {0.8, -0.4, 0.5},
      {-0.6, 0.9, -0.3}, {1.2, 0.7, 0.1},    {-1.1, 0.3, 1.0},
      {0.4, -1.0, -0.8}, {0.2, 0.5, 1.3},    {-0.3, -0.7, 0.6},
      {0.9, 1.1, -0.5},  {-0.8, 1.3, 0.9},   {1.4, -1.2, 0.7},
  };

  std::vector<LiveCloudArkitBaCenterPairV2> pairs;
  for (const auto& ba : ba_centers) {
    pairs.push_back({TransformBaToArkit(ba), ba});
  }
  pairs.back().arkit_center_m[0] += 1.5;
  pairs.back().arkit_center_m[1] -= 0.8;

  const auto summary = SummarizeLiveCloudArkitBaSim3V2(pairs);
  assert(summary.valid);
  assert(summary.pair_count == pairs.size());
  assert(summary.inlier_count == pairs.size() - 1);
  assert(Near(summary.ba_to_arkit_scale, 1.2, 1e-9));
  assert(Near(summary.ba_to_arkit_translation_m[0], 0.3, 1e-9));
  assert(Near(summary.ba_to_arkit_translation_m[1], -0.2, 1e-9));
  assert(Near(summary.ba_to_arkit_translation_m[2], 0.5, 1e-9));
  assert(Near(summary.ba_to_arkit_rotation_deg, 30.0, 1e-8));
  assert(Near(summary.arkit_to_ba_scale, 1.0 / 1.2, 1e-9));
  assert(summary.residual_p90_m < 1e-9);
}

void TestDegenerateSim3() {
  using aether::sfm::LiveCloudArkitBaCenterPairV2;
  using aether::sfm::SummarizeLiveCloudArkitBaSim3V2;
  const std::vector<LiveCloudArkitBaCenterPairV2> pairs = {
      {{1.0, 2.0, 3.0}, {0.0, 0.0, 0.0}},
      {{1.0, 2.0, 3.0}, {0.0, 0.0, 0.0}},
      {{1.0, 2.0, 3.0}, {0.0, 0.0, 0.0}},
  };
  const auto summary = SummarizeLiveCloudArkitBaSim3V2(pairs);
  assert(!summary.valid);
  assert(summary.status == "degenerate_geometry");
}

void TestSameIdPointDisplacement() {
  using aether::sfm::LiveCloudDiagPointMapV2;
  using aether::sfm::SummarizeLiveCloudSameIdPointDeltasV2;

  const LiveCloudDiagPointMapV2 previous = {
      {10, {0.0, 0.0, 0.0}},
      {20, {1.0, 0.0, 0.0}},
      {30, {0.0, 1.0, 0.0}},
      {40, {0.0, 0.0, 1.0}},
  };
  const LiveCloudDiagPointMapV2 current = {
      {10, {0.01, 0.02, 0.03}},
      {20, {1.06, 0.0, 0.0}},
      {30, {0.0, 1.12, 0.0}},
      {50, {2.0, 2.0, 2.0}},
  };

  const auto summary =
      SummarizeLiveCloudSameIdPointDeltasV2(previous, current);
  assert(summary.valid);
  assert(summary.previous_count == 4);
  assert(summary.current_count == 4);
  assert(summary.common_count == 3);
  assert(summary.new_count == 1);
  assert(summary.dropped_count == 1);
  assert(summary.warning_5cm_count == 2);
  assert(summary.severe_10cm_count == 1);
  assert(summary.worst_point_id == 30);
  assert(Near(summary.median_delta_m[0], 0.01, 1e-12));
  assert(Near(summary.median_delta_m[1], 0.02, 1e-12));
  assert(Near(summary.median_delta_m[2], 0.0, 1e-12));
  assert(Near(summary.max_norm_m, 0.12, 1e-12));
}

void TestSameIdSeverityBoundariesAreInclusive() {
  using aether::sfm::LiveCloudDiagPointMapV2;
  using aether::sfm::SummarizeLiveCloudSameIdPointDeltasV2;
  const LiveCloudDiagPointMapV2 previous = {
      {1, {0.0, 0.0, 0.0}},
      {2, {0.0, 0.0, 0.0}},
  };
  const LiveCloudDiagPointMapV2 current = {
      {1, {0.05, 0.0, 0.0}},
      {2, {0.10, 0.0, 0.0}},
  };
  const auto summary =
      SummarizeLiveCloudSameIdPointDeltasV2(previous, current);
  assert(summary.warning_5cm_count == 2);
  assert(summary.severe_10cm_count == 1);
}

}  // namespace

int main() {
  TestRobustArkitBaSim3();
  TestDegenerateSim3();
  TestSameIdPointDisplacement();
  TestSameIdSeverityBoundariesAreInclusive();
  return 0;
}
