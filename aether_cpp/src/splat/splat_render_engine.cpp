// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/splat_render_engine.h"

#include "aether/splat/ply_loader.h"
#include "aether/splat/spz_decoder.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdio>   // fprintf for debug diagnostics
#include <numeric>   // iota
#include <queue>
#include <unordered_map>
#include <vector>

namespace aether {
namespace splat {

namespace {
constexpr std::uint32_t kRadixBuckets = 256;
constexpr std::uint32_t kRadixThreadgroupSize = 256;
constexpr std::size_t kStableCpuSortThreshold = 250000;
constexpr float kStableDepthQuantizationMeters = 0.015f;

struct ViewerOutlierClipResult {
    std::vector<GaussianParams> gaussians;
    bool active{false};
    float q95_radius{0.0f};
    float q99_radius{0.0f};
    float clip_radius{0.0f};
    bool support_active{false};
    std::size_t support_voxels{0};
    std::size_t support_supported_voxels{0};
    std::size_t support_kept{0};
    bool cluster_active{false};
    std::size_t cluster_components{0};
    std::size_t cluster_kept{0};
    std::size_t cluster_second_kept{0};
    float cluster_voxel_size{0.0f};
};

struct ViewerVoxelKey {
    int x;
    int y;
    int z;

    bool operator==(const ViewerVoxelKey& other) const noexcept {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct ViewerVoxelKeyHash {
    std::size_t operator()(const ViewerVoxelKey& key) const noexcept {
        const std::uint64_t hx = static_cast<std::uint64_t>(
            static_cast<std::uint32_t>(key.x * 73856093));
        const std::uint64_t hy = static_cast<std::uint64_t>(
            static_cast<std::uint32_t>(key.y * 19349663));
        const std::uint64_t hz = static_cast<std::uint64_t>(
            static_cast<std::uint32_t>(key.z * 83492791));
        return static_cast<std::size_t>(hx ^ hy ^ hz);
    }
};

ViewerOutlierClipResult maybe_clip_extreme_viewer_outliers(
    const GaussianParams* params,
    std::size_t count) noexcept
{
    ViewerOutlierClipResult result;
    if (!params || count < 2048) {
        return result;
    }

    double cx = 0.0;
    double cy = 0.0;
    double cz = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        cx += params[i].position[0];
        cy += params[i].position[1];
        cz += params[i].position[2];
    }
    const double inv = 1.0 / static_cast<double>(count);
    const float center_x = static_cast<float>(cx * inv);
    const float center_y = static_cast<float>(cy * inv);
    const float center_z = static_cast<float>(cz * inv);

    std::vector<float> dists2(count);
    float max_dist2 = 0.0f;
    for (std::size_t i = 0; i < count; ++i) {
        const float dx = params[i].position[0] - center_x;
        const float dy = params[i].position[1] - center_y;
        const float dz = params[i].position[2] - center_z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        dists2[i] = d2;
        max_dist2 = std::max(max_dist2, d2);
    }

    const auto nth_radius = [&dists2, count](std::size_t num, std::size_t den) -> float {
        const std::size_t idx = std::min(count - 1, (count * num) / den);
        std::nth_element(dists2.begin(),
                         dists2.begin() + static_cast<std::ptrdiff_t>(idx),
                         dists2.end());
        return std::sqrt(std::max(dists2[idx], 0.0f));
    };

    const float q95 = nth_radius(95, 100);
    const float q99 = nth_radius(99, 100);
    const float max_dist = std::sqrt(std::max(max_dist2, 0.0f));
    if (q95 < 1e-4f) {
        return result;
    }

    const bool extreme_outliers =
        q99 > (q95 * 3.0f) ||
        max_dist > (q95 * 8.0f);
    if (!extreme_outliers) {
        return result;
    }

    const float clip_radius = std::max(q95 * 3.0f, 0.75f);
    result.gaussians.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        const float dx = params[i].position[0] - center_x;
        const float dy = params[i].position[1] - center_y;
        const float dz = params[i].position[2] - center_z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 <= clip_radius * clip_radius) {
            result.gaussians.push_back(params[i]);
        }
    }

    if (result.gaussians.size() < count / 4 || result.gaussians.size() >= count) {
        result.gaussians.clear();
        return result;
    }

    result.active = true;
    result.q95_radius = q95;
    result.q99_radius = q99;
    result.clip_radius = clip_radius;

    const GaussianParams* clustered_params = result.gaussians.data();
    std::size_t clustered_count = result.gaussians.size();
    if (!clustered_params || clustered_count < 2048) {
        return result;
    }

    const float voxel_size = std::clamp(q95 * 0.08f, 0.03f, 0.10f);
    if (!(voxel_size > 0.0f)) {
        return result;
    }

    struct VoxelStats {
        std::uint32_t count{0};
        float opacity_sum{0.0f};
        std::uint32_t local_support{0};
        bool supported{false};
        int component{-1};
    };

    std::unordered_map<ViewerVoxelKey, std::size_t, ViewerVoxelKeyHash> voxel_index;
    voxel_index.reserve(clustered_count / 3);
    std::vector<ViewerVoxelKey> voxel_keys;
    voxel_keys.reserve(clustered_count / 3);
    std::vector<VoxelStats> voxels;
    voxels.reserve(clustered_count / 3);
    std::vector<std::size_t> point_to_voxel(clustered_count, 0);

    const auto to_voxel = [center_x, center_y, center_z, voxel_size](const GaussianParams& g) noexcept {
        return ViewerVoxelKey{
            static_cast<int>(std::floor((g.position[0] - center_x) / voxel_size)),
            static_cast<int>(std::floor((g.position[1] - center_y) / voxel_size)),
            static_cast<int>(std::floor((g.position[2] - center_z) / voxel_size)),
        };
    };

    for (std::size_t i = 0; i < clustered_count; ++i) {
        const ViewerVoxelKey key = to_voxel(clustered_params[i]);
        const auto [it, inserted] = voxel_index.emplace(key, voxels.size());
        if (inserted) {
            voxel_keys.push_back(key);
            voxels.push_back(VoxelStats{});
        }
        const std::size_t idx = it->second;
        point_to_voxel[i] = idx;
        voxels[idx].count += 1;
        voxels[idx].opacity_sum += std::clamp(clustered_params[i].opacity, 0.0f, 1.0f);
    }

    auto nth_percentile = [](const std::vector<float>& values,
                             std::size_t num,
                             std::size_t den) noexcept -> float {
        if (values.empty() || den == 0) {
            return 0.0f;
        }
        std::vector<float> copy = values;
        const std::size_t idx =
            std::min(copy.size() - 1, ((copy.size() - 1) * num) / den);
        std::nth_element(copy.begin(), copy.begin() + static_cast<std::ptrdiff_t>(idx), copy.end());
        return copy[idx];
    };

    std::size_t supported_voxels = 0;
    std::vector<float> local_support_values;
    local_support_values.reserve(voxels.size());
    std::vector<float> core_score_values;
    core_score_values.reserve(voxels.size());
    const auto recompute_voxel_support = [&]() noexcept {
        supported_voxels = 0;
        local_support_values.clear();
        core_score_values.clear();
        local_support_values.reserve(voxels.size());
        core_score_values.reserve(voxels.size());
        for (std::size_t i = 0; i < voxels.size(); ++i) {
            const ViewerVoxelKey base = voxel_keys[i];
            std::uint32_t local_support = 0;
            float local_opacity = 0.0f;
            std::uint32_t non_empty_neighbors = 0;
            std::uint32_t face_neighbors = 0;
            for (int dz = -1; dz <= 1; ++dz) {
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        const ViewerVoxelKey neighbor{base.x + dx, base.y + dy, base.z + dz};
                        const auto it = voxel_index.find(neighbor);
                        if (it == voxel_index.end()) {
                            continue;
                        }
                        local_support += voxels[it->second].count;
                        local_opacity += voxels[it->second].opacity_sum;
                        if (!(dx == 0 && dy == 0 && dz == 0)) {
                            non_empty_neighbors += 1;
                            if (std::abs(dx) + std::abs(dy) + std::abs(dz) == 1) {
                                face_neighbors += 1;
                            }
                        }
                    }
                }
            }
            voxels[i].local_support = local_support;
            local_support_values.push_back(static_cast<float>(local_support));
            const float core_score =
                static_cast<float>(local_support) +
                voxels[i].opacity_sum * 8.0f +
                static_cast<float>(voxels[i].count) * 4.0f;
            core_score_values.push_back(core_score);
            const bool supported =
                local_support >= 32 ||
                (local_support >= 22 && local_opacity >= 5.0f && face_neighbors >= 2) ||
                (voxels[i].count >= 6 && face_neighbors >= 3) ||
                (voxels[i].count >= 10 && non_empty_neighbors >= 6);
            voxels[i].supported = supported;
            voxels[i].component = -1;
            if (supported) {
                supported_voxels += 1;
            }
        }
    };
    recompute_voxel_support();

    if (supported_voxels > 0 && supported_voxels < voxels.size()) {
        std::vector<GaussianParams> supported_gaussians;
        supported_gaussians.reserve(clustered_count);
        for (std::size_t i = 0; i < clustered_count; ++i) {
            if (voxels[point_to_voxel[i]].supported) {
                supported_gaussians.push_back(clustered_params[i]);
            }
        }
        if (supported_gaussians.size() >= clustered_count / 6 &&
            supported_gaussians.size() < clustered_count) {
            result.gaussians = std::move(supported_gaussians);
            result.support_active = true;
            result.support_voxels = voxels.size();
            result.support_supported_voxels = supported_voxels;
            result.support_kept = result.gaussians.size();

            clustered_params = result.gaussians.data();
            clustered_count = result.gaussians.size();
            voxel_index.clear();
            voxel_keys.clear();
            voxels.clear();
            point_to_voxel.assign(clustered_count, 0);
            voxel_index.reserve(clustered_count / 3);
            voxel_keys.reserve(clustered_count / 3);
            voxels.reserve(clustered_count / 3);

            for (std::size_t i = 0; i < clustered_count; ++i) {
                const ViewerVoxelKey key = to_voxel(clustered_params[i]);
                const auto [it, inserted] = voxel_index.emplace(key, voxels.size());
                if (inserted) {
                    voxel_keys.push_back(key);
                    voxels.push_back(VoxelStats{});
                }
                const std::size_t idx = it->second;
                point_to_voxel[i] = idx;
                voxels[idx].count += 1;
                voxels[idx].opacity_sum += std::clamp(clustered_params[i].opacity, 0.0f, 1.0f);
            }
            recompute_voxel_support();
        }
    }

