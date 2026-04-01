// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/ply_loader.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

static bool near(float a, float b, float eps = 1e-4f) {
    return std::fabs(a - b) <= eps;
}

using namespace aether::splat;

// ---------------------------------------------------------------------------
// Helper: write a minimal ASCII PLY file for testing
// ---------------------------------------------------------------------------

static const char* kTempPlyAscii = "/tmp/aether_test_ascii.ply";
static const char* kTempPlyBinary = "/tmp/aether_test_binary.ply";
static const char* kTempPlyRoundtrip = "/tmp/aether_test_roundtrip.ply";

static bool write_test_ascii_ply(const char* path, int vertex_count) {
    std::FILE* f = std::fopen(path, "w");
    if (!f) return false;

    std::fprintf(f, "ply\n");
    std::fprintf(f, "format ascii 1.0\n");
    std::fprintf(f, "element vertex %d\n", vertex_count);
    std::fprintf(f, "property float x\n");
    std::fprintf(f, "property float y\n");
    std::fprintf(f, "property float z\n");
    std::fprintf(f, "property float f_dc_0\n");
    std::fprintf(f, "property float f_dc_1\n");
    std::fprintf(f, "property float f_dc_2\n");
    std::fprintf(f, "property float opacity\n");
    std::fprintf(f, "property float scale_0\n");
    std::fprintf(f, "property float scale_1\n");
    std::fprintf(f, "property float scale_2\n");
    std::fprintf(f, "property float rot_0\n");
    std::fprintf(f, "property float rot_1\n");
    std::fprintf(f, "property float rot_2\n");
    std::fprintf(f, "property float rot_3\n");
    std::fprintf(f, "end_header\n");

    for (int i = 0; i < vertex_count; ++i) {
        float fi = static_cast<float>(i);
        // x, y, z
        std::fprintf(f, "%f %f %f ", fi * 0.1f, fi * 0.2f, fi * 0.3f);
        // f_dc_0, f_dc_1, f_dc_2 (SH DC → color via c = sh * 0.282 + 0.5)
        std::fprintf(f, "0.0 0.0 0.0 ");
        // opacity (raw, before sigmoid: 0.0 → sigmoid = 0.5)
        std::fprintf(f, "0.0 ");
        // scale_0..2 (log-space: 0.0 → exp(0) = 1.0)
        std::fprintf(f, "0.0 0.0 0.0 ");
        // rot_0..3 (identity quaternion)
        std::fprintf(f, "1.0 0.0 0.0 0.0\n");
    }

    std::fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// load_ply tests
// ---------------------------------------------------------------------------

static void test_load_nonexistent_file() {
    PlyLoadResult result;
    auto status = load_ply("/tmp/nonexistent_file_aether_test.ply", result);
    CHECK(status != aether::core::Status::kOk);
    CHECK(result.vertex_count == 0);
}

static void test_load_ascii_ply() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 3));

    PlyLoadResult result;
    auto status = load_ply(kTempPlyAscii, result);
    CHECK(status == aether::core::Status::kOk);
    CHECK(result.vertex_count == 3);
    CHECK(result.gaussians.size() == 3);
}

static void test_ascii_ply_positions() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 5));

    PlyLoadResult result;
    auto status = load_ply(kTempPlyAscii, result);
    CHECK(status == aether::core::Status::kOk);

    // Verify positions match what we wrote
    for (int i = 0; i < 5; ++i) {
        float fi = static_cast<float>(i);
        CHECK(near(result.gaussians[i].position[0], fi * 0.1f));
        CHECK(near(result.gaussians[i].position[1], fi * 0.2f));
        CHECK(near(result.gaussians[i].position[2], fi * 0.3f));
    }
}

static void test_ascii_ply_color_from_sh() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 1));

    PlyLoadResult result;
    load_ply(kTempPlyAscii, result);

    // SH DC = 0.0 → color = 0.0 * 0.28209 + 0.5 = 0.5
    CHECK(near(result.gaussians[0].color[0], 0.5f, 0.01f));
    CHECK(near(result.gaussians[0].color[1], 0.5f, 0.01f));
    CHECK(near(result.gaussians[0].color[2], 0.5f, 0.01f));
}

static void test_ascii_ply_opacity_sigmoid() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 1));

    PlyLoadResult result;
    load_ply(kTempPlyAscii, result);

    // Raw opacity = 0.0 → sigmoid(0) = 0.5
    CHECK(near(result.gaussians[0].opacity, 0.5f, 0.01f));
}

static void test_ascii_ply_scale_exp() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 1));

    PlyLoadResult result;
    load_ply(kTempPlyAscii, result);

    // Log-scale = 0.0 → exp(0) = 1.0
    CHECK(near(result.gaussians[0].scale[0], 1.0f, 0.01f));
    CHECK(near(result.gaussians[0].scale[1], 1.0f, 0.01f));
    CHECK(near(result.gaussians[0].scale[2], 1.0f, 0.01f));
}

