// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/spatial_hash_adjacency.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace aether {
namespace quality {
namespace {

struct Vec3f {
    float x;
    float y;
    float z;
};

struct VertexKey {
    std::int32_t x;
    std::int32_t y;
    std::int32_t z;

    bool operator==(const VertexKey& other) const {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct VertexKeyHash {
    std::size_t operator()(const VertexKey& key) const {
        std::size_t h = 1469598103934665603ull;
        auto mix = [&](std::uint32_t v) {
            h ^= static_cast<std::size_t>(v);
            h *= 1099511628211ull;
        };
        mix(static_cast<std::uint32_t>(key.x));
        mix(static_cast<std::uint32_t>(key.y));
        mix(static_cast<std::uint32_t>(key.z));
        return h;
    }
};

inline float sqr(float x) {
    return x * x;
}

inline float dist_sq(const Vec3f& a, const Vec3f& b) {
    return sqr(a.x - b.x) + sqr(a.y - b.y) + sqr(a.z - b.z);
}

std::array<Vec3f, 3> vertices_of(const Triangle3f& t) {
    return {{
        Vec3f{t.ax, t.ay, t.az},
        Vec3f{t.bx, t.by, t.bz},
        Vec3f{t.cx, t.cy, t.cz},
    }};
}

VertexKey quantize(const Vec3f& v, float inv_cell_size) {
    return VertexKey{
        static_cast<std::int32_t>(std::llround(static_cast<double>(v.x * inv_cell_size))),
        static_cast<std::int32_t>(std::llround(static_cast<double>(v.y * inv_cell_size))),
        static_cast<std::int32_t>(std::llround(static_cast<double>(v.z * inv_cell_size))),
    };
}

std::uint64_t pack_pair(std::uint32_t a, std::uint32_t b) {
    const std::uint32_t lo = std::min(a, b);
    const std::uint32_t hi = std::max(a, b);
    return (static_cast<std::uint64_t>(lo) << 32u) | static_cast<std::uint64_t>(hi);
}

bool share_edge_with_epsilon(
    const Triangle3f& a,
    const Triangle3f& b,
    float eps_sq) {
    const auto av = vertices_of(a);
    const auto bv = vertices_of(b);

    int match_count = 0;
    for (const Vec3f& va : av) {
        for (const Vec3f& vb : bv) {
            if (dist_sq(va, vb) <= eps_sq) {
                ++match_count;
                break;
            }
        }
    }
    return match_count >= 2;
}

}  // namespace

core::Status build_spatial_hash_adjacency(
    const Triangle3f* triangles,
    std::size_t triangle_count,
    float cell_size,
    float epsilon,
    std::vector<std::uint32_t>* out_offsets,
    std::vector<std::uint32_t>* out_neighbors) {
    if (out_offsets == nullptr || out_neighbors == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_offsets->clear();
    out_neighbors->clear();

    if (triangle_count == 0u) {
        out_offsets->push_back(0u);
        return core::Status::kOk;
    }
    if (triangles == nullptr ||
        !std::isfinite(cell_size) || cell_size <= 0.0f ||
        !std::isfinite(epsilon) || epsilon < 0.0f) {
        return core::Status::kInvalidArgument;
    }

    const float inv_cell_size = 1.0f / cell_size;
    const float eps_sq = epsilon * epsilon;

    std::unordered_map<VertexKey, std::vector<std::uint32_t>, VertexKeyHash> vertex_buckets;
    vertex_buckets.reserve(triangle_count * 3u);

    for (std::uint32_t tri = 0u; tri < static_cast<std::uint32_t>(triangle_count); ++tri) {
        const auto verts = vertices_of(triangles[tri]);
        for (const Vec3f& v : verts) {
            vertex_buckets[quantize(v, inv_cell_size)].push_back(tri);
        }
    }

    std::vector<std::vector<std::uint32_t>> adjacency(triangle_count);
    std::unordered_set<std::uint64_t> dedup_pairs;
    dedup_pairs.reserve(triangle_count * 3u);

    for (const auto& kv : vertex_buckets) {
        const std::vector<std::uint32_t>& candidates = kv.second;
        if (candidates.size() < 2u) {
            continue;
        }

        for (std::size_t i = 0u; i < candidates.size(); ++i) {
            for (std::size_t j = i + 1u; j < candidates.size(); ++j) {
                const std::uint32_t a = candidates[i];
                const std::uint32_t b = candidates[j];
                const std::uint64_t pair_key = pack_pair(a, b);
                if (dedup_pairs.find(pair_key) != dedup_pairs.end()) {
                    continue;
                }
                if (share_edge_with_epsilon(triangles[a], triangles[b], eps_sq)) {
                    dedup_pairs.insert(pair_key);
                    adjacency[a].push_back(b);
                    adjacency[b].push_back(a);
                }
            }
        }
    }

    out_offsets->resize(triangle_count + 1u, 0u);
    std::size_t total_neighbors = 0u;
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        total_neighbors += adjacency[i].size();
        if (total_neighbors > static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max())) {
            return core::Status::kOutOfRange;
        }
        (*out_offsets)[i + 1u] = static_cast<std::uint32_t>(total_neighbors);
    }

    out_neighbors->resize(total_neighbors);
    std::size_t cursor = 0u;
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        for (std::uint32_t n : adjacency[i]) {
            (*out_neighbors)[cursor++] = n;
        }
    }
    return core::Status::kOk;
}

core::Status bfs_distances(
    const std::uint32_t* offsets,
    const std::uint32_t* neighbors,
    std::size_t triangle_count,
    const std::uint32_t* sources,
    std::size_t source_count,
    int max_hops,
    std::vector<std::int32_t>* out_distances) {
    if (out_distances == nullptr || max_hops < 0) {
        return core::Status::kInvalidArgument;
    }
    out_distances->assign(triangle_count, -1);
    if (triangle_count == 0u) {
        return core::Status::kOk;
    }
    if (offsets == nullptr || (source_count > 0u && sources == nullptr)) {
        return core::Status::kInvalidArgument;
    }

    const std::uint32_t edge_count = offsets[triangle_count];
    if (edge_count > 0u && neighbors == nullptr) {
        return core::Status::kInvalidArgument;
    }
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        if (offsets[i] > offsets[i + 1u]) {
            return core::Status::kInvalidArgument;
        }
    }

    std::queue<std::uint32_t> q;
    for (std::size_t i = 0u; i < source_count; ++i) {
        const std::uint32_t s = sources[i];
        if (s >= triangle_count) {
            continue;
        }
        if ((*out_distances)[s] < 0) {
            (*out_distances)[s] = 0;
            q.push(s);
        }
    }

    while (!q.empty()) {
        const std::uint32_t u = q.front();
        q.pop();

        const std::int32_t du = (*out_distances)[u];
        if (du >= max_hops) {
            continue;
        }

        const std::uint32_t begin = offsets[u];
        const std::uint32_t end = offsets[u + 1u];
        if (begin > edge_count || end > edge_count || begin > end) {
            return core::Status::kInvalidArgument;
        }

        for (std::uint32_t k = begin; k < end; ++k) {
            const std::uint32_t v = neighbors[k];
            if (v >= triangle_count) {
                return core::Status::kInvalidArgument;
            }
            if ((*out_distances)[v] < 0) {
                (*out_distances)[v] = du + 1;
                q.push(v);
            }
        }
    }

    return core::Status::kOk;
}

}  // namespace quality
}  // namespace aether
