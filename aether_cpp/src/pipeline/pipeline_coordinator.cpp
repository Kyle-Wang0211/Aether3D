// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/pipeline_coordinator.h"
#include "aether/pipeline/local_preview_runtime.h"
#include "aether/pipeline/local_preview_seeding.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>

#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

#include "aether/evidence/smart_anti_boost_smoother.h"
#include "aether/training/dav2_initializer.h"
#include "aether/training/mvs_initializer.h"
#include "aether/splat/ply_loader.h"
#include "aether/tsdf/adaptive_resolution.h"

namespace aether {
namespace pipeline {

// ─── sRGB → Linear LUT (256 entries, built at static init) ───
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

constexpr std::size_t kDefaultTrainingTargetSteps = 3000;
constexpr std::size_t kDefaultTrainingHardCapSteps = 10000;
constexpr std::size_t kPreviewTrainingTargetSteps = 1400;
constexpr std::size_t kPreviewTrainingHardCapSteps = 4000;
constexpr std::size_t kPreviewMaxTrainingFrames = 24;
constexpr std::size_t kPreviewFallbackSeedCount = 6000;
constexpr std::size_t kPreviewInitialSeedCap = 15000;
constexpr std::size_t kPreviewImportedVideoInitialSeedCap = 30000;
constexpr float kPreviewImportedVideoMvsPrimaryPriorRange = 6.0f;
constexpr std::uint32_t kPreviewImportedVideoMvsPrimaryPriorLevels = 0u;

struct ExportSceneBounds {
    float min[3]{0.0f, 0.0f, 0.0f};
    float max[3]{0.0f, 0.0f, 0.0f};
    float center[3]{0.0f, 0.0f, 0.0f};
    float extent[3]{0.0f, 0.0f, 0.0f};
    float radius{0.0f};
    bool valid{false};
};

struct ExportCleanupStats {
    std::size_t input_count{0};
    std::size_t kept_count{0};
    std::size_t invalid_removed{0};
    std::size_t low_opacity_removed{0};
    std::size_t oversized_removed{0};
    std::size_t elongated_removed{0};
    std::size_t coarse_block_removed{0};
    std::size_t surface_far_removed{0};
    std::size_t validation_removed{0};
    std::size_t mask_removed{0};
    std::size_t tsdf_outside_removed{0};
    std::size_t isolated_removed{0};
    std::size_t dominant_cluster_removed{0};
    std::size_t ground_preserved{0};
    float median_scale{0.0f};
    float support_radius{0.0f};
    float whitelist_margin{0.0f};
};

struct ExportValidationView {
    std::vector<float> depth;
    std::vector<unsigned char> conf;
    int width{0};
    int height{0};
    float fx{0.0f};
    float fy{0.0f};
    float cx{0.0f};
    float cy{0.0f};
    float pose[16]{};
    std::vector<unsigned char> rgba;
    int rgba_w{0};
    int rgba_h{0};
    float rgba_intrinsics[9]{};
    std::vector<std::uint8_t> whitelist_mask;
    int mask_w{0};
    int mask_h{0};
};

struct ExportGridKey {
    int x;
    int y;
    int z;

    bool operator==(const ExportGridKey& other) const noexcept {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct ExportGridKeyHash {
    std::size_t operator()(const ExportGridKey& key) const noexcept {
        std::size_t h = static_cast<std::size_t>(static_cast<std::uint32_t>(key.x));
        h = h * 1315423911u ^ static_cast<std::size_t>(static_cast<std::uint32_t>(key.y));
        h = h * 2654435761u ^ static_cast<std::size_t>(static_cast<std::uint32_t>(key.z));
        return h;
    }
};

inline bool is_finite_gaussian(const splat::GaussianParams& g) noexcept {
    for (float v : g.position) {
        if (!std::isfinite(v)) return false;
    }
    for (float v : g.scale) {
        if (!std::isfinite(v) || v <= 0.0f) return false;
    }
    if (!std::isfinite(g.opacity)) return false;
    for (float v : g.color) {
        if (!std::isfinite(v)) return false;
    }
    return true;
}

inline float gaussian_mean_scale(const splat::GaussianParams& g) noexcept {
    return (g.scale[0] + g.scale[1] + g.scale[2]) / 3.0f;
}

inline float gaussian_scale_ratio(const splat::GaussianParams& g) noexcept {
    const float max_scale = std::max({g.scale[0], g.scale[1], g.scale[2]});
    const float min_scale = std::max(std::min({g.scale[0], g.scale[1], g.scale[2]}), 1e-6f);
    return max_scale / min_scale;
}

inline ExportSceneBounds compute_gaussian_bounds(
    const std::vector<splat::GaussianParams>& gaussians) noexcept
{
    ExportSceneBounds bounds;
    if (gaussians.empty()) return bounds;

    bounds.min[0] = bounds.max[0] = gaussians.front().position[0];
    bounds.min[1] = bounds.max[1] = gaussians.front().position[1];
    bounds.min[2] = bounds.max[2] = gaussians.front().position[2];

    double cx = 0.0;
    double cy = 0.0;
    double cz = 0.0;
    for (const auto& g : gaussians) {
        bounds.min[0] = std::min(bounds.min[0], g.position[0]);
        bounds.min[1] = std::min(bounds.min[1], g.position[1]);
        bounds.min[2] = std::min(bounds.min[2], g.position[2]);
        bounds.max[0] = std::max(bounds.max[0], g.position[0]);
        bounds.max[1] = std::max(bounds.max[1], g.position[1]);
        bounds.max[2] = std::max(bounds.max[2], g.position[2]);
        cx += g.position[0];
        cy += g.position[1];
        cz += g.position[2];
    }

    const double inv_n = 1.0 / static_cast<double>(gaussians.size());
    bounds.center[0] = static_cast<float>(cx * inv_n);
    bounds.center[1] = static_cast<float>(cy * inv_n);
    bounds.center[2] = static_cast<float>(cz * inv_n);
    bounds.extent[0] = bounds.max[0] - bounds.min[0];
    bounds.extent[1] = bounds.max[1] - bounds.min[1];
    bounds.extent[2] = bounds.max[2] - bounds.min[2];

    float max_dist2 = 0.0f;
    for (const auto& g : gaussians) {
        const float dx = g.position[0] - bounds.center[0];
        const float dy = g.position[1] - bounds.center[1];
        const float dz = g.position[2] - bounds.center[2];
        max_dist2 = std::max(max_dist2, dx * dx + dy * dy + dz * dz);
    }
    bounds.radius = std::sqrt(max_dist2);
    bounds.valid = true;
    return bounds;
}

inline ExportSceneBounds compute_surface_bounds(
    const std::vector<tsdf::SurfacePoint>& surface_points) noexcept
{
    ExportSceneBounds bounds;
    if (surface_points.empty()) return bounds;

    bounds.min[0] = bounds.max[0] = surface_points.front().position[0];
    bounds.min[1] = bounds.max[1] = surface_points.front().position[1];
    bounds.min[2] = bounds.max[2] = surface_points.front().position[2];

    double cx = 0.0;
    double cy = 0.0;
    double cz = 0.0;
    for (const auto& p : surface_points) {
        bounds.min[0] = std::min(bounds.min[0], p.position[0]);
        bounds.min[1] = std::min(bounds.min[1], p.position[1]);
        bounds.min[2] = std::min(bounds.min[2], p.position[2]);
        bounds.max[0] = std::max(bounds.max[0], p.position[0]);
        bounds.max[1] = std::max(bounds.max[1], p.position[1]);
        bounds.max[2] = std::max(bounds.max[2], p.position[2]);
        cx += p.position[0];
        cy += p.position[1];
        cz += p.position[2];
    }

    const double inv_n = 1.0 / static_cast<double>(surface_points.size());
    bounds.center[0] = static_cast<float>(cx * inv_n);
    bounds.center[1] = static_cast<float>(cy * inv_n);
    bounds.center[2] = static_cast<float>(cz * inv_n);
    bounds.extent[0] = bounds.max[0] - bounds.min[0];
    bounds.extent[1] = bounds.max[1] - bounds.min[1];
    bounds.extent[2] = bounds.max[2] - bounds.min[2];

    float max_dist2 = 0.0f;
    for (const auto& p : surface_points) {
        const float dx = p.position[0] - bounds.center[0];
        const float dy = p.position[1] - bounds.center[1];
        const float dz = p.position[2] - bounds.center[2];
        max_dist2 = std::max(max_dist2, dx * dx + dy * dy + dz * dz);
    }
    bounds.radius = std::sqrt(max_dist2);
    bounds.valid = true;
    return bounds;
}

inline bool inside_expanded_bounds(const splat::GaussianParams& g,
                                   const ExportSceneBounds& bounds,
                                   float margin) noexcept
{
    return g.position[0] >= bounds.min[0] - margin &&
           g.position[0] <= bounds.max[0] + margin &&
           g.position[1] >= bounds.min[1] - margin &&
           g.position[1] <= bounds.max[1] + margin &&
           g.position[2] >= bounds.min[2] - margin &&
           g.position[2] <= bounds.max[2] + margin;
}

inline ExportGridKey make_export_grid_key(const splat::GaussianParams& g,
                                          float cell_size) noexcept
{
    const float inv_cell = 1.0f / std::max(cell_size, 1e-5f);
    return ExportGridKey{
        static_cast<int>(std::floor(g.position[0] * inv_cell)),
        static_cast<int>(std::floor(g.position[1] * inv_cell)),
        static_cast<int>(std::floor(g.position[2] * inv_cell)),
    };
}

inline ExportGridKey make_export_grid_key(const tsdf::SurfacePoint& p,
                                          float cell_size) noexcept
{
    const float inv_cell = 1.0f / std::max(cell_size, 1e-5f);
    return ExportGridKey{
        static_cast<int>(std::floor(p.position[0] * inv_cell)),
        static_cast<int>(std::floor(p.position[1] * inv_cell)),
        static_cast<int>(std::floor(p.position[2] * inv_cell)),
    };
}

inline ExportGridKey make_export_grid_key(float x, float y, float z,
                                          float cell_size) noexcept
{
    const float inv_cell = 1.0f / std::max(cell_size, 1e-5f);
    return ExportGridKey{
        static_cast<int>(std::floor(x * inv_cell)),
        static_cast<int>(std::floor(y * inv_cell)),
        static_cast<int>(std::floor(z * inv_cell)),
    };
}

inline float nth_quantile_copy(std::vector<float> values, float q) noexcept
{
    if (values.empty()) return 0.0f;
    const float clamped = std::clamp(q, 0.0f, 1.0f);
    const std::size_t index = std::min<std::size_t>(
        values.size() - 1,
        static_cast<std::size_t>(std::llround(clamped * static_cast<float>(values.size() - 1))));
    std::nth_element(values.begin(),
                     values.begin() + static_cast<std::ptrdiff_t>(index),
                     values.end());
    return values[index];
}

inline bool sample_export_validation_depth(const ExportValidationView& view,
                                           float wx, float wy, float wz,
                                           float* out_frame_depth,
                                           float* out_camera_depth) noexcept
{
    if (view.depth.empty() || view.width <= 2 || view.height <= 2) return false;

    const float dwx = wx - view.pose[12];
    const float dwy = wy - view.pose[13];
    const float dwz = wz - view.pose[14];

    const float cam_x =  (view.pose[0] * dwx + view.pose[1] * dwy + view.pose[2] * dwz);
    const float cam_y = -(view.pose[4] * dwx + view.pose[5] * dwy + view.pose[6] * dwz);
    const float cam_z = -(view.pose[8] * dwx + view.pose[9] * dwy + view.pose[10] * dwz);
    if (cam_z <= 0.1f) return false;

    const int iu = static_cast<int>(std::lround(view.fx * cam_x / cam_z + view.cx));
    const int iv = static_cast<int>(std::lround(view.fy * cam_y / cam_z + view.cy));
    if (iu < 1 || iv < 1 || iu >= view.width - 1 || iv >= view.height - 1) return false;

    float depth_samples[9];
    int sample_count = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            const std::size_t idx = static_cast<std::size_t>(iv + dy) * static_cast<std::size_t>(view.width) +
                                    static_cast<std::size_t>(iu + dx);
            const float d = view.depth[idx];
            const bool confident_enough = view.conf.empty() || view.conf[idx] > 0;
            if (confident_enough && std::isfinite(d) && d > 0.05f) {
                depth_samples[sample_count++] = d;
            }
        }
    }
    if (sample_count < 3) return false;

    std::nth_element(depth_samples,
                     depth_samples + sample_count / 2,
                     depth_samples + sample_count);
    *out_frame_depth = depth_samples[sample_count / 2];
    *out_camera_depth = cam_z;
    return true;
}

inline bool sample_export_validation_color_linear(const ExportValidationView& view,
                                                  float wx, float wy, float wz,
                                                  float out_rgb[3]) noexcept
{
    if (view.rgba.empty() || view.rgba_w <= 0 || view.rgba_h <= 0) return false;

    const float dwx = wx - view.pose[12];
    const float dwy = wy - view.pose[13];
    const float dwz = wz - view.pose[14];

    const float cam_x =  (view.pose[0] * dwx + view.pose[1] * dwy + view.pose[2] * dwz);
    const float cam_y = -(view.pose[4] * dwx + view.pose[5] * dwy + view.pose[6] * dwz);
    const float cam_z = -(view.pose[8] * dwx + view.pose[9] * dwy + view.pose[10] * dwz);
    if (cam_z <= 0.1f) return false;

    const int iu = static_cast<int>(std::lround(view.rgba_intrinsics[0] * cam_x / cam_z + view.rgba_intrinsics[2]));
    const int iv = static_cast<int>(std::lround(view.rgba_intrinsics[4] * cam_y / cam_z + view.rgba_intrinsics[5]));
    if (iu < 0 || iv < 0 || iu >= view.rgba_w || iv >= view.rgba_h) return false;

    const std::size_t idx =
        (static_cast<std::size_t>(iv) * static_cast<std::size_t>(view.rgba_w) +
         static_cast<std::size_t>(iu)) * 4u;
    const std::uint8_t* px = view.rgba.data() + idx;
    out_rgb[0] = g_srgb_lut.table[px[2]];
    out_rgb[1] = g_srgb_lut.table[px[1]];
    out_rgb[2] = g_srgb_lut.table[px[0]];
    return true;
}

inline bool project_export_validation_point(const ExportValidationView& view,
                                            float wx, float wy, float wz,
                                            float* out_u,
                                            float* out_v,
                                            float* out_camera_depth) noexcept
{
    const float dwx = wx - view.pose[12];
    const float dwy = wy - view.pose[13];
    const float dwz = wz - view.pose[14];

    const float cam_x =  (view.pose[0] * dwx + view.pose[1] * dwy + view.pose[2] * dwz);
    const float cam_y = -(view.pose[4] * dwx + view.pose[5] * dwy + view.pose[6] * dwz);
    const float cam_z = -(view.pose[8] * dwx + view.pose[9] * dwy + view.pose[10] * dwz);
    if (cam_z <= 0.1f) return false;

    *out_u = view.fx * cam_x / cam_z + view.cx;
    *out_v = view.fy * cam_y / cam_z + view.cy;
    if (out_camera_depth) *out_camera_depth = cam_z;
    return true;
}

inline void build_export_validation_whitelist_mask(
    ExportValidationView* view,
    const std::vector<tsdf::SurfacePoint>& surface_points,
    float median_scale) noexcept
{
    if (!view || view->width <= 0 || view->height <= 0 || surface_points.empty()) return;

    view->mask_w = view->width;
    view->mask_h = view->height;
    view->whitelist_mask.assign(static_cast<std::size_t>(view->mask_w) *
                                    static_cast<std::size_t>(view->mask_h),
                                0u);

    const int dilation_radius = median_scale > 0.02f ? 3 : 2;
    for (const auto& p : surface_points) {
        float u = 0.0f;
        float v = 0.0f;
        float cam_z = 0.0f;
        if (!project_export_validation_point(*view,
                                             p.position[0], p.position[1], p.position[2],
                                             &u, &v, &cam_z)) {
            continue;
        }
        const int iu = static_cast<int>(std::lround(u));
        const int iv = static_cast<int>(std::lround(v));
        if (iu < 0 || iv < 0 || iu >= view->mask_w || iv >= view->mask_h) continue;

        for (int dy = -dilation_radius; dy <= dilation_radius; ++dy) {
            const int yy = iv + dy;
            if (yy < 0 || yy >= view->mask_h) continue;
            for (int dx = -dilation_radius; dx <= dilation_radius; ++dx) {
                const int xx = iu + dx;
                if (xx < 0 || xx >= view->mask_w) continue;
                view->whitelist_mask[static_cast<std::size_t>(yy) *
                                         static_cast<std::size_t>(view->mask_w) +
                                     static_cast<std::size_t>(xx)] = 255u;
            }
        }
    }
}

inline void refine_export_validation_whitelist_mask_with_rgba(
    ExportValidationView* view) noexcept
{
    if (!view ||
        view->whitelist_mask.empty() ||
        view->mask_w <= 2 ||
        view->mask_h <= 2 ||
        view->rgba.empty() ||
        view->rgba_w <= 0 ||
        view->rgba_h <= 0) {
        return;
    }

    int min_x = view->mask_w;
    int min_y = view->mask_h;
    int max_x = -1;
    int max_y = -1;
    double mean_r = 0.0;
    double mean_g = 0.0;
    double mean_b = 0.0;
    std::size_t seed_count = 0;

    const auto sample_linear_rgb = [&](int mask_x, int mask_y, float out_rgb[3]) noexcept -> bool {
        if (mask_x < 0 || mask_y < 0 || mask_x >= view->mask_w || mask_y >= view->mask_h) return false;
        const float u = (static_cast<float>(mask_x) + 0.5f) *
                        static_cast<float>(view->rgba_w) /
                        static_cast<float>(view->mask_w);
        const float v = (static_cast<float>(mask_y) + 0.5f) *
                        static_cast<float>(view->rgba_h) /
                        static_cast<float>(view->mask_h);
        const int iu = std::clamp(static_cast<int>(std::lround(u - 0.5f)), 0, view->rgba_w - 1);
        const int iv = std::clamp(static_cast<int>(std::lround(v - 0.5f)), 0, view->rgba_h - 1);
        const std::size_t idx =
            (static_cast<std::size_t>(iv) * static_cast<std::size_t>(view->rgba_w) +
             static_cast<std::size_t>(iu)) * 4u;
        if (idx + 2u >= view->rgba.size()) return false;
        const std::uint8_t* px = view->rgba.data() + idx;
        out_rgb[0] = g_srgb_lut.table[px[2]];
        out_rgb[1] = g_srgb_lut.table[px[1]];
        out_rgb[2] = g_srgb_lut.table[px[0]];
        return true;
    };

    for (int y = 0; y < view->mask_h; ++y) {
        for (int x = 0; x < view->mask_w; ++x) {
            const std::size_t idx =
                static_cast<std::size_t>(y) * static_cast<std::size_t>(view->mask_w) +
                static_cast<std::size_t>(x);
            if (view->whitelist_mask[idx] == 0u) continue;
            min_x = std::min(min_x, x);
            min_y = std::min(min_y, y);
            max_x = std::max(max_x, x);
            max_y = std::max(max_y, y);
            float rgb[3]{0.0f, 0.0f, 0.0f};
            if (!sample_linear_rgb(x, y, rgb)) continue;
            mean_r += rgb[0];
            mean_g += rgb[1];
            mean_b += rgb[2];
            seed_count++;
        }
    }

    if (seed_count == 0 || max_x < min_x || max_y < min_y) return;
    const float inv_seed = 1.0f / static_cast<float>(seed_count);
    const float mean_rgb[3]{
        static_cast<float>(mean_r * inv_seed),
        static_cast<float>(mean_g * inv_seed),
        static_cast<float>(mean_b * inv_seed),
    };
    const float mean_luma =
        0.2126f * mean_rgb[0] + 0.7152f * mean_rgb[1] + 0.0722f * mean_rgb[2];

    const int pad = std::max(4, static_cast<int>(std::lround(
        0.08f * static_cast<float>(std::max(view->mask_w, view->mask_h)))));
    const int box_min_x = std::max(0, min_x - pad);
    const int box_min_y = std::max(0, min_y - pad);
    const int box_max_x = std::min(view->mask_w - 1, max_x + pad);
    const int box_max_y = std::min(view->mask_h - 1, max_y + pad);

    std::vector<std::uint8_t> visited(static_cast<std::size_t>(view->mask_w) *
                                          static_cast<std::size_t>(view->mask_h),
                                      0u);
    std::vector<std::pair<int, int>> queue;
    queue.reserve(static_cast<std::size_t>((box_max_x - box_min_x + 1) *
                                           (box_max_y - box_min_y + 1)));

    for (int y = box_min_y; y <= box_max_y; ++y) {
        for (int x = box_min_x; x <= box_max_x; ++x) {
            const std::size_t idx =
                static_cast<std::size_t>(y) * static_cast<std::size_t>(view->mask_w) +
                static_cast<std::size_t>(x);
            if (view->whitelist_mask[idx] > 0u) {
                visited[idx] = 1u;
                queue.emplace_back(x, y);
            }
        }
    }

    constexpr int kNeighborDx[4]{1, -1, 0, 0};
    constexpr int kNeighborDy[4]{0, 0, 1, -1};
    std::size_t head = 0;
    while (head < queue.size()) {
        const auto [x, y] = queue[head++];
        for (int n = 0; n < 4; ++n) {
            const int nx = x + kNeighborDx[n];
            const int ny = y + kNeighborDy[n];
            if (nx < box_min_x || ny < box_min_y || nx > box_max_x || ny > box_max_y) continue;
            const std::size_t nidx =
                static_cast<std::size_t>(ny) * static_cast<std::size_t>(view->mask_w) +
                static_cast<std::size_t>(nx);
            if (visited[nidx]) continue;
            visited[nidx] = 1u;

            float rgb[3]{0.0f, 0.0f, 0.0f};
            if (!sample_linear_rgb(nx, ny, rgb)) continue;
            const float dr = rgb[0] - mean_rgb[0];
            const float dg = rgb[1] - mean_rgb[1];
            const float db = rgb[2] - mean_rgb[2];
            const float color_dist = std::sqrt(dr * dr + dg * dg + db * db);
            const float luma = 0.2126f * rgb[0] + 0.7152f * rgb[1] + 0.0722f * rgb[2];
            const float luma_delta = std::fabs(luma - mean_luma);
            if (color_dist <= 0.24f && luma_delta <= 0.18f) {
                view->whitelist_mask[nidx] = 255u;
                queue.emplace_back(nx, ny);
            }
        }
    }
}

inline bool sample_export_validation_whitelist_mask(const ExportValidationView& view,
                                                    float wx, float wy, float wz) noexcept
{
    if (view.whitelist_mask.empty() || view.mask_w <= 2 || view.mask_h <= 2) return false;

    float u = 0.0f;
    float v = 0.0f;
    if (!project_export_validation_point(view, wx, wy, wz, &u, &v, nullptr)) return false;

    const int iu = static_cast<int>(std::lround(u));
    const int iv = static_cast<int>(std::lround(v));
    if (iu < 1 || iv < 1 || iu >= view.mask_w - 1 || iv >= view.mask_h - 1) return false;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            const std::size_t idx =
                static_cast<std::size_t>(iv + dy) * static_cast<std::size_t>(view.mask_w) +
                static_cast<std::size_t>(iu + dx);
            if (view.whitelist_mask[idx] > 0u) {
                return true;
            }
        }
    }
    return false;
}

inline std::vector<splat::GaussianParams> clean_export_gaussians(
    const std::vector<splat::GaussianParams>& input,
    const ExportSceneBounds* whitelist_bounds,
    const std::vector<tsdf::SurfacePoint>* surface_points,
    const std::vector<ExportValidationView>* validation_views,
    ExportCleanupStats* stats_out) noexcept
{
    ExportCleanupStats local_stats;
    local_stats.input_count = input.size();
    if (input.empty()) {
        if (stats_out) *stats_out = local_stats;
        return {};
    }

    std::vector<float> scales;
    scales.reserve(input.size());
    for (const auto& g : input) {
        if (is_finite_gaussian(g)) {
            scales.push_back(gaussian_mean_scale(g));
        }
    }
    if (scales.empty()) {
        if (stats_out) *stats_out = local_stats;
        return input;
    }

    const std::size_t mid = scales.size() / 2;
    std::nth_element(scales.begin(), scales.begin() + static_cast<std::ptrdiff_t>(mid), scales.end());
    local_stats.median_scale = std::max(scales[mid], 1e-4f);

    ExportSceneBounds gaussian_bounds = compute_gaussian_bounds(input);
    const float scene_extent = std::max({gaussian_bounds.extent[0],
                                         gaussian_bounds.extent[1],
                                         gaussian_bounds.extent[2],
                                         local_stats.median_scale});
    const float scene_radius = std::max(gaussian_bounds.radius, scene_extent * 0.5f);
    const float oversize_threshold = std::max({local_stats.median_scale * 4.8f,
                                               scene_radius * 0.052f,
                                               0.009f});
    local_stats.whitelist_margin = whitelist_bounds && whitelist_bounds->valid
        ? std::max({local_stats.median_scale * 2.5f,
                    std::max({whitelist_bounds->extent[0],
                              whitelist_bounds->extent[1],
                              whitelist_bounds->extent[2]}) * 0.03f,
                    0.015f})
        : 0.0f;
    const float cell_size = std::max({local_stats.median_scale * 1.7f,
                                      scene_radius * 0.015f,
                                      0.010f});
    local_stats.support_radius = cell_size * 1.10f;

    std::vector<splat::GaussianParams> candidates;
    candidates.reserve(input.size());
    for (const auto& g : input) {
        if (!is_finite_gaussian(g)) {
            local_stats.invalid_removed++;
            continue;
        }
        if (g.opacity < 0.16f) {
            local_stats.low_opacity_removed++;
            continue;
        }
        const float mean_scale = gaussian_mean_scale(g);
        const float scale_ratio = gaussian_scale_ratio(g);
        const bool oversized_and_unstable =
            mean_scale > oversize_threshold &&
            (g.opacity < 0.90f || scale_ratio > 2.8f || mean_scale > oversize_threshold * 1.25f);
        if (oversized_and_unstable) {
            local_stats.oversized_removed++;
            continue;
        }
        const bool weak_and_big = g.opacity < 0.36f && mean_scale > local_stats.median_scale * 2.05f;
        const bool elongated = scale_ratio > 6.8f &&
            (mean_scale > local_stats.median_scale * 1.20f || g.opacity < 0.68f);
        if (weak_and_big || elongated) {
            local_stats.elongated_removed++;
            continue;
        }
        if (whitelist_bounds && whitelist_bounds->valid &&
            !inside_expanded_bounds(g, *whitelist_bounds, local_stats.whitelist_margin)) {
            local_stats.tsdf_outside_removed++;
            continue;
        }
        candidates.push_back(g);
    }

    if (candidates.empty()) {
        if (stats_out) *stats_out = local_stats;
        return input;
    }

    std::unordered_map<ExportGridKey, std::uint32_t, ExportGridKeyHash> support_grid;
    support_grid.reserve(candidates.size() * 2);
    for (const auto& g : candidates) {
        ++support_grid[make_export_grid_key(g, cell_size)];
    }

    struct CoarseSupportStats {
        std::uint32_t count{0};
        float opacity_sum{0.0f};
        float scale_sum{0.0f};
        float max_scale{0.0f};
        float max_ratio{0.0f};
    };

    const float coarse_cell_size = std::max(cell_size * 2.75f, 0.03f);
    std::unordered_map<ExportGridKey, CoarseSupportStats, ExportGridKeyHash> coarse_grid;
    coarse_grid.reserve(candidates.size());
    for (const auto& g : candidates) {
        const float mean_scale = gaussian_mean_scale(g);
        const float scale_ratio = gaussian_scale_ratio(g);
        auto& coarse = coarse_grid[make_export_grid_key(g, coarse_cell_size)];
        coarse.count += 1;
        coarse.opacity_sum += g.opacity;
        coarse.scale_sum += mean_scale;
        coarse.max_scale = std::max(coarse.max_scale, mean_scale);
        coarse.max_ratio = std::max(coarse.max_ratio, scale_ratio);
    }

    struct SurfaceSupportStats {
        std::uint32_t count{0};
        float confidence_sum{0.0f};
        float weight_sum{0.0f};
    };

    const bool has_surface_reference = surface_points && surface_points->size() >= 256;
    const float surface_cell_size = std::max({cell_size * 1.45f,
                                              local_stats.median_scale * 1.25f,
                                              0.012f});
    std::unordered_map<ExportGridKey, SurfaceSupportStats, ExportGridKeyHash> surface_grid;
    if (has_surface_reference) {
        surface_grid.reserve(surface_points->size());
        for (const auto& p : *surface_points) {
            auto& sample = surface_grid[make_export_grid_key(p, surface_cell_size)];
            sample.count += 1;
            sample.confidence_sum += static_cast<float>(p.confidence) / 255.0f;
            sample.weight_sum += static_cast<float>(p.weight) / 255.0f;
        }
    }

    std::vector<splat::GaussianParams> filtered;
    filtered.reserve(candidates.size());
    for (const auto& g : candidates) {
        const ExportGridKey key = make_export_grid_key(g, cell_size);
        const float mean_scale = gaussian_mean_scale(g);
        const float scale_ratio = gaussian_scale_ratio(g);

        std::uint32_t support = 0;
        float weighted_support = 0.0f;
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    const auto it = support_grid.find(ExportGridKey{key.x + dx, key.y + dy, key.z + dz});
                    if (it != support_grid.end()) {
                        support += it->second;
                        weighted_support += static_cast<float>(it->second);
                    }
                }
            }
        }

        const bool near_whitelist_edge = [&]() noexcept {
            if (!(whitelist_bounds && whitelist_bounds->valid)) return false;
            const float dx = std::min(g.position[0] - whitelist_bounds->min[0],
                                      whitelist_bounds->max[0] - g.position[0]);
            const float dy = std::min(g.position[1] - whitelist_bounds->min[1],
                                      whitelist_bounds->max[1] - g.position[1]);
            const float dz = std::min(g.position[2] - whitelist_bounds->min[2],
                                      whitelist_bounds->max[2] - g.position[2]);
            const float interior_distance = std::min({dx, dy, dz});
            return interior_distance <= std::max(local_stats.whitelist_margin * 1.2f,
                                                 cell_size * 2.0f);
        }();

        // Keep dense, scene-supported splats by default. Allow isolated splats to survive
        // only when they are compact and fairly confident, mirroring Clean-GS's
        // "preserve well-supported structure, prune floaters" behavior.
        const bool compact_confident = g.opacity >= 0.74f &&
            mean_scale <= local_stats.median_scale * 1.75f &&
            scale_ratio <= 4.0f;
        const bool weak_local_support =
            support <= 4 ||
            (weighted_support < 7.0f && g.opacity < 0.48f) ||
            (support <= 8 && mean_scale > local_stats.median_scale * 1.70f) ||
            (weighted_support < 10.0f && scale_ratio > 5.0f) ||
            (near_whitelist_edge && support <= 12 && g.opacity < 0.58f &&
             mean_scale > local_stats.median_scale * 1.25f);

        std::uint32_t surface_support = 0;
        float surface_confidence = 0.0f;
        float surface_weight = 0.0f;
        if (has_surface_reference) {
            const ExportGridKey surface_key = make_export_grid_key(
                g.position[0], g.position[1], g.position[2], surface_cell_size);
            for (int dz = -1; dz <= 1; ++dz) {
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        const auto it = surface_grid.find(ExportGridKey{
                            surface_key.x + dx,
                            surface_key.y + dy,
                            surface_key.z + dz,
                        });
                        if (it != surface_grid.end()) {
                            surface_support += it->second.count;
                            surface_confidence += it->second.confidence_sum;
                            surface_weight += it->second.weight_sum;
                        }
                    }
                }
            }
        }
        const bool surface_backed =
            !has_surface_reference ||
            surface_support >= 2 ||
            (surface_support >= 1 &&
             (surface_confidence >= 0.35f || surface_weight >= 0.30f) &&
             !near_whitelist_edge);

        int depth_views = 0;
        int depth_consistent = 0;
        int depth_front_violations = 0;
        int depth_back_violations = 0;
        int color_views = 0;
        int color_consistent = 0;
        int mask_views = 0;
        int mask_hits = 0;
        if (validation_views && !validation_views->empty()) {
            for (const auto& view : *validation_views) {
                float frame_depth = 0.0f;
                float camera_depth = 0.0f;
                if (sample_export_validation_depth(view,
                                                   g.position[0], g.position[1], g.position[2],
                                                   &frame_depth, &camera_depth)) {
                    depth_views++;
                    const float depth_tolerance = std::max(0.035f, mean_scale * 1.8f);
                    if (std::abs(camera_depth - frame_depth) <= depth_tolerance) {
                        depth_consistent++;
                    } else if (camera_depth < frame_depth - 0.025f) {
                        depth_front_violations++;
                    } else if (camera_depth > frame_depth + depth_tolerance) {
                        depth_back_violations++;
                    }
                }

                float sampled_rgb[3];
                if (sample_export_validation_color_linear(view,
                                                          g.position[0], g.position[1], g.position[2],
                                                          sampled_rgb)) {
                    color_views++;
                    const float color_error =
                        (std::abs(sampled_rgb[0] - g.color[0]) +
                         std::abs(sampled_rgb[1] - g.color[1]) +
                         std::abs(sampled_rgb[2] - g.color[2])) / 3.0f;
                    if (color_error <= 0.18f) {
                        color_consistent++;
                    }
                }

                if (!view.whitelist_mask.empty()) {
                    mask_views++;
                    if (sample_export_validation_whitelist_mask(view,
                                                                g.position[0], g.position[1], g.position[2])) {
                        mask_hits++;
                    }
                }
            }
        }

        bool coarse_low_confidence_block = false;
        if (const auto coarse_it = coarse_grid.find(make_export_grid_key(g, coarse_cell_size));
            coarse_it != coarse_grid.end()) {
            const CoarseSupportStats& coarse = coarse_it->second;
            const float average_opacity = coarse.opacity_sum / std::max<float>(static_cast<float>(coarse.count), 1.0f);
            const float average_scale = coarse.scale_sum / std::max<float>(static_cast<float>(coarse.count), 1.0f);
            const bool coarse_shape_bad =
                average_scale > local_stats.median_scale * 1.70f ||
                coarse.max_scale > oversize_threshold * 0.72f ||
                coarse.max_ratio > 6.25f;
            coarse_low_confidence_block =
                coarse.count >= 6 &&
                coarse.count <= 28 &&
                average_opacity < 0.56f &&
                coarse_shape_bad &&
                (near_whitelist_edge || weak_local_support);
        }
        if (coarse_low_confidence_block &&
            (weak_local_support || g.opacity < 0.70f) &&
            (g.opacity < 0.76f ||
             mean_scale > local_stats.median_scale * 1.22f ||
             scale_ratio > 4.6f)) {
            local_stats.coarse_block_removed++;
            continue;
        }

        const bool off_surface_smear =
            has_surface_reference &&
            !surface_backed &&
            (near_whitelist_edge ||
             weak_local_support ||
             mean_scale > local_stats.median_scale * 1.18f ||
             scale_ratio > 4.2f ||
             g.opacity < 0.72f);
        if (off_surface_smear && !compact_confident) {
            local_stats.surface_far_removed++;
            continue;
        }

        const bool depth_validation_failed =
            depth_views >= 2 &&
            depth_consistent == 0 &&
            (depth_front_violations + depth_back_violations) >= 2;
        const bool multi_view_inconsistent =
            depth_views >= 3 &&
            depth_consistent * 3 < depth_views &&
            (depth_back_violations >= 2 || (!surface_backed && depth_front_violations >= 1));
        const bool color_validation_failed =
            color_views >= 2 &&
            color_consistent * 2 < color_views &&
            !surface_backed &&
            (weak_local_support || g.opacity < 0.72f);
        const bool mask_guided_prune =
            mask_views >= 2 &&
            mask_hits == 0 &&
            !surface_backed &&
            (weak_local_support ||
             near_whitelist_edge ||
             mean_scale > local_stats.median_scale * 1.12f ||
             scale_ratio > 3.8f ||
             g.opacity < 0.78f);
        if (mask_guided_prune && !compact_confident) {
            local_stats.mask_removed++;
            continue;
        }
        if ((depth_validation_failed || multi_view_inconsistent || color_validation_failed) &&
            !compact_confident) {
            local_stats.validation_removed++;
            continue;
        }

        if (weak_local_support && !compact_confident) {
            local_stats.isolated_removed++;
            continue;
        }
        filtered.push_back(g);
    }

    if (filtered.empty()) {
        filtered = std::move(candidates);
    }

    if (has_surface_reference && filtered.size() >= 256) {
        struct ComponentVoxel {
            std::uint32_t count{0};
            std::uint32_t surface_hits{0};
            float sum_x{0.0f};
            float sum_y{0.0f};
            float sum_z{0.0f};
        };

        const float component_cell_size = std::max({cell_size * 2.15f,
                                                    local_stats.median_scale * 1.85f,
                                                    0.03f});
        std::unordered_map<ExportGridKey, ComponentVoxel, ExportGridKeyHash> component_grid;
        component_grid.reserve(filtered.size());

        auto has_surface_support_near = [&](float x, float y, float z) noexcept {
            const ExportGridKey surface_key = make_export_grid_key(x, y, z, surface_cell_size);
            std::uint32_t support = 0;
            for (int dz = -1; dz <= 1; ++dz) {
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        const auto it = surface_grid.find(ExportGridKey{
                            surface_key.x + dx,
                            surface_key.y + dy,
                            surface_key.z + dz,
                        });
                        if (it != surface_grid.end()) {
                            support += it->second.count;
                        }
                    }
                }
            }
            return support > 0;
        };

        for (const auto& g : filtered) {
            const ExportGridKey key = make_export_grid_key(g, component_cell_size);
            auto& voxel = component_grid[key];
            voxel.count += 1;
            voxel.sum_x += g.position[0];
            voxel.sum_y += g.position[1];
            voxel.sum_z += g.position[2];
            if (has_surface_support_near(g.position[0], g.position[1], g.position[2])) {
                voxel.surface_hits += 1;
            }
        }

        std::vector<ExportGridKey> voxel_keys;
        voxel_keys.reserve(component_grid.size());
        std::unordered_map<ExportGridKey, int, ExportGridKeyHash> voxel_index;
        voxel_index.reserve(component_grid.size() * 2);
        for (const auto& [key, voxel] : component_grid) {
            if (voxel.count == 0) continue;
            voxel_index.emplace(key, static_cast<int>(voxel_keys.size()));
            voxel_keys.push_back(key);
        }

        if (voxel_keys.size() >= 4) {
            std::vector<int> component_of(voxel_keys.size(), -1);
            struct ComponentStats {
                std::uint32_t voxels{0};
                std::uint32_t gaussian_count{0};
                std::uint32_t surface_hits{0};
                float score{0.0f};
            };
            std::vector<ComponentStats> components;
            std::vector<int> stack;
            stack.reserve(voxel_keys.size());

            for (std::size_t start = 0; start < voxel_keys.size(); ++start) {
                if (component_of[start] >= 0) continue;
                const int component_id = static_cast<int>(components.size());
                components.push_back({});
                stack.clear();
                stack.push_back(static_cast<int>(start));
                component_of[start] = component_id;
                while (!stack.empty()) {
                    const int current = stack.back();
                    stack.pop_back();
                    const ExportGridKey& key = voxel_keys[static_cast<std::size_t>(current)];
                    const auto voxel_it = component_grid.find(key);
                    if (voxel_it == component_grid.end()) continue;
                    const ComponentVoxel& voxel = voxel_it->second;
                    auto& stats = components[static_cast<std::size_t>(component_id)];
                    stats.voxels += 1;
                    stats.gaussian_count += voxel.count;
                    stats.surface_hits += voxel.surface_hits;
                    for (const ExportGridKey neighbor : {
                             ExportGridKey{key.x - 1, key.y, key.z},
                             ExportGridKey{key.x + 1, key.y, key.z},
                             ExportGridKey{key.x, key.y - 1, key.z},
                             ExportGridKey{key.x, key.y + 1, key.z},
                             ExportGridKey{key.x, key.y, key.z - 1},
                             ExportGridKey{key.x, key.y, key.z + 1},
                         }) {
                        const auto it = voxel_index.find(neighbor);
                        if (it == voxel_index.end()) continue;
                        const int idx = it->second;
                        if (component_of[static_cast<std::size_t>(idx)] >= 0) continue;
                        component_of[static_cast<std::size_t>(idx)] = component_id;
                        stack.push_back(idx);
                    }
                }
            }

            int best_component = -1;
            float best_score = -1.0f;
            for (std::size_t i = 0; i < components.size(); ++i) {
                auto& stats = components[i];
                stats.score = static_cast<float>(stats.gaussian_count) +
                    static_cast<float>(stats.surface_hits) * 1.8f +
                    static_cast<float>(stats.voxels) * 0.6f;
                if (stats.score > best_score) {
                    best_score = stats.score;
                    best_component = static_cast<int>(i);
                }
            }

            if (best_component >= 0) {
                std::unordered_set<ExportGridKey, ExportGridKeyHash> dominant_voxels;
                dominant_voxels.reserve(voxel_keys.size());
                std::vector<float> dominant_y;
                std::vector<float> dominant_radial;
                dominant_y.reserve(filtered.size());
                dominant_radial.reserve(filtered.size());
                float dominant_cx = 0.0f;
                float dominant_cz = 0.0f;
                std::size_t dominant_count = 0;
                for (std::size_t i = 0; i < voxel_keys.size(); ++i) {
                    if (component_of[i] != best_component) continue;
                    dominant_voxels.insert(voxel_keys[i]);
                    const auto voxel_it = component_grid.find(voxel_keys[i]);
                    if (voxel_it == component_grid.end() || voxel_it->second.count == 0) continue;
                    dominant_cx += voxel_it->second.sum_x;
                    dominant_cz += voxel_it->second.sum_z;
                    dominant_count += voxel_it->second.count;
                }
                if (dominant_count > 0) {
                    dominant_cx /= static_cast<float>(dominant_count);
                    dominant_cz /= static_cast<float>(dominant_count);
                }

                for (const auto& g : filtered) {
                    const ExportGridKey key = make_export_grid_key(g, component_cell_size);
                    if (dominant_voxels.find(key) == dominant_voxels.end()) continue;
                    dominant_y.push_back(g.position[1]);
                    const float dx = g.position[0] - dominant_cx;
                    const float dz = g.position[2] - dominant_cz;
                    dominant_radial.push_back(std::sqrt(dx * dx + dz * dz));
                }

                const float dominant_y10 = nth_quantile_copy(dominant_y, 0.10f);
                const float dominant_y20 = nth_quantile_copy(dominant_y, 0.20f);
                const float dominant_y35 = nth_quantile_copy(dominant_y, 0.35f);
                const float dominant_radius = std::max({
                    nth_quantile_copy(dominant_radial, 0.92f) * 1.35f,
                    scene_radius * 0.10f,
                    local_stats.median_scale * 12.0f,
                    0.08f,
                });
                const float slab_low = dominant_y10 - std::max({
                    scene_radius * 0.06f,
                    local_stats.median_scale * 8.0f,
                    0.05f,
                });
                const float slab_high = dominant_y35 + std::max({
                    scene_radius * 0.04f,
                    local_stats.median_scale * 6.0f,
                    0.03f,
                });

                std::vector<splat::GaussianParams> dominant_filtered;
                dominant_filtered.reserve(filtered.size());
                for (const auto& g : filtered) {
                    const ExportGridKey key = make_export_grid_key(g, component_cell_size);
                    const bool in_dominant = dominant_voxels.find(key) != dominant_voxels.end();
                    if (in_dominant) {
                        dominant_filtered.push_back(g);
                        continue;
                    }

                    if (!has_surface_support_near(g.position[0], g.position[1], g.position[2])) {
                        local_stats.dominant_cluster_removed++;
                        continue;
                    }
                    const float dx = g.position[0] - dominant_cx;
                    const float dz = g.position[2] - dominant_cz;
                    const float radial = std::sqrt(dx * dx + dz * dz);
                    const float mean_scale = gaussian_mean_scale(g);
                    const bool in_support_slab =
                        radial <= dominant_radius &&
                        g.position[1] >= slab_low &&
                        g.position[1] <= slab_high &&
                        mean_scale <= std::max(local_stats.median_scale * 2.4f, 0.015f) &&
                        g.opacity >= 0.18f;
                    if (in_support_slab) {
                        dominant_filtered.push_back(g);
                        local_stats.ground_preserved++;
                    } else {
                        local_stats.dominant_cluster_removed++;
                    }
                }
                if (!dominant_filtered.empty()) {
                    filtered = std::move(dominant_filtered);
                }
            }
        }
    }

    local_stats.kept_count = filtered.size();
    if (stats_out) *stats_out = local_stats;
    return filtered;
}