static void test_ascii_ply_identity_quaternion() {
    CHECK(write_test_ascii_ply(kTempPlyAscii, 1));

    PlyLoadResult result;
    load_ply(kTempPlyAscii, result);

    CHECK(near(result.gaussians[0].rotation[0], 1.0f, 0.01f));
    CHECK(near(result.gaussians[0].rotation[1], 0.0f, 0.01f));
    CHECK(near(result.gaussians[0].rotation[2], 0.0f, 0.01f));
    CHECK(near(result.gaussians[0].rotation[3], 0.0f, 0.01f));
}

// ---------------------------------------------------------------------------
// write_ply tests
// ---------------------------------------------------------------------------

static void test_write_ply_nonexistent_dir() {
    GaussianParams g{};
    auto status = write_ply("/tmp/nonexistent_dir_aether/test.ply", &g, 1);
    CHECK(status != aether::core::Status::kOk);
}

static void test_write_ply_empty() {
    auto status = write_ply(kTempPlyBinary, nullptr, 0);
    CHECK(status == aether::core::Status::kOk);

    // Read back — should have 0 vertices
    PlyLoadResult result;
    auto load_status = load_ply(kTempPlyBinary, result);
    // With 0 vertices, the loader may return invalid argument since vertex_count==0
    // is handled as an error, OR it may succeed with empty. Either is acceptable.
    if (load_status == aether::core::Status::kOk) {
        CHECK(result.vertex_count == 0);
    }
}

// ---------------------------------------------------------------------------
// Write → Read roundtrip (binary PLY)
// ---------------------------------------------------------------------------

static void test_ply_roundtrip() {
    // Create test data
    constexpr std::size_t n = 10;
    std::vector<GaussianParams> original(n);

    for (std::size_t i = 0; i < n; ++i) {
        float fi = static_cast<float>(i);
        original[i].position[0] = fi * 1.1f;
        original[i].position[1] = fi * -0.5f;
        original[i].position[2] = fi * 0.7f + 1.0f;
        original[i].color[0] = 0.1f + fi * 0.05f;
        original[i].color[1] = 0.2f + fi * 0.03f;
        original[i].color[2] = 0.3f + fi * 0.02f;
        // Clamp colors to [0,1]
        for (int c = 0; c < 3; ++c) {
            if (original[i].color[c] > 1.0f) original[i].color[c] = 1.0f;
        }
        original[i].opacity = 0.5f + fi * 0.04f;
        if (original[i].opacity > 0.99f) original[i].opacity = 0.99f;
        original[i].scale[0] = 0.05f + fi * 0.01f;
        original[i].scale[1] = 0.1f + fi * 0.02f;
        original[i].scale[2] = 0.02f + fi * 0.005f;
        original[i].rotation[0] = 1.0f;  // identity
        original[i].rotation[1] = 0.0f;
        original[i].rotation[2] = 0.0f;
        original[i].rotation[3] = 0.0f;
    }

    // Write
    auto write_status = write_ply(kTempPlyRoundtrip, original.data(), n);
    CHECK(write_status == aether::core::Status::kOk);

    // Read back
    PlyLoadResult result;
    auto load_status = load_ply(kTempPlyRoundtrip, result);
    CHECK(load_status == aether::core::Status::kOk);
    CHECK(result.vertex_count == n);
    CHECK(result.gaussians.size() == n);

    // Compare
    for (std::size_t i = 0; i < n; ++i) {
        const auto& orig = original[i];
        const auto& loaded = result.gaussians[i];

        // Position should be exact (float → float binary roundtrip)
        CHECK(near(loaded.position[0], orig.position[0], 1e-5f));
        CHECK(near(loaded.position[1], orig.position[1], 1e-5f));
        CHECK(near(loaded.position[2], orig.position[2], 1e-5f));

        // Color: stored as SH DC, read back via inverse → some precision loss
        // SH DC = (c - 0.5) / C0, then read back as c = sh * C0 + 0.5
        // This should be exact in float precision
        CHECK(near(loaded.color[0], orig.color[0], 1e-4f));
        CHECK(near(loaded.color[1], orig.color[1], 1e-4f));
        CHECK(near(loaded.color[2], orig.color[2], 1e-4f));

        // Opacity: stored as logit, read back via sigmoid
        // logit(sigmoid(x)) = x, so this is float-exact
        CHECK(near(loaded.opacity, orig.opacity, 1e-4f));

        // Scale: stored as log, read back via exp
        CHECK(near(loaded.scale[0], orig.scale[0], 1e-4f));
        CHECK(near(loaded.scale[1], orig.scale[1], 1e-4f));
        CHECK(near(loaded.scale[2], orig.scale[2], 1e-4f));

        // Rotation: quaternion stored directly
        CHECK(near(loaded.rotation[0], orig.rotation[0], 1e-4f));
        CHECK(near(loaded.rotation[1], orig.rotation[1], 1e-4f));
        CHECK(near(loaded.rotation[2], orig.rotation[2], 1e-4f));
        CHECK(near(loaded.rotation[3], orig.rotation[3], 1e-4f));
    }
}

