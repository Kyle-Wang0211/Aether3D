// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_GAUSSIAN_MATH_H
#define AETHER_CPP_SPLAT_GAUSSIAN_MATH_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "aether/splat/packed_splats.h"

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// Gaussian Math: Core 3DGS mathematical operations
// ═══════════════════════════════════════════════════════════════════════
// Algorithm source: gsplat.js (Hugging Face, MIT)
//   - wasm/data.cpp: quaternion_to_rotation_matrix, compute_3d_covariance
//   - RenderProgram.ts: EWA projection, eigendecomposition
//
// All functions are header-only for inlining on GPU-adjacent hot paths.

// ─── 2D Projected Gaussian (output of EWA projection) ──────────────

struct ProjectedGaussian2D {
    float center_x;          // screen-space center x
    float center_y;          // screen-space center y
    float depth;             // view-space depth (for sorting)
    float cov2d[3];          // 2D covariance upper triangle: [a, b, c]
                             // [[a, b], [b, c]]
    float axis_major;        // major axis length (sqrt of eigenvalue)
    float axis_minor;        // minor axis length (sqrt of eigenvalue)
    float cos_theta;         // rotation cos
    float sin_theta;         // rotation sin
    float opacity;           // final opacity after sigmoid
};

// ─── Quaternion → Rotation Matrix ───────────────────────────────────
// Source: gsplat.js wasm/data.cpp computeRotationMatrix()

/// Convert unit quaternion (w,x,y,z) to 3x3 rotation matrix.
/// Output R[9] is row-major: R[row*3 + col].
inline void quaternion_to_rotation_matrix(const float q[4],
                                           float R[9]) noexcept {
    float w = q[0], x = q[1], y = q[2], z = q[3];

    // Pre-compute products
    float xx = x * x, yy = y * y, zz = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;

    // Row-major 3x3
    R[0] = 1.0f - 2.0f * (yy + zz);
    R[1] = 2.0f * (xy - wz);
    R[2] = 2.0f * (xz + wy);

    R[3] = 2.0f * (xy + wz);
    R[4] = 1.0f - 2.0f * (xx + zz);
    R[5] = 2.0f * (yz - wx);

    R[6] = 2.0f * (xz - wy);
    R[7] = 2.0f * (yz + wx);
    R[8] = 1.0f - 2.0f * (xx + yy);
}

// ─── 3D Covariance from Rotation + Scale ────────────────────────────
// Source: gsplat.js wasm/data.cpp computeCov3D()
// Sigma = R * S * S^T * R^T = (R*S) * (R*S)^T
// where S = diag(scale_x, scale_y, scale_z)

/// Compute upper-triangle of 3D covariance matrix.
/// Output cov6[6] = [Sigma_00, Sigma_01, Sigma_02, Sigma_11, Sigma_12, Sigma_22].
inline void compute_3d_covariance(const float R[9],
                                   const float scale[3],
                                   float cov6[6]) noexcept {
    // M = R * S (scale columns of R)
    float m00 = R[0] * scale[0], m01 = R[1] * scale[1], m02 = R[2] * scale[2];
    float m10 = R[3] * scale[0], m11 = R[4] * scale[1], m12 = R[5] * scale[2];
    float m20 = R[6] * scale[0], m21 = R[7] * scale[1], m22 = R[8] * scale[2];

    // Sigma = M * M^T (symmetric, store upper triangle)
    cov6[0] = m00 * m00 + m01 * m01 + m02 * m02;   // [0,0]
    cov6[1] = m00 * m10 + m01 * m11 + m02 * m12;   // [0,1]
    cov6[2] = m00 * m20 + m01 * m21 + m02 * m22;   // [0,2]
    cov6[3] = m10 * m10 + m11 * m11 + m12 * m12;   // [1,1]
    cov6[4] = m10 * m20 + m11 * m21 + m12 * m22;   // [1,2]
    cov6[5] = m20 * m20 + m21 * m21 + m22 * m22;   // [2,2]
}

/// Pack upper-triangle covariance to float16.
inline void pack_covariance_half(const float cov6[6],
                                  std::uint16_t out_half[6]) noexcept {
    for (int i = 0; i < 6; ++i) {
        out_half[i] = float_to_half(cov6[i]);
    }
}

// ─── 2x2 Eigendecomposition (Closed-Form) ───────────────────────────
// Source: gsplat.js RenderProgram.ts
// For symmetric 2x2 matrix [[a, b], [b, c]]:
//   eigenvalues = ((a+c) ± sqrt((a-c)^2 + 4b^2)) / 2

