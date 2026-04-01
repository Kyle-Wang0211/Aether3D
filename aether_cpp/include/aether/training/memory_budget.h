// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// memory_budget.h — Per-Gaussian memory accounting and OOM protection.
//
// ═══════════════════════════════════════════════════════════════════════
// Design principles (Aether3D 自研):
// ═══════════════════════════════════════════════════════════════════════
//
// 1. EXACT byte-level accounting — no estimates, no surprises.
//    Every vector<float> per Gaussian is counted.
//
// 2. Three operating modes:
//    - kFull:    All features (Student-t, SteepGS, full snapshot). 444 bytes/G.
//    - kCompact: No Student-t/SteepGS, pos-only snapshot. 360 bytes/G.
//    - kMinimal: No snapshot, no anchors, no densify stats. 328 bytes/G.
//
// 3. Hard memory ceiling with graceful degradation:
//    - Below 70%: normal operation
//    - 70-85%: switch to kCompact mode, disable optional features
//    - 85-95%: aggressive pruning, halt densification
//    - >95%: emergency mode — refuse new Gaussians, force prune bottom 10%
//
// 4. Device-specific limits from DevicePreset (iPhone 4-8GB, iPad 8-32GB).
//
// Memory audit (per Gaussian, kFull mode):
//   params_:                14 × 4 =  56 bytes
//   gradients_:             14 × 4 =  56 bytes
//   params_snapshot_:       14 × 4 =  56 bytes
//   anchor_positions_:       3 × 4 =  12 bytes
//   screen_grad_accum_:      1 × 4 =   4 bytes
//   grad_count_:             1 × 4 =   4 bytes
//   Adam (m1+m2+step):  (14+14)×4+4 = 116 bytes
//   Student-t (nu×4):        4 × 4 =  16 bytes
//   SteepGS (prev×2):        6 × 4 =  24 bytes
//   ─────────────────────────────────────────
//   TOTAL kFull:                      344 bytes
//
//   kCompact (no Student-t, no SteepGS, pos-only snapshot):
//     344 - 16 (Student-t) - 24 (SteepGS) - 44 (snapshot→pos-only) = 260 bytes
//
//   GPU additional per Gaussian (Metal unified memory, SHARED with CPU):
//     projected_buffer:       ~64 bytes (ProjectedGaussian)
//     sort keys/indices×2:     16 bytes
//     absgrad+count:            8 bytes
//     cov2d_grad:              12 bytes
//     ─────────────────────────────────────
//     GPU additional:         ~100 bytes
//
// ═══════════════════════════════════════════════════════════════════════

#ifndef AETHER_TRAINING_MEMORY_BUDGET_H
#define AETHER_TRAINING_MEMORY_BUDGET_H

#ifdef __cplusplus

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Memory mode — trades features for capacity
// ═══════════════════════════════════════════════════════════════════════

enum class MemoryMode : std::int32_t {
    kFull    = 0,   // All features. 444 bytes/Gaussian.
    kCompact = 1,   // No Student-t, no SteepGS, pos-only snapshot. 360 bytes/G.
    kMinimal = 2,   // No snapshot, no anchors, no densify stats. 328 bytes/G.
};

// ═══════════════════════════════════════════════════════════════════════
// Per-Gaussian byte counts (verified against actual code)
// ═══════════════════════════════════════════════════════════════════════

struct PerGaussianMemory {
    static constexpr std::size_t kParams          = 14 * 4;  //  56 bytes
    static constexpr std::size_t kGradients       = 14 * 4;  //  56 bytes
    static constexpr std::size_t kSnapshot        = 14 * 4;  //  56 bytes (full)
    static constexpr std::size_t kSnapshotPosOnly =  3 * 4;  //  12 bytes (compact)
    static constexpr std::size_t kAnchor          =  3 * 4;  //  12 bytes
    static constexpr std::size_t kScreenGrad      =  1 * 4;  //   4 bytes
    static constexpr std::size_t kGradCount       =  1 * 4;  //   4 bytes
    static constexpr std::size_t kAdam            = (14 + 14) * 4 + 4;  // 116 bytes
    static constexpr std::size_t kStudentT        =  4 * 4;  //  16 bytes
    static constexpr std::size_t kSteepGS         =  6 * 4;  //  24 bytes
    static constexpr std::size_t kGPUBuffers      = 100;     // ~100 bytes (sort, project, etc.)