// ---------------------------------------------------------------------------
// PLY with minimal properties (only position)
// ---------------------------------------------------------------------------

static void test_load_minimal_ply() {
    const char* path = "/tmp/aether_test_minimal.ply";
    std::FILE* f = std::fopen(path, "w");
    CHECK(f != nullptr);
    if (!f) return;

    std::fprintf(f, "ply\n");
    std::fprintf(f, "format ascii 1.0\n");
    std::fprintf(f, "element vertex 2\n");
    std::fprintf(f, "property float x\n");
    std::fprintf(f, "property float y\n");
    std::fprintf(f, "property float z\n");
    std::fprintf(f, "end_header\n");
    std::fprintf(f, "1.0 2.0 3.0\n");
    std::fprintf(f, "4.0 5.0 6.0\n");
    std::fclose(f);

    PlyLoadResult result;
    auto status = load_ply(path, result);
    CHECK(status == aether::core::Status::kOk);
    CHECK(result.vertex_count == 2);

    // Position
    CHECK(near(result.gaussians[0].position[0], 1.0f));
    CHECK(near(result.gaussians[0].position[1], 2.0f));
    CHECK(near(result.gaussians[0].position[2], 3.0f));
    CHECK(near(result.gaussians[1].position[0], 4.0f));

    // Defaults: color=0.5, opacity=1.0, scale=0.01, rotation=identity
    CHECK(near(result.gaussians[0].color[0], 0.5f));
    CHECK(near(result.gaussians[0].opacity, 1.0f));
    CHECK(near(result.gaussians[0].scale[0], 0.01f));
    CHECK(near(result.gaussians[0].rotation[0], 1.0f));
}

// ---------------------------------------------------------------------------
// PLY with no vertex element
// ---------------------------------------------------------------------------

static void test_load_no_vertex_ply() {
    const char* path = "/tmp/aether_test_novertex.ply";
    std::FILE* f = std::fopen(path, "w");
    CHECK(f != nullptr);
    if (!f) return;

    std::fprintf(f, "ply\n");
    std::fprintf(f, "format ascii 1.0\n");
    std::fprintf(f, "element face 1\n");
    std::fprintf(f, "property list uchar int vertex_indices\n");
    std::fprintf(f, "end_header\n");
    std::fprintf(f, "3 0 1 2\n");
    std::fclose(f);

    PlyLoadResult result;
    auto status = load_ply(path, result);
    CHECK(status != aether::core::Status::kOk);
}

// ---------------------------------------------------------------------------
// PLY missing position properties
// ---------------------------------------------------------------------------

static void test_load_missing_position() {
    const char* path = "/tmp/aether_test_noxyz.ply";
    std::FILE* f = std::fopen(path, "w");
    CHECK(f != nullptr);
    if (!f) return;

    std::fprintf(f, "ply\n");
    std::fprintf(f, "format ascii 1.0\n");
    std::fprintf(f, "element vertex 1\n");
    std::fprintf(f, "property float opacity\n");
    std::fprintf(f, "end_header\n");
    std::fprintf(f, "0.5\n");
    std::fclose(f);

    PlyLoadResult result;
    auto status = load_ply(path, result);
    CHECK(status != aether::core::Status::kOk);
}

// ---------------------------------------------------------------------------
// Cleanup temp files
// ---------------------------------------------------------------------------

static void cleanup() {
    std::remove(kTempPlyAscii);
    std::remove(kTempPlyBinary);
    std::remove(kTempPlyRoundtrip);
    std::remove("/tmp/aether_test_minimal.ply");
    std::remove("/tmp/aether_test_novertex.ply");
    std::remove("/tmp/aether_test_noxyz.ply");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    test_load_nonexistent_file();
    test_load_ascii_ply();
    test_ascii_ply_positions();
    test_ascii_ply_color_from_sh();
    test_ascii_ply_opacity_sigmoid();
    test_ascii_ply_scale_exp();
    test_ascii_ply_identity_quaternion();

    test_write_ply_nonexistent_dir();
    test_write_ply_empty();

    test_ply_roundtrip();
    test_load_minimal_ply();
    test_load_no_vertex_ply();
    test_load_missing_position();

    cleanup();

    if (g_failed == 0) {
        std::fprintf(stdout, "ply_loader_test: all tests passed\n");
    }
    return g_failed;
}
