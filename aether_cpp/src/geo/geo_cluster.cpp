// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_cluster.h"
#include "aether/geo/geo_constants.h"

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

namespace aether {
namespace geo {

// Grid-based clustering: each grid cell at zoom level becomes a cluster.
// Cell size derived from zoom level and radius in pixels.
// At zoom z, world width in pixels = 256 * 2^z.
// Cluster grid cell size in degrees = radius_px / (256 * 2^z) * 360.

core::Status geo_cluster_points(const ClusterPoint* points, std::size_t point_count,
                                std::uint32_t zoom_level,
                                std::uint32_t radius_px,
                                GeoCluster* out_clusters, std::size_t max_clusters,
                                std::size_t* out_count) {
    if (!out_count) return core::Status::kInvalidArgument;
    if (point_count > 0 && !points) return core::Status::kInvalidArgument;
    if (zoom_level > CLUSTER_MAX_ZOOM) return core::Status::kOutOfRange;

    *out_count = 0;

    if (point_count == 0) return core::Status::kOk;

    // Compute grid cell size in degrees
    double world_px = 256.0 * std::pow(2.0, static_cast<double>(zoom_level));
    double cell_deg = (static_cast<double>(radius_px) / world_px) * 360.0 * CLUSTER_GRID_SIZE_FACTOR;
    if (cell_deg < COORDINATE_EPSILON) cell_deg = COORDINATE_EPSILON;

    // Assign each point to a grid cell
    struct CellKey {
        std::int64_t x;
        std::int64_t y;
        bool operator==(const CellKey& o) const { return x == o.x && y == o.y; }
    };
    struct CellKeyHash {
        std::size_t operator()(const CellKey& k) const {
            return std::hash<std::int64_t>()(k.x) ^ (std::hash<std::int64_t>()(k.y) << 32);
        }
    };

    struct CellData {
        double sum_lat{0};
        double sum_lon{0};
        double sum_weight{0};
        std::uint32_t count{0};
        std::uint64_t best_id{0};
        float best_weight{-1.0f};
    };

    std::unordered_map<CellKey, CellData, CellKeyHash> grid;

    for (std::size_t i = 0; i < point_count; ++i) {
        const auto& p = points[i];
        CellKey key{
            static_cast<std::int64_t>(std::floor(p.lat / cell_deg)),
            static_cast<std::int64_t>(std::floor(p.lon / cell_deg))
        };
        auto& cell = grid[key];
        cell.sum_lat += p.lat * p.weight;
        cell.sum_lon += p.lon * p.weight;
        cell.sum_weight += p.weight;
        cell.count++;
        if (p.weight > cell.best_weight) {
            cell.best_weight = p.weight;
            cell.best_id = p.id;
        }
    }

    // Convert grid cells to clusters
    std::vector<GeoCluster> clusters;
    clusters.reserve(grid.size());
    for (const auto& kv : grid) {
        GeoCluster c{};
        if (kv.second.sum_weight > 0) {
            c.center_lat = kv.second.sum_lat / kv.second.sum_weight;
            c.center_lon = kv.second.sum_lon / kv.second.sum_weight;
        }
        c.point_count = kv.second.count;
        c.total_weight = static_cast<float>(kv.second.sum_weight);
        c.representative_id = kv.second.best_id;
        clusters.push_back(c);
    }

    // Sort by weight descending for deterministic output
    std::sort(clusters.begin(), clusters.end(),
        [](const GeoCluster& a, const GeoCluster& b) {
            return a.total_weight > b.total_weight;
        });

    *out_count = (clusters.size() < max_clusters) ? clusters.size() : max_clusters;
    if (out_clusters) {
        for (std::size_t i = 0; i < *out_count; ++i) {
            out_clusters[i] = clusters[i];
        }
    }
    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
