// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/cross_temporal_gs.h"
#include "aether/geo/geo_constants.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal engine structure
// ---------------------------------------------------------------------------

struct CrossTemporalEngine {
    int32_t thermal_level;
    uint32_t max_gaussians;
};

namespace {

// Compute squared Mahalanobis distance between two Gaussian positions
// using the average covariance (simplified)
float mahalanobis_sq(const GaussianState& a, const GaussianState& b) {
    // Delta position
    float dx = b.position[0] - a.position[0];
    float dy = b.position[1] - a.position[1];
    float dz = b.position[2] - a.position[2];

    // Average covariance (upper triangle: c00, c01, c02, c11, c12, c22)
    float c00 = (a.covariance[0] + b.covariance[0]) * 0.5f;
    float c11 = (a.covariance[3] + b.covariance[3]) * 0.5f;
    float c22 = (a.covariance[5] + b.covariance[5]) * 0.5f;

    // Use diagonal approximation for robustness
    if (c00 < 1e-6f) c00 = 1e-6f;
    if (c11 < 1e-6f) c11 = 1e-6f;
    if (c22 < 1e-6f) c22 = 1e-6f;

    return (dx * dx) / c00 + (dy * dy) / c11 + (dz * dz) / c22;
}

// Compute position distance (Euclidean)
float position_distance(const GaussianState& a, const GaussianState& b) {
    float dx = b.position[0] - a.position[0];
    float dy = b.position[1] - a.position[1];
    float dz = b.position[2] - a.position[2];
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

// Compute scale distance (relative)
float scale_distance(const GaussianState& a, const GaussianState& b) {
    float sum = 0.0f;
    for (int i = 0; i < 3; ++i) {
        float sa = a.scale[i];
        float sb = b.scale[i];
        if (sa < 1e-6f) sa = 1e-6f;
        if (sb < 1e-6f) sb = 1e-6f;
        float ratio = sa / sb;
        if (ratio < 1.0f) ratio = 1.0f / ratio;
        sum += (ratio - 1.0f);
    }
    return sum / 3.0f;
}

// Compute color distance (L2 in RGB)
float color_distance(const GaussianState& a, const GaussianState& b) {
    float sum = 0.0f;
    for (int i = 0; i < 3; ++i) {
        float d = a.color[i] - b.color[i];
        sum += d * d;
    }
    return std::sqrt(sum);
}

// Dempster-Shafer evidence combination (simplified)
// Combines two belief masses using Dempster's rule
float ds_combine(float m1, float m2) {
    float k = m1 * (1.0f - m2) + (1.0f - m1) * m2;  // conflict
    if (k >= 1.0f) return 0.5f;  // Maximum conflict
    // Normalized combination
    float combined = (m1 * m2) / (1.0f - k + 1e-8f);
    return combined;
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Create / Destroy
// ---------------------------------------------------------------------------

CrossTemporalEngine* cross_temporal_create(int32_t thermal_level) {
    auto* engine = static_cast<CrossTemporalEngine*>(
        std::calloc(1, sizeof(CrossTemporalEngine)));
    if (!engine) return nullptr;

    engine->thermal_level = thermal_level;

    // Set max gaussians based on thermal level
    if (thermal_level <= 3) {
        engine->max_gaussians = CHANGE_MAX_GAUSSIANS_PER_FRAME;
    } else if (thermal_level <= 6) {
        engine->max_gaussians = CHANGE_SUBSAMPLE_THERMAL_4_6;
    } else {
        engine->max_gaussians = CHANGE_SUBSAMPLE_THERMAL_7_8;
    }

    return engine;
}

void cross_temporal_destroy(CrossTemporalEngine* engine) {
    std::free(engine);
}

// ---------------------------------------------------------------------------
// Match: Mahalanobis matching + D-S evidence + change scoring
// ---------------------------------------------------------------------------

core::Status cross_temporal_match(CrossTemporalEngine* engine,
                                  const GaussianState* epoch_a, size_t count_a,
                                  const GaussianState* epoch_b, size_t count_b,
                                  ChangeResult* out, size_t* out_count) {
    if (!engine || !out || !out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!epoch_a && count_a > 0) return core::Status::kInvalidArgument;
    if (!epoch_b && count_b > 0) return core::Status::kInvalidArgument;

    // Apply thermal limit
    size_t eff_a = count_a;
    size_t eff_b = count_b;
    if (eff_a > engine->max_gaussians) eff_a = engine->max_gaussians;
    if (eff_b > engine->max_gaussians) eff_b = engine->max_gaussians;

    // For each Gaussian in epoch_b, find best match in epoch_a
    // Track which epoch_a entries were matched
    bool* matched_a = nullptr;
    if (eff_a > 0) {
        matched_a = static_cast<bool*>(std::calloc(eff_a, sizeof(bool)));
        if (!matched_a) return core::Status::kResourceExhausted;
    }

    size_t result_count = 0;

    // Match epoch_b against epoch_a
    for (size_t bi = 0; bi < eff_b; ++bi) {
        float best_maha = 1e30f;
        size_t best_ai = eff_a;  // invalid

        for (size_t ai = 0; ai < eff_a; ++ai) {
            if (matched_a[ai]) continue;
            float maha = mahalanobis_sq(epoch_a[ai], epoch_b[bi]);
            if (maha < best_maha) {
                best_maha = maha;
                best_ai = ai;
            }
        }

        ChangeResult cr;
        cr.is_new = false;
        cr.is_removed = false;
        cr.is_changed = false;

        float maha_dist = std::sqrt(best_maha);

        if (best_ai >= eff_a || maha_dist > CHANGE_DETECTION_THRESHOLD) {
            // No match found: this is a new Gaussian
            cr.is_new = true;
            cr.change_score = 1.0f;
        } else {
            matched_a[best_ai] = true;

            // Compute weighted change score
            float pos_d = position_distance(epoch_a[best_ai], epoch_b[bi]);
            float scl_d = scale_distance(epoch_a[best_ai], epoch_b[bi]);
            float col_d = color_distance(epoch_a[best_ai], epoch_b[bi]);

            // Normalize distances to [0,1] range approximately
            float pos_score = pos_d / (pos_d + 1.0f);
            float scl_score = scl_d / (scl_d + 1.0f);
            float col_score = col_d / (col_d + 1.0f);

            float score = CHANGE_W_POSITION * pos_score
                        + CHANGE_W_SCALE * scl_score
                        + CHANGE_W_COLOR * col_score;

            // Apply D-S evidence combination
            float evidence_pos = pos_score;
            float evidence_shape = ds_combine(scl_score, col_score);
            cr.change_score = ds_combine(evidence_pos, evidence_shape);

            // Use the weighted score for thresholding
            cr.change_score = (cr.change_score + score) * 0.5f;

            if (cr.change_score < CHANGE_THRESHOLD_LOW) {
                cr.is_changed = false;  // Unchanged
            } else if (cr.change_score > CHANGE_THRESHOLD_HIGH) {
                cr.is_changed = true;
            } else {
                cr.is_changed = false;  // Ambiguous, treat as unchanged
            }
        }

        out[result_count++] = cr;
    }

    // Unmatched epoch_a entries are "removed"
    for (size_t ai = 0; ai < eff_a; ++ai) {
        if (!matched_a[ai]) {
            ChangeResult cr;
            cr.change_score = 1.0f;
            cr.is_new = false;
            cr.is_removed = true;
            cr.is_changed = false;
            out[result_count++] = cr;
        }
    }

    std::free(matched_a);
    *out_count = result_count;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Compact: merge near-identical Gaussians
// ---------------------------------------------------------------------------

core::Status cross_temporal_compact(CrossTemporalEngine* engine,
                                    GaussianState* gaussians, size_t count,
                                    size_t* out_count) {
    if (!engine || !out_count) return core::Status::kInvalidArgument;
    *out_count = count;
    if (!gaussians || count == 0) return core::Status::kOk;

    // Mark which Gaussians are merged (absorbed into another)
    bool* absorbed = static_cast<bool*>(std::calloc(count, sizeof(bool)));
    if (!absorbed) return core::Status::kResourceExhausted;

    for (size_t i = 0; i < count; ++i) {
        if (absorbed[i]) continue;

        for (size_t j = i + 1; j < count; ++j) {
            if (absorbed[j]) continue;

            // Compute change score between i and j
            float pos_d = position_distance(gaussians[i], gaussians[j]);
            float scl_d = scale_distance(gaussians[i], gaussians[j]);
            float col_d = color_distance(gaussians[i], gaussians[j]);

            float score = CHANGE_W_POSITION * (pos_d / (pos_d + 1.0f))
                        + CHANGE_W_SCALE * (scl_d / (scl_d + 1.0f))
                        + CHANGE_W_COLOR * (col_d / (col_d + 1.0f));

            if (score < COMPACTION_MERGE_THRESHOLD) {
                // Merge j into i (weighted average by opacity)
                float wi = gaussians[i].opacity;
                float wj = gaussians[j].opacity;
                float w_total = wi + wj;
                if (w_total < 1e-8f) w_total = 1e-8f;

                for (int k = 0; k < 3; ++k) {
                    gaussians[i].position[k] =
                        (gaussians[i].position[k] * wi + gaussians[j].position[k] * wj) / w_total;
                    gaussians[i].scale[k] =
                        (gaussians[i].scale[k] * wi + gaussians[j].scale[k] * wj) / w_total;
                    gaussians[i].color[k] =
                        (gaussians[i].color[k] * wi + gaussians[j].color[k] * wj) / w_total;
                }
                gaussians[i].opacity = (wi + wj) * 0.5f;
                if (gaussians[i].opacity > 1.0f) gaussians[i].opacity = 1.0f;

                for (int k = 0; k < 6; ++k) {
                    gaussians[i].covariance[k] =
                        (gaussians[i].covariance[k] * wi + gaussians[j].covariance[k] * wj) / w_total;
                }

                absorbed[j] = true;
            }
        }
    }

    // Compact: remove absorbed entries
    size_t write = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!absorbed[i]) {
            if (write != i) {
                gaussians[write] = gaussians[i];
            }
            write++;
        }
    }

    std::free(absorbed);
    *out_count = write;
    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
