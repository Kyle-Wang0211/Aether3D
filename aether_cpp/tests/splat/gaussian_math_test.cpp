// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/gaussian_math.h"

#include <cmath>
#include <cstdio>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

static bool near(float a, float b, float eps = 1e-5f) {
    return std::fabs(a - b) <= eps;
}

using namespace aether::splat;

// ---------------------------------------------------------------------------
// quaternion_to_rotation_matrix
// ---------------------------------------------------------------------------

static void test_identity_quaternion() {
    // Identity quaternion → identity matrix
    float q[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    float R[9];
    quaternion_to_rotation_matrix(q, R);

    CHECK(near(R[0], 1.0f)); CHECK(near(R[1], 0.0f)); CHECK(near(R[2], 0.0f));
    CHECK(near(R[3], 0.0f)); CHECK(near(R[4], 1.0f)); CHECK(near(R[5], 0.0f));
    CHECK(near(R[6], 0.0f)); CHECK(near(R[7], 0.0f)); CHECK(near(R[8], 1.0f));
}

static void test_90deg_z_rotation() {
    // 90° around Z: q = (cos(45°), 0, 0, sin(45°))
    float c = std::cos(0.7853981f);
    float s = std::sin(0.7853981f);
    float q[4] = {c, 0.0f, 0.0f, s};
    float R[9];
    quaternion_to_rotation_matrix(q, R);

    // Expected: [[0,-1,0], [1,0,0], [0,0,1]]
    CHECK(near(R[0],  0.0f, 1e-4f));
    CHECK(near(R[1], -1.0f, 1e-4f));
    CHECK(near(R[2],  0.0f, 1e-4f));
    CHECK(near(R[3],  1.0f, 1e-4f));
    CHECK(near(R[4],  0.0f, 1e-4f));
    CHECK(near(R[5],  0.0f, 1e-4f));
    CHECK(near(R[6],  0.0f, 1e-4f));
    CHECK(near(R[7],  0.0f, 1e-4f));
    CHECK(near(R[8],  1.0f, 1e-4f));
}

static void test_rotation_matrix_orthogonality() {
    // Arbitrary quaternion → R should be orthogonal (R^T R = I)
    float q[4] = {0.5f, 0.5f, 0.5f, 0.5f};
    float R[9];
    quaternion_to_rotation_matrix(q, R);

    // Check R^T * R ≈ I (row i dot row j = delta_ij)
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            float dot = 0.0f;
            for (int k = 0; k < 3; ++k) {
                dot += R[k * 3 + i] * R[k * 3 + j];  // column i dot column j
            }
            float expected = (i == j) ? 1.0f : 0.0f;
            CHECK(near(dot, expected, 1e-4f));
        }
    }
}

static void test_rotation_matrix_determinant() {
    // det(R) should be +1 for a proper rotation
    float q[4] = {0.36f, 0.48f, 0.6f, 0.52f};
    // Normalize
    float len = std::sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
    for (int i = 0; i < 4; ++i) q[i] /= len;

    float R[9];
    quaternion_to_rotation_matrix(q, R);

    float det = R[0] * (R[4] * R[8] - R[5] * R[7])
              - R[1] * (R[3] * R[8] - R[5] * R[6])
              + R[2] * (R[3] * R[7] - R[4] * R[6]);
    CHECK(near(det, 1.0f, 1e-4f));
}

// ---------------------------------------------------------------------------
// compute_3d_covariance
// ---------------------------------------------------------------------------

static void test_covariance_identity_rotation() {
    // Identity rotation + scale → Sigma = diag(sx^2, sy^2, sz^2)
    float R[9] = {1,0,0, 0,1,0, 0,0,1};
    float scale[3] = {2.0f, 3.0f, 4.0f};
    float cov[6];
    compute_3d_covariance(R, scale, cov);

    CHECK(near(cov[0], 4.0f));   // sx^2
    CHECK(near(cov[1], 0.0f));   // off-diagonal
    CHECK(near(cov[2], 0.0f));
    CHECK(near(cov[3], 9.0f));   // sy^2
    CHECK(near(cov[4], 0.0f));
    CHECK(near(cov[5], 16.0f));  // sz^2
}

static void test_covariance_symmetric() {
    // The upper triangle should be consistent with a symmetric matrix
    float q[4] = {0.5f, 0.5f, 0.5f, 0.5f};
    float R[9];
    quaternion_to_rotation_matrix(q, R);

    float scale[3] = {0.1f, 0.2f, 0.3f};
    float cov[6];
    compute_3d_covariance(R, scale, cov);

    // cov = [Sigma00, Sigma01, Sigma02, Sigma11, Sigma12, Sigma22]
    // All values should be finite
    for (int i = 0; i < 6; ++i) {
        CHECK(std::isfinite(cov[i]));
    }

    // Diagonal elements must be non-negative (variance)
    CHECK(cov[0] >= 0.0f);
    CHECK(cov[3] >= 0.0f);
    CHECK(cov[5] >= 0.0f);
}

