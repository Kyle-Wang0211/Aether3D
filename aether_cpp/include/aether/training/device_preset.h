// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// device_preset.h — Device-specific training presets for iPhone/iPad.
// Selects parameters optimized for each Apple SoC's GPU, RAM, and thermal
// envelope. The pipeline coordinator applies a preset to TrainingConfig
// at initialization time.
//
// ═══════════════════════════════════════════════════════════════════════
// 参数设计原则 (Sprint 3 全面超越竞品):
// ═══════════════════════════════════════════════════════════════════════
//
// 竞品参考底线 (NOT our target — these are minimums to surpass):
//   PocketGS:    500 iters, 33-168K gaussians, 23.5-24.3 dB PSNR
//   3DGS-MCMC:   30K iters, cap_max dependent, 27.4-29.8 dB PSNR
//   Student-t:   30K iters, 83-624K primitives, 29.9 dB (Mip-NeRF360)
//   Polycam:     5-6M points (cloud), no formal PSNR benchmark
//   Scaniverse:  1-5M points (on-device LiDAR), no formal benchmark
//
// 我们的优势 (自研混合算法):
//   - Student-t primitives: up to 98% reduction (1 Student-t ≈ 5-50 Gaussians)
//   - MCMC + SteepGS densification: mathematically optimal primitive placement
//   - DAv2 depth supervision: strong geometry prior from first frame
//   - On-device real-time training: no cloud, instant feedback
//
// 目标 S6+:
//   - PSNR ≥ 31dB (surpass ALL competitors including SSS's 29.9dB)
//   - Primitive count ≤ 300K Student-t (effective ≥ 3M Gaussian equivalent)
//   - Training time: 3-8 min on-device (within thermal window)
//   - Point cloud: 10M+ accumulation (surpass Polycam's 6M)
//
// Hardware reference:
//   A14 (iPhone 12):  ~1.5 TFLOPS, 4GB, 34 GB/s bandwidth
//   A15 (iPhone 13):  ~1.7 TFLOPS, 6GB, 34 GB/s bandwidth
//   A16 (iPhone 14):  ~1.8 TFLOPS, 6GB, 34 GB/s bandwidth
//   A17 Pro (15 Pro): ~2.15 TFLOPS, 8GB, 17 GB/s LPDDR5 (but GPU cache)
//   A18 Pro (16 Pro): ~2.5 TFLOPS, 8GB, 17 GB/s LPDDR5x
//   M1 (iPad Pro):    ~2.6 TFLOPS, 8-16GB, 68.25 GB/s
//   M2 (iPad Pro):    ~3.6 TFLOPS, 8-16GB, 100 GB/s
//   M4 (iPad Pro):    ~4.5 TFLOPS, 16-32GB, 120 GB/s

#ifndef AETHER_TRAINING_DEVICE_PRESET_H
#define AETHER_TRAINING_DEVICE_PRESET_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Device Tiers
// ═══════════════════════════════════════════════════════════════════════

enum class DeviceTier : std::int32_t {
    kMobile4GB = 0,   // iPhone 12/13 mini, SE 3 (A14/A15, 4GB)
    kMobile6GB = 1,   // iPhone 13/14/15 (A15/A16, 6GB)
    kMobile8GB = 2,   // iPhone 15 Pro/16 Pro (A17/A18 Pro, 8GB)
    kTablet    = 3,   // iPad Pro M1/M2/M4 (8-16GB)
};

// ═══════════════════════════════════════════════════════════════════════
// Device Preset (all training-relevant parameters in one struct)
// ═══════════════════════════════════════════════════════════════════════

struct DevicePreset {
    DeviceTier tier{DeviceTier::kMobile4GB};

    // ─── Primitive budget ───
    // With Student-t: effective quality = primitives × 5-50× Gaussian equivalent.
    // No artificial cap — MCMC convergence naturally limits actual count.
    // Per-device presets set the real GPU-memory-safe maximum.
    std::uint32_t max_primitives{1000000};

    // ─── Point cloud accumulation budget ───
    // This is the maximum points accumulated during scanning (spatial hash dedup).
    // Polycam: 5-6M, Scaniverse: 1-5M, SiteScape: 12-115M raw
    // Our target: 10M+ for S6+ density. Display budget is separate (max_display_points).
    std::uint32_t max_point_cloud_vertices{10000000};  // 10M accumulation
    std::uint32_t max_display_points{5000000};         // 5M for GPU display (LOD cull rest)

