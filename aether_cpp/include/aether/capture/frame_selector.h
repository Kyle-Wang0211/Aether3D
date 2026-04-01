// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CAPTURE_FRAME_SELECTOR_H
#define AETHER_CAPTURE_FRAME_SELECTOR_H

#ifdef __cplusplus

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <utility>
#include <vector>

namespace aether {
namespace capture {

// ═══════════════════════════════════════════════════════════════════════
// FrameSelector: MonoGS-style keyframe admission translated to C++
// ═══════════════════════════════════════════════════════════════════════
// Selection gates:
//   1. Quality gate
//   2. Blur gate
//   3. Keyframe gate:
//        dist > kf_translation * median_depth
//        OR (overlap < kf_overlap AND dist > kf_min_translation * median_depth)
//
// The overlap proxy uses quantized AR feature points in world space.
// This keeps the donor logic intact without importing Python visibility masks.
//
// Selected keyframes are also maintained in a small sliding window, following
// MonoGS's add_to_window() semantics.

/// Frame candidate metadata submitted from the main thread.
struct FrameCandidate {
    const std::uint8_t* rgba_ptr{nullptr};  // Pointer to RGBA pixel data (not owned)
    std::uint32_t width{0};
    std::uint32_t height{0};
    float transform[16];           // Column-major 4x4 camera-to-world matrix
    float intrinsics[4];           // [fx, fy, cx, cy]
    double timestamp{0.0};         // Monotonic seconds
    float quality_score{0.0f};     // Evidence quality [0, 1]
    float blur_score{0.0f};        // Sharpness metric [0, 1], higher = sharper
    const float* feature_xyz{nullptr}; // World-space feature points, xyzxyz...
    std::uint32_t feature_count{0};
};

struct FrameSelectionConfig {
    float min_displacement_m{0.003f};     // Absolute floor, even if depth is tiny
    float min_rotation_rad{0.026f};       // Fallback when overlap proxy is unavailable
    float min_blur_score{0.05f};
    float min_quality_score{0.08f};
    float test_frame_ratio{0.1f};         // 10% holdout for quality eval

    // MonoGS donor parameters.
    float kf_translation_ratio{0.05f};    // dist > ratio * median_depth
    float kf_min_translation_ratio{0.02f};
    float kf_overlap{0.90f};              // Jaccard threshold vs last keyframe
    float kf_cutoff{0.30f};               // Simpson coefficient cutoff in window pruning
    std::size_t keyframe_window_size{8};
    std::size_t protected_window_count{2};

    // Overlap proxy built from AR feature points.
    float feature_cell_size_m{0.04f};     // 4cm spatial quantization
    std::uint32_t min_feature_overlap_points{24};
};

/// Result of frame selection.
struct FrameSelectionResult {
    bool selected;       // True if frame passes all gates
    bool is_test_frame;  // True if marked as holdout (not for training)
    // Diagnostic: which gate rejected (0=none/selected, 1=quality, 2=blur, 3=motion)
    int reject_gate{0};
    float overlap_ratio{1.0f};
    float translation_m{0.0f};
    float rotation_rad{0.0f};
    float median_depth_m{0.0f};
};

class FrameSelector {
public:
    explicit FrameSelector(const FrameSelectionConfig& config = {}) noexcept
        : config_(config), selected_count_(0), test_count_(0),
          last_selected_time_(0.0) {}

    /// Evaluate a frame candidate.
    /// Returns whether the frame should be selected and if it's a test frame.
    FrameSelectionResult evaluate(const FrameCandidate& candidate) noexcept {
        FrameSelectionResult result{false, false, 0};

        // Gate 1: Quality threshold
        if (candidate.quality_score < config_.min_quality_score) {
            result.reject_gate = 1;
            return result;
        }

        // Gate 2: Blur threshold
        if (candidate.blur_score < config_.min_blur_score) {
            result.reject_gate = 2;
            return result;
        }

        float pos[3];
        extract_position(candidate.transform, pos);
        float fwd[3];
        extract_forward(candidate.transform, fwd);
        result.median_depth_m = estimate_median_depth(candidate, pos, fwd);

        if (window_.empty()) {
            select_current(candidate, pos, fwd, result.median_depth_m);
            return finalize_selection(result);
        }

        auto current_cells = build_feature_cells(candidate);
        const KeyframeState& last_kf = window_.front();
        result.overlap_ratio = feature_overlap_ratio(current_cells, last_kf.feature_cells);

        const float dx = pos[0] - last_kf.position[0];
        const float dy = pos[1] - last_kf.position[1];
        const float dz = pos[2] - last_kf.position[2];
        result.translation_m = std::sqrt(dx * dx + dy * dy + dz * dz);

        float dot = fwd[0] * last_kf.forward[0] +
                    fwd[1] * last_kf.forward[1] +
                    fwd[2] * last_kf.forward[2];
        dot = dot < -1.0f ? -1.0f : (dot > 1.0f ? 1.0f : dot);
        result.rotation_rad = std::acos(dot);

        const float depth_scale = std::max(
            std::max(result.median_depth_m, last_kf.median_depth_m), 1.0f);
        const float kf_translation =
            std::max(config_.min_displacement_m,
                     config_.kf_translation_ratio * depth_scale);
        const float kf_min_translation =
            std::max(config_.min_displacement_m * 0.5f,
                     config_.kf_min_translation_ratio * depth_scale);
        const bool dist_check = result.translation_m > kf_translation;
        const bool dist_check2 = result.translation_m > kf_min_translation;

        const bool overlap_valid =
            current_cells.size() >= config_.min_feature_overlap_points &&
            last_kf.feature_cells.size() >= config_.min_feature_overlap_points;
        const bool overlap_check = overlap_valid
            ? (result.overlap_ratio < config_.kf_overlap)
            : (result.rotation_rad >= config_.min_rotation_rad);

        if (!((overlap_check && dist_check2) || dist_check)) {
            result.reject_gate = 3;
            return result;
        }

        select_current(candidate, pos, fwd, result.median_depth_m, std::move(current_cells));
        return finalize_selection(result);
    }

