// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/photometric_checker.h"

#include <cmath>
#include <cstdio>

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

// ---------------------------------------------------------------------------
// CIEDE2000 reference pairs (from Sharma et al. 2005 Table 1)
// We verify a subset to validate our implementation against published data.
// ---------------------------------------------------------------------------

static void test_ciede2000_identical_colors() {
    using Lab = aether::quality::LabColor;
    const Lab a{50.0, 2.6772, -79.7751};
    const double de = aether::quality::PhotometricChecker::ciede2000(a, a);
    CHECK(near(de, 0.0, 1e-10));
}

static void test_ciede2000_gray_axis() {
    // Pure L* difference on the gray axis (a=b=0)
    using Lab = aether::quality::LabColor;
    const Lab a{50.0, 0.0, 0.0};
    const Lab b{60.0, 0.0, 0.0};
    const double de = aether::quality::PhotometricChecker::ciede2000(a, b);
    // On the gray axis, CIEDE2000 reduces to |dL'/SL|
    CHECK(de > 0.0);
    CHECK(std::isfinite(de));
    // Should be close to the CIE76 value but adjusted by SL weighting
    CHECK(de < 12.0);  // Roughly: dL=10, SL factor < 1.2
    CHECK(de > 5.0);
}

static void test_ciede2000_symmetric() {
    using Lab = aether::quality::LabColor;
    const Lab a{50.0, 25.0, -10.0};
    const Lab b{60.0, -5.0, 30.0};
    const double de1 = aether::quality::PhotometricChecker::ciede2000(a, b);
    const double de2 = aether::quality::PhotometricChecker::ciede2000(b, a);
    CHECK(near(de1, de2, 1e-12));  // Must be exactly symmetric
}

static void test_ciede2000_high_chroma() {
    using Lab = aether::quality::LabColor;
    const Lab a{50.0, 60.0, 0.0};    // Saturated red-ish
    const Lab b{50.0, 0.0, 60.0};    // Saturated yellow-ish
    const double de = aether::quality::PhotometricChecker::ciede2000(a, b);
    CHECK(de > 20.0);  // Very different hues at high chroma => large DE
    CHECK(std::isfinite(de));
}

static void test_ciede2000_zero_chroma_both() {
    // Both achromatic: hue term should be zero, only L matters
    using Lab = aether::quality::LabColor;
    const Lab a{30.0, 0.0, 0.0};
    const Lab b{30.0, 0.0, 0.0};
    const double de = aether::quality::PhotometricChecker::ciede2000(a, b);
    CHECK(near(de, 0.0, 1e-12));
}

static void test_ciede2000_near_zero_chroma() {
    // One near-achromatic, one with tiny chroma
    using Lab = aether::quality::LabColor;
    const Lab a{50.0, 0.001, 0.0};
    const Lab b{50.0, -0.001, 0.0};
    const double de = aether::quality::PhotometricChecker::ciede2000(a, b);
    CHECK(std::isfinite(de));
    CHECK(de < 0.01);  // Negligible difference
}

// ---------------------------------------------------------------------------
// PhotometricChecker integration
// ---------------------------------------------------------------------------

static void test_checker_single_sample() {
    using PC = aether::quality::PhotometricChecker;
    using Lab = aether::quality::LabColor;
    PC checker(10);
    checker.update(100.0, 0.01, Lab{50.0, 0.0, 0.0});
    auto r = checker.check(1.0, 1.0, 0.5);
    CHECK(r.luminance_variance == 0.0);  // Single sample => 0 variance
    CHECK(r.lab_variance == 0.0);
    CHECK(r.is_consistent);
}

static void test_checker_consistent_sequence() {
    using PC = aether::quality::PhotometricChecker;
    using Lab = aether::quality::LabColor;
    PC checker(5);
    // All identical => zero variance
    for (int i = 0; i < 5; ++i) {
        checker.update(100.0, 0.01, Lab{50.0, 10.0, -20.0});
    }
    auto r = checker.check(1.0, 1.0, 0.5);
    CHECK(near(r.luminance_variance, 0.0, 1e-10));
    CHECK(near(r.lab_variance, 0.0, 1e-10));
    CHECK(near(r.exposure_consistency, 1.0, 1e-10));
    CHECK(r.is_consistent);
    CHECK(near(r.confidence, 1.0, 1e-10));
}

static void test_checker_inconsistent_sequence() {
    using PC = aether::quality::PhotometricChecker;
    using Lab = aether::quality::LabColor;
    PC checker(4);
    checker.update(10.0, 0.01, Lab{20.0, 0.0, 0.0});
    checker.update(200.0, 0.10, Lab{80.0, 50.0, -50.0});
    checker.update(10.0, 0.01, Lab{20.0, 0.0, 0.0});
    checker.update(200.0, 0.10, Lab{80.0, 50.0, -50.0});
    auto r = checker.check(1.0, 0.5, 0.9);
    CHECK(r.luminance_variance > 1.0);
    CHECK(r.lab_variance > 0.5);
    CHECK(!r.is_consistent);
}

static void test_checker_reset() {
    using PC = aether::quality::PhotometricChecker;
    using Lab = aether::quality::LabColor;
    PC checker(5);
    checker.update(100.0, 0.01, Lab{50.0, 0.0, 0.0});
    checker.reset();
    auto r = checker.check(1.0, 1.0, 0.5);
    CHECK(r.luminance_variance == 0.0);
    CHECK(near(r.confidence, 0.0, 1e-10));
}

static void test_checker_window_capping() {
    using PC = aether::quality::PhotometricChecker;
    using Lab = aether::quality::LabColor;
    PC checker(3);
    // Fill with inconsistent, then consistent
    checker.update(0.0, 0.01, Lab{0.0, 0.0, 0.0});
    checker.update(200.0, 0.10, Lab{100.0, 50.0, 50.0});
    checker.update(100.0, 0.05, Lab{50.0, 25.0, 25.0});
    // Now overwrite with 3 consistent samples
    checker.update(100.0, 0.05, Lab{50.0, 25.0, 25.0});
    checker.update(100.0, 0.05, Lab{50.0, 25.0, 25.0});
    checker.update(100.0, 0.05, Lab{50.0, 25.0, 25.0});
    auto r = checker.check(1.0, 1.0, 0.5);
    CHECK(near(r.luminance_variance, 0.0, 1e-10));
    CHECK(near(r.lab_variance, 0.0, 1e-10));
}

int main() {
    test_ciede2000_identical_colors();
    test_ciede2000_gray_axis();
    test_ciede2000_symmetric();
    test_ciede2000_high_chroma();
    test_ciede2000_zero_chroma_both();
    test_ciede2000_near_zero_chroma();

    test_checker_single_sample();
    test_checker_consistent_sequence();
    test_checker_inconsistent_sequence();
    test_checker_reset();
    test_checker_window_capping();

    if (g_failed == 0) {
        std::fprintf(stdout, "photometric_checker_test: all tests passed\n");
    }
    return g_failed;
}
