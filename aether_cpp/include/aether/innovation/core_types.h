// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_CORE_TYPES_H
#define AETHER_INNOVATION_CORE_TYPES_H

#ifdef __cplusplus

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace innovation {

using GaussianId = std::uint32_t;
using ScaffoldUnitId = std::uint64_t;

struct Float3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

inline Float3 make_float3(float x, float y, float z) {
    Float3 out{};
    out.x = x;
    out.y = y;
    out.z = z;
    return out;
}

inline Float3 add(const Float3& a, const Float3& b) {
    return make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

inline Float3 sub(const Float3& a, const Float3& b) {
    return make_float3(a.x - b.x, a.y - b.y, a.z - b.z);
}

inline Float3 mul(const Float3& v, float s) {
    return make_float3(v.x * s, v.y * s, v.z * s);
}

inline float dot(const Float3& a, const Float3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Float3 cross(const Float3& a, const Float3& b) {
    return make_float3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

inline float length_sq(const Float3& v) {
    return dot(v, v);
}

float length(const Float3& v);
Float3 normalize(const Float3& v);

struct Aabb {
    Float3 min{};
    Float3 max{};
    bool valid{false};
};

void expand_aabb(const Float3& p, Aabb& box);
float triangle_area(const Float3& a, const Float3& b, const Float3& c);
Float3 triangle_normal(const Float3& a, const Float3& b, const Float3& c);

struct ScaffoldVertex {
    std::uint32_t id{0};
    Float3 position{};
};

struct ScaffoldUnit {
    ScaffoldUnitId unit_id{0};
    std::uint32_t generation{0};
    std::uint32_t v0{0};
    std::uint32_t v1{0};
    std::uint32_t v2{0};
    float area{0.0f};
    Float3 normal{};
    float confidence{1.0f};
    std::uint32_t view_count{0};
    std::uint8_t lod_level{0};
    std::string patch_id{};
};

struct DisplayFragment {
    ScaffoldUnitId parent_unit_id{0};
    std::uint32_t sub_index{0};
    std::array<Float3, 6> vertices{};
    std::uint8_t vertex_count{0};
    Float3 centroid{};
    Float3 normal{};
    float display{0.0f};
    float gap_shrink{0.0f};
    float crack_seed{0.0f};
};

enum class BindingState : std::uint8_t {
    kFree = 0u,
    kSoft = 1u,
    kHard = 2u,
    kDynamic = 3u,
};

struct GaussianPrimitive {
    GaussianId id{0};
    Float3 position{};
    Float3 scale{1.0f, 1.0f, 1.0f};
    float opacity{1.0f};
    float confidence{1.0f};
    std::array<float, 16> sh_coeffs{};
    ScaffoldUnitId host_unit_id{0};
    std::uint32_t bind_generation{0};
    std::uint16_t observation_count{0};
    std::uint16_t patch_priority{0};
    std::uint32_t capture_sequence{0};
    std::uint64_t first_observed_frame_id{0};
    std::uint64_t frame_last_seen{0};
    std::int64_t first_observed_ms{0};
    std::uint8_t flags{0};
    std::uint8_t lod_level{0};
    BindingState binding_state{BindingState::kFree};
    float uncertainty{0.0f};
    float peak_confidence{0.0f};
    std::string patch_id{};
};

inline bool gaussian_is_dynamic(const GaussianPrimitive& gaussian) {
    return (gaussian.flags & 0x1u) != 0u;
}

inline void set_gaussian_dynamic(GaussianPrimitive& gaussian, bool dynamic) {
    if (dynamic) {
        gaussian.flags = static_cast<std::uint8_t>(gaussian.flags | 0x1u);
        gaussian.binding_state = BindingState::kDynamic;
    } else {
        gaussian.flags = static_cast<std::uint8_t>(gaussian.flags & ~0x1u);
        if (gaussian.binding_state == BindingState::kDynamic) {
            gaussian.binding_state = BindingState::kSoft;
        }
    }
}

inline const char* binding_state_name(BindingState state) {
    switch (state) {
        case BindingState::kFree:
            return "free";
        case BindingState::kSoft:
            return "soft";
        case BindingState::kHard:
            return "hard";
        case BindingState::kDynamic:
            return "dynamic";
    }
    return "free";
}

struct GaussianBuffer {
    std::vector<GaussianPrimitive> primitives{};

    void clear();
    void reserve(std::size_t capacity);
    std::size_t size() const;
    bool empty() const;
    GaussianPrimitive* find_by_id(GaussianId gaussian_id);
    const GaussianPrimitive* find_by_id(GaussianId gaussian_id) const;
    bool upsert(const GaussianPrimitive& gaussian);
    bool erase(GaussianId gaussian_id);
};

struct CameraPose {
    Float3 position{};
    Float3 forward{0.0f, 0.0f, 1.0f};
    Float3 up{0.0f, 1.0f, 0.0f};
};

struct PipelineMetrics {
    float psnr_estimate{0.0f};
    float ssim_estimate{0.0f};
    float coverage_ratio{0.0f};
    float unknown_ratio{1.0f};
    std::size_t active_gaussians{0};
    std::size_t bytes_used{0};
};

std::uint64_t splitmix64(std::uint64_t value);
std::string to_hex_lower(const std::uint8_t* bytes, std::size_t size);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_CORE_TYPES_H