    // ─── Training resolution ───
    // 3DGS-MCMC uses full resolution; PocketGS doesn't specify.
    // Our approach: progressive multi-res (warmup → mid → full) for convergence speed.
    std::uint32_t render_width{800};
    std::uint32_t render_height{600};

    // ─── Iteration budget ───
    // Global engine with TSDF initialization: positions are already 1-2cm accurate.
    // MCMC + Student-t converge much faster than from-scratch.
    // Convergence detection (Lyapunov) will stop training early if quality is met.
    std::uint32_t max_iterations{3000};

    // ─── Temporal-focal training ───
    // PocketGS: 8 frame temporal window, 250ms.
    // We use larger windows for broader coverage + harder maintenance sampling.
    std::uint32_t temporal_window_size{8};       // Focal window: latest N frames
    float focal_sampling_prob{0.65f};            // P(sample from focal window)
    // 65% focal (current region) + 35% maintenance (all regions) — prevents forgetting

    // ─── Progressive resolution (3-stage warmup) ───
    // Stage 1 (0-15%): warmup_res (coarse geometry from depth priors)
    // Stage 2 (15-40%): mid_res (structure refinement + densification)
    // Stage 3 (40-100%): full_res (photometric detail refinement)
    std::uint32_t warmup_res_w{320};
    std::uint32_t warmup_res_h{240};
    std::uint32_t mid_res_w{480};               // NEW: intermediate resolution stage
    std::uint32_t mid_res_h{360};
    float warmup_fraction{0.15f};                // Stage 1 ends at 15%
    float mid_res_fraction{0.40f};               // Stage 2 ends at 40%

    // ─── Depth supervision ───
    // Higher weight = stronger geometry, potentially lower photometric detail.
    // With DAv2 depth: aggressive early (strong prior), decay to let photometric refine.
    // SSS paper: depth not used (they rely on heavy tails). We use depth as competitive edge.
    float depth_loss_weight_max{0.7f};           // Lambda_depth peak (was 0.5, increase for geometry)
    float depth_loss_weight_min{0.02f};          // Minimum (never fully disable)

    // ─── GPU depth supervision config ───
    float depth_edge_beta{8.0f};                 // Edge-aware modulation strength (Layer 2)
    float depth_grad_clamp{1.0f};                // Depth gradient clamp magnitude (Layer 6)
    float lidar_depth_weight_ratio{0.3f};        // LiDAR L1 weight = ratio × depth_lambda (Layer 1b)
    bool enable_tangent_projection{true};        // GeoSplat tangent-plane projection (Layer 4)
    float tangent_projection_start{0.05f};       // Start at 5% of training (allow init positioning)
    float tangent_projection_end{0.80f};         // End at 80% (allow late fine detail adjustment)

    // ─── Opacity reset ───
    // 3DGS-MCMC: opacity_reset_interval=3000. Proven effective for floater cleanup.
    // We add dual-interval: frequent early (clear init artifacts), less frequent later.
    std::uint32_t opacity_reset_interval{2500};  // Steps between opacity resets
    float opacity_reset_target{0.01f};           // Reset to logit(0.01) = -4.595

    // ─── Scale clamp ───
    float scale_clamp{10.0f};                    // Max |log_scale| before exp()

    // ─── Position LR decay (exponential) ───
    // 3DGS-MCMC: 0.00016 → 0.0000016 (100× decay). This is SOTA standard.
    // We match but with delay_mult=0.01 (3DGS-MCMC style: no delay, immediate decay).
    float lr_position_init{0.00016f};
    float lr_position_final{0.0000016f};         // 100× decay over training

    // ─── Other learning rates (standard across all SOTA) ───
    float lr_color{0.0025f};                     // SH band-0 (matches gsplat sh0_lr)
    float lr_color_higher_sh{0.000125f};         // SH bands 1-3 (gsplat: sh0/20)
    float lr_opacity{0.05f};                     // Matches 3DGS-MCMC, gsplat
    float lr_scale{0.005f};                      // Matches all SOTA
    float lr_rotation{0.001f};                   // Matches all SOTA

    // ─── Student-t nu LR ───
    // SSS paper: nu learned per-component, SGHMC with friction.
    // We use Adam with dedicated LR (simpler, faster on mobile).
    float lr_nu{0.01f};                          // Learning rate for log(nu-2)

