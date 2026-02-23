// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/image_metrics.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
// laplacian_variance
// ---------------------------------------------------------------------------

static void test_laplacian_null_output() {
    const std::uint8_t data[9] = {};
    CHECK(aether::quality::laplacian_variance(data, 3, 3, 3, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

static void test_laplacian_null_bytes() {
    double var = -1.0;
    CHECK(aether::quality::laplacian_variance(nullptr, 3, 3, 3, &var) ==
          aether::core::Status::kInvalidArgument);
}

static void test_laplacian_too_small() {
    double var = -1.0;
    const std::uint8_t data[4] = {};
    CHECK(aether::quality::laplacian_variance(data, 2, 2, 2, &var) ==
          aether::core::Status::kInvalidArgument);
}

static void test_laplacian_uniform_image() {
    // Uniform gray: Laplacian is 0 everywhere => variance = 0
    constexpr int w = 8;
    constexpr int h = 8;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 128);
    double var = -1.0;
    CHECK(aether::quality::laplacian_variance(img.data(), w, h, w, &var) ==
          aether::core::Status::kOk);
    CHECK(near(var, 0.0, 1e-10));
}

static void test_laplacian_sharp_edge() {
    // Left half 0, right half 255 => strong laplacian at edge => high variance
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 0);
    for (int y = 0; y < h; ++y) {
        for (int x = w / 2; x < w; ++x) {
            img[static_cast<std::size_t>(y * w + x)] = 255;
        }
    }
    double var = -1.0;
    CHECK(aether::quality::laplacian_variance(img.data(), w, h, w, &var) ==
          aether::core::Status::kOk);
    CHECK(var > 100.0);  // Significant variance from sharp edge
}

static void test_laplacian_welford_accuracy() {
    // Gradient image: pixel = x. Laplacian kernel [1, -2, 1] on constant
    // gradient in x gives 0 for each pixel => variance = 0.
    // But column-wise variation from the y-neighbors introduces non-zero lap.
    // We just verify it returns finite and non-negative.
    constexpr int w = 32;
    constexpr int h = 32;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h));
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            img[static_cast<std::size_t>(y * w + x)] = static_cast<std::uint8_t>(x * 8 % 256);
        }
    }
    double var = -1.0;
    CHECK(aether::quality::laplacian_variance(img.data(), w, h, w, &var) ==
          aether::core::Status::kOk);
    CHECK(std::isfinite(var));
    CHECK(var >= 0.0);
}

static void test_laplacian_row_bytes_padding() {
    // row_bytes > width: each row has 4 bytes padding
    constexpr int w = 8;
    constexpr int h = 8;
    constexpr int rb = 12;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(rb * h), 100);
    double var = -1.0;
    CHECK(aether::quality::laplacian_variance(img.data(), w, h, rb, &var) ==
          aether::core::Status::kOk);
    CHECK(near(var, 0.0, 1e-10));
}

// ---------------------------------------------------------------------------
// tenengrad_metric_from_image
// ---------------------------------------------------------------------------

static void test_tenengrad_null_output() {
    double val, conf, roi;
    bool skip;
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 0, 1.0, nullptr, &conf, &roi, &skip) ==
          aether::core::Status::kInvalidArgument);
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 0, 1.0, &val, nullptr, &roi, &skip) ==
          aether::core::Status::kInvalidArgument);
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 0, 1.0, &val, &conf, nullptr, &skip) ==
          aether::core::Status::kInvalidArgument);
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 0, 1.0, &val, &conf, &roi, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

static void test_tenengrad_quality_level_skip() {
    double val, conf, roi;
    bool skip = false;
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 2, 100.0, &val, &conf, &roi, &skip) ==
          aether::core::Status::kOk);
    CHECK(skip);
}

static void test_tenengrad_uniform_image() {
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 128);
    double val = -1.0, conf = -1.0, roi = -1.0;
    bool skip = true;
    CHECK(aether::quality::tenengrad_metric_from_image(
              img.data(), w, h, w, 0, 1000.0, &val, &conf, &roi, &skip) ==
          aether::core::Status::kOk);
    CHECK(!skip);
    CHECK(near(val, 0.0, 1e-10));  // Uniform => zero gradient
}

static void test_tenengrad_sharp_edge() {
    constexpr int w = 16;
    constexpr int h = 16;
    std::vector<std::uint8_t> img(static_cast<std::size_t>(w * h), 0);
    for (int y = 0; y < h; ++y) {
        for (int x = w / 2; x < w; ++x) {
            img[static_cast<std::size_t>(y * w + x)] = 255;
        }
    }
    double val = -1.0, conf = -1.0, roi = -1.0;
    bool skip = true;
    CHECK(aether::quality::tenengrad_metric_from_image(
              img.data(), w, h, w, 0, 1000.0, &val, &conf, &roi, &skip) ==
          aether::core::Status::kOk);
    CHECK(!skip);
    CHECK(val > 0.0);  // Strong Sobel response at edge
}

static void test_tenengrad_negative_threshold() {
    double val, conf, roi;
    bool skip;
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 0, -1.0, &val, &conf, &roi, &skip) ==
          aether::core::Status::kInvalidArgument);
}

static void test_tenengrad_fallback_quality1() {
    // No image, quality_level=1 => fallback produces tenengrad_threshold * 0.94
    double val = 0.0, conf = 0.0, roi = 0.0;
    bool skip = true;
    CHECK(aether::quality::tenengrad_metric_from_image(
              nullptr, 0, 0, 0, 1, 100.0, &val, &conf, &roi, &skip) ==
          aether::core::Status::kOk);
    CHECK(!skip);
    CHECK(near(val, 94.0, 0.01));
    CHECK(near(conf, 0.85, 0.001));
}

int main() {
    test_laplacian_null_output();
    test_laplacian_null_bytes();
    test_laplacian_too_small();
    test_laplacian_uniform_image();
    test_laplacian_sharp_edge();
    test_laplacian_welford_accuracy();
    test_laplacian_row_bytes_padding();

    test_tenengrad_null_output();
    test_tenengrad_quality_level_skip();
    test_tenengrad_uniform_image();
    test_tenengrad_sharp_edge();
    test_tenengrad_negative_threshold();
    test_tenengrad_fallback_quality1();

    if (g_failed == 0) {
        std::fprintf(stdout, "image_metrics_test: all tests passed\n");
    }
    return g_failed;
}