/// Eigendecompose a 2x2 symmetric matrix [[a, b], [b, c]].
/// Outputs major/minor axis lengths (sqrt of eigenvalues) and rotation.
inline void eigendecompose_2x2(float a, float b, float c,
                                float& axis_major, float& axis_minor,
                                float& cos_theta, float& sin_theta) noexcept {
    float trace = a + c;
    float diff = a - c;
    // Bug 0.19 fix: use double precision for discriminant to prevent float32 overflow
    // when (a-c) is very large. diff*diff alone can overflow at ~1.8e19.
    double ddiff = static_cast<double>(diff);
    double db = static_cast<double>(b);
    float discriminant = static_cast<float>(std::sqrt(ddiff * ddiff + 4.0 * db * db));

    float lambda1 = 0.5f * (trace + discriminant);
    float lambda2 = 0.5f * (trace - discriminant);

    // Clamp eigenvalues to avoid negative sqrt
    if (lambda1 < 1e-6f) lambda1 = 1e-6f;
    if (lambda2 < 1e-6f) lambda2 = 1e-6f;

    axis_major = std::sqrt(lambda1);
    axis_minor = std::sqrt(lambda2);

    // Eigenvector direction
    if (std::fabs(b) < 1e-8f) {
        cos_theta = 1.0f;
        sin_theta = 0.0f;
    } else {
        float v = lambda1 - a;
        float len = std::sqrt(b * b + v * v);
        // Bug 0.30 fix: protect eigenvector division when len is near zero
        if (len < 1e-8f) {
            cos_theta = 1.0f;
            sin_theta = 0.0f;
        } else {
            cos_theta = b / len;
            sin_theta = v / len;
        }
    }
}

// ─── EWA Projection: 3D Covariance → 2D Screen Covariance ──────────
// Source: gsplat.js RenderProgram.ts vertex shader
//
// Given a 3D Gaussian with covariance Sigma3D at world position p,
// camera view matrix V, and projection parameters:
//   J = Jacobian of perspective projection at p
//   T = J * W (W = upper-left 3x3 of view matrix)
//   Sigma2D = T^T * Sigma3D * T  (but we compute T * Sigma3D * T^T after
//             transposing the convention to match gsplat.js)
//
// We follow the EWA splatting formulation from Zwicker et al. 2001.

struct CameraIntrinsics {
    float fx;    // focal length x (pixels)
    float fy;    // focal length y (pixels)
    float cx;    // principal point x
    float cy;    // principal point y
};

/// Project a 3D Gaussian to 2D screen space via EWA splatting.
///
/// Parameters:
///   position[3]  — world-space position of the Gaussian
///   cov3d[6]     — upper triangle of 3D covariance
///   opacity      — base opacity [0,1]
///   view[16]     — column-major 4x4 view matrix (world → camera)
///   intrinsics   — camera intrinsic parameters
///   vp_width     — viewport width in pixels
///   vp_height    — viewport height in pixels
///   out          — output projected Gaussian
///
/// Returns false if the Gaussian is behind the camera or degenerate.
inline bool project_gaussian_ewa(
    const float position[3],
    const float cov3d[6],
    float opacity,
    const float view[16],
    const CameraIntrinsics& intrinsics,
    std::uint32_t vp_width,
    std::uint32_t vp_height,
    ProjectedGaussian2D& out) noexcept
{
    // Transform position to camera space (column-major view matrix)
    float tx = view[0] * position[0] + view[4] * position[1] +
               view[8] * position[2] + view[12];
    float ty = view[1] * position[0] + view[5] * position[1] +
               view[9] * position[2] + view[13];
    float tz = view[2] * position[0] + view[6] * position[1] +
               view[10] * position[2] + view[14];

    // Near-plane cull
    if (tz <= 0.2f) return false;

    float inv_tz = 1.0f / tz;
    float inv_tz2 = inv_tz * inv_tz;

    // Screen-space center
    out.center_x = intrinsics.fx * tx * inv_tz + intrinsics.cx;
    out.center_y = intrinsics.fy * ty * inv_tz + intrinsics.cy;
    out.depth = tz;

    // Jacobian of perspective projection
    // J = | fx/tz   0     -fx*tx/tz^2 |
    //     | 0       fy/tz -fy*ty/tz^2 |
    float j00 = intrinsics.fx * inv_tz;
    float j02 = -intrinsics.fx * tx * inv_tz2;
    float j11 = intrinsics.fy * inv_tz;
    float j12 = -intrinsics.fy * ty * inv_tz2;

    // W = upper-left 3x3 of view matrix (column-major extraction)
    float w00 = view[0], w01 = view[4], w02 = view[8];
    float w10 = view[1], w11 = view[5], w12 = view[9];
    float w20 = view[2], w21 = view[6], w22 = view[10];

    // T = J * W  (2x3 matrix)
    float t00 = j00 * w00 + j02 * w20;
    float t01 = j00 * w01 + j02 * w21;
    float t02 = j00 * w02 + j02 * w22;
    float t10 = j11 * w10 + j12 * w20;
    float t11 = j11 * w11 + j12 * w21;
    float t12 = j11 * w12 + j12 * w22;

    // Sigma2D = T * Sigma3D * T^T
    // Expand: cov3d = [s00, s01, s02, s11, s12, s22]
    float s00 = cov3d[0], s01 = cov3d[1], s02 = cov3d[2];
    float s11 = cov3d[3], s12 = cov3d[4], s22 = cov3d[5];

    // Intermediate: M = T * Sigma3D (2x3)
    float m00 = t00 * s00 + t01 * s01 + t02 * s02;
    float m01 = t00 * s01 + t01 * s11 + t02 * s12;
    float m02 = t00 * s02 + t01 * s12 + t02 * s22;
    float m10 = t10 * s00 + t11 * s01 + t12 * s02;
    float m11 = t10 * s01 + t11 * s11 + t12 * s12;
    float m12 = t10 * s02 + t11 * s12 + t12 * s22;

    // Sigma2D = M * T^T (2x2 symmetric)
    float c00 = m00 * t00 + m01 * t01 + m02 * t02;
    float c01 = m00 * t10 + m01 * t11 + m02 * t12;
    float c11 = m10 * t10 + m11 * t11 + m12 * t12;

    // Low-pass filter (anti-aliasing): add 0.3 pixel variance
    c00 += 0.3f;
    c11 += 0.3f;

    out.cov2d[0] = c00;
    out.cov2d[1] = c01;
    out.cov2d[2] = c11;

    // Eigendecompose 2x2 for ellipse axes
    eigendecompose_2x2(c00, c01, c11,
                       out.axis_major, out.axis_minor,
                       out.cos_theta, out.sin_theta);

    out.opacity = opacity;

    // Frustum cull: reject if center is far outside viewport
    float radius = 3.0f * out.axis_major;  // 3-sigma
    if (out.center_x + radius < 0.0f ||
        out.center_x - radius > static_cast<float>(vp_width) ||
        out.center_y + radius < 0.0f ||
        out.center_y - radius > static_cast<float>(vp_height)) {
        return false;
    }

    return true;
}

