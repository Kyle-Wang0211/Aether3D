// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F9_SCENE_PASSPORT_WATERMARK_H
#define AETHER_INNOVATION_F9_SCENE_PASSPORT_WATERMARK_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace innovation {

struct F9WatermarkConfig {
    std::uint32_t bit_count{128};
    std::uint32_t replicas_per_bit{5};
    float opacity_quant_step{1.0f / 1024.0f};
    float sh_quant_step{1.0f / 512.0f};
};

struct F9WatermarkPacket {
    std::vector<std::uint8_t> bits{};   // one byte per bit (0/1)
    std::string bits_sha256_hex{};
};

struct F9SignatureProvider {
    core::Status (*sign)(
        const std::uint8_t* message,
        std::size_t message_size,
        void* context,
        std::vector<std::uint8_t>* out_signature){nullptr};
    bool (*verify)(
        const std::uint8_t* message,
        std::size_t message_size,
        const std::uint8_t* signature,
        std::size_t signature_size,
        void* context){nullptr};
    void* context{nullptr};
};

struct F9Sha256MacKey {
    const std::uint8_t* key_bytes{nullptr};
    std::size_t key_size{0};
};

struct F9ScenePassport {
    std::string scene_id{};
    std::string merkle_root_hex{};
    std::string owner_id{};
    std::string watermark_sha256_hex{};
    std::string canonical_json{};
    std::vector<std::uint8_t> signature{};
};

core::Status f9_generate_watermark_packet(
    const char* owner_id,
    const char* scene_id,
    std::uint64_t nonce,
    std::uint32_t bit_count,
    F9WatermarkPacket* out_packet);

core::Status f9_embed_watermark(
    const F9WatermarkPacket& packet,
    std::uint64_t seed,
    const F9WatermarkConfig& config,
    GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::size_t* out_slots_used);

core::Status f9_extract_watermark(
    std::uint64_t seed,
    const F9WatermarkConfig& config,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::uint32_t bit_count,
    F9WatermarkPacket* out_packet,
    float* out_confidence);

core::Status f9_build_scene_passport(
    const char* scene_id,
    const char* merkle_root_hex,
    const char* owner_id,
    const F9WatermarkPacket& packet,
    const F9SignatureProvider& signature_provider,
    F9ScenePassport* out_passport);

core::Status f9_verify_scene_passport(
    const F9ScenePassport& passport,
    const F9SignatureProvider& signature_provider,
    bool* out_valid);

core::Status f9_sha256mac_sign(
    const std::uint8_t* message,
    std::size_t message_size,
    void* context,
    std::vector<std::uint8_t>* out_signature);

bool f9_sha256mac_verify(
    const std::uint8_t* message,
    std::size_t message_size,
    const std::uint8_t* signature,
    std::size_t signature_size,
    void* context);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F9_SCENE_PASSPORT_WATERMARK_H
