// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/merkle_tree_hash.h"

#include "aether/crypto/sha256.h"
#include "aether/merkle/merkle_constants.h"

#include <cstdint>
#include <cstring>
#include <string>

namespace aether {
namespace merkle {

Hash32 hash_leaf(const uint8_t* data, size_t len) {
    if (len > static_cast<size_t>(MERKLE_LEAF_DATA_MAX_LEN)) {
        return empty_root();
    }
    if (len > 0 && data == nullptr) {
        return empty_root();
    }

    uint8_t input[1 + MERKLE_LEAF_DATA_MAX_LEN] = {};
    input[0] = kLeafPrefix;
    if (len > 0) {
        std::memcpy(input + 1, data, len);
    }

    crypto::Sha256Digest digest{};
    crypto::sha256(input, 1 + len, digest);

    Hash32 result{};
    std::memcpy(result.data(), digest.bytes, 32);
    return result;
}

Hash32 hash_nodes(const Hash32& left, const Hash32& right) {
    uint8_t input[1 + 32 + 32] = {};
    input[0] = kNodePrefix;
    std::memcpy(input + 1, left.data(), 32);
    std::memcpy(input + 1 + 32, right.data(), 32);

    crypto::Sha256Digest digest{};
    crypto::sha256(input, sizeof(input), digest);

    Hash32 result{};
    std::memcpy(result.data(), digest.bytes, 32);
    return result;
}

Hash32 empty_root() {
    // RFC 9162 §2.1.1: MTH({}) = SHA-256("") — the hash of the empty string.
    // This is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.
    crypto::Sha256Digest digest{};
    crypto::sha256(nullptr, 0, digest);
    Hash32 result{};
    std::memcpy(result.data(), digest.bytes, 32);
    return result;
}

bool hash_equal(const Hash32& a, const Hash32& b) {
    // L6 FIX: Constant-time comparison to prevent timing side-channel attacks.
    // Standard memcmp may short-circuit on the first differing byte, leaking
    // information about how many prefix bytes match.
    volatile uint8_t diff = 0;
    for (size_t i = 0; i < 32; ++i) {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

Hash32 hash_leaf(const std::string& text) {
    return hash_leaf(reinterpret_cast<const uint8_t*>(text.data()), text.size());
}

std::string hash_to_hex(const Hash32& hash) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out(64, '0');
    for (size_t i = 0; i < 32; ++i) {
        out[2 * i]     = kHex[(hash[i] >> 4) & 0x0f];
        out[2 * i + 1] = kHex[hash[i] & 0x0f];
    }
    return out;
}

bool hash_from_hex(const std::string& hex, Hash32& out_hash) {
    if (hex.size() != 64) return false;
    for (size_t i = 0; i < 32; ++i) {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
            if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
            return -1;
        };
        int hi = nibble(hex[2 * i]);
        int lo = nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out_hash[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

bool hash_is_zero(const Hash32& hash) {
    for (size_t i = 0; i < 32; ++i) {
        if (hash[i] != 0) {
            return false;
        }
    }
    return true;
}

}  // namespace merkle
}  // namespace aether