    const float support_p75 = nth_percentile(local_support_values, 3, 4);
    const float support_p90 = nth_percentile(local_support_values, 9, 10);
    const float core_score_p80 = nth_percentile(core_score_values, 4, 5);
    const float core_score_p90 = nth_percentile(core_score_values, 9, 10);

    struct ComponentStats {
        std::size_t voxel_count{0};
        std::size_t point_count{0};
        float opacity_sum{0.0f};
    };

    std::vector<std::uint8_t> core_candidate(voxels.size(), 0);
    std::size_t core_candidate_count = 0;
    for (std::size_t i = 0; i < voxels.size(); ++i) {
        const float core_score =
            static_cast<float>(voxels[i].local_support) +
            voxels[i].opacity_sum * 8.0f +
            static_cast<float>(voxels[i].count) * 4.0f;
        const bool candidate =
            voxels[i].supported &&
            core_score >= std::max(core_score_p80, core_score_p90 * 0.92f) &&
            voxels[i].local_support >= std::max(28u, static_cast<std::uint32_t>(std::floor(support_p75))) &&
            (voxels[i].count >= 3 || voxels[i].opacity_sum >= 2.5f);
        core_candidate[i] = candidate ? 1 : 0;
        if (candidate) {
            core_candidate_count += 1;
        }
    }

    if (core_candidate_count < 8) {
        core_candidate_count = 0;
        std::fill(core_candidate.begin(), core_candidate.end(), 0);
        for (std::size_t i = 0; i < voxels.size(); ++i) {
            const float core_score =
                static_cast<float>(voxels[i].local_support) +
                voxels[i].opacity_sum * 8.0f +
                static_cast<float>(voxels[i].count) * 4.0f;
            const bool candidate =
                voxels[i].supported &&
                core_score >= std::max(core_score_p80 * 0.88f, core_score_p90 * 0.78f) &&
                voxels[i].local_support >= std::max(22u, static_cast<std::uint32_t>(std::floor(support_p75 * 0.85f))) &&
                (voxels[i].count >= 2 || voxels[i].opacity_sum >= 1.75f);
            core_candidate[i] = candidate ? 1 : 0;
            if (candidate) {
                core_candidate_count += 1;
            }
        }
    }

    if (core_candidate_count < 4) {
        return result;
    }

    std::vector<ComponentStats> components;
    components.reserve(core_candidate_count);
    std::queue<std::size_t> bfs;

