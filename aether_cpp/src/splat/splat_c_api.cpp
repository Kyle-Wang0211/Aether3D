// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/aether_splat_c.h"

#include "aether/render/gpu_device.h"
#include "aether/render/metal_gpu_device.h"    // wrap_metal_command_buffer
#include "aether/splat/packed_splats.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/splat/ply_loader.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

constexpr int kAxisNeighborOffsets[6][3] = {
    { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 },
    { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 }
};

struct SubjectVoxelKey {
    int x;
    int y;
    int z;

    bool operator==(const SubjectVoxelKey& other) const noexcept {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct SubjectVoxelKeyHash {
    std::size_t operator()(const SubjectVoxelKey& key) const noexcept {
        std::size_t seed = 1469598103934665603ull;
        auto mix = [&](std::uint64_t value) {
            seed ^= value + 0x9e3779b97f4a7c15ull + (seed << 6) + (seed >> 2);
        };
        mix(static_cast<std::uint64_t>(static_cast<std::int64_t>(key.x)));
        mix(static_cast<std::uint64_t>(static_cast<std::int64_t>(key.y)));
        mix(static_cast<std::uint64_t>(static_cast<std::int64_t>(key.z)));
        return seed;
    }
};

struct SubjectBounds {
    float min_x{std::numeric_limits<float>::max()};
    float min_y{std::numeric_limits<float>::max()};
    float min_z{std::numeric_limits<float>::max()};
    float max_x{-std::numeric_limits<float>::max()};
    float max_y{-std::numeric_limits<float>::max()};
    float max_z{-std::numeric_limits<float>::max()};
};

enum class SubjectMaskStage : std::uint8_t {
    kReject = 0,
    kCore = 1,
    kBoundary = 2,
    kSupport = 3
};

struct SubjectMaskSignal {
    SubjectMaskStage stage{SubjectMaskStage::kReject};
    float component_score{0.0f};
    float boundary_score{0.0f};
    float support_score{0.0f};
};

inline float average_scale(const aether::splat::GaussianParams& g) noexcept {
    return (g.scale[0] + g.scale[1] + g.scale[2]) / 3.0f;
}

inline float max_scale(const aether::splat::GaussianParams& g) noexcept {
    return std::max(g.scale[0], std::max(g.scale[1], g.scale[2]));
}

inline float clamp01(float value) noexcept {
    return std::max(0.0f, std::min(1.0f, value));
}

inline SubjectVoxelKey make_voxel_key(
    const aether::splat::GaussianParams& g,
    float voxel_size
) noexcept {
    const float inv = voxel_size > 1e-6f ? 1.0f / voxel_size : 1.0f;
    return SubjectVoxelKey{
        static_cast<int>(std::floor(g.position[0] * inv)),
        static_cast<int>(std::floor(g.position[1] * inv)),
        static_cast<int>(std::floor(g.position[2] * inv))
    };
}

inline void expand_bounds(
    SubjectBounds& bounds,
    const aether::splat::GaussianParams& g
) noexcept {
    bounds.min_x = std::min(bounds.min_x, g.position[0]);
    bounds.min_y = std::min(bounds.min_y, g.position[1]);
    bounds.min_z = std::min(bounds.min_z, g.position[2]);
    bounds.max_x = std::max(bounds.max_x, g.position[0]);
    bounds.max_y = std::max(bounds.max_y, g.position[1]);
    bounds.max_z = std::max(bounds.max_z, g.position[2]);
}

inline bool is_finite_bounds(const SubjectBounds& bounds) noexcept {
    return std::isfinite(bounds.min_x) && std::isfinite(bounds.min_y) &&
        std::isfinite(bounds.min_z) && std::isfinite(bounds.max_x) &&
        std::isfinite(bounds.max_y) && std::isfinite(bounds.max_z);
}

inline float component_span(const SubjectBounds& bounds) noexcept {
    if (!is_finite_bounds(bounds)) return 0.0f;
    const float dx = std::max(0.0f, bounds.max_x - bounds.min_x);
    const float dy = std::max(0.0f, bounds.max_y - bounds.min_y);
    const float dz = std::max(0.0f, bounds.max_z - bounds.min_z);
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

inline bool is_candidate_for_subject_component(
    const aether::splat::GaussianParams& g,
    float scene_span
) noexcept {
    const float avg = average_scale(g);
    const float max_allowed_scale = std::max(0.12f, scene_span * 0.18f);
    return g.opacity >= 0.025f && avg > 1e-5f && avg <= max_allowed_scale;
}

inline int axis_neighbor_count(
    const std::unordered_set<SubjectVoxelKey, SubjectVoxelKeyHash>& voxels,
    const SubjectVoxelKey& key
) noexcept {
    int count = 0;
    for (const auto& offset : kAxisNeighborOffsets) {
        SubjectVoxelKey next{
            key.x + offset[0],
            key.y + offset[1],
            key.z + offset[2]
        };
        if (voxels.find(next) != voxels.end()) {
            ++count;
        }
    }
    return count;
}

inline std::array<float, 3> rotate_by_quaternion(
    const std::array<float, 3>& v,
    const float q[4]
) noexcept {
    const float w = q[0];
    const float x = q[1];
    const float y = q[2];
    const float z = q[3];
    const float q_norm = std::sqrt(w * w + x * x + y * y + z * z);
    if (!(q_norm > 1e-6f)) {
        return v;
    }

    const float inv = 1.0f / q_norm;
    const float qw = w * inv;
    const float qx = x * inv;
    const float qy = y * inv;
    const float qz = z * inv;

    const std::array<float, 3> u{qx, qy, qz};
    const float s = qw;

    const std::array<float, 3> uv{
        u[1] * v[2] - u[2] * v[1],
        u[2] * v[0] - u[0] * v[2],
        u[0] * v[1] - u[1] * v[0]
    };
    const std::array<float, 3> uuv{
        u[1] * uv[2] - u[2] * uv[1],
        u[2] * uv[0] - u[0] * uv[2],
        u[0] * uv[1] - u[1] * uv[0]
    };

    return std::array<float, 3>{
        v[0] + 2.0f * (s * uv[0] + uuv[0]),
        v[1] + 2.0f * (s * uv[1] + uuv[1]),
        v[2] + 2.0f * (s * uv[2] + uuv[2])
    };
}

inline std::array<float, 3> major_axis_direction(
    const aether::splat::GaussianParams& g
) noexcept {
    int axis = 0;
    if (g.scale[1] > g.scale[axis]) axis = 1;
    if (g.scale[2] > g.scale[axis]) axis = 2;

    std::array<float, 3> local_axis{0.0f, 0.0f, 0.0f};
    local_axis[axis] = 1.0f;
    return rotate_by_quaternion(local_axis, g.rotation);
}

inline std::vector<aether::splat::GaussianParams> split_boundary_gaussian(
    const aether::splat::GaussianParams& gaussian,
    float offset_scale,
    float opacity_scale
) {
    std::vector<aether::splat::GaussianParams> outputs;
    outputs.reserve(2);

    const std::array<float, 3> axis = major_axis_direction(gaussian);
    const float major = std::max({gaussian.scale[0], gaussian.scale[1], gaussian.scale[2], 1e-4f});
    const float offset = major * offset_scale;

    aether::splat::GaussianParams a = gaussian;
    aether::splat::GaussianParams b = gaussian;

    int major_axis = 0;
    if (gaussian.scale[1] > gaussian.scale[major_axis]) major_axis = 1;
    if (gaussian.scale[2] > gaussian.scale[major_axis]) major_axis = 2;

    for (int i = 0; i < 3; ++i) {
        a.position[i] -= axis[i] * offset;
        b.position[i] += axis[i] * offset;
        a.scale[i] = std::max(1e-5f, gaussian.scale[i] * (i == major_axis ? 0.58f : 0.88f));
        b.scale[i] = std::max(1e-5f, gaussian.scale[i] * (i == major_axis ? 0.58f : 0.88f));
    }
    a.opacity = clamp01(gaussian.opacity * opacity_scale);
    b.opacity = clamp01(gaussian.opacity * opacity_scale);

    outputs.push_back(a);
    outputs.push_back(b);
    return outputs;
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// Opaque wrappers
// ═══════════════════════════════════════════════════════════════════════

// Must match layout in metal_c_api.mm (single-pointer wrapper).
struct aether_gpu_device {
    aether::render::GPUDevice* impl;
};

struct aether_splat_engine {
    aether::splat::SplatRenderEngine* impl;
    aether::render::GPUDevice* device;  // Stored for wrapping MTLCommandBuffer→GPUCommandBuffer
};

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle
// ═══════════════════════════════════════════════════════════════════════

extern "C" {

int aether_splat_default_config(aether_splat_config_t* out_config) {
    if (!out_config) return -1;
    out_config->max_splats = 500000;
    // Match the full float depth key width so we do not collapse far/near
    // splats into the same truncated radix buckets once GPU sort is re-enabled.
    out_config->sort_precision_bits = 32;
    out_config->max_screen_radius = 1024.0f;
    out_config->triple_buffer_count = 3;
    return 0;
}

int aether_splat_engine_create(void* gpu_device_ptr,
                                const aether_splat_config_t* config,
                                aether_splat_engine_t** out_engine) {
    if (!gpu_device_ptr || !config || !out_engine) return -1;

    // gpu_device_ptr is aether_gpu_device_t* (wrapper), extract the impl.
    auto* device_wrapper = static_cast<aether_gpu_device*>(gpu_device_ptr);
    auto* device = device_wrapper->impl;
    if (!device) return -1;

    aether::splat::SplatRenderConfig cpp_config;
    cpp_config.max_splats = config->max_splats;
    cpp_config.sort_precision_bits = config->sort_precision_bits;
    cpp_config.max_screen_radius = config->max_screen_radius;
    cpp_config.triple_buffer_count = config->triple_buffer_count;

    auto* engine = new (std::nothrow) aether_splat_engine();
    if (!engine) return -3;

    engine->impl = new (std::nothrow) aether::splat::SplatRenderEngine(
        *device, cpp_config);
    if (!engine->impl) {
        delete engine;
        return -3;
    }
    engine->device = device;  // Store for MTLCommandBuffer → GPUCommandBuffer wrapping

    *out_engine = engine;
    return 0;
}

void aether_splat_engine_destroy(aether_splat_engine_t* engine) {
    if (!engine) return;
    delete engine->impl;
    delete engine;
}

// ═══════════════════════════════════════════════════════════════════════
// Data Loading
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_load_ply(aether_splat_engine_t* engine, const char* path) {
    if (!engine || !engine->impl || !path) return -1;
    auto status = engine->impl->load_from_ply(path);
    return aether::core::is_ok(status) ? 0 : -1;
}

int aether_splat_load_spz(aether_splat_engine_t* engine,
                           const uint8_t* data, size_t size) {
    if (!engine || !engine->impl || !data || size == 0) return -1;
    auto status = engine->impl->load_from_spz(data, size);
    return aether::core::is_ok(status) ? 0 : -1;
}

int aether_splat_load_gaussians(aether_splat_engine_t* engine,
                                 const aether_gaussian_params_t* params,
                                 size_t count) {
    if (!engine || !engine->impl || !params || count == 0) return -1;

    // aether_gaussian_params_t and aether::splat::GaussianParams have
    // identical memory layout (92 bytes, same field order including SH coefficients).
    static_assert(sizeof(aether_gaussian_params_t) ==
                  sizeof(aether::splat::GaussianParams),
                  "C and C++ Gaussian structs must match");

    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    auto status = engine->impl->load_gaussians(cpp_params, count);
    return aether::core::is_ok(status) ? 0 : -1;
}

// ═══════════════════════════════════════════════════════════════════════
// Incremental Update
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_push(aether_splat_engine_t* engine,
                       const aether_gaussian_params_t* params,
                       size_t count) {
    if (!engine || !engine->impl || !params || count == 0) return -1;
    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    engine->impl->push_splats(cpp_params, count);
    return 0;
}

int aether_splat_push_with_regions(aether_splat_engine_t* engine,
                                    const aether_gaussian_params_t* params,
                                    const uint8_t* region_ids,
                                    size_t count) {
    if (!engine || !engine->impl || !params || !region_ids || count == 0) return -1;
    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    engine->impl->push_splats_with_regions(cpp_params, region_ids, count);
    return 0;
}

void aether_splat_set_region_fade_alphas(aether_splat_engine_t* engine,
                                          const float* fade_alphas,
                                          size_t count) {
    if (!engine || !engine->impl || !fade_alphas || count == 0) return;
    engine->impl->set_region_fade_alphas(fade_alphas, count);
}

void aether_splat_clear(aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return;
    engine->impl->clear_splats();
}

// ═══════════════════════════════════════════════════════════════════════
// Per-Frame Rendering
// ═══════════════════════════════════════════════════════════════════════

void aether_splat_begin_frame(aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return;
    engine->impl->begin_frame();
}

void aether_splat_update_camera(aether_splat_engine_t* engine,
                                 const aether_splat_camera_t* camera) {
    if (!engine || !engine->impl || !camera) return;

    aether::splat::SplatCameraState state;
    std::memcpy(state.view, camera->view, sizeof(state.view));
    std::memcpy(state.proj, camera->proj, sizeof(state.proj));
    state.fx = camera->fx;
    state.fy = camera->fy;
    state.cx = camera->cx;
    state.cy = camera->cy;
    state.vp_width = camera->vp_width;
    state.vp_height = camera->vp_height;
    state.render_splat_limit = camera->render_splat_limit;

    engine->impl->update_camera(state);
}

void aether_splat_encode_sort(aether_splat_engine_t* engine,
                               void* cmd_buffer_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr) return;

    // cmd_buffer_ptr is an MTLCommandBuffer* from Swift (via Unmanaged.passUnretained.toOpaque).
    // We MUST wrap it in a MetalCommandBuffer adapter for C++ virtual dispatch.
    // Previous code did static_cast<GPUCommandBuffer*> which is WRONG — MTLCommandBuffer is
    // an ObjC object, not a C++ class with vtable. This caused EXC_BAD_ACCESS.
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;
    engine->impl->encode_sort_pass(*cmd);
}

void aether_splat_encode_render(aether_splat_engine_t* engine,
                                 void* cmd_buffer_ptr,
                                 void* render_target_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr || !render_target_ptr) return;

    // Same wrapping as encode_sort — MTLCommandBuffer* → MetalCommandBuffer adapter.
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;
    auto* target = static_cast<aether::render::GPURenderTargetDesc*>(render_target_ptr);
    engine->impl->encode_render_pass(*cmd, *target);
}

void aether_splat_encode_render_native(aether_splat_engine_t* engine,
                                        void* cmd_buffer_ptr,
                                        void* render_pass_desc_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr || !render_pass_desc_ptr) return;

    // MTLCommandBuffer* → MetalCommandBuffer adapter (same as encode_sort).
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;

    // render_pass_desc_ptr is an MTLRenderPassDescriptor* from Swift.
    // Pass it through to the native render encoder — renders directly into the drawable.
    engine->impl->encode_render_pass_native(*cmd, render_pass_desc_ptr);
}

void aether_splat_end_frame(aether_splat_engine_t* engine,
                             aether_splat_stats_t* out_stats) {
    if (!engine || !engine->impl) return;
    auto stats = engine->impl->end_frame();
    if (out_stats) {
        out_stats->total_splats = stats.total_splats;
        out_stats->visible_splats = stats.visible_splats;
        out_stats->sort_mode = stats.sort_mode;
        out_stats->sort_time_ms = stats.sort_time_ms;
        out_stats->render_time_ms = stats.render_time_ms;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════

size_t aether_splat_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->splat_count();
}

int aether_splat_is_initialized(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->is_initialized() ? 1 : 0;
}

int aether_splat_get_bounds(const aether_splat_engine_t* engine,
                             float center[3], float* radius) {
    if (!engine || !engine->impl || !center || !radius) return -1;
    return engine->impl->get_bounds(center, radius) ? 0 : -1;
}

const void* aether_splat_get_packed_data(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return nullptr;
    const auto& buf = engine->impl->packed_data();
    return buf.empty() ? nullptr : static_cast<const void*>(buf.data());
}

size_t aether_splat_get_packed_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->packed_data().size();
}

const void* aether_splat_get_sh_data(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return nullptr;
    const auto& buf = engine->impl->sh_data();
    return buf.empty() ? nullptr : static_cast<const void*>(buf.data());
}

size_t aether_splat_get_sh_float_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->sh_data().size();
}

// ═══════════════════════════════════════════════════════════════════════
// Utility
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_ply_vertex_count(const char* path, size_t* out_count) {
    if (!path || !out_count) return -1;
    aether::splat::PlyLoadResult result;
    auto status = aether::splat::load_ply(path, result);
    if (!aether::core::is_ok(status)) return -1;
    *out_count = result.vertex_count;
    return 0;
}

int aether_splat_subject_cleanup_ply(const char* input_path,
                                      const char* output_path,
                                      aether_subject_cleanup_stats_t* out_stats) {
    if (!input_path || !output_path) return -1;

    aether::splat::PlyLoadResult result;
    auto status = aether::splat::load_ply(input_path, result);
    if (!aether::core::is_ok(status)) return -1;
    if (result.gaussians.empty()) return -1;

    aether_subject_cleanup_stats_t stats{};
    stats.input_splats = result.gaussians.size();

    SubjectBounds scene_bounds;
    for (const auto& gaussian : result.gaussians) {
        expand_bounds(scene_bounds, gaussian);
    }
    const float scene_span = std::max(component_span(scene_bounds), 0.10f);
    const float voxel_size = std::max(0.03f, scene_span / 42.0f);

    std::unordered_map<SubjectVoxelKey, std::size_t, SubjectVoxelKeyHash> voxel_counts;
    voxel_counts.reserve(result.gaussians.size());
    for (const auto& gaussian : result.gaussians) {
        if (!is_candidate_for_subject_component(gaussian, scene_span)) {
            continue;
        }
        ++voxel_counts[make_voxel_key(gaussian, voxel_size)];
    }

    if (voxel_counts.empty()) {
        const auto write_status = aether::splat::write_ply(
            output_path,
            result.gaussians.data(),
            result.gaussians.size()
        );
        if (!aether::core::is_ok(write_status)) return -1;
        stats.mask_seed_kept_splats = result.gaussians.size();
        stats.boundary_refined_splats = result.gaussians.size();
        stats.boundary_split_splats = 0;
        stats.cutout_kept_splats = result.gaussians.size();
        stats.cleanup_kept_splats = result.gaussians.size();
        stats.cleanup_removed_splats = 0;
        if (out_stats) *out_stats = stats;
        return 0;
    }

    std::unordered_set<SubjectVoxelKey, SubjectVoxelKeyHash> visited;
    visited.reserve(voxel_counts.size());
    std::unordered_set<SubjectVoxelKey, SubjectVoxelKeyHash> dominant_component;
    dominant_component.reserve(voxel_counts.size());
    std::size_t dominant_score = 0;

    for (const auto& entry : voxel_counts) {
        const SubjectVoxelKey& start_key = entry.first;
        if (visited.find(start_key) != visited.end()) {
            continue;
        }
        std::queue<SubjectVoxelKey> queue;
        std::vector<SubjectVoxelKey> component;
        std::size_t component_score = 0;
        queue.push(start_key);
        visited.insert(start_key);

        while (!queue.empty()) {
            const SubjectVoxelKey key = queue.front();
            queue.pop();
            component.push_back(key);
            component_score += voxel_counts[key];

            for (const auto& offset : kAxisNeighborOffsets) {
                SubjectVoxelKey next{
                    key.x + offset[0],
                    key.y + offset[1],
                    key.z + offset[2]
                };
                if (voxel_counts.find(next) == voxel_counts.end()) {
                    continue;
                }
                if (visited.insert(next).second) {
                    queue.push(next);
                }
            }
        }

        if (component_score > dominant_score) {
            dominant_score = component_score;
            dominant_component.clear();
            for (const auto& key : component) {
                dominant_component.insert(key);
            }
        }
    }

    if (dominant_component.empty()) {
        dominant_component.reserve(voxel_counts.size());
        for (const auto& entry : voxel_counts) {
            dominant_component.insert(entry.first);
        }
    }

    std::unordered_set<SubjectVoxelKey, SubjectVoxelKeyHash> dominant_shell;
    dominant_shell.reserve(dominant_component.size());
    for (const auto& key : dominant_component) {
        const int face_neighbors = axis_neighbor_count(dominant_component, key);
        const std::size_t local_density = voxel_counts[key];
        if (face_neighbors < 6 || local_density <= 2) {
            dominant_shell.insert(key);
        }
    }

    SubjectBounds dominant_bounds;
    for (const auto& gaussian : result.gaussians) {
        const auto key = make_voxel_key(gaussian, voxel_size);
        if (dominant_component.find(key) != dominant_component.end()) {
            expand_bounds(dominant_bounds, gaussian);
        }
    }
    if (!is_finite_bounds(dominant_bounds)) {
        dominant_bounds = scene_bounds;
    }

    const float dominant_span_x = std::max(0.05f, dominant_bounds.max_x - dominant_bounds.min_x);
    const float dominant_span_y = std::max(0.05f, dominant_bounds.max_y - dominant_bounds.min_y);
    const float dominant_span_z = std::max(0.05f, dominant_bounds.max_z - dominant_bounds.min_z);
    const float footprint_margin = std::max(0.05f, std::max(dominant_span_x, dominant_span_z) * 0.10f);
    const float bottom_band_height = std::max(0.03f, dominant_span_y * 0.12f);
    const float bottom_band_limit = dominant_bounds.min_y + bottom_band_height;
    const float shell_margin = std::max(voxel_size * 1.8f, std::max(dominant_span_x, dominant_span_z) * 0.04f);
    const float shell_y_margin = std::max(voxel_size * 1.5f, dominant_span_y * 0.08f);
    const float boundary_split_threshold = std::max(voxel_size * 1.4f, std::max(dominant_span_x, dominant_span_z) * 0.035f);
    const float boundary_soft_threshold = std::max(voxel_size * 1.1f, std::max(dominant_span_x, dominant_span_z) * 0.022f);

    auto in_support_band = [&](const aether::splat::GaussianParams& gaussian) -> bool {
        return gaussian.position[0] >= dominant_bounds.min_x - footprint_margin &&
            gaussian.position[0] <= dominant_bounds.max_x + footprint_margin &&
            gaussian.position[2] >= dominant_bounds.min_z - footprint_margin &&
            gaussian.position[2] <= dominant_bounds.max_z + footprint_margin &&
            gaussian.position[1] <= bottom_band_limit;
    };

    auto near_shell_band = [&](const aether::splat::GaussianParams& gaussian) -> bool {
        if (gaussian.position[0] < dominant_bounds.min_x - shell_margin ||
            gaussian.position[0] > dominant_bounds.max_x + shell_margin ||
            gaussian.position[2] < dominant_bounds.min_z - shell_margin ||
            gaussian.position[2] > dominant_bounds.max_z + shell_margin ||
            gaussian.position[1] < dominant_bounds.min_y - bottom_band_height ||
            gaussian.position[1] > dominant_bounds.max_y + shell_y_margin) {
            return false;
        }

        const auto key = make_voxel_key(gaussian, voxel_size);
        if (dominant_shell.find(key) != dominant_shell.end()) {
            return true;
        }
        for (int dx = -1; dx <= 1; ++dx) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dz = -1; dz <= 1; ++dz) {
                    if (dx == 0 && dy == 0 && dz == 0) continue;
                    SubjectVoxelKey next{ key.x + dx, key.y + dy, key.z + dz };
                    if (dominant_shell.find(next) != dominant_shell.end()) {
                        return true;
                    }
                }
            }
        }
        return false;
    };

    std::vector<aether::splat::GaussianParams> mask_seed_gaussians;
    mask_seed_gaussians.reserve(result.gaussians.size());
    std::vector<SubjectMaskSignal> mask_seed_signals;
    mask_seed_signals.reserve(result.gaussians.size());

    for (const auto& gaussian : result.gaussians) {
        const auto key = make_voxel_key(gaussian, voxel_size);
        const bool in_dominant = dominant_component.find(key) != dominant_component.end();
        const bool support_candidate = in_support_band(gaussian) && gaussian.opacity >= 0.02f;
        const bool boundary_candidate =
            near_shell_band(gaussian) &&
            gaussian.opacity >= 0.018f &&
            average_scale(gaussian) >= 1e-5f &&
            max_scale(gaussian) <= std::max(0.10f, scene_span * 0.12f);

        SubjectMaskSignal signal{};
        signal.component_score = in_dominant ? 1.0f : 0.0f;
        signal.support_score = support_candidate ? clamp01(0.55f + gaussian.opacity * 0.45f) : 0.0f;
        signal.boundary_score = boundary_candidate
            ? clamp01(0.45f + gaussian.opacity * 0.40f +
                      std::max(0.0f, 1.0f - max_scale(gaussian) / std::max(boundary_split_threshold, 1e-4f)) * 0.15f)
            : 0.0f;

        if (in_dominant) {
            signal.stage = SubjectMaskStage::kCore;
        } else if (boundary_candidate && signal.boundary_score >= signal.support_score) {
            signal.stage = SubjectMaskStage::kBoundary;
        } else if (support_candidate) {
            signal.stage = SubjectMaskStage::kSupport;
        } else {
            signal.stage = SubjectMaskStage::kReject;
        }

        if (signal.stage == SubjectMaskStage::kReject) {
            continue;
        }
        mask_seed_gaussians.push_back(gaussian);
        mask_seed_signals.push_back(signal);
    }

    if (mask_seed_gaussians.empty()) {
        const auto write_status = aether::splat::write_ply(
            output_path,
            result.gaussians.data(),
            result.gaussians.size()
        );
        if (!aether::core::is_ok(write_status)) return -1;
        stats.mask_seed_kept_splats = 0;
        stats.boundary_refined_splats = 0;
        stats.boundary_split_splats = 0;
        stats.cutout_kept_splats = result.gaussians.size();
        stats.cleanup_kept_splats = result.gaussians.size();
        stats.cleanup_removed_splats = 0;
        if (out_stats) *out_stats = stats;
        return 0;
    }

    stats.mask_seed_kept_splats = mask_seed_gaussians.size();

    std::vector<aether::splat::GaussianParams> boundary_refined_gaussians;
    boundary_refined_gaussians.reserve(mask_seed_gaussians.size());
    std::vector<SubjectMaskSignal> boundary_refined_signals;
    boundary_refined_signals.reserve(mask_seed_signals.size());

    std::size_t boundary_refined_outputs = 0;
    std::size_t boundary_split_extra = 0;

    for (std::size_t i = 0; i < mask_seed_gaussians.size(); ++i) {
        const auto& gaussian = mask_seed_gaussians[i];
        const auto& signal = mask_seed_signals[i];
        if (signal.stage != SubjectMaskStage::kBoundary) {
            boundary_refined_gaussians.push_back(gaussian);
            boundary_refined_signals.push_back(signal);
            continue;
        }

        const float largest_scale = max_scale(gaussian);
        if (largest_scale >= boundary_split_threshold && gaussian.opacity >= 0.028f) {
            auto split = split_boundary_gaussian(gaussian, 0.34f, 0.56f);
            boundary_refined_outputs += split.size();
            if (split.size() > 1) {
                boundary_split_extra += split.size() - 1;
            }
            for (const auto& child : split) {
                boundary_refined_gaussians.push_back(child);
                boundary_refined_signals.push_back(signal);
            }
            continue;
        }

        aether::splat::GaussianParams refined = gaussian;
        if (largest_scale >= boundary_soft_threshold) {
            int major_axis = 0;
            if (refined.scale[1] > refined.scale[major_axis]) major_axis = 1;
            if (refined.scale[2] > refined.scale[major_axis]) major_axis = 2;
            for (int axis = 0; axis < 3; ++axis) {
                refined.scale[axis] = std::max(
                    1e-5f,
                    refined.scale[axis] * (axis == major_axis ? 0.78f : 0.92f)
                );
            }
            refined.opacity = clamp01(refined.opacity * 0.92f);
        }
        ++boundary_refined_outputs;
        boundary_refined_gaussians.push_back(refined);
        boundary_refined_signals.push_back(signal);
    }

    stats.boundary_refined_splats = boundary_refined_outputs;
    stats.boundary_split_splats = boundary_split_extra;
    stats.cutout_kept_splats = boundary_refined_gaussians.size();

    std::unordered_map<SubjectVoxelKey, std::size_t, SubjectVoxelKeyHash> cutout_voxel_counts;
    cutout_voxel_counts.reserve(boundary_refined_gaussians.size());
    for (const auto& gaussian : boundary_refined_gaussians) {
        ++cutout_voxel_counts[make_voxel_key(gaussian, voxel_size)];
    }

    std::vector<aether::splat::GaussianParams> cleaned_gaussians;
    cleaned_gaussians.reserve(boundary_refined_gaussians.size());

    auto neighbor_weight = [&](const SubjectVoxelKey& key) -> std::size_t {
        std::size_t total = 0;
        for (int dx = -1; dx <= 1; ++dx) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dz = -1; dz <= 1; ++dz) {
                    if (dx == 0 && dy == 0 && dz == 0) continue;
                    SubjectVoxelKey next{ key.x + dx, key.y + dy, key.z + dz };
                    auto it = cutout_voxel_counts.find(next);
                    if (it != cutout_voxel_counts.end()) {
                        total += it->second;
                    }
                }
            }
        }
        return total;
    };

    const float extreme_scale = std::max(0.10f, scene_span * 0.12f);
    const float loose_margin = footprint_margin * 1.8f;

    for (std::size_t i = 0; i < boundary_refined_gaussians.size(); ++i) {
        const auto& gaussian = boundary_refined_gaussians[i];
        const auto& signal = boundary_refined_signals[i];
        const auto key = make_voxel_key(gaussian, voxel_size);
        const bool preserve_core = signal.stage == SubjectMaskStage::kCore;
        const bool preserve_support = signal.stage == SubjectMaskStage::kSupport;
        if (preserve_core || preserve_support) {
            cleaned_gaussians.push_back(gaussian);
            continue;
        }

        const std::size_t local_count = cutout_voxel_counts[key];
        const std::size_t nearby_count = neighbor_weight(key);
        const bool isolated = local_count <= 1 && nearby_count <= 2;
        const bool too_faint = gaussian.opacity < 0.035f;
        const bool too_large = max_scale(gaussian) > extreme_scale;
        const bool far_outside_footprint =
            gaussian.position[0] < dominant_bounds.min_x - loose_margin ||
            gaussian.position[0] > dominant_bounds.max_x + loose_margin ||
            gaussian.position[2] < dominant_bounds.min_z - loose_margin ||
            gaussian.position[2] > dominant_bounds.max_z + loose_margin;
        const bool likely_contact_bridge =
            !far_outside_footprint &&
            gaussian.position[1] <= bottom_band_limit + bottom_band_height * 0.9f &&
            nearby_count >= 1 &&
            gaussian.opacity >= 0.02f;
        const bool boundary_consistent =
            signal.boundary_score >= 0.45f &&
            nearby_count >= 1 &&
            gaussian.opacity >= 0.018f;

        if (isolated && (too_faint || too_large || far_outside_footprint) &&
            !likely_contact_bridge && !boundary_consistent) {
            continue;
        }

        cleaned_gaussians.push_back(gaussian);
    }

    if (cleaned_gaussians.empty()) {
        cleaned_gaussians = boundary_refined_gaussians;
    }

    stats.cleanup_kept_splats = cleaned_gaussians.size();
    stats.cleanup_removed_splats =
        stats.cutout_kept_splats > stats.cleanup_kept_splats
            ? stats.cutout_kept_splats - stats.cleanup_kept_splats
            : 0;

    const auto write_status = aether::splat::write_ply(
        output_path,
        cleaned_gaussians.data(),
        cleaned_gaussians.size()
    );
    if (!aether::core::is_ok(write_status)) return -1;
    if (out_stats) {
        *out_stats = stats;
    }
    return 0;
}

void aether_splat_pack(const aether_gaussian_params_t* params,
                        uint8_t out_packed[16]) {
    if (!params || !out_packed) return;
    auto* cpp = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    aether::splat::PackedSplat packed = aether::splat::pack_gaussian(*cpp);
    std::memcpy(out_packed, &packed, 16);
}

void aether_splat_unpack(const uint8_t packed[16],
                          aether_gaussian_params_t* out_params) {
    if (!packed || !out_params) return;
    aether::splat::PackedSplat ps;
    std::memcpy(&ps, packed, 16);
    aether::splat::GaussianParams result = aether::splat::unpack_gaussian(ps);
    std::memcpy(out_params, &result, sizeof(result));
}

}  // extern "C"