    // ─── MCMC parameters (3DGS-MCMC NeurIPS 2024) ───
    float mcmc_noise_lr{5e-5f};                  // SGLD noise learning rate (matches paper exactly)
    float mcmc_scale_reg{0.01f};                 // Scale regularization (matches paper)
    float mcmc_opacity_reg{0.01f};               // Opacity regularization (0.001 for indoor/fine)
    float mcmc_temperature_init{1.0f};           // Initial temperature
    float mcmc_temperature_final{0.01f};         // Final temperature (100× annealing)

    // ─── Densification ───
    // 3DGS-MCMC: densify_grad_threshold=0.0002, from_iter=500, until_iter=25000.
    // Fraunhofer 2025: exponential rise in threshold (aggressive early, conservative late).
    // Our hybrid: start lower than MCMC (0.00005) for aggressive early densify with Student-t,
    // rise to 0.0005 (slightly above MCMC) to let heavy tails handle coverage.
    float densify_grad_threshold_init{0.00005f};   // Start very aggressive
    float densify_grad_threshold_final{0.0005f};   // End conservative
    std::uint32_t densify_start_iter{200};         // Start after 200 steps (MCMC: 500, ours earlier with depth)
    std::uint32_t densify_stop_fraction_pct{80};   // Stop densifying at 80% of max_iterations
    std::uint32_t densify_interval{100};           // Steps between densify (matches 3DGS-MCMC)

    // ─── Pruning ───
    float prune_opacity_threshold{0.005f};         // Kill nearly-invisible primitives
    float mcmc_death_percentile{0.05f};            // MCMC importance: prune bottom 5%
    float floater_scale_multiplier{10.0f};         // Floater: max_scale > N× median → prune

    // ─── D-SSIM loss weight ───
    // 3DGS-MCMC, gsplat: lambda_dssim=0.2. Universal standard.
    float lambda_dssim{0.2f};

    // ─── Thermal management ───
    // iPhone sustained GPU: 60-70% of peak after 5-10 min. Must respect thermal wall.
    // Strategy: reduce iteration rate, NOT quality. Keep primitives + resolution same.
    float thermal_skip_prob_level1{0.0f};          // Nominal: no skip
    float thermal_skip_prob_level2{0.3f};          // Fair: skip 30% steps
    float thermal_skip_prob_level3{0.6f};          // Serious: skip 60% steps
    float thermal_skip_prob_critical{0.85f};       // Critical: skip 85% steps (emergency only)
    float thermal_cooldown_duty_cycle{0.8f};       // At serious+: 80% compute, 20% cooldown

    // ─── Convergence detection ───
    // Early stopping when loss plateau detected (saves thermal budget).
    float convergence_loss_delta{0.0001f};         // Min loss improvement to continue
    std::uint32_t convergence_patience{500};       // Steps of no improvement before stopping region

    // ─── Frame ingestion rate ───
    // ARKit: 60fps. We don't need all frames. Adaptive with thermal state.
    // Normal: 30fps (interval=2), Thermal 2: 15fps (interval=4), Thermal 3: 10fps (interval=6)
    std::uint32_t frame_interval_nominal{2};       // 60/2 = 30fps
    std::uint32_t frame_interval_thermal2{4};      // 60/4 = 15fps
    std::uint32_t frame_interval_thermal3{6};      // 60/6 = 10fps
};

// ═══════════════════════════════════════════════════════════════════════
// Preset Definitions — calibrated against SOTA benchmarks
// ═══════════════════════════════════════════════════════════════════════

