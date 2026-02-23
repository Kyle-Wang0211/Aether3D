// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f7_shaderml_decode.h"

#include <cmath>
#include <cstdio>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

int test_fallback_path() {
    int failed = 0;
    using namespace aether::innovation;

    F7AppearanceDecoder decoder{};
    F7DecodeInput in{};
    in.view_dir = make_float3(0.0f, 0.0f, 1.0f);
    in.sh_coeffs[0] = 0.2f;
    in.sh_coeffs[3] = 0.3f;
    in.sh_coeffs[5] = 0.1f;
    in.sh_coeffs[8] = 0.2f;
    in.sh_coeffs[10] = 0.05f;
    in.sh_coeffs[13] = 0.4f;

    F7DecodeOutput out{};
    if (decoder.decode(in, &out) != aether::core::Status::kOk) {
        std::fprintf(stderr, "fallback decode failed\n");
        return 1;
    }
    if (out.backend != F7DecodeBackend::kSHFallback) {
        std::fprintf(stderr, "decoder should default to SH fallback\n");
        failed++;
    }

    F7BatchDecodeStats stats{};
    if (decoder.decode_batch(&in, 1u, &out, 1u, 1000u, &stats) != aether::core::Status::kOk) {
        std::fprintf(stderr, "fallback batch decode failed\n");
        failed++;
    } else {
        if (stats.backend != F7DecodeBackend::kSHFallback) {
            std::fprintf(stderr, "batch stats backend mismatch for fallback\n");
            failed++;
        }
        if (stats.estimated_memory_saving_ratio != 0.0f) {
            std::fprintf(stderr, "fallback mode should report zero memory saving\n");
            failed++;
        }
    }

    return failed;
}

int test_tiny_mlp_path() {
    int failed = 0;
    using namespace aether::innovation;

    F7AppearanceDecoder decoder{};
    F7RuntimeCaps caps{};
    caps.shaderml_supported = true;
    caps.prefer_neural_decode = true;
    caps.max_parameter_count = 128u;
    decoder.set_runtime_caps(caps);

    F7TinyMLPWeights w{};
    w.input_dim = 6u;
    w.hidden_dim = 3u;
    w.output_dim = 3u;
    w.layer0_weights.assign(18u, 0.0f);
    w.layer0_bias.assign(3u, 0.0f);
    w.layer1_weights.assign(9u, 0.0f);
    w.layer1_bias.assign(3u, 0.5f);

    // Hidden = [pos.x, pos.y, pos.z].
    w.layer0_weights[0u * 6u + 0u] = 1.0f;
    w.layer0_weights[1u * 6u + 1u] = 1.0f;
    w.layer0_weights[2u * 6u + 2u] = 1.0f;

    // Output RGB = 0.5 + 0.1 * hidden.
    w.layer1_weights[0u * 3u + 0u] = 0.1f;
    w.layer1_weights[1u * 3u + 1u] = 0.1f;
    w.layer1_weights[2u * 3u + 2u] = 0.1f;

    if (decoder.set_tiny_mlp_weights(w) != aether::core::Status::kOk) {
        std::fprintf(stderr, "set tiny MLP weights failed\n");
        return 1;
    }
    if (decoder.active_backend() != F7DecodeBackend::kTinyMLP) {
        std::fprintf(stderr, "decoder should switch to tiny MLP backend\n");
        failed++;
    }

    F7DecodeInput in{};
    in.position = make_float3(1.0f, 2.0f, 3.0f);
    in.view_dir = make_float3(0.0f, 0.0f, 1.0f);
    F7DecodeOutput out{};
    if (decoder.decode(in, &out) != aether::core::Status::kOk) {
        std::fprintf(stderr, "tiny MLP decode failed\n");
        failed++;
    } else {
        if (out.backend != F7DecodeBackend::kTinyMLP) {
            std::fprintf(stderr, "tiny MLP backend not reported\n");
            failed++;
        }
        if (!approx(out.rgb.x, 0.6f, 1e-4f) ||
            !approx(out.rgb.y, 0.7f, 1e-4f) ||
            !approx(out.rgb.z, 0.8f, 1e-4f)) {
            std::fprintf(stderr, "tiny MLP output mismatch\n");
            failed++;
        }
    }

    F7BatchDecodeStats stats{};
    if (decoder.decode_batch(&in, 1u, &out, 1u, 1000u, &stats) != aether::core::Status::kOk) {
        std::fprintf(stderr, "tiny MLP batch decode failed\n");
        failed++;
    } else if (stats.estimated_memory_saving_ratio < 0.30f) {
        std::fprintf(stderr, "expected memory saving ratio should be >= 30%%\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;

    F7AppearanceDecoder decoder{};
    F7TinyMLPWeights bad{};
    bad.input_dim = 6u;
    bad.hidden_dim = 3u;
    bad.output_dim = 3u;
    bad.layer0_weights.assign(1u, 0.0f);  // invalid size.
    bad.layer0_bias.assign(3u, 0.0f);
    bad.layer1_weights.assign(9u, 0.0f);
    bad.layer1_bias.assign(3u, 0.0f);
    if (decoder.set_tiny_mlp_weights(bad) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid weight shape should fail\n");
        failed++;
    }

    F7DecodeInput input{};
    F7DecodeOutput output{};
    if (decoder.decode(input, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null decode output should fail\n");
        failed++;
    }
    if (decoder.decode_batch(&input, 1u, &output, 0u, 1u, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid batch args should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_fallback_path();
    failed += test_tiny_mlp_path();
    failed += test_invalid_paths();
    return failed;
}
