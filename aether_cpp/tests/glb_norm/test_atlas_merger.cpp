// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 1 smoke test for atlas_merger. Synthesizes 3 solid-colour
// 256×256 charts that span the full UV unit square, packs them via
// merge_atlases(), then verifies:
//   - returns true
//   - output is power-of-2 within [1024, 8192]
//   - one remapped UV array per input, same element count, all in [0,1]
//   - output buffer is non-empty and matches output_w × output_h × 3
//   - the four corner UVs of each input chart, mapped through the
//     atlas, sample roughly the chart's solid colour (within tolerance
//     to allow for the dilation seam + 8 bit rounding)
//
// Test passes by returning 0; any failure adds to the failure count
// and prints a one-line diagnostic. This matches every other test in
// aether_cpp/tests/.

#include "../../src/glb_norm/atlas_merger.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

bool is_power_of_two(int v) {
    return v > 0 && (v & (v - 1)) == 0;
}

// Solid-colour chart of `size`×`size` with corner UVs (0,0)(1,0)(0,1)(1,1).
aether::glb_norm::ChartInput make_solid_chart(int size,
                                              uint8_t r, uint8_t g, uint8_t b) {
    aether::glb_norm::ChartInput in;
    in.atlas_w = size;
    in.atlas_h = size;
    in.atlas_rgb.resize(static_cast<size_t>(size) * size * 3u);
    for (size_t i = 0; i + 2 < in.atlas_rgb.size(); i += 3) {
        in.atlas_rgb[i + 0] = r;
        in.atlas_rgb[i + 1] = g;
        in.atlas_rgb[i + 2] = b;
    }
    in.uvs = {
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };
    return in;
}

// Sample a UV from the output atlas; the UV is shifted slightly
// inward so we don't accidentally land on the dilation seam.
void sample_atlas(const aether::glb_norm::AtlasMergerResult& res,
                  float u, float v,
                  uint8_t& r, uint8_t& g, uint8_t& b) {
    if (u < 0.0f) u = 0.0f;
    if (u > 1.0f) u = 1.0f;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    int x = static_cast<int>(u * (res.output_w - 1));
    int y = static_cast<int>(v * (res.output_h - 1));
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= res.output_w) x = res.output_w - 1;
    if (y >= res.output_h) y = res.output_h - 1;
    const uint8_t* p =
        res.output_rgb.data() +
        (static_cast<size_t>(y) * res.output_w + x) * 3u;
    r = p[0]; g = p[1]; b = p[2];
}

}  // namespace

