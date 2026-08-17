#include "pair_selection_v2.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using aether::sfm::CanonicalPairCandidateV2;
using aether::sfm::MergeCanonicalPairCandidatesV2;
using aether::sfm::PairCandidateSourceV2;
using aether::sfm::PairSelectionConfigV2;
using aether::sfm::PairSelectionFrameV2;
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

PairSelectionFrameV2 Frame(const int32_t id,
                           const std::array<double, 3> center,
                           const std::array<double, 3> forward = {0.0, 0.0, 1.0},
                           const bool pose_valid = true,
                           const bool matchable = true) {
  PairSelectionFrameV2 frame{};
  frame.frame_id = id;
  frame.center_xyz = center;
  frame.forward_xyz = forward;
  frame.pose_valid = pose_valid;
  frame.matchable = matchable;
  return frame;
}

void ExpectCandidate(const CanonicalPairCandidateV2& actual,
                     const int32_t first, const int32_t second,
                     const uint32_t source_mask, const std::string& name) {
  if (actual.first_frame_id != first || actual.second_frame_id != second ||
      actual.source_mask != source_mask) {
    std::cerr << "actual=(" << actual.first_frame_id << ','
              << actual.second_frame_id << ",mask=" << actual.source_mask
              << ") expected=(" << first << ',' << second
              << ",mask=" << source_mask << ")\n";
    Fail(name);
  }
}

std::vector<PairSelectionFrameV2> LinearHistory(const int32_t count) {
  std::vector<PairSelectionFrameV2> history;
  history.reserve(static_cast<size_t>(count));
  for (int32_t id = 0; id < count; ++id) {
    history.push_back(
        Frame(id, {static_cast<double>(count - id), 0.0, 0.0}));
  }
  return history;
}

void TestFullSpatialSetDoesNotConsumeT2() {
  const auto history = LinearHistory(30);
  const auto result = SelectSpatialTemporalCandidatesV2(
      history, Frame(30, {0.0, 0.0, 0.0}),
      PairSelectionConfigV2{.spatial_k = 20, .temporal_lookback = 2,
                            .spatial_recent_exclusion = 2});

  Expect(result.spatial_count == 20, "S20 must keep all 20 spatial slots");
  Expect(result.temporal_count == 2, "T2 must remain independent of S20");
  Expect(result.ordered_pairs.size() == 22,
         "a full S20 plus T2 must emit 22 unique pairs");
  ExpectCandidate(result.ordered_pairs.front(), 8, 30, kSpatial,
                  "oldest selected S20 pair");
  ExpectCandidate(result.ordered_pairs[19], 27, 30, kSpatial,
                  "S20 excludes current-1/current-2");
  ExpectCandidate(result.ordered_pairs[20], 28, 30, kTemporal,
                  "T2 contains current-2");
  ExpectCandidate(result.ordered_pairs[21], 29, 30, kTemporal,
                  "T2 contains current-1");
}

void TestT2AttemptsExactPreviousFrameIds() {
  auto history = LinearHistory(8);
  history[6].matchable = false;
  const auto result = SelectSpatialTemporalCandidatesV2(
      history, Frame(8, {0.0, 0.0, 0.0}),
      PairSelectionConfigV2{.spatial_k = 0, .temporal_lookback = 2,
                            .spatial_recent_exclusion = 2});

  Expect(result.ordered_pairs.size() == 1,
         "T2 must not silently backfill current-3 when current-2 is unusable");
  ExpectCandidate(result.ordered_pairs[0], 7, 8, kTemporal,
                  "T2 exact previous-id behavior");
}

void TestMissingPoseRetainsT2Only() {
  const auto history = LinearHistory(6);
  const auto result = SelectSpatialTemporalCandidatesV2(
      history, Frame(6, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, true),
      PairSelectionConfigV2{.spatial_k = 20, .temporal_lookback = 2,
                            .spatial_recent_exclusion = 2});

  Expect(result.spatial_count == 0, "missing current pose disables S20");
  Expect(result.temporal_count == 2, "missing current pose retains T2");
  Expect(result.ordered_pairs.size() == 2,
         "missing current pose emits T2 only");
  ExpectCandidate(result.ordered_pairs[0], 4, 6, kTemporal,
                  "missing-pose current-2");
  ExpectCandidate(result.ordered_pairs[1], 5, 6, kTemporal,
                  "missing-pose current-1");
}

