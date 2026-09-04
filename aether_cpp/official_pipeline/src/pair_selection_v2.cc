#include "pair_selection_v2.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <unordered_set>
#include <utility>
#include <cstdlib>
#include <vector>

namespace aether::sfm {
namespace {

constexpr double kPi = 3.141592653589793238462643383279502884;
constexpr double kViewAngleMaxDegDefault = 45.0;

// [VIEW-ANGLE-AB 2026-08-11] 主光轴夹角门做成 env 可调,用于 host A/B。
// 现状 45°(出货,写死已久);hloc(Apache-2.0)的 pairs_from_poses 用 30°。
// 收紧 = 候选更共视但可能丢真配对;放宽 = 机会更多但废配对更多 —— 方向
// 靠实测定,不猜。unset ⇒ 45.0,与出货逐字节一致。
double ViewAngleMaxRad() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_VIEW_ANGLE_MAX_DEG");
    double deg = kViewAngleMaxDegDefault;
    if (e && *e) {
      const double v = std::atof(e);
      if (v > 0.0 && v <= 180.0) deg = v;
    }
    return deg * kPi / 180.0;
  }();
  return cached;
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

}  // namespace

PairSelectionLegacyResultV2 SelectLegacySpatialCandidatesV2(
    const std::vector<PairSelectionFrameV2>& history,
    const PairSelectionFrameV2& current, const int32_t k,
    const bool temporal_only) {
  PairSelectionLegacyResultV2 result;
  if (k <= 0 || current.frame_id <= 0) return result;
  result.ordered_frame_ids.reserve(static_cast<size_t>(k));

  if (!temporal_only && current.pose_valid) {
    const double min_dot = std::cos(ViewAngleMaxRad());
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
    // [COLMAP-SPATIAL-PARITY 2026-09-02] Spatial eligibility now replicates
    // COLMAP SpatialPairGenerator::Next() (colmap/controllers/pairing.cc,
    // vendored tree third_party/glomap_vendor/colmap-src, COLMAP 3.14.0.dev0,
    // BSD-3-Clause): position-KNN sorted by distance, cut by max_distance —
    // and NOTHING else. The former self-invented 45-degree forward-axis gate
    // (view-angle cone) is REMOVED from this production path: it made the
    // candidate COUNT collapse whenever the camera forward axis swept through
    // a turn (n_cand 8→3 mid-session, 2026-09-02 telemetry), which no COLMAP
    // pair source does. Upstream defaults (pairing.h): max_distance = 100,
    // min_num_neighbors = 0. Upstream break predicate (pairing.cc, Next()):
    //   if (distance_squared_matrix_(current_idx_, j) > max_distance_squared
    //       && j > options_.min_num_neighbors) break;
    // where j indexes the KNN result INCLUDING the query itself at j == 0
    // (skipped via an identity check). Our `compatible` list never contains
    // the query, so our 0-based index maps to upstream's j - 1; the literal
    // transcription is therefore `index + 1 > kSpatialMinNumNeighbors`.
    constexpr double kSpatialMaxDistance = 100.0;   // COLMAP pairing.h default
    constexpr int32_t kSpatialMinNumNeighbors = 0;  // COLMAP pairing.h default
    const double max_distance_squared =
        kSpatialMaxDistance * kSpatialMaxDistance;
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
      compatible.emplace_back(
          SquaredDistance(current.center_xyz, previous.center_xyz),
          previous.frame_id);
    }

    const int32_t knn = std::min<int32_t>(
        spatial_k, static_cast<int32_t>(compatible.size()));
    std::partial_sort(compatible.begin(), compatible.begin() + knn,
                      compatible.end());
    for (int32_t index = 0; index < knn; ++index) {
      if (compatible[index].first > max_distance_squared &&
          index + 1 > kSpatialMinNumNeighbors) {
        break;
      }
      candidates.push_back(
          {.first_frame_id = compatible[index].second,
           .second_frame_id = current.frame_id,
           .source_mask =
               static_cast<uint32_t>(PairCandidateSourceV2::kSpatial)});
      ++result.spatial_count;
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
