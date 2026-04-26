// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5a smoke test — Brush sort_count.wgsl on Dawn.
//
// First kernel of Brush's 4-bit-per-pass radix sort. Reads N keys, masks
// to a 4-bit window (per shift), increments per-bin atomic histogram in
// workgroup memory, writes per-block bin counts to global counts buffer.
//
// Inputs:
//   @binding(0) config            : { shift: u32 }
//   @binding(1) num_keys_arr      : [N]
//   @binding(2) src               : [N keys]
// Output:
//   @binding(3) counts            : [BIN_COUNT * num_blocks]
//
// What this verifies:
//   1. sort_count.wgsl compiles via Tint (atomic + workgroup memory paths)
//   2. 4-buffer @group(0) bind layout valid
//   3. Element conservation: sum(counts) == N
//   4. No bin count exceeds N (sanity)

#include "aether_dawn_sort_test_data.h"
#include "dawn_kernel_harness.h"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {
using namespace aether::tools::sort_test_data;
}

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/sort_count.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl_file(wgsl_path);
    if (wgsl.empty()) { std::cerr << "Failed to read WGSL\n"; return EXIT_FAILURE; }

    DawnKernelHarness h;
    if (!h.init()) { std::cerr << "init failed\n"; return EXIT_FAILURE; }

    // ─── Inputs ────────────────────────────────────────────────────────
    uint32_t shift = 0;
    uint32_t num_keys = kSortN;
    auto keys = make_test_keys();

    auto buf_config = h.upload(&shift, sizeof(shift),
        wgpu::BufferUsage::Storage);
    auto buf_num_keys = h.upload(&num_keys, sizeof(num_keys),
        wgpu::BufferUsage::Storage);
    auto buf_src = h.upload(keys.data(), keys.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage);
    auto buf_counts = h.alloc(kSortCountsLen * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    // ─── Compile + dispatch ───────────────────────────────────────────
    auto pipeline = h.load_compute(wgsl, "main");
    if (pipeline == nullptr) { std::cerr << "load_compute null\n"; return EXIT_FAILURE; }

    // num_blocks = 1, so dispatch 1 workgroup of 256 threads
    h.dispatch(pipeline, { buf_config, buf_num_keys, buf_src, buf_counts },
               kSortNumBlocks, 1, 1);

    // ─── Readback ─────────────────────────────────────────────────────
    const size_t counts_bytes = kSortCountsLen * sizeof(uint32_t);
    auto staging = h.alloc_staging_for_readback(counts_bytes);
    h.copy_to_staging(buf_counts, staging, counts_bytes);
    auto out = h.readback(staging, counts_bytes);

    if (out.size() != counts_bytes) {
        std::cerr << "Readback size mismatch\n"; return EXIT_FAILURE;
    }
    std::vector<uint32_t> counts(kSortCountsLen);
    std::memcpy(counts.data(), out.data(), counts_bytes);

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_sort_count ===\n";
    std::cout << "WGSL: " << wgsl_path << '\n';
    std::cout << "N = " << num_keys << ", shift = " << shift
              << ", num_blocks = " << kSortNumBlocks << '\n';

    uint32_t total = 0;
    uint32_t max_count = 0;
    for (uint32_t i = 0; i < kSortCountsLen; ++i) {
        total += counts[i];
        if (counts[i] > max_count) max_count = counts[i];
    }
    std::cout << "counts: ";
    for (uint32_t i = 0; i < kSortCountsLen; ++i) std::cout << counts[i] << ' ';
    std::cout << "\nsum(counts) = " << total << " (expected " << num_keys << ")\n";
    std::cout << "max bin count = " << max_count << '\n';

    if (total != num_keys) {
        std::cerr << "FAIL: sum(counts) != N — element conservation broken\n";
        return EXIT_FAILURE;
    }
    if (max_count == 0) {
        std::cerr << "FAIL: all counts zero — kernel didn't write\n";
        return EXIT_FAILURE;
    }
    if (max_count > num_keys) {
        std::cerr << "FAIL: bin count > N — atomic increment broken\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
