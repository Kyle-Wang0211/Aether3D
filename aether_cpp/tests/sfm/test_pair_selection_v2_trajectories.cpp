#include "pair_selection_v2.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using aether::sfm::PairCandidateSourceV2;
using aether::sfm::PairSelectionConfigV2;
using aether::sfm::PairSelectionFrameV2;
using aether::sfm::PairSelectionResultV2;
using aether::sfm::SelectSpatialTemporalCandidatesV2;

constexpr uint32_t kSpatial =
    static_cast<uint32_t>(PairCandidateSourceV2::kSpatial);
constexpr uint32_t kTemporal =
    static_cast<uint32_t>(PairCandidateSourceV2::kTemporal);

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(const bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

PairSelectionFrameV2 Frame(const int32_t id, const double x,
                           const double y) {
  return {.frame_id = id,
          .center_xyz = {x, y, 0.0},
          .forward_xyz = {0.0, 0.0, 1.0},
          .pose_valid = true,
          .matchable = true};
}

std::vector<int32_t> IdsWithSource(const PairSelectionResultV2& result,
                                   const uint32_t source) {
  std::vector<int32_t> ids;
  for (const auto& pair : result.ordered_pairs) {
    if ((pair.source_mask & source) != 0U) {
      ids.push_back(pair.first_frame_id);
    }
  }
  return ids;
}

void ExpectIds(const std::vector<int32_t>& actual,
               const std::vector<int32_t>& expected,
               const std::string& name) {
  if (actual == expected) return;
  std::cerr << "expected:";
  for (const int32_t id : expected) std::cerr << ' ' << id;
  std::cerr << "\nactual:";
  for (const int32_t id : actual) std::cerr << ' ' << id;
  std::cerr << '\n';
  Fail(name);
}

PairSelectionResultV2 Select(const std::vector<PairSelectionFrameV2>& history,
                             const PairSelectionFrameV2& current,
                             const int32_t spatial_k) {
  return SelectSpatialTemporalCandidatesV2(
      history, current,
      {.spatial_k = spatial_k,
       .temporal_lookback = 2,
       .spatial_recent_exclusion = 2});
}

void TestThreeLoopSquareReturnsPriorLoops() {
  const std::array<std::array<double, 2>, 4> square = {
      std::array<double, 2>{0.0, 0.0}, {1.0, 1.0}, {2.0, 0.0},
      {1.0, -1.0}};
  std::vector<PairSelectionFrameV2> history;
  for (int32_t id = 0; id < 12; ++id) {
    const auto& point = square[static_cast<size_t>(id % 4)];
    history.push_back(Frame(id, point[0], point[1]));
  }

  const auto result = Select(history, Frame(12, 0.0, 0.0), 5);
  ExpectIds(IdsWithSource(result, kSpatial), {0, 1, 3, 4, 8},
            "three-loop square spatial golden");
  ExpectIds(IdsWithSource(result, kTemporal), {10, 11},
            "three-loop square temporal golden");
}

void TestSingleLoopKeepsContinuityAndSpatialCoverage() {
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, 0.0, 0.0), Frame(1, 1.0, 1.0),
      Frame(2, 2.0, 0.0), Frame(3, 1.0, -1.0)};
  const auto result = Select(history, Frame(4, 0.0, 0.0), 20);
  ExpectIds(IdsWithSource(result, kSpatial), {0, 1},
            "single-loop non-recent spatial golden");
  ExpectIds(IdsWithSource(result, kTemporal), {2, 3},
            "single-loop recent temporal golden");
}

void TestOutAndBackReconnectsReturnPath() {
  const std::array<double, 8> x = {0.0, 1.0, 2.0, 3.0,
                                    4.0, 3.0, 2.0, 1.0};
  std::vector<PairSelectionFrameV2> history;
  for (int32_t id = 0; id < static_cast<int32_t>(x.size()); ++id) {
    history.push_back(Frame(id, x[static_cast<size_t>(id)], 0.0));
  }
  const auto result = Select(history, Frame(8, 0.0, 0.0), 4);
  ExpectIds(IdsWithSource(result, kSpatial), {0, 1, 2, 3},
            "out-and-back spatial golden");
  ExpectIds(IdsWithSource(result, kTemporal), {6, 7},
            "out-and-back temporal golden");
}

void TestFigureEightReconnectsCrossing() {
  const std::array<std::array<double, 2>, 8> points = {
      std::array<double, 2>{0.0, 0.0}, {1.0, 1.0}, {0.0, 0.0},
      {-1.0, 1.0}, {0.0, 0.0}, {1.0, -1.0}, {0.0, 0.0},
      {-1.0, -1.0}};
  std::vector<PairSelectionFrameV2> history;
  for (int32_t id = 0; id < static_cast<int32_t>(points.size()); ++id) {
    const auto& point = points[static_cast<size_t>(id)];
    history.push_back(Frame(id, point[0], point[1]));
  }
  const auto result = Select(history, Frame(8, 0.0, 0.0), 4);
  ExpectIds(IdsWithSource(result, kSpatial), {0, 1, 2, 4},
            "figure-eight spatial crossing golden");
  ExpectIds(IdsWithSource(result, kTemporal), {6, 7},
            "figure-eight temporal golden");
}

void TestTwentyFrameMinimumUsesEveryAvailableFrameOnce() {
  std::vector<PairSelectionFrameV2> history;
  for (int32_t id = 0; id < 19; ++id) {
    history.push_back(Frame(id, static_cast<double>(19 - id), 0.0));
  }
  const auto result = Select(history, Frame(19, 0.0, 0.0), 20);
  Expect(result.spatial_count == 17,
         "20-frame minimum has 17 non-recent spatial candidates");
  Expect(result.temporal_count == 2,
         "20-frame minimum has two temporal candidates");
  Expect(result.ordered_pairs.size() == 19,
         "20-frame minimum emits every prior matchable frame once");
}

void TestThreeHundredFrameRepeatedOrbitHasBoundedPairCount() {
  std::vector<PairSelectionFrameV2> history;
  history.reserve(300);
  for (int32_t id = 0; id < 300; ++id) {
    const int32_t phase = id % 30;
    history.push_back(Frame(id, static_cast<double>(phase),
                            static_cast<double>((phase * 7) % 30)));
  }
  const auto result = Select(history, Frame(300, 0.0, 0.0), 20);
  Expect(result.spatial_count == 20, "300-frame orbit fills S20");
  Expect(result.temporal_count == 2, "300-frame orbit fills T2");
  Expect(result.ordered_pairs.size() == 22,
         "300-frame orbit remains bounded at S20+T2");
  const auto spatial_ids = IdsWithSource(result, kSpatial);
  Expect(!spatial_ids.empty() && spatial_ids.front() == 0,
         "300-frame orbit recovers the oldest exact revisit");
}

}  // namespace

int main() {
  TestThreeLoopSquareReturnsPriorLoops();
  TestSingleLoopKeepsContinuityAndSpatialCoverage();
  TestOutAndBackReconnectsReturnPath();
  TestFigureEightReconnectsCrossing();
  TestTwentyFrameMinimumUsesEveryAvailableFrameOnce();
  TestThreeHundredFrameRepeatedOrbitHasBoundedPairCount();
  std::cout << "PASS pair_selection_v2 trajectory goldens\n";
  return 0;
}
