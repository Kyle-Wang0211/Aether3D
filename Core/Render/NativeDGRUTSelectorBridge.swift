// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for 3DGS/DGRUT splat selection and KHR export.
enum NativeDGRUTSelectorBridge {
    static func defaultScoringConfig() -> aether_dgrut_scoring_config_t {
        #if canImport(CAetherNativeBridge)
        var config = aether_dgrut_scoring_config_t()
        _ = aether_dgrut_default_scoring_config(&config)
        return config
        #else
        return aether_dgrut_scoring_config_t()
        #endif
    }
}
