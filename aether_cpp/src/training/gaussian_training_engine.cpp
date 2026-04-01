// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/training/gaussian_training_engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <random>

#include "aether/render/gpu_command.h"
#include "aether/render/gpu_resource.h"
#include "aether/splat/gaussian_math.h"
#include "aether/splat/ply_loader.h"
#include "aether/training/depth_loss.h"
#include "aether/training/loss_functions.h"
#include "aether/training/mcmc_densifier.h"
#include "aether/training/steepgs_densifier.h"
#include "aether/training/student_t_primitive.h"

namespace aether {
namespace training {

// ─── sRGB → linear LUT: 256-entry float table replaces std::pow() ───
// Eliminates ~28ms/step of per-pixel pow(2.4) calls in target image prep.
// Formula: s <= 0.04045 ? s/12.92 : ((s+0.055)/1.055)^2.4
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
}  // anonymous namespace

// ─── Activation functions for logit/log reparameterization ───
// Opacity stored as logit(opacity), scale stored as log(scale).
// This prevents optimizer overshoot: sigmoid ∈ (0,1), exp > 0.
static inline float sigmoid(float x) noexcept {
    if (x >= 0.0f) {
        float e = std::exp(-x);
        return 1.0f / (1.0f + e);
    }
    float e = std::exp(x);
    return e / (1.0f + e);
}

static inline float logit(float p) noexcept {
    p = std::clamp(p, 0.001f, 0.999f);
    return std::log(p / (1.0f - p));
}

static inline float safe_log(float x) noexcept {
    return std::log(std::max(x, 1e-7f));
}

static inline std::uint8_t bilinear_sample_u8(
    const std::uint8_t* rgba,
    std::uint32_t w,
    std::uint32_t h,
    float x,
    float y,
    int channel) noexcept
{
    if (!rgba || w == 0 || h == 0) return 0;
    x = std::clamp(x, 0.0f, static_cast<float>(w - 1));
    y = std::clamp(y, 0.0f, static_cast<float>(h - 1));
    const std::uint32_t x0 = static_cast<std::uint32_t>(x);
    const std::uint32_t y0 = static_cast<std::uint32_t>(y);
    const std::uint32_t x1 = std::min(x0 + 1, w - 1);
    const std::uint32_t y1 = std::min(y0 + 1, h - 1);
    const float fx = x - static_cast<float>(x0);
    const float fy = y - static_cast<float>(y0);
    const float v00 = rgba[(y0 * w + x0) * 4 + channel];
    const float v10 = rgba[(y0 * w + x1) * 4 + channel];
    const float v01 = rgba[(y1 * w + x0) * 4 + channel];
    const float v11 = rgba[(y1 * w + x1) * 4 + channel];
    const float val = v00 * (1.0f - fx) * (1.0f - fy) +
                      v10 * fx * (1.0f - fy) +
                      v01 * (1.0f - fx) * fy +
                      v11 * fx * fy;
    return static_cast<std::uint8_t>(std::clamp(val, 0.0f, 255.0f));
}

GaussianTrainingEngine::GaussianTrainingEngine(
    render::GPUDevice& device,
    const TrainingConfig& config) noexcept
    : device_(device), config_(config) {
    if (config_.align_to_baseline_3dgs) {
        use_student_t_ = false;
        use_mcmc_noise_ = false;
        use_steepgs_ = false;
    }

    // B1: Select device preset based on GPU capabilities.
    // This adapts training parameters (max primitives, resolution, iterations,
    // temporal window, etc.) to the device's available RAM/GPU tier.
    auto caps = device_.capabilities();
    if (caps.max_buffer_size > 0) {
        // Estimate available RAM from max buffer size (heuristic: RAM ≈ 4× max buffer).
        // Promote to 64-bit first so 3GB-class max buffer values do not overflow to 0.
        std::size_t estimated_ram =
            static_cast<std::size_t>(caps.max_buffer_size) * 4ULL;
        preset_ = select_preset(estimated_ram);
    } else {
        // Fallback: assume 4GB mobile device (most conservative)
        preset_ = preset_mobile_4gb();
    }

    // Apply preset overrides to config.
    // max_primitives is treated as a soft target for mobile throughput, not a hard
    // stop. The real ceiling comes from memory budget + GPU buffer limits below.
    if (config_.max_iterations < preset_.max_iterations) {
        config_.max_iterations = preset_.max_iterations;
    }

    if (config_.align_to_baseline_3dgs) {
        preset_.opacity_reset_interval = 0;
    }

    // Initialize memory budget controller from device RAM.
    // Training fraction = 0.45 is conservative (iOS system ~2GB, TSDF ~300MB, etc.)
    {
        std::size_t device_ram = 8ULL * 1024 * 1024 * 1024;  // default 8GB
        if (caps.max_buffer_size > 0) {
            device_ram = static_cast<std::size_t>(caps.max_buffer_size) * 4ULL;
            if (device_ram == 0) {
                device_ram = 8ULL * 1024 * 1024 * 1024;
            }
        }
        memory_budget_ = MemoryBudgetController(
            static_cast<std::uint64_t>(device_ram), 0.45f);
    }

    const std::size_t mem_cap_full = memory_budget_.max_gaussians(MemoryMode::kFull);
    if (mem_cap_full > 0 && config_.max_gaussians > mem_cap_full) {
        config_.max_gaussians = mem_cap_full;
    }

    std::fprintf(stderr, "[Aether3D][Training] Device preset: max_prims=%u, "
                 "res=%ux%u, max_iter=%u, window=%u, focal_prob=%.2f, "
                 "mem_budget=%zuMB, max_G(full)=%zuK, max_G(compact)=%zuK\n",
                 preset_.max_primitives,
                 preset_.render_width, preset_.render_height,
                 preset_.max_iterations,
                 preset_.temporal_window_size,
                 preset_.focal_sampling_prob,
                 memory_budget_.budget_bytes() / (1024 * 1024),
                 memory_budget_.max_gaussians(MemoryMode::kFull) / 1000,
                 memory_budget_.max_gaussians(MemoryMode::kCompact) / 1000);
    if (config_.align_to_baseline_3dgs) {
        std::fprintf(stderr,
            "[Aether3D][Training] baseline_3dgs semantics: Student-t/MCMC/SteepGS "
            "disabled, opacity reset disabled, anchor/color hard guards bypassed\n");
    }
}

GaussianTrainingEngine::~GaussianTrainingEngine() noexcept {
    // GPU resources cleaned up by GPUDevice
}

// ─── Data Management ─────────────────────────────────────────────────

core::Status GaussianTrainingEngine::set_initial_point_cloud(
    const splat::GaussianParams* pts, std::size_t count) noexcept
{
    if (!pts || count == 0) return core::Status::kInvalidArgument;
    if (count > config_.max_gaussians) {
        count = config_.max_gaussians;
    }

    num_gaussians_ = count;
    params_.resize(count * kParamsPerGaussian);
    gradients_.resize(count * kParamsPerGaussian, 0.0f);
    screen_grad_accum_.resize(count, 0.0f);
    grad_count_.resize(count, 0);

    // C1: Initialize Student-t nu parameters.
    // Default log_nu = 1.0 → nu = exp(1)+2 ≈ 4.72 (moderate heavy-tail).
    // The network will learn optimal nu per primitive during training.
    if (use_student_t_) {
        nu_params_.assign(count, 1.0f);   // log(nu-2), nu ≈ 4.72
        nu_grad_.assign(count, 0.0f);
        nu_m1_.assign(count, 0.0f);
        nu_m2_.assign(count, 0.0f);
    }

    // C2b: SteepGS state for Hessian estimation
    if (use_steepgs_) {
        prev_position_grad_.assign(count * 3, 0.0f);
        prev_position_.assign(count * 3, 0.0f);
    }

    params_to_flat(pts, count);
    optimizer_.resize(count);

    // Store initial positions for anchor regularization
    anchor_positions_.resize(count * 3);
    for (std::size_t i = 0; i < count; ++i) {
        anchor_positions_[i * 3 + 0] = pts[i].position[0];
        anchor_positions_[i * 3 + 1] = pts[i].position[1];
        anchor_positions_[i * 3 + 2] = pts[i].position[2];
    }

    // Create GPU resources
    return create_gpu_resources();
}

void GaussianTrainingEngine::add_training_frame(
    const std::uint8_t* rgba,
    std::uint32_t w, std::uint32_t h,
    const float transform[16],
    const float intrinsics[4],
    float quality_weight,
    double timestamp,
    std::uint64_t frame_index,
    const float* ref_depth,
    std::uint32_t ref_depth_w,
    std::uint32_t ref_depth_h,
    const float* lidar_depth,
    std::uint32_t lidar_w,
    std::uint32_t lidar_h) noexcept
{
    TrainingFrame frame;

    // Pre-scale RGBA to render resolution at storage time.
    // Saves ~10.5MB/frame (11MB full → 0.5MB scaled) and eliminates
    // per-step nearest-neighbor downsampling in train_step().
    const std::uint32_t tw = preset_.render_width  > 0 ? preset_.render_width  : config_.render_width;
    const std::uint32_t th = preset_.render_height > 0 ? preset_.render_height : config_.render_height;

    if (tw > 0 && th > 0 && (w != tw || h != th) && w > 0 && h > 0) {
        // Bilinear downsample to training resolution
        frame.rgba.resize(tw * th * 4);
        const float sx = static_cast<float>(w) / tw;
        const float sy = static_cast<float>(h) / th;
        for (std::uint32_t dy = 0; dy < th; ++dy) {
            const float src_y = dy * sy;
            const std::uint32_t y0 = std::min(static_cast<std::uint32_t>(src_y), h - 1);
            const std::uint32_t y1 = std::min(y0 + 1, h - 1);
            const float fy = src_y - y0;
            for (std::uint32_t dx = 0; dx < tw; ++dx) {
                const float src_x = dx * sx;
                const std::uint32_t x0 = std::min(static_cast<std::uint32_t>(src_x), w - 1);
                const std::uint32_t x1 = std::min(x0 + 1, w - 1);
                const float fx = src_x - x0;
                for (int c = 0; c < 4; ++c) {
                    float v00 = rgba[(y0 * w + x0) * 4 + c];
                    float v10 = rgba[(y0 * w + x1) * 4 + c];
                    float v01 = rgba[(y1 * w + x0) * 4 + c];
                    float v11 = rgba[(y1 * w + x1) * 4 + c];
                    float val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                                v01 * (1 - fx) * fy + v11 * fx * fy;
                    frame.rgba[((dy * tw) + dx) * 4 + c] =
                        static_cast<std::uint8_t>(std::clamp(val, 0.0f, 255.0f));
                }
            }
        }
        // Scale intrinsics to match new resolution
        float scale_intrinsics[4] = {
            intrinsics[0] * tw / static_cast<float>(w),
            intrinsics[1] * th / static_cast<float>(h),
            intrinsics[2] * tw / static_cast<float>(w),
            intrinsics[3] * th / static_cast<float>(h)
        };
        frame.width = tw;
        frame.height = th;
        std::memcpy(frame.transform, transform, sizeof(float) * 16);
        std::memcpy(frame.intrinsics, scale_intrinsics, sizeof(float) * 4);
    } else {
        frame.rgba.assign(rgba, rgba + w * h * 4);
        frame.width = w;
        frame.height = h;
        std::memcpy(frame.transform, transform, sizeof(float) * 16);
        std::memcpy(frame.intrinsics, intrinsics, sizeof(float) * 4);
    }
    frame.quality_weight = quality_weight;
    if (quality_weight >= 0.90f) {
        frame.remaining_times_of_use = 5;
    } else if (quality_weight >= 0.75f) {
        frame.remaining_times_of_use = 4;
    } else if (quality_weight >= 0.55f) {
        frame.remaining_times_of_use = 3;
    } else {
        frame.remaining_times_of_use = 2;
    }
    // Bug 0.26 fix: preserve temporal metadata
    frame.timestamp = timestamp;
    frame.frame_index = frame_index;

    // B6: Store DAv2 reference depth for Pearson depth supervision (100% experience)
    if (ref_depth && ref_depth_w > 0 && ref_depth_h > 0) {
        std::size_t depth_pixels = static_cast<std::size_t>(ref_depth_w) * ref_depth_h;
        frame.ref_depth.assign(ref_depth, ref_depth + depth_pixels);
        frame.ref_depth_w = ref_depth_w;
        frame.ref_depth_h = ref_depth_h;
    }

    // Store LiDAR metric depth for L1 depth supervision (120% enhancement, Pro only)
    if (lidar_depth && lidar_w > 0 && lidar_h > 0) {
        std::size_t lidar_pixels = static_cast<std::size_t>(lidar_w) * lidar_h;
        frame.lidar_depth.assign(lidar_depth, lidar_depth + lidar_pixels);
        frame.lidar_w = lidar_w;
        frame.lidar_h = lidar_h;
    }

    build_training_pyramid(frame);
    frames_.push_back(std::move(frame));
    trim_training_frames();
}

void GaussianTrainingEngine::build_training_pyramid(TrainingFrame& frame) const noexcept {
    frame.pyramid_rgba.clear();
    frame.pyramid_widths.clear();
    frame.pyramid_heights.clear();

    if (frame.rgba.empty() || frame.width == 0 || frame.height == 0) return;

    frame.pyramid_rgba.push_back(frame.rgba);
    frame.pyramid_widths.push_back(frame.width);
    frame.pyramid_heights.push_back(frame.height);

    constexpr std::size_t kMaxLevels = 3;
    while (frame.pyramid_rgba.size() < kMaxLevels) {
        const std::uint32_t src_w = frame.pyramid_widths.back();
        const std::uint32_t src_h = frame.pyramid_heights.back();
        if (src_w <= 128 || src_h <= 128) break;

        const std::uint32_t dst_w = std::max<std::uint32_t>(src_w / 2, 1);
        const std::uint32_t dst_h = std::max<std::uint32_t>(src_h / 2, 1);
        const auto& src = frame.pyramid_rgba.back();
        std::vector<std::uint8_t> dst(static_cast<std::size_t>(dst_w) * dst_h * 4);

        const float sx = static_cast<float>(src_w) / static_cast<float>(dst_w);
        const float sy = static_cast<float>(src_h) / static_cast<float>(dst_h);
        for (std::uint32_t y = 0; y < dst_h; ++y) {
            for (std::uint32_t x = 0; x < dst_w; ++x) {
                const float src_x = (static_cast<float>(x) + 0.5f) * sx - 0.5f;
                const float src_y = (static_cast<float>(y) + 0.5f) * sy - 0.5f;
                for (int c = 0; c < 4; ++c) {
                    dst[(static_cast<std::size_t>(y) * dst_w + x) * 4 + c] =
                        bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, c);
                }
            }
        }

        frame.pyramid_rgba.push_back(std::move(dst));
        frame.pyramid_widths.push_back(dst_w);
        frame.pyramid_heights.push_back(dst_h);
    }
}

std::size_t GaussianTrainingEngine::select_pyramid_level(
    const TrainingFrame& frame,
    std::uint32_t target_w,
    std::uint32_t target_h) const noexcept
{
    if (frame.pyramid_rgba.empty()) return 0;

    std::size_t best = 0;
    std::uint64_t best_score = std::numeric_limits<std::uint64_t>::max();
    for (std::size_t i = 0; i < frame.pyramid_rgba.size(); ++i) {
        const std::uint32_t pw = frame.pyramid_widths[i];
        const std::uint32_t ph = frame.pyramid_heights[i];
        const std::uint64_t score =
            static_cast<std::uint64_t>(pw > target_w ? pw - target_w : target_w - pw) +
            static_cast<std::uint64_t>(ph > target_h ? ph - target_h : target_h - ph);
        if (score < best_score) {
            best = i;
            best_score = score;
        }
    }
    return best;
}

void GaussianTrainingEngine::prepare_target_image_from_frame(
    const TrainingFrame& frame,
    std::uint32_t target_w,
    std::uint32_t target_h) noexcept
{
    target_image_.resize(static_cast<std::size_t>(target_w) * target_h * 3);
    if (target_w == 0 || target_h == 0) return;

    const std::size_t level = select_pyramid_level(frame, target_w, target_h);
    const std::uint32_t src_w =
        (level < frame.pyramid_widths.size()) ? frame.pyramid_widths[level] : frame.width;
    const std::uint32_t src_h =
        (level < frame.pyramid_heights.size()) ? frame.pyramid_heights[level] : frame.height;
    const std::vector<std::uint8_t>& src =
        (level < frame.pyramid_rgba.size()) ? frame.pyramid_rgba[level] : frame.rgba;

    if (src.empty() || src_w == 0 || src_h == 0) return;

    const float x_scale = static_cast<float>(src_w) / static_cast<float>(target_w);
    const float y_scale = static_cast<float>(src_h) / static_cast<float>(target_h);
    const float* lut = g_srgb_lut.table;
    for (std::uint32_t y = 0; y < target_h; ++y) {
        for (std::uint32_t x = 0; x < target_w; ++x) {
            const float src_x = (static_cast<float>(x) + 0.5f) * x_scale - 0.5f;
            const float src_y = (static_cast<float>(y) + 0.5f) * y_scale - 0.5f;
            const std::size_t dst_idx = (static_cast<std::size_t>(y) * target_w + x) * 3;
            target_image_[dst_idx + 0] = lut[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 2)];
            target_image_[dst_idx + 1] = lut[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 1)];
            target_image_[dst_idx + 2] = lut[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 0)];
        }
    }
}

void GaussianTrainingEngine::sample_frame_color(
    const TrainingFrame& frame,
    float px,
    float py,
    std::uint32_t target_w,
    std::uint32_t target_h,
    float rgb[3]) const noexcept
{
    rgb[0] = rgb[1] = rgb[2] = 0.5f;
    if (target_w == 0 || target_h == 0) return;

    const std::size_t level = select_pyramid_level(frame, target_w, target_h);
    const std::uint32_t src_w =
        (level < frame.pyramid_widths.size()) ? frame.pyramid_widths[level] : frame.width;
    const std::uint32_t src_h =
        (level < frame.pyramid_heights.size()) ? frame.pyramid_heights[level] : frame.height;
    const std::vector<std::uint8_t>& src =
        (level < frame.pyramid_rgba.size()) ? frame.pyramid_rgba[level] : frame.rgba;
    if (src.empty() || src_w == 0 || src_h == 0) return;

    const float sx = static_cast<float>(src_w) / static_cast<float>(target_w);
    const float sy = static_cast<float>(src_h) / static_cast<float>(target_h);
    const float src_x = (px + 0.5f) * sx - 0.5f;
    const float src_y = (py + 0.5f) * sy - 0.5f;
    rgb[0] = g_srgb_lut.table[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 2)];
    rgb[1] = g_srgb_lut.table[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 1)];
    rgb[2] = g_srgb_lut.table[bilinear_sample_u8(src.data(), src_w, src_h, src_x, src_y, 0)];
}

// ─── add_gaussians: append Gaussians to a running engine ─────────────
// Follows the exact pattern from densify_and_prune() clone section
// (lines 1732-1775): resize arrays, copy params with logit/log
// reparameterization, optimizer_.grow(), resize Student-t/SteepGS.

