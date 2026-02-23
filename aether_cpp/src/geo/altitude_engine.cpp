// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/altitude_engine.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/numeric_guard.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal engine structure
// ---------------------------------------------------------------------------
struct AltitudeEngine {
    AltitudeState state;
    double nis_ema;  // Exponential moving average of Normalized Innovation Squared
};

namespace {

// State indices
static constexpr int kH     = 0;  // altitude
static constexpr int kVH    = 1;  // vertical velocity
static constexpr int kBBaro = 2;  // baro bias
static constexpr int kBGnss = 3;  // GNSS bias
static constexpr int kSVio  = 4;  // VIO sigma
static constexpr int kN     = 5;  // state dimension

// Matrix helper: access P[i][j] in row-major 5x5
inline double& P(double* mat, int r, int c) { return mat[r * kN + c]; }

// Guard all state elements against NaN/Inf
void guard_state(AltitudeState& s) {
    core::guard_finite_scalar(&s.h);
    core::guard_finite_scalar(&s.v_h);
    core::guard_finite_scalar(&s.b_baro);
    core::guard_finite_scalar(&s.b_gnss);
    core::guard_finite_scalar(&s.sigma_vio);
    core::guard_finite_vector(s.P, 25);
    core::guard_finite_scalar(&s.iaqs_q_scale);
    core::guard_finite_scalar(&s.confidence);
}

// Clamp covariance diagonal to minimum
void clamp_covariance_diagonal(double* mat) {
    for (int i = 0; i < kN; ++i) {
        if (P(mat, i, i) < ALTITUDE_EKF_P_MIN) {
            P(mat, i, i) = ALTITUDE_EKF_P_MIN;
        }
    }
}

// Joseph-form covariance update: P = (I - K*H) * P * (I - K*H)' + K*R*K'
void joseph_update(double* out_P, const double* P_in,
                   const double* K, const double* H,
                   double R, int n) {
    // Compute (I - K*H)
    double IKH[kN * kN];
    std::memset(IKH, 0, sizeof(IKH));
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            double ikh_val = -K[i] * H[j];
            if (i == j) ikh_val += 1.0;
            IKH[i * n + j] = ikh_val;
        }
    }

    // tmp = (I-KH) * P
    double tmp[kN * kN];
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            double sum = 0.0;
            for (int k = 0; k < n; ++k) {
                sum += IKH[i * n + k] * P_in[k * n + j];
            }
            tmp[i * n + j] = sum;
        }
    }

    // P_new = tmp * (I-KH)' + K*R*K'
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            double sum = 0.0;
            for (int k = 0; k < n; ++k) {
                sum += tmp[i * n + k] * IKH[j * n + k];  // transpose
            }
            sum += K[i] * R * K[j];
            out_P[i * n + j] = sum;
        }
    }
}

