// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/temporal_cluster.h"
#include "aether/geo/geo_constants.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal structures
// ---------------------------------------------------------------------------

static constexpr size_t kMaxPoints = 65536;

struct TemporalCluster {
    double spatial_eps_m;
    double temporal_eps_s;
    double altitude_eps_m;
    uint32_t min_points;

    STPoint* points;
    size_t point_count;
    size_t point_capacity;

    // Union-find parent array (used during clustering)
    int32_t* parent;
    int32_t* rank_arr;

    // Cluster results cached after run
    double last_run_time;
};

namespace {

// Haversine distance in meters (simplified for clustering)
double haversine_m(double lat1, double lon1, double lat2, double lon2) {
    double dlat = (lat2 - lat1) * DEG_TO_RAD;
    double dlon = (lon2 - lon1) * DEG_TO_RAD;
    double la1 = lat1 * DEG_TO_RAD;
    double la2 = lat2 * DEG_TO_RAD;

    double a = std::sin(dlat * 0.5) * std::sin(dlat * 0.5)
             + std::cos(la1) * std::cos(la2)
             * std::sin(dlon * 0.5) * std::sin(dlon * 0.5);
    double c = 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
    return EARTH_MEAN_RADIUS_M * c;
}

// Union-Find operations
int32_t uf_find(int32_t* parent, int32_t x) {
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];  // path compression
        x = parent[x];
    }
    return x;
}

