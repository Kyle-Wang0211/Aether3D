// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/deterministic_triangulator.h"

#include <cmath>
#include <cstdio>
#include <vector>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

static bool near(double a, double b, double eps = 1e-6) {
    return std::fabs(a - b) <= eps;
}

static double tri_area(const aether::quality::Triangle2d& t) {
    return 0.5 * std::fabs(
        (t.b.x - t.a.x) * (t.c.y - t.a.y) -
        (t.c.x - t.a.x) * (t.b.y - t.a.y));
}

// ---------------------------------------------------------------------------
// triangulate_quad
// ---------------------------------------------------------------------------

static void test_quad_unit_square() {
    using namespace aether::quality;
    Point2d quad[4] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
    Triangle2d out[2] = {};
    CHECK(triangulate_quad(quad, 1e-9, out) == aether::core::Status::kOk);
    // Two triangles covering the unit square: total area = 1.0
    const double total = tri_area(out[0]) + tri_area(out[1]);
    CHECK(near(total, 1.0, 1e-6));
}

static void test_quad_degenerate_line() {
    using namespace aether::quality;
    // All four points collinear
    Point2d quad[4] = {{0, 0}, {1, 0}, {2, 0}, {3, 0}};
    Triangle2d out[2] = {};
    auto s = triangulate_quad(quad, 1e-9, out);
    // Should return kOk but with zero-area triangles
    CHECK(s == aether::core::Status::kOk);
    CHECK(tri_area(out[0]) < 1e-6);
    CHECK(tri_area(out[1]) < 1e-6);
}

static void test_quad_nullptr() {
    using namespace aether::quality;
    Point2d quad[4] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
    Triangle2d out[2] = {};
    CHECK(triangulate_quad(nullptr, 1e-9, out) ==
          aether::core::Status::kInvalidArgument);
    CHECK(triangulate_quad(quad, 1e-9, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

// ---------------------------------------------------------------------------
// sort_triangles — deterministic ordering
// ---------------------------------------------------------------------------

static void test_sort_determinism() {
    using namespace aether::quality;
    // Two triangles in different order should produce same sorted output
    Triangle2d a{{0, 0}, {1, 0}, {0, 1}};
    Triangle2d b{{2, 2}, {3, 2}, {2, 3}};

    std::vector<Triangle2d> sorted1;
    std::vector<Triangle2d> sorted2;

    // Order 1: a, b
    {
        Triangle2d input[2] = {a, b};
        CHECK(sort_triangles(input, 2, 1e-9, &sorted1) ==
              aether::core::Status::kOk);
    }
    // Order 2: b, a
    {
        Triangle2d input[2] = {b, a};
        CHECK(sort_triangles(input, 2, 1e-9, &sorted2) ==
              aether::core::Status::kOk);
    }

    CHECK(sorted1.size() == 2u);
    CHECK(sorted2.size() == 2u);
    // Same ordering regardless of input order
    CHECK(sorted1[0].a == sorted2[0].a);
    CHECK(sorted1[0].b == sorted2[0].b);
    CHECK(sorted1[1].a == sorted2[1].a);
    CHECK(sorted1[1].b == sorted2[1].b);
}

static void test_sort_empty() {
    using namespace aether::quality;
    std::vector<Triangle2d> sorted;
    CHECK(sort_triangles(nullptr, 0, 1e-9, &sorted) ==
          aether::core::Status::kOk);
    CHECK(sorted.empty());
}

static void test_sort_single() {
    using namespace aether::quality;
    Triangle2d t{{0, 0}, {1, 0}, {0, 1}};
    std::vector<Triangle2d> sorted;
    CHECK(sort_triangles(&t, 1, 1e-9, &sorted) ==
          aether::core::Status::kOk);
    CHECK(sorted.size() == 1u);
}

static void test_sort_null_output() {
    using namespace aether::quality;
    Triangle2d t{{0, 0}, {1, 0}, {0, 1}};
    CHECK(sort_triangles(&t, 1, 1e-9, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

int main() {
    test_quad_unit_square();
    test_quad_degenerate_line();
    test_quad_nullptr();
    test_sort_determinism();
    test_sort_empty();
    test_sort_single();
    test_sort_null_output();

    if (g_failed == 0) {
        std::fprintf(stdout, "deterministic_triangulator_test: all tests passed\n");
    }
    return g_failed;
}