// Floor detection from altitude
int32_t detect_floor(double altitude_m) {
    if (altitude_m < ALTITUDE_OUTDOOR_THRESHOLD_M) {
        return 0;  // Ground floor / outdoors
    }
    double floor_height = altitude_m - ALTITUDE_GROUND_OFFSET_M;
    int32_t level = static_cast<int32_t>(floor_height / ALTITUDE_FLOOR_HEIGHT_M) + 1;
    if (level < ALTITUDE_MIN_FLOOR) level = ALTITUDE_MIN_FLOOR;
    if (level > ALTITUDE_MAX_FLOOR) level = ALTITUDE_MAX_FLOOR;
    return level;
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Create / Destroy / Reset
// ---------------------------------------------------------------------------
AltitudeEngine* altitude_engine_create() {
    auto* engine = static_cast<AltitudeEngine*>(std::calloc(1, sizeof(AltitudeEngine)));
    if (!engine) return nullptr;
    altitude_engine_reset(engine);
    return engine;
}

void altitude_engine_destroy(AltitudeEngine* engine) {
    std::free(engine);
}

void altitude_engine_reset(AltitudeEngine* engine) {
    if (!engine) return;
    std::memset(&engine->state, 0, sizeof(AltitudeState));

    // Initialize covariance diagonal with large uncertainty
    for (int i = 0; i < kN; ++i) {
        P(engine->state.P, i, i) = 100.0;
    }

    engine->state.iaqs_q_scale = 1.0;
    engine->state.confidence = 0.5;
    engine->state.floor_level = 0;
    engine->state.frame_counter = 0;
    engine->nis_ema = 1.0;
}

// ---------------------------------------------------------------------------
// EKF Predict: state propagation with process noise
// ---------------------------------------------------------------------------
core::Status altitude_engine_predict(AltitudeEngine* engine, double dt_s) {
    if (!engine) return core::Status::kInvalidArgument;
    if (dt_s <= 0.0 || dt_s > 60.0) return core::Status::kInvalidArgument;

    AltitudeState& s = engine->state;

    // State transition: x_new = F * x
    s.h += s.v_h * dt_s;

    // Bias drift: exponential decay toward zero
    double alpha_baro = std::exp(-dt_s / ALTITUDE_EKF_TAU_BARO);
    double alpha_gnss = std::exp(-dt_s / ALTITUDE_EKF_TAU_GNSS);
    s.b_baro *= alpha_baro;
    s.b_gnss *= alpha_gnss;

    // VIO drift grows over time
    s.sigma_vio += ALTITUDE_VIO_BASE_DRIFT_MPS * dt_s + ALTITUDE_VIO_DRIFT_RATE * s.sigma_vio * dt_s;

    // State transition matrix F
    double F[kN * kN];
    std::memset(F, 0, sizeof(F));
    for (int i = 0; i < kN; ++i) F[i * kN + i] = 1.0;
    F[kH * kN + kVH] = dt_s;             // h += v_h * dt
    F[kBBaro * kN + kBBaro] = alpha_baro; // baro bias decay
    F[kBGnss * kN + kBGnss] = alpha_gnss; // GNSS bias decay

    // Process noise Q (IAQS-scaled)
    double Q[kN * kN];
    std::memset(Q, 0, sizeof(Q));
    double qs = s.iaqs_q_scale;
    Q[kH * kN + kH]         = ALTITUDE_EKF_Q_H * dt_s * qs;
    Q[kVH * kN + kVH]       = ALTITUDE_EKF_Q_VH * dt_s * qs;
    Q[kBBaro * kN + kBBaro] = (1.0 - alpha_baro * alpha_baro) * 0.01 * qs;
    Q[kBGnss * kN + kBGnss] = (1.0 - alpha_gnss * alpha_gnss) * 0.01 * qs;
    Q[kSVio * kN + kSVio]   = ALTITUDE_VIO_BASE_DRIFT_MPS * dt_s * qs;

    // Covariance propagation: P = F*P*F' + Q
    double FP[kN * kN];
    for (int i = 0; i < kN; ++i) {
        for (int j = 0; j < kN; ++j) {
            double sum = 0.0;
            for (int k = 0; k < kN; ++k) {
                sum += F[i * kN + k] * s.P[k * kN + j];
            }
            FP[i * kN + j] = sum;
        }
    }

    double P_new[kN * kN];
    for (int i = 0; i < kN; ++i) {
        for (int j = 0; j < kN; ++j) {
            double sum = 0.0;
            for (int k = 0; k < kN; ++k) {
                sum += FP[i * kN + k] * F[j * kN + k];  // F' transpose
            }
            P_new[i * kN + j] = sum + Q[i * kN + j];
        }
    }

    std::memcpy(s.P, P_new, sizeof(P_new));
    clamp_covariance_diagonal(s.P);

    s.frame_counter++;
    guard_state(s);

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// EKF Update: fuse GNSS, baro, and VIO measurements
// ---------------------------------------------------------------------------
core::Status altitude_engine_update(AltitudeEngine* engine,
                                    const AltitudeMeasurement& meas) {
    if (!engine) return core::Status::kInvalidArgument;
    if (meas.dt_s <= 0.0) return core::Status::kInvalidArgument;

    AltitudeState& s = engine->state;
    // H2 FIX: Always use Joseph-form covariance update for numerical stability.
    // The naive form P=(I-KH)*P can lose positive-definiteness over time.
    // Reference: Grewal & Andrews 2015, "Kalman Filtering: Theory and Practice"
    constexpr bool use_joseph = true;

    // --- GNSS update ---
    // GNSS provides an absolute altitude reference (after geoid correction).
    // The GNSS bias b_gnss is subtracted from the raw measurement to yield
    // the corrected observation: z = gnss_raw - geoid - b_gnss ≈ h_true
    {
        double gnss_corrected = meas.gnss_alt_m - meas.geoid_undulation_m - s.b_gnss;
        double z = gnss_corrected;  // corrected measurement
        double h_pred = s.h;  // predicted = state altitude

        double H[kN] = {0};
        H[kH] = 1.0;

        double R = 9.0;  // GNSS noise variance ~3m sigma

        double S = 0.0;
        for (int i = 0; i < kN; ++i) {
            for (int j = 0; j < kN; ++j) {
                S += H[i] * s.P[i * kN + j] * H[j];
            }
        }
        S += R;

        if (S > 1e-12) {
            double innovation = z - h_pred;

            // Kalman gain K = P * H' / S
            double K[kN];
            for (int i = 0; i < kN; ++i) {
                double ph = 0.0;
                for (int j = 0; j < kN; ++j) {
                    ph += s.P[i * kN + j] * H[j];
                }
                K[i] = ph / S;
            }

            // NIS for IAQS
            double nis = (innovation * innovation) / S;

            // State update: x = x + K * innovation
            s.h         += K[kH]     * innovation;
            s.v_h       += K[kVH]    * innovation;
            s.b_baro    += K[kBBaro] * innovation;
            s.b_gnss    += K[kBGnss] * innovation;
            s.sigma_vio += K[kSVio]  * innovation;

            // Covariance update
            if (use_joseph) {
                double P_copy[kN * kN];
                std::memcpy(P_copy, s.P, sizeof(P_copy));
                joseph_update(s.P, P_copy, K, H, R, kN);
            } else {
                // Standard: P = (I - K*H) * P
                double P_copy[kN * kN];
                std::memcpy(P_copy, s.P, sizeof(P_copy));
                for (int i = 0; i < kN; ++i) {
                    for (int j = 0; j < kN; ++j) {
                        // Full (I - K*H)*P multiplication
                        double sum = 0.0;
                        for (int m = 0; m < kN; ++m) {
                            double ikh = (i == m ? 1.0 : 0.0) - K[i] * H[m];
                            sum += ikh * P_copy[m * kN + j];
                        }
                        s.P[i * kN + j] = sum;
                    }
                }
            }

            // IAQS: Adaptive Q scaling
            engine->nis_ema = (1.0 - IAQS_EMA_ALPHA) * engine->nis_ema + IAQS_EMA_ALPHA * nis;
            if (engine->nis_ema > IAQS_OVERCONFIDENT_THRESHOLD) {
                s.iaqs_q_scale *= IAQS_INCREASE_FACTOR;
            } else if (engine->nis_ema < IAQS_UNDERCONFIDENT_THRESHOLD) {
                s.iaqs_q_scale -= IAQS_DECREASE_STEP;
            }
            if (s.iaqs_q_scale < IAQS_Q_SCALE_MIN) s.iaqs_q_scale = IAQS_Q_SCALE_MIN;
            if (s.iaqs_q_scale > IAQS_Q_SCALE_MAX) s.iaqs_q_scale = IAQS_Q_SCALE_MAX;
        }
    }

    // --- Baro update ---
    // Barometer provides altitude observation with a slow-varying bias.
    // Corrected observation: z = baro_raw - b_baro ≈ h_true
    {
        double z = meas.baro_alt_m - s.b_baro;
        double h_pred = s.h;

        double H[kN] = {0};
        H[kH] = 1.0;

        double R = ALTITUDE_BARO_NOISE_M * ALTITUDE_BARO_NOISE_M;

        double S = 0.0;
        for (int i = 0; i < kN; ++i) {
            for (int j = 0; j < kN; ++j) {
                S += H[i] * s.P[i * kN + j] * H[j];
            }
        }
        S += R;

        if (S > 1e-12) {
            double innovation = z - h_pred;

            double K[kN];
            for (int i = 0; i < kN; ++i) {
                double ph = 0.0;
                for (int j = 0; j < kN; ++j) {
                    ph += s.P[i * kN + j] * H[j];
                }
                K[i] = ph / S;
            }

            // State update
            s.h       += K[kH]     * innovation;
            s.v_h     += K[kVH]    * innovation;
            s.b_baro  += K[kBBaro] * innovation;
            s.b_gnss  += K[kBGnss] * innovation;
            s.sigma_vio += K[kSVio] * innovation;

            // Covariance update — always Joseph form for numerical stability
            {
                double P_copy[kN * kN];
                std::memcpy(P_copy, s.P, sizeof(P_copy));
                joseph_update(s.P, P_copy, K, H, R, kN);
            }
        }
    }

    // --- VIO update (velocity observation) ---
    {
        double z = meas.vio_delta_h / meas.dt_s;  // Observed vertical velocity
        double h_pred = s.v_h;

        double H[kN] = {0};
        H[kVH] = 1.0;

        double R = s.sigma_vio * s.sigma_vio + 0.01;

        double S = 0.0;
        for (int i = 0; i < kN; ++i) {
            for (int j = 0; j < kN; ++j) {
                S += H[i] * s.P[i * kN + j] * H[j];
            }
        }
        S += R;

        if (S > 1e-12) {
            double innovation = z - h_pred;

            double K[kN];
            for (int i = 0; i < kN; ++i) {
                double ph = 0.0;
                for (int j = 0; j < kN; ++j) {
                    ph += s.P[i * kN + j] * H[j];
                }
                K[i] = ph / S;
            }

            s.h       += K[kH]     * innovation;
            s.v_h     += K[kVH]    * innovation;
            s.b_baro  += K[kBBaro] * innovation;
            s.b_gnss  += K[kBGnss] * innovation;
            s.sigma_vio += K[kSVio] * innovation;

            // Covariance update — always Joseph form for numerical stability
            {
                double P_copy[kN * kN];
                std::memcpy(P_copy, s.P, sizeof(P_copy));
                joseph_update(s.P, P_copy, K, H, R, kN);
            }
        }
    }

    // Clamp sigma_vio to non-negative (L3 fix: drift magnitude cannot be negative)
    if (s.sigma_vio < 0.0) s.sigma_vio = 0.0;

    // Floor detection
    s.floor_level = detect_floor(s.h);

    // Confidence update based on covariance
    double h_var = s.P[kH * kN + kH];
    if (h_var < 0.01) h_var = 0.01;
    s.confidence = 1.0 / (1.0 + std::sqrt(h_var));
    if (s.confidence < ALTITUDE_MIN_CONFIDENCE) s.confidence = ALTITUDE_MIN_CONFIDENCE;
    if (s.confidence > 1.0) s.confidence = 1.0;

    // VIO drift reset check
    if (s.sigma_vio > ALTITUDE_VIO_RESET_SIGMA_M) {
        s.sigma_vio = ALTITUDE_VIO_BASE_DRIFT_MPS;
        s.P[kSVio * kN + kSVio] = 1.0;
    }

    clamp_covariance_diagonal(s.P);
    s.frame_counter++;
    guard_state(s);

    return core::Status::kOk;
}

const AltitudeState* altitude_engine_state(const AltitudeEngine* engine) {
    if (!engine) return nullptr;
    return &engine->state;
}

}  // namespace geo
}  // namespace aether
