// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/memory/arena.h"
#include <cassert>
#include <cstdio>

int main() {
    int failed = 0;
    aether::memory::Arena arena;
    arena.init(4096);
    if (arena.data == nullptr || arena.capacity != 4096) {
        std::fprintf(stderr, "arena init failed\n");
        failed++;
    }
    void* p = arena.allocate(64, 8);
    if (p == nullptr || arena.used < 64) {
        std::fprintf(stderr, "arena allocate failed\n");
        failed++;
    }
    if (arena.allocate(16, 0) != nullptr) {
        std::fprintf(stderr, "arena alignment=0 must fail\n");
        failed++;
    }
    if (arena.allocate(static_cast<size_t>(-1), 8) != nullptr) {
        std::fprintf(stderr, "arena huge allocation must fail\n");
        failed++;
    }
    // Exhaust arena and ensure overflow-safe failure instead of wraparound.
    (void)arena.allocate(4000, 8);
    if (arena.allocate(128, 8) != nullptr) {
        std::fprintf(stderr, "arena should reject allocation past capacity\n");
        failed++;
    }
    arena.reset();
    if (arena.used != 0) {
        std::fprintf(stderr, "arena reset failed\n");
        failed++;
    }
    return failed;
}
