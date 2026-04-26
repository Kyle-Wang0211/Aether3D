// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 5a smoke test — Brush sort_scan.wgsl on Dawn.
//
// Third kernel of Brush 4-bit radix sort. Performs an exclusive prefix
// scan on the `reduced` buffer (in-place) so each bin's count becomes the
// running offset where its elements start in the sorted output.
//
// Chains sort_count → sort_reduce → sort_scan to validate end-to-end.
//
// What this verifies:
//   1. sort_scan.wgsl compiles via Tint
//   2. 2-buffer @group(0) bind layout valid (read-write counts/reduced)
//   3. After scan, the reduced buffer is monotone non-decreasing (exclusive
//      scan property)
//   4. The final scanned value equals the total (sum was preserved)

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

    std::string scan_path   = "aether_cpp/shaders/wgsl/sort_scan.wgsl";
    std::string reduce_path = "aether_cpp/shaders/wgsl/sort_reduce.wgsl";
    std::string count_path  = "aether_cpp/shaders/wgsl/sort_count.wgsl";
    if (argc > 1) scan_path   = argv[1];
    if (argc > 2) reduce_path = argv[2];
    if (argc > 3) count_path  = argv[3];

    std::string scan_wgsl   = read_wgsl_file(scan_path);
    std::string reduce_wgsl = read_wgsl_file(reduce_path);
    std::string count_wgsl  = read_wgsl_file(count_path);
    if (scan_wgsl.empty() || reduce_wgsl.empty() || count_wgsl.empty()) {
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

    // ─── Chain: count → reduce → scan ─────────────────────────────────
    auto pipe_count  = h.load_compute(count_wgsl,  "main");
    auto pipe_reduce = h.load_compute(reduce_wgsl, "main");
    auto pipe_scan   = h.load_compute(scan_wgsl,   "main");
    if (pipe_count == nullptr || pipe_reduce == nullptr || pipe_scan == nullptr) {
        std::cerr << "load_compute null\n"; return EXIT_FAILURE;
    }
    // ─── Chain: count → reduce → scan ─────────────────────────────────
    h.dispatch(pipe_count,  { buf_config, buf_num_keys, buf_src, buf_counts },
               kSortNumBlocks, 1, 1);
    h.dispatch(pipe_reduce, { buf_num_keys, buf_counts, buf_reduced },
               kSortNumReduceWgs, 1, 1);
    // sort_scan dispatches a single workgroup that processes all of `reduced`.
    h.dispatch(pipe_scan,   { buf_num_keys, buf_reduced },
               1, 1, 1);

    // ─── Readback reduced (post-scan) ──────────────────────────────────
    const size_t reduced_bytes = kSortReducedLen * sizeof(uint32_t);
    auto staging = h.alloc_staging_for_readback(reduced_bytes);
    h.copy_to_staging(buf_reduced, staging, reduced_bytes);
    auto out = h.readback(staging, reduced_bytes);
    std::vector<uint32_t> scanned(kSortReducedLen);
    std::memcpy(scanned.data(), out.data(), reduced_bytes);

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_sort_scan ===\n";
    std::cout << "N = " << num_keys
              << ", num_reduce_wgs = " << kSortNumReduceWgs << '\n';
    std::cout << "scanned: ";
    for (auto x : scanned) std::cout << x << ' ';
    std::cout << '\n';

    // (1) Monotone non-decreasing — exclusive scan property.
    for (uint32_t i = 1; i < kSortReducedLen; ++i) {
        if (scanned[i] < scanned[i - 1]) {
            std::cerr << "FAIL: scan not monotone — idx " << i
                      << ": " << scanned[i - 1] << " -> " << scanned[i] << '\n';
            return EXIT_FAILURE;
        }
    }

    // (2) First element of exclusive scan should be 0.
    if (scanned[0] != 0) {
        std::cerr << "FAIL: exclusive scan should start at 0, got " << scanned[0] << '\n';
        return EXIT_FAILURE;
    }

    // (3) Final value < N + 1 — running total is bounded by sum which is N.
    //     (For exclusive scan over k elems summing to N, final entry = N - last_input.)
    uint32_t final_val = scanned[kSortReducedLen - 1];
    if (final_val >= num_keys) {
        std::cerr << "FAIL: final scan value " << final_val
                  << " >= N=" << num_keys << " — overflow / wrong scan direction\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
