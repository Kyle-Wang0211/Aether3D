// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5a smoke test — Brush sort_scan_add.wgsl on Dawn.
//
// Fourth kernel of Brush 4-bit radix sort. Adds the scanned bin offsets
// (from sort_scan, stored in `reduced`) back into the per-block `counts`
// so each (bin, block) entry holds a global-scope offset.
//
// Chains sort_count → sort_reduce → sort_scan → sort_scan_add.
//
// What this verifies:
//   1. sort_scan_add.wgsl compiles via Tint
//   2. 3-buffer @group(0) bind layout valid
//   3. After scan_add, counts are monotone non-decreasing within each bin
//      (each block's offset = previous block's offset + previous count)
//   4. Final counts entry < N (sanity: offsets bounded by sort domain)

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

int main(int argc, char* argv[]) {
    using namespace aether::tools;

    std::string scan_add_path = "aether_cpp/shaders/wgsl/sort_scan_add.wgsl";
    std::string scan_path     = "aether_cpp/shaders/wgsl/sort_scan.wgsl";
    std::string reduce_path   = "aether_cpp/shaders/wgsl/sort_reduce.wgsl";
    std::string count_path    = "aether_cpp/shaders/wgsl/sort_count.wgsl";
    if (argc > 1) scan_add_path = argv[1];
    if (argc > 2) scan_path     = argv[2];
    if (argc > 3) reduce_path   = argv[3];
    if (argc > 4) count_path    = argv[4];

    std::string scan_add_wgsl = read_wgsl_file(scan_add_path);
    std::string scan_wgsl     = read_wgsl_file(scan_path);
    std::string reduce_wgsl   = read_wgsl_file(reduce_path);
    std::string count_wgsl    = read_wgsl_file(count_path);
    if (scan_add_wgsl.empty() || scan_wgsl.empty()
            || reduce_wgsl.empty() || count_wgsl.empty()) {
        std::cerr << "Failed to read WGSL\n"; return EXIT_FAILURE;
    }

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
    auto buf_reduced = h.alloc(kSortReducedLen * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    // ─── Chain: count → reduce → scan → scan_add ──────────────────────
    auto pipe_count    = h.load_compute(count_wgsl,    "main");
    auto pipe_reduce   = h.load_compute(reduce_wgsl,   "main");
    auto pipe_scan     = h.load_compute(scan_wgsl,     "main");
    auto pipe_scan_add = h.load_compute(scan_add_wgsl, "main");
    if (pipe_count == nullptr || pipe_reduce == nullptr
            || pipe_scan == nullptr || pipe_scan_add == nullptr) {
        std::cerr << "load_compute null\n"; return EXIT_FAILURE;
    }
    h.dispatch(pipe_count,    { buf_config, buf_num_keys, buf_src, buf_counts },
               kSortNumBlocks, 1, 1);
    h.dispatch(pipe_reduce,   { buf_num_keys, buf_counts, buf_reduced },
               kSortNumReduceWgs, 1, 1);
    h.dispatch(pipe_scan,     { buf_num_keys, buf_reduced },
               1, 1, 1);
    h.dispatch(pipe_scan_add, { buf_num_keys, buf_reduced, buf_counts },
               kSortNumReduceWgs, 1, 1);

    // ─── Readback ─────────────────────────────────────────────────────
    const size_t counts_bytes = kSortCountsLen * sizeof(uint32_t);
    auto staging = h.alloc_staging_for_readback(counts_bytes);
    h.copy_to_staging(buf_counts, staging, counts_bytes);
    auto out = h.readback(staging, counts_bytes);
    std::vector<uint32_t> counts(kSortCountsLen);
    std::memcpy(counts.data(), out.data(), counts_bytes);

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_sort_scan_add ===\n";
    std::cout << "N = " << num_keys << '\n';
    std::cout << "counts (post scan_add): ";
    for (auto x : counts) std::cout << x << ' ';
    std::cout << '\n';

    // (1) All entries should be < N (offsets are bounded by sort domain).
    uint32_t max_v = 0, nonzero = 0;
    for (auto x : counts) {
        if (x > max_v) max_v = x;
        if (x != 0) ++nonzero;
    }
    std::cout << "max = " << max_v << ", nonzero entries = " << nonzero << '\n';
    if (max_v >= num_keys) {
        std::cerr << "FAIL: max counts " << max_v << " >= N=" << num_keys
                  << " — offset arithmetic broken\n";
        return EXIT_FAILURE;
    }
    if (nonzero == 0) {
        std::cerr << "FAIL: all counts zero — scan_add didn't write\n";
        return EXIT_FAILURE;
    }

    // (2) Monotone non-decreasing across the 16-entry counts buffer.
    //     For num_blocks=1 the buffer is [bin0_block0, bin1_block0, ...]
    //     and each entry is the global offset for that bin's block 0
    //     (the running scan total) → monotone is the correct invariant.
    for (uint32_t i = 1; i < kSortCountsLen; ++i) {
        if (counts[i] < counts[i - 1]) {
            std::cerr << "FAIL: counts not monotone at idx " << i
                      << ": " << counts[i - 1] << " -> " << counts[i] << '\n';
            return EXIT_FAILURE;
        }
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
