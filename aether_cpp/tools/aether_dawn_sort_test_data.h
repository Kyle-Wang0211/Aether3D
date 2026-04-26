// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TOOLS_AETHER_DAWN_SORT_TEST_DATA_H
#define AETHER_CPP_TOOLS_AETHER_DAWN_SORT_TEST_DATA_H

// ─── Phase 6.3a Step 5a — shared sort-pipeline test data ───────────────
//
// 5 sort smokes need similar setup: hand-crafted u32 keys, repeatable
// random sequence, and the ability to chain prior kernels (e.g. sort_reduce
// needs counts produced by sort_count). This header provides:
//
//   - kSortBlockSize / kSortBinCount / kSortWG — Brush sort constants
//   - make_test_keys()   — deterministic random key set, 4-bit-rich
//   - make_test_values() — payload values matching keys (for sort_scatter)
//   - read_wgsl_file()   — common file loader
//   - any_nan_or_inf()   — common float-buffer checker
//
// Sort kernel layout (Brush 4-bit-per-pass radix):
//   sort_count:    src[N] → counts[BIN_COUNT * num_blocks]
//   sort_reduce:   counts → reduced[BIN_COUNT * num_reduce_wgs_per_bin]
//   sort_scan:     reduced (in-place exclusive scan)
//   sort_scan_add: counts (in-place += reduced offsets)
//   sort_scatter:  src,values,counts → out,out_values
//
// For our smoke tests we use N = kSortN = 256 keys (one block, simplest
// path through the kernels — engages the bounds checks but only one
// workgroup of work per kernel).

#include <cstdint>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace aether {
namespace tools {
namespace sort_test_data {

constexpr uint32_t kSortBlockSize = 1024u;
constexpr uint32_t kSortBinCount = 16u;
constexpr uint32_t kSortWG = 256u;
constexpr uint32_t kSortElementsPerThread = 4u;

// 256 keys: small but exercises bounds checks (< BLOCK_SIZE=1024).
constexpr uint32_t kSortN = 256u;
// num_blocks = ceil(N / BLOCK_SIZE) = 1
constexpr uint32_t kSortNumBlocks = 1u;
// num_reduce_wgs_per_bin = ceil(num_blocks / BLOCK_SIZE) = 1
constexpr uint32_t kSortNumReduceWgsPerBin = 1u;
// num_reduce_wgs = BIN_COUNT * num_reduce_wgs_per_bin = 16
constexpr uint32_t kSortNumReduceWgs = kSortBinCount * kSortNumReduceWgsPerBin;

// Counts buffer length = BIN_COUNT * num_blocks
constexpr uint32_t kSortCountsLen = kSortBinCount * kSortNumBlocks;
// Reduced buffer length = num_reduce_wgs
constexpr uint32_t kSortReducedLen = kSortNumReduceWgs;

// Deterministic random keys covering all 4-bit bins. seed=42 is the
// canonical "deterministic but not all zeros" choice, reusing the same
// keys across all 5 smokes keeps cross-smoke chained validation cheap.
inline std::vector<uint32_t> make_test_keys() {
    std::mt19937 rng(42);
    std::uniform_int_distribution<uint32_t> dist(0, UINT32_MAX);
    std::vector<uint32_t> keys(kSortN);
    for (auto& k : keys) k = dist(rng);
    return keys;
}

// Payload values matching keys 1:1 — for sort_scatter, after sorting
// keys, the values must follow (i.e. value[i] tracks original key[i]).
// We use values = original_index, so post-scatter we can reconstruct
// the permutation and verify element conservation.
inline std::vector<uint32_t> make_test_values() {
    std::vector<uint32_t> v(kSortN);
    for (uint32_t i = 0; i < kSortN; ++i) v[i] = i;
    return v;
}

// Load WGSL file, abort on failure (smoke tests fail loud).
inline std::string read_wgsl_file(const std::string& path) {
    std::ifstream in(path);
    if (!in) return {};
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

}  // namespace sort_test_data
}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_AETHER_DAWN_SORT_TEST_DATA_H