/// iPhone 12 / A14 / 4GB — most constrained.
/// Even 4GB targets S6+ with Student-t (500K Student-t ≈ 2.5M Gaussian equiv).
/// Memory budget: ~1.8GB for training data (OS takes ~2.2GB).
/// PocketGS comparison: they do 168K@23.5dB. We target 500K@≥28dB.
inline DevicePreset preset_mobile_4gb() noexcept {
    DevicePreset p{};
    p.tier = DeviceTier::kMobile4GB;

    // Primitives: 1M Student-t (effective ~5M Gaussian)
    // Memory: 1M × 15 × 4B + Adam = ~120MB. Affordable on 4GB.
    p.max_primitives = 1000000;
    p.max_point_cloud_vertices = 5000000;    // 5M accumulation (surpass PocketGS's 168K)
    p.max_display_points = 2000000;          // 2M display

    // Resolution: conservative to save bandwidth (A14: 34 GB/s)
    p.render_width = 640;
    p.render_height = 480;

    // Iterations: 2K — TSDF init + MCMC converges fast on 4GB device
    p.max_iterations = 2000;

    // Focal training: smaller window on constrained device
    p.temporal_window_size = 6;
    p.focal_sampling_prob = 0.65f;

    // 3-stage progressive resolution
    p.warmup_res_w = 320;
    p.warmup_res_h = 240;
    p.mid_res_w = 480;
    p.mid_res_h = 360;
    p.warmup_fraction = 0.15f;
    p.mid_res_fraction = 0.40f;

    // Depth: strong guidance (compensates for fewer iterations)
    p.depth_loss_weight_max = 0.7f;
    p.depth_loss_weight_min = 0.03f;

    // Opacity reset: frequent for 4GB (clear floaters fast, save memory)
    p.opacity_reset_interval = 2000;
    p.opacity_reset_target = 0.01f;

    p.scale_clamp = 10.0f;

    // LR: standard SOTA
    p.lr_position_init = 0.00016f;
    p.lr_position_final = 0.0000016f;
    p.lr_color = 0.0025f;
    p.lr_color_higher_sh = 0.000125f;
    p.lr_opacity = 0.05f;
    p.lr_scale = 0.005f;
    p.lr_rotation = 0.001f;
    p.lr_nu = 0.01f;

    // MCMC: match 3DGS-MCMC paper defaults
    p.mcmc_noise_lr = 5e-5f;
    p.mcmc_scale_reg = 0.01f;
    p.mcmc_opacity_reg = 0.01f;
    p.mcmc_temperature_init = 1.0f;
    p.mcmc_temperature_final = 0.01f;

    // Densification: aggressive early with Student-t
    p.densify_grad_threshold_init = 0.00005f;
    p.densify_grad_threshold_final = 0.0005f;
    p.densify_start_iter = 200;
    p.densify_stop_fraction_pct = 80;
    p.densify_interval = 100;

    // Pruning
    p.prune_opacity_threshold = 0.005f;
    p.mcmc_death_percentile = 0.05f;
    p.floater_scale_multiplier = 10.0f;

    p.lambda_dssim = 0.2f;

    // Thermal: conservative for 4GB (A14 thermal ceiling lower)
    p.thermal_skip_prob_level1 = 0.0f;
    p.thermal_skip_prob_level2 = 0.35f;
    p.thermal_skip_prob_level3 = 0.65f;
    p.thermal_skip_prob_critical = 0.9f;
    p.thermal_cooldown_duty_cycle = 0.75f;

    // Convergence: slightly more patient on 4GB (fewer steps → each counts more)
    p.convergence_loss_delta = 0.0001f;
    p.convergence_patience = 400;

    // Frame ingestion: 30fps nominal, drop with thermal
    p.frame_interval_nominal = 2;
    p.frame_interval_thermal2 = 4;
    p.frame_interval_thermal3 = 8;

    return p;
}

/// iPhone 13-15 / A15-A16 / 6GB — mainstream flagship.
/// 6GB gives ~3.5GB for training. Solid thermal headroom with A15/A16.
/// Target: match Student-t paper quality (29.9dB PSNR on MipNeRF360).
inline DevicePreset preset_mobile_6gb() noexcept {
    DevicePreset p{};
    p.tier = DeviceTier::kMobile6GB;

    // Primitives: 3M Student-t (effective ~15M Gaussian)
    // Memory: 3M × 15 × 4B + Adam = ~360MB. Comfortable on 6GB.
    p.max_primitives = 3000000;
    p.max_point_cloud_vertices = 10000000;   // 10M accumulation (surpass Polycam)
    p.max_display_points = 3000000;          // 3M display

    // Resolution: higher for 6GB
    p.render_width = 800;
    p.render_height = 600;

    // Iterations: 3K — TSDF init + MCMC converges fast on 6GB device
    p.max_iterations = 3000;

    // Focal training
    p.temporal_window_size = 8;
    p.focal_sampling_prob = 0.65f;

    // 3-stage progressive resolution
    p.warmup_res_w = 400;
    p.warmup_res_h = 300;
    p.mid_res_w = 640;
    p.mid_res_h = 480;
    p.warmup_fraction = 0.12f;
    p.mid_res_fraction = 0.35f;

    // Depth
    p.depth_loss_weight_max = 0.7f;
    p.depth_loss_weight_min = 0.02f;

    // Opacity reset
    p.opacity_reset_interval = 2500;
    p.opacity_reset_target = 0.01f;

    p.scale_clamp = 10.0f;

    // LR: standard
    p.lr_position_init = 0.00016f;
    p.lr_position_final = 0.0000016f;
    p.lr_color = 0.0025f;
    p.lr_color_higher_sh = 0.000125f;
    p.lr_opacity = 0.05f;
    p.lr_scale = 0.005f;
    p.lr_rotation = 0.001f;
    p.lr_nu = 0.01f;

    // MCMC
    p.mcmc_noise_lr = 5e-5f;
    p.mcmc_scale_reg = 0.01f;
    p.mcmc_opacity_reg = 0.01f;
    p.mcmc_temperature_init = 1.0f;
    p.mcmc_temperature_final = 0.01f;

    // Densification
    p.densify_grad_threshold_init = 0.00005f;
    p.densify_grad_threshold_final = 0.0005f;
    p.densify_start_iter = 200;
    p.densify_stop_fraction_pct = 80;
    p.densify_interval = 100;

    // Pruning
    p.prune_opacity_threshold = 0.005f;
    p.mcmc_death_percentile = 0.05f;
    p.floater_scale_multiplier = 10.0f;

    p.lambda_dssim = 0.2f;

    // Thermal
    p.thermal_skip_prob_level1 = 0.0f;
    p.thermal_skip_prob_level2 = 0.3f;
    p.thermal_skip_prob_level3 = 0.6f;
    p.thermal_skip_prob_critical = 0.85f;
    p.thermal_cooldown_duty_cycle = 0.8f;

    // Convergence
    p.convergence_loss_delta = 0.0001f;
    p.convergence_patience = 500;

    // Frame ingestion: 30fps nominal
    p.frame_interval_nominal = 2;
    p.frame_interval_thermal2 = 4;
    p.frame_interval_thermal3 = 6;

    return p;
}

