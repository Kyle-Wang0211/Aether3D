// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/core_types.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace aether {
namespace innovation {

float length(const Float3& v) {
    const float sq = length_sq(v);
    if (sq <= 0.0f) {
        return 0.0f;
    }
    float result = std::sqrt(sq);
    // C01 NumericGuard: protect against NaN from denormalized inputs
    core::guard_finite_scalar(&result);
    return result;
}

Float3 normalize(const Float3& v) {
    const float len = length(v);
    if (len <= 1e-12f) {
        return make_float3(0.0f, 0.0f, 0.0f);
    }
    const float inv = 1.0f / len;
    return make_float3(v.x * inv, v.y * inv, v.z * inv);
}

void expand_aabb(const Float3& p, Aabb& box) {
    if (!box.valid) {
        box.min = p;
        box.max = p;
        box.valid = true;
        return;
    }
    box.min.x = std::min(box.min.x, p.x);
    box.min.y = std::min(box.min.y, p.y);
    box.min.z = std::min(box.min.z, p.z);
    box.max.x = std::max(box.max.x, p.x);
    box.max.y = std::max(box.max.y, p.y);
    box.max.z = std::max(box.max.z, p.z);
}

float triangle_area(const Float3& a, const Float3& b, const Float3& c) {
    const Float3 ab = sub(b, a);
    const Float3 ac = sub(c, a);
    const Float3 cr = cross(ab, ac);
    float area = 0.5f * length(cr);
    core::guard_finite_scalar(&area);
    return area;
}

Float3 triangle_normal(const Float3& a, const Float3& b, const Float3& c) {
    const Float3 ab = sub(b, a);
    const Float3 ac = sub(c, a);
    const Float3 cr = cross(ab, ac);
    return normalize(cr);
}

std::uint64_t splitmix64(std::uint64_t value) {
    value += 0x9e3779b97f4a7c15ULL;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
    return value ^ (value >> 31);
}

std::string to_hex_lower(const std::uint8_t* bytes, std::size_t size) {
    static const char hex_chars[] = "0123456789abcdef";
    std::string result;
    result.reserve(size * 2);
    for (std::size_t i = 0; i < size; ++i) {
        result.push_back(hex_chars[(bytes[i] >> 4) & 0x0F]);
        result.push_back(hex_chars[bytes[i] & 0x0F]);
    }
    return result;
}

// GaussianBuffer methods

void GaussianBuffer::clear() {
    primitives.clear();
}

void GaussianBuffer::reserve(std::size_t capacity) {
    primitives.reserve(capacity);
}

std::size_t GaussianBuffer::size() const {
    return primitives.size();
}

bool GaussianBuffer::empty() const {
    return primitives.empty();
}

GaussianPrimitive* GaussianBuffer::find_by_id(GaussianId gaussian_id) {
    for (auto& g : primitives) {
        if (g.id == gaussian_id) {
            return &g;
        }
    }
    return nullptr;
}

const GaussianPrimitive* GaussianBuffer::find_by_id(GaussianId gaussian_id) const {
    for (const auto& g : primitives) {
        if (g.id == gaussian_id) {
            return &g;
        }
    }
    return nullptr;
}

bool GaussianBuffer::upsert(const GaussianPrimitive& gaussian) {
    GaussianPrimitive* existing = find_by_id(gaussian.id);
    if (existing != nullptr) {
        *existing = gaussian;
        return false;  // updated existing
    }
    primitives.push_back(gaussian);
    return true;  // inserted new
}

bool GaussianBuffer::erase(GaussianId gaussian_id) {
    for (auto it = primitives.begin(); it != primitives.end(); ++it) {
        if (it->id == gaussian_id) {
            primitives.erase(it);
            return true;
        }
    }
    return false;
}

}  // namespace innovation
}  // namespace aether
