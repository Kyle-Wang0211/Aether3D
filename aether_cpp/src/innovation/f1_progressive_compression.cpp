// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f1_progressive_compression.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <utility>

namespace aether {
namespace innovation {
namespace {

constexpr std::uint32_t kMagicF1PC = 0x43315046u;  // "F1PC" little-endian.
constexpr std::uint16_t kVersionF1PC = 2u;
constexpr std::size_t kHeaderBytes =
    4u +   // magic
    2u +   // version
    2u +   // reserved
    4u +   // level index
    4u +   // gaussian count
    4u +   // sh coeff count
    6u * 4u +  // scene bounds (min xyz, max xyz)
    4u +   // scale_max
    3u +   // quant_bits (position, scale, uncertainty) — M1 FIX
    0u;

// ---------- byte helpers ----------

void write_u8(std::vector<std::uint8_t>& buf, std::uint8_t v) {
    buf.push_back(v);
}

void write_u16(std::vector<std::uint8_t>& buf, std::uint16_t v) {
    buf.push_back(static_cast<std::uint8_t>(v & 0xffu));
    buf.push_back(static_cast<std::uint8_t>((v >> 8u) & 0xffu));
}

void write_u32(std::vector<std::uint8_t>& buf, std::uint32_t v) {
    buf.push_back(static_cast<std::uint8_t>(v & 0xffu));
    buf.push_back(static_cast<std::uint8_t>((v >> 8u) & 0xffu));
    buf.push_back(static_cast<std::uint8_t>((v >> 16u) & 0xffu));
    buf.push_back(static_cast<std::uint8_t>((v >> 24u) & 0xffu));
}

[[maybe_unused]] void write_u64(std::vector<std::uint8_t>& buf, std::uint64_t v) {
    write_u32(buf, static_cast<std::uint32_t>(v & 0xFFFFFFFFu));
    write_u32(buf, static_cast<std::uint32_t>((v >> 32u) & 0xFFFFFFFFu));
}

void write_f32(std::vector<std::uint8_t>& buf, float v) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &v, sizeof(bits));
    write_u32(buf, bits);
}

std::uint8_t read_u8(const std::uint8_t*& ptr) {
    std::uint8_t v = *ptr;
    ptr += 1;
    return v;
}

std::uint16_t read_u16(const std::uint8_t*& ptr) {
    std::uint16_t v = static_cast<std::uint16_t>(ptr[0]) |
                      (static_cast<std::uint16_t>(ptr[1]) << 8u);
    ptr += 2;
    return v;
}

std::uint32_t read_u32(const std::uint8_t*& ptr) {
    std::uint32_t v = static_cast<std::uint32_t>(ptr[0]) |
                      (static_cast<std::uint32_t>(ptr[1]) << 8u) |
                      (static_cast<std::uint32_t>(ptr[2]) << 16u) |
                      (static_cast<std::uint32_t>(ptr[3]) << 24u);
    ptr += 4;
    return v;
}

[[maybe_unused]] std::uint64_t read_u64(const std::uint8_t*& ptr) {
    std::uint32_t lo = read_u32(ptr);
    std::uint32_t hi = read_u32(ptr);
    return static_cast<std::uint64_t>(lo) | (static_cast<std::uint64_t>(hi) << 32u);
}

float read_f32(const std::uint8_t*& ptr) {
    std::uint32_t bits = read_u32(ptr);
    float v = 0.0f;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

// ---------- quantization ----------

std::uint16_t quantize_float(float value, float min_val, float max_val, std::uint32_t bits) {
    if (bits == 0u || bits > 16u) {
        return 0u;
    }
    const std::uint32_t max_code = (1u << bits) - 1u;
    float range = max_val - min_val;
    if (range <= 0.0f) {
        range = 1.0f;
    }
    float t = (value - min_val) / range;
    core::guard_finite_scalar(&t);
    t = std::max(0.0f, std::min(1.0f, t));
    return static_cast<std::uint16_t>(std::min(
        static_cast<std::uint32_t>(std::round(t * static_cast<float>(max_code))),
        max_code));
}

float dequantize_float(std::uint16_t code, float min_val, float max_val, std::uint32_t bits) {
    if (bits == 0u || bits > 16u) {
        return min_val;
    }
    const std::uint32_t max_code = (1u << bits) - 1u;
    if (max_code == 0u) {
        return min_val;
    }
    float range = max_val - min_val;
    if (range <= 0.0f) {
        range = 1.0f;
    }
    float v = min_val + (static_cast<float>(code) / static_cast<float>(max_code)) * range;
    core::guard_finite_scalar(&v);
    return v;
}

std::uint8_t quantize_float_u8(float value, float min_val, float max_val) {
    float range = max_val - min_val;
    if (range <= 0.0f) {
        range = 1.0f;
    }
    float t = (value - min_val) / range;
    core::guard_finite_scalar(&t);
    t = std::max(0.0f, std::min(1.0f, t));
    return static_cast<std::uint8_t>(std::min(
        static_cast<std::uint32_t>(std::round(t * 255.0f)), 255u));
}

float dequantize_float_u8(std::uint8_t code, float min_val, float max_val) {
    float range = max_val - min_val;
    if (range <= 0.0f) {
        range = 1.0f;
    }
    float v = min_val + (static_cast<float>(code) / 255.0f) * range;
    core::guard_finite_scalar(&v);
    return v;
}

// ---------- per-gaussian byte estimate ----------

std::size_t estimate_bytes_per_gaussian(std::uint32_t sh_coeff_count) {
    // id(4) + host_unit_id(8) + observation_count(2) + flags(2)
    // + patch_priority(4) + capture_sequence(4)
    // + position(6) + scale(6) + opacity(1) + uncertainty(2) + sh_coeffs(N)
    return 4u + 8u + 2u + 2u + 4u + 4u + 6u + 6u + 1u + 2u + static_cast<std::size_t>(sh_coeff_count);
}

// ---------- area computation for a unit ----------

[[maybe_unused]] float compute_unit_area(
    const ScaffoldUnit& unit,
    const ScaffoldVertex* /* unused in this path */) {
    // The unit already carries its computed area.
    float a = unit.area;
    core::guard_finite_scalar(&a);
    return std::max(a, 0.0f);
}

}  // namespace

// ==================================================================
// f1_build_progressive_hierarchy
// ==================================================================

core::Status f1_build_progressive_hierarchy(
    const ScaffoldUnit* units,
    std::size_t unit_count,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ScaffoldPatchMap* patch_map,
    const ProgressiveCompressionConfig& config,
    ProgressiveHierarchy* out_hierarchy) {
    if (out_hierarchy == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (unit_count > 0u && units == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (config.level_count == 0u) {
        return core::Status::kInvalidArgument;
    }

    (void)patch_map;  // Used only for capture-order queue.

    // Compute scene bounds and per-unit area lookup.
    Aabb bounds{};
    for (std::size_t i = 0; i < gaussian_count; ++i) {
        expand_aabb(gaussians[i].position, bounds);
    }
    if (!bounds.valid) {
        bounds.min = make_float3(0.0f, 0.0f, 0.0f);
        bounds.max = make_float3(1.0f, 1.0f, 1.0f);
        bounds.valid = true;
    }

    // Build a mapping: unit_id -> area, for assigning gaussians to area tiers.
    // Collect the area for each gaussian's host unit.
    struct GaussianArea {
        std::uint32_t index;
        float area;
    };
    std::vector<GaussianArea> ga(gaussian_count);
    for (std::size_t i = 0; i < gaussian_count; ++i) {
        ga[i].index = static_cast<std::uint32_t>(i);
        ga[i].area = 0.0f;
    }

    // Map unit_id -> area.
    for (std::size_t i = 0; i < gaussian_count; ++i) {
        const std::uint64_t uid = gaussians[i].host_unit_id;
        if (uid == 0u) {
            ga[i].area = 0.0f;
            continue;
        }
        // Linear scan over units (typically small).
        for (std::size_t u = 0; u < unit_count; ++u) {
            if (units[u].unit_id == uid) {
                float a = units[u].area;
                core::guard_finite_scalar(&a);
                ga[i].area = std::max(a, 0.0f);
                break;
            }
        }
    }

    // Apply area_gamma.
    if (config.area_gamma != 1.0f && config.area_gamma > 0.0f) {
        for (auto& g : ga) {
            if (g.area > 0.0f) {
                g.area = std::pow(g.area, config.area_gamma);
                core::guard_finite_scalar(&g.area);
            }
        }
    }

    // Find area range.
    float area_min = std::numeric_limits<float>::max();
    float area_max = 0.0f;
    for (const auto& g : ga) {
        area_min = std::min(area_min, g.area);
        area_max = std::max(area_max, g.area);
    }
    if (area_min > area_max) {
        area_min = 0.0f;
        area_max = 1.0f;
    }
    if (area_max <= area_min) {
        area_max = area_min + 1.0f;
    }

    // Partition gaussians into levels by area quantile.
    // Sort indices by area (largest first -> coarsest LOD level 0).
    std::vector<std::uint32_t> sorted_indices(gaussian_count);
    for (std::uint32_t i = 0; i < gaussian_count; ++i) {
        sorted_indices[i] = i;
    }
    std::sort(sorted_indices.begin(), sorted_indices.end(),
              [&ga](std::uint32_t a, std::uint32_t b) {
                  if (ga[a].area != ga[b].area) {
                      return ga[a].area > ga[b].area;  // Larger area first.
                  }
                  return a < b;
              });

    const std::uint32_t level_count = config.level_count;
    const std::size_t per_level = std::max<std::size_t>(
        1u, (gaussian_count + level_count - 1u) / level_count);

    const std::size_t bpg = estimate_bytes_per_gaussian(config.sh_coeff_count);

    ProgressiveHierarchy hierarchy{};
    hierarchy.scene_bounds = bounds;
    hierarchy.estimated_bytes_per_gaussian = bpg;
    hierarchy.levels.resize(level_count);

    for (std::uint32_t lev = 0; lev < level_count; ++lev) {
        LODLevel& level = hierarchy.levels[lev];
        level.level_index = lev;
        level.min_unit_area = std::numeric_limits<float>::max();
        level.max_unit_area = 0.0f;

        const std::size_t begin = lev * per_level;
        const std::size_t end = std::min(begin + per_level, gaussian_count);
        for (std::size_t s = begin; s < end; ++s) {
            const std::uint32_t gi = sorted_indices[s];
            level.gaussian_indices.push_back(gi);
            const float a = ga[gi].area;
            level.min_unit_area = std::min(level.min_unit_area, a);
            level.max_unit_area = std::max(level.max_unit_area, a);
        }

        if (level.gaussian_indices.empty()) {
            level.min_unit_area = 0.0f;
            level.max_unit_area = 0.0f;
        }
        level.estimated_bytes = level.gaussian_indices.size() * bpg;
    }

    *out_hierarchy = std::move(hierarchy);
    return core::Status::kOk;
}

// ==================================================================
// f1_select_level_for_budget
// ==================================================================

core::Status f1_select_level_for_budget(
    const ProgressiveHierarchy& hierarchy,
    std::size_t byte_budget,
    std::uint32_t* out_level_index) {
    if (out_level_index == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (hierarchy.levels.empty()) {
        return core::Status::kOutOfRange;
    }

    // Find the highest level whose estimated bytes fits within the budget.
    // Each level is self-contained (not cumulative).
    std::uint32_t selected = 0;
    bool any_fits = false;
    for (std::uint32_t i = 0; i < static_cast<std::uint32_t>(hierarchy.levels.size()); ++i) {
        if (hierarchy.levels[i].estimated_bytes <= byte_budget) {
            selected = i;
            any_fits = true;
        }
    }
    *out_level_index = any_fits ? selected : 0u;
    if (!any_fits) {
        return core::Status::kOutOfRange;
    }
    return core::Status::kOk;
}

// ==================================================================
// f1_encode_level
// ==================================================================

core::Status f1_encode_level(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ProgressiveHierarchy& hierarchy,
    std::uint32_t level_index,
    const ProgressiveCompressionConfig& config,
    ProgressiveEncodedLevel* out_encoded) {
    if (out_encoded == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussians == nullptr && gaussian_count > 0u) {
        return core::Status::kInvalidArgument;
    }
    if (level_index >= static_cast<std::uint32_t>(hierarchy.levels.size())) {
        return core::Status::kInvalidArgument;
    }

    const LODLevel& level = hierarchy.levels[level_index];
    const Aabb& bounds = hierarchy.scene_bounds;

    // Compute position bounds for quantization.
    const float pos_min_x = bounds.min.x;
    const float pos_min_y = bounds.min.y;
    const float pos_min_z = bounds.min.z;
    const float pos_max_x = bounds.max.x;
    const float pos_max_y = bounds.max.y;
    const float pos_max_z = bounds.max.z;

    // Scale range.
    float scale_min = 0.0f;
    float scale_max = 1.0f;
    for (std::uint32_t gi : level.gaussian_indices) {
        if (gi >= gaussian_count) {
            continue;
        }
        const auto& g = gaussians[gi];
        scale_max = std::max(scale_max, std::max(g.scale.x, std::max(g.scale.y, g.scale.z)));
    }
    scale_max = std::max(scale_max, scale_min + 1e-6f);

    // SH range.
    float sh_min = -4.0f;
    float sh_max = 4.0f;

    const std::uint32_t sh_count = std::min(config.sh_coeff_count,
                                            static_cast<std::uint32_t>(16u));

    std::vector<std::uint8_t> buf;
    buf.reserve(kHeaderBytes + level.gaussian_indices.size() * 32u);

    // Header.
    write_u32(buf, kMagicF1PC);
    write_u16(buf, kVersionF1PC);
    write_u16(buf, 0u);  // reserved
    write_u32(buf, level_index);
    write_u32(buf, static_cast<std::uint32_t>(level.gaussian_indices.size()));
    write_u32(buf, sh_count);

    // Bounds.
    write_f32(buf, pos_min_x);
    write_f32(buf, pos_min_y);
    write_f32(buf, pos_min_z);
    write_f32(buf, pos_max_x);
    write_f32(buf, pos_max_y);
    write_f32(buf, pos_max_z);

    // Scale max for dequantization.
    write_f32(buf, scale_max);

    // M1 FIX: Store quant_bits after scale_max so decoder reads them in matching order.
    // Without this, if F3's adapted_config changes quant_bits, decode produces wrong values.
    write_u8(buf, static_cast<std::uint8_t>(config.quant_bits_position));
    write_u8(buf, static_cast<std::uint8_t>(config.quant_bits_scale));
    write_u8(buf, static_cast<std::uint8_t>(config.quant_bits_uncertainty));

    // Per-gaussian data.
    for (std::uint32_t gi : level.gaussian_indices) {
        if (gi >= gaussian_count) {
            return core::Status::kOutOfRange;
        }
        const auto& g = gaussians[gi];

        // ID (4 bytes).
        write_u32(buf, g.id);

        // Metadata fields for roundtrip fidelity.
        write_u64(buf, g.host_unit_id);
        write_u16(buf, g.observation_count);
        write_u16(buf, g.flags);
        write_u32(buf, g.patch_priority);
        write_u32(buf, g.capture_sequence);

        // Position (quantized to quant_bits_position, stored as u16 each).
        write_u16(buf, quantize_float(g.position.x, pos_min_x, pos_max_x, config.quant_bits_position));
        write_u16(buf, quantize_float(g.position.y, pos_min_y, pos_max_y, config.quant_bits_position));
        write_u16(buf, quantize_float(g.position.z, pos_min_z, pos_max_z, config.quant_bits_position));

        // Scale (quantized, u16 each).
        write_u16(buf, quantize_float(g.scale.x, scale_min, scale_max, config.quant_bits_scale));
        write_u16(buf, quantize_float(g.scale.y, scale_min, scale_max, config.quant_bits_scale));
        write_u16(buf, quantize_float(g.scale.z, scale_min, scale_max, config.quant_bits_scale));

        // Opacity (u8).
        write_u8(buf, quantize_float_u8(g.opacity, 0.0f, 1.0f));

        // Uncertainty (u16, quant_bits_uncertainty).
        write_u16(buf, quantize_float(g.uncertainty, 0.0f, 1.0f, config.quant_bits_uncertainty));

        // SH coefficients (u8 each).
        for (std::uint32_t s = 0; s < sh_count; ++s) {
            write_u8(buf, quantize_float_u8(g.sh_coeffs[s], sh_min, sh_max));
        }
    }

    ProgressiveEncodedLevel encoded{};
    encoded.level_index = level_index;
    encoded.gaussian_count = static_cast<std::uint32_t>(level.gaussian_indices.size());
    encoded.sh_coeff_count = sh_count;
    encoded.bytes = std::move(buf);
    *out_encoded = std::move(encoded);
    return core::Status::kOk;
}

// ==================================================================
// f1_decode_level
// ==================================================================

core::Status f1_decode_level(
    const ProgressiveEncodedLevel& encoded,
    std::vector<GaussianPrimitive>* out_gaussians) {
    if (out_gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_gaussians->clear();

    if (encoded.bytes.size() < kHeaderBytes) {
        return core::Status::kOutOfRange;
    }

    const std::uint8_t* ptr = encoded.bytes.data();

    // Read header.
    const std::uint32_t magic = read_u32(ptr);
    if (magic != kMagicF1PC) {
        return core::Status::kInvalidArgument;
    }
    const std::uint16_t version = read_u16(ptr);
    if (version != kVersionF1PC) {
        return core::Status::kInvalidArgument;
    }
    read_u16(ptr);  // reserved.
    const std::uint32_t level_index = read_u32(ptr);
    (void)level_index;
    const std::uint32_t gaussian_count = read_u32(ptr);
    const std::uint32_t sh_count = read_u32(ptr);

    // Bounds.
    const float pos_min_x = read_f32(ptr);
    const float pos_min_y = read_f32(ptr);
    const float pos_min_z = read_f32(ptr);
    const float pos_max_x = read_f32(ptr);
    const float pos_max_y = read_f32(ptr);
    const float pos_max_z = read_f32(ptr);

    // Compute expected per-gaussian size:
    // id(4) + host_unit_id(8) + observation_count(2) + flags(2) + patch_priority(4)
    // + capture_sequence(4) + pos(6) + scale(6) + opacity(1) + uncertainty(2) + sh(sh_count)
    const std::size_t per_g = 4u + 8u + 2u + 2u + 4u + 4u + 6u + 6u + 1u + 2u + static_cast<std::size_t>(sh_count);
    const std::size_t expected = kHeaderBytes + per_g * gaussian_count;
    if (encoded.bytes.size() < expected) {
        return core::Status::kOutOfRange;
    }

    // SH range used during encode.
    const float sh_min = -4.0f;
    const float sh_max = 4.0f;

    // Scale range stored in header after bounds.
    const float scale_min = 0.0f;
    const float scale_max = read_f32(ptr);

    // M1 FIX: Read quant_bits from header (written by encoder).
    // Falls back to hardcoded defaults for legacy v2 streams without these bytes.
    std::uint32_t qb_pos = 16u;
    std::uint32_t qb_scale = 16u;
    std::uint32_t qb_uncert = 12u;
    const std::size_t bytes_consumed = static_cast<std::size_t>(ptr - encoded.bytes.data());
    if (bytes_consumed + 3u <= encoded.bytes.size()) {
        qb_pos = read_u8(ptr);
        qb_scale = read_u8(ptr);
        qb_uncert = read_u8(ptr);
        // Validate ranges
        if (qb_pos == 0u || qb_pos > 16u) qb_pos = 16u;
        if (qb_scale == 0u || qb_scale > 16u) qb_scale = 16u;
        if (qb_uncert == 0u || qb_uncert > 16u) qb_uncert = 12u;
    }

    out_gaussians->reserve(gaussian_count);
    for (std::uint32_t i = 0; i < gaussian_count; ++i) {
        GaussianPrimitive g{};

        // ID (4 bytes).
        g.id = read_u32(ptr);

        // Metadata fields (must match encoder order).
        g.host_unit_id = read_u64(ptr);
        g.observation_count = read_u16(ptr);
        g.flags = read_u16(ptr);
        g.patch_priority = read_u32(ptr);
        g.capture_sequence = read_u32(ptr);

        // Position (quantized u16 each — using quant_bits from header).
        g.position.x = dequantize_float(read_u16(ptr), pos_min_x, pos_max_x, qb_pos);
        g.position.y = dequantize_float(read_u16(ptr), pos_min_y, pos_max_y, qb_pos);
        g.position.z = dequantize_float(read_u16(ptr), pos_min_z, pos_max_z, qb_pos);

        // Scale (quantized u16 each — using quant_bits from header).
        g.scale.x = dequantize_float(read_u16(ptr), scale_min, scale_max, qb_scale);
        g.scale.y = dequantize_float(read_u16(ptr), scale_min, scale_max, qb_scale);
        g.scale.z = dequantize_float(read_u16(ptr), scale_min, scale_max, qb_scale);

        // Opacity (u8).
        g.opacity = dequantize_float_u8(read_u8(ptr), 0.0f, 1.0f);

        // Uncertainty (u16 — using quant_bits from header).
        g.uncertainty = dequantize_float(read_u16(ptr), 0.0f, 1.0f, qb_uncert);

        // SH coefficients (u8 each).
        for (std::uint32_t s = 0; s < sh_count; ++s) {
            g.sh_coeffs[s] = dequantize_float_u8(read_u8(ptr), sh_min, sh_max);
        }

        core::guard_finite_vector(&g.position.x, 3);
        core::guard_finite_vector(&g.scale.x, 3);
        core::guard_finite_scalar(&g.opacity);
        core::guard_finite_scalar(&g.uncertainty);
        core::guard_finite_vector(g.sh_coeffs.data(), sh_count);

        out_gaussians->push_back(g);
    }

    return core::Status::kOk;
}

// ==================================================================
// f1_build_capture_order_queue
// ==================================================================

core::Status f1_build_capture_order_queue(
    const ProgressiveHierarchy& hierarchy,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::uint32_t level_index,
    std::vector<F1RenderQueueEntry>* out_queue,
    const ScaffoldPatchMap* patch_map) {
    if (out_queue == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussians == nullptr && gaussian_count > 0u) {
        return core::Status::kInvalidArgument;
    }
    out_queue->clear();

    if (hierarchy.levels.empty()) {
        return core::Status::kOutOfRange;
    }

    // Use the requested level (clamped to valid range).
    const std::uint32_t max_lev = std::min(
        level_index,
        static_cast<std::uint32_t>(hierarchy.levels.size() - 1u));

    // Each level is a progressive superset, so level max_lev contains all gaussians
    // for that detail level. Only emit entries from the requested level.
    {
        const std::uint32_t lev = max_lev;
        const LODLevel& level = hierarchy.levels[lev];
        for (std::uint32_t gi : level.gaussian_indices) {
            if (gi >= gaussian_count) {
                continue;
            }
            const auto& g = gaussians[gi];

            F1RenderQueueEntry entry{};
            entry.gaussian_index = gi;
            entry.gaussian_id = g.id;
            entry.host_unit_id = g.host_unit_id;
            entry.capture_sequence = g.capture_sequence;
            entry.patch_priority = g.patch_priority;
            entry.first_observed_frame_id = g.first_observed_frame_id;
            entry.first_observed_ms = g.first_observed_ms;
            entry.lod_level = lev;

            // Resolve patch_id and host_unit_id from the gaussian or the patch_map.
            entry.patch_id = g.patch_id;
            if (entry.patch_id.empty() && patch_map != nullptr && g.host_unit_id != 0u) {
                (void)patch_map->patch_id_for_unit(g.host_unit_id, &entry.patch_id);
            }
            // If gaussian has a patch_id but no host_unit, resolve from patch_map.
            if (patch_map != nullptr && !entry.patch_id.empty() && entry.host_unit_id == 0u) {
                ScaffoldUnitId resolved_id = 0;
                if (patch_map->unit_id_for_patch_id(entry.patch_id, &resolved_id) == core::Status::kOk) {
                    entry.host_unit_id = resolved_id;
                }
            }

            out_queue->push_back(entry);
        }
    }

    // Sort the queue: by patch_priority (higher first, reshoot front-loading),
    // then by capture_sequence (earlier captures first within same priority),
    // then by LOD level, then by gaussian_id for stability.
    std::sort(out_queue->begin(), out_queue->end(),
              [](const F1RenderQueueEntry& a, const F1RenderQueueEntry& b) {
                  if (a.patch_priority != b.patch_priority) {
                      return a.patch_priority > b.patch_priority;
                  }
                  if (a.capture_sequence != b.capture_sequence) {
                      return a.capture_sequence < b.capture_sequence;
                  }
                  if (a.lod_level != b.lod_level) {
                      return a.lod_level < b.lod_level;
                  }
                  return a.gaussian_id < b.gaussian_id;
              });

    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