core::Status GaussianTrainingEngine::add_gaussians(
    const splat::GaussianParams* pts, std::size_t count) noexcept
{
    if (!pts || count == 0) return core::Status::kInvalidArgument;

    // Cap to GPU buffer capacity (same guard as densify_and_prune)
    std::size_t old_count = num_gaussians_;
    if (old_count + count > config_.max_gaussians) {
        count = (old_count < config_.max_gaussians)
            ? config_.max_gaussians - old_count : 0;
    }

    // Memory budget cap: also limit by available memory headroom.
    // Prevents OOM even if config_.max_gaussians is set higher than budget allows.
    std::size_t headroom = memory_budget_.headroom(MemoryPressure::kCritical);
    if (count > headroom) {
        count = headroom;
    }

    if (count == 0) return core::Status::kOk;  // At capacity, silently skip

    num_gaussians_ = old_count + count;
    params_.resize(num_gaussians_ * kParamsPerGaussian);
    gradients_.resize(num_gaussians_ * kParamsPerGaussian, 0.0f);
    screen_grad_accum_.resize(num_gaussians_, 0.0f);
    grad_count_.resize(num_gaussians_, 0);

    // Copy new params with logit/log reparameterization (same as params_to_flat)
    for (std::size_t i = 0; i < count; ++i) {
        float* dst = params_.data() + (old_count + i) * kParamsPerGaussian;
        std::memcpy(dst, pts[i].position, 3 * sizeof(float));
        std::memcpy(dst + 3, pts[i].color, 3 * sizeof(float));
        dst[6] = logit(pts[i].opacity);
        dst[7] = safe_log(pts[i].scale[0]);
        dst[8] = safe_log(pts[i].scale[1]);
        dst[9] = safe_log(pts[i].scale[2]);
        std::memcpy(dst + 10, pts[i].rotation, 4 * sizeof(float));
    }

    // Grow optimizer (zero-initialized Adam state for new Gaussians)
    optimizer_.grow(count);

    // C1: Grow Student-t nu vectors
    if (use_student_t_) {
        nu_params_.resize(num_gaussians_, 1.0f);   // log(nu-2), nu ≈ 4.72
        nu_grad_.resize(num_gaussians_, 0.0f);
        nu_m1_.resize(num_gaussians_, 0.0f);
        nu_m2_.resize(num_gaussians_, 0.0f);
    }

    // C2b: Grow SteepGS vectors
    if (use_steepgs_) {
        prev_position_grad_.resize(num_gaussians_ * 3, 0.0f);
        prev_position_.resize(num_gaussians_ * 3, 0.0f);
    }

    // Grow anchor positions for new Gaussians (their "home" is where they were added)
    anchor_positions_.resize(num_gaussians_ * 3);
    for (std::size_t i = 0; i < count; ++i) {
        anchor_positions_[(old_count + i) * 3 + 0] = pts[i].position[0];
        anchor_positions_[(old_count + i) * 3 + 1] = pts[i].position[1];
        anchor_positions_[(old_count + i) * 3 + 2] = pts[i].position[2];
    }

    // Grow NaN rollback snapshot (prevents crash in next snapshot)
    params_snapshot_.resize(num_gaussians_ * kParamsPerGaussian);

    cpu_params_modified_ = true;  // CPU modified params_, next GPU step must re-upload

    std::fprintf(stderr, "[Aether3D][Training] add_gaussians: +%zu → %zu total\n",
                 count, num_gaussians_);
    return core::Status::kOk;
}

// ─── Training Loop ───────────────────────────────────────────────────

core::Status GaussianTrainingEngine::train_step() noexcept {
    if (frames_.empty() || num_gaussians_ == 0) {
        return core::Status::kInvalidArgument;
    }

    // ─── GPU path: dispatch to full GPU pipeline when ready ───
    if (gpu_training_ready_) {
        return train_step_gpu();
    }

    // ── GPU Recovery: retry after cooldown ──
    // After a GPU error, wait (2s × 2^fail_count) before retrying.
    // Shorter cooldown (2s base vs old 5s) — overlay tile count is now much
    // lower after quality + edge filters, so GPU should recover faster.
    if (gpu_fail_count_ > 0 && gpu_fail_count_ <= kMaxGPURetries) {
        const auto now = std::chrono::steady_clock::now();
        const auto cooldown_ms = 2000 * (1 << (gpu_fail_count_ - 1));  // 2s, 4s, 8s
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - gpu_fail_time_).count();
        if (elapsed >= cooldown_ms) {
            std::fprintf(stderr, "[Aether3D] GPU recovery attempt %d/%d after %lldms cooldown\n",
                         gpu_fail_count_, kMaxGPURetries, elapsed);
            // Test if we can create a command buffer
            auto probe = device_.create_command_buffer();
            if (probe) {
                probe->commit();
                probe->wait_until_completed();
                if (!probe->had_error()) {
                    gpu_training_ready_ = true;
                    std::fprintf(stderr, "[Aether3D] GPU RECOVERED — resuming GPU training\n");
                    return train_step_gpu();
                }
            }
            // Recovery failed — increment counter, update timer
            gpu_fail_count_++;
            gpu_fail_time_ = now;
            if (gpu_fail_count_ > kMaxGPURetries) {
                std::fprintf(stderr, "[Aether3D] GPU recovery FAILED after %d retries — permanent CPU fallback\n",
                             kMaxGPURetries);
            }
        }
    }

    // ─── CPU fallback path below ───
    {
        static bool cpu_fallback_logged = false;
        if (!cpu_fallback_logged) {
            std::fprintf(stderr,
                "[Aether3D][Training] *** CPU FALLBACK ACTIVE *** "
                "(gpu_fail_count=%d, gaussians=%zu)\n",
                gpu_fail_count_, num_gaussians_);
            cpu_fallback_logged = true;
        }
    }

    // No thermal throttling — let CPU/GPU manage clock speeds naturally.
    std::size_t step = current_step_.load(std::memory_order_relaxed);

    // B3: Temporal-focal frame sampling (replaces uniform random).
    // 70% from focal window (latest N frames), 30% from maintenance pool.
    std::size_t frame_idx = sample_focal_frame();

    // B4: Progressive resolution — use warmup resolution for early steps.
    std::uint32_t effective_rw, effective_rh;
    resolution_at_step(step, preset_, effective_rw, effective_rh);
    config_.render_width = effective_rw;
    config_.render_height = effective_rh;

    // Forward render
    forward_render(frame_idx);

    // Compute loss
    const TrainingFrame& frame = frames_[frame_idx];
    std::uint32_t rw = config_.render_width;
    std::uint32_t rh = config_.render_height;

    // Bug 0.9 fix: guard against zero render dimensions to prevent division by zero
    if (rw == 0 || rh == 0) {
        return core::Status::kOk;
    }

    // Photo-SLAM-style image pyramid: choose closest prepared level instead of
    // repeatedly downsampling level-0 every step.
    prepare_target_image_from_frame(frame, rw, rh);

    // DynamicWeights: smoothstep transition geometry → appearance.
    // Early training: high depth weight + low D-SSIM (focus on 3D structure)
    // Late training: low depth weight + high D-SSIM (focus on perceptual quality)
    DynamicWeights dyn_w = dynamic_weights_at_step(
        preset_.depth_loss_weight_max, 0.02f,  // depth: max → 0.02
        0.10f, 0.30f,                           // dssim: 0.10 → 0.30
        step, config_.max_iterations);

    float loss = compute_combined_loss(
        rendered_image_.data(), target_image_.data(),
        rw, rh, dyn_w.dssim_weight);

    // B6: Add Pearson-invariant depth supervision loss (if DAv2 depth available).
    // Uses scale/shift-invariant correlation — compatible with DAv2's relative depth.
    // Lambda scheduled by DynamicWeights smoothstep (high early, decays late).
    // Reuse class member for depth gradient to avoid per-step heap allocation (~1.2MB)
    if (!frame.ref_depth.empty() && frame.ref_depth_w > 0 && frame.ref_depth_h > 0) {
        cpu_depth_grad_.resize(static_cast<std::size_t>(rw) * rh);
        std::fill(cpu_depth_grad_.begin(), cpu_depth_grad_.end(), 0.0f);
        float depth_loss = pearson_depth_loss(
            cpu_rendered_depth_.data(),
            frame.ref_depth.data(),
            frame.ref_depth_w, frame.ref_depth_h,
            rw, rh,
            dyn_w.depth_weight,
            cpu_depth_grad_.data());
        loss += depth_loss;
    }

    // Apply quality weight
    loss *= frame.quality_weight;
    current_loss_.store(loss, std::memory_order_relaxed);

    // ─── Stability guard 1: NaN/Inf detection with rollback ───
    // If loss is NaN or Inf, the forward pass produced garbage.
    // Roll back params to last known-good snapshot and skip this step.
    if (!std::isfinite(loss)) {
        if (!params_snapshot_.empty()) {
            // Safety: use min size in case densification changed param count
            std::size_t rollback_count = std::min(params_.size(),
                                                  params_snapshot_.size());
            std::memcpy(params_.data(), params_snapshot_.data(),
                        rollback_count * sizeof(float));
        }
        nan_rollback_count_++;
        if (nan_rollback_count_ <= 3) {
            std::fprintf(stderr, "[Aether3D] train_step %zu: NaN/Inf loss — rollback #%zu\n",
                         step, nan_rollback_count_);
        }
        // Advance step counter but skip gradient update
        current_step_.store(step + 1, std::memory_order_relaxed);
        return core::Status::kOk;
    }
    // Save snapshot of current (valid) params for future rollback
    params_snapshot_ = params_;

    // Backward pass (compute gradients)
    backward_pass();

    // ─── Position anchor regularization ───
    // L_anchor = lambda * ||pos - anchor||^2
    // dL/dpos = 2 * lambda * (pos - anchor)
    // Lambda decays: 10.0 early → 5.0 late (极致位置锚定，最大限度减少偏差)
    // Pure visual approach — no depth camera needed, anchors from TSDF initialization.
    if (!config_.align_to_baseline_3dgs &&
        !anchor_positions_.empty() &&
        anchor_positions_.size() >= num_gaussians_ * 3) {
        float t_ratio = static_cast<float>(step) / std::max(config_.max_iterations, std::size_t(1));
        float anchor_lambda = 10.0f * (1.0f - t_ratio) + 5.0f * t_ratio;  // 10.0 → 5.0
        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            std::size_t pb = i * kParamsPerGaussian;  // params base
            std::size_t ab = i * 3;                    // anchor base
            for (int d = 0; d < 3; ++d) {
                float delta = params_[pb + d] - anchor_positions_[ab + d];
                gradients_[pb + d] += 2.0f * anchor_lambda * delta;
            }
        }
    }

    // ─── Color gradient freeze for early steps ───
    // With sparse Gaussians and modest opacity, early color gradients
    // consistently push colors toward 1.0 (white) because rendered pixels
    // are darker than targets. Adam momentum accumulates this bias.
    // Fix: freeze colors (use TSDF-initialized values) for the first
    // 50 steps, letting geometry/opacity stabilize first.
    constexpr std::size_t kColorFreezeSteps = 50;
    if (!config_.align_to_baseline_3dgs && step < kColorFreezeSteps) {
        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            gradients_[i * kParamsPerGaussian + 3] = 0.0f;
            gradients_[i * kParamsPerGaussian + 4] = 0.0f;
            gradients_[i * kParamsPerGaussian + 5] = 0.0f;
        }
    }

    // ─── Stability guard 2: Gradient clipping ───
    // Prevent exploding gradients from destabilizing Adam.
    // Global gradient norm clipping (max_grad_norm = 1.0).
    {
        const std::size_t n_params = num_gaussians_ * kParamsPerGaussian;
        double grad_norm_sq = 0.0;
        for (std::size_t i = 0; i < n_params; ++i) {
            grad_norm_sq += static_cast<double>(gradients_[i]) * gradients_[i];
        }
        float grad_norm = static_cast<float>(std::sqrt(grad_norm_sq));
        constexpr float kMaxGradNorm = 1.0f;
        // Bug 0.10 fix: also check grad_norm > 1e-8f to prevent division by zero
        if (grad_norm > 1e-8f && grad_norm > kMaxGradNorm) {
            float clip_scale = kMaxGradNorm / grad_norm;
            for (std::size_t i = 0; i < n_params; ++i) {
                gradients_[i] *= clip_scale;
            }
        }
    }

    // Adam optimizer step
    optimizer_.step(params_.data(), gradients_.data(), num_gaussians_);

    // ─── Color + Quaternion + Position post-Adam guards ───
    constexpr float kMaxPositionDrift = 0.002f;  // 2mm radial hard limit — 极致一比一还原
    for (std::size_t i = 0; i < num_gaussians_; ++i) {
        float* p = params_.data() + i * kParamsPerGaussian;

        // Position clamping: radial hard limit from initial anchor position.
        // TSDF positions are accurate to ~1-2mm; training micro-adjusts only.
        // 极致一比一还原：最大 5mm 位移保证几何精度。
        // Pure-visual constraint — no depth camera required.
        if (!config_.align_to_baseline_3dgs &&
            i * 3 + 2 < anchor_positions_.size()) {
            float dx = p[0] - anchor_positions_[i * 3 + 0];
            float dy = p[1] - anchor_positions_[i * 3 + 1];
            float dz = p[2] - anchor_positions_[i * 3 + 2];
            float dist = std::sqrt(dx * dx + dy * dy + dz * dz);
            if (dist > kMaxPositionDrift) {
                float scale = kMaxPositionDrift / dist;
                p[0] = anchor_positions_[i * 3 + 0] + dx * scale;
                p[1] = anchor_positions_[i * 3 + 1] + dy * scale;
                p[2] = anchor_positions_[i * 3 + 2] + dz * scale;
            }
        }

        // Color clamping: keep in [0, 1] after each step.
        // Without this, Adam overshoots on early steps when rendered image
        // is dark (low opacity) → gradient pushes colors >> 1.0 → white.
        p[3] = std::clamp(p[3], 0.0f, 1.0f);
        p[4] = std::clamp(p[4], 0.0f, 1.0f);
        p[5] = std::clamp(p[5], 0.0f, 1.0f);

        float* q = p + 10;
        float norm = std::sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
        // Bug 0.29 fix: raise threshold from 1e-8 to 1e-6 for more robust
        // quaternion degenerate detection (1e-8 can pass near-zero quats)
        if (norm < 1e-6f) {
            // Degenerate quaternion: reset to identity
            q[0] = 1.0f; q[1] = q[2] = q[3] = 0.0f;
        } else {
            float inv_norm = 1.0f / norm;
            q[0] *= inv_norm;
            q[1] *= inv_norm;
            q[2] *= inv_norm;
            q[3] *= inv_norm;
        }
    }

    // C1: Student-t nu parameter Adam update (separate from main params)
    // Uses its own Adam moments with fixed learning rate.
    if (use_student_t_ && !nu_params_.empty()) {
        constexpr float kBeta1 = 0.9f;
        constexpr float kBeta2 = 0.999f;
        constexpr float kEps = 1e-8f;
        float step_f = static_cast<float>(step + 1);
        float bc1 = 1.0f - std::pow(kBeta1, step_f);
        float bc2 = 1.0f - std::pow(kBeta2, step_f);
        for (std::size_t i = 0; i < num_gaussians_ && i < nu_params_.size(); ++i) {
            float g = nu_grad_[i];
            // Gradient clipping for nu
            g = std::clamp(g, -1.0f, 1.0f);
            // Update Adam moments
            nu_m1_[i] = kBeta1 * nu_m1_[i] + (1.0f - kBeta1) * g;
            nu_m2_[i] = kBeta2 * nu_m2_[i] + (1.0f - kBeta2) * g * g;
            // Bias-corrected
            float m_hat = nu_m1_[i] / bc1;
            float v_hat = nu_m2_[i] / bc2;
            // Update log_nu
            nu_params_[i] -= kNuLrInit * m_hat / (std::sqrt(v_hat) + kEps);
            // Clamp log_nu to safe range
            nu_params_[i] = std::clamp(nu_params_[i], -5.0f, 5.0f);
        }
        // Reset nu gradients for next step
        std::fill(nu_grad_.begin(), nu_grad_.end(), 0.0f);
    }

    // C2: MCMC noise injection — SGLD noise into positions for exploration.
    // Injected after Adam step, temperature anneals over training.
    if (use_mcmc_noise_ && step > 0) {
        float temp = annealed_temperature(
            /*T0=*/0.1f, /*T_final=*/0.001f, step, config_.max_iterations);
        if (temp > 1e-8f) {
            static thread_local std::mt19937 mcmc_rng(std::random_device{}());
            std::normal_distribution<float> norm(0.0f, 1.0f);
            float noise_scale = std::sqrt(2.0f * config_.lr_position * temp);
            for (std::size_t i = 0; i < num_gaussians_; ++i) {
                float* p = params_.data() + i * kParamsPerGaussian;
                p[0] += noise_scale * norm(mcmc_rng);
                p[1] += noise_scale * norm(mcmc_rng);
                p[2] += noise_scale * norm(mcmc_rng);
            }
        }
    }

    // ─── Post-MCMC position re-clamp ───
    // MCMC SGLD noise (above) adds random perturbation AFTER the initial clamp.
    // Must re-enforce the hard radial limit to guarantee 极致一比一还原.
    if (!config_.align_to_baseline_3dgs &&
        !anchor_positions_.empty() &&
        anchor_positions_.size() >= num_gaussians_ * 3) {
        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            float* p = params_.data() + i * kParamsPerGaussian;
            float dx = p[0] - anchor_positions_[i * 3 + 0];
            float dy = p[1] - anchor_positions_[i * 3 + 1];
            float dz = p[2] - anchor_positions_[i * 3 + 2];
            float dist = std::sqrt(dx * dx + dy * dy + dz * dz);
            if (dist > kMaxPositionDrift) {
                float scale = kMaxPositionDrift / dist;
                p[0] = anchor_positions_[i * 3 + 0] + dx * scale;
                p[1] = anchor_positions_[i * 3 + 1] + dy * scale;
                p[2] = anchor_positions_[i * 3 + 2] + dz * scale;
            }
        }
    }

    // C2b: SteepGS saddle detection state update (save for next step)
    if (use_steepgs_ && !prev_position_grad_.empty()) {
        for (std::size_t i = 0; i < num_gaussians_ && i * 3 + 2 < prev_position_grad_.size(); ++i) {
            const float* grad = gradients_.data() + i * kParamsPerGaussian;
            const float* p = params_.data() + i * kParamsPerGaussian;
            prev_position_grad_[i * 3 + 0] = grad[0];
            prev_position_grad_[i * 3 + 1] = grad[1];
            prev_position_grad_[i * 3 + 2] = grad[2];
            prev_position_[i * 3 + 0] = p[0];
            prev_position_[i * 3 + 1] = p[1];
            prev_position_[i * 3 + 2] = p[2];
        }
    }

    // Densify/prune at intervals (B8: uses adaptive threshold internally)
    step++;
    if (step % config_.densify_interval == 0 && step < config_.max_iterations * 3 / 4) {
        // Memory budget gate: skip densification if memory pressure is High or Critical
        if (memory_budget_.allow_densification()) {
            densify_and_prune();
        }
    }

    // ─── Memory budget update + compact mode switching ───
    // Update pressure level based on current Gaussian count.
    // Automatically toggles Student-t/SteepGS off when memory is constrained.
    {
        memory_budget_.update(num_gaussians_);

        // Compact mode: disable Student-t and SteepGS to save 40 bytes/G (16+24)
        // This happens automatically at 70% utilization via MemoryBudgetController.
        bool budget_allows_student_t = memory_budget_.allow_student_t();
        bool budget_allows_steepgs   = memory_budget_.allow_steepgs();

        // Only downgrade, never upgrade back mid-training (hysteresis)
        if (!budget_allows_student_t && use_student_t_) {
            use_student_t_ = false;
            std::fprintf(stderr, "[Aether3D][MemBudget] Disabled Student-t "
                "(Gaussians=%zu, mode=%s)\n",
                num_gaussians_,
                memory_budget_.mode() == MemoryMode::kCompact ? "Compact" : "Minimal");
        }
        if (!budget_allows_steepgs && use_steepgs_) {
            use_steepgs_ = false;
            // Free SteepGS memory immediately
            prev_position_grad_.clear();
            prev_position_grad_.shrink_to_fit();
            prev_position_.clear();
            prev_position_.shrink_to_fit();
            std::fprintf(stderr, "[Aether3D][MemBudget] Disabled SteepGS "
                "(Gaussians=%zu, freed %zuKB)\n",
                num_gaussians_,
                (num_gaussians_ * 6 * 4) / 1024);
        }

        // Force prune at critical pressure (>95% budget)
        if (memory_budget_.should_force_prune()) {
            std::fprintf(stderr, "[Aether3D][MemBudget] CRITICAL pressure — "
                "force pruning bottom 10%%\n");
            densify_and_prune();  // MCMC importance death handles the rest
        }

        // Log memory status every 200 steps
        if (step % 200 == 0) {
            memory_budget_.print_status("periodic");
        }
    }

    // B7: Opacity reset — every N steps, reset all opacities to near-zero.
    // Forces re-competition among primitives, eliminating transparent ghosts.
    maybe_opacity_reset();

    current_step_.store(step, std::memory_order_relaxed);

    // Upload updated parameters to GPU
    upload_gaussians_to_gpu();

    return core::Status::kOk;
}

