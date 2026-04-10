// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/runtime_tsdf_gaussian_augmentation.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>

#include "aether/tsdf/tsdf_constants.h"

namespace aether {
namespace pipeline {
namespace runtime_tsdf_gaussian_augmentation {
namespace {

struct SRGBToLinearLUT {
    float table[256];
    SRGBToLinearLUT() noexcept {
        for (int i = 0; i < 256; ++i) {
            const float s = static_cast<float>(i) / 255.0f;
            table[i] = s <= 0.04045f ? s / 12.92f
                                     : std::pow((s + 0.055f) / 1.055f, 2.4f);
        }
    }
};

const SRGBToLinearLUT g_srgb_lut{};

inline std::uint64_t mix64(std::uint64_t x) noexcept {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline float hash_unit01(std::uint64_t seed) noexcept {
    constexpr double inv =
        1.0 / static_cast<double>(std::numeric_limits<std::uint32_t>::max());
    const std::uint32_t top = static_cast<std::uint32_t>(mix64(seed) >> 32);
    return static_cast<float>(static_cast<double>(top) * inv);
}

inline std::int64_t block_hash_key(const tsdf::BlockIndex& idx) noexcept {
    return (static_cast<std::int64_t>(idx.x) << 40) |
           ((static_cast<std::int64_t>(idx.y) & 0xFFFFF) << 20) |
           (static_cast<std::int64_t>(idx.z) & 0xFFFFF);
}

inline bool sample_color_linear(
    const ColorFrameView& frame,
    float wx,
    float wy,
    float wz,
    float out_rgb[3]) noexcept
{
    if (!frame.rgba || frame.width == 0 || frame.height == 0) {
        return false;
    }

    const float dwx = wx - frame.transform[12];
    const float dwy = wy - frame.transform[13];
    const float dwz = wz - frame.transform[14];

    const float cam_x =
        (frame.transform[0] * dwx + frame.transform[1] * dwy + frame.transform[2] * dwz);
    const float cam_y =
        -(frame.transform[4] * dwx + frame.transform[5] * dwy + frame.transform[6] * dwz);
    const float cam_z =
        -(frame.transform[8] * dwx + frame.transform[9] * dwy + frame.transform[10] * dwz);
    if (cam_z <= 0.1f) {
        return false;
    }

    const float u = frame.intrinsics[0] * cam_x / cam_z + frame.intrinsics[2];
    const float v = frame.intrinsics[4] * cam_y / cam_z + frame.intrinsics[5];
    const int iu = static_cast<int>(std::lround(u));
    const int iv = static_cast<int>(std::lround(v));
    if (iu < 0 || iv < 0 ||
        iu >= static_cast<int>(frame.width) ||
        iv >= static_cast<int>(frame.height)) {
        return false;
    }

    const std::size_t idx =
        (static_cast<std::size_t>(iv) * static_cast<std::size_t>(frame.width) +
         static_cast<std::size_t>(iu)) * 4u;
    const std::uint8_t* px = frame.rgba + idx;
    out_rgb[0] = g_srgb_lut.table[px[2]];
    out_rgb[1] = g_srgb_lut.table[px[1]];
    out_rgb[2] = g_srgb_lut.table[px[0]];
    return true;
}

inline bool sample_color_with_keyframes(
    const ColorFrameView& current_color_frame,
    const std::vector<ColorFrameView>& keyframes,
    float wx,
    float wy,
    float wz,
    float out_rgb[3]) noexcept
{
    if (sample_color_linear(current_color_frame, wx, wy, wz, out_rgb)) {
        return true;
    }
    for (auto it = keyframes.rbegin(); it != keyframes.rend(); ++it) {
        if (sample_color_linear(*it, wx, wy, wz, out_rgb)) {
            return true;
        }
    }
    return false;
}

inline void refill_token_bucket(
    State& state,
    std::chrono::steady_clock::time_point now) noexcept
{
    if (!state.gaussian_bucket_initialized) {
        state.gaussian_bucket_tokens = kGaussianBucketCapacity;
        state.gaussian_bucket_last_refill = now;
        state.gaussian_bucket_initialized = true;
        return;
    }

    const auto refill_elapsed =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            now - state.gaussian_bucket_last_refill);
    if (refill_elapsed.count() <= 0) {
        return;
    }

    const std::size_t refill = static_cast<std::size_t>(
        static_cast<double>(kGaussianRefillRate) *
        static_cast<double>(refill_elapsed.count()) / 1000.0);
    state.gaussian_bucket_tokens = std::min(
        state.gaussian_bucket_tokens + refill,
        kGaussianBucketCapacity);
    state.gaussian_bucket_last_refill = now;
}

}  // namespace

bool should_run_runtime_tsdf_gaussian_augmentation(
    bool capture_sparse_dense_map,
    bool imported_video_runtime_tsdf_augmentation) noexcept
{
    return !capture_sparse_dense_map && !imported_video_runtime_tsdf_augmentation;
}

std::size_t assigned_block_count(
    const State& state) noexcept
{
    return state.assigned_blocks.size();
}

Result build_runtime_tsdf_gaussian_seeds(
    State& state,
    const std::vector<tsdf::BlockQualitySample>& samples,
    const ColorFrameView& current_color_frame,
    const std::vector<ColorFrameView>& keyframes,
    float cam_x,
    float cam_y,
    float cam_z,
    bool strict_preview_color,
    std::chrono::steady_clock::time_point now) noexcept
{
    Result result;
    refill_token_bucket(state, now);

    constexpr float kBaseVoxelSize = tsdf::VOXEL_SIZE_MID;
    const bool bootstrap_seed_mode = state.assigned_blocks.size() < 4096u;
    const float min_weight_for_gaussian = bootstrap_seed_mode ? 0.35f : 2.0f;
    const float min_alt_weight = bootstrap_seed_mode ? 0.9f : 6.0f;
    const std::uint32_t min_alt_occupied = bootstrap_seed_mode ? 4u : 32u;
    constexpr std::size_t kMaxSeedsPerBlock = 512u;
    constexpr float kGoldenAngle = 2.39996322f;
    const float block_world_size =
        kBaseVoxelSize * static_cast<float>(tsdf::BLOCK_SIZE);
    constexpr std::size_t kReserveSeeds = 200000u;
    result.gaussians.reserve(std::min(samples.size() * 4u, kReserveSeeds));

    for (const auto& s : samples) {
        if (s.occupied_count == 0) {
            continue;
        }
        result.blocks_checked++;

        const bool surface_ok = s.has_surface;
        const bool alt_ok =
            s.avg_weight >= min_alt_weight && s.occupied_count >= min_alt_occupied;
        if (!surface_ok && !alt_ok) {
            result.blocks_rejected_surface++;
            continue;
        }
        if (s.avg_weight < min_weight_for_gaussian) {
            result.blocks_rejected_weight++;
            continue;
        }

        tsdf::BlockIndex idx(
            static_cast<std::int32_t>(std::floor(s.center[0] / block_world_size)),
            static_cast<std::int32_t>(std::floor(s.center[1] / block_world_size)),
            static_cast<std::int32_t>(std::floor(s.center[2] / block_world_size)));
        const auto key = block_hash_key(idx);
        if (state.assigned_blocks.count(key) > 0) {
            continue;
        }
        if (state.gaussian_bucket_tokens == 0) {
            break;
        }

        state.assigned_blocks.insert(key);
        result.seeded_blocks++;

        float nx = s.normal[0];
        float ny = s.normal[1];
        float nz = s.normal[2];
        float nlen = std::sqrt(nx * nx + ny * ny + nz * nz);
        float q_w = 1.0f;
        float q_x = 0.0f;
        float q_y = 0.0f;
        float q_z = 0.0f;
        if (nlen > 0.001f) {
            nx /= nlen;
            ny /= nlen;
            nz /= nlen;
            const float dot = nz;
            if (dot < -0.999f) {
                q_w = 0.0f;
                q_x = 1.0f;
            } else {
                const float cx_ = -ny;
                const float cy_ = nx;
                const float cz_ = 0.0f;
                const float w_ = 1.0f + dot;
                const float qlen =
                    std::sqrt(cx_ * cx_ + cy_ * cy_ + cz_ * cz_ + w_ * w_);
                q_w = w_ / qlen;
                q_x = cx_ / qlen;
                q_y = cy_ / qlen;
                q_z = cz_ / qlen;
            }
        } else {
            nx = 0.0f;
            ny = 1.0f;
            nz = 0.0f;
        }

        float ref_x = 0.0f;
        float ref_y = 1.0f;
        float ref_z = 0.0f;
        if (std::fabs(ny) > 0.9f) {
            ref_x = 1.0f;
            ref_y = 0.0f;
            ref_z = 0.0f;
        }
        float tx = ref_y * nz - ref_z * ny;
        float ty = ref_z * nx - ref_x * nz;
        float tz = ref_x * ny - ref_y * nx;
        const float tlen = std::sqrt(tx * tx + ty * ty + tz * tz);
        if (tlen > 1e-6f) {
            tx /= tlen;
            ty /= tlen;
            tz /= tlen;
        } else {
            tx = 1.0f;
            ty = 0.0f;
            tz = 0.0f;
        }
        const float bx = ny * tz - nz * ty;
        const float by = nz * tx - nx * tz;
        const float bz = nx * ty - ny * tx;

        const float blk_dx = s.surface_center[0] - cam_x;
        const float blk_dy = s.surface_center[1] - cam_y;
        const float blk_dz = s.surface_center[2] - cam_z;
        const float block_depth =
            std::sqrt(blk_dx * blk_dx + blk_dy * blk_dy + blk_dz * blk_dz);

        float effective_voxel_size = kBaseVoxelSize;
        if (block_depth < tsdf::DEPTH_NEAR_THRESHOLD) {
            effective_voxel_size = tsdf::VOXEL_SIZE_NEAR;
        } else if (block_depth > tsdf::DEPTH_FAR_THRESHOLD) {
            effective_voxel_size = tsdf::VOXEL_SIZE_FAR;
        }

        const float weight_norm = std::min(s.avg_weight / 16.0f, 1.0f);
        const float quality_norm = std::clamp(s.composite_quality, 0.0f, 1.0f);
        const float occupancy_norm = std::clamp(
            static_cast<float>(s.occupied_count) / 96.0f, 0.0f, 1.0f);
        float seed_density =
            0.18f + 0.34f * quality_norm + 0.24f * weight_norm + 0.24f * occupancy_norm;
        if (block_depth < tsdf::DEPTH_NEAR_THRESHOLD) {
            seed_density += 0.18f;
        } else if (block_depth > tsdf::DEPTH_FAR_THRESHOLD) {
            seed_density -= 0.08f;
        }
        seed_density = std::clamp(seed_density, 0.125f, 0.625f);

        std::size_t seeds_per_block = static_cast<std::size_t>(
            std::llround(static_cast<double>(kMaxSeedsPerBlock) * seed_density));
        seeds_per_block = std::clamp<std::size_t>(seeds_per_block, 64u, 320u);
        const float spread_radius = block_world_size * 0.45f;
        const float base_scale = effective_voxel_size * 0.7f;
        const float seeds_f = static_cast<float>(seeds_per_block);

        for (std::size_t seed_idx = 0; seed_idx < seeds_per_block; ++seed_idx) {
            const std::uint64_t seed =
                static_cast<std::uint64_t>(key) ^
                (0x9E3779B97F4A7C15ULL + seed_idx * 0x94D049BB133111EBULL);
            const float jitter_c = hash_unit01(seed + 41u);
            const float angle = static_cast<float>(seed_idx) * kGoldenAngle;
            const float radial = seed_idx == 0
                ? 0.0f
                : spread_radius *
                      std::sqrt(static_cast<float>(seed_idx) / seeds_f);
            const float c = std::cos(angle);
            const float ss = std::sin(angle);

            const float ox = (tx * c + bx * ss) * radial;
            const float oy = (ty * c + by * ss) * radial;
            const float oz = (tz * c + bz * ss) * radial;
            const float nj =
                (hash_unit01(seed + 59u) - 0.5f) * effective_voxel_size * 0.5f;

            splat::GaussianParams g{};
            g.position[0] = s.surface_center[0] + ox + nx * nj;
            g.position[1] = s.surface_center[1] + oy + ny * nj;
            g.position[2] = s.surface_center[2] + oz + nz * nj;

            float sampled_rgb[3] = {0.0f, 0.0f, 0.0f};
            const bool color_ok = sample_color_with_keyframes(
                current_color_frame,
                keyframes,
                g.position[0],
                g.position[1],
                g.position[2],
                sampled_rgb);
            if (color_ok) {
                g.color[0] = sampled_rgb[0];
                g.color[1] = sampled_rgb[1];
                g.color[2] = sampled_rgb[2];
                result.sampled_colors++;
            } else if (strict_preview_color) {
                continue;
            } else {
                const float base_luma = std::clamp(
                    0.08f + 0.42f * quality_norm + 0.10f * weight_norm,
                    0.06f,
                    0.72f);
                g.color[0] = base_luma * (0.92f + 0.14f * jitter_c);
                g.color[1] = base_luma * (0.90f + 0.10f * (1.0f - jitter_c));
                g.color[2] = base_luma * (0.95f + 0.08f * (1.0f - weight_norm));
                result.fallback_colors++;
            }

            g.opacity = 0.25f + 0.60f * weight_norm;
            const float anis = 0.75f + 0.50f * jitter_c;
            g.scale[0] = base_scale * anis;
            g.scale[1] = base_scale * (1.60f - anis);
            g.scale[2] =
                effective_voxel_size * (0.10f + 0.12f * (1.0f - quality_norm));
            g.rotation[0] = q_w;
            g.rotation[1] = q_x;
            g.rotation[2] = q_y;
            g.rotation[3] = q_z;
            result.gaussians.push_back(g);
        }

        if (seeds_per_block <= state.gaussian_bucket_tokens) {
            state.gaussian_bucket_tokens -= seeds_per_block;
        } else {
            state.gaussian_bucket_tokens = 0;
        }
    }

    if (result.gaussians.empty() && !samples.empty() && state.gaussian_bucket_tokens > 0) {
        static std::uint32_t empty_seed_diag = 0;
        empty_seed_diag++;
        if (empty_seed_diag <= 10 || (empty_seed_diag % 60 == 0)) {
            std::fprintf(
                stderr,
                "[Aether3D][TSDF→GS] empty primary seeding: checked=%zu reject_surface=%zu "
                "reject_weight=%zu bucket=%zu assigned=%zu bootstrap=%d "
                "minW=%.2f altW=%.2f altOcc=%d\n",
                result.blocks_checked,
                result.blocks_rejected_surface,
                result.blocks_rejected_weight,
                state.gaussian_bucket_tokens,
                state.assigned_blocks.size(),
                bootstrap_seed_mode ? 1 : 0,
                min_weight_for_gaussian,
                min_alt_weight,
                min_alt_occupied);
        }

        std::size_t emergency_blocks = 0;
        constexpr std::size_t kEmergencyMaxBlocks = 96u;
        constexpr std::size_t kEmergencyMaxSeedsPerBlock = 8u;

        for (const auto& s : samples) {
            if (emergency_blocks >= kEmergencyMaxBlocks ||
                state.gaussian_bucket_tokens == 0) {
                break;
            }
            if (s.occupied_count == 0) {
                continue;
            }
            if (!s.has_surface && s.avg_weight < 0.35f) {
                continue;
            }

            tsdf::BlockIndex idx(
                static_cast<std::int32_t>(std::floor(s.center[0] / block_world_size)),
                static_cast<std::int32_t>(std::floor(s.center[1] / block_world_size)),
                static_cast<std::int32_t>(std::floor(s.center[2] / block_world_size)));
            const auto key = block_hash_key(idx);
            if (state.assigned_blocks.count(key) > 0) {
                continue;
            }

            state.assigned_blocks.insert(key);
            result.seeded_blocks++;
            emergency_blocks++;

            std::size_t seeds_per_block = std::max<std::size_t>(
                1u,
                std::min<std::size_t>(
                    kEmergencyMaxSeedsPerBlock,
                    static_cast<std::size_t>(s.occupied_count / 8u + 1u)));
            if (seeds_per_block > state.gaussian_bucket_tokens) {
                seeds_per_block = state.gaussian_bucket_tokens;
            }

            float nx = s.normal[0];
            float ny = s.normal[1];
            float nz = s.normal[2];
            const float nlen = std::sqrt(nx * nx + ny * ny + nz * nz);
            if (nlen > 1e-6f) {
                nx /= nlen;
                ny /= nlen;
                nz /= nlen;
            } else {
                nx = 0.0f;
                ny = 1.0f;
                nz = 0.0f;
            }

            for (std::size_t seed_idx = 0; seed_idx < seeds_per_block; ++seed_idx) {
                const std::uint64_t seed =
                    static_cast<std::uint64_t>(key) ^
                    (0x9E3779B97F4A7C15ULL +
                     seed_idx * 0x94D049BB133111EBULL);
                const float jitter =
                    (hash_unit01(seed + 17u) - 0.5f) * kBaseVoxelSize * 0.35f;

                splat::GaussianParams g{};
                const float px = s.has_surface ? s.surface_center[0] : s.center[0];
                const float py = s.has_surface ? s.surface_center[1] : s.center[1];
                const float pz = s.has_surface ? s.surface_center[2] : s.center[2];
                g.position[0] = px + nx * jitter;
                g.position[1] = py + ny * jitter;
                g.position[2] = pz + nz * jitter;

                float sampled_rgb[3] = {0.0f, 0.0f, 0.0f};
                const bool color_ok = sample_color_with_keyframes(
                    current_color_frame,
                    keyframes,
                    g.position[0],
                    g.position[1],
                    g.position[2],
                    sampled_rgb);
                if (color_ok) {
                    g.color[0] = sampled_rgb[0];
                    g.color[1] = sampled_rgb[1];
                    g.color[2] = sampled_rgb[2];
                    result.sampled_colors++;
                } else if (strict_preview_color) {
                    continue;
                } else {
                    const float q = std::clamp(s.composite_quality, 0.0f, 1.0f);
                    const float luma = std::clamp(0.12f + 0.35f * q, 0.08f, 0.55f);
                    g.color[0] = luma;
                    g.color[1] = luma;
                    g.color[2] = luma;
                    result.fallback_colors++;
                }

                const float weight_norm =
                    std::clamp(s.avg_weight / 8.0f, 0.0f, 1.0f);
                g.opacity = 0.20f + 0.50f * weight_norm;
                const float scale = std::max(0.0025f, kBaseVoxelSize * 0.55f);
                g.scale[0] = scale;
                g.scale[1] = scale;
                g.scale[2] = scale * 0.7f;
                g.rotation[0] = 1.0f;
                g.rotation[1] = 0.0f;
                g.rotation[2] = 0.0f;
                g.rotation[3] = 0.0f;
                result.gaussians.push_back(g);
            }

            if (seeds_per_block <= state.gaussian_bucket_tokens) {
                state.gaussian_bucket_tokens -= seeds_per_block;
            } else {
                state.gaussian_bucket_tokens = 0;
            }
        }

        if (!result.gaussians.empty()) {
            std::fprintf(
                stderr,
                "[Aether3D][TSDF→GS] emergency seeding activated: +%zu gaussians from %zu blocks\n",
                result.gaussians.size(),
                emergency_blocks);
        }
    }

    if (!result.gaussians.empty()) {
        state.total_created_gaussians += result.gaussians.size();
        const float density = result.seeded_blocks > 0
            ? static_cast<float>(result.gaussians.size()) /
                  static_cast<float>(result.seeded_blocks)
            : 0.0f;
        const float color_hit =
            (result.sampled_colors + result.fallback_colors) > 0
                ? (100.0f * static_cast<float>(result.sampled_colors) /
                   static_cast<float>(result.sampled_colors + result.fallback_colors))
                : 0.0f;
        float avg_r = 0.0f;
        float avg_g = 0.0f;
        float avg_b = 0.0f;
        for (const auto& ng : result.gaussians) {
            avg_r += ng.color[0];
            avg_g += ng.color[1];
            avg_b += ng.color[2];
        }
        const float inv = 1.0f / static_cast<float>(result.gaussians.size());
        avg_r *= inv;
        avg_g *= inv;
        avg_b *= inv;
        std::fprintf(
            stderr,
            "[Aether3D][TSDF→GS] +%zu Gaussians from %zu blocks "
            "(density=%.1f/block, colorHit=%.1f%%, avg_rgb=[%.3f,%.3f,%.3f], "
            "total=%zu, assigned=%zu, checked=%zu, reject_surface=%zu, reject_weight=%zu)\n",
            result.gaussians.size(),
            result.seeded_blocks,
            density,
            color_hit,
            avg_r,
            avg_g,
            avg_b,
            state.total_created_gaussians,
            state.assigned_blocks.size(),
            result.blocks_checked,
            result.blocks_rejected_surface,
            result.blocks_rejected_weight);
    }

    return result;
}

}  // namespace runtime_tsdf_gaussian_augmentation
}  // namespace pipeline
}  // namespace aether