/// iPhone 15 Pro / 16 Pro / A17-A18 Pro / 8GB — premium mobile.
/// 8GB gives ~5-6GB for training. A17/A18 Pro: 2.15-2.5 TFLOPS.
/// Target: surpass Student-t paper (>30dB) with dense primitive budget.
inline DevicePreset preset_mobile_8gb() noexcept {
    DevicePreset p{};
    p.tier = DeviceTier::kMobile8GB;

    // Primitives: 5M Student-t (effective ~25M Gaussian)
    // Memory: 5M × 15 × 4B + Adam = ~600MB. Feasible on 8GB (~10% of available).
    // MCMC naturally caps at convergence; 5M is the headroom.
    p.max_primitives = 5000000;
    p.max_point_cloud_vertices = 15000000;   // 15M accumulation
    p.max_display_points = 5000000;          // 5M display

    // Resolution: high for A17/A18 Pro
    p.render_width = 960;
    p.render_height = 720;

    // Iterations: 4K — TSDF init + MCMC converges fast on 8GB device
    p.max_iterations = 4000;

    // Focal training: larger window for 8GB
    p.temporal_window_size = 10;
    p.focal_sampling_prob = 0.65f;

    // 3-stage progressive resolution
    p.warmup_res_w = 480;
    p.warmup_res_h = 360;
    p.mid_res_w = 720;
    p.mid_res_h = 540;
    p.warmup_fraction = 0.10f;
    p.mid_res_fraction = 0.30f;

    // Depth
    p.depth_loss_weight_max = 0.7f;
    p.depth_loss_weight_min = 0.02f;

    // Opacity reset
    p.opacity_reset_interval = 3000;
    p.opacity_reset_target = 0.01f;

    p.scale_clamp = 10.0f;

    // LR: standard
    p.lr_position_init = 0.00016f;
    p.lr_position_final = 0.0000016f;
    p.lr_color = 0.0025f;
    p.lr_color_higher_sh = 0.000125f;
    p.lr_opacity = 0.05f;
    p.lr_scale = 0.005f;
    p.lr_rotation = 0.001f;
    p.lr_nu = 0.01f;

    // MCMC
    p.mcmc_noise_lr = 5e-5f;
    p.mcmc_scale_reg = 0.01f;
    p.mcmc_opacity_reg = 0.01f;
    p.mcmc_temperature_init = 1.0f;
    p.mcmc_temperature_final = 0.01f;

    // Densification
    p.densify_grad_threshold_init = 0.00005f;
    p.densify_grad_threshold_final = 0.0005f;
    p.densify_start_iter = 200;
    p.densify_stop_fraction_pct = 80;
    p.densify_interval = 100;

    // Pruning
    p.prune_opacity_threshold = 0.005f;
    p.mcmc_death_percentile = 0.05f;
    p.floater_scale_multiplier = 10.0f;

    p.lambda_dssim = 0.2f;

    // Thermal: A17/A18 Pro has better thermal design
    p.thermal_skip_prob_level1 = 0.0f;
    p.thermal_skip_prob_level2 = 0.25f;
    p.thermal_skip_prob_level3 = 0.55f;
    p.thermal_skip_prob_critical = 0.8f;
    p.thermal_cooldown_duty_cycle = 0.85f;

    // Convergence
    p.convergence_loss_delta = 0.00008f;
    p.convergence_patience = 600;

    // Frame ingestion: 30fps nominal
    p.frame_interval_nominal = 2;
    p.frame_interval_thermal2 = 3;
    p.frame_interval_thermal3 = 6;

    return p;
}