TrainingProgress GaussianTrainingEngine::progress() const noexcept {
    TrainingProgress p;
    p.step = current_step_.load(std::memory_order_relaxed);
    p.total_steps = config_.max_iterations;
    p.loss = current_loss_.load(std::memory_order_relaxed);
    p.num_gaussians = num_gaussians_;
    p.is_complete = (p.step >= p.total_steps);
    return p;
}

void GaussianTrainingEngine::set_thermal_state(int level) noexcept {
    thermal_state_.store(level, std::memory_order_relaxed);
}

// ─── Export ──────────────────────────────────────────────────────────

core::Status GaussianTrainingEngine::export_gaussians(
    std::vector<splat::GaussianParams>& out) const noexcept
{
    out.resize(num_gaussians_);
    flat_to_params(out.data(), num_gaussians_);
    return core::Status::kOk;
}

core::Status GaussianTrainingEngine::export_ply(const char* path) const noexcept {
    std::vector<splat::GaussianParams> gaussians(num_gaussians_);
    flat_to_params(gaussians.data(), num_gaussians_);
    return splat::write_ply(path, gaussians.data(), num_gaussians_);
}

// ─── Internal Methods ────────────────────────────────────────────────

core::Status GaussianTrainingEngine::create_gpu_resources() noexcept {
    // Probe GPU capability: if create_command_buffer() returns nullptr,
    // this is a NullGPUDevice or a backend without compute — fall back to CPU.
    {
        auto probe = device_.create_command_buffer();
        if (!probe) {
            gpu_training_ready_ = false;
            std::fprintf(stderr, "[Aether3D] GPU: no command buffer support — CPU training only\n");
            return core::Status::kOk;
        }
    }

    // ── Device-adaptive capacity ──
    // Cap max_gaussians based on the LARGEST per-Gaussian buffer (adam_moments = 128 bytes),
    // not the smallest (params = 56 bytes). Previous bug: capping against 56 bytes allowed
    // max_gaussians that caused adam_moments_buffer to exceed maxBufferLength → allocation
    // failure → GPU training silently broken.
    auto caps = device_.capabilities();
    std::fprintf(stderr,
        "[Aether3D][GPU] Device caps: maxBuffer=%uMB, maxThreadsPerGroup=%u\n",
        caps.max_buffer_size / (1024u*1024u),
        caps.max_threadgroup_memory);

    if (caps.max_buffer_size > 0) {
        // Adam moments buffer is the largest: 128 bytes per Gaussian.
        // Cap max_gaussians so ALL buffers fit within maxBufferLength.
        constexpr std::size_t kLargestPerGaussianBytes = 128;  // adam_moments
        std::size_t max_by_buffer = caps.max_buffer_size / kLargestPerGaussianBytes;
        if (config_.max_gaussians > max_by_buffer) {
            std::fprintf(stderr,
                "[Aether3D][GPU] Buffer cap: max_gaussians %zu → %zu "
                "(maxBuffer=%uMB / %zu bytes/gaussian)\n",
                config_.max_gaussians, max_by_buffer,
                caps.max_buffer_size / (1024u*1024u), kLargestPerGaussianBytes);
            config_.max_gaussians = max_by_buffer;
        }
    }
    if (caps.max_buffer_size > 0 && caps.max_buffer_size < 256 * 1024 * 1024) {
        // Small GPU buffer (< 256MB) → also reduce render resolution
        config_.render_width = std::min(config_.render_width, 480u);
        config_.render_height = std::min(config_.render_height, 360u);
    }

    // ── Core data buffers ──
    // Allocate for max capacity to avoid reallocation during densification
    std::size_t max_n = config_.max_gaussians;
    std::size_t param_bytes = max_n * kParamsPerGaussian * sizeof(float);
    std::size_t total_gpu_bytes = 0;

    std::fprintf(stderr,
        "[Aether3D][GPU] Allocating buffers: max_gaussians=%zu, render=%ux%u\n",
        max_n, config_.render_width, config_.render_height);

    render::GPUBufferDesc buf_desc{};
    buf_desc.storage = render::GPUStorageMode::kShared;
    buf_desc.usage_mask = static_cast<std::uint8_t>(render::GPUBufferUsage::kStorage);

    buf_desc.size_bytes = param_bytes;
    gaussian_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;
    gradient_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // Rendered/target image buffers
    std::size_t npix = config_.render_width * config_.render_height;
    std::size_t img_bytes = npix * 3 * sizeof(float);
    buf_desc.size_bytes = img_bytes;
    rendered_buffer_ = device_.create_buffer(buf_desc);    total_gpu_bytes += buf_desc.size_bytes;
    target_buffer_ = device_.create_buffer(buf_desc);      total_gpu_bytes += buf_desc.size_bytes;
    image_grad_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // Per-pixel auxiliary buffers
    buf_desc.size_bytes = npix * sizeof(float);
    transmittance_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // B5: Rendered depth buffer (per-pixel, for Pearson depth loss)
    buf_desc.size_bytes = npix * sizeof(float);
    rendered_depth_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    buf_desc.size_bytes = npix * sizeof(std::uint32_t);
    last_contributor_buf_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // Projection + sort buffers (max capacity)
    buf_desc.size_bytes = max_n * 48;  // sizeof(ProjectedGaussian) = 48 bytes
    projected_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    buf_desc.size_bytes = max_n * sizeof(std::uint32_t);
    depth_keys_buffer_ = device_.create_buffer(buf_desc);   total_gpu_bytes += buf_desc.size_bytes;
    sort_indices_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;
    sort_keys_tmp_ = device_.create_buffer(buf_desc);        total_gpu_bytes += buf_desc.size_bytes;
    sort_vals_tmp_ = device_.create_buffer(buf_desc);        total_gpu_bytes += buf_desc.size_bytes;

    // Sort histogram (256 bins)
    buf_desc.size_bytes = 256 * sizeof(std::uint32_t);
    sort_histogram_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // AbsGrad + grad count (per-Gaussian atomic buffers)
    buf_desc.size_bytes = max_n * sizeof(std::uint32_t);
    absgrad_buffer_ = device_.create_buffer(buf_desc);       total_gpu_bytes += buf_desc.size_bytes;
    grad_count_gpu_buf_ = device_.create_buffer(buf_desc);   total_gpu_bytes += buf_desc.size_bytes;

    // Cov2D gradient buffer (per-Gaussian, 3 floats: dL/d(c00, c01, c11))
    buf_desc.size_bytes = max_n * 3 * sizeof(std::uint32_t);  // atomic uint (as_type<float>)
    cov2d_grad_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // Adam moments (per-Gaussian)
    // AdamMoments: 14+14 floats + 1 uint + 3 pad = 120 bytes → padded to 128
    buf_desc.size_bytes = max_n * 128;
    adam_moments_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    // Uniform buffer (oversized for safety)
    buf_desc.size_bytes = 256;
    buf_desc.usage_mask = static_cast<std::uint8_t>(render::GPUBufferUsage::kUniform);
    training_uniform_buffer_ = device_.create_buffer(buf_desc);  total_gpu_bytes += buf_desc.size_bytes;

    std::fprintf(stderr,
        "[Aether3D][GPU] Total GPU buffer allocation: %zuMB\n",
        total_gpu_bytes / (1024u*1024u));

    // ── Validate critical buffer allocations ──
    // If any core buffer failed to allocate, GPU training cannot proceed.
    if (!gaussian_buffer_.valid() || !gradient_buffer_.valid() ||
        !rendered_buffer_.valid() || !target_buffer_.valid() ||
        !adam_moments_buffer_.valid() || !projected_buffer_.valid() ||
        !sort_indices_buffer_.valid() || !training_uniform_buffer_.valid()) {
        std::fprintf(stderr,
            "[Aether3D][GPU] *** BUFFER ALLOCATION FAILED *** — "
            "gaussians=%d gradients=%d rendered=%d target=%d "
            "adam=%d projected=%d sort=%d uniform=%d\n",
            gaussian_buffer_.valid(), gradient_buffer_.valid(),
            rendered_buffer_.valid(), target_buffer_.valid(),
            adam_moments_buffer_.valid(), projected_buffer_.valid(),
            sort_indices_buffer_.valid(), training_uniform_buffer_.valid());
        gpu_training_ready_ = false;
        std::fprintf(stderr,
            "[Aether3D][GPU] GPU training DISABLED — falling back to CPU\n");
        return core::Status::kOk;
    }

    // ── GPU Depth Supervision buffers (dual depth source) ──
    // These are allocated regardless of depth availability. If allocation fails,
    // depth_gpu_ready_ stays false and training runs without depth supervision (Layer 7).
    {
        buf_desc.storage = render::GPUStorageMode::kShared;
        buf_desc.usage_mask = static_cast<std::uint8_t>(render::GPUBufferUsage::kStorage);

        // DAv2 reference depth (max 1024×1024 to cover any DAv2 resolution)
        buf_desc.size_bytes = 1024 * 1024 * sizeof(float);
        ref_depth_buffer_ = device_.create_buffer(buf_desc);

        // LiDAR metric depth (fixed 256×192 = ARKit sceneDepth)
        buf_desc.size_bytes = 256 * 192 * sizeof(float);
        lidar_depth_buffer_ = device_.create_buffer(buf_desc);

        // Per-pixel depth gradient (render resolution)
        buf_desc.size_bytes = npix * sizeof(float);
        depth_grad_buffer_ = device_.create_buffer(buf_desc);

        // Pearson statistics (8 floats)
        buf_desc.size_bytes = 8 * sizeof(float);
        depth_stats_buffer_ = device_.create_buffer(buf_desc);

        // Partial reduction sums: (npix/256 + 1) threadgroups × 7 floats
        std::size_t num_depth_groups = (npix + 255) / 256;
        buf_desc.size_bytes = (num_depth_groups + 1) * 7 * sizeof(float);
        depth_partial_sums_buffer_ = device_.create_buffer(buf_desc);

        // DepthConfig constant buffer (48 bytes, padded to 64)
        buf_desc.size_bytes = 64;
        buf_desc.usage_mask = static_cast<std::uint8_t>(render::GPUBufferUsage::kUniform);
        depth_config_buffer_ = device_.create_buffer(buf_desc);

        buf_desc.usage_mask = static_cast<std::uint8_t>(render::GPUBufferUsage::kStorage);
    }

    // ── Load compute shaders ──
    auto load_pipeline = [&](const char* name) -> render::GPUComputePipelineHandle {
        auto shader = device_.load_shader(name, render::GPUShaderStage::kCompute);
        if (!shader.valid()) {
            std::fprintf(stderr, "[Aether3D] GPU: failed to load shader '%s'\n", name);
            return render::GPUComputePipelineHandle{0};
        }
        return device_.create_compute_pipeline(shader);
    };

    preprocess_pipeline_     = load_pipeline("preprocessGaussians");
    forward_pipeline_        = load_pipeline("forwardRasterize");
    l1_gradient_pipeline_    = load_pipeline("computeL1Gradient");
    backward_pipeline_       = load_pipeline("backwardRasterize");
    adam_pipeline_           = load_pipeline("adamUpdate");
    densify_pipeline_        = load_pipeline("densificationStats");
    compact_pipeline_        = load_pipeline("compactSplats");
    sort_histogram_pipeline_ = load_pipeline("radixSortHistogram");
    sort_prefix_sum_pipeline_  = load_pipeline("radixSortPrefixSum");
    sort_scatter_pipeline_   = load_pipeline("radixSortScatter");
    sort_clear_pipeline_     = load_pipeline("radixSortClearHistogram");
    scale_rot_grad_pipeline_ = load_pipeline("computeScaleRotGradients");

    // ── Depth supervision pipelines (independent of core training) ──
    depth_reduce_partial_pipeline_ = load_pipeline("depthPearsonReducePartial");
    depth_reduce_final_pipeline_   = load_pipeline("depthPearsonReduceFinal");
    depth_gradient_pipeline_       = load_pipeline("depthGradientCompute");
    tangent_project_pipeline_      = load_pipeline("projectGradientsToTangentPlane");

    // Depth pipelines are NOT required for core training (Layer 7: graceful degradation).
    // Depth shader compilation failure doesn't block training.
    depth_gpu_ready_ = depth_reduce_partial_pipeline_.valid() &&
                       depth_reduce_final_pipeline_.valid() &&
                       depth_gradient_pipeline_.valid() &&
                       tangent_project_pipeline_.valid() &&
                       ref_depth_buffer_.valid() &&
                       lidar_depth_buffer_.valid() &&
                       depth_grad_buffer_.valid() &&
                       depth_stats_buffer_.valid() &&
                       depth_partial_sums_buffer_.valid() &&
                       depth_config_buffer_.valid();

    if (depth_gpu_ready_) {
        std::fprintf(stderr, "[Aether3D] GPU depth supervision: all 4 pipelines + 6 buffers ready\n");
    } else {
        std::fprintf(stderr, "[Aether3D] GPU depth supervision: disabled (shader/buffer failure — "
                             "training continues without depth loss)\n");
    }

    // Check ALL 12 GPU pipeline shaders loaded (not just 5).
    // A missing sort or densify kernel would crash at dispatch time.
    gpu_training_ready_ = preprocess_pipeline_.valid() &&
                          forward_pipeline_.valid() &&
                          l1_gradient_pipeline_.valid() &&
                          backward_pipeline_.valid() &&
                          adam_pipeline_.valid() &&
                          densify_pipeline_.valid() &&
                          compact_pipeline_.valid() &&
                          sort_histogram_pipeline_.valid() &&
                          sort_prefix_sum_pipeline_.valid() &&
                          sort_scatter_pipeline_.valid() &&
                          sort_clear_pipeline_.valid() &&
                          scale_rot_grad_pipeline_.valid();

    if (!gpu_training_ready_) {
        // Log which specific pipelines failed for debugging
        std::fprintf(stderr, "[Aether3D] GPU training: shader load failures —");
        if (!preprocess_pipeline_.valid())     std::fprintf(stderr, " preprocessGaussians");
        if (!forward_pipeline_.valid())        std::fprintf(stderr, " forwardRasterize");
        if (!l1_gradient_pipeline_.valid())    std::fprintf(stderr, " computeL1Gradient");
        if (!backward_pipeline_.valid())       std::fprintf(stderr, " backwardRasterize");
        if (!adam_pipeline_.valid())            std::fprintf(stderr, " adamUpdate");
        if (!densify_pipeline_.valid())        std::fprintf(stderr, " densificationStats");
        if (!compact_pipeline_.valid())        std::fprintf(stderr, " compactSplats");
        if (!sort_histogram_pipeline_.valid()) std::fprintf(stderr, " radixSortHistogram");
        if (!sort_prefix_sum_pipeline_.valid()) std::fprintf(stderr, " radixSortPrefixSum");
        if (!sort_scatter_pipeline_.valid())   std::fprintf(stderr, " radixSortScatter");
        if (!sort_clear_pipeline_.valid())     std::fprintf(stderr, " radixSortClearHistogram");
        if (!scale_rot_grad_pipeline_.valid()) std::fprintf(stderr, " computeScaleRotGradients");
        std::fprintf(stderr, "\n[Aether3D] GPU training: falling back to CPU\n");
    } else {
        std::fprintf(stderr, "[Aether3D] GPU training: all 12 pipelines ready, "
                             "max_gaussians=%zu, %ux%u\n",
                     config_.max_gaussians, config_.render_width, config_.render_height);
    }

    // Zero buffers for per-step gradient clearing.
    // Start at depth-buffer size; train_step() grows on demand as Gaussians increase.
    // This avoids allocating hundreds of MB upfront for high max_gaussians.
    {
        std::size_t init_elems = std::max(npix * 3, std::size_t(65536));
        zero_buf_float_.assign(init_elems, 0.0f);
        zero_buf_uint_.assign(init_elems, 0u);
    }

    // Zero-initialize depth buffers at allocation time so backward shader
    // reads zeros even before depth supervision activates.
    if (depth_config_buffer_.valid()) {
        char zeros[64] = {};
        device_.update_buffer(depth_config_buffer_, zeros, 0, 64);
    }
    if (depth_grad_buffer_.valid()) {
        std::size_t depth_grad_bytes = npix * sizeof(float);
        device_.update_buffer(depth_grad_buffer_, zero_buf_float_.data(), 0,
                              std::min(depth_grad_bytes, zero_buf_float_.size() * sizeof(float)));
    }

    // Initial upload of Gaussian parameters to GPU buffer
    upload_gaussians_to_gpu();

    return core::Status::kOk;
}

void GaussianTrainingEngine::upload_gaussians_to_gpu() noexcept {
    if (num_gaussians_ == 0) return;
    if (!gpu_training_ready_) return;  // GPU disabled after error — prevent EXC_BAD_ACCESS

    // Cap to GPU buffer allocation size (max_gaussians × kParamsPerGaussian × sizeof(float)).
    // If num_gaussians_ somehow exceeds max_gaussians, only upload what fits.
    std::size_t upload_count = std::min(num_gaussians_, config_.max_gaussians);
    const std::size_t byte_count = upload_count * kParamsPerGaussian * sizeof(float);
    // Bounds check: ensure we don't write beyond params_ vector
    if (byte_count > params_.size() * sizeof(float)) {
        std::fprintf(stderr, "[Aether3D] upload_gaussians_to_gpu: byte_count %zu > params "
                     "capacity %zu — skipping\n", byte_count, params_.size() * sizeof(float));
        return;
    }
    device_.update_buffer(gaussian_buffer_, params_.data(), 0, byte_count);
}

