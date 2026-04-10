// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_BUDGET_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_BUDGET_H

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <vector>

namespace aether {
namespace pipeline {
namespace local_subject_first_capture_budget {

inline constexpr std::size_t kConfirmedOverlayCellCap = 8000u;
inline constexpr std::size_t kConfirmedDenseCellCap = 48000u;

struct CaptureBudgetReleaseSummary {
    bool released{false};
    std::size_t overlay_cache_count{0};
    std::size_t stable_surface_count{0};
    std::size_t overlay_cell_count{0};
    std::size_t dense_cell_count{0};
    std::size_t stable_dense_count{0};
    std::size_t pointmap_keyframe_count{0};
    std::size_t gsf_seeded_count{0};
    std::size_t bootstrap_point_count{0};
    std::size_t bootstrap_normal_count{0};
    std::size_t retained_depth_keyframes{0};
};

struct CaptureBudgetPruneSummary {
    std::size_t overlay_removed{0};
    std::size_t overlay_kept{0};
    std::size_t dense_removed{0};
    std::size_t dense_kept{0};
};

inline bool should_release_capture_preview_budget(
    bool release_requested,
    bool released,
    bool scanning_active,
    bool features_frozen) noexcept
{
    return release_requested &&
           !released &&
           !scanning_active &&
           features_frozen;
}

template <typename KeyedContainer, typename ScoreFn>
inline std::size_t prune_ranked_capture_keys(
    KeyedContainer& container,
    std::size_t cap,
    ScoreFn&& score_fn)
{
    if (container.size() <= cap) {
        return 0;
    }

    const std::size_t prune_count = container.size() - cap;
    using KeyType = typename std::decay_t<KeyedContainer>::key_type;
    std::vector<std::pair<float, KeyType>> ranked;
    ranked.reserve(container.size());
    for (const auto& [key, value] : container) {
        ranked.emplace_back(score_fn(value), key);
    }
    if (prune_count >= ranked.size()) {
        const std::size_t removed = container.size();
        container.clear();
        container.rehash(0);
        return removed;
    }
    std::nth_element(
        ranked.begin(),
        ranked.begin() + static_cast<std::ptrdiff_t>(prune_count),
        ranked.end(),
        [](const auto& a, const auto& b) {
            if (a.first != b.first) {
                return a.first < b.first;
            }
            return a.second < b.second;
        });
    for (std::size_t i = 0; i < prune_count; ++i) {
        container.erase(ranked[i].second);
    }
    return prune_count;
}

template <typename OverlayCellMap, typename DenseCellMap>
inline CaptureBudgetPruneSummary prune_capture_preview_budget(
    double timestamp_seconds,
    OverlayCellMap& confirmed_overlay_cells,
    DenseCellMap& confirmed_dense_cells) noexcept
{
    CaptureBudgetPruneSummary summary;
    summary.overlay_removed = prune_ranked_capture_keys(
        confirmed_overlay_cells,
        kConfirmedOverlayCellCap,
        [timestamp_seconds](const auto& tile) {
            const float staleness = static_cast<float>(
                std::max(0.0, timestamp_seconds - tile.last_update_ts));
            const float support_norm =
                std::clamp(tile.support_count / 6.0f, 0.0f, 1.0f);
            const float fresh_bonus = staleness < 0.35f ? 1.0f : 0.0f;
            return fresh_bonus +
                   2.30f * std::clamp(tile.quality, 0.0f, 1.0f) +
                   1.35f * std::clamp(tile.stability, 0.0f, 1.0f) +
                   0.60f * support_norm -
                   0.14f * std::min(staleness, 12.0f);
        });

    summary.dense_removed = prune_ranked_capture_keys(
        confirmed_dense_cells,
        kConfirmedDenseCellCap,
        [timestamp_seconds](const auto& cell) {
            const float staleness = static_cast<float>(
                std::max(0.0, timestamp_seconds - cell.last_update_ts));
            const float average_confidence =
                cell.confidence_accum /
                std::max(1.0f, static_cast<float>(cell.update_count));
            const float confidence_norm = std::clamp(
                std::log1pf(std::max(0.0f, average_confidence)) / std::log1pf(4.0f),
                0.0f,
                1.0f);
            const float keyframe_norm = std::clamp(
                static_cast<float>(cell.unique_keyframes_seen) / 4.0f,
                0.0f,
                1.0f);
            const float fresh_bonus = staleness < 0.50f ? 1.0f : 0.0f;
            return fresh_bonus +
                   2.10f * std::max(
                       std::clamp(cell.display_quality_peak, 0.0f, 1.0f),
                       std::clamp(cell.quality, 0.0f, 1.0f)) +
                   1.25f * std::clamp(cell.stability, 0.0f, 1.0f) +
                   0.75f * confidence_norm +
                   0.60f * keyframe_norm -
                   0.12f * std::min(staleness, 15.0f);
        });

    summary.overlay_kept = confirmed_overlay_cells.size();
    summary.dense_kept = confirmed_dense_cells.size();
    return summary;
}

template <typename OverlayCache,
          typename StableSurfaceOverlay,
          typename OverlayCellMap,
          typename DenseCellMap,
          typename StableDenseVertices,
          typename PointmapKeyframeVector,
          typename SeededCellSet,
          typename BootstrapPointVector,
          typename BootstrapNormalVector>
inline CaptureBudgetReleaseSummary release_capture_preview_budget(
    std::atomic<bool>& release_requested,
    std::atomic<bool>& released,
    OverlayCache& overlay_cache,
    StableSurfaceOverlay& stable_surface_overlay,
    OverlayCellMap& confirmed_overlay_cells,
    DenseCellMap& confirmed_dense_cells,
    StableDenseVertices& stable_dense_vertices,
    PointmapKeyframeVector& pointmap_keyframes,
    std::uint32_t& next_pointmap_keyframe_id,
    std::uint32_t& active_pointmap_keyframe_id,
    SeededCellSet& gsf_seeded_cells,
    BootstrapPointVector& bootstrap_target_points_world,
    BootstrapNormalVector& bootstrap_target_normals_world,
    bool& bootstrap_pose_initialized,
    float bootstrap_pose[16],
    bool& bootstrap_intrinsics_initialized,
    float bootstrap_intrinsics[9],
    std::chrono::steady_clock::time_point& overlay_last_gen_time,
    bool& has_keyframe,
    bool& has_preview_selected_keyframe,
    std::size_t retained_depth_keyframes) noexcept
{
    CaptureBudgetReleaseSummary summary;
    if (released.exchange(true, std::memory_order_acq_rel)) {
        return summary;
    }
    release_requested.store(false, std::memory_order_release);

    summary.released = true;
    summary.retained_depth_keyframes = retained_depth_keyframes;
    summary.overlay_cache_count = overlay_cache.size();
    summary.stable_surface_count = stable_surface_overlay.size();
    summary.overlay_cell_count = confirmed_overlay_cells.size();
    summary.dense_cell_count = confirmed_dense_cells.size();
    summary.stable_dense_count = stable_dense_vertices.size();
    summary.pointmap_keyframe_count = pointmap_keyframes.size();
    summary.gsf_seeded_count = gsf_seeded_cells.size();
    summary.bootstrap_point_count = bootstrap_target_points_world.size();
    summary.bootstrap_normal_count = bootstrap_target_normals_world.size();

    overlay_cache.clear();
    overlay_cache.shrink_to_fit();
    stable_surface_overlay.clear();
    stable_surface_overlay.shrink_to_fit();
    confirmed_overlay_cells.clear();
    confirmed_overlay_cells.rehash(0);
    confirmed_dense_cells.clear();
    confirmed_dense_cells.rehash(0);
    stable_dense_vertices.clear();
    stable_dense_vertices.shrink_to_fit();
    pointmap_keyframes.clear();
    pointmap_keyframes.shrink_to_fit();
    next_pointmap_keyframe_id = 1;
    active_pointmap_keyframe_id = 0;
    gsf_seeded_cells.clear();
    gsf_seeded_cells.rehash(0);
    bootstrap_target_points_world.clear();
    bootstrap_target_points_world.shrink_to_fit();
    bootstrap_target_normals_world.clear();
    bootstrap_target_normals_world.shrink_to_fit();
    bootstrap_pose_initialized = false;
    std::memset(bootstrap_pose, 0, sizeof(float) * 16u);
    bootstrap_pose[0] = 1.0f;
    bootstrap_pose[5] = 1.0f;
    bootstrap_pose[10] = 1.0f;
    bootstrap_pose[15] = 1.0f;
    bootstrap_intrinsics_initialized = false;
    std::memset(bootstrap_intrinsics, 0, sizeof(float) * 9u);
    overlay_last_gen_time = std::chrono::steady_clock::time_point{};
    has_keyframe = false;
    has_preview_selected_keyframe = false;
    return summary;
}

}  // namespace local_subject_first_capture_budget
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_BUDGET_H