    std::size_t selected_count() const noexcept { return selected_count_; }
    std::size_t test_count() const noexcept { return test_count_; }
    std::size_t training_count() const noexcept { return selected_count_ - test_count_; }

    void reset() noexcept {
        selected_count_ = 0;
        test_count_ = 0;
        last_selected_time_ = 0.0;
        window_.clear();
    }

private:
    struct KeyframeState {
        float position[3]{};
        float forward[3]{0.0f, 0.0f, -1.0f};
        float median_depth_m{1.0f};
        std::vector<std::uint64_t> feature_cells;
    };

    FrameSelectionConfig config_;
    std::size_t selected_count_;
    std::size_t test_count_;
    double last_selected_time_;
    std::deque<KeyframeState> window_;

    /// Extract camera position from column-major 4x4 transform.
    static void extract_position(const float m[16], float pos[3]) noexcept {
        // Translation is in column 3: m[12], m[13], m[14]
        pos[0] = m[12];
        pos[1] = m[13];
        pos[2] = m[14];
    }

    /// Extract camera forward direction from column-major 4x4 transform.
    /// Camera looks along -Z in its local frame → world forward = -column2.
    static void extract_forward(const float m[16], float fwd[3]) noexcept {
        float len = std::sqrt(m[8]*m[8] + m[9]*m[9] + m[10]*m[10]);
        if (len < 1e-6f) len = 1.0f;
        fwd[0] = -m[8]  / len;
        fwd[1] = -m[9]  / len;
        fwd[2] = -m[10] / len;
    }

    static float estimate_median_depth(const FrameCandidate& candidate,
                                       const float pos[3],
                                       const float fwd[3]) noexcept {
        if (candidate.feature_xyz == nullptr || candidate.feature_count == 0) {
            return 1.0f;
        }

        std::vector<float> depths;
        depths.reserve(candidate.feature_count);
        for (std::uint32_t i = 0; i < candidate.feature_count; ++i) {
            const float* p = candidate.feature_xyz + i * 3u;
            const float vx = p[0] - pos[0];
            const float vy = p[1] - pos[1];
            const float vz = p[2] - pos[2];
            const float depth = vx * fwd[0] + vy * fwd[1] + vz * fwd[2];
            if (std::isfinite(depth) && depth > 0.05f) {
                depths.push_back(depth);
            }
        }

        if (depths.empty()) {
            return 1.0f;
        }
        auto mid = depths.begin() + static_cast<std::ptrdiff_t>(depths.size() / 2u);
        std::nth_element(depths.begin(), mid, depths.end());
        return *mid;
    }

    static std::uint64_t encode_feature_cell(float x, float y, float z,
                                             float cell_size) noexcept {
        constexpr int kBias = 1 << 20;  // supports +/-1,048,576 cells per axis
        const float inv_cell = 1.0f / std::max(cell_size, 1e-3f);
        const int ix = static_cast<int>(std::floor(x * inv_cell)) + kBias;
        const int iy = static_cast<int>(std::floor(y * inv_cell)) + kBias;
        const int iz = static_cast<int>(std::floor(z * inv_cell)) + kBias;
        const std::uint64_t ux = static_cast<std::uint64_t>(std::clamp(ix, 0, (1 << 21) - 1));
        const std::uint64_t uy = static_cast<std::uint64_t>(std::clamp(iy, 0, (1 << 21) - 1));
        const std::uint64_t uz = static_cast<std::uint64_t>(std::clamp(iz, 0, (1 << 21) - 1));
        return (ux << 42u) | (uy << 21u) | uz;
    }

    std::vector<std::uint64_t> build_feature_cells(const FrameCandidate& candidate) const {
        std::vector<std::uint64_t> cells;
        if (candidate.feature_xyz == nullptr || candidate.feature_count == 0) {
            return cells;
        }

        cells.reserve(candidate.feature_count);
        for (std::uint32_t i = 0; i < candidate.feature_count; ++i) {
            const float* p = candidate.feature_xyz + i * 3u;
            if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || !std::isfinite(p[2])) {
                continue;
            }
            cells.push_back(encode_feature_cell(
                p[0], p[1], p[2], config_.feature_cell_size_m));
        }

