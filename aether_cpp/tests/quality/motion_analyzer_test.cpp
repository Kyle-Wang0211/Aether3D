// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/motion_analyzer.h"

#include <cmath>
#include <cstdint>
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

// ---------------------------------------------------------------------------
// Basic construction and null safety
// ---------------------------------------------------------------------------

static void test_null_image() {
    aether::quality::MotionAnalyzer analyzer(10);
    auto r = analyzer.analyze_frame(nullptr, 16, 16);
    CHECK(near(r.score, 0.0));
    CHECK(!r.is_fast_pan);
    CHECK(!r.is_hand_shake);
}

static void test_zero_dimensions() {
    aether::quality::MotionAnalyzer analyzer(10);
    std::uint8_t data[1] = {128};
    auto r = analyzer.analyze_frame(data, 0, 0);
    CHECK(near(r.score, 0.0));
}

static void test_first_frame_zero_score() {
    // First frame has no previous => score must be 0
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 128);
    aether::quality::MotionAnalyzer analyzer(10);
    auto r = analyzer.analyze_frame(img.data(), w, h);
    CHECK(near(r.score, 0.0));
}

static void test_identical_frames_zero_motion() {
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 100);
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(img.data(), w, h);  // First frame
    auto r = analyzer.analyze_frame(img.data(), w, h);  // Second frame
    CHECK(near(r.score, 0.0));
    CHECK(!r.is_fast_pan);
}

static void test_high_motion_score() {
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> frame1(static_cast<std::size_t>(w * h), 0);
    std::vector<std::uint8_t> frame2(static_cast<std::size_t>(w * h), 255);
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(frame1.data(), w, h);
    auto r = analyzer.analyze_frame(frame2.data(), w, h);
    CHECK(r.score > 0.5);  // Dramatic change => high score
    CHECK(std::isfinite(r.score));
    CHECK(r.score <= 1.0);
}

// ---------------------------------------------------------------------------
// NaN guard test: all-black frames (centroid weight ~ 0)
// ---------------------------------------------------------------------------

static void test_all_black_frames_no_nan() {
    constexpr int w = 32;
    constexpr int h = 32;
    std::vector<std::uint8_t> black(static_cast<std::size_t>(w * h), 0);
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(black.data(), w, h);
    auto r = analyzer.analyze_frame(black.data(), w, h);
    CHECK(std::isfinite(r.score));
    CHECK(near(r.score, 0.0));
}

static void test_nearly_black_frames_no_nan() {
    // One bright pixel in corner — weighted_current > 0 but very small
    constexpr int w = 32;
    constexpr int h = 32;
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(w * h), 0);
    frame[0] = 1;  // Tiny weight — triggers the >= 1.0 guard
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(frame.data(), w, h);
    auto r = analyzer.analyze_frame(frame.data(), w, h);
    CHECK(std::isfinite(r.score));
}

// ---------------------------------------------------------------------------
// Fast pan detection
// ---------------------------------------------------------------------------

static void test_fast_pan_horizontal_shift() {
    constexpr int w = 64;
    constexpr int h = 64;
    // Frame 1: left half bright, right half dark
    std::vector<std::uint8_t> f1(static_cast<std::size_t>(w * h), 0);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w / 2; ++x) {
            f1[static_cast<std::size_t>(y * w + x)] = 200;
        }
    }
    // Frame 2: shifted — right half bright, left half dark
    std::vector<std::uint8_t> f2(static_cast<std::size_t>(w * h), 0);
    for (int y = 0; y < h; ++y) {
        for (int x = w / 2; x < w; ++x) {
            f2[static_cast<std::size_t>(y * w + x)] = 200;
        }
    }
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(f1.data(), w, h);
    auto r = analyzer.analyze_frame(f2.data(), w, h);
    CHECK(r.score > 0.0);
    // The centroid shift is large enough to trigger fast pan
    CHECK(r.is_fast_pan);
}

// ---------------------------------------------------------------------------
// Dimension change resets
// ---------------------------------------------------------------------------

static void test_dimension_change_resets() {
    constexpr int w1 = 16;
    constexpr int h1 = 16;
    constexpr int w2 = 32;
    constexpr int h2 = 32;
    std::vector<std::uint8_t> small(static_cast<std::size_t>(w1 * h1), 128);
    std::vector<std::uint8_t> large(static_cast<std::size_t>(w2 * h2), 0);
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(small.data(), w1, h1);
    // Change dimensions => treated as first frame
    auto r = analyzer.analyze_frame(large.data(), w2, h2);
    CHECK(near(r.score, 0.0));
}

// ---------------------------------------------------------------------------
// analyze_quality
// ---------------------------------------------------------------------------

static void test_analyze_quality_empty() {
    aether::quality::MotionAnalyzer analyzer(10);
    auto m = analyzer.analyze_quality(0);
    CHECK(near(m.value, 0.0));
    CHECK(near(m.confidence, 0.85));
}

static void test_analyze_quality_levels() {
    aether::quality::MotionAnalyzer analyzer(10);
    auto m0 = analyzer.analyze_quality(0);
    auto m1 = analyzer.analyze_quality(1);
    auto m2 = analyzer.analyze_quality(2);
    CHECK(m0.confidence > m1.confidence);
    CHECK(m1.confidence > m2.confidence);
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

static void test_reset() {
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 100);
    aether::quality::MotionAnalyzer analyzer(10);
    analyzer.analyze_frame(img.data(), w, h);
    analyzer.reset();
    // After reset, next frame is treated as first
    auto r = analyzer.analyze_frame(img.data(), w, h);
    CHECK(near(r.score, 0.0));
}

int main() {
    test_null_image();
    test_zero_dimensions();
    test_first_frame_zero_score();
    test_identical_frames_zero_motion();
    test_high_motion_score();
    test_all_black_frames_no_nan();
    test_nearly_black_frames_no_nan();
    test_fast_pan_horizontal_shift();
    test_dimension_change_resets();
    test_analyze_quality_empty();
    test_analyze_quality_levels();
    test_reset();

    if (g_failed == 0) {
        std::fprintf(stdout, "motion_analyzer_test: all tests passed\n");
    }
    return g_failed;
}
