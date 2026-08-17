#include "pair_selection_v2.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

using aether::sfm::PairSelectionFrameV2;
using aether::sfm::PairSelectionLegacyResultV2;
using aether::sfm::SelectLegacySpatialCandidatesV2;

constexpr double kPi = 3.141592653589793238462643383279502884;
constexpr double kMinViewDot =
    0.707106781186547524400844362104849039;  // cos(45 deg)

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

void ExpectIds(const std::vector<int32_t>& actual,
               std::initializer_list<int32_t> expected,
               const std::string& name) {
  const std::vector<int32_t> expected_vec(expected);
  if (actual != expected_vec) {
    std::cerr << "expected:";
    for (const int32_t id : expected_vec) std::cerr << ' ' << id;
    std::cerr << "\nactual:";
    for (const int32_t id : actual) std::cerr << ' ' << id;
    std::cerr << '\n';
    Fail(name);
  }
}

PairSelectionFrameV2 Frame(int32_t id, std::array<double, 3> center,
                           std::array<double, 3> forward,
                           bool pose_valid = true,
                           bool matchable = true) {
  PairSelectionFrameV2 frame{};
  frame.frame_id = id;
  frame.center_xyz = center;
  frame.forward_xyz = forward;
  frame.pose_valid = pose_valid;
  frame.matchable = matchable;
  return frame;
}

double Dot(const std::array<double, 3>& a,
           const std::array<double, 3>& b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

double SquaredDistance(const std::array<double, 3>& a,
                       const std::array<double, 3>& b) {
  const double dx = a[0] - b[0];
  const double dy = a[1] - b[1];
  const double dz = a[2] - b[2];
  return dx * dx + dy * dy + dz * dz;
}

PairSelectionLegacyResultV2 LegacyOracle(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current, int32_t k, bool temporal_only) {
  PairSelectionLegacyResultV2 result{};
  if (k <= 0 || current.frame_id <= 0) return result;

  if (!temporal_only && current.pose_valid) {
    std::vector<std::pair<double, int32_t>> compatible;
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < 0 || previous.frame_id >= current.frame_id ||
          !previous.pose_valid || !previous.matchable) {
        continue;
      }
      const double dot = std::clamp(
          Dot(current.forward_xyz, previous.forward_xyz), -1.0, 1.0);
      if (dot < kMinViewDot) continue;
      compatible.emplace_back(
          SquaredDistance(current.center_xyz, previous.center_xyz),
          previous.frame_id);
    }
    const int32_t spatial_count = std::min<int32_t>(
        k, static_cast<int32_t>(compatible.size()));
    std::partial_sort(compatible.begin(),
                      compatible.begin() + spatial_count, compatible.end());
    for (int32_t index = 0; index < spatial_count; ++index) {
      result.ordered_frame_ids.push_back(compatible[index].second);
    }
    result.spatial_count = spatial_count;
  }

  if (static_cast<int32_t>(result.ordered_frame_ids.size()) < k) {
    std::unordered_set<int32_t> chosen(result.ordered_frame_ids.begin(),
                                       result.ordered_frame_ids.end());
    for (auto it = history.rbegin(); it != history.rend() &&
                                        static_cast<int32_t>(
                                            result.ordered_frame_ids.size()) <
                                            k;
         ++it) {
      if (it->frame_id < 0 || it->frame_id >= current.frame_id ||
          !it->matchable || !chosen.insert(it->frame_id).second) {
        continue;
      }
      result.ordered_frame_ids.push_back(it->frame_id);
      ++result.temporal_count;
    }
  }

  std::sort(result.ordered_frame_ids.begin(),
            result.ordered_frame_ids.end());
  return result;
}

