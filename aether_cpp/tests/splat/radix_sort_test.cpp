// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/radix_sort.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

using namespace aether::splat;

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

static void test_sort_empty() {
    std::uint32_t indices[1];
    // Should not crash
    radix_sort_by_depth(nullptr, 0, indices, nullptr);
}

static void test_sort_single() {
    float depths[1] = {3.14f};
    std::uint32_t indices[1];
    std::uint32_t temp[1];
    radix_sort_by_depth(depths, 1, indices, temp);
    CHECK(indices[0] == 0);
}

static void test_sort_two_elements() {
    float depths[2] = {5.0f, 2.0f};
    std::uint32_t indices[2];
    std::uint32_t temp[2];
    radix_sort_by_depth(depths, 2, indices, temp);

    // Sorted by depth: index 1 (2.0) before index 0 (5.0)
    CHECK(indices[0] == 1);
    CHECK(indices[1] == 0);
}

// ---------------------------------------------------------------------------
// Small arrays (insertion sort path, count ≤ 64)
// ---------------------------------------------------------------------------

static void test_sort_small_sorted() {
    float depths[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f};
    std::uint32_t indices[5];
    std::uint32_t temp[5];
    radix_sort_by_depth(depths, 5, indices, temp);

    for (int i = 0; i < 5; ++i) {
        CHECK(indices[i] == static_cast<std::uint32_t>(i));
    }
}

static void test_sort_small_reversed() {
    float depths[] = {5.0f, 4.0f, 3.0f, 2.0f, 1.0f};
    std::uint32_t indices[5];
    std::uint32_t temp[5];
    radix_sort_by_depth(depths, 5, indices, temp);

    for (int i = 0; i < 5; ++i) {
        CHECK(indices[i] == static_cast<std::uint32_t>(4 - i));
    }
}