    for (std::size_t seed = 0; seed < voxels.size(); ++seed) {
        if (!core_candidate[seed] || voxels[seed].component >= 0) {
            continue;
        }
        const int component_id = static_cast<int>(components.size());
        components.push_back(ComponentStats{});
        voxels[seed].component = component_id;
        bfs.push(seed);
        while (!bfs.empty()) {
            const std::size_t current = bfs.front();
            bfs.pop();
            ComponentStats& stats = components[static_cast<std::size_t>(component_id)];
            stats.voxel_count += 1;
            stats.point_count += voxels[current].count;
            stats.opacity_sum += voxels[current].opacity_sum;

            const ViewerVoxelKey base = voxel_keys[current];
            for (int dz = -1; dz <= 1; ++dz) {
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (dx == 0 && dy == 0 && dz == 0) {
                            continue;
                        }
                        if (std::abs(dx) + std::abs(dy) + std::abs(dz) != 1) {
                            continue;
                        }
                        const ViewerVoxelKey neighbor{base.x + dx, base.y + dy, base.z + dz};
                        const auto it = voxel_index.find(neighbor);
                        if (it == voxel_index.end()) {
                            continue;
                        }
                        const std::size_t neighbor_idx = it->second;
                        VoxelStats& neighbor_stats = voxels[neighbor_idx];
                        if (!core_candidate[neighbor_idx] || neighbor_stats.component >= 0) {
                            continue;
                        }
                        neighbor_stats.component = component_id;
                        bfs.push(neighbor_idx);
                    }
                }
            }
        }
    }

    auto component_score = [&components](std::size_t idx) noexcept -> double {
        const ComponentStats& c = components[idx];
        return static_cast<double>(c.point_count) * 1.5 +
               static_cast<double>(c.voxel_count) * 16.0 +
               static_cast<double>(c.opacity_sum) * 6.0;
    };

    std::size_t best_component = 0;
    std::size_t second_component = 0;
    for (std::size_t i = 1; i < components.size(); ++i) {
        if (component_score(i) > component_score(best_component)) {
            second_component = best_component;
            best_component = i;
        } else if (second_component == best_component ||
                   component_score(i) > component_score(second_component)) {
            second_component = i;
        }
    }

    const std::size_t best_points = components[best_component].point_count;
    const std::size_t second_points =
        (components.size() > 1) ? components[second_component].point_count : 0;

    float core_center_x = 0.0f;
    float core_center_y = 0.0f;
    float core_center_z = 0.0f;
    float core_center_weight = 0.0f;
    std::vector<float> core_distances;
    core_distances.reserve(components[best_component].voxel_count);
    for (std::size_t i = 0; i < voxels.size(); ++i) {
        if (voxels[i].component != static_cast<int>(best_component)) {
            continue;
        }
        const float vx = center_x + (static_cast<float>(voxel_keys[i].x) + 0.5f) * voxel_size;
        const float vy = center_y + (static_cast<float>(voxel_keys[i].y) + 0.5f) * voxel_size;
        const float vz = center_z + (static_cast<float>(voxel_keys[i].z) + 0.5f) * voxel_size;
        const float weight = std::max(1.0f, voxels[i].opacity_sum + static_cast<float>(voxels[i].count));
        core_center_x += vx * weight;
        core_center_y += vy * weight;
        core_center_z += vz * weight;
        core_center_weight += weight;
    }
    if (core_center_weight == 0) {
        return result;
    }
    core_center_x /= core_center_weight;
    core_center_y /= core_center_weight;
    core_center_z /= core_center_weight;
    for (std::size_t i = 0; i < voxels.size(); ++i) {
        if (voxels[i].component != static_cast<int>(best_component)) {
            continue;
        }
        const float vx = center_x + (static_cast<float>(voxel_keys[i].x) + 0.5f) * voxel_size;
        const float vy = center_y + (static_cast<float>(voxel_keys[i].y) + 0.5f) * voxel_size;
        const float vz = center_z + (static_cast<float>(voxel_keys[i].z) + 0.5f) * voxel_size;
        const float dx = vx - core_center_x;
        const float dy = vy - core_center_y;
        const float dz = vz - core_center_z;
        core_distances.push_back(std::sqrt(dx * dx + dy * dy + dz * dz));
    }
    const float core_dist_p80 = nth_percentile(core_distances, 4, 5);
    const float core_dist_p92 = nth_percentile(core_distances, 23, 25);
    const float core_keep_radius = std::max(voxel_size * 4.5f, std::max(core_dist_p80 * 1.25f, core_dist_p92 * 1.05f));
    const float neighbor_keep_radius = std::max(core_keep_radius * 1.35f, voxel_size * 7.0f);

    std::vector<std::uint8_t> dominant_keep_mask(clustered_count, 0);
    std::vector<std::size_t> dominant_cluster_indices;
    dominant_cluster_indices.reserve(best_points * 2);
    std::vector<GaussianParams> dominant_cluster;
    dominant_cluster.reserve(best_points * 2);
    for (std::size_t i = 0; i < clustered_count; ++i) {
        const std::size_t voxel_idx = point_to_voxel[i];
        const VoxelStats& voxel = voxels[voxel_idx];
        const float vx = center_x + (static_cast<float>(voxel_keys[voxel_idx].x) + 0.5f) * voxel_size;
        const float vy = center_y + (static_cast<float>(voxel_keys[voxel_idx].y) + 0.5f) * voxel_size;
        const float vz = center_z + (static_cast<float>(voxel_keys[voxel_idx].z) + 0.5f) * voxel_size;
        const float dx_center = vx - core_center_x;
        const float dy_center = vy - core_center_y;
        const float dz_center = vz - core_center_z;
        const float voxel_dist_to_core =
            std::sqrt(dx_center * dx_center + dy_center * dy_center + dz_center * dz_center);
        bool keep = voxel.component == static_cast<int>(best_component);
        if (!keep &&
            voxel.supported &&
            voxel.local_support >= std::max(22u, static_cast<std::uint32_t>(std::floor(support_p90 * 0.72f))) &&
            voxel_dist_to_core <= neighbor_keep_radius) {
            const ViewerVoxelKey base = voxel_keys[voxel_idx];
            for (int dz = -1; dz <= 1 && !keep; ++dz) {
                for (int dy = -1; dy <= 1 && !keep; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (dx == 0 && dy == 0 && dz == 0) {
                            continue;
                        }
                        if (std::abs(dx) + std::abs(dy) + std::abs(dz) != 1) {
                            continue;
                        }
                        const ViewerVoxelKey neighbor{base.x + dx, base.y + dy, base.z + dz};
                        const auto it = voxel_index.find(neighbor);
                        if (it == voxel_index.end()) {
                            continue;
                        }
                        if (voxels[it->second].component == static_cast<int>(best_component)) {
                            keep = true;
                            break;
                        }
                    }
                }
            }
        }
        if (keep) {
            dominant_keep_mask[i] = 1;
            dominant_cluster_indices.push_back(i);
            dominant_cluster.push_back(clustered_params[i]);
        }
    }

    if (dominant_cluster.size() < clustered_count / 25 ||
        dominant_cluster.size() >= (clustered_count * 95) / 100) {
        return result;
    }

    std::vector<float> dominant_mean_scales;
    dominant_mean_scales.reserve(dominant_cluster.size());
    std::vector<float> dominant_opacities;
    dominant_opacities.reserve(dominant_cluster.size());
    for (const auto& g : dominant_cluster) {
        dominant_mean_scales.push_back((g.scale[0] + g.scale[1] + g.scale[2]) / 3.0f);
        dominant_opacities.push_back(g.opacity);
    }
    const float dominant_scale_p50 = nth_percentile(dominant_mean_scales, 1, 2);
    const float dominant_scale_p70 = nth_percentile(dominant_mean_scales, 7, 10);
    const float dominant_scale_p85 = nth_percentile(dominant_mean_scales, 17, 20);
    const float dominant_scale_p95 = nth_percentile(dominant_mean_scales, 19, 20);
    const float dominant_opacity_p10 = nth_percentile(dominant_opacities, 1, 10);
    const float dominant_opacity_p25 = nth_percentile(dominant_opacities, 1, 4);
    std::vector<float> dominant_cluster_y;
    dominant_cluster_y.reserve(dominant_cluster.size());
    std::vector<float> dominant_cluster_xz;
    dominant_cluster_xz.reserve(dominant_cluster.size());
    double dominant_footprint_x = 0.0;
    double dominant_footprint_z = 0.0;
    double dominant_footprint_w = 0.0;
    for (const auto& g : dominant_cluster) {
        const double w = std::max(0.15, static_cast<double>(g.opacity) + 0.25);
        dominant_footprint_x += static_cast<double>(g.position[0]) * w;
        dominant_footprint_z += static_cast<double>(g.position[2]) * w;
        dominant_footprint_w += w;
        dominant_cluster_y.push_back(g.position[1]);
    }
    const float dominant_footprint_center_x =
        dominant_footprint_w > 0.0 ? static_cast<float>(dominant_footprint_x / dominant_footprint_w) : 0.0f;
    const float dominant_footprint_center_z =
        dominant_footprint_w > 0.0 ? static_cast<float>(dominant_footprint_z / dominant_footprint_w) : 0.0f;
    for (const auto& g : dominant_cluster) {
        const float dx = g.position[0] - dominant_footprint_center_x;
        const float dz = g.position[2] - dominant_footprint_center_z;
        dominant_cluster_xz.push_back(std::sqrt(dx * dx + dz * dz));
    }
    auto encode_xz = [](int x, int z) noexcept -> std::uint64_t {
        return (static_cast<std::uint64_t>(static_cast<std::uint32_t>(x)) << 32) |
               static_cast<std::uint32_t>(z);
    };
    std::unordered_map<std::uint64_t, std::uint8_t> dominant_footprint_columns;
    dominant_footprint_columns.reserve(components[best_component].voxel_count * 9);
    for (std::size_t i = 0; i < voxels.size(); ++i) {
        if (voxels[i].component != static_cast<int>(best_component)) {
            continue;
        }
        const ViewerVoxelKey base = voxel_keys[i];
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dx = -1; dx <= 1; ++dx) {
                dominant_footprint_columns.emplace(encode_xz(base.x + dx, base.z + dz), 1);
            }
        }
    }
    const float dominant_bottom_p10 = nth_percentile(dominant_cluster_y, 1, 10);
    const float dominant_bottom_p20 = nth_percentile(dominant_cluster_y, 1, 5);
    const float dominant_bottom_p35 = nth_percentile(dominant_cluster_y, 7, 20);
    const float dominant_footprint_p85 = nth_percentile(dominant_cluster_xz, 17, 20);
    const float dominant_footprint_p95 = nth_percentile(dominant_cluster_xz, 19, 20);
    const float preserve_slab_lower =
        dominant_bottom_p10 - std::max(0.14f, voxel_size * 3.5f);
    const float preserve_slab_upper =
        dominant_bottom_p35 + std::max(0.08f, voxel_size * 1.4f);
    const float preserve_slab_radius =
        std::max(std::max(dominant_footprint_p85 * 1.30f, dominant_footprint_p95 * 1.05f),
                 voxel_size * 5.0f);

    const auto append_support_slab = [&](std::vector<GaussianParams>& cluster,
                                         const std::vector<std::uint8_t>* active_keep_mask) -> std::size_t {
        if (cluster.size() < 512) {
            return 0;
        }
        std::vector<float> cluster_y;
        cluster_y.reserve(cluster.size());
        std::vector<float> cluster_xz_dist;
        cluster_xz_dist.reserve(cluster.size());
        double footprint_x = 0.0;
        double footprint_z = 0.0;
        double footprint_w = 0.0;
        for (const auto& g : cluster) {
            const double w = std::max(0.15, static_cast<double>(g.opacity) + 0.25);
            footprint_x += static_cast<double>(g.position[0]) * w;
            footprint_z += static_cast<double>(g.position[2]) * w;
            footprint_w += w;
            cluster_y.push_back(g.position[1]);
        }
        if (footprint_w <= 0.0) {
            return 0;
        }
        const float footprint_center_x = static_cast<float>(footprint_x / footprint_w);
        const float footprint_center_z = static_cast<float>(footprint_z / footprint_w);
        auto encode_xz = [](int x, int z) noexcept -> std::uint64_t {
            return (static_cast<std::uint64_t>(static_cast<std::uint32_t>(x)) << 32) |
                   static_cast<std::uint32_t>(z);
        };
        std::unordered_map<std::uint64_t, std::uint8_t> footprint_columns;
        footprint_columns.reserve(components[best_component].voxel_count * 9);
        for (std::size_t i = 0; i < voxels.size(); ++i) {
            if (voxels[i].component != static_cast<int>(best_component)) {
                continue;
            }
            const ViewerVoxelKey base = voxel_keys[i];
            for (int dz = -1; dz <= 1; ++dz) {
                for (int dx = -1; dx <= 1; ++dx) {
                    footprint_columns.emplace(encode_xz(base.x + dx, base.z + dz), 1);
                }
            }
        }
        for (const auto& g : cluster) {
            const float dx = g.position[0] - footprint_center_x;
            const float dz = g.position[2] - footprint_center_z;
            cluster_xz_dist.push_back(std::sqrt(dx * dx + dz * dz));
        }

        const float bottom_p10 = nth_percentile(cluster_y, 1, 10);
        const float bottom_p20 = nth_percentile(cluster_y, 1, 5);
        const float bottom_p35 = nth_percentile(cluster_y, 7, 20);
        const float footprint_p85 = nth_percentile(cluster_xz_dist, 17, 20);
        const float footprint_p95 = nth_percentile(cluster_xz_dist, 19, 20);
        const float slab_lower = bottom_p10 - std::max(0.18f, voxel_size * 4.5f);
        const float slab_upper = bottom_p35 + std::max(0.10f, voxel_size * 1.8f);
        const float slab_radius = std::max(std::max(footprint_p85 * 1.45f, footprint_p95 * 1.20f),
                                           voxel_size * 6.0f);

        std::vector<GaussianParams> recovered;
        recovered.reserve(cluster.size() / 2);
        const float slab_scale_cap = dominant_scale_p95 * 2.1f;
        const float slab_opacity_floor = std::max(0.008f, dominant_opacity_p10 * 0.60f);
        const std::uint32_t slab_support_floor =
            std::max(12u, static_cast<std::uint32_t>(std::floor(support_p75 * 0.45f)));

        for (std::size_t i = 0; i < clustered_count; ++i) {
            const VoxelStats& voxel = voxels[point_to_voxel[i]];
            if (active_keep_mask && (*active_keep_mask)[i]) {
                continue;
            }
            if (!voxel.supported || voxel.local_support < slab_support_floor) {
                continue;
            }
            const GaussianParams& g = clustered_params[i];
            if (g.position[1] < slab_lower || g.position[1] > slab_upper) {
                continue;
            }
            const float dx = g.position[0] - footprint_center_x;
            const float dz = g.position[2] - footprint_center_z;
            const ViewerVoxelKey base = voxel_keys[point_to_voxel[i]];
            const bool under_core_columns =
                footprint_columns.find(encode_xz(base.x, base.z)) != footprint_columns.end();
            if (!under_core_columns &&
                std::sqrt(dx * dx + dz * dz) > slab_radius) {
                continue;
            }
            const float sx = std::max(g.scale[0], 1e-6f);
            const float sy = std::max(g.scale[1], 1e-6f);
            const float sz = std::max(g.scale[2], 1e-6f);
            const float mean_scale = (sx + sy + sz) / 3.0f;
            if (mean_scale > slab_scale_cap || g.opacity < slab_opacity_floor) {
                continue;
            }
            recovered.push_back(g);
        }

        if (!recovered.empty()) {
            cluster.insert(cluster.end(), recovered.begin(), recovered.end());
        }
        std::fprintf(stderr,
                     "[Aether3D][ViewerGround] recovered=%zu y10=%.3f y20=%.3f y35=%.3f slab=[%.3f,%.3f] radius=%.3f columns=%zu\n",
                     recovered.size(),
                     bottom_p10,
                     bottom_p20,
                     bottom_p35,
                     slab_lower,
                     slab_upper,
                     slab_radius,
                     footprint_columns.size());
        return recovered.size();
    };

    std::vector<GaussianParams> refined_cluster;
    refined_cluster.reserve(dominant_cluster.size());
    std::vector<std::uint8_t> refined_keep_mask(clustered_count, 0);
    std::size_t splat_cleanup_removed = 0;
    std::size_t bottom_support_preserved = 0;
    for (std::size_t dominant_idx = 0; dominant_idx < dominant_cluster.size(); ++dominant_idx) {
        const auto& g = dominant_cluster[dominant_idx];
        const std::size_t source_idx = dominant_cluster_indices[dominant_idx];
        const VoxelStats& voxel = voxels[point_to_voxel[source_idx]];
        const ViewerVoxelKey base = voxel_keys[point_to_voxel[source_idx]];
        const float sx = std::max(g.scale[0], 1e-6f);
        const float sy = std::max(g.scale[1], 1e-6f);
        const float sz = std::max(g.scale[2], 1e-6f);
        const float mean_scale = (sx + sy + sz) / 3.0f;
        const float max_scale = std::max(sx, std::max(sy, sz));
        const float min_scale = std::min(sx, std::min(sy, sz));
        const float anisotropy = max_scale / std::max(min_scale, 1e-6f);
        const float dx_fp = g.position[0] - dominant_footprint_center_x;
        const float dz_fp = g.position[2] - dominant_footprint_center_z;
        const bool under_core_columns =
            dominant_footprint_columns.find(encode_xz(base.x, base.z)) != dominant_footprint_columns.end();
        const bool near_core_footprint =
            std::sqrt(dx_fp * dx_fp + dz_fp * dz_fp) <= preserve_slab_radius;
        const bool in_bottom_slab =
            g.position[1] >= preserve_slab_lower &&
            g.position[1] <= preserve_slab_upper;
        const bool bottom_support_candidate =
            in_bottom_slab &&
            voxel.supported &&
            voxel.local_support >= std::max(12u, static_cast<std::uint32_t>(std::floor(support_p75 * 0.42f))) &&
            (under_core_columns || near_core_footprint) &&
            mean_scale <= dominant_scale_p95 * 2.4f &&
            anisotropy <= 4.8f &&
            g.opacity >= std::max(0.006f, dominant_opacity_p10 * 0.55f);
        const bool huge_and_weak =
            mean_scale > dominant_scale_p95 * 1.00f &&
            g.opacity < 0.90f;
        const bool big_and_soft =
            mean_scale > dominant_scale_p85 * 1.08f &&
            g.opacity < 0.76f;
        const bool medium_big_and_soft =
            mean_scale > dominant_scale_p70 * 1.12f &&
            g.opacity < 0.62f;
        const bool elongated_and_weak =
            anisotropy > 3.2f &&
            mean_scale > dominant_scale_p50 * 0.98f &&
            g.opacity < 0.92f;
        const bool very_large_sheet =
            mean_scale > dominant_scale_p50 * 1.35f &&
            anisotropy > 1.9f &&
            g.opacity < 0.98f;
        const bool giant_cap =
            max_scale > dominant_scale_p95 * 1.20f &&
            g.opacity < 0.99f;
        const bool low_alpha_blob =
            mean_scale > dominant_scale_p50 * 1.05f &&
            g.opacity < 0.48f;
        const bool low_alpha_noise =
            g.opacity < std::max(0.015f, dominant_opacity_p10 * 0.65f);
        const bool low_alpha_medium =
            g.opacity < std::max(0.045f, dominant_opacity_p25 * 0.80f) &&
            mean_scale > dominant_scale_p50 * 0.95f;
        const bool anisotropic_medium =
            anisotropy > 2.6f &&
            mean_scale > dominant_scale_p70 * 0.95f &&
            g.opacity < 0.96f;
        const bool should_cull =
            huge_and_weak || big_and_soft || medium_big_and_soft ||
            elongated_and_weak || very_large_sheet || giant_cap || low_alpha_blob ||
            low_alpha_noise || low_alpha_medium || anisotropic_medium;
        const bool preserve_bottom_support =
            bottom_support_candidate &&
            !(giant_cap && g.opacity < 0.15f) &&
            !(very_large_sheet && g.opacity < 0.12f);
        if (should_cull && !preserve_bottom_support) {
            splat_cleanup_removed += 1;
            continue;
        }
        if (preserve_bottom_support) {
            bottom_support_preserved += 1;
        }
        refined_cluster.push_back(g);
        refined_keep_mask[source_idx] = 1;
    }

    if (refined_cluster.size() >= dominant_cluster.size() / 3 &&
        refined_cluster.size() < dominant_cluster.size()) {
        append_support_slab(refined_cluster, &refined_keep_mask);
        result.gaussians = std::move(refined_cluster);
        result.cluster_active = true;
        result.cluster_components = components.size();
        result.cluster_kept = result.gaussians.size();
        result.cluster_second_kept = second_points;
        result.cluster_voxel_size = voxel_size;
        std::fprintf(stderr,
                     "[Aether3D][ViewerSplatCull] kept=%zu removed=%zu preservedBottom=%zu scale50=%.4f scale70=%.4f scale85=%.4f scale95=%.4f op10=%.4f op25=%.4f slab=[%.3f,%.3f] radius=%.3f\n",
                     result.gaussians.size(),
                     splat_cleanup_removed,
                     bottom_support_preserved,
                     dominant_scale_p50,
                     dominant_scale_p70,
                     dominant_scale_p85,
                     dominant_scale_p95,
                     dominant_opacity_p10,
                     dominant_opacity_p25,
                     preserve_slab_lower,
                     preserve_slab_upper,
                     preserve_slab_radius);
        return result;
    }

    append_support_slab(dominant_cluster, &dominant_keep_mask);
    result.gaussians = std::move(dominant_cluster);
    result.cluster_active = true;
    result.cluster_components = components.size();
    result.cluster_kept = result.gaussians.size();
    result.cluster_second_kept = second_points;
    result.cluster_voxel_size = voxel_size;
    return result;
}