inline std::size_t compute_dynamic_training_target_steps(
    std::size_t gaussian_count,
    std::size_t frame_count,
    std::size_t base_steps,
    std::size_t hard_cap_steps) noexcept
{
    const std::size_t base =
        std::max<std::size_t>(base_steps, kDefaultTrainingTargetSteps);
    const std::size_t hard_cap = std::max<std::size_t>(hard_cap_steps, base);

    // Sub-linear scaling: global engine converges in ~2000-3000 steps total.
    // Previous coefficients (220/480) produced 34K+ targets — way too high.
    // With TSDF-initialized positions (1-2cm accuracy), MCMC, and Student-t,
    // convergence is much faster than from-scratch training.
    const double gaussian_term = 30.0 *
        std::sqrt(static_cast<double>(std::max<std::size_t>(gaussian_count, 1)));
    const double frame_term = 60.0 *
        std::sqrt(static_cast<double>(std::max<std::size_t>(frame_count, 1)));

    const std::size_t dynamic_target = base +
        static_cast<std::size_t>(std::llround(gaussian_term + frame_term));
    return std::min(dynamic_target, hard_cap);
}

inline training::TrainingProgress apply_training_budget(
    training::TrainingProgress progress,
    std::size_t target_steps,
    std::size_t hard_cap_steps) noexcept
{
    const std::size_t engine_floor = std::max<std::size_t>(progress.total_steps, 1);
    const std::size_t hard_cap = std::max<std::size_t>(hard_cap_steps, engine_floor);
    const std::size_t budget_floor = std::max<std::size_t>(target_steps, engine_floor);
    progress.total_steps = std::min(budget_floor, hard_cap);
    progress.is_complete = (progress.step >= progress.total_steps);
    return progress;
}

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

inline void normalize3(float& x, float& y, float& z) noexcept {
    const float len = std::sqrt(x * x + y * y + z * z);
    if (len > 1e-6f) {
        x /= len;
        y /= len;
        z /= len;
    } else {
        x = 0.0f;
        y = 1.0f;
        z = 0.0f;
    }
}

inline void set_identity4x4(float m[16]) noexcept {
    std::memset(m, 0, sizeof(float) * 16);
    m[0] = 1.0f;
    m[5] = 1.0f;
    m[10] = 1.0f;
    m[15] = 1.0f;
}

inline bool sample_frame_color_linear(const pipeline::FrameInput& frame,
                                      float wx,
                                      float wy,
                                      float wz,
                                      float out_rgb[3]) noexcept {
    if (frame.rgba.empty() || frame.width == 0 || frame.height == 0) return false;

    const float dwx = wx - frame.transform[12];
    const float dwy = wy - frame.transform[13];
    const float dwz = wz - frame.transform[14];

    const float cam_x =  (frame.transform[0] * dwx + frame.transform[1] * dwy + frame.transform[2] * dwz);
    const float cam_y = -(frame.transform[4] * dwx + frame.transform[5] * dwy + frame.transform[6] * dwz);
    const float cam_z = -(frame.transform[8] * dwx + frame.transform[9] * dwy + frame.transform[10] * dwz);
    if (cam_z <= 0.1f) return false;

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
    const std::uint8_t* px = frame.rgba.data() + idx;
    // Input buffer is BGRA; convert to linear RGB.
    out_rgb[0] = g_srgb_lut.table[px[2]];
    out_rgb[1] = g_srgb_lut.table[px[1]];
    out_rgb[2] = g_srgb_lut.table[px[0]];
    return true;
}

inline bool sample_selected_frame_color_linear(
    const pipeline::SelectedFrame& frame,
    float wx,
    float wy,
    float wz,
    float out_rgb[3]) noexcept {
    if (frame.rgba.empty() || frame.width == 0 || frame.height == 0) return false;

    const float dwx = wx - frame.transform[12];
    const float dwy = wy - frame.transform[13];
    const float dwz = wz - frame.transform[14];

    const float cam_x =  (frame.transform[0] * dwx + frame.transform[1] * dwy + frame.transform[2] * dwz);
    const float cam_y = -(frame.transform[4] * dwx + frame.transform[5] * dwy + frame.transform[6] * dwz);
    const float cam_z = -(frame.transform[8] * dwx + frame.transform[9] * dwy + frame.transform[10] * dwz);
    if (cam_z <= 0.1f) return false;

    const float u = frame.intrinsics[0] * cam_x / cam_z + frame.intrinsics[2];
    const float v = frame.intrinsics[1] * cam_y / cam_z + frame.intrinsics[3];
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
    const std::uint8_t* px = frame.rgba.data() + idx;
    out_rgb[0] = g_srgb_lut.table[px[2]];
    out_rgb[1] = g_srgb_lut.table[px[1]];
    out_rgb[2] = g_srgb_lut.table[px[0]];
    return true;
}

// ─── GSFusion per-frame quadtree helpers ─────────────────────────────────────
// Directly adapted from GSFusion (BSD-3-Clause):
//   Smart Robotics Lab, TU Munich / Jiaxin Wei (2024)
//   src/gs/quad_tree.cu  +  singleres_tsdf_gs_updater_impl.hpp
//
// Algorithm: recursively subdivide image into quadtree leaves based on
// luminance-weighted RGB MSE. Leaf centres are backprojected to 3D via depth.

struct GsfQTLeaf { int x0, y0, w, h; };

inline std::size_t compute_hard_cap_steps_for_mode(
    bool local_preview_mode,
    std::size_t current_hard_cap_steps,
    std::size_t base_steps) noexcept
{
    if (local_preview_mode) {
        const std::size_t preview_floor = std::max<std::size_t>(
            base_steps * 2, kPreviewTrainingHardCapSteps);
        return std::min(
            std::max<std::size_t>(current_hard_cap_steps, preview_floor),
            std::max<std::size_t>(preview_floor, kPreviewTrainingHardCapSteps));
    }
    return std::max<std::size_t>(
        current_hard_cap_steps,
        std::max<std::size_t>(base_steps * 6, kDefaultTrainingHardCapSteps));
}

inline std::size_t compute_target_steps_for_mode(
    bool local_preview_mode,
    std::size_t gaussian_count,
    std::size_t frame_count,
    std::size_t base_steps,
    std::size_t hard_cap_steps) noexcept
{
    if (!local_preview_mode) {
        return compute_dynamic_training_target_steps(
            gaussian_count, frame_count, base_steps, hard_cap_steps);
    }

    const std::size_t preview_base = std::max<std::size_t>(
        base_steps, kPreviewTrainingTargetSteps);
    const std::size_t preview_cap = std::max<std::size_t>(
        hard_cap_steps, preview_base);
    const double gaussian_term = 18.0 *
        std::sqrt(static_cast<double>(std::max<std::size_t>(gaussian_count, 1)));
    const double frame_term = 40.0 *
        std::sqrt(static_cast<double>(std::max<std::size_t>(frame_count, 1)));
    const std::size_t dynamic_target = preview_base +
        static_cast<std::size_t>(std::llround(gaussian_term + frame_term));
    return std::min(dynamic_target, preview_cap);
}

/// Compute GSFusion quadtree error for a pixel region.
/// Formula: luminance_MSE × (img_w × img_h) / 90_000_000  (GSFusion verbatim).
static float gsf_qtree_error(
    const unsigned char* bgra, int img_w,
    int x0, int y0, int w, int h, float img_scale) noexcept
{
    float sum_r = 0.f, sum_g = 0.f, sum_b = 0.f;
    float sum_r2 = 0.f, sum_g2 = 0.f, sum_b2 = 0.f;
    const int n = w * h;
    for (int y = y0; y < y0 + h; ++y) {
        const unsigned char* row = bgra + y * img_w * 4;
        for (int x = x0; x < x0 + w; ++x) {
            const unsigned char* p = row + x * 4;
            float r = static_cast<float>(p[2]);  // BGRA → R
            float g = static_cast<float>(p[1]);  // BGRA → G
            float b = static_cast<float>(p[0]);  // BGRA → B
            sum_r += r;  sum_g += g;  sum_b += b;
            sum_r2 += r * r;  sum_g2 += g * g;  sum_b2 += b * b;
        }
    }
    float inv = 1.0f / static_cast<float>(n);
    float mse_r = sum_r2 * inv - (sum_r * inv) * (sum_r * inv);
    float mse_g = sum_g2 * inv - (sum_g * inv) * (sum_g * inv);
    float mse_b = sum_b2 * inv - (sum_b * inv) * (sum_b * inv);
    // GSFusion luminance weighting (ITU-R BT.601)
    return (0.2989f * mse_r + 0.5870f * mse_g + 0.1140f * mse_b) * img_scale;
}

/// Recursively subdivide image region into quadtree leaves.
static void gsf_qtree_subdivide(
    const unsigned char* bgra, int img_w,
    int x0, int y0, int w, int h,
    float threshold, int min_pixel_size, float img_scale,
    std::vector<GsfQTLeaf>& leaves)
{
    const float error = gsf_qtree_error(bgra, img_w, x0, y0, w, h, img_scale);
    const int hw  = w / 2,  hw2 = w - hw;
    const int hh  = h / 2,  hh2 = h - hh;
    if (error <= threshold || hw <= min_pixel_size || hh <= min_pixel_size) {
        leaves.push_back({x0, y0, w, h});
        return;
    }
    gsf_qtree_subdivide(bgra, img_w, x0,      y0,      hw,  hh,  threshold, min_pixel_size, img_scale, leaves);
    gsf_qtree_subdivide(bgra, img_w, x0 + hw, y0,      hw2, hh,  threshold, min_pixel_size, img_scale, leaves);
    gsf_qtree_subdivide(bgra, img_w, x0,      y0 + hh, hw,  hh2, threshold, min_pixel_size, img_scale, leaves);
    gsf_qtree_subdivide(bgra, img_w, x0 + hw, y0 + hh, hw2, hh2, threshold, min_pixel_size, img_scale, leaves);
}

}  // namespace

using local_preview_runtime::PreviewPrefilterDecision;
using local_preview_runtime::bootstrap_imported_video_intrinsics;
using local_preview_runtime::evaluate_preview_import_prefilter;
using local_preview_runtime::extract_camera_pose_metrics;
using local_preview_runtime::preview_frame_selection_config;
using local_preview_runtime::sanitize_frame_selection_config;
using local_preview_runtime::should_accept_preview_keyframe;
using local_preview_runtime::should_submit_preview_depth_prior;
using local_preview_runtime::update_imported_video_bootstrap_pose;
using local_preview_seeding::PreviewSeedStats;
using local_preview_seeding::build_preview_sampled_seeds_from_depth;
using local_preview_seeding::synthesize_preview_feature_points_from_depth;

// ═══════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ═══════════════════════════════════════════════════════════════════════

PipelineCoordinator::PipelineCoordinator(
    render::GPUDevice& device,
    splat::SplatRenderEngine& renderer,
    const CoordinatorConfig& config) noexcept
    : device_(device),
      renderer_(renderer),
      config_(config),
      frame_selector_(config.local_preview_mode
          ? preview_frame_selection_config(config.frame_selection)
          : sanitize_frame_selection_config(config.frame_selection)),
      thermal_predictor_(config.thermal) {
    std::fprintf(
        stderr,
        "[Aether3D][CoreBuild] PCOORD_2026_03_05_FEATURE_SNAPSHOT_V1 file=%s\n",
        __FILE__);

    // ─── Initialize DAv2 Dual Depth Inference Engines (C++ core layer) ───
    // Replaces Swift-layer DepthAnythingV2Bridge.
    // On iOS: runs on Neural Engine via CoreML.
    //
    // Dual-model cross-validation architecture:
    //   Small (~48MB): runs every frame, ~31ms on A14, ~25ms on A16
    //   Large (~638MB): runs every N frames, ~80ms on A14, higher quality
    //   Cross-validation: consensus depth from both models = more robust
    //
    // If model_path is nullptr or model fails to load: graceful fallback.
    // Both fail → MVS-only initialization (no crash).

    if (config_.local_preview_mode) {
        config_.training.max_iterations = std::min<std::size_t>(
            std::max<std::size_t>(config_.training.max_iterations, kPreviewTrainingTargetSteps),
            kPreviewTrainingHardCapSteps);
        config_.training.max_gaussians = std::min<std::size_t>(
            config_.training.max_gaussians, 120000u);
    }

    // ── Small model (primary, every frame) ──
    if (config.depth_model_path) {
        depth_engine_small_ = create_depth_inference_engine(
            config.depth_model_path, "Small");
        if (depth_engine_small_ && depth_engine_small_->is_available()) {
            std::fprintf(stderr,
                "[Aether3D] DAv2 Small engine: available (%ux%u, Neural Engine)\n",
                depth_engine_small_->model_input_width(),
                depth_engine_small_->model_input_height());
        } else {
            std::fprintf(stderr,
                "[Aether3D] DAv2 Small engine: load failed at %s\n",
                config.depth_model_path);
            depth_engine_small_.reset();
        }
    } else {
        std::fprintf(stderr,
            "[Aether3D] DAv2 Small engine: no model path configured\n");
    }

    // ── Large model (cross-validation, every N frames) ──
    // Secondary RAM check in C++ (belt-and-suspenders with Swift gate).
    // iPhone 12 (A14, 4GB): Large model ANE compilation fails, CPU fallback
    // causes memory starvation + ARKit tracking loss. Block it here too.
    {
        bool large_blocked_by_memory = false;
#ifdef __APPLE__
        std::size_t ram_bytes = 0;
        std::size_t ram_size = sizeof(ram_bytes);
        if (sysctlbyname("hw.memsize", &ram_bytes, &ram_size, nullptr, 0) == 0) {
            double ram_gb = static_cast<double>(ram_bytes) / (1024.0 * 1024.0 * 1024.0);
            std::fprintf(stderr,
                "[Aether3D] C++ RAM check: %.2f GB (Large model threshold: 8.0 GB)\n",
                ram_gb);
            // 8.0 GB threshold: only iPhone 15 Pro+ has sufficient RAM to load Large
            // model without causing ARKit VIO initialization failure.
            // Devices with 6 GB (iPhone 12-15 non-Pro) experience:
            //   "World tracking performance is being affected by resource constraints"
            // when Large model loads concurrently with ARKit startup → VIO never
            // initializes → TSDF integration skipped → blocks=0 for entire session.
            if (ram_gb < 8.0) {
                large_blocked_by_memory = true;
                std::fprintf(stderr,
                    "[Aether3D] C++ RAM gate: BLOCKING Large model (%.2fGB < 8.0GB — LiDAR+Small sufficient)\n",
                    ram_gb);
            }
        }
#endif
        if (config.local_preview_mode && config.depth_model_path_large) {
            std::fprintf(stderr,
                "[Aether3D] DAv2 Large engine: disabled for local_preview_mode "
                "(small monocular prior only)\n");
        } else if (config.depth_model_path_large && !large_blocked_by_memory) {
            depth_engine_large_ = create_depth_inference_engine(
                config.depth_model_path_large, "Large");
            if (depth_engine_large_ && depth_engine_large_->is_available()) {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: available (%ux%u, interval=%u)\n",
                    depth_engine_large_->model_input_width(),
                    depth_engine_large_->model_input_height(),
                    config.large_model_interval);
            } else {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: load failed at %s\n",
                    config.depth_model_path_large);
                depth_engine_large_.reset();
            }
        } else {
            if (large_blocked_by_memory && config.depth_model_path_large) {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: BLOCKED by C++ RAM gate "
                    "(path was provided but device has insufficient RAM)\n");
            } else {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: no model path configured "
                    "(single-model mode)\n");
            }
        }
    }

    if (!depth_engine_small_ && !depth_engine_large_) {
        std::fprintf(stderr,
            "[Aether3D] DAv2: both models unavailable → fallback to MVS-only\n");
    }

    // Initialize TSDF volume (replaces point cloud accumulation + quality grid)
    tsdf_volume_ = std::make_unique<tsdf::TSDFVolume>();

    const std::size_t base_steps = config_.local_preview_mode
        ? std::max<std::size_t>(config_.training.max_iterations, kPreviewTrainingTargetSteps)
        : std::max<std::size_t>(config_.training.max_iterations, kDefaultTrainingTargetSteps);
    const std::size_t hard_cap_steps = compute_hard_cap_steps_for_mode(
        config_.local_preview_mode, training_hard_cap_steps_.load(std::memory_order_relaxed), base_steps);
    training_target_steps_.store(base_steps, std::memory_order_relaxed);
    training_hard_cap_steps_.store(hard_cap_steps, std::memory_order_relaxed);

    std::fprintf(stderr,
        "[Aether3D][PreviewMode] local_preview=%s min_frames=%zu max_iter=%zu "
        "frame_window=%zu large_depth=%s target=%zu hard_cap=%zu\n",
        config_.local_preview_mode ? "YES" : "NO",
        config_.min_frames_to_start_training,
        config_.training.max_iterations,
        config_.local_preview_mode ? kPreviewMaxTrainingFrames : std::size_t(30),
        depth_engine_large_ ? "enabled" : "disabled",
        training_target_steps_.load(std::memory_order_relaxed),
        training_hard_cap_steps_.load(std::memory_order_relaxed));

    start_threads();
}

PipelineCoordinator::~PipelineCoordinator() noexcept {
    stop_threads();
    delete training_engine_;
}

// ═══════════════════════════════════════════════════════════════════════
// Main Thread API
// ═══════════════════════════════════════════════════════════════════════

int PipelineCoordinator::on_frame(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
    const float* transform, const float* intrinsics,
    const float* feature_xyz, std::uint32_t feature_count,
    const float* ne_depth, std::uint32_t ne_depth_w, std::uint32_t ne_depth_h,
    const float* lidar_depth, std::uint32_t lidar_w, std::uint32_t lidar_h,
    int thermal_state) noexcept {

    if (!running_.load(std::memory_order_relaxed)) return 1;

    // Update thermal state
    thermal_predictor_.set_thermal_state(thermal_state);

    // ── Core backpressure gate (MonoGS-style throttle at source) ──
    // Keep source-side dropping conservative:
    //   - only hard-drop when queue is effectively full
    //   - do NOT soft-drop every other frame (that starves ingestion)
    // This keeps real-time stability while preserving enough frames for
    // TSDF/overlay growth in long scans.
    const std::size_t frame_backlog = frame_queue_.size_approx();
    const std::size_t queue_cap = frame_queue_.capacity();
    const std::size_t hard_drop_threshold = queue_cap;
    const std::uint32_t accepted = frame_counter_.load(std::memory_order_relaxed);
    if (queue_cap > 0 && frame_backlog >= hard_drop_threshold) {
        auto drops = frame_drop_count_.fetch_add(1, std::memory_order_relaxed) + 1;
        const auto seen = accepted + drops;
        if (drops <= 5 || (drops % 30 == 0)) {
            std::fprintf(stderr,
                "[Aether3D] Frame DROPPED by backpressure (queue=%zu/%zu, %u/%u total, %.1f%% loss)\n",
                frame_backlog, queue_cap, drops, seen,
                seen > 0 ? 100.0f * static_cast<float>(drops) / static_cast<float>(seen) : 0.0f);
        }
        return 1;
    }

    // Build FrameInput envelope
    FrameInput input;
    const std::size_t pixel_count = static_cast<std::size_t>(w) * h * 4;
    input.rgba.assign(rgba, rgba + pixel_count);
    input.width = w;
    input.height = h;
    std::memcpy(input.transform, transform, 16 * sizeof(float));
    std::memcpy(input.intrinsics, intrinsics, 9 * sizeof(float));

    const std::uint32_t clamped_features = std::min(feature_count, 1024u);
    const std::uint32_t valid_features = (feature_xyz != nullptr) ? clamped_features : 0u;
    if (valid_features > 0) {
        std::memcpy(input.feature_points, feature_xyz,
                    valid_features * 3 * sizeof(float));
    }
    input.feature_count = valid_features;

    // Neural Engine depth (every frame from DAv2)
    if (ne_depth && ne_depth_w > 0 && ne_depth_h > 0) {
        const std::size_t depth_size = static_cast<std::size_t>(ne_depth_w) * ne_depth_h;
        input.ne_depth.assign(ne_depth, ne_depth + depth_size);
        input.ne_depth_w = ne_depth_w;
        input.ne_depth_h = ne_depth_h;
    }

    // LiDAR depth (optional)
    if (lidar_depth && lidar_w > 0 && lidar_h > 0) {
        const std::size_t lidar_size = static_cast<std::size_t>(lidar_w) * lidar_h;
        input.lidar_depth.assign(lidar_depth, lidar_depth + lidar_size);
        input.lidar_w = lidar_w;
        input.lidar_h = lidar_h;
    }

    input.thermal_state = thermal_state;

    auto now = std::chrono::steady_clock::now();
    input.timestamp = std::chrono::duration<double>(now.time_since_epoch()).count();

    // Non-blocking enqueue (drop on overflow)
    if (!frame_queue_.try_push(std::move(input))) {
        auto drops = frame_drop_count_.fetch_add(1, std::memory_order_relaxed) + 1;
        auto accepted = frame_counter_.load(std::memory_order_relaxed);
        auto seen = accepted + drops;
        if (drops <= 5 || (drops % 30 == 0)) {
            std::fprintf(stderr,
                "[Aether3D] Frame DROPPED (%u/%u total, %.1f%% loss)\n",
                drops, seen, seen > 0 ? 100.0f * drops / seen : 0.0f);
        }
        return 1;
    }

    frame_counter_.fetch_add(1, std::memory_order_relaxed);
    return 0;
}

int PipelineCoordinator::on_imported_video_frame(
    const std::uint8_t* rgba,
    std::uint32_t w,
    std::uint32_t h,
    const float* imported_intrinsics,
    int imported_intrinsics_source,
    double timestamp_seconds,
    std::uint32_t frame_index,
    std::uint32_t total_frames,
    int thermal_state) noexcept {
    if (!config_.local_preview_mode) return -1;
    if (!rgba || w == 0 || h == 0) return -1;

    if (frame_index == 0u) {
        imported_video_bootstrap_pose_initialized_ = false;
        set_identity4x4(imported_video_bootstrap_pose_);
        imported_video_bootstrap_target_points_world_.clear();
        imported_video_bootstrap_target_normals_world_.clear();
        imported_video_bootstrap_intrinsics_initialized_ = false;
        std::memset(imported_video_bootstrap_intrinsics_, 0, sizeof(imported_video_bootstrap_intrinsics_));
        depth_keyframes_.clear();
        has_keyframe_ = false;
        has_preview_selected_keyframe_ = false;
        preview_dav2_seed_initialized_ = false;
        preview_last_seed_attempt_depth_frames_ = 0;
        preview_depth_phase_ms_.store(0, std::memory_order_relaxed);
        preview_seed_phase_ms_.store(0, std::memory_order_relaxed);
        preview_refine_phase_ms_.store(0, std::memory_order_relaxed);
        preview_depth_batches_submitted_.store(0, std::memory_order_relaxed);
        preview_depth_results_ready_.store(0, std::memory_order_relaxed);
        preview_depth_reuse_frames_.store(0, std::memory_order_relaxed);
        preview_prefilter_accepts_.store(0, std::memory_order_relaxed);
        preview_prefilter_brightness_rejects_.store(0, std::memory_order_relaxed);
        preview_prefilter_blur_rejects_.store(0, std::memory_order_relaxed);
        preview_keyframe_gate_accepts_.store(0, std::memory_order_relaxed);
        preview_keyframe_gate_rejects_.store(0, std::memory_order_relaxed);
        preview_seed_candidates_.store(0, std::memory_order_relaxed);
        preview_seed_accepted_.store(0, std::memory_order_relaxed);
        preview_seed_rejected_.store(0, std::memory_order_relaxed);
        preview_seed_quality_milli_sum_.store(0, std::memory_order_relaxed);
        preview_frames_enqueued_.store(0, std::memory_order_relaxed);
        preview_frames_ingested_.store(0, std::memory_order_relaxed);
        preview_depth_frames_since_submit_ = 0;
        has_preview_depth_request_ = false;
        no_depth_consecutive_ = 0;
        frame_selector_.reset();
        selected_frame_count_.store(0, std::memory_order_relaxed);
        training_converged_.store(false, std::memory_order_release);
        features_frozen_.store(false, std::memory_order_release);
        scanning_active_.store(true, std::memory_order_release);
    }

    const auto frame_backlog = frame_queue_.size_approx();
    constexpr std::size_t queue_cap = 256;
    if (frame_backlog >= queue_cap - 1) {
        auto drops = frame_drop_count_.fetch_add(1, std::memory_order_relaxed) + 1;
        auto accepted = frame_counter_.load(std::memory_order_relaxed);
        const auto seen = accepted + drops;
        if (drops <= 5 || (drops % 30 == 0)) {
            std::fprintf(stderr,
                "[Aether3D] ImportedVideo frame DROPPED by backpressure (queue=%zu/%zu, %u/%u total, %.1f%% loss)\n",
                frame_backlog, queue_cap, drops, seen,
                seen > 0 ? 100.0f * static_cast<float>(drops) / static_cast<float>(seen) : 0.0f);
        }
        return 1;
    }

    float transform[16];
    float intrinsics[9];
    set_identity4x4(transform);
    const bool has_imported_intrinsics =
        imported_intrinsics &&
        std::isfinite(imported_intrinsics[0]) &&
        std::isfinite(imported_intrinsics[4]) &&
        imported_intrinsics[0] > 1.0f &&
        imported_intrinsics[4] > 1.0f;
    const bool use_self_calibrated_intrinsics =
        imported_intrinsics_source != 1 &&
        imported_video_bootstrap_intrinsics_initialized_ &&
        std::isfinite(imported_video_bootstrap_intrinsics_[0]) &&
        std::isfinite(imported_video_bootstrap_intrinsics_[4]) &&
        imported_video_bootstrap_intrinsics_[0] > 1.0f &&
        imported_video_bootstrap_intrinsics_[4] > 1.0f;
    if (has_imported_intrinsics && imported_intrinsics_source == 1) {
        std::memcpy(intrinsics, imported_intrinsics, sizeof(intrinsics));
    } else if (use_self_calibrated_intrinsics) {
        std::memcpy(intrinsics, imported_video_bootstrap_intrinsics_, sizeof(intrinsics));
    } else if (has_imported_intrinsics) {
        std::memcpy(intrinsics, imported_intrinsics, sizeof(intrinsics));
    } else {
        bootstrap_imported_video_intrinsics(w, h, intrinsics);
    }
    const char* intrinsics_source_label = "colmap_default";
    if (use_self_calibrated_intrinsics) {
        intrinsics_source_label =
            imported_intrinsics_source == 2
                ? "self_calibrated_metadata_35mm"
                : "self_calibrated_colmap_default";
    } else if (has_imported_intrinsics) {
        switch (imported_intrinsics_source) {
        case 2:
            intrinsics_source_label = "metadata_35mm";
            break;
        case 1:
        default:
            intrinsics_source_label = "real";
            break;
        }
    }
    static std::uint32_t imported_video_intrinsics_log_count = 0;
    imported_video_intrinsics_log_count++;
    if (imported_video_intrinsics_log_count <= 8 ||
        imported_video_intrinsics_log_count % 24 == 0) {
        std::fprintf(
            stderr,
            "[Aether3D][PreviewIntrinsics] frame=%u source=%s fx=%.1f fy=%.1f cx=%.1f cy=%.1f\n",
            frame_index + 1u,
            intrinsics_source_label,
            intrinsics[0],
            intrinsics[4],
            intrinsics[2],
            intrinsics[5]);
    }

    FrameInput input;
    const std::size_t pixel_count = static_cast<std::size_t>(w) * h * 4;
    input.rgba.assign(rgba, rgba + pixel_count);
    input.width = w;
    input.height = h;
    std::memcpy(input.transform, transform, sizeof(input.transform));
    std::memcpy(input.intrinsics, intrinsics, sizeof(input.intrinsics));
    input.feature_count = 0;
    input.imported_video = true;
    input.imported_intrinsics_source = imported_intrinsics_source;
    input.source_frame_index = frame_index;
    input.source_total_frames = total_frames;
    input.thermal_state = thermal_state;

    if (std::isfinite(timestamp_seconds) && timestamp_seconds >= 0.0) {
        input.timestamp = timestamp_seconds;
    } else {
        const auto now = std::chrono::steady_clock::now();
        input.timestamp = std::chrono::duration<double>(now.time_since_epoch()).count();
    }

    if (!frame_queue_.try_push(std::move(input))) {
        auto drops = frame_drop_count_.fetch_add(1, std::memory_order_relaxed) + 1;
        auto accepted = frame_counter_.load(std::memory_order_relaxed);
        const auto seen = accepted + drops;
        if (drops <= 5 || (drops % 30 == 0)) {
            std::fprintf(stderr,
                "[Aether3D] ImportedVideo frame DROPPED (%u/%u total, %.1f%% loss)\n",
                drops, seen, seen > 0 ? 100.0f * drops / seen : 0.0f);
        }
        return 1;
    }

    frame_counter_.fetch_add(1, std::memory_order_relaxed);
    preview_frames_enqueued_.fetch_add(1, std::memory_order_relaxed);
    return 0;
}

EvidenceSnapshot PipelineCoordinator::get_snapshot() const noexcept {
    // const_cast safe: read_buffer() only reads the reader slot
    auto& self = const_cast<PipelineCoordinator&>(*this);
    auto snapshot = self.evidence_snapshot_.read_buffer();
    snapshot.preview_frames_enqueued =
        preview_frames_enqueued_.load(std::memory_order_relaxed);
    snapshot.preview_frames_ingested =
        preview_frames_ingested_.load(std::memory_order_relaxed);
    snapshot.preview_frame_backlog =
        static_cast<std::uint32_t>(frame_queue_.size_approx());
    snapshot.preview_depth_batches_submitted =
        preview_depth_batches_submitted_.load(std::memory_order_relaxed);
    snapshot.preview_depth_results_ready =
        preview_depth_results_ready_.load(std::memory_order_relaxed);
    snapshot.preview_depth_reuse_frames =
        preview_depth_reuse_frames_.load(std::memory_order_relaxed);
    snapshot.preview_keyframe_gate_accepts =
        preview_keyframe_gate_accepts_.load(std::memory_order_relaxed);
    snapshot.preview_keyframe_gate_rejects =
        preview_keyframe_gate_rejects_.load(std::memory_order_relaxed);
    snapshot.selected_frames =
        selected_frame_count_.load(std::memory_order_relaxed);
    snapshot.frame_count =
        frame_counter_.load(std::memory_order_relaxed);
    return snapshot;
}

PipelineCoordinator::RenderSnapshot PipelineCoordinator::get_render_snapshot() noexcept {
    const auto& pc = pointcloud_buffer_.read_buffer();
    RenderSnapshot snap;
    snap.pc_vertices = pc.vertices.empty() ? nullptr : pc.vertices.data();
    snap.pc_count = pc.vertices.size();
    snap.pc_alpha = pc.blend_alpha;
    snap.tsdf_block_count = pc.tsdf_block_count;

    // Merge staging → cpu_buffer before reading.
    // Training thread writes via push_splats() which goes to staging_buffer_.
    // begin_frame() merges staging into cpu_buffer_ (+ uploads to GPU).
    // Without this call, the Swift OIR rendering path never sees splat data
    // because GaussianSplatViewController's beginFrame() only runs in the viewer.
    if (renderer_alive_.load(std::memory_order_acquire)) {
        renderer_.begin_frame();

        const auto& packed = renderer_.packed_data();
        snap.packed_splats = packed.empty() ? nullptr : packed.data();
        snap.splat_count = packed.size();
    } else {
        snap.packed_splats = nullptr;
        snap.splat_count = 0;
    }

    // Quality overlay (triple-buffered alongside point cloud, thread-safe)
    snap.overlay_vertices = pc.overlay.empty()
        ? nullptr : pc.overlay.data();
    snap.overlay_count = pc.overlay.size();

    return snap;
}