static void test_covariance_uniform_scale() {
    // Uniform scale + any rotation → Sigma = s^2 * I
    float q[4] = {0.5f, 0.5f, 0.5f, 0.5f};
    float R[9];
    quaternion_to_rotation_matrix(q, R);

    float s = 0.5f;
    float scale[3] = {s, s, s};
    float cov[6];
    compute_3d_covariance(R, scale, cov);

    float expected = s * s;
    CHECK(near(cov[0], expected, 1e-4f));
    CHECK(near(cov[1], 0.0f, 1e-4f));
    CHECK(near(cov[2], 0.0f, 1e-4f));
    CHECK(near(cov[3], expected, 1e-4f));
    CHECK(near(cov[4], 0.0f, 1e-4f));
    CHECK(near(cov[5], expected, 1e-4f));
}

// ---------------------------------------------------------------------------
// eigendecompose_2x2
// ---------------------------------------------------------------------------

static void test_eigendecompose_diagonal() {
    // [[4, 0], [0, 1]] → eigenvalues 4, 1
    float major, minor, cos_t, sin_t;
    eigendecompose_2x2(4.0f, 0.0f, 1.0f, major, minor, cos_t, sin_t);

    CHECK(near(major, 2.0f, 1e-4f));  // sqrt(4)
    CHECK(near(minor, 1.0f, 1e-4f));  // sqrt(1)
}

static void test_eigendecompose_equal() {
    // [[3, 0], [0, 3]] → both eigenvalues = 3
    float major, minor, cos_t, sin_t;
    eigendecompose_2x2(3.0f, 0.0f, 3.0f, major, minor, cos_t, sin_t);

    CHECK(near(major, std::sqrt(3.0f), 1e-4f));
    CHECK(near(minor, std::sqrt(3.0f), 1e-4f));
}

static void test_eigendecompose_offdiagonal() {
    // [[2, 1], [1, 2]] → eigenvalues 3 and 1
    float major, minor, cos_t, sin_t;
    eigendecompose_2x2(2.0f, 1.0f, 2.0f, major, minor, cos_t, sin_t);

    CHECK(near(major, std::sqrt(3.0f), 1e-4f));
    CHECK(near(minor, 1.0f, 1e-4f));
}

static void test_eigendecompose_axes_positive() {
    // Axes must always be positive
    float major, minor, cos_t, sin_t;
    eigendecompose_2x2(0.01f, 0.0f, 0.01f, major, minor, cos_t, sin_t);
    CHECK(major > 0.0f);
    CHECK(minor > 0.0f);
}

// ---------------------------------------------------------------------------
// evaluate_gaussian_alpha
// ---------------------------------------------------------------------------

static void test_alpha_at_center() {
    // At the center (dx=0, dy=0), exponent = 0 → alpha = opacity * 1.0
    float cov[3] = {1.0f, 0.0f, 1.0f};  // [[1,0],[0,1]]
    float alpha = evaluate_gaussian_alpha(0.0f, 0.0f, cov, 0.8f);
    CHECK(near(alpha, 0.8f, 0.01f));
}

static void test_alpha_far_away() {
    // Far from center → alpha ≈ 0 (beyond 3-sigma cutoff)
    float cov[3] = {1.0f, 0.0f, 1.0f};
    float alpha = evaluate_gaussian_alpha(10.0f, 10.0f, cov, 1.0f);
    CHECK(alpha == 0.0f);
}

static void test_alpha_degenerate_covariance() {
    // Zero determinant → alpha = 0
    float cov[3] = {0.0f, 0.0f, 0.0f};
    float alpha = evaluate_gaussian_alpha(0.0f, 0.0f, cov, 1.0f);
    CHECK(alpha == 0.0f);
}

static void test_alpha_monotone_decay() {
    // Alpha should decrease with distance from center
    float cov[3] = {4.0f, 0.0f, 4.0f};
    float a0 = evaluate_gaussian_alpha(0.0f, 0.0f, cov, 1.0f);
    float a1 = evaluate_gaussian_alpha(1.0f, 0.0f, cov, 1.0f);
    float a2 = evaluate_gaussian_alpha(2.0f, 0.0f, cov, 1.0f);
    CHECK(a0 > a1);
    CHECK(a1 > a2);
    CHECK(a0 > 0.0f);
}

// ---------------------------------------------------------------------------
// project_gaussian_ewa
// ---------------------------------------------------------------------------