// ─── Gaussian Alpha Evaluation ──────────────────────────────────────
// Fragment shader math: evaluate the Gaussian at a pixel offset.

/// Evaluate Gaussian alpha at pixel offset (dx, dy) from center.
/// Uses the inverse of the 2D covariance to compute the exponent.
/// cov2d = [a, b, c] for [[a, b], [b, c]].
inline float evaluate_gaussian_alpha(float dx, float dy,
                                      const float cov2d[3],
                                      float opacity) noexcept {
    float a = cov2d[0], b = cov2d[1], c = cov2d[2];
    float det = a * c - b * b;
    // Bug 0.20 fix: use 1e-6f instead of 0.0f to prevent inv_det explosion
    // at tiny positive determinants.
    if (det < 1e-6f) return 0.0f;

    float inv_det = 1.0f / det;
    // Mahalanobis distance squared: d^2 = [dx, dy] * Sigma^-1 * [dx, dy]^T
    float power = -0.5f * (c * dx * dx - 2.0f * b * dx * dy + a * dy * dy)
                  * inv_det;

    if (power > 0.0f) return 0.0f;  // Numerical safety
    // Bug 0.21 fix: clamp power to prevent exp underflow at extreme values.
    // -100 corresponds to ~exp(-100) ≈ 3.7e-44 which is negligible.
    power = std::max(power, -100.0f);
    if (power < -4.0f) return 0.0f; // Beyond 3-sigma cutoff

    return opacity * std::exp(power);
}

// ─── Utility: Compute Full Pipeline (Params → Projected) ────────────

/// Compute projected 2D Gaussian from full GaussianParams.
/// Convenience function chaining: rotation→covariance→EWA→eigendecompose.
inline bool compute_projected_gaussian(
    const GaussianParams& params,
    const float view[16],
    const CameraIntrinsics& intrinsics,
    std::uint32_t vp_width,
    std::uint32_t vp_height,
    ProjectedGaussian2D& out) noexcept
{
    // Step 1: Quaternion → rotation matrix
    float R[9];
    quaternion_to_rotation_matrix(params.rotation, R);

    // Step 2: R + scale → 3D covariance
    float cov3d[6];
    compute_3d_covariance(R, params.scale, cov3d);

    // Step 3: EWA projection
    return project_gaussian_ewa(
        params.position, cov3d, params.opacity,
        view, intrinsics, vp_width, vp_height, out);
}

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_GAUSSIAN_MATH_H
