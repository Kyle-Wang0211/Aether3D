// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5b smoke test — Brush prefix_sum_scan_sums.wgsl on Dawn.
//
// Second kernel of Brush's 3-stage prefix-sum: scans the per-workgroup
// totals from prefix_sum_scan output. Each thread reads input at
// idx = id.x * 512 - 1 (the LAST element of the id.x-th workgroup),
// then performs a Hillis-Steele inclusive scan on those.
//
// Smoke crafts an input where workgroup-last positions have known values
// so we can verify the scan deterministically:
//   N = 1024 (2 workgroups), input[511] = 10, input[1023] = 20, rest 0.
// Expected:
//   output[0] = 0 (thread 0's idx wraps, x = 0)
//   output[1] = 10  (thread 1 reads input[511])
//   output[2] = 30  (thread 2 reads input[1023], scan adds previous: 10 + 20)
//   output[3..] = 30  (all subsequent threads have x=0, scan stays at 30)

#include "dawn_kernel_harness.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kN = 1024;

std::string read_wgsl(const std::string& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::ostringstream ss; ss << in.rdbuf(); return ss.str();
}
}

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/prefix_sum_scan_sums.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl(wgsl_path);
    if (wgsl.empty()) return 1;

    DawnKernelHarness h;
    if (!h.init()) return 1;

    std::vector<uint32_t> input(kN, 0u);
    input[511] = 10;
    input[1023] = 20;

    auto buf_in = h.upload(input.data(), input.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage);
    // output is sized for one workgroup of scanned sums (= 512 threads
    // worth of output). Allocate kN to match the input length (kernel
    // bounds-checks against arrayLength(output)).
    auto buf_out = h.alloc(kN * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto pipe = h.load_compute(wgsl, "main");
    if (pipe == nullptr) return 1;
    // 1 workgroup of 512 threads, each reads 1 per-workgroup total.
    h.dispatch(pipe, { buf_in, buf_out }, 1, 1, 1);

    auto staging = h.alloc_staging_for_readback(kN * sizeof(uint32_t));
    h.copy_to_staging(buf_out, staging, kN * sizeof(uint32_t));
    auto bytes = h.readback(staging, kN * sizeof(uint32_t));
    std::vector<uint32_t> out(kN);
    std::memcpy(out.data(), bytes.data(), bytes.size());

    std::cout << "=== aether_dawn_splat_smoke_prefix_sum_scan_sums ===\n";
    std::cout << "N = " << kN << ", input[511]=10, input[1023]=20\n";
    std::cout << "output[0..5]: ";
    for (uint32_t i = 0; i < 5; ++i) std::cout << out[i] << ' ';
    std::cout << '\n';

    // Expected: output[0]=0, output[1]=10, output[2]=30, output[3..]=30.
    if (out[0] != 0 || out[1] != 10 || out[2] != 30) {
        std::cerr << "FAIL: scan-of-sums bad. got "
                  << out[0] << ", " << out[1] << ", " << out[2] << '\n';
        return 1;
    }
    // Monotone (inclusive scan is non-decreasing for non-negative input).
    for (uint32_t i = 1; i < 8; ++i) {
        if (out[i] < out[i - 1]) {
            std::cerr << "FAIL: not monotone at " << i << '\n'; return 1;
        }
    }

    std::cout << "PASS\n";
    return 0;
}
