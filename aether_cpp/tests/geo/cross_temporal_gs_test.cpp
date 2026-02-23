// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/cross_temporal_gs.h"

#include <cmath>
#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;
    using namespace aether::geo;

    // -- Test 1: Create and destroy cross-temporal engine. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            cross_temporal_destroy(engine);
        }
    }

    // -- Test 2: Create with various thermal levels (boundary values). --
    {
        for (int level = 0; level <= 8; ++level) {
            CrossTemporalEngine* engine = cross_temporal_create(level);
            if (engine == nullptr) {
                std::fprintf(stderr,
                             "cross_temporal_create(thermal=%d) returned null\n",
                             level);
                failed++;
            } else {
                cross_temporal_destroy(engine);
            }
        }
    }

    // -- Test 3: Default GaussianState values. --
    {
        GaussianState gs{};
        if (gs.position[0] != 0.0f || gs.position[1] != 0.0f ||
            gs.position[2] != 0.0f) {
            std::fprintf(stderr,
                         "default GaussianState position should be (0,0,0)\n");
            failed++;
        }
        if (gs.opacity != 0.0f) {
            std::fprintf(stderr,
                         "default GaussianState opacity should be 0.0\n");
            failed++;
        }
    }

    // -- Test 4: Default ChangeResult values. --
    {
        ChangeResult cr{};
        if (cr.change_score != 0.0f) {
            std::fprintf(stderr,
                         "default ChangeResult change_score should be 0.0\n");
            failed++;
        }
        if (cr.is_new || cr.is_removed || cr.is_changed) {
            std::fprintf(stderr,
                         "default ChangeResult flags should be false\n");
            failed++;
        }
    }

    // -- Test 5: Match identical epochs -> no changes. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            const int n = 3;
            GaussianState gaussians[n]{};
            for (int i = 0; i < n; ++i) {
                gaussians[i].position[0] = static_cast<float>(i);
                gaussians[i].position[1] = 0.0f;
                gaussians[i].position[2] = 0.0f;
                gaussians[i].scale[0] = 1.0f;
                gaussians[i].scale[1] = 1.0f;
                gaussians[i].scale[2] = 1.0f;
                gaussians[i].color[0] = 0.5f;
                gaussians[i].color[1] = 0.5f;
                gaussians[i].color[2] = 0.5f;
                gaussians[i].opacity = 1.0f;
            }

            ChangeResult results[n]{};
            std::size_t out_count = 0;
            auto st = cross_temporal_match(
                engine,
                gaussians, n,
                gaussians, n,
                results, &out_count);

            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_match returned error\n");
                failed++;
            }

            // Identical epochs: no gaussians should be marked as changed.
            for (std::size_t i = 0; i < out_count; ++i) {
                if (results[i].is_new || results[i].is_removed) {
                    std::fprintf(stderr,
                                 "identical epochs: result[%zu] should not be new/removed\n",
                                 i);
                    failed++;
                    break;
                }
            }

            cross_temporal_destroy(engine);
        }
    }

    // -- Test 6: Match with empty epoch_a -> all in epoch_b are new. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            GaussianState epoch_b[2]{};
            epoch_b[0].position[0] = 1.0f;
            epoch_b[0].opacity = 1.0f;
            epoch_b[1].position[0] = 5.0f;
            epoch_b[1].opacity = 0.8f;

            ChangeResult results[2]{};
            std::size_t out_count = 0;
            auto st = cross_temporal_match(
                engine,
                nullptr, 0,
                epoch_b, 2,
                results, &out_count);

            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_match with empty epoch_a returned error\n");
                failed++;
            }

            // All epoch_b gaussians should be new.
            for (std::size_t i = 0; i < out_count; ++i) {
                if (!results[i].is_new) {
                    std::fprintf(stderr,
                                 "empty epoch_a: result[%zu] should be marked new\n",
                                 i);
                    failed++;
                    break;
                }
            }

            cross_temporal_destroy(engine);
        }
    }

    // -- Test 7: Match with empty epoch_b -> all in epoch_a are removed. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            GaussianState epoch_a[2]{};
            epoch_a[0].position[0] = 1.0f;
            epoch_a[0].opacity = 1.0f;
            epoch_a[1].position[0] = 5.0f;
            epoch_a[1].opacity = 0.8f;

            ChangeResult results[2]{};
            std::size_t out_count = 0;
            auto st = cross_temporal_match(
                engine,
                epoch_a, 2,
                nullptr, 0,
                results, &out_count);

            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_match with empty epoch_b returned error\n");
                failed++;
            }

            for (std::size_t i = 0; i < out_count; ++i) {
                if (!results[i].is_removed) {
                    std::fprintf(stderr,
                                 "empty epoch_b: result[%zu] should be marked removed\n",
                                 i);
                    failed++;
                    break;
                }
            }

            cross_temporal_destroy(engine);
        }
    }

    // -- Test 8: Match with significantly different epochs -> changes detected. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            GaussianState epoch_a[2]{};
            epoch_a[0].position[0] = 0.0f;
            epoch_a[0].position[1] = 0.0f;
            epoch_a[0].position[2] = 0.0f;
            epoch_a[0].opacity = 1.0f;
            epoch_a[0].scale[0] = 1.0f;
            epoch_a[0].scale[1] = 1.0f;
            epoch_a[0].scale[2] = 1.0f;

            epoch_a[1].position[0] = 10.0f;
            epoch_a[1].opacity = 1.0f;
            epoch_a[1].scale[0] = 1.0f;
            epoch_a[1].scale[1] = 1.0f;
            epoch_a[1].scale[2] = 1.0f;

            GaussianState epoch_b[2]{};
            // Same as epoch_a[0] but with dramatically different color.
            epoch_b[0].position[0] = 0.0f;
            epoch_b[0].opacity = 1.0f;
            epoch_b[0].scale[0] = 1.0f;
            epoch_b[0].scale[1] = 1.0f;
            epoch_b[0].scale[2] = 1.0f;
            epoch_b[0].color[0] = 1.0f;
            epoch_b[0].color[1] = 0.0f;
            epoch_b[0].color[2] = 0.0f;

            // Completely new gaussian at different position.
            epoch_b[1].position[0] = 50.0f;
            epoch_b[1].opacity = 1.0f;
            epoch_b[1].scale[0] = 1.0f;
            epoch_b[1].scale[1] = 1.0f;
            epoch_b[1].scale[2] = 1.0f;

            ChangeResult results[4]{};
            std::size_t out_count = 0;
            auto st = cross_temporal_match(
                engine,
                epoch_a, 2,
                epoch_b, 2,
                results, &out_count);

            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_match with different epochs returned error\n");
                failed++;
            }

            // At least some results should indicate changes.
            bool any_change = false;
            for (std::size_t i = 0; i < out_count; ++i) {
                if (results[i].is_new || results[i].is_removed ||
                    results[i].is_changed || results[i].change_score > 0.0f) {
                    any_change = true;
                    break;
                }
            }
            if (!any_change && out_count > 0) {
                std::fprintf(stderr,
                             "different epochs should produce at least one change\n");
                failed++;
            }

            cross_temporal_destroy(engine);
        }
    }

    // -- Test 9: Compact identical gaussians. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            const int n = 4;
            GaussianState gaussians[n]{};
            for (int i = 0; i < n; ++i) {
                gaussians[i].position[0] = 0.0f;
                gaussians[i].position[1] = 0.0f;
                gaussians[i].position[2] = 0.0f;
                gaussians[i].scale[0] = 1.0f;
                gaussians[i].scale[1] = 1.0f;
                gaussians[i].scale[2] = 1.0f;
                gaussians[i].opacity = 1.0f;
            }

            std::size_t out_count = 0;
            auto st = cross_temporal_compact(engine, gaussians, n, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_compact returned error\n");
                failed++;
            }
            // Identical gaussians should be compacted down.
            if (out_count > static_cast<std::size_t>(n)) {
                std::fprintf(stderr,
                             "compact should not increase count: in=%d, out=%zu\n",
                             n, out_count);
                failed++;
            }

            cross_temporal_destroy(engine);
        }
    }

    // -- Test 10: Compact with distinct gaussians should preserve them. --
    {
        CrossTemporalEngine* engine = cross_temporal_create(4);
        if (engine == nullptr) {
            std::fprintf(stderr, "cross_temporal_create returned null\n");
            failed++;
        } else {
            const int n = 3;
            GaussianState gaussians[n]{};
            for (int i = 0; i < n; ++i) {
                gaussians[i].position[0] = static_cast<float>(i * 100);
                gaussians[i].position[1] = static_cast<float>(i * 100);
                gaussians[i].position[2] = static_cast<float>(i * 100);
                gaussians[i].scale[0] = 1.0f;
                gaussians[i].scale[1] = 1.0f;
                gaussians[i].scale[2] = 1.0f;
                gaussians[i].opacity = 1.0f;
            }

            std::size_t out_count = 0;
            auto st = cross_temporal_compact(engine, gaussians, n, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "cross_temporal_compact returned error\n");
                failed++;
            }
            // Distinct gaussians should all be preserved.
            if (out_count != static_cast<std::size_t>(n)) {
                std::fprintf(stderr,
                             "compact of distinct gaussians: expected %d, got %zu\n",
                             n, out_count);
                failed++;
            }

            cross_temporal_destroy(engine);
        }
    }

    return failed;
}
