#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace aether::sfm {

// Platform-neutral projection of the fields used by the existing production
// SelectStreamCandidates policy. The Phase-1 adapter supplies history in
// strictly increasing frame_id order, matching Session::frames indexing.
struct PairSelectionFrameV2 {
  int32_t frame_id = -1;
  std::array<double, 3> center_xyz{};
  std::array<double, 3> forward_xyz{};
  bool pose_valid = false;
  bool matchable = false;
};

struct PairSelectionLegacyResultV2 {
  std::vector<int32_t> ordered_frame_ids;
  int32_t spatial_count = 0;
  int32_t temporal_count = 0;
};

enum class PairCandidateSourceV2 : uint32_t {
  kSpatial = 1U << 0U,
  kTemporal = 1U << 1U,
  kVisualLoop = 1U << 2U,
  kQuadraticBackstop = 1U << 3U,
};

// Canonical pair identity and the OR-union of every policy source that emitted
// it. first_frame_id is always less than second_frame_id.
struct CanonicalPairCandidateV2 {
  int32_t first_frame_id = -1;
  int32_t second_frame_id = -1;
  uint32_t source_mask = 0;
};

struct PairSelectionConfigV2 {
  int32_t spatial_k = 20;
  int32_t temporal_lookback = 2;
  int32_t spatial_recent_exclusion = 2;
};

struct PairSelectionResultV2 {
  std::vector<CanonicalPairCandidateV2> ordered_pairs;
  int32_t spatial_count = 0;
  int32_t temporal_count = 0;
};

// Characterized legacy-compatible policy:
//   - spatial KNN with the production 45-degree forward-axis gate;
//   - recent temporal fill when the spatial set is short;
//   - full temporal fallback when forced or when current pose is missing;
//   - final ascending frame-id order.
//
// This Phase-1 API intentionally does not implement independent S20 and T2
// sources. That semantic change is introduced by a later RED/GREEN cycle.
PairSelectionLegacyResultV2 SelectLegacySpatialCandidatesV2(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current, int32_t k, bool temporal_only);

// Canonicalizes, orders, and deduplicates arbitrary sourced pair candidates.
// Source masks are OR-preserved so policy telemetry remains lossless even when
// multiple sources select the same pair.
std::vector<CanonicalPairCandidateV2> MergeCanonicalPairCandidatesV2(
    const std::vector<CanonicalPairCandidateV2>& candidates);

// Product-candidate policy core. Spatial and temporal sources have independent
// budgets: S(K) excludes recent frame ids, while T(N) attempts exactly the N
// immediately preceding frame ids. T(N) never fills unused S(K) slots and does
// not backfill an unavailable recent id with an older temporal frame.
PairSelectionResultV2 SelectSpatialTemporalCandidatesV2(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current,
    const PairSelectionConfigV2& config);

}  // namespace aether::sfm
