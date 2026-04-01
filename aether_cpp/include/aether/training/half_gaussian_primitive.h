// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// half_gaussian_primitive.h — Half-Gaussian splatting primitive (3D-HGS, CVPR 2025).
// Truncates the Gaussian along the surface normal direction,
// eliminating back-face bleed that causes ghosting artifacts.
// Drop-in improvement for all 3DGS methods.
// Reference: "3D Half-Gaussian Splatting" — CVPR 2025

#ifndef AETHER_TRAINING_HALF_GAUSSIAN_PRIMITIVE_H
#define AETHER_TRAINING_HALF_GAUSSIAN_PRIMITIVE_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Half-Gaussian Primitive: 14 parameters (same as standard Gaussian)
// ═══════════════════════════════════════════════════════════════════════
// Uses the SAME parameter count as Gaussian (no new learnable params).
// The surface normal is the eigenvector corresponding to the
// smallest eigenvalue of the 3D covariance matrix (thinnest axis).
// Primitives are truncated on one side of this normal plane.
//
// alpha = opacity × exp(power) × half_mask × 2.0
// where half_mask = (dot(offset, normal) >= 0) ? 1 : 0
// and ×2 compensates for the halved area.

/// Compute the surface normal from the covariance matrix.
/// The normal is the eigenvector of the smallest eigenvalue.
/// @param scale    Scale values [sx, sy, sz] (natural space, not log)
/// @param rot_quat Quaternion [w, x, y, z]
/// @param out_normal Output normal vector [nx, ny, nz] (normalized)
inline void half_gaussian_normal(const float scale[3],
                                  const float rot_quat[4],
                                  float out_normal[3]) noexcept {
    // Find the axis with the smallest scale (thinnest direction)
    int min_axis = 0;
    if (scale[1] < scale[min_axis]) min_axis = 1;
    if (scale[2] < scale[min_axis]) min_axis = 2;

    // The normal is the rotation of the unit vector along min_axis.
    // Quaternion rotation: v' = q * v * q^(-1)
    // For unit vectors along axis, this simplifies to extracting the
    // corresponding column of the rotation matrix.
    float w = rot_quat[0], x = rot_quat[1], y = rot_quat[2], z = rot_quat[3];

    // Rotation matrix columns from quaternion (column-major):
    // Column 0: [1-2(y²+z²), 2(xy+wz), 2(xz-wy)]
    // Column 1: [2(xy-wz), 1-2(x²+z²), 2(yz+wx)]
    // Column 2: [2(xz+wy), 2(yz-wx), 1-2(x²+y²)]
    if (min_axis == 0) {
        out_normal[0] = 1.0f - 2.0f * (y*y + z*z);
        out_normal[1] = 2.0f * (x*y + w*z);
        out_normal[2] = 2.0f * (x*z - w*y);
    } else if (min_axis == 1) {
        out_normal[0] = 2.0f * (x*y - w*z);
        out_normal[1] = 1.0f - 2.0f * (x*x + z*z);
        out_normal[2] = 2.0f * (y*z + w*x);
    } else {
        out_normal[0] = 2.0f * (x*z + w*y);
        out_normal[1] = 2.0f * (y*z - w*x);
        out_normal[2] = 1.0f - 2.0f * (x*x + y*y);
    }

    // Normalize (should already be unit if quaternion is normalized)
    float len = std::sqrt(out_normal[0]*out_normal[0] +
                          out_normal[1]*out_normal[1] +
                          out_normal[2]*out_normal[2]);
    if (len > 1e-6f) {
        out_normal[0] /= len;
        out_normal[1] /= len;
        out_normal[2] /= len;
    }
}

/// Compute Half-Gaussian alpha.
/// @param power     Mahalanobis distance (negative)
/// @param opacity   Base opacity
/// @param offset_3d Offset from Gaussian center to sample point (world space)
/// @param normal    Surface normal (from half_gaussian_normal)
/// @return Alpha value with half-space masking, ×2 area compensation
inline float half_gaussian_alpha(float power, float opacity,
                                  const float offset_3d[3],
                                  const float normal[3]) noexcept {
    if (power > 0.0f || power < -100.0f) return 0.0f;

    // Half-space mask: only render on the "front" side
    float dot = offset_3d[0]*normal[0] + offset_3d[1]*normal[1] + offset_3d[2]*normal[2];
    if (dot < 0.0f) return 0.0f;  // Behind the surface plane

    // Standard Gaussian × 2 (area compensation for truncation)
    float alpha = opacity * std::exp(power) * 2.0f;
    return std::clamp(alpha, 0.0f, 0.99f);
}

/// Gradient of half-Gaussian alpha w.r.t. power (same as Gaussian × 2).
/// Only non-zero on the front side of the half-space.
inline float half_gaussian_dalpha_dpower(float power, float opacity,
                                          float dot_offset_normal) noexcept {
    if (power > 0.0f || power < -100.0f) return 0.0f;
    if (dot_offset_normal < 0.0f) return 0.0f;  // Masked out

    return opacity * std::exp(power) * 2.0f;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_HALF_GAUSSIAN_PRIMITIVE_H