std::uint32_t radix_group_count(std::size_t splat_count) noexcept {
    return static_cast<std::uint32_t>(
        (splat_count + kRadixThreadgroupSize - 1) / kRadixThreadgroupSize);
}
}

SplatRenderEngine::SplatRenderEngine(render::GPUDevice& device,
                                     const SplatRenderConfig& config) noexcept
    : device_(device)
    , config_(config)
    , cpu_buffer_(config.max_splats)
    , staging_buffer_(4096) {
    // D3: Default regions to fully visible (1.0).
    // Initial capacity: 64 regions (grows dynamically as needed).
    region_fade_alphas_.resize(64, 1.0f);
    region_fade_gpu_capacity_ = 64;
    create_gpu_resources();
}

SplatRenderEngine::~SplatRenderEngine() noexcept {
    destroy_gpu_resources();
}

core::Status SplatRenderEngine::load_from_ply(const char* path) noexcept {
    PlyLoadResult ply_result;
    auto status = load_ply(path, ply_result);
    if (!core::is_ok(status)) return status;

    return load_gaussians(ply_result.gaussians.data(),
                          ply_result.gaussians.size());
}

core::Status SplatRenderEngine::load_from_spz(const std::uint8_t* data,
                                               std::size_t size) noexcept {
    SpzDecodeResult spz_result;
    auto status = decode_spz(data, size, spz_result);
    if (!core::is_ok(status)) return status;

    return load_gaussians(spz_result.gaussians.data(),
                          spz_result.gaussians.size());
}

core::Status SplatRenderEngine::load_gaussians(const GaussianParams* params,
                                                std::size_t count) noexcept {
    if (!params || count == 0) return core::Status::kInvalidArgument;
    if (count > config_.max_splats) count = config_.max_splats;

    const GaussianParams* upload_params = params;
    std::size_t upload_count = count;

    cpu_buffer_.clear();
    cpu_buffer_.push_batch(upload_params, upload_count);
    splat_count_ = upload_count;

    // Extract SH coefficients into GPU-ready layout: 12 floats per splat
    // GPU layout: [R_b0, R_b1, R_b2, pad, G_b0, G_b1, G_b2, pad, B_b0, B_b1, B_b2, pad]
    // Source sh1[] layout (PLY per-channel): [R_b0, R_b1, R_b2, G_b0, G_b1, G_b2, B_b0, B_b1, B_b2]
    //   where f_rest_0..2 = R channel, f_rest_3..5 = G channel, f_rest_6..8 = B channel
    cpu_sh_data_.resize(upload_count * 12);
    for (std::size_t i = 0; i < upload_count; ++i) {
        float* dst = &cpu_sh_data_[i * 12];
        const float* sh = upload_params[i].sh1;
        // R channel: sh[0..2] = R_b0, R_b1, R_b2
        dst[0] = sh[0]; dst[1] = sh[1]; dst[2] = sh[2]; dst[3] = 0.0f;
        // G channel: sh[3..5] = G_b0, G_b1, G_b2
        dst[4] = sh[3]; dst[5] = sh[4]; dst[6] = sh[5]; dst[7] = 0.0f;
        // B channel: sh[6..8] = B_b0, B_b1, B_b2
        dst[8] = sh[6]; dst[9] = sh[7]; dst[10] = sh[8]; dst[11] = 0.0f;
    }

    upload_splats_to_gpu();

    // Mark initialized once the legacy single-pass pipeline is available.
    initialized_ = render_pipeline_.valid();
    if (!initialized_) {
        std::fprintf(stderr, "[Aether3D][SplatEngine] WARNING: data loaded (%zu splats) "
                     "but no viewer pipeline is available — shader load failed\n",
                     splat_count_);
    }

    return core::Status::kOk;
}

