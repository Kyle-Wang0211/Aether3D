// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_topology.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

// Minimal open-addressing hash set for edge pairs.
// Avoids std::unordered_map which requires exceptions/RTTI on some platforms.
namespace aether {
namespace tsdf {
namespace {

/// Pack two vertex indices into a single uint64_t key (min, max order).
inline uint64_t pack_edge(uint32_t a, uint32_t b) {
    const uint32_t lo = a < b ? a : b;
    const uint32_t hi = a < b ? b : a;
    return (static_cast<uint64_t>(lo) << 32) | static_cast<uint64_t>(hi);
}

/// Simple open-addressing hash table: key → count.
/// Keys: packed edge pairs.  Count: number of triangles referencing the edge.
struct EdgeMap {
    static constexpr uint64_t kEmpty = UINT64_MAX;

    uint64_t* keys{nullptr};
    uint8_t* counts{nullptr};
    std::size_t capacity{0};
    std::size_t size{0};

    explicit EdgeMap(std::size_t cap) {
        // Round up to power of 2 for fast modulo.
        capacity = 16;
        while (capacity < cap) capacity <<= 1;
        keys = new uint64_t[capacity];
        counts = new uint8_t[capacity];
        std::memset(keys, 0xFF, capacity * sizeof(uint64_t));  // fill with kEmpty
        std::memset(counts, 0, capacity * sizeof(uint8_t));
    }

    ~EdgeMap() {
        delete[] keys;
        delete[] counts;
    }

    EdgeMap(const EdgeMap&) = delete;
    EdgeMap& operator=(const EdgeMap&) = delete;

    /// Insert or increment count for an edge.
    void insert_or_increment(uint64_t key) {
        // FNV-1a-style hash mixing.
        uint64_t h = key;
        h ^= h >> 33;
        h *= 0xff51afd7ed558ccdULL;
        h ^= h >> 33;
        h *= 0xc4ceb9fe1a85ec53ULL;
        h ^= h >> 33;

        const std::size_t mask = capacity - 1;
        std::size_t idx = static_cast<std::size_t>(h) & mask;
        for (;;) {
            if (keys[idx] == kEmpty) {
                keys[idx] = key;
                counts[idx] = 1;
                ++size;
                return;
            }
            if (keys[idx] == key) {
                if (counts[idx] < 255) ++counts[idx];
                return;
            }
            idx = (idx + 1) & mask;
        }
    }

    /// Count edges with reference count == 1 (boundary edges).
    int32_t count_boundary() const {
        int32_t boundary = 0;
        for (std::size_t i = 0; i < capacity; ++i) {
            if (keys[i] != kEmpty && counts[i] == 1) {
                ++boundary;
            }
        }
        return boundary;
    }
};

}  // namespace

MeshTopologyDiagnostics compute_mesh_topology(
    const MeshTriangle* triangles,
    std::size_t triangle_count,
    std::size_t vertex_count) {

    MeshTopologyDiagnostics diag{};
    diag.vertex_count = static_cast<int64_t>(vertex_count);
    diag.face_count = static_cast<int64_t>(triangle_count);

    if (triangle_count == 0 || triangles == nullptr) {
        diag.euler_characteristic = static_cast<int32_t>(vertex_count);
        diag.topology_ok = (vertex_count == 0);
        return diag;
    }

    // Each triangle contributes 3 edges.  Load factor ~50% → capacity = 6 * F.
    const std::size_t estimated_edges = triangle_count * 3;
    EdgeMap edges(estimated_edges * 2);

    for (std::size_t i = 0; i < triangle_count; ++i) {
        const auto& tri = triangles[i];
        edges.insert_or_increment(pack_edge(tri.i0, tri.i1));
        edges.insert_or_increment(pack_edge(tri.i1, tri.i2));
        edges.insert_or_increment(pack_edge(tri.i2, tri.i0));
    }

    diag.edge_count = static_cast<int64_t>(edges.size);
    diag.boundary_edge_count = edges.count_boundary();

    // Euler characteristic: χ = V - E + F
    const int64_t V = diag.vertex_count;
    const int64_t E = diag.edge_count;
    const int64_t F = diag.face_count;
    diag.euler_characteristic = static_cast<int32_t>(V - E + F);
    diag.topology_ok = (diag.euler_characteristic == diag.expected_euler);

    return diag;
}

MeshTopologyDiagnostics compute_mesh_topology_from_indices(
    const uint32_t* indices,
    std::size_t index_count,
    std::size_t vertex_count) {

    MeshTopologyDiagnostics diag{};
    diag.vertex_count = static_cast<int64_t>(vertex_count);

    if (indices == nullptr || index_count < 3) {
        diag.euler_characteristic = static_cast<int32_t>(vertex_count);
        diag.topology_ok = (vertex_count == 0);
        return diag;
    }

    const std::size_t triangle_count = index_count / 3;
    diag.face_count = static_cast<int64_t>(triangle_count);

    const std::size_t estimated_edges = triangle_count * 3;
    EdgeMap edges(estimated_edges * 2);

    for (std::size_t i = 0; i < triangle_count; ++i) {
        const uint32_t i0 = indices[i * 3 + 0];
        const uint32_t i1 = indices[i * 3 + 1];
        const uint32_t i2 = indices[i * 3 + 2];
        edges.insert_or_increment(pack_edge(i0, i1));
        edges.insert_or_increment(pack_edge(i1, i2));
        edges.insert_or_increment(pack_edge(i2, i0));
    }

    diag.edge_count = static_cast<int64_t>(edges.size);
    diag.boundary_edge_count = edges.count_boundary();

    const int64_t V = diag.vertex_count;
    const int64_t E = diag.edge_count;
    const int64_t F = diag.face_count;
    diag.euler_characteristic = static_cast<int32_t>(V - E + F);
    diag.topology_ok = (diag.euler_characteristic == diag.expected_euler);

    return diag;
}

}  // namespace tsdf
}  // namespace aether