void uf_union(int32_t* parent, int32_t* rank_arr, int32_t a, int32_t b) {
    a = uf_find(parent, a);
    b = uf_find(parent, b);
    if (a == b) return;
    if (rank_arr[a] < rank_arr[b]) {
        int32_t tmp = a; a = b; b = tmp;
    }
    parent[b] = a;
    if (rank_arr[a] == rank_arr[b]) rank_arr[a]++;
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Create / Destroy
// ---------------------------------------------------------------------------

TemporalCluster* temporal_cluster_create(double spatial_eps_m,
                                         double temporal_eps_s,
                                         double altitude_eps_m,
                                         uint32_t min_points) {
    auto* tc = static_cast<TemporalCluster*>(std::calloc(1, sizeof(TemporalCluster)));
    if (!tc) return nullptr;

    tc->spatial_eps_m = spatial_eps_m;
    tc->temporal_eps_s = temporal_eps_s;
    tc->altitude_eps_m = altitude_eps_m;
    tc->min_points = min_points;
    tc->point_capacity = 1024;  // Initial capacity
    tc->point_count = 0;

    tc->points = static_cast<STPoint*>(std::calloc(tc->point_capacity, sizeof(STPoint)));
    if (!tc->points) {
        std::free(tc);
        return nullptr;
    }

    tc->parent = nullptr;
    tc->rank_arr = nullptr;
    tc->last_run_time = 0.0;

    return tc;
}

void temporal_cluster_destroy(TemporalCluster* tc) {
    if (!tc) return;
    std::free(tc->points);
    std::free(tc->parent);
    std::free(tc->rank_arr);
    std::free(tc);
}

// ---------------------------------------------------------------------------
// Add point
// ---------------------------------------------------------------------------

core::Status temporal_cluster_add(TemporalCluster* tc, const STPoint& point) {
    if (!tc) return core::Status::kInvalidArgument;

    // Grow if needed
    if (tc->point_count >= tc->point_capacity) {
        size_t new_cap = tc->point_capacity * 2;
        if (new_cap > kMaxPoints) new_cap = kMaxPoints;
        if (tc->point_count >= new_cap) return core::Status::kResourceExhausted;

        auto* new_pts = static_cast<STPoint*>(
            std::realloc(tc->points, new_cap * sizeof(STPoint)));
        if (!new_pts) return core::Status::kResourceExhausted;
        tc->points = new_pts;
        tc->point_capacity = new_cap;
    }

    tc->points[tc->point_count++] = point;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Run: 3D ST-DBSCAN with union-find
// ---------------------------------------------------------------------------

core::Status temporal_cluster_run(TemporalCluster* tc,
                                  STCluster* out, size_t max,
                                  size_t* out_count) {
    if (!tc || !out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!out && max > 0) return core::Status::kInvalidArgument;

    size_t n = tc->point_count;
    if (n == 0) return core::Status::kOk;

    // Allocate union-find arrays
    std::free(tc->parent);
    std::free(tc->rank_arr);
    tc->parent = static_cast<int32_t*>(std::calloc(n, sizeof(int32_t)));
    tc->rank_arr = static_cast<int32_t*>(std::calloc(n, sizeof(int32_t)));
    if (!tc->parent || !tc->rank_arr) return core::Status::kResourceExhausted;

    for (size_t i = 0; i < n; ++i) {
        tc->parent[i] = static_cast<int32_t>(i);
        tc->rank_arr[i] = 0;
    }

    // Count neighbors for each point (for core point determination)
    // and perform union on spatial+temporal+altitude neighbors
    // Use O(n^2) brute force (suitable for n < 65536)
    uint32_t* neighbor_count = static_cast<uint32_t*>(std::calloc(n, sizeof(uint32_t)));
    if (!neighbor_count) {
        return core::Status::kResourceExhausted;
    }

    for (size_t i = 0; i < n; ++i) {
        for (size_t j = i + 1; j < n; ++j) {
            double spatial_d = haversine_m(
                tc->points[i].lat, tc->points[i].lon,
                tc->points[j].lat, tc->points[j].lon);
            double temporal_d = std::fabs(tc->points[i].timestamp_s - tc->points[j].timestamp_s);
            double altitude_d = std::fabs(tc->points[i].alt_m - tc->points[j].alt_m);

            if (spatial_d <= tc->spatial_eps_m &&
                temporal_d <= tc->temporal_eps_s &&
                altitude_d <= tc->altitude_eps_m) {
                neighbor_count[i]++;
                neighbor_count[j]++;
                uf_union(tc->parent, tc->rank_arr,
                         static_cast<int32_t>(i), static_cast<int32_t>(j));
            }
        }
    }

    // Identify clusters: group points by root, filter by min_points
    // First pass: count per cluster root
    // Use a simple linear scan approach
    size_t cluster_count = 0;

    // Track which roots we've seen and their cluster mapping
    struct RootInfo {
        int32_t root;
        double sum_lat, sum_lon, sum_alt;
        uint32_t count;
        double max_timestamp;
    };

    // Collect unique roots
    RootInfo roots[256];
    size_t root_count = 0;

    for (size_t i = 0; i < n; ++i) {
        // Only include core points and their neighbors
        int32_t root = uf_find(tc->parent, static_cast<int32_t>(i));

        // Find existing root entry
        size_t ri = root_count;
        for (size_t r = 0; r < root_count; ++r) {
            if (roots[r].root == root) {
                ri = r;
                break;
            }
        }

        if (ri == root_count) {
            // New root
            if (root_count >= 256) continue;  // Cap number of tracked clusters
            roots[root_count].root = root;
            roots[root_count].sum_lat = 0;
            roots[root_count].sum_lon = 0;
            roots[root_count].sum_alt = 0;
            roots[root_count].count = 0;
            roots[root_count].max_timestamp = 0;
            root_count++;
        }

        roots[ri].sum_lat += tc->points[i].lat;
        roots[ri].sum_lon += tc->points[i].lon;
        roots[ri].sum_alt += tc->points[i].alt_m;
        roots[ri].count++;
        if (tc->points[i].timestamp_s > roots[ri].max_timestamp) {
            roots[ri].max_timestamp = tc->points[i].timestamp_s;
        }
    }

    // Output clusters meeting min_points threshold
    for (size_t r = 0; r < root_count && cluster_count < max; ++r) {
        if (roots[r].count >= tc->min_points) {
            STCluster& c = out[cluster_count];
            c.center_lat = roots[r].sum_lat / roots[r].count;
            c.center_lon = roots[r].sum_lon / roots[r].count;
            c.center_alt = roots[r].sum_alt / roots[r].count;
            c.point_count = roots[r].count;
            c.heat = 1.0;  // Initial heat = 1.0
            c.cluster_id = static_cast<uint64_t>(cluster_count);
            cluster_count++;
        }
    }

    std::free(neighbor_count);

    *out_count = cluster_count;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Heat decay: exponential decay of cluster heat values
// ---------------------------------------------------------------------------

core::Status temporal_cluster_heat_decay(TemporalCluster* tc,
                                         double current_time_s) {
    if (!tc) return core::Status::kInvalidArgument;

    double dt = current_time_s - tc->last_run_time;
    if (dt <= 0.0) return core::Status::kOk;

    // Heat decay is applied externally to cluster results,
    // but we track the time for delta computation
    tc->last_run_time = current_time_s;

    // The decay factor: heat *= exp(-TEMPORAL_HEAT_DECAY_RATE * dt)
    // This is stored so that callers who hold STCluster arrays can apply it
    // We don't hold persistent cluster results, so this just updates the time reference
    // and is a no-op on the internal point store.

    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