void GaussianTrainingEngine::download_gradients_from_gpu() noexcept {
    if (num_gaussians_ == 0) return;
    if (!gpu_training_ready_) return;  // GPU disabled after error — prevent EXC_BAD_ACCESS
    if (stop_requested_.load(std::memory_order_acquire)) return;  // Shutdown in progress

    void* mapped = device_.map_buffer(gradient_buffer_);
    if (mapped) {
        std::memcpy(gradients_.data(), mapped,
                     num_gaussians_ * kParamsPerGaussian * sizeof(float));
        device_.unmap_buffer(gradient_buffer_);
    }
}

void GaussianTrainingEngine::forward_render(std::size_t frame_idx) noexcept {
    if (frame_idx >= frames_.size()) return;
    last_frame_idx_ = frame_idx;

    rendered_image_.resize(config_.render_width * config_.render_height * 3, 0.0f);
    // B6: Also accumulate rendered depth for Pearson depth loss
    cpu_rendered_depth_.resize(config_.render_width * config_.render_height, 0.0f);

    // CPU-based forward rendering (tile-based rasterization)
    // For each Gaussian, project to 2D and splat onto rendered image
    const TrainingFrame& frame = frames_[frame_idx];

    splat::CameraIntrinsics intr{
        frame.intrinsics[0] * config_.render_width / frame.width,
        frame.intrinsics[1] * config_.render_height / frame.height,
        frame.intrinsics[2] * config_.render_width / frame.width,
        frame.intrinsics[3] * config_.render_height / frame.height
    };

    // Compute view matrix (inverse of camera-to-world)
    // Simplified: use transform directly as view for now
    float view[16];
    std::memcpy(view, frame.transform, sizeof(view));

    // Build world-to-camera (view) matrix from camera-to-world.
    // view = [R|t] column-major → R^T = transpose of upper-left 3×3
    // inv_view = [R^T | -R^T*t]
    float R[9] = {view[0], view[1], view[2],
                   view[4], view[5], view[6],
                   view[8], view[9], view[10]};
    float t[3] = {view[12], view[13], view[14]};
    float inv_view[16] = {};
    inv_view[0] = R[0]; inv_view[4] = R[1]; inv_view[8]  = R[2];
    inv_view[1] = R[3]; inv_view[5] = R[4]; inv_view[9]  = R[5];
    inv_view[2] = R[6]; inv_view[6] = R[7]; inv_view[10] = R[8];
    inv_view[12] = -(R[0]*t[0] + R[1]*t[1] + R[2]*t[2]);
    inv_view[13] = -(R[3]*t[0] + R[4]*t[1] + R[5]*t[2]);
    inv_view[14] = -(R[6]*t[0] + R[7]*t[1] + R[8]*t[2]);
    inv_view[15] = 1.0f;

    std::uint32_t rw = config_.render_width;
    std::uint32_t rh = config_.render_height;

    // Clear rendered image + depth
    std::fill(rendered_image_.begin(), rendered_image_.end(), 0.0f);
    std::fill(cpu_rendered_depth_.begin(), cpu_rendered_depth_.end(), 0.0f);

    // Per-pixel transmittance for front-to-back compositing (reuse class member)
    cpu_transmittance_.resize(rw * rh);
    std::fill(cpu_transmittance_.begin(), cpu_transmittance_.end(), 1.0f);

    for (std::size_t gi = 0; gi < num_gaussians_; ++gi) {
        const float* p = params_.data() + gi * kParamsPerGaussian;

        splat::GaussianParams g{};
        std::memcpy(g.position, p, 3 * sizeof(float));
        std::memcpy(g.color, p + 3, 3 * sizeof(float));
        // Apply activations: logit → sigmoid, log → exp
        g.opacity = sigmoid(p[6]);
        // Bug 0.7 fix: clamp log-space scale to [-10, 10] before exp to prevent
        // Inf/NaN propagation. exp(10) ≈ 22026 is generous upper bound for any
        // real-world Gaussian primitive scale.
        g.scale[0] = std::exp(std::clamp(p[7], -10.0f, 10.0f));
        g.scale[1] = std::exp(std::clamp(p[8], -10.0f, 10.0f));
        g.scale[2] = std::exp(std::clamp(p[9], -10.0f, 10.0f));
        std::memcpy(g.rotation, p + 10, 4 * sizeof(float));

        splat::ProjectedGaussian2D proj;
        if (!splat::compute_projected_gaussian(g, inv_view, intr, rw, rh, proj)) {
            continue;
        }

        // Bounding box (3-sigma)
        float radius = 3.0f * proj.axis_major;
        int x0 = std::max(0, static_cast<int>(proj.center_x - radius));
        int y0 = std::max(0, static_cast<int>(proj.center_y - radius));
        int x1 = std::min(static_cast<int>(rw) - 1,
                          static_cast<int>(proj.center_x + radius));
        int y1 = std::min(static_cast<int>(rh) - 1,
                          static_cast<int>(proj.center_y + radius));

        // C1: Student-t nu for this Gaussian (if enabled)
        float gi_nu = 0.0f;
        if (use_student_t_ && gi < nu_params_.size()) {
            gi_nu = log_nu_to_nu(nu_params_[gi]);
        }

        for (int y = y0; y <= y1; ++y) {
            for (int x = x0; x <= x1; ++x) {
                float dx = static_cast<float>(x) - proj.center_x;
                float dy = static_cast<float>(y) - proj.center_y;

                float alpha;
                if (use_student_t_) {
                    // C1: Student-t alpha — heavy-tailed distribution.
                    // Compute Mahalanobis distance first, then use Student-t kernel.
                    float a = proj.cov2d[0], b = proj.cov2d[1], c = proj.cov2d[2];
                    float det = a * c - b * b;
                    if (det < 1e-6f) continue;
                    float inv_det = 1.0f / det;
                    float power = -0.5f * (c*dx*dx - 2.0f*b*dx*dy + a*dy*dy) * inv_det;
                    alpha = student_t_alpha(power, proj.opacity, gi_nu);
                } else {
                    alpha = splat::evaluate_gaussian_alpha(
                        dx, dy, proj.cov2d, proj.opacity);
                }
                if (alpha < 1.0f / 255.0f) continue;

                std::size_t pidx = y * rw + x;
                float T = cpu_transmittance_[pidx];
                if (T < 0.001f) continue;

                float weight = alpha * T;
                std::size_t cidx = pidx * 3;
                rendered_image_[cidx + 0] += weight * g.color[0];
                rendered_image_[cidx + 1] += weight * g.color[1];
                rendered_image_[cidx + 2] += weight * g.color[2];

                // B6: Accumulate depth (view-space) for Pearson depth loss
                cpu_rendered_depth_[pidx] += weight * proj.depth;

                cpu_transmittance_[pidx] *= (1.0f - alpha);
            }
        }
    }
}

