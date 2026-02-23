// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/screen_detail_selector.h"
#include "aether/innovation/core_types.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

[[maybe_unused]] bool approx(float a, float b, float eps = 1e-5f) {
    return std::fabs(a - b) <= eps;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::render;
    using namespace aether::innovation;

    // -- Test 1: screen_detail_factor returns positive value for valid input. --
    {
        float factor = screen_detail_factor(
            0.01f,   // unit_area
            2.0f,    // distance_to_camera
            500.0f,  // focal_length
            0.8f     // display
        );
        if (factor <= 0.0f) {
            std::fprintf(stderr,
                         "screen_detail_factor should be positive, got %f\n",
                         factor);
            failed++;
        }
    }

    // -- Test 2: Closer objects should have higher detail factor. --
    {
        float near_factor = screen_detail_factor(0.01f, 1.0f, 500.0f, 1.0f);
        float far_factor = screen_detail_factor(0.01f, 5.0f, 500.0f, 1.0f);

        if (near_factor <= far_factor) {
            std::fprintf(stderr,
                         "near object should have higher detail: near=%f, far=%f\n",
                         near_factor, far_factor);
            failed++;
        }
    }

    // -- Test 3: Larger unit area should produce higher screen-space factor. --
    {
        float small_area = screen_detail_factor(0.001f, 2.0f, 500.0f, 1.0f);
        float large_area = screen_detail_factor(0.1f, 2.0f, 500.0f, 1.0f);

        if (large_area <= small_area) {
            std::fprintf(stderr,
                         "larger area should give higher detail: small=%f, large=%f\n",
                         small_area, large_area);
            failed++;
        }
    }

    // -- Test 4: Higher display value should increase factor. --
    {
        ScreenDetailConfig config{};
        config.display_weight = 0.3f;

        float low_display = screen_detail_factor(0.01f, 2.0f, 500.0f, 0.1f, config);
        float high_display = screen_detail_factor(0.01f, 2.0f, 500.0f, 1.0f, config);

        if (high_display < low_display) {
            std::fprintf(stderr,
                         "higher display should give >= detail: low=%f, high=%f\n",
                         low_display, high_display);
            failed++;
        }
    }

    // -- Test 5: Default ScreenDetailConfig values are sane. --
    {
        ScreenDetailConfig config{};
        if (config.reference_screen_area <= 0.0f) {
            std::fprintf(stderr,
                         "default reference_screen_area should be positive: %f\n",
                         config.reference_screen_area);
            failed++;
        }
        if (config.display_weight < 0.0f || config.display_weight > 1.0f) {
            std::fprintf(stderr,
                         "default display_weight out of [0,1]: %f\n",
                         config.display_weight);
            failed++;
        }
    }

    // -- Test 6: batch_screen_detail_factor with a single unit. --
    {
        ScaffoldUnit unit{};
        unit.unit_id = 1;
        unit.area = 0.02f;

        float distance = 3.0f;
        float display = 0.9f;
        float focal_length = 500.0f;
        ScreenDetailConfig config{};

        float out_factor = 0.0f;
        auto st = batch_screen_detail_factor(
            &unit, 1,
            &distance,
            &display,
            focal_length,
            config,
            &out_factor);

        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "batch_screen_detail_factor returned error\n");
            failed++;
        }
        if (out_factor <= 0.0f) {
            std::fprintf(stderr,
                         "batch output factor should be positive, got %f\n",
                         out_factor);
            failed++;
        }
    }

    // -- Test 7: batch_screen_detail_factor with multiple units. --
    {
        const int n = 3;
        ScaffoldUnit units[n]{};
        float distances[n] = {1.0f, 3.0f, 5.0f};
        float displays[n] = {1.0f, 0.5f, 0.1f};
        float out_factors[n] = {0.0f, 0.0f, 0.0f};

        for (int i = 0; i < n; ++i) {
            units[i].unit_id = static_cast<ScaffoldUnitId>(i);
            units[i].area = 0.01f;
        }

        ScreenDetailConfig config{};
        auto st = batch_screen_detail_factor(
            units, n,
            distances,
            displays,
            500.0f,
            config,
            out_factors);

        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "batch_screen_detail_factor multi returned error\n");
            failed++;
        }

        // Closer unit (index 0) with higher display should have highest factor.
        if (out_factors[0] <= out_factors[2]) {
            std::fprintf(stderr,
                         "closer unit with higher display should have higher detail: "
                         "[0]=%f, [2]=%f\n",
                         out_factors[0], out_factors[2]);
            failed++;
        }
    }

    // -- Test 8: batch_screen_detail_factor with zero count. --
    {
        ScreenDetailConfig config{};
        auto st = batch_screen_detail_factor(
            nullptr, 0,
            nullptr, nullptr,
            500.0f, config, nullptr);

        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "batch with zero count should return ok\n");
            failed++;
        }
    }

    return failed;
}