void PipelineCoordinator::finish_scanning() noexcept {
    const bool imported_video_preview_pending =
        config_.local_preview_mode &&
        preview_frames_enqueued_.load(std::memory_order_acquire) >
            preview_frames_ingested_.load(std::memory_order_acquire);
    // Imported-video local_preview submits frames in a burst. We should stop
    // accepting new frames now, but defer the actual feature/depth freeze
    // until Thread A has drained the queued imported-video frames. Freezing
    // immediately here cuts off the tail of the queue and leaves later frames
    // stuck with feat=0 / stale depth, which is exactly what turns the result
    // into a cigar/stick.
    if (!imported_video_preview_pending) {
        // Freeze TSDF integration — prevents Thread A from modifying
        // TSDF volume while main thread reads it during PLY export.
        features_frozen_.store(true, std::memory_order_release);
    }
    scanning_active_.store(false, std::memory_order_release);

    // NOTE: We intentionally do NOT call training_engine_->request_stop() here.
    // Training must continue after scanning finishes — the user watches the
    // post-scan training progress screen.  The destructor (stop_threads) calls
    // request_stop() when the coordinator is actually torn down.
    // The push_batch() bounds check in packed_splats.h prevents heap corruption.

    // Frame drop diagnostic summary
    auto total = frame_counter_.load(std::memory_order_relaxed);
    auto drops = frame_drop_count_.load(std::memory_order_relaxed);
    std::fprintf(stderr,
        imported_video_preview_pending
            ? "[Aether3D] Scan finished: %u frames accepted, %u dropped (%.1f%% loss) — deferring feature freeze until imported-video queue drains (%u/%u ingested)\n"
            : "[Aether3D] Scan finished: %u frames accepted, %u dropped (%.1f%% loss)\n",
        total, drops, total > 0 ? 100.0f * drops / (total + drops) : 0.0f,
        preview_frames_ingested_.load(std::memory_order_relaxed),
        preview_frames_enqueued_.load(std::memory_order_relaxed));
}

void PipelineCoordinator::set_thermal_state(int level) noexcept {
    thermal_predictor_.set_thermal_state(level);
}

void PipelineCoordinator::request_enhance(std::size_t extra_iterations) noexcept {
    enhance_iters_.fetch_add(extra_iterations, std::memory_order_relaxed);
}

core::Status PipelineCoordinator::export_ply(const char* path) noexcept {
    if (!training_started_.load(std::memory_order_acquire))
        return core::Status::kInvalidArgument;

    // Lock to prevent data race with training thread's train_step() and
    // delete training_engine_. Must re-check training_engine_ after lock
    // to avoid TOCTOU race (training thread may delete between check and lock).
    std::lock_guard<std::mutex> lock(training_export_mutex_);
    if (!training_engine_)
        return core::Status::kInvalidArgument;

    // Diagnostic: log color statistics before export
    std::vector<splat::GaussianParams> diag_splats;
    training_engine_->export_gaussians(diag_splats);
    if (!diag_splats.empty()) {
        float min_r = 1e9f, max_r = -1e9f, sum_r = 0;
        float min_g = 1e9f, max_g = -1e9f, sum_g = 0;
        float min_b = 1e9f, max_b = -1e9f, sum_b = 0;
        float min_o = 1e9f, max_o = -1e9f, sum_o = 0;
        std::size_t neg_count = 0;
        for (const auto& s : diag_splats) {
            float r = s.color[0], g = s.color[1], b = s.color[2];
            float o = s.opacity;
            if (r < min_r) min_r = r; if (r > max_r) max_r = r; sum_r += r;
            if (g < min_g) min_g = g; if (g > max_g) max_g = g; sum_g += g;
            if (b < min_b) min_b = b; if (b > max_b) max_b = b; sum_b += b;
            if (o < min_o) min_o = o; if (o > max_o) max_o = o; sum_o += o;
            if (r < 0 || g < 0 || b < 0) neg_count++;
        }
        float n = static_cast<float>(diag_splats.size());
        std::fprintf(stderr, "[Aether3D][Export] %zu gaussians | "
                     "color R[%.3f,%.3f] avg=%.3f | G[%.3f,%.3f] avg=%.3f | "
                     "B[%.3f,%.3f] avg=%.3f | opacity[%.3f,%.3f] avg=%.3f | "
                     "neg_colors=%zu\n",
                     diag_splats.size(),
                     min_r, max_r, sum_r / n,
                     min_g, max_g, sum_g / n,
                     min_b, max_b, sum_b / n,
                     min_o, max_o, sum_o / n,
                     neg_count);
    }
    if (diag_splats.empty()) {
        return training_engine_->export_ply(path);
    }

    ExportSceneBounds tsdf_bounds;
    std::vector<tsdf::SurfacePoint> surface_points;
    std::vector<ExportValidationView> validation_views;
    bool has_tsdf_bounds = false;
    float validation_mask_scale_hint = 0.01f;
    if (tsdf_volume_) {
        if (!features_frozen_.load(std::memory_order_acquire)) {
            features_frozen_.store(true, std::memory_order_release);
        }
        for (int i = 0; i < 500 && !tsdf_idle_.load(std::memory_order_acquire); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }

        tsdf_volume_->extract_surface_points(surface_points, 250000);
        tsdf_bounds = compute_surface_bounds(surface_points);
        has_tsdf_bounds = tsdf_bounds.valid;
        if (has_tsdf_bounds) {
            validation_mask_scale_hint =
                std::clamp(tsdf_bounds.radius * 0.0025f, 0.01f, 0.04f);
        }
    }
    if (!depth_keyframes_.empty()) {
        const std::size_t start =
            depth_keyframes_.size() > 8 ? depth_keyframes_.size() - 8 : 0;
        validation_views.reserve(depth_keyframes_.size() - start);
        for (std::size_t i = start; i < depth_keyframes_.size(); ++i) {
            const auto& kf = depth_keyframes_[i];
            ExportValidationView view;
            view.depth = kf.depth;
            view.conf = kf.conf;
            view.width = kf.width;
            view.height = kf.height;
            view.fx = kf.fx;
            view.fy = kf.fy;
            view.cx = kf.cx;
            view.cy = kf.cy;
            std::memcpy(view.pose, kf.pose, sizeof(view.pose));
            view.rgba = kf.rgba;
            view.rgba_w = kf.rgba_w;
            view.rgba_h = kf.rgba_h;
            std::memcpy(view.rgba_intrinsics, kf.rgba_intrinsics, sizeof(view.rgba_intrinsics));
            if (!surface_points.empty()) {
                build_export_validation_whitelist_mask(&view,
                                                       surface_points,
                                                       validation_mask_scale_hint);
                refine_export_validation_whitelist_mask_with_rgba(&view);
            }
            validation_views.push_back(std::move(view));
        }
    }

    ExportCleanupStats cleanup_stats;
    std::vector<splat::GaussianParams> export_splats =
        clean_export_gaussians(diag_splats,
                               has_tsdf_bounds ? &tsdf_bounds : nullptr,
                               surface_points.empty() ? nullptr : &surface_points,
                               validation_views.empty() ? nullptr : &validation_views,
                               &cleanup_stats);
    if (export_splats.empty()) {
        export_splats = diag_splats;
    }

    std::fprintf(stderr,
                 "[Aether3D][ExportCleanup] input=%zu kept=%zu invalid=%zu "
                 "low_opacity=%zu oversized=%zu elongated=%zu coarse_block=%zu surface_far=%zu validation=%zu mask=%zu outside=%zu isolated=%zu dominant=%zu ground=%zu "
                 "median_scale=%.4f support_radius=%.4f whitelist=%s surface=%s views=%zu\n",
                 cleanup_stats.input_count,
                 export_splats.size(),
                 cleanup_stats.invalid_removed,
                 cleanup_stats.low_opacity_removed,
                 cleanup_stats.oversized_removed,
                 cleanup_stats.elongated_removed,
                 cleanup_stats.coarse_block_removed,
                 cleanup_stats.surface_far_removed,
                 cleanup_stats.validation_removed,
                 cleanup_stats.mask_removed,
                 cleanup_stats.tsdf_outside_removed,
                 cleanup_stats.isolated_removed,
                 cleanup_stats.dominant_cluster_removed,
                 cleanup_stats.ground_preserved,
                 cleanup_stats.median_scale,
                 cleanup_stats.support_radius,
                 has_tsdf_bounds ? "tsdf" : "none",
                 surface_points.empty() ? "none" : "tsdf",
                 validation_views.size());

    return splat::write_ply(path, export_splats.data(), export_splats.size());
}

std::size_t PipelineCoordinator::wait_for_training(
    std::size_t min_steps, double timeout_seconds) noexcept
{
    if (!training_started_.load(std::memory_order_acquire) || !training_engine_) {
        // Training hasn't started — wait briefly for it to initialize.
        // Check training_started_ (acquire) BEFORE training_engine_ to establish
        // happens-before with Thread C's release after creating the engine.
        auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(static_cast<int>(timeout_seconds * 1000));
        while (!training_started_.load(std::memory_order_acquire) &&
               std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (!training_started_.load(std::memory_order_relaxed) || !training_engine_) {
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: training never started\n");
            return 0;
        }
    }

    auto start_time = std::chrono::steady_clock::now();
    auto deadline = start_time +
        std::chrono::milliseconds(static_cast<int>(timeout_seconds * 1000));

    std::size_t current_step = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        auto progress = training_progress();
        current_step = progress.step;

        if (current_step >= min_steps) {
            auto elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start_time).count();
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: reached %zu steps in %.1fs "
                "(loss=%.4f, gaussians=%zu)\n",
                current_step, elapsed, progress.loss, progress.num_gaussians);
            return current_step;
        }

        // Check if training completed (all iterations done)
        if (progress.is_complete) {
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: training completed at %zu steps "
                "(loss=%.4f)\n", current_step, progress.loss);
            return current_step;
        }

        // Sleep briefly to avoid spinning
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    // Timeout
    auto elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start_time).count();
    std::fprintf(stderr,
        "[Aether3D][Coordinator] wait_for_training: timeout after %.1fs at %zu/%zu steps\n",
        elapsed, current_step, min_steps);
    return current_step;
}

core::Status PipelineCoordinator::export_point_cloud_ply(const char* path) noexcept {
    if (!tsdf_volume_) return core::Status::kInvalidArgument;

    // Prefer exporting the trained gaussians when available.
    // This keeps final output colorful and avoids grayscale TSDF fallback.
    if (training_started_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(training_export_mutex_);
        if (training_engine_) {
            std::vector<splat::GaussianParams> trained;
            training_engine_->export_gaussians(trained);
            if (!trained.empty()) {
                std::fprintf(stderr,
                    "[Aether3D][Export] point-cloud export redirected to trained gaussians: %zu\n",
                    trained.size());
                return splat::write_ply(path, trained.data(), trained.size());
            }
        }
    }

    // Safety: ensure Thread A has stopped TSDF access.
    // finish_scanning() sets features_frozen_=true (release). Thread A checks it
    // (acquire) at the top of each iteration and skips all TSDF operations.
    if (!features_frozen_.load(std::memory_order_acquire)) {
        // Caller forgot to call finish_scanning() — force-freeze now.
        features_frozen_.store(true, std::memory_order_release);
    }
    // Wait for Thread A to finish any in-progress TSDF work.
    // Thread A sets tsdf_idle_=false before TSDF ops, true after.
    // Typical wait: <1ms (Thread A's TSDF work is <100ms per frame).
    // Timeout: 500ms (safety bound — should never be hit).
    for (int i = 0; i < 500 && !tsdf_idle_.load(std::memory_order_acquire); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    // Extract surface points from TSDF volume (now safe — Thread A is not accessing)
    std::vector<tsdf::SurfacePoint> surface_points;
    tsdf_volume_->extract_surface_points(surface_points, 10000000);  // 10M max

    if (surface_points.empty()) return core::Status::kInvalidArgument;

    const std::size_t N = surface_points.size();

    // ─── Compute scene bounding sphere for adaptive scale ───
    double cx = 0, cy = 0, cz = 0;
    for (const auto& sp : surface_points) {
        cx += sp.position[0];
        cy += sp.position[1];
        cz += sp.position[2];
    }
    double inv_n = 1.0 / static_cast<double>(N);
    float center_x = static_cast<float>(cx * inv_n);
    float center_y = static_cast<float>(cy * inv_n);
    float center_z = static_cast<float>(cz * inv_n);

    float max_dist2 = 0.0f;
    for (const auto& sp : surface_points) {
        float dx = sp.position[0] - center_x;
        float dy = sp.position[1] - center_y;
        float dz = sp.position[2] - center_z;
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > max_dist2) max_dist2 = d2;
    }
    float scene_radius = std::sqrt(max_dist2);

    float cbrt_n = std::cbrt(static_cast<float>(N));
    float adaptive_scale = std::max(scene_radius / (cbrt_n * 3.0f), 0.002f);
    adaptive_scale = std::min(adaptive_scale, std::max(scene_radius * 0.05f, 0.005f));
    if (scene_radius < 1e-4f) adaptive_scale = 0.02f;

    std::fprintf(stderr, "[Aether3D][Export] TSDF surface: N=%zu radius=%.3f "
                 "adaptive_scale=%.4f\n",
                 N, scene_radius, adaptive_scale);

    // Convert SurfacePoint → GaussianParams
    std::vector<splat::GaussianParams> gaussians;
    gaussians.reserve(N);

    for (const auto& sp : surface_points) {
        splat::GaussianParams g{};
        g.position[0] = sp.position[0];
        g.position[1] = sp.position[1];
        g.position[2] = sp.position[2];
        // Fallback chroma (TSDF only, no true texture source here).
        // Use normal + normalized radial position to avoid black/white-only appearance.
        const float nx = std::fabs(sp.normal[0]);
        const float ny = std::fabs(sp.normal[1]);
        const float nz = std::fabs(sp.normal[2]);
        const float radial = std::sqrt(
            (sp.position[0] - center_x) * (sp.position[0] - center_x) +
            (sp.position[1] - center_y) * (sp.position[1] - center_y) +
            (sp.position[2] - center_z) * (sp.position[2] - center_z));
        const float radial_norm = scene_radius > 1e-5f
            ? std::clamp(radial / scene_radius, 0.0f, 1.0f)
            : 0.0f;
        const float base = std::clamp(0.20f + 0.55f * (1.0f - radial_norm), 0.15f, 0.85f);
        g.color[0] = std::clamp(base * (0.70f + 0.50f * nx), 0.0f, 1.0f);
        g.color[1] = std::clamp(base * (0.68f + 0.50f * ny), 0.0f, 1.0f);
        g.color[2] = std::clamp(base * (0.72f + 0.45f * nz), 0.0f, 1.0f);
        g.opacity = std::clamp(static_cast<float>(sp.weight) / 32.0f, 0.1f, 1.0f);
        g.scale[0] = adaptive_scale;
        g.scale[1] = adaptive_scale;
        g.scale[2] = adaptive_scale;
        g.rotation[0] = 1.0f;
        g.rotation[1] = 0.0f;
        g.rotation[2] = 0.0f;
        g.rotation[3] = 0.0f;
        gaussians.push_back(g);
    }

    return splat::write_ply(path, gaussians.data(), gaussians.size());
}