void GaussianTrainingEngine::backward_pass() noexcept {
    // ═══════════════════════════════════════════════════════════════════
    // Complete backward pass: analytical gradients for all 14 parameters.
    //
    // Chain rule: dL/d(params) = dL/d(rendered) → dL/d(alpha,color) →
    //             dL/d(opacity,mean2d,cov2d) → dL/d(position,scale,rotation)
    //
    // Reference: 3DGS (Kerbl 2023) Eq.2-5, gsplat backward.cu
    // ═══════════════════════════════════════════════════════════════════

    std::uint32_t rw = config_.render_width;
    std::uint32_t rh = config_.render_height;

    // Step 1: dL/d(rendered_image) from combined loss (L1 + D-SSIM)
    // DynamicWeights: use current step's D-SSIM weight (matches forward loss)
    std::size_t cur_step = current_step_.load(std::memory_order_relaxed);
    DynamicWeights dyn_w_back = dynamic_weights_at_step(
        preset_.depth_loss_weight_max, 0.02f,
        0.10f, 0.30f,
        cur_step, config_.max_iterations);
    // Reuse class member to avoid per-step heap allocation (~3.6MB)
    cpu_image_grad_.resize(rw * rh * 3);
    std::fill(cpu_image_grad_.begin(), cpu_image_grad_.end(), 0.0f);
    compute_loss_gradient(rendered_image_.data(), target_image_.data(),
                          rw, rh, cpu_image_grad_.data(), dyn_w_back.dssim_weight);

    // Zero all gradients
    std::fill(gradients_.begin(), gradients_.end(), 0.0f);

    // Step 2: Reconstruct camera from the frame used in forward_render
    if (last_frame_idx_ >= frames_.size()) return;
    const TrainingFrame& frame = frames_[last_frame_idx_];

    splat::CameraIntrinsics intr{
        frame.intrinsics[0] * rw / static_cast<float>(frame.width),
        frame.intrinsics[1] * rh / static_cast<float>(frame.height),
        frame.intrinsics[2] * rw / static_cast<float>(frame.width),
        frame.intrinsics[3] * rh / static_cast<float>(frame.height)
    };

    // Compute view matrix (inverse of camera-to-world, same as forward_render)
    const float* cam2w = frame.transform;
    float R_cam[9] = {cam2w[0], cam2w[1], cam2w[2],
                      cam2w[4], cam2w[5], cam2w[6],
                      cam2w[8], cam2w[9], cam2w[10]};
    float t_cam[3] = {cam2w[12], cam2w[13], cam2w[14]};
    float view[16] = {};
    // R^T
    view[0] = R_cam[0]; view[4] = R_cam[1]; view[8]  = R_cam[2];
    view[1] = R_cam[3]; view[5] = R_cam[4]; view[9]  = R_cam[5];
    view[2] = R_cam[6]; view[6] = R_cam[7]; view[10] = R_cam[8];
    // -R^T * t
    view[12] = -(R_cam[0]*t_cam[0] + R_cam[1]*t_cam[1] + R_cam[2]*t_cam[2]);
    view[13] = -(R_cam[3]*t_cam[0] + R_cam[4]*t_cam[1] + R_cam[5]*t_cam[2]);
    view[14] = -(R_cam[6]*t_cam[0] + R_cam[7]*t_cam[1] + R_cam[8]*t_cam[2]);
    view[15] = 1.0f;

    // Extract view matrix 3x3 (column-major → row access: view[col*4+row])
    float v00 = view[0], v01 = view[4], v02 = view[8];
    float v10 = view[1], v11 = view[5], v12 = view[9];
    float v20 = view[2], v21 = view[6], v22 = view[10];

    // Per-pixel transmittance (re-initialized, reuse class member)
    cpu_transmittance_.resize(rw * rh);
    std::fill(cpu_transmittance_.begin(), cpu_transmittance_.end(), 1.0f);

    // Step 3: Iterate all Gaussians (same order as forward) and accumulate gradients
    for (std::size_t gi = 0; gi < num_gaussians_; ++gi) {
        const float* p = params_.data() + gi * kParamsPerGaussian;
        float* grad = gradients_.data() + gi * kParamsPerGaussian;

        // Extract params (apply activations for logit/log reparameterization)
        float px = p[0], py = p[1], pz = p[2];
        float col_r = p[3], col_g = p[4], col_b = p[5];
        float opacity = sigmoid(p[6]);                    // logit → sigmoid
        // Bug 0.7 fix: clamp before exp throughout backward pass as well
        float sx = std::exp(std::clamp(p[7], -10.0f, 10.0f));
        float sy = std::exp(std::clamp(p[8], -10.0f, 10.0f));
        float sz = std::exp(std::clamp(p[9], -10.0f, 10.0f));
        // rotation: p[10..13] = (w, x, y, z)

        // ── Forward: transform to camera space ──
        float tx = v00*px + v01*py + v02*pz + view[12];
        float ty = v10*px + v11*py + v12*pz + view[13];
        float tz = v20*px + v21*py + v22*pz + view[14];

        if (tz <= 0.2f) continue;

        float inv_tz = 1.0f / tz;
        float inv_tz2 = inv_tz * inv_tz;

        // Screen-space center
        float mean2d_x = intr.fx * tx * inv_tz + intr.cx;
        float mean2d_y = intr.fy * ty * inv_tz + intr.cy;

        // ── Forward: 3D covariance ──
        float qw = p[10], qx = p[11], qy = p[12], qz = p[13];
        float Rot[9];
        splat::quaternion_to_rotation_matrix(p + 10, Rot);
        float cov3d[6];
        // Use activated scale values (exp of log-space params), NOT raw p[7..9]
        float scale_activated[3] = {sx, sy, sz};
        splat::compute_3d_covariance(Rot, scale_activated, cov3d);

        // ── Forward: Jacobian ──
        float j00 = intr.fx * inv_tz;
        float j02 = -intr.fx * tx * inv_tz2;
        float j11 = intr.fy * inv_tz;
        float j12 = -intr.fy * ty * inv_tz2;

        // T = J * W (2x3)
        float t_00 = j00*v00 + j02*v20, t_01 = j00*v01 + j02*v21, t_02 = j00*v02 + j02*v22;
        float t_10 = j11*v10 + j12*v20, t_11 = j11*v11 + j12*v21, t_12 = j11*v12 + j12*v22;

        // ── Forward: 2D covariance (Sigma2D = T * Sigma3D * T^T) ──
        float s00 = cov3d[0], s01 = cov3d[1], s02 = cov3d[2];
        float s11 = cov3d[3], s12 = cov3d[4], s22 = cov3d[5];

        float c00 = t_00*(t_00*s00 + t_01*s01 + t_02*s02)
                   + t_01*(t_00*s01 + t_01*s11 + t_02*s12)
                   + t_02*(t_00*s02 + t_01*s12 + t_02*s22);
        float c01 = t_10*(t_00*s00 + t_01*s01 + t_02*s02)
                   + t_11*(t_00*s01 + t_01*s11 + t_02*s12)
                   + t_12*(t_00*s02 + t_01*s12 + t_02*s22);
        float c11_val = t_10*(t_10*s00 + t_11*s01 + t_12*s02)
                      + t_11*(t_10*s01 + t_11*s11 + t_12*s12)
                      + t_12*(t_10*s02 + t_11*s12 + t_12*s22);

        // Bug 0.34 fix: clamp 2D covariance to prevent overflow in downstream
        // determinant/eigenvalue calculations when large 3D scales combine
        // with extreme Jacobian values.
        constexpr float kMaxCov2d = 1e6f;
        c00 = std::clamp(c00, -kMaxCov2d, kMaxCov2d);
        c01 = std::clamp(c01, -kMaxCov2d, kMaxCov2d);
        c11_val = std::clamp(c11_val, -kMaxCov2d, kMaxCov2d);

        // Bug 0.42 fix: only add anti-aliasing filter if covariance is already
        // positive semi-definite. Adding 0.3 unconditionally can mask degenerate
        // Gaussians that should be skipped.
        float pre_det = c00 * c11_val - c01 * c01;
        if (pre_det < -1e-6f) continue;  // Skip degenerate (negative determinant)
        c00 += 0.3f;
        c11_val += 0.3f;

        float det = c00 * c11_val - c01 * c01;
        // Bug 0.11 fix: raise epsilon from 1e-8 to 1e-6. At 1e-8, inv_det=1e8
        // which causes downstream multiplications to overflow float32.
        if (det <= 1e-6f) continue;
        float inv_det = 1.0f / det;

        // Ellipse bounding box
        float trace = c00 + c11_val;
        float diff = c00 - c11_val;
        float disc = std::sqrt(diff*diff + 4.0f*c01*c01);
        float lambda1 = std::max(0.5f * (trace + disc), 1e-6f);
        float radius = 3.0f * std::sqrt(lambda1);
        if (radius > 1024.0f) continue;

        int x0 = std::max(0, static_cast<int>(mean2d_x - radius));
        int y0 = std::max(0, static_cast<int>(mean2d_y - radius));
        int x1 = std::min(static_cast<int>(rw) - 1, static_cast<int>(mean2d_x + radius));
        int y1 = std::min(static_cast<int>(rh) - 1, static_cast<int>(mean2d_y + radius));

        // C1: Student-t nu parameter for this Gaussian (compute once, before pixel loop)
        float gi_nu = 0.0f;
        if (use_student_t_ && gi < nu_params_.size()) {
            gi_nu = log_nu_to_nu(nu_params_[gi]);
        }

        // B6: Check if depth loss gradient is available for this step
        bool has_depth_grad = !cpu_depth_grad_.empty() &&
                              cpu_depth_grad_.size() >= static_cast<std::size_t>(rw) * rh;

        // ── Backward: accumulate pixel-level gradients ──
        float dL_color[3] = {0, 0, 0};
        float dL_opacity = 0;
        float dL_mean2d[2] = {0, 0};
        float dL_cov2d[3] = {0, 0, 0};  // [a, b, c] = [c00, c01, c11]
        float absgrad_accum = 0.0f;      // AbsGrad: absolute per-pixel gradient magnitude
        float dL_log_nu = 0.0f;          // C1: Student-t nu gradient accumulator
        float dL_tz = 0.0f;             // B6: depth gradient → camera-space z

        for (int iy = y0; iy <= y1; ++iy) {
            for (int ix = x0; ix <= x1; ++ix) {
                float dx = static_cast<float>(ix) - mean2d_x;
                float dy = static_cast<float>(iy) - mean2d_y;

                // Mahalanobis distance
                float power = -0.5f * (c11_val*dx*dx - 2.0f*c01*dx*dy + c00*dy*dy) * inv_det;
                // Bug 0.1 fix: power should be ≤ 0 for valid Gaussians.
                // Old threshold -4.0 was far too restrictive, rejecting valid gradient
                // contributions. Use -100.0 to match standard 3DGS practice.
                if (power > 0.0f || power < -100.0f) continue;

                // C1: Student-t vs Gaussian alpha computation
                float alpha, dalpha_dopacity, dalpha_dpower_val;
                if (use_student_t_ && gi_nu > 2.0f) {
                    alpha = student_t_alpha(power, opacity, gi_nu);
                    dalpha_dpower_val = student_t_dalpha_dpower(power, opacity, gi_nu);
                    // d(alpha)/d(opacity) = t_val = alpha / opacity
                    dalpha_dopacity = (opacity > 1e-8f) ? (alpha / opacity) : 0.0f;
                } else {
                    float exp_p = std::exp(power);
                    alpha = opacity * exp_p;
                    dalpha_dpower_val = opacity * exp_p;
                    dalpha_dopacity = exp_p;
                }
                if (alpha < 1.0f / 255.0f) continue;

                std::size_t pidx = iy * rw + ix;
                float T = cpu_transmittance_[pidx];
                if (T < 0.001f) continue;

                float weight = alpha * T;

                // Image gradient at this pixel
                std::size_t cidx = pidx * 3;
                float ig[3] = {cpu_image_grad_[cidx], cpu_image_grad_[cidx+1], cpu_image_grad_[cidx+2]};

                // ── dL/d(color_i) = image_grad * alpha * T ──
                dL_color[0] += ig[0] * weight;
                dL_color[1] += ig[1] * weight;
                dL_color[2] += ig[2] * weight;

                // ── dL/d(alpha_i) = (image_grad · color) * T ──
                float dL_dalpha = (ig[0]*col_r + ig[1]*col_g + ig[2]*col_b) * T;

                // B6: Depth loss gradient contribution to alpha and position.
                // rendered_depth[pidx] += T * alpha * tz
                // → dL/d(alpha) += dL/d(depth) * T * tz
                // → dL/d(tz) += dL/d(depth) * T * alpha
                if (has_depth_grad) {
                    float dg = cpu_depth_grad_[pidx];
                    dL_dalpha += dg * T * tz;
                    dL_tz += dg * weight;  // weight = alpha * T
                }

                // ── dL/d(opacity) += dL/d(alpha) * d(alpha)/d(opacity) ──
                dL_opacity += dL_dalpha * dalpha_dopacity;

                // ── dL/d(power) = dL/d(alpha) * d(alpha)/d(power) ──
                float dL_dpower = dL_dalpha * dalpha_dpower_val;

                // C1: Student-t nu gradient accumulation
                if (use_student_t_ && gi_nu > 2.0f) {
                    float dL_dnu = dL_dalpha * student_t_dalpha_dnu(power, opacity, gi_nu);
                    // Chain rule: dL/d(log_nu) = dL/d(nu) * d(nu)/d(log_nu)
                    dL_log_nu += dL_dnu * dnu_dlog_nu(nu_params_[gi]);
                }

                // ── dL/d(mean2d): d(power)/d(dx) = -0.5*(2*c11*dx - 2*c01*dy)/det ──
                //                  d(dx)/d(mean2d_x) = -1
                float dp_ddx = -0.5f * (2.0f*c11_val*dx - 2.0f*c01*dy) * inv_det;
                float dp_ddy = -0.5f * (-2.0f*c01*dx + 2.0f*c00*dy) * inv_det;
                float pixel_grad_x = -dL_dpower * dp_ddx;
                float pixel_grad_y = -dL_dpower * dp_ddy;
                dL_mean2d[0] += pixel_grad_x;  // -1 from d(dx)/d(mean2d_x)
                dL_mean2d[1] += pixel_grad_y;

                // AbsGrad: accumulate |per-pixel gradient| to prevent
                // multi-view cancellation (gsplat, Ye et al. 2024).
                // Standard 3DGS sums signed gradients then takes ||·||,
                // so opposing views cancel → blocks split/clone of large Gaussians.
                absgrad_accum += std::sqrt(pixel_grad_x * pixel_grad_x +
                                           pixel_grad_y * pixel_grad_y);

                // ── dL/d(cov2d): partial derivatives of power w.r.t. cov2d ──
                // power = -0.5 * N / D, N = c11*dx²-2*c01*dx*dy+c00*dy², D = c00*c11-c01²
                float N = c11_val*dx*dx - 2.0f*c01*dx*dy + c00*dy*dy;
                float inv_D2 = inv_det * inv_det;

                // dp/d(c00) = -0.5 * (dy²*D - N*c11) / D²
                dL_cov2d[0] += dL_dpower * (-0.5f) * (dy*dy*det - N*c11_val) * inv_D2;
                // dp/d(c01) = -0.5 * (-2*dx*dy*D + 2*N*c01) / D²
                dL_cov2d[1] += dL_dpower * (-0.5f) * (-2.0f*dx*dy*det + 2.0f*N*c01) * inv_D2;
                // dp/d(c11) = -0.5 * (dx²*D - N*c00) / D²
                dL_cov2d[2] += dL_dpower * (-0.5f) * (dx*dx*det - N*c00) * inv_D2;

                // Update transmittance (same as forward)
                cpu_transmittance_[pidx] *= (1.0f - alpha);
            }
        }

        // ── Store color and opacity gradients ──
        grad[3] = dL_color[0];
        grad[4] = dL_color[1];
        grad[5] = dL_color[2];
        // Chain rule for logit reparameterization:
        // dL/d(logit) = dL/d(opacity) × d(sigmoid)/d(logit)
        //             = dL/d(opacity) × opacity × (1 - opacity)
        grad[6] = dL_opacity * opacity * (1.0f - opacity);

        // ── Chain: dL/d(mean2d) → dL/d(position) ──
        // mean2d_x = fx * tx/tz + cx
        // d(mean2d_x)/d(px) = fx * (V00*tz - tx*V20) / tz²
        float dm_x_dpx = intr.fx * (v00*tz - tx*v20) * inv_tz2;
        float dm_x_dpy = intr.fx * (v01*tz - tx*v21) * inv_tz2;
        float dm_x_dpz = intr.fx * (v02*tz - tx*v22) * inv_tz2;
        float dm_y_dpx = intr.fy * (v10*tz - ty*v20) * inv_tz2;
        float dm_y_dpy = intr.fy * (v11*tz - ty*v21) * inv_tz2;
        float dm_y_dpz = intr.fy * (v12*tz - ty*v22) * inv_tz2;

        grad[0] = dL_mean2d[0]*dm_x_dpx + dL_mean2d[1]*dm_y_dpx;
        grad[1] = dL_mean2d[0]*dm_x_dpy + dL_mean2d[1]*dm_y_dpy;
        grad[2] = dL_mean2d[0]*dm_x_dpz + dL_mean2d[1]*dm_y_dpz;

        // B6: Depth loss → position gradient via camera-space z.
        // tz = v20*px + v21*py + v22*pz + view[14]
        // d(tz)/d(px) = v20, d(tz)/d(py) = v21, d(tz)/d(pz) = v22
        if (has_depth_grad && std::fabs(dL_tz) > 1e-10f) {
            grad[0] += dL_tz * v20;
            grad[1] += dL_tz * v21;
            grad[2] += dL_tz * v22;
        }

        // Bug 0.36 fix: clamp cov2d gradients to prevent explosion when
        // determinant is near the threshold. Without this, unbounded gradients
        // propagate through the cov3d→scale→rotation chain.
        constexpr float kMaxCov2dGrad = 1e4f;
        for (int ci = 0; ci < 3; ++ci) {
            dL_cov2d[ci] = std::clamp(dL_cov2d[ci], -kMaxCov2dGrad, kMaxCov2dGrad);
        }

        // ── Chain: dL/d(cov2d) → dL/d(cov3d) ──
        // cov2d = T * cov3d * T^T, T is 2x3
        // d(cov2d)/d(cov3d_ij) = T_row_a[i]*T_row_b[j] + T_row_a[j]*T_row_b[i] (for i≠j)
        // For symmetric cov3d stored as [s00,s01,s02,s11,s12,s22]:
        float dL_cov3d[6] = {0};
        // d(c00)/d(s_kl) = 2*t0k*t0l (off-diag doubled)
        dL_cov3d[0] = dL_cov2d[0]*t_00*t_00 + dL_cov2d[2]*t_10*t_10;  // s00
        dL_cov3d[1] = dL_cov2d[0]*2*t_00*t_01 + dL_cov2d[2]*2*t_10*t_11
                     + dL_cov2d[1]*(t_00*t_11 + t_01*t_10);              // s01
        dL_cov3d[2] = dL_cov2d[0]*2*t_00*t_02 + dL_cov2d[2]*2*t_10*t_12
                     + dL_cov2d[1]*(t_00*t_12 + t_02*t_10);              // s02
        dL_cov3d[3] = dL_cov2d[0]*t_01*t_01 + dL_cov2d[2]*t_11*t_11
                     + dL_cov2d[1]*t_01*t_11;                             // s11
        dL_cov3d[4] = dL_cov2d[0]*2*t_01*t_02 + dL_cov2d[2]*2*t_11*t_12
                     + dL_cov2d[1]*(t_01*t_12 + t_02*t_11);              // s12
        dL_cov3d[5] = dL_cov2d[0]*t_02*t_02 + dL_cov2d[2]*t_12*t_12
                     + dL_cov2d[1]*t_02*t_12;                             // s22

        // ── Chain: dL/d(cov3d) → dL/d(scale) ──
        // cov3d_kl = Σ_i (R_ki*s_i) * (R_li*s_i) = Σ_i R_ki * R_li * s_i²
        // d(cov3d_kl)/d(s_j) = 2 * s_j * R_kj * R_lj
        // Bug 0.12 fix: removed dead code (first ds computation was overwritten)
        for (int j = 0; j < 3; ++j) {
            float scale_vals[3] = {sx, sy, sz};
            float s_j = scale_vals[j];
            float ds = 0.0f;
            ds += dL_cov3d[0] * 2.0f * s_j * Rot[0*3+j] * Rot[0*3+j];
            ds += dL_cov3d[1] * 2.0f * s_j * Rot[0*3+j] * Rot[1*3+j];
            ds += dL_cov3d[2] * 2.0f * s_j * Rot[0*3+j] * Rot[2*3+j];
            ds += dL_cov3d[3] * 2.0f * s_j * Rot[1*3+j] * Rot[1*3+j];
            ds += dL_cov3d[4] * 2.0f * s_j * Rot[1*3+j] * Rot[2*3+j];
            ds += dL_cov3d[5] * 2.0f * s_j * Rot[2*3+j] * Rot[2*3+j];

            // Chain rule for log reparameterization:
            // dL/d(log_s_j) = dL/d(s_j) × d(exp)/d(log_s) = dL/d(s_j) × s_j
            grad[7+j] = ds * s_j;
        }

        // ── Chain: dL/d(cov3d) → dL/d(rotation) via d(R)/d(quaternion) ──
        // M = R * S → cov3d_kl = Σ_i R_ki * R_li * s_i²
        // First compute dL/d(R_mn):
        float dL_dR[9] = {0};
        for (int m = 0; m < 3; ++m) {
            for (int n = 0; n < 3; ++n) {
                // Use activated scale (exp of log-space), NOT raw log params
                float s_n_act = scale_activated[n];
                float s_n2 = s_n_act * s_n_act;  // scale[n]²
                // d(cov3d_kl)/d(R_mn) = s_n² * (δ(k=m)*R_ln + R_kn*δ(l=m))
                // Sum contributions from all 6 upper-triangle elements
                // Σ00 (k=l=0): 2*δ(0=m)*R[0n]*s_n²
                // Σ01 (k=0,l=1): δ(0=m)*R[1n]*s_n² + R[0n]*s_n²*δ(1=m)
                // etc.
                float d = 0.0f;
                // From Σ00: dL_cov3d[0] * 2*s_n² * R[0n] if m=0
                if (m == 0) d += dL_cov3d[0] * 2.0f * s_n2 * Rot[0*3+n];
                if (m == 1) d += dL_cov3d[3] * 2.0f * s_n2 * Rot[1*3+n];
                if (m == 2) d += dL_cov3d[5] * 2.0f * s_n2 * Rot[2*3+n];
                // From off-diag: Σ01
                d += dL_cov3d[1] * s_n2 * ((m==0 ? Rot[1*3+n] : 0.0f) + (m==1 ? Rot[0*3+n] : 0.0f));
                // Σ02
                d += dL_cov3d[2] * s_n2 * ((m==0 ? Rot[2*3+n] : 0.0f) + (m==2 ? Rot[0*3+n] : 0.0f));
                // Σ12
                d += dL_cov3d[4] * s_n2 * ((m==1 ? Rot[2*3+n] : 0.0f) + (m==2 ? Rot[1*3+n] : 0.0f));

                dL_dR[m*3+n] = d;
            }
        }

        // dR/d(quaternion): analytical derivatives of rotation matrix w.r.t. (w,x,y,z)
        // R00 = 1-2(yy+zz), R01 = 2(xy-wz), R02 = 2(xz+wy), etc.
        float dL_dqw = 0, dL_dqx = 0, dL_dqy = 0, dL_dqz = 0;

        // dR00/dw=0, dR00/dx=0, dR00/dy=-4y, dR00/dz=-4z
        dL_dqy += dL_dR[0] * (-4.0f*qy);
        dL_dqz += dL_dR[0] * (-4.0f*qz);
        // dR01/dw=-2z, dR01/dx=2y, dR01/dy=2x, dR01/dz=-2w
        dL_dqw += dL_dR[1] * (-2.0f*qz);
        dL_dqx += dL_dR[1] * (2.0f*qy);
        dL_dqy += dL_dR[1] * (2.0f*qx);
        dL_dqz += dL_dR[1] * (-2.0f*qw);
        // dR02/dw=2y, dR02/dx=2z, dR02/dy=2w, dR02/dz=2x
        dL_dqw += dL_dR[2] * (2.0f*qy);
        dL_dqx += dL_dR[2] * (2.0f*qz);
        dL_dqy += dL_dR[2] * (2.0f*qw);
        dL_dqz += dL_dR[2] * (2.0f*qx);
        // dR10/dw=2z, dR10/dx=2y, dR10/dy=2x, dR10/dz=2w
        dL_dqw += dL_dR[3] * (2.0f*qz);
        dL_dqx += dL_dR[3] * (2.0f*qy);
        dL_dqy += dL_dR[3] * (2.0f*qx);
        dL_dqz += dL_dR[3] * (2.0f*qw);
        // dR11/dw=0, dR11/dx=-4x, dR11/dy=0, dR11/dz=-4z
        dL_dqx += dL_dR[4] * (-4.0f*qx);
        dL_dqz += dL_dR[4] * (-4.0f*qz);
        // dR12/dw=-2x, dR12/dx=-2w, dR12/dy=2z, dR12/dz=2y
        dL_dqw += dL_dR[5] * (-2.0f*qx);
        dL_dqx += dL_dR[5] * (-2.0f*qw);
        dL_dqy += dL_dR[5] * (2.0f*qz);
        dL_dqz += dL_dR[5] * (2.0f*qy);
        // dR20/dw=-2y, dR20/dx=2z, dR20/dy=-2w, dR20/dz=2x
        dL_dqw += dL_dR[6] * (-2.0f*qy);
        dL_dqx += dL_dR[6] * (2.0f*qz);
        dL_dqy += dL_dR[6] * (-2.0f*qw);
        dL_dqz += dL_dR[6] * (2.0f*qx);
        // dR21/dw=2x, dR21/dx=2w, dR21/dy=2z, dR21/dz=2y
        dL_dqw += dL_dR[7] * (2.0f*qx);
        dL_dqx += dL_dR[7] * (2.0f*qw);
        dL_dqy += dL_dR[7] * (2.0f*qz);
        dL_dqz += dL_dR[7] * (2.0f*qy);
        // dR22/dw=0, dR22/dx=-4x, dR22/dy=-4y, dR22/dz=0
        dL_dqx += dL_dR[8] * (-4.0f*qx);
        dL_dqy += dL_dR[8] * (-4.0f*qy);

        grad[10] = dL_dqw;
        grad[11] = dL_dqx;
        grad[12] = dL_dqy;
        grad[13] = dL_dqz;

        // ── Accumulate screen-space gradient magnitude for densification ──
        // Using AbsGrad (absolute per-pixel gradient sum) instead of
        // ||signed_sum||. AbsGrad prevents multi-view gradient cancellation
        // that blocks densification of large Gaussians covering multiple objects.
        screen_grad_accum_[gi] += absgrad_accum;
        grad_count_[gi]++;

        // C1: Store Student-t nu gradient
        if (use_student_t_ && gi < nu_grad_.size()) {
            nu_grad_[gi] += dL_log_nu;
        }
    }
}