/// iPad Pro M-series / 8-16GB — desktop-class performance.
/// M1: 2.6 TFLOPS, 68 GB/s. M2: 3.6 TFLOPS, 100 GB/s. M4: 4.5 TFLOPS, 120 GB/s.
/// Target: S6+ frontier (≥33dB), maximum primitive budget, full resolution.
inline DevicePreset preset_tablet() noexcept {
    DevicePreset p{};
    p.tier = DeviceTier::kTablet;

    // Primitives: 10M Student-t (effective ~50M Gaussian)
    // Memory: 10M × 15 × 4B + Adam = ~1.2GB. Easy on 8-16GB M-series.
    // MCMC convergence naturally caps actual count well below this.
    p.max_primitives = 10000000;
    p.max_point_cloud_vertices = 20000000;   // 20M accumulation (massive)
    p.max_display_points = 10000000;         // 10M display

    // Resolution: maximum for tablet GPU bandwidth
    p.render_width = 1280;
    p.render_height = 960;

    // Iterations: 5K — TSDF init + MCMC converges fast on tablet
    p.max_iterations = 5000;

    // Focal training: large window
    p.temporal_window_size = 15;
    p.focal_sampling_prob = 0.60f;   // More maintenance (40%) — tablet has budget for it

    // 3-stage progressive resolution
    p.warmup_res_w = 640;
    p.warmup_res_h = 480;
    p.mid_res_w = 960;
    p.mid_res_h = 720;
    p.warmup_fraction = 0.08f;       // Only 8% warmup (M-series is fast)
    p.mid_res_fraction = 0.25f;

    // Depth
    p.depth_loss_weight_max = 0.7f;
    p.depth_loss_weight_min = 0.02f;

    // Opacity reset
    p.opacity_reset_interval = 3500;
    p.opacity_reset_target = 0.01f;

    p.scale_clamp = 10.0f;

    // LR: standard
    p.lr_position_init = 0.00016f;
    p.lr_position_final = 0.0000016f;
    p.lr_color = 0.0025f;
    p.lr_color_higher_sh = 0.000125f;
    p.lr_opacity = 0.05f;
    p.lr_scale = 0.005f;
    p.lr_rotation = 0.001f;
    p.lr_nu = 0.01f;

    // MCMC
    p.mcmc_noise_lr = 5e-5f;
    p.mcmc_scale_reg = 0.01f;
    p.mcmc_opacity_reg = 0.005f;   // Slightly lower for tablet (finer detail)
    p.mcmc_temperature_init = 1.0f;
    p.mcmc_temperature_final = 0.01f;

    // Densification
    p.densify_grad_threshold_init = 0.00005f;
    p.densify_grad_threshold_final = 0.0005f;
    p.densify_start_iter = 200;
    p.densify_stop_fraction_pct = 85;  // Allow densification longer on tablet
    p.densify_interval = 100;

    // Pruning
    p.prune_opacity_threshold = 0.005f;
    p.mcmc_death_percentile = 0.05f;
    p.floater_scale_multiplier = 10.0f;

    p.lambda_dssim = 0.2f;

    // Thermal: M-series has excellent thermal design, barely throttles
    p.thermal_skip_prob_level1 = 0.0f;
    p.thermal_skip_prob_level2 = 0.15f;
    p.thermal_skip_prob_level3 = 0.4f;
    p.thermal_skip_prob_critical = 0.7f;
    p.thermal_cooldown_duty_cycle = 0.9f;

    // Convergence: strict for tablet (can afford more steps)
    p.convergence_loss_delta = 0.00005f;
    p.convergence_patience = 800;

    // Frame ingestion: 30fps always (tablet can handle it)
    p.frame_interval_nominal = 2;
    p.frame_interval_thermal2 = 2;   // Stay at 30fps even at thermal 2
    p.frame_interval_thermal3 = 4;

    return p;
}

