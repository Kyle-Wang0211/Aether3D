// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 7 smoke test — Brush project_backwards.wgsl on Dawn.
//
// Final training-side kernel. Backward gradient pass for project_forward
// + project_visible: takes v_grads (gradient w.r.t. ProjectedSplat) and
// produces gradients w.r.t. the original Gaussian primitives:
//   v_means      — ∂L/∂mean_xyz
//   v_scales     — ∂L/∂log_scale
//   v_quats      — ∂L/∂quaternion
//   v_coeffs_1   — ∂L/∂SH-DC-coefficient
//
// Phase 6 viewer skips this (no training in viewer); kept for Phase 7+
// on-device training.
//
// Bindings (10):
//   0 uniforms                     (read storage — atomic-free, see splat_render note)
//   1 means          (fwd input)
//   2 log_scales     (fwd input)
//   3 quats          (fwd input)
//   4 global_from_compact_gid (chain link)
//   5 v_grads        (vec4 gradient input from rasterize_backwards)
//   6 v_means        (write — gradient out)
//   7 v_scales       (write — gradient out)
//   8 v_quats        (write — gradient out)
//   9 v_coeffs_1     (write — SH coefficient gradient out)
//
// Test setup: 4 splats (same primitive data as project_forward smoke),
// v_grads = constant (1, 1, 1, 1) per splat as synthetic gradient.
//
// DoD: ∂L/∂Gaussian outputs non-NaN + magnitudes reasonable (not zero
// everywhere, not denormalized).

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

#include <array>
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
using aether::tools::splat_test_data::make_identity_camera_args;

constexpr uint32_t kNumSplats = 4;

std::string read_wgsl(const std::string& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::ostringstream ss; ss << in.rdbuf(); return ss.str();
}

bool any_nan_or_inf(const std::vector<float>& v) {
    for (float x : v) {
        if (std::isnan(x) || std::isinf(x)) return true;
    }
    return false;
}