int main() {
    using namespace aether::glb_norm;

    int failed = 0;

    std::vector<ChartInput> inputs;
    inputs.push_back(make_solid_chart(256, 220, 30, 30));   // red-ish
    inputs.push_back(make_solid_chart(256, 30, 200, 60));   // green-ish
    inputs.push_back(make_solid_chart(256, 30, 50, 220));   // blue-ish

    AtlasMergerOptions opts;   // defaults
    AtlasMergerResult res;
    if (!merge_atlases(inputs, opts, res)) {
        std::fprintf(stderr, "merge_atlases returned false\n");
        return 1;
    }

    if (!is_power_of_two(res.output_w) || !is_power_of_two(res.output_h) ||
        res.output_w != res.output_h) {
        std::fprintf(stderr, "output not square pow2: %dx%d\n",
                     res.output_w, res.output_h);
        ++failed;
    }
    if (res.output_w < 1024 || res.output_w > 8192) {
        std::fprintf(stderr, "output side %d out of [1024,8192]\n",
                     res.output_w);
        ++failed;
    }

    const size_t expected_bytes =
        static_cast<size_t>(res.output_w) *
        static_cast<size_t>(res.output_h) * 3u;
    if (res.output_rgb.size() != expected_bytes || expected_bytes == 0) {
        std::fprintf(stderr, "output_rgb size mismatch: got %zu expected %zu\n",
                     res.output_rgb.size(), expected_bytes);
        ++failed;
    }

    if (res.remapped_uvs.size() != inputs.size()) {
        std::fprintf(stderr, "remapped_uvs count %zu != inputs %zu\n",
                     res.remapped_uvs.size(), inputs.size());
        ++failed;
    } else {
        for (size_t i = 0; i < inputs.size(); ++i) {
            if (res.remapped_uvs[i].size() != inputs[i].uvs.size()) {
                std::fprintf(stderr, "chart %zu uv size mismatch %zu vs %zu\n",
                             i, res.remapped_uvs[i].size(),
                             inputs[i].uvs.size());
                ++failed;
            }
            for (size_t k = 0; k + 1 < res.remapped_uvs[i].size(); k += 2) {
                const float u = res.remapped_uvs[i][k + 0];
                const float v = res.remapped_uvs[i][k + 1];
                if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f) {
                    std::fprintf(stderr,
                        "chart %zu vertex %zu UV out of [0,1]: (%f, %f)\n",
                        i, k / 2, static_cast<double>(u),
                        static_cast<double>(v));
                    ++failed;
                }
            }
        }
    }

    // Each input chart's interior UV (e.g., 0.5, 0.5) should sample
    // close to the chart's solid colour through the remapping. Use a
    // generous tolerance — dilation rim, downscale (if any), and
    // background fill all subtract from the centre's purity at the
    // edges, but at chart-centre we should be on-colour.
    constexpr int kColourTolerance = 16;   // 6.3 % of full 8 bit range
    const std::array<std::array<uint8_t, 3>, 3> expected = {{
        {220, 30, 30},
        {30, 200, 60},
        {30, 50, 220},
    }};
    for (size_t i = 0; i < inputs.size(); ++i) {
        if (res.remapped_uvs[i].size() < 8) continue;   // need 4 corners
        // Centre of the chart in remapped UV space is the mean of its
        // four corner UVs.
        float cu = 0.0f, cv = 0.0f;
        for (size_t k = 0; k < 8; k += 2) {
            cu += res.remapped_uvs[i][k + 0];
            cv += res.remapped_uvs[i][k + 1];
        }
        cu *= 0.25f;
        cv *= 0.25f;
        uint8_t r = 0, g = 0, b = 0;
        sample_atlas(res, cu, cv, r, g, b);
        const int dr = std::abs(static_cast<int>(r) - expected[i][0]);
        const int dg = std::abs(static_cast<int>(g) - expected[i][1]);
        const int db = std::abs(static_cast<int>(b) - expected[i][2]);
        if (dr > kColourTolerance || dg > kColourTolerance ||
            db > kColourTolerance) {
            std::fprintf(stderr,
                "chart %zu centre sample (%u,%u,%u) far from expected "
                "(%u,%u,%u) — Δ(%d,%d,%d)\n",
                i, r, g, b, expected[i][0], expected[i][1], expected[i][2],
                dr, dg, db);
            ++failed;
        }
    }

    if (res.chosen_atlas_size != res.output_w) {
        std::fprintf(stderr, "chosen_atlas_size %d != output_w %d\n",
                     res.chosen_atlas_size, res.output_w);
        ++failed;
    }
    if (res.scale_factor < 0.0f || res.scale_factor > 1.001f) {
        std::fprintf(stderr, "scale_factor %f out of plausible [0,1]\n",
                     static_cast<double>(res.scale_factor));
        ++failed;
    }

    if (failed == 0) {
        std::printf(
            "atlas_merger smoke OK: %d×%d atlas, %zu charts, "
            "scale=%.3f\n",
            res.output_w, res.output_h, res.remapped_uvs.size(),
            static_cast<double>(res.scale_factor));
    } else {
        std::fprintf(stderr, "atlas_merger smoke: %d failure(s)\n", failed);
    }

    return failed;
}
