// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/pose_graph.h"
#include "aether/tsdf/solver_watchdog.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <vector>

namespace aether {
namespace tsdf {
namespace {

struct Vec3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

struct PoseRt {
    // Row-major 3x3.
    float r[9] = {
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    };
    Vec3 t{};
};

inline Vec3 add(const Vec3& a, const Vec3& b) {
    return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
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

inline float norm(const Vec3& v) {
    return std::sqrt(dot(v, v));
}

inline void mat3_identity(float out[9]) {
    out[0] = 1.0f; out[1] = 0.0f; out[2] = 0.0f;
    out[3] = 0.0f; out[4] = 1.0f; out[5] = 0.0f;
    out[6] = 0.0f; out[7] = 0.0f; out[8] = 1.0f;
}

inline void mat3_transpose(const float in[9], float out[9]) {
    out[0] = in[0]; out[1] = in[3]; out[2] = in[6];
    out[3] = in[1]; out[4] = in[4]; out[5] = in[7];
    out[6] = in[2]; out[7] = in[5]; out[8] = in[8];
}

inline void mat3_mul(const float a[9], const float b[9], float out[9]) {
    out[0] = a[0] * b[0] + a[1] * b[3] + a[2] * b[6];
    out[1] = a[0] * b[1] + a[1] * b[4] + a[2] * b[7];
    out[2] = a[0] * b[2] + a[1] * b[5] + a[2] * b[8];

    out[3] = a[3] * b[0] + a[4] * b[3] + a[5] * b[6];
    out[4] = a[3] * b[1] + a[4] * b[4] + a[5] * b[7];
    out[5] = a[3] * b[2] + a[4] * b[5] + a[5] * b[8];

    out[6] = a[6] * b[0] + a[7] * b[3] + a[8] * b[6];
    out[7] = a[6] * b[1] + a[7] * b[4] + a[8] * b[7];
    out[8] = a[6] * b[2] + a[7] * b[5] + a[8] * b[8];
}

inline Vec3 mat3_mul_vec(const float m[9], const Vec3& v) {
    return Vec3{
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z,
    };
}

inline void pose_to_rt(const float pose[16], PoseRt* out) {
    out->r[0] = pose[0];  out->r[1] = pose[4];  out->r[2] = pose[8];
    out->r[3] = pose[1];  out->r[4] = pose[5];  out->r[5] = pose[9];
    out->r[6] = pose[2];  out->r[7] = pose[6];  out->r[8] = pose[10];
    out->t = Vec3{pose[12], pose[13], pose[14]};
}

inline void rt_to_pose(const PoseRt& in, float pose[16]) {
    pose[0] = in.r[0];  pose[4] = in.r[1];  pose[8] = in.r[2];
    pose[1] = in.r[3];  pose[5] = in.r[4];  pose[9] = in.r[5];
    pose[2] = in.r[6];  pose[6] = in.r[7];  pose[10] = in.r[8];
    pose[3] = 0.0f;     pose[7] = 0.0f;     pose[11] = 0.0f;
    pose[12] = in.t.x;  pose[13] = in.t.y;  pose[14] = in.t.z; pose[15] = 1.0f;
}

inline Vec3 so3_log(const float r[9]) {
    const float trace = r[0] + r[4] + r[8];
    const float cos_theta = std::clamp((trace - 1.0f) * 0.5f, -1.0f, 1.0f);
    const float theta = std::acos(cos_theta);
    if (theta < 1e-6f) {
        return Vec3{
            0.5f * (r[7] - r[5]),
            0.5f * (r[2] - r[6]),
            0.5f * (r[3] - r[1]),
        };
    }
    const float scale = theta / std::max(1e-6f, 2.0f * std::sin(theta));
    return Vec3{
        scale * (r[7] - r[5]),
        scale * (r[2] - r[6]),
        scale * (r[3] - r[1]),
    };
}

inline void so3_exp(const Vec3& w, float out_r[9]) {
    const float theta = norm(w);
    mat3_identity(out_r);
    if (theta < 1e-8f) {
        out_r[1] = -w.z; out_r[2] = w.y;
        out_r[3] = w.z;  out_r[5] = -w.x;
        out_r[6] = -w.y; out_r[7] = w.x;
        return;
    }

    const float inv_theta = 1.0f / theta;
    const float kx = w.x * inv_theta;
    const float ky = w.y * inv_theta;
    const float kz = w.z * inv_theta;
    const float c = std::cos(theta);
    const float s = std::sin(theta);
    const float v = 1.0f - c;

    out_r[0] = c + kx * kx * v;
    out_r[1] = kx * ky * v - kz * s;
    out_r[2] = kx * kz * v + ky * s;

    out_r[3] = ky * kx * v + kz * s;
    out_r[4] = c + ky * ky * v;
    out_r[5] = ky * kz * v - kx * s;

    out_r[6] = kz * kx * v - ky * s;
    out_r[7] = kz * ky * v + kx * s;
    out_r[8] = c + kz * kz * v;
}

inline void apply_se3_delta(PoseRt* pose, const Vec3& delta_rot, const Vec3& delta_t) {
    float r_inc[9];
    float new_r[9];
    so3_exp(delta_rot, r_inc);
    mat3_mul(r_inc, pose->r, new_r);
    for (int i = 0; i < 9; ++i) {
        pose->r[i] = new_r[i];
    }
    pose->t = add(mat3_mul_vec(r_inc, pose->t), delta_t);
}

inline float robust_weight(float error_norm, float huber_delta) {
    if (huber_delta <= 0.0f || error_norm <= huber_delta) {
        return 1.0f;
    }
    return huber_delta / std::max(error_norm, 1e-6f);
}

inline void edge_residual(
    const PoseRt& i_pose,
    const PoseRt& j_pose,
    const PoseRt& meas,
    Vec3* out_r_rot,
    Vec3* out_r_trans) {
    float ri_t[9];
    mat3_transpose(i_pose.r, ri_t);

    float r_pred[9];
    mat3_mul(ri_t, j_pose.r, r_pred);
    const Vec3 t_pred = mat3_mul_vec(ri_t, sub(j_pose.t, i_pose.t));

    float rm_t[9];
    float r_err[9];
    mat3_transpose(meas.r, rm_t);
    mat3_mul(rm_t, r_pred, r_err);

    *out_r_rot = so3_log(r_err);
    *out_r_trans = sub(t_pred, meas.t);
}

float compute_error(
    const std::vector<PoseRt>& poses,
    const PoseGraphEdge* edges,
    std::size_t edge_count,
    const std::unordered_map<std::uint32_t, std::size_t>& node_lut) {
    float total = 0.0f;
    for (std::size_t e = 0u; e < edge_count; ++e) {
        const auto it_i = node_lut.find(edges[e].from_id);
        const auto it_j = node_lut.find(edges[e].to_id);
        if (it_i == node_lut.end() || it_j == node_lut.end()) {
            continue;
        }
        PoseRt meas{};
        pose_to_rt(edges[e].transform, &meas);
        Vec3 r_rot{};
        Vec3 r_trans{};
        edge_residual(poses[it_i->second], poses[it_j->second], meas, &r_rot, &r_trans);
        const float sq = dot(r_rot, r_rot) + dot(r_trans, r_trans);
        const float w = edges[e].is_loop ? 1.5f : 1.0f;
        total += w * sq;
    }
    return total;
}

}  // namespace

core::Status optimize_pose_graph(
    PoseGraphNode* nodes,
    std::size_t node_count,
    const PoseGraphEdge* edges,
    std::size_t edge_count,
    const PoseGraphConfig& config,
    PoseGraphResult* out_result) {
    if (nodes == nullptr || edges == nullptr || out_result == nullptr || node_count == 0u) {
        return core::Status::kInvalidArgument;
    }
    *out_result = PoseGraphResult{};

    std::unordered_map<std::uint32_t, std::size_t> node_lut;
    node_lut.reserve(node_count * 2u);
    std::vector<PoseGraphNode> node_copy(node_count);
    std::vector<PoseRt> poses(node_count);
    std::vector<PoseRt> initial_poses(node_count);
    for (std::size_t i = 0u; i < node_count; ++i) {
        node_copy[i] = nodes[i];
        pose_to_rt(nodes[i].pose, &poses[i]);
        initial_poses[i] = poses[i];
        node_lut[nodes[i].id] = i;
    }

    const int max_iterations = std::max(1, std::min(config.max_iterations, 100));
    const float step_size = std::clamp(config.step_size, 0.01f, 1.0f);
    const float stop_translation = std::max(config.stop_translation, 1e-8f);
    const float stop_rotation = std::max(config.stop_rotation, 1e-8f);

    SolverWatchdogConfig watchdog_config{};
    watchdog_config.max_diag_ratio = std::max(1.0f, config.watchdog_max_diag_ratio);
    watchdog_config.max_residual_rise_streak = std::max(1, config.watchdog_max_residual_rise);
    watchdog_config.residual_rise_ratio = 1.01f;
    SolverWatchdogState watchdog{};

    const float initial_error = compute_error(poses, edges, edge_count, node_lut);
    out_result->initial_error = initial_error;
    out_result->final_error = initial_error;

    for (int iter = 0; iter < max_iterations; ++iter) {
        std::vector<Vec3> grad_rot(node_count, Vec3{});
        std::vector<Vec3> grad_trans(node_count, Vec3{});
        std::vector<float> hdiag(node_count * 6u, 0.0f);
        std::vector<int> degree(node_count, 0);

        float residual_error = 0.0f;
        for (std::size_t e = 0u; e < edge_count; ++e) {
            const auto it_i = node_lut.find(edges[e].from_id);
            const auto it_j = node_lut.find(edges[e].to_id);
            if (it_i == node_lut.end() || it_j == node_lut.end()) {
                continue;
            }
            const std::size_t i = it_i->second;
            const std::size_t j = it_j->second;
            PoseRt meas{};
            pose_to_rt(edges[e].transform, &meas);

            Vec3 r_rot{};
            Vec3 r_trans{};
            edge_residual(poses[i], poses[j], meas, &r_rot, &r_trans);
            const float residual_norm = std::sqrt(dot(r_rot, r_rot) + dot(r_trans, r_trans));
            const float w = robust_weight(residual_norm, config.huber_delta) * (edges[e].is_loop ? 1.5f : 1.0f);
            residual_error += w * residual_norm * residual_norm;

            const Vec3 wr = mul(r_rot, w);
            const Vec3 wt = mul(r_trans, w);

            if (!node_copy[i].fixed) {
                grad_rot[i] = add(grad_rot[i], mul(wr, -1.0f));
                grad_trans[i] = add(grad_trans[i], mul(wt, -1.0f));
                degree[i] += 1;
                hdiag[i * 6u + 0u] += w;
                hdiag[i * 6u + 1u] += w;
                hdiag[i * 6u + 2u] += w;
                hdiag[i * 6u + 3u] += w;
                hdiag[i * 6u + 4u] += w;
                hdiag[i * 6u + 5u] += w;
            }
            if (!node_copy[j].fixed) {
                grad_rot[j] = add(grad_rot[j], wr);
                grad_trans[j] = add(grad_trans[j], wt);
                degree[j] += 1;
                hdiag[j * 6u + 0u] += w;
                hdiag[j * 6u + 1u] += w;
                hdiag[j * 6u + 2u] += w;
                hdiag[j * 6u + 3u] += w;
                hdiag[j * 6u + 4u] += w;
                hdiag[j * 6u + 5u] += w;
            }
        }

        float diag_min = std::numeric_limits<float>::infinity();
        float diag_max = 0.0f;
        for (float v : hdiag) {
            if (v > 0.0f && std::isfinite(v)) {
                diag_min = std::min(diag_min, v);
                diag_max = std::max(diag_max, v);
            }
        }
        if (!std::isfinite(diag_min) || diag_max <= 0.0f) {
            diag_min = 1.0f;
            diag_max = 1.0f;
        }

        if (!solver_watchdog_observe(diag_min, diag_max, residual_error, watchdog_config, &watchdog)) {
            out_result->watchdog_tripped = true;
            out_result->watchdog_diag_ratio = watchdog.last_diag_ratio;
            break;
        }

        float max_translation_update = 0.0f;
        float max_rotation_update = 0.0f;
        for (std::size_t i = 0u; i < node_count; ++i) {
            if (node_copy[i].fixed || degree[i] <= 0) {
                continue;
            }
            const float inv_degree = 1.0f / static_cast<float>(degree[i]);
            const Vec3 delta_rot = mul(grad_rot[i], -step_size * inv_degree);
            const Vec3 delta_t = mul(grad_trans[i], -step_size * inv_degree);
            apply_se3_delta(&poses[i], delta_rot, delta_t);

            max_translation_update = std::max(max_translation_update, norm(delta_t));
            max_rotation_update = std::max(max_rotation_update, norm(delta_rot));
        }

        out_result->iterations = iter + 1;
        out_result->watchdog_diag_ratio = watchdog.last_diag_ratio;
        out_result->final_error = compute_error(poses, edges, edge_count, node_lut);

        if (max_translation_update < stop_translation && max_rotation_update < stop_rotation) {
            out_result->converged = true;
            break;
        }
    }

    if (out_result->watchdog_tripped) {
        poses = initial_poses;
        out_result->final_error = initial_error;
    }

    for (std::size_t i = 0u; i < node_count; ++i) {
        rt_to_pose(poses[i], nodes[i].pose);
    }
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
