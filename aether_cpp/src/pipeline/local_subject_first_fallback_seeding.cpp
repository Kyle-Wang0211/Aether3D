// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_fallback_seeding.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace pipeline {
namespace local_subject_first_fallback_seeding {
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

bool sample_selected_frame_color_linear(
    const SelectedFrame& frame,
    float wx,
    float wy,
    float wz,
    float out_rgb[3]) noexcept
{
    if (frame.rgba.empty() || frame.width == 0 || frame.height == 0) {
        return false;
    }

    const float dwx = wx - frame.transform[12];
    const float dwy = wy - frame.transform[13];
    const float dwz = wz - frame.transform[14];

    const float cam_x =
        frame.transform[0] * dwx + frame.transform[1] * dwy + frame.transform[2] * dwz;
    const float cam_y =
        -(frame.transform[4] * dwx + frame.transform[5] * dwy + frame.transform[6] * dwz);
    const float cam_z =
        -(frame.transform[8] * dwx + frame.transform[9] * dwy + frame.transform[10] * dwz);
    if (cam_z <= 0.1f) {
        return false;
    }

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

}  // namespace

TsdfFallbackSeedStats append_tsdf_fallback_gaussians(
    const std::vector<tsdf::SurfacePoint>& surface_points,
    const std::vector<SelectedFrame>& all_frames,
    std::vector<splat::GaussianParams>& out) noexcept
{
    TsdfFallbackSeedStats stats;
    if (surface_points.empty()) {
        return stats;
    }

    const std::size_t before = out.size();
    out.reserve(before + surface_points.size());

    for (const auto& surface_point : surface_points) {
        splat::GaussianParams gaussian{};
        gaussian.position[0] = surface_point.position[0];
        gaussian.position[1] = surface_point.position[1];
        gaussian.position[2] = surface_point.position[2];

        float sampled_rgb[3] = {0.0f, 0.0f, 0.0f};
        bool color_ok = false;
        for (auto it = all_frames.rbegin();
             it != all_frames.rend() && !color_ok;
             ++it) {
            color_ok = sample_selected_frame_color_linear(
                *it,
                gaussian.position[0],
                gaussian.position[1],
                gaussian.position[2],
                sampled_rgb);
        }
        if (color_ok) {
            gaussian.color[0] = sampled_rgb[0];
            gaussian.color[1] = sampled_rgb[1];
            gaussian.color[2] = sampled_rgb[2];
            stats.sampled_frame_colors++;
        } else {
            const float nx = std::fabs(surface_point.normal[0]);
            const float ny = std::fabs(surface_point.normal[1]);
            const float nz = std::fabs(surface_point.normal[2]);
            gaussian.color[0] = std::clamp(0.18f + 0.55f * nx, 0.0f, 1.0f);
            gaussian.color[1] = std::clamp(0.16f + 0.58f * ny, 0.0f, 1.0f);
            gaussian.color[2] = std::clamp(0.18f + 0.55f * nz, 0.0f, 1.0f);
            stats.shaded_fallback_colors++;
        }

        const float weight_norm = std::clamp(
            static_cast<float>(surface_point.weight) / 24.0f,
            0.0f,
            1.0f);
        gaussian.opacity = 0.20f + 0.70f * weight_norm;
        const float scale = std::clamp(
            0.004f + (1.0f - weight_norm) * 0.004f,
            0.003f,
            0.012f);
        gaussian.scale[0] = scale;
        gaussian.scale[1] = scale;
        gaussian.scale[2] = scale;
        gaussian.rotation[0] = 1.0f;
        gaussian.rotation[1] = 0.0f;
        gaussian.rotation[2] = 0.0f;
        gaussian.rotation[3] = 0.0f;
        out.push_back(gaussian);
    }

    stats.seeded = out.size() - before;
    return stats;
}

}  // namespace local_subject_first_fallback_seeding
}  // namespace pipeline
}  // namespace aether
