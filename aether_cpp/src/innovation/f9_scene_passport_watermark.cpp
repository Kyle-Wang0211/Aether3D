// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f9_scene_passport_watermark.h"

#include "aether/crypto/sha256.h"
#include "aether/evidence/deterministic_json.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace aether {
namespace innovation {
namespace {

float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(v, hi));
}

std::string sha256_hex(const std::uint8_t* data, std::size_t size) {
    crypto::Sha256Digest digest{};
    crypto::sha256(data, size, digest);
    return to_hex_lower(digest.bytes, sizeof(digest.bytes));
}

std::string sha256_hex(const std::vector<std::uint8_t>& data) {
    return sha256_hex(data.data(), data.size());
}

std::uint8_t quantized_parity(float value, float step, float min_v, float max_v) {
    if (!(step > 0.0f)) {
        return 0u;
    }
    const float clamped = clampf(value, min_v, max_v);
    const std::int64_t q = static_cast<std::int64_t>(std::llround(clamped / step));
    return static_cast<std::uint8_t>(q & 1LL);
}

void embed_bit_in_value(float* inout_value, float step, float min_v, float max_v, std::uint8_t bit) {
    if (inout_value == nullptr || !(step > 0.0f)) {
        return;
    }
    const float clamped = clampf(*inout_value, min_v, max_v);
    std::int64_t q = static_cast<std::int64_t>(std::llround(clamped / step));
    const std::int64_t min_q = static_cast<std::int64_t>(std::llround(min_v / step));
    const std::int64_t max_q = static_cast<std::int64_t>(std::llround(max_v / step));
    if ((q & 1LL) != static_cast<std::int64_t>(bit & 1u)) {
        if (q < max_q) {
            q += 1LL;
        } else if (q > min_q) {
            q -= 1LL;
        }
    }
    const float out = clampf(static_cast<float>(q) * step, min_v, max_v);
    *inout_value = out;
}

void deterministic_slot_sequence(
    std::uint64_t seed,
    std::uint32_t total_slots,
    std::size_t needed_slots,
    std::vector<std::uint32_t>* out_slots) {
    out_slots->clear();
    if (total_slots == 0u || needed_slots == 0u) {
        return;
    }

    std::vector<std::uint32_t> perm(total_slots);
    for (std::uint32_t i = 0u; i < total_slots; ++i) {
        perm[i] = i;
    }
    std::uint64_t rng = seed;
    for (std::uint32_t i = total_slots; i > 1u; --i) {
        rng = splitmix64(rng);
        const std::uint32_t j = static_cast<std::uint32_t>(rng % static_cast<std::uint64_t>(i));
        std::swap(perm[i - 1u], perm[j]);
    }

    out_slots->reserve(needed_slots);
    for (std::size_t i = 0u; i < needed_slots; ++i) {
        out_slots->push_back(perm[i % perm.size()]);
    }
}

core::Status build_passport_json(
    const char* scene_id,
    const char* merkle_root_hex,
    const char* owner_id,
    const std::string& watermark_sha256_hex,
    std::string* out_json) {
    if (scene_id == nullptr || merkle_root_hex == nullptr || owner_id == nullptr || out_json == nullptr) {
        return core::Status::kInvalidArgument;
    }
    using evidence::CanonicalJsonValue;
    std::vector<std::pair<std::string, CanonicalJsonValue>> obj;
    obj.emplace_back("merkle_root_hex", CanonicalJsonValue::make_string(merkle_root_hex));
    obj.emplace_back("owner_id", CanonicalJsonValue::make_string(owner_id));
    obj.emplace_back("scene_id", CanonicalJsonValue::make_string(scene_id));
    obj.emplace_back("schema", CanonicalJsonValue::make_string("aether.f9.scene_passport.v1"));
    obj.emplace_back("watermark_sha256_hex", CanonicalJsonValue::make_string(watermark_sha256_hex));
    const CanonicalJsonValue root = CanonicalJsonValue::make_object(std::move(obj));
    return evidence::encode_canonical_json(root, *out_json);
}

}  // namespace