        std::sort(cells.begin(), cells.end());
        cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
        return cells;
    }

    static float feature_overlap_ratio(const std::vector<std::uint64_t>& a,
                                       const std::vector<std::uint64_t>& b) noexcept {
        if (a.empty() || b.empty()) {
            return 1.0f;
        }
        std::size_t intersection = 0;
        std::size_t ia = 0;
        std::size_t ib = 0;
        while (ia < a.size() && ib < b.size()) {
            if (a[ia] == b[ib]) {
                ++intersection;
                ++ia;
                ++ib;
            } else if (a[ia] < b[ib]) {
                ++ia;
            } else {
                ++ib;
            }
        }
        const std::size_t uni = a.size() + b.size() - intersection;
        return uni == 0 ? 1.0f
                        : static_cast<float>(intersection) / static_cast<float>(uni);
    }

    static float containment_overlap_ratio(const std::vector<std::uint64_t>& a,
                                           const std::vector<std::uint64_t>& b) noexcept {
        if (a.empty() || b.empty()) {
            return 1.0f;
        }
        std::size_t intersection = 0;
        std::size_t ia = 0;
        std::size_t ib = 0;
        while (ia < a.size() && ib < b.size()) {
            if (a[ia] == b[ib]) {
                ++intersection;
                ++ia;
                ++ib;
            } else if (a[ia] < b[ib]) {
                ++ia;
            } else {
                ++ib;
            }
        }
        const std::size_t denom = std::min(a.size(), b.size());
        return denom == 0 ? 1.0f
                          : static_cast<float>(intersection) / static_cast<float>(denom);
    }

    void select_current(const FrameCandidate& candidate,
                        const float pos[3],
                        const float fwd[3],
                        float median_depth_m,
                        std::vector<std::uint64_t> feature_cells = {}) {
        if (feature_cells.empty()) {
            feature_cells = build_feature_cells(candidate);
        }

        KeyframeState state;
        state.position[0] = pos[0];
        state.position[1] = pos[1];
        state.position[2] = pos[2];
        state.forward[0] = fwd[0];
        state.forward[1] = fwd[1];
        state.forward[2] = fwd[2];
        state.median_depth_m = std::max(median_depth_m, 0.1f);
        state.feature_cells = std::move(feature_cells);

        last_selected_time_ = candidate.timestamp;
        window_.push_front(std::move(state));
        prune_window();
    }

    void prune_window() {
        const std::size_t protected_count =
            std::min(config_.protected_window_count, window_.size());
        if (window_.size() <= 1) {
            return;
        }

        const KeyframeState& current = window_.front();
        for (std::size_t i = protected_count; i < window_.size();) {
            const float overlap = containment_overlap_ratio(
                current.feature_cells, window_[i].feature_cells);
            if (overlap <= config_.kf_cutoff) {
                window_.erase(window_.begin() + static_cast<std::ptrdiff_t>(i));
                continue;
            }
            ++i;
        }

        while (window_.size() > config_.keyframe_window_size) {
            std::size_t best_idx = protected_count;
            float best_score = -std::numeric_limits<float>::infinity();
            for (std::size_t i = protected_count; i < window_.size(); ++i) {
                const KeyframeState& kf_i = window_[i];
                const float dx0 = kf_i.position[0] - current.position[0];
                const float dy0 = kf_i.position[1] - current.position[1];
                const float dz0 = kf_i.position[2] - current.position[2];
                const float k = std::sqrt(std::sqrt(dx0 * dx0 + dy0 * dy0 + dz0 * dz0));

                float inv_dist_sum = 0.0f;
                for (std::size_t j = protected_count; j < window_.size(); ++j) {
                    if (i == j) {
                        continue;
                    }
                    const KeyframeState& kf_j = window_[j];
                    const float dx = kf_i.position[0] - kf_j.position[0];
                    const float dy = kf_i.position[1] - kf_j.position[1];
                    const float dz = kf_i.position[2] - kf_j.position[2];
                    inv_dist_sum += 1.0f / (std::sqrt(dx * dx + dy * dy + dz * dz) + 1e-6f);
                }

                const float score = k * inv_dist_sum;
                if (score > best_score) {
                    best_score = score;
                    best_idx = i;
                }
            }
            window_.erase(window_.begin() + static_cast<std::ptrdiff_t>(best_idx));
        }
    }

    FrameSelectionResult finalize_selection(FrameSelectionResult result) noexcept {
        result.selected = true;
        selected_count_++;

        std::size_t interval = static_cast<std::size_t>(
            1.0f / config_.test_frame_ratio + 0.5f);
        if (interval < 2) interval = 2;
        if (selected_count_ % interval == 0) {
            result.is_test_frame = true;
            test_count_++;
        }

        return result;
    }
};

}  // namespace capture
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CAPTURE_FRAME_SELECTOR_H
