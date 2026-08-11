#include "pair_selection_v2.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace aether::sfm {
namespace {

constexpr double kPi = 3.141592653589793238462643383279502884;
constexpr double kViewAngleMaxRad = 45.0 * kPi / 180.0;

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

}  // namespace

PairSelectionLegacyResultV2 SelectLegacySpatialCandidatesV2(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current, const int32_t k,
    const bool temporal_only) {
  PairSelectionLegacyResultV2 result;
  if (k <= 0 || current.frame_id <= 0) return result;
  result.ordered_frame_ids.reserve(static_cast<size_t>(k));

  if (!temporal_only && current.pose_valid) {
    const double min_dot = std::cos(kViewAngleMaxRad);
    std::vector<std::pair<double, int32_t>> compatible;
    compatible.reserve(history.size());
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < 0 || previous.frame_id >= current.frame_id ||
          !previous.pose_valid || !previous.matchable) {
        continue;
      }
      const double dot = std::clamp(
          Dot(current.forward_xyz, previous.forward_xyz), -1.0, 1.0);
      if (dot < min_dot) continue;
      compatible.emplace_back(
          SquaredDistance(current.center_xyz, previous.center_xyz),
          previous.frame_id);
    }

    result.spatial_count = std::min<int32_t>(
        k, static_cast<int32_t>(compatible.size()));
    std::partial_sort(compatible.begin(),
                      compatible.begin() + result.spatial_count,
                      compatible.end());
    for (int32_t index = 0; index < result.spatial_count; ++index) {
      result.ordered_frame_ids.push_back(compatible[index].second);
    }
  }

  if (static_cast<int32_t>(result.ordered_frame_ids.size()) < k) {
    std::unordered_set<int32_t> chosen(result.ordered_frame_ids.begin(),
                                       result.ordered_frame_ids.end());
    for (auto it = history.rbegin();
         it != history.rend() &&
         static_cast<int32_t>(result.ordered_frame_ids.size()) < k;
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

std::vector<CanonicalPairCandidateV2> MergeCanonicalPairCandidatesV2(
    const std::vector<CanonicalPairCandidateV2>& candidates) {
  std::map<std::pair<int32_t, int32_t>, uint32_t> source_by_pair;
  for (const CanonicalPairCandidateV2& candidate : candidates) {
    if (candidate.first_frame_id < 0 || candidate.second_frame_id < 0 ||
        candidate.first_frame_id == candidate.second_frame_id ||
        candidate.source_mask == 0U) {
      continue;
    }
    const int32_t first =
        std::min(candidate.first_frame_id, candidate.second_frame_id);
    const int32_t second =
        std::max(candidate.first_frame_id, candidate.second_frame_id);
    source_by_pair[{first, second}] |= candidate.source_mask;
  }

  std::vector<CanonicalPairCandidateV2> merged;
  merged.reserve(source_by_pair.size());
  for (const auto& [pair, source_mask] : source_by_pair) {
    merged.push_back({.first_frame_id = pair.first,
                      .second_frame_id = pair.second,
                      .source_mask = source_mask});
  }
  return merged;
}

PairSelectionResultV2 SelectSpatialTemporalCandidatesV2(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current,
    const PairSelectionConfigV2& config) {
  PairSelectionResultV2 result;
  if (current.frame_id <= 0) return result;

  const int32_t spatial_k = std::max(config.spatial_k, 0);
  const int32_t temporal_lookback =
      std::min(std::max(config.temporal_lookback, 0), current.frame_id);
  const int32_t recent_exclusion =
      std::max(config.spatial_recent_exclusion, 0);

  std::vector<CanonicalPairCandidateV2> candidates;
  candidates.reserve(
      static_cast<size_t>(spatial_k + temporal_lookback));

  if (spatial_k > 0 && current.pose_valid) {
    const double min_dot = std::cos(kViewAngleMaxRad);
    std::vector<std::pair<double, int32_t>> compatible;
    compatible.reserve(history.size());
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < 0 || previous.frame_id >= current.frame_id ||
          !previous.pose_valid || !previous.matchable) {
        continue;
      }
      if (recent_exclusion > 0 &&
          previous.frame_id >= current.frame_id - recent_exclusion) {
        continue;
      }
      const double dot = std::clamp(
          Dot(current.forward_xyz, previous.forward_xyz), -1.0, 1.0);
      if (dot < min_dot) continue;
      compatible.emplace_back(
          SquaredDistance(current.center_xyz, previous.center_xyz),
          previous.frame_id);
    }

    result.spatial_count = std::min<int32_t>(
        spatial_k, static_cast<int32_t>(compatible.size()));
    std::partial_sort(compatible.begin(),
                      compatible.begin() + result.spatial_count,
                      compatible.end());
    for (int32_t index = 0; index < result.spatial_count; ++index) {
      candidates.push_back(
          {.first_frame_id = compatible[index].second,
           .second_frame_id = current.frame_id,
           .source_mask =
               static_cast<uint32_t>(PairCandidateSourceV2::kSpatial)});
    }
  }

  if (temporal_lookback > 0) {
    const int32_t oldest_temporal_id =
        current.frame_id - temporal_lookback;
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < oldest_temporal_id ||
          previous.frame_id >= current.frame_id || !previous.matchable) {
        continue;
      }
      candidates.push_back(
          {.first_frame_id = previous.frame_id,
           .second_frame_id = current.frame_id,
           .source_mask =
               static_cast<uint32_t>(PairCandidateSourceV2::kTemporal)});
      ++result.temporal_count;
    }
  }

  result.ordered_pairs = MergeCanonicalPairCandidatesV2(candidates);
  return result;
}

}  // namespace aether::sfm