void GaussianTrainingEngine::densify_and_prune() noexcept {
    // Clone/split Gaussians with large screen-space gradients.
    // Split: large Gaussians → two smaller Gaussians (under-reconstruction)
    // Clone: small Gaussians → duplicate at same position (under-coverage)
    // Reference: 3DGS paper (Kerbl et al., 2023) Section 5

    // ─── Stability guard 3: Compute scene bounding sphere for position check ───
    // Gaussians that fly far from the scene center waste computation and can
    // destabilize sorting/rasterization. Prune those > 10× scene_radius.
    double cx = 0, cy = 0, cz = 0;
    for (std::size_t i = 0; i < num_gaussians_; ++i) {
        const float* p = params_.data() + i * kParamsPerGaussian;
        cx += p[0]; cy += p[1]; cz += p[2];
    }
    float inv_n = 1.0f / static_cast<float>(std::max(num_gaussians_, std::size_t(1)));
    float center_x = static_cast<float>(cx * inv_n);
    float center_y = static_cast<float>(cy * inv_n);
    float center_z = static_cast<float>(cz * inv_n);

    float max_dist_sq = 0.0f;
    for (std::size_t i = 0; i < num_gaussians_; ++i) {
        const float* p = params_.data() + i * kParamsPerGaussian;
        float dx = p[0] - center_x, dy = p[1] - center_y, dz = p[2] - center_z;
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > max_dist_sq) max_dist_sq = d2;
    }
    float scene_radius = std::sqrt(max_dist_sq);
    float prune_radius_sq = (10.0f * scene_radius) * (10.0f * scene_radius);
    // Minimum prune radius to avoid pruning everything in tiny scenes
    if (prune_radius_sq < 1.0f) prune_radius_sq = 100.0f;

    std::vector<splat::GaussianParams> new_gaussians;
    std::vector<std::uint8_t> keep_mask(num_gaussians_, 1);

    // C2: Only enable importance-death under true emergency pressure.
    // Photo-SLAM/MonoGS style growth should keep climbing until memory pressure or
    // GPU buffers force a stop. A soft preset target is not a valid reason to kill.
    const std::size_t mcmc_death_threshold =
        static_cast<std::size_t>(config_.max_gaussians * 0.98f);
    bool has_grad_data = false;
    for (std::size_t i = 0; i < grad_count_.size() && i < num_gaussians_; ++i) {
        if (grad_count_[i] > 0) { has_grad_data = true; break; }
    }
    if (use_mcmc_noise_ &&
        memory_budget_.should_force_prune() &&
        num_gaussians_ > mcmc_death_threshold &&
        has_grad_data) {
        std::vector<float> importance(num_gaussians_);
        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            const float* p = params_.data() + i * kParamsPerGaussian;
            float op = sigmoid(p[6]);
            float scale[3] = {
                std::exp(std::clamp(p[7], -10.0f, 10.0f)),
                std::exp(std::clamp(p[8], -10.0f, 10.0f)),
                std::exp(std::clamp(p[9], -10.0f, 10.0f))
            };
            float pixel_contrib = static_cast<float>(grad_count_[i]);
            importance[i] = compute_importance(pixel_contrib, op, scale);
        }
        // Kill bottom 5% (capped to percentile×count, see find_death_candidates fix)
        std::vector<std::size_t> death_candidates;
        find_death_candidates(importance.data(), num_gaussians_,
                              0.02f, death_candidates);
        for (std::size_t idx : death_candidates) {
            keep_mask[idx] = 0;
        }
    }

    // ── MonoGS big_points_ws: world-space scale pruning ──
    // Directly from MonoGS densify_and_prune:
    //   big_points_ws = self.get_scaling.max(dim=1).values > 0.1 * extent
    // extent = scene_radius (max dist from centroid to any Gaussian).
    // Room scene_radius ≈ 2.4m → threshold ≈ 0.24m.
    // TSDF seeds scale 0.003-0.012m → never triggered.
    // Only catches optimizer-exploded scales.
    {
        const float big_ws_threshold = scene_radius * 0.1f;
        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            if (!keep_mask[i]) continue;
            const float* p = params_.data() + i * kParamsPerGaussian;
            float ms = std::max({
                std::exp(std::clamp(p[7], -10.0f, 10.0f)),
                std::exp(std::clamp(p[8], -10.0f, 10.0f)),
                std::exp(std::clamp(p[9], -10.0f, 10.0f))
            });
            if (ms > big_ws_threshold) {
                keep_mask[i] = 0;
            }
        }
    }

    // Threshold for distinguishing split vs clone: Gaussians with max scale
    // above this are "large" (should be split), below are "small" (should be cloned).
    const float split_scale_threshold = config_.densify_max_screen_size * 0.01f;

    for (std::size_t i = 0; i < num_gaussians_; ++i) {
        float* p = params_.data() + i * kParamsPerGaussian;
        float avg_grad = (grad_count_[i] > 0) ?
            screen_grad_accum_[i] / grad_count_[i] : 0.0f;

        float real_opacity = sigmoid(p[6]);

        // Prune: opacity too low — directly from MonoGS densify_and_prune:
        //   prune_mask = (self.get_opacity < min_opacity).squeeze()
        // min_opacity = 0.005. TSDF seeds init at 0.1-0.85, so this only
        // fires when optimizer drives opacity to near-zero (dead Gaussians).
        if (real_opacity < config_.prune_opacity_threshold) {
            keep_mask[i] = 0;
            continue;
        }

        // grad_count==0 pruning DISABLED: with dense TSDF initialization (1M Gaussians),
        // back-layer Gaussians are occluded by front-layer ones in every training view.
        // This is expected behavior — they contribute via alpha-blending after front
        // Gaussians become transparent. Pruning on grad_count==0 collapses the scene
        // from 954K to ~2 within 3000 steps. Opacity-only pruning is sufficient.

        // Prune: position far from scene center (prevents fly-away Gaussians)
        {
            float dx = p[0] - center_x, dy = p[1] - center_y, dz = p[2] - center_z;
            float d2 = dx * dx + dy * dy + dz * dz;
            if (d2 > prune_radius_sq) {
                keep_mask[i] = 0;
                continue;
            }
        }

        // Densify: large gradient → split or clone
        // B8: Improved ADC (Fraunhofer 2025) — exponential rising threshold.
        // Early: aggressive densify (low threshold), Late: conservative (high threshold).
        // Bug 0.31 fix: use <= instead of < so we can reach exactly max_gaussians
        float adaptive_threshold = adaptive_densify_threshold(
            preset_.densify_grad_threshold_init,
            preset_.densify_grad_threshold_final,
            current_step_.load(std::memory_order_relaxed),
            config_.max_iterations);
        if (avg_grad > adaptive_threshold &&
            num_gaussians_ + new_gaussians.size() <= config_.max_gaussians) {

            // Convert from logit/log internal space to natural space for manipulation
            // Bug 0.7 fix (also here): clamp before exp
            float real_scale[3] = {
                std::exp(std::clamp(p[7], -10.0f, 10.0f)),
                std::exp(std::clamp(p[8], -10.0f, 10.0f)),
                std::exp(std::clamp(p[9], -10.0f, 10.0f))
            };

            splat::GaussianParams new_g{};
            std::memcpy(new_g.position, p, 3 * sizeof(float));
            std::memcpy(new_g.color, p + 3, 3 * sizeof(float));
            new_g.opacity = real_opacity;
            new_g.scale[0] = real_scale[0];
            new_g.scale[1] = real_scale[1];
            new_g.scale[2] = real_scale[2];
            std::memcpy(new_g.rotation, p + 10, 4 * sizeof(float));

            float max_scale = std::max({real_scale[0], real_scale[1], real_scale[2]});

            if (max_scale > split_scale_threshold) {
                // ── SPLIT: Large Gaussian → two smaller ones ──
                // C2b: SteepGS — use Hessian-guided split direction if saddle detected,
                // otherwise fall back to dominant axis (standard 3DGS).
                int axis = 0;
                bool steepgs_split = false;
                if (use_steepgs_ && i * 3 + 2 < prev_position_grad_.size()) {
                    float current_grad[3] = {
                        gradients_[i * kParamsPerGaussian + 0],
                        gradients_[i * kParamsPerGaussian + 1],
                        gradients_[i * kParamsPerGaussian + 2]
                    };
                    SteepGSState state;
                    state.prev_grad[0] = prev_position_grad_[i * 3 + 0];
                    state.prev_grad[1] = prev_position_grad_[i * 3 + 1];
                    state.prev_grad[2] = prev_position_grad_[i * 3 + 2];
                    state.prev_pos[0] = prev_position_[i * 3 + 0];
                    state.prev_pos[1] = prev_position_[i * 3 + 1];
                    state.prev_pos[2] = prev_position_[i * 3 + 2];
                    state.has_prev = true;
                    SteepGSConfig steep_cfg;
                    float split_dir[3];
                    if (steepgs_detect_saddle(current_grad, state, p, steep_cfg, split_dir)) {
                        // Find the axis corresponding to the split direction
                        for (int d = 0; d < 3; ++d) {
                            if (split_dir[d] > 0.5f) { axis = d; break; }
                        }
                        steepgs_split = true;
                    }
                }
                if (!steepgs_split) {
                    // Standard 3DGS: dominant axis (largest scale)
                    if (real_scale[1] > real_scale[axis]) axis = 1;
                    if (real_scale[2] > real_scale[axis]) axis = 2;
                }

                // Offset along split axis by 0.5σ
                float offset = real_scale[axis] * 0.5f;
                new_g.position[axis] += offset;

                // Both new and original shrink by factor 1/1.6 (per 3DGS paper)
                const float shrink = 1.0f / 1.6f;
                new_g.scale[0] *= shrink;
                new_g.scale[1] *= shrink;
                new_g.scale[2] *= shrink;

                // Shrink the original in log space: log(s*shrink) = log(s) + log(shrink)
                float log_shrink = std::log(shrink);
                p[7] += log_shrink;
                p[8] += log_shrink;
                p[9] += log_shrink;

                // Offset original in opposite direction
                p[axis] -= offset * shrink;
            } else {
                // ── CLONE: Small Gaussian → duplicate (no scale change) ──
                new_g.position[0] += max_scale * 0.1f;
                new_g.position[1] += max_scale * 0.1f;
                new_g.position[2] += max_scale * 0.1f;
            }

            new_gaussians.push_back(new_g);
        }
    }

    // Compact pruned Gaussians
    optimizer_.compact(keep_mask.data(), num_gaussians_);

    std::size_t write = 0;
    for (std::size_t i = 0; i < num_gaussians_; ++i) {
        if (keep_mask[i]) {
            if (write != i) {
                std::memcpy(params_.data() + write * kParamsPerGaussian,
                            params_.data() + i * kParamsPerGaussian,
                            kParamsPerGaussian * sizeof(float));
                // C1: Compact Student-t nu vectors in parallel
                if (use_student_t_ && i < nu_params_.size()) {
                    nu_params_[write] = nu_params_[i];
                    nu_grad_[write] = nu_grad_[i];
                    nu_m1_[write] = nu_m1_[i];
                    nu_m2_[write] = nu_m2_[i];
                }
                // C2b: Compact SteepGS vectors
                if (use_steepgs_ && i * 3 + 2 < prev_position_grad_.size()) {
                    for (int d = 0; d < 3; ++d) {
                        prev_position_grad_[write * 3 + d] = prev_position_grad_[i * 3 + d];
                        prev_position_[write * 3 + d] = prev_position_[i * 3 + d];
                    }
                }
                // Compact anchor positions
                if (i * 3 + 2 < anchor_positions_.size()) {
                    for (int d = 0; d < 3; ++d) {
                        anchor_positions_[write * 3 + d] = anchor_positions_[i * 3 + d];
                    }
                }
            }
            write++;
        }
    }
    num_gaussians_ = write;

    // Add cloned Gaussians (capped to max_gaussians AND memory budget)
    if (!new_gaussians.empty()) {
        std::size_t old_count = num_gaussians_;
        std::size_t add_count = new_gaussians.size();
        // CRITICAL: Cap to GPU buffer capacity. Without this, num_gaussians_ can
        // exceed config_.max_gaussians after clone/split, causing memcpy to read
        // past the GPU buffer end → EXC_BAD_ACCESS (KERN_PROTECTION_FAILURE).
        if (old_count + add_count > config_.max_gaussians) {
            add_count = (old_count < config_.max_gaussians)
                ? config_.max_gaussians - old_count : 0;
        }
        // Memory budget cap: also limit by available headroom
        std::size_t headroom = memory_budget_.headroom(MemoryPressure::kCritical);
        if (add_count > headroom) {
            add_count = headroom;
        }
        if (add_count == 0) goto skip_clone;
        num_gaussians_ = old_count + add_count;
        params_.resize(num_gaussians_ * kParamsPerGaussian);
        gradients_.resize(num_gaussians_ * kParamsPerGaussian, 0.0f);

        for (std::size_t i = 0; i < add_count; ++i) {
            float* dst = params_.data() + (old_count + i) * kParamsPerGaussian;
            const auto& g = new_gaussians[i];
            std::memcpy(dst, g.position, 3 * sizeof(float));
            std::memcpy(dst + 3, g.color, 3 * sizeof(float));
            // Convert to logit/log internal space
            dst[6] = logit(g.opacity);
            dst[7] = safe_log(g.scale[0]);
            dst[8] = safe_log(g.scale[1]);
            dst[9] = safe_log(g.scale[2]);
            std::memcpy(dst + 10, g.rotation, 4 * sizeof(float));
        }

        optimizer_.grow(add_count);

        // C1: Grow Student-t nu vectors for new Gaussians
        if (use_student_t_) {
            nu_params_.resize(num_gaussians_, 1.0f);   // log(nu-2), nu ≈ 4.72
            nu_grad_.resize(num_gaussians_, 0.0f);
            nu_m1_.resize(num_gaussians_, 0.0f);
            nu_m2_.resize(num_gaussians_, 0.0f);
        }
        // C2b: Grow SteepGS vectors
        if (use_steepgs_) {
            prev_position_grad_.resize(num_gaussians_ * 3, 0.0f);
            prev_position_.resize(num_gaussians_ * 3, 0.0f);
        }
        // Grow anchor positions: new Gaussians' anchor = their birth position
        anchor_positions_.resize(num_gaussians_ * 3);
        for (std::size_t i = 0; i < add_count; ++i) {
            const auto& g = new_gaussians[i];
            anchor_positions_[(old_count + i) * 3 + 0] = g.position[0];
            anchor_positions_[(old_count + i) * 3 + 1] = g.position[1];
            anchor_positions_[(old_count + i) * 3 + 2] = g.position[2];
        }
    }
    skip_clone:

    // C2: MCMC error-guided birth — spawn new Gaussians at under-represented regions.
    // Uses per-pixel L1 error from last forward pass to find gaps.
    // S3: Progressive MCMC densification — increased birth rate for denser models.
    //   Old: budget=50 per interval, threshold=0.15 → slow growth.
    //   New: budget=200 per interval, threshold=0.10 → 4× faster growth.
    //   Combined with S1 (per-voxel) and S2 (5mm voxels), enables 1M+ convergence.
    if (use_mcmc_noise_ && !rendered_image_.empty() && !target_image_.empty() &&
        num_gaussians_ < config_.max_gaussians &&
        memory_budget_.allow_densification() &&
        last_frame_idx_ < frames_.size()) {
        std::uint32_t rw = config_.render_width;
        std::uint32_t rh = config_.render_height;
        if (rw > 0 && rh > 0 && rendered_image_.size() >= rw * rh * 3) {
            // Compute per-pixel error map
            std::vector<float> error_map(rw * rh);
            for (std::size_t j = 0; j < rw * rh; ++j) {
                float er = std::fabs(rendered_image_[j * 3 + 0] - target_image_[j * 3 + 0]);
                float eg = std::fabs(rendered_image_[j * 3 + 1] - target_image_[j * 3 + 1]);
                float eb = std::fabs(rendered_image_[j * 3 + 2] - target_image_[j * 3 + 2]);
                error_map[j] = (er + eg + eb) / 3.0f;
            }

            // Find high-error pixels
            // S3: Budget = 200 per densify interval (4× higher than before).
            // Memory budget headroom also caps the birth count.
            std::vector<float> px_vals, py_vals, depth_vals;
            std::size_t mem_headroom = memory_budget_.headroom(MemoryPressure::kHigh);
            std::uint32_t budget = static_cast<std::uint32_t>(std::min({
                static_cast<std::size_t>(200),
                static_cast<std::size_t>(config_.max_gaussians - num_gaussians_),
                mem_headroom}));
            // S3: Lower error threshold (0.10 vs 0.15) → catches more under-reconstructed areas
            std::uint32_t found = find_high_error_pixels(
                error_map.data(),
                cpu_rendered_depth_.empty() ? nullptr : cpu_rendered_depth_.data(),
                rw, rh, 0.10f, budget, px_vals, py_vals, depth_vals);

            if (found > 0) {
                // Reconstruct inverse view for backprojection
                const TrainingFrame& frame = frames_[last_frame_idx_];
                splat::CameraIntrinsics intr{
                    frame.intrinsics[0] * rw / static_cast<float>(frame.width),
                    frame.intrinsics[1] * rh / static_cast<float>(frame.height),
                    frame.intrinsics[2] * rw / static_cast<float>(frame.width),
                    frame.intrinsics[3] * rh / static_cast<float>(frame.height)
                };

                std::size_t birth_count = 0;
	                for (std::uint32_t k = 0; k < found && num_gaussians_ < config_.max_gaussians; ++k) {
	                    float pos[3];
	                    if (backproject_pixel(px_vals[k], py_vals[k], depth_vals[k],
	                                          frame.transform, intr.fx, intr.fy, intr.cx, intr.cy, pos)) {
	                        float rgb[3];
	                        sample_frame_color(frame, px_vals[k], py_vals[k], rw, rh, rgb);
	                        // Initialize new Gaussian at backprojected position
	                        params_.resize((num_gaussians_ + 1) * kParamsPerGaussian);
	                        gradients_.resize((num_gaussians_ + 1) * kParamsPerGaussian, 0.0f);
	                        float* dst = params_.data() + num_gaussians_ * kParamsPerGaussian;
	                        dst[0] = pos[0]; dst[1] = pos[1]; dst[2] = pos[2];
	                        dst[3] = rgb[0];
	                        dst[4] = rgb[1];
	                        dst[5] = rgb[2];
	                        dst[6] = 0.0f;  // logit(0.5) = 0
                        dst[7] = std::log(0.01f); dst[8] = std::log(0.01f); dst[9] = std::log(0.01f);
                        dst[10] = 1.0f; dst[11] = 0.0f; dst[12] = 0.0f; dst[13] = 0.0f;
                        num_gaussians_++;
                        birth_count++;
                    }
                }
                if (birth_count > 0) {
                    optimizer_.grow(birth_count);
                }
            }
        }
    }

    // Resize nu/steepgs vectors after compaction (even if no new Gaussians added)
    if (use_student_t_) {
        nu_params_.resize(num_gaussians_, 1.0f);
        nu_grad_.resize(num_gaussians_, 0.0f);
        nu_m1_.resize(num_gaussians_, 0.0f);
        nu_m2_.resize(num_gaussians_, 0.0f);
    }
    if (use_steepgs_) {
        prev_position_grad_.resize(num_gaussians_ * 3, 0.0f);
        prev_position_.resize(num_gaussians_ * 3, 0.0f);
    }

    // Resize anchor positions after all compaction/growth.
    // For MCMC-born Gaussians, their anchor = birth position (already in params_).
    {
        std::size_t old_anchor_n = anchor_positions_.size() / 3;
        anchor_positions_.resize(num_gaussians_ * 3, 0.0f);
        for (std::size_t i = old_anchor_n; i < num_gaussians_; ++i) {
            const float* p = params_.data() + i * kParamsPerGaussian;
            anchor_positions_[i * 3 + 0] = p[0];
            anchor_positions_[i * 3 + 1] = p[1];
            anchor_positions_[i * 3 + 2] = p[2];
        }
    }

    // Reset accumulators
    screen_grad_accum_.assign(num_gaussians_, 0.0f);
    grad_count_.assign(num_gaussians_, 0);
}

void GaussianTrainingEngine::params_to_flat(
    const splat::GaussianParams* src, std::size_t count) noexcept
{
    for (std::size_t i = 0; i < count; ++i) {
        float* dst = params_.data() + i * kParamsPerGaussian;
        std::memcpy(dst, src[i].position, 3 * sizeof(float));       // [0..2] position
        std::memcpy(dst + 3, src[i].color, 3 * sizeof(float));      // [3..5] color (linear)
        // Logit/Log reparameterization:
        // Internal: logit(opacity), log(scale) — optimizer works in unconstrained space
        // Forward: sigmoid(logit) → opacity ∈ (0,1), exp(log_s) → scale > 0
        dst[6] = logit(src[i].opacity);                              // [6] logit(opacity)
        dst[7] = safe_log(src[i].scale[0]);                          // [7] log(scale_x)
        dst[8] = safe_log(src[i].scale[1]);                          // [8] log(scale_y)
        dst[9] = safe_log(src[i].scale[2]);                          // [9] log(scale_z)
        std::memcpy(dst + 10, src[i].rotation, 4 * sizeof(float));  // [10..13] quaternion
    }
}

