// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f9_scene_passport_watermark.h"

#include <cstdio>
#include <vector>

namespace {

std::vector<aether::innovation::GaussianPrimitive> make_gaussians(std::size_t count) {
    using namespace aether::innovation;
    std::vector<GaussianPrimitive> out(count);
    for (std::size_t i = 0; i < count; ++i) {
        out[i].id = static_cast<std::uint32_t>(i + 1u);
        out[i].opacity = 0.10f + 0.001f * static_cast<float>(i % 700u);
        out[i].sh_coeffs[0] = -0.5f + 0.002f * static_cast<float>(i % 500u);
    }
    return out;
}

int test_watermark_roundtrip() {
    int failed = 0;
    using namespace aether::innovation;

    F9WatermarkPacket packet{};
    if (f9_generate_watermark_packet("owner-a", "scene-1", 12345u, 64u, &packet) != aether::core::Status::kOk) {
        std::fprintf(stderr, "generate watermark packet failed\n");
        return 1;
    }
    if (packet.bits.size() != 64u || packet.bits_sha256_hex.size() != 64u) {
        std::fprintf(stderr, "generated packet shape mismatch\n");
        failed++;
    }

    auto gaussians = make_gaussians(256u);
    F9WatermarkConfig cfg{};
    cfg.bit_count = 64u;
    cfg.replicas_per_bit = 4u;

    std::size_t slots_used = 0u;
    if (f9_embed_watermark(packet, 777u, cfg, gaussians.data(), gaussians.size(), &slots_used) != aether::core::Status::kOk) {
        std::fprintf(stderr, "embed watermark failed\n");
        return failed + 1;
    }
    if (slots_used != 64u * 4u) {
        std::fprintf(stderr, "slots used mismatch\n");
        failed++;
    }

    F9WatermarkPacket extracted{};
    float confidence = 0.0f;
    if (f9_extract_watermark(777u, cfg, gaussians.data(), gaussians.size(), 64u, &extracted, &confidence) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "extract watermark failed\n");
        return failed + 1;
    }
    if (extracted.bits != packet.bits) {
        std::fprintf(stderr, "extracted watermark bits mismatch\n");
        failed++;
    }
    if (extracted.bits_sha256_hex != packet.bits_sha256_hex) {
        std::fprintf(stderr, "watermark hash mismatch\n");
        failed++;
    }
    if (confidence < 0.95f) {
        std::fprintf(stderr, "watermark confidence too low\n");
        failed++;
    }

    return failed;
}

int test_scene_passport_signature() {
    int failed = 0;
    using namespace aether::innovation;

    const std::uint8_t key_bytes[] = {1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u};
    F9Sha256MacKey key{};
    key.key_bytes = key_bytes;
    key.key_size = sizeof(key_bytes);

    F9SignatureProvider provider{};
    provider.sign = &f9_sha256mac_sign;
    provider.verify = &f9_sha256mac_verify;
    provider.context = &key;

    F9WatermarkPacket packet{};
    if (f9_generate_watermark_packet("owner-a", "scene-2", 99u, 32u, &packet) != aether::core::Status::kOk) {
        std::fprintf(stderr, "packet generation for passport failed\n");
        return 1;
    }

    F9ScenePassport passport{};
    if (f9_build_scene_passport(
            "scene-2",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "owner-a",
            packet,
            provider,
            &passport) != aether::core::Status::kOk) {
        std::fprintf(stderr, "build scene passport failed\n");
        return 1;
    }

    bool valid = false;
    if (f9_verify_scene_passport(passport, provider, &valid) != aether::core::Status::kOk || !valid) {
        std::fprintf(stderr, "passport verification failed\n");
        failed++;
    }

    F9ScenePassport tampered = passport;
    tampered.owner_id = "owner-b";
    if (f9_verify_scene_passport(tampered, provider, &valid) != aether::core::Status::kOk) {
        std::fprintf(stderr, "tampered verification status failed\n");
        failed++;
    } else if (valid) {
        std::fprintf(stderr, "tampered passport should fail verification\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;

    F9WatermarkPacket packet{};
    if (f9_generate_watermark_packet(nullptr, "scene", 1u, 8u, &packet) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null owner should fail\n");
        failed++;
    }

    F9WatermarkConfig cfg{};
    cfg.replicas_per_bit = 0u;
    auto gaussians = make_gaussians(8u);
    std::size_t slots_used = 0u;
    if (f9_embed_watermark(packet, 1u, cfg, gaussians.data(), gaussians.size(), &slots_used) !=
        aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid watermark config should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_watermark_roundtrip();
    failed += test_scene_passport_signature();
    failed += test_invalid_paths();
    return failed;
}