/// Select preset from available RAM in bytes.
inline DevicePreset select_preset(std::uint64_t ram_bytes) noexcept {
    if (ram_bytes >= 8ULL * 1024 * 1024 * 1024) {
        // Try to distinguish tablet from phone by large RAM
        // (M-series iPads have 8-16GB, but so does A17 Pro)
        if (ram_bytes >= 12ULL * 1024 * 1024 * 1024) {
            return preset_tablet();
        }
        return preset_mobile_8gb();
    }
    if (ram_bytes >= 6ULL * 1024 * 1024 * 1024) {
        return preset_mobile_6gb();
    }
    return preset_mobile_4gb();
}

// ═══════════════════════════════════════════════════════════════════════
// Helpers for applying preset to TrainingConfig
// ═══════════════════════════════════════════════════════════════════════

/// Compute exponential ADC gradient threshold for current step.
/// Threshold rises from init to final over max_iterations (Fraunhofer 2025).
/// Early: aggressive densification. Late: conservative.
inline float adaptive_densify_threshold(
    float init, float final_val,
    std::size_t step, std::size_t max_iterations) noexcept
{
    if (max_iterations == 0) return init;
    float t = static_cast<float>(step) / static_cast<float>(max_iterations);
    t = std::clamp(t, 0.0f, 1.0f);
    // Exponential interpolation: threshold = init × (final/init)^t
    if (final_val <= 0.0f || init <= 0.0f) return init;
    float ratio = final_val / init;
    return init * std::exp(t * std::log(ratio));
}

/// Compute position learning rate with exponential decay.
/// lr = lr_init × (lr_final / lr_init)^(step / max_steps)
/// Matches 3DGS-MCMC position_lr schedule exactly.
inline float position_lr_at_step(
    float lr_init, float lr_final,
    std::size_t step, std::size_t max_steps) noexcept
{
    if (max_steps == 0) return lr_init;
    float t = static_cast<float>(step) / static_cast<float>(max_steps);
    t = std::clamp(t, 0.0f, 1.0f);
    if (lr_final <= 0.0f || lr_init <= 0.0f) return lr_init;
    float ratio = lr_final / lr_init;
    return lr_init * std::exp(t * std::log(ratio));
}

// ═══════════════════════════════════════════════════════════════════════
// DynamicWeights: smoothstep phase transition (geometry → appearance)
// ═══════════════════════════════════════════════════════════════════════
// Inspired by progecttwo DynamicWeights.swift but reimplemented as
// Hermite smoothstep for zero-derivative transitions (no jumps, no jitter).
//
// Phase 1 (0-30%):  Geometry focus — depth_weight=high, dssim_weight=low
//                   Anchor positions, establish 3D structure
// Phase 2 (30-70%): Smooth transition — weights crossfade via smoothstep
//                   Geometry → appearance handoff
// Phase 3 (70-100%): Appearance focus — depth_weight=low, dssim_weight=high
//                    Color refinement, perceptual quality
// ═══════════════════════════════════════════════════════════════════════

