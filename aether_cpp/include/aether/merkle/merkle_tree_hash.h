// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MERKLE_MERKLE_TREE_HASH_H
#define AETHER_MERKLE_MERKLE_TREE_HASH_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace aether {
namespace merkle {

using Hash32 = std::array<uint8_t, 32>;

constexpr uint8_t kLeafPrefix = 0x00;
constexpr uint8_t kNodePrefix = 0x01;

Hash32 hash_leaf(const uint8_t* data, size_t len);
Hash32 hash_leaf(const std::string& text);
Hash32 hash_nodes(const Hash32& left, const Hash32& right);
Hash32 empty_root();

bool hash_equal(const Hash32& a, const Hash32& b);
bool hash_is_zero(const Hash32& hash);

std::string hash_to_hex(const Hash32& hash);
bool hash_from_hex(const std::string& hex, Hash32& out_hash);

}  // namespace merkle
}  // namespace aether

#endif  // AETHER_MERKLE_MERKLE_TREE_HASH_H