core::Status f9_generate_watermark_packet(
    const char* owner_id,
    const char* scene_id,
    std::uint64_t nonce,
    std::uint32_t bit_count,
    F9WatermarkPacket* out_packet) {
    if (owner_id == nullptr || scene_id == nullptr || out_packet == nullptr || bit_count == 0u) {
        return core::Status::kInvalidArgument;
    }

    std::string seed(owner_id);
    seed.push_back('|');
    seed.append(scene_id);
    seed.push_back('|');
    seed.append(std::to_string(nonce));

    std::vector<std::uint8_t> entropy;
    entropy.reserve((bit_count + 7u) / 8u);
    std::uint64_t counter = 0u;
    while (entropy.size() * 8u < bit_count) {
        std::vector<std::uint8_t> msg(seed.begin(), seed.end());
        for (std::uint32_t i = 0u; i < 8u; ++i) {
            msg.push_back(static_cast<std::uint8_t>((counter >> (8u * i)) & 0xffu));
        }
        crypto::Sha256Digest digest{};
        crypto::sha256(msg.data(), msg.size(), digest);
        for (std::uint8_t b : digest.bytes) {
            entropy.push_back(b);
            if (entropy.size() * 8u >= bit_count) {
                break;
            }
        }
        counter += 1u;
    }

    F9WatermarkPacket packet{};
    packet.bits.resize(bit_count, 0u);
    for (std::uint32_t i = 0u; i < bit_count; ++i) {
        const std::uint8_t byte = entropy[i / 8u];
        const std::uint8_t bit = static_cast<std::uint8_t>((byte >> (i % 8u)) & 0x1u);
        packet.bits[i] = bit;
    }
    packet.bits_sha256_hex = sha256_hex(packet.bits);
    *out_packet = std::move(packet);
    return core::Status::kOk;
}

