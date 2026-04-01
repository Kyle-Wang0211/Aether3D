// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_preview_seeding.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_set>
#include <vector>

#include "aether/pipeline/pipeline_coordinator.h"

namespace aether {
namespace pipeline {
namespace local_preview_seeding {
namespace {

struct SRGBToLinearLUT {
    float table[256];
    SRGBToLinearLUT() noexcept {
        for (int i = 0; i < 256; ++i) {
            float s = static_cast<float>(i) / 255.0f;
            table[i] = s <= 0.04045f ? s / 12.92f
                                     : std::pow((s + 0.055f) / 1.055f, 2.4f);
        }
    }
};

static const SRGBToLinearLUT g_srgb_lut;

inline std::uint64_t mix64(std::uint64_t x) noexcept {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline float hash_unit01(std::uint64_t seed) noexcept {
    constexpr double inv = 1.0 / static_cast<double>(std::numeric_limits<std::uint32_t>::max());
    const std::uint32_t top = static_cast<std::uint32_t>(mix64(seed) >> 32);
    return static_cast<float>(static_cast<double>(top) * inv);
}

inline float seed_gradient_score(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    int u,
    int v) noexcept {
    if (!bgra || img_w <= 2 || img_h <= 2 || u <= 0 || v <= 0 ||
        u >= img_w - 1 || v >= img_h - 1) {
        return 0.0f;
    }

    auto luminance = [&](int x, int y) noexcept -> float {
        const unsigned char* p = bgra + (y * img_w + x) * 4;
        return 0.2126f * static_cast<float>(p[2]) +
               0.7152f * static_cast<float>(p[1]) +
               0.0722f * static_cast<float>(p[0]);
    };

    const float gx = std::fabs(luminance(u + 1, v) - luminance(u - 1, v));
    const float gy = std::fabs(luminance(u, v + 1) - luminance(u, v - 1));
    return std::clamp((gx + gy) / 96.0f, 0.0f, 1.0f);
}

inline bool preview_rgb_valid(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    int u,
    int v) noexcept {
    if (!bgra || img_w <= 0 || img_h <= 0 ||
        u < 0 || v < 0 || u >= img_w || v >= img_h) {
        return false;
    }
    const unsigned char* p = bgra + (v * img_w + u) * 4;
    const float rgb_sum =
        g_srgb_lut.table[p[2]] +
        g_srgb_lut.table[p[1]] +
        g_srgb_lut.table[p[0]];
    return rgb_sum > 0.01f;
}

inline float preview_depth_validity_score(
    const float* depth,
    int depth_w,
    int depth_h,
    int du,
    int dv) noexcept {
    if (!depth || depth_w <= 0 || depth_h <= 0) {
        return 0.0f;
    }
    int valid = 0;
    int total = 0;
    for (int y = std::max(0, dv - 1); y <= std::min(depth_h - 1, dv + 1); ++y) {
        for (int x = std::max(0, du - 1); x <= std::min(depth_w - 1, du + 1); ++x) {
            const float d = depth[y * depth_w + x];
            total++;
            if (std::isfinite(d) && d > 0.10f && d < 5.00f) {
                valid++;
            }
        }
    }
    return total > 0 ? static_cast<float>(valid) / static_cast<float>(total) : 0.0f;
}

inline float preview_depth_consistency_score(
    const float* depth,
    int depth_w,
    int depth_h,
    int du,
    int dv) noexcept {
    if (!depth || depth_w <= 0 || depth_h <= 0) {
        return 0.0f;
    }
    float samples[9];
    int count = 0;
    for (int y = std::max(0, dv - 1); y <= std::min(depth_h - 1, dv + 1); ++y) {
        for (int x = std::max(0, du - 1); x <= std::min(depth_w - 1, du + 1); ++x) {
            const float d = depth[y * depth_w + x];
            if (std::isfinite(d) && d > 0.10f && d < 5.00f) {
                samples[count++] = d;
            }
        }
    }
    if (count < 3) {
        return 0.0f;
    }
    float mean = 0.0f;
    for (int i = 0; i < count; ++i) {
        mean += samples[i];
    }
    mean /= static_cast<float>(count);
    if (mean <= 1e-4f) {
        return 0.0f;
    }
    float variance = 0.0f;
    for (int i = 0; i < count; ++i) {
        const float delta = samples[i] - mean;
        variance += delta * delta;
    }
    variance /= static_cast<float>(count);
    const float rel_std = std::sqrt(variance) / mean;
    return std::clamp(1.0f - (rel_std / 0.20f), 0.0f, 1.0f);
}

inline float preview_seed_quality_score(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    int u,
    int v,
    const float* depth,
    int depth_w,
    int depth_h,
    int du,
    int dv) noexcept {
    const float gradient = seed_gradient_score(bgra, img_w, img_h, u, v);
    const float depth_validity = preview_depth_validity_score(depth, depth_w, depth_h, du, dv);
    const float depth_consistency = preview_depth_consistency_score(depth, depth_w, depth_h, du, dv);
    return std::clamp(
        0.20f * gradient +
        0.45f * depth_validity +
        0.35f * depth_consistency,
        0.0f, 1.0f);
}

inline float estimate_preview_median_depth_impl(
    const float* depth,
    int depth_w,
    int depth_h) {
    std::vector<float> valid_depths;
    valid_depths.reserve(static_cast<std::size_t>(depth_w * depth_h) / 16u + 1u);
    for (int y = 0; y < depth_h; y += 4) {
        for (int x = 0; x < depth_w; x += 4) {
            const float d = depth[y * depth_w + x];
            if (std::isfinite(d) && d > 0.10f && d < 5.00f) {
                valid_depths.push_back(d);
            }
        }
    }
    if (valid_depths.empty()) {
        return 1.0f;
    }
    const auto mid = valid_depths.begin() + static_cast<std::ptrdiff_t>(valid_depths.size() / 2u);
    std::nth_element(valid_depths.begin(), mid, valid_depths.end());
    return *mid;
}

struct ScoredPreviewFeaturePoint {
    float xyz[3]{};
    float quality{0.0f};
    std::uint64_t cell_key{0};
};

inline std::uint64_t preview_feature_cell_key(
    float x,
    float y,
    float z,
    float cell_size_m) noexcept {
    constexpr int kBias = 1 << 20;
    const float inv = 1.0f / std::max(cell_size_m, 1e-3f);
    const int ix = static_cast<int>(std::floor(x * inv)) + kBias;
    const int iy = static_cast<int>(std::floor(y * inv)) + kBias;
    const int iz = static_cast<int>(std::floor(z * inv)) + kBias;
    const std::uint64_t ux = static_cast<std::uint64_t>(std::clamp(ix, 0, (1 << 21) - 1));
    const std::uint64_t uy = static_cast<std::uint64_t>(std::clamp(iy, 0, (1 << 21) - 1));
    const std::uint64_t uz = static_cast<std::uint64_t>(std::clamp(iz, 0, (1 << 21) - 1));
    return (ux << 42u) | (uy << 21u) | uz;
}

}  // namespace

std::uint32_t synthesize_preview_feature_points_from_depth(
    FrameInput& input,
    const float* depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool init_pass) noexcept {
    if (input.feature_count > 0 ||
        !depth ||
        depth_w == 0 || depth_h == 0 ||
        input.width == 0 || input.height == 0) {
        return input.feature_count;
    }

    constexpr std::uint32_t kPreviewFeatureCap = 1024u;
    constexpr float kNearPlane = 0.10f;
    constexpr float kFarPlane = 5.00f;
    const std::uint32_t downsample_factor = init_pass ? 16u : 32u;
    const float keep_probability = 1.0f / static_cast<float>(downsample_factor);

    const float depth_sx = static_cast<float>(depth_w) /
                           static_cast<float>(std::max<std::uint32_t>(input.width, 1u));
    const float depth_sy = static_cast<float>(depth_h) /
                           static_cast<float>(std::max<std::uint32_t>(input.height, 1u));
    const float depth_fx = input.intrinsics[0] * depth_sx;
    const float depth_fy = input.intrinsics[4] * depth_sy;
    const float depth_cx = input.intrinsics[2] * depth_sx;
    const float depth_cy = input.intrinsics[5] * depth_sy;
    if (!std::isfinite(depth_fx) || !std::isfinite(depth_fy) ||
        std::abs(depth_fx) < 1e-6f || std::abs(depth_fy) < 1e-6f) {
        return 0u;
    }

    const float c0x = input.transform[0],  c0y = input.transform[1],  c0z = input.transform[2];
    const float c1x = input.transform[4],  c1y = input.transform[5],  c1z = input.transform[6];
    const float c2x = input.transform[8],  c2y = input.transform[9],  c2z = input.transform[10];
    const float tx = input.transform[12], ty = input.transform[13], tz = input.transform[14];

    std::vector<ScoredPreviewFeaturePoint> scored_points;
    scored_points.reserve(static_cast<std::size_t>(depth_w * depth_h) /
                          std::max<std::uint32_t>(downsample_factor, 1u));
    std::unordered_set<std::uint64_t> occupied_cells;
    occupied_cells.reserve(kPreviewFeatureCap * 2u);

    for (std::uint32_t dv = 0; dv < depth_h; ++dv) {
        for (std::uint32_t du = 0; du < depth_w; ++du) {
            const float d = depth[static_cast<std::size_t>(dv) * depth_w + du];
            if (!std::isfinite(d) || d < kNearPlane || d > kFarPlane) {
                continue;
            }

            const std::uint64_t sample_key =
                (static_cast<std::uint64_t>(du) << 32u) ^
                static_cast<std::uint64_t>(dv) ^
                (static_cast<std::uint64_t>(downsample_factor) << 56u);
            if (hash_unit01(sample_key) > keep_probability) {
                continue;
            }

            const int u = std::min(
                static_cast<int>(input.width) - 1,
                std::max(0, static_cast<int>((du * input.width + depth_w / 2) /
                                             std::max(depth_w, 1u))));
            const int v = std::min(
                static_cast<int>(input.height) - 1,
                std::max(0, static_cast<int>((dv * input.height + depth_h / 2) /
                                             std::max(depth_h, 1u))));
            if (!preview_rgb_valid(input.rgba.data(),
                                   static_cast<int>(input.width),
                                   static_cast<int>(input.height),
                                   u,
                                   v)) {
                continue;
            }

            const float pc_x = (static_cast<float>(du) - depth_cx) / depth_fx * d;
            const float pc_y = -(static_cast<float>(dv) - depth_cy) / depth_fy * d;
            const float pc_z = -d;
            // Match the ARKit-style convention used by the main TSDF/pipeline:
            // column 0 = right, column 1 = up, column 2 = back (= -forward).
            const float pw_x = tx + pc_x * c0x + pc_y * c1x + pc_z * c2x;
            const float pw_y = ty + pc_x * c0y + pc_y * c1y + pc_z * c2y;
            const float pw_z = tz + pc_x * c0z + pc_y * c1z + pc_z * c2z;
            if (!std::isfinite(pw_x) || !std::isfinite(pw_y) || !std::isfinite(pw_z)) {
                continue;
            }

            const std::uint64_t cell_key = preview_feature_cell_key(
                pw_x, pw_y, pw_z, 0.05f);
            if (occupied_cells.find(cell_key) != occupied_cells.end()) {
                continue;
            }

            const float quality = preview_seed_quality_score(
                input.rgba.data(),
                static_cast<int>(input.width),
                static_cast<int>(input.height),
                u,
                v,
                depth,
                static_cast<int>(depth_w),
                static_cast<int>(depth_h),
                static_cast<int>(du),
                static_cast<int>(dv));
            if (quality < 0.40f) {
                continue;
            }

            ScoredPreviewFeaturePoint point{};
            point.xyz[0] = pw_x;
            point.xyz[1] = pw_y;
            point.xyz[2] = pw_z;
            point.quality = quality;
            point.cell_key = cell_key;
            scored_points.push_back(point);
            occupied_cells.insert(cell_key);
        }
    }

    if (scored_points.size() < std::min<std::size_t>(kPreviewFeatureCap, 128u)) {
        const std::size_t target_sparse_points =
            std::min<std::size_t>(kPreviewFeatureCap, init_pass ? 256u : 128u);
        const std::uint32_t sparse_stride = init_pass ? 12u : 16u;
        for (std::uint32_t dv = 0;
             dv < depth_h && scored_points.size() < target_sparse_points;
             dv += sparse_stride) {
            for (std::uint32_t du = 0;
                 du < depth_w && scored_points.size() < target_sparse_points;
                 du += sparse_stride) {
                const float d = depth[static_cast<std::size_t>(dv) * depth_w + du];
                if (!std::isfinite(d) || d < kNearPlane || d > kFarPlane) {
                    continue;
                }

                const int u = std::min(
                    static_cast<int>(input.width) - 1,
                    std::max(0, static_cast<int>((du * input.width + depth_w / 2) /
                                                 std::max(depth_w, 1u))));
                const int v = std::min(
                    static_cast<int>(input.height) - 1,
                    std::max(0, static_cast<int>((dv * input.height + depth_h / 2) /
                                                 std::max(depth_h, 1u))));
                if (!preview_rgb_valid(input.rgba.data(),
                                       static_cast<int>(input.width),
                                       static_cast<int>(input.height),
                                       u,
                                       v)) {
                    continue;
                }

                const float pc_x = (static_cast<float>(du) - depth_cx) / depth_fx * d;
                const float pc_y = -(static_cast<float>(dv) - depth_cy) / depth_fy * d;
                const float pc_z = -d;
                const float pw_x = tx + pc_x * c0x + pc_y * c1x + pc_z * c2x;
                const float pw_y = ty + pc_x * c0y + pc_y * c1y + pc_z * c2y;
                const float pw_z = tz + pc_x * c0z + pc_y * c1z + pc_z * c2z;
                if (!std::isfinite(pw_x) || !std::isfinite(pw_y) || !std::isfinite(pw_z)) {
                    continue;
                }

                const std::uint64_t cell_key = preview_feature_cell_key(
                    pw_x, pw_y, pw_z, 0.06f);
                if (occupied_cells.find(cell_key) != occupied_cells.end()) {
                    continue;
                }

                const float fallback_quality = std::max(
                    0.10f,
                    0.30f * preview_depth_validity_score(
                        depth,
                        static_cast<int>(depth_w),
                        static_cast<int>(depth_h),
                        static_cast<int>(du),
                        static_cast<int>(dv)) +
                    0.20f * preview_depth_consistency_score(
                        depth,
                        static_cast<int>(depth_w),
                        static_cast<int>(depth_h),
                        static_cast<int>(du),
                        static_cast<int>(dv)));

                ScoredPreviewFeaturePoint point{};
                point.xyz[0] = pw_x;
                point.xyz[1] = pw_y;
                point.xyz[2] = pw_z;
                point.quality = fallback_quality;
                point.cell_key = cell_key;
                scored_points.push_back(point);
                occupied_cells.insert(cell_key);
            }
        }
    }

    if (scored_points.empty()) {
        input.feature_count = 0;
        return 0u;
    }

    if (scored_points.size() > kPreviewFeatureCap) {
        std::partial_sort(
            scored_points.begin(),
            scored_points.begin() + static_cast<std::ptrdiff_t>(kPreviewFeatureCap),
            scored_points.end(),
            [](const ScoredPreviewFeaturePoint& lhs,
               const ScoredPreviewFeaturePoint& rhs) noexcept {
                return lhs.quality > rhs.quality;
            });
        scored_points.resize(kPreviewFeatureCap);
    }

    const std::uint32_t accepted =
        static_cast<std::uint32_t>(std::min<std::size_t>(scored_points.size(), kPreviewFeatureCap));
    for (std::uint32_t index = 0; index < accepted; ++index) {
        input.feature_points[index * 3u + 0u] = scored_points[index].xyz[0];
        input.feature_points[index * 3u + 1u] = scored_points[index].xyz[1];
        input.feature_points[index * 3u + 2u] = scored_points[index].xyz[2];
    }
    input.feature_count = accepted;
    return accepted;
}

PreviewSeedStats build_preview_sampled_seeds_from_depth(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    const float* depth,
    int depth_w,
    int depth_h,
    float fx,
    float fy,
    float cx,
    float cy,
    const float* cam2world,
    bool init_pass,
    std::unordered_set<std::int64_t>& seeded_cells,
    std::vector<splat::GaussianParams>& out_new_gaussians) noexcept {
    PreviewSeedStats stats{};
    stats.init_pass = init_pass;
    stats.downsample_factor = stats.init_pass ? 16u : 32u;

    constexpr float kNearPlane = 0.10f;
    constexpr float kFarPlane = 5.00f;
    constexpr float kHashCell = 0.005f;
    constexpr float kHashInv = 1.0f / kHashCell;
    constexpr float kMinScale = 0.001f;
    constexpr float kMaxScale = 0.50f;
    const float keep_probability = 1.0f / static_cast<float>(stats.downsample_factor);
    const std::size_t preview_seed_cap = stats.init_pass ? 1536u : 768u;
    stats.median_depth = estimate_preview_median_depth_impl(depth, depth_w, depth_h);
    const float depth_to_rgb_x =
        static_cast<float>(std::max(img_w, 1)) /
        static_cast<float>(std::max(depth_w, 1));
    const float depth_to_rgb_y =
        static_cast<float>(std::max(img_h, 1)) /
        static_cast<float>(std::max(depth_h, 1));
    const float effective_leaf_scale =
        std::sqrt(static_cast<float>(std::max<std::uint32_t>(stats.downsample_factor, 1u)));
    const float leaf_w_px = std::max(1.0f, depth_to_rgb_x * effective_leaf_scale);
    const float leaf_h_px = std::max(1.0f, depth_to_rgb_y * effective_leaf_scale);

    struct ScoredPreviewSeed {
        splat::GaussianParams gaussian;
        float quality{0.0f};
        std::int64_t cell_key{0};
    };

    const float c0x = cam2world[0], c0y = cam2world[1], c0z = cam2world[2];
    const float c1x = cam2world[4], c1y = cam2world[5], c1z = cam2world[6];
    const float c2x = cam2world[8], c2y = cam2world[9], c2z = cam2world[10];
    const float tx = cam2world[12], ty = cam2world[13], tz = cam2world[14];

    std::vector<ScoredPreviewSeed> scored_preview_seeds;
    scored_preview_seeds.reserve(static_cast<std::size_t>(depth_w * depth_h) /
                                 std::max<std::uint32_t>(stats.downsample_factor, 1u) + 1u);

    for (int dv = 0; dv < depth_h; ++dv) {
        for (int du = 0; du < depth_w; ++du) {
            const float d = depth[dv * depth_w + du];
            if (d < kNearPlane || d > kFarPlane || !std::isfinite(d)) {
                continue;
            }

            const std::uint64_t sample_key =
                (static_cast<std::uint64_t>(static_cast<std::uint32_t>(du)) << 32) ^
                static_cast<std::uint64_t>(static_cast<std::uint32_t>(dv)) ^
                (static_cast<std::uint64_t>(stats.downsample_factor) << 56);
            if (hash_unit01(sample_key) > keep_probability) {
                continue;
            }
            stats.candidates++;

            const int u = std::min(
                img_w - 1,
                std::max(0, (du * img_w + depth_w / 2) / std::max(depth_w, 1))
            );
            const int v = std::min(
                img_h - 1,
                std::max(0, (dv * img_h + depth_h / 2) / std::max(depth_h, 1))
            );
            if (!preview_rgb_valid(bgra, img_w, img_h, u, v)) {
                stats.rejected++;
                continue;
            }

            const float pc_x = (static_cast<float>(u) - cx) / fx * d;
            const float pc_y = -(static_cast<float>(v) - cy) / fy * d;
            const float pc_z = -d;
            const float pw_x = tx + pc_x * c0x + pc_y * c1x + pc_z * c2x;
            const float pw_y = ty + pc_x * c0y + pc_y * c1y + pc_z * c2y;
            const float pw_z = tz + pc_x * c0z + pc_y * c1z + pc_z * c2z;

            const auto hx = static_cast<std::int64_t>(std::floor(pw_x * kHashInv));
            const auto hy = static_cast<std::int64_t>(std::floor(pw_y * kHashInv));
            const auto hz = static_cast<std::int64_t>(std::floor(pw_z * kHashInv));
            const std::int64_t key = ((hx & 0xFFFFF) << 40) |
                                     ((hy & 0xFFFFF) << 20) |
                                      (hz & 0xFFFFF);
            if (seeded_cells.count(key) > 0) {
                stats.rejected++;
                continue;
            }

            const unsigned char* p = bgra + (v * img_w + u) * 4;
            const float r = g_srgb_lut.table[p[2]];
            const float g_val = g_srgb_lut.table[p[1]];
            const float b = g_srgb_lut.table[p[0]];
            const float hw = leaf_w_px * 0.5f;
            const float hh = leaf_h_px * 0.5f;
            float scale = d * std::sqrt(hw * hw + hh * hh) / std::max(fx, 1.0f);
            scale = std::clamp(scale, kMinScale, kMaxScale);

            splat::GaussianParams gp{};
            gp.position[0] = pw_x;  gp.position[1] = pw_y;  gp.position[2] = pw_z;
            gp.color[0] = r;  gp.color[1] = g_val;  gp.color[2] = b;
            gp.opacity = 0.5f;
            gp.scale[0] = scale;  gp.scale[1] = scale;  gp.scale[2] = scale * 0.3f;
            gp.rotation[0] = 1.0f;  gp.rotation[1] = 0.0f;
            gp.rotation[2] = 0.0f;  gp.rotation[3] = 0.0f;

            const float seed_quality = preview_seed_quality_score(
                bgra, img_w, img_h, u, v, depth, depth_w, depth_h, du, dv);
            if (seed_quality < 0.45f) {
                stats.rejected++;
                continue;
            }
            scored_preview_seeds.push_back({gp, seed_quality, key});
        }
    }

    if (scored_preview_seeds.size() > preview_seed_cap) {
        std::partial_sort(
            scored_preview_seeds.begin(),
            scored_preview_seeds.begin() + static_cast<std::ptrdiff_t>(preview_seed_cap),
            scored_preview_seeds.end(),
            [](const ScoredPreviewSeed& lhs, const ScoredPreviewSeed& rhs) noexcept {
                return lhs.quality > rhs.quality;
            });
        stats.rejected += static_cast<std::uint32_t>(
            scored_preview_seeds.size() - preview_seed_cap);
        scored_preview_seeds.resize(preview_seed_cap);
    }

    out_new_gaussians.reserve(out_new_gaussians.size() + scored_preview_seeds.size());
    for (const auto& scored_seed : scored_preview_seeds) {
        seeded_cells.insert(scored_seed.cell_key);
        out_new_gaussians.push_back(scored_seed.gaussian);
        stats.accepted_quality_milli_sum += static_cast<std::uint64_t>(
            std::llround(std::clamp(scored_seed.quality, 0.0f, 1.0f) * 1000.0f));
    }
    stats.accepted = static_cast<std::uint32_t>(scored_preview_seeds.size());
    return stats;
}

}  // namespace local_preview_seeding
}  // namespace pipeline
}  // namespace aether