// Internal helper: push splats WITHOUT locking staging_mutex_.
// Caller MUST hold staging_mutex_ before calling.
void SplatRenderEngine::push_splats_locked(const GaussianParams* params,
                                            std::size_t count) noexcept {
    // Append to staging buffer
    staging_buffer_.push_batch(params, count);

    // Also extract SH coefficients into staging (GPU-ready layout)
    // sh1[] is per-channel: [R_b0,R_b1,R_b2, G_b0,G_b1,G_b2, B_b0,B_b1,B_b2]
    std::size_t base = staging_sh_data_.size();
    staging_sh_data_.resize(base + count * 12);
    for (std::size_t i = 0; i < count; ++i) {
        float* dst = &staging_sh_data_[base + i * 12];
        const float* sh = params[i].sh1;
        dst[0] = sh[0]; dst[1] = sh[1]; dst[2] = sh[2]; dst[3] = 0.0f;
        dst[4] = sh[3]; dst[5] = sh[4]; dst[6] = sh[5]; dst[7] = 0.0f;
        dst[8] = sh[6]; dst[9] = sh[7]; dst[10] = sh[8]; dst[11] = 0.0f;
    }

    staging_dirty_ = true;
}

void SplatRenderEngine::push_splats(const GaussianParams* params,
                                     std::size_t count) noexcept {
    if (!params || count == 0) return;

    // CRITICAL FIX: Lock staging_mutex_ to prevent data race with begin_frame().
    // Training thread writes staging_buffer_ via push_splats(), while
    // rendering thread reads/clears it in begin_frame(). Without this lock,
    // concurrent access corrupts PackedSplatsBuffer::data_ → SIGABRT on delete[].
    // try-catch: defense against mutex destroyed during shutdown (EINVAL).
    try {
        std::lock_guard<std::mutex> lock(staging_mutex_);
        push_splats_locked(params, count);
    } catch (const std::system_error&) { return; }
}

void SplatRenderEngine::push_splats_with_regions(
    const GaussianParams* params,
    const std::uint8_t* region_ids,
    std::size_t count) noexcept
{
    if (!params || count == 0) return;

    // Single lock for entire operation: splats + region IDs.
    // try-catch: defense against mutex destroyed during shutdown (EINVAL).
    try {
        std::lock_guard<std::mutex> lock(staging_mutex_);
        push_splats_locked(params, count);

        // Also stage region IDs (parallel to staging_buffer_)
        if (region_ids) {
            std::size_t base = staging_region_ids_.size();
            staging_region_ids_.resize(base + count);
            std::memcpy(&staging_region_ids_[base], region_ids, count);
        } else {
            staging_region_ids_.resize(staging_region_ids_.size() + count, 0);
        }
    } catch (const std::system_error&) { return; }
}

void SplatRenderEngine::set_region_fade_alphas(
    const float* fade_alphas,
    std::size_t count) noexcept
{
    if (!fade_alphas || count == 0) return;
    active_region_count_ = count;

    // Grow vector if needed (dynamic, no upper limit)
    if (count > region_fade_alphas_.size()) {
        std::size_t old_size = region_fade_alphas_.size();
        region_fade_alphas_.resize(count, 1.0f);
    }
    for (std::size_t i = 0; i < count; ++i) {
        region_fade_alphas_[i] = fade_alphas[i];
    }
}

void SplatRenderEngine::push_splats_with_regions_u16(
    const GaussianParams* params,
    const std::uint16_t* region_ids,
    std::size_t count) noexcept
{
    if (!params || count == 0) return;

    // Single lock for entire operation: splats + region IDs.
    // try-catch: defense against mutex destroyed during shutdown (EINVAL).
    try {
        std::lock_guard<std::mutex> lock(staging_mutex_);
        push_splats_locked(params, count);

        if (region_ids) {
            std::size_t base = staging_region_ids_.size();
            staging_region_ids_.resize(base + count);
            for (std::size_t i = 0; i < count; ++i) {
                staging_region_ids_[base + i] = static_cast<std::uint8_t>(
                    std::min(static_cast<unsigned>(region_ids[i]), 255u));
            }
        } else {
            staging_region_ids_.resize(staging_region_ids_.size() + count, 0);
        }
    } catch (const std::system_error&) { return; }
}

void SplatRenderEngine::clear_splats() noexcept {
    // Thread-safe: only clear the staging buffer (written by training thread).
    // Set pending_clear_ flag so begin_frame() (main thread) clears cpu_buffer_.
    // try-catch: defense against mutex destroyed during shutdown (EINVAL).
    try {
        std::lock_guard<std::mutex> lock(staging_mutex_);
        staging_buffer_.clear();
        staging_sh_data_.clear();
        staging_region_ids_.clear();
        pending_clear_ = true;
        staging_dirty_ = true;
    } catch (const std::system_error&) { return; }
}

void SplatRenderEngine::begin_frame() noexcept {
    // CRITICAL FIX: Lock staging_mutex_ while accessing staging buffers.
    // Training thread writes via push_splats() concurrently.
    // Scope lock to staging access only — don't hold during GPU upload.
    // try-catch: defense against mutex destroyed during shutdown (EINVAL).
    bool need_upload = false;
    try {
        std::lock_guard<std::mutex> lock(staging_mutex_);
        if (staging_dirty_) {
            // Handle pending clear first (set by training thread via clear_splats())
            if (pending_clear_) {
                cpu_buffer_.clear();
                cpu_sh_data_.clear();
                cpu_region_ids_.clear();
                splat_count_ = 0;
                initialized_ = false;
                pending_clear_ = false;
            }

            // Merge staging into main buffer
            const PackedSplat* staging_data = staging_buffer_.data();
            std::size_t staging_count = staging_buffer_.size();

            for (std::size_t i = 0; i < staging_count; ++i) {
                if (cpu_buffer_.size() < config_.max_splats) {
                    cpu_buffer_.push(staging_data[i]);
                }
            }

            // Merge staging SH data into main SH buffer
            // Bug 0.8 fix: guard against unsigned underflow when splat_count_ > max_splats.
            std::size_t available_slots = (splat_count_ < config_.max_splats)
                ? (config_.max_splats - splat_count_) : 0;
            std::size_t sh_entries_to_merge = std::min(
                staging_sh_data_.size() / 12,
                available_slots);
            if (sh_entries_to_merge > 0) {
                std::size_t old_count = cpu_sh_data_.size() / 12;
                cpu_sh_data_.resize((old_count + sh_entries_to_merge) * 12);
                std::memcpy(&cpu_sh_data_[old_count * 12],
                            staging_sh_data_.data(),
                            sh_entries_to_merge * 12 * sizeof(float));
            }

            // D3: Merge staging region IDs into main region ID buffer
            std::size_t region_entries_to_merge = std::min(
                staging_region_ids_.size(), available_slots);
            if (region_entries_to_merge > 0) {
                std::size_t old_region_count = cpu_region_ids_.size();
                cpu_region_ids_.resize(old_region_count + region_entries_to_merge);
                std::memcpy(&cpu_region_ids_[old_region_count],
                            staging_region_ids_.data(),
                            region_entries_to_merge);
            }
            // Pad with region 0 if splats were added without region IDs
            while (cpu_region_ids_.size() < cpu_buffer_.size()) {
                cpu_region_ids_.push_back(0);
            }

            splat_count_ = cpu_buffer_.size();
            staging_buffer_.clear();
            staging_sh_data_.clear();
            staging_region_ids_.clear();
            staging_dirty_ = false;
            need_upload = true;
        }
    } catch (const std::system_error&) { return; }
    // staging_mutex_ released before GPU upload (no need to hold during GPU work)

    if (need_upload) {
        upload_splats_to_gpu();
    }

    stats_ = SplatRenderStats{};
    stats_.total_splats = splat_count_;
}