static void test_ewa_behind_camera() {
    // Point behind camera (tz <= 0.2) → return false
    float pos[3] = {0.0f, 0.0f, -1.0f};  // behind camera
    float cov3d[6] = {1,0,0, 1,0, 1};
    // Identity view matrix (column-major)
    float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    };
    CameraIntrinsics intr{500.0f, 500.0f, 320.0f, 240.0f};
    ProjectedGaussian2D out{};

    bool ok = project_gaussian_ewa(pos, cov3d, 1.0f, view, intr, 640, 480, out);
    CHECK(!ok);
}

static void test_ewa_center_point() {
    // Point at (0,0,2) with identity view → should project to principal point
    float pos[3] = {0.0f, 0.0f, 2.0f};
    float cov3d[6] = {0.01f, 0.0f, 0.0f, 0.01f, 0.0f, 0.01f};
    float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    };
    CameraIntrinsics intr{500.0f, 500.0f, 320.0f, 240.0f};
    ProjectedGaussian2D out{};

    bool ok = project_gaussian_ewa(pos, cov3d, 0.9f, view, intr, 640, 480, out);
    CHECK(ok);

    // Screen center should be at principal point (cx, cy)
    CHECK(near(out.center_x, 320.0f, 1.0f));
    CHECK(near(out.center_y, 240.0f, 1.0f));
    CHECK(near(out.depth, 2.0f, 0.01f));
    CHECK(near(out.opacity, 0.9f, 0.01f));
}

static void test_ewa_offcenter_point() {
    // Point at (1, 0, 5) → projects to (fx * 1/5 + cx, cy)
    float pos[3] = {1.0f, 0.0f, 5.0f};
    float cov3d[6] = {0.01f, 0.0f, 0.0f, 0.01f, 0.0f, 0.01f};
    float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    };
    CameraIntrinsics intr{500.0f, 500.0f, 320.0f, 240.0f};
    ProjectedGaussian2D out{};

    bool ok = project_gaussian_ewa(pos, cov3d, 1.0f, view, intr, 640, 480, out);
    CHECK(ok);

    float expected_x = 500.0f * (1.0f / 5.0f) + 320.0f;  // 420
    CHECK(near(out.center_x, expected_x, 1.0f));
    CHECK(near(out.center_y, 240.0f, 1.0f));
}

static void test_ewa_frustum_cull() {
    // Point far off screen → should be culled
    float pos[3] = {100.0f, 0.0f, 1.0f};  // Way off to the right
    float cov3d[6] = {0.001f, 0.0f, 0.0f, 0.001f, 0.0f, 0.001f};
    float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    };
    CameraIntrinsics intr{500.0f, 500.0f, 320.0f, 240.0f};
    ProjectedGaussian2D out{};

    bool ok = project_gaussian_ewa(pos, cov3d, 1.0f, view, intr, 640, 480, out);
    CHECK(!ok);  // Should be frustum-culled
}

// ---------------------------------------------------------------------------
// compute_projected_gaussian (full pipeline convenience)
// ---------------------------------------------------------------------------

static void test_full_pipeline() {
    GaussianParams params{};
    params.position[0] = 0.0f;
    params.position[1] = 0.0f;
    params.position[2] = 3.0f;
    params.color[0] = params.color[1] = params.color[2] = 0.5f;
    params.opacity = 0.8f;
    params.scale[0] = params.scale[1] = params.scale[2] = 0.1f;
    params.rotation[0] = 1.0f;  // identity
    params.rotation[1] = params.rotation[2] = params.rotation[3] = 0.0f;

    float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    };
    CameraIntrinsics intr{500.0f, 500.0f, 320.0f, 240.0f};
    ProjectedGaussian2D out{};

    bool ok = compute_projected_gaussian(params, view, intr, 640, 480, out);
    CHECK(ok);
    CHECK(near(out.center_x, 320.0f, 1.0f));
    CHECK(near(out.center_y, 240.0f, 1.0f));
    CHECK(near(out.depth, 3.0f, 0.01f));
    CHECK(out.axis_major > 0.0f);
    CHECK(out.axis_minor > 0.0f);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    test_identity_quaternion();
    test_90deg_z_rotation();
    test_rotation_matrix_orthogonality();
    test_rotation_matrix_determinant();

    test_covariance_identity_rotation();
    test_covariance_symmetric();
    test_covariance_uniform_scale();

    test_eigendecompose_diagonal();
    test_eigendecompose_equal();
    test_eigendecompose_offdiagonal();
    test_eigendecompose_axes_positive();

    test_alpha_at_center();
    test_alpha_far_away();
    test_alpha_degenerate_covariance();
    test_alpha_monotone_decay();

    test_ewa_behind_camera();
    test_ewa_center_point();
    test_ewa_offcenter_point();
    test_ewa_frustum_cull();

    test_full_pipeline();

    if (g_failed == 0) {
        std::fprintf(stdout, "gaussian_math_test: all tests passed\n");
    }
    return g_failed;
}