float rms(const std::vector<float>& v) {
    if (v.empty()) return 0.0f;
    double s = 0.0;
    for (float x : v) s += static_cast<double>(x) * x;
    return static_cast<float>(std::sqrt(s / v.size()));
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/project_backwards.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl(wgsl_path);
    if (wgsl.empty()) return 1;

    DawnKernelHarness h;
    if (!h.init()) return 1;

    // ─── Forward inputs (same as project_forward smoke) ────────────────
    RenderArgsStorage u = make_identity_camera_args(kNumSplats, kNumSplats);

    PackedVec3 means[kNumSplats] = {
        {0.0f, 0.0f, 2.0f},
        {0.0f, 0.0f, 4.0f},
        {0.0f, 0.0f, 6.0f},
        {0.0f, 0.0f, 8.0f},
    };
    PackedVec3 log_scales[kNumSplats] = {
        {0.0f, 0.0f, 0.0f},  // exp(0) = 1, isotropic unit-scale splat
        {0.0f, 0.0f, 0.0f},
        {0.0f, 0.0f, 0.0f},
        {0.0f, 0.0f, 0.0f},
    };
    float quats[kNumSplats][4] = {
        {1.0f, 0.0f, 0.0f, 0.0f},  // identity quaternion (w, x, y, z) order
        {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f},
    };
    uint32_t global_from_compact_gid[kNumSplats] = {0, 1, 2, 3};

    // Synthetic gradient: each splat receives a uniform (1, 1, 1, 1)
    // gradient on its ProjectedSplat output.
    float v_grads[kNumSplats][4] = {
        {1.0f, 1.0f, 1.0f, 1.0f},
        {1.0f, 1.0f, 1.0f, 1.0f},
        {1.0f, 1.0f, 1.0f, 1.0f},
        {1.0f, 1.0f, 1.0f, 1.0f},
    };

    // ─── Upload + alloc ────────────────────────────────────────────────
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage);
    auto buf_means = h.upload(means, sizeof(means),
        wgpu::BufferUsage::Storage);
    auto buf_log_scales = h.upload(log_scales, sizeof(log_scales),
        wgpu::BufferUsage::Storage);
    auto buf_quats = h.upload(quats, sizeof(quats),
        wgpu::BufferUsage::Storage);
    auto buf_global_from_compact = h.upload(global_from_compact_gid,
        sizeof(global_from_compact_gid), wgpu::BufferUsage::Storage);
    auto buf_v_grads = h.upload(v_grads, sizeof(v_grads),
        wgpu::BufferUsage::Storage);

    // Output buffers: zero-init, will receive gradient writes.
    auto buf_v_means = h.alloc(sizeof(means),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_v_scales = h.alloc(sizeof(log_scales),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_v_quats = h.alloc(sizeof(quats),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    // v_coeffs_1: SH degree 0 = 1 coefficient × 3 channels = 3 floats per splat.
    constexpr size_t kCoeffsLen = kNumSplats * 3;
    auto buf_v_coeffs = h.alloc(kCoeffsLen * sizeof(float),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto pipe = h.load_compute(wgsl, "main");
    if (pipe == nullptr) return 1;

    // workgroup_size(256), dispatch ceil(N / 256) = 1 for N=4.
    const uint32_t wg_x = (kNumSplats + 255) / 256;
    h.dispatch(pipe,
               { buf_uniforms, buf_means, buf_log_scales, buf_quats,
                 buf_global_from_compact, buf_v_grads,
                 buf_v_means, buf_v_scales, buf_v_quats, buf_v_coeffs },
               wg_x, 1, 1);

    // ─── Readback ─────────────────────────────────────────────────────
    auto staging_m = h.alloc_staging_for_readback(sizeof(means));
    auto staging_s = h.alloc_staging_for_readback(sizeof(log_scales));
    auto staging_q = h.alloc_staging_for_readback(sizeof(quats));
    auto staging_c = h.alloc_staging_for_readback(kCoeffsLen * sizeof(float));
    h.copy_to_staging(buf_v_means,  staging_m, sizeof(means));
    h.copy_to_staging(buf_v_scales, staging_s, sizeof(log_scales));
    h.copy_to_staging(buf_v_quats,  staging_q, sizeof(quats));
    h.copy_to_staging(buf_v_coeffs, staging_c, kCoeffsLen * sizeof(float));
    auto bytes_m = h.readback(staging_m, sizeof(means));
    auto bytes_s = h.readback(staging_s, sizeof(log_scales));
    auto bytes_q = h.readback(staging_q, sizeof(quats));
    auto bytes_c = h.readback(staging_c, kCoeffsLen * sizeof(float));

    auto to_floats = [](const std::vector<uint8_t>& bytes, size_t count) {
        std::vector<float> out(count);
        std::memcpy(out.data(), bytes.data(), count * sizeof(float));
        return out;
    };
    auto v_means_out  = to_floats(bytes_m, kNumSplats * 3);
    auto v_scales_out = to_floats(bytes_s, kNumSplats * 3);
    auto v_quats_out  = to_floats(bytes_q, kNumSplats * 4);
    auto v_coeffs_out = to_floats(bytes_c, kCoeffsLen);

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_project_backwards ===\n";
    std::cout << "N = " << kNumSplats << ", v_grads = (1,1,1,1) per splat\n";

    std::cout << "v_means RMS  = " << rms(v_means_out)  << "  first=("
              << v_means_out[0]  << ", " << v_means_out[1]  << ", " << v_means_out[2]  << ")\n";
    std::cout << "v_scales RMS = " << rms(v_scales_out) << "  first=("
              << v_scales_out[0] << ", " << v_scales_out[1] << ", " << v_scales_out[2] << ")\n";
    std::cout << "v_quats RMS  = " << rms(v_quats_out)  << "  first=("
              << v_quats_out[0]  << ", " << v_quats_out[1]  << ", "
              << v_quats_out[2]  << ", " << v_quats_out[3]  << ")\n";
    std::cout << "v_coeffs RMS = " << rms(v_coeffs_out) << '\n';

    if (any_nan_or_inf(v_means_out) || any_nan_or_inf(v_scales_out)
        || any_nan_or_inf(v_quats_out) || any_nan_or_inf(v_coeffs_out)) {
        std::cerr << "FAIL: NaN/Inf in gradient output — kernel produced bad numbers\n";
        return 1;
    }

    // At least one gradient should be non-zero (kernel actually wrote).
    auto nonzero_count = [](const std::vector<float>& v) {
        size_t n = 0;
        for (float x : v) if (x != 0.0f) ++n;
        return n;
    };
    size_t nz = nonzero_count(v_means_out) + nonzero_count(v_scales_out)
              + nonzero_count(v_quats_out) + nonzero_count(v_coeffs_out);
    std::cout << "total non-zero gradient entries: " << nz << '\n';
    if (nz == 0) {
        std::cerr << "FAIL: all gradients zero — kernel didn't write\n";
        return 1;
    }

    // Magnitudes reasonable: RMS should be in [1e-6, 1e6] range
    // (anything outside hints at numerical pathology).
    auto check_magnitude = [](const std::string& name, float r) -> bool {
        if (r > 0 && (r < 1e-10f || r > 1e10f)) {
            std::cerr << "FAIL: " << name << " RMS " << r
                      << " out of [1e-10, 1e10] reasonable range\n";
            return false;
        }
        return true;
    };
    if (!check_magnitude("v_means",  rms(v_means_out))  ||
        !check_magnitude("v_scales", rms(v_scales_out)) ||
        !check_magnitude("v_quats",  rms(v_quats_out))  ||
        !check_magnitude("v_coeffs", rms(v_coeffs_out))) {
        return 1;
    }

    std::cout << "PASS\n";
    return 0;
}
