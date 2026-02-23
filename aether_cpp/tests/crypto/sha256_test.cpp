// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/crypto/sha256.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

std::string to_hex(const std::uint8_t* bytes, std::size_t count) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.resize(count * 2u);
    for (std::size_t i = 0u; i < count; ++i) {
        const std::uint8_t b = bytes[i];
        out[2u * i] = kHex[(b >> 4u) & 0x0fu];
        out[2u * i + 1u] = kHex[b & 0x0fu];
    }
    return out;
}

}  // namespace

int main() {
    int failed = 0;

    struct Vector {
        const char* msg;
        const char* expected_hex;
    };
    const std::array<Vector, 6u> vectors{{
        {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
        {"hello", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"},
        {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
        {"The quick brown fox jumps over the lazy dog",
         "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"},
        {"The quick brown fox jumps over the lazy dog.",
         "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c"},
    }};

    for (const auto& v : vectors) {
        aether::crypto::Sha256Digest out{};
        const auto* ptr = reinterpret_cast<const std::uint8_t*>(v.msg);
        const std::size_t len = std::strlen(v.msg);
        aether::crypto::sha256(ptr, len, out);
        const std::string got = to_hex(out.bytes, sizeof(out.bytes));
        if (got != v.expected_hex) {
            std::fprintf(stderr, "sha256 vector mismatch for \"%s\"\n", v.msg);
            failed++;
        }
    }

    // len=0 with nullptr must match the empty-message digest.
    {
        aether::crypto::Sha256Digest out{};
        aether::crypto::sha256(nullptr, 0u, out);
        const std::string got = to_hex(out.bytes, sizeof(out.bytes));
        const std::string expected = vectors[0].expected_hex;
        if (got != expected) {
            std::fprintf(stderr, "sha256 nullptr+zero-length mismatch\n");
            failed++;
        }
    }

    // NIST-style long vector: one million 'a' bytes.
    {
        std::vector<std::uint8_t> msg(1000000u, static_cast<std::uint8_t>('a'));
        aether::crypto::Sha256Digest out{};
        aether::crypto::sha256(msg.data(), msg.size(), out);
        const std::string got = to_hex(out.bytes, sizeof(out.bytes));
        const std::string expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
        if (got != expected) {
            std::fprintf(stderr, "sha256 one-million-'a' vector mismatch\n");
            failed++;
        }
    }

    return failed;
}