// Column-major 4×4 matrix multiply: out = a * b
static void mat4_multiply(const float* a, const float* b, float* out) noexcept {
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) {
                sum += a[k * 4 + r] * b[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
}

void SplatRenderEngine::update_camera(const SplatCameraState& camera) noexcept {
    camera_ = camera;

    // Compute viewProjMatrix = proj * view (column-major)
    mat4_multiply(camera_.proj, camera_.view, camera_.view_proj);

    // Fill engine-known fields
    render_splat_count_ = splat_count_;
    if (camera_.render_splat_limit > 0) {
        render_splat_count_ = std::min<std::size_t>(render_splat_count_, camera_.render_splat_limit);
    }
    camera_.splat_count = static_cast<std::uint32_t>(render_splat_count_);
    camera_.render_splat_limit = static_cast<std::uint32_t>(render_splat_count_);

    // ─── Diagnostic: print camera + first splat info (first 5 calls only) ───
    static int diag_count = 0;
    if (diag_count < 5 && render_splat_count_ > 0) {
        diag_count++;
        // Camera info
        std::fprintf(stderr, "[Aether3D][DIAG] camera: fx=%.1f fy=%.1f cx=%.1f cy=%.1f "
                     "vp=%ux%u splats=%zu render=%zu\n",
                     camera_.fx, camera_.fy, camera_.cx, camera_.cy,
                     camera_.vp_width, camera_.vp_height, splat_count_, render_splat_count_);

        // View matrix rows (column-major: V[col*4+row])
        const float* V = camera_.view;
        std::fprintf(stderr, "[Aether3D][DIAG] view row2: [%.4f %.4f %.4f %.4f] (z-axis)\n",
                     V[0*4+2], V[1*4+2], V[2*4+2], V[3*4+2]);

        // First splat info
        const PackedSplat& s0 = cpu_buffer_.data()[0];
        float px = half_to_float(s0.center[0]);
        float py = half_to_float(s0.center[1]);
        float pz = half_to_float(s0.center[2]);
        std::fprintf(stderr, "[Aether3D][DIAG] splat[0]: pos=(%.4f, %.4f, %.4f) "
                     "scale_bytes=(%u, %u, %u) rgba=(%u,%u,%u,%u)\n",
                     px, py, pz,
                     s0.log_scale[0], s0.log_scale[1], s0.log_scale[2],
                     s0.rgba[0], s0.rgba[1], s0.rgba[2], s0.rgba[3]);

        // Compute view-space position of first splat
        float vx = V[0*4+0]*px + V[1*4+0]*py + V[2*4+0]*pz + V[3*4+0];
        float vy = V[0*4+1]*px + V[1*4+1]*py + V[2*4+1]*pz + V[3*4+1];
        float vz = V[0*4+2]*px + V[1*4+2]*py + V[2*4+2]*pz + V[3*4+2];
        float depth = -vz;
        std::fprintf(stderr, "[Aether3D][DIAG] splat[0] viewPos=(%.4f, %.4f, %.4f) depth=%.4f\n",
                     vx, vy, vz, depth);

        // Compute expected screen radius
        float scale_val = std::exp(float(s0.log_scale[0]) / 255.0f * 16.0f - 8.0f);
        if (depth > 0.01f) {
            float sigma2d = scale_val * camera_.fx / depth;
            std::fprintf(stderr, "[Aether3D][DIAG] splat[0] decoded_scale=%.6f "
                         "sigma2d=%.2f px, 3sigma=%.2f px\n",
                         scale_val, sigma2d, sigma2d * 3.0f);
        }

        // Print bounding info for all splats (min/max positions)
        float min_x = 1e30f, max_x = -1e30f;
        float min_y = 1e30f, max_y = -1e30f;
        float min_z = 1e30f, max_z = -1e30f;
        for (std::size_t i = 0; i < splat_count_; ++i) {
            float x = half_to_float(cpu_buffer_.data()[i].center[0]);
            float y = half_to_float(cpu_buffer_.data()[i].center[1]);
            float z = half_to_float(cpu_buffer_.data()[i].center[2]);
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
            if (z < min_z) min_z = z;
            if (z > max_z) max_z = z;
        }
        std::fprintf(stderr, "[Aether3D][DIAG] point cloud bounds: "
                     "x=[%.3f, %.3f] y=[%.3f, %.3f] z=[%.3f, %.3f]\n",
                     min_x, max_x, min_y, max_y, min_z, max_z);
        float span = std::sqrt((max_x-min_x)*(max_x-min_x) +
                                (max_y-min_y)*(max_y-min_y) +
                                (max_z-min_z)*(max_z-min_z));
        std::fprintf(stderr, "[Aether3D][DIAG] span=%.3f, depth=%.3f, "
                     "depth/span=%.1f (large = far camera)\n",
                     span, depth, depth / (span > 0 ? span : 1e-6f));
    }

    // Upload camera uniform to GPU (full 224 bytes matching SplatCameraUniforms)
    if (camera_buffer_.valid()) {
        device_.update_buffer(camera_buffer_, &camera_,
                              0, sizeof(SplatCameraState));
    }

    stats_.sort_time_ms = 0.0f;
    stats_.sort_mode = 0;
    bool gpu_sort_ready = depth_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();
    cpu_stable_sort_active_ = false;
    if (render_splat_count_ > 0 &&
        index_buffer_.valid() &&
        (should_prefer_cpu_stable_sort() || !gpu_sort_ready)) {
        cpu_stable_sort_active_ = true;
        stats_.sort_mode = 1;
        cpu_depth_sort();
    } else if (render_splat_count_ > 0 && gpu_sort_ready) {
        stats_.sort_mode = 2;
    }
}

bool SplatRenderEngine::should_prefer_cpu_stable_sort() const noexcept {
    // StopThePop-style pragmatic stabilization:
    // prefer deterministic CPU sorting for small/medium scenes where the
    // sort cost is acceptable, because it dramatically reduces frame-to-frame
    // ordering jitter compared with generic radix-sort tie behavior. We bias
    // further toward stable sorting here so medium-large scenes still prefer
    // coherence over raw sort throughput.
    return render_splat_count_ > 0 && render_splat_count_ <= kStableCpuSortThreshold;
}

void SplatRenderEngine::cpu_depth_sort() noexcept {
    const auto sort_start = std::chrono::steady_clock::now();
    const std::size_t n = render_splat_count_;
    const PackedSplat* splats = cpu_buffer_.data();

    // Resize buffers if needed
    if (cpu_sort_indices_.size() < n) {
        cpu_sort_indices_.resize(n);
        cpu_sort_depths_.resize(n);
    }

    // Extract view matrix row 2 (column-major: view[c*4+r])
    // viewPos.z = view[0*4+2]*px + view[1*4+2]*py + view[2*4+2]*pz + view[3*4+2]
    const float* V = camera_.view;
    float v02 = V[0 * 4 + 2];  // row=2, col=0
    float v12 = V[1 * 4 + 2];  // row=2, col=1
    float v22 = V[2 * 4 + 2];  // row=2, col=2
    float v32 = V[3 * 4 + 2];  // row=2, col=3 (translation)

    // Compute depth for each splat
    for (std::size_t i = 0; i < n; ++i) {
        float px = half_to_float(splats[i].center[0]);
        float py = half_to_float(splats[i].center[1]);
        float pz = half_to_float(splats[i].center[2]);
        // viewPos.z = dot(view_row2, [px, py, pz, 1])
        // In our lookAt convention, viewPos.z < 0 for objects in front.
        // More negative = farther from camera. With premultiplied src-over
        // blending we want back-to-front ordering: farthest first.
        cpu_sort_depths_[i] = v02 * px + v12 * py + v22 * pz + v32;
        cpu_sort_indices_[i] = static_cast<std::uint32_t>(i);
    }

    // Use a stable, deterministic ordering so tiny camera motions do not
    // reshuffle equal-depth splats frame-to-frame. Once splats fall into the
    // same quantized depth bucket, preserve their original artifact order
    // instead of reordering by tiny per-frame center-depth differences.
    std::stable_sort(cpu_sort_indices_.begin(),
                     cpu_sort_indices_.begin() + static_cast<std::ptrdiff_t>(n),
                     [this](std::uint32_t a, std::uint32_t b) {
                         float da = cpu_sort_depths_[a];
                         float db = cpu_sort_depths_[b];
                         const int qa = static_cast<int>(std::llround(
                             da / kStableDepthQuantizationMeters));
                         const int qb = static_cast<int>(std::llround(
                             db / kStableDepthQuantizationMeters));
                         if (qa != qb) return qa < qb;
                         return a < b;
                     });

    // Upload sorted indices to GPU
    device_.update_buffer(index_buffer_, cpu_sort_indices_.data(),
                          0, n * sizeof(std::uint32_t));
    const auto sort_end = std::chrono::steady_clock::now();
    stats_.sort_time_ms = std::chrono::duration<float, std::milli>(sort_end - sort_start).count();
}

void SplatRenderEngine::encode_sort_pass(render::GPUCommandBuffer& cmd) noexcept {
    if (render_splat_count_ == 0) return;
    if (cpu_stable_sort_active_) return;

    const std::uint32_t thread_count = static_cast<std::uint32_t>(render_splat_count_);
    const std::uint32_t group_count = radix_group_count(render_splat_count_);
    constexpr std::uint32_t threadgroup_size = kRadixThreadgroupSize;

    // Step 1: Compute depths from camera
    // Step 2: Stable GPU radix sort by depth.
    // We build per-threadgroup histograms, prefix them into absolute bucket
    // offsets, then scatter with a deterministic in-group rank.
    bool gpu_sort_ready = depth_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();

    if (!gpu_sort_ready) {
        return;
    }

    {
        auto* encoder = cmd.make_compute_encoder();
        if (!encoder) return;

        encoder->set_pipeline(depth_pipeline_);
        encoder->set_buffer(splat_buffer_, 0, 0);     // buffer(0): PackedSplat[]
        encoder->set_buffer(camera_buffer_, 0, 1);    // buffer(1): Camera uniform
        encoder->set_buffer(depth_buffer_, 0, 2);     // buffer(2): uint[] sortable depth keys
        encoder->set_buffer(index_buffer_, 0, 3);     // buffer(3): uint[] indices
        encoder->dispatch_1d(thread_count, threadgroup_size);
        encoder->end_encoding();
    }

    const std::uint32_t passes = 4;

    for (std::uint32_t pass = 0; pass < passes; ++pass) {
        auto& src_buf = (pass % 2 == 0) ? index_buffer_ : sort_temp_indices_;
        auto& dst_buf = (pass % 2 == 0) ? sort_temp_indices_ : index_buffer_;

        std::uint32_t sort_params[4] = {
            pass, thread_count, pass * 8u, group_count
        };

        {
            auto* enc = cmd.make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(histogram_pipeline_);
            enc->set_buffer(depth_buffer_, 0, 0);      // sortable depth keys[]
            enc->set_buffer(src_buf, 0, 1);
            enc->set_bytes(sort_params, sizeof(sort_params), 2);
            enc->set_buffer(sort_histogram_, 0, 3);
            enc->dispatch(group_count, 1, 1, threadgroup_size, 1, 1);
            enc->end_encoding();
        }

        {
            auto* enc = cmd.make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(prefix_sum_pipeline_);
            enc->set_buffer(sort_histogram_, 0, 0);
            enc->set_bytes(sort_params, sizeof(sort_params), 1);
            enc->dispatch_1d(kRadixBuckets, kRadixBuckets);
            enc->end_encoding();
        }

        {
            auto* enc = cmd.make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(scatter_pipeline_);
            enc->set_buffer(depth_buffer_, 0, 0);      // sortable depth keys[]
            enc->set_buffer(src_buf, 0, 1);
            enc->set_buffer(dst_buf, 0, 2);
            enc->set_bytes(sort_params, sizeof(sort_params), 3);
            enc->set_buffer(sort_histogram_, 0, 4);
            enc->dispatch(group_count, 1, 1, threadgroup_size, 1, 1);
            enc->end_encoding();
        }
    }

}

void SplatRenderEngine::encode_render_pass(
    render::GPUCommandBuffer& cmd,
    const render::GPURenderTargetDesc& target) noexcept
{
    if (render_splat_count_ == 0 || !render_pipeline_.valid()) return;

    auto* encoder = cmd.make_render_encoder(target);
    if (!encoder) return;

    encoder->set_pipeline(render_pipeline_);

    // Metal shader splatVertex expects:
    //   buffer(0) = PackedSplatGPU[]       (splat data)
    //   buffer(1) = uint[]                 (sorted indices)
    //   buffer(2) = SplatCameraUniforms    (camera)
    //   buffer(3) = float4[]              (SH degree-1 coefficients, 3 per splat)
    //   buffer(4) = uint8[]               (D3: per-splat region IDs)
    //   buffer(5) = float[]               (D3: per-region fade alphas)
    // Vertex ID (vid) and Instance ID (iid) come from Metal automatically.
    encoder->set_vertex_buffer(splat_buffer_, 0, 0);     // buffer(0): PackedSplat[]
    encoder->set_vertex_buffer(index_buffer_, 0, 1);     // buffer(1): sorted indices
    encoder->set_vertex_buffer(camera_buffer_, 0, 2);    // buffer(2): camera uniform
    if (sh_buffer_.valid()) {
        encoder->set_vertex_buffer(sh_buffer_, 0, 3);    // buffer(3): SH coefficients
    }
    // D3: Region fade buffers for "破镜重圆" progressive reveal
    if (region_id_buffer_.valid()) {
        encoder->set_vertex_buffer(region_id_buffer_, 0, 4);   // buffer(4): region IDs
    }
    if (region_fade_buffer_.valid()) {
        encoder->set_vertex_buffer(region_fade_buffer_, 0, 5); // buffer(5): fade alphas
    }

    // Draw instanced quads: 4 vertices per quad (triangle strip), splat_count instances
    encoder->draw_instanced(render::GPUPrimitiveType::kTriangleStrip,
                            4, static_cast<std::uint32_t>(render_splat_count_));
    encoder->end_encoding();

    stats_.visible_splats = render_splat_count_;  // TODO: actual frustum cull count
}

void SplatRenderEngine::encode_render_pass_native(
    render::GPUCommandBuffer& cmd,
    void* native_rpd) noexcept
{
    if (render_splat_count_ == 0 || !native_rpd) return;

    if (!render_pipeline_.valid()) return;

    auto* encoder = cmd.make_render_encoder_native(native_rpd);
    if (!encoder) return;

    encoder->set_pipeline(render_pipeline_);

    // Metal shader splatVertex expects:
    //   buffer(0) = PackedSplatGPU[]       (splat data)
    //   buffer(1) = uint[]                 (sorted indices)
    //   buffer(2) = SplatCameraUniforms    (camera)
    //   buffer(3) = float4[]              (SH degree-1 coefficients, 3 per splat)
    //   buffer(4) = uint8[]               (D3: per-splat region IDs)
    //   buffer(5) = float[]               (D3: per-region fade alphas)
    encoder->set_vertex_buffer(splat_buffer_, 0, 0);
    encoder->set_vertex_buffer(index_buffer_, 0, 1);
    encoder->set_vertex_buffer(camera_buffer_, 0, 2);
    if (sh_buffer_.valid()) {
        encoder->set_vertex_buffer(sh_buffer_, 0, 3);    // buffer(3): SH coefficients
    }
    // D3: Region fade buffers for "破镜重圆" progressive reveal
    if (region_id_buffer_.valid()) {
        encoder->set_vertex_buffer(region_id_buffer_, 0, 4);   // buffer(4): region IDs
    }
    if (region_fade_buffer_.valid()) {
        encoder->set_vertex_buffer(region_fade_buffer_, 0, 5); // buffer(5): fade alphas
    }

    // Draw instanced quads: 4 vertices per quad (triangle strip), splat_count instances
    encoder->draw_instanced(render::GPUPrimitiveType::kTriangleStrip,
                            4, static_cast<std::uint32_t>(render_splat_count_));
    encoder->end_encoding();

    stats_.visible_splats = render_splat_count_;
}

SplatRenderStats SplatRenderEngine::end_frame() noexcept {
    return stats_;
}

bool SplatRenderEngine::get_bounds(float center[3], float* radius) const noexcept {
    if (cpu_buffer_.empty() || splat_count_ == 0) return false;

    const PackedSplat* data = cpu_buffer_.data();
    std::size_t count = cpu_buffer_.size();

    // Pass 1: compute centroid
    double cx = 0, cy = 0, cz = 0;
    for (std::size_t i = 0; i < count; ++i) {
        cx += half_to_float(data[i].center[0]);
        cy += half_to_float(data[i].center[1]);
        cz += half_to_float(data[i].center[2]);
    }
    double inv = 1.0 / static_cast<double>(count);
    center[0] = static_cast<float>(cx * inv);
    center[1] = static_cast<float>(cy * inv);
    center[2] = static_cast<float>(cz * inv);

    // Pass 2: 95th percentile distance from centroid (outlier-resistant).
    // Using max distance would let a single far-off point push the camera
    // to 57m away, making the actual scene invisible.
    std::vector<float> dists2(count);
    for (std::size_t i = 0; i < count; ++i) {
        float dx = half_to_float(data[i].center[0]) - center[0];
        float dy = half_to_float(data[i].center[1]) - center[1];
        float dz = half_to_float(data[i].center[2]) - center[2];
        dists2[i] = dx * dx + dy * dy + dz * dz;
    }
    std::size_t p95_idx = count * 95 / 100;
    if (p95_idx >= count) p95_idx = count - 1;
    std::nth_element(dists2.begin(),
                     dists2.begin() + static_cast<std::ptrdiff_t>(p95_idx),
                     dists2.end());
    *radius = std::sqrt(dists2[p95_idx]);
    // Floor at 0.5m so the camera never starts inside a tiny cluster
    if (*radius < 0.5f) *radius = 0.5f;
    return true;
}

core::Status SplatRenderEngine::create_gpu_resources() noexcept {
    // Splat buffer
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(PackedSplat);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "SplatBuffer";
        splat_buffer_ = device_.create_buffer(desc);
    }

    // SH coefficients buffer (parallel to splat buffer)
    // 12 floats (3 float4) per splat: R/G/B channels × 3 SH degree-1 basis
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * 12 * sizeof(float);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "SHBuffer";
        sh_buffer_ = device_.create_buffer(desc);
        // Zero-initialize SH buffer to prevent garbage SH values.
        // Metal kShared buffers have undefined initial contents.
        // If SH data is not uploaded (e.g., DC-only PLY), the shader would
        // read garbage from buffer(3) → random color shifts or black splats.
        if (sh_buffer_.valid()) {
            void* ptr = device_.map_buffer(sh_buffer_);
            if (ptr) {
                std::memset(ptr, 0, desc.size_bytes);
                device_.unmap_buffer(sh_buffer_);
            }
        }
    }

    // D3: Region ID buffer (uint8 per splat — identifies which temporal region each splat belongs to)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint8_t);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "RegionIDBuffer";
        region_id_buffer_ = device_.create_buffer(desc);
        // Zero-initialize: all splats default to region 0
        if (region_id_buffer_.valid()) {
            void* ptr = device_.map_buffer(region_id_buffer_);
            if (ptr) {
                std::memset(ptr, 0, desc.size_bytes);
                device_.unmap_buffer(region_id_buffer_);
            }
        }
    }

    // D3: Region fade alpha buffer (dynamic, initially 64 regions)
    // Grows as needed when more regions are created (no upper limit).
    {
        render::GPUBufferDesc desc{};
        region_fade_gpu_capacity_ = 64;
        desc.size_bytes = region_fade_gpu_capacity_ * sizeof(float);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kUniform) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "RegionFadeBuffer";
        region_fade_buffer_ = device_.create_buffer(desc);
        // Initialize all regions to fully visible (1.0)
        if (region_fade_buffer_.valid()) {
            void* ptr = device_.map_buffer(region_fade_buffer_);
            if (ptr) {
                auto* alphas = static_cast<float*>(ptr);
                for (std::size_t i = 0; i < region_fade_gpu_capacity_; ++i) {
                    alphas[i] = 1.0f;
                }
                device_.unmap_buffer(region_fade_buffer_);
            }
        }
    }

    // Depth key buffer (sortable uint32 keys for radix sorting)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(float);
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);
        desc.label = "DepthBuffer";
        depth_buffer_ = device_.create_buffer(desc);
    }

    // Index buffer (sorted permutation)
    // Use kShared so we can CPU-prefill identity indices as a safe fallback.
    // If computeSplatDepths runs, it overwrites with gid (same result).
    // If it doesn't run (shader not found), we still have valid indices.
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint32_t);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "IndexBuffer";
        index_buffer_ = device_.create_buffer(desc);
        // Pre-fill with identity indices: [0, 1, 2, ..., N-1]
        if (index_buffer_.valid()) {
            void* ptr = device_.map_buffer(index_buffer_);
            if (ptr) {
                auto* indices = static_cast<std::uint32_t*>(ptr);
                for (std::size_t i = 0; i < config_.max_splats; ++i) {
                    indices[i] = static_cast<std::uint32_t>(i);
                }
                device_.unmap_buffer(index_buffer_);
            }
        }
    }

    // Camera uniform buffer
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = sizeof(SplatCameraState);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kUniform);
        desc.label = "CameraUniform";
        camera_buffer_ = device_.create_buffer(desc);
    }

    // Quad vertex buffer (unit quad: 4 vertices, triangle strip)
    {
        float quad_vertices[] = {
            -1.0f, -1.0f,   // bottom-left
             1.0f, -1.0f,   // bottom-right
            -1.0f,  1.0f,   // top-left
             1.0f,  1.0f,   // top-right
        };
        render::GPUBufferDesc desc{};
        desc.size_bytes = sizeof(quad_vertices);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kVertex);
        desc.label = "QuadVertices";
        quad_buffer_ = device_.create_buffer(desc);
        if (quad_buffer_.valid()) {
            device_.update_buffer(quad_buffer_, quad_vertices,
                                  0, sizeof(quad_vertices));
        }
    }

    // Radix sort temporary buffer (ping-pong for index reordering)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint32_t);
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);

        desc.label = "SortTempIndices";
        sort_temp_indices_ = device_.create_buffer(desc);
    }
    {
        render::GPUBufferDesc desc{};
        const std::uint32_t max_groups = radix_group_count(config_.max_splats);
        desc.size_bytes = static_cast<std::size_t>(max_groups) *
                          static_cast<std::size_t>(kRadixBuckets) *
                          sizeof(std::uint32_t);
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);
        desc.label = "SortHistogram";
        sort_histogram_ = device_.create_buffer(desc);
    }

    // Shader loading (platform-specific names matching GaussianSplat.metal)
    auto depth_shader = device_.load_shader("computeSplatDepths",
                                             render::GPUShaderStage::kCompute);
    auto clear_hist_shader = device_.load_shader("radixClearHistogram",
                                                  render::GPUShaderStage::kCompute);
    auto histogram_shader = device_.load_shader("radixHistogram",
                                                 render::GPUShaderStage::kCompute);
    auto prefix_sum_shader = device_.load_shader("radixPrefixSum",
                                                  render::GPUShaderStage::kCompute);
    auto scatter_shader = device_.load_shader("radixScatter",
                                               render::GPUShaderStage::kCompute);
    auto vert_shader = device_.load_shader("splatVertex",
                                            render::GPUShaderStage::kVertex);
    auto frag_shader = device_.load_shader("splatFragment",
                                            render::GPUShaderStage::kFragment);

    std::fprintf(stderr, "[Aether3D][SplatEngine] Shader loading: "
                 "depth=%s clearHist=%s histogram=%s prefixSum=%s scatter=%s "
                 "vert=%s frag=%s\n",
                 depth_shader.valid()       ? "OK" : "FAIL",
                 clear_hist_shader.valid()  ? "OK" : "FAIL",
                 histogram_shader.valid()   ? "OK" : "FAIL",
                 prefix_sum_shader.valid()  ? "OK" : "FAIL",
                 scatter_shader.valid()     ? "OK" : "FAIL",
                 vert_shader.valid()        ? "OK" : "FAIL",
                 frag_shader.valid()        ? "OK" : "FAIL");

    if (depth_shader.valid()) {
        depth_pipeline_ = device_.create_compute_pipeline(depth_shader);
    }
    if (clear_hist_shader.valid()) {
        clear_hist_pipeline_ = device_.create_compute_pipeline(clear_hist_shader);
    }
    if (histogram_shader.valid()) {
        histogram_pipeline_ = device_.create_compute_pipeline(histogram_shader);
    }
    if (prefix_sum_shader.valid()) {
        prefix_sum_pipeline_ = device_.create_compute_pipeline(prefix_sum_shader);
    }
    if (scatter_shader.valid()) {
        scatter_pipeline_ = device_.create_compute_pipeline(scatter_shader);
    }
    if (vert_shader.valid() && frag_shader.valid()) {
        render::GPURenderTargetDesc default_target{};
        default_target.color_format = render::GPUTextureFormat::kBGRA8Unorm;
        default_target.color_attachment_count = 1;
        default_target.color_attachments[0].format = render::GPUTextureFormat::kBGRA8Unorm;
        default_target.color_attachments[0].blend.blending_enabled = true;
        default_target.color_attachments[0].blend.rgb_blend_op = render::GPUBlendOperation::kAdd;
        default_target.color_attachments[0].blend.alpha_blend_op = render::GPUBlendOperation::kAdd;
        default_target.color_attachments[0].blend.source_rgb_blend = render::GPUBlendFactor::kOne;
        default_target.color_attachments[0].blend.destination_rgb_blend =
            render::GPUBlendFactor::kOneMinusSourceAlpha;
        default_target.color_attachments[0].blend.source_alpha_blend = render::GPUBlendFactor::kOne;
        default_target.color_attachments[0].blend.destination_alpha_blend =
            render::GPUBlendFactor::kOneMinusSourceAlpha;
        default_target.depth_format = render::GPUTextureFormat::kDepth32Float;
        default_target.blending_enabled = true;
        default_target.depth_test_enabled = true;
        // Transparent Gaussian splats should not populate the depth buffer.
        // Writing depth here causes semi-transparent layers to self-occlude
        // and produces the "PPT / block popping" artifact during small camera
        // motions when overlapping splats fight in depth.
        default_target.depth_write_enabled = false;
        default_target.depth_compare = render::GPUCompareFunction::kLessEqual;
        render_pipeline_ = device_.create_render_pipeline(
            vert_shader, frag_shader, default_target);
    }

    bool gpu_sort_ready = depth_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();
    std::fprintf(stderr, "[Aether3D][SplatEngine] Pipeline creation: "
                 "depth=%s gpuSort=%s render=%s\n",
                 depth_pipeline_.valid()  ? "OK" : "FAIL",
                 gpu_sort_ready           ? "OK" : "FAIL",
                 render_pipeline_.valid() ? "OK" : "FAIL");

    return core::Status::kOk;
}