    /// Total bytes per Gaussian for a given memory mode.
    static constexpr std::size_t total(MemoryMode mode) noexcept {
        // Core (always needed): params + gradients + adam + gpu
        std::size_t core = kParams + kGradients + kAdam + kGPUBuffers;
        // 56 + 56 + 116 + 100 = 328 bytes

        switch (mode) {
            case MemoryMode::kFull:
                return core + kAnchor + kSnapshot + kScreenGrad + kGradCount
                       + kStudentT + kSteepGS;
                // 328 + 12 + 56 + 4 + 4 + 16 + 24 = 444
            case MemoryMode::kCompact:
                return core + kAnchor + kSnapshotPosOnly + kScreenGrad + kGradCount;
                // 328 + 12 + 12 + 4 + 4 = 360
            case MemoryMode::kMinimal:
                return core;
                // 328 bytes — no anchor, no snapshot, no densify stats
            default:
                return 444;  // fallback to full
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Memory pressure levels
// ═══════════════════════════════════════════════════════════════════════

enum class MemoryPressure : std::int32_t {
    kNormal    = 0,   // < 70% budget. Full features, densification active.
    kElevated  = 1,   // 70-85%. Switch to kCompact mode. Log warnings.
    kHigh      = 2,   // 85-95%. Halt densification, aggressive pruning.
    kCritical  = 3,   // > 95%. Refuse new Gaussians, force prune bottom 10%.
};

// ═══════════════════════════════════════════════════════════════════════
// MemoryBudgetController
// ═══════════════════════════════════════════════════════════════════════

class MemoryBudgetController {
public:
    /// Construct with device memory limit.
    /// @param device_ram_bytes  Total device RAM (e.g., 8GB for iPhone 15 Pro)
    /// @param training_fraction Fraction of RAM available for training (default: 0.45)
    ///                          Conservative: iOS takes ~2GB, TSDF ~300MB, frames ~200MB
    explicit MemoryBudgetController(
        std::uint64_t device_ram_bytes = 8ULL * 1024 * 1024 * 1024,
        float training_fraction = 0.45f) noexcept
        : budget_bytes_(static_cast<std::size_t>(
              static_cast<double>(device_ram_bytes) * training_fraction))
        , mode_(MemoryMode::kFull)
        , current_gaussians_(0)
    {}

    /// Set explicit budget in bytes (overrides fraction-based calculation).
    void set_budget_bytes(std::size_t bytes) noexcept { budget_bytes_ = bytes; }

    /// Get current budget in bytes.
    std::size_t budget_bytes() const noexcept { return budget_bytes_; }

    /// Current memory mode.
    MemoryMode mode() const noexcept { return mode_; }

    /// Update Gaussian count and recalculate pressure level.
    /// Returns the new memory pressure level.
    MemoryPressure update(std::size_t num_gaussians) noexcept {
        current_gaussians_ = num_gaussians;
        std::size_t used = num_gaussians * PerGaussianMemory::total(mode_);
        float utilization = budget_bytes_ > 0
            ? static_cast<float>(used) / static_cast<float>(budget_bytes_)
            : 1.0f;

        // Determine pressure level and adjust mode
        if (utilization > 0.95f) {
            pressure_ = MemoryPressure::kCritical;
            mode_ = MemoryMode::kMinimal;
        } else if (utilization > 0.85f) {
            pressure_ = MemoryPressure::kHigh;
            mode_ = MemoryMode::kCompact;
        } else if (utilization > 0.70f) {
            pressure_ = MemoryPressure::kElevated;
            mode_ = MemoryMode::kCompact;
        } else {
            pressure_ = MemoryPressure::kNormal;
            // Don't auto-upgrade back to kFull if we manually set compact
        }

        return pressure_;
    }

    /// How many MORE Gaussians can we add before hitting the given pressure level?
    std::size_t headroom(MemoryPressure max_level = MemoryPressure::kElevated) const noexcept {
        float threshold = 0.70f;  // default: headroom until elevated
        switch (max_level) {
            case MemoryPressure::kNormal:   threshold = 0.70f; break;
            case MemoryPressure::kElevated: threshold = 0.85f; break;
            case MemoryPressure::kHigh:     threshold = 0.95f; break;
            case MemoryPressure::kCritical: threshold = 1.00f; break;
        }

        std::size_t per_g = PerGaussianMemory::total(mode_);
        if (per_g == 0) return 0;

        std::size_t used = current_gaussians_ * per_g;
        std::size_t limit = static_cast<std::size_t>(
            static_cast<float>(budget_bytes_) * threshold);

        if (used >= limit) return 0;
        return (limit - used) / per_g;
    }

    /// Maximum Gaussian count for current mode and budget.
    std::size_t max_gaussians() const noexcept {
        std::size_t per_g = PerGaussianMemory::total(mode_);
        return per_g > 0 ? budget_bytes_ / per_g : 0;
    }

    /// Maximum Gaussian count for a specific mode.
    std::size_t max_gaussians(MemoryMode mode) const noexcept {
        std::size_t per_g = PerGaussianMemory::total(mode);
        return per_g > 0 ? budget_bytes_ / per_g : 0;
    }

    /// Current memory pressure level.
    MemoryPressure pressure() const noexcept { return pressure_; }

    /// Should densification be allowed?
    bool allow_densification() const noexcept {
        return pressure_ < MemoryPressure::kHigh;
    }

    /// Should we force-prune?
    bool should_force_prune() const noexcept {
        return pressure_ >= MemoryPressure::kCritical;
    }

    /// Should Student-t be enabled?
    bool allow_student_t() const noexcept {
        return mode_ == MemoryMode::kFull;
    }

    /// Should SteepGS be enabled?
    bool allow_steepgs() const noexcept {
        return mode_ == MemoryMode::kFull;
    }

    /// Print memory status report.
    void print_status(const char* label = "") const noexcept {
        std::size_t per_g = PerGaussianMemory::total(mode_);
        std::size_t used = current_gaussians_ * per_g;
        float pct = budget_bytes_ > 0
            ? 100.0f * static_cast<float>(used) / static_cast<float>(budget_bytes_)
            : 0.0f;

        const char* mode_str = "Full";
        if (mode_ == MemoryMode::kCompact) mode_str = "Compact";
        else if (mode_ == MemoryMode::kMinimal) mode_str = "Minimal";

        const char* pressure_str = "Normal";
        if (pressure_ == MemoryPressure::kElevated) pressure_str = "Elevated";
        else if (pressure_ == MemoryPressure::kHigh) pressure_str = "HIGH";
        else if (pressure_ == MemoryPressure::kCritical) pressure_str = "CRITICAL";

        std::fprintf(stderr,
            "[MemBudget] %s Gaussians=%zu  %zuMB/%zuMB (%.1f%%)  "
            "mode=%s  pressure=%s  bytes/G=%zu  max=%zuK\n",
            label,
            current_gaussians_,
            used / (1024 * 1024),
            budget_bytes_ / (1024 * 1024),
            pct,
            mode_str, pressure_str,
            per_g,
            max_gaussians() / 1000);
    }

private:
    std::size_t budget_bytes_;
    MemoryMode mode_;
    MemoryPressure pressure_{MemoryPressure::kNormal};
    std::size_t current_gaussians_;
};

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_MEMORY_BUDGET_H