void GaussianTrainingEngine::flat_to_params(
    splat::GaussianParams* dst, std::size_t count) const noexcept
{
    for (std::size_t i = 0; i < count; ++i) {
        const float* src = params_.data() + i * kParamsPerGaussian;
        std::memcpy(dst[i].position, src, 3 * sizeof(float));

        // Clamp colors to [0, 1] — training gradients (Adam) can push values
        // outside valid range. Negative colors become black in pack_gaussian;
        // values > 1 clip to white. Clamping here ensures valid export data.
        dst[i].color[0] = src[3] < 0.0f ? 0.0f : (src[3] > 1.0f ? 1.0f : src[3]);
        dst[i].color[1] = src[4] < 0.0f ? 0.0f : (src[4] > 1.0f ? 1.0f : src[4]);
        dst[i].color[2] = src[5] < 0.0f ? 0.0f : (src[5] > 1.0f ? 1.0f : src[5]);

        // Logit → sigmoid for opacity: automatically in (0, 1), no clamping needed
        dst[i].opacity = sigmoid(src[6]);

        // Log → exp for scale: automatically > 0
        // Bug 0.53 fix: clamp before exp to prevent Inf
        dst[i].scale[0] = std::exp(std::clamp(src[7], -10.0f, 10.0f));
        dst[i].scale[1] = std::exp(std::clamp(src[8], -10.0f, 10.0f));
        dst[i].scale[2] = std::exp(std::clamp(src[9], -10.0f, 10.0f));

        std::memcpy(dst[i].rotation, src + 10, 4 * sizeof(float));

        // Training only optimises 14 params (no SH).  Explicitly zero sh1[]
        // so exported PLY and push_splats() never contain garbage SH data.
        std::memset(dst[i].sh1, 0, sizeof(dst[i].sh1));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// B3: Temporal-Focal Frame Sampling
// ═══════════════════════════════════════════════════════════════════════
// Replaces uniform random sampling with a 70/30 focal/maintenance split.
// Focal window = latest N frames (captures the current scan region).
// Maintenance pool = all frames (prevents catastrophic forgetting).

std::size_t GaussianTrainingEngine::sample_focal_frame() noexcept {
    static thread_local std::mt19937 rng(std::random_device{}());

    if (frames_.empty()) return 0;
    if (frames_.size() == 1) return 0;

    std::size_t total = frames_.size();
    std::size_t window_size = preset_.temporal_window_size;
    if (window_size == 0) window_size = 5;

    // Focal window: last N frames (sorted by insertion order = capture order)
    std::size_t focal_start = (total > window_size) ? (total - window_size) : 0;
    std::size_t focal_count = total - focal_start;

    auto collect_eligible = [&](std::size_t begin, std::size_t end,
                                std::vector<std::size_t>& out) {
        out.clear();
        for (std::size_t i = begin; i < end; ++i) {
            if (frames_[i].remaining_times_of_use > 0) out.push_back(i);
        }
    };
    auto replenish = [&](std::size_t begin, std::size_t end, int refill) {
        for (std::size_t i = begin; i < end; ++i) {
            frames_[i].remaining_times_of_use =
                std::max(frames_[i].remaining_times_of_use, refill);
        }
    };

    std::vector<std::size_t> eligible;
    std::uniform_real_distribution<float> coin(0.0f, 1.0f);
    const bool use_focal = coin(rng) < preset_.focal_sampling_prob && focal_count > 0;
    const std::size_t begin = use_focal ? focal_start : 0;
    const std::size_t end = use_focal ? total : total;

    collect_eligible(begin, end, eligible);
    if (eligible.empty()) {
        replenish(begin, end, use_focal ? 2 : 1);
        collect_eligible(begin, end, eligible);
    }
    if (eligible.empty()) {
        replenish(0, total, 1);
        collect_eligible(0, total, eligible);
    }
    if (eligible.empty()) {
        return total - 1;
    }

    std::uniform_int_distribution<std::size_t> pick(0, eligible.size() - 1);
    const std::size_t selected = eligible[pick(rng)];
    if (frames_[selected].remaining_times_of_use > 0) {
        --frames_[selected].remaining_times_of_use;
    }
    return selected;
}

std::size_t GaussianTrainingEngine::training_frame_budget() const noexcept {
    const std::size_t base_window =
        std::max<std::size_t>(preset_.temporal_window_size, 6);
    std::size_t budget = std::clamp<std::size_t>(base_window * 4, 24, 64);
    if (memory_budget_.pressure() >= MemoryPressure::kHigh) {
        budget = std::max<std::size_t>(base_window * 2, 16);
    } else if (memory_budget_.pressure() >= MemoryPressure::kElevated) {
        budget = std::max<std::size_t>(base_window * 3, 20);
    }
    return budget;
}

void GaussianTrainingEngine::trim_training_frames() noexcept {
    const std::size_t budget = training_frame_budget();
    if (frames_.size() <= budget) return;

    const std::size_t protected_recent =
        std::min<std::size_t>(frames_.size(),
                              std::max<std::size_t>(preset_.temporal_window_size, 6));

    while (frames_.size() > budget) {
        const std::size_t protected_begin =
            (frames_.size() > protected_recent) ? (frames_.size() - protected_recent) : 0;
        if (protected_begin == 0) {
            break;
        }

        std::size_t erase_idx = protected_begin;
        bool found_depleted = false;
        for (std::size_t i = 0; i < protected_begin; ++i) {
            if (frames_[i].remaining_times_of_use <= 0) {
                erase_idx = i;
                found_depleted = true;
                break;
            }
        }

        if (!found_depleted) {
            float worst_score = std::numeric_limits<float>::infinity();
            for (std::size_t i = 0; i < protected_begin; ++i) {
                const float age_penalty =
                    static_cast<float>(protected_begin - i) * 0.05f;
                const float reuse_bonus =
                    static_cast<float>(std::max(frames_[i].remaining_times_of_use, 0)) * 0.15f;
                const float score = frames_[i].quality_weight + reuse_bonus - age_penalty;
                if (score < worst_score) {
                    worst_score = score;
                    erase_idx = i;
                }
            }
        }

        frames_.erase(frames_.begin() + static_cast<std::ptrdiff_t>(erase_idx));
        if (frames_.empty()) {
            last_frame_idx_ = 0;
            break;
        }
        if (last_frame_idx_ > erase_idx) {
            --last_frame_idx_;
        } else if (last_frame_idx_ >= frames_.size()) {
            last_frame_idx_ = frames_.size() - 1;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// B7: Opacity Reset
// ═══════════════════════════════════════════════════════════════════════
// Every N steps, reset all opacities to sigmoid(logit(0.01)) = -4.595.
// Forces re-competition: useful primitives regain opacity quickly,
// ghost primitives stay transparent and get pruned next cycle.
// Only reset opacity's Adam moments (m1, m2), not other parameters'.

void GaussianTrainingEngine::maybe_opacity_reset() noexcept {
    if (config_.align_to_baseline_3dgs) return;
    std::size_t step = current_step_.load(std::memory_order_relaxed);
    std::uint32_t interval = preset_.opacity_reset_interval;
    if (interval == 0) return;  // Disabled

    if (step > 0 && step != last_opacity_reset_step_ && step % interval == 0) {
        last_opacity_reset_step_ = step;

        // logit(0.01) = log(0.01 / 0.99) ≈ -4.595
        constexpr float kResetLogitOpacity = -4.595f;

        for (std::size_t i = 0; i < num_gaussians_; ++i) {
            float* p = params_.data() + i * kParamsPerGaussian;
            p[6] = kResetLogitOpacity;  // Reset opacity logit
        }

        // Reset Adam moments for opacity parameter only (index 6 per Gaussian)
        optimizer_.reset_param_moments(6, kParamsPerGaussian, num_gaussians_);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Training Path
// ═══════════════════════════════════════════════════════════════════════

void GaussianTrainingEngine::gpu_radix_sort(
    render::GPUComputeEncoder* /*unused*/, std::uint32_t count) noexcept
{
    // 4-pass radix sort (8-bit per pass, 32-bit keys).
    // Each pass requires 4 sub-steps (clear, histogram, prefix-sum, scatter),
    // each needing its own compute encoder because end_encoding() acts as a
    // GPU barrier. ALL 4 passes are batched into a SINGLE command buffer —
    // the Metal GPU executes them sequentially with implicit barriers between
    // encoders, eliminating 4× CPU↔GPU round-trip synchronization.
    //
    // Ping-pong: pass 0,2 read keys→tmp, pass 1,3 read tmp→keys.
    // After 4 passes (even), final sorted data is back in depth_keys_buffer_
    // and sort_indices_buffer_.

    constexpr std::uint32_t kTG = 256;

    auto cmd = device_.create_command_buffer();
    if (!cmd) return;

    for (std::uint32_t pass = 0; pass < 4; ++pass) {
        auto& src_keys = (pass % 2 == 0) ? depth_keys_buffer_ : sort_keys_tmp_;
        auto& src_vals = (pass % 2 == 0) ? sort_indices_buffer_ : sort_vals_tmp_;
        auto& dst_keys = (pass % 2 == 0) ? sort_keys_tmp_ : depth_keys_buffer_;
        auto& dst_vals = (pass % 2 == 0) ? sort_vals_tmp_ : sort_indices_buffer_;
        std::uint32_t bit_offset = pass * 8;

        // Step 1: Clear histogram
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(sort_clear_pipeline_);
            enc->set_buffer(sort_histogram_, 0, 0);
            enc->dispatch_1d(256, kTG);
            enc->end_encoding();
        }

        // Step 2: Build histogram
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(sort_histogram_pipeline_);
            enc->set_buffer(src_keys, 0, 0);
            enc->set_buffer(sort_histogram_, 0, 1);
            enc->set_bytes(&count, sizeof(count), 2);
            enc->set_bytes(&bit_offset, sizeof(bit_offset), 3);
            enc->dispatch_1d(count, kTG);
            enc->end_encoding();
        }

        // Step 3: Prefix sum
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(sort_prefix_sum_pipeline_);
            enc->set_buffer(sort_histogram_, 0, 0);
            enc->dispatch(1, 1, 1, 256, 1, 1);  // single threadgroup
            enc->end_encoding();
        }

        // Step 4: Scatter
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return;
            enc->set_pipeline(sort_scatter_pipeline_);
            enc->set_buffer(src_keys, 0, 0);
            enc->set_buffer(src_vals, 0, 1);
            enc->set_buffer(dst_keys, 0, 2);
            enc->set_buffer(dst_vals, 0, 3);
            enc->set_buffer(sort_histogram_, 0, 4);
            enc->set_bytes(&count, sizeof(count), 5);
            enc->set_bytes(&bit_offset, sizeof(bit_offset), 6);
            enc->dispatch_1d(count, kTG);
            enc->end_encoding();
        }
    }

    cmd->commit();
    cmd->wait_until_completed();
}

core::Status GaussianTrainingEngine::train_step_gpu() noexcept {
    // ═══════════════════════════════════════════════════════════════════
    // GPU Training Pipeline: Full multi-pass dispatch
    // ═══════════════════════════════════════════════════════════════════
    // Pipeline per step:
    //   1. Upload target image
    //   2. Preprocess (projection + depth keys)
    //   3. Radix sort (4 passes, depth-ordered)
    //   4. Forward rasterize (tile-based, front-to-back)
    //   5. L1 gradient computation
    //   6. Backward rasterize (back-to-front, atomic gradients)
    //   7. Scale/rotation gradient computation (from cov2d gradients)
    //   8. Adam optimizer step
    //   9. Read back loss scalar (only GPU→CPU sync point)
    //  10. Densification / pruning (CPU decision, periodic)

    if (!gpu_training_ready_ || num_gaussians_ == 0 || frames_.empty()) {
        gpu_training_ready_ = false;  // Permanently disable GPU to avoid recursion
        return core::Status::kInvalidArgument;
    }

    // Early exit if stop requested (prevents EXC_BAD_ACCESS during shutdown)
    if (stop_requested_.load(std::memory_order_acquire)) {
        return core::Status::kCancelled;
    }

    // Helper: On GPU failure, disable GPU path and start recovery cooldown.
    // After cooldown, train_step() will attempt to re-enable GPU training.
    // Max kMaxGPURetries recovery attempts before permanent disable.
    auto gpu_fail = [&]() -> core::Status {
        gpu_training_ready_ = false;
        gpu_fail_count_++;
        gpu_fail_time_ = std::chrono::steady_clock::now();
        std::fprintf(stderr, "[Aether3D] GPU failure #%d — disabling GPU training, "
                             "will retry after %dms cooldown (max %d retries)\n",
                     gpu_fail_count_,
                     5000 * (1 << (gpu_fail_count_ - 1)),
                     kMaxGPURetries);
        return core::Status::kResourceExhausted;
    };

    // Helper: wait for command buffer and check for GPU error (IOGPUMetalError etc.)
    // After a GPU error, the Metal device/queue may be in an invalid state —
    // creating new command buffers will EXC_BAD_ACCESS. Must bail out immediately.
    // gpu_wait is no longer used: single command buffer merge means we call
    // wait_until_completed() directly at the end of the pipeline.

    // ── Defensive: validate critical GPU buffers before dispatch ──
    // EXC_BAD_ACCESS occurs if a buffer handle appears valid but the
    // underlying allocation was released or never completed.
    if (!gaussian_buffer_.valid() || !projected_buffer_.valid() ||
        !sort_indices_buffer_.valid() || !depth_keys_buffer_.valid() ||
        !rendered_buffer_.valid() || !target_buffer_.valid() ||
        !training_uniform_buffer_.valid() || !gradient_buffer_.valid() ||
        !transmittance_buffer_.valid() || !image_grad_buffer_.valid() ||
        !adam_moments_buffer_.valid()) {
        std::fprintf(stderr,
            "[Aether3D] train_step_gpu: critical buffer invalid — disabling GPU\n");
        return gpu_fail();
    }

    // No thermal throttling — the GPU hardware manages its own clock frequency.
    // Skipping steps only delays the user. Let the GPU do its job.
    std::size_t step = current_step_.load(std::memory_order_relaxed);

    // ── Per-phase wall-clock timing (every 50 steps → stderr) ──
    auto t_start = std::chrono::steady_clock::now();

    // Photo-SLAM-style focal/sliding-window sampling with usage budget.
    std::size_t frame_idx = sample_focal_frame();
    last_frame_idx_ = frame_idx;

    const TrainingFrame& frame = frames_[frame_idx];
    std::uint32_t effective_rw, effective_rh;
    resolution_at_step(step, preset_, effective_rw, effective_rh);
    config_.render_width = effective_rw;
    config_.render_height = effective_rh;
    std::uint32_t rw = config_.render_width;
    std::uint32_t rh = config_.render_height;
    std::uint32_t n = static_cast<std::uint32_t>(num_gaussians_);

    // ─── Prepare uniforms ───
    // Build view matrix (inverse of camera-to-world)
    const float* cam2w = frame.transform;
    float R[9] = {cam2w[0], cam2w[1], cam2w[2],
                   cam2w[4], cam2w[5], cam2w[6],
                   cam2w[8], cam2w[9], cam2w[10]};
    float t[3] = {cam2w[12], cam2w[13], cam2w[14]};

    // TrainingUniforms matches the Metal struct layout (column-major 4×4)
    struct {
        float viewMatrix[16];   // column-major
        float fx, fy, cx, cy;
        std::uint32_t imageWidth;
        std::uint32_t imageHeight;
        std::uint32_t numGaussians;
        std::uint32_t currentStep;
        float lambdaDSSIM;
        float _pad[3];
    } uniforms{};

    // Build column-major view matrix: world-to-camera = R^T | -R^T*t
    // Column-major layout: column k at indices [4k .. 4k+3]
    uniforms.viewMatrix[0]  = R[0]; uniforms.viewMatrix[1]  = R[3]; uniforms.viewMatrix[2]  = R[6]; uniforms.viewMatrix[3]  = 0;
    uniforms.viewMatrix[4]  = R[1]; uniforms.viewMatrix[5]  = R[4]; uniforms.viewMatrix[6]  = R[7]; uniforms.viewMatrix[7]  = 0;
    uniforms.viewMatrix[8]  = R[2]; uniforms.viewMatrix[9]  = R[5]; uniforms.viewMatrix[10] = R[8]; uniforms.viewMatrix[11] = 0;
    uniforms.viewMatrix[12] = -(R[0]*t[0] + R[1]*t[1] + R[2]*t[2]);
    uniforms.viewMatrix[13] = -(R[3]*t[0] + R[4]*t[1] + R[5]*t[2]);
    uniforms.viewMatrix[14] = -(R[6]*t[0] + R[7]*t[1] + R[8]*t[2]);
    uniforms.viewMatrix[15] = 1.0f;

    uniforms.fx = frame.intrinsics[0] * rw / static_cast<float>(frame.width);
    uniforms.fy = frame.intrinsics[1] * rh / static_cast<float>(frame.height);
    uniforms.cx = frame.intrinsics[2] * rw / static_cast<float>(frame.width);
    uniforms.cy = frame.intrinsics[3] * rh / static_cast<float>(frame.height);
    uniforms.imageWidth = rw;
    uniforms.imageHeight = rh;
    uniforms.numGaussians = n;
    uniforms.currentStep = static_cast<std::uint32_t>(step);
    // DynamicWeights: modulate D-SSIM weight via smoothstep (geometry → appearance)
    {
        DynamicWeights dyn_w_gpu = dynamic_weights_at_step(
            preset_.depth_loss_weight_max, 0.02f,
            0.10f, 0.30f,
            step, config_.max_iterations);
        uniforms.lambdaDSSIM = dyn_w_gpu.dssim_weight;
    }

    device_.update_buffer(training_uniform_buffer_, &uniforms, 0, sizeof(uniforms));

    // ─── Upload target image (downscale + sRGB→linear via LUT) ───
    // Uses precomputed g_srgb_lut instead of per-pixel pow(2.4) —
    // eliminates ~920K pow() calls per step (~46ms→<1ms).
    {
        prepare_target_image_from_frame(frame, rw, rh);
        device_.update_buffer(target_buffer_, target_image_.data(), 0,
                              rw * rh * 3 * sizeof(float));
    }

    // ─── Upload current Gaussian params (only if CPU modified them) ───
    // After GPU Adam update, gaussian_buffer_ already has the latest params.
    // Skip redundant upload (~5.6MB for 100K Gaussians) on non-densification steps.
    if (cpu_params_modified_) {
        upload_gaussians_to_gpu();
        cpu_params_modified_ = false;
    }

    constexpr std::uint32_t kTG = 256;
    std::uint32_t tiles_x = (rw + 15) / 16;
    std::uint32_t tiles_y = (rh + 15) / 16;

    // ═══════════════════════════════════════════════════════════════════
    // PIPELINED GPU DISPATCH: All passes in minimal command buffers.
    // Previously each pass had its own commit()+wait_until_completed(),
    // causing ~14 CPU↔GPU sync points (~3-5ms each = 42-70ms overhead).
    // Now: 2 command buffers total (forward + backward), 1 sync point.
    // Multiple compute encoders within one CB execute sequentially with
    // implicit GPU barriers (end_encoding() acts as barrier).
    // ═══════════════════════════════════════════════════════════════════

    // ── Depth supervision setup (CPU-side uploads before GPU dispatch) ──
    bool has_dav2 = !frame.ref_depth.empty() && frame.ref_depth_w > 0 && frame.ref_depth_h > 0;
    bool has_lidar = !frame.lidar_depth.empty() && frame.lidar_w > 0 && frame.lidar_h > 0;
    bool depth_active = depth_gpu_ready_ && (has_dav2 || has_lidar) && step >= 5;

    // DepthConfig for this step (matches Metal struct layout)
    struct {
        float depthLambda;
        std::uint32_t hasRelativeDepth;
        std::uint32_t hasMetricDepth;
        float edgeBeta;
        float gradClamp;
        float lidarLambda;
        std::uint32_t renderWidth;
        std::uint32_t renderHeight;
        std::uint32_t refDepthWidth;
        std::uint32_t refDepthHeight;
        std::uint32_t lidarWidth;
        std::uint32_t lidarHeight;
    } depth_cfg{};

    if (depth_active) {
        float depth_lambda = depth_loss_weight_at_step(
            preset_.depth_loss_weight_max, step, config_.max_iterations);

        depth_cfg.depthLambda = depth_lambda;
        depth_cfg.hasRelativeDepth = has_dav2 ? 1u : 0u;
        depth_cfg.hasMetricDepth = has_lidar ? 1u : 0u;
        depth_cfg.edgeBeta = preset_.depth_edge_beta;
        depth_cfg.gradClamp = preset_.depth_grad_clamp;
        depth_cfg.lidarLambda = depth_lambda * preset_.lidar_depth_weight_ratio;
        depth_cfg.renderWidth = rw;
        depth_cfg.renderHeight = rh;
        depth_cfg.refDepthWidth = has_dav2 ? frame.ref_depth_w : 0u;
        depth_cfg.refDepthHeight = has_dav2 ? frame.ref_depth_h : 0u;
        depth_cfg.lidarWidth = has_lidar ? frame.lidar_w : 0u;
        depth_cfg.lidarHeight = has_lidar ? frame.lidar_h : 0u;

        device_.update_buffer(depth_config_buffer_, &depth_cfg, 0, sizeof(depth_cfg));

        // Upload DAv2 relative depth (100% experience, all phones)
        if (has_dav2) {
            device_.update_buffer(ref_depth_buffer_, frame.ref_depth.data(), 0,
                                  frame.ref_depth_w * frame.ref_depth_h * sizeof(float));
        }

        // Upload LiDAR metric depth (120% enhancement, Pro only)
        if (has_lidar) {
            device_.update_buffer(lidar_depth_buffer_, frame.lidar_depth.data(), 0,
                                  frame.lidar_w * frame.lidar_h * sizeof(float));
        }
    } else {
        // Ensure DepthConfig flags are zero so backward kernel skips depth logic.
        if (depth_config_buffer_.valid()) {
            device_.update_buffer(depth_config_buffer_, &depth_cfg, 0, sizeof(depth_cfg));
        }
    }

    // ── Pre-zero gradient buffers (CPU upload before GPU dispatch) ──
    {
        std::size_t grad_elems = num_gaussians_ * kParamsPerGaussian;
        std::size_t grad_bytes = grad_elems * sizeof(float);
        if (zero_buf_float_.size() < grad_elems) {
            zero_buf_float_.assign(grad_elems, 0.0f);
        }
        device_.update_buffer(gradient_buffer_, zero_buf_float_.data(), 0, grad_bytes);

        std::size_t cov2d_elems = num_gaussians_ * 3;
        std::size_t cov2d_bytes = cov2d_elems * sizeof(std::uint32_t);
        if (zero_buf_uint_.size() < cov2d_elems) {
            zero_buf_uint_.assign(cov2d_elems, 0u);
        }
        device_.update_buffer(cov2d_grad_buffer_, zero_buf_uint_.data(), 0, cov2d_bytes);
        device_.update_buffer(absgrad_buffer_, zero_buf_uint_.data(), 0,
                              num_gaussians_ * sizeof(std::uint32_t));
        device_.update_buffer(grad_count_gpu_buf_, zero_buf_uint_.data(), 0,
                              num_gaussians_ * sizeof(std::uint32_t));
    }

    auto t_cpu_prep = std::chrono::steady_clock::now();

    // ═══════════════════════════════════════════════════════════════════
    // COMMAND BUFFER 1: Forward pipeline
    //   Preprocess → Radix Sort → Forward Rasterize → L1 Gradient
    //   → Depth Reduction → Depth Gradient
    // All passes use sequential compute encoders with implicit barriers.
    // ═══════════════════════════════════════════════════════════════════
    {
        auto cmd = device_.create_command_buffer();
        if (!cmd) return gpu_fail();

        // Pass 1: Preprocess (per-Gaussian → projected + depth keys)
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(preprocess_pipeline_);
            enc->set_buffer(gaussian_buffer_, 0, 0);
            enc->set_buffer(projected_buffer_, 0, 1);
            enc->set_buffer(depth_keys_buffer_, 0, 2);
            enc->set_buffer(sort_indices_buffer_, 0, 3);
            enc->set_buffer(training_uniform_buffer_, 0, 4);
            enc->dispatch_1d(n, kTG);
            enc->end_encoding();
        }

        // Pass 2: Radix sort (4 passes × 4 sub-steps, all in this CB)
        for (std::uint32_t pass = 0; pass < 4; ++pass) {
            auto& src_keys = (pass % 2 == 0) ? depth_keys_buffer_ : sort_keys_tmp_;
            auto& src_vals = (pass % 2 == 0) ? sort_indices_buffer_ : sort_vals_tmp_;
            auto& dst_keys = (pass % 2 == 0) ? sort_keys_tmp_ : depth_keys_buffer_;
            auto& dst_vals = (pass % 2 == 0) ? sort_vals_tmp_ : sort_indices_buffer_;
            std::uint32_t bit_offset = pass * 8;

            { // Clear histogram
                auto* enc = cmd->make_compute_encoder();
                if (!enc) return gpu_fail();
                enc->set_pipeline(sort_clear_pipeline_);
                enc->set_buffer(sort_histogram_, 0, 0);
                enc->dispatch_1d(256, kTG);
                enc->end_encoding();
            }
            { // Build histogram
                auto* enc = cmd->make_compute_encoder();
                if (!enc) return gpu_fail();
                enc->set_pipeline(sort_histogram_pipeline_);
                enc->set_buffer(src_keys, 0, 0);
                enc->set_buffer(sort_histogram_, 0, 1);
                enc->set_bytes(&n, sizeof(n), 2);
                enc->set_bytes(&bit_offset, sizeof(bit_offset), 3);
                enc->dispatch_1d(n, kTG);
                enc->end_encoding();
            }
            { // Prefix sum
                auto* enc = cmd->make_compute_encoder();
                if (!enc) return gpu_fail();
                enc->set_pipeline(sort_prefix_sum_pipeline_);
                enc->set_buffer(sort_histogram_, 0, 0);
                enc->dispatch(1, 1, 1, 256, 1, 1);
                enc->end_encoding();
            }
            { // Scatter
                auto* enc = cmd->make_compute_encoder();
                if (!enc) return gpu_fail();
                enc->set_pipeline(sort_scatter_pipeline_);
                enc->set_buffer(src_keys, 0, 0);
                enc->set_buffer(src_vals, 0, 1);
                enc->set_buffer(dst_keys, 0, 2);
                enc->set_buffer(dst_vals, 0, 3);
                enc->set_buffer(sort_histogram_, 0, 4);
                enc->set_bytes(&n, sizeof(n), 5);
                enc->set_bytes(&bit_offset, sizeof(bit_offset), 6);
                enc->dispatch_1d(n, kTG);
                enc->end_encoding();
            }
        }

        // Pass 3: Forward rasterize (tile-based, front-to-back)
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(forward_pipeline_);
            enc->set_buffer(projected_buffer_, 0, 0);
            enc->set_buffer(sort_indices_buffer_, 0, 1);
            enc->set_buffer(rendered_buffer_, 0, 2);
            enc->set_buffer(transmittance_buffer_, 0, 3);
            enc->set_buffer(last_contributor_buf_, 0, 4);
            enc->set_buffer(training_uniform_buffer_, 0, 5);
            enc->set_buffer(rendered_depth_buffer_, 0, 6);
            enc->dispatch(tiles_x, tiles_y, 1, 16, 16, 1);
            enc->end_encoding();
        }

        // Pass 4: L1 loss gradient (per-pixel)
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(l1_gradient_pipeline_);
            enc->set_buffer(rendered_buffer_, 0, 0);
            enc->set_buffer(target_buffer_, 0, 1);
            enc->set_buffer(image_grad_buffer_, 0, 2);
            enc->set_buffer(training_uniform_buffer_, 0, 3);
            enc->dispatch_1d(rw * rh, kTG);
            enc->end_encoding();
        }

        // Pass 4a-4b: Depth supervision (Pearson reduction + gradient)
        if (depth_active && has_dav2) {
            std::uint32_t npix_total = rw * rh;
            std::uint32_t num_depth_groups = (npix_total + kTG - 1) / kTG;

            { // Partial reduction
                auto* enc = cmd->make_compute_encoder();
                if (!enc) { depth_active = false; goto skip_depth_backward; }
                enc->set_pipeline(depth_reduce_partial_pipeline_);
                enc->set_buffer(rendered_depth_buffer_, 0, 0);
                enc->set_buffer(ref_depth_buffer_, 0, 1);
                enc->set_buffer(depth_partial_sums_buffer_, 0, 2);
                enc->set_buffer(depth_config_buffer_, 0, 3);
                enc->dispatch_1d(npix_total, kTG);
                enc->end_encoding();
            }
            { // Final reduction
                auto* enc = cmd->make_compute_encoder();
                if (!enc) { depth_active = false; goto skip_depth_backward; }
                enc->set_pipeline(depth_reduce_final_pipeline_);
                enc->set_buffer(depth_partial_sums_buffer_, 0, 0);
                enc->set_buffer(depth_stats_buffer_, 0, 1);
                enc->set_bytes(&num_depth_groups, sizeof(num_depth_groups), 2);
                enc->dispatch(1, 1, 1, 256, 1, 1);
                enc->end_encoding();
            }
        } else if (depth_active) {
            // No DAv2 → zero Pearson stats (LiDAR-only path)
            float zero_stats[8] = {};
            device_.update_buffer(depth_stats_buffer_, zero_stats, 0, sizeof(zero_stats));
        }

        if (depth_active) {
            // Depth gradient computation (dual-path: Pearson + L1)
            auto* enc = cmd->make_compute_encoder();
            if (!enc) { depth_active = false; goto skip_depth_backward; }
            enc->set_pipeline(depth_gradient_pipeline_);
            enc->set_buffer(rendered_depth_buffer_, 0, 0);
            enc->set_buffer(ref_depth_buffer_, 0, 1);
            enc->set_buffer(depth_stats_buffer_, 0, 2);
            enc->set_buffer(target_buffer_, 0, 3);
            enc->set_buffer(depth_grad_buffer_, 0, 4);
            enc->set_buffer(depth_config_buffer_, 0, 5);
            enc->set_buffer(lidar_depth_buffer_, 0, 6);
            enc->dispatch_1d(rw * rh, kTG);
            enc->end_encoding();
        }

        skip_depth_backward:

        // If depth got disabled mid-pipeline, update config so backward skips it
        if (!depth_active && depth_config_buffer_.valid()) {
            std::memset(&depth_cfg, 0, sizeof(depth_cfg));
            device_.update_buffer(depth_config_buffer_, &depth_cfg, 0, sizeof(depth_cfg));
        }

        // Pass 5: Backward rasterize (back-to-front, atomic gradients)
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(backward_pipeline_);
            enc->set_buffer(projected_buffer_, 0, 0);
            enc->set_buffer(sort_indices_buffer_, 0, 1);
            enc->set_buffer(image_grad_buffer_, 0, 2);
            enc->set_buffer(transmittance_buffer_, 0, 3);
            enc->set_buffer(rendered_buffer_, 0, 4);
            enc->set_buffer(last_contributor_buf_, 0, 5);
            enc->set_buffer(gaussian_buffer_, 0, 6);
            enc->set_buffer(gradient_buffer_, 0, 7);
            enc->set_buffer(absgrad_buffer_, 0, 8);
            enc->set_buffer(grad_count_gpu_buf_, 0, 9);
            enc->set_buffer(cov2d_grad_buffer_, 0, 10);
            enc->set_buffer(training_uniform_buffer_, 0, 11);
            enc->set_buffer(depth_grad_buffer_, 0, 12);
            enc->set_buffer(depth_config_buffer_, 0, 13);
            enc->dispatch(tiles_x, tiles_y, 1, 16, 16, 1);
            enc->end_encoding();
        }

        // Pass 5a: Tangent-plane gradient projection (GeoSplat)
        if (depth_active && preset_.enable_tangent_projection) {
            float progress = static_cast<float>(step) / static_cast<float>(config_.max_iterations);
            if (progress >= preset_.tangent_projection_start &&
                progress <= preset_.tangent_projection_end) {
                auto* enc = cmd->make_compute_encoder();
                if (enc) {
                    enc->set_pipeline(tangent_project_pipeline_);
                    enc->set_buffer(gaussian_buffer_, 0, 0);
                    enc->set_buffer(gradient_buffer_, 0, 1);
                    enc->set_bytes(&n, sizeof(n), 2);
                    enc->dispatch_1d(n, kTG);
                    enc->end_encoding();
                }
            }
        }

        // Pass 6: Scale/Rotation gradients from cov2d gradients
        {
            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(scale_rot_grad_pipeline_);
            enc->set_buffer(gaussian_buffer_, 0, 0);
            enc->set_buffer(cov2d_grad_buffer_, 0, 1);
            enc->set_buffer(gradient_buffer_, 0, 2);
            enc->set_buffer(training_uniform_buffer_, 0, 3);
            enc->dispatch_1d(n, kTG);
            enc->end_encoding();
        }

        // Pass 7: Adam optimizer step
        {
            struct {
                float beta1, beta2, epsilon;
                float lr_position, lr_color, lr_opacity, lr_scale, lr_rotation;
            } adam_hp{};
            adam_hp.beta1 = 0.9f;
            adam_hp.beta2 = 0.999f;
            adam_hp.epsilon = 1e-15f;
            adam_hp.lr_position = config_.lr_position;
            adam_hp.lr_color = config_.lr_color;
            adam_hp.lr_opacity = config_.lr_opacity;
            adam_hp.lr_scale = config_.lr_scale;
            adam_hp.lr_rotation = config_.lr_rotation;

            auto* enc = cmd->make_compute_encoder();
            if (!enc) return gpu_fail();
            enc->set_pipeline(adam_pipeline_);
            enc->set_buffer(gaussian_buffer_, 0, 0);
            enc->set_buffer(gradient_buffer_, 0, 1);
            enc->set_buffer(adam_moments_buffer_, 0, 2);
            enc->set_bytes(&adam_hp, sizeof(adam_hp), 3);
            enc->set_buffer(training_uniform_buffer_, 0, 4);
            enc->dispatch_1d(n, kTG);
            enc->end_encoding();
        }

        // Single GPU sync point for the entire step
        cmd->commit();
        if (!cmd->had_error()) {
            cmd->wait_until_completed();
            if (cmd->had_error()) return gpu_fail();
        } else {
            return gpu_fail();
        }
    }

    auto t_gpu_done = std::chrono::steady_clock::now();

    // ═══════════════════════════════════════════════════════════════════
    // Loss readback (single GPU→CPU sync point)
    // ═══════════════════════════════════════════════════════════════════
    // SAFETY: check stop_requested_ before accessing GPU buffers.
    // During shutdown, Metal device may be in teardown → map_buffer() → EXC_BAD_ACCESS.
    if (stop_requested_.load(std::memory_order_acquire)) {
        return core::Status::kCancelled;
    }

    float loss = 0.0f;
    {
        // Read rendered image from GPU, compute loss on CPU
        // (Avoids adding a GPU reduce kernel — loss is cheap on CPU)
        void* rendered_ptr = device_.map_buffer(rendered_buffer_);
        if (rendered_ptr) {
            rendered_image_.resize(rw * rh * 3);
            std::memcpy(rendered_image_.data(), rendered_ptr, rw * rh * 3 * sizeof(float));
            device_.unmap_buffer(rendered_buffer_);
            // DynamicWeights: use dynamic D-SSIM weight for loss readback (matches GPU forward pass)
            DynamicWeights dyn_w_loss = dynamic_weights_at_step(
                preset_.depth_loss_weight_max, 0.02f,
                0.10f, 0.30f,
                step, config_.max_iterations);
            loss = compute_combined_loss(rendered_image_.data(), target_image_.data(),
                                         rw, rh, dyn_w_loss.dssim_weight);
            loss *= frame.quality_weight;
        }
    }
    current_loss_.store(loss, std::memory_order_relaxed);

    // ─── NaN/Inf check: if loss is garbage, roll back to CPU params snapshot ───
    if (!std::isfinite(loss)) {
        if (!params_snapshot_.empty()) {
            // CRITICAL FIX: After densification, params_ may be larger than
            // params_snapshot_ (more Gaussians added). Using params_.size()
            // as memcpy length caused OOB read → EXC_BAD_ACCESS crash.
            // Use min of both sizes; extra Gaussians keep their current values.
            std::size_t rollback_count = std::min(params_.size(),
                                                  params_snapshot_.size());
            std::memcpy(params_.data(), params_snapshot_.data(),
                        rollback_count * sizeof(float));
            upload_gaussians_to_gpu();
            cpu_params_modified_ = false;  // Upload just happened
        }
        nan_rollback_count_++;
        if (nan_rollback_count_ <= 3) {
            std::fprintf(stderr, "[Aether3D] GPU train_step %zu: NaN/Inf loss — rollback #%zu\n",
                         step, nan_rollback_count_);
        }
        current_step_.store(step + 1, std::memory_order_relaxed);
        return core::Status::kOk;
    }

    // SAFETY: check stop_requested_ before GPU buffer access (crash site during shutdown).
    if (stop_requested_.load(std::memory_order_acquire)) {
        return core::Status::kCancelled;
    }

    // ─── Params download + densification (optimized: skip on non-densification steps) ───
    // After GPU Adam, gaussian_buffer_ has the latest params. Only download when
    // CPU needs them: densification or periodic NaN-rollback snapshot.
    step++;
    bool is_densify_step = (step % config_.densify_interval == 0) &&
                           (step < config_.max_iterations * 3 / 4);
    // Periodic snapshot for NaN rollback safety (every 50 steps).
    // On non-snapshot steps, we accept losing up to 50 steps on NaN rollback.
    bool is_snapshot_step = (step % 50 == 0);

    if (is_densify_step || is_snapshot_step) {
        // Download updated params from GPU.
        // CRITICAL: cap read_bytes to GPU buffer allocation (max_gaussians).
        std::size_t read_count = std::min(num_gaussians_, config_.max_gaussians);
        std::size_t read_bytes = read_count * kParamsPerGaussian * sizeof(float);
        if (gaussian_buffer_.valid() && read_count > 0 &&
            read_bytes > 0 &&
            params_.size() >= read_count * kParamsPerGaussian) {
            void* param_ptr = device_.map_buffer(gaussian_buffer_);
            if (param_ptr) {
                std::memcpy(params_.data(), param_ptr, read_bytes);
                device_.unmap_buffer(gaussian_buffer_);
            } else {
                std::fprintf(stderr,
                    "[Aether3D] train_step_gpu: map_buffer(gaussian) returned null "
                    "(n=%zu, bytes=%zu) — skipping param download\n",
                    num_gaussians_, read_bytes);
            }
        }
        // Update snapshot after download
        params_snapshot_ = params_;
    }

    if (is_densify_step) {
        // SAFETY: check stop_requested_ before densification GPU reads.
        if (stop_requested_.load(std::memory_order_acquire)) {
            return core::Status::kCancelled;
        }
        // Download absgrad + grad_count for CPU densification decision
        {
            void* ag = absgrad_buffer_.valid() ? device_.map_buffer(absgrad_buffer_) : nullptr;
            void* gc = grad_count_gpu_buf_.valid() ? device_.map_buffer(grad_count_gpu_buf_) : nullptr;
            if (ag && gc) {
                screen_grad_accum_.resize(num_gaussians_);
                grad_count_.resize(num_gaussians_);
                const auto* ag_u = static_cast<const std::uint32_t*>(ag);
                for (std::size_t i = 0; i < num_gaussians_; ++i) {
                    float f;
                    std::memcpy(&f, &ag_u[i], sizeof(float));
                    screen_grad_accum_[i] = f;
                }
                std::memcpy(grad_count_.data(), gc, num_gaussians_ * sizeof(std::uint32_t));
            }
            if (ag) device_.unmap_buffer(absgrad_buffer_);
            if (gc) device_.unmap_buffer(grad_count_gpu_buf_);
        }

        densify_and_prune();

        // Re-upload modified params to GPU after densification
        params_.resize(num_gaussians_ * kParamsPerGaussian);
        gradients_.resize(num_gaussians_ * kParamsPerGaussian, 0.0f);
        upload_gaussians_to_gpu();
        cpu_params_modified_ = false;  // Upload just happened
        // Re-take snapshot after densification (size may have changed)
        params_snapshot_ = params_;
    }

    current_step_.store(step, std::memory_order_relaxed);

    // ── Per-phase timing log (every 50 steps) ──
    auto t_end = std::chrono::steady_clock::now();
    if (step % 50 == 0) {
        auto ms = [](auto a, auto b) {
            return std::chrono::duration<double, std::milli>(b - a).count();
        };
        std::fprintf(stderr,
            "[Aether3D][PERF] step=%zu  n=%u  %ux%u  "
            "cpu_prep=%.1fms  gpu=%.1fms  cpu_post=%.1fms  total=%.1fms  "
            "loss=%.4f\n",
            step, n, rw, rh,
            ms(t_start, t_cpu_prep),
            ms(t_cpu_prep, t_gpu_done),
            ms(t_gpu_done, t_end),
            ms(t_start, t_end),
            loss);
    }

    return core::Status::kOk;
}

}  // namespace training
}  // namespace aether