void SplatRenderEngine::destroy_gpu_resources() noexcept {
    if (splat_buffer_.valid())        device_.destroy_buffer(splat_buffer_);
    if (sh_buffer_.valid())           device_.destroy_buffer(sh_buffer_);
    if (depth_buffer_.valid())        device_.destroy_buffer(depth_buffer_);
    if (index_buffer_.valid())        device_.destroy_buffer(index_buffer_);
    if (camera_buffer_.valid())       device_.destroy_buffer(camera_buffer_);
    if (quad_buffer_.valid())         device_.destroy_buffer(quad_buffer_);
    if (sort_temp_indices_.valid())   device_.destroy_buffer(sort_temp_indices_);
    if (sort_histogram_.valid())      device_.destroy_buffer(sort_histogram_);

    if (depth_pipeline_.valid())      device_.destroy_compute_pipeline(depth_pipeline_);
    if (clear_hist_pipeline_.valid()) device_.destroy_compute_pipeline(clear_hist_pipeline_);
    if (histogram_pipeline_.valid())  device_.destroy_compute_pipeline(histogram_pipeline_);
    if (prefix_sum_pipeline_.valid()) device_.destroy_compute_pipeline(prefix_sum_pipeline_);
    if (scatter_pipeline_.valid())    device_.destroy_compute_pipeline(scatter_pipeline_);
    if (render_pipeline_.valid())     device_.destroy_render_pipeline(render_pipeline_);
}