void TestReverseFacingAndUnposedFramesStayOutOfSpatialPool() {
  std::vector<PairSelectionFrameV2> history = {
      Frame(0, {1.0, 0.0, 0.0}, {0.0, 0.0, -1.0}),
      Frame(1, {2.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, true),
      Frame(2, {3.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, true, false),
      Frame(3, {4.0, 0.0, 0.0}),
      Frame(4, {5.0, 0.0, 0.0}),
  };
  const auto result = SelectSpatialTemporalCandidatesV2(
      history, Frame(5, {0.0, 0.0, 0.0}),
      PairSelectionConfigV2{.spatial_k = 20, .temporal_lookback = 2,
                            .spatial_recent_exclusion = 2});

  Expect(result.spatial_count == 0,
         "reverse/unposed/unmatchable frames stay outside S20");
  Expect(result.temporal_count == 2, "recent usable frames remain T2");
  ExpectCandidate(result.ordered_pairs[0], 3, 5, kTemporal,
                  "recent exclusion frame current-2");
  ExpectCandidate(result.ordered_pairs[1], 4, 5, kTemporal,
                  "recent exclusion frame current-1");
}

void TestCanonicalUnionOrsEverySource() {
  const std::vector<CanonicalPairCandidateV2> candidates = {
      {.first_frame_id = 10, .second_frame_id = 4,
       .source_mask = kSpatial},
      {.first_frame_id = 4, .second_frame_id = 10,
       .source_mask = kTemporal},
      {.first_frame_id = 2, .second_frame_id = 10,
       .source_mask = kSpatial},
  };
  const auto merged = MergeCanonicalPairCandidatesV2(candidates);
  Expect(merged.size() == 2, "canonical union deduplicates reversed pair");
  ExpectCandidate(merged[0], 2, 10, kSpatial,
                  "canonical union deterministic ordering");
  ExpectCandidate(merged[1], 4, 10, kSpatial | kTemporal,
                  "canonical union ORs source provenance");
}

void TestKValuesHaveDeterministicMarginalPrefixes() {
  const auto history = LinearHistory(30);
  std::vector<int32_t> previous_spatial_ids;
  for (const int32_t k : {12, 16, 20}) {
    const auto result = SelectSpatialTemporalCandidatesV2(
        history, Frame(30, {0.0, 0.0, 0.0}),
        PairSelectionConfigV2{.spatial_k = k, .temporal_lookback = 2,
                              .spatial_recent_exclusion = 2});
    Expect(result.spatial_count == k, "S12/S16/S20 spatial count");
    Expect(result.temporal_count == 2, "S12/S16/S20 T2 count");

    std::vector<int32_t> spatial_ids;
    for (const auto& pair : result.ordered_pairs) {
      if ((pair.source_mask & kSpatial) != 0U) {
        spatial_ids.push_back(pair.first_frame_id);
      }
    }
    if (!previous_spatial_ids.empty()) {
      // In this monotonic-distance fixture, increasing K adds only older
      // spatial neighbors; the previously selected closest set is retained.
      for (const int32_t id : previous_spatial_ids) {
        Expect(std::find(spatial_ids.begin(), spatial_ids.end(), id) !=
                   spatial_ids.end(),
               "larger K retains the smaller-K spatial set");
      }
    }
    previous_spatial_ids = spatial_ids;
  }
}

void TestSmallHistoryAndZeroUsableFrames() {
  std::vector<PairSelectionFrameV2> history = {
      Frame(0, {2.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, true, false),
      Frame(1, {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, false, false),
  };
  const auto result = SelectSpatialTemporalCandidatesV2(
      history, Frame(2, {0.0, 0.0, 0.0}),
      PairSelectionConfigV2{.spatial_k = 20, .temporal_lookback = 2,
                            .spatial_recent_exclusion = 2});
  Expect(result.ordered_pairs.empty(), "zero usable history emits no pairs");
  Expect(result.spatial_count == 0 && result.temporal_count == 0,
         "zero usable history counters");
}

}  // namespace

int main() {
  TestFullSpatialSetDoesNotConsumeT2();
  TestT2AttemptsExactPreviousFrameIds();
  TestMissingPoseRetainsT2Only();
  TestReverseFacingAndUnposedFramesStayOutOfSpatialPool();
  TestCanonicalUnionOrsEverySource();
  TestKValuesHaveDeterministicMarginalPrefixes();
  TestSmallHistoryAndZeroUsableFrames();
  std::cout << "PASS pair_selection_v2 S20/T2 source union\n";
  return 0;
}
