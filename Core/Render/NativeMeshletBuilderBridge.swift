// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for meshlet (GPU mesh shader) construction.
enum NativeMeshletBuilderBridge {
    static func defaultConfig() -> aether_meshlet_build_config_t {
        #if canImport(CAetherNativeBridge)
        var config = aether_meshlet_build_config_t()
        _ = aether_meshlet_default_config(&config)
        return config
        #else
        return aether_meshlet_build_config_t()
        #endif
    }
}