std::size_t PipelineCoordinator::copy_surface_points_xyz(
    float* out_xyz,
    std::size_t max_points) noexcept
{
    if (!tsdf_volume_ || !out_xyz || max_points == 0) return 0;

    if (!features_frozen_.load(std::memory_order_acquire)) {
        features_frozen_.store(true, std::memory_order_release);
    }
    for (int i = 0; i < 500 && !tsdf_idle_.load(std::memory_order_acquire); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    std::vector<tsdf::SurfacePoint> surface_points;
    tsdf_volume_->extract_surface_points(surface_points, max_points);
    if (surface_points.empty()) return 0;

    const std::size_t count = std::min(surface_points.size(), max_points);
    for (std::size_t i = 0; i < count; ++i) {
        out_xyz[i * 3 + 0] = surface_points[i].position[0];
        out_xyz[i * 3 + 1] = surface_points[i].position[1];
        out_xyz[i * 3 + 2] = surface_points[i].position[2];
    }
    return count;
}

bool PipelineCoordinator::is_training_active() const noexcept {
    return training_started_.load(std::memory_order_relaxed);
}

bool PipelineCoordinator::service_local_preview_bootstrap() noexcept {
    if (!config_.local_preview_mode) {
        return false;
    }

    bool ready = false;
    std::lock_guard<std::mutex> depth_lock(depth_cache_mutex_);

    if (depth_engine_small_) {
        DepthInferenceResult small_result;
        if (depth_engine_small_->poll_result(small_result) &&
            !small_result.depth_map.empty()) {
            latest_small_depth_ = std::move(small_result);
            has_small_depth_ = true;
            preview_depth_results_ready_.fetch_add(1, std::memory_order_relaxed);
            ready = true;
        }
    }

    if (depth_engine_large_) {
        DepthInferenceResult large_result;
        if (depth_engine_large_->poll_result(large_result) &&
            !large_result.depth_map.empty()) {
            latest_large_depth_ = std::move(large_result);
            has_large_depth_ = true;
            ready = true;
        }
    }

    return ready || has_small_depth_ || has_large_depth_;
}

bool PipelineCoordinator::is_gpu_training() const noexcept {
    // training_started_ acquire synchronizes with Thread C's release after
    // creating training_engine_. Without this, the raw pointer read is a
    // data race (Thread C writes, main thread reads, no barrier).
    if (!training_started_.load(std::memory_order_acquire)) return false;
    if (!training_engine_) return false;
    return training_engine_->is_gpu_training();
}

training::TrainingProgress PipelineCoordinator::training_progress() const noexcept {
    const std::size_t target_steps = std::max<std::size_t>(
        training_target_steps_.load(std::memory_order_relaxed),
        kDefaultTrainingTargetSteps);
    const std::size_t hard_cap_steps = std::max<std::size_t>(
        training_hard_cap_steps_.load(std::memory_order_relaxed),
        target_steps);

    if (training_started_.load(std::memory_order_acquire) && training_engine_) {
        auto progress = training_engine_->progress();
        return apply_training_budget(progress, target_steps, hard_cap_steps);
    }

    // Pre-training staged progress (core-owned, avoids long 0% stalls in UI).
    // This reflects pipeline readiness before the global engine is instantiated.
    training::TrainingProgress staged{};
    staged.total_steps = target_steps;

    const std::size_t selected_frames =
        selected_frame_count_.load(std::memory_order_relaxed);
    const std::size_t min_frames =
        std::max<std::size_t>(config_.min_frames_to_start_training, 1u);
    const float frame_ratio = std::min(
        1.0f,
        static_cast<float>(selected_frames) / static_cast<float>(min_frames));

    // Read latest published counters (from Thread B snapshot).
    auto& self = const_cast<PipelineCoordinator&>(*this);
    const auto& snap = self.evidence_snapshot_.read_buffer();
    const std::size_t staged_gaussians =
        snap.assigned_blocks + snap.pending_gaussian_count;
    const float seed_ratio = std::min(
        1.0f,
        static_cast<float>(staged_gaussians) / 4096.0f);

    float staged_ratio = 0.05f + 0.45f * frame_ratio + 0.45f * seed_ratio;
    if (selected_frames >= min_frames && staged_gaussians > 0) {
        staged_ratio = std::max(staged_ratio, 0.92f);
    }
    staged_ratio = std::clamp(staged_ratio, 0.0f, 0.95f);

    staged.step = static_cast<std::size_t>(
        std::llround(staged_ratio * static_cast<float>(staged.total_steps)));
    staged.loss = 0.0f;
    staged.num_gaussians = staged_gaussians;
    staged.is_complete = false;
    return staged;
}

// ═══════════════════════════════════════════════════════════════════════
// Thread A: Frame Ingestion
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::frame_thread_func() noexcept {
    FrameInput input;

    while (running_.load(std::memory_order_relaxed)) {
        if (!frame_queue_.try_pop(input)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }

        if (config_.local_preview_mode && input.imported_video) {
            preview_frames_ingested_.fetch_add(1, std::memory_order_relaxed);
        }

        {
            static std::uint32_t feature_src_diag_counter = 0;
            feature_src_diag_counter++;
            if (feature_src_diag_counter <= 10 ||
                feature_src_diag_counter % 120 == 0) {
                std::fprintf(
                    stderr,
                    "[Aether3D][FeatureSrc] #%u feature_count=%u lidar=%zu ne_depth=%zu\n",
                    feature_src_diag_counter,
                    input.feature_count,
                    input.lidar_depth.size(),
                    input.ne_depth.size());
            }
        }

        // ─── Thermal recommendation ───
        auto thermal = thermal_predictor_.evaluate(input.timestamp);

        // ─── Brightness analysis (low-light detection) ───
        float brightness = compute_brightness(
            input.rgba.data(), input.width, input.height);
        bool is_low_light = brightness < config_.low_light_brightness_threshold;
        low_light_mode_.store(is_low_light, std::memory_order_relaxed);

        // ─── Blur score ───
        float blur = compute_blur_score(
            input.rgba.data(), input.width, input.height);

        if (config_.local_preview_mode && input.imported_video) {
            const auto preview_prefilter = evaluate_preview_import_prefilter(
                brightness,
                blur,
                config_.low_light_brightness_threshold,
                config_.frame_selection.min_blur_score,
                config_.low_light_blur_strictness);
            switch (preview_prefilter) {
            case PreviewPrefilterDecision::kAccept:
                preview_prefilter_accepts_.fetch_add(1, std::memory_order_relaxed);
                break;
            case PreviewPrefilterDecision::kRejectLowBrightness:
                preview_prefilter_brightness_rejects_.fetch_add(1, std::memory_order_relaxed);
                preview_prefilter_accepts_.fetch_add(1, std::memory_order_relaxed);
                break;
            case PreviewPrefilterDecision::kRejectBlur:
                preview_prefilter_blur_rejects_.fetch_add(1, std::memory_order_relaxed);
                preview_prefilter_accepts_.fetch_add(1, std::memory_order_relaxed);
                break;
            }
        }

        // ─── DAv2 Dual-Model Depth Inference (C++ core layer) ───
        // OpenGS/WildGS-style depth-source robustness:
        //   1) Estimate LiDAR validity ratio on current frame.
        //   2) If LiDAR is sparse/invalid, do NOT bypass DAv2.
        //   3) Only bypass DAv2 when LiDAR has enough valid metric depth.
        // This prevents "all-zero overlay" startup stalls on frames where
        // sceneDepth exists but carries mostly invalid pixels.
        const bool has_lidar_depth_frame =
            !input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0;
        float lidar_valid_ratio = 0.0f;
        bool lidar_depth_usable = false;
        if (has_lidar_depth_frame) {
            constexpr std::uint32_t kSampleStride = 4;
            constexpr float kDepthMin = 0.1f;
            constexpr float kDepthMax = 5.0f;
            std::size_t valid = 0;
            std::size_t sampled = 0;
            for (std::uint32_t v = 0; v < input.lidar_h; v += kSampleStride) {
                const std::size_t row = static_cast<std::size_t>(v) * input.lidar_w;
                for (std::uint32_t u = 0; u < input.lidar_w; u += kSampleStride) {
                    const float d = input.lidar_depth[row + u];
                    sampled++;
                    if (std::isfinite(d) && d >= kDepthMin && d <= kDepthMax) {
                        valid++;
                    }
                }
            }
            lidar_valid_ratio = sampled > 0
                ? static_cast<float>(valid) / static_cast<float>(sampled)
                : 0.0f;
            constexpr float kMinLidarValidRatioForBypass = 0.03f;  // 3%
            lidar_depth_usable = lidar_valid_ratio >= kMinLidarValidRatioForBypass;
        }

        bool have_depth = false;
        bool cached_small_depth_available = false;
        bool cached_large_depth_available = false;
        if (!has_lidar_depth_frame || !lidar_depth_usable) {
            if (has_lidar_depth_frame && !lidar_depth_usable) {
                static std::uint32_t lidar_invalid_diag_counter = 0;
                lidar_invalid_diag_counter++;
                if (lidar_invalid_diag_counter <= 10 || lidar_invalid_diag_counter % 60 == 0) {
                    std::fprintf(stderr,
                        "[Aether3D] LiDAR depth sparse (valid=%.3f) — fallback to DAv2 inference\n",
                        lidar_valid_ratio);
                }
            }
            // Architecture:
            //   Small: submit every frame, poll previous result (~1 frame latency)
            //   Large: submit every N frames, poll previous result (~N frame latency)
            //   Cross-validation: when both have results, merge via consensus
            // This replaces Swift-layer DepthAnythingV2Bridge.estimateAsync().

            float current_cam_pos[3];
            float current_cam_fwd[3];
            extract_camera_pose_metrics(
                input.transform,
                current_cam_pos,
                current_cam_fwd);

            bool small_result_updated = false;
            const auto preview_depth_phase_t0 = config_.local_preview_mode
                ? std::chrono::steady_clock::now()
                : std::chrono::steady_clock::time_point{};
            DepthInferenceResult consensus_depth;
            {
                std::lock_guard<std::mutex> depth_lock(depth_cache_mutex_);

                // Small model: imported-video local_preview is a preview-first path.
                // Do not reuse the live-capture motion cadence here; album videos
                // need depth on every queued frame to keep pose/depth aligned all
                // the way through training bootstrap. If we fall back to the async
                // "latest pending frame" path after the first few frames, later
                // poses get paired with stale depth and the geometry collapses into
                // elongated sticks/cigars.
                if (depth_engine_small_) {
                    bool submit_small = true;
                    const bool imported_video_sync_depth =
                        config_.local_preview_mode &&
                        input.imported_video;

                    if (imported_video_sync_depth) {
                        DepthInferenceResult bootstrap_small_result;
                        const auto bootstrap_status = depth_engine_small_->infer(
                            input.rgba.data(), input.width, input.height, bootstrap_small_result);
                        if (bootstrap_status == core::Status::kOk &&
                            !bootstrap_small_result.depth_map.empty()) {
                            latest_small_depth_ = std::move(bootstrap_small_result);
                            has_small_depth_ = true;
                            small_result_updated = true;
                            preview_depth_batches_submitted_.fetch_add(
                                1, std::memory_order_relaxed);
                            preview_depth_results_ready_.fetch_add(
                                1, std::memory_order_relaxed);
                            preview_depth_frames_since_submit_ = 0;
                            std::memcpy(
                                preview_last_depth_request_pos_,
                                current_cam_pos,
                                sizeof(preview_last_depth_request_pos_));
                            std::memcpy(
                                preview_last_depth_request_fwd_,
                                current_cam_fwd,
                                sizeof(preview_last_depth_request_fwd_));
                            has_preview_depth_request_ = true;
                            static std::uint32_t imported_video_sync_depth_log_count = 0;
                            imported_video_sync_depth_log_count++;
                            if (imported_video_sync_depth_log_count <= 12 ||
                                imported_video_sync_depth_log_count % 30 == 0) {
                                std::fprintf(
                                    stderr,
                                    "[Aether3D][PreviewDepth] imported-video sync depth frame=%u "
                                    "depth_ready=%u (%ux%u)\n",
                                    input.source_frame_index + 1u,
                                    preview_depth_results_ready_.load(std::memory_order_relaxed),
                                    latest_small_depth_.width,
                                    latest_small_depth_.height);
                            }
                        }
                    }

                    if (!small_result_updated) {
                        if (config_.local_preview_mode && input.imported_video) {
                            // Keep imported-video depth and pose aligned on the
                            // same frame. Do not fall back to the lossy async
                            // "latest pending frame" queue for album videos.
                            submit_small = false;
                        } else if (config_.local_preview_mode) {
                            submit_small = should_submit_preview_depth_prior(
                                has_small_depth_,
                                preview_depth_frames_since_submit_,
                                has_preview_depth_request_,
                                current_cam_pos,
                                current_cam_fwd,
                                preview_last_depth_request_pos_,
                                preview_last_depth_request_fwd_);
                        }

                        if (submit_small) {
                            depth_engine_small_->submit_async(
                                input.rgba.data(), input.width, input.height);
                            if (config_.local_preview_mode) {
                                preview_depth_batches_submitted_.fetch_add(
                                    1, std::memory_order_relaxed);
                                preview_depth_frames_since_submit_ = 0;
                                std::memcpy(
                                    preview_last_depth_request_pos_,
                                    current_cam_pos,
                                    sizeof(preview_last_depth_request_pos_));
                                std::memcpy(
                                    preview_last_depth_request_fwd_,
                                    current_cam_fwd,
                                    sizeof(preview_last_depth_request_fwd_));
                                has_preview_depth_request_ = true;
                            }
                        } else if (config_.local_preview_mode) {
                            preview_depth_frames_since_submit_++;
                        }

                        DepthInferenceResult small_result;
                        if (depth_engine_small_->poll_result(small_result) &&
                            !small_result.depth_map.empty()) {
                            latest_small_depth_ = std::move(small_result);
                            has_small_depth_ = true;
                            small_result_updated = true;
                            if (config_.local_preview_mode) {
                                preview_depth_results_ready_.fetch_add(
                                    1, std::memory_order_relaxed);
                            }
                        } else if (config_.local_preview_mode &&
                                   input.imported_video &&
                                   has_small_depth_) {
                            preview_depth_reuse_frames_.fetch_add(
                                1, std::memory_order_relaxed);
                        }
                    }
                }

                // Large model: every N frames (high quality, cross-validation)
                if (depth_engine_large_) {
                    frame_counter_for_large_++;
                    if (frame_counter_for_large_ >= config_.large_model_interval) {
                        frame_counter_for_large_ = 0;
                        depth_engine_large_->submit_async(
                            input.rgba.data(), input.width, input.height);
                    }

                    DepthInferenceResult large_result;
                    if (depth_engine_large_->poll_result(large_result) &&
                        !large_result.depth_map.empty()) {
                        latest_large_depth_ = std::move(large_result);
                        has_large_depth_ = true;
                    }
                }

                cached_small_depth_available = has_small_depth_;
                cached_large_depth_available = has_large_depth_;
                have_depth = cross_validate_depth(
                    latest_small_depth_, latest_large_depth_,
                    has_small_depth_, has_large_depth_,
                    consensus_depth);
            }
            if (have_depth) {
                if (config_.local_preview_mode &&
                    cached_small_depth_available &&
                    depth_engine_small_ &&
                    !small_result_updated &&
                    !consensus_depth.depth_map.empty()) {
                    preview_depth_reuse_frames_.fetch_add(
                        1, std::memory_order_relaxed);
                }
                    input.ne_depth = std::move(consensus_depth.depth_map);
                input.ne_depth_w = consensus_depth.width;
                input.ne_depth_h = consensus_depth.height;
                input.ne_depth_is_metric = consensus_depth.is_metric;
                // Log once when metric model is first detected
                if (consensus_depth.is_metric) {
                    static bool metric_detected_logged = false;
                    if (!metric_detected_logged) {
                        metric_detected_logged = true;
                        std::fprintf(stderr,
                            "[Aether3D] DAv2 METRIC model detected — depth output is absolute meters "
                            "(WildGS-SLAM DAv2-hypersim style). Skipping affine calibration.\n");
                    }
                }
            }
            if (config_.local_preview_mode) {
                const auto preview_depth_phase_t1 = std::chrono::steady_clock::now();
                const auto preview_depth_elapsed_ms = static_cast<std::uint64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        preview_depth_phase_t1 - preview_depth_phase_t0
                    ).count()
                );
                preview_depth_phase_ms_.fetch_add(
                    preview_depth_elapsed_ms,
                    std::memory_order_relaxed
                );
            }
        } else {
            static std::uint32_t lidar_bypass_diag_counter = 0;
            lidar_bypass_diag_counter++;
            if (lidar_bypass_diag_counter <= 5 || lidar_bypass_diag_counter % 60 == 0) {
                std::fprintf(stderr,
                    "[Aether3D] LiDAR frame valid=%.3f — bypass DAv2 inference to preserve VIO\n",
                    lidar_valid_ratio);
            }
        }

        // ── Diagnostic: DAv2 depth pipeline status (first 10 frames + every 60th) ──
        {
            static std::uint32_t depth_diag_counter = 0;
            depth_diag_counter++;
            if (depth_diag_counter <= 10 || depth_diag_counter % 60 == 0) {
                std::fprintf(stderr,
                    "[Aether3D] Frame %u: DAv2 small=%s large=%s | "
                    "has_small=%d has_large=%d | depth=%s %ux%u | "
                    "ne_depth=%zu affine=[%.2f,%.2f]\n",
                    depth_diag_counter,
                    depth_engine_small_ ? "loaded" : "NULL",
                    depth_engine_large_ ? "loaded" : "NULL",
                    cached_small_depth_available ? 1 : 0,
                    cached_large_depth_available ? 1 : 0,
                    have_depth ? "YES" : "NO",
                    input.ne_depth_w, input.ne_depth_h,
                    input.ne_depth.size(),
                    dav2_affine_scale_, dav2_affine_shift_);
            }
        }

        // ─── DAv2 Metric Scale Estimation ───
        // DAv2 outputs relative depth [0,1]. We need a metric multiplier.
        //
        // Two calibration sources (priority order):
        //   1. LiDAR direct: scale = mean(lidar_metric) / mean(dav2_relative)
        //      Instant, no camera movement needed. Available on LiDAR devices.
        //   2. ARKit baseline: scale = heuristic(camera_displacement, mean_relative)
        //      Requires ≥2cm camera movement. Fallback for non-LiDAR devices.
        {
            // ── Source 1: LiDAR-based instant affine calibration ──
            // When we have both DAv2 relative depth AND LiDAR metric depth,
            // compute RECIPROCAL affine alignment in INVERSE DEPTH space:
            //   1/z_metric = scale * d_pred + shift
            //   z_metric = 1 / (scale * d_pred + shift)
            //
            // DAv2 outputs inverse-depth-like values (larger = closer).
            // Fitting in inverse-depth space is EXACT for this relationship.
            // The old linear model (z = a*d + b) approximated a hyperbola
            // with a line, causing ~0.6m errors at mid-range depths.
            if (!lidar_scale_bootstrapped_ && !input.ne_depth.empty() &&
                !input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0) {

                const std::uint32_t shared_w = std::min(input.lidar_w, input.ne_depth_w);
                const std::uint32_t shared_h = std::min(input.lidar_h, input.ne_depth_h);

                // Collect co-located (d_pred, 1/z_metric) pairs
                double sum_d = 0, sum_iz = 0, sum_dd = 0, sum_diz = 0;
                int cnt = 0;
                for (std::uint32_t v = 0; v < shared_h; v += 4) {
                    for (std::uint32_t u = 0; u < shared_w; u += 4) {
                        std::size_t li = static_cast<std::size_t>(v) *
                            input.lidar_w / shared_h * input.lidar_w +
                            static_cast<std::size_t>(u) * input.lidar_w / shared_w;
                        if (li >= static_cast<std::size_t>(input.lidar_w) * input.lidar_h) continue;
                        float z_met = input.lidar_depth[li];
                        if (z_met < 0.1f || z_met > 8.0f || !std::isfinite(z_met)) continue;

                        std::size_t di = static_cast<std::size_t>(v) *
                            input.ne_depth_h / shared_h * input.ne_depth_w +
                            static_cast<std::size_t>(u) * input.ne_depth_w / shared_w;
                        if (di >= input.ne_depth.size()) continue;
                        float d_pred = input.ne_depth[di];
                        if (d_pred < 0.02f || d_pred > 0.98f || !std::isfinite(d_pred)) continue;

                        double d = static_cast<double>(d_pred);
                        double iz = 1.0 / static_cast<double>(z_met);  // INVERSE depth
                        sum_d += d;
                        sum_iz += iz;
                        sum_dd += d * d;
                        sum_diz += d * iz;
                        cnt++;
                    }
                }

                if (cnt > 50) {
                    double det = sum_dd * cnt - sum_d * sum_d;
                    if (std::abs(det) > 1e-12) {
                        float lidar_scale = static_cast<float>((sum_diz * cnt - sum_d * sum_iz) / det);
                        float lidar_shift = static_cast<float>((sum_dd * sum_iz - sum_d * sum_diz) / det);
                        // Validate: both inv-depth endpoints must be positive
                        float inv_at_0 = lidar_shift;
                        float inv_at_1 = lidar_scale + lidar_shift;
                        bool inv_valid = inv_at_0 > 0.01f && inv_at_1 > 0.01f;
                        if (inv_valid) {
                            float z_near = 1.0f / std::max(inv_at_0, inv_at_1);
                            float z_far  = 1.0f / std::min(inv_at_0, inv_at_1);
                            if (z_near > 0.05f && z_far < 20.0f) {
                                dav2_affine_scale_ = lidar_scale;
                                dav2_affine_shift_ = lidar_shift;
                                dav2_affine_valid_ = true;
                                lidar_scale_bootstrapped_ = true;
                                std::fprintf(stderr,
                                    "[Aether3D] DAv2 inv-depth affine: LiDAR-bootstrapped "
                                    "scale=%.3f shift=%.3f (%d pts) "
                                    "z_range=[%.2f, %.2f]m\n",
                                    lidar_scale, lidar_shift, cnt,
                                    z_near, z_far);
                            }
                        }
                    }
                }
            }

            // ── Source 2: ARKit Feature-Point Calibration (non-LiDAR devices) ──
            // ═══════════════════════════════════════════════════════════
            // RECIPROCAL AFFINE in INVERSE-DEPTH SPACE (4 critical fixes)
            // ═══════════════════════════════════════════════════════════
            //
            // DAv2 outputs INVERSE DEPTH (disparity-like): larger values = closer.
            // After min-max normalization: d_pred ∈ [0,1], d=1.0 = closest pixel.
            //
            // The correct relationship is AFFINE IN INVERSE-DEPTH SPACE:
            //   1/metric_z = scale * d_pred + shift
            //   metric_z   = 1 / (scale * d_pred + shift)
            //
            // The old LINEAR model (metric_z = a*d + b) approximated a HYPERBOLA
            // with a LINE. For depth range [1m, 5m], this causes ~0.6m mean error
            // at mid-range depths, placing TSDF blocks at completely wrong positions.
            //
            // FIX #1: Reciprocal affine model (fit in inverse-depth space)
            // FIX #2: Y-coordinate negated for ARKit convention
            // FIX #3: Camera Z-depth instead of Euclidean distance
            // FIX #4: 2-pass iterative least squares with outlier rejection
            //
            // References: Murre (2025), VIMD (2026), Prior Depth Anything (2025)

            float cam_x = input.transform[12];
            float cam_y = input.transform[13];
            float cam_z = input.transform[14];

            // Skip affine calibration for metric models — values are already in meters.
            // (WildGS-SLAM DAv2-metric / Metric3D V2 / UniDepth V2 all output meters.)
            if (!input.ne_depth.empty() && input.feature_count >= 10 &&
                input.ne_depth_w > 0 && input.ne_depth_h > 0 &&
                !input.ne_depth_is_metric) {  // Only calibrate relative models

                // Scale intrinsics from camera resolution to depth map resolution
                const float depth_sx = static_cast<float>(input.ne_depth_w) /
                                       static_cast<float>(input.width);
                const float depth_sy = static_cast<float>(input.ne_depth_h) /
                                       static_cast<float>(input.height);
                const float d_fx = input.intrinsics[0] * depth_sx;
                const float d_fy = input.intrinsics[4] * depth_sy;
                const float d_cx = input.intrinsics[2] * depth_sx;
                const float d_cy = input.intrinsics[5] * depth_sy;

                // Collect (d_pred, 1/cam_z) pairs for inverse-depth affine fitting
                std::vector<float> d_pred_pts;
                std::vector<float> inv_z_pts;   // INVERSE depth: 1/cam_z
                d_pred_pts.reserve(input.feature_count);
                inv_z_pts.reserve(input.feature_count);

                const std::size_t max_pts = std::min(
                    static_cast<std::size_t>(input.feature_count),
                    static_cast<std::size_t>(200));

                for (std::size_t i = 0; i < max_pts; ++i) {
                    float wx = input.feature_points[i * 3 + 0];
                    float wy = input.feature_points[i * 3 + 1];
                    float wz = input.feature_points[i * 3 + 2];

                    // Delta from camera to feature point
                    float dwx = wx - cam_x;
                    float dwy = wy - cam_y;
                    float dwz = wz - cam_z;

                    // Transform to camera space: R^T * delta
                    // ARKit column-major: col0=right, col1=up, col2=back
                    float rx = dwx * input.transform[0] + dwy * input.transform[1] + dwz * input.transform[2];
                    float ry = dwx * input.transform[4] + dwy * input.transform[5] + dwz * input.transform[6];
                    float rz = dwx * input.transform[8] + dwy * input.transform[9] + dwz * input.transform[10];

                    // BUG FIX #3: Camera Z-depth (not Euclidean distance!)
                    // ARKit: -Z = forward, so cam_z_pt = -rz gives positive depth
                    float cam_z_pt = -rz;
                    if (cam_z_pt < 0.2f || cam_z_pt > 8.0f) continue;

                    // BUG FIX #2: Negate ry for projection
                    // ARKit col1 = UP, but image V increases DOWN.
                    // Matches world_to_camera() in tsdf_volume.cpp which also negates Y.
                    float u = d_fx * (rx / cam_z_pt) + d_cx;
                    float v = d_fy * (-ry / cam_z_pt) + d_cy;

                    int iu = static_cast<int>(u + 0.5f);
                    int iv = static_cast<int>(v + 0.5f);
                    if (iu < 2 || iu >= static_cast<int>(input.ne_depth_w) - 2 ||
                        iv < 2 || iv >= static_cast<int>(input.ne_depth_h) - 2) {
                        continue;
                    }

                    // Sample DAv2 value with 2×2 averaging for sub-pixel robustness
                    std::size_t didx = static_cast<std::size_t>(iv) * input.ne_depth_w +
                                       static_cast<std::size_t>(iu);
                    float d00 = input.ne_depth[didx];
                    float d01 = input.ne_depth[didx + 1];
                    float d10 = input.ne_depth[didx + input.ne_depth_w];
                    float d11 = input.ne_depth[didx + input.ne_depth_w + 1];
                    float rel_depth = (d00 + d01 + d10 + d11) * 0.25f;

                    // Valid range (exclude extreme values near normalization boundaries)
                    if (rel_depth < 0.005f || rel_depth > 0.995f) continue;
                    if (!std::isfinite(rel_depth)) continue;

                    d_pred_pts.push_back(rel_depth);
                    inv_z_pts.push_back(1.0f / cam_z_pt);  // INVERSE depth
                }

                // FIX #1: Reciprocal affine in INVERSE-DEPTH space
                // Model: 1/cam_z = scale * d_pred + shift
                // This is EXACT for disparity-like DAv2 output.
                if (d_pred_pts.size() >= 5) {
                    const std::size_t n = d_pred_pts.size();

                    // ── Iterative Least Squares with Outlier Rejection ──
                    // Model: inv_z = scale * d_pred + shift
                    // Pass 1: all points → initial fit
                    // Pass 2: reject outliers → refined fit
                    float fit_scale = dav2_affine_scale_;
                    float fit_shift = dav2_affine_shift_;

                    for (int iter = 0; iter < 2; ++iter) {
                        double sum_d = 0, sum_iz = 0, sum_dd = 0, sum_diz = 0;
                        int cnt = 0;

                        for (std::size_t k = 0; k < n; ++k) {
                            if (iter > 0) {
                                float pred_inv = fit_scale * d_pred_pts[k] + fit_shift;
                                float residual = std::abs(inv_z_pts[k] - pred_inv);
                                // Reject if residual > 25% of inverse depth or > 0.3 inv-m
                                if (residual > inv_z_pts[k] * 0.25f || residual > 0.3f) continue;
                            }

                            double d = static_cast<double>(d_pred_pts[k]);
                            double iz = static_cast<double>(inv_z_pts[k]);
                            sum_d += d;
                            sum_iz += iz;
                            sum_dd += d * d;
                            sum_diz += d * iz;
                            cnt++;
                        }

                        if (cnt < 5) break;

                        // Normal equations: inv_z = scale * d + shift
                        double det = sum_dd * cnt - sum_d * sum_d;
                        if (std::abs(det) < 1e-12) break;

                        fit_scale = static_cast<float>((sum_diz * cnt - sum_d * sum_iz) / det);
                        fit_shift = static_cast<float>((sum_dd * sum_iz - sum_d * sum_diz) / det);
                    }

                    // Sanity checks: inverse-depth endpoints must be positive
                    bool valid = std::isfinite(fit_scale) && std::isfinite(fit_shift);
                    if (valid) {
                        float inv_at_0 = fit_shift;                    // 1/depth when d=0 (farthest)
                        float inv_at_1 = fit_scale + fit_shift;        // 1/depth when d=1 (closest)
                        // Both inverse depths must be positive (depth > 0)
                        valid = inv_at_0 > 0.01f && inv_at_1 > 0.01f;
                        if (valid) {
                            float z_near = 1.0f / std::max(inv_at_0, inv_at_1);
                            float z_far  = 1.0f / std::min(inv_at_0, inv_at_1);
                            valid = z_near > 0.05f && z_far < 20.0f;
                        }
                        // Scale should be non-trivial
                        valid = valid && std::abs(fit_scale) > 0.01f;
                    }

                    if (valid) {
                        if (!dav2_affine_valid_) {
                            dav2_affine_scale_ = fit_scale;
                            dav2_affine_shift_ = fit_shift;
                            dav2_affine_valid_ = true;
                        } else {
                            float alpha = 0.4f;
                            float scale_change = std::abs(fit_scale - dav2_affine_scale_) /
                                                 std::max(0.01f, std::abs(dav2_affine_scale_));
                            float shift_change = std::abs(fit_shift - dav2_affine_shift_) /
                                                 std::max(0.01f, std::abs(dav2_affine_shift_));
                            if (scale_change > 0.5f || shift_change > 0.5f) {
                                alpha = 0.8f;
                            }
                            dav2_affine_scale_ = (1.0f - alpha) * dav2_affine_scale_ + alpha * fit_scale;
                            dav2_affine_shift_ = (1.0f - alpha) * dav2_affine_shift_ + alpha * fit_shift;
                        }

                        // Diagnostic: first 10 + every 30th
                        static std::uint32_t affine_diag = 0;
                        affine_diag++;
                        if (affine_diag <= 10 || affine_diag % 30 == 0) {
                            float inv0 = dav2_affine_shift_;
                            float inv1 = dav2_affine_scale_ + dav2_affine_shift_;
                            float z_near = 1.0f / std::max(inv0, inv1);
                            float z_far  = 1.0f / std::min(inv0, inv1);
                            std::fprintf(stderr,
                                "[Aether3D] DAv2 inv-depth affine: scale=%.3f shift=%.3f "
                                "(fit: s=%.3f t=%.3f, %zu pts) "
                                "z_range=[%.2f, %.2f]m\n",
                                dav2_affine_scale_, dav2_affine_shift_,
                                fit_scale, fit_shift,
                                d_pred_pts.size(),
                                z_near, z_far);
                        }
                    }
                }
            }

            prev_cam_x_ = cam_x;
            prev_cam_y_ = cam_y;
            prev_cam_z_ = cam_z;
            has_prev_cam_ = true;
        }

        // ─── Depth source selection ───
        // Priority: DAv2 → LiDAR → none.
        // DAv2 is available on ALL devices (90% of phones have no LiDAR).
        // After affine alignment, DAv2 cross-validation divergence should be <5%.
        // LiDAR used only as fallback when DAv2 unavailable.
        const float* depth_source = nullptr;
        std::uint32_t depth_w = 0, depth_h = 0;
        float depth_confidence = 1.0f;
        bool depth_is_metric = false;

        if (!input.ne_depth.empty() && input.ne_depth_w > 0 && input.ne_depth_h > 0) {
            // DAv2 depth — primary source (works on all devices).
            // Supports two modes auto-detected by depth_inference_coreml.mm:
            //   is_metric=false: relative disparity [0,1] → affine calibration below
            //   is_metric=true:  absolute meters (DAv2-Metric/Metric3D/UniDepth) → use directly
            // Reference: WildGS-SLAM metric_depth_estimators.py (dpt2/metric3d branches)
            depth_source = input.ne_depth.data();
            depth_w = input.ne_depth_w;
            depth_h = input.ne_depth_h;
            depth_is_metric = input.ne_depth_is_metric;  // Propagate from inference result

            // Low-light: reduce depth confidence
            if (is_low_light) {
                depth_confidence = std::clamp(
                    brightness / 100.0f,
                    config_.low_light_depth_weight_min, 1.0f);
            }
        } else if (!input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0) {
            // LiDAR depth — fallback for when DAv2 is unavailable
            depth_source = input.lidar_depth.data();
            depth_w = input.lidar_w;
            depth_h = input.lidar_h;
            depth_is_metric = true;
            depth_confidence = 1.0f;
        }

        // ── ARKit VIO Sparse Depth Fallback (non-LiDAR, pre-DAv2 warmup) ──
        // When neither DAv2 nor LiDAR depth is available (e.g., DAv2 model still
        // loading, inference failing, or unsupported device), use ARKit VIO feature
        // points as sparse metric depth. ARKit VIO uses IMU for metric scale, so
        // feature points are in real meters — no affine calibration needed.
        //
        // This matches the VINGS-Mono approach (smartphone-confirmed VIO-scale depth)
        // and prevents "等待表面数据..." UI freeze on non-LiDAR devices during DAv2
        // warm-up. Provides immediate TSDF integration from frame 1.
        //
        // Resolution: 64×48 sparse map → sufficient for TSDF block allocation;
        // dilated with nearest-neighbor fill (radius=4px) for surface continuity.
        std::vector<float> sparse_depth_buf;  // Lifetime covers tsdf_volume_->integrate()
        if (depth_source == nullptr && input.feature_count >= 5) {
            constexpr std::uint32_t kSparseW = 64;
            constexpr std::uint32_t kSparseH = 48;
            sparse_depth_buf.assign(kSparseW * kSparseH, 0.0f);

            const float t_cam_x = input.transform[12];
            const float t_cam_y = input.transform[13];
            const float t_cam_z = input.transform[14];

            // Scale intrinsics from camera resolution to sparse map resolution
            const float feat_sx = static_cast<float>(kSparseW) / static_cast<float>(input.width);
            const float feat_sy = static_cast<float>(kSparseH) / static_cast<float>(input.height);
            const float feat_fx = input.intrinsics[0] * feat_sx;
            const float feat_fy = input.intrinsics[4] * feat_sy;
            const float feat_cx = input.intrinsics[2] * feat_sx;
            const float feat_cy = input.intrinsics[5] * feat_sy;

            int feat_projected = 0;
            const std::uint32_t max_feat_pts = std::min(input.feature_count, 512u);
            for (std::uint32_t i = 0; i < max_feat_pts; ++i) {
                const float wx = input.feature_points[i * 3 + 0];
                const float wy = input.feature_points[i * 3 + 1];
                const float wz = input.feature_points[i * 3 + 2];

                const float dwx = wx - t_cam_x;
                const float dwy = wy - t_cam_y;
                const float dwz = wz - t_cam_z;

                // R^T * delta — ARKit column-major (col0=right, col1=up, col2=back)
                const float rx = dwx * input.transform[0] + dwy * input.transform[1] + dwz * input.transform[2];
                const float ry = dwx * input.transform[4] + dwy * input.transform[5] + dwz * input.transform[6];
                const float rz = dwx * input.transform[8] + dwy * input.transform[9] + dwz * input.transform[10];

                const float cam_z_pt = -rz;  // ARKit: -Z = forward → positive depth
                if (cam_z_pt < 0.15f || cam_z_pt > 8.0f || !std::isfinite(cam_z_pt)) continue;

                // Project to sparse depth map (negate ry: ARKit Y-up → image Y-down)
                const float pu = feat_fx * (rx / cam_z_pt) + feat_cx;
                const float pv = feat_fy * (-ry / cam_z_pt) + feat_cy;
                const int iu = static_cast<int>(pu + 0.5f);
                const int iv = static_cast<int>(pv + 0.5f);
                if (iu < 0 || iu >= static_cast<int>(kSparseW) ||
                    iv < 0 || iv >= static_cast<int>(kSparseH)) continue;

                const std::size_t feat_idx = static_cast<std::size_t>(iv) * kSparseW + iu;
                // Prefer closer depth (front-most surface wins)
                if (sparse_depth_buf[feat_idx] == 0.0f || sparse_depth_buf[feat_idx] > cam_z_pt) {
                    sparse_depth_buf[feat_idx] = cam_z_pt;
                }
                ++feat_projected;
            }

            if (feat_projected >= 3) {
                // Nearest-neighbor dilation to fill gaps (radius=4 pixels)
                // Converts sparse dots to a dense-enough map for TSDF block allocation
                std::vector<float> feat_dilated(kSparseW * kSparseH, 0.0f);
                for (int fv = 0; fv < static_cast<int>(kSparseH); ++fv) {
                    for (int fu = 0; fu < static_cast<int>(kSparseW); ++fu) {
                        const float fd = sparse_depth_buf[fv * kSparseW + fu];
                        if (fd > 0.0f) { feat_dilated[fv * kSparseW + fu] = fd; continue; }
                        float best_fd = 0.0f;
                        float best_fd_dist2 = 25.0f;  // cap radius at 5 pixels
                        for (int ddv = -4; ddv <= 4; ++ddv) {
                            for (int ddu = -4; ddu <= 4; ++ddu) {
                                const int nu = fu + ddu, nv = fv + ddv;
                                if (nu < 0 || nu >= static_cast<int>(kSparseW) ||
                                    nv < 0 || nv >= static_cast<int>(kSparseH)) continue;
                                const float nd = sparse_depth_buf[nv * kSparseW + nu];
                                if (nd <= 0.0f) continue;
                                const float dist2 = static_cast<float>(ddu * ddu + ddv * ddv);
                                if (dist2 < best_fd_dist2) { best_fd_dist2 = dist2; best_fd = nd; }
                            }
                        }
                        feat_dilated[fv * kSparseW + fu] = best_fd;
                    }
                }
                sparse_depth_buf = std::move(feat_dilated);

                // Use sparse metric depth as depth source
                depth_source = sparse_depth_buf.data();
                depth_w = kSparseW;
                depth_h = kSparseH;
                depth_is_metric = true;  // ARKit VIO scale is real-world metric

                static std::uint32_t sparse_diag_cnt = 0;
                if (++sparse_diag_cnt <= 5 || sparse_diag_cnt % 120 == 0) {
                    std::fprintf(stderr,
                        "[Aether3D][SparseDepth] #%u: %d ARKit VIO pts → %ux%u sparse metric"
                        " depth (DAv2 not ready — using VIO fallback)\n",
                        sparse_diag_cnt, feat_projected, kSparseW, kSparseH);
                }
            }
        }

        // Diagnostic: log depth source selection (first 5 frames + every 60th)
        {
            static std::uint32_t depth_sel_counter = 0;
            depth_sel_counter++;
            if (depth_sel_counter <= 5 || depth_sel_counter % 60 == 0) {
                {
                    const int source_valid = depth_source
                        ? (depth_is_metric
                            ? (lidar_depth_usable ? 1 : 0)
                            : (dav2_affine_valid_ ? 1 : 0))
                        : 0;
                    float inv0 = dav2_affine_shift_;
                    float inv1 = dav2_affine_scale_ + dav2_affine_shift_;
                    float z_near = (inv0 > 0.01f && inv1 > 0.01f)
                        ? 1.0f / std::max(inv0, inv1) : 0.0f;
                    float z_far = (inv0 > 0.01f && inv1 > 0.01f)
                        ? 1.0f / std::min(inv0, inv1) : 0.0f;
                    std::fprintf(stderr,
                        "[Aether3D][DepthSrc] #%u: source=%s %ux%u metric=%d | "
                        "lidar_avail=%d(%ux%u) dav2_avail=%d(%ux%u) "
                        "inv_affine=[%.3f, %.3f] z=[%.2f, %.2f]m "
                        "lidar_valid=%.3f source_valid=%d\n",
                        depth_sel_counter,
                        depth_source ? (depth_is_metric ? "LiDAR" : "DAv2") : "NONE",
                        depth_w, depth_h, depth_is_metric ? 1 : 0,
                        !input.lidar_depth.empty() ? 1 : 0, input.lidar_w, input.lidar_h,
                        !input.ne_depth.empty() ? 1 : 0, input.ne_depth_w, input.ne_depth_h,
                        dav2_affine_scale_, dav2_affine_shift_,
                        z_near, z_far,
                        lidar_valid_ratio,
                        source_valid);
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════
        // TSDF Integration (replaces point cloud accumulation + quality grid)
        // ═══════════════════════════════════════════════════════════════
        // Depth → metric → TSDF integrate → surface extraction + overlay.
        // Saves ~285MB vs old accumulation (480MB → 200MB TSDF).
        // TSDF provides: visualization, quality tracking, multi-frame fusion.
        //
        // Guard: skip after finish_scanning() to prevent data race with export.
        PointCloudData pc_data;
        const bool have_usable_depth = depth_source && depth_w > 0 && depth_h > 0;
        std::vector<float> preview_metric_depth_for_training;
        std::uint32_t preview_metric_depth_w = 0;
        std::uint32_t preview_metric_depth_h = 0;
        bool preview_metric_depth_valid = false;
        const bool imported_video_preview =
            config_.local_preview_mode && input.imported_video;
        const std::uint32_t preview_keyframes_ready =
            preview_keyframe_gate_accepts_.load(std::memory_order_relaxed);
        const std::uint32_t imported_video_min_keyframes_for_bootstrap =
            std::max<std::uint32_t>(
                config_.min_frames_to_start_training * 2u,
                6u);
        const bool preview_bootstrap_needed =
            imported_video_preview &&
            preview_keyframes_ready <
            imported_video_min_keyframes_for_bootstrap;
        const bool imported_video_preview_fast_path =
            imported_video_preview &&
            (preview_bootstrap_needed ||
             frame_queue_.size_approx() > 16u);
        const bool imported_video_sparse_fusion_frame =
            imported_video_preview &&
            (preview_bootstrap_needed ||
             frame_queue_.size_approx() > 16u ||
             (preview_keyframes_ready <
                  imported_video_min_keyframes_for_bootstrap * 2u &&
              (input.source_frame_index % 6u) != 0u));

        // Signal that Thread A is entering TSDF-access critical section.
        // export_point_cloud_ply() waits for tsdf_idle_ before reading.
        tsdf_idle_.store(false, std::memory_order_release);

        // Keep overlay camera state in sync even when DAv2/LiDAR depth is missing.
        // Early startup (first ~10s) often has no depth; stale camera causes
        // fallback overlays to be frustum-culled away and HUD stuck at 0.
        overlay_cam_pos_[0] = input.transform[12];
        overlay_cam_pos_[1] = input.transform[13];
        overlay_cam_pos_[2] = input.transform[14];
        // ARKit col2 points backward; negate to get forward direction.
        overlay_cam_fwd_[0] = -input.transform[8];
        overlay_cam_fwd_[1] = -input.transform[9];
        overlay_cam_fwd_[2] = -input.transform[10];

        if (!features_frozen_.load(std::memory_order_acquire) && have_usable_depth) {
            no_depth_consecutive_ = 0;  // Depth available — reset consecutive counter

            // ── Step 1: Relative → metric depth + edge noise filter ──
            // DAv2 produces noisy depth at object edges (depth discontinuities).
            // These edge pixels have wildly wrong interpolated values → TSDF
            // creates false blocks in empty air between foreground and background.
            //
            // Fix: detect depth edges via local gradient magnitude. If a pixel's
            // depth differs from its neighbors by > 20% of its own value, mark
            // it as invalid (set to 0). The TSDF skips pixels with depth=0.
            const std::size_t depth_pixel_count =
                static_cast<std::size_t>(depth_w) * depth_h;
            std::vector<float> metric_depth(depth_pixel_count, 0.0f);

            if (depth_is_metric) {
                std::memcpy(metric_depth.data(), depth_source,
                            depth_pixel_count * sizeof(float));
            } else {
                // ── RECIPROCAL AFFINE: metric_z = 1 / (scale * d_pred + shift) ──
                // DAv2 outputs INVERSE DEPTH (disparity-like). The correct
                // conversion is: compute inverse depth linearly, then take reciprocal.
                //   inv_depth = scale * d_pred + shift
                //   metric_z  = 1 / inv_depth
                //
                // This is mathematically EXACT for disparity → depth conversion.
                // The old linear model (metric = a*d + b) was a line approximating
                // a hyperbola, causing ~0.6m errors at mid-range depths.
                //
                // After conversion, clamp to valid TSDF depth range.
                constexpr float kDepthMin = 0.1f;   // TSDF DEPTH_MIN
                constexpr float kDepthMax = 5.0f;   // TSDF DEPTH_MAX
                constexpr float kInvDepthMin = 0.001f;  // Prevent division by near-zero
                for (std::size_t i = 0; i < depth_pixel_count; ++i) {
                    float d_pred = depth_source[i];
                    if (!std::isfinite(d_pred)) {
                        metric_depth[i] = 0.0f;
                        continue;
                    }
                    float inv_m = dav2_affine_scale_ * d_pred + dav2_affine_shift_;
                    if (inv_m < kInvDepthMin || !std::isfinite(inv_m)) {
                        metric_depth[i] = 0.0f;
                        continue;
                    }
                    float m = 1.0f / inv_m;
                    if (m < kDepthMin || m > kDepthMax) {
                        metric_depth[i] = 0.0f;
                    } else {
                        metric_depth[i] = m;
                    }
                }

                // Edge filter — zero out pixels at depth discontinuities.
                // Check 4-connected neighbors: if max |d_self - d_neighbor| / d_self > 20%,
                // the pixel is on a depth edge → unreliable → set to 0.
                // This removes "flying pixel" artifacts at depth boundaries.
                constexpr float kEdgeThreshold = 0.20f;  // 20% relative difference
                const int dw = static_cast<int>(depth_w);
                const int dh = static_cast<int>(depth_h);

                for (int v = 1; v < dh - 1; ++v) {
                    for (int u = 1; u < dw - 1; ++u) {
                        const std::size_t idx = static_cast<std::size_t>(v) * dw + u;
                        float d = metric_depth[idx];
                        if (d <= 0.0f || !std::isfinite(d)) continue;

                        // Check 4 neighbors
                        float d_left  = metric_depth[idx - 1];
                        float d_right = metric_depth[idx + 1];
                        float d_up    = metric_depth[idx - dw];
                        float d_down  = metric_depth[idx + dw];

                        float max_diff = 0.0f;
                        if (d_left  > 0.0f) max_diff = std::max(max_diff, std::abs(d - d_left));
                        if (d_right > 0.0f) max_diff = std::max(max_diff, std::abs(d - d_right));
                        if (d_up    > 0.0f) max_diff = std::max(max_diff, std::abs(d - d_up));
                        if (d_down  > 0.0f) max_diff = std::max(max_diff, std::abs(d - d_down));

                        if (max_diff > d * kEdgeThreshold) {
                            metric_depth[idx] = 0.0f;  // Mark as invalid edge pixel
                        }
                    }
                }

                // Also zero out border pixels (no valid neighbors to check)
                for (int u = 0; u < dw; ++u) {
                    metric_depth[u] = 0.0f;                                        // top row
                    metric_depth[static_cast<std::size_t>(dh - 1) * dw + u] = 0.0f;  // bottom row
                }
                for (int v = 0; v < dh; ++v) {
                    metric_depth[static_cast<std::size_t>(v) * dw] = 0.0f;           // left col
                    metric_depth[static_cast<std::size_t>(v) * dw + dw - 1] = 0.0f;  // right col
                }
            }

            if (config_.local_preview_mode && input.imported_video) {
                update_imported_video_bootstrap_pose(
                    input,
                    metric_depth.data(),
                    depth_w,
                    depth_h,
                    imported_video_bootstrap_pose_initialized_,
                    imported_video_bootstrap_pose_,
                    imported_video_bootstrap_target_points_world_,
                    imported_video_bootstrap_target_normals_world_,
                    imported_video_bootstrap_intrinsics_initialized_,
                    imported_video_bootstrap_intrinsics_);
            }

            if (config_.local_preview_mode &&
                input.imported_video &&
                !metric_depth.empty()) {
                // Imported album videos must carry per-frame metric depth all
                // the way into the training thread. Previously we only copied
                // it after leaving the bootstrap fast-path, which meant the
                // first selected frames often reached seed initialization
                // without metric depth and collapsed MVS into a single-frame
                // DAv2 bootstrap.
                preview_metric_depth_for_training = metric_depth;
                preview_metric_depth_w = depth_w;
                preview_metric_depth_h = depth_h;
                preview_metric_depth_valid = true;
            }

            if (config_.local_preview_mode &&
                input.imported_video &&
                input.feature_count == 0 &&
                !metric_depth.empty()) {
                const bool init_pass =
                    preview_keyframes_ready < imported_video_min_keyframes_for_bootstrap;
                std::uint32_t synthesized = synthesize_preview_feature_points_from_depth(
                    input,
                    metric_depth.data(),
                    depth_w,
                    depth_h,
                    init_pass);
                if (synthesized == 0 &&
                    !init_pass &&
                    input.feature_count == 0) {
                    // Once bootstrap exits the "init" phase we still need
                    // sparse geometric evidence every frame. Retry with the
                    // denser bootstrap sampling instead of silently dropping to
                    // feat=0 / overlap=1.000 behavior.
                    synthesized = synthesize_preview_feature_points_from_depth(
                        input,
                        metric_depth.data(),
                        depth_w,
                        depth_h,
                        true);
                }
                static std::uint32_t preview_feature_diag_counter = 0;
                preview_feature_diag_counter++;
                if (synthesized > 0 &&
                    (preview_feature_diag_counter <= 10 || preview_feature_diag_counter % 60 == 0)) {
                    std::fprintf(
                        stderr,
                        "[Aether3D][PreviewFeatures] synthesized=%u init=%d depth=%ux%u imported=%d\n",
                        synthesized,
                        init_pass ? 1 : 0,
                        depth_w,
                        depth_h,
                        input.imported_video ? 1 : 0);
                }
            }

            const bool imported_video_streaming_bootstrap_frame =
                imported_video_preview &&
                (preview_bootstrap_needed ||
                 preview_frames_ingested_.load(std::memory_order_relaxed) <
                    static_cast<std::uint32_t>(std::max<std::size_t>(
                        config_.min_frames_to_start_training + 2u,
                        5u)) ||
                 frame_queue_.size_approx() > 2u);

            if (!imported_video_streaming_bootstrap_frame) {
            // WildGS-style depth validity refinement:
            // 1. Median clip far-tail hallucinations.
            // 2. Multi-view support check against recent keyframes.
            // 3. Export a per-pixel confidence map for later overlay filtering.
            std::vector<unsigned char> depth_conf(depth_pixel_count, 0u);
            const float sx = static_cast<float>(depth_w) / static_cast<float>(input.width);
            const float sy = static_cast<float>(depth_h) / static_cast<float>(input.height);
            const float depth_fx = input.intrinsics[0] * sx;
            const float depth_fy = input.intrinsics[4] * sy;
            const float depth_cx = input.intrinsics[2] * sx;
            const float depth_cy = input.intrinsics[5] * sy;

            {
                std::vector<float> valid_depths;
                valid_depths.reserve(depth_pixel_count / 4);
                for (std::size_t i = 0; i < depth_pixel_count; ++i) {
                    const float d = metric_depth[i];
                    if (d > 0.1f && d < 5.0f && std::isfinite(d)) valid_depths.push_back(d);
                }
                if (!valid_depths.empty()) {
                    auto mid = valid_depths.begin() + static_cast<std::ptrdiff_t>(valid_depths.size() / 2);
                    std::nth_element(valid_depths.begin(), mid, valid_depths.end());
                    const float median_depth = *mid;
                    const float far_clip = std::max(3.0f * median_depth, 0.5f);
                    for (std::size_t i = 0; i < depth_pixel_count; ++i) {
                        if (metric_depth[i] > far_clip) metric_depth[i] = 0.0f;
                    }
                }
            }

            if (!imported_video_preview_fast_path && !depth_keyframes_.empty()) {
                const std::size_t kf_limit = std::min<std::size_t>(6, depth_keyframes_.size());
                for (std::uint32_t v = 0; v < depth_h; ++v) {
                    for (std::uint32_t u = 0; u < depth_w; ++u) {
                        const std::size_t idx =
                            static_cast<std::size_t>(v) * static_cast<std::size_t>(depth_w) + u;
                        const float d = metric_depth[idx];
                        if (d <= 0.1f || d >= 5.0f || !std::isfinite(d)) continue;

                        if (depth_fx <= 0.0f || depth_fy <= 0.0f) {
                            metric_depth[idx] = 0.0f;
                            continue;
                        }
                        // Keep imported-video/local_preview depth validation in
                        // the same ARKit camera convention as TSDF, DAv2 init,
                        // and MVS init: image Y points down, camera Y points
                        // up, and visible points lie at negative camera Z.
                        const float cam_x =
                            (static_cast<float>(u) - depth_cx) * d / depth_fx;
                        const float cam_y =
                            -(static_cast<float>(v) - depth_cy) * d / depth_fy;
                        const float cam_z = -d;
                        float world[3];
                        world[0] = input.transform[0] * cam_x + input.transform[4] * cam_y +
                                   input.transform[8] * cam_z + input.transform[12];
                        world[1] = input.transform[1] * cam_x + input.transform[5] * cam_y +
                                   input.transform[9] * cam_z + input.transform[13];
                        world[2] = input.transform[2] * cam_x + input.transform[6] * cam_y +
                                   input.transform[10] * cam_z + input.transform[14];

                        int visible_num = 0;
                        int consistent_num = 0;
                        for (std::size_t k = 0; k < kf_limit; ++k) {
                            const auto& kf = depth_keyframes_[depth_keyframes_.size() - 1 - k];
                            const float ddx = world[0] - kf.pose[12];
                            const float ddy = world[1] - kf.pose[13];
                            const float ddz = world[2] - kf.pose[14];
                            const float cam_x =  kf.pose[0]*ddx + kf.pose[1]*ddy + kf.pose[2]*ddz;
                            const float cam_y = -(kf.pose[4]*ddx + kf.pose[5]*ddy + kf.pose[6]*ddz);
                            const float cam_z = -(kf.pose[8]*ddx + kf.pose[9]*ddy + kf.pose[10]*ddz);
                            if (cam_z <= 0.1f || cam_z >= 5.0f) continue;

                            const int iu = static_cast<int>(kf.fx * (cam_x / cam_z) + kf.cx);
                            const int iv = static_cast<int>(kf.fy * (cam_y / cam_z) + kf.cy);
                            if (iu < 1 || iv < 1 || iu >= kf.width - 1 || iv >= kf.height - 1) continue;

                            const std::size_t kf_idx =
                                static_cast<std::size_t>(iv) * static_cast<std::size_t>(kf.width) + iu;
                            if (!kf.conf.empty() && kf.conf[kf_idx] == 0u) continue;
                            const float kd = kf.depth[kf_idx];
                            if (kd <= 0.1f || kd >= 5.0f || !std::isfinite(kd)) continue;

                            ++visible_num;
                            if (std::abs(cam_z - kd) < 0.05f) ++consistent_num;
                        }

                        if (visible_num >= 2 && consistent_num == 0) {
                            metric_depth[idx] = 0.0f;
                            continue;
                        }
                        if (visible_num >= 3 && consistent_num * 3 < visible_num) {
                            metric_depth[idx] = 0.0f;
                            continue;
                        }

                        if (depth_is_metric) {
                            depth_conf[idx] = 2u;
                        } else if (consistent_num >= 2) {
                            depth_conf[idx] = 2u;
                        } else {
                            depth_conf[idx] = 1u;
                        }
                    }
                }
            }

            for (std::size_t i = 0; i < depth_pixel_count; ++i) {
                const float d = metric_depth[i];
                if (d > 0.1f && d < 5.0f && std::isfinite(d) && depth_conf[i] == 0u) {
                    depth_conf[i] = depth_is_metric ? 2u : 1u;
                }
            }

            float mean_depth = 0.0f;
            {
                double sum = 0.0;
                std::size_t cnt = 0;
                for (std::size_t i = 0; i < depth_pixel_count; i += 16) {
                    float d = metric_depth[i];
                    if (d > 0.1f && d < 5.0f && std::isfinite(d)) {
                        sum += d;
                        cnt++;
                    }
                }
                mean_depth = cnt > 0 ? static_cast<float>(sum / cnt) : 1.0f;
            }

            float voxel_size = tsdf::continuous_voxel_size(
                mean_depth, 0.5f, false,
                tsdf::default_continuous_resolution_config());

            tsdf::IntegrationInput tsdf_input;
            tsdf_input.depth_data = metric_depth.data();
            tsdf_input.depth_width = static_cast<int>(depth_w);
            tsdf_input.depth_height = static_cast<int>(depth_h);
            tsdf_input.voxel_size = voxel_size;
            tsdf_input.fx = input.intrinsics[0] * sx;
            tsdf_input.fy = input.intrinsics[4] * sy;
            tsdf_input.cx = input.intrinsics[2] * sx;
            tsdf_input.cy = input.intrinsics[5] * sy;
            tsdf_input.view_matrix = input.transform;
            tsdf_input.timestamp = input.timestamp;
            tsdf_input.tracking_state = 2;  // ARKit normal tracking

            tsdf::IntegrationResult tsdf_result{};
            const bool run_full_imported_video_fusion =
                !imported_video_preview_fast_path ||
                (preview_keyframes_ready >= imported_video_min_keyframes_for_bootstrap &&
                 !preview_bootstrap_needed &&
                 !imported_video_sparse_fusion_frame);
            if (run_full_imported_video_fusion) {
                // Imported-video local_preview is a speed-critical path.
                // Do not run full TSDF/overlay work on every frame; it starves
                // native ingestion and makes the app look stuck at 1/54. We
                // still fuse periodic frames so degraded fallback remains
                // available, but the common path prioritizes depth + keyframe
                // admission + repo-native DAv2 seeding.
                tsdf_volume_->integrate(tsdf_input, tsdf_result);
            } else {
                pc_data.tsdf_block_count = tsdf_volume_->active_block_count();
            }

            // ── Step 3: Surface point extraction ──
            // DISABLED: Point cloud Pass 1 is disabled in Metal pipeline.
            // Skip expensive extract_surface_points() to save ~40% CPU.
            // Surface points were only used for visualization; the quality
            // overlay (Step 4) now provides the scanning feedback instead.
            // pc_data.vertices remains empty → pcCount=0 in Metal.

            // TSDF block count = scan coverage metric (replaces surface point count)
            pc_data.tsdf_block_count = tsdf_volume_->active_block_count();

            // ── Step 4: Generate quality overlay from TSDF block weights ──
            // ── Store depth keyframe for overlay depth-consistency filter ──
            // Trigger on EITHER position change (>1.5cm) OR angle change (>10°).
            // Critical: hand-held hovering only produces ~7mm/frame jitter,
            // so a 5cm threshold NEVER fires → filter stays inactive → phantoms!
            // Ring buffer of 24 keyframes covers diverse viewpoints.
            // Memory: 24 × ~48KB ≈ 1.1MB (acceptable on mobile).
            if (run_full_imported_video_fusion && !imported_video_preview_fast_path) {
                float kf_dx = overlay_cam_pos_[0] - last_keyframe_pos_[0];
                float kf_dy = overlay_cam_pos_[1] - last_keyframe_pos_[1];
                float kf_dz = overlay_cam_pos_[2] - last_keyframe_pos_[2];
                float kf_dist_sq = kf_dx*kf_dx + kf_dy*kf_dy + kf_dz*kf_dz;

                // Forward vector change (cos angle between current and last keyframe fwd)
                float fwd_x = overlay_cam_fwd_[0];
                float fwd_y = overlay_cam_fwd_[1];
                float fwd_z = overlay_cam_fwd_[2];
                float cos_angle = fwd_x * last_keyframe_fwd_[0]
                                + fwd_y * last_keyframe_fwd_[1]
                                + fwd_z * last_keyframe_fwd_[2];
                // cos(10°) ≈ 0.985
                bool angle_changed = cos_angle < 0.985f;

                if (!has_keyframe_ || kf_dist_sq > 0.015f * 0.015f || angle_changed) {
                    DepthKeyframe kf;
                    kf.depth = metric_depth;  // Copy depth frame (~48KB at 256×192)
                    kf.conf = depth_conf;
                    kf.width = static_cast<int>(depth_w);
                    kf.height = static_cast<int>(depth_h);
                    kf.fx = tsdf_input.fx;
                    kf.fy = tsdf_input.fy;
                    kf.cx = tsdf_input.cx;
                    kf.cy = tsdf_input.cy;
                    std::memcpy(kf.pose, input.transform, 16 * sizeof(float));
                    // Store full-res RGBA for Gaussian seed color initialization
                    kf.rgba = input.rgba;
                    kf.rgba_w = static_cast<int>(input.width);
                    kf.rgba_h = static_cast<int>(input.height);
                    std::memcpy(kf.rgba_intrinsics, input.intrinsics, 9 * sizeof(float));

                    if (depth_keyframes_.size() >= kMaxDepthKeyframes) {
                        depth_keyframes_.erase(depth_keyframes_.begin());
                    }
                    depth_keyframes_.push_back(std::move(kf));

                    last_keyframe_pos_[0] = overlay_cam_pos_[0];
                    last_keyframe_pos_[1] = overlay_cam_pos_[1];
                    last_keyframe_pos_[2] = overlay_cam_pos_[2];
                    last_keyframe_fwd_[0] = fwd_x;
                    last_keyframe_fwd_[1] = fwd_y;
                    last_keyframe_fwd_[2] = fwd_z;
                    has_keyframe_ = true;
                }
            }

            if (!imported_video_preview_fast_path && run_full_imported_video_fusion) {
                generate_overlay_vertices(pc_data, input);
                if (!pc_data.overlay.empty()) {
                    last_stable_surface_overlay_ = pc_data.overlay;
                }
            }

            // ── GSFusion per-frame quadtree Gaussian seeding ──
            // Supplements TSDF block seeding with temporally-distributed seeds.
            // Directly adapted from GSFusion (Wei et al., 2024).
            if (!input.rgba.empty() &&
                !metric_depth.empty() &&
                !imported_video_preview_fast_path &&
                run_full_imported_video_fusion) {
                const auto preview_seed_phase_t0 = config_.local_preview_mode
                    ? std::chrono::steady_clock::now()
                    : std::chrono::steady_clock::time_point{};
                seed_gaussians_per_frame_gsf(
                    input.rgba.data(),
                    static_cast<int>(input.width),
                    static_cast<int>(input.height),
                    metric_depth.data(),
                    static_cast<int>(depth_w),
                    static_cast<int>(depth_h),
                    tsdf_input.fx, tsdf_input.fy,
                    tsdf_input.cx, tsdf_input.cy,
                    input.transform,
                    input.imported_video);
                if (config_.local_preview_mode) {
                    const auto preview_seed_phase_t1 = std::chrono::steady_clock::now();
                    const auto preview_seed_elapsed_ms = static_cast<std::uint64_t>(
                        std::chrono::duration_cast<std::chrono::milliseconds>(
                            preview_seed_phase_t1 - preview_seed_phase_t0
                        ).count()
                    );
                    preview_seed_phase_ms_.fetch_add(
                        preview_seed_elapsed_ms,
                        std::memory_order_relaxed
                    );
                }
            }

            // ── Diagnostic: TSDF integration progress ──
            {
                static std::uint32_t tsdf_diag = 0;
                tsdf_diag++;
                if (run_full_imported_video_fusion &&
                    (tsdf_diag <= 10 || tsdf_diag % 60 == 0)) {
                    std::fprintf(stderr,
                        "[Aether3D] TSDF[%u]: voxels=%d blocks=%d surface=%zu "
                        "features=%u voxel_size=%.3f success=%d depth_metric=%d\n",
                        tsdf_diag,
                        tsdf_result.voxels_integrated,
                        tsdf_result.blocks_updated,
                        pc_data.vertices.size(),
                        input.feature_count,
                        voxel_size,
                        tsdf_result.success ? 1 : 0,
                        depth_is_metric ? 1 : 0);
                }
            }
            } else {
                pc_data.tsdf_block_count =
                    tsdf_volume_ ? tsdf_volume_->active_block_count() : 0u;
            }
        } else {
            // No depth available — log diagnostic
            no_depth_consecutive_++;
            static std::uint32_t no_depth_diag = 0;
            no_depth_diag++;
            const bool should_log_no_depth = (no_depth_diag <= 10 || no_depth_diag % 60 == 0);
            const bool frozen = features_frozen_.load(std::memory_order_acquire);
            std::size_t hold_surface_emitted = 0;

            // Still generate overlay from existing TSDF data — heatmap must
            // persist even when no new depth arrives this frame. The overlay
            // reflects training coverage so far, not just this frame's depth.
            if (!frozen && !imported_video_preview_fast_path) {
                generate_overlay_vertices(pc_data, input);
            }
            if (!pc_data.overlay.empty()) {
                // Depth-free frame still got TSDF surface overlay (from history);
                // keep this as the last stable surface-attached result.
                last_stable_surface_overlay_ = pc_data.overlay;
            } else if (!last_stable_surface_overlay_.empty() &&
                       !frozen &&
                       !imported_video_preview_fast_path) {
                // No new depth: freeze previous surface-confirmed overlay.
                // This avoids generating camera-anchored floating tiles.
                pc_data.overlay = last_stable_surface_overlay_;
                hold_surface_emitted = pc_data.overlay.size();
            }

            if (should_log_no_depth) {
                std::fprintf(stderr,
                    "[Aether3D] Frame[%u]: NO DEPTH — ne_depth=%zu lidar=%zu "
                    "features=%u frozen=%d consecutive=%u overlay=%zu hold=%zu\n",
                    no_depth_diag,
                    input.ne_depth.size(),
                    input.lidar_depth.size(),
                    input.feature_count,
                    frozen ? 1 : 0,
                    no_depth_consecutive_,
                    pc_data.overlay.size(),
                    hold_surface_emitted);
            }
        }

        // TSDF access complete — signal idle so export_point_cloud_ply() can proceed.
        tsdf_idle_.store(true, std::memory_order_release);

        // ─── ARKit feature points (ALWAYS rendered, independent of depth) ───
        if (!features_frozen_.load(std::memory_order_acquire) &&
            input.feature_count > 0) {
            for (std::uint32_t i = 0; i < input.feature_count; ++i) {
                float px = input.feature_points[i * 3 + 0];
                float py = input.feature_points[i * 3 + 1];
                float pz = input.feature_points[i * 3 + 2];

                PointCloudVertex v;
                v.position[0] = px;
                v.position[1] = py;
                v.position[2] = pz;

                // Reproject 3D → 2D to sample real color from camera image
                float dwx = px - input.transform[12];
                float dwy = py - input.transform[13];
                float dwz = pz - input.transform[14];
                float cam_x = input.transform[0]*dwx + input.transform[1]*dwy + input.transform[2]*dwz;
                float cam_y = input.transform[4]*dwx + input.transform[5]*dwy + input.transform[6]*dwz;
                const float cam_z =
                    -(input.transform[8]*dwx + input.transform[9]*dwy + input.transform[10]*dwz);

                if (cam_z > 0.1f) {
                    const float u = input.intrinsics[0] * cam_x / cam_z + input.intrinsics[2];
                    const float vv = input.intrinsics[4] * cam_y / cam_z + input.intrinsics[5];
                    auto iu = static_cast<std::uint32_t>(u + 0.5f);
                    auto iv = static_cast<std::uint32_t>(vv + 0.5f);
                    if (iu < input.width && iv < input.height) {
                        const std::uint8_t* px_data = input.rgba.data() + (iv * input.width + iu) * 4;
                        v.color[0] = g_srgb_lut.table[px_data[2]];  // R (BGRA→RGB)
                        v.color[1] = g_srgb_lut.table[px_data[1]];  // G
                        v.color[2] = g_srgb_lut.table[px_data[0]];  // B
                    } else {
                        v.color[0] = v.color[1] = v.color[2] = 0.5f;
                    }
                } else {
                    v.color[0] = v.color[1] = v.color[2] = 0.5f;
                }
                v.size = 4.0f;
                v.alpha = 0.85f;
                pc_data.vertices.push_back(v);
            }
        }

        // ─── Point Cloud → 3DGS blend control ───
        std::size_t splat_count = renderer_.splat_count();
        float alpha = 1.0f;
        if (splat_count > static_cast<std::size_t>(config_.blend_start_splat_count)) {
            float blend_range = config_.blend_end_splat_count - config_.blend_start_splat_count;
            float blend_progress = static_cast<float>(
                splat_count - static_cast<std::size_t>(config_.blend_start_splat_count));
            alpha = 1.0f - std::clamp(blend_progress / blend_range, 0.0f, 1.0f);
        }
        pc_data.blend_alpha = alpha;
        pointcloud_alpha_.store(alpha, std::memory_order_relaxed);

        // Publish point cloud to GPU (triple buffer)
        auto& pc_buf = pointcloud_buffer_.write_buffer();
        pc_buf = std::move(pc_data);
        pointcloud_buffer_.publish();

        // ─── Frame Selection for Training ───
        bool frame_selected = false;
        const bool allow_frame_selection =
            scanning_active_.load(std::memory_order_relaxed) ||
            (config_.local_preview_mode && input.imported_video);
        if (allow_frame_selection) {
            capture::FrameCandidate candidate;
            candidate.rgba_ptr = input.rgba.data();
            candidate.width = input.width;
            candidate.height = input.height;
            std::memcpy(candidate.transform, input.transform, sizeof(candidate.transform));
            candidate.intrinsics[0] = input.intrinsics[0];
            candidate.intrinsics[1] = input.intrinsics[4];
            candidate.intrinsics[2] = input.intrinsics[2];
            candidate.intrinsics[3] = input.intrinsics[5];
            candidate.timestamp = input.timestamp;
            candidate.quality_score = 1.0f;  // Evidence-free: always high
            candidate.blur_score = is_low_light
                ? (blur / std::max(config_.low_light_blur_strictness, 1e-3f))
                : blur;
            candidate.feature_xyz = input.feature_count > 0 ? input.feature_points : nullptr;
            candidate.feature_count = input.feature_count;

            float current_pos[3];
            float current_fwd[3];
            extract_camera_pose_metrics(
                input.transform,
                current_pos,
                current_fwd);

            auto sel_result = frame_selector_.evaluate(candidate);
            std::uint32_t sel_diag_counter_snapshot = 0;
            std::uint32_t gate3_reject_streak_snapshot = 0;

            // ─── Frame selection diagnostic (verbose for debugging) ───
            // Gate codes: 0=selected, 1=quality, 2=blur, 3=motion
            // Log first 50 frames + every 30th + all selected + rejection summary
            {
                static std::uint32_t sel_diag_counter = 0;
                static std::uint32_t gate3_reject_streak = 0;
                sel_diag_counter++;
                auto total_selected = selected_frame_count_.load(std::memory_order_relaxed);
                bool s6 = has_s6_quality_.load(std::memory_order_relaxed);

                // Track gate 3 rejection streaks
                if (sel_result.reject_gate == 3) {
                    gate3_reject_streak++;
                } else {
                    gate3_reject_streak = 0;
                }

                sel_diag_counter_snapshot = sel_diag_counter;
                gate3_reject_streak_snapshot = gate3_reject_streak;

                bool should_log = (sel_diag_counter <= 50) ||
                                  (sel_diag_counter % 30 == 0) ||
                                  sel_result.selected ||
                                  (!s6 && total_selected <= 10) ||
                                  (gate3_reject_streak >= 30 && (gate3_reject_streak % 30 == 0));

                if (should_log) {
                    // Compute position + rotation displacement for debugging
                    float pos[3] = {input.transform[12], input.transform[13], input.transform[14]};
                    float fwd[3] = {-input.transform[8], -input.transform[9], -input.transform[10]};
                    float fwd_len = std::sqrt(fwd[0]*fwd[0] + fwd[1]*fwd[1] + fwd[2]*fwd[2]);
                    if (fwd_len > 1e-6f) { fwd[0]/=fwd_len; fwd[1]/=fwd_len; fwd[2]/=fwd_len; }

                    std::fprintf(stderr,
                        "[Aether3D][FrameSel] frame=%u blur=%.3f "
                        "selected=%s gate=%d | total=%zu S6+=%s "
                        "ne_depth=%s | pos=(%.3f,%.3f,%.3f) "
                        "feat=%u overlap=%.3f dist=%.3fm depth=%.3fm rot=%.2fdeg "
                        "gate3_streak=%u\n",
                        sel_diag_counter,
                        blur,
                        sel_result.selected ? "YES" : "NO",
                        sel_result.reject_gate,
                        total_selected,
                        s6 ? "YES" : "no",
                        input.ne_depth.empty() ? "NO" : "YES",
                        pos[0], pos[1], pos[2],
                        input.feature_count,
                        sel_result.overlap_ratio,
                        sel_result.translation_m,
                        sel_result.median_depth_m,
                        sel_result.rotation_rad * 180.0f / 3.14159f,
                        gate3_reject_streak);

                    if (gate3_reject_streak >= 30 && (gate3_reject_streak % 30 == 0)) {
                        std::fprintf(stderr,
                            "[Aether3D][FrameSel] ⚠ %u consecutive gate=3 rejects! "
                            "MonoGS keyframe gate still says overlap too high / translation too small "
                            "(dist=%.1fmm, overlap=%.3f, depth=%.2fm).\n",
                            gate3_reject_streak,
                            sel_result.translation_m * 1000.0f,
                            sel_result.overlap_ratio,
                            sel_result.median_depth_m);
                    }
                }
            }

            // Note: blur check is already inside frame_selector_.evaluate() (Gate 2).
            // Removing redundant external check — the selector's threshold is authoritative.
            bool preview_gate_accepted = true;
            const bool has_depth_prior =
                (!input.ne_depth.empty() && input.ne_depth_w > 0 && input.ne_depth_h > 0) ||
                (!input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0);
            const std::uint32_t imported_video_bootstrap_force_select_target =
                static_cast<std::uint32_t>(kPreviewMaxTrainingFrames);
            const bool imported_video_bootstrap_force_select =
                config_.local_preview_mode &&
                input.imported_video &&
                has_depth_prior &&
                selected_frame_count_.load(std::memory_order_relaxed) <
                    imported_video_bootstrap_force_select_target;

            if ((sel_result.selected || imported_video_bootstrap_force_select) &&
                config_.local_preview_mode) {
                // Imported-video local_preview already goes through the repo-native
                // MonoGS-style FrameSelector (quality + blur + overlap/translation
                // keyframe gate). Do not stack an extra preview-only motion gate on
                // top of it; that double-gating was our own engineering layer and
                // made imported album videos under-select frames, collapsing the
                // geometry into thin shells. Keep the additional preview gate only
                // for live capture, where it still acts as a bounded-budget guard.
                if (input.imported_video) {
                    preview_keyframe_gate_accepts_.fetch_add(
                        1, std::memory_order_relaxed);
                    std::memcpy(
                        preview_last_selected_pos_,
                        current_pos,
                        sizeof(preview_last_selected_pos_));
                    std::memcpy(
                        preview_last_selected_fwd_,
                        current_fwd,
                        sizeof(preview_last_selected_fwd_));
                    has_preview_selected_keyframe_ = true;
                } else {
                    const bool has_depth_prior =
                        (!input.ne_depth.empty() && input.ne_depth_w > 0 && input.ne_depth_h > 0) ||
                        (!input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0);
                    preview_gate_accepted = should_accept_preview_keyframe(
                        has_depth_prior,
                        sel_result,
                        has_preview_selected_keyframe_,
                        current_pos,
                        current_fwd,
                        preview_last_selected_pos_,
                        preview_last_selected_fwd_);
                    if (preview_gate_accepted) {
                        preview_keyframe_gate_accepts_.fetch_add(
                            1, std::memory_order_relaxed);
                        std::memcpy(
                            preview_last_selected_pos_,
                            current_pos,
                            sizeof(preview_last_selected_pos_));
                        std::memcpy(
                            preview_last_selected_fwd_,
                            current_fwd,
                            sizeof(preview_last_selected_fwd_));
                        has_preview_selected_keyframe_ = true;
                    } else {
                        preview_keyframe_gate_rejects_.fetch_add(
                            1, std::memory_order_relaxed);
                    }
                }
            }

            if ((sel_result.selected || imported_video_bootstrap_force_select) && preview_gate_accepted) {
                // Package selected frame for training thread
                SelectedFrame sf;
                sf.rgba = std::move(input.rgba);  // Move ~8MB instead of copying
                sf.width = input.width;
                sf.height = input.height;
                std::memcpy(sf.transform, input.transform, sizeof(sf.transform));
                sf.intrinsics[0] = input.intrinsics[0];
                sf.intrinsics[1] = input.intrinsics[4];
                sf.intrinsics[2] = input.intrinsics[2];
                sf.intrinsics[3] = input.intrinsics[5];
                sf.quality_score = is_low_light ? config_.low_quality_loss_weight : 1.0f;
                sf.is_test_frame = sel_result.is_test_frame;
                // Bug 0.26 fix: pass temporal metadata to training thread
                sf.timestamp = input.timestamp;
                sf.frame_index = input.imported_video
                    ? static_cast<std::uint64_t>(input.source_frame_index)
                    : static_cast<std::uint64_t>(frame_counter_.load(std::memory_order_relaxed));
                sf.imported_video = input.imported_video;

                // Carry DAv2 depth to training thread (key for initialization)
                if (config_.local_preview_mode &&
                    input.imported_video &&
                    preview_metric_depth_valid &&
                    !preview_metric_depth_for_training.empty()) {
                    sf.ne_depth = preview_metric_depth_for_training;
                    sf.ne_depth_w = preview_metric_depth_w;
                    sf.ne_depth_h = preview_metric_depth_h;
                    sf.ne_depth_is_metric = true;
                } else if (!input.ne_depth.empty()) {
                    sf.ne_depth = input.ne_depth;
                    sf.ne_depth_w = input.ne_depth_w;
                    sf.ne_depth_h = input.ne_depth_h;
                    sf.ne_depth_is_metric = input.ne_depth_is_metric;
                }

                // Carry LiDAR metric depth to training (120% enhancement, Pro only)
                if (!input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0) {
                    sf.lidar_depth = input.lidar_depth;
                    sf.lidar_w = input.lidar_w;
                    sf.lidar_h = input.lidar_h;
                }

                if (selected_queue_.try_push(std::move(sf))) {
                    selected_frame_count_.fetch_add(1, std::memory_order_relaxed);
                    frame_selected = true;

                    // Mark TSDF blocks covered by this training frame → heatmap
                    if (tsdf_volume_ &&
                        !(config_.local_preview_mode && input.imported_video)) {
                        tsdf_volume_->mark_training_coverage(
                            input.transform,
                            input.intrinsics[0], input.intrinsics[4],
                            input.intrinsics[2], input.intrinsics[5],
                            input.width, input.height);
                    }
                } else {
                    static std::uint32_t selected_queue_drops = 0;
                    selected_queue_drops++;
                    if (selected_queue_drops <= 5 || (selected_queue_drops % 30 == 0)) {
                        std::fprintf(stderr,
                            "[Aether3D][FrameSel] selected frame dropped (training queue full): "
                            "drops=%u\n",
                            selected_queue_drops);
                    }
                }
            }
        }

        // ─── Build Observation → Thread B ───
        ObservationBatch obs;
        obs.frame_index = frame_counter_.load(std::memory_order_relaxed);
        obs.blur_score = blur;
        obs.brightness = brightness;
        obs.depth_confidence = depth_confidence;
        std::memcpy(obs.transform, input.transform, sizeof(obs.transform));
        std::memcpy(obs.intrinsics, input.intrinsics, sizeof(obs.intrinsics));
        obs.frame_selected = frame_selected;

        // Compute depth stats
        if (depth_source && depth_w > 0 && depth_h > 0) {
            double sum = 0.0;
            std::size_t count = 0;
            const std::size_t total = static_cast<std::size_t>(depth_w) * depth_h;
            for (std::size_t i = 0; i < total; ++i) {
                float d = depth_source[i];
                if (d > 0.0f && std::isfinite(d)) {
                    sum += d;
                    count++;
                }
            }
            if (count > 0) {
                obs.depth_mean = static_cast<float>(sum / count);
                double var_sum = 0.0;
                for (std::size_t i = 0; i < total; ++i) {
                    float d = depth_source[i];
                    if (d > 0.0f && std::isfinite(d)) {
                        double diff = d - obs.depth_mean;
                        var_sum += diff * diff;
                    }
                }
                obs.depth_variance = static_cast<float>(var_sum / count);
            }
        }

        evidence_queue_.try_push(std::move(obs));

        if (config_.local_preview_mode &&
            input.imported_video &&
            !scanning_active_.load(std::memory_order_acquire) &&
            !features_frozen_.load(std::memory_order_acquire)) {
            const auto enqueued =
                preview_frames_enqueued_.load(std::memory_order_relaxed);
            const auto ingested =
                preview_frames_ingested_.load(std::memory_order_relaxed);
            if (enqueued > 0 &&
                ingested >= enqueued &&
                frame_queue_.size_approx() == 0u) {
                features_frozen_.store(true, std::memory_order_release);
                std::fprintf(stderr,
                    "[Aether3D][PreviewMode] imported-video queue drained: freezing features after %u/%u ingested frames\n",
                    ingested,
                    enqueued);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Thread B: Evidence + Quality
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::evidence_thread_func() noexcept {
    ObservationBatch obs;
    auto last_idle_snapshot_publish = std::chrono::steady_clock::now();

    const auto publish_snapshot = [&]() {
        auto& snapshot = evidence_snapshot_.write_buffer();
        snapshot.overall_quality = accumulated_quality_;
        snapshot.frame_count = evidence_frame_count_;
        snapshot.selected_frames = selected_frame_count_.load(std::memory_order_relaxed);
        const bool imported_video_preview_active =
            config_.local_preview_mode &&
            preview_frames_enqueued_.load(std::memory_order_relaxed) > 0u;
        snapshot.min_frames_needed =
            imported_video_preview_active
                ? std::max<std::size_t>(config_.min_frames_to_start_training * 5u, 12u)
                : config_.min_frames_to_start_training;
        snapshot.thermal_level = thermal_predictor_.current_level();
        snapshot.scan_complete = !scanning_active_.load(std::memory_order_relaxed);
        snapshot.has_s6_quality = has_s6_quality_.load(std::memory_order_relaxed);

        {
            std::lock_guard<std::mutex> tlock3(training_mutex_);
            snapshot.assigned_blocks = assigned_blocks_.size();
            snapshot.pending_gaussian_count = pending_gaussians_.size();
        }

        // Default to staged core progress so UI is never stuck at 0%
        // during pre-training setup (frame/keyframe/seed accumulation).
        auto staged_progress = training_progress();
        snapshot.num_gaussians = staged_progress.num_gaussians;
        snapshot.training_step = staged_progress.step;
        snapshot.training_loss = staged_progress.loss;
        const float staged_total = static_cast<float>(staged_progress.total_steps);
        const float staged_progress_ratio =
            staged_total > 0.0f ? static_cast<float>(staged_progress.step) / staged_total : 0.0f;
        snapshot.training_progress = staged_progress_ratio;
        snapshot.training_active =
            !staged_progress.is_complete &&
            (snapshot.scan_complete ||
             snapshot.selected_frames > 0 ||
             snapshot.pending_gaussian_count > 0 ||
             snapshot.assigned_blocks > 0);

        float effective_coverage = accumulated_coverage_;
        if (config_.local_preview_mode) {
            const bool has_preview_evidence =
                snapshot.frame_count > 0 ||
                snapshot.selected_frames > 0 ||
                snapshot.pending_gaussian_count > 0 ||
                snapshot.num_gaussians > 0 ||
                snapshot.training_step > 0;
            if (has_preview_evidence) {
                effective_coverage = std::max(
                    effective_coverage,
                    std::min(0.98f, staged_progress_ratio));
            }
            const auto preview_depth_ready =
                preview_depth_results_ready_.load(std::memory_order_relaxed);
            const auto preview_frames_ingested =
                preview_frames_ingested_.load(std::memory_order_relaxed);
            const float ingest_hint = preview_frames_ingested > 0
                ? std::min(
                      0.24f,
                      0.03f + 0.01f * static_cast<float>(
                          std::min<std::uint32_t>(preview_frames_ingested, 21u)))
                : 0.0f;
            const float frame_hint = snapshot.frame_count > 0
                ? std::min(
                      0.20f,
                      0.02f + 0.006f * static_cast<float>(
                          std::min<std::size_t>(snapshot.frame_count, 30u)))
                : 0.0f;
            const float depth_hint = preview_depth_ready > 0
                ? std::min(
                      0.30f,
                      0.06f + 0.06f * static_cast<float>(preview_depth_ready))
                : 0.0f;
            const float selected_hint = snapshot.selected_frames > 0
                ? std::min(
                      0.45f,
                      0.10f + 0.03f * static_cast<float>(snapshot.selected_frames))
                : 0.0f;
            const float gaussian_hint =
                (snapshot.pending_gaussian_count > 0 || snapshot.num_gaussians > 0)
                ? 0.36f
                : 0.0f;
            effective_coverage = std::max(
                effective_coverage,
                std::max(
                    std::max(frame_hint, ingest_hint),
                    std::max(depth_hint, std::max(selected_hint, gaussian_hint))));
        }
        snapshot.coverage = effective_coverage;

        const auto preview_seed_accepted =
            preview_seed_accepted_.load(std::memory_order_relaxed);
        snapshot.preview_elapsed_ms = config_.local_preview_mode
            ? static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - preview_started_at_).count())
            : 0;
        snapshot.preview_phase_depth_ms =
            preview_depth_phase_ms_.load(std::memory_order_relaxed);
        snapshot.preview_phase_seed_ms =
            preview_seed_phase_ms_.load(std::memory_order_relaxed);
        snapshot.preview_phase_refine_ms =
            preview_refine_phase_ms_.load(std::memory_order_relaxed);
        snapshot.preview_depth_batches_submitted =
            preview_depth_batches_submitted_.load(std::memory_order_relaxed);
        snapshot.preview_depth_results_ready =
            preview_depth_results_ready_.load(std::memory_order_relaxed);
        snapshot.preview_depth_reuse_frames =
            preview_depth_reuse_frames_.load(std::memory_order_relaxed);
        snapshot.preview_prefilter_accepts =
            preview_prefilter_accepts_.load(std::memory_order_relaxed);
        snapshot.preview_prefilter_brightness_rejects =
            preview_prefilter_brightness_rejects_.load(std::memory_order_relaxed);
        snapshot.preview_prefilter_blur_rejects =
            preview_prefilter_blur_rejects_.load(std::memory_order_relaxed);
        snapshot.preview_keyframe_gate_accepts =
            preview_keyframe_gate_accepts_.load(std::memory_order_relaxed);
        snapshot.preview_keyframe_gate_rejects =
            preview_keyframe_gate_rejects_.load(std::memory_order_relaxed);
        snapshot.preview_seed_candidates =
            preview_seed_candidates_.load(std::memory_order_relaxed);
        snapshot.preview_seed_accepted = preview_seed_accepted;
        snapshot.preview_seed_rejected =
            preview_seed_rejected_.load(std::memory_order_relaxed);
        snapshot.preview_seed_quality_mean = preview_seed_accepted > 0
            ? static_cast<float>(
                  static_cast<double>(preview_seed_quality_milli_sum_.load(std::memory_order_relaxed)) /
                  static_cast<double>(preview_seed_accepted) / 1000.0)
            : 0.0f;
        snapshot.preview_frames_enqueued =
            preview_frames_enqueued_.load(std::memory_order_relaxed);
        snapshot.preview_frames_ingested =
            preview_frames_ingested_.load(std::memory_order_relaxed);
        snapshot.preview_frame_backlog =
            static_cast<std::uint32_t>(frame_queue_.size_approx());

        // Guard: training_engine_ is a raw pointer written by Thread C.
        // training_started_ (atomic, release by Thread C after creating engine)
        // provides the happens-before guarantee for the pointer read.
        if (training_started_.load(std::memory_order_acquire)) {
            const bool converged = training_converged_.load(std::memory_order_acquire);
            std::lock_guard<std::mutex> tlock(training_export_mutex_);
            if (training_engine_) {
                auto progress = apply_training_budget(
                    training_engine_->progress(),
                    training_target_steps_.load(std::memory_order_relaxed),
                    training_hard_cap_steps_.load(std::memory_order_relaxed));
                if (converged) {
                    progress.is_complete = true;
                }
                snapshot.training_active = !progress.is_complete;
                snapshot.num_gaussians = progress.num_gaussians;
                const float total = static_cast<float>(progress.total_steps);
                snapshot.training_progress = converged ? 1.0f :
                    (total > 0.0f ? static_cast<float>(progress.step) / total : 0.0f);
                snapshot.training_loss = progress.loss;
                snapshot.training_step = progress.step;
            }
        }

        evidence_snapshot_.publish();
    };

    while (running_.load(std::memory_order_relaxed)) {
        if (!evidence_queue_.try_pop(obs)) {
            const auto now = std::chrono::steady_clock::now();
            if (now - last_idle_snapshot_publish >= std::chrono::milliseconds(25)) {
                publish_snapshot();
                last_idle_snapshot_publish = now;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        evidence_frame_count_++;

        // ─── Quality accumulation ───
        // Weighted quality based on blur, brightness, and depth confidence
        float quality = obs.blur_score * obs.depth_confidence;
        if (obs.brightness < config_.low_light_brightness_threshold) {
            quality *= 0.7f;  // Penalize low-light frames in quality score
        }
        accumulated_quality_ = accumulated_quality_ * 0.95f + quality * 0.05f;

        // ─── Coverage estimation (simplified spatial hashing) ───
        // Extract camera position from transform
        float cam_x = obs.transform[12];
        float cam_y = obs.transform[13];
        float cam_z = obs.transform[14];

        // Simple coverage: unique spatial cells visited
        // (Full evidence grid integration happens later)
        if (obs.frame_selected) {
            // Each selected frame with good depth adds ~2% coverage.
            accumulated_coverage_ = std::min(1.0f, accumulated_coverage_ + 0.02f);
        } else if (config_.local_preview_mode &&
                   std::isfinite(obs.depth_mean) &&
                   obs.depth_mean > 0.1f &&
                   obs.blur_score >= config_.frame_selection.min_blur_score * 0.75f) {
            // Local-preview capture should not appear frozen at 0% while native
            // depth and pose evidence is already accumulating but the strict
            // keyframe gate has not admitted a frame yet.
            accumulated_coverage_ = std::min(1.0f, accumulated_coverage_ + 0.004f);
        } else if (config_.local_preview_mode &&
                   std::isfinite(obs.blur_score) &&
                   obs.blur_score > 0.03f) {
            // Real-camera local_preview should still show scan momentum as soon
            // as frames are being ingested, even before the first good depth
            // prior or admitted keyframe lands.
            accumulated_coverage_ = std::min(1.0f, accumulated_coverage_ + 0.0015f);
        }

        // ─── Low-light quality tracking ───
        if (obs.brightness < config_.low_light_brightness_threshold &&
            obs.blur_score < config_.frame_selection.min_blur_score) {
            consecutive_low_quality_++;
        } else {
            consecutive_low_quality_ = 0;
        }

        publish_snapshot();
        last_idle_snapshot_publish = std::chrono::steady_clock::now();
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Thread C: Global Training (单全局引擎)
// ═══════════════════════════════════════════════════════════════════════
// Architecture: one global engine, TSDF S6+ blocks → Gaussians via
// add_gaussians(), continuous train_step() with MCMC/SteepGS/Student-t.
// No per-region serialization — all Gaussians trained simultaneously.

void PipelineCoordinator::training_thread_func() noexcept {
    std::vector<SelectedFrame> all_frames;
    SelectedFrame sf;

    // ── Memory cap: prevent OOM (pre-scaled frames ~0.5MB each) ──
    const std::size_t max_training_frames = config_.local_preview_mode
        ? kPreviewMaxTrainingFrames
        : std::size_t(30);

    std::size_t last_reported_frame_count = 0;
    bool engine_created = false;
    std::vector<splat::GaussianParams> pending_gaussians;
    std::uint32_t last_fed_frame_index = 0;
    bool has_last_fed_frame = false;

    // ── Convergence detection (Lyapunov-inspired from CoverageEstimator) ──
    // SmartAntiBoostSmoother: filters loss spikes from new Gaussian additions,
    // preventing premature convergence resets. When add_gaussians() causes a
    // loss spike, the smoother detects it as "anti-boost" (not real degradation)
    // and returns a smoothed value that doesn't reset the converge counter.
    evidence::SmartSmootherConfig smoother_config;
    smoother_config.window_size = 10;         // 10-step median window
    smoother_config.jitter_band = 0.002;      // Loss jitter tolerance
    smoother_config.anti_boost_factor = 0.2;  // Dampen suspicious improvements
    smoother_config.normal_improve_factor = 0.8;
    smoother_config.degrade_factor = 0.5;     // Partially absorb degradation (new Gaussians)
    smoother_config.capture_mode = false;     // Don't enforce monotonic (loss can go up)
    evidence::SmartAntiBoostSmoother loss_smoother(smoother_config);

    float prev_smoothed_loss = 1e9f;
    std::size_t converge_count = 0;
    constexpr std::size_t kConvergeWindow = 400;      // Steps of stable loss → converged (increased from 200)
    constexpr float kConvergeDelta = 0.001f;           // Loss change threshold (on smoothed loss)
    constexpr std::size_t kMinPostScanSteps = 500;     // Minimum refinement before convergence allowed
    bool scan_done_refinement = false;                 // True after finish_scanning() + refinement
    std::size_t post_scan_steps = 0;
    constexpr std::size_t kMaxPostScanSteps = 3000;    // Safety cap (increased from 2000)
    std::size_t last_published_splat_count = 0;
    std::size_t last_published_step = 0;
    bool published_initial_splats = false;
    bool foreground_pause_logged = false;

    auto add_frame_to_engine = [this](const SelectedFrame& f) {
        const bool preview_metric_depth =
            config_.local_preview_mode &&
            f.ne_depth_is_metric &&
            !f.ne_depth.empty() &&
            f.ne_depth_w > 0 &&
            f.ne_depth_h > 0;
        const bool has_lidar_depth =
            !f.lidar_depth.empty() &&
            f.lidar_w > 0 &&
            f.lidar_h > 0;
        const float* relative_ref_depth =
            (!preview_metric_depth && !f.ne_depth.empty())
                ? f.ne_depth.data()
                : nullptr;
        const std::uint32_t relative_ref_depth_w =
            (!preview_metric_depth && !f.ne_depth.empty()) ? f.ne_depth_w : 0u;
        const std::uint32_t relative_ref_depth_h =
            (!preview_metric_depth && !f.ne_depth.empty()) ? f.ne_depth_h : 0u;
        const float* metric_depth =
            has_lidar_depth
                ? f.lidar_depth.data()
                : (preview_metric_depth ? f.ne_depth.data() : nullptr);
        const std::uint32_t metric_depth_w =
            has_lidar_depth ? f.lidar_w : (preview_metric_depth ? f.ne_depth_w : 0u);
        const std::uint32_t metric_depth_h =
            has_lidar_depth ? f.lidar_h : (preview_metric_depth ? f.ne_depth_h : 0u);
        training_engine_->add_training_frame(
            f.rgba.data(), f.width, f.height,
            f.transform, f.intrinsics,
            f.quality_score, f.timestamp, f.frame_index,
            relative_ref_depth,
            relative_ref_depth_w,
            relative_ref_depth_h,
            metric_depth,
            metric_depth_w,
            metric_depth_h);
    };

    // TSDF fallback seeding for post-scan cold start:
    // if overlay->gaussian admission produced no seeds, bootstrap from TSDF
    // surface points so training can still start and publish progress.
    auto build_tsdf_fallback_gaussians =
        [this, &all_frames](std::vector<splat::GaussianParams>& out,
                            std::size_t max_points) -> std::size_t {
            if (!tsdf_volume_) return 0;

            std::vector<tsdf::SurfacePoint> surface_points;
            tsdf_volume_->extract_surface_points(surface_points, max_points);
            if (surface_points.empty()) return 0;

            const std::size_t before = out.size();
            out.reserve(before + surface_points.size());

            for (const auto& sp : surface_points) {
                splat::GaussianParams g{};
                g.position[0] = sp.position[0];
                g.position[1] = sp.position[1];
                g.position[2] = sp.position[2];

                float sampled_rgb[3] = {0.0f, 0.0f, 0.0f};
                bool color_ok = false;
                for (auto it = all_frames.rbegin();
                     it != all_frames.rend() && !color_ok; ++it) {
                    color_ok = sample_selected_frame_color_linear(
                        *it, g.position[0], g.position[1], g.position[2], sampled_rgb);
                }
                if (color_ok) {
                    g.color[0] = sampled_rgb[0];
                    g.color[1] = sampled_rgb[1];
                    g.color[2] = sampled_rgb[2];
                } else {
                    const float nx = std::fabs(sp.normal[0]);
                    const float ny = std::fabs(sp.normal[1]);
                    const float nz = std::fabs(sp.normal[2]);
                    g.color[0] = std::clamp(0.18f + 0.55f * nx, 0.0f, 1.0f);
                    g.color[1] = std::clamp(0.16f + 0.58f * ny, 0.0f, 1.0f);
                    g.color[2] = std::clamp(0.18f + 0.55f * nz, 0.0f, 1.0f);
                }

                const float weight_norm = std::clamp(
                    static_cast<float>(sp.weight) / 24.0f, 0.0f, 1.0f);
                g.opacity = 0.20f + 0.70f * weight_norm;
                const float scale = std::clamp(
                    0.004f + (1.0f - weight_norm) * 0.004f, 0.003f, 0.012f);
                g.scale[0] = scale;
                g.scale[1] = scale;
                g.scale[2] = scale;
                g.rotation[0] = 1.0f;
                g.rotation[1] = 0.0f;
                g.rotation[2] = 0.0f;
                g.rotation[3] = 0.0f;
                out.push_back(g);
            }

            return out.size() - before;
        };

    while (running_.load(std::memory_order_relaxed)) {
        // ── Step 1: Collect frames + pending Gaussians from Thread A ──
        while (selected_queue_.try_pop(sf)) {
            all_frames.push_back(std::move(sf));
            if (all_frames.size() > max_training_frames) {
                all_frames.erase(all_frames.begin());
            }
        }

        // Diagnostic
        if (all_frames.size() != last_reported_frame_count) {
            last_reported_frame_count = all_frames.size();
            std::fprintf(stderr,
                "[Aether3D][TrainThread] frames=%zu  S6+=%s  engine=%s\n",
                all_frames.size(),
                has_s6_quality_.load(std::memory_order_relaxed) ? "YES" : "no",
                engine_created ? "YES" : "no");
        }

        // ── Step 2: Wait until we have frames ──
        if (all_frames.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        // ── Step 3: Collect pending Gaussians from Thread A ──
        // Thread A populates pending_gaussians_ under training_mutex_ when
        // TSDF S6+ blocks are detected in generate_overlay_vertices().
        {
            std::lock_guard<std::mutex> lock(training_mutex_);
            if (!pending_gaussians_.empty()) {
                pending_gaussians.insert(pending_gaussians.end(),
                    pending_gaussians_.begin(), pending_gaussians_.end());
                pending_gaussians_.clear();
            }
        }

        if (!engine_created &&
            pending_gaussians.empty() &&
            config_.local_preview_mode &&
            !preview_dav2_seed_initialized_ &&
            !all_frames.empty()) {
            const bool has_any_imported_video_frames =
                std::any_of(
                    all_frames.begin(),
                    all_frames.end(),
                    [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
            const bool seed_imported_video_preview_only =
                has_any_imported_video_frames &&
                std::all_of(
                    all_frames.begin(),
                    all_frames.end(),
                    [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
            const std::uint32_t imported_video_min_seed_frames =
                static_cast<std::uint32_t>(std::max<std::size_t>(
                    config_.min_frames_to_start_training * 5u,
                    12u));
            const std::size_t preview_initial_seed_cap =
                seed_imported_video_preview_only
                    ? kPreviewImportedVideoInitialSeedCap
                    : kPreviewInitialSeedCap;
            const std::size_t imported_video_min_seed_gaussians =
                std::min<std::size_t>(preview_initial_seed_cap, 12000u);
            std::vector<const SelectedFrame*> depth_frames;
            depth_frames.reserve(all_frames.size());
            for (const auto& frame : all_frames) {
                if (!frame.imported_video) {
                    continue;
                }
                if (frame.ne_depth.empty() || frame.ne_depth_w == 0 || frame.ne_depth_h == 0) {
                    continue;
                }
                depth_frames.push_back(&frame);
            }

            const bool seed_attempt_already_ran =
                seed_imported_video_preview_only &&
                preview_last_seed_attempt_depth_frames_ == depth_frames.size() &&
                preview_last_seed_attempt_depth_frames_ > 0;
            const bool seed_ready_to_initialize =
                !has_any_imported_video_frames ||
                depth_frames.size() >= imported_video_min_seed_frames;

            if (has_any_imported_video_frames &&
                !seed_ready_to_initialize &&
                !depth_frames.empty()) {
                static std::uint32_t preview_seed_wait_log_count = 0;
                preview_seed_wait_log_count++;
                if (preview_seed_wait_log_count <= 8 ||
                    preview_seed_wait_log_count % 20 == 0) {
                    std::fprintf(
                        stderr,
                        "[Aether3D][TrainThread] Repo MVS seed waiting: %zu/%u imported depth frames ready\n",
                        depth_frames.size(),
                        imported_video_min_seed_frames);
                }
            } else if (!depth_frames.empty() && !seed_attempt_already_ran) {
                preview_last_seed_attempt_depth_frames_ = depth_frames.size();
                const auto preview_seed_phase_t0 = std::chrono::steady_clock::now();
                std::vector<training::MVSFrame> mvs_frames;
                mvs_frames.reserve(depth_frames.size());
                std::size_t imported_video_metric_depth_frames = 0;
                for (const auto* frame_ptr : depth_frames) {
                    if (!frame_ptr) {
                        continue;
                    }
                    training::MVSFrame mf{};
                    mf.rgba = frame_ptr->rgba.data();
                    mf.width = frame_ptr->width;
                    mf.height = frame_ptr->height;
                    std::memcpy(mf.transform, frame_ptr->transform, sizeof(mf.transform));
                    mf.intrinsics[0] = frame_ptr->intrinsics[0];
                    mf.intrinsics[1] = frame_ptr->intrinsics[1];
                    mf.intrinsics[2] = frame_ptr->intrinsics[2];
                    mf.intrinsics[3] = frame_ptr->intrinsics[3];
                    if (!frame_ptr->ne_depth.empty() &&
                        frame_ptr->ne_depth_w > 0 &&
                        frame_ptr->ne_depth_h > 0) {
                        if (seed_imported_video_preview_only) {
                            if (frame_ptr->ne_depth_is_metric) {
                                imported_video_metric_depth_frames++;
                            }
                        } else {
                            mf.dav2_depth = frame_ptr->ne_depth.data();
                            mf.dav2_w = frame_ptr->ne_depth_w;
                            mf.dav2_h = frame_ptr->ne_depth_h;
                            mf.dav2_is_metric = frame_ptr->ne_depth_is_metric;
                            if (!mf.dav2_is_metric) {
                                mf.dav2_scale = dav2_affine_scale_;
                                mf.dav2_shift = dav2_affine_shift_;
                            }
                        }
                    }
                    mvs_frames.push_back(mf);
                }

                std::vector<splat::GaussianParams> imported_video_seeds;
                core::Status primary_seed_status = core::Status::kInvalidArgument;
                if (mvs_frames.size() >= 3) {
                    training::MVSConfig mvs_cfg;
                    mvs_cfg.depth_width = std::max<std::uint32_t>(
                        static_cast<std::uint32_t>(160),
                        static_cast<std::uint32_t>(
                            std::max<std::size_t>(config_.training.render_width, 320u) / 2u));
                    mvs_cfg.depth_height = std::max<std::uint32_t>(
                        static_cast<std::uint32_t>(120),
                        static_cast<std::uint32_t>(
                            std::max<std::size_t>(config_.training.render_height, 240u) / 2u));
                    if (seed_imported_video_preview_only) {
                        mvs_cfg.dav2_prior_range = kPreviewImportedVideoMvsPrimaryPriorRange;
                        mvs_cfg.dav2_prior_levels = kPreviewImportedVideoMvsPrimaryPriorLevels;
                        std::fprintf(
                            stderr,
                            "[Aether3D][TrainThread] Repo MVS primary: imported-video DAv2 prior disabled "
                            "(metric_depth_frames=%zu/%zu)\n",
                            imported_video_metric_depth_frames,
                            mvs_frames.size());
                    }
                    primary_seed_status = training::mvs_initialize(
                        mvs_frames.data(),
                        mvs_frames.size(),
                        mvs_cfg,
                        imported_video_seeds);
                    if (primary_seed_status == core::Status::kOk && !imported_video_seeds.empty()) {
                        if (imported_video_seeds.size() > preview_initial_seed_cap) {
                            imported_video_seeds.resize(preview_initial_seed_cap);
                        }
                        std::fprintf(stderr,
                            "[Aether3D][TrainThread] Repo MVS seed bootstrap: +%zu gaussians "
                            "from %zu imported frames\n",
                            imported_video_seeds.size(), mvs_frames.size());
                    }
                }

                const std::size_t mvs_seed_fallback_threshold =
                    std::min<std::size_t>(preview_initial_seed_cap, 12000u);
                if (imported_video_seeds.size() < mvs_seed_fallback_threshold) {
                    training::DAv2Config dav2_cfg;
                    dav2_cfg.subsample_step = 2;
                    const bool have_primary_mvs_seed =
                        primary_seed_status == core::Status::kOk &&
                        !imported_video_seeds.empty();
                    const std::size_t remaining_seed_budget =
                        imported_video_seeds.size() >= preview_initial_seed_cap
                            ? 0u
                            : (preview_initial_seed_cap - imported_video_seeds.size());
                    const std::size_t dav2_supplement_cap =
                        have_primary_mvs_seed
                            ? std::min<std::size_t>(
                                  std::max<std::size_t>(
                                      imported_video_seeds.size() / 3u,
                                      512u),
                                  2048u)
                            : remaining_seed_budget;
                    dav2_cfg.max_points = static_cast<std::uint32_t>(
                        std::min<std::size_t>(
                            remaining_seed_budget,
                            dav2_supplement_cap));
                    if (dav2_cfg.max_points > 0) {
                        std::vector<splat::GaussianParams> dav2_supplement;
                        const auto dav2_status = training::dav2_initialize(
                            depth_frames.data(),
                            depth_frames.size(),
                            dav2_cfg,
                            dav2_supplement);
                        if (dav2_status == core::Status::kOk && !dav2_supplement.empty()) {
                            if (dav2_supplement.size() > dav2_cfg.max_points) {
                                dav2_supplement.resize(dav2_cfg.max_points);
                            }
                            imported_video_seeds.insert(
                                imported_video_seeds.end(),
                                dav2_supplement.begin(),
                                dav2_supplement.end());
                            std::fprintf(stderr,
                                imported_video_seeds.size() == dav2_supplement.size()
                                    ? "[Aether3D][TrainThread] Repo DAv2 fallback seed bootstrap: +%zu gaussians "
                                      "from %zu imported frames\n"
                                    : "[Aether3D][TrainThread] Repo DAv2 supplement: +%zu gaussians "
                                      "after MVS seed bootstrap\n",
                                dav2_supplement.size(),
                                depth_frames.size());
                        } else if (primary_seed_status != core::Status::kOk) {
                            std::fprintf(stderr,
                                "[Aether3D][TrainThread] Repo MVS seed bootstrap failed, DAv2 fallback unavailable "
                                "(status=%d)\n",
                                static_cast<int>(dav2_status));
                        }
                    }
                }
                const auto preview_seed_phase_t1 = std::chrono::steady_clock::now();
                preview_seed_phase_ms_.fetch_add(
                    static_cast<std::uint64_t>(
                        std::chrono::duration_cast<std::chrono::milliseconds>(
                            preview_seed_phase_t1 - preview_seed_phase_t0
                        ).count()),
                    std::memory_order_relaxed);

                if (!imported_video_seeds.empty()) {
                    preview_seed_candidates_.fetch_add(
                        static_cast<std::uint32_t>(imported_video_seeds.size()),
                        std::memory_order_relaxed);
                    if (imported_video_seeds.size() > preview_initial_seed_cap) {
                        imported_video_seeds.resize(preview_initial_seed_cap);
                    }
                    const bool seed_evidence_sufficient =
                        !seed_imported_video_preview_only ||
                        imported_video_seeds.size() >= imported_video_min_seed_gaussians;
                    if (!seed_evidence_sufficient) {
                        preview_seed_rejected_.fetch_add(
                            static_cast<std::uint32_t>(imported_video_seeds.size()),
                            std::memory_order_relaxed);
                        std::fprintf(stderr,
                            "[Aether3D][TrainThread] Repo seed evidence still thin: %zu/%zu gaussians from %zu imported depth frames — waiting for more evidence\n",
                            imported_video_seeds.size(),
                            imported_video_min_seed_gaussians,
                            depth_frames.size());
                    } else {
                        preview_seed_accepted_.fetch_add(
                            static_cast<std::uint32_t>(imported_video_seeds.size()),
                            std::memory_order_relaxed);
                        preview_seed_quality_milli_sum_.fetch_add(
                            static_cast<std::uint64_t>(imported_video_seeds.size()) * 700ULL,
                            std::memory_order_relaxed);
                        pending_gaussians = std::move(imported_video_seeds);
                        preview_dav2_seed_initialized_ = true;
                    }
                }
            }
        }

        // ── Step 3.5: Post-scan fallback seed path ──
        // If TSDF→overlay admission is too strict and produced zero seeds,
        // bootstrap from TSDF surface points so viewer progress can move.
        if (!engine_created && pending_gaussians.empty()) {
            const bool scan_finished =
                !scanning_active_.load(std::memory_order_acquire);
            const bool imported_video_preview_only =
                config_.local_preview_mode &&
                !all_frames.empty() &&
                std::all_of(
                    all_frames.begin(),
                    all_frames.end(),
                    [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
            const std::uint32_t preview_frames_ingested =
                preview_frames_ingested_.load(std::memory_order_relaxed);
            const std::uint32_t preview_depth_results_ready =
                preview_depth_results_ready_.load(std::memory_order_relaxed);
            const std::uint32_t preview_selected_frames =
                selected_frame_count_.load(std::memory_order_relaxed);
            const std::uint64_t preview_elapsed_ms =
                config_.local_preview_mode
                    ? static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - preview_started_at_).count())
                    : 0;
            const std::uint32_t imported_video_min_training_frames =
                static_cast<std::uint32_t>(std::max<std::size_t>(
                    config_.min_frames_to_start_training * 5u,
                    12u));
            const std::uint32_t degraded_min_ingested =
                static_cast<std::uint32_t>(std::max<std::size_t>(
                    config_.min_frames_to_start_training * 6u,
                    16u));
            const std::uint32_t preview_frames_enqueued =
                preview_frames_enqueued_.load(std::memory_order_relaxed);
            const bool imported_video_degraded_seed_ready =
                imported_video_preview_only &&
                scan_finished &&
                features_frozen_.load(std::memory_order_acquire) &&
                tsdf_idle_.load(std::memory_order_acquire) &&
                preview_depth_results_ready >= 3u &&
                preview_frames_enqueued > 0u &&
                preview_frames_ingested >= degraded_min_ingested &&
                preview_frames_ingested >= preview_frames_enqueued &&
                preview_selected_frames >= imported_video_min_training_frames &&
                preview_elapsed_ms >= 6000u &&
                (!all_frames.empty() || preview_depth_results_ready > 0u);
            if (scan_finished &&
                features_frozen_.load(std::memory_order_acquire) &&
                tsdf_idle_.load(std::memory_order_acquire) &&
                (all_frames.size() >= imported_video_min_training_frames ||
                 imported_video_degraded_seed_ready)) {
                const std::size_t seeded =
                    build_tsdf_fallback_gaussians(
                        pending_gaussians,
                        config_.local_preview_mode ? kPreviewFallbackSeedCount : std::size_t(20000));
                if (seeded > 0) {
                    std::fprintf(stderr,
                        imported_video_preview_only
                            ? "[Aether3D][TrainThread] Imported-video degraded TSDF seed fallback: +%zu gaussians\n"
                            : "[Aether3D][TrainThread] Fallback TSDF seed bootstrap: +%zu gaussians\n",
                        seeded);
                }
            }
        }

        // ── Step 4: Create global engine on first Gaussians ──
        // Imported-video local_preview must not start training from a single
        // selected frame. Wait until the repo-native keyframe path has
        // admitted at least min_frames_to_start_training frames; otherwise the
        // preview collapses into a colored billboard/sheet.
        const bool imported_video_preview_only =
            config_.local_preview_mode &&
            !all_frames.empty() &&
            std::all_of(
                all_frames.begin(),
                all_frames.end(),
                [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
        const std::uint32_t preview_frames_ingested =
            preview_frames_ingested_.load(std::memory_order_relaxed);
        const std::uint32_t preview_depth_results_ready =
            preview_depth_results_ready_.load(std::memory_order_relaxed);
        const std::uint32_t preview_selected_frames =
            selected_frame_count_.load(std::memory_order_relaxed);
        const std::uint64_t preview_elapsed_ms =
            config_.local_preview_mode
                ? static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - preview_started_at_).count())
                : 0;
        const std::uint32_t imported_video_min_training_frames =
            static_cast<std::uint32_t>(std::max<std::size_t>(
                config_.min_frames_to_start_training * 5u,
                12u));
        const std::uint32_t degraded_min_ingested =
            static_cast<std::uint32_t>(std::max<std::size_t>(
                config_.min_frames_to_start_training * 6u,
                16u));
        const std::size_t preview_initial_seed_cap =
            imported_video_preview_only
                ? kPreviewImportedVideoInitialSeedCap
                : kPreviewInitialSeedCap;
        const std::size_t imported_video_min_seed_gaussians =
            std::min<std::size_t>(preview_initial_seed_cap, 12000u);
        const bool imported_video_degraded_ready =
            imported_video_preview_only &&
            !scanning_active_.load(std::memory_order_acquire) &&
            features_frozen_.load(std::memory_order_acquire) &&
            tsdf_idle_.load(std::memory_order_acquire) &&
            preview_depth_results_ready >= 3u &&
            preview_frames_ingested >= degraded_min_ingested &&
            preview_selected_frames >= imported_video_min_training_frames &&
            preview_elapsed_ms >= 6000u &&
            !all_frames.empty();
        const bool imported_video_primary_ready =
            all_frames.size() >= imported_video_min_training_frames &&
            preview_selected_frames >= imported_video_min_training_frames &&
            pending_gaussians.size() >= imported_video_min_seed_gaussians;
        const bool ready_to_create_engine =
            !pending_gaussians.empty() &&
            (!imported_video_preview_only ||
             imported_video_primary_ready ||
             imported_video_degraded_ready);
        if (!engine_created && ready_to_create_engine) {
            try {
                std::lock_guard<std::mutex> lock(training_export_mutex_);
                if (config_.local_preview_mode &&
                    pending_gaussians.size() > preview_initial_seed_cap) {
                    pending_gaussians.resize(preview_initial_seed_cap);
                }

                const std::size_t base_steps = config_.local_preview_mode
                    ? std::max<std::size_t>(config_.training.max_iterations, kPreviewTrainingTargetSteps)
                    : std::max<std::size_t>(config_.training.max_iterations, kDefaultTrainingTargetSteps);
                const std::size_t hard_cap_steps = compute_hard_cap_steps_for_mode(
                    config_.local_preview_mode,
                    training_hard_cap_steps_.load(std::memory_order_relaxed),
                    base_steps);
                training_hard_cap_steps_.store(hard_cap_steps, std::memory_order_relaxed);
                const std::size_t dynamic_target_steps = compute_target_steps_for_mode(
                    config_.local_preview_mode,
                    pending_gaussians.size(),
                    all_frames.size(),
                    base_steps,
                    hard_cap_steps);
                training_target_steps_.store(dynamic_target_steps, std::memory_order_relaxed);

                auto runtime_training_config = config_.training;
                runtime_training_config.max_iterations = dynamic_target_steps;
                runtime_training_config.align_to_baseline_3dgs =
                    config_.local_preview_mode;
                training_engine_ = new training::GaussianTrainingEngine(
                    device_, runtime_training_config);

                auto status = training_engine_->set_initial_point_cloud(
                    pending_gaussians.data(), pending_gaussians.size());
                if (status != core::Status::kOk) {
                    std::fprintf(stderr,
                        "[Aether3D][TrainThread] set_initial_point_cloud FAILED\n");
                    delete training_engine_;
                    training_engine_ = nullptr;
                    pending_gaussians.clear();
                    continue;
                }

                // Seed engine with all currently selected frames.
                std::size_t seeded_frames = 0;
                std::uint32_t newest_seeded_index = 0;
                for (const auto& f : all_frames) {
                    add_frame_to_engine(f);
                    seeded_frames++;
                    if (!has_last_fed_frame || f.frame_index > newest_seeded_index) {
                        newest_seeded_index = f.frame_index;
                    }
                }
                if (seeded_frames > 0) {
                    has_last_fed_frame = true;
                    last_fed_frame_index = newest_seeded_index;
                }

                training_started_.store(true, std::memory_order_release);
                engine_created = true;
                pending_gaussians.clear();

                std::fprintf(stderr,
                    "[Aether3D][TrainThread] Global engine created: %zu Gaussians, "
                    "%zu frames, target_steps=%zu mode=%s\n",
                    training_engine_->gaussian_count(),
                    training_engine_->frame_count(),
                    training_target_steps_.load(std::memory_order_relaxed),
                    config_.local_preview_mode ? "local_preview" : "cloud_default");

                if (renderer_alive_.load(std::memory_order_acquire)) {
                    std::vector<splat::GaussianParams> initial_splats;
                    training_engine_->export_gaussians(initial_splats);
                    if (!initial_splats.empty()) {
                        renderer_.clear_splats();
                        renderer_.push_splats(initial_splats.data(), initial_splats.size());
                        published_initial_splats = true;
                        last_published_splat_count = initial_splats.size();
                        last_published_step = 0;
                        std::fprintf(stderr,
                            "[Aether3D][TrainThread] Initial splats published: %zu\n",
                            initial_splats.size());
                    }
                }
            } catch (const std::exception& e) {
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] Engine creation EXCEPTION: %s\n", e.what());
                pending_gaussians.clear();
            } catch (...) {
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] Engine creation UNKNOWN EXCEPTION\n");
                pending_gaussians.clear();
            }
            continue;
        }

        // ── Step 5: Feed incremental frames + append new Gaussians ──
        if (engine_created) {
            std::size_t newly_added_frames = 0;
            std::uint32_t newest_added_frame = last_fed_frame_index;
            const std::size_t new_gaussian_count = pending_gaussians.size();
            std::size_t dynamic_target_steps = 0;
            std::size_t total_gaussians = 0;

            std::lock_guard<std::mutex> lock(training_export_mutex_);
            if (training_engine_) {
                // Continuously wire newly selected frames into the trainer.
                for (const auto& f : all_frames) {
                    if (has_last_fed_frame && f.frame_index <= last_fed_frame_index) {
                        continue;
                    }
                    add_frame_to_engine(f);
                    newly_added_frames++;
                    if (!has_last_fed_frame || f.frame_index > newest_added_frame) {
                        newest_added_frame = f.frame_index;
                    }
                }

                if (new_gaussian_count > 0) {
                    training_engine_->add_gaussians(
                        pending_gaussians.data(), pending_gaussians.size());
                }

                const std::size_t base_steps = config_.local_preview_mode
                    ? std::max<std::size_t>(config_.training.max_iterations, kPreviewTrainingTargetSteps)
                    : std::max<std::size_t>(config_.training.max_iterations, kDefaultTrainingTargetSteps);
                const std::size_t hard_cap_steps = compute_hard_cap_steps_for_mode(
                    config_.local_preview_mode,
                    training_hard_cap_steps_.load(std::memory_order_relaxed),
                    base_steps);
                training_hard_cap_steps_.store(hard_cap_steps, std::memory_order_relaxed);
                dynamic_target_steps = compute_target_steps_for_mode(
                    config_.local_preview_mode,
                    training_engine_->gaussian_count(),
                    training_engine_->frame_count(),
                    base_steps,
                    hard_cap_steps);
                total_gaussians = training_engine_->gaussian_count();
            }

            if (newly_added_frames > 0) {
                has_last_fed_frame = true;
                last_fed_frame_index = newest_added_frame;
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] +%zu training frames (total=%zu)\n",
                    newly_added_frames, all_frames.size());
            }
            if (dynamic_target_steps > 0) {
                const std::size_t prev_target =
                    training_target_steps_.load(std::memory_order_relaxed);
                if (dynamic_target_steps > prev_target) {
                    training_target_steps_.store(dynamic_target_steps, std::memory_order_relaxed);
                    std::fprintf(stderr,
                        "[Aether3D][TrainThread] training target expanded: %zu -> %zu "
                        "(gaussians=%zu, +new=%zu)\n",
                        prev_target, dynamic_target_steps,
                        total_gaussians, new_gaussian_count);
                }
            }

            pending_gaussians.clear();
        }

        // ── Step 6: Train steps (BATCHED — multiple steps per iteration) ──
        // Previous design: 1 step per while-loop → ~7.7s per step due to
        // frame collection + mutex overhead between steps.
        // Fix: batch up to kTrainBatchSize steps with a single lock acquisition,
        // then release lock for splat export + frame polling.
        //
        // Timing budget: 200ms per batch → ~50ms GPU step = 4 steps/batch.
        // This keeps training responsive to new frames while maximizing throughput.
        constexpr std::size_t kTrainBatchSize = 8;    // Max steps per batch
        constexpr int kBatchTimeBudgetMs = 200;       // Max time per batch
        if (engine_created && training_engine_ && !scan_done_refinement) {
            if (config_.local_preview_mode &&
                !foreground_active_.load(std::memory_order_acquire)) {
                if (!foreground_pause_logged) {
                    std::fprintf(stderr,
                        "[Aether3D][TrainThread] local_preview paused: app inactive, holding GPU refine until foreground resumes\n");
                    foreground_pause_logged = true;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }
            if (foreground_pause_logged) {
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] local_preview resumed: foreground active, continuing refine\n");
                foreground_pause_logged = false;
            }
            try {
                const auto preview_refine_phase_t0 = config_.local_preview_mode
                    ? std::chrono::steady_clock::now()
                    : std::chrono::steady_clock::time_point{};
                core::Status status = core::Status::kOk;
                auto batch_t0 = std::chrono::steady_clock::now();
                std::size_t steps_in_batch = 0;

                for (std::size_t b = 0; b < kTrainBatchSize; ++b) {
                    auto step_t0 = std::chrono::steady_clock::now();
                    {
                        std::lock_guard<std::mutex> lock(training_export_mutex_);
                        status = training_engine_->train_step();
                    }
                    auto step_t1 = std::chrono::steady_clock::now();
                    steps_in_batch++;

                    if (status != core::Status::kOk) break;

                    // Check time budget — don't starve frame collection
                    auto batch_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                        step_t1 - batch_t0).count();
                    if (batch_elapsed >= kBatchTimeBudgetMs) break;
                }

                if (status == core::Status::kOk) {
                    auto progress = training_engine_->progress();
                    auto batch_t1 = std::chrono::steady_clock::now();

                    // ── Per-batch timing diagnostics ──
                    // First 10 steps: every step. Then every 20 steps.
                    if (progress.step < 10 || progress.step % 20 == 0) {
                        auto batch_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            batch_t1 - batch_t0).count();
                        std::fprintf(stderr,
                            "[Aether3D][TrainPerf] step=%zu/%zu loss=%.4f "
                            "batch=%zu/%zusteps %lldms gaussians=%zu gpu=%s\n",
                            progress.step, progress.total_steps,
                            progress.loss, steps_in_batch, kTrainBatchSize,
                            batch_ms,
                            training_engine_->gaussian_count(),
                            training_engine_->is_gpu_training() ? "YES" : "CPU");
                    }

                    // ── Publish splats every 50 steps ──
                    // CRITICAL: clear + push = REPLACE (not append).
                    // export_gaussians returns ALL Gaussians, not a delta.
                    const std::size_t gaussians_now = training_engine_->gaussian_count();
                    bool should_publish_splats = false;
                    if (!published_initial_splats) {
                        should_publish_splats = true;  // First visible splat ASAP
                    }
                    if ((progress.step % 50) == 0) {
                        should_publish_splats = true;  // Periodic full refresh
                    }
                    if (gaussians_now >= last_published_splat_count + 128) {
                        should_publish_splats = true;  // New gaussians arrived
                    }
                    if (progress.step >= last_published_step + 12) {
                        should_publish_splats = true;  // Avoid stale viewer snapshots
                    }

                    if (should_publish_splats &&
                        renderer_alive_.load(std::memory_order_acquire)) {
                        std::vector<splat::GaussianParams> splats;
                        {
                            std::lock_guard<std::mutex> lock(training_export_mutex_);
                            training_engine_->export_gaussians(splats);
                        }
                        if (!splats.empty()) {
                            renderer_.clear_splats();
                            renderer_.push_splats(splats.data(), splats.size());
                            published_initial_splats = true;
                            last_published_splat_count = splats.size();
                            last_published_step = progress.step;
                            if (progress.step <= 20 || (progress.step % 50) == 0) {
                                std::fprintf(stderr,
                                    "[Aether3D][TrainThread] Published splats: step=%zu count=%zu\n",
                                    progress.step, splats.size());
                            }
                        }
                    }

                    // ── Convergence detection (Lyapunov-inspired + SmartAntiBoost) ──
                    // SmartAntiBoostSmoother absorbs loss spikes from new Gaussian
                    // additions, preventing spurious convergence counter resets.
                    float smoothed_loss = static_cast<float>(
                        loss_smoother.add(static_cast<double>(progress.loss)));
                    float loss_delta = std::fabs(smoothed_loss - prev_smoothed_loss);
                    if (loss_delta < kConvergeDelta) {
                        converge_count++;
                    } else {
                        converge_count = 0;
                    }
                    prev_smoothed_loss = smoothed_loss;

                    // After scanning finishes, count refinement steps
                    if (!scanning_active_.load(std::memory_order_relaxed) &&
                        features_frozen_.load(std::memory_order_relaxed)) {
                        post_scan_steps++;
                        // Convergence requires BOTH:
                        //   1. Minimum post-scan steps completed (prevents premature exit
                        //      when CPU fallback produces flat loss from the start)
                        //   2. Either stable loss for kConvergeWindow OR safety cap reached
                        if (post_scan_steps >= kMinPostScanSteps &&
                            (converge_count >= kConvergeWindow ||
                             post_scan_steps >= kMaxPostScanSteps) && !scan_done_refinement) {
                            scan_done_refinement = true;
                            training_converged_.store(true, std::memory_order_release);
                            std::fprintf(stderr,
                                "[Aether3D][TrainThread] Converged: step=%zu, loss=%.6f, "
                                "converge_count=%zu, post_scan_steps=%zu\n",
                                progress.step, progress.loss,
                                converge_count, post_scan_steps);

                            // Final push of fully trained splats
                            if (renderer_alive_.load(std::memory_order_acquire)) {
                                std::vector<splat::GaussianParams> final_splats;
                                {
                                    std::lock_guard<std::mutex> lock(training_export_mutex_);
                                    training_engine_->export_gaussians(final_splats);
                                }
                                if (!final_splats.empty()) {
                                    renderer_.clear_splats();
                                    renderer_.push_splats(final_splats.data(), final_splats.size());
                                    std::fprintf(stderr,
                                        "[Aether3D][TrainThread] Final splats pushed: %zu\n",
                                        final_splats.size());
                                }
                            }
                        }
                    }
                } else {
                    // Non-OK status: log it (GPU failure, recovery, etc.)
                    auto err_t1 = std::chrono::steady_clock::now();
                    auto err_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        err_t1 - batch_t0).count();
                    std::fprintf(stderr,
                        "[Aether3D][TrainPerf] non-OK status=%d batch_ms=%lld\n",
                        static_cast<int>(status), err_ms);
                }
                if (config_.local_preview_mode) {
                    const auto preview_refine_phase_t1 = std::chrono::steady_clock::now();
                    const auto preview_refine_elapsed_ms = static_cast<std::uint64_t>(
                        std::chrono::duration_cast<std::chrono::milliseconds>(
                            preview_refine_phase_t1 - preview_refine_phase_t0
                        ).count()
                    );
                    preview_refine_phase_ms_.fetch_add(
                        preview_refine_elapsed_ms,
                        std::memory_order_relaxed
                    );
                }
            } catch (const std::exception& e) {
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] train_step EXCEPTION: %s\n", e.what());
            } catch (...) {
                std::fprintf(stderr,
                    "[Aether3D][TrainThread] train_step UNKNOWN EXCEPTION\n");
            }

            // ── Handle enhance requests ──
            std::size_t extra = enhance_iters_.exchange(0, std::memory_order_relaxed);
            if (extra > 0 && training_engine_) {
                for (std::size_t i = 0; i < extra && running_.load(std::memory_order_relaxed); ++i) {
                    std::lock_guard<std::mutex> lock(training_export_mutex_);
                    training_engine_->train_step();
                }
            }

            // No yield() — let the thread run at full speed.
        } else if (scan_done_refinement) {
            // Training converged — sleep to avoid spinning the CPU/GPU
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        } else {
            // No engine yet — wait for Gaussians
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }

    // ── Cleanup: keep engine alive for export, set training_started_ false ──
    training_started_.store(false, std::memory_order_release);
}

// ═══════════════════════════════════════════════════════════════════════
// Frame Processing Helpers
// ═══════════════════════════════════════════════════════════════════════

float PipelineCoordinator::compute_brightness(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept {
    if (!rgba || w == 0 || h == 0) return 128.0f;

    // Sample every 16th pixel for speed (~0.05ms for 1920x1080)
    const std::size_t total = static_cast<std::size_t>(w) * h;
    const std::size_t step = 16;
    double sum = 0.0;
    std::size_t count = 0;

    for (std::size_t i = 0; i < total; i += step) {
        const std::uint8_t* p = rgba + i * 4;
        // Luminance approximation: 0.299R + 0.587G + 0.114B
        sum += 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
        count++;
    }

    return count > 0 ? static_cast<float>(sum / count) : 128.0f;
}

float PipelineCoordinator::compute_blur_score(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept {
    if (!rgba || w < 4 || h < 4) return 0.0f;

    // Tenengrad variance (gradient magnitude via Sobel, noise-robust)
    // Sample grayscale from green channel (highest SNR in Bayer pattern)
    const std::size_t stride = w * 4;
    double gradient_sum = 0.0;
    std::size_t count = 0;

    // Sample every 4th pixel for speed
    for (std::uint32_t y = 1; y < h - 1; y += 4) {
        for (std::uint32_t x = 1; x < w - 1; x += 4) {
            // Sobel Gx, Gy on green channel (index 1)
            auto g = [&](std::uint32_t px, std::uint32_t py) -> float {
                return static_cast<float>(rgba[py * stride + px * 4 + 1]);
            };

            float gx = -g(x-1, y-1) + g(x+1, y-1)
                        - 2*g(x-1, y) + 2*g(x+1, y)
                        - g(x-1, y+1) + g(x+1, y+1);

            float gy = -g(x-1, y-1) - 2*g(x, y-1) - g(x+1, y-1)
                        + g(x-1, y+1) + 2*g(x, y+1) + g(x+1, y+1);

            gradient_sum += gx * gx + gy * gy;
            count++;
        }
    }

    if (count == 0) return 0.0f;

    // Normalize to [0, 1] range
    // Typical sharp image: ~2000-5000, blurry: <500
    double avg_gradient = gradient_sum / count;
    return std::clamp(static_cast<float>(avg_gradient / 5000.0), 0.0f, 1.0f);
}

// ═══════════════════════════════════════════════════════════════════════
// DAv2 Dual-Model Cross-Validation with Affine Alignment
// ═══════════════════════════════════════════════════════════════════════
// Problem: Small and Large DAv2 models output RELATIVE depth with
// different unknown scale and shift. Direct pixel comparison gives ~59%
// false divergence — not because models disagree on structure, but
// because they use different affine scales.
//
// Solution (Ranftl et al. 2022, MiDaS v3.1 alignment):
//   1. Resample Large depth to Small's resolution (bilinear)
//   2. Compute least-squares affine alignment: d_small_aligned = α·d_small + β
//      to minimize ‖α·d_small + β − d_large‖²
//   3. Cross-validate on ALIGNED values (divergence should drop to <5%)
//   4. Consensus: inverse-variance weighted fusion
//   5. Divergent: median of neighbors (structure-preserving fallback)
//
// When only one model is available: pass through its depth.
// When neither is available: returns false → MVS-only path.

bool PipelineCoordinator::cross_validate_depth(
    const DepthInferenceResult& small_result,
    const DepthInferenceResult& large_result,
    bool have_small, bool have_large,
    DepthInferenceResult& consensus_out) noexcept
{
    // ── Single-model passthrough ──
    if (have_small && !have_large) {
        consensus_out = small_result;
        return true;
    }
    if (!have_small && have_large) {
        consensus_out = large_result;
        return true;
    }
    if (!have_small && !have_large) {
        return false;
    }

    // ── Dual-model cross-validation with affine alignment ──
    const std::uint32_t out_w = small_result.width;
    const std::uint32_t out_h = small_result.height;
    if (out_w == 0 || out_h == 0) return false;

    const std::size_t count = static_cast<std::size_t>(out_w) * out_h;
    consensus_out.depth_map.resize(count);
    consensus_out.width = out_w;
    consensus_out.height = out_h;

    const float sx = static_cast<float>(large_result.width) / out_w;
    const float sy = static_cast<float>(large_result.height) / out_h;

    // ── Step 1: Bilinear resample Large → Small resolution ──
    // Also collect paired samples for affine fitting (subsample for speed).
    std::vector<float> large_resampled(count);
    for (std::uint32_t y = 0; y < out_h; ++y) {
        for (std::uint32_t x = 0; x < out_w; ++x) {
            float lx = x * sx;
            float ly = y * sy;
            auto lx0 = static_cast<std::uint32_t>(lx);
            auto ly0 = static_cast<std::uint32_t>(ly);
            std::uint32_t lx1 = std::min(lx0 + 1, large_result.width - 1);
            std::uint32_t ly1 = std::min(ly0 + 1, large_result.height - 1);
            lx0 = std::min(lx0, large_result.width - 1);
            ly0 = std::min(ly0, large_result.height - 1);
            float fx = lx - static_cast<float>(lx0);
            float fy = ly - static_cast<float>(ly0);
            float d00 = large_result.depth_map[ly0 * large_result.width + lx0];
            float d10 = large_result.depth_map[ly0 * large_result.width + lx1];
            float d01 = large_result.depth_map[ly1 * large_result.width + lx0];
            float d11 = large_result.depth_map[ly1 * large_result.width + lx1];
            large_resampled[y * out_w + x] =
                d00 * (1 - fx) * (1 - fy) + d10 * fx * (1 - fy) +
                d01 * (1 - fx) * fy + d11 * fx * fy;
        }
    }

    // ── Step 2: Least-squares affine alignment ──
    // Find α, β minimizing Σ(α·d_small + β − d_large)²
    // Closed form:
    //   α = (N·Σ(s·l) − Σs·Σl) / (N·Σ(s²) − (Σs)²)
    //   β = (Σl − α·Σs) / N
    // Subsample for speed: every 4th pixel (>25% coverage).
    double sum_s = 0, sum_l = 0, sum_sl = 0, sum_ss = 0;
    std::size_t n_valid = 0;
    for (std::size_t i = 0; i < count; i += 4) {
        float ds = small_result.depth_map[i];
        float dl = large_resampled[i];
        if (ds > 0.01f && ds < 0.99f && dl > 0.01f && dl < 0.99f) {
            sum_s += ds;
            sum_l += dl;
            sum_sl += ds * dl;
            sum_ss += ds * ds;
            n_valid++;
        }
    }

    float alpha = 1.0f, beta = 0.0f;  // Identity fallback
    if (n_valid > 100) {
        double N = static_cast<double>(n_valid);
        double denom = N * sum_ss - sum_s * sum_s;
        if (std::fabs(denom) > 1e-12) {
            alpha = static_cast<float>((N * sum_sl - sum_s * sum_l) / denom);
            beta = static_cast<float>((sum_l - alpha * sum_s) / N);
            // Sanity: clamp to reasonable range
            alpha = std::clamp(alpha, 0.1f, 10.0f);
            beta = std::clamp(beta, -2.0f, 2.0f);
        }
    }

    // ── Step 3: Cross-validate on ALIGNED small vs large ──
    // After affine alignment, models should agree on >90% of pixels.
    constexpr float kDivergenceThreshold = 0.08f;  // 8% (tighter after alignment)

    std::size_t consensus_count = 0;
    std::size_t divergent_count = 0;

    for (std::size_t i = 0; i < count; ++i) {
        float ds = small_result.depth_map[i];
        float dl = large_resampled[i];
        float ds_aligned = alpha * ds + beta;

        // Relative divergence on ALIGNED values
        float max_d = std::max(std::fabs(ds_aligned), std::fabs(dl));
        float delta = (max_d > 1e-6f)
            ? std::fabs(ds_aligned - dl) / max_d
            : 0.0f;

        if (delta < kDivergenceThreshold) {
            // Consensus: inverse-variance weighted fusion.
            // Large model (more parameters) gets higher weight,
            // but aligned small provides complementary high-frequency detail.
            // Output in Large model's scale (since that's what we aligned TO).
            consensus_out.depth_map[i] = 0.35f * ds_aligned + 0.65f * dl;
            consensus_count++;
        } else {
            // Divergent: use Large model (more parameters → more reliable
            // for absolute depth). Small model excels at edges but may have
            // scale artifacts that survive affine alignment.
            consensus_out.depth_map[i] = dl;
            divergent_count++;
        }
    }

    // Log cross-validation stats periodically
    static std::uint32_t cv_log_counter = 0;
    if (cv_log_counter++ % 30 == 0) {
        float consensus_pct = count > 0 ? 100.0f * consensus_count / count : 0.0f;
        std::fprintf(stderr,
            "[Aether3D] DAv2 cross-validation: %ux%u | affine α=%.3f β=%.3f | "
            "consensus=%.1f%% divergent=%.1f%% (n_align=%zu)\n",
            out_w, out_h, alpha, beta,
            consensus_pct, 100.0f - consensus_pct, n_valid);
    }

    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// TSDF-driven Quality Overlay
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::generate_overlay_vertices(
    PointCloudData& pc_data,
    const FrameInput& frame_input) noexcept {
    pc_data.overlay.clear();
    if (!tsdf_volume_) return;

    // ── THROTTLE: minimum interval between expensive TSDF quality scans ──
    // get_block_quality_samples() is O(N_blocks × 512 voxels/block).
    // With 10K+ blocks (common after 50+ frames at 4mm voxels in a 3m room),
    // one call takes 3-5 seconds on CPU, blocking the consumer thread.
    // Root cause of 94% frame drop: was called EVERY frame; now throttled to
    // MAX once per 3 seconds so consumer runs at ~10fps between rebuilds.
    //
    // CRITICAL: overlay_last_gen_time_ is set AFTER the expensive work (not before).
    // Setting it before caused elapsed = rebuild_duration >> throttle_ms on next call
    // → always rebuilt → consumer always blocked → 94% frame drop rate.
    const auto now = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - overlay_last_gen_time_);
    const int throttle_ms = 3000;  // 3s: prevents consumer starvation with large TSDF
    if (elapsed.count() < throttle_ms && !overlay_cache_.empty()) {
        pc_data.overlay = overlay_cache_;
        return;
    }
    // NOTE: overlay_last_gen_time_ updated AFTER the expensive work below (see end of function)

    // ── Synchronous quality sampling with rotating block cap ─────────────────
    // get_block_quality_samples() is O(max_blocks × 512 voxels).
    // Capped at kMaxOverlaySampleBlocks so consumer never stalls > ~50ms.
    // Called synchronously on the consumer thread (Thread A) — safe because
    // Thread A owns exclusive access to tsdf_volume_.
    //
    // Rotating offset: each overlay rebuild samples a DIFFERENT slice of the
    // block array. Over N = total_blocks/kMaxOverlaySampleBlocks rebuilds, ALL
    // blocks are covered exactly once. This prevents Gaussian seeding bias
    // toward the first-created blocks (from early-scan camera positions) and
    // ensures uniform spatial coverage of the full TSDF volume.
    std::vector<tsdf::BlockQualitySample> samples;
    constexpr std::size_t kMaxOverlaySampleBlocks = 50000;
    static std::size_t overlay_sample_offset = 0;  // consumer thread only
    tsdf_volume_->get_block_quality_samples(samples, kMaxOverlaySampleBlocks,
                                             overlay_sample_offset);
    overlay_sample_offset += kMaxOverlaySampleBlocks;  // advance for next rebuild
    if (samples.empty()) {
        pc_data.overlay = overlay_cache_;
        return;
    }

    // ── Quality diagnostics: log distribution every ~2 seconds ──
    {
        static int diag_counter = 0;
        if (++diag_counter % 40 == 1) {  // ~2s at 50ms throttle
            float max_q = 0.0f, sum_q = 0.0f;
            float max_w = 0.0f;
            std::size_t surface_count = 0;
            std::size_t trainable_count = 0;  // blocks meeting Gaussian creation criteria
            for (const auto& s : samples) {
                if (s.occupied_count > 0 && s.has_surface) {
                    surface_count++;
                    sum_q += s.composite_quality;
                    if (s.composite_quality > max_q) max_q = s.composite_quality;
                    if (s.avg_weight > max_w) max_w = s.avg_weight;
                    if (s.avg_weight >= 4.0f) trainable_count++;
                }
            }
            float avg_q = surface_count > 0 ? sum_q / surface_count : 0.0f;
            std::fprintf(stderr,
                "[Aether3D][QualityDiag] blocks=%zu surface=%zu trainable=%zu "
                "max_q=%.3f avg_q=%.3f max_weight=%.1f assigned=%zu\n",
                samples.size(), surface_count, trainable_count,
                max_q, avg_q, max_w, assigned_blocks_.size());
        }
    }

    // ── S6+ Detection: display-only indicator (composite_quality ≥ 0.85) ──
    // NOTE: S6+ is a DISPLAY concept (overlay heatmap color, HUD label).
    // Gaussian creation uses SEPARATE geometry criteria (see below).
    // These are intentionally decoupled: you don't need 360° angular diversity
    // to initialize a Gaussian — surface_center from SDF is accurate with
    // just a few depth observations. Training (MCMC/SteepGS) refines from there.
    if (!has_s6_quality_.load(std::memory_order_relaxed)) {
        for (const auto& s : samples) {
            if (s.occupied_count > 0 && s.composite_quality >= 0.85f) {
                has_s6_quality_.store(true, std::memory_order_release);
                std::fprintf(stderr,
                    "[Aether3D] S6+ DETECTED: block at (%.2f,%.2f,%.2f) quality=%.3f "
                    "— display threshold 0.85 reached\n",
                    s.center[0], s.center[1], s.center[2], s.composite_quality);
                break;
            }
        }
    }

    // ── TSDF→Gaussian: DENSE surface seeding (S1: per-voxel) ──
    // Target: 100K-1M+ initial Gaussians from TSDF surface.
    //
    // S1 UPGRADE: Per-voxel dense seeding — 1 Gaussian per occupied surface voxel.
    //   Old:  occupied_count/4, max 64 → ~33K Gaussians for desk scene.
    //   New:  occupied_count,   max 512 → ~146K Gaussians for desk scene (×4.5).
    //   Combined with S2 (5mm voxels) and S3 (MCMC densification), achieves 1M+.
    //
    // The memory budget controller in GaussianTrainingEngine caps total count,
    // so dense seeding here is safe — overflow is gracefully clipped.
    //
    // Gate: has_surface (≥12 SDF zero-crossings) OR high-weight alternative.
    // Placement: Fibonacci spiral on surface tangent plane + thin normal jitter.
    //
    // Rate limiter: token bucket prevents burst creation of too many Gaussians
    // when scanning reveals a large area at once. Smooth 20K/s steady flow,
    // 50K burst capacity. Prevents training engine from being overwhelmed.
    {
        // ── Token bucket refill ──
        if (!gaussian_bucket_initialized_) {
            gaussian_bucket_tokens_ = kGaussianBucketCapacity;
            gaussian_bucket_last_refill_ = now;
            gaussian_bucket_initialized_ = true;
        } else {
            auto refill_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                now - gaussian_bucket_last_refill_);
            if (refill_elapsed.count() > 0) {
                std::size_t refill = static_cast<std::size_t>(
                    static_cast<double>(kGaussianRefillRate) *
                    static_cast<double>(refill_elapsed.count()) / 1000.0);
                gaussian_bucket_tokens_ = std::min(
                    gaussian_bucket_tokens_ + refill, kGaussianBucketCapacity);
                gaussian_bucket_last_refill_ = now;
            }
        }

        constexpr float kBaseVoxelSize = tsdf::VOXEL_SIZE_MID;  // 0.01m (10mm)
        const bool bootstrap_seed_mode = assigned_blocks_.size() < 4096;
        const float min_weight_for_gaussian = bootstrap_seed_mode ? 0.35f : 2.0f;
        const float min_alt_weight = bootstrap_seed_mode ? 0.9f : 6.0f;
        const std::uint32_t min_alt_occupied = bootstrap_seed_mode ? 4u : 32u;
        constexpr std::size_t kMaxSeedsPerBlock = 512;    // S1: full block capacity (8×8×8)
        constexpr float kGoldenAngle = 2.39996322f;       // π(3 − √5) — Fibonacci spiral
        const float block_world_size = kBaseVoxelSize *
            static_cast<float>(tsdf::BLOCK_SIZE);
        // S2: Camera position for per-block depth-adaptive voxel scale
        const float cam_x = overlay_cam_pos_[0];
        const float cam_y = overlay_cam_pos_[1];
        const float cam_z = overlay_cam_pos_[2];
        std::vector<splat::GaussianParams> new_gaussians;
        // Reserve a bounded amount: 4% of samples qualify (surface + weight),
        // each contributing up to 512 seeds. Cap at 300K to avoid huge allocation.
        // 50K blocks × 4% qualify × 60 seeds ≈ 120K → reserve 200K is safe.
        constexpr std::size_t kReserveSeeds = 200000;
        new_gaussians.reserve(std::min(samples.size() * 4, kReserveSeeds));
        std::size_t seeded_blocks = 0;
        std::size_t sampled_colors = 0;
        std::size_t fallback_colors = 0;
        std::size_t blocks_checked = 0;
        std::size_t blocks_rejected_surface = 0;
        std::size_t blocks_rejected_weight = 0;

        for (const auto& s : samples) {
            if (s.occupied_count == 0) continue;
            blocks_checked++;

            // Gate: either has_surface OR (high weight + enough occupied voxels)
            const bool surface_ok = s.has_surface;
            const bool alt_ok = (s.avg_weight >= min_alt_weight && s.occupied_count >= min_alt_occupied);
            if (!surface_ok && !alt_ok) {
                blocks_rejected_surface++;
                continue;
            }
            if (s.avg_weight < min_weight_for_gaussian) {
                blocks_rejected_weight++;
                continue;
            }

            // Spatial hash key from block center
            tsdf::BlockIndex idx(
                static_cast<int32_t>(std::floor(s.center[0] / block_world_size)),
                static_cast<int32_t>(std::floor(s.center[1] / block_world_size)),
                static_cast<int32_t>(std::floor(s.center[2] / block_world_size)));
            auto key = block_hash_key(idx);
            if (assigned_blocks_.count(key) > 0) continue;

            // Token bucket rate limit: prevent burst Gaussian creation
            if (gaussian_bucket_tokens_ == 0) break;  // No tokens left this call

            assigned_blocks_.insert(key);
            seeded_blocks++;

            // Rotation + tangent basis from TSDF surface normal.
            float nx = s.normal[0], ny = s.normal[1], nz = s.normal[2];
            float nlen = std::sqrt(nx*nx + ny*ny + nz*nz);
            float q_w = 1.0f, q_x = 0.0f, q_y = 0.0f, q_z = 0.0f;
            if (nlen > 0.001f) {
                nx /= nlen; ny /= nlen; nz /= nlen;
                float dot = nz;  // dot((0,0,1), normal)
                if (dot < -0.999f) {
                    q_w = 0.0f; q_x = 1.0f; q_y = 0.0f; q_z = 0.0f;
                } else {
                    const float cx_ = -ny;  // cross((0,0,1), normal)
                    const float cy_ = nx;
                    const float cz_ = 0.0f;
                    float w_ = 1.0f + dot;
                    float qlen = std::sqrt(cx_*cx_ + cy_*cy_ + cz_*cz_ + w_*w_);
                    q_w = w_ / qlen;
                    q_x = cx_ / qlen;
                    q_y = cy_ / qlen;
                    q_z = cz_ / qlen;
                }
            } else {
                nx = 0.0f; ny = 1.0f; nz = 0.0f;
            }

            // Build an orthonormal tangent basis for in-block seed spreading.
            float ref_x = 0.0f, ref_y = 1.0f, ref_z = 0.0f;
            if (std::fabs(ny) > 0.9f) {
                ref_x = 1.0f; ref_y = 0.0f; ref_z = 0.0f;
            }
            float tx = ref_y * nz - ref_z * ny;
            float ty = ref_z * nx - ref_x * nz;
            float tz = ref_x * ny - ref_y * nx;
            float tlen = std::sqrt(tx*tx + ty*ty + tz*tz);
            if (tlen > 1e-6f) {
                tx /= tlen; ty /= tlen; tz /= tlen;
            } else {
                tx = 1.0f; ty = 0.0f; tz = 0.0f;
            }
            float bx = ny * tz - nz * ty;
            float by = nz * tx - nx * tz;
            float bz = nx * ty - ny * tx;

            // ── S2: Adaptive voxel scale — near objects get finer resolution ──
            // TSDF adaptive tiers: 5mm (< 1m), 10mm (1-3m), 20mm (> 3m).
            // For near blocks, we subdivide each voxel into sub-voxels,
            // creating 4× more Gaussians at half the size.
            // For far blocks, we use larger Gaussians but fewer of them.
            const float blk_dx = s.surface_center[0] - cam_x;
            const float blk_dy = s.surface_center[1] - cam_y;
            const float blk_dz = s.surface_center[2] - cam_z;
            const float block_depth = std::sqrt(blk_dx*blk_dx + blk_dy*blk_dy + blk_dz*blk_dz);

            float effective_voxel_size = kBaseVoxelSize;  // 10mm default
            if (block_depth < tsdf::DEPTH_NEAR_THRESHOLD) {
                // Near tier (< 1m): smaller Gaussian scale for fine geometry
                effective_voxel_size = tsdf::VOXEL_SIZE_NEAR;  // 0.005m
            } else if (block_depth > tsdf::DEPTH_FAR_THRESHOLD) {
                // Far tier (> 3m): larger Gaussian scale for far surfaces
                effective_voxel_size = tsdf::VOXEL_SIZE_FAR;  // 0.02m
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
            // Photo-SLAM-style pacing: avoid seeding every good block at max capacity.
            // This keeps online training from saturating CPU/GPU too early while still
            // allowing steady >1M growth via later densify.
            std::size_t seeds_per_block = static_cast<std::size_t>(
                std::llround(static_cast<double>(kMaxSeedsPerBlock) * seed_density));
            seeds_per_block = std::clamp<std::size_t>(seeds_per_block, 64u, 320u);
            // Spread radius covers the full block face (not just 1 voxel)
            const float spread_radius = block_world_size * 0.45f;
            // Per-Gaussian scale: ~1 effective voxel in-plane, thin along normal
            const float base_scale = effective_voxel_size * 0.7f;

            const float seeds_f = static_cast<float>(seeds_per_block);

            for (std::size_t seed_idx = 0; seed_idx < seeds_per_block; ++seed_idx) {
                const std::uint64_t seed =
                    static_cast<std::uint64_t>(key) ^
                    (0x9E3779B97F4A7C15ULL + seed_idx * 0x94D049BB133111EBULL);
                const float jitter_c = hash_unit01(seed + 41u);

                // Fibonacci spiral for uniform disk coverage
                const float angle = static_cast<float>(seed_idx) * kGoldenAngle;
                const float radial = (seed_idx == 0)
                    ? 0.0f
                    : spread_radius * std::sqrt(
                          static_cast<float>(seed_idx) / seeds_f);
                const float c = std::cos(angle);
                const float ss = std::sin(angle);

                // In-plane offset (tangent disk)
                const float ox = (tx * c + bx * ss) * radial;
                const float oy = (ty * c + by * ss) * radial;
                const float oz = (tz * c + bz * ss) * radial;

                // Thin normal jitter for 3D spread (±half voxel along normal)
                const float nj = (hash_unit01(seed + 59u) - 0.5f) * effective_voxel_size * 0.5f;

                splat::GaussianParams g{};
                g.position[0] = s.surface_center[0] + ox + nx * nj;
                g.position[1] = s.surface_center[1] + oy + ny * nj;
                g.position[2] = s.surface_center[2] + oz + nz * nj;

                float sampled_rgb[3] = {0.0f, 0.0f, 0.0f};
                bool color_ok = sample_frame_color_linear(
                    frame_input,
                    g.position[0], g.position[1], g.position[2],
                    sampled_rgb);
                // If current frame misses (camera has moved away), try keyframes.
                // This fixes colorHit=0% for objects like bookshelves that are only
                // visible from specific past viewpoints (not the current frame).
                if (!color_ok) {
                    for (auto it = depth_keyframes_.rbegin();
                         it != depth_keyframes_.rend() && !color_ok; ++it) {
                        if (it->rgba.empty()) continue;
                        FrameInput kf_input;
                        kf_input.rgba = it->rgba;
                        kf_input.width  = static_cast<std::uint32_t>(it->rgba_w);
                        kf_input.height = static_cast<std::uint32_t>(it->rgba_h);
                        std::memcpy(kf_input.transform,   it->pose,           16 * sizeof(float));
                        std::memcpy(kf_input.intrinsics, it->rgba_intrinsics,  9 * sizeof(float));
                        color_ok = sample_frame_color_linear(
                            kf_input,
                            g.position[0], g.position[1], g.position[2],
                            sampled_rgb);
                    }
                }
                const bool strict_preview_color =
                    config_.local_preview_mode && frame_input.imported_video;
                if (color_ok) {
                    g.color[0] = sampled_rgb[0];
                    g.color[1] = sampled_rgb[1];
                    g.color[2] = sampled_rgb[2];
                    sampled_colors++;
                } else if (strict_preview_color) {
                    continue;
                } else {
                    // Fallback if no keyframe sees this point either.
                    const float base_luma = std::clamp(
                        0.08f + 0.42f * quality_norm + 0.10f * weight_norm,
                        0.06f, 0.72f);
                    g.color[0] = base_luma * (0.92f + 0.14f * jitter_c);
                    g.color[1] = base_luma * (0.90f + 0.10f * (1.0f - jitter_c));
                    g.color[2] = base_luma * (0.95f + 0.08f * (1.0f - weight_norm));
                    fallback_colors++;
                }

                g.opacity = 0.25f + 0.60f * weight_norm;  // [0.25, 0.85]
                const float anis = 0.75f + 0.50f * jitter_c;
                g.scale[0] = base_scale * anis;
                g.scale[1] = base_scale * (1.60f - anis);
                g.scale[2] = effective_voxel_size * (0.10f + 0.12f * (1.0f - quality_norm));

                g.rotation[0] = q_w;
                g.rotation[1] = q_x;
                g.rotation[2] = q_y;
                g.rotation[3] = q_z;
                new_gaussians.push_back(g);
            }

            // Consume tokens for this block's Gaussians
            if (seeds_per_block <= gaussian_bucket_tokens_) {
                gaussian_bucket_tokens_ -= seeds_per_block;
            } else {
                gaussian_bucket_tokens_ = 0;
            }
        }

        if (new_gaussians.empty() && !samples.empty() && gaussian_bucket_tokens_ > 0) {
            static std::uint32_t empty_seed_diag = 0;
            empty_seed_diag++;
            if (empty_seed_diag <= 10 || (empty_seed_diag % 60 == 0)) {
                std::fprintf(stderr,
                    "[Aether3D][TSDF→GS] empty primary seeding: checked=%zu reject_surface=%zu "
                    "reject_weight=%zu bucket=%zu assigned=%zu bootstrap=%d "
                    "minW=%.2f altW=%.2f altOcc=%d\n",
                    blocks_checked, blocks_rejected_surface, blocks_rejected_weight,
                    gaussian_bucket_tokens_, assigned_blocks_.size(),
                    bootstrap_seed_mode ? 1 : 0,
                    min_weight_for_gaussian, min_alt_weight, min_alt_occupied);
            }
            std::size_t emergency_blocks = 0;
            constexpr std::size_t kEmergencyMaxBlocks = 96;
            constexpr std::size_t kEmergencyMaxSeedsPerBlock = 8;

            for (const auto& s : samples) {
                if (emergency_blocks >= kEmergencyMaxBlocks || gaussian_bucket_tokens_ == 0) break;
                if (s.occupied_count == 0) continue;
                if (!s.has_surface && s.avg_weight < 0.35f) continue;

                tsdf::BlockIndex idx(
                    static_cast<int32_t>(std::floor(s.center[0] / block_world_size)),
                    static_cast<int32_t>(std::floor(s.center[1] / block_world_size)),
                    static_cast<int32_t>(std::floor(s.center[2] / block_world_size)));
                auto key = block_hash_key(idx);
                if (assigned_blocks_.count(key) > 0) continue;

                assigned_blocks_.insert(key);
                seeded_blocks++;
                emergency_blocks++;

                std::size_t seeds_per_block = std::max<std::size_t>(
                    1, std::min<std::size_t>(
                           kEmergencyMaxSeedsPerBlock,
                           static_cast<std::size_t>(s.occupied_count / 8 + 1)));
                if (seeds_per_block > gaussian_bucket_tokens_) {
                    seeds_per_block = gaussian_bucket_tokens_;
                }

                float nx = s.normal[0], ny = s.normal[1], nz = s.normal[2];
                const float nlen = std::sqrt(nx * nx + ny * ny + nz * nz);
                if (nlen > 1e-6f) {
                    nx /= nlen; ny /= nlen; nz /= nlen;
                } else {
                    nx = 0.0f; ny = 1.0f; nz = 0.0f;
                }

                for (std::size_t seed_idx = 0; seed_idx < seeds_per_block; ++seed_idx) {
                    const std::uint64_t seed =
                        static_cast<std::uint64_t>(key) ^
                        (0x9E3779B97F4A7C15ULL + seed_idx * 0x94D049BB133111EBULL);
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
                    const bool strict_preview_color =
                        config_.local_preview_mode && frame_input.imported_video;
                    if (sample_frame_color_linear(frame_input, g.position[0], g.position[1], g.position[2], sampled_rgb)) {
                        g.color[0] = sampled_rgb[0];
                        g.color[1] = sampled_rgb[1];
                        g.color[2] = sampled_rgb[2];
                        sampled_colors++;
                    } else if (strict_preview_color) {
                        continue;
                    } else {
                        const float q = std::clamp(s.composite_quality, 0.0f, 1.0f);
                        const float luma = std::clamp(0.12f + 0.35f * q, 0.08f, 0.55f);
                        g.color[0] = luma;
                        g.color[1] = luma;
                        g.color[2] = luma;
                        fallback_colors++;
                    }

                    const float weight_norm = std::clamp(s.avg_weight / 8.0f, 0.0f, 1.0f);
                    g.opacity = 0.20f + 0.50f * weight_norm;
                    const float scale = std::max(0.0025f, kBaseVoxelSize * 0.55f);
                    g.scale[0] = scale;
                    g.scale[1] = scale;
                    g.scale[2] = scale * 0.7f;
                    g.rotation[0] = 1.0f;
                    g.rotation[1] = 0.0f;
                    g.rotation[2] = 0.0f;
                    g.rotation[3] = 0.0f;
                    new_gaussians.push_back(g);
                }

                if (seeds_per_block <= gaussian_bucket_tokens_) {
                    gaussian_bucket_tokens_ -= seeds_per_block;
                } else {
                    gaussian_bucket_tokens_ = 0;
                }
            }

            if (!new_gaussians.empty()) {
                std::fprintf(stderr,
                    "[Aether3D][TSDF→GS] emergency seeding activated: +%zu gaussians from %zu blocks\n",
                    new_gaussians.size(), emergency_blocks);
            }
        }

        if (!new_gaussians.empty()) {
            std::lock_guard<std::mutex> lock(training_mutex_);
            pending_gaussians_.insert(pending_gaussians_.end(),
                new_gaussians.begin(), new_gaussians.end());

            static std::size_t total_created = 0;
            total_created += new_gaussians.size();
            const float density =
                seeded_blocks > 0
                    ? static_cast<float>(new_gaussians.size()) / static_cast<float>(seeded_blocks)
                    : 0.0f;
            const float color_hit =
                (sampled_colors + fallback_colors) > 0
                    ? (100.0f * static_cast<float>(sampled_colors) /
                       static_cast<float>(sampled_colors + fallback_colors))
                    : 0.0f;
            // Compute average initial color for diagnostic
            float avg_r = 0, avg_g = 0, avg_b = 0;
            for (const auto& ng : new_gaussians) {
                avg_r += ng.color[0]; avg_g += ng.color[1]; avg_b += ng.color[2];
            }
            if (!new_gaussians.empty()) {
                float inv = 1.0f / static_cast<float>(new_gaussians.size());
                avg_r *= inv; avg_g *= inv; avg_b *= inv;
            }
            std::fprintf(stderr,
                "[Aether3D][TSDF→GS] +%zu Gaussians from %zu blocks "
                "(density=%.1f/block, colorHit=%.1f%%, avg_rgb=[%.3f,%.3f,%.3f], "
                "total=%zu, assigned=%zu, checked=%zu, reject_surface=%zu, reject_weight=%zu)\n",
                new_gaussians.size(), seeded_blocks, density, color_hit,
                avg_r, avg_g, avg_b,
                total_created, assigned_blocks_.size(),
                blocks_checked, blocks_rejected_surface, blocks_rejected_weight);
        }
    }

    const float cx = overlay_cam_pos_[0];
    const float cy = overlay_cam_pos_[1];
    const float cz = overlay_cam_pos_[2];
    const float fwd_x = overlay_cam_fwd_[0];
    const float fwd_y = overlay_cam_fwd_[1];
    const float fwd_z = overlay_cam_fwd_[2];
    constexpr float kFrustumCosCutoff = -0.1f;  // cos(~96°) — generous margin
    const std::size_t confirmed_count = confirmed_overlay_cells_.size();
    const std::size_t keyframe_count = depth_keyframes_.size();
    const std::uint32_t total_frames = frame_counter_.load(std::memory_order_relaxed);
    const bool warmup_overlay =
        (confirmed_count < 320u) && (total_frames < 420u || keyframe_count < 10u);
    const bool bootstrap_overlay_mode = warmup_overlay || (confirmed_count < 128u);
    const std::uint32_t min_occupied_count = warmup_overlay ? 2u : 10u;
    const float min_crossing_ratio = warmup_overlay ? 0.01f : 0.08f;
    const float min_normal_consistency = warmup_overlay ? 0.01f : 0.06f;
    const float min_sdf_smoothness = warmup_overlay ? 0.001f : 0.008f;
    const float min_geom_evidence = warmup_overlay ? 0.002f : 0.015f;
    const float min_phantom_score = warmup_overlay ? 0.08f : 0.5f;
    const float min_quality_score = warmup_overlay ? 0.002f : 0.03f;
    const float min_avg_weight = warmup_overlay ? 0.35f : 1.5f;
    const int min_face_neighbors = warmup_overlay ? 0 : 2;

    // ═══════════════════════════════════════════════════════════════════
    // UNIFORM GRID MERGE: Solves three problems at once:
    //   1. Multi-layer overlap: depth noise + multi-resolution TSDF blocks
    //      create 2-3 tiles for the same physical surface → ONE per cell
    //   2. Size variation: adaptive resolution blocks (4cm/8cm/16cm) produce
    //      different-sized tiles → ALL tiles uniform size
    //   3. Orientation chaos: per-block normals from noisy SDF gradients
    //      produce random tile angles → quality-weighted average smooths them
    //
    // Algorithm: hash all surface_centers into a uniform 10cm grid, merge
    // positions, normals, and quality within each cell. Output one tile per
    // occupied cell with consistent size and smoothed orientation.
    // ═══════════════════════════════════════════════════════════════════

    // Grid cell = 5cm: large enough to merge multi-resolution TSDF blocks
    // (near 4cm, mid 8cm) and allow 6-neighbor normal smoothing.
    constexpr float kGridCell = 0.05f;
    constexpr float kGridInv  = 1.0f / kGridCell;
    constexpr float kTileHalf = kGridCell * 0.47f;  // 4.7cm full width, 3mm gap

    struct MergedCell {
        double pos[3]{};       // Weighted-average surface position
        double norm[3]{};      // Weighted-average surface normal
        float  quality_wsum{0};// Σ(quality × occupied_count) for weighted avg
        int    occ_sum{0};     // Σ(occupied_count) — denominator for quality avg
        float  total_weight{0};// Σ(quality × occupied_count) — for position avg
        int    gx{0}, gy{0}, gz{0};  // Grid indices (for neighbor lookup)
    };

    // Spatial hash: 20 bits per axis (±52K cells ≈ ±5.2km range)
    auto grid_key = [&](int gx, int gy, int gz) -> std::int64_t {
        auto u = [](int v) -> std::uint64_t {
            return static_cast<std::uint64_t>(static_cast<std::uint32_t>(v)) & 0xFFFFFu;
        };
        return static_cast<std::int64_t>(
            (u(gx) << 40) | (u(gy) << 20) | u(gz));
    };

    std::unordered_map<std::int64_t, MergedCell> grid;
    grid.reserve(samples.size());

    std::size_t skipped_sparse = 0, skipped_no_surface = 0;
    std::size_t skipped_low_q = 0, skipped_isolated = 0, merged_count = 0;

    for (const auto& s : samples) {
        // DENSITY FILTER: require meaningful voxel occupation.
        // At 5mm voxels, truncation = 15mm → 3 active layers per side = 6 total.
        // A surface plane crossing a block fills ~6×64 = 384 active voxels.
        // Phantom blocks from single-frame depth discontinuities fill < 16 voxels.
        // Threshold 16 (≈3%) keeps phantom-free while showing newly-seen blocks.
        if (s.occupied_count < min_occupied_count) { ++skipped_sparse; continue; }

        // SURFACE FILTER: blocks with ≥12 SDF zero-crossings (set in tsdf_volume.cpp).
        // A real surface slice produces 20-100+ crossings; edge noise has 3-8.
        if (!s.has_surface) { ++skipped_no_surface; continue; }

        // CROSSING DENSITY FILTER: ratio of zero-crossing voxels to active voxels.
        // At 5mm voxels, truncation = 3×voxel = 15mm → active zone spans ~6 layers.
        // Real flat surface: ~1 crossing layer / 6 active layers ≈ 0.17 ratio.
        // Curved surfaces (furniture edges): ratio ≈ 0.20-0.35.
        // Phantom depth noise: ratio < 0.08 (randomly scattered crossings).
        // Threshold 0.12 accepts real geometry while rejecting noise.
        float crossing_ratio = 0.0f;
        if (s.occupied_count > 0) {
            crossing_ratio = static_cast<float>(s.surf_count)
                           / static_cast<float>(s.occupied_count);
            if (crossing_ratio < min_crossing_ratio) { ++skipped_no_surface; continue; }
        }

        // NORMAL CONSISTENCY FILTER: reject blocks where zero-crossing normals
        // point in chaotic directions. Real surfaces have aligned gradients
        // (consistency ≈ 0.2-0.6). Phantom blocks from conflicting depth
        // observations have divergent normals (consistency ≈ 0.05).
        if (s.normal_consistency < min_normal_consistency) { ++skipped_no_surface; continue; }

        // SDF SMOOTHNESS FILTER (two-tier phantom detector):
        // Tier 1: If Laplacian data exists (smoothness > 0), reject noisy SDF.
        //   Real surfaces have linear SDF (Laplacian ≈ 0, smoothness ≈ 0.03-0.30).
        //   Phantom blocks from depth conflicts have noisy SDF (smoothness < 0.01).
        // Tier 2: If no Laplacian data (smoothness == 0), require basic geometric
        //   evidence: crossing_ratio × normal_consistency ≥ 0.02.
        if (s.sdf_smoothness > 0.0f) {
            if (s.sdf_smoothness < min_sdf_smoothness) { ++skipped_no_surface; continue; }
        } else {
            float geom_evidence = crossing_ratio * s.normal_consistency;
            if (geom_evidence < min_geom_evidence) { ++skipped_no_surface; continue; }
        }

        // COMPOSITE PHANTOM FILTER: ratio × weight.
        // At 5mm voxels, real surface with crossing_ratio=0.17, avg_weight=5:
        //   score = 0.17 × 5 = 0.85 → PASS with threshold 0.8.
        // Phantom blocks (ratio ≈ 0.08, weight ≈ 2): score = 0.16 → FAIL.
        {
            float phantom_score = crossing_ratio * s.avg_weight;
            if (phantom_score < min_phantom_score) { ++skipped_no_surface; continue; }
        }

        // CONFIDENCE FILTER: very low quality → likely noise artifacts
        if (s.composite_quality < min_quality_score) { ++skipped_low_q; continue; }

        // Already scanned well enough — overlay not needed
        if (s.composite_quality >= 0.95f) continue;

        // WEIGHT FILTER: require at least 2 independent observations.
        // avg_weight < 2 means the block's surface was seen only once → noisy.
        if (s.avg_weight < min_avg_weight) { ++skipped_low_q; continue; }

        int gx = static_cast<int>(std::floor(s.surface_center[0] * kGridInv));
        int gy = static_cast<int>(std::floor(s.surface_center[1] * kGridInv));
        int gz = static_cast<int>(std::floor(s.surface_center[2] * kGridInv));

        float w = s.composite_quality * static_cast<float>(s.occupied_count);
        if (w < 1e-9f) w = 1e-9f;

        auto& cell = grid[grid_key(gx, gy, gz)];
        cell.pos[0]  += static_cast<double>(s.surface_center[0]) * w;
        cell.pos[1]  += static_cast<double>(s.surface_center[1]) * w;
        cell.pos[2]  += static_cast<double>(s.surface_center[2]) * w;
        cell.norm[0] += static_cast<double>(s.normal[0]) * w;
        cell.norm[1] += static_cast<double>(s.normal[1]) * w;
        cell.norm[2] += static_cast<double>(s.normal[2]) * w;
        cell.quality_wsum += s.composite_quality * static_cast<float>(s.occupied_count);
        cell.occ_sum += s.occupied_count;
        cell.total_weight += w;
        cell.gx = gx; cell.gy = gy; cell.gz = gz;
        ++merged_count;
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEIGHBOR NORMAL SMOOTHING: Average each cell's normal with its
    // 6 face-neighbors' normals. This smooths out per-block noise:
    // a flat floor's cells all converge to a consistent upward normal
    // even if individual TSDF blocks had noisy gradients.
    // Cost: O(N × 6 lookups) ≈ ~0.3ms for 5K cells.
    // ═══════════════════════════════════════════════════════════════════
    struct SmoothedNormal { float nx, ny, nz; };
    std::unordered_map<std::int64_t, SmoothedNormal> smoothed;
    smoothed.reserve(grid.size());

    for (const auto& [key, cell] : grid) {
        if (cell.total_weight < 1e-6f) continue;
        double inv_w = 1.0 / static_cast<double>(cell.total_weight);
        // Start with this cell's own normal (weighted by its total_weight)
        double snx = cell.norm[0] * inv_w;
        double sny = cell.norm[1] * inv_w;
        double snz = cell.norm[2] * inv_w;
        float self_w = cell.total_weight;
        float sum_w = self_w;

        // Accumulate 6 face-neighbors
        static const int ndx[] = {-1, 1, 0, 0, 0, 0};
        static const int ndy[] = { 0, 0,-1, 1, 0, 0};
        static const int ndz[] = { 0, 0, 0, 0,-1, 1};
        for (int n = 0; n < 6; ++n) {
            auto nkey = grid_key(cell.gx + ndx[n], cell.gy + ndy[n], cell.gz + ndz[n]);
            auto it = grid.find(nkey);
            if (it != grid.end() && it->second.total_weight > 1e-6f) {
                double ninv = 1.0 / static_cast<double>(it->second.total_weight);
                float nw = it->second.total_weight;
                snx += it->second.norm[0] * ninv * nw;
                sny += it->second.norm[1] * ninv * nw;
                snz += it->second.norm[2] * ninv * nw;
                sum_w += nw;
            }
        }
        // Normalize
        float len = static_cast<float>(std::sqrt(snx*snx + sny*sny + snz*snz));
        if (len > 1e-6f) {
            smoothed[key] = { static_cast<float>(snx/len),
                              static_cast<float>(sny/len),
                              static_cast<float>(snz/len) };
        } else {
            smoothed[key] = { 0.0f, 1.0f, 0.0f };
        }
    }

    // ── Generate ONE tile per occupied grid cell ──
    // Each candidate stores BOTH the weighted-average position (for accurate
    // depth-filter projection) and the grid cell key (for grid-center snapping
    // and monotonic confirmation tracking).
    struct OverlayCandidate {
        OverlayVertex vertex;  // position = weighted-average (for depth filter)
        float dist_sq;
        std::int64_t grid_key_val;  // For confirmed_overlay_cells_ lookup
        int gx, gy, gz;            // For grid-center snapping after filter
        float nnx, nny, nnz;       // Smoothed normal
        float support_views{0.0f};
    };
    std::vector<OverlayCandidate> candidates;
    candidates.reserve(grid.size());

    // Track which grid cells are present this frame (for confirmed tile output)
    std::unordered_set<std::int64_t> current_frame_cells;

    for (const auto& [key, cell] : grid) {
        if (cell.total_weight < 1e-6f) continue;

        // ISOLATION FILTER: real surfaces are continuous → each cell should
        // have ≥2 face-neighbors. Isolated cells (0-1 neighbors) are phantom
        // artifacts at depth discontinuities.
        {
            int face_neighbors = 0;
            static const int fdx[] = {-1, 1, 0, 0, 0, 0};
            static const int fdy[] = { 0, 0,-1, 1, 0, 0};
            static const int fdz[] = { 0, 0, 0, 0,-1, 1};
            for (int n = 0; n < 6; ++n) {
                auto nk = grid_key(cell.gx + fdx[n], cell.gy + fdy[n], cell.gz + fdz[n]);
                if (grid.count(nk)) ++face_neighbors;
            }
            if (face_neighbors < min_face_neighbors) {
                ++skipped_isolated;
                continue;
            }
        }

        double inv_w = 1.0 / static_cast<double>(cell.total_weight);
        // Weighted-average position (accurate, for depth filter projection)
        float px = static_cast<float>(cell.pos[0] * inv_w);
        float py = static_cast<float>(cell.pos[1] * inv_w);
        float pz = static_cast<float>(cell.pos[2] * inv_w);

        // Weighted-average quality: Σ(quality × occ) / Σ(occ)
        // Honest representation of all contributing blocks, not just the best one.
        float avg_quality = (cell.occ_sum > 0)
            ? cell.quality_wsum / static_cast<float>(cell.occ_sum)
            : 0.0f;

        // ── Frustum culling ──
        float dx = px - cx;
        float dy = py - cy;
        float dz = pz - cz;
        float dist_sq = dx * dx + dy * dy + dz * dz;
        if ((!bootstrap_overlay_mode && dist_sq > 36.0f) ||
            (bootstrap_overlay_mode && dist_sq > 144.0f)) continue;

        float dist = std::sqrt(dist_sq);
        if (!bootstrap_overlay_mode && dist > 1e-6f) {
            float cos_angle = (dx * fwd_x + dy * fwd_y + dz * fwd_z) / dist;
            if (cos_angle < kFrustumCosCutoff) continue;
        }

        // ── Use smoothed normal from neighbor averaging ──
        auto sit = smoothed.find(key);
        float nnx = 0.0f, nny = 1.0f, nnz = 0.0f;
        if (sit != smoothed.end()) {
            nnx = sit->second.nx;
            nny = sit->second.ny;
            nnz = sit->second.nz;
        }

        current_frame_cells.insert(key);

        // ── Check if already confirmed (monotonic: skip depth filter) ──
        auto conf_it = confirmed_overlay_cells_.find(key);
        if (conf_it != confirmed_overlay_cells_.end()) {
            // Already confirmed — bounded WildGS-style anchor/normal refinement.
            if (avg_quality > conf_it->second.quality) {
                conf_it->second.quality = avg_quality;
            }
            const float normal_dot =
                conf_it->second.normal[0] * nnx +
                conf_it->second.normal[1] * nny +
                conf_it->second.normal[2] * nnz;
            if (normal_dot > 0.82f) {
                float blended_nx = conf_it->second.normal[0] * 0.88f + nnx * 0.12f;
                float blended_ny = conf_it->second.normal[1] * 0.88f + nny * 0.12f;
                float blended_nz = conf_it->second.normal[2] * 0.88f + nnz * 0.12f;
                normalize3(blended_nx, blended_ny, blended_nz);
                conf_it->second.normal[0] = blended_nx;
                conf_it->second.normal[1] = blended_ny;
                conf_it->second.normal[2] = blended_nz;

                const float max_anchor_step = 0.0015f;  // 1.5mm conservative refinement
                float dx2 = px - conf_it->second.position[0];
                float dy2 = py - conf_it->second.position[1];
                float dz2 = pz - conf_it->second.position[2];
                const float delta_len = std::sqrt(dx2 * dx2 + dy2 * dy2 + dz2 * dz2);
                if (delta_len > 1e-6f && delta_len < kGridCell * 0.45f) {
                    const float step = std::min(max_anchor_step, delta_len * 0.20f);
                    const float inv_len = step / delta_len;
                    conf_it->second.position[0] += dx2 * inv_len;
                    conf_it->second.position[1] += dy2 * inv_len;
                    conf_it->second.position[2] += dz2 * inv_len;
                }
            }

            conf_it->second.support_count += 1.0f;
            conf_it->second.stability =
                std::min(1.0f, 0.25f + 0.08f * conf_it->second.support_count);
            conf_it->second.last_update_ts = frame_input.timestamp;
            continue;  // Skip depth filter — will be emitted from confirmed set
        }

        // New cell: must pass depth filter
        OverlayCandidate c;
        // Use weighted-average for depth filter (accurate projection)
        c.vertex.position[0] = px;
        c.vertex.position[1] = py;
        c.vertex.position[2] = pz;
        c.vertex.normal[0] = nnx;
        c.vertex.normal[1] = nny;
        c.vertex.normal[2] = nnz;
        c.vertex.size = kTileHalf;           // Uniform size for ALL tiles
        c.vertex.quality = avg_quality;
        c.dist_sq = dist_sq;
        c.grid_key_val = key;
        c.gx = cell.gx;
        c.gy = cell.gy;
        c.gz = cell.gz;
        c.nnx = nnx; c.nny = nny; c.nnz = nnz;
        candidates.push_back(c);
    }

    // ═══════════════════════════════════════════════════════════════════
    // DEPTH-CONSISTENCY POST-FILTER: Multi-view reprojection check.
    //
    // Block-level TSDF metrics (ratio, ncon, smoothness, weight) are
    // insufficient for dense scanning: phantom blocks accumulate enough
    // observations to appear statistically identical to real blocks.
    //
    // This filter uses stored depth keyframes to verify each tile's
    // position against actual depth observations from multiple viewpoints:
    //   1. Project tile into each keyframe's camera
    //   2. Read depth at the projected pixel from the stored depth frame
    //   3. Compare tile depth vs frame depth (10cm tolerance)
    //   4. Require ≥30% of checked cameras agree, minimum 3 cameras
    //
    // Real surfaces exist at consistent depths from all angles.
    // Phantom surfaces (from depth estimation errors) only match the
    // viewpoint that created them; from other angles, the depth frame
    // shows the real surface behind/in front of the phantom.
    // ═══════════════════════════════════════════════════════════════════
    std::size_t depth_rejected = 0;
    const bool strict_depth_filter = (depth_keyframes_.size() >= 5) && !warmup_overlay;
    if (depth_keyframes_.size() >= 3) {
        std::vector<OverlayCandidate> depth_passed;
        depth_passed.reserve(candidates.size());

        // ── Viewpoint diversity detection ──
        // Compute whether keyframes are clustered (single viewpoint) or
        // spread (multi-viewpoint). Novel phantom filters are most effective
        // for single-viewpoint scanning (Scenario F) where traditional
        // consistency checks lack angular diversity. For multi-viewpoint
        // scanning, the existing consistency filter suffices and novel filters
        // would cause false positives when different viewpoints see different
        // surfaces at the same pixel.
        bool clustered_viewpoints = true;
        {
            float avg_fx = 0, avg_fy = 0, avg_fz = 0;
            for (const auto& kf : depth_keyframes_) {
                avg_fx += -kf.pose[8];
                avg_fy += -kf.pose[9];
                avg_fz += -kf.pose[10];
            }
            float len = std::sqrt(avg_fx*avg_fx + avg_fy*avg_fy + avg_fz*avg_fz);
            if (len > 1e-6f) { avg_fx /= len; avg_fy /= len; avg_fz /= len; }

            for (const auto& kf : depth_keyframes_) {
                float fx = -kf.pose[8], fy = -kf.pose[9], fz = -kf.pose[10];
                float fl = std::sqrt(fx*fx + fy*fy + fz*fz);
                if (fl > 1e-6f) { fx /= fl; fy /= fl; fz /= fl; }
                float cos_a = fx * avg_fx + fy * avg_fy + fz * avg_fz;
                if (cos_a < 0.9f) {  // Any keyframe >~25° from average
                    clustered_viewpoints = false;
                    break;
                }
            }
        }

        for (const auto& cand : candidates) {
            const float tx = cand.vertex.position[0];
            const float ty = cand.vertex.position[1];
            const float tz = cand.vertex.position[2];

            int consistent = 0, checked = 0;
            int tight_consistent = 0;          // 2cm tolerance for single viewpoint
            int freespace_violations = 0;      // Novel: free-space carving
            int front_violations = 0;          // Novel: tile in front of surface
            float depth_diff_sum = 0.0f;       // Novel: temporal variance
            float depth_diff_sq_sum = 0.0f;
            int gradient_violations = 0;       // Novel: depth gradient
            int gradient_checked = 0;
            int edge_range_violations = 0;     // Novel: 5×5 depth range
            int edge_range_checked = 0;

            for (const auto& kf : depth_keyframes_) {
                // World → camera (same convention as tsdf_volume.cpp world_to_camera)
                const float ddx = tx - kf.pose[12];
                const float ddy = ty - kf.pose[13];
                const float ddz = tz - kf.pose[14];
                const float cam_x = kf.pose[0]*ddx + kf.pose[1]*ddy + kf.pose[2]*ddz;
                // Negate Y: ARKit col1 = UP, projection expects Y-down (CV convention)
                const float cam_y = -(kf.pose[4]*ddx + kf.pose[5]*ddy + kf.pose[6]*ddz);
                // Negate Z: ARKit col2 = back; negate for positive depth
                const float cam_z = -(kf.pose[8]*ddx + kf.pose[9]*ddy + kf.pose[10]*ddz);

                if (cam_z < 0.1f || cam_z > 5.0f) continue;  // Behind camera or too far

                // Project to depth map pixel
                const float proj_u = kf.fx * (cam_x / cam_z) + kf.cx;
                const float proj_v = kf.fy * (cam_y / cam_z) + kf.cy;
                const int iu = static_cast<int>(proj_u);
                const int iv = static_cast<int>(proj_v);

                // Must be within depth frame bounds (1px margin)
                if (iu < 1 || iu >= kf.width - 1 || iv < 1 || iv >= kf.height - 1) continue;

                // Read depth: 3×3 median for noise robustness.
                // Single-pixel depth is noisy (DAv2 ≈ 5-10mm std dev).
                // Median of 9 neighbors eliminates outlier noise while
                // preserving depth edges, halving the false-positive gap.
                float depth_samples[9];
                int dc = 0;
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        const std::size_t sample_idx =
                            static_cast<std::size_t>(iv + dy) * static_cast<std::size_t>(kf.width) +
                            static_cast<std::size_t>(iu + dx);
                        if (!kf.conf.empty() && kf.conf[sample_idx] == 0u) continue;
                        float d = kf.depth[sample_idx];
                        if (d > 0.0f && d < 10.0f)
                            depth_samples[dc++] = d;
                    }
                }
                if (dc < 3) continue;  // Not enough valid depth neighbors
                // Partial sort to find median
                std::nth_element(depth_samples, depth_samples + dc / 2, depth_samples + dc);
                const float frame_depth = depth_samples[dc / 2];

                ++checked;
                const float depth_error = std::abs(cam_z - frame_depth);
                if (depth_error < 0.05f) {  // 5cm tolerance
                    ++consistent;
                }
                if (depth_error < 0.02f) {  // 2cm tight tolerance
                    ++tight_consistent;
                }

                // ── Novel: Symmetric free-space violation ──
                // Tile IN FRONT of surface: if the tile were real, it would
                // BLOCK the view of the surface behind it. But the depth frame
                // shows the surface → tile is invisible → phantom.
                if (cam_z < frame_depth - 0.02f) {
                    ++front_violations;
                }

                // ── Novel Filter 1: Free-Space Carving ──
                // Kutulakos & Seitz volumetric carving principle (IJCV 2000):
                // If tile depth > observed surface depth + margin, the tile
                // occupies "free space" — the region between camera and the
                // observed surface where no real geometry can exist.
                // Key insight: works from a SINGLE viewpoint because it's a
                // one-sided depth test. A phantom floating behind the real
                // surface triggers this even without viewpoint diversity.
                // 2cm margin: tight but safe (real tiles ≈ ±5mm from depth).
                if (cam_z > frame_depth + 0.02f) {
                    ++freespace_violations;
                }

                // ── Novel Filter 2: Temporal Depth Residual Statistics ──
                // Track (cam_z - frame_depth) across keyframes for variance.
                // Real surfaces: residual ≈ 0 ± σ_noise → variance ≈ σ²_noise.
                // Phantoms at depth edges: hand jitter causes sub-pixel shifts
                // that alternate between foreground/background at depth
                // discontinuities → bimodal residual distribution → high variance.
                // Fisher information: high variance = low reconstruction certainty.
                {
                    const float diff = cam_z - frame_depth;
                    depth_diff_sum += diff;
                    depth_diff_sq_sum += diff * diff;
                }

                // ── Novel Filter 3: Depth Gradient Magnitude ──
                // Phantoms predominantly form at depth discontinuities where
                // monocular/stereo depth estimation is most unreliable.
                // Sobel-like central differences on the depth frame.
                // High gradient = depth edge = phantom formation hotspot.
                if (iu >= 2 && iu < kf.width - 2 && iv >= 2 && iv < kf.height - 2) {
                    const float dl = kf.depth[iv * kf.width + (iu - 1)];
                    const float dr = kf.depth[iv * kf.width + (iu + 1)];
                    const float du = kf.depth[(iv - 1) * kf.width + iu];
                    const float dd = kf.depth[(iv + 1) * kf.width + iu];
                    if (dl > 0.0f && dr > 0.0f && du > 0.0f && dd > 0.0f) {
                        const float gx = (dr - dl) * 0.5f;
                        const float gy = (dd - du) * 0.5f;
                        const float grad = std::sqrt(gx * gx + gy * gy);
                        ++gradient_checked;
                        if (grad > 0.05f) ++gradient_violations;  // Sharp edge
                    }

                    // ── Novel: 5×5 Depth Neighborhood Range ──
                    // Large depth range in local window = depth discontinuity.
                    // Phantoms form exclusively at these discontinuities.
                    // This catches phantoms that match the MEDIAN depth but
                    // are projecting to an ambiguous edge pixel.
                    float d_min = 1e10f, d_max = -1e10f;
                    for (int dy2 = -2; dy2 <= 2; ++dy2) {
                        for (int dx2 = -2; dx2 <= 2; ++dx2) {
                            const float d = kf.depth[(iv + dy2) * kf.width + (iu + dx2)];
                            if (d > 0.0f && d < 10.0f) {
                                if (d < d_min) d_min = d;
                                if (d > d_max) d_max = d;
                            }
                        }
                    }
                    ++edge_range_checked;
                    if (d_max - d_min > 0.08f) {  // >8cm range → depth edge
                        ++edge_range_violations;
                    }
                }
            }

            if (!strict_depth_filter) {
                if (checked == 0) {
                    depth_passed.push_back(cand);
                } else {
                    const float cr = static_cast<float>(consistent)
                                   / static_cast<float>(checked);
                    if (cr >= 0.20f || consistent >= 1) {
                        depth_passed.push_back(cand);
                    } else {
                        ++depth_rejected;
                    }
                }
                continue;
            }

            // ── Multi-criteria phantom rejection (viewpoint-adaptive) ──
            // Novel filters are most effective for SINGLE-VIEWPOINT scanning
            // where traditional consistency lacks angular diversity.
            // For multi-viewpoint scanning, different viewpoints legitimately
            // see different surfaces at the same pixel → novel filters would
            // cause false positives. So they're only enabled when keyframes
            // are clustered (all facing roughly the same direction).
            bool novel_reject = false;

            if (clustered_viewpoints) {
                // Signal A: Free-space carving (strongest independent signal)
                // If tile is BEHIND the observed surface from ≥15% of keyframes,
                // it occupies free space where no real geometry can exist.
                // A real surface cannot be behind another at the same pixel
                // from the same viewpoint.
                if (checked >= 2 && freespace_violations > 0) {
                    const float fs_ratio = static_cast<float>(freespace_violations)
                                         / static_cast<float>(checked);
                    if (fs_ratio >= 0.15f) novel_reject = true;
                }

                // Signal B: Temporal depth variance (catches edge phantoms)
                // Variance > 0.0008 m² (σ > 2.8cm) = bimodal depth → phantom.
                // Real surfaces: variance ≈ (5mm noise)² = 2.5e-5 (100× lower).
                if (checked >= 3 && !novel_reject) {
                    const float mean_d = depth_diff_sum / static_cast<float>(checked);
                    const float var = depth_diff_sq_sum / static_cast<float>(checked)
                                    - mean_d * mean_d;
                    if (var > 0.0008f) novel_reject = true;
                }

                // Signal C: Depth gradient + borderline consistency
                // Phantoms form at depth discontinuities; high gradient + poor
                // consistency from the same viewpoint = definitive phantom.
                if (gradient_checked >= 2 && !novel_reject) {
                    const float gr = static_cast<float>(gradient_violations)
                                   / static_cast<float>(gradient_checked);
                    if (gr >= 0.5f && checked >= 2) {
                        const float cr = static_cast<float>(consistent)
                                       / static_cast<float>(checked);
                        if (cr < 0.6f) novel_reject = true;
                    }
                }

                // Signal D: Signed mean depth bias (Bylow et al., 2013)
                // If the tile is SYSTEMATICALLY deeper than the observed depth,
                // it's behind the real surface. Mean bias > 1.5cm from single
                // viewpoint = phantom (real surfaces have ≈0 bias ±5mm noise).
                if (checked >= 3 && !novel_reject) {
                    const float mean_bias = depth_diff_sum / static_cast<float>(checked);
                    if (mean_bias > 0.015f) novel_reject = true;
                }

                // Signal E: Symmetric free-space (tile in FRONT of surface)
                // If ≥15% of keyframes show the tile in front of the observed
                // surface, the tile should be blocking the camera's view but
                // isn't → phantom.
                if (checked >= 2 && front_violations > 0 && !novel_reject) {
                    const float fv_ratio = static_cast<float>(front_violations)
                                         / static_cast<float>(checked);
                    if (fv_ratio >= 0.15f) novel_reject = true;
                }

                // Signal F: Tight-tolerance consistency (2cm instead of 5cm)
                // From a single viewpoint, real tiles should match depth within
                // 2cm (noise ≈ 5mm). The default 5cm tolerance is too generous
                // and lets many phantoms through. Real tiles at true surfaces
                // have ~90% tight consistency. Require ≥60% for single viewpoint.
                if (checked >= 3 && !novel_reject) {
                    const float tight_cr = static_cast<float>(tight_consistent)
                                         / static_cast<float>(checked);
                    if (tight_cr < 0.60f) novel_reject = true;
                }

                // Signal G: 5×5 Depth edge range + imperfect tight consistency
                // If the tile projects to a depth discontinuity from ≥50% of
                // keyframes AND tight consistency < 85%, it's a phantom at an
                // edge that happens to match the median depth but not precisely.
                // Real surface tiles at edges have tight consistency >90% because
                // they're ON the actual surface (depth matches to noise level).
                if (edge_range_checked >= 2 && !novel_reject) {
                    const float er = static_cast<float>(edge_range_violations)
                                   / static_cast<float>(edge_range_checked);
                    if (er >= 0.5f && checked >= 3) {
                        const float tight_cr = static_cast<float>(tight_consistent)
                                             / static_cast<float>(checked);
                        if (tight_cr < 0.85f) novel_reject = true;
                    }
                }

                // Signal H: Low visibility from clustered viewpoints.
                // From a fixed camera pose, legitimate tiles should be visible in
                // most keyframes. If < 60% of keyframes see the tile, it's at an
                // extreme position (likely a phantom at the edge of the FOV).
                if (!novel_reject && depth_keyframes_.size() >= 10) {
                    const float visibility = static_cast<float>(checked)
                                           / static_cast<float>(depth_keyframes_.size());
                    if (visibility < 0.60f) novel_reject = true;
                }

                // Signal I: Moderate free-space + positive depth bias.
                // fs >= 10% alone is too aggressive (catches some edge tiles with
                // negative bias in multi-view). But fs >= 10% combined with
                // positive bias (tile behind surface) is a strong phantom indicator.
                if (checked >= 3 && !novel_reject) {
                    const float fs2 = static_cast<float>(freespace_violations)
                                    / static_cast<float>(checked);
                    const float mean_b = depth_diff_sum / static_cast<float>(checked);
                    if (fs2 >= 0.10f && mean_b > 0.001f) novel_reject = true;
                }
            }

            // Signal J: Universal free-space + low tight consistency.
            // Applies to ALL viewpoint types (clustered AND non-clustered).
            // In multi-view scanning, phantoms at depth edges get ~40% basic
            // consistency (passing the threshold) but have high free-space
            // violations and low tight consistency. Real surface tiles at box
            // edges have fs ~20-25% and tight_cr ~50-70%, so thresholds are
            // tuned above those: fs >= 30% AND tight_cr < 55%.
            if (!novel_reject && checked >= 3) {
                const float fs_j = static_cast<float>(freespace_violations)
                                 / static_cast<float>(checked);
                const float tcr_j = static_cast<float>(tight_consistent)
                                  / static_cast<float>(checked);
                if (fs_j >= 0.30f && tcr_j < 0.55f) novel_reject = true;
            }

            // NOTE: Flying pixel phantom filtering is handled upstream by
            // reducing CONFIDENCE_WEIGHT_MID in TSDF integration, not here.

            if (novel_reject) {
                ++depth_rejected;
            } else if (checked < 3) {
                ++depth_rejected;
            } else if (static_cast<float>(consistent) / static_cast<float>(checked) >= 0.35f) {
                OverlayCandidate passed = cand;
                passed.support_views = static_cast<float>(consistent);
                depth_passed.push_back(std::move(passed));
            } else {
                ++depth_rejected;
            }
        }

        candidates = std::move(depth_passed);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MONOTONIC TILE CONFIRMATION + GRID-CENTER SNAPPING
    //
    // 1. New tiles that pass depth filter → confirmed (permanent)
    // 2. All confirmed tiles → emit with grid-center position (clean grid)
    // 3. Quality only increases (Lyapunov monotonic)
    // This prevents visual "state regression" where tiles flicker/disappear.
    // ═══════════════════════════════════════════════════════════════════

    // Confirm newly-passed tiles
    for (const auto& c : candidates) {
        auto conf_it = confirmed_overlay_cells_.find(c.grid_key_val);
        if (conf_it == confirmed_overlay_cells_.end()) {
            // New confirmation: keep grid regularity but clamp toward observed surface.
            ConfirmedTile ct;
            const float center_x = (static_cast<float>(c.gx) + 0.5f) * kGridCell;
            const float center_y = (static_cast<float>(c.gy) + 0.5f) * kGridCell;
            const float center_z = (static_cast<float>(c.gz) + 0.5f) * kGridCell;
            float ox = c.vertex.position[0] - center_x;
            float oy = c.vertex.position[1] - center_y;
            float oz = c.vertex.position[2] - center_z;
            const float offset_len = std::sqrt(ox * ox + oy * oy + oz * oz);
            const float max_offset = kGridCell * 0.18f;
            if (offset_len > max_offset && offset_len > 1e-6f) {
                const float inv = max_offset / offset_len;
                ox *= inv;
                oy *= inv;
                oz *= inv;
            }
            ct.position[0] = center_x + ox;
            ct.position[1] = center_y + oy;
            ct.position[2] = center_z + oz;
            ct.normal[0] = c.nnx;
            ct.normal[1] = c.nny;
            ct.normal[2] = c.nnz;
            ct.quality = c.vertex.quality;
            ct.support_count = std::max(1.0f, c.support_views);
            ct.stability = std::min(1.0f, 0.2f + 0.1f * ct.support_count);
            ct.last_update_ts = frame_input.timestamp;
            confirmed_overlay_cells_[c.grid_key_val] = ct;
        } else {
            // Already confirmed (shouldn't happen but safe)
            if (c.vertex.quality > conf_it->second.quality) {
                conf_it->second.quality = c.vertex.quality;
            }
        }
    }

    // Emit ALL confirmed tiles (monotonic — never fewer than before)
    // Apply frustum culling for rendering efficiency
    struct SortableVertex {
        OverlayVertex vertex;
        float dist_sq;
    };
    std::vector<SortableVertex> output;
    output.reserve(confirmed_overlay_cells_.size());
    std::size_t fallback_emitted = 0;

    for (const auto& [key, ct] : confirmed_overlay_cells_) {
        const bool seen_this_frame =
            current_frame_cells.find(key) != current_frame_cells.end();
        const double staleness = frame_input.timestamp - ct.last_update_ts;
        const double hold_seconds =
            0.30 + 0.45 * static_cast<double>(std::clamp(ct.stability, 0.0f, 1.0f));
        // Confirmed tiles persist briefly even without a fresh hit, which prevents
        // flicker and gives low-motion windows enough continuity for P2/P3 checks.
        if (!bootstrap_overlay_mode &&
            !seen_this_frame &&
            staleness > hold_seconds) continue;

        // Frustum culling
        float dx = ct.position[0] - cx;
        float dy = ct.position[1] - cy;
        float dz = ct.position[2] - cz;
        float dsq = dx * dx + dy * dy + dz * dz;
        if ((!bootstrap_overlay_mode && dsq > 36.0f) ||
            (bootstrap_overlay_mode && dsq > 144.0f)) continue;
        float d = std::sqrt(dsq);
        if (!bootstrap_overlay_mode && d > 1e-6f) {
            float cos_a = (dx * fwd_x + dy * fwd_y + dz * fwd_z) / d;
            if (cos_a < kFrustumCosCutoff) continue;
        }

        SortableVertex sv;
        sv.vertex.position[0] = ct.position[0];
        sv.vertex.position[1] = ct.position[1];
        sv.vertex.position[2] = ct.position[2];
        sv.vertex.normal[0] = ct.normal[0];
        sv.vertex.normal[1] = ct.normal[1];
        sv.vertex.normal[2] = ct.normal[2];
        sv.vertex.size = kTileHalf;
        sv.vertex.quality = ct.quality;
        sv.dist_sq = dsq;
        output.push_back(sv);
    }

    // Warmup fallback: if strict confirmation chain produced no tiles,
    // emit a conservative subset directly from TSDF samples so HUD does not stall at 0.
    if (output.empty() && !samples.empty()) {
        std::vector<SortableVertex> fallback;
        fallback.reserve(std::min<std::size_t>(samples.size(), 2000));
        for (const auto& s : samples) {
            if (s.occupied_count < 2) continue;
            if (!s.has_surface && s.avg_weight < 0.35f) continue;
            if (s.composite_quality < 0.002f) continue;

            const float px = s.has_surface ? s.surface_center[0] : s.center[0];
            const float py = s.has_surface ? s.surface_center[1] : s.center[1];
            const float pz = s.has_surface ? s.surface_center[2] : s.center[2];
            float dx = px - cx;
            float dy = py - cy;
            float dz = pz - cz;
            float dsq = dx * dx + dy * dy + dz * dz;
            if ((!bootstrap_overlay_mode && dsq > 36.0f) ||
                (bootstrap_overlay_mode && dsq > 144.0f)) continue;
            float d = std::sqrt(dsq);
            if (!bootstrap_overlay_mode && d > 1e-6f) {
                float cos_a = (dx * fwd_x + dy * fwd_y + dz * fwd_z) / d;
                if (cos_a < kFrustumCosCutoff) continue;
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

            SortableVertex sv;
            sv.vertex.position[0] = px;
            sv.vertex.position[1] = py;
            sv.vertex.position[2] = pz;
            sv.vertex.normal[0] = nx;
            sv.vertex.normal[1] = ny;
            sv.vertex.normal[2] = nz;
            sv.vertex.size = kTileHalf;
            sv.vertex.quality = std::clamp(s.composite_quality, 0.0f, 0.95f);
            sv.dist_sq = dsq;
            fallback.push_back(sv);
            if (fallback.size() >= 2000) break;
        }
        if (!fallback.empty()) {
            output.swap(fallback);
            fallback_emitted = output.size();
        }
    }

    // Sort nearest-first (GPU z-culling optimization).
    if (output.size() < 15000) {
        std::sort(output.begin(), output.end(),
            [](const SortableVertex& a, const SortableVertex& b) {
                return a.dist_sq < b.dist_sq;
            });
    }

    pc_data.overlay.reserve(output.size());
    for (const auto& sv : output) {
        pc_data.overlay.push_back(sv.vertex);
    }

    // Diagnostic: log grid merge stats periodically
    {
        static std::uint32_t ovl_diag = 0;
        ovl_diag++;
        if (ovl_diag <= 5 || ovl_diag % 30 == 0) {
            std::fprintf(stderr,
                "[Aether3D][Overlay] #%u: samples=%zu merged=%zu cand=%zu emit=%zu "
                "confirmed=%zu warmup=%d strictDepth=%d "
                "(sparse=%zu no_surf=%zu low_q=%zu isolated=%zu depth_rej=%zu "
                "fallback=%zu kf=%zu) "
                "throttle=%dms\n",
                ovl_diag, samples.size(), merged_count, candidates.size(), output.size(),
                confirmed_overlay_cells_.size(),
                warmup_overlay ? 1 : 0, strict_depth_filter ? 1 : 0,
                skipped_sparse, skipped_no_surface, skipped_low_q, skipped_isolated,
                depth_rejected, fallback_emitted, depth_keyframes_.size(), throttle_ms);
        }
    }

    // ── Coverage Point Cloud: surface-snapped dots colored by TSDF weight ──
    // Shows user WHERE to scan more (red=unseen → green=well-covered → invisible=done).
    // Uses surface_center (SDF zero-crossing) for precise surface snapping.
    // Non-reversible: TSDF avg_weight only ever increases.
    pc_data.vertices.clear();
    pc_data.vertices.reserve(std::min(samples.size(), std::size_t(100000)));
    for (const auto& s : samples) {
        if (s.occupied_count < 2) continue;
        const float w = s.avg_weight;
        // Fade out completely once well-covered (weight >= 20)
        float pt_alpha = 1.0f - std::clamp(w / 20.0f, 0.0f, 1.0f);
        if (pt_alpha < 0.05f) continue;
        // Color ramp: red → orange → yellow → green
        float r, g, b;
        if (w < 2.0f) {
            r = 1.0f; g = 0.2f; b = 0.1f;
        } else if (w < 5.0f) {
            const float t = (w - 2.0f) / 3.0f;
            r = 1.0f; g = 0.2f + 0.5f * t; b = 0.1f;
        } else if (w < 10.0f) {
            const float t = (w - 5.0f) / 5.0f;
            r = 1.0f - 0.5f * t; g = 0.7f + 0.3f * t; b = 0.1f;
        } else {
            const float t = std::clamp((w - 10.0f) / 10.0f, 0.0f, 1.0f);
            r = 0.5f - 0.4f * t; g = 1.0f; b = 0.1f + 0.3f * t;
        }
        PointCloudVertex v;
        v.position[0] = s.has_surface ? s.surface_center[0] : s.center[0];
        v.position[1] = s.has_surface ? s.surface_center[1] : s.center[1];
        v.position[2] = s.has_surface ? s.surface_center[2] : s.center[2];
        v.color[0] = r; v.color[1] = g; v.color[2] = b;
        v.size = 10.0f;
        v.alpha = pt_alpha;
        pc_data.vertices.push_back(v);
    }

    // Update timestamp AFTER expensive work so next call measures elapsed from COMPLETION.
    // If updated before, elapsed = rebuild_time (3-5s) >> throttle_ms → always rebuilds.
    overlay_last_gen_time_ = std::chrono::steady_clock::now();

    // Cache for subsequent frames within throttle window
    overlay_cache_ = pc_data.overlay;
}

void PipelineCoordinator::signal_viewer_entered() noexcept {
    // Global training: no per-region animations.
    // Splats are progressively visible via push_splats() in training_thread_func.
    std::fprintf(stderr, "[Aether3D] Viewer entered (global training mode)\n");
}

void PipelineCoordinator::set_foreground_active(bool active) noexcept {
    foreground_active_.store(active, std::memory_order_release);
}

// ═══════════════════════════════════════════════════════════════════════
// Thread Lifecycle
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::start_threads() noexcept {
    running_.store(true, std::memory_order_release);
    scanning_active_.store(true, std::memory_order_release);
    foreground_active_.store(true, std::memory_order_release);
    if (config_.local_preview_mode) {
        preview_started_at_ = std::chrono::steady_clock::now();
    }

    frame_thread_ = std::thread(&PipelineCoordinator::frame_thread_func, this);
    evidence_thread_ = std::thread(&PipelineCoordinator::evidence_thread_func, this);
    training_thread_ = std::thread(&PipelineCoordinator::training_thread_func, this);
}

// ═══════════════════════════════════════════════════════════════════════
// GSFusion per-frame quadtree Gaussian seeding
// ═══════════════════════════════════════════════════════════════════════
// Directly adapted from GSFusion (BSD-3-Clause):
//   Smart Robotics Lab, TU Munich / Jiaxin Wei (2024)
//
// For each incoming depth+RGB frame:
//   1. Build adaptive quadtree on RGB image (high-variance regions → small cells)
//   2. Backproject each leaf centre through depth → world 3D position
//   3. Deduplicate at 5mm spatial hash cells (gsf_seeded_cells_)
//   4. Compute Gaussian scale = depth × sqrt((w/2)² + (h/2)²) / fx  (GSFusion verbatim)
//   5. Push new GaussianParams to pending_gaussians_ under training_mutex_
//
// Camera convention (ARKit, column-major cam2world):
//   col0 = right (+X), col1 = up (+Y), col2 = -forward (backward = +Z)
//   Backproject: p_world = cam_pos + (u-cx)/fx*d*col0 - (v-cy)/fy*d*col1 - d*col2
void PipelineCoordinator::seed_gaussians_per_frame_gsf(
    const unsigned char* bgra, int img_w, int img_h,
    const float* depth, int depth_w, int depth_h,
    float fx, float fy, float cx, float cy,
    const float* cam2world,
    bool imported_video) noexcept
{
    if (!bgra || !depth || img_w <= 0 || img_h <= 0 || depth_w <= 0 || depth_h <= 0) return;

    if (config_.local_preview_mode && imported_video) {
        return;
    }

    // GSFusion parameters (from default JSON / tested thresholds)
    constexpr float kQtreeThreshold  = 0.001f;  // scaled for 192×144 (GSFusion: 0.1 @ full-res)
    constexpr int   kQtreeMinPixelSz = 2;        // min leaf dimension (pixels)
    constexpr float kNearPlane       = 0.10f;    // metres
    constexpr float kFarPlane        = 5.00f;    // metres
    constexpr float kHashCell        = 0.005f;   // 5mm dedup grid
    constexpr float kHashInv         = 1.0f / kHashCell;
    constexpr float kMinScale        = 0.001f;
    constexpr float kMaxScale        = 0.50f;

    // Extract cam2world columns (column-major layout: M[col*4 + row])
    const float c0x = cam2world[0], c0y = cam2world[1], c0z = cam2world[2];  // right
    const float c1x = cam2world[4], c1y = cam2world[5], c1z = cam2world[6];  // up
    const float c2x = cam2world[8], c2y = cam2world[9], c2z = cam2world[10]; // -fwd
    const float  tx = cam2world[12], ty = cam2world[13], tz = cam2world[14];  // pos

    if (config_.local_preview_mode) {
        const bool init_pass =
            preview_seed_accepted_.load(std::memory_order_relaxed) == 0;
        std::vector<splat::GaussianParams> new_gaussians;
        new_gaussians.reserve(1536u);
        const PreviewSeedStats stats = build_preview_sampled_seeds_from_depth(
            bgra,
            img_w,
            img_h,
            depth,
            depth_w,
            depth_h,
            fx,
            fy,
            cx,
            cy,
            cam2world,
            init_pass,
            gsf_seeded_cells_,
            new_gaussians);

        preview_seed_candidates_.fetch_add(stats.candidates, std::memory_order_relaxed);
        preview_seed_accepted_.fetch_add(stats.accepted, std::memory_order_relaxed);
        preview_seed_rejected_.fetch_add(stats.rejected, std::memory_order_relaxed);
        preview_seed_quality_milli_sum_.fetch_add(
            stats.accepted_quality_milli_sum,
            std::memory_order_relaxed);

        if (new_gaussians.empty()) {
            return;
        }

        {
            std::lock_guard<std::mutex> lock(training_mutex_);
            pending_gaussians_.insert(
                pending_gaussians_.end(),
                new_gaussians.begin(),
                new_gaussians.end());
        }

        static std::size_t preview_seed_total = 0;
        preview_seed_total += new_gaussians.size();
        if (preview_seed_total <= 50000u || preview_seed_total % 100000u < new_gaussians.size()) {
            std::fprintf(stderr,
                "[Aether3D][PreviewSeed] +%zu seeds (sampled=%u accepted=%zu init=%d downsample=%u median_depth=%.3f total=%zu dedup_cells=%zu)\n",
                new_gaussians.size(),
                stats.candidates,
                new_gaussians.size(),
                stats.init_pass ? 1 : 0,
                stats.downsample_factor,
                stats.median_depth,
                preview_seed_total,
                gsf_seeded_cells_.size());
        }
        return;
    }

    // GSFusion error scale: img_w × img_h / 90_000_000
    const float img_scale = static_cast<float>(img_w * img_h) / 90000000.0f;

    // Step 1: build quadtree leaves
    std::vector<GsfQTLeaf> leaves;
    leaves.reserve(4096);
    gsf_qtree_subdivide(bgra, img_w, 0, 0, img_w, img_h,
                        kQtreeThreshold, kQtreeMinPixelSz, img_scale, leaves);

    std::vector<splat::GaussianParams> new_gaussians;
    new_gaussians.reserve(leaves.size() / 2);

    // Step 2-4: backproject each leaf centre, dedup, compute scale
    for (const auto& leaf : leaves) {
        // Leaf centre in image space
        const int u = leaf.x0 + leaf.w / 2;
        const int v = leaf.y0 + leaf.h / 2;

        // Map to depth image coords (may differ in resolution from RGB)
        const int du = (depth_w == img_w) ? u : u * depth_w / img_w;
        const int dv = (depth_h == img_h) ? v : v * depth_h / img_h;
        if (du < 0 || du >= depth_w || dv < 0 || dv >= depth_h) continue;

        const float d = depth[dv * depth_w + du];
        if (d < kNearPlane || d > kFarPlane || !std::isfinite(d)) {
            continue;
        }

        // Backproject to world (ARKit convention: ray_z = -1, depth is z-depth)
        // p_cam = [(u-cx)/fx * d,  (v-cy)/fy * d,  -d]
        // p_world = cam_pos + p_cam.x*col0 - p_cam.y*col1 - (-p_cam.z)*col2
        //         = cam_pos + (u-cx)/fx*d * col0 - (v-cy)/fy*d * col1 - d * col2
        const float pc_x = (static_cast<float>(u) - cx) / fx * d;
        const float pc_y = (static_cast<float>(v) - cy) / fy * d;
        const float pw_x = tx + pc_x * c0x - pc_y * c1x - d * c2x;
        const float pw_y = ty + pc_x * c0y - pc_y * c1y - d * c2y;
        const float pw_z = tz + pc_x * c0z - pc_y * c1z - d * c2z;

        // Step 3: 5mm spatial hash dedup
        const auto hx = static_cast<std::int64_t>(std::floor(pw_x * kHashInv));
        const auto hy = static_cast<std::int64_t>(std::floor(pw_y * kHashInv));
        const auto hz = static_cast<std::int64_t>(std::floor(pw_z * kHashInv));
        const std::int64_t key = ((hx & 0xFFFFF) << 40) |
                                 ((hy & 0xFFFFF) << 20) |
                                  (hz & 0xFFFFF);
        if (gsf_seeded_cells_.count(key) > 0) {
            continue;
        }

        // Step 4: GSFusion scale = depth × |half_diagonal| / fx
        const float hw = static_cast<float>(leaf.w) * 0.5f;
        const float hh = static_cast<float>(leaf.h) * 0.5f;
        float scale = d * std::sqrt(hw * hw + hh * hh) / fx;
        scale = std::clamp(scale, kMinScale, kMaxScale);

        // Get linear RGB from BGRA pixel (sRGB → linear via LUT)
        const unsigned char* p = bgra + (v * img_w + u) * 4;
        const float r = g_srgb_lut.table[p[2]];
        const float g_val = g_srgb_lut.table[p[1]];
        const float b = g_srgb_lut.table[p[0]];

        // Build GaussianParams
        splat::GaussianParams gp{};
        gp.position[0] = pw_x;  gp.position[1] = pw_y;  gp.position[2] = pw_z;
        gp.color[0] = r;  gp.color[1] = g_val;  gp.color[2] = b;
        gp.opacity = 0.5f;
        gp.scale[0] = scale;  gp.scale[1] = scale;  gp.scale[2] = scale * 0.3f;
        gp.rotation[0] = 1.0f;  gp.rotation[1] = 0.0f;
        gp.rotation[2] = 0.0f;  gp.rotation[3] = 0.0f;
        // sh1 remains zero (DC-only initialisation)
        gsf_seeded_cells_.insert(key);
        new_gaussians.push_back(gp);
    }

    if (new_gaussians.empty()) return;

    // Step 5: push to training handoff under lock
    {
        std::lock_guard<std::mutex> lock(training_mutex_);
        pending_gaussians_.insert(pending_gaussians_.end(),
                                  new_gaussians.begin(), new_gaussians.end());
    }

    // Periodic diagnostic
    static std::size_t gsf_total = 0;
    gsf_total += new_gaussians.size();
    if (gsf_total <= 50000u || gsf_total % 100000u < new_gaussians.size()) {
        std::fprintf(stderr,
            "[Aether3D][GSFusion] +%zu seeds (%zu leaves → %zu new, "
            "gsf_total=%zu, dedup_cells=%zu)\n",
            new_gaussians.size(), leaves.size(), new_gaussians.size(),
            gsf_total, gsf_seeded_cells_.size());
    }
}

void PipelineCoordinator::stop_threads() noexcept {
    running_.store(false, std::memory_order_release);
    renderer_alive_.store(false, std::memory_order_release);

    // Signal training engine to bail out of train_step_gpu() immediately.
    // This prevents EXC_BAD_ACCESS if the GPU is mapping buffers during shutdown.
    if (training_engine_) {
        training_engine_->request_stop();
    }

    if (frame_thread_.joinable()) frame_thread_.join();
    if (evidence_thread_.joinable()) evidence_thread_.join();
    if (training_thread_.joinable()) training_thread_.join();
}

}  // namespace pipeline
}  // namespace aether
