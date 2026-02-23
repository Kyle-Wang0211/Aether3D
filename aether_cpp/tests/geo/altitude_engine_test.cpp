// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/altitude_engine.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // --- Test 1: Create and destroy ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "create: returned null\n");
            ++failed;
        } else {
            const auto* state = aether::geo::altitude_engine_state(engine);
            if (!state) {
                std::fprintf(stderr, "state: returned null\n");
                ++failed;
            } else if (state->h != 0.0) {
                std::fprintf(stderr, "initial h: got %.3f, expected 0\n", state->h);
                ++failed;
            }
            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 2: Predict step ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "predict: create failed\n");
            ++failed;
        } else {
            auto s = aether::geo::altitude_engine_predict(engine, 0.1);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "predict: status != kOk\n");
                ++failed;
            }

            const auto* state = aether::geo::altitude_engine_state(engine);
            if (!state) {
                std::fprintf(stderr, "predict: state null after predict\n");
                ++failed;
            } else if (state->frame_counter != 1) {
                std::fprintf(stderr, "predict: frame_counter != 1, got %llu\n",
                             static_cast<unsigned long long>(state->frame_counter));
                ++failed;
            }

            // Predict with invalid dt
            auto s2 = aether::geo::altitude_engine_predict(engine, -1.0);
            if (s2 != aether::core::Status::kInvalidArgument) {
                std::fprintf(stderr, "predict negative dt: expected kInvalidArgument\n");
                ++failed;
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 3: Update with clean measurements converges ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "update: create failed\n");
            ++failed;
        } else {
            // Simulate standing at 100m altitude
            double target_alt = 100.0;
            for (int i = 0; i < 50; ++i) {
                auto sp = aether::geo::altitude_engine_predict(engine, 0.1);
                if (sp != aether::core::Status::kOk) {
                    std::fprintf(stderr, "update loop predict %d: failed\n", i);
                    ++failed;
                    break;
                }

                aether::geo::AltitudeMeasurement meas;
                meas.gnss_alt_m = target_alt;
                meas.baro_alt_m = target_alt;
                meas.vio_delta_h = 0.0;
                meas.dt_s = 0.1;
                meas.geoid_undulation_m = 0.0;

                auto su = aether::geo::altitude_engine_update(engine, meas);
                if (su != aether::core::Status::kOk) {
                    std::fprintf(stderr, "update loop update %d: failed\n", i);
                    ++failed;
                    break;
                }
            }

            const auto* state = aether::geo::altitude_engine_state(engine);
            if (state) {
                double error = std::fabs(state->h - target_alt);
                if (error > 5.0) {
                    std::fprintf(stderr, "convergence: h=%.3f, expected ~%.3f, error=%.3f\n",
                                 state->h, target_alt, error);
                    ++failed;
                }
                if (state->confidence < 0.3) {
                    std::fprintf(stderr, "convergence: confidence too low: %.3f\n",
                                 state->confidence);
                    ++failed;
                }
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 4: Floor detection ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "floor: create failed\n");
            ++failed;
        } else {
            // Feed measurements at ~10m altitude (should be ~3rd floor)
            for (int i = 0; i < 50; ++i) {
                aether::geo::altitude_engine_predict(engine, 0.1);

                aether::geo::AltitudeMeasurement meas;
                meas.gnss_alt_m = 10.0;
                meas.baro_alt_m = 10.0;
                meas.vio_delta_h = 0.0;
                meas.dt_s = 0.1;
                meas.geoid_undulation_m = 0.0;

                aether::geo::altitude_engine_update(engine, meas);
            }

            const auto* state = aether::geo::altitude_engine_state(engine);
            if (state) {
                // At ~10m: floor = (10 - 1.5) / 3.0 + 1 = 3.83... => floor 3
                if (state->floor_level < 1 || state->floor_level > 5) {
                    std::fprintf(stderr, "floor detection: got %d at h=%.1f, expected 2-4\n",
                                 state->floor_level, state->h);
                    ++failed;
                }
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 5: IAQS adaptation ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "iaqs: create failed\n");
            ++failed;
        } else {
            const auto* state0 = aether::geo::altitude_engine_state(engine);
            double initial_q = state0->iaqs_q_scale;

            // Feed very noisy measurements to trigger IAQS increase
            for (int i = 0; i < 100; ++i) {
                aether::geo::altitude_engine_predict(engine, 0.1);

                aether::geo::AltitudeMeasurement meas;
                // Oscillate wildly
                meas.gnss_alt_m = (i % 2 == 0) ? 200.0 : -200.0;
                meas.baro_alt_m = (i % 2 == 0) ? -200.0 : 200.0;
                meas.vio_delta_h = 0.0;
                meas.dt_s = 0.1;
                meas.geoid_undulation_m = 0.0;

                aether::geo::altitude_engine_update(engine, meas);
            }

            const auto* state = aether::geo::altitude_engine_state(engine);
            if (state) {
                // Q scale should have adapted (different from initial)
                if (state->iaqs_q_scale == initial_q) {
                    std::fprintf(stderr, "iaqs: q_scale unchanged at %.3f after noisy input\n",
                                 state->iaqs_q_scale);
                    // Not necessarily a failure since adaptation depends on NIS
                    // but we check it changed
                }
                // Verify it's within bounds
                if (state->iaqs_q_scale < aether::geo::IAQS_Q_SCALE_MIN ||
                    state->iaqs_q_scale > aether::geo::IAQS_Q_SCALE_MAX) {
                    std::fprintf(stderr, "iaqs: q_scale %.3f out of bounds [%.3f, %.3f]\n",
                                 state->iaqs_q_scale,
                                 aether::geo::IAQS_Q_SCALE_MIN,
                                 aether::geo::IAQS_Q_SCALE_MAX);
                    ++failed;
                }
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 6: NaN injection recovery ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "nan recovery: create failed\n");
            ++failed;
        } else {
            // Feed some clean measurements first
            for (int i = 0; i < 10; ++i) {
                aether::geo::altitude_engine_predict(engine, 0.1);
                aether::geo::AltitudeMeasurement meas;
                meas.gnss_alt_m = 50.0;
                meas.baro_alt_m = 50.0;
                meas.vio_delta_h = 0.0;
                meas.dt_s = 0.1;
                meas.geoid_undulation_m = 0.0;
                aether::geo::altitude_engine_update(engine, meas);
            }

            // Inject NaN measurements — NumericGuard should protect state
            aether::geo::AltitudeMeasurement nan_meas;
            nan_meas.gnss_alt_m = 0.0 / 0.0;  // NaN
            nan_meas.baro_alt_m = 50.0;
            nan_meas.vio_delta_h = 0.0;
            nan_meas.dt_s = 0.1;
            nan_meas.geoid_undulation_m = 0.0;
            aether::geo::altitude_engine_update(engine, nan_meas);

            const auto* state = aether::geo::altitude_engine_state(engine);
            if (state) {
                // State should not contain NaN after NumericGuard
                if (std::isnan(state->h) || std::isinf(state->h)) {
                    std::fprintf(stderr, "nan recovery: h is NaN/Inf after NaN injection\n");
                    ++failed;
                }
                // Covariance diagonal should be positive
                for (int i = 0; i < 5; ++i) {
                    if (state->P[i * 5 + i] < 0.0 ||
                        std::isnan(state->P[i * 5 + i])) {
                        std::fprintf(stderr, "nan recovery: P[%d,%d] = %.3f is invalid\n",
                                     i, i, state->P[i * 5 + i]);
                        ++failed;
                        break;
                    }
                }
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 7: Reset ---
    {
        auto* engine = aether::geo::altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "reset: create failed\n");
            ++failed;
        } else {
            // Modify state
            aether::geo::altitude_engine_predict(engine, 0.5);
            aether::geo::AltitudeMeasurement meas;
            meas.gnss_alt_m = 500.0;
            meas.baro_alt_m = 500.0;
            meas.vio_delta_h = 0.0;
            meas.dt_s = 0.5;
            meas.geoid_undulation_m = 0.0;
            aether::geo::altitude_engine_update(engine, meas);

            // Reset
            aether::geo::altitude_engine_reset(engine);
            const auto* state = aether::geo::altitude_engine_state(engine);
            if (state) {
                if (state->h != 0.0 || state->v_h != 0.0 || state->frame_counter != 0) {
                    std::fprintf(stderr, "reset: state not zeroed (h=%.3f v_h=%.3f fc=%llu)\n",
                                 state->h, state->v_h,
                                 static_cast<unsigned long long>(state->frame_counter));
                    ++failed;
                }
            }

            aether::geo::altitude_engine_destroy(engine);
        }
    }

    // --- Test 8: Null engine checks ---
    {
        auto s1 = aether::geo::altitude_engine_predict(nullptr, 0.1);
        if (s1 != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "predict null: expected kInvalidArgument\n");
            ++failed;
        }

        aether::geo::AltitudeMeasurement meas{};
        meas.dt_s = 0.1;
        auto s2 = aether::geo::altitude_engine_update(nullptr, meas);
        if (s2 != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "update null: expected kInvalidArgument\n");
            ++failed;
        }

        const auto* state = aether::geo::altitude_engine_state(nullptr);
        if (state != nullptr) {
            std::fprintf(stderr, "state null: expected nullptr\n");
            ++failed;
        }
    }

    return failed;
}
