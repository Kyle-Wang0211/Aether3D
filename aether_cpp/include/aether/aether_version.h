// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Minimal C ABI entry point for the cross-platform version string.
// Intentionally the SIMPLEST function in the public C ABI — used as the
// first FFI smoke test from Dart (Phase 3.4) before any real call lands.
//
// String is statically allocated, caller must NOT free.
// Format is opaque — meant for display / logging, not parsing.

#ifndef AETHER_CPP_AETHER_VERSION_H
#define AETHER_CPP_AETHER_VERSION_H

#ifdef __cplusplus
extern "C" {
#endif

const char* aether_version_string(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_CPP_AETHER_VERSION_H
