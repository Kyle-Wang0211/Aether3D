// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 3.3 smoke test: link against libaether3d_core, call the C ABI,
// print the result. This is the macOS-side baseline that the Dart FFI
// step (Phase 3.4) must reproduce.

#include "aether/aether_version.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

int main(int /*argc*/, char* /*argv*/[]) {
    const char* v = aether_version_string();
    if (v == nullptr) {
        std::fprintf(stderr, "aether_version_string() returned null\n");
        return EXIT_FAILURE;
    }
    if (std::strlen(v) == 0) {
        std::fprintf(stderr, "aether_version_string() returned empty\n");
        return EXIT_FAILURE;
    }
    std::printf("=== aether_version_test (P3.3) ===\n");
    std::printf("aether_version_string(): \"%s\"\n", v);
    std::printf("length: %zu\n", std::strlen(v));
    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
