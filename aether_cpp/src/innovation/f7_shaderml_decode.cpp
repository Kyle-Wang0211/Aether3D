// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f7_shaderml_decode.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace aether {
namespace innovation {
namespace {

float clamp01(float v) {
    return std::max(0.0f, std::min(v, 1.0f));
}

float relu(float v) {
    return (v > 0.0f) ? v : 0.0f;
}

Float3 decode_sh_fallback(const F7DecodeInput& in) {
    const Float3 v = normalize(in.view_dir);
    const float vx = v.x;
    const float vy = v.y;
    const float vz = v.z;

    const auto& s = in.sh_coeffs;
    const float r = s[0] + s[1] * vx + s[2] * vy + s[3] * vz + s[4] * (vx * vy);
    const float g = s[5] + s[6] * vx + s[7] * vy + s[8] * vz + s[9] * (vy * vz);
    const float b = s[10] + s[11] * vx + s[12] * vy + s[13] * vz + s[14] * (vx * vz);
    return make_float3(clamp01(r), clamp01(g), clamp01(b));
}

}  // namespace

void F7AppearanceDecoder::set_runtime_caps(const F7RuntimeCaps& caps) {
    caps_ = caps;
}

core::Status F7AppearanceDecoder::set_tiny_mlp_weights(const F7TinyMLPWeights& weights) {
    if (weights.input_dim == 0u || weights.hidden_dim == 0u || weights.output_dim < 3u) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t expected_w0 = static_cast<std::size_t>(weights.hidden_dim) * weights.input_dim;
    const std::size_t expected_b0 = weights.hidden_dim;
    const std::size_t expected_w1 = static_cast<std::size_t>(weights.output_dim) * weights.hidden_dim;
    const std::size_t expected_b1 = weights.output_dim;
    if (weights.layer0_weights.size() != expected_w0 ||
        weights.layer0_bias.size() != expected_b0 ||
        weights.layer1_weights.size() != expected_w1 ||
        weights.layer1_bias.size() != expected_b1) {
        return core::Status::kInvalidArgument;
    }

    weights_ = weights;
    has_valid_weights_ = true;
    return core::Status::kOk;
}

bool F7AppearanceDecoder::can_use_tiny_mlp() const {
    return caps_.shaderml_supported &&
        caps_.prefer_neural_decode &&
        has_valid_weights_ &&
        parameter_count() <= caps_.max_parameter_count;
}

std::size_t F7AppearanceDecoder::parameter_count() const {
    return weights_.layer0_weights.size() +
        weights_.layer0_bias.size() +
        weights_.layer1_weights.size() +
        weights_.layer1_bias.size();
}

float F7AppearanceDecoder::estimate_memory_saving_ratio(std::size_t scene_gaussian_count) const {
    if (!can_use_tiny_mlp() || scene_gaussian_count == 0u) {
        return 0.0f;
    }
    const std::size_t baseline_bytes = scene_gaussian_count * 16u * sizeof(float);
    const std::size_t neural_bytes = parameter_count() * sizeof(float);
    if (baseline_bytes == 0u) {
        return 0.0f;
    }
    const float ratio = 1.0f - (static_cast<float>(neural_bytes) / static_cast<float>(baseline_bytes));
    return std::max(0.0f, std::min(ratio, 1.0f));
}

F7DecodeBackend F7AppearanceDecoder::active_backend() const {
    return can_use_tiny_mlp() ? F7DecodeBackend::kTinyMLP : F7DecodeBackend::kSHFallback;
}

core::Status F7AppearanceDecoder::decode(const F7DecodeInput& input, F7DecodeOutput* out) const {
    if (out == nullptr) {
        return core::Status::kInvalidArgument;
    }

    if (!can_use_tiny_mlp()) {
        out->rgb = decode_sh_fallback(input);
        out->backend = F7DecodeBackend::kSHFallback;
        return core::Status::kOk;
    }

    std::vector<float> feat(weights_.input_dim, 0.0f);
    if (weights_.input_dim >= 1u) feat[0] = input.position.x;
    if (weights_.input_dim >= 2u) feat[1] = input.position.y;
    if (weights_.input_dim >= 3u) feat[2] = input.position.z;
    if (weights_.input_dim >= 4u) feat[3] = input.view_dir.x;
    if (weights_.input_dim >= 5u) feat[4] = input.view_dir.y;
    if (weights_.input_dim >= 6u) feat[5] = input.view_dir.z;

    std::vector<float> hidden(weights_.hidden_dim, 0.0f);
    for (std::size_t h = 0u; h < weights_.hidden_dim; ++h) {
        float sum = weights_.layer0_bias[h];
        for (std::size_t i = 0u; i < weights_.input_dim; ++i) {
            sum += weights_.layer0_weights[h * weights_.input_dim + i] * feat[i];
        }
        hidden[h] = relu(sum);
    }

    std::vector<float> outv(weights_.output_dim, 0.0f);
    for (std::size_t o = 0u; o < weights_.output_dim; ++o) {
        float sum = weights_.layer1_bias[o];
        for (std::size_t h = 0u; h < weights_.hidden_dim; ++h) {
            sum += weights_.layer1_weights[o * weights_.hidden_dim + h] * hidden[h];
        }
        outv[o] = sum;
    }

    out->rgb = make_float3(clamp01(outv[0]), clamp01(outv[1]), clamp01(outv[2]));
    out->backend = F7DecodeBackend::kTinyMLP;
    return core::Status::kOk;
}

core::Status F7AppearanceDecoder::decode_batch(
    const F7DecodeInput* inputs,
    std::size_t input_count,
    F7DecodeOutput* outputs,
    std::size_t output_capacity,
    std::size_t scene_gaussian_count,
    F7BatchDecodeStats* out_stats) const {
    if (input_count > 0u && inputs == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (input_count > output_capacity || (input_count > 0u && outputs == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (out_stats == nullptr) {
        return core::Status::kInvalidArgument;
    }

    for (std::size_t i = 0u; i < input_count; ++i) {
        const core::Status status = decode(inputs[i], &outputs[i]);
        if (status != core::Status::kOk) {
            return status;
        }
    }

    F7BatchDecodeStats stats{};
    stats.sample_count = input_count;
    stats.parameter_count = parameter_count();
    stats.estimated_memory_saving_ratio = estimate_memory_saving_ratio(scene_gaussian_count);
    stats.backend = active_backend();
    *out_stats = stats;
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
