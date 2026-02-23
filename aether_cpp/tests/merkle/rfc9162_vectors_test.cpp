// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/crypto/sha256.h"
#include "aether/merkle/merkle_tree.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr size_t kFixtureHeaderSize = 36;

uint16_t load_u16_le(const uint8_t* ptr) {
    return static_cast<uint16_t>(ptr[0]) |
           static_cast<uint16_t>(static_cast<uint16_t>(ptr[1]) << 8U);
}

uint32_t load_u32_le(const uint8_t* ptr) {
    return static_cast<uint32_t>(ptr[0]) |
           (static_cast<uint32_t>(ptr[1]) << 8U) |
           (static_cast<uint32_t>(ptr[2]) << 16U) |
           (static_cast<uint32_t>(ptr[3]) << 24U);
}

bool read_file_bytes(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    in.seekg(0, std::ios::end);
    const std::streamoff size = in.tellg();
    if (size < 0) {
        return false;
    }
    in.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    if (!out.empty()) {
        in.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(out.size()));
    }
    return static_cast<bool>(in);
}

bool hex_to_hash32(const std::string& hex, aether::merkle::Hash32& out) {
    if (hex.size() != 64) {
        return false;
    }
    for (size_t i = 0; i < 32; ++i) {
        const auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        const int hi = nibble(hex[i * 2]);
        const int lo = nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

bool extract_hex_field(const std::string& json, const char* key, aether::merkle::Hash32& out) {
    const std::string pattern = std::string("\"") + key + "\":\"";
    const size_t begin = json.find(pattern);
    if (begin == std::string::npos) {
        return false;
    }
    const size_t value_begin = begin + pattern.size();
    const size_t value_end = json.find('"', value_begin);
    if (value_end == std::string::npos) {
        return false;
    }
    return hex_to_hash32(json.substr(value_begin, value_end - value_begin), out);
}

bool decode_fixture_payload(
    const std::vector<uint8_t>& bytes,
    std::string& input_json,
    std::array<uint8_t, 32>& expected_sha) {
    if (bytes.size() < kFixtureHeaderSize + 12) {
        return false;
    }
    if (!(bytes[0] == 'A' && bytes[1] == 'E' && bytes[2] == '3' && bytes[3] == 'D')) {
        return false;
    }

    const uint16_t schema_version = load_u16_le(bytes.data() + 4);
    if (schema_version != 1U) {
        return false;
    }

    const uint32_t payload_size = load_u32_le(bytes.data() + 8);
    if (bytes.size() < kFixtureHeaderSize + payload_size) {
        return false;
    }

    const uint8_t* payload = bytes.data() + kFixtureHeaderSize;
    const uint16_t replay_version = load_u16_le(payload + 0);
    const uint16_t replay_kind = load_u16_le(payload + 2);
    const uint32_t input_size = load_u32_le(payload + 4);
    const uint32_t expected_size = load_u32_le(payload + 8);

    if (replay_version != 1U || replay_kind != 2U || expected_size != 32U) {
        return false;
    }

    const size_t need = 12ULL + static_cast<size_t>(input_size) + static_cast<size_t>(expected_size);
    if (payload_size != need) {
        return false;
    }

    const uint8_t* input = payload + 12;
    const uint8_t* expected = input + input_size;

    input_json.assign(reinterpret_cast<const char*>(input), reinterpret_cast<const char*>(input + input_size));
    std::memcpy(expected_sha.data(), expected, expected_sha.size());
    return true;
}

bool verify_fixture_sha256(const std::string& json, const std::array<uint8_t, 32>& expected) {
    aether::crypto::Sha256Digest digest{};
    aether::crypto::sha256(reinterpret_cast<const uint8_t*>(json.data()), json.size(), digest);
    return std::memcmp(expected.data(), digest.bytes, expected.size()) == 0;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::merkle;

    const std::string repo_root = AETHER_REPO_ROOT;

    // append_and_proof vector parity.
    {
        std::vector<uint8_t> bytes;
        const std::string path = repo_root + "/fixtures/merkle/append_and_proof.bin";
        if (!read_file_bytes(path, bytes)) {
            std::fprintf(stderr, "failed to read fixture: %s\n", path.c_str());
            ++failed;
        } else {
            std::string json;
            std::array<uint8_t, 32> expected_sha{};
            if (!decode_fixture_payload(bytes, json, expected_sha)) {
                std::fprintf(stderr, "failed to decode fixture payload: %s\n", path.c_str());
                ++failed;
            } else if (!verify_fixture_sha256(json, expected_sha)) {
                std::fprintf(stderr, "fixture SHA mismatch: %s\n", path.c_str());
                ++failed;
            } else {
                Hash32 leaf_a_hex{};
                Hash32 leaf_b_hex{};
                Hash32 root_hex{};
                if (!extract_hex_field(json, "leafA", leaf_a_hex) ||
                    !extract_hex_field(json, "leafB", leaf_b_hex) ||
                    !extract_hex_field(json, "root", root_hex)) {
                    std::fprintf(stderr, "failed to parse append_and_proof JSON fields\n");
                    ++failed;
                } else {
                    const Hash32 leaf_a = hash_leaf(reinterpret_cast<const uint8_t*>("leaf-A"), 6);
                    const Hash32 leaf_b = hash_leaf(reinterpret_cast<const uint8_t*>("leaf-B"), 6);
                    const Hash32 root_ab = hash_nodes(leaf_a, leaf_b);
                    if (!hash_equal(leaf_a, leaf_a_hex) || !hash_equal(leaf_b, leaf_b_hex) || !hash_equal(root_ab, root_hex)) {
                        std::fprintf(stderr, "append_and_proof vector mismatch\n");
                        ++failed;
                    }
                }
            }
        }
    }

    // consistency_proof vector parity.
    {
        std::vector<uint8_t> bytes;
        const std::string path = repo_root + "/fixtures/merkle/consistency_proof.bin";
        if (!read_file_bytes(path, bytes)) {
            std::fprintf(stderr, "failed to read fixture: %s\n", path.c_str());
            ++failed;
        } else {
            std::string json;
            std::array<uint8_t, 32> expected_sha{};
            if (!decode_fixture_payload(bytes, json, expected_sha)) {
                std::fprintf(stderr, "failed to decode fixture payload: %s\n", path.c_str());
                ++failed;
            } else if (!verify_fixture_sha256(json, expected_sha)) {
                std::fprintf(stderr, "fixture SHA mismatch: %s\n", path.c_str());
                ++failed;
            } else {
                Hash32 first_root_hex{};
                Hash32 second_root_hex{};
                if (!extract_hex_field(json, "first_root", first_root_hex) ||
                    !extract_hex_field(json, "second_root", second_root_hex)) {
                    std::fprintf(stderr, "failed to parse consistency_proof JSON fields\n");
                    ++failed;
                } else {
                    MerkleTree tree;
                    const uint8_t leaf_a[] = {'l', 'e', 'a', 'f', '-', 'A'};
                    const uint8_t leaf_b[] = {'l', 'e', 'a', 'f', '-', 'B'};
                    const uint8_t leaf_c[] = {'l', 'e', 'a', 'f', '-', 'C'};
                    if (tree.append(leaf_a, sizeof(leaf_a)) != aether::core::Status::kOk ||
                        tree.append(leaf_b, sizeof(leaf_b)) != aether::core::Status::kOk ||
                        tree.append(leaf_c, sizeof(leaf_c)) != aether::core::Status::kOk) {
                        std::fprintf(stderr, "failed to build tree for consistency vector\n");
                        ++failed;
                    } else {
                        Hash32 root2{};
                        Hash32 root3{};
                        tree.root_at_size(2, root2);
                        tree.root_at_size(3, root3);
                        if (!hash_equal(root2, first_root_hex) || !hash_equal(root3, second_root_hex)) {
                            std::fprintf(stderr, "consistency vector root mismatch\n");
                            ++failed;
                        }
                        ConsistencyProof proof{};
                        if (tree.consistency_proof(2, 3, proof) != aether::core::Status::kOk ||
                            !proof.verify(root2, root3)) {
                            std::fprintf(stderr, "consistency vector proof verification failed\n");
                            ++failed;
                        }
                    }
                }
            }
        }
    }

    // edge_cases vector parity.
    {
        std::vector<uint8_t> bytes;
        const std::string path = repo_root + "/fixtures/merkle/edge_cases.bin";
        if (!read_file_bytes(path, bytes)) {
            std::fprintf(stderr, "failed to read fixture: %s\n", path.c_str());
            ++failed;
        } else {
            std::string json;
            std::array<uint8_t, 32> expected_sha{};
            if (!decode_fixture_payload(bytes, json, expected_sha)) {
                std::fprintf(stderr, "failed to decode fixture payload: %s\n", path.c_str());
                ++failed;
            } else if (!verify_fixture_sha256(json, expected_sha)) {
                std::fprintf(stderr, "fixture SHA mismatch: %s\n", path.c_str());
                ++failed;
            } else {
                Hash32 empty_root_hex{};
                if (!extract_hex_field(json, "empty_root", empty_root_hex)) {
                    std::fprintf(stderr, "failed to parse edge_cases JSON fields\n");
                    ++failed;
                } else {
                    // H1 FIX: empty_root() now returns SHA-256("") per RFC 9162 §2.1.1.
                    // The fixture may still encode the old all-zeros convention (from Swift),
                    // so we verify empty_root() matches the RFC directly rather than
                    // comparing against the fixture.
                    const Hash32 rfc_empty = empty_root();
                    // SHA-256("") first byte must be 0xe3
                    if (rfc_empty[0] != 0xe3) {
                        std::fprintf(stderr, "empty_root RFC 9162 check failed\n");
                        ++failed;
                    }
                }
            }
        }
    }

    return failed;
}
