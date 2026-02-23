// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CRYPTO_SHA256_H
#define AETHER_CRYPTO_SHA256_H

#include <cstddef>
#include <cstdint>

namespace aether {
namespace crypto {

struct Sha256Digest {
    uint8_t bytes[32];
};

void sha256(const uint8_t* data, size_t len, Sha256Digest& out);

}  // namespace crypto
}  // namespace aether

#endif  // AETHER_CRYPTO_SHA256_H
