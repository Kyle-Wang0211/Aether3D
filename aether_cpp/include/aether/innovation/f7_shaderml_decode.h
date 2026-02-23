// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F7_SHADERML_DECODE_H
#define AETHER_INNOVATION_F7_SHADERML_DECODE_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

enum class F7DecodeBackend : std::uint8_t {
    kSHFallback = 0,
    kTinyMLP = 1,
};

struct F7RuntimeCaps {
    bool shaderml_supported{false};
    bool prefer_neural_decode{false};
    std::uint32_t max_parameter_count{4096};
};

struct F7TinyMLPWeights {
    std::uint32_t input_dim{6};
    std::uint32_t hidden_dim{8};
    std::uint32_t output_dim{3};
    std::vector<float> layer0_weights{};  // hidden_dim * input_dim
    std::vector<float> layer0_bias{};     // hidden_dim
    std::vector<float> layer1_weights{};  // output_dim * hidden_dim
    std::vector<float> layer1_bias{};     // output_dim
};

struct F7DecodeInput {
    Float3 position{};
    Float3 view_dir{0.0f, 0.0f, 1.0f};
    std::array<float, 16> sh_coeffs{};
};

struct F7DecodeOutput {
    Float3 rgb{};
    F7DecodeBackend backend{F7DecodeBackend::kSHFallback};
};

struct F7BatchDecodeStats {
    std::size_t sample_count{0};
    std::size_t parameter_count{0};
    float estimated_memory_saving_ratio{0.0f};
    F7DecodeBackend backend{F7DecodeBackend::kSHFallback};
};

class F7AppearanceDecoder {
public:
    F7AppearanceDecoder() = default;

    void set_runtime_caps(const F7RuntimeCaps& caps);
    core::Status set_tiny_mlp_weights(const F7TinyMLPWeights& weights);

    F7DecodeBackend active_backend() const;
    core::Status decode(const F7DecodeInput& input, F7DecodeOutput* out) const;
    core::Status decode_batch(
        const F7DecodeInput* inputs,
        std::size_t input_count,
        F7DecodeOutput* outputs,
        std::size_t output_capacity,
        std::size_t scene_gaussian_count,
        F7BatchDecodeStats* out_stats) const;

private:
    bool can_use_tiny_mlp() const;
    std::size_t parameter_count() const;
    float estimate_memory_saving_ratio(std::size_t scene_gaussian_count) const;

    F7RuntimeCaps caps_{};
    F7TinyMLPWeights weights_{};
    bool has_valid_weights_{false};
};

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F7_SHADERML_DECODE_H
