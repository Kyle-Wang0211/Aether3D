// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/deterministic_json.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>

int main() {
    int failed = 0;
    using namespace aether::evidence;

    // Quantization (half-away-from-zero)
    if (std::fabs(quantize_half_away_from_zero(0.12345, 4) - 0.1235) > 1e-12) {
        std::fprintf(stderr, "quantize +0.12345 mismatch\n");
        failed++;
    }
    if (std::fabs(quantize_half_away_from_zero(-0.12345, 4) + 0.1235) > 1e-12) {
        std::fprintf(stderr, "quantize -0.12345 mismatch\n");
        failed++;
    }

    // Canonical key ordering + escaping
    {
        CanonicalJsonValue obj = CanonicalJsonValue::make_object({
            {"z", CanonicalJsonValue::make_int(1)},
            {"a", CanonicalJsonValue::make_string("x\ny\"z")},
        }, true);
        std::string json;
        if (encode_canonical_json(obj, json) != aether::core::Status::kOk) {
            std::fprintf(stderr, "encode_canonical_json failed\n");
            failed++;
        } else if (json != "{\"a\":\"x\\ny\\\"z\",\"z\":1}") {
            std::fprintf(stderr, "canonical ordering/escaping mismatch: %s\n", json.c_str());
            failed++;
        }
    }

    // Swift golden parity: EvidenceState canonical JSON must be byte-identical
    {
        CanonicalJsonValue patches = CanonicalJsonValue::make_object({
            {"patch_0", CanonicalJsonValue::make_object({
                {"evidence", CanonicalJsonValue::make_number("0.3")},
                {"lastUpdateMs", CanonicalJsonValue::make_int(1000)},
                {"observationCount", CanonicalJsonValue::make_int(5)},
                {"bestFrameId", CanonicalJsonValue::make_string("frame_2")},
                {"errorCount", CanonicalJsonValue::make_int(0)},
                {"errorStreak", CanonicalJsonValue::make_int(0)},
                {"lastGoodUpdateMs", CanonicalJsonValue::make_int(1000)},
            }, true)},
            {"patch_1", CanonicalJsonValue::make_object({
                {"evidence", CanonicalJsonValue::make_number("0.6")},
                {"lastUpdateMs", CanonicalJsonValue::make_int(2000)},
                {"observationCount", CanonicalJsonValue::make_int(10)},
                {"bestFrameId", CanonicalJsonValue::make_string("frame_5")},
                {"errorCount", CanonicalJsonValue::make_int(1)},
                {"errorStreak", CanonicalJsonValue::make_int(0)},
                {"lastGoodUpdateMs", CanonicalJsonValue::make_int(2000)},
            }, true)},
            {"patch_2", CanonicalJsonValue::make_object({
                {"evidence", CanonicalJsonValue::make_number("0.9")},
                {"lastUpdateMs", CanonicalJsonValue::make_int(3000)},
                {"observationCount", CanonicalJsonValue::make_int(20)},
                {"bestFrameId", CanonicalJsonValue::make_string("frame_10")},
                {"errorCount", CanonicalJsonValue::make_int(0)},
                {"errorStreak", CanonicalJsonValue::make_int(0)},
                {"lastGoodUpdateMs", CanonicalJsonValue::make_int(3000)},
            }, true)},
        }, true);

        CanonicalJsonValue root = CanonicalJsonValue::make_object({
            {"patches", patches},
            {"gateDisplay", CanonicalJsonValue::make_number("0.5")},
            {"softDisplay", CanonicalJsonValue::make_number("0.45")},
            {"lastTotalDisplay", CanonicalJsonValue::make_number("0.475")},
            {"schemaVersion", CanonicalJsonValue::make_string("3.0")},
            {"exportedAtMs", CanonicalJsonValue::make_int(1234567890)},
        }, true);

        std::string encoded;
        if (encode_canonical_json(root, encoded) != aether::core::Status::kOk) {
            std::fprintf(stderr, "failed to encode Swift golden state\n");
            failed++;
        } else {
            const std::string path = std::string(AETHER_REPO_ROOT) +
                "/Tests/Evidence/Fixtures/Golden/evidence_state_v2.1.json";
            std::ifstream in(path);
            std::string golden((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            if (!in.good() && !in.eof()) {
                std::fprintf(stderr, "failed to read golden file: %s\n", path.c_str());
                failed++;
            } else if (encoded != golden) {
                std::fprintf(stderr, "Swift golden JSON parity mismatch\n");
                failed++;
            }
        }
    }

    // Hash determinism
    {
        CanonicalJsonValue payload = CanonicalJsonValue::make_object({
            {"x", CanonicalJsonValue::make_number_quantized(0.25)},
            {"y", CanonicalJsonValue::make_number_quantized(0.75)},
        }, true);
        std::string h1, h2;
        if (canonical_json_sha256_hex(payload, h1) != aether::core::Status::kOk ||
            canonical_json_sha256_hex(payload, h2) != aether::core::Status::kOk) {
            std::fprintf(stderr, "hash generation failed\n");
            failed++;
        } else if (h1 != h2 || h1.size() != 64) {
            std::fprintf(stderr, "hash determinism mismatch\n");
            failed++;
        }
    }

    return failed;
}