void SplatRenderEngine::upload_splats_to_gpu() noexcept {
    if (cpu_buffer_.empty() || !splat_buffer_.valid()) return;

    std::size_t upload_bytes = cpu_buffer_.size_bytes();
    std::size_t max_bytes = config_.max_splats * sizeof(PackedSplat);
    if (upload_bytes > max_bytes) upload_bytes = max_bytes;

    device_.update_buffer(splat_buffer_, cpu_buffer_.data(), 0, upload_bytes);

    // Upload SH coefficients to GPU (parallel buffer)
    if (sh_buffer_.valid() && !cpu_sh_data_.empty()) {
        std::size_t sh_upload_bytes = cpu_sh_data_.size() * sizeof(float);
        std::size_t sh_max_bytes = config_.max_splats * 12 * sizeof(float);
        if (sh_upload_bytes > sh_max_bytes) sh_upload_bytes = sh_max_bytes;
        device_.update_buffer(sh_buffer_, cpu_sh_data_.data(), 0, sh_upload_bytes);
    }

    // D3: Upload region IDs to GPU (parallel to splat buffer)
    if (region_id_buffer_.valid() && !cpu_region_ids_.empty()) {
        std::size_t rid_upload_bytes = cpu_region_ids_.size() * sizeof(std::uint8_t);
        std::size_t rid_max_bytes = config_.max_splats * sizeof(std::uint8_t);
        if (rid_upload_bytes > rid_max_bytes) rid_upload_bytes = rid_max_bytes;
        device_.update_buffer(region_id_buffer_, cpu_region_ids_.data(), 0, rid_upload_bytes);
    }

    // D3: Upload region fade alphas to GPU (dynamic buffer)
    if (region_fade_buffer_.valid() && !region_fade_alphas_.empty()) {
        std::size_t upload_count = region_fade_alphas_.size();

        // Grow GPU buffer if needed
        if (upload_count > region_fade_gpu_capacity_) {
            std::size_t new_capacity = std::max(upload_count, region_fade_gpu_capacity_ * 2);
            render::GPUBufferDesc desc{};
            desc.size_bytes = new_capacity * sizeof(float);
            desc.storage = render::GPUStorageMode::kShared;
            desc.usage_mask = static_cast<std::uint8_t>(
                render::GPUBufferUsage::kUniform) |
                static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
            desc.label = "RegionFadeBuffer";
            auto new_buffer = device_.create_buffer(desc);
            if (new_buffer.valid()) {
                // Replace old buffer
                region_fade_buffer_ = new_buffer;
                region_fade_gpu_capacity_ = new_capacity;
            }
        }

        device_.update_buffer(region_fade_buffer_, region_fade_alphas_.data(),
                              0, upload_count * sizeof(float));
    }
}

}  // namespace splat
}  // namespace aether
