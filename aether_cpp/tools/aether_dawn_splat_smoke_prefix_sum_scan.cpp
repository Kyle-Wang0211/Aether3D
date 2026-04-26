// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5b smoke test — Brush prefix_sum_scan.wgsl on Dawn.
//
// First kernel of Brush's 3-stage prefix-sum: per-workgroup inclusive scan
// (Hillis-Steele, log2(512)=9 iterations, workgroup_size=512). Each
// workgroup independently scans its own chunk of `input[]` into `output[]`.
//
// Smoke uses N=64 ones (one workgroup, exercises bounds check) and
// verifies the inclusive-scan property:
//   output[i] = sum(input[0..=i]) = i + 1
// i.e. output = [1, 2, 3, ..., 64]
//
// What this verifies:
//   1. prefix_sum_scan.wgsl compiles via Tint (Hillis-Steele + workgroupBarrier)
//   2. 2-buffer @group(0) bind layout valid
//   3. Single-workgroup inclusive scan correct end-to-end

#include "dawn_kernel_harness.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kN = 64;

std::string read_wgsl(const std::string& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::ostringstream ss; ss << in.rdbuf(); return ss.str();
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/prefix_sum_scan.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl(wgsl_path);
    if (wgsl.empty()) { std::cerr << "Failed to read WGSL\n"; return 1; }

    DawnKernelHarness h;
    if (!h.init()) return 1;

    std::vector<uint32_t> input(kN, 1u);
    auto buf_in = h.upload(input.data(), input.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage);
    auto buf_out = h.alloc(input.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto pipe = h.load_compute(wgsl, "main");
    if (pipe == nullptr) return 1;
    // 1 workgroup of 512 threads covers N=64 (excess threads do nothing).
    h.dispatch(pipe, { buf_in, buf_out }, 1, 1, 1);

    auto staging = h.alloc_staging_for_readback(input.size() * sizeof(uint32_t));
    h.copy_to_staging(buf_out, staging, input.size() * sizeof(uint32_t));
    auto bytes = h.readback(staging, input.size() * sizeof(uint32_t));
    std::vector<uint32_t> out(kN);
    std::memcpy(out.data(), bytes.data(), bytes.size());

    std::cout << "=== aether_dawn_splat_smoke_prefix_sum_scan ===\n";
    std::cout << "N = " << kN << " (input all-ones)\n";
    std::cout << "first 8 output: ";
    for (uint32_t i = 0; i < 8; ++i) std::cout << out[i] << ' ';
    std::cout << "\nlast 4 output: ";
    for (uint32_t i = kN - 4; i < kN; ++i) std::cout << out[i] << ' ';
    std::cout << '\n';

    // Inclusive scan of all-ones: output[i] = i + 1.
    for (uint32_t i = 0; i < kN; ++i) {
        if (out[i] != i + 1) {
            std::cerr << "FAIL: output[" << i << "] = " << out[i]
                      << " expected " << (i + 1) << '\n';
            return 1;
        }
    }
    // Monotone (just a redundant check for sort family parity).
    for (uint32_t i = 1; i < kN; ++i) {
        if (out[i] < out[i - 1]) {
            std::cerr << "FAIL: not monotone at " << i << '\n'; return 1;
        }
    }

    std::cout << "PASS\n";
    return 0;
}
