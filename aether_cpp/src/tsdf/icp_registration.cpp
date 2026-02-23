// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/icp_registration.h"
#include "aether/tsdf/solver_watchdog.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>

namespace aether {
namespace tsdf {
namespace {

struct Vec3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

inline Vec3 to_vec3(const ICPPoint& p) {
    return Vec3{p.x, p.y, p.z};
}

inline Vec3 sub(const Vec3& a, const Vec3& b) {
    return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

inline Vec3 mul(const Vec3& a, float s) {
    return Vec3{a.x * s, a.y * s, a.z * s};
}

inline float dot(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return Vec3{
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    };
}

inline float norm(const Vec3& a) {
    return std::sqrt(dot(a, a));
}

inline Vec3 normalize(const Vec3& a) {
    const float n = norm(a);
    if (n <= 1e-8f) {
        return Vec3{0.0f, 0.0f, 1.0f};
    }
    return mul(a, 1.0f / n);
}

inline Vec3 transform_point(const float pose[16], const Vec3& p) {
    return Vec3{
        pose[0] * p.x + pose[4] * p.y + pose[8] * p.z + pose[12],
        pose[1] * p.x + pose[5] * p.y + pose[9] * p.z + pose[13],
        pose[2] * p.x + pose[6] * p.y + pose[10] * p.z + pose[14],
    };
}

inline void pose_multiply(float lhs[16], const float rhs[16]) {
    float out[16] = {0.0f};
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) {
                sum += lhs[k * 4 + r] * rhs[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
    for (int i = 0; i < 16; ++i) {
        lhs[i] = out[i];
    }
}

inline float deg_to_cos(float deg) {
    const float rad = deg * static_cast<float>(3.14159265358979323846 / 180.0);
    return std::cos(rad);
}

float robust_weight(float residual, float huber_delta) {
    const float a = std::fabs(residual);
    if (a <= huber_delta || huber_delta <= 0.0f) {
        return 1.0f;
    }
    return huber_delta / a;
}

bool solve_symmetric_6x6(float a[6][6], float b[6], float x[6]) {
    // Gaussian elimination with partial pivoting.
    float m[6][7] = {{0.0f}};
    for (int r = 0; r < 6; ++r) {
        for (int c = 0; c < 6; ++c) {
            m[r][c] = a[r][c];
        }
        m[r][6] = b[r];
    }

    for (int k = 0; k < 6; ++k) {
        int pivot = k;
        float best = std::fabs(m[k][k]);
        for (int r = k + 1; r < 6; ++r) {
            const float v = std::fabs(m[r][k]);
            if (v > best) {
                best = v;
                pivot = r;
            }
        }
        if (!(best > 1e-9f) || !std::isfinite(best)) {
            return false;
        }
        if (pivot != k) {
            for (int c = k; c <= 6; ++c) {
                std::swap(m[k][c], m[pivot][c]);
            }
        }

        const float diag = m[k][k];
        for (int c = k; c <= 6; ++c) {
            m[k][c] /= diag;
        }

        for (int r = 0; r < 6; ++r) {
            if (r == k) {
                continue;
            }
            const float factor = m[r][k];
            for (int c = k; c <= 6; ++c) {
                m[r][c] -= factor * m[k][c];
            }
        }
    }

    for (int i = 0; i < 6; ++i) {
        x[i] = m[i][6];
        if (!std::isfinite(x[i])) {
            return false;
        }
    }
    return true;
}

void exp_se3(const float delta[6], float out_pose[16]) {
    const Vec3 w{delta[0], delta[1], delta[2]};
    const Vec3 t{delta[3], delta[4], delta[5]};
    const float theta = norm(w);

    float r[9] = {
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    };

    if (theta > 1e-8f) {
        const Vec3 k = mul(w, 1.0f / theta);
        const float c = std::cos(theta);
        const float s = std::sin(theta);
        const float v = 1.0f - c;

        r[0] = k.x * k.x * v + c;
        r[1] = k.x * k.y * v + k.z * s;
        r[2] = k.x * k.z * v - k.y * s;

        r[3] = k.y * k.x * v - k.z * s;
        r[4] = k.y * k.y * v + c;
        r[5] = k.y * k.z * v + k.x * s;

        r[6] = k.z * k.x * v + k.y * s;
        r[7] = k.z * k.y * v - k.x * s;
        r[8] = k.z * k.z * v + c;
    }

    out_pose[0] = r[0]; out_pose[4] = r[1]; out_pose[8] = r[2]; out_pose[12] = t.x;
    out_pose[1] = r[3]; out_pose[5] = r[4]; out_pose[9] = r[5]; out_pose[13] = t.y;
    out_pose[2] = r[6]; out_pose[6] = r[7]; out_pose[10] = r[8]; out_pose[14] = t.z;
    out_pose[3] = 0.0f; out_pose[7] = 0.0f; out_pose[11] = 0.0f; out_pose[15] = 1.0f;
}

}  // namespace

core::Status icp_refine(
    const ICPPoint* source_points,
    std::size_t source_count,
    const ICPPoint* target_points,
    std::size_t target_count,
    const ICPPoint* target_normals,
    const float initial_pose[16],
    float angular_velocity,
    const ICPConfig& config,
    ICPResult* out_result) {
    if (source_count > 0u && source_points == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (target_count > 0u && target_points == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (target_count > 0u && target_normals == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (initial_pose == nullptr || out_result == nullptr || source_count == 0u || target_count == 0u) {
        return core::Status::kInvalidArgument;
    }

    *out_result = ICPResult{};
    float pose[16] = {0.0f};
    for (int i = 0; i < 16; ++i) {
        pose[i] = initial_pose[i];
    }

    const float dynamic_threshold = std::clamp(
        config.distance_threshold * (1.0f + std::fabs(angular_velocity) * 0.5f),
        0.002f,
        0.10f);
    const float normal_cos_threshold = deg_to_cos(config.normal_threshold_deg);
    const int max_iterations = std::max(1, std::min(config.max_iterations, 50));

    float last_rmse = std::numeric_limits<float>::infinity();
    SolverWatchdogState watchdog{};
    SolverWatchdogConfig watchdog_config{};
    watchdog_config.max_diag_ratio = std::max(1.0f, config.watchdog_max_diag_ratio);
    watchdog_config.max_residual_rise_streak = std::max(1, config.watchdog_max_residual_rise);
    watchdog_config.residual_rise_ratio = 1.01f;

    for (int iter = 0; iter < max_iterations; ++iter) {
        float ata[6][6] = {{0.0f}};
        float atb[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};

        float sq_error_sum = 0.0f;
        int corr_count = 0;

        for (std::size_t i = 0u; i < source_count; ++i) {
            const Vec3 s = transform_point(pose, to_vec3(source_points[i]));

            float best_dist2 = std::numeric_limits<float>::infinity();
            std::size_t best_j = 0u;
            for (std::size_t j = 0u; j < target_count; ++j) {
                const Vec3 t = to_vec3(target_points[j]);
                const Vec3 d = sub(s, t);
                const float dist2 = dot(d, d);
                if (dist2 < best_dist2) {
                    best_dist2 = dist2;
                    best_j = j;
                }
            }

            const float dist = std::sqrt(best_dist2);
            if (!(dist < dynamic_threshold)) {
                continue;
            }

            const Vec3 q = to_vec3(target_points[best_j]);
            const Vec3 n = normalize(to_vec3(target_normals[best_j]));
            const Vec3 d = sub(s, q);

            const float point_norm = std::max(1e-6f, norm(d));
            const float cos_angle = std::fabs(dot(normalize(d), n));
            if (std::isfinite(cos_angle) && cos_angle < normal_cos_threshold && point_norm > 1e-3f) {
                continue;
            }

            const float residual = dot(n, d);
            const float weight = robust_weight(residual, config.huber_delta);
            const Vec3 cross_sn = cross(s, n);
            const float j_row[6] = {
                cross_sn.x,
                cross_sn.y,
                cross_sn.z,
                n.x,
                n.y,
                n.z,
            };

            for (int r = 0; r < 6; ++r) {
                atb[r] += weight * j_row[r] * residual;
                for (int c = 0; c < 6; ++c) {
                    ata[r][c] += weight * j_row[r] * j_row[c];
                }
            }

            sq_error_sum += residual * residual;
            corr_count += 1;
        }

        if (corr_count < 6) {
            break;
        }

        float diag_min = std::numeric_limits<float>::infinity();
        float diag_max = 0.0f;
        for (int d = 0; d < 6; ++d) {
            const float v = std::fabs(ata[d][d]);
            if (v > 0.0f) {
                diag_min = std::min(diag_min, v);
                diag_max = std::max(diag_max, v);
            }
        }
        const float rmse = std::sqrt(std::max(0.0f, sq_error_sum / static_cast<float>(corr_count)));
        if (!solver_watchdog_observe(diag_min, diag_max, rmse, watchdog_config, &watchdog)) {
            out_result->watchdog_tripped = true;
            out_result->watchdog_diag_ratio = watchdog.last_diag_ratio;
            break;
        }

        float delta[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        for (float& v : atb) {
            v = -v;
        }
        if (!solve_symmetric_6x6(ata, atb, delta)) {
            break;
        }

        float update_pose[16] = {0.0f};
        exp_se3(delta, update_pose);
        pose_multiply(update_pose, pose);
        for (int i = 0; i < 16; ++i) {
            pose[i] = update_pose[i];
        }

        const float delta_t = std::sqrt(delta[3] * delta[3] + delta[4] * delta[4] + delta[5] * delta[5]);
        const float delta_r = std::sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]);

        out_result->iterations = iter + 1;
        out_result->correspondence_count = corr_count;
        out_result->rmse = rmse;
        out_result->watchdog_diag_ratio = watchdog.last_diag_ratio;

        if (delta_t < config.convergence_translation && delta_r < config.convergence_rotation) {
            out_result->converged = true;
            break;
        }
        if (rmse > last_rmse * 1.05f) {
            break;
        }
        last_rmse = rmse;
    }

    for (int i = 0; i < 16; ++i) {
        out_result->pose_out[i] = out_result->watchdog_tripped ? initial_pose[i] : pose[i];
    }
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
