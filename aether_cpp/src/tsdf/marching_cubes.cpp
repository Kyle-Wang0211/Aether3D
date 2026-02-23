// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/marching_cubes.h"
#include "aether/math/vec3.h"
#include "aether/tsdf/tsdf_constants.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <vector>
#include <unordered_map>
#include <vector>
#include <unordered_map>
#include <vector>

namespace aether {
namespace tsdf {

namespace {

constexpr int kEdgeTable[256] = {
    0x0, 0x109, 0x203, 0x30a, 0x406, 0x50f, 0x605, 0x70c, 0x80c, 0x905, 0xa0f, 0xb06, 0xc0a, 0xd03, 0xe09, 0xf00,
    0x190, 0x99, 0x393, 0x29a, 0x596, 0x49f, 0x795, 0x69c, 0x99c, 0x895, 0xb9f, 0xa96, 0xd9a, 0xc93, 0xf99, 0xe90,
    0x230, 0x339, 0x33, 0x13a, 0x636, 0x73f, 0x435, 0x53c, 0xa3c, 0xb35, 0x83f, 0x936, 0xe3a, 0xf33, 0xc39, 0xd30,
    0x3a0, 0x2a9, 0x1a3, 0xaa, 0x7a6, 0x6af, 0x5a5, 0x4ac, 0xbac, 0xaa5, 0x9af, 0x8a6, 0xfaa, 0xea3, 0xda9, 0xca0,
    0x460, 0x569, 0x663, 0x76a, 0x66, 0x16f, 0x265, 0x36c, 0xc6c, 0xd65, 0xe6f, 0xf66, 0x86a, 0x963, 0xa69, 0xb60,
    0x5f0, 0x4f9, 0x7f3, 0x6fa, 0x1f6, 0xff, 0x3f5, 0x2fc, 0xdfc, 0xcf5, 0xfff, 0xef6, 0x9fa, 0x8f3, 0xbf9, 0xaf0,
    0x650, 0x759, 0x453, 0x55a, 0x256, 0x35f, 0x55, 0x15c, 0xe5c, 0xf55, 0xc5f, 0xd56, 0xa5a, 0xb53, 0x859, 0x950,
    0x7c0, 0x6c9, 0x5c3, 0x4ca, 0x3c6, 0x2cf, 0x1c5, 0xcc, 0xfcc, 0xec5, 0xdcf, 0xcc6, 0xbca, 0xac3, 0x9c9, 0x8c0,
    0x8c0, 0x9c9, 0xac3, 0xbca, 0xcc6, 0xdcf, 0xec5, 0xfcc, 0xcc, 0x1c5, 0x2cf, 0x3c6, 0x4ca, 0x5c3, 0x6c9, 0x7c0,
    0x950, 0x859, 0xb53, 0xa5a, 0xd56, 0xc5f, 0xf55, 0xe5c, 0x15c, 0x55, 0x35f, 0x256, 0x55a, 0x453, 0x759, 0x650,
    0xaf0, 0xbf9, 0x8f3, 0x9fa, 0xef6, 0xfff, 0xcf5, 0xdfc, 0x2fc, 0x3f5, 0xff, 0x1f6, 0x6fa, 0x7f3, 0x4f9, 0x5f0,
    0xb60, 0xa69, 0x963, 0x86a, 0xf66, 0xe6f, 0xd65, 0xc6c, 0x36c, 0x265, 0x16f, 0x66, 0x76a, 0x663, 0x569, 0x460,
    0xca0, 0xda9, 0xea3, 0xfaa, 0x8a6, 0x9af, 0xaa5, 0xbac, 0x4ac, 0x5a5, 0x6af, 0x7a6, 0xaa, 0x1a3, 0x2a9, 0x3a0,
    0xd30, 0xc39, 0xf33, 0xe3a, 0x936, 0x83f, 0xb35, 0xa3c, 0x53c, 0x435, 0x73f, 0x636, 0x13a, 0x33, 0x339, 0x230,
    0xe90, 0xf99, 0xc93, 0xd9a, 0xa96, 0xb9f, 0x895, 0x99c, 0x69c, 0x795, 0x49f, 0x596, 0x29a, 0x393, 0x99, 0x190,
    0xf00, 0xe09, 0xd03, 0xc0a, 0xb06, 0xa0f, 0x905, 0x80c, 0x70c, 0x605, 0x50f, 0x406, 0x30a, 0x203, 0x109, 0x0
};

constexpr int kTetDecomposition[6][4] = {
    {0, 5, 1, 6},
    {0, 1, 2, 6},
    {0, 2, 3, 6},
    {0, 3, 7, 6},
    {0, 7, 4, 6},
    {0, 4, 5, 6},
};

inline aether::math::Vec3 to_vec3(const McVertex& v) {
    return aether::math::Vec3(v.x, v.y, v.z);
}

inline aether::math::Vec3 operator-(const aether::math::Vec3& a, const aether::math::Vec3& b) {
    return aether::math::Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}

inline aether::math::Vec3 cross(const aether::math::Vec3& a, const aether::math::Vec3& b) {
    return aether::math::Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

inline float length(const aether::math::Vec3& v) {
    return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

inline aether::math::Vec3 normalize_or_default(
    const aether::math::Vec3& v,
    const aether::math::Vec3& fallback) {
    const float len = length(v);
    if (len <= 1e-8f) {
        return fallback;
    }
    return aether::math::Vec3(v.x / len, v.y / len, v.z / len);
}

inline float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

inline int clampi(int value, int low, int high) {
    return std::max(low, std::min(high, value));
}

inline int grid_index(int x, int y, int z, int dim) {
    return x + y * dim + z * dim * dim;
}

inline float sample_sdf(
    const float* grid,
    int dim,
    int x,
    int y,
    int z) {
    const int gx = clampi(x, 0, dim - 1);
    const int gy = clampi(y, 0, dim - 1);
    const int gz = clampi(z, 0, dim - 1);
    return grid[grid_index(gx, gy, gz, dim)];
}

float quantize_interpolation_local(float t, float step) {
    if (!(step > 0.0f)) {
        return clamp01(t);
    }
    const float q = std::round(t / step) * step;
    return clamp01(q);
}

inline McVertex lerp_vertex(const McVertex& a, const McVertex& b, float va, float vb) {
    float t = 0.5f;
    const float denom = vb - va;
    if (std::fabs(denom) > 1e-8f) {
        t = (0.0f - va) / denom;
    }
    t = quantize_interpolation_local(t, VERTEX_QUANTIZATION_STEP);
    t = std::clamp(t, MC_INTERPOLATION_MIN, MC_INTERPOLATION_MAX);
    return McVertex{
        a.x + t * (b.x - a.x),
        a.y + t * (b.y - a.y),
        a.z + t * (b.z - a.z),
    };
}

inline bool append_triangle(
    const McVertex& a,
    const McVertex& b,
    const McVertex& c,
    MarchingCubesResult& out,
    size_t max_vertices,
    size_t& vc,
    size_t& ic) {
    if (vc + 3 > max_vertices) return false;
    if (is_degenerate_triangle(a, b, c)) return true;
    out.vertices[vc] = a;
    out.indices[ic++] = static_cast<uint32_t>(vc++);
    out.vertices[vc] = b;
    out.indices[ic++] = static_cast<uint32_t>(vc++);
    out.vertices[vc] = c;
    out.indices[ic++] = static_cast<uint32_t>(vc++);
    return true;
}

inline void polygonise_tetra(
    const McVertex* p,
    const float* val,
    MarchingCubesResult& out,
    size_t max_vertices,
    size_t& vc,
    size_t& ic) {
    int inside_idx[4] = {-1, -1, -1, -1};
    int outside_idx[4] = {-1, -1, -1, -1};
    int inside_count = 0;
    int outside_count = 0;

    for (int i = 0; i < 4; ++i) {
        if (val[i] < 0.0f) {
            inside_idx[inside_count++] = i;
        } else {
            outside_idx[outside_count++] = i;
        }
    }

    if (inside_count == 0 || inside_count == 4) return;

    if (inside_count == 1 || inside_count == 3) {
        const bool invert = inside_count == 3;
        const int v_in = invert ? outside_idx[0] : inside_idx[0];
        const int v0 = invert ? inside_idx[0] : outside_idx[0];
        const int v1 = invert ? inside_idx[1] : outside_idx[1];
        const int v2 = invert ? inside_idx[2] : outside_idx[2];

        const McVertex a = lerp_vertex(p[v_in], p[v0], val[v_in], val[v0]);
        const McVertex b = lerp_vertex(p[v_in], p[v1], val[v_in], val[v1]);
        const McVertex c = lerp_vertex(p[v_in], p[v2], val[v_in], val[v2]);
        append_triangle(a, b, c, out, max_vertices, vc, ic);
        return;
    }

    const int i0 = inside_idx[0];
    const int i1 = inside_idx[1];
    const int o0 = outside_idx[0];
    const int o1 = outside_idx[1];

    const McVertex a = lerp_vertex(p[i0], p[o0], val[i0], val[o0]);
    const McVertex b = lerp_vertex(p[i1], p[o0], val[i1], val[o0]);
    const McVertex c = lerp_vertex(p[i1], p[o1], val[i1], val[o1]);
    const McVertex d = lerp_vertex(p[i0], p[o1], val[i0], val[o1]);
    append_triangle(a, b, c, out, max_vertices, vc, ic);
    append_triangle(a, c, d, out, max_vertices, vc, ic);
}

inline void mesh_cube_with_tetra(
    const McVertex* cube_pos,
    const float* cube_val,
    MarchingCubesResult& out,
    size_t max_vertices,
    size_t& vc,
    size_t& ic) {
    for (int t = 0; t < 6; ++t) {
        McVertex p[4];
        float v[4];
        for (int i = 0; i < 4; ++i) {
            const int ci = kTetDecomposition[t][i];
            p[i] = cube_pos[ci];
            v[i] = cube_val[ci];
        }
        polygonise_tetra(p, v, out, max_vertices, vc, ic);
    }
}

struct VertexKey {
    std::int32_t x{0};
    std::int32_t y{0};
    std::int32_t z{0};

    bool operator==(const VertexKey& rhs) const {
        return x == rhs.x && y == rhs.y && z == rhs.z;
    }
};

struct VertexKeyHash {
    std::size_t operator()(const VertexKey& key) const {
        const std::uint64_t x = static_cast<std::uint32_t>(key.x);
        const std::uint64_t y = static_cast<std::uint32_t>(key.y);
        const std::uint64_t z = static_cast<std::uint32_t>(key.z);
        const std::uint64_t h = (x * 73856093ull) ^ (y * 19349669ull) ^ (z * 83492791ull);
        return static_cast<std::size_t>(h);
    }
};

inline VertexKey make_vertex_key(const McVertex& v) {
    const float step = std::max(1e-6f, VERTEX_QUANTIZATION_STEP);
    const float inv = 1.0f / step;
    VertexKey key{};
    key.x = static_cast<std::int32_t>(std::lround(v.x * inv));
    key.y = static_cast<std::int32_t>(std::lround(v.y * inv));
    key.z = static_cast<std::int32_t>(std::lround(v.z * inv));
    return key;
}

void deduplicate_vertices(MarchingCubesResult& out) {
    if (out.vertices == nullptr || out.indices == nullptr || out.vertex_count == 0u || out.index_count == 0u) {
        return;
    }

    std::unordered_map<VertexKey, std::uint32_t, VertexKeyHash> remap_table;
    remap_table.reserve(out.vertex_count);
    std::vector<McVertex> unique_vertices;
    unique_vertices.reserve(out.vertex_count);
    std::vector<std::uint32_t> old_to_new(out.vertex_count, 0u);

    for (std::size_t i = 0u; i < out.vertex_count; ++i) {
        const VertexKey key = make_vertex_key(out.vertices[i]);
        const auto it = remap_table.find(key);
        if (it != remap_table.end()) {
            old_to_new[i] = it->second;
            continue;
        }
        const std::uint32_t new_index = static_cast<std::uint32_t>(unique_vertices.size());
        unique_vertices.push_back(out.vertices[i]);
        remap_table.emplace(key, new_index);
        old_to_new[i] = new_index;
    }

    std::vector<std::uint32_t> remapped_indices(out.index_count, 0u);
    for (std::size_t i = 0u; i < out.index_count; ++i) {
        const std::uint32_t old_idx = out.indices[i];
        if (old_idx >= old_to_new.size()) {
            remapped_indices[i] = 0u;
            continue;
        }
        remapped_indices[i] = old_to_new[old_idx];
    }

    McVertex* compact_vertices = static_cast<McVertex*>(
        std::realloc(out.vertices, unique_vertices.size() * sizeof(McVertex)));
    std::uint32_t* compact_indices = static_cast<std::uint32_t*>(
        std::realloc(out.indices, remapped_indices.size() * sizeof(std::uint32_t)));
    if (compact_vertices == nullptr || compact_indices == nullptr) {
        std::free(compact_vertices);
        std::free(compact_indices);
        std::free(out.vertices);
        std::free(out.indices);
        out.vertices = nullptr;
        out.indices = nullptr;
        out.vertex_count = 0u;
        out.index_count = 0u;
        return;
    }

    out.vertices = compact_vertices;
    out.indices = compact_indices;
    std::memcpy(out.vertices, unique_vertices.data(), unique_vertices.size() * sizeof(McVertex));
    std::memcpy(out.indices, remapped_indices.data(), remapped_indices.size() * sizeof(std::uint32_t));
    out.vertex_count = unique_vertices.size();
    out.index_count = remapped_indices.size();
}

}  // namespace

float quantize_interpolation(float t, float step) {
    return quantize_interpolation_local(t, step);
}

aether::math::Vec3 sdf_gradient_at_corner(
    const float* sdf_grid,
    int dim,
    int gx,
    int gy,
    int gz,
    float voxel_size) {
    if (sdf_grid == nullptr || dim < 2 || voxel_size <= 0.0f) {
        return aether::math::Vec3(0.0f, 1.0f, 0.0f);
    }

    const int x0 = gx - 1;
    const int x1 = gx + 1;
    const int y0 = gy - 1;
    const int y1 = gy + 1;
    const int z0 = gz - 1;
    const int z1 = gz + 1;

    const bool cx = (gx > 0 && gx < dim - 1);
    const bool cy = (gy > 0 && gy < dim - 1);
    const bool cz = (gz > 0 && gz < dim - 1);

    const float inv2h = 0.5f / voxel_size;
    const float invh = 1.0f / voxel_size;

    const float dx = cx
        ? (sample_sdf(sdf_grid, dim, x1, gy, gz) - sample_sdf(sdf_grid, dim, x0, gy, gz)) * inv2h
        : ((gx == 0)
            ? (sample_sdf(sdf_grid, dim, gx + 1, gy, gz) - sample_sdf(sdf_grid, dim, gx, gy, gz)) * invh
            : (sample_sdf(sdf_grid, dim, gx, gy, gz) - sample_sdf(sdf_grid, dim, gx - 1, gy, gz)) * invh);

    const float dy = cy
        ? (sample_sdf(sdf_grid, dim, gx, y1, gz) - sample_sdf(sdf_grid, dim, gx, y0, gz)) * inv2h
        : ((gy == 0)
            ? (sample_sdf(sdf_grid, dim, gx, gy + 1, gz) - sample_sdf(sdf_grid, dim, gx, gy, gz)) * invh
            : (sample_sdf(sdf_grid, dim, gx, gy, gz) - sample_sdf(sdf_grid, dim, gx, gy - 1, gz)) * invh);

    const float dz = cz
        ? (sample_sdf(sdf_grid, dim, gx, gy, z1) - sample_sdf(sdf_grid, dim, gx, gy, z0)) * inv2h
        : ((gz == 0)
            ? (sample_sdf(sdf_grid, dim, gx, gy, gz + 1) - sample_sdf(sdf_grid, dim, gx, gy, gz)) * invh
            : (sample_sdf(sdf_grid, dim, gx, gy, gz) - sample_sdf(sdf_grid, dim, gx, gy, gz - 1)) * invh);

    return aether::math::Vec3(dx, dy, dz);
}

aether::math::Vec3 interpolate_normal(
    const aether::math::Vec3& n0,
    const aether::math::Vec3& n1,
    float t) {
    const float clamped = clamp01(t);
    const aether::math::Vec3 blended(
        n0.x + (n1.x - n0.x) * clamped,
        n0.y + (n1.y - n0.y) * clamped,
        n0.z + (n1.z - n0.z) * clamped);
    return normalize_or_default(blended, aether::math::Vec3(0.0f, 1.0f, 0.0f));
}

aether::math::Vec3 face_normal(const McVertex& a, const McVertex& b, const McVertex& c) {
    const aether::math::Vec3 av = to_vec3(a);
    const aether::math::Vec3 bv = to_vec3(b);
    const aether::math::Vec3 cv = to_vec3(c);
    const aether::math::Vec3 n = cross(bv - av, cv - av);
    return normalize_or_default(n, aether::math::Vec3(0.0f, 1.0f, 0.0f));
}

bool is_degenerate_triangle(const McVertex& v0, const McVertex& v1, const McVertex& v2) {
    const aether::math::Vec3 a = to_vec3(v0);
    const aether::math::Vec3 b = to_vec3(v1);
    const aether::math::Vec3 c = to_vec3(v2);
    const aether::math::Vec3 e0 = b - a;
    const aether::math::Vec3 e1 = c - b;
    const aether::math::Vec3 e2 = a - c;
    const float area = 0.5f * length(cross(e0, c - a));
    if (area < MIN_TRIANGLE_AREA) return true;
    const float l0 = length(e0);
    const float l1 = length(e1);
    const float l2 = length(e2);
    const float max_edge = std::max(l0, std::max(l1, l2));
    const float min_edge = std::max(1e-10f, std::min(l0, std::min(l1, l2)));
    return (max_edge / min_edge) > MAX_TRIANGLE_ASPECT_RATIO;
}

void marching_cubes(const float* sdf_grid, int dim,
                    float origin_x, float origin_y, float origin_z,
                    float voxel_size, MarchingCubesResult& out) {
    std::memset(&out, 0, sizeof(out));
    if (!sdf_grid || dim < 2 || voxel_size <= 0.0f) return;

    const size_t cube_count = static_cast<size_t>(dim - 1) * static_cast<size_t>(dim - 1) * static_cast<size_t>(dim - 1);
    const size_t max_triangles = cube_count * 12;
    const size_t max_vertices = max_triangles * 3;
    out.vertices = static_cast<McVertex*>(std::malloc(max_vertices * sizeof(McVertex)));
    out.indices = static_cast<uint32_t*>(std::malloc(max_vertices * sizeof(uint32_t)));
    if (!out.vertices || !out.indices) {
        std::free(out.vertices);
        std::free(out.indices);
        out.vertices = nullptr;
        out.indices = nullptr;
        return;
    }

    size_t vc = 0;
    size_t ic = 0;
    const int dim2 = dim * dim;
    const int corner_offsets[8][3] = {
        {0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
        {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1},
    };

    for (int z = 0; z < dim - 1; ++z) {
        for (int y = 0; y < dim - 1; ++y) {
            for (int x = 0; x < dim - 1; ++x) {
                McVertex cube_pos[8];
                float cube_val[8];
                int cube_index = 0;
                for (int i = 0; i < 8; ++i) {
                    const int gx = x + corner_offsets[i][0];
                    const int gy = y + corner_offsets[i][1];
                    const int gz = z + corner_offsets[i][2];
                    const int gi = gx + gy * dim + gz * dim2;
                    const float sdf = sdf_grid[gi];
                    cube_val[i] = sdf;
                    cube_pos[i] = McVertex{
                        origin_x + static_cast<float>(gx) * voxel_size,
                        origin_y + static_cast<float>(gy) * voxel_size,
                        origin_z + static_cast<float>(gz) * voxel_size
                    };
                    if (sdf < 0.0f) cube_index |= (1 << i);
                }
                if (cube_index == 0 || cube_index == 255) continue;
                if (kEdgeTable[cube_index] == 0) continue;
                mesh_cube_with_tetra(cube_pos, cube_val, out, max_vertices, vc, ic);
            }
        }
    }

    out.vertex_count = vc;
    out.index_count = ic;
    deduplicate_vertices(out);
}

namespace {

aether::math::Vec3 gradient_from_world_vertex(
    const float* sdf_grid,
    int dim,
    float origin_x,
    float origin_y,
    float origin_z,
    float voxel_size,
    const McVertex& v) {
    const float inv = 1.0f / voxel_size;
    const int gx = clampi(static_cast<int>(std::lround((v.x - origin_x) * inv)), 0, dim - 1);
    const int gy = clampi(static_cast<int>(std::lround((v.y - origin_y) * inv)), 0, dim - 1);
    const int gz = clampi(static_cast<int>(std::lround((v.z - origin_z) * inv)), 0, dim - 1);
    return sdf_gradient_at_corner(sdf_grid, dim, gx, gy, gz, voxel_size);
}

}  // namespace

void extract_incremental_block(
    VoxelBlock& block,
    BlockMeshState* state,
    const BlockIndex& block_index,
    float voxel_size,
    MeshOutput& out,
    size_t triangle_budget,
    std::uint64_t current_frame) {
    if (triangle_budget == 0 || voxel_size <= 0.0f) return;
    if (block.integration_generation < MIN_OBSERVATIONS_BEFORE_MESH) return;
    if (block.integration_generation == block.mesh_generation) return;

    const int dim = BLOCK_SIZE;
    float sdf_grid[BLOCK_SIZE * BLOCK_SIZE * BLOCK_SIZE];
    for (int i = 0; i < BLOCK_SIZE * BLOCK_SIZE * BLOCK_SIZE; ++i) {
        sdf_grid[i] = block.voxels[i].sdf.to_float();
    }

    MarchingCubesResult local{};
    const float origin_x = static_cast<float>(block_index.x) * voxel_size * static_cast<float>(BLOCK_SIZE);
    const float origin_y = static_cast<float>(block_index.y) * voxel_size * static_cast<float>(BLOCK_SIZE);
    const float origin_z = static_cast<float>(block_index.z) * voxel_size * static_cast<float>(BLOCK_SIZE);
    marching_cubes(sdf_grid, dim, origin_x, origin_y, origin_z, voxel_size, local);
    if (local.index_count == 0 || local.vertex_count == 0) {
        std::free(local.vertices);
        std::free(local.indices);
        block.mesh_generation = block.integration_generation;
        return;
    }

    const size_t triangles_generated = local.index_count / 3;
    const size_t triangles_to_copy = std::min(triangles_generated, triangle_budget);
    const size_t vertices_to_copy = local.vertex_count;
    if (triangles_to_copy == 0u || vertices_to_copy == 0u) {
        std::free(local.vertices);
        std::free(local.indices);
        block.mesh_generation = block.integration_generation;
        return;
    }

    MeshVertex* grown_vertices = static_cast<MeshVertex*>(std::realloc(
        out.vertices, (out.vertex_count + vertices_to_copy) * sizeof(MeshVertex)));
    MeshTriangle* grown_triangles = static_cast<MeshTriangle*>(std::realloc(
        out.triangles, (out.triangle_count + triangles_to_copy) * sizeof(MeshTriangle)));
    if (!grown_vertices || !grown_triangles) {
        std::free(grown_vertices);
        std::free(grown_triangles);
        std::free(local.vertices);
        std::free(local.indices);
        return;
    }

    out.vertices = grown_vertices;
    out.triangles = grown_triangles;
    const size_t base = out.vertex_count;

    float alpha = 1.0f;
    if (state != nullptr && !state->is_stable) {
        if (state->first_mesh_frame == 0u) {
            state->first_mesh_frame = static_cast<std::uint32_t>(current_frame);
        }
        const float t = clamp01(state->opacity_progress);
        alpha = t * t * (3.0f - 2.0f * t);
        state->opacity_progress = std::min(
            1.0f,
            state->opacity_progress + 1.0f / static_cast<float>(std::max(1, MESH_FADE_IN_FRAMES)));
        if (state->opacity_progress >= 1.0f) {
            state->is_stable = true;
        }
    }

    std::vector<aether::math::Vec3> face_fallback(vertices_to_copy, aether::math::Vec3(0.0f, 0.0f, 0.0f));
    for (size_t t = 0; t < triangles_to_copy; ++t) {
        const std::uint32_t i0 = local.indices[t * 3 + 0];
        const std::uint32_t i1 = local.indices[t * 3 + 1];
        const std::uint32_t i2 = local.indices[t * 3 + 2];
        if (i0 >= vertices_to_copy || i1 >= vertices_to_copy || i2 >= vertices_to_copy) {
            continue;
        }
        const aether::math::Vec3 n = face_normal(local.vertices[i0], local.vertices[i1], local.vertices[i2]);
        face_fallback[i0] = aether::math::Vec3(
            face_fallback[i0].x + n.x,
            face_fallback[i0].y + n.y,
            face_fallback[i0].z + n.z);
        face_fallback[i1] = aether::math::Vec3(
            face_fallback[i1].x + n.x,
            face_fallback[i1].y + n.y,
            face_fallback[i1].z + n.z);
        face_fallback[i2] = aether::math::Vec3(
            face_fallback[i2].x + n.x,
            face_fallback[i2].y + n.y,
            face_fallback[i2].z + n.z);
    }

    for (size_t i = 0; i < vertices_to_copy; ++i) {
        const McVertex p = local.vertices[i];
        const aether::math::Vec3 g = gradient_from_world_vertex(
            sdf_grid, dim, origin_x, origin_y, origin_z, voxel_size, p);
        const aether::math::Vec3 fallback = normalize_or_default(
            face_fallback[i],
            aether::math::Vec3(0.0f, 1.0f, 0.0f));
        MeshVertex out_v{};
        out_v.position = aether::math::Vec3(p.x, p.y, p.z);
        out_v.normal = normalize_or_default(g, fallback);
        out_v.alpha = alpha;
        out_v.quality = 1.0f;
        out.vertices[base + i] = out_v;
    }

    std::size_t written_triangles = 0u;
    for (size_t t = 0; t < triangles_to_copy; ++t) {
        const std::uint32_t li0 = local.indices[t * 3 + 0];
        const std::uint32_t li1 = local.indices[t * 3 + 1];
        const std::uint32_t li2 = local.indices[t * 3 + 2];
        if (li0 >= vertices_to_copy || li1 >= vertices_to_copy || li2 >= vertices_to_copy) {
            continue;
        }
        const std::uint32_t i0 = static_cast<std::uint32_t>(base + li0);
        const std::uint32_t i1 = static_cast<std::uint32_t>(base + li1);
        const std::uint32_t i2 = static_cast<std::uint32_t>(base + li2);
        out.triangles[out.triangle_count + written_triangles] = MeshTriangle{i0, i1, i2};
        ++written_triangles;
    }
    out.vertex_count += vertices_to_copy;
    out.triangle_count += written_triangles;
    block.mesh_generation = block.integration_generation;

    std::free(local.vertices);
    std::free(local.indices);
}

}  // namespace tsdf
}  // namespace aether
