// pair_selection_v2_colmap_parity_test.cc — 钉住 2026-09-02 的候选腰斩修复:
// SelectSpatialTemporalCandidatesV2 的空间源资格判定 = COLMAP
// SpatialPairGenerator 语义(位置 KNN + max_distance 截断),
// 不再含自设的 45° 主光轴夹角门。
//
// 上游出处(vendored COLMAP 3.14.0.dev0, BSD-3-Clause,
// third_party/glomap_vendor/colmap-src/colmap/controllers/pairing.h):
//   max_num_neighbors = 50, min_num_neighbors = 0, max_distance = 100
// 本管线的空间名额走 config.spatial_k(生产 = 12 - 2 = 10),其余两参取上游默认。
//
// 编译(host,无任何外部依赖):
//   clang++ -std=c++20 -I../src \
//     ../src/pair_selection_v2.cc pair_selection_v2_colmap_parity_test.cc \
//     -o /tmp/pair_selection_v2_colmap_parity_test && /tmp/...

#include <array>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

#include "pair_selection_v2.h"

namespace {

int failures = 0;

void Check(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

aether::sfm::PairSelectionFrameV2 Frame(int32_t id, double x, double y,
                                        double z, double fx, double fy,
                                        double fz) {
  aether::sfm::PairSelectionFrameV2 f;
  f.frame_id = id;
  f.center_xyz = {x, y, z};
  f.forward_xyz = {fx, fy, fz};
  f.pose_valid = true;
  f.matchable = true;
  return f;
}

// 场景 1:相机边走边转(每帧朝向转 15°)。旧 45° 视角门下,当前帧只能
// 看到最近 ~3 帧朝向兼容 → 候选骤减(2026-09-02 S3 遥测:fid9 由 8 跌到 4)。
// COLMAP 空间语义(纯位置 KNN)下,朝向无关,配额应打满。
void TestTurnSweepDoesNotStarve() {
  std::vector<aether::sfm::PairSelectionFrameV2> history;
  const double step_deg = 15.0;
  for (int i = 0; i < 12; ++i) {
    const double a = i * step_deg * M_PI / 180.0;
    // 位置沿弧线走,间距 ~0.2 m;朝向逐帧转 15°。
    history.push_back(Frame(i, 0.2 * i, 0.0, 0.0, std::sin(a), 0.0,
                            std::cos(a)));
  }
  const double ca = 12 * step_deg * M_PI / 180.0;  // 当前帧朝向已转 180°
  const auto current =
      Frame(12, 0.2 * 12, 0.0, 0.0, std::sin(ca), 0.0, std::cos(ca));

  aether::sfm::PairSelectionConfigV2 config;
  config.spatial_k = 10;
  config.temporal_lookback = 2;
  config.spatial_recent_exclusion = 2;
  const auto result = aether::sfm::SelectSpatialTemporalCandidatesV2(
      history, current, config);

  Check(result.spatial_count == 10,
        "turn sweep: spatial_count == 10 (got " +
            std::to_string(result.spatial_count) + ")");
  Check(result.temporal_count == 2,
        "turn sweep: temporal_count == 2 (got " +
            std::to_string(result.temporal_count) + ")");
  Check(result.ordered_pairs.size() == 12,
        "turn sweep: 12 unique pairs (got " +
            std::to_string(result.ordered_pairs.size()) + ")");
}

// 场景 2:同位置、正对面(180°)的历史帧必须可选 —— COLMAP 空间源不看朝向。
void TestOppositeFacingIsSelected() {
  std::vector<aether::sfm::PairSelectionFrameV2> history;
  history.push_back(Frame(0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0));
  const auto current = Frame(5, 0.1, 0.0, 0.0, 0.0, 0.0, 1.0);

  aether::sfm::PairSelectionConfigV2 config;
  config.spatial_k = 10;
  config.temporal_lookback = 0;
  config.spatial_recent_exclusion = 2;
  const auto result = aether::sfm::SelectSpatialTemporalCandidatesV2(
      history, current, config);

  Check(result.spatial_count == 1,
        "opposite facing: selected as spatial (got " +
            std::to_string(result.spatial_count) + ")");
}

// 场景 3:max_distance = 100(上游默认)截断:排序后越界即停。
void TestMaxDistanceCut() {
  std::vector<aether::sfm::PairSelectionFrameV2> history;
  history.push_back(Frame(0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0));    // 1 m
  history.push_back(Frame(1, 2.0, 0.0, 0.0, 0.0, 0.0, 1.0));    // 2 m
  history.push_back(Frame(2, 3.0, 0.0, 0.0, 0.0, 0.0, 1.0));    // 3 m
  history.push_back(Frame(3, 150.0, 0.0, 0.0, 0.0, 0.0, 1.0));  // 150 m
  history.push_back(Frame(4, 160.0, 0.0, 0.0, 0.0, 0.0, 1.0));  // 160 m
  const auto current = Frame(10, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0);

  aether::sfm::PairSelectionConfigV2 config;
  config.spatial_k = 10;
  config.temporal_lookback = 0;
  config.spatial_recent_exclusion = 2;
  const auto result = aether::sfm::SelectSpatialTemporalCandidatesV2(
      history, current, config);

  Check(result.spatial_count == 3,
        "max_distance: only the 3 within 100 m (got " +
            std::to_string(result.spatial_count) + ")");
  for (const auto& pair : result.ordered_pairs) {
    Check(pair.first_frame_id != 3 && pair.first_frame_id != 4,
          "max_distance: 150/160 m frames must be absent");
  }
}

// 场景 4(回归钉):当前帧无位姿 ⇒ 空间源为 0,时间源不受影响(原有语义)。
void TestPoseInvalidCurrentKeepsTemporalOnly() {
  std::vector<aether::sfm::PairSelectionFrameV2> history;
  for (int i = 0; i < 6; ++i) {
    history.push_back(Frame(i, 0.2 * i, 0.0, 0.0, 0.0, 0.0, 1.0));
  }
  auto current = Frame(6, 1.4, 0.0, 0.0, 0.0, 0.0, 1.0);
  current.pose_valid = false;

  aether::sfm::PairSelectionConfigV2 config;
  config.spatial_k = 10;
  config.temporal_lookback = 2;
  config.spatial_recent_exclusion = 2;
  const auto result = aether::sfm::SelectSpatialTemporalCandidatesV2(
      history, current, config);

  Check(result.spatial_count == 0, "no current pose: spatial_count == 0");
  Check(result.temporal_count == 2, "no current pose: temporal_count == 2");
  Check(result.ordered_pairs.size() == 2, "no current pose: 2 pairs");
}

// 场景 5(回归钉):recent_exclusion=0 时空间与时间可命中同一对,合并后
// source_mask 取并集(MergeCanonicalPairCandidatesV2 原有语义不变)。
void TestSourceMaskUnionUnchanged() {
  std::vector<aether::sfm::PairSelectionFrameV2> history;
  history.push_back(Frame(0, 0.1, 0.0, 0.0, 0.0, 0.0, 1.0));
  const auto current = Frame(1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0);

  aether::sfm::PairSelectionConfigV2 config;
  config.spatial_k = 10;
  config.temporal_lookback = 2;
  config.spatial_recent_exclusion = 0;
  const auto result = aether::sfm::SelectSpatialTemporalCandidatesV2(
      history, current, config);

  Check(result.ordered_pairs.size() == 1, "mask union: single unique pair");
  if (result.ordered_pairs.size() == 1) {
    const uint32_t mask = result.ordered_pairs[0].source_mask;
    const uint32_t want =
        static_cast<uint32_t>(aether::sfm::PairCandidateSourceV2::kSpatial) |
        static_cast<uint32_t>(aether::sfm::PairCandidateSourceV2::kTemporal);
    Check(mask == want, "mask union: spatial|temporal OR-preserved");
  }
}

}  // namespace

int main() {
  TestTurnSweepDoesNotStarve();
  TestOppositeFacingIsSelected();
  TestMaxDistanceCut();
  TestPoseInvalidCurrentKeepsTemporalOnly();
  TestSourceMaskUnionUnchanged();
  if (failures == 0) {
    std::cout << "PASS: pair_selection_v2 COLMAP spatial parity (5 scenarios)"
              << '\n';
    return 0;
  }
  std::cerr << failures << " failure(s)" << '\n';
  return 1;
}
