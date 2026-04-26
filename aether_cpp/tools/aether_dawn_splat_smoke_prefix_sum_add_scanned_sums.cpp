// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5b smoke test — Brush prefix_sum_add_scanned_sums.wgsl on Dawn.
//
// Third (final) kernel of Brush's 3-stage prefix-sum: takes the scanned
// per-workgroup totals (from prefix_sum_scan_sums) and adds the running
// total to every element of the corresponding workgroup in `output[]`.
//
// Per-thread: output[id.x] += input[wid.x]
// where wid.x = id.x / 512 is the workgroup index.
//
// Smoke design:
//   - output pre-loaded with all-ones (1024 elements = 2 workgroups)
//   - input = [0, 100] (additions per workgroup)
//   - After kernel: output[0..511] += 0 → still 1
//                   output[512..1023] += 100 → 101
//
// What this verifies:
//   1. prefix_sum_add_scanned_sums.wgsl compiles via Tint
//   2. 2-buffer @group(0) bind layout valid
//   3. Workgroup-id indexed read + per-thread output write working

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
constexpr uint32_t kWG = 512;

std::string read_wgsl(const std::string& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::ostringstream ss; ss << in.rdbuf(); return ss.str();
}
}

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/prefix_sum_add_scanned_sums.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl(wgsl_path);
    if (wgsl.empty()) return 1;

    DawnKernelHarness h;
    if (!h.init()) return 1;

    // Output starts as all-ones; kernel adds input[wid.x] per workgroup.
    std::vector<uint32_t> output_init(kN, 1u);
    std::vector<uint32_t> input = {0, 100};  // one entry per workgroup

    auto buf_in = h.upload(input.data(), input.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage);
    auto buf_out = h.upload(output_init.data(), output_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto pipe = h.load_compute(wgsl, "main");
    if (pipe == nullptr) return 1;
    // 2 workgroups × 512 threads = 1024 threads (covers entire output).
    h.dispatch(pipe, { buf_in, buf_out }, 2, 1, 1);

    auto staging = h.alloc_staging_for_readback(kN * sizeof(uint32_t));
    h.copy_to_staging(buf_out, staging, kN * sizeof(uint32_t));
    auto bytes = h.readback(staging, kN * sizeof(uint32_t));
    std::vector<uint32_t> out(kN);
    std::memcpy(out.data(), bytes.data(), bytes.size());

    std::cout << "=== aether_dawn_splat_smoke_prefix_sum_add_scanned_sums ===\n";
    std::cout << "N = " << kN << ", workgroup adds: [0, 100]\n";
    std::cout << "output[0]    = " << out[0] << " (expect 1)\n";
    std::cout << "output[511]  = " << out[511] << " (expect 1)\n";
    std::cout << "output[512]  = " << out[512] << " (expect 101)\n";
    std::cout << "output[1023] = " << out[1023] << " (expect 101)\n";

    // Workgroup 0 (idx 0..511): output should still be 1 (added 0).
    for (uint32_t i = 0; i < kWG; ++i) {
        if (out[i] != 1) {
            std::cerr << "FAIL: WG0 output[" << i << "] = " << out[i]
                      << " expected 1\n"; return 1;
        }
    }
    // Workgroup 1 (idx 512..1023): output should be 101 (added 100).
    for (uint32_t i = kWG; i < kN; ++i) {
        if (out[i] != 101) {
            std::cerr << "FAIL: WG1 output[" << i << "] = " << out[i]
                      << " expected 101\n"; return 1;
        }
    }

    std::cout << "PASS\n";
    return 0;
}
