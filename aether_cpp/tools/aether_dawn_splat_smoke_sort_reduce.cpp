// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5a smoke test — Brush sort_reduce.wgsl on Dawn.
//
// Second kernel of Brush 4-bit radix sort. Sums counts within block-groups
// to produce per-bin reduced sums.
//
// Chains sort_count → sort_reduce so we can verify reduce against a known
// histogram sum (sum(reduced) should equal N for our small N=256 case
// because num_reduce_wgs_per_bin = 1 → reduced[bin] = counts[bin][0..1024]
// where only entry [0] has data).
//
// What this verifies:
//   1. sort_reduce.wgsl compiles via Tint (loop + workgroupBarrier paths)
//   2. 3-buffer @group(0) bind layout valid
//   3. sum(reduced) == sum(counts) == N (element conservation across reduce)
//   4. No reduced entry exceeds N (sanity)

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

    // Args: argv[1] = sort_reduce.wgsl, argv[2] = sort_count.wgsl
    std::string reduce_path = "aether_cpp/shaders/wgsl/sort_reduce.wgsl";
    std::string count_path  = "aether_cpp/shaders/wgsl/sort_count.wgsl";
    if (argc > 1) reduce_path = argv[1];
    if (argc > 2) count_path  = argv[2];

    std::string reduce_wgsl = read_wgsl_file(reduce_path);
    std::string count_wgsl  = read_wgsl_file(count_path);
    if (reduce_wgsl.empty() || count_wgsl.empty()) {
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

    // ─── Compile both pipelines before dispatching ────────────────────
    auto pipe_count  = h.load_compute(count_wgsl,  "main");
    auto pipe_reduce = h.load_compute(reduce_wgsl, "main");
    if (pipe_count == nullptr || pipe_reduce == nullptr) {
        std::cerr << "load_compute null\n"; return EXIT_FAILURE;
    }
    // Step 1: sort_count → counts.
    h.dispatch(pipe_count, { buf_config, buf_num_keys, buf_src, buf_counts },
               kSortNumBlocks, 1, 1);
    // Step 2: sort_reduce → reduced.
    h.dispatch(pipe_reduce, { buf_num_keys, buf_counts, buf_reduced },
               kSortNumReduceWgs, 1, 1);

    // ─── Readback both ────────────────────────────────────────────────
    const size_t counts_bytes  = kSortCountsLen  * sizeof(uint32_t);
    const size_t reduced_bytes = kSortReducedLen * sizeof(uint32_t);
    auto staging_c = h.alloc_staging_for_readback(counts_bytes);
    auto staging_r = h.alloc_staging_for_readback(reduced_bytes);
    h.copy_to_staging(buf_counts,  staging_c, counts_bytes);
    h.copy_to_staging(buf_reduced, staging_r, reduced_bytes);
    auto out_c = h.readback(staging_c, counts_bytes);
    auto out_r = h.readback(staging_r, reduced_bytes);

    std::vector<uint32_t> counts(kSortCountsLen), reduced(kSortReducedLen);
    std::memcpy(counts.data(),  out_c.data(), counts_bytes);
    std::memcpy(reduced.data(), out_r.data(), reduced_bytes);

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_sort_reduce ===\n";
    std::cout << "N = " << num_keys
              << ", num_reduce_wgs = " << kSortNumReduceWgs << '\n';

    uint32_t sum_counts = 0, sum_reduced = 0, max_reduced = 0;
    for (auto x : counts)  sum_counts  += x;
    for (auto x : reduced) {
        sum_reduced += x;
        if (x > max_reduced) max_reduced = x;
    }
    std::cout << "reduced: ";
    for (auto x : reduced) std::cout << x << ' ';
    std::cout << "\nsum(counts)  = " << sum_counts << '\n';
    std::cout << "sum(reduced) = " << sum_reduced << " (expected " << num_keys << ")\n";

    if (sum_counts != num_keys) {
        std::cerr << "FAIL: sum(counts) != N — sort_count regression\n";
        return EXIT_FAILURE;
    }
    if (sum_reduced != num_keys) {
        std::cerr << "FAIL: sum(reduced) != N — sort_reduce broke conservation\n";
        return EXIT_FAILURE;
    }
    if (max_reduced == 0) {
        std::cerr << "FAIL: all reduced zero — kernel didn't write\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