void TestTemporalOnlyWindow() {
  std::vector<PairSelectionFrameV2> history;
  for (int32_t id = 0; id < 6; ++id) {
    history.push_back(Frame(id, {static_cast<double>(id), 0.0, 0.0},
                            {0.0, 0.0, 1.0}));
  }
  const auto result = SelectLegacySpatialCandidatesV2(
      history, Frame(6, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 3, true);
  ExpectIds(result.ordered_frame_ids, {3, 4, 5},
            "temporal-only returns the latest K in ascending order");
  Expect(result.spatial_count == 0, "temporal-only spatial count");
  Expect(result.temporal_count == 3, "temporal-only temporal count");
}

void TestSpatialDistanceAndDirection() {
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, {5.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(1, {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(2, {2.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(3, {0.5, 0.0, 0.0}, {0.0, 0.0, -1.0}),
      Frame(4, {0.25, 0.0, 0.0}, {0.0, 0.0, 1.0}, true, false),
      Frame(5, {0.1, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, true),
  };
  const auto result = SelectLegacySpatialCandidatesV2(
      history, Frame(6, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 2, false);
  ExpectIds(result.ordered_frame_ids, {1, 2},
            "spatial selection rejects reverse/unusable/unposed frames");
  Expect(result.spatial_count == 2, "spatial distance count");
  Expect(result.temporal_count == 0, "spatial distance fill count");
}

void TestTemporalFillIncludesUnposedFrames() {
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, {8.0, 0.0, 0.0}, {0.0, 0.0, -1.0}),
      Frame(1, {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(2, {7.0, 0.0, 0.0}, {0.0, 0.0, -1.0}),
      Frame(3, {6.0, 0.0, 0.0}, {0.0, 0.0, -1.0}),
      Frame(4, {5.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, true, false),
      Frame(5, {4.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, true),
  };
  const auto result = SelectLegacySpatialCandidatesV2(
      history, Frame(6, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 4, false);
  ExpectIds(result.ordered_frame_ids, {1, 2, 3, 5},
            "temporal fill uses recent matchable frames regardless of pose");
  Expect(result.spatial_count == 1, "temporal-fill spatial count");
  Expect(result.temporal_count == 3, "temporal-fill temporal count");
}

void TestStableDistanceTie() {
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, {9.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(1, {-1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(2, {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
  };
  const auto result = SelectLegacySpatialCandidatesV2(
      history, Frame(3, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 1, false);
  ExpectIds(result.ordered_frame_ids, {1},
            "distance tie uses the smaller frame id");
}

void TestViewAngleBoundary() {
  const double radians = 45.0 * kPi / 180.0;
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, {1.0, 0.0, 0.0},
            {std::sin(radians), 0.0, std::cos(radians)}),
      Frame(1, {2.0, 0.0, 0.0},
            {std::sin(radians + 1e-6), 0.0,
             std::cos(radians + 1e-6)}),
  };
  const auto result = SelectLegacySpatialCandidatesV2(
      history, Frame(2, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 1, false);
  ExpectIds(result.ordered_frame_ids, {0},
            "45-degree boundary is included and the larger angle is excluded");
  Expect(result.spatial_count == 1, "view boundary spatial count");
}

void TestMissingCurrentPoseFallsBack() {
  const std::vector<PairSelectionFrameV2> history = {
      Frame(0, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(1, {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
      Frame(2, {2.0, 0.0, 0.0}, {0.0, 0.0, 1.0}),
  };
  const auto result = SelectLegacySpatialCandidatesV2(
      history,
      Frame(3, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, true), 2,
      false);
  ExpectIds(result.ordered_frame_ids, {1, 2},
            "missing current pose falls back to temporal");
  Expect(result.spatial_count == 0, "missing-pose spatial count");
  Expect(result.temporal_count == 2, "missing-pose temporal count");
}

void TestEmptyAndZeroK() {
  const std::vector<PairSelectionFrameV2> empty;
  const auto zero_k = SelectLegacySpatialCandidatesV2(
      empty, Frame(0, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}), 0, false);
  Expect(zero_k.ordered_frame_ids.empty(), "zero K is empty");
  Expect(zero_k.spatial_count == 0 && zero_k.temporal_count == 0,
         "zero K counters");
}

void TestSeededLegacyOracleParity() {
  std::mt19937_64 rng(20260803);
  std::uniform_real_distribution<double> coordinate(-5.0, 5.0);
  std::bernoulli_distribution present(0.83);
  std::bernoulli_distribution pose(0.81);
  std::bernoulli_distribution temporal_only(0.27);

  for (int iteration = 0; iteration < 500; ++iteration) {
    const int32_t count = 1 + static_cast<int32_t>(rng() % 48);
    std::vector<PairSelectionFrameV2> history;
    history.reserve(static_cast<size_t>(count));
    for (int32_t id = 0; id < count; ++id) {
      const double angle = coordinate(rng);
      history.push_back(Frame(
          id, {coordinate(rng), coordinate(rng), coordinate(rng)},
          {std::sin(angle), 0.0, std::cos(angle)}, pose(rng), present(rng)));
    }
    const double current_angle = coordinate(rng);
    const PairSelectionFrameV2 current = Frame(
        count, {coordinate(rng), coordinate(rng), coordinate(rng)},
        {std::sin(current_angle), 0.0, std::cos(current_angle)}, pose(rng),
        true);
    const int32_t k = static_cast<int32_t>(rng() % 24);
    const bool force_temporal = temporal_only(rng);
    const auto expected = LegacyOracle(history, current, k, force_temporal);
    const auto actual = SelectLegacySpatialCandidatesV2(
        history, current, k, force_temporal);
    if (actual.ordered_frame_ids != expected.ordered_frame_ids ||
        actual.spatial_count != expected.spatial_count ||
        actual.temporal_count != expected.temporal_count) {
      Fail("seeded legacy oracle parity iteration " +
           std::to_string(iteration));
    }
  }
}

}  // namespace

int main() {
  TestTemporalOnlyWindow();
  TestSpatialDistanceAndDirection();
  TestTemporalFillIncludesUnposedFrames();
  TestStableDistanceTie();
  TestViewAngleBoundary();
  TestMissingCurrentPoseFallsBack();
  TestEmptyAndZeroK();
  TestSeededLegacyOracleParity();
  std::cout << "PASS pair_selection_v2 legacy characterization\n";
  return 0;
}