static void test_sort_small_random() {
    float depths[] = {3.1f, 1.5f, 4.2f, 0.7f, 2.8f, 5.5f, 0.3f, 1.1f};
    constexpr std::size_t n = 8;
    std::uint32_t indices[n];
    std::uint32_t temp[n];
    radix_sort_by_depth(depths, n, indices, temp);

    // Verify sorted order
    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

static void test_sort_small_duplicates() {
    float depths[] = {2.0f, 2.0f, 1.0f, 3.0f, 1.0f};
    constexpr std::size_t n = 5;
    std::uint32_t indices[n];
    std::uint32_t temp[n];
    radix_sort_by_depth(depths, n, indices, temp);

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

static void test_sort_small_negative() {
    float depths[] = {-1.0f, 3.0f, -5.0f, 0.0f, 2.0f};
    constexpr std::size_t n = 5;
    std::uint32_t indices[n];
    std::uint32_t temp[n];
    radix_sort_by_depth(depths, n, indices, temp);

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }

    // First element should be -5.0
    CHECK(depths[indices[0]] == -5.0f);
    // Last should be 3.0
    CHECK(depths[indices[n - 1]] == 3.0f);
}

// ---------------------------------------------------------------------------
// Large arrays (radix sort path, count > 64)
// ---------------------------------------------------------------------------

static void test_sort_large_random() {
    constexpr std::size_t n = 1000;
    std::vector<float> depths(n);

    // Pseudo-random using LCG (deterministic, no std::rand dependency)
    std::uint32_t seed = 42;
    for (std::size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        // Map to [-100, 100]
        depths[i] = (static_cast<float>(seed) / 4294967295.0f) * 200.0f - 100.0f;
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    // Verify sorted order
    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }

    // Verify permutation (all indices used exactly once)
    std::vector<bool> seen(n, false);
    for (std::size_t i = 0; i < n; ++i) {
        CHECK(indices[i] < n);
        CHECK(!seen[indices[i]]);
        seen[indices[i]] = true;
    }
}

static void test_sort_large_sorted() {
    constexpr std::size_t n = 200;
    std::vector<float> depths(n);
    for (std::size_t i = 0; i < n; ++i) {
        depths[i] = static_cast<float>(i) * 0.1f;
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    for (std::size_t i = 0; i < n; ++i) {
        CHECK(indices[i] == static_cast<std::uint32_t>(i));
    }
}

static void test_sort_large_reversed() {
    constexpr std::size_t n = 200;
    std::vector<float> depths(n);
    for (std::size_t i = 0; i < n; ++i) {
        depths[i] = static_cast<float>(n - i);
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

static void test_sort_large_mixed_sign() {
    constexpr std::size_t n = 500;
    std::vector<float> depths(n);

    std::uint32_t seed = 12345;
    for (std::size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        depths[i] = (static_cast<float>(seed) / 4294967295.0f) * 20.0f - 10.0f;
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

// ---------------------------------------------------------------------------
// Convenience overload (self-allocating temp buffer)
// ---------------------------------------------------------------------------

static void test_sort_convenience_overload() {
    float depths[] = {3.0f, 1.0f, 4.0f, 1.0f, 5.0f, 9.0f, 2.0f, 6.0f};
    constexpr std::size_t n = 8;
    std::uint32_t indices[n];

    bool ok = radix_sort_by_depth(depths, n, indices);
    CHECK(ok);

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

static void test_sort_convenience_empty() {
    bool ok = radix_sort_by_depth(nullptr, 0, nullptr);
    CHECK(ok);
}

// ---------------------------------------------------------------------------
// Comparison with std::sort (correctness oracle)
// ---------------------------------------------------------------------------

static void test_sort_matches_std_sort() {
    constexpr std::size_t n = 300;
    std::vector<float> depths(n);

    std::uint32_t seed = 99999;
    for (std::size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        depths[i] = (static_cast<float>(seed) / 4294967295.0f) * 50.0f - 25.0f;
    }

    // Reference: std::sort on (depth, index) pairs
    std::vector<std::pair<float, std::uint32_t>> ref(n);
    for (std::size_t i = 0; i < n; ++i) {
        ref[i] = {depths[i], static_cast<std::uint32_t>(i)};
    }
    std::sort(ref.begin(), ref.end());

    // Our radix sort
    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    // Compare sorted depth values (not indices, due to stability differences)
    for (std::size_t i = 0; i < n; ++i) {
        CHECK(depths[indices[i]] == ref[i].first);
    }
}

// ---------------------------------------------------------------------------
// IEEE 754 special values
// ---------------------------------------------------------------------------

static void test_sort_with_zero() {
    float depths[] = {1.0f, 0.0f, -1.0f, 0.0f};
    constexpr std::size_t n = 4;
    std::uint32_t indices[n];
    std::uint32_t temp[n];
    radix_sort_by_depth(depths, n, indices, temp);

    CHECK(depths[indices[0]] == -1.0f);
    // 0.0 values next (two of them)
    CHECK(depths[indices[1]] == 0.0f);
    CHECK(depths[indices[2]] == 0.0f);
    CHECK(depths[indices[3]] == 1.0f);
}

// ---------------------------------------------------------------------------
// Boundary: exactly 64 elements (insertion sort boundary)
// ---------------------------------------------------------------------------

static void test_sort_boundary_64() {
    constexpr std::size_t n = 64;
    std::vector<float> depths(n);
    for (std::size_t i = 0; i < n; ++i) {
        depths[i] = static_cast<float>(n - i);
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

static void test_sort_boundary_65() {
    constexpr std::size_t n = 65;  // Just above insertion sort threshold → radix path
    std::vector<float> depths(n);
    for (std::size_t i = 0; i < n; ++i) {
        depths[i] = static_cast<float>(n - i);
    }

    std::vector<std::uint32_t> indices(n);
    std::vector<std::uint32_t> temp(n);
    radix_sort_by_depth(depths.data(), n, indices.data(), temp.data());

    for (std::size_t i = 1; i < n; ++i) {
        CHECK(depths[indices[i - 1]] <= depths[indices[i]]);
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    test_sort_empty();
    test_sort_single();
    test_sort_two_elements();

    test_sort_small_sorted();
    test_sort_small_reversed();
    test_sort_small_random();
    test_sort_small_duplicates();
    test_sort_small_negative();

    test_sort_large_random();
    test_sort_large_sorted();
    test_sort_large_reversed();
    test_sort_large_mixed_sign();

    test_sort_convenience_overload();
    test_sort_convenience_empty();

    test_sort_matches_std_sort();

    test_sort_with_zero();
    test_sort_boundary_64();
    test_sort_boundary_65();

    if (g_failed == 0) {
        std::fprintf(stdout, "radix_sort_test: all tests passed\n");
    }
    return g_failed;
}
