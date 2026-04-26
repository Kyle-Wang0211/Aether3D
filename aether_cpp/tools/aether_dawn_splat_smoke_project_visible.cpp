// Phase 6.3a smoke test — Brush project_visible.wgsl on Dawn.
//
// Second kernel in the viewer pipeline. Reads the visible-splat indices
// produced by project_forward (binding 6 = global_from_compact_gid) +
// SH coefficients (binding 4 = coeffs) + the per-Gaussian primitive
// data, and writes ProjectedSplat[] (2D position, conic, RGBA color)
// per visible splat.
//
// Runs in isolation: we pre-populate uniforms.num_visible + the gid
// mapping array directly, rather than chaining project_forward → this.
// Per-kernel isolation matches Plan B's "bisect range = 1 kernel" goal.
//
// What this verifies (not "is the math correct"):
//   1. project_visible.wgsl compiles via Tint
//   2. 8-buffer @group(0) bind layout valid (one more binding than
//      project_forward — exercises a different bind-group-layout shape)
//   3. atomicLoad on RenderArgsStorage::num_visible works
//   4. Dispatch reads global_from_compact_gid + writes ProjectedSplat
//      without crash, no NaN/inf in output
//   5. SH degree 0 (DC color only) path doesn't crash even with 1
//      coefficient per splat (vs higher-degree multi-coeff arrays)

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::PackedVec3;
using aether::tools::splat_test_data::ProjectedSplat;
using aether::tools::splat_test_data::make_identity_camera_args;

constexpr uint32_t kNumSplats = 4;

std::string read_wgsl_file(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        std::cerr << "Failed to open WGSL: " << path << '\n';
        return {};
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

bool any_nan_or_inf(const std::vector<uint8_t>& bytes) {
    const auto* fp = reinterpret_cast<const float*>(bytes.data());
    const size_t count = bytes.size() / sizeof(float);
    for (size_t i = 0; i < count; ++i) {
        if (std::isnan(fp[i]) || std::isinf(fp[i])) return true;
    }
    return false;
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path =
        "aether_cpp/shaders/wgsl/project_visible.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl_file(wgsl_path);
    if (wgsl.empty()) return EXIT_FAILURE;

    DawnKernelHarness h;
    if (!h.init()) {
        std::cerr << "DawnKernelHarness::init failed\n";
        return EXIT_FAILURE;
    }

    // ─── Build uniforms with num_visible PRE-POPULATED ─────────────────
    // project_visible reads num_visible via atomicLoad to determine
    // dispatch boundary. project_forward would have set it; we set it
    // directly so this smoke test runs standalone.
    RenderArgsStorage u = make_identity_camera_args(kNumSplats,
                                                     /*num_visible=*/kNumSplats);

    // ─── Per-Gaussian primitive arrays (same layout as project_forward) ─
    PackedVec3 means[kNumSplats] = {
        {0.0f, 0.0f, 2.0f},
        {0.0f, 0.0f, 4.0f},
        {0.0f, 0.0f, 6.0f},
        {0.0f, 0.0f, 8.0f},
    };
    PackedVec3 log_scales[kNumSplats] = {
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
    };
    float quats[kNumSplats * 4] = {
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    // SH degree 0 → 1 PackedVec3 (DC term) per splat. Mid-gray DC.
    PackedVec3 coeffs[kNumSplats] = {
        {0.5f, 0.5f, 0.5f},
        {0.5f, 0.5f, 0.5f},
        {0.5f, 0.5f, 0.5f},
        {0.5f, 0.5f, 0.5f},
    };
    float raw_opacities[kNumSplats] = {1.0f, 1.0f, 1.0f, 1.0f};
    // global_from_compact_gid: identity mapping (compact[i] → global[i])
    // since we pretend project_forward's output put all 4 splats visible.
    uint32_t gid_map[kNumSplats] = {0, 1, 2, 3};

    // ─── Upload buffers in @binding order ──────────────────────────────
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_means        = h.upload(means,         sizeof(means),         wgpu::BufferUsage::Storage);
    auto buf_log_scales   = h.upload(log_scales,    sizeof(log_scales),    wgpu::BufferUsage::Storage);
    auto buf_quats        = h.upload(quats,         sizeof(quats),         wgpu::BufferUsage::Storage);
    auto buf_coeffs       = h.upload(coeffs,        sizeof(coeffs),        wgpu::BufferUsage::Storage);
    auto buf_opacities    = h.upload(raw_opacities, sizeof(raw_opacities), wgpu::BufferUsage::Storage);
    auto buf_gid          = h.upload(gid_map,       sizeof(gid_map),       wgpu::BufferUsage::Storage);
    constexpr size_t kProjectedBytes = kNumSplats * sizeof(ProjectedSplat);
    auto buf_projected = h.alloc(kProjectedBytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    // ─── Compile + dispatch ───────────────────────────────────────────
    auto pipeline = h.load_compute(wgsl, "main");
    if (pipeline == nullptr) {
        std::cerr << "load_compute returned null\n";
        return EXIT_FAILURE;
    }
    const uint32_t wg_x = (kNumSplats + 255) / 256;
    h.dispatch(pipeline,
               { buf_uniforms, buf_means, buf_log_scales, buf_quats,
                 buf_coeffs, buf_opacities, buf_gid, buf_projected },
               wg_x, 1, 1);

    // ─── Readback ProjectedSplat[] ────────────────────────────────────
    auto staging = h.alloc_staging_for_readback(kProjectedBytes);
    h.copy_to_staging(buf_projected, staging, kProjectedBytes);
    auto bytes = h.readback(staging, kProjectedBytes);
    if (bytes.size() != kProjectedBytes) {
        std::cerr << "Readback size mismatch (got " << bytes.size()
                  << " expected " << kProjectedBytes << ")\n";
        return EXIT_FAILURE;
    }

    std::cout << "=== aether_dawn_splat_smoke_project_visible ===\n";
    std::cout << "WGSL: " << wgsl_path << '\n';
    std::cout << "WGSL bytes: " << wgsl.size() << '\n';
    std::cout << "input num_visible (preset): " << u.num_visible << '\n';
    std::cout << "ProjectedSplat output (per splat):\n";
    const auto* ps = reinterpret_cast<const ProjectedSplat*>(bytes.data());
    for (uint32_t i = 0; i < kNumSplats; ++i) {
        std::cout << "  splat " << i << ": xy=("
                  << ps[i].xy_x << "," << ps[i].xy_y << ") "
                  << "conic=(" << ps[i].conic_x << "," << ps[i].conic_y
                  << "," << ps[i].conic_z << ") "
                  << "rgba=(" << ps[i].color_r << "," << ps[i].color_g
                  << "," << ps[i].color_b << "," << ps[i].color_a << ")\n";
    }

    if (any_nan_or_inf(bytes)) {
        std::cerr << "FAIL: NaN/Inf in ProjectedSplat output\n";
        return EXIT_FAILURE;
    }
    // Sanity bounds check — projection should land all 4 splats inside
    // a 256×256 image (since means are at z=2..8 along the optical axis,
    // they project to image center at (128,128) regardless of depth).
    for (uint32_t i = 0; i < kNumSplats; ++i) {
        if (ps[i].xy_x < -1.0f || ps[i].xy_x > 257.0f ||
            ps[i].xy_y < -1.0f || ps[i].xy_y > 257.0f) {
            std::cerr << "WARN: splat " << i << " projected outside image: ("
                      << ps[i].xy_x << "," << ps[i].xy_y
                      << ") — math may differ from assumption, MetalSplatter "
                      << "cross-val (Phase 6.5) catches semantic divergence\n";
        }
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
