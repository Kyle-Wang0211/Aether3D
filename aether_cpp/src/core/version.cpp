// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/aether_version.h"

namespace {
// Hardcoded for now. TODO when convenient: make CMake substitute the
// project version + git short hash via a configure_file()-generated
// header (e.g., aether_version_generated.h). Not on critical path for
// Phase 3.4 FFI validation, so keeping it static.
constexpr const char kVersion[] = "aether 0.1.0-phase3";
}  // namespace

extern "C" const char* aether_version_string(void) {
    return kVersion;
}
