// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TRAINING_ADAM_OPTIMIZER_H
#define AETHER_TRAINING_ADAM_OPTIMIZER_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <vector>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Adam Optimizer for 3DGS Training
// ═══════════════════════════════════════════════════════════════════════
// Per-parameter Adam with momentum reset on densify/prune.
// Each Gaussian has 14 trainable parameters:
//   position[3], color[3], opacity[1], scale[3], rotation[4]

/// Number of trainable parameters per Gaussian.
constexpr std::size_t kParamsPerGaussian = 14;

/// Adam optimizer state per Gaussian.
struct AdamState {
    float first_moment[kParamsPerGaussian];   // m (exponential avg of gradients)
    float second_moment[kParamsPerGaussian];  // v (exponential avg of squared gradients)
    std::uint32_t step;                       // t (per-parameter step count)
};

/// Adam hyperparameters.
struct AdamConfig {
    float beta1{0.9f};
    float beta2{0.999f};
    float epsilon{1e-15f};

    // Per-parameter-group learning rates (3DGS convention)
    float lr_position{0.00016f};
    float lr_color{0.0025f};
    float lr_opacity{0.05f};
    float lr_scale{0.005f};
    float lr_rotation{0.001f};
};

/// Apply one Adam step to a single Gaussian's parameters.
/// params[14] = [pos(3), color(3), opacity(1), scale(3), rotation(4)]
/// grads[14]  = corresponding gradients
inline void adam_step(float params[kParamsPerGaussian],
                      const float grads[kParamsPerGaussian],
                      AdamState& state,
                      const AdamConfig& config) noexcept {
    state.step++;
    float t = static_cast<float>(state.step);

    // Bias correction factors
    float bc1 = 1.0f / (1.0f - std::pow(config.beta1, t));
    float bc2 = 1.0f / (1.0f - std::pow(config.beta2, t));

    // Learning rate per parameter index
    // [0..2]=position, [3..5]=color, [6]=opacity, [7..9]=scale, [10..13]=rotation
    float lr_table[kParamsPerGaussian] = {
        config.lr_position, config.lr_position, config.lr_position,
        config.lr_color, config.lr_color, config.lr_color,
        config.lr_opacity,
        config.lr_scale, config.lr_scale, config.lr_scale,
        config.lr_rotation, config.lr_rotation, config.lr_rotation, config.lr_rotation
    };

    for (std::size_t i = 0; i < kParamsPerGaussian; ++i) {
        float g = grads[i];

        // Update moments
        state.first_moment[i] = config.beta1 * state.first_moment[i] +
                                 (1.0f - config.beta1) * g;
        state.second_moment[i] = config.beta2 * state.second_moment[i] +
                                  (1.0f - config.beta2) * g * g;

        // Bias-corrected estimates
        float m_hat = state.first_moment[i] * bc1;
        float v_hat = state.second_moment[i] * bc2;

        // Parameter update
        params[i] -= lr_table[i] * m_hat / (std::sqrt(v_hat) + config.epsilon);
    }
}

/// Adam optimizer managing state for all Gaussians.
class AdamOptimizer {
public:
    explicit AdamOptimizer(const AdamConfig& config = {}) noexcept
        : config_(config) {}

    /// Resize state for N Gaussians (zero-initialized).
    void resize(std::size_t num_gaussians) noexcept {
        states_.resize(num_gaussians);
        for (auto& s : states_) {
            std::memset(&s, 0, sizeof(s));
        }
    }

    /// Apply Adam update to all Gaussians.
    /// params_flat[N * 14]: flattened parameter array
    /// grads_flat[N * 14]:  flattened gradient array
    void step(float* params_flat, const float* grads_flat,
              std::size_t num_gaussians) noexcept {
        if (states_.size() != num_gaussians) {
            resize(num_gaussians);
        }
        for (std::size_t i = 0; i < num_gaussians; ++i) {
            adam_step(params_flat + i * kParamsPerGaussian,
                      grads_flat + i * kParamsPerGaussian,
                      states_[i], config_);
        }
    }

    /// Reset momentum for a specific Gaussian (after densify/prune).
    void reset_state(std::size_t index) noexcept {
        if (index < states_.size()) {
            std::memset(&states_[index], 0, sizeof(AdamState));
        }
    }

    /// Insert new states at the end (for densification).
    void grow(std::size_t additional) noexcept {
        std::size_t old_size = states_.size();
        states_.resize(old_size + additional);
        for (std::size_t i = old_size; i < states_.size(); ++i) {
            std::memset(&states_[i], 0, sizeof(AdamState));
        }
    }

    /// Remove states by compaction (for pruning).
    /// keep_mask[N]: true = keep, false = prune.
    void compact(const std::uint8_t* keep_mask, std::size_t old_count) noexcept {
        std::size_t write = 0;
        for (std::size_t i = 0; i < old_count && i < states_.size(); ++i) {
            if (keep_mask[i]) {
                if (write != i) {
                    states_[write] = states_[i];
                }
                write++;
            }
        }
        states_.resize(write);
    }

    /// B7: Reset Adam moments for a specific parameter index across all Gaussians.
    /// Used by opacity reset: zeros m1[param_idx] and m2[param_idx] for every Gaussian.
    /// @param param_idx  The parameter index within each Gaussian (e.g., 6 for opacity)
    /// @param stride     Number of parameters per Gaussian (kParamsPerGaussian)
    /// @param count      Number of Gaussians
    void reset_param_moments(std::size_t param_idx, std::size_t /*stride*/,
                             std::size_t count) noexcept {
        if (param_idx >= kParamsPerGaussian) return;
        std::size_t n = std::min(count, states_.size());
        for (std::size_t i = 0; i < n; ++i) {
            states_[i].first_moment[param_idx] = 0.0f;
            states_[i].second_moment[param_idx] = 0.0f;
        }
    }

    std::size_t size() const noexcept { return states_.size(); }
    const AdamConfig& config() const noexcept { return config_; }

private:
    AdamConfig config_;
    std::vector<AdamState> states_;
};

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_ADAM_OPTIMIZER_H
