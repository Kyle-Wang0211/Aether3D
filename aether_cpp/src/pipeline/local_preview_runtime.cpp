// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_preview_runtime.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

#include "aether_tsdf_c.h"
#include "aether/pipeline/pipeline_coordinator.h"

namespace {

struct ICPVec3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

inline ICPVec3 icp_add(const ICPVec3& a, const ICPVec3& b) noexcept {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

inline ICPVec3 icp_sub(const ICPVec3& a, const ICPVec3& b) noexcept {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

inline ICPVec3 icp_mul(const ICPVec3& v, float s) noexcept {
    return {v.x * s, v.y * s, v.z * s};
}

inline float icp_dot(const ICPVec3& a, const ICPVec3& b) noexcept {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline float icp_norm_sq(const ICPVec3& v) noexcept {
    return icp_dot(v, v);
}

inline ICPVec3 icp_from_c(const aether_icp_point_t& p) noexcept {
    return {p.x, p.y, p.z};
}

inline ICPVec3 icp_transform_point(const float pose[16], const ICPVec3& p) noexcept {
    return {
        pose[0] * p.x + pose[4] * p.y + pose[8] * p.z + pose[12],
        pose[1] * p.x + pose[5] * p.y + pose[9] * p.z + pose[13],
        pose[2] * p.x + pose[6] * p.y + pose[10] * p.z + pose[14]};
}

inline void icp_quat_to_matrix(const float q[4], float r[9]) noexcept {
    const float w = q[0];
    const float x = q[1];
    const float y = q[2];
    const float z = q[3];
    const float xx = x * x;
    const float yy = y * y;
    const float zz = z * z;
    const float xy = x * y;
    const float xz = x * z;
    const float yz = y * z;
    const float wx = w * x;
    const float wy = w * y;
    const float wz = w * z;

    r[0] = 1.0f - 2.0f * (yy + zz);
    r[1] = 2.0f * (xy - wz);
    r[2] = 2.0f * (xz + wy);
    r[3] = 2.0f * (xy + wz);
    r[4] = 1.0f - 2.0f * (xx + zz);
    r[5] = 2.0f * (yz - wx);
    r[6] = 2.0f * (xz - wy);
    r[7] = 2.0f * (yz + wx);
    r[8] = 1.0f - 2.0f * (xx + yy);
}

inline void icp_build_pose(const float r[9], const ICPVec3& t, float pose[16]) noexcept {
    pose[0] = r[0];
    pose[1] = r[3];
    pose[2] = r[6];
    pose[3] = 0.0f;
    pose[4] = r[1];
    pose[5] = r[4];
    pose[6] = r[7];
    pose[7] = 0.0f;
    pose[8] = r[2];
    pose[9] = r[5];
    pose[10] = r[8];
    pose[11] = 0.0f;
    pose[12] = t.x;
    pose[13] = t.y;
    pose[14] = t.z;
    pose[15] = 1.0f;
}

inline float icp_rotation_delta_rad(const float a[16], const float b[16]) noexcept {
    float rrel00 = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    float rrel11 = a[4] * b[4] + a[5] * b[5] + a[6] * b[6];
    float rrel22 = a[8] * b[8] + a[9] * b[9] + a[10] * b[10];
    float trace = rrel00 + rrel11 + rrel22;
    float c = std::clamp((trace - 1.0f) * 0.5f, -1.0f, 1.0f);
    return std::acos(c);
}

inline bool icp_solve_absolute_pose(
    const std::vector<ICPVec3>& source_cam,
    const std::vector<ICPVec3>& target_world,
    float pose_out[16],
    float* out_rmse) noexcept {
    if (source_cam.size() != target_world.size() || source_cam.size() < 3u) {
        return false;
    }

    ICPVec3 cs{};
    ICPVec3 ct{};
    for (std::size_t i = 0; i < source_cam.size(); ++i) {
        cs = icp_add(cs, source_cam[i]);
        ct = icp_add(ct, target_world[i]);
    }
    const float inv_n = 1.0f / static_cast<float>(source_cam.size());
    cs = icp_mul(cs, inv_n);
    ct = icp_mul(ct, inv_n);

    float sxx = 0.0f, sxy = 0.0f, sxz = 0.0f;
    float syx = 0.0f, syy = 0.0f, syz = 0.0f;
    float szx = 0.0f, szy = 0.0f, szz = 0.0f;
    for (std::size_t i = 0; i < source_cam.size(); ++i) {
        const ICPVec3 a = icp_sub(source_cam[i], cs);
        const ICPVec3 b = icp_sub(target_world[i], ct);
        sxx += a.x * b.x; sxy += a.x * b.y; sxz += a.x * b.z;
        syx += a.y * b.x; syy += a.y * b.y; syz += a.y * b.z;
        szx += a.z * b.x; szy += a.z * b.y; szz += a.z * b.z;
    }

    float n[16]{};
    n[0] = sxx + syy + szz;
    n[1] = syz - szy;
    n[2] = szx - sxz;
    n[3] = sxy - syx;

    n[4] = syz - szy;
    n[5] = sxx - syy - szz;
    n[6] = sxy + syx;
    n[7] = szx + sxz;

    n[8] = szx - sxz;
    n[9] = sxy + syx;
    n[10] = -sxx + syy - szz;
    n[11] = syz + szy;

    n[12] = sxy - syx;
    n[13] = szx + sxz;
    n[14] = syz + szy;
    n[15] = -sxx - syy + szz;

    float q[4]{1.0f, 0.0f, 0.0f, 0.0f};
    for (int iter = 0; iter < 24; ++iter) {
        float qn[4]{};
        qn[0] = n[0] * q[0] + n[1] * q[1] + n[2] * q[2] + n[3] * q[3];
        qn[1] = n[4] * q[0] + n[5] * q[1] + n[6] * q[2] + n[7] * q[3];
        qn[2] = n[8] * q[0] + n[9] * q[1] + n[10] * q[2] + n[11] * q[3];
        qn[3] = n[12] * q[0] + n[13] * q[1] + n[14] * q[2] + n[15] * q[3];
        float len = std::sqrt(std::max(
            1e-12f,
            qn[0] * qn[0] + qn[1] * qn[1] + qn[2] * qn[2] + qn[3] * qn[3]));
        q[0] = qn[0] / len;
        q[1] = qn[1] / len;
        q[2] = qn[2] / len;
        q[3] = qn[3] / len;
    }

    float r[9]{};
    icp_quat_to_matrix(q, r);
    const ICPVec3 rcs{
        r[0] * cs.x + r[1] * cs.y + r[2] * cs.z,
        r[3] * cs.x + r[4] * cs.y + r[5] * cs.z,
        r[6] * cs.x + r[7] * cs.y + r[8] * cs.z};
    const ICPVec3 t = icp_sub(ct, rcs);
    icp_build_pose(r, t, pose_out);

    float rmse_acc = 0.0f;
    for (std::size_t i = 0; i < source_cam.size(); ++i) {
        const ICPVec3 p = icp_transform_point(pose_out, source_cam[i]);
        const ICPVec3 d = icp_sub(p, target_world[i]);
        rmse_acc += icp_norm_sq(d);
    }
    if (out_rmse != nullptr) {
        *out_rmse = std::sqrt(rmse_acc * inv_n);
    }
    return true;
}

}  // namespace

extern "C" int aether_icp_refine(
    const aether_icp_point_t* source_points,
    int source_count,
    const aether_icp_point_t* target_points,
    int target_count,
    const aether_icp_point_t* target_normals,
    const float initial_pose[16],
    float angular_velocity,
    const aether_icp_config_t* config,
    aether_icp_result_t* out_result) {
    (void)target_normals;
    (void)angular_velocity;
    if (source_points == nullptr || target_points == nullptr || initial_pose == nullptr ||
        config == nullptr || out_result == nullptr || source_count < 3 || target_count < 3) {
        return 0;
    }

    float current_pose[16]{};
    std::memcpy(current_pose, initial_pose, sizeof(current_pose));
    float best_pose[16]{};
    std::memcpy(best_pose, current_pose, sizeof(best_pose));
    float best_rmse = std::numeric_limits<float>::infinity();
    int best_corr = 0;
    int watchdog_rise = 0;

    const float max_dist_sq = std::max(config->distance_threshold, 0.01f) *
                              std::max(config->distance_threshold, 0.01f);

    std::vector<ICPVec3> src_corr;
    std::vector<ICPVec3> tgt_corr;
    src_corr.reserve(static_cast<std::size_t>(source_count));
    tgt_corr.reserve(static_cast<std::size_t>(source_count));

    int converged = 0;
    int iterations = 0;
    for (int iter = 0; iter < std::max(config->max_iterations, 1); ++iter) {
        iterations = iter + 1;
        src_corr.clear();
        tgt_corr.clear();

        for (int i = 0; i < source_count; ++i) {
            const ICPVec3 src_cam = icp_from_c(source_points[i]);
            const ICPVec3 src_world = icp_transform_point(current_pose, src_cam);

            float best_d2 = max_dist_sq;
            int best_j = -1;
            for (int j = 0; j < target_count; ++j) {
                const ICPVec3 tgt = icp_from_c(target_points[j]);
                const ICPVec3 delta = icp_sub(src_world, tgt);
                const float d2 = icp_norm_sq(delta);
                if (d2 < best_d2) {
                    best_d2 = d2;
                    best_j = j;
                }
            }

            if (best_j >= 0) {
                src_corr.push_back(src_cam);
                tgt_corr.push_back(icp_from_c(target_points[best_j]));
            }
        }

        if (src_corr.size() < 12u) {
            break;
        }

        float candidate_pose[16]{};
        float candidate_rmse = 0.0f;
        if (!icp_solve_absolute_pose(src_corr, tgt_corr, candidate_pose, &candidate_rmse)) {
            break;
        }

        const float trans_delta = std::sqrt(
            (candidate_pose[12] - current_pose[12]) * (candidate_pose[12] - current_pose[12]) +
            (candidate_pose[13] - current_pose[13]) * (candidate_pose[13] - current_pose[13]) +
            (candidate_pose[14] - current_pose[14]) * (candidate_pose[14] - current_pose[14]));
        const float rot_delta = icp_rotation_delta_rad(current_pose, candidate_pose);

        if (std::isfinite(candidate_rmse) && candidate_rmse < best_rmse) {
            best_rmse = candidate_rmse;
            best_corr = static_cast<int>(src_corr.size());
            std::memcpy(best_pose, candidate_pose, sizeof(best_pose));
            watchdog_rise = 0;
        } else {
            watchdog_rise++;
        }

        std::memcpy(current_pose, candidate_pose, sizeof(current_pose));
        if (trans_delta <= std::max(config->convergence_translation, 1e-4f) &&
            rot_delta <= std::max(config->convergence_rotation, 1e-4f)) {
            converged = 1;
            break;
        }
        if (watchdog_rise > std::max(config->watchdog_max_residual_rise, 2)) {
            break;
        }
    }

    std::memcpy(out_result->pose_out, best_pose, sizeof(best_pose));
    out_result->iterations = iterations;
    out_result->correspondence_count = best_corr;
    out_result->rmse = std::isfinite(best_rmse) ? best_rmse : 0.0f;
    out_result->watchdog_diag_ratio = 1.0f;
    out_result->watchdog_tripped = watchdog_rise > std::max(config->watchdog_max_residual_rise, 2) ? 1 : 0;
    out_result->converged = converged;
    return best_corr >= 12 ? 1 : 0;
}

namespace aether {
namespace pipeline {
namespace local_preview_runtime {
namespace {

inline void normalize3(float& x, float& y, float& z) noexcept {
    const float len = std::sqrt(x * x + y * y + z * z);
    if (len > 1e-6f) {
        x /= len;
        y /= len;
        z /= len;
    } else {
        x = 0.0f;
        y = 1.0f;
        z = 0.0f;
    }
}

inline float translation_distance_m(const float a[3], const float b[3]) noexcept {
    const float dx = a[0] - b[0];
    const float dy = a[1] - b[1];
    const float dz = a[2] - b[2];
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

inline float angular_distance_rad(const float a[3], const float b[3]) noexcept {
    const float dot = std::clamp(
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
        -1.0f, 1.0f);
    return std::acos(dot);
}

inline void set_identity_pose(float pose[16]) noexcept {
    std::memset(pose, 0, sizeof(float) * 16u);
    pose[0] = 1.0f;
    pose[5] = 1.0f;
    pose[10] = 1.0f;
    pose[15] = 1.0f;
}

inline void scaled_depth_intrinsics(
    const FrameInput& input,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    float intr[4]) noexcept {
    const float scale_x = std::max(
        static_cast<float>(input.width) / std::max(static_cast<float>(depth_w), 1.0f),
        1e-6f);
    const float scale_y = std::max(
        static_cast<float>(input.height) / std::max(static_cast<float>(depth_h), 1.0f),
        1e-6f);
    intr[0] = input.intrinsics[0] / scale_x;
    intr[1] = input.intrinsics[4] / scale_y;
    intr[2] = input.intrinsics[2] / scale_x;
    intr[3] = input.intrinsics[5] / scale_y;
}

inline bool backproject_camera_point(
    std::uint32_t x,
    std::uint32_t y,
    float depth,
    const float intr[4],
    aether_icp_point_t& out_point) noexcept {
    if (!std::isfinite(depth) || depth <= 0.10f || depth > 5.00f ||
        intr[0] < 1.0f || intr[1] < 1.0f) {
        return false;
    }
    out_point.x = (static_cast<float>(x) - intr[2]) / intr[0] * depth;
    out_point.y = -(static_cast<float>(y) - intr[3]) / intr[1] * depth;
    out_point.z = -depth;
    return true;
}

inline void transform_point_world(
    const float pose[16],
    const aether_icp_point_t& cam_point,
    aether_icp_point_t& world_point) noexcept {
    world_point.x = pose[0] * cam_point.x + pose[4] * cam_point.y +
                    pose[8] * cam_point.z + pose[12];
    world_point.y = pose[1] * cam_point.x + pose[5] * cam_point.y +
                    pose[9] * cam_point.z + pose[13];
    world_point.z = pose[2] * cam_point.x + pose[6] * cam_point.y +
                    pose[10] * cam_point.z + pose[14];
}

inline bool normalize_point(aether_icp_point_t& p) noexcept {
    const float len = std::sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
    if (!(len > 1e-6f)) {
        return false;
    }
    p.x /= len;
    p.y /= len;
    p.z /= len;
    return true;
}

inline aether_icp_point_t cross_point(
    const aether_icp_point_t& a,
    const aether_icp_point_t& b) noexcept {
    aether_icp_point_t out{};
    out.x = a.y * b.z - a.z * b.y;
    out.y = a.z * b.x - a.x * b.z;
    out.z = a.x * b.y - a.y * b.x;
    return out;
}

inline void build_icp_source_camera_points(
    const FrameInput& input,
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    std::vector<aether_icp_point_t>& out_points) {
    out_points.clear();
    if (!metric_depth || depth_w == 0 || depth_h == 0) {
        return;
    }

    float intr[4]{};
    scaled_depth_intrinsics(input, depth_w, depth_h, intr);
    constexpr std::uint32_t kStep = 12u;
    out_points.reserve(static_cast<std::size_t>(depth_w / kStep + 1u) *
                       static_cast<std::size_t>(depth_h / kStep + 1u));
    for (std::uint32_t y = kStep; y + kStep < depth_h; y += kStep) {
        for (std::uint32_t x = kStep; x + kStep < depth_w; x += kStep) {
            const float depth = metric_depth[static_cast<std::size_t>(y) * depth_w + x];
            aether_icp_point_t cam_point{};
            if (!backproject_camera_point(x, y, depth, intr, cam_point)) {
                continue;
            }
            out_points.push_back(cam_point);
        }
    }
}

inline void build_icp_target_world_points(
    const FrameInput& input,
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    const float pose[16],
    std::vector<aether_icp_point_t>& out_points,
    std::vector<aether_icp_point_t>& out_normals) {
    out_points.clear();
    out_normals.clear();
    if (!metric_depth || depth_w == 0 || depth_h == 0) {
        return;
    }

    float intr[4]{};
    scaled_depth_intrinsics(input, depth_w, depth_h, intr);
    constexpr std::uint32_t kStep = 12u;
    out_points.reserve(static_cast<std::size_t>(depth_w / kStep + 1u) *
                       static_cast<std::size_t>(depth_h / kStep + 1u));
    out_normals.reserve(out_points.capacity());
    for (std::uint32_t y = kStep; y + kStep < depth_h; y += kStep) {
        for (std::uint32_t x = kStep; x + kStep < depth_w; x += kStep) {
            const float depth = metric_depth[static_cast<std::size_t>(y) * depth_w + x];
            const float depth_right = metric_depth[static_cast<std::size_t>(y) * depth_w + (x + kStep)];
            const float depth_down = metric_depth[static_cast<std::size_t>(y + kStep) * depth_w + x];

            aether_icp_point_t p_cam{};
            aether_icp_point_t pr_cam{};
            aether_icp_point_t pd_cam{};
            if (!backproject_camera_point(x, y, depth, intr, p_cam) ||
                !backproject_camera_point(x + kStep, y, depth_right, intr, pr_cam) ||
                !backproject_camera_point(x, y + kStep, depth_down, intr, pd_cam)) {
                continue;
            }

            aether_icp_point_t p_world{};
            aether_icp_point_t pr_world{};
            aether_icp_point_t pd_world{};
            transform_point_world(pose, p_cam, p_world);
            transform_point_world(pose, pr_cam, pr_world);
            transform_point_world(pose, pd_cam, pd_world);

            aether_icp_point_t vx{};
            vx.x = pr_world.x - p_world.x;
            vx.y = pr_world.y - p_world.y;
            vx.z = pr_world.z - p_world.z;
            aether_icp_point_t vy{};
            vy.x = pd_world.x - p_world.x;
            vy.y = pd_world.y - p_world.y;
            vy.z = pd_world.z - p_world.z;
            aether_icp_point_t n = cross_point(vx, vy);
            if (!normalize_point(n)) {
                continue;
            }

            out_points.push_back(p_world);
            out_normals.push_back(n);
        }
    }
}

struct ImportedVideoICPAttempt {
    int icp_ok{0};
    bool accepted{false};
    aether_icp_result_t result{};
    float intrinsics[9]{};
    std::vector<aether_icp_point_t> source_points;
};

inline void copy_intrinsics9(const float src[9], float dst[9]) noexcept {
    std::memcpy(dst, src, sizeof(float) * 9u);
}

inline void scale_intrinsics_focal(const float base[9],
                                   float scale,
                                   float out[9]) noexcept {
    copy_intrinsics9(base, out);
    out[0] = std::max(base[0] * scale, 1.0f);
    out[4] = std::max(base[4] * scale, 1.0f);
}

inline bool better_icp_attempt(const ImportedVideoICPAttempt& candidate,
                               const ImportedVideoICPAttempt& incumbent) noexcept {
    if (candidate.accepted != incumbent.accepted) {
        return candidate.accepted;
    }
    if (candidate.result.correspondence_count != incumbent.result.correspondence_count) {
        return candidate.result.correspondence_count > incumbent.result.correspondence_count;
    }
    if (std::isfinite(candidate.result.rmse) != std::isfinite(incumbent.result.rmse)) {
        return std::isfinite(candidate.result.rmse);
    }
    return candidate.result.rmse < incumbent.result.rmse;
}

inline ImportedVideoICPAttempt run_imported_video_icp_attempt(
    const FrameInput& input,
    const float attempt_intrinsics[9],
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    const std::vector<aether_icp_point_t>& target_points_world,
    const std::vector<aether_icp_point_t>& target_normals_world,
    const float initial_pose[16]) {
    ImportedVideoICPAttempt attempt{};
    copy_intrinsics9(attempt_intrinsics, attempt.intrinsics);
    std::memcpy(attempt.result.pose_out, initial_pose, sizeof(float) * 16u);
    attempt.result.rmse = std::numeric_limits<float>::infinity();
    attempt.result.correspondence_count = 0;

    if (!metric_depth || depth_w == 0 || depth_h == 0 ||
        target_points_world.size() < 48u ||
        target_points_world.size() != target_normals_world.size()) {
        return attempt;
    }

    FrameInput probe{};
    probe.width = input.width;
    probe.height = input.height;
    copy_intrinsics9(attempt_intrinsics, probe.intrinsics);
    build_icp_source_camera_points(probe, metric_depth, depth_w, depth_h, attempt.source_points);
    if (attempt.source_points.size() < 48u) {
        return attempt;
    }

    aether_icp_config_t config{};
    config.max_iterations = 12;
    config.distance_threshold = 0.08f;
    config.normal_threshold_deg = 40.0f;
    config.huber_delta = 0.03f;
    config.convergence_translation = 0.0005f;
    config.convergence_rotation = 0.0020f;
    config.watchdog_max_diag_ratio = 12.0f;
    config.watchdog_max_residual_rise = 3;

    attempt.icp_ok = aether_icp_refine(
        attempt.source_points.data(),
        static_cast<int>(attempt.source_points.size()),
        target_points_world.data(),
        static_cast<int>(target_points_world.size()),
        target_normals_world.data(),
        initial_pose,
        0.0f,
        &config,
        &attempt.result);

    attempt.accepted =
        attempt.icp_ok != 0 &&
        !attempt.result.watchdog_tripped &&
        attempt.result.correspondence_count >= 48 &&
        std::isfinite(attempt.result.rmse);
    return attempt;
}

}  // namespace

capture::FrameSelectionConfig sanitize_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept {
    cfg.min_displacement_m = std::min(cfg.min_displacement_m, 0.003f);
    cfg.min_rotation_rad = std::min(cfg.min_rotation_rad, 0.026f);
    cfg.min_blur_score = std::min(cfg.min_blur_score, 0.01f);
    cfg.min_quality_score = std::min(cfg.min_quality_score, 0.01f);
    cfg.kf_translation_ratio = std::clamp(cfg.kf_translation_ratio, 0.04f, 0.08f);
    cfg.kf_min_translation_ratio = std::clamp(cfg.kf_min_translation_ratio, 0.02f, 0.05f);
    cfg.kf_overlap = std::clamp(cfg.kf_overlap, 0.85f, 0.95f);
    cfg.kf_cutoff = std::clamp(cfg.kf_cutoff, 0.25f, 0.40f);
    cfg.keyframe_window_size = std::clamp<std::size_t>(cfg.keyframe_window_size, 6u, 10u);
    cfg.protected_window_count = std::min(cfg.protected_window_count, cfg.keyframe_window_size);
    cfg.feature_cell_size_m = std::clamp(cfg.feature_cell_size_m, 0.02f, 0.06f);
    cfg.min_feature_overlap_points = std::clamp<std::uint32_t>(
        cfg.min_feature_overlap_points, 12u, 64u);
    return cfg;
}

capture::FrameSelectionConfig preview_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept {
    cfg = sanitize_frame_selection_config(cfg);
    cfg.min_displacement_m = std::max(cfg.min_displacement_m, 0.0010f);
    cfg.min_rotation_rad = std::max(cfg.min_rotation_rad, 0.004f);
    cfg.min_blur_score = std::max(cfg.min_blur_score, 0.005f);
    cfg.min_quality_score = std::max(cfg.min_quality_score, 0.005f);
    cfg.kf_translation_ratio = std::max(cfg.kf_translation_ratio, 0.012f);
    cfg.kf_min_translation_ratio = std::max(cfg.kf_min_translation_ratio, 0.005f);
    cfg.kf_overlap = std::min(cfg.kf_overlap, 0.995f);
    cfg.kf_cutoff = std::min(cfg.kf_cutoff, 0.25f);
    cfg.keyframe_window_size = std::min<std::size_t>(cfg.keyframe_window_size, 12u);
    cfg.protected_window_count = std::min<std::size_t>(cfg.protected_window_count, 3u);
    cfg.feature_cell_size_m = std::max(cfg.feature_cell_size_m, 0.04f);
    cfg.min_feature_overlap_points = std::clamp<std::uint32_t>(
        cfg.min_feature_overlap_points, 4u, 12u);
    return cfg;
}

void bootstrap_imported_video_intrinsics(std::uint32_t w,
                                         std::uint32_t h,
                                         float intrinsics[9]) noexcept {
    const float width = std::max(static_cast<float>(w), 1.0f);
    const float height = std::max(static_cast<float>(h), 1.0f);
    // Keep the fallback aligned with COLMAP's documented default when EXIF /
    // camera parameters are unavailable:
    //   default_focal_length_factor * max(width, height)
    // where default_focal_length_factor = 1.2.
    const float focal = std::max(width, height) * 1.2f;
    const float fx = focal;
    const float fy = focal;
    intrinsics[0] = fx;           intrinsics[1] = 0.0f;         intrinsics[2] = width * 0.5f;
    intrinsics[3] = 0.0f;         intrinsics[4] = fy;           intrinsics[5] = height * 0.5f;
    intrinsics[6] = 0.0f;         intrinsics[7] = 0.0f;         intrinsics[8] = 1.0f;
}

void update_imported_video_bootstrap_pose(
    FrameInput& input,
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool& pose_initialized,
    float pose[16],
    std::vector<aether_icp_point_t>& target_points_world,
    std::vector<aether_icp_point_t>& target_normals_world,
    bool& shared_intrinsics_initialized,
    float shared_intrinsics[9]) noexcept {
    if (input.imported_intrinsics_source != 1 && shared_intrinsics_initialized) {
        copy_intrinsics9(shared_intrinsics, input.intrinsics);
    }

    std::vector<aether_icp_point_t> source_points;
    build_icp_source_camera_points(input, metric_depth, depth_w, depth_h, source_points);

    if (!pose_initialized) {
        set_identity_pose(pose);
        std::memcpy(input.transform, pose, sizeof(float) * 16u);
        pose_initialized = true;
        build_icp_target_world_points(
            input,
            metric_depth,
            depth_w,
            depth_h,
            pose,
            target_points_world,
            target_normals_world);
        std::fprintf(
            stderr,
            "[Aether3D][PreviewICP] imported-video bootstrap init frame=%u pts=%zu target=%zu pose=identity\n",
            input.source_frame_index + 1u,
            source_points.size(),
            target_points_world.size());
        return;
    }

    std::memcpy(input.transform, pose, sizeof(float) * 16u);
    if (source_points.size() >= 48u &&
        target_points_world.size() >= 48u &&
        target_points_world.size() == target_normals_world.size()) {
        ImportedVideoICPAttempt best_attempt{};
        best_attempt.result.rmse = std::numeric_limits<float>::infinity();
        best_attempt.result.correspondence_count = -1;

        const bool allow_intrinsics_self_calibration =
            input.imported_intrinsics_source != 1 &&
            input.source_frame_index < 24u;
        const float* base_intrinsics =
            (allow_intrinsics_self_calibration && shared_intrinsics_initialized)
                ? shared_intrinsics
                : input.intrinsics;

        auto evaluate_attempt = [&](const float candidate_intrinsics[9]) {
            ImportedVideoICPAttempt attempt = run_imported_video_icp_attempt(
                input,
                candidate_intrinsics,
                metric_depth,
                depth_w,
                depth_h,
                target_points_world,
                target_normals_world,
                pose);
            if (attempt.source_points.empty() && attempt.result.correspondence_count == 0 &&
                !std::isfinite(attempt.result.rmse)) {
                return;
            }
            if (best_attempt.result.correspondence_count < 0 ||
                better_icp_attempt(attempt, best_attempt)) {
                best_attempt = std::move(attempt);
            }
        };

        evaluate_attempt(base_intrinsics);
        if (allow_intrinsics_self_calibration) {
            std::vector<float> focal_scales;
            if (shared_intrinsics_initialized) {
                focal_scales = {0.94f, 0.98f, 1.0f, 1.02f, 1.06f};
            } else if (input.imported_intrinsics_source == 2) {
                focal_scales = {0.82f, 0.90f, 0.96f, 1.0f, 1.04f, 1.10f, 1.18f};
            } else {
                focal_scales = {0.70f, 0.82f, 0.94f, 1.0f, 1.06f, 1.18f, 1.30f};
            }
            for (float scale : focal_scales) {
                if (std::abs(scale - 1.0f) <= 1e-3f) {
                    continue;
                }
                float candidate_intrinsics[9]{};
                scale_intrinsics_focal(base_intrinsics, scale, candidate_intrinsics);
                evaluate_attempt(candidate_intrinsics);
            }
        }

        if (best_attempt.result.correspondence_count >= 0) {
            copy_intrinsics9(best_attempt.intrinsics, input.intrinsics);
            source_points = best_attempt.source_points;
        }

        const int icp_ok = best_attempt.icp_ok;
        const aether_icp_result_t& result = best_attempt.result;
        const bool accept_pose = best_attempt.accepted;
        if (accept_pose) {
            if (allow_intrinsics_self_calibration) {
                const bool intrinsics_changed =
                    !shared_intrinsics_initialized ||
                    std::abs(shared_intrinsics[0] - best_attempt.intrinsics[0]) >
                        std::max(1.0f, 0.01f * best_attempt.intrinsics[0]);
                copy_intrinsics9(best_attempt.intrinsics, shared_intrinsics);
                shared_intrinsics_initialized = true;
                static std::uint32_t intrinsics_log_counter = 0;
                intrinsics_log_counter++;
                if (intrinsics_changed ||
                    intrinsics_log_counter <= 8 ||
                    intrinsics_log_counter % 16 == 0) {
                    const char* intrinsics_source_label =
                        input.imported_intrinsics_source == 2
                            ? "metadata_35mm"
                            : "colmap_default";
                    std::fprintf(
                        stderr,
                        "[Aether3D][PreviewIntrinsicsCalib] frame=%u source=%s fx=%.1f fy=%.1f corr=%d rmse=%.4f\n",
                        input.source_frame_index + 1u,
                        intrinsics_source_label,
                        best_attempt.intrinsics[0],
                        best_attempt.intrinsics[4],
                        result.correspondence_count,
                        result.rmse);
                }
            }
            std::memcpy(pose, result.pose_out, sizeof(float) * 16u);
            std::memcpy(input.transform, pose, sizeof(float) * 16u);
            build_icp_target_world_points(
                input,
                metric_depth,
                depth_w,
                depth_h,
                input.transform,
                target_points_world,
                target_normals_world);
        }

        static std::uint32_t icp_log_counter = 0;
        icp_log_counter++;
        if (icp_log_counter <= 12 || icp_log_counter % 24 == 0) {
            std::fprintf(
                stderr,
                "[Aether3D][PreviewICP] frame=%u ok=%d accepted=%d corr=%d rmse=%.4f converged=%d watchdog=%d src=%zu tgt=%zu\n",
                input.source_frame_index + 1u,
                icp_ok,
                accept_pose ? 1 : 0,
                result.correspondence_count,
                result.rmse,
                result.converged,
                result.watchdog_tripped,
                source_points.size(),
                target_points_world.size());
        }
        return;
    }

    build_icp_target_world_points(
        input,
        metric_depth,
        depth_w,
        depth_h,
        input.transform,
        target_points_world,
        target_normals_world);
}

void extract_camera_pose_metrics(
    const float* transform,
    float out_pos[3],
    float out_fwd[3]) noexcept {
    out_pos[0] = transform[12];
    out_pos[1] = transform[13];
    out_pos[2] = transform[14];
    // ARKit column 2 stores back (= -forward); negate it to recover forward.
    out_fwd[0] = -transform[8];
    out_fwd[1] = -transform[9];
    out_fwd[2] = -transform[10];
    normalize3(out_fwd[0], out_fwd[1], out_fwd[2]);
}

bool should_submit_preview_depth_prior(
    bool has_cached_depth,
    std::uint32_t frames_since_last_submit,
    bool has_last_request,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept {
    if (!has_cached_depth || !has_last_request) {
        return true;
    }

    constexpr std::uint32_t kPreviewDepthMaxCadence = 1;
    constexpr float kPreviewDepthMotionM = 0.003f;
    constexpr float kPreviewDepthMotionRad = 0.010f;

    if (frames_since_last_submit >= kPreviewDepthMaxCadence) {
        return true;
    }

    const float translation_m = translation_distance_m(current_pos, last_pos);
    const float rotation_rad = angular_distance_rad(current_fwd, last_fwd);
    return translation_m >= kPreviewDepthMotionM || rotation_rad >= kPreviewDepthMotionRad;
}

bool should_accept_preview_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept {
    if (!has_depth_prior) {
        return false;
    }
    if (!has_last_selected) {
        return true;
    }

    constexpr float kPreviewKeyframeMinMotionM = 0.008f;
    constexpr float kPreviewKeyframeMinMotionRad = 0.020f;
    constexpr float kPreviewMaxOverlap = 0.94f;

    const float translation_m = translation_distance_m(current_pos, last_pos);
    const float rotation_rad = angular_distance_rad(current_fwd, last_fwd);
    if (translation_m >= kPreviewKeyframeMinMotionM ||
        rotation_rad >= kPreviewKeyframeMinMotionRad) {
        return true;
    }

    return sel_result.overlap_ratio <= kPreviewMaxOverlap;
}

ImportedPreviewKeyframeDecision decide_imported_preview_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept {
    ImportedPreviewKeyframeDecision decision{};
    if (!has_depth_prior) {
        decision.low_parallax = true;
        return decision;
    }
    if (!has_last_selected) {
        decision.accept = true;
        return decision;
    }

    constexpr float kImportedOrbitMotionM = 0.010f;
    constexpr float kImportedOrbitMotionRad = 0.045f;
    constexpr float kImportedStrongMotionM = 0.016f;
    constexpr float kImportedStrongMotionRad = 0.070f;
    constexpr float kImportedGoodOverlap = 0.84f;
    constexpr float kImportedDuplicateOverlap = 0.93f;

    const float translation_m = translation_distance_m(current_pos, last_pos);
    const float rotation_rad = angular_distance_rad(current_fwd, last_fwd);

    decision.low_parallax =
        translation_m < kImportedOrbitMotionM &&
        rotation_rad < kImportedOrbitMotionRad;
    decision.near_duplicate =
        decision.low_parallax &&
        sel_result.overlap_ratio >= kImportedDuplicateOverlap;

    if (translation_m >= kImportedStrongMotionM ||
        rotation_rad >= kImportedStrongMotionRad) {
        decision.accept = true;
        return decision;
    }

    if ((translation_m >= kImportedOrbitMotionM ||
         rotation_rad >= kImportedOrbitMotionRad) &&
        sel_result.overlap_ratio <= kImportedGoodOverlap) {
        decision.accept = true;
    }
    return decision;
}

PreviewPrefilterDecision evaluate_preview_import_prefilter(
    float brightness,
    float blur,
    float low_light_brightness_threshold,
    float min_blur_score,
    float low_light_blur_strictness) noexcept {
    const float effective_blur = brightness < low_light_brightness_threshold
        ? (blur / std::max(low_light_blur_strictness, 1e-3f))
        : blur;
    if (brightness < low_light_brightness_threshold &&
        effective_blur < min_blur_score * 0.5f) {
        return PreviewPrefilterDecision::kRejectLowBrightness;
    }
    if (effective_blur < min_blur_score) {
        return PreviewPrefilterDecision::kRejectBlur;
    }
    return PreviewPrefilterDecision::kAccept;
}

}  // namespace local_preview_runtime
}  // namespace pipeline
}  // namespace aether