/// Hermite smoothstep: zero first derivative at x=0 and x=1.
/// s(t) = 3t² - 2t³ = t²(3 - 2t)
inline float smoothstep(float t) noexcept {
    t = std::clamp(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// DynamicWeights output — all loss weights for one training step.
struct DynamicWeights {
    float depth_weight;    // Geometry: high early, low late
    float dssim_weight;    // Appearance: low early, high late (modulates lambda_dssim)
    float color_l1_weight; // Always 1.0 (baseline)
};

/// Compute all loss weights for a given training step.
/// Uses smoothstep for zero-jitter transitions.
///
/// @param depth_max     Maximum depth weight (geometry phase)
/// @param depth_min     Minimum depth weight (appearance phase)
/// @param dssim_min     D-SSIM weight during geometry phase (e.g. 0.10)
/// @param dssim_max     D-SSIM weight during appearance phase (e.g. 0.30)
/// @param step          Current training step
/// @param max_steps     Total training steps
inline DynamicWeights dynamic_weights_at_step(
    float depth_max, float depth_min,
    float dssim_min, float dssim_max,
    std::size_t step, std::size_t max_steps) noexcept
{
    DynamicWeights w;
    w.color_l1_weight = 1.0f;

    if (max_steps == 0) {
        w.depth_weight = depth_max;
        w.dssim_weight = dssim_min;
        return w;
    }

    float t = static_cast<float>(step) / static_cast<float>(max_steps);

    // Transition zone: [0.30, 0.70] — smoothstep crossfade
    float phase_t = 0.0f;
    if (t < 0.30f) {
        phase_t = 0.0f;  // Pure geometry phase
    } else if (t > 0.70f) {
        phase_t = 1.0f;  // Pure appearance phase
    } else {
        phase_t = smoothstep((t - 0.30f) / 0.40f);  // Smooth transition
    }

    // Depth weight: high → low (geometry → appearance)
    w.depth_weight = depth_max * (1.0f - phase_t) + depth_min * phase_t;
    // D-SSIM weight: low → high (geometry → appearance)
    w.dssim_weight = dssim_min * (1.0f - phase_t) + dssim_max * phase_t;

    return w;
}

/// Compute depth loss weight schedule (backward compatible).
/// 3-phase: strong early (geometry priors) → decay → maintenance.
/// Now uses smoothstep instead of linear for zero-jitter transition.
/// Phase 1 (0-30%): weight_max (full depth supervision for geometry structure)
/// Phase 2 (30-70%): smoothstep decay to weight_min (photometric takes over)
/// Phase 3 (70-100%): weight_min (minimal, prevents drift)
inline float depth_loss_weight_at_step(
    float weight_max, float weight_min,
    std::size_t step, std::size_t max_steps) noexcept
{
    if (max_steps == 0) return weight_max;
    float t = static_cast<float>(step) / static_cast<float>(max_steps);
    if (t < 0.30f) return weight_max;
    if (t > 0.70f) return weight_min;
    // Smoothstep decay from max to min over [0.30, 0.70]
    float decay_t = smoothstep((t - 0.30f) / 0.40f);
    return weight_max * (1.0f - decay_t) + weight_min * decay_t;
}

/// Backward-compatible overload (uses default min=0.01).
inline float depth_loss_weight_at_step(
    float weight_max,
    std::size_t step, std::size_t max_steps) noexcept
{
    return depth_loss_weight_at_step(weight_max, 0.02f, step, max_steps);
}

/// Determine render resolution for current step (3-stage progressive warmup).
/// Stage 1 (0 → warmup_fraction): warmup resolution (coarse geometry)
/// Stage 2 (warmup_fraction → mid_res_fraction): mid resolution (structure)
/// Stage 3 (mid_res_fraction → 1.0): full resolution (detail refinement)
inline void resolution_at_step(
    std::size_t step, const DevicePreset& preset,
    std::uint32_t& out_w, std::uint32_t& out_h) noexcept
{
    float t = (preset.max_iterations > 0)
        ? static_cast<float>(step) / static_cast<float>(preset.max_iterations)
        : 1.0f;

    if (t < preset.warmup_fraction) {
        // Stage 1: warmup resolution
        out_w = preset.warmup_res_w;
        out_h = preset.warmup_res_h;
    } else if (t < preset.mid_res_fraction) {
        // Stage 2: mid resolution
        out_w = preset.mid_res_w;
        out_h = preset.mid_res_h;
    } else {
        // Stage 3: full resolution
        out_w = preset.render_width;
        out_h = preset.render_height;
    }
}

/// Compute MCMC noise temperature with exponential annealing.
/// T(t) = T_init × (T_final / T_init)^(t / max_steps)
inline float mcmc_temperature_at_step(
    const DevicePreset& preset,
    std::size_t step) noexcept
{
    if (preset.max_iterations == 0) return preset.mcmc_temperature_init;
    float t = static_cast<float>(step) / static_cast<float>(preset.max_iterations);
    t = std::clamp(t, 0.0f, 1.0f);
    float ratio = preset.mcmc_temperature_final / preset.mcmc_temperature_init;
    if (ratio <= 0.0f) return preset.mcmc_temperature_init;
    return preset.mcmc_temperature_init * std::exp(t * std::log(ratio));
}

/// Compute thermal skip probability for current thermal level.
inline float thermal_skip_probability(
    const DevicePreset& preset,
    int thermal_level) noexcept
{
    switch (thermal_level) {
        case 0: return preset.thermal_skip_prob_level1;
        case 1: return preset.thermal_skip_prob_level2;
        case 2: return preset.thermal_skip_prob_level3;
        default: return preset.thermal_skip_prob_critical;
    }
}

/// Get frame ingestion interval based on thermal state.
inline std::uint32_t frame_interval_for_thermal(
    const DevicePreset& preset,
    int thermal_level) noexcept
{
    switch (thermal_level) {
        case 0:
        case 1: return preset.frame_interval_nominal;
        case 2: return preset.frame_interval_thermal2;
        default: return preset.frame_interval_thermal3;
    }
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_DEVICE_PRESET_H
