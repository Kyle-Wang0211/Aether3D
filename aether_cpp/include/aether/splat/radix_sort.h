// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_RADIX_SORT_H
#define AETHER_CPP_SPLAT_RADIX_SORT_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// CPU Radix Sort: Reference implementation for unit testing
// ═══════════════════════════════════════════════════════════════════════
// Algorithm source: gsplat.js wasm/sort.cpp (MIT)
//
// This is the CPU fallback / reference implementation. In production,
// GPU radix sort (GaussianSplat.metal) is used for performance.
// CPU version is kept for:
//   1. Unit test validation (compare against GPU results)
//   2. Headless/NullGPUDevice scenarios
//
// Sort by depth (key) and produce a permutation index array.
// Uses 8-bit radix (256 buckets), 4 passes for 32-bit keys.

/// Sort depth values and produce sorted index permutation.
///
/// Parameters:
///   depths      — array of float depth values (view-space z)
///   count       — number of elements
///   out_indices — output: sorted index permutation (caller-allocated, count elements)
///   temp_buffer — temporary workspace (caller-allocated, count * sizeof(uint32_t))
///
/// After sorting, out_indices[0] is the index of the nearest splat,
/// out_indices[count-1] is the farthest.
inline void radix_sort_by_depth(const float* depths,
                                 std::size_t count,
                                 std::uint32_t* out_indices,
                                 std::uint32_t* temp_buffer) noexcept {
    if (count == 0) return;
    if (count == 1) { out_indices[0] = 0; return; }

    // Initialize indices
    for (std::size_t i = 0; i < count; ++i) {
        out_indices[i] = static_cast<std::uint32_t>(i);
    }

    // Convert float depths to sortable uint32 keys.
    // IEEE 754 floats can be sorted as integers with sign bit manipulation:
    //   positive: flip sign bit (0x80000000)
    //   negative: flip all bits (~)
    // This gives correct numerical ordering as unsigned integers.

    // Allocate key arrays (reuse temp_buffer for keys, need separate for swap)
    auto* keys_a = temp_buffer;
    // We need an extra buffer for key swap — use second half of a larger temp
    // For simplicity, encode keys in-place in out_indices pattern
    // Actually, let's use a cleaner 4-pass approach:

    // Encode depths as sortable uint32 keys
    for (std::size_t i = 0; i < count; ++i) {
        std::uint32_t bits;
        std::memcpy(&bits, &depths[i], sizeof(bits));
        // Float-to-sortable-uint conversion
        if (bits & 0x80000000u) {
            bits = ~bits;  // Negative: flip all bits
        } else {
            bits ^= 0x80000000u;  // Positive: flip sign bit
        }
        keys_a[i] = bits;
    }

    // 4-pass radix sort (8 bits per pass, LSB first)
    constexpr int kRadixBits = 8;
    constexpr int kBuckets = 1 << kRadixBits;  // 256
    constexpr int kPasses = 4;  // 32-bit / 8-bit = 4 passes

    // We need swap buffers for keys and indices
    // Use stack allocation for histogram (small)
    std::uint32_t histogram[kBuckets];

    // Ping-pong between original and temp arrays
    // For indices, we use out_indices as source and need a temp
    // We'll do an in-place sort by allocating a temporary index array
    // Limitation: this uses the temp_buffer for keys, we need another for indices swap
    // Solution: use interleaved passes that write back to source

    // Actually, for a proper 4-pass sort we need temp space for both keys and indices.
    // The caller provides temp_buffer with count elements.
    // We'll reuse memory carefully:
    //   keys_a (temp_buffer[0..count-1]): sortable keys
    //   We sort keys_a and out_indices together using counting sort per pass.

    // Temp storage for one pass of counting sort
    // We'll do each pass in-place by using histogram + scatter.
    // Need a destination buffer — we'll allocate on stack for small counts,
    // or use the second half of the key buffer for ping-pong.

    // For clean implementation: 4 passes, each pass uses counting sort.
    // We need temp arrays for keys and indices during each pass.
    // The minimal approach: allocate keys_b and indices_b dynamically.

    // Since we target no-exception C++ and this is a CPU reference impl,
    // we'll do a simpler two-buffer approach with temp_buffer split.

    // Note: For production GPU sort, this complexity doesn't apply.
    // This CPU version prioritizes correctness over peak efficiency.

    // Simple insertion sort for small arrays
    if (count <= 64) {
        for (std::size_t i = 1; i < count; ++i) {
            std::uint32_t key = keys_a[i];
            std::uint32_t idx = out_indices[i];
            std::size_t j = i;
            while (j > 0 && keys_a[j - 1] > key) {
                keys_a[j] = keys_a[j - 1];
                out_indices[j] = out_indices[j - 1];
                --j;
            }
            keys_a[j] = key;
            out_indices[j] = idx;
        }
        return;
    }

    // For larger arrays: 4-pass LSB radix sort with counting sort
    // We need a second buffer for keys and indices. Use new/nothrow.
    auto* keys_b = new (std::nothrow) std::uint32_t[count];
    auto* indices_b = new (std::nothrow) std::uint32_t[count];
    if (!keys_b || !indices_b) {
        // Fallback: insertion sort (slow but correct)
        delete[] keys_b;
        delete[] indices_b;
        for (std::size_t i = 1; i < count; ++i) {
            std::uint32_t key = keys_a[i];
            std::uint32_t idx = out_indices[i];
            std::size_t j = i;
            while (j > 0 && keys_a[j - 1] > key) {
                keys_a[j] = keys_a[j - 1];
                out_indices[j] = out_indices[j - 1];
                --j;
            }
            keys_a[j] = key;
            out_indices[j] = idx;
        }
        return;
    }

    std::uint32_t* src_keys = keys_a;
    std::uint32_t* dst_keys = keys_b;
    std::uint32_t* src_idx = out_indices;
    std::uint32_t* dst_idx = indices_b;

    for (int pass = 0; pass < kPasses; ++pass) {
        int shift = pass * kRadixBits;

        // Build histogram
        std::memset(histogram, 0, sizeof(histogram));
        for (std::size_t i = 0; i < count; ++i) {
            std::uint32_t bucket = (src_keys[i] >> shift) & 0xFFu;
            histogram[bucket]++;
        }

        // Prefix sum (exclusive)
        std::uint32_t total = 0;
        for (int b = 0; b < kBuckets; ++b) {
            std::uint32_t h = histogram[b];
            histogram[b] = total;
            total += h;
        }

        // Scatter
        for (std::size_t i = 0; i < count; ++i) {
            std::uint32_t bucket = (src_keys[i] >> shift) & 0xFFu;
            std::uint32_t dest = histogram[bucket]++;
            dst_keys[dest] = src_keys[i];
            dst_idx[dest] = src_idx[i];
        }

        // Swap ping-pong buffers
        std::uint32_t* tmp;
        tmp = src_keys; src_keys = dst_keys; dst_keys = tmp;
        tmp = src_idx;  src_idx = dst_idx;   dst_idx = tmp;
    }

    // After 4 passes (even number), result is in the original src_keys/src_idx.
    // Since we swapped after each pass, after pass 0,1,2,3 the result
    // is in the buffer that was dst at pass 3, which is src after swap = keys_a/out_indices.
    // Actually: pass 0 writes to keys_b/indices_b, swap → src=keys_b, dst=keys_a
    //           pass 1 writes to keys_a/out_indices, swap → src=keys_a, dst=keys_b
    //           pass 2 writes to keys_b/indices_b, swap → src=keys_b, dst=keys_a
    //           pass 3 writes to keys_a/out_indices, swap → src=keys_a, dst=keys_b
    // So after 4 passes, result is in keys_a/out_indices. Correct!

    // But src_keys might not be keys_a after the swaps. Let's verify:
    // Initial: src_keys=keys_a, dst_keys=keys_b
    // After pass 0 swap: src_keys=keys_b, dst_keys=keys_a
    // After pass 1 swap: src_keys=keys_a, dst_keys=keys_b
    // After pass 2 swap: src_keys=keys_b, dst_keys=keys_a
    // After pass 3 swap: src_keys=keys_a, dst_keys=keys_b
    // src_keys == keys_a == temp_buffer ✓
    // src_idx == out_indices ✓

    delete[] keys_b;
    delete[] indices_b;
}

/// Convenience: sort depths and return only indices.
/// Allocates temporary buffer internally.
inline bool radix_sort_by_depth(const float* depths,
                                 std::size_t count,
                                 std::uint32_t* out_indices) noexcept {
    if (count == 0) return true;
    auto* temp = new (std::nothrow) std::uint32_t[count];
    if (!temp) return false;
    radix_sort_by_depth(depths, count, out_indices, temp);
    delete[] temp;
    return true;
}

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_RADIX_SORT_H