core::Status f9_embed_watermark(
    const F9WatermarkPacket& packet,
    std::uint64_t seed,
    const F9WatermarkConfig& config,
    GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::size_t* out_slots_used) {
    if ((gaussian_count > 0u && gaussians == nullptr) || out_slots_used == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (packet.bits.empty() || config.replicas_per_bit == 0u || !(config.opacity_quant_step > 0.0f) || !(config.sh_quant_step > 0.0f)) {
        return core::Status::kInvalidArgument;
    }
    const std::uint32_t total_slots = static_cast<std::uint32_t>(gaussian_count * 2u);
    if (total_slots == 0u) {
        return core::Status::kOutOfRange;
    }

    const std::size_t needed_slots = static_cast<std::size_t>(packet.bits.size()) * config.replicas_per_bit;
    std::vector<std::uint32_t> slots;
    deterministic_slot_sequence(seed, total_slots, needed_slots, &slots);

    std::size_t slot_cursor = 0u;
    for (std::size_t bit_idx = 0u; bit_idx < packet.bits.size(); ++bit_idx) {
        const std::uint8_t bit = packet.bits[bit_idx] & 1u;
        for (std::uint32_t rep = 0u; rep < config.replicas_per_bit; ++rep) {
            const std::uint32_t slot = slots[slot_cursor++];
            const std::size_t g_idx = static_cast<std::size_t>(slot / 2u);
            const bool use_opacity = (slot % 2u) == 0u;
            if (g_idx >= gaussian_count) {
                return core::Status::kOutOfRange;
            }
            if (use_opacity) {
                embed_bit_in_value(&gaussians[g_idx].opacity, config.opacity_quant_step, 0.0f, 1.0f, bit);
            } else {
                embed_bit_in_value(&gaussians[g_idx].sh_coeffs[0], config.sh_quant_step, -4.0f, 4.0f, bit);
            }
        }
    }

    *out_slots_used = needed_slots;
    return core::Status::kOk;
}

core::Status f9_extract_watermark(
    std::uint64_t seed,
    const F9WatermarkConfig& config,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::uint32_t bit_count,
    F9WatermarkPacket* out_packet,
    float* out_confidence) {
    if (out_packet == nullptr || out_confidence == nullptr || (gaussian_count > 0u && gaussians == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (bit_count == 0u || config.replicas_per_bit == 0u || !(config.opacity_quant_step > 0.0f) || !(config.sh_quant_step > 0.0f)) {
        return core::Status::kInvalidArgument;
    }
    const std::uint32_t total_slots = static_cast<std::uint32_t>(gaussian_count * 2u);
    if (total_slots == 0u) {
        return core::Status::kOutOfRange;
    }

    const std::size_t needed_slots = static_cast<std::size_t>(bit_count) * config.replicas_per_bit;
    std::vector<std::uint32_t> slots;
    deterministic_slot_sequence(seed, total_slots, needed_slots, &slots);

    F9WatermarkPacket packet{};
    packet.bits.assign(bit_count, 0u);
    float confidence_sum = 0.0f;
    std::size_t slot_cursor = 0u;
    for (std::uint32_t bit_idx = 0u; bit_idx < bit_count; ++bit_idx) {
        std::uint32_t ones = 0u;
        for (std::uint32_t rep = 0u; rep < config.replicas_per_bit; ++rep) {
            const std::uint32_t slot = slots[slot_cursor++];
            const std::size_t g_idx = static_cast<std::size_t>(slot / 2u);
            const bool use_opacity = (slot % 2u) == 0u;
            if (g_idx >= gaussian_count) {
                return core::Status::kOutOfRange;
            }
            const std::uint8_t parity = use_opacity
                ? quantized_parity(gaussians[g_idx].opacity, config.opacity_quant_step, 0.0f, 1.0f)
                : quantized_parity(gaussians[g_idx].sh_coeffs[0], config.sh_quant_step, -4.0f, 4.0f);
            ones += parity ? 1u : 0u;
        }
        const std::uint32_t zeros = config.replicas_per_bit - ones;
        packet.bits[bit_idx] = (ones >= zeros) ? 1u : 0u;
        const float margin = static_cast<float>(std::abs(static_cast<int>(ones) - static_cast<int>(zeros))) /
            static_cast<float>(config.replicas_per_bit);
        confidence_sum += margin;
    }
    packet.bits_sha256_hex = sha256_hex(packet.bits);

    *out_packet = std::move(packet);
    *out_confidence = confidence_sum / static_cast<float>(bit_count);
    return core::Status::kOk;
}

core::Status f9_build_scene_passport(
    const char* scene_id,
    const char* merkle_root_hex,
    const char* owner_id,
    const F9WatermarkPacket& packet,
    const F9SignatureProvider& signature_provider,
    F9ScenePassport* out_passport) {
    if (scene_id == nullptr || merkle_root_hex == nullptr || owner_id == nullptr || out_passport == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (signature_provider.sign == nullptr) {
        return core::Status::kInvalidArgument;
    }
    std::string watermark_hash = packet.bits_sha256_hex;
    if (watermark_hash.empty()) {
        watermark_hash = sha256_hex(packet.bits);
    }

    std::string canonical_json;
    core::Status status = build_passport_json(
        scene_id,
        merkle_root_hex,
        owner_id,
        watermark_hash,
        &canonical_json);
    if (status != core::Status::kOk) {
        return status;
    }

    std::vector<std::uint8_t> signature;
    status = signature_provider.sign(
        reinterpret_cast<const std::uint8_t*>(canonical_json.data()),
        canonical_json.size(),
        signature_provider.context,
        &signature);
    if (status != core::Status::kOk) {
        return status;
    }

    F9ScenePassport passport{};
    passport.scene_id = scene_id;
    passport.merkle_root_hex = merkle_root_hex;
    passport.owner_id = owner_id;
    passport.watermark_sha256_hex = std::move(watermark_hash);
    passport.canonical_json = std::move(canonical_json);
    passport.signature = std::move(signature);
    *out_passport = std::move(passport);
    return core::Status::kOk;
}

core::Status f9_verify_scene_passport(
    const F9ScenePassport& passport,
    const F9SignatureProvider& signature_provider,
    bool* out_valid) {
    if (out_valid == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_valid = false;
    if (signature_provider.verify == nullptr) {
        return core::Status::kInvalidArgument;
    }

    std::string expected_json;
    core::Status status = build_passport_json(
        passport.scene_id.c_str(),
        passport.merkle_root_hex.c_str(),
        passport.owner_id.c_str(),
        passport.watermark_sha256_hex,
        &expected_json);
    if (status != core::Status::kOk) {
        return status;
    }
    if (expected_json != passport.canonical_json) {
        *out_valid = false;
        return core::Status::kOk;
    }

    *out_valid = signature_provider.verify(
        reinterpret_cast<const std::uint8_t*>(passport.canonical_json.data()),
        passport.canonical_json.size(),
        passport.signature.data(),
        passport.signature.size(),
        signature_provider.context);
    return core::Status::kOk;
}

core::Status f9_sha256mac_sign(
    const std::uint8_t* message,
    std::size_t message_size,
    void* context,
    std::vector<std::uint8_t>* out_signature) {
    if (message == nullptr || out_signature == nullptr || context == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const auto* key = reinterpret_cast<const F9Sha256MacKey*>(context);
    if (key->key_bytes == nullptr || key->key_size == 0u) {
        return core::Status::kInvalidArgument;
    }

    std::vector<std::uint8_t> payload;
    payload.reserve(key->key_size + message_size);
    payload.insert(payload.end(), key->key_bytes, key->key_bytes + key->key_size);
    payload.insert(payload.end(), message, message + message_size);

    crypto::Sha256Digest digest{};
    crypto::sha256(payload.data(), payload.size(), digest);
    out_signature->assign(digest.bytes, digest.bytes + sizeof(digest.bytes));
    return core::Status::kOk;
}

bool f9_sha256mac_verify(
    const std::uint8_t* message,
    std::size_t message_size,
    const std::uint8_t* signature,
    std::size_t signature_size,
    void* context) {
    if (message == nullptr || signature == nullptr || context == nullptr || signature_size != 32u) {
        return false;
    }
    std::vector<std::uint8_t> expected;
    if (f9_sha256mac_sign(message, message_size, context, &expected) != core::Status::kOk) {
        return false;
    }
    return std::memcmp(expected.data(), signature, signature_size) == 0;
}

}  // namespace innovation
}  // namespace aether
